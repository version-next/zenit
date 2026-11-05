//! ui.view behavior tests: structure, style paths (static / theme playback / reactive),
//! control flow locating, component protocol, failure rollback.
const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const reactive = @import("reactive.zig");
const types = @import("core/types.zig");
const theme = @import("theme.zig");
const v = @import("view.zig");
const on = @import("on.zig");
const hooks = @import("hooks.zig");

const Node = core.Node;
const Cx = core.Cx;
const Scope = reactive.Scope;
const Color = core.Color;
const BoxStyle = core.BoxStyle;
const TextStyle = core.TextStyle;
const ThemeTokens = theme.ThemeTokens;
const ViewParts = v.ViewParts;

const Env = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !Env {
        const cx = try Cx.init(testing.allocator, std.testing.io);
        cx.tokens = &theme.light;
        const scope = try Scope.init(testing.allocator, null, cx.owner);
        return .{ .cx = cx, .scope = scope };
    }

    /// Teardown order: dispose scope first, then free node tree.
    fn deinit(self: Env, root: ?*Node) void {
        self.scope.dispose();
        if (root) |r| self.cx.freeNode(r);
        self.cx.deinit();
    }
};

fn textOf(n: *Node) []const u8 {
    return n.getText().?.content;
}

/// Non-anchor child nodes (anchors track position in control flow regions)
fn content(parent: *Node, i: usize) *Node {
    var k: usize = 0;
    for (parent.children.items) |c| {
        if (c.tag == .anchor) continue;
        if (k == i) return c;
        k += 1;
    }
    @panic("content: index out of range");
}

fn contentLen(parent: *Node) usize {
    var k: usize = 0;
    for (parent.children.items) |c| {
        if (c.tag != .anchor) k += 1;
    }
    return k;
}

// ---------- Stylesheet (mock styles.zig) ----------

const S = struct {
    fn root(t: *const ThemeTokens) BoxStyle {
        return .{ .gap = t.tokens.space.space200, .background = t.tokens.color.bg_primary };
    }
    fn card(t: *const ThemeTokens) BoxStyle {
        return .{ .background = t.tokens.color.bg_secondary, .padding = core.Padding.all(t.tokens.space.space400) };
    }
    fn selected(t: *const ThemeTokens) BoxStyle {
        return .{ .background = t.tokens.color.accent, .border_color = t.tokens.color.accent };
    }
    fn title(t: *const ThemeTokens) TextStyle {
        return .{ .font_size = t.tokens.font_size.xxl, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    const Size = enum { sm, lg };
    fn sized(size: Size, t: *const ThemeTokens) BoxStyle {
        return .{ .padding = core.Padding.all(if (size == .sm) t.tokens.space.space100 else t.tokens.space.space400) };
    }
    fn label(size: Size, t: *const ThemeTokens) TextStyle {
        return .{ .font_size = if (size == .sm) t.tokens.font_size.sm else t.tokens.font_size.xl, .color = t.tokens.color.fg_primary };
    }
};

test "render: 元素树结构、row/col 方向、字符串子元素、test_id / on_click" {
    const env = try Env.init();
    const clicks = try env.scope.createSignal(u32, 0);
    const root = try v.render(env.scope, env.cx, v.col(.{ .style = S.root, .test_id = "root" }, .{
        v.text(.{ .style = S.title }, "Title"),
        v.row(.{ .style = .{ .gap = 4 }, .on_click = on.update(clicks, struct {
            fn inc(x: u32) u32 {
                return x + 1;
            }
        }.inc) }, .{ "a", "b" }),
        null,
        v.spacer(),
    }));
    defer env.deinit(root);

    try testing.expectEqualStrings("root", root.meta.ownership.meta.test_id.?);
    try testing.expectEqual(core.Direction.column, root.style.direction);
    try testing.expectEqual(theme.light.tokens.space.space200, root.style.gap);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_primary, root.getBackground()));
    try testing.expectEqual(@as(usize, 3), root.children.items.len);

    const title = root.children.items[0];
    try testing.expectEqualStrings("Title", textOf(title));
    try testing.expectEqual(theme.light.tokens.font_size.xxl, title.getText().?.font_size);

    const r = root.children.items[1];
    try testing.expectEqual(core.Direction.row, r.style.direction);
    try testing.expectEqual(@as(f32, 4), r.style.gap);
    try testing.expectEqualStrings("a", textOf(r.children.items[0]));
    try testing.expectEqualStrings("b", textOf(r.children.items[1]));
    // String child uses theme default text style
    try testing.expect(Color.eql(theme.light.tokens.color.fg_primary, r.children.items[0].getText().?.color));

    const h = r.behavior.events.on_click.?;
    h.callback(h.context);
    try testing.expectEqual(@as(u32, 1), clicks.peek());
}

test "style: 编译期可知的样式（函数 + 字面量 tuple）走 on_theme 重放，不建 effect" {
    const env = try Env.init();
    const effects_before = env.scope.effects.items.len;
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ S.card, .{ .gap = 3 } } }, .{
        v.text(.{ .style = S.title }, "x"),
        v.text(.{}, "default"),
    }));
    defer env.deinit(root);

    try testing.expect(root.meta.per_frame.hooks.on_theme != null);
    try testing.expectEqual(@as(f32, 3), root.style.gap);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));
    // No effect in render subscope (static style zero cost)
    try testing.expectEqual(effects_before, env.scope.effects.items.len);
    try testing.expectEqual(@as(usize, 0), env.scope.children.items[0].effects.items.len);

    env.cx.root = root;
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, root.getBackground()));
    try testing.expectEqual(@as(f32, 3), root.style.gap); // Literal part still there after playback
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_primary, root.children.items[0].getText().?.color));
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_primary, root.children.items[1].getText().?.color));
    env.cx.root = null;
}

test "style: v.when 开合，撤销时被它设置过的字段回到默认（含 border 细粒度字段）" {
    const env = try Env.init();
    const sel = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{
        .{ .border_width = 1, .gap = 2 },
        v.when(sel, S.selected),
        v.when(sel, BoxStyle{ .opacity = 0.5, .corner_radius = 6 }),
    } }, .{}));
    defer env.deinit(root);

    try testing.expect(Color.eql(Color.TRANSPARENT, root.getBackground()));
    try testing.expectEqual(@as(f32, 1), root.style.border.width);
    const default_border_color = root.style.border.color;

    sel.set(true);
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.style.border.color));
    try testing.expectEqual(@as(f32, 1), root.style.border.width);
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.getOpacity(), 0.001);
    try testing.expectEqual(@as(f32, 6), root.style.ext.?.corner_radius.?.all);

    sel.set(false);
    try testing.expect(Color.eql(Color.TRANSPARENT, root.getBackground()));
    try testing.expect(Color.eql(default_border_color, root.style.border.color));
    try testing.expectEqual(@as(f32, 1), root.style.border.width); // base width replayed
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);
    try testing.expect(root.style.ext.?.corner_radius == null);
    try testing.expectEqual(@as(f32, 2), root.style.gap);
}

test "style: 响应式样式也跟随主题；styleBy 按源值选样式（box 与 text）" {
    const env = try Env.init();
    const sel = try env.scope.createSignal(bool, true);
    const size = try env.scope.createSignal(S.Size, .sm);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ S.card, v.when(sel, S.selected), v.styleBy(size, S.sized) } }, .{
        v.text(.{ .style = v.styleBy(size, S.label) }, "label"),
    }));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;

    const label = root.children.items[0];
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));
    try testing.expectEqual(theme.light.tokens.space.space100, root.style.padding.top);
    try testing.expectEqual(theme.light.tokens.font_size.sm, label.getText().?.font_size);

    size.set(.lg);
    try testing.expectEqual(theme.light.tokens.space.space400, root.style.padding.top);
    try testing.expectEqual(theme.light.tokens.font_size.xl, label.getText().?.font_size);

    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.accent, root.getBackground()));
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_primary, label.getText().?.color));

    sel.set(false);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, root.getBackground()));
}

test "style: v.hover 跟随节点悬停" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ S.card, v.hover(BoxStyle{ .opacity = 0.25 }) } }, .{}));
    defer env.deinit(root);

    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expectApproxEqAbs(@as(f32, 0.25), root.getOpacity(), 0.001);
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);
}

// ---------- ui.css / ui.cva hookup ----------

const css = @import("css.zig").css;
const cva = @import("css.zig").cva;

const C = struct {
    const card = css(.{ .background = .bg_secondary, .padding = .space400, .corner_radius = .md });
    const hot = css(.{ .background = .bg_secondary, ._hover = .{ .background = .bg_hover, .opacity = 0.5 } });
    const picked = css(.{ .background = .accent });
    const muted = css(.{ .color = .fg_tertiary, .strikethrough = true });
    const big = css(.{ .font_size = .xxl });
    const Btn = cva(.{
        .base = .{ .corner_radius = .md },
        .variants = .{
            .intent = .{ .primary = .{ .background = .accent }, .ghost = .{ .background = Color.TRANSPARENT, ._hover = .{ .background = .bg_hover } } },
        },
    });
};

test "css: token 样式走 on_theme 重放（不建 effect），换主题取新值" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = C.card }, .{
        v.box(.{ .style = .{ .gap = .space200, .background = .bg_hover } }, .{}), // Inline literal also recognizes token
    }));
    defer env.deinit(root);
    try testing.expect(root.meta.per_frame.hooks.on_theme != null);
    try testing.expectEqual(@as(usize, 0), env.scope.children.items[0].effects.items.len);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));
    try testing.expectEqual(theme.light.tokens.space.space400, root.style.padding.top);
    const inner = root.children.items[0];
    try testing.expect(inner.meta.per_frame.hooks.on_theme != null);
    try testing.expectEqual(theme.light.tokens.space.space200, inner.style.gap);

    env.cx.root = root;
    defer env.cx.root = null;
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, root.getBackground()));
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_hover, inner.getBackground()));
}

test "css: _hover 跟随悬停（单独用与放进 v.when 里都生效）" {
    const env = try Env.init();
    const on_flag = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = C.hot }, .{
        v.box(.{ .style = .{ C.card, v.when(on_flag, C.hot) } }, .{}),
    }));
    defer env.deinit(root);

    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_hover, root.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.getOpacity(), 0.001);
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001); // Hover layer override retracted

    const inner = root.children.items[0];
    on_flag.set(true);
    const enter2 = inner.behavior.events.on_hover.?;
    enter2.callback(enter2.context);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_hover, inner.getBackground()));
}

test "overlay：静态样式叠到已分层的组件根上也进层，换主题后不被组件自己的样式重算抹掉" {
    const env = try Env.init();
    const ControlShell = @import("components/control_shell/mod.zig").ControlShell;
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .style = BoxStyle{ .width = .{ .px = 77 }, .padding = core.Padding.all(3) } }, v.with(ControlShell(.{ .variant = .field }), .{}).slots(.{ .content = v.text(.{}, "x") })),
    }));
    defer env.deinit(root);
    const shell = root.children.items[0];
    try testing.expectEqual(core.Sizing{ .px = 77 }, shell.style.width);
    env.cx.setTheme(&theme.dark);
    try testing.expectEqual(core.Sizing{ .px = 77 }, shell.style.width);
    try testing.expectEqual(core.Padding.all(3), shell.style.padding);
    const bg = if (shell.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.background)) |slot| if (slot.active) slot.to_color else shell.getBackground() else shell.getBackground() else shell.getBackground();
    try testing.expect(Color.eql(theme.dark.tokens.color.input_bg, bg));
}

test "overlay state：叠加层的条件样式读调用方给的状态源，跟随信号切换" {
    const env = try Env.init();
    const ControlShell = @import("components/control_shell/mod.zig").ControlShell;
    const invalid = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .style = css(.{ .padding = 2, ._invalid = .{ .padding = 6 } }), .state = .{ .invalid = invalid } }, v.with(ControlShell(.{ .variant = .field, .invalid = invalid }), .{}).slots(.{ .content = v.text(.{}, "x") })),
    }));
    defer env.deinit(root);
    const shell = root.children.items[0];
    try testing.expectEqual(core.Padding.all(2), shell.style.padding);
    invalid.set(true);
    try testing.expectEqual(core.Padding.all(6), shell.style.padding);
    invalid.set(false);
    try testing.expectEqual(core.Padding.all(2), shell.style.padding);
}

test "文字颜色继承：祖先 text_color 只填补未声明的颜色，文字自己声明的颜色总是优先" {
    const env = try Env.init();
    const painted = @import("core/render_engine/text_render.zig").resolveNodeLogicalTextProps;
    const t = theme.light.tokens.color;
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = css(.{ .text_color = .fg_inverse }) }, .{
        v.text(.{}, "inherits"),
        v.text(.{ .style = css(.{ .color = .accent }) }, "own css"),
        v.text(.{ .style = TextStyle{ .color = t.danger } }, "own value"),
    }));
    defer env.deinit(root);
    try testing.expect(Color.eql(t.fg_inverse, painted(root.children.items[0]).?.color));
    try testing.expect(Color.eql(t.accent, painted(root.children.items[1]).?.color));
    try testing.expect(Color.eql(t.danger, painted(root.children.items[2]).?.color));
}

test "挂载时已在的状态（disabled / 钉住 hover）立即生效不走过渡；之后的变化照常过渡" {
    const env = try Env.init();
    const style = css(.{
        .background = .bg_primary,
        .transition = @import("recipe.zig").transition("background 150ms ease-out"),
        ._hover = .{ .background = .bg_hover },
        ._disabled = .{ .background = .disabled_bg },
    });
    const disabled = try env.scope.createSignal(bool, true);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = style, .state = .{ .disabled = disabled } }, .{}),
        v.box(.{ .style = style, .state = .{ .hover = true, .disabled = false } }, .{}),
    }));
    defer env.deinit(root);
    const t = theme.light.tokens.color;
    const animating = struct {
        fn f(n: *Node) bool {
            const slots = n.frame_state.frame_local.runtime.transitions orelse return false;
            const slot = slots.find(.background) orelse return false;
            return slot.active;
        }
    }.f;
    const kids = root.children.items;
    try testing.expect(Color.eql(t.disabled_bg, kids[0].getBackground()));
    try testing.expect(!animating(kids[0]));
    try testing.expect(Color.eql(t.bg_hover, kids[1].getBackground()));
    try testing.expect(!animating(kids[1]));
    disabled.set(false);
    try testing.expect(animating(kids[0]));
}

test "state 钉住：hover / active 不随指针；钉住 false 时悬停也不生效；disabled 压过钉住；信号可切换" {
    const env = try Env.init();
    const pressed_style = css(.{ .background = .bg_secondary, ._hover = .{ .background = .bg_hover }, ._active = .{ .background = .accent }, ._disabled = .{ .background = .disabled_bg } });
    const pin_active = try env.scope.createSignal(bool, false);
    const off = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = pressed_style, .state = .{ .hover = true, .disabled = false } }, .{}),
        v.box(.{ .style = pressed_style, .state = .{ .hover = false, .disabled = false } }, .{}),
        v.box(.{ .style = pressed_style, .state = .{ .hover = true, .active = pin_active, .disabled = off } }, .{}),
    }));
    defer env.deinit(root);
    const t = theme.light.tokens.color;
    const held = root.children.items[0];
    const never = root.children.items[1];
    const live = root.children.items[2];
    // Pinned on: hover colours with no pointer at all.
    try testing.expect(Color.eql(t.bg_hover, held.getBackground()));
    // Pinned off: a real hover does not apply.
    if (never.behavior.events.on_hover) |enter| enter.callback(enter.context);
    try testing.expect(Color.eql(t.bg_secondary, never.getBackground()));
    // Pin from a signal: switches; disabled short-circuits the pin.
    try testing.expect(Color.eql(t.bg_hover, live.getBackground()));
    pin_active.set(true);
    try testing.expect(Color.eql(t.accent, live.getBackground()));
    off.set(true);
    try testing.expect(Color.eql(t.disabled_bg, live.getBackground()));
}

test "css: 文本样式从主题默认值起按字段叠加，v.when(css) 开合，换主题跟随" {
    const env = try Env.init();
    const done = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.text(.{ .style = .{ C.big, v.when(done, C.muted) } }, "task"),
        v.text(.{ .style = .{ .font_size = .sm } }, "literal"),
    }));
    defer env.deinit(root);
    const a = root.children.items[0];
    const b = root.children.items[1];
    try testing.expectEqual(theme.light.tokens.font_size.xxl, a.getText().?.font_size);
    try testing.expect(Color.eql(theme.light.tokens.color.fg_primary, a.getText().?.color));
    try testing.expect(!a.getText().?.strikethrough);
    // Literal only changes declared field; color uses theme default (not TextStyle struct default)
    try testing.expectEqual(theme.light.tokens.font_size.sm, b.getText().?.font_size);
    try testing.expect(Color.eql(theme.light.tokens.color.fg_primary, b.getText().?.color));

    done.set(true);
    try testing.expect(Color.eql(theme.light.tokens.color.fg_tertiary, a.getText().?.color));
    try testing.expect(a.getText().?.strikethrough);
    try testing.expectEqual(theme.light.tokens.font_size.xxl, a.getText().?.font_size);

    env.cx.root = root;
    defer env.cx.root = null;
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_tertiary, a.getText().?.color));
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_primary, b.getText().?.color));

    done.set(false);
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_primary, a.getText().?.color));
    try testing.expect(!a.getText().?.strikethrough);
}

test "cva: 变体值来自信号时随之切换，变体里的 _hover 生效" {
    const env = try Env.init();
    const Intent = enum { primary, ghost };
    const intent = try env.scope.createSignal(Intent, .primary);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = C.Btn.of(.{ .intent = intent }) }, .{
        v.box(.{ .style = C.Btn.of(.{ .intent = .ghost }) }, .{}),
    }));
    defer env.deinit(root);

    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));
    try testing.expectEqual(theme.light.tokens.radius.md, root.style.ext.?.corner_radius.?.all);
    intent.set(.ghost);
    try testing.expect(Color.eql(Color.TRANSPARENT, root.getBackground()));
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_hover, root.getBackground()));
    intent.set(.primary); // primary has no hover layer: also reverts to accent while hovering
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));

    const fixed = root.children.items[0];
    try testing.expect(Color.eql(Color.TRANSPARENT, fixed.getBackground()));
}

test "cva: 静态变体里没有 _hover 时不需要悬停——不建悬停钩子与 effect；静态 when(false, _hover) 同理" {
    const env = try Env.init();
    const Intent = enum { primary, ghost };
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = C.Btn.of(.{ .intent = reactive.Source(Intent).of(.primary) }) }, .{}),
        v.box(.{ .style = .{ C.card, v.when(reactive.Source(bool).of(false), C.hot) } }, .{}),
    }));
    defer env.deinit(root);
    try testing.expectEqual(before, env.cx.owner.graph.countByKind().get(.effect));
    for (root.children.items) |n| try testing.expect(n.behavior.events.on_hover == null);
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.children.items[0].getBackground()));

    // Variant picked statically has _hover: the hover hook is built as usual and hover takes effect
    const ghost = try v.render(env.scope, env.cx, v.box(.{ .style = C.Btn.of(.{ .intent = reactive.Source(Intent).of(.ghost) }) }, .{}));
    defer env.cx.freeNode(ghost);
    const enter = ghost.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_hover, ghost.getBackground()));
}

test "cva: 普通运行期枚举走静态取值，嵌套 token 随主题重放" {
    const R = @import("css.zig").cva(.{
        .variants = .{ .size = .{ .sm = .{ .padding = .{ .x = .space100 }, .border = .{ .width = .thin, .color = .border } }, .lg = .{ .padding = .{ .x = .space400 } } } },
    });
    var size: R.Dim(.size) = .sm;
    _ = &size;
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = R.of(.{ .size = size }) }, .{}));
    defer env.deinit(root);
    try testing.expectEqual(theme.light.tokens.space.space100, root.style.padding.left);
    env.cx.root = root;
    defer env.cx.root = null;
    env.cx.setTheme(&theme.dark);
    try testing.expectEqual(theme.dark.tokens.space.space100, root.style.padding.left);
    try testing.expect(Color.eql(theme.dark.tokens.color.border, root.style.border.color));
}

test "text: 静态 / v.fmt / 响应式源三种内容" {
    const env = try Env.init();
    const count = try env.scope.createSignal(u32, 1);
    const name = try env.scope.createSignal([]const u8, "zen");
    const doubled = reactive.map(count, struct {
        fn f(x: u32) u32 {
            return x * 2;
        }
    }.f);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.text(.{}, "static"),
        v.text(.{}, v.fmt("n={d} x2={d}", .{ count, doubled })),
        v.text(.{}, name),
    }));
    defer env.deinit(root);

    try testing.expectEqualStrings("static", textOf(root.children.items[0]));
    try testing.expectEqualStrings("n=1 x2=2", textOf(root.children.items[1]));
    try testing.expectEqualStrings("zen", textOf(root.children.items[2]));
    count.set(5);
    name.set("zenit");
    try testing.expectEqualStrings("n=5 x2=10", textOf(root.children.items[1]));
    try testing.expectEqualStrings("zenit", textOf(root.children.items[2]));
}

const Page = enum { home, settings, about };

test "控制流：show / fallback / match / each 混排时内容都留在原位" {
    const env = try Env.init();
    const loading = try env.scope.createSignal(bool, true);
    const page = try env.scope.createSignal(Page, .home);
    const Item = struct { id: u32, name: []const u8 };
    const two = [_]Item{ .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "two" } };
    const three = [_]Item{ .{ .id = 3, .name = "three" }, .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "two" } };
    const items = try env.scope.createSignal([]const Item, &two);

    const Row = struct {
        fn row(it: Item) @TypeOf(v.text(.{}, @as([]const u8, ""))) {
            return v.text(.{}, it.name);
        }
    };

    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        "head",
        v.show(loading, .{ "loading", "…" }).fallback(.{"ready"}),
        v.match(page, .{ .home = v.text(.{}, "home"), .@"else" = .{"other"} }),
        v.each(items, .id, Row.row),
        "tail",
    }));
    defer env.deinit(root);

    const expectAll = struct {
        fn f(parent: *Node, want: []const []const u8) !void {
            try testing.expectEqual(want.len, contentLen(parent));
            for (want, 0..) |w, i| try testing.expectEqualStrings(w, textOf(content(parent, i)));
        }
    }.f;

    try expectAll(root, &.{ "head", "loading", "…", "home", "one", "two", "tail" });
    loading.set(false);
    try expectAll(root, &.{ "head", "ready", "home", "one", "two", "tail" });
    page.set(.about);
    try expectAll(root, &.{ "head", "ready", "other", "one", "two", "tail" });
    items.set(&three);
    try expectAll(root, &.{ "head", "ready", "other", "three", "one", "two", "tail" });
    loading.set(true);
    page.set(.home);
    try expectAll(root, &.{ "head", "loading", "…", "home", "three", "one", "two", "tail" });
}

test "控制流：嵌套 show 跟随外层一起卸载，不留节点" {
    const env = try Env.init();
    const outer = try env.scope.createSignal(bool, true);
    const inner = try env.scope.createSignal(bool, true);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        "a",
        v.show(outer, .{ "b", v.show(inner, .{"c"}), "d" }),
        "e",
    }));
    defer env.deinit(root);

    try testing.expectEqual(@as(usize, 5), contentLen(root));
    inner.set(false);
    try testing.expectEqual(@as(usize, 4), contentLen(root));
    outer.set(false);
    try testing.expectEqual(@as(usize, 2), contentLen(root));
    try testing.expectEqualStrings("e", textOf(content(root, 1)));
    // After outer unmounts, only outer anchors remain
    try testing.expectEqual(@as(usize, 4), root.children.items.len);
    inner.set(true); // Inner region already destroyed with outer scope; shouldn't react
    try testing.expectEqual(@as(usize, 2), contentLen(root));
    outer.set(true);
    try testing.expectEqual(@as(usize, 5), contentLen(root));
}

test "each: eachWith 上下文 + on.bind 捕获行值" {
    const env = try Env.init();
    const Item = struct { id: u32 };
    const data = [_]Item{ .{ .id = 7 }, .{ .id = 9 } };
    const picked = try env.scope.createSignal(u32, 0);

    const Ctx = struct { picked: *reactive.Signal(u32) };
    const RowC = struct {
        scope: *Scope,
        ctx: Ctx,
        id: u32,
        pub fn mount(self: @This(), scope: *Scope, cx: *Cx) !*Node {
            _ = self.scope;
            return v.render(scope, cx, v.box(.{ .on_click = try on.bind(scope, .{ .sig = self.ctx.picked, .id = self.id }, struct {
                fn f(c: anytype) void {
                    c.sig.set(c.id);
                }
            }.f) }, .{}));
        }
    };
    const rowFn = struct {
        fn r(ctx: Ctx, it: Item) RowC {
            return .{ .scope = undefined, .ctx = ctx, .id = it.id };
        }
    }.r;

    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.eachWith(Ctx{ .picked = picked }, &data, .id, rowFn)}));
    defer env.deinit(root);

    const second = content(root, 1);
    const h = second.behavior.events.on_click.?;
    h.callback(h.context);
    try testing.expectEqual(@as(u32, 9), picked.peek());
}

test "each: 组件形态行函数 fn (T, *Scope, *Cx) !*Node，行内 signal 随行卸载" {
    const env = try Env.init();
    const Item = struct { id: u32, name: []const u8 };
    const two = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" } };
    const one = [_]Item{.{ .id = 2, .name = "b" }};
    const items = try env.scope.createSignal([]const Item, &two);

    const Row = struct {
        fn row(it: Item, scope: *Scope, cx: *Cx) !*Node {
            const local = try scope.createSignal(u32, it.id * 10);
            return v.render(scope, cx, v.text(.{}, v.fmt("{s}:{d}", .{ it.name, local })));
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.each(items, .id, Row.row)}));
    defer env.deinit(root);

    try testing.expectEqual(@as(usize, 2), contentLen(root));
    try testing.expectEqualStrings("a:10", textOf(content(root, 0)));
    items.set(&one);
    try testing.expectEqual(@as(usize, 1), contentLen(root));
    try testing.expectEqualStrings("b:20", textOf(content(root, 0)));
}

test "each: diff 中某行挂载出错只跳过该行（不 panic、不泄漏），之后可恢复" {
    const env = try Env.init();
    const Item = struct { id: u32, name: []const u8 };
    const good = [_]Item{.{ .id = 1, .name = "a" }};
    const with_bad = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "bad" }, .{ .id = 3, .name = "c" } };
    const items = try env.scope.createSignal([]const Item, &good);
    const Row = struct {
        fn row(it: Item, scope: *Scope, cx: *Cx) !*Node {
            if (std.mem.eql(u8, it.name, "bad")) return error.BadRow;
            return v.render(scope, cx, v.text(.{}, it.name));
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.each(items, .id, Row.row)}));
    defer env.deinit(root);

    const cf = @import("control_flow.zig");
    cf.control_flow_suppress_error_log = true;
    defer cf.control_flow_suppress_error_log = false;
    const errors_before = cf.control_flow_error_count;
    items.set(&with_bad);
    try testing.expect(cf.control_flow_error_count > errors_before);
    try testing.expectEqual(@as(usize, 2), contentLen(root));
    try testing.expectEqualStrings("c", textOf(content(root, 1)));
    items.set(&good);
    try testing.expectEqual(@as(usize, 1), contentLen(root));
}

test "attrs：给组件根补 test_id / 样式；条件撤销回到组件自己的值而不是默认值" {
    const env = try Env.init();
    const sel = try env.scope.createSignal(bool, false);
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            return core.box(cx, .{ .gap = 7, .background = Color.hex(0x112233), .width = .{ .px = 50 } }, .{});
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .test_id = "plain", .style = .{ .width = .{ .px = 80 } } }, Comp{}),
        v.attrs(.{ .test_id = "cond", .style = v.when(sel, BoxStyle{ .gap = 1, .background = Color.hex(0xFF0000) }) }, Comp{}),
    }));
    defer env.deinit(root);

    const plain = root.children.items[0];
    try testing.expectEqualStrings("plain", plain.meta.ownership.meta.test_id.?);
    try testing.expectEqual(@as(f32, 80), plain.style.width.px);
    try testing.expectEqual(@as(f32, 7), plain.style.gap); // Component's own field unchanged

    const cond = root.children.items[1];
    try testing.expectEqual(@as(f32, 7), cond.style.gap);
    sel.set(true);
    try testing.expectEqual(@as(f32, 1), cond.style.gap);
    try testing.expect(Color.eql(Color.hex(0xFF0000), cond.getBackground()));
    sel.set(false);
    try testing.expectEqual(@as(f32, 7), cond.style.gap);
    try testing.expect(Color.eql(Color.hex(0x112233), cond.getBackground()));
}

test "attrs：纯样式函数叠加到组件根（编译期样式不进运行期字段），换主题跟随" {
    const env = try Env.init();
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            return core.box(cx, .{ .gap = 7 }, .{});
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.attrs(.{ .style = S.card }, Comp{})}));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;

    const c = root.children.items[0];
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, c.getBackground()));
    try testing.expectEqual(@as(f32, 7), c.style.gap);
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, c.getBackground()));
}

test "icon：尺寸走 style，着色函数换主题跟随；静态 fmt 只格式化一次不建 effect" {
    const env = try Env.init();
    const Tint = struct {
        fn accent(t: *const ThemeTokens) Color {
            return t.tokens.color.accent;
        }
        fn square(t: *const ThemeTokens) BoxStyle {
            _ = t;
            return .{ .width = .fixed(13), .height = .fixed(13) };
        }
    };
    const effects_before = env.scope.effects.items.len;
    const root = try v.render(env.scope, env.cx, v.row(.{}, .{
        v.icon(.{ .style = Tint.square, .tint = Tint.accent }, @import("ui.zig").icons.chevron_down),
        v.text(.{}, v.fmt("#{d}", .{@as(u32, 42)})),
    }));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;

    const ic = root.children.items[0];
    try testing.expectEqual(@as(f32, 13), ic.style.width.px);
    try testing.expectEqualStrings("#42", textOf(root.children.items[1]));
    try testing.expectEqual(effects_before, env.scope.effects.items.len);
    try testing.expectEqual(@as(usize, 0), env.scope.children.items[0].effects.items.len);

    const tintOf = struct {
        fn get(n: *Node) Color {
            if (n.getIcon()) |i| return i.tint;
            return n.getImage().?.tint;
        }
    }.get;
    try testing.expect(Color.eql(theme.light.tokens.color.accent, tintOf(ic)));
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.accent, tintOf(ic)));
}

test "attrs / setup 包在控制流区域里也能找到正确的根节点" {
    const env = try Env.init();
    const on_flag = try env.scope.createSignal(bool, true);
    const Seen = struct {
        var node: ?*Node = null;
        fn grab(tag: []const u8, n: *Node) void {
            _ = tag;
            node = n;
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        "a",
        v.show(on_flag, .{v.setup(v.attrs(.{ .test_id = "inner" }, Leaf{ .label = "x" }), @as([]const u8, "t"), Seen.grab)}),
        "b",
    }));
    defer env.deinit(root);

    const inner = content(root, 1);
    try testing.expectEqualStrings("inner", inner.meta.ownership.meta.test_id.?);
    try testing.expectEqual(inner, Seen.node.?);
    try testing.expectEqualStrings("x", textOf(inner));
}

test "list / listWith：静态数组展开成兄弟，不建区域锚点" {
    const env = try Env.init();
    const Spec = struct { t: []const u8 };
    const specs = [_]Spec{ .{ .t = "one" }, .{ .t = "two" }, .{ .t = "three" } };
    const props = .{};
    const Fns = struct {
        fn item(s: Spec) v.Text(@TypeOf(props), []const u8) {
            return v.text(props, s.t);
        }
        fn indexed(prefix: []const u8, s: Spec, i: usize) v.Text(@TypeOf(props), []const u8) {
            _ = prefix;
            return v.text(props, if (i == 0) "first" else s.t);
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.list(&specs, Fns.item),
        v.listWith(@as([]const u8, "p"), specs, Fns.indexed),
    }));
    defer env.deinit(root);

    try testing.expectEqual(@as(usize, 6), root.children.items.len); // No anchors
    try testing.expectEqualStrings("three", textOf(root.children.items[2]));
    try testing.expectEqualStrings("first", textOf(root.children.items[3]));
}

test ".visible：切 display 不卸载（子树与其 effect 保留）；v.dynamic 按值重建" {
    const env = try Env.init();
    const shown = try env.scope.createSignal(bool, true);
    const n = try env.scope.createSignal(u32, 1);
    const page = try env.scope.createSignal(u32, 1);
    const PageView = struct {
        fn render(p: u32, scope: *Scope, cx: *Cx) !*Node {
            return v.render(scope, cx, v.text(.{}, v.fmt("page {d}", .{p})));
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .visible = shown }, .{v.text(.{}, v.fmt("n={d}", .{n}))}),
        v.dynamic(page, PageView.render),
    }));
    defer env.deinit(root);

    const panel = root.children.items[0];
    try testing.expectEqual(core.Display.flex, panel.style.display);
    shown.set(false);
    try testing.expectEqual(core.Display.none, panel.style.display);
    n.set(2); // Hidden: subtree still alive, bindings update normally
    try testing.expectEqualStrings("n=2", textOf(panel.children.items[0]));
    shown.set(true);
    try testing.expectEqual(core.Display.flex, panel.style.display);

    try testing.expectEqualStrings("page 1", textOf(content(root, 1)));
    page.set(7);
    try testing.expectEqualStrings("page 7", textOf(content(root, 1)));
    try testing.expectEqual(@as(usize, 2), contentLen(root));
}

// ---------- Component protocol ----------

const Leaf = struct {
    label: []const u8,
    pub fn mount(self: Leaf, _: *Scope, cx: *Cx) !*Node {
        return core.text(cx, self.label, .{});
    }
};

const Panel = struct {
    const Result = struct {
        outer: *Node,
        inner: *Node,
        pub fn viewParts(self: Result) ViewParts {
            return .{ .root = self.outer, .slot = self.inner };
        }
    };
    pub fn mount(_: Panel, _: *Scope, cx: *Cx) !Result {
        const outer = try core.box(cx, .{}, .{});
        errdefer cx.freeNode(outer);
        const inner = try core.box(cx, .{ .gap = 9 }, .{});
        try outer.appendChild(cx.allocator, inner);
        return .{ .outer = outer, .inner = inner };
    }
};

test "attrs .parts：按 Result 字段名给组件内部部件设 test_id（组件与 v.with 两种写法）" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .test_id = "p1", .parts = .{ .inner = "p1.inner" } }, Panel{}),
        v.attrs(.{ .parts = .{ .inner = "p2.inner" } }, v.with(Panel{}, .{"x"})),
        v.with(Panel{}, .{}).parts(.{ .outer = "p3" }),
    }));
    defer env.deinit(root);

    const p1 = root.children.items[0];
    try testing.expectEqualStrings("p1", p1.meta.ownership.meta.test_id.?);
    try testing.expectEqualStrings("p1.inner", p1.children.items[0].meta.ownership.meta.test_id.?);
    const p2 = root.children.items[1];
    try testing.expectEqualStrings("p2.inner", p2.children.items[0].meta.ownership.meta.test_id.?);
    try testing.expectEqualStrings("x", textOf(p2.children.items[0].children.items[0]));
    try testing.expectEqualStrings("p3", root.children.items[2].meta.ownership.meta.test_id.?);
}

test "组件：返回 *Node 直接挂；返回 Result 走 viewParts；with 把子元素放进 slot" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        Leaf{ .label = "leaf" },
        v.with(Panel{}, .{ "x", Leaf{ .label = "y" } }),
    }));
    defer env.deinit(root);

    try testing.expectEqualStrings("leaf", textOf(root.children.items[0]));
    const outer = root.children.items[1];
    const inner = outer.children.items[0];
    try testing.expectEqual(@as(f32, 9), inner.style.gap);
    try testing.expectEqualStrings("x", textOf(inner.children.items[0]));
    try testing.expectEqualStrings("y", textOf(inner.children.items[1]));
}

// ---------- Failure rollback ----------

const Boom = struct {
    pub fn mount(_: Boom, _: *Scope, _: *Cx) !*Node {
        return error.Boom;
    }
};

test "失败回滚：中途失败时整棵树回收、effect 随子 scope 销毁（之后改 signal 不碰已释放节点）" {
    const env = try Env.init();
    defer env.deinit(null);
    const sel = try env.scope.createSignal(bool, false);
    const count = try env.scope.createSignal(u32, 0);
    const scopes_before = env.scope.children.items.len;

    const result = v.render(env.scope, env.cx, v.col(.{ .style = v.when(sel, S.selected) }, .{
        v.text(.{}, v.fmt("{d}", .{count})),
        v.show(sel, .{"shown"}),
        Boom{},
    }));
    try testing.expectError(error.Boom, result);
    try testing.expectEqual(scopes_before, env.scope.children.items.len);
    // Effect depending on these signals already destroyed: future changes don't touch freed nodes
    // (testing.allocator catches UAF/leaks)
    sel.set(true);
    count.set(3);
}

test "失败回滚：show 内容挂载失败只清本区域，兄弟与锚点保留，下一次仍可重建" {
    const env = try Env.init();
    const flag = try env.scope.createSignal(bool, false);
    const Flaky = struct {
        var fail = true;
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            if (fail) return error.Flaky;
            return core.text(cx, "ok", .{});
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{ "a", v.show(flag, .{ "b", Flaky{} }), "c" }));
    defer env.deinit(root);

    const cf = @import("control_flow.zig");
    cf.control_flow_suppress_error_log = true;
    defer cf.control_flow_suppress_error_log = false;
    flag.set(true);
    try testing.expectEqual(@as(usize, 2), contentLen(root));

    Flaky.fail = false;
    defer Flaky.fail = true;
    flag.set(false);
    flag.set(true);
    try testing.expectEqual(@as(usize, 4), contentLen(root));
    try testing.expectEqualStrings("ok", textOf(content(root, 2)));
    try testing.expectEqualStrings("c", textOf(content(root, 3)));
}

test "mount：往已有节点追加，失败时只回收本次追加" {
    const env = try Env.init();
    const parent = try core.box(env.cx, .{}, .{});
    defer env.deinit(parent);
    try parent.appendChild(testing.allocator, try core.text(env.cx, "existing", .{}));

    try v.mount(env.scope, env.cx, parent, .{ "x", "y" });
    try testing.expectEqual(@as(usize, 3), parent.children.items.len);

    try testing.expectError(error.Boom, v.mount(env.scope, env.cx, parent, .{ "z", Boom{} }));
    try testing.expectEqual(@as(usize, 3), parent.children.items.len);
    try testing.expectEqualStrings("y", textOf(parent.children.items[2]));
}

// ---------- Real components ----------

fn subtreeHasText(root: *Node, want: []const u8) bool {
    if (root.getText()) |t| {
        if (std.mem.eql(u8, t.content, want)) return true;
    }
    for (root.children.items) |c| {
        if (subtreeHasText(c, want)) return true;
    }
    return false;
}

test "真实组件：Button / ScrollArea / Card / Popover(trigger) / Modal 经 ViewParts 接入" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    // Popover / Modal content hangs in portal under window root; needs cx.root
    const win = try core.box(env.cx, .{}, .{});
    env.cx.root = win;
    defer {
        env.scope.dispose();
        env.cx.root = null;
        env.cx.freeNode(win);
        env.cx.deinit();
    }
    const open = try env.scope.createSignal(bool, false);
    const modal_open = try env.scope.createSignal(bool, false);
    const clicks = try env.scope.createSignal(u32, 5);

    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        W.Button(.{ .label = "Reset", .on_click = on.set(clicks, 0) }),
        v.with(W.ScrollArea(.{ .direction = .vertical }), .{ "s1", "s2" }),
        v.with(W.Card(.{ .title = "Card" }), .{"card body"}),
        v.with(W.Popover(.{ .open = open }), .{"popover content"}).trigger(.{v.text(.{}, "trigger here")}),
        v.with(W.Modal(.{ .title = "M", .open = modal_open }), .{"modal body"}),
    }));
    try win.appendChild(testing.allocator, root);

    try testing.expect(root.children.items.len >= 4);
    try testing.expect(subtreeHasText(root.children.items[1], "s2"));
    try testing.expect(subtreeHasText(root.children.items[2], "card body"));
    // trigger content in Popover wrapper (normal tree), content in portal
    try testing.expect(subtreeHasText(root.children.items[3], "trigger here"));
}

test "失败回滚：Popover 挂载成功后 slot 内容出错，portal 里的内容与 Popover scope 一并回收" {
    // Portal content not in root subtree, txn rollback only frees root +
    // subscope dispose. Cleanup relies on Popover's scope being render subscope descendant,
    // and detach frees portal content. Verify with testing.allocator leak detection +
    // portal child count, not inference.
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const win = try core.box(env.cx, .{}, .{});
    env.cx.root = win;
    defer {
        env.scope.dispose();
        env.cx.root = null;
        env.cx.freeNode(win);
        env.cx.deinit();
    }
    const open = try env.scope.createSignal(bool, true);
    const portal_children_before = blk: {
        const p = try env.cx.ensurePopoverPortalRoot();
        break :blk p.children.items.len;
    };

    const result = v.render(env.scope, env.cx, v.col(.{}, .{
        v.with(W.Popover(.{ .open = open }), .{ "portal content", Boom{} }).trigger(.{"t"}),
    }));
    try testing.expectError(error.Boom, result);
    const portal = try env.cx.ensurePopoverPortalRoot();
    try testing.expectEqual(portal_children_before, portal.children.items.len);
    open.set(false); // Popover effect destroyed with scope; shouldn't touch freed node
    open.set(true);
}

test "v.ref：组件挂载结果与普通节点句柄；VStack / HStack / Accordion / GlassBox 经 with 接收子元素" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const St = struct {
        sa: W.ScrollAreaResult = undefined,
        glass: ?W.glass_box.GlassBoxMount = null,
        label: *Node = undefined,
    };
    const st = try env.scope.createState(St, .{});

    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.capture(&st.sa, v.with(W.ScrollArea(.{ .direction = .vertical }), .{"in scroll"})),
        v.capture(&st.label, v.text(.{}, "label")),
        v.with(W.VStack(.{ .gap = 4 }), .{ "v1", "v2" }),
        v.with(W.HStack(.{ .gap = 4 }), .{"h1"}),
        v.with(W.Accordion(.{}), .{v.with(W.AccordionItem(.{ .title = "A" }), .{"acc body"})}),
        v.capture(&st.glass, v.with(W.GlassBox(.{ .corner_radius = 18 }), .{"glass body"})),
    }));
    defer env.deinit(root);

    try testing.expectEqual(content(root, 0), st.sa.container);
    try testing.expect(subtreeHasText(st.sa.content, "in scroll"));
    try testing.expectEqualStrings("label", textOf(st.label));
    try testing.expectEqual(@as(usize, 2), contentLen(content(root, 2)));
    try testing.expectEqualStrings("h1", textOf(content(content(root, 3), 0)));
    try testing.expect(subtreeHasText(content(root, 4), "acc body"));
    const g = st.glass.?;
    try testing.expectEqual(content(root, 5), g.box);
    try testing.expect(subtreeHasText(g.body, "glass body"));
}

test "accordionItemOpen：互斥展开，写 false 只清当前项" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    defer env.deinit(null);
    const open = try env.scope.createSignal(?usize, null);
    const b0 = try reactive.resolveModel(bool, env.scope, W.accordionItemOpen(open, 0));
    const b1 = try reactive.resolveModel(bool, env.scope, W.accordionItemOpen(open, 1));

    try testing.expect(!b0.read.get() and !b1.read.get());
    _ = b1.commit(true);
    try testing.expectEqual(@as(?usize, 1), open.peek());
    try testing.expect(!b0.read.get() and b1.read.get());
    _ = b0.commit(false); // Not current: no change
    try testing.expectEqual(@as(?usize, 1), open.peek());
    _ = b1.commit(false);
    try testing.expectEqual(@as(?usize, null), open.peek());
}

fn glassOn(_: *const ThemeTokens) BoxStyle {
    return .{
        .glass = .{ .backdrop_blur = 12 },
        .multi_gradient = core.MultiGradient.fromSlice(&.{ .{ .color = Color.WHITE, .position = 0 }, .{ .color = Color.BLACK, .position = 1 } }, .diagonal),
        .composited_group = true,
    };
}

test "BoxStyle glass / multi_gradient / composited_group：写入 ext，条件撤销回到原值" {
    const env = try Env.init();
    const on_sig = try env.scope.createSignal(bool, true);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{v.when(on_sig, glassOn)} }, .{}));
    defer env.deinit(root);

    try testing.expect(root.style.glass_params() != null);
    try testing.expect(root.style.multi_gradient() != null);
    try testing.expect(root.style.composited_group());
    on_sig.set(false);
    try testing.expect(root.style.glass_params() == null);
    try testing.expect(root.style.multi_gradient() == null);
    try testing.expect(!root.style.composited_group());
}

const CellCtx = struct { label: *reactive.Signal([]const u8) };

fn tableCellView(ctx: CellCtx, row: usize, col: usize) v.Text(@TypeOf(.{}), v.Fmt("{s}:{d}.{d}", struct { *reactive.Signal([]const u8), usize, usize })) {
    return v.text(.{}, v.fmt("{s}:{d}.{d}", .{ ctx.label, row, col }));
}

test "Table.cells：视图形态单元格；响应式内容随 signal 更新，表体重建时格内 scope 一并回收" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const cols = [_]W.ColumnDef{ .{ .id = "a", .header = "A", .width = 80 }, .{ .id = "b", .header = "B", .width = 80 } };
    const rows = try env.scope.createSignal(usize, 2);
    const label = try env.scope.createSignal([]const u8, "x");
    const St = struct { table: W.table.TableResult = undefined };
    const st = try env.scope.createState(St, .{});

    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.capture(&st.table, W.Table(.{ .columns = &cols, .row_count = rows }).cells(CellCtx{ .label = label }, tableCellView)),
    }));
    defer env.deinit(root);

    try testing.expect(subtreeHasText(root, "x:1.1"));
    label.set("y");
    try testing.expect(subtreeHasText(root, "y:1.0"));
    rows.set(3); // Table rebuild: old row node freeNode, bound scope destroyed (leaks caught by allocator)
    try testing.expect(subtreeHasText(root, "y:2.1"));
    label.set("z");
    try testing.expect(subtreeHasText(root, "z:2.1"));
    try testing.expect(!subtreeHasText(root, "y:0.0"));
}

test "Table.cells：跨越虚拟化阈值后旧单元格效果回收，新表体保持响应式" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const cols = [_]W.ColumnDef{ .{ .id = "a", .header = "A", .width = 80 }, .{ .id = "b", .header = "B", .width = 80 } };
    const rows = try env.scope.createSignal(usize, 50);
    const label = try env.scope.createSignal([]const u8, "direct");
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        W.Table(.{ .columns = &cols, .row_count = rows }).cells(CellCtx{ .label = label }, tableCellView),
    }));
    defer env.deinit(root);

    // Exactly 50 rows renders the whole body directly.
    try testing.expect(subtreeHasText(root, "direct:49.1"));
    label.set("first");
    try testing.expect(subtreeHasText(root, "first:49.1"));
    try testing.expect(!subtreeHasText(root, "direct:0.0"));

    // Enter virtual mode. Updating label must only reach the new visible cells;
    // effects attached to the released direct body would access freed nodes.
    rows.set(51);
    try testing.expect(subtreeHasText(root, "first:0.0"));
    try testing.expect(!subtreeHasText(root, "first:49.1"));
    label.set("virtual");
    try testing.expect(subtreeHasText(root, "virtual:0.1"));
    try testing.expect(!subtreeHasText(root, "first:0.0"));

    // Return to the threshold: the former pooled cells must release their
    // effects too, while the complete new direct body remains subscribed.
    rows.set(50);
    try testing.expect(subtreeHasText(root, "virtual:49.1"));
    label.set("final");
    try testing.expect(subtreeHasText(root, "final:0.0"));
    try testing.expect(subtreeHasText(root, "final:49.1"));
    try testing.expect(!subtreeHasText(root, "virtual:0.1"));
}

fn gridCellView(row: usize, col: usize) v.Text(@TypeOf(.{}), v.Fmt("{d}/{d}", struct { usize, usize })) {
    return v.text(.{}, v.fmt("{d}/{d}", .{ row, col }));
}

test "Grid.cells：视图形态单元格挂进池化格" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const widths = [_]f32{ 60, 60 };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        W.Grid(.{ .row_count = 3, .col_count = 2, .col_widths = &widths, .width = 200, .height = 200 }).cells({}, gridCellView),
    }));
    defer env.deinit(root);
    try testing.expect(subtreeHasText(root, "2/1"));
}

fn labeledGridCell(ctx: CellCtx, row: usize, col: usize) v.Text(@TypeOf(.{}), v.Fmt("{s}:{d}.{d}", struct { *reactive.Signal([]const u8), usize, usize })) {
    return v.text(.{}, v.fmt("{s}:{d}.{d}", .{ ctx.label, row, col }));
}

fn labeledRow(ctx: CellCtx, row: usize) v.Text(@TypeOf(.{}), v.Fmt("{s}:{d}", struct { *reactive.Signal([]const u8), usize })) {
    return v.text(.{}, v.fmt("{s}:{d}", .{ ctx.label, row }));
}

fn liveEffects(cx: *Cx) usize {
    return cx.owner.graph.countByKind().get(.effect);
}

test "Grid.cells：释放 Grid 根（调用方 scope 仍存活）时单元格内容 scope / 绑定效果随 Grid 一并回收" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const label = try env.scope.createSignal([]const u8, "x");
    const widths = [_]f32{ 60, 60 };
    const base = liveEffects(env.cx);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        W.Grid(.{ .row_count = 3, .col_count = 2, .col_widths = &widths, .width = 200, .height = 200 }).cells(CellCtx{ .label = label }, labeledGridCell),
    }));
    defer env.deinit(root);
    try testing.expect(subtreeHasText(root, "x:2.1"));
    try testing.expect(liveEffects(env.cx) > base);

    // Grid binds its own scope to its root, so freeing the root alone must retire everything
    // the grid mounted -- including the cells' content effects.
    const grid = root.children.items[0];
    env.cx.detachChild(root, grid);
    env.cx.freeNode(grid);
    try testing.expectEqual(base, liveEffects(env.cx));
    label.set("y"); // a surviving bindText effect would write the freed text node
}

test "VirtualList.rows：释放列表容器（调用方 scope 仍存活）时行内容 scope / 绑定效果随列表一并回收" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const label = try env.scope.createSignal([]const u8, "x");
    const base = liveEffects(env.cx);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        W.VirtualList(.{ .item_count = 5, .item_height = 20, .height = 200 }).rows(CellCtx{ .label = label }, labeledRow),
    }));
    defer env.deinit(root);
    try testing.expect(subtreeHasText(root, "x:4"));
    try testing.expect(liveEffects(env.cx) > base);

    const list = root.children.items[0];
    env.cx.detachChild(root, list);
    env.cx.freeNode(list);
    try testing.expectEqual(base, liveEffects(env.cx));
    label.set("y");
}

const grid_cols = [_]core.GridTrackSize{ .{ .px = 70 }, .{ .fr = 1 } };

fn spanTwo(_: *const ThemeTokens) BoxStyle {
    return .{ .grid_placement = .{ .col_start = 1, .col_span = 2 } };
}

test "v.grid：轨道写入 GridConfig（随节点释放）；子项 grid_placement 来自样式" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.grid(.{ .columns = &grid_cols, .column_gap = 8 }, .{
        v.box(.{ .style = spanTwo }, .{}),
        "b",
    }));
    defer env.deinit(root);

    const gc = root.style.grid().?;
    try testing.expectEqual(@as(u8, 2), gc.column_count);
    try testing.expectEqual(@as(u8, 0), gc.row_count);
    try testing.expectEqual(@as(f32, 8), gc.column_gap);
    try testing.expectEqual(core.GridTrackSize{ .px = 70 }, gc.columns[0]);
    try testing.expectEqual(@as(u8, 2), content(root, 0).style.grid_placement().?.col_span);
}

test "v.portal：内容挂到 portal root、声明处不占位；scope 销毁时从 portal 摘除并回收" {
    const env = try Env.init();
    const win = try core.box(env.cx, .{}, .{});
    env.cx.root = win;
    defer {
        env.cx.root = null;
        env.cx.freeNode(win);
        env.cx.deinit();
    }
    const portal = try env.cx.ensurePopoverPortalRoot();
    const before = portal.children.items.len;
    const page = try env.scope.childScope();

    const root = try v.render(page, env.cx, v.col(.{}, .{
        "inline",
        v.portal(v.box(.{ .test_id = "overlay" }, .{"in portal"})),
    }));
    try win.appendChild(testing.allocator, root);
    try testing.expectEqual(@as(usize, 1), contentLen(root));
    try testing.expectEqual(before + 1, portal.children.items.len);
    try testing.expect(subtreeHasText(portal, "in portal"));

    // Detach contract: dispose scope first (portal content freed), then free declaration subtree
    page.dispose();
    try testing.expectEqual(before, portal.children.items.len);
    env.cx.detachChild(win, root);
    env.cx.freeNode(root);
    env.scope.dispose();
}

test "失败回滚：portal 挂上后兄弟出错，portal 里的内容一并回收" {
    const env = try Env.init();
    const win = try core.box(env.cx, .{}, .{});
    env.cx.root = win;
    defer {
        env.scope.dispose();
        env.cx.root = null;
        env.cx.freeNode(win);
        env.cx.deinit();
    }
    const portal = try env.cx.ensurePopoverPortalRoot();
    const before = portal.children.items.len;
    const result = v.render(env.scope, env.cx, v.col(.{}, .{
        v.portal(v.text(.{}, "overlay")),
        Boom{},
    }));
    try testing.expectError(error.Boom, result);
    try testing.expectEqual(before, portal.children.items.len);
}

test "v.ref：Input / Textarea 拿到编辑状态，.parts 标内部输入框" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const St = struct {
        input: W.input.InputResult = undefined,
        area: ?W.input.TextareaResult = null,
    };
    const st = try env.scope.createState(St, .{});
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.capture(&st.input, W.Input(.{ .placeholder = "name" })),
        v.attrs(.{ .parts = .{ .input = "area.input" } }, v.capture(&st.area, W.Textarea(.{ .rows = 2 }))),
    }));
    defer env.deinit(root);

    try testing.expectEqual(content(root, 0), st.input.node);
    const area = st.area.?;
    try testing.expectEqual(content(root, 1), area.wrapper);
    try testing.expectEqualStrings("area.input", area.input.meta.ownership.meta.test_id.?);
}

fn partGap(_: *const ThemeTokens) BoxStyle {
    return .{ .gap = 21 };
}

test ".parts 叠样式：写到组件部件上，条件撤销回到组件原值" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const on_sig = try env.scope.createSignal(bool, true);
    const St = struct { sa: W.ScrollAreaResult = undefined };
    const st = try env.scope.createState(St, .{});
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .parts = .{ .content = .{ .style = .{v.when(on_sig, partGap)}, .test_id = "sa.content" } } }, v.capture(&st.sa, W.ScrollArea(.{ .direction = .vertical }))),
    }));
    defer env.deinit(root);

    try testing.expectEqualStrings("sa.content", st.sa.content.meta.ownership.meta.test_id.?);
    try testing.expectEqual(@as(f32, 21), st.sa.content.style.gap);
    on_sig.set(false);
    try testing.expect(st.sa.content.style.gap != 21);
}

const CampaignState = struct {
    sa: ?@import("components/mod.zig").ScrollAreaResult = null,
    label: ?*Node = null,
};

fn campaignCell(row: usize, col: usize) v.Text(@TypeOf(.{}), v.Fmt("{d}:{d}", struct { usize, usize })) {
    return v.text(.{}, v.fmt("{d}:{d}", .{ row, col }));
}

test "allocation campaign: ui.view 挂载（portal / grid / cells / parts / ref / show）任意分配点失败都整体回收" {
    const W = @import("components/mod.zig");
    const allocator = testing.allocator;
    const cols = [_]W.ColumnDef{ .{ .id = "a", .header = "A", .width = 60 }, .{ .id = "b", .header = "B", .width = 60 } };
    var fail_index: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (!succeeded and fail_index < 4000) : (fail_index += 1) {
        const cx = try Cx.init(allocator, std.testing.io);
        cx.tokens = &theme.light;
        const win = try core.box(cx, .{}, .{});
        cx.root = win;
        const portal = try cx.ensurePopoverPortalRoot();
        const portal_before = portal.children.items.len;
        const scope = try Scope.init(allocator, null, cx.owner);
        const on_sig = try scope.createSignal(bool, true);
        const st = try scope.createState(CampaignState, .{});
        const live_node = try v.createRef(scope, *Node);
        const live_scroll = try v.createRef(scope, W.ScrollAreaResult);
        const later = try scope.createSignal(bool, false);

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        cx.allocator = failing.allocator();
        scope.allocator = failing.allocator();

        const result = v.render(scope, cx, v.col(.{}, .{
            v.box(.{ .style = v.when(later, BoxStyle{ .corner_radius = 9 }) }, .{}),
            v.portal(v.box(.{ .test_id = "overlay" }, .{"in portal"})),
            v.grid(.{ .columns = &grid_cols, .column_gap = 4 }, .{ v.box(.{ .style = spanTwo }, .{}), "g" }),
            W.Table(.{ .columns = &cols, .row_count = 2 }).cells({}, campaignCell),
            v.attrs(.{ .parts = .{ .content = .{ .style = .{v.when(on_sig, partGap)}, .test_id = "sa.content" } } }, v.capture(&st.sa, v.with(W.ScrollArea(.{ .direction = .vertical }), .{"s"}))),
            v.capture(&st.label, v.text(.{}, "label")),
            v.show(on_sig, .{ v.ref(live_node, v.text(.{}, "shown")), v.ref(live_scroll, W.ScrollArea(.{})) }),
        }));

        // Subscope built during mount cached failing allocator: later rebuilds don't inject failure
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        cx.allocator = allocator;
        scope.allocator = allocator;
        if (result) |root| {
            try win.appendChild(allocator, root);
            try testing.expectEqual(portal_before + 1, portal.children.items.len);
            // The cell callback by design swallows OOM (the cell is left empty), render still succeeds.
            // FailingAllocator fails forever; this round only verifies cleanup, doesn't trigger
            // rebuild.
            if (!induced) {
                succeeded = true;
                on_sig.set(false);
                try testing.expect(live_node.get() == null and live_scroll.get() == null);
            }
            scope.dispose();
            try testing.expectEqual(portal_before, portal.children.items.len);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expect(live_node.get() == null and live_scroll.get() == null);
            // Portal empty after rollback; future signal changes don't touch freed nodes
            try testing.expectEqual(portal_before, portal.children.items.len);
            on_sig.set(false);
            scope.dispose();
        }
        cx.root = null;
        cx.freeNode(win);
        cx.deinit();
    }
    try testing.expect(succeeded);
    try testing.expect(failures > 20);
}

test "静态条件：可选元素与 v.branch 挂载时决定，不建锚点" {
    const env = try Env.init();
    // Runtime bool: if result type is ?E (compile constants folded away)
    var yes = true;
    var no = false;
    _ = .{ &yes, &no };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        if (yes) v.text(.{}, "a") else null,
        if (no) v.text(.{}, "b") else null,
        v.branch(no, v.text(.{}, "c"), v.box(.{ .test_id = "d" }, .{})),
    }));
    defer env.deinit(root);
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqualStrings("a", textOf(root.children.items[0]));
    try testing.expectEqualStrings("d", root.children.items[1].meta.ownership.meta.test_id.?);
}

test "core.text 的内容地址在节点生命周期内稳定（a11y label / live_text 可借用；文本表扩容不搬家）" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{ v.text(.{}, "short"), v.text(.{}, "") }));
    defer env.deinit(root);
    const first = root.children.items[0];
    const borrowed = first.getText().?.content;
    // Force text table to expand multiple times
    var i: usize = 0;
    while (i < 300) : (i += 1) try v.mount(env.scope, env.cx, root, v.text(.{}, "tiny"));
    try testing.expectEqual(borrowed.ptr, first.getText().?.content.ptr);
    try testing.expectEqualStrings("short", borrowed);
}

test "view.append：scope 绑在根节点上，清空重建不累积 scope" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{}));
    defer env.deinit(root);
    const sig = try env.scope.createSignal(u32, 1);
    const base_children = env.scope.children.items.len;
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        while (root.children.items.len > 0) {
            const c = root.children.items[root.children.items.len - 1];
            env.cx.detachChild(root, c);
            env.cx.freeNode(c);
        }
        _ = try v.append(env.scope, env.cx, root, v.text(.{}, v.fmt("n={d}", .{sig})));
    }
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    // render subscope + current line's scope; old line scopes freed with nodes
    try testing.expectEqual(base_children + 1, env.scope.children.items.len);
    sig.set(7);
    try testing.expectEqualStrings("n=7", textOf(root.children.items[0]));
}

test "allocation campaign: 带 StyleExt 的图标 / grid 构造器任意分配点失败都不泄漏" {
    const icons = @import("zenit_system_icons");
    const allocator = testing.allocator;
    var fail_index: usize = 0;
    var ok = false;
    var failures: usize = 0;
    while (!ok and fail_index < 200) : (fail_index += 1) {
        const cx = try Cx.init(allocator, std.testing.io);
        defer cx.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        cx.allocator = failing.allocator();
        const icon = core.iconTintStyled(cx, icons.close, Color.WHITE, .{ .inset = .{ .top = .{ .px = 1 } }, .corner_radius = 2 });
        const grid = core.grid(cx, .{ .columns = &.{.{ .fr = 1 }}, .corner_radius = core.CornerRadius.uniform(2), .margin_spec = .{} }, .{});
        failing.fail_index = std.math.maxInt(usize);
        cx.allocator = allocator;
        if (icon) |n| cx.freeNode(n) else |_| failures += 1;
        if (grid) |n| cx.freeNode(n) else |_| failures += 1;
        if (icon != error.OutOfMemory and grid != error.OutOfMemory) ok = true;
    }
    try testing.expect(ok);
    try testing.expect(failures > 2);
}

test "失败回滚：view.mount 收到的外部组件节点连同它绑定的 scope 当场回收" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{}));
    defer env.deinit(root);
    const baseline = env.scope.children.items.len;
    // Component node mounted outside: scope is subscope of env.scope, bound to node
    const btn = try W.Button(.{ .label = "x" }).mount(env.scope, env.cx);
    try testing.expectEqual(baseline + 1, env.scope.children.items.len);
    try testing.expectError(error.Boom, v.mount(env.scope, env.cx, root, .{ btn, Boom{} }));
    try testing.expectEqual(@as(usize, 0), root.children.items.len);
    try testing.expectEqual(baseline, env.scope.children.items.len);
}

const OwnedEffect = struct {
    var runs: usize = 0;
    fn component(props: struct { src: *reactive.Signal(u32) }, scope: *Scope, cx: *Cx) anyerror!*Node {
        // Component's own effect: must destroy with root node, not outlive it
        try scope.createEffect(props.src, struct {
            fn run(src: *reactive.Signal(u32)) void {
                _ = src.get();
                runs += 1;
            }
        }.run);
        return v.render(scope, cx, v.box(.{}, .{}));
    }
};

test "v.component：组件 scope 绑在根节点上，freeNode 后组件建的 effect 不再运行" {
    const env = try Env.init();
    defer env.deinit(null);
    const src = try env.scope.createSignal(u32, 0);
    OwnedEffect.runs = 0;
    const node = try v.component(OwnedEffect.component, .{ .src = src }).mount(env.scope, env.cx);
    try testing.expectEqual(@as(usize, 1), OwnedEffect.runs);
    src.set(1);
    try testing.expectEqual(@as(usize, 2), OwnedEffect.runs);
    env.cx.freeNode(node);
    src.set(2);
    try testing.expectEqual(@as(usize, 2), OwnedEffect.runs);
}

test "v.component：作为子元素挂载时同样随节点回收" {
    const env = try Env.init();
    const src = try env.scope.createSignal(u32, 0);
    OwnedEffect.runs = 0;
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.component(OwnedEffect.component, .{ .src = src })}));
    defer env.deinit(root);
    const child = root.children.items[0];
    env.cx.detachChild(root, child);
    env.cx.freeNode(child);
    src.set(5);
    try testing.expectEqual(@as(usize, 1), OwnedEffect.runs);
}

const ReplayRecipe = @import("css.zig").cva(.{
    .base = .{ .padding = .space100 },
    .variants = .{ .tone = .{ .calm = .{ .background = .bg_secondary }, .loud = .{ .background = .accent } } },
    .defaults = .{ .tone = .calm },
});
const Tone = ReplayRecipe.Dim(.tone);

test "运行期静态的变体样式：不建 effect，换主题经 view_theme 槽重放" {
    const env = try Env.init();
    const tone = reactive.Source(Tone).of(.loud);
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = ReplayRecipe.of(.{ .tone = tone }) }, .{}),
        v.text(.{ .style = .{ .color = .accent } }, "t"),
    }));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;
    try testing.expectEqual(before, env.cx.owner.graph.countByKind().get(.effect));
    const b = root.children.items[0];
    try testing.expect(b.meta.per_frame.hooks.view_theme != null);
    try testing.expectEqual(theme.light.tokens.color.accent, b.getBackground());
    var custom = theme.light;
    custom.tokens.color.accent = core.Color.hex(0x123456);
    custom.tokens.space.space100 = 9;
    env.cx.setTheme(&custom);
    try testing.expectEqual(core.Color.hex(0x123456), b.getBackground());
    try testing.expectEqual(@as(f32, 9), b.style.padding.left);
}

test "运行期静态样式的主题重放：信号源仍走 effect" {
    const env = try Env.init();
    const tone = try env.scope.createSignal(Tone, .calm);
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = ReplayRecipe.of(.{ .tone = tone }) }, .{}));
    defer env.deinit(root);
    try testing.expectEqual(before + 1, env.cx.owner.graph.countByKind().get(.effect));
    try testing.expect(root.meta.per_frame.hooks.view_theme == null);
    tone.set(.loud);
    try testing.expectEqual(theme.light.tokens.color.accent, root.getBackground());
}

test "view_theme 槽：样式 scope 先销毁时摘掉回调，节点先释放时解除不碰已释放节点" {
    const env = try Env.init();
    defer env.deinit(null);
    const tone = reactive.Source(Tone).of(.loud);
    // Scope first: node still there, slot must clear; theme change can't call freed state
    const s1 = try env.scope.childScope();
    const n1 = try v.render(s1, env.cx, v.box(.{ .style = ReplayRecipe.of(.{ .tone = tone }) }, .{}));
    try testing.expect(n1.meta.per_frame.hooks.view_theme != null);
    s1.dispose();
    try testing.expect(n1.meta.per_frame.hooks.view_theme == null);
    env.cx.root = n1;
    env.cx.setTheme(&theme.dark);
    env.cx.root = null;
    env.cx.freeNode(n1);
    // Node first: later scope deinit detaches by gen handle, recognizes node is gone
    const s2 = try env.scope.childScope();
    const n2 = try v.render(s2, env.cx, v.box(.{ .style = ReplayRecipe.of(.{ .tone = tone }) }, .{}));
    env.cx.freeNode(n2);
    s2.dispose();
}

const render_engine = @import("core/render_engine/mod.zig");

fn pulse(phase: f32, t: *const theme.ThemeTokens) BoxStyle {
    return .{ .opacity = phase, .background = if (phase < 0.5) t.tokens.color.bg_secondary else t.tokens.color.accent };
}

/// Run v.loop before_render hook on node (called by tick phase in frame loop)
fn runFrameHooks(n: *Node) void {
    const h = &n.meta.per_frame.hooks.before_render;
    if (h.main) |f| f(n);
    for (h.hooks[0..h.count]) |f| f.?(n);
}

test "v.loop：相位取帧时钟（墙钟），每帧重算；视口外不推进" {
    const env = try Env.init();
    const saved = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = saved;
    render_engine.current_frame_time_ms = 250;
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ C.card, v.loop(.{ .period_ms = 1000 }, pulse) } }, .{}));
    defer env.deinit(root);
    try testing.expect(root.hasBeforeRenderHooks());
    try testing.expectApproxEqAbs(@as(f32, 0.25), root.getOpacity(), 0.001);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));

    render_engine.current_frame_time_ms = 2750; // Crossed two periods: phase 0.75
    runFrameHooks(root);
    try testing.expectApproxEqAbs(@as(f32, 0.75), root.getOpacity(), 0.001);
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));

    root.frame_state.state_bits.flags.out_of_viewport = true;
    render_engine.current_frame_time_ms = 3100;
    runFrameHooks(root);
    try testing.expectApproxEqAbs(@as(f32, 0.75), root.getOpacity(), 0.001);
}

test "v.loop：.on 为信号时开合——关掉摘 hook、字段回到其余层，打开重新挂" {
    const env = try Env.init();
    const saved = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = saved;
    render_engine.current_frame_time_ms = 800;
    const running = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ C.card, v.loop(.{ .period_ms = 1000, .on = running }, pulse) } }, .{}));
    defer env.deinit(root);
    try testing.expect(!root.hasBeforeRenderHooks());
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground())); // C.card background
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);

    running.set(true);
    try testing.expect(root.hasBeforeRenderHooks());
    try testing.expect(Color.eql(theme.light.tokens.color.accent, root.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 0.8), root.getOpacity(), 0.001);

    running.set(false);
    try testing.expect(!root.hasBeforeRenderHooks());
    try testing.expect(root.meta.per_frame.hooks.slots.view_loop == null);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_secondary, root.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);
}

test "v.loop：scope 先销毁时摘掉 hook；节点先释放时解除不碰已释放节点" {
    const env = try Env.init();
    defer env.deinit(null);
    const s1 = try env.scope.childScope();
    const n1 = try v.render(s1, env.cx, v.box(.{ .style = v.loop(.{ .period_ms = 1000 }, pulse) }, .{}));
    try testing.expect(n1.hasBeforeRenderHooks());
    s1.dispose();
    try testing.expect(!n1.hasBeforeRenderHooks());
    try testing.expect(n1.meta.per_frame.hooks.slots.view_loop == null);
    runFrameHooks(n1);
    env.cx.freeNode(n1);

    const s2 = try env.scope.childScope();
    const n2 = try v.render(s2, env.cx, v.box(.{ .style = v.loop(.{ .period_ms = 1000 }, pulse) }, .{}));
    env.cx.freeNode(n2);
    s2.dispose();
}

const EachItem = struct { id: u32, name: []const u8 };
fn eachRow(item: EachItem) v.Text(@TypeOf(.{}), []const u8) {
    return v.text(.{}, item.name);
}

test "v.each 静态列表：逐项挂一次，不建区域锚点与 effect" {
    const env = try Env.init();
    const items = [_]EachItem{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" } };
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.each(&items, .id, eachRow)}));
    defer env.deinit(root);
    try testing.expectEqual(before, env.cx.owner.graph.countByKind().get(.effect));
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqualStrings("b", textOf(root.children.items[1]));
}

const FadeRecipe = @import("css.zig").cva(.{
    .base = .{ .transition = @import("recipe.zig").transition("background 150ms ease-out") },
    .variants = .{ .tone = .{ .calm = .{ .background = .bg_secondary }, .loud = .{ .background = .accent } } },
    .defaults = .{ .tone = .calm },
});

test "样式里的 .transition：挂载时装到节点，挂载本身不起过渡，之后切换变体插值" {
    const env = try Env.init();
    const tone = try env.scope.createSignal(FadeRecipe.Dim(.tone), .calm);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = FadeRecipe.of(.{ .tone = tone }) }, .{}));
    defer env.deinit(root);
    const slots = root.frame_state.frame_local.runtime.transitions.?;
    const slot = slots.find(.background).?;
    try testing.expect(!slot.active);
    try testing.expectEqual(theme.light.tokens.color.bg_secondary, root.getBackground());
    tone.set(.loud);
    try testing.expect(slot.active);
    try testing.expectEqual(theme.light.tokens.color.accent, slot.to_color);
}

test "a11y 字段可以是响应式源：静态源一次写定，信号源随值更新" {
    const env = try Env.init();
    const msg = try env.scope.createText("saved", .{});
    const level = try env.scope.createSignal([]const u8, "polite");
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .a11y = .{ .role = .alert, .live = reactive.Source([]const u8).of("assertive") } }, .{}),
        v.box(.{ .a11y = .{ .role = .status, .live = level, .live_text = msg } }, .{}),
    }));
    defer env.deinit(root);
    const fixed = root.children.items[0].behavior.interaction.a11y.?;
    try testing.expectEqualStrings("assertive", fixed.live.?);
    try testing.expectEqual(before + 1, env.cx.owner.graph.countByKind().get(.effect));
    const live = root.children.items[1];
    try testing.expectEqualStrings("saved", live.behavior.interaction.a11y.?.live_text.?);
    msg.set("failed");
    level.set("assertive");
    try testing.expectEqualStrings("failed", live.behavior.interaction.a11y.?.live_text.?);
    try testing.expectEqualStrings("assertive", live.behavior.interaction.a11y.?.live.?);
    try testing.expectEqual(types.A11yRole.status, live.behavior.interaction.a11y.?.role);
}

fn itemRow(prefix: []const u8, name: []const u8, i: usize) v.Text(@TypeOf(.{}), v.Fmt("{s}{d}:{s}", struct { []const u8, usize, []const u8 })) {
    return v.text(.{}, v.fmt("{s}{d}:{s}", .{ prefix, i, name }));
}

test "v.items：运行期切片一次挂载展开，不建锚点" {
    const env = try Env.init();
    var names_buf = [_][]const u8{ "a", "b", "c" };
    const names: []const []const u8 = names_buf[0..];
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{ "head", v.items(@as([]const u8, "#"), names, itemRow) }));
    defer env.deinit(root);
    try testing.expectEqual(@as(usize, 4), root.children.items.len);
    try testing.expectEqualStrings("#2:c", textOf(root.children.items[3]));
}

test "tag / icon hit_test / v.image 属性" {
    const env = try Env.init();
    const icons = @import("zenit_system_icons");
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .tag = .button }, .{}),
        v.icon(.{ .hit_test = false }, icons.close),
        v.image(.{ .style = .{ .width = .{ .px = 8 }, .height = .{ .px = 8 } }, .tint = Color.BLACK }, 1),
    }));
    defer env.deinit(root);
    try testing.expectEqual(core.ElementTag.button, root.children.items[0].tag);
    try testing.expect(!root.children.items[1].frame_state.state_bits.flags.hit_test_visible);
    try testing.expectEqual(core.ElementTag.image, root.children.items[2].tag);
}

fn repeatCell(i: usize) v.Text(@TypeOf(.{}), v.Fmt("r{d}", struct { usize })) {
    return v.text(.{}, v.fmt("r{d}", .{i}));
}

test "v.repeat 按次数展开；attrs 收 .tag" {
    const env = try Env.init();
    var n: usize = 3;
    _ = &n;
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.repeat({}, n, repeatCell),
        v.attrs(.{ .tag = .button }, v.text(.{}, "t")),
    }));
    defer env.deinit(root);
    try testing.expectEqual(@as(usize, 4), root.children.items.len);
    try testing.expectEqualStrings("r2", textOf(root.children.items[2]));
    try testing.expectEqual(core.ElementTag.button, root.children.items[3].tag);
}

test "v.repeat：次数可为字面量 / 负数（钳到 0）/ 信号（变化时整体重建）" {
    const env = try Env.init();
    var neg: i32 = -2;
    _ = &neg;
    const count = try env.scope.createSignal(u8, 1);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.repeat({}, 2, repeatCell),
        v.repeat({}, neg, repeatCell),
        v.repeat({}, count, repeatCell),
    }));
    defer env.deinit(root);
    const texts = struct {
        fn n(node: *Node) usize {
            var k: usize = 0;
            for (node.children.items) |c| k += @intFromBool(c.getText() != null);
            return k;
        }
    }.n;
    try testing.expectEqual(@as(usize, 3), texts(root));
    count.set(4);
    try testing.expectEqual(@as(usize, 6), texts(root));
    count.set(0);
    try testing.expectEqual(@as(usize, 2), texts(root));
}

test "sva: reactive variants, hover restoration, theme replay on separate slots" {
    const css_mod = @import("css.zig");
    const env = try Env.init();
    const Size = enum { sm, lg };
    const size = try env.scope.createSignal(Size, .sm);
    const R = css_mod.sva(.{
        .slots = .{ .root, .icon },
        .base = .{ .root = .{ .background = .bg_secondary, ._hover = .{ .opacity = 0.5 } } },
        .variants = .{ .size = .{
            .sm = .{ .root = .{ .gap = .space100 }, .icon = .{ .width = 12 } },
            .lg = .{ .root = .{ .gap = .space300 }, .icon = .{ .width = 24 } },
        } },
    });
    const parts = R.of(.{ .size = size });
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = parts.root }, v.box(.{ .style = parts.icon }, .{})));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;
    try testing.expectEqual(theme.light.tokens.space.space100, root.style.gap);
    try testing.expectEqual(@as(f32, 12), root.children.items[0].style.width.px);
    size.set(.lg);
    try testing.expectEqual(theme.light.tokens.space.space300, root.style.gap);
    try testing.expectEqual(@as(f32, 24), root.children.items[0].style.width.px);
    const hover = root.behavior.events.on_hover.?;
    hover.callback(hover.context);
    try testing.expectEqual(@as(f32, 0.5), root.getOpacity());
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expectEqual(@as(f32, 1), root.getOpacity());
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, root.getBackground()));
}

test "sva: one source updates box and text slots, restores omitted fields, replays theme" {
    const R = @import("css.zig").sva(.{
        .slots = .{ .root, .label },
        .base = .{
            .root = .{ .border = .{ .width = .thin, .color = .border } },
            .label = .{ .color = .fg_secondary, .max_lines = 2 },
        },
        .variants = .{ .highlight = .{
            .false = .{},
            .true = .{
                .root = .{ .background = .accent, .border_color = .accent, ._hover = .{ .opacity = 0.5 } },
                .label = .{ .font_size = .xl, .strikethrough = true },
            },
        } },
        .compound = .{.{ .when = .{ .highlight = true }, .style = .{ .label = .{ .color = .accent } } }},
    });
    const env = try Env.init();
    const flag = try env.scope.createSignal(bool, false);
    const parts = R.of(.{ .highlight = flag });
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = parts.root }, v.text(.{ .style = parts.label }, "label")));
    defer env.deinit(root);
    const label = root.children.items[0];
    try testing.expectEqual(@as(u16, 2), label.getText().?.max_lines);
    try testing.expectEqual(theme.light.tokens.font_size.lg, label.getText().?.font_size);
    flag.set(true);
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expectEqual(@as(f32, 0.5), root.getOpacity());
    try testing.expectEqual(theme.light.tokens.font_size.xl, label.getText().?.font_size);
    try testing.expect(label.getText().?.strikethrough);
    env.cx.root = root;
    defer env.cx.root = null;
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.accent, root.getBackground()));
    try testing.expect(Color.eql(theme.dark.tokens.color.accent, label.getText().?.color));
    flag.set(false);
    try testing.expectEqual(@as(f32, 1), root.getOpacity());
    try testing.expect(Color.eql(Color.TRANSPARENT, root.getBackground()));
    try testing.expect(Color.eql(theme.dark.tokens.color.border, root.style.border.color));
    try testing.expect(Color.eql(theme.dark.tokens.color.fg_secondary, label.getText().?.color));
    try testing.expectEqual(theme.dark.tokens.font_size.lg, label.getText().?.font_size);
    try testing.expect(!label.getText().?.strikethrough);
    try testing.expectEqual(@as(u16, 2), label.getText().?.max_lines);
}

test "cva: text variants layer over defaults and remove variant-only fields" {
    const R = @import("css.zig").cva(.{
        .base = .{ .font_size = .sm },
        .variants = .{ .done = .{ .false = .{}, .true = .{ .color = .fg_tertiary, .strikethrough = true } } },
    });
    const env = try Env.init();
    const done = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.text(.{ .style = R.of(.{ .done = done }) }, "task"));
    defer env.deinit(root);
    done.set(true);
    try testing.expect(root.getText().?.strikethrough);
    done.set(false);
    try testing.expect(!root.getText().?.strikethrough);
    try testing.expectEqual(theme.light.tokens.font_size.sm, root.getText().?.font_size);
    try testing.expect(Color.eql(theme.light.tokens.color.fg_primary, root.getText().?.color));
}

test "hover style preserves user callbacks and Button hover animation subscription" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const State = struct {
        enters: usize = 0,
        leaves: usize = 0,
        fn enter(self: *@This()) void {
            self.enters += 1;
        }
        fn leave(self: *@This()) void {
            self.leaves += 1;
        }
    };
    const state = try env.scope.createState(State, .{});
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = C.hot, .on_hover = on.call(state, State.enter), .on_leave = on.call(state, State.leave) }, {}),
        v.attrs(.{ .style = css(.{ ._hover = .{ .opacity = 0.5 } }), .on_hover = on.call(state, State.enter), .on_leave = on.call(state, State.leave) }, W.Button(.{ .label = "Hover" })),
    }));
    defer env.deinit(root);
    for (root.children.items) |node| {
        node.behavior.events.on_hover.?.invoke();
        try testing.expectApproxEqAbs(@as(f32, 0.5), node.getOpacity(), 0.001);
        node.behavior.events.on_leave.?.invoke();
        try testing.expectApproxEqAbs(@as(f32, 1), node.getOpacity(), 0.001);
    }
    try testing.expectEqual(@as(usize, 2), state.enters);
    try testing.expectEqual(@as(usize, 2), state.leaves);
}

test "live ref clears on show unmount and rollback including component result" {
    const W = @import("components/mod.zig");
    const env = try Env.init();
    const visible = try env.scope.createSignal(bool, true);
    const label = try v.createRef(env.scope, *Node);
    const scroll = try v.createRef(env.scope, W.ScrollAreaResult);
    const root = try v.render(env.scope, env.cx, v.col(.{}, v.show(visible, .{
        v.ref(label, v.text(.{}, "tracked")),
        v.ref(scroll, W.ScrollArea(.{})),
    })));
    defer env.deinit(root);
    try testing.expect(label.get() != null and scroll.get() != null);
    visible.set(false);
    try testing.expect(label.get() == null and scroll.get() == null);
    visible.set(true);
    try testing.expectEqualStrings("tracked", textOf(label.get().?));
    const failed = v.render(env.scope, env.cx, v.col(.{}, .{ v.ref(label, v.text(.{}, "failed")), Boom{} }));
    try testing.expectError(error.Boom, failed);
    try testing.expect(label.get() == null);
}

test "old ref cleanup cannot clear a later binding and keyed removal clears its ref" {
    const env = try Env.init();
    const a = try env.scope.createSignal(bool, true);
    const b = try env.scope.createSignal(bool, false);
    const handle = try v.createRef(env.scope, *Node);
    const Row = struct {
        id: u32,
        ref: *v.Ref(*Node),
        fn render(item: @This(), scope: *Scope, cx: *Cx) !*Node {
            return v.render(scope, cx, v.ref(item.ref, v.text(.{}, "row")));
        }
    };
    const row_ref = try v.createRef(env.scope, *Node);
    const rows = try env.scope.createList(Row, &.{.{ .id = 1, .ref = row_ref }});
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.show(a, v.ref(handle, v.text(.{}, "a"))),
        v.show(b, v.ref(handle, v.text(.{}, "b"))),
        v.each(rows, .id, Row.render),
    }));
    defer env.deinit(root);
    b.set(true);
    a.set(false);
    try testing.expectEqualStrings("b", textOf(handle.get().?));
    b.set(false);
    try testing.expect(handle.get() == null);
    try testing.expect(row_ref.get() != null);
    rows.set(&.{});
    try testing.expect(row_ref.get() == null);
}

test "style: bool when is static; nested hover still subscribes" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.row(.{}, .{
        v.box(.{ .style = v.when(true, BoxStyle{ .gap = 8 }) }, .{}),
        v.box(.{ .style = v.when(false, BoxStyle{ .gap = 9 }) }, .{}),
    }));
    defer env.deinit(root);
    try testing.expectEqual(@as(usize, 0), env.scope.children.items[0].effects.items.len);
    try testing.expectEqual(@as(f32, 8), root.children.items[0].style.gap);
    try testing.expectEqual(@as(f32, 0), root.children.items[1].style.gap);
    const hovered = try v.render(env.scope, env.cx, v.box(.{ .style = v.when(true, v.hover(BoxStyle{ .gap = 4 })) }, .{}));
    defer env.cx.freeNode(hovered);
    hovered.behavior.events.on_hover.?.invoke();
    try testing.expectEqual(@as(f32, 4), hovered.style.gap);
}

test "style: inactive branches and variants reserve ext before updates" {
    const env = try Env.init();
    const enabled = try env.scope.createSignal(bool, false);
    const css_mod = @import("css.zig");
    const R = css_mod.cva(.{ .variants = .{ .enabled = .{
        .true = .{ .corner_radius = 12 },
        .false = .{},
    } } });
    const Slots = css_mod.sva(.{ .slots = .{.root}, .variants = .{ .enabled = .{
        .true = .{ .root = .{ .scale_x = 2 } },
        .false = .{},
    } } });
    const Geometry = struct {
        fn derive(args: anytype, _: *const ThemeTokens) struct { root: BoxStyle } {
            return .{ .root = if (args.enabled) .{ .scale_y = 3 } else .{} };
        }
    };
    const Derived = css_mod.sva(.{ .slots = .{.root}, .variants = .{ .enabled = .{ .true = .{}, .false = .{} } }, .derived = Geometry.derive });
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = v.when(enabled, BoxStyle{ .corner_radius = 8 }) }, .{}),
        v.box(.{ .style = css_mod.css(.{ ._hover = .{ .corner_radius = 9 } }) }, .{}),
        v.box(.{ .style = R.of(.{ .enabled = enabled }) }, .{}),
        v.box(.{ .style = Slots.of(.{ .enabled = enabled }).root }, .{}),
        v.box(.{ .style = Derived.of(.{ .enabled = enabled }).root }, .{}),
        v.box(.{ .style = v.when(enabled, BoxStyle{ .gap = 5 }) }, .{}),
    }));
    defer env.deinit(root);
    for (root.children.items[0..5]) |n| try testing.expect(n.style.ext != null);
    try testing.expect(root.children.items[5].style.ext == null);
    const ext = root.children.items[0].style.ext.?;
    enabled.set(true);
    try testing.expectEqual(ext, root.children.items[0].style.ext.?);
    try testing.expectEqual(@as(f32, 8), ext.corner_radius.?.all);
    try testing.expectEqual(@as(f32, 12), root.children.items[2].style.ext.?.corner_radius.?.all);
    try testing.expectEqual(@as(f32, 2), root.children.items[3].style.ext.?.scale_x);
    try testing.expectEqual(@as(f32, 3), root.children.items[4].style.ext.?.scale_y);
}

test "style: repeated NaN is stable and paint changes do not dirty layout" {
    const env = try Env.init();
    const tick = try env.scope.createSignal(u32, 0);
    const F = struct {
        fn style(_: u32, _: *const ThemeTokens) BoxStyle {
            return .{ .width = .{ .px = std.math.nan(f32) }, .padding = core.Padding.all(std.math.nan(f32)) };
        }
    };
    const on_flag = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = v.styleBy(tick, F.style) }, .{}),
        v.box(.{ .style = v.when(on_flag, BoxStyle{ .background = Color.hex(0x123456) }) }, .{}),
        v.box(.{ .style = v.when(on_flag, BoxStyle{ .opacity = 0.5 }) }, .{}),
        v.box(.{ .style = v.when(on_flag, BoxStyle{ .width = .{ .px = 80 } }) }, .{}),
    }));
    defer env.deinit(root);
    for (root.children.items) |n| n.frame_state.state_bits.dirty = std.mem.zeroes(@TypeOf(n.frame_state.state_bits.dirty));
    root.frame_state.state_bits.dirty = std.mem.zeroes(@TypeOf(root.frame_state.state_bits.dirty));
    const nan_node = root.children.items[0];
    const before = nan_node.meta.per_frame.caches.versions;
    tick.set(1);
    try testing.expectEqual(before, nan_node.meta.per_frame.caches.versions);
    try testing.expect(!nan_node.frame_state.state_bits.dirty.core.layout);
    try testing.expect(!nan_node.frame_state.state_bits.dirty.core.render);
    on_flag.set(true);
    try testing.expect(!root.children.items[1].frame_state.state_bits.dirty.core.layout);
    try testing.expect(root.children.items[1].frame_state.state_bits.dirty.core.render);
    try testing.expect(!root.children.items[2].frame_state.state_bits.dirty.core.layout);
    try testing.expect(root.children.items[2].frame_state.state_bits.dirty.pipeline.composite);
    try testing.expect(root.children.items[3].frame_state.state_bits.dirty.core.layout);
    try testing.expect(root.frame_state.state_bits.dirty.core.layout);
    for (root.children.items) |n| n.frame_state.state_bits.dirty = std.mem.zeroes(@TypeOf(n.frame_state.state_bits.dirty));
    on_flag.set(false);
    try testing.expect(!root.children.items[1].frame_state.state_bits.dirty.core.layout);
    try testing.expect(!root.children.items[2].frame_state.state_bits.dirty.core.layout);
    try testing.expectEqual(@as(f32, 1), root.children.items[2].getOpacity());
}

test "style: mixed layout and transform clears cached commands; z order avoids layout" {
    const env = try Env.init();
    const active = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = v.when(active, BoxStyle{ .width = .{ .px = 90 }, .scale_x = 2 }) }, .{}),
        v.box(.{ .style = v.when(active, BoxStyle{ .z_index = 4 }) }, .{}),
    }));
    defer env.deinit(root);
    const mixed = root.children.items[0];
    mixed.meta.per_frame.caches.commands.own = .{
        .commands = &.{},
        .scroll_offset_x = 0,
        .scroll_offset_y = 0,
        .allocator = testing.allocator,
    };
    const ordered = root.children.items[1];
    ordered.frame_state.state_bits.dirty = std.mem.zeroes(@TypeOf(ordered.frame_state.state_bits.dirty));
    active.set(true);
    try testing.expect(mixed.meta.per_frame.caches.commands.own == null);
    try testing.expect(!ordered.frame_state.state_bits.dirty.core.layout);
    try testing.expect(ordered.frame_state.state_bits.dirty.pipeline.order);
    try testing.expect(ordered.frame_state.state_bits.dirty.pipeline.composite);
    try testing.expect(ordered.frame_state.state_bits.dirty.hit.geometry);
}

const CanvasRec = struct {
    var draws: usize = 0;
    var last_value: u32 = 0;
    var last_now: f64 = 0;
    fn draw(_: core.DrawContext, value: u32, frame: v.Frame) anyerror!void {
        draws += 1;
        last_value = value;
        last_now = frame.now_ms;
    }
};

test "v.canvas：数据源变化时标脏并以新值绘制；animate 开合挂 / 摘帧 hook；scope 先走时摘掉自绘回调" {
    const env = try Env.init();
    defer env.deinit(null);
    const value = try env.scope.createSignal(u32, 7);
    const anim = try env.scope.createSignal(bool, false);
    const s1 = try env.scope.childScope();
    const n = try v.render(s1, env.cx, v.canvas(.{ .style = .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } } }, v.paint(.{ .data = value, .animate = anim }, CanvasRec.draw)));
    const d = n.meta.per_frame.custom_hooks.draw.?;
    try d.callback(undefined, d.context);
    try testing.expectEqual(@as(u32, 7), CanvasRec.last_value);
    value.set(9);
    try d.callback(undefined, d.context);
    try testing.expectEqual(@as(u32, 9), CanvasRec.last_value);

    try testing.expect(!n.hasBeforeRenderHooks());
    anim.set(true);
    try testing.expect(n.hasBeforeRenderHooks());
    anim.set(false);
    try testing.expect(!n.hasBeforeRenderHooks());
    anim.set(true);

    s1.dispose();
    try testing.expect(n.meta.per_frame.custom_hooks.draw == null);
    try testing.expect(!n.hasBeforeRenderHooks());
    env.cx.freeNode(n);

    // Node freed first: detach on deinit doesn't touch freed node
    const s2 = try env.scope.childScope();
    const n2 = try v.render(s2, env.cx, v.canvas(.{}, v.paint(.{ .data = @as(u32, 1), .animate = true }, CanvasRec.draw)));
    env.cx.freeNode(n2);
    s2.dispose();
}

test "v.canvas：帧时间取请求重绘那一帧 tick 时的时钟，而不是绘制时的全局时钟" {
    const env = try Env.init();
    defer env.deinit(null);
    const saved = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = saved;
    render_engine.current_frame_time_ms = 100;
    const n = try v.render(env.scope, env.cx, v.canvas(.{}, v.paint(.{ .data = @as(u32, 1), .animate = true }, CanvasRec.draw)));
    defer env.cx.freeNode(n);
    render_engine.current_frame_time_ms = 500;
    runFrameHooks(n);
    render_engine.current_frame_time_ms = 0; // Other window bound to global clock
    const d = n.meta.per_frame.custom_hooks.draw.?;
    try d.callback(undefined, d.context);
    try testing.expectEqual(@as(f64, 500), CanvasRec.last_now);
}

const PressStyle = struct {
    const btn = css(.{ .background = .bg_secondary, ._hover = .{ .background = .bg_hover }, ._active = .{ .background = .accent } });
};

fn pressAt(cx: *Cx, node: ?*Node) void {
    cx.pressed_node = node;
    cx.notifyPressWatchers();
}

test "css _active：按下且指针仍在节点内才叠加；拖出取消、拖回恢复、松开回到悬停 / 常态" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = PressStyle.btn }, .{v.box(.{}, .{})}));
    defer env.deinit(root);
    const child = root.children.items[0];
    const enter = root.behavior.events.on_hover.?;
    const leave = root.behavior.events.on_leave.?;
    const t = theme.light.tokens.color;

    pressAt(env.cx, child); // Press down on child, but pointer not in bounds (not yet hovering)
    try testing.expect(Color.eql(t.bg_secondary, root.getBackground()));
    enter.callback(enter.context);
    try testing.expect(Color.eql(t.accent, root.getBackground()));
    leave.callback(leave.context); // Drag out while held
    try testing.expect(Color.eql(t.bg_secondary, root.getBackground()));
    enter.callback(enter.context); // Drag back
    try testing.expect(Color.eql(t.accent, root.getBackground()));
    pressAt(env.cx, null); // Release
    try testing.expect(Color.eql(t.bg_hover, root.getBackground()));
    leave.callback(leave.context);
    try testing.expect(Color.eql(t.bg_secondary, root.getBackground()));
    try testing.expectEqual(@as(usize, 1), env.cx.press_watchers.items.len);
}

test "usePressed：按下别处的节点不算；scope 销毁时注销观察者" {
    const env = try Env.init();
    defer env.deinit(null);
    const s1 = try env.scope.childScope();
    const a = try v.render(s1, env.cx, v.box(.{ .style = PressStyle.btn }, .{}));
    defer env.cx.freeNode(a);
    const other = try v.render(env.scope, env.cx, v.box(.{}, .{}));
    defer env.cx.freeNode(other);
    const enter = a.behavior.events.on_hover.?;
    enter.callback(enter.context);
    pressAt(env.cx, other);
    try testing.expect(Color.eql(theme.light.tokens.color.bg_hover, a.getBackground()));
    pressAt(env.cx, null);
    s1.dispose();
    try testing.expectEqual(@as(usize, 0), env.cx.press_watchers.items.len);
    pressAt(env.cx, other); // Unregistered: no longer writes freed signal
    pressAt(env.cx, null);
}

test "css _active：真实鼠标事件（移动 → 按下 → 松开）驱动按下高亮" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } } }, .{
        v.box(.{ .style = .{ PressStyle.btn, BoxStyle{ .width = .{ .px = 80 }, .height = .{ .px = 40 } } } }, .{}),
    }));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;
    env.cx.setViewport(200, 100);
    env.cx.layout();
    const btn = root.children.items[0];
    const t = theme.light.tokens.color;
    env.cx.handleMouseMove(20, 20);
    try testing.expect(Color.eql(t.bg_hover, btn.getBackground()));
    env.cx.handleMouseDown(20, 20, .{});
    try testing.expect(Color.eql(t.accent, btn.getBackground()));
    env.cx.handleMouseUp(20, 20);
    try testing.expect(Color.eql(t.bg_hover, btn.getBackground()));
}

test "notifyPressWatchers：信号触发的 effect 在遍历之后才跑（不会看到一半观察者已更新的中间态）" {
    const env = try Env.init();
    defer env.deinit(null);
    const outer = try v.render(env.scope, env.cx, v.box(.{ .style = PressStyle.btn }, .{v.box(.{ .style = PressStyle.btn }, .{})}));
    defer env.cx.freeNode(outer);
    try testing.expectEqual(@as(usize, 2), env.cx.press_watchers.items.len);
    const Watch = struct {
        cx: *Cx,
        torn: bool = false,
        runs: usize = 0,
        fn run(self: *@This()) void {
            const a = self.cx.press_watchers.items[0].signal.get();
            const b = self.cx.press_watchers.items[1].signal.get();
            self.runs += 1;
            if (a != b) self.torn = true;
        }
    };
    var w: Watch = .{ .cx = env.cx };
    try env.scope.createEffect(&w, Watch.run);
    pressAt(env.cx, outer.children.items[0]); // Falls in both subtrees: both signals become true
    pressAt(env.cx, null);
    try testing.expect(!w.torn);
    try testing.expectEqual(@as(usize, 3), w.runs);
}

const StatesLook = struct {
    fn look(loud: bool, t: *const ThemeTokens) @import("recipe.zig").ConditionalStyle {
        return .{
            .base = .{ .background = if (loud) t.tokens.color.danger else t.tokens.color.bg_secondary },
            .hover = .{ .background = t.tokens.color.bg_hover },
            .active = .{ .background = t.tokens.color.accent },
        };
    }
    fn plain(_: bool, t: *const ThemeTokens) @import("recipe.zig").ConditionalStyle {
        return .{ .base = .{ .background = t.tokens.color.bg_secondary } };
    }
};

test "v.statesBy：运行期条件样式按悬停 / 按下叠加，源变化时重算，换主题跟随；静态且无条件层时零成本" {
    const env = try Env.init();
    const loud = try env.scope.createSignal(bool, false);
    const before = env.cx.owner.graph.countByKind().get(.effect);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{ .style = v.statesBy(loud, StatesLook.look) }, .{}),
        v.box(.{ .style = v.statesBy(reactive.Source(bool).of(false), StatesLook.plain) }, .{}),
    }));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;
    const a = root.children.items[0];
    const b = root.children.items[1];
    try testing.expectEqual(before + 1, env.cx.owner.graph.countByKind().get(.effect));
    try testing.expect(b.behavior.events.on_hover == null);
    const t = theme.light.tokens.color;
    try testing.expect(Color.eql(t.bg_secondary, a.getBackground()));
    const enter = a.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expect(Color.eql(t.bg_hover, a.getBackground()));
    pressAt(env.cx, a);
    try testing.expect(Color.eql(t.accent, a.getBackground()));
    pressAt(env.cx, null);
    const leave = a.behavior.events.on_leave.?;
    leave.callback(leave.context);
    loud.set(true);
    try testing.expect(Color.eql(t.danger, a.getBackground()));
    env.cx.setTheme(&theme.dark);
    try testing.expect(Color.eql(theme.dark.tokens.color.danger, a.getBackground()));
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, b.getBackground()));
}

const MediaTint = struct {
    fn tint(lit: bool, t: *const ThemeTokens) Color {
        return if (lit) t.tokens.color.accent else t.tokens.color.fg_primary;
    }
};

test "v.icon / v.image：资源可为源（挂载时取值），纹理图像同样支持 tintBy" {
    const env = try Env.init();
    const svg = @import("svg_assets.zig");
    const Asset = svg.Asset;
    const lit = try env.scope.createSignal(bool, false);
    const asset = reactive.Source(?Asset).of(svg.common.star);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.icon(.{}, asset),
        v.image(.{ .tint = v.tintBy(lit, MediaTint.tint) }, reactive.Source(u32).of(7)),
    }));
    defer env.deinit(root);
    const img = root.children.items[1];
    try testing.expect(Color.eql(theme.light.tokens.color.fg_primary, img.getImage().?.tint));
    lit.set(true);
    try testing.expect(Color.eql(theme.light.tokens.color.accent, img.getImage().?.tint));
    try testing.expectError(error.ViewMediaNoResource, v.render(env.scope, env.cx, v.col(.{}, .{v.icon(.{}, reactive.Source(?Asset).of(null))})));
}

test "v.icon：src 是会变的源时跟随（资源变化重建图标节点，变成 null 时不显示）" {
    const env = try Env.init();
    const svg = @import("svg_assets.zig");
    const Asset = svg.Asset;
    const asset = try env.scope.createSignal(?Asset, svg.common.star);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.icon(.{ .test_id = "ic" }, asset)}));
    defer env.deinit(root);
    const first = findIcon(root) orelse return error.TestUnexpectedResult;
    asset.set(svg.common.check);
    const second = findIcon(root) orelse return error.TestUnexpectedResult;
    try testing.expect(first != second); // New resource, new node
    asset.set(null);
    try testing.expect(findIcon(root) == null);
}

fn findIcon(n: *Node) ?*Node {
    if (n.meta.ownership.meta.test_id) |t| if (std.mem.eql(u8, t, "ic")) return n;
    for (n.children.items) |c| if (findIcon(c)) |r| return r;
    return null;
}

fn indexedRow(item: EachItem, index: reactive.Source(usize), scope: *Scope, cx: *Cx) anyerror!*Node {
    return v.render(scope, cx, v.text(.{}, v.fmt("{d}:{s}", .{ index, item.name })));
}

test "v.each：行收到下标源，重排后被复用的行跟随新位置（节点不重建）" {
    const env = try Env.init();
    const a = [_]EachItem{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" }, .{ .id = 3, .name = "c" } };
    const b = [_]EachItem{ .{ .id = 3, .name = "c" }, .{ .id = 1, .name = "a" } };
    const list = try env.scope.createSignal([]const EachItem, &a);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.each(list, .id, indexedRow)}));
    defer env.deinit(root);
    try testing.expectEqualStrings("0:a", textOf(content(root, 0)));
    try testing.expectEqualStrings("2:c", textOf(content(root, 2)));
    const node_c = content(root, 2);
    list.set(&b);
    try testing.expectEqual(node_c, content(root, 0)); // Reuse, no rebuild
    try testing.expectEqualStrings("0:c", textOf(content(root, 0)));
    try testing.expectEqualStrings("1:a", textOf(content(root, 1)));
}

test "宿主 on_event / event_context 为信号时一起跟随（不会出现新回调 + 旧上下文）" {
    const env = try Env.init();
    const Ev = struct {
        fn a(_: @import("events.zig").Event, _: ?*anyopaque) @import("events.zig").EventResult {
            return .handled;
        }
    };
    var c1: u8 = 1;
    var c2: u8 = 2;
    const cb = try env.scope.createSignal(?core.GenericEventCallback, Ev.a);
    const ctx = try env.scope.createSignal(?*anyopaque, @ptrCast(&c1));
    const root = try v.render(env.scope, env.cx, v.box(.{ .on_event = cb, .event_context = ctx }, .{}));
    defer env.deinit(root);
    try testing.expect(root.behavior.events.event_context.? == @as(*anyopaque, @ptrCast(&c1)));
    ctx.set(@ptrCast(&c2));
    try testing.expect(root.behavior.events.event_context.? == @as(*anyopaque, @ptrCast(&c2)));
    cb.set(null);
    try testing.expect(root.behavior.events.on_event == null);
}

const ThemedLayer = struct {
    /// Only dark theme has hover layer
    fn look(_: bool, t: *const ThemeTokens) @import("recipe.zig").ConditionalStyle {
        return .{
            .base = .{ .background = t.tokens.color.bg_secondary },
            .hover = if (t.scheme == .dark) .{ .background = t.tokens.color.accent } else null,
        };
    }
};

test "v.statesBy：条件层随主题出现时补建悬停信号（静态路径升级为响应式）" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = v.statesBy(reactive.Source(bool).of(false), ThemedLayer.look) }, .{}));
    defer env.deinit(root);
    env.cx.root = root;
    defer env.cx.root = null;
    try testing.expect(root.behavior.events.on_hover == null); // Light has no hover layer: zero cost
    env.cx.setTheme(&theme.dark);
    const enter = root.behavior.events.on_hover orelse return error.TestExpectedHoverHook;
    enter.callback(enter.context);
    try testing.expect(Color.eql(theme.dark.tokens.color.accent, root.getBackground()));
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expect(Color.eql(theme.dark.tokens.color.bg_secondary, root.getBackground()));
}

test "宿主 on_event 跟随源时让给后写者：调用方挂载后改写过节点上的回调，源再变也不覆盖" {
    const env = try Env.init();
    const Ev = struct {
        fn a(_: @import("events.zig").Event, _: ?*anyopaque) @import("events.zig").EventResult {
            return .handled;
        }
        fn b(_: @import("events.zig").Event, _: ?*anyopaque) @import("events.zig").EventResult {
            return .ignored;
        }
    };
    const cb = try env.scope.createSignal(?core.GenericEventCallback, Ev.a);
    const root = try v.render(env.scope, env.cx, v.box(.{ .on_event = cb }, .{}));
    defer env.deinit(root);
    root.behavior.events.on_event = Ev.b; // Caller overwrites directly
    cb.set(null);
    try testing.expect(root.behavior.events.on_event.? == Ev.b);
    // Once yielded, stays yielded: caller wrote same value source wrote; source changes don't
    // retake
    root.behavior.events.on_event = Ev.a;
    cb.set(Ev.b);
    try testing.expect(root.behavior.events.on_event.? == Ev.a);
}

test "样式层叠：组件根元素自己的悬停样式压不过调用方叠加；叠加撤销后回落到元素自己的值" {
    const env = try Env.init();
    const over = try env.scope.createSignal(bool, true);
    // Component root is hover-styled element (element layer); caller overlays background (overlay
    // layer, conditional retractable)
    const Comp = struct {
        pub fn mount(_: @This(), scope: *Scope, cx: *Cx) !*Node {
            return v.render(scope, cx, v.box(.{ .style = .{ BoxStyle{ .background = Color.hex(0x111111), .gap = 3 }, v.hover(BoxStyle{ .background = Color.hex(0x222222), .opacity = 0.5 }) } }, .{}));
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .style = v.when(over, BoxStyle{ .background = Color.hex(0xFF0000) }) }, Comp{}),
    }));
    defer env.deinit(root);
    const n = root.children.items[0];
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    // Hover: element layer changes background to 0x222222, but overlay on top—background still
    // overlay red;
    // element opacity works.
    const enter = n.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 0.5), n.getOpacity(), 0.001);
    // Retract overlay: revert to element current value (0x222222 while hovering), not mount
    // snapshot
    over.set(false);
    try testing.expect(Color.eql(Color.hex(0x222222), n.getBackground()));
    const leave = n.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expect(Color.eql(Color.hex(0x111111), n.getBackground()));
    try testing.expectApproxEqAbs(@as(f32, 1), n.getOpacity(), 0.001);
    try testing.expectEqual(@as(f32, 3), n.style.gap);
    // Overlay again
    over.set(true);
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
}

test "样式层叠：运行期样式不再按值保存完整的 BoxStyle（每层只存声明了的字段）" {
    // BoxRuntime state has only sparse declaration, not 1120-byte last / mount snapshot
    try testing.expect(@sizeOf(@import("view.zig").StyleLayerForTest) < 128);
}

test "样式层叠：Show 关闭释放带运行期样式的元素（层在节点释放过程中摘下自己，宿主销毁时不碰已释放的层）" {
    const env = try Env.init();
    const shown = try env.scope.createSignal(bool, true);
    const over = try env.scope.createSignal(bool, true);
    const Comp = struct {
        pub fn mount(_: @This(), scope: *Scope, cx: *Cx) !*Node {
            return v.render(scope, cx, v.box(.{ .style = .{ BoxStyle{ .gap = 2 }, v.hover(BoxStyle{ .opacity = 0.5 }) } }, .{}));
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.show(shown, v.attrs(.{ .style = v.when(over, BoxStyle{ .gap = 9 }) }, Comp{})),
    }));
    defer env.deinit(root);
    for (0..3) |_| {
        shown.set(false);
        shown.set(true);
    }
    over.set(false);
    shown.set(false);
}

test "组件内联层：组件后来的命令式写入进内联层——叠加仍在上；叠加撤销回落到组件最新的值而不是挂载快照" {
    const env = try Env.init();
    const over = try env.scope.createSignal(bool, true);
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            return core.box(cx, .{ .background = Color.hex(0x101010), .gap = 4 }, .{});
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .style = v.when(over, BoxStyle{ .background = Color.hex(0xFF0000) }) }, Comp{}),
    }));
    defer env.deinit(root);
    const n = root.children.items[0];
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    // After component (e.g., hover) changes own background: overlay on top, unchanged
    n.setBackground(Color.hex(0x303030));
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    // Retract: revert to component latest write (not 0x101010 at mount)
    over.set(false);
    try testing.expect(Color.eql(Color.hex(0x303030), n.getBackground()));
    // Unmanaged: component writes take effect directly
    n.setBackground(Color.hex(0x404040));
    try testing.expect(Color.eql(Color.hex(0x404040), n.getBackground()));
    over.set(true);
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    over.set(false);
    try testing.expect(Color.eql(Color.hex(0x404040), n.getBackground()));
}

test "组件内联层：压过元素自己的悬停样式；setStyleInline 在没有宿主的节点上直接写" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ BoxStyle{ .gap = 1 }, v.hover(BoxStyle{ .opacity = 0.5, .gap = 6 }) } }, .{}));
    defer env.deinit(root);
    root.setOpacity(0.8); // Component inline
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expectApproxEqAbs(@as(f32, 0.8), root.getOpacity(), 0.001); // Inline overrides element hover opacity
    try testing.expectEqual(@as(f32, 6), root.style.gap); // Element other fields normal
    root.setStyleInline(env.cx.allocator, .{ .gap = 9 });
    try testing.expectEqual(@as(f32, 9), root.style.gap);
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expectEqual(@as(f32, 9), root.style.gap);

    const plain = try core.box(env.cx, .{ .gap = 2 }, .{});
    defer env.cx.freeNode(plain);
    plain.setStyleInline(env.cx.allocator, .{ .gap = 5, .background = Color.hex(0x123456) });
    try testing.expectEqual(@as(f32, 5), plain.style.gap);
    try testing.expect(Color.eql(Color.hex(0x123456), plain.getBackground()));
}

// Reference-checked OOM sweep over the style runtime's mount paths (components/oom_sweep.zig): an
// element styled through the effect's first run (state source, a pinned hover, transitions), a
// loop style (author + animation layers recalculated together) and a static caller overlay on a
// layered component root. A mount that reports success must
// look exactly like the uninjected one; `check` pins the states the reference was given.
test "view 样式运行时：mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("components/oom_sweep.zig");
    try sw.sweepMountVerified("view(style runtime)", struct {
        const red = Color.rgba(200, 0, 0, 255);
        const blue = Color.rgba(0, 0, 200, 255);
        const disabled_style = css(.{
            .background = Color.rgba(10, 10, 10, 255),
            .corner_radius = 6,
            .padding = 4,
            .transition = @import("recipe.zig").transition("background 150ms ease-out, opacity 150ms ease-out"),
            ._disabled = .{ .background = red, .shadow = types.Shadow{ .blur = 3, .color = blue } },
        });
        const hover_style = css(.{
            .background = Color.rgba(10, 10, 10, 255),
            .transition = @import("recipe.zig").transition("border-color 150ms ease-out"),
            ._hover = .{ .border_width = 2 },
            ._invalid = .{ .border_color = blue },
        });
        const plain = css(.{ .background = Color.rgba(10, 10, 10, 255), .transition = @import("recipe.zig").transition("opacity 150ms ease-out") });
        fn loopStyle(phase: f32, _: *const ThemeTokens) BoxStyle {
            return .{ .opacity = 0.5 + phase / 4, .corner_radius = 3 };
        }
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const disabled = try scope.createSignal(bool, true);
            const invalid = try scope.createSignal(bool, true);
            return try v.render(scope, cx, v.col(.{}, .{
                v.box(.{ .style = disabled_style, .state = .{ .disabled = disabled } }, .{}),
                v.box(.{ .style = hover_style, .state = .{ .hover = true, .invalid = invalid } }, .{}),
                v.box(.{ .style = .{ plain, v.loop(.{ .period_ms = 1000 }, loopStyle) } }, .{}),
                // static caller overlay on a component root that already has style layers
                v.attrs(.{ .style = BoxStyle{ .width = .{ .px = 77 }, .padding = core.Padding.all(3) } }, v.with(@import("components/control_shell/mod.zig").ControlShell(.{ .variant = .field }), .{}).slots(.{ .content = v.text(.{}, "x") })),
            }));
        }
    }.m, struct {
        fn check(root: *Node) anyerror!void {
            // states present at mount resolved by the effect's first run, without a transition
            const a = root.children.items[0];
            try testing.expect(Color.eql(Color.rgba(200, 0, 0, 255), a.getBackground()));
            try testing.expect(a.style.shadow() != null);
            try testing.expectApproxEqAbs(@as(f32, 6), a.style.effectiveRadii()[0], 0.001);
            try testing.expect(!a.frame_state.frame_local.runtime.transitions.?.any_active);
            const b = root.children.items[1];
            try testing.expectEqual(@as(f32, 2), b.style.border.width);
            try testing.expect(Color.eql(Color.rgba(0, 0, 200, 255), b.style.border.color));
            try testing.expect(b.frame_state.frame_local.runtime.transitions.?.find(.border_color) != null);
            // loop: author and animation layers both landed
            const c = root.children.items[2];
            try testing.expect(c.hasBeforeRenderHooks());
            try testing.expectApproxEqAbs(@as(f32, 3), c.style.effectiveRadii()[0], 0.001);
            try testing.expect(Color.eql(Color.rgba(10, 10, 10, 255), c.getBackground()));
            const d = root.children.items[3];
            try testing.expectEqual(core.Sizing{ .px = 77 }, d.style.width);
            try testing.expectEqual(core.Padding.all(3), d.style.padding);
        }
    }.check);
}

test "setStyleInlineFallible：任意分配点失败时报错且节点不变（有宿主 / 无宿主），成功时完整生效" {
    const want = BoxStyle{ .corner_radii = .{ .each = .{ 8, 0, 0, 8 } }, .border_right_color = Color.TRANSPARENT, .margin = .{ .left = -1 } };
    for ([_]bool{ true, false }) |hosted| {
        var failure_index: usize = 0;
        var failures: usize = 0;
        while (true) : (failure_index += 1) {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            const cx = try Cx.init(failing.allocator(), std.testing.io);
            defer cx.deinit();
            cx.tokens = &theme.light;
            const scope = try Scope.init(failing.allocator(), null, cx.owner);
            defer scope.dispose();
            const node = if (hosted)
                try v.render(scope, cx, v.box(.{ .style = .{ BoxStyle{ .gap = 1, .padding = types.Padding.all(2) }, v.hover(BoxStyle{ .opacity = 0.5 }) } }, .{}))
            else
                try core.box(cx, .{ .gap = 1, .padding = types.Padding.all(2) }, .{});
            defer cx.freeNode(node);
            try testing.expectEqual(hosted, node.meta.per_frame.hooks.style_host != null);
            const had_ext = node.style.ext != null;
            failing.fail_index = failing.alloc_index + failure_index;
            const result = node.setStyleInlineFallible(cx.allocator, want);
            failing.fail_index = std.math.maxInt(usize);
            if (result) |_| {
                try testing.expectEqual(@as(f32, 0), node.style.effectiveRadii()[1]);
                try testing.expectEqual(@as(f32, 8), node.style.effectiveRadii()[3]);
                try testing.expect(Color.eql(Color.TRANSPARENT, node.style.border_side_colors().?.right.?));
                try testing.expectEqual(@as(f32, -1), node.style.margin.left);
                try testing.expectEqual(@as(f32, 1), node.style.gap);
                // A later best-effort write still cascades over the fallible one.
                node.setStyleInline(cx.allocator, .{ .gap = 4 });
                try testing.expectEqual(@as(f32, 4), node.style.gap);
                try testing.expectEqual(@as(f32, -1), node.style.margin.left);
                break;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                // nothing applied, nothing left behind
                try testing.expectEqual(@as(f32, 0), node.style.margin.left);
                try testing.expectEqual(@as(f32, 0), node.style.effectiveRadii()[0]);
                try testing.expect(node.style.border_side_colors() == null);
                try testing.expectEqual(had_ext, node.style.ext != null);
                // and the node keeps working: the write lands once memory is back
                try node.setStyleInlineFallible(cx.allocator, want);
                try testing.expectEqual(@as(f32, -1), node.style.margin.left);
            }
        }
        // host: inline declaration, target and ext block; direct: the ext block
        try testing.expect(failures >= if (hosted) @as(usize, 3) else 1);
    }
}

test "stageStyleInline：abort 后节点原样（不留新建的 ext、不留暂存），commit 后完整生效" {
    const env = try Env.init();
    defer env.deinit(null);
    for ([_]bool{ true, false }) |hosted| {
        const node = if (hosted)
            try v.render(env.scope, env.cx, v.box(.{ .style = .{ BoxStyle{ .gap = 1 }, v.hover(BoxStyle{ .opacity = 0.5 }) } }, .{}))
        else
            try core.box(env.cx, .{ .gap = 1 }, .{});
        defer env.cx.freeNode(node);
        try testing.expectEqual(hosted, node.meta.per_frame.hooks.style_host != null);
        try testing.expect(node.style.ext == null);
        const want = BoxStyle{ .corner_radii = .{ .all = 6 }, .margin = .{ .left = -1 } };
        const staged = try node.stageStyleInline(env.cx.allocator, want);
        try testing.expectEqual(@as(f32, 0), node.style.margin.left); // nothing visible yet
        staged.abort();
        try testing.expect(node.style.ext == null);
        try testing.expectEqual(@as(f32, 0), node.style.margin.left);
        (try node.stageStyleInline(env.cx.allocator, want)).commit();
        try testing.expectEqual(@as(f32, 6), node.style.effectiveRadii()[0]);
        try testing.expectEqual(@as(f32, -1), node.style.margin.left);
    }
}

test "组件内联层：绕过宿主直接改写它管着的字段会被 Debug 检测到" {
    const env = try Env.init();
    const sel = try env.scope.createSignal(bool, false);
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ BoxStyle{ .gap = 1 }, v.when(sel, BoxStyle{ .padding = types.Padding.all(3) }) } }, .{}));
    defer env.deinit(root);
    try testing.expect(!v.styleConflictReportedForTest(root));
    root.style.gap = 42; // Directly overwrite gap managed by host
    sel.set(true);
    try testing.expect(v.styleConflictReportedForTest(root));
}

fn expectSameBoxStorage(a: *Node, b: *Node) !void {
    var sa = a.style;
    var sb = b.style;
    sa.ext = null;
    sb.ext = null;
    inline for (@import("zenit_reflection").fields(types.Style)) |f| {
        if (comptime !std.mem.eql(u8, f.name, "ext")) {
            if (!@import("style_decl.zig").valueEql(@field(sa, f.name), @field(sb, f.name))) {
                std.debug.print("Style.{s} differs\n", .{f.name});
                return error.TestUnexpectedResult;
            }
        }
    }
    const def: types.StyleExt = .{};
    const ea = if (a.style.ext) |e| e.* else def;
    const eb = if (b.style.ext) |e| e.* else def;
    inline for (@import("zenit_reflection").fields(types.StyleExt)) |f| {
        const is_ptr = comptime switch (@typeInfo(f.type)) {
            .pointer => true,
            .optional => |o| @typeInfo(o.child) == .pointer,
            else => false,
        };
        // Pointer fields (grid config etc) not in BoxStyle write scope
        if (comptime !is_ptr) if (!@import("style_decl.zig").valueEql(@field(ea, f.name), @field(eb, f.name))) {
            std.debug.print("StyleExt.{s} differs\n", .{f.name});
            return error.TestUnexpectedResult;
        };
    }
    try testing.expect(Color.eql(a.getBackground(), b.getBackground()));
    try testing.expectApproxEqAbs(a.getOpacity(), b.getOpacity(), 0.0001);
}

test "组件内联层：节点当前盒样式读成声明再写到新节点，样式存储完全一致（与 applyTo 互逆）" {
    const env = try Env.init();
    const holder = try core.box(env.cx, .{}, .{});
    defer env.deinit(holder);
    const sh = types.Shadow{ .color = Color.hex(0x112233), .blur = 6, .offset_y = 2 };
    const ish = types.InsetShadow{ .color = Color.hex(0x445566), .blur = 3 };
    const styles = [_]BoxStyle{
        .{
            .width = .{ .px = 120 },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = .center,
            .align_items = .center,
            .gap = 7,
            .padding = types.Padding.all(5),
            .margin_spec = .{ .left = 3, .auto_mask = 0b0010 },
            .flex = 1,
            .overflow_hidden = true,
            .cursor = .pointer,
            .translate_x = 4,
            .translate_y = -2,
            .border = .{ .width = 2, .color = Color.hex(0xAA0000), .radius = 6 },
            .border_left_color = Color.hex(0x00AA00),
            .corner_radii = .{ .each = .{ 1, 2, 3, 4 } },
            .shadows = types.ShadowList.of(&.{ sh, sh }),
            .inset_shadows = types.InsetShadowList.of(&.{ ish, ish }),
            .scale_x = 1.1,
            .rotate = 0.2,
            .z_index = 3,
            .outline = .{ .color = Color.hex(0x0000FF) },
            .min_width = 10,
            .tab_index = 2,
            .text_color = Color.hex(0x777777),
            .font_size = 15,
            .font_weight = 600,
            .background = Color.hex(0x202020),
            .opacity = 0.75,
        },
        .{
            .margin = types.Padding.all(2),
            .corner_radius = 9,
            .shadow = sh,
            .inset_shadow = ish,
            .border_width = 1,
            .border_color = Color.hex(0x333333),
            .gap = 1,
        },
        .{},
    };
    for (styles) |st| {
        const a = try core.box(env.cx, st, .{});
        defer env.cx.freeNode(a);
        const cap = v.captureInlineStyleForTest(a);
        const b = try core.box(env.cx, cap, .{});
        defer env.cx.freeNode(b);
        try expectSameBoxStorage(a, b);
    }
}

test "组件内联层：unsetStyleInline 撤掉内联写入，回落到元素自己的样式" {
    const env = try Env.init();
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{ BoxStyle{ .gap = 1 }, v.hover(BoxStyle{ .opacity = 0.5 }) } }, .{}));
    defer env.deinit(root);
    root.setOpacity(0.8);
    const enter = root.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try testing.expectApproxEqAbs(@as(f32, 0.8), root.getOpacity(), 0.001);
    root.unsetStyleInline(.{ .opacity = 0 }); // Value ignored, only field checked
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.getOpacity(), 0.001); // Revert to element hover value
    const leave = root.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try testing.expectApproxEqAbs(@as(f32, 1), root.getOpacity(), 0.001);
}

test "组件内联层：宿主创建时背景正在过渡，捕获的是过渡终点而不是插值中的值" {
    const env = try Env.init();
    const over = try env.scope.createSignal(bool, false);
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            const n = try core.box(cx, .{ .background = Color.hex(0x000000), .width = .{ .px = 10 } }, .{});
            const tr = comptime @import("recipe.zig").transition("background 200ms");
            try n.applyTransition(cx.allocator, &tr);
            n.setBackground(Color.hex(0xFFFFFF)); // Transition start: black to white, current rendered is still black
            return n;
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.attrs(.{ .style = v.when(over, BoxStyle{ .background = Color.hex(0xFF0000) }) }, Comp{}),
    }));
    defer env.deinit(root);
    const n = root.children.items[0];
    over.set(true);
    over.set(false);
    // Retract target is white from inline layer (transition end), not rendered value at capture
    const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
    try testing.expect(Color.eql(Color.hex(0xFFFFFF), slot.to_color));
}

test "呈现值与过渡：叠加层的首次应用（挂载期间）立即生效，不触发过渡" {
    const env = try Env.init();
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            const n = try core.box(cx, .{ .background = Color.hex(0x000000), .width = .{ .px = 10 } }, .{});
            const tr = comptime @import("recipe.zig").transition("background 200ms");
            try n.applyTransition(cx.allocator, &tr);
            return n;
        }
    };
    const over_on = try env.scope.createSignal(bool, true);
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.attrs(.{ .style = v.when(over_on, BoxStyle{ .background = Color.hex(0xFF0000) }) }, Comp{})}));
    defer env.deinit(root);
    const n = root.children.items[0];
    try testing.expect(Color.eql(Color.hex(0xFF0000), n.getBackground()));
    try testing.expect(!n.frame_state.frame_local.runtime.transitions.?.find(.background).?.active);
}

fn fadeLoop(phase: f32, _: *const theme.ThemeTokens) BoxStyle {
    return .{ .opacity = 0.2 + phase * 0.5 };
}

test "动画层：循环压过作者层、独占它驱动的属性且不进过渡；关掉后按过渡从呈现值回到作者值" {
    const env = try Env.init();
    const saved = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = saved;
    render_engine.current_frame_time_ms = 400;
    const running = try env.scope.createSignal(bool, true);
    const dim = try env.scope.createSignal(bool, false);
    const tr = comptime @import("recipe.zig").transition("opacity 200ms");
    const root = try v.render(env.scope, env.cx, v.box(.{ .style = .{
        v.loop(.{ .period_ms = 1000, .on = running }, fadeLoop),
        css(.{ .transition = tr }),
        v.when(dim, BoxStyle{ .opacity = 0.9 }),
    } }, .{}));
    defer env.deinit(root);
    // Loop first in tuple, but animation layer still overrides later author parts
    try testing.expectApproxEqAbs(@as(f32, 0.4), root.getOpacity(), 0.001);
    const slot = root.frame_state.frame_local.runtime.transitions.?.find(.opacity).?;
    render_engine.current_frame_time_ms = 600;
    runFrameHooks(root);
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.getOpacity(), 0.001); // Immediate, no transition
    try testing.expect(!slot.active);
    // During animation, author changes same field: animation exclusive, unchanged, no transition
    dim.set(true);
    try testing.expectApproxEqAbs(@as(f32, 0.5), root.getOpacity(), 0.001);
    try testing.expect(!slot.active);
    // Stop loop: opacity reverts to author (0.9), transitions from rendered 0.5
    running.set(false);
    try testing.expect(slot.active);
    try testing.expectApproxEqAbs(@as(f32, 0.5), slot.from_value, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), slot.to_value, 0.001);
}

fn bgOf(c: Color, _: *const theme.ThemeTokens) BoxStyle {
    return .{ .background = c };
}

test "呈现值与过渡：叠加层挂载时与当前显示相同（没有变化），之后它的变化照常过渡" {
    const env = try Env.init();
    const color = try env.scope.createSignal(Color, Color.hex(0xFF0000));
    const Comp = struct {
        pub fn mount(_: @This(), _: *Scope, cx: *Cx) !*Node {
            const n = try core.box(cx, .{ .background = Color.hex(0xFF0000), .width = .{ .px = 10 } }, .{});
            const tr = comptime @import("recipe.zig").transition("background 200ms");
            try n.applyTransition(cx.allocator, &tr);
            return n;
        }
    };
    const root = try v.render(env.scope, env.cx, v.col(.{}, .{v.attrs(.{ .style = v.styleBy(color, bgOf) }, Comp{})}));
    defer env.deinit(root);
    const n = root.children.items[0];
    const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
    try testing.expect(!slot.active);
    color.set(Color.hex(0x0000FF));
    try testing.expect(slot.active); // Not first apply: transitioned interpolation
    try testing.expect(Color.eql(Color.hex(0x0000FF), slot.to_color));
}

fn paintedTextColor(cx: *Cx, content_str: []const u8) ?Color {
    for (cx.display_list.items.items) |item| switch (item) {
        .text_run => |run| if (std.mem.eql(u8, run.content, content_str)) return run.color,
        else => {},
    };
    return null;
}

fn paintedIconTint(cx: *Cx) ?Color {
    for (cx.display_list.items.items) |item| switch (item) {
        .icon_rep => |ic| return ic.tint,
        else => {},
    };
    return null;
}

const CurrentColorProbe = struct {
    var seen: ?Color = null;
    fn draw(ctx: core.DrawContext, _: void, _: v.Frame) anyerror!void {
        seen = ctx.current_color;
    }
};

fn layoutAndRender(cx: *Cx) void {
    cx.layout();
    _ = cx.render();
}

const StarIcon = struct {
    fn current(c: ?Color, _: *const ThemeTokens) ?Color {
        return c;
    }
};

/// A box whose text_color follows `danger`, holding `leaf` (two levels down).
fn inheritedColorPage(env: Env, danger: *reactive.Signal(bool), leaf: anytype) !*Node {
    const page = try v.render(env.scope, env.cx, v.box(.{ .style = .{ .width = .{ .px = 200 }, .height = .{ .px = 60 } } }, .{
        v.box(.{ .style = .{ css(.{ .text_color = .fg_primary }), v.when(danger, css(.{ .text_color = .danger })) } }, .{
            v.row(.{}, .{leaf}),
        }),
    }));
    env.cx.root = page;
    env.cx.setViewport(200, 60);
    layoutAndRender(env.cx);
    return page;
}

fn closePage(env: Env, page: *Node) void {
    env.cx.root = null;
    env.deinit(page);
}

test "继承的文字颜色：祖先 text_color 变化时文字重画，不回放旧缓存" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const danger = try env.scope.createSignal(bool, false);
    const page = try inheritedColorPage(env, danger, v.text(.{}, "inherits"));
    defer closePage(env, page);
    try testing.expect(Color.eql(t.fg_primary, paintedTextColor(env.cx, "inherits").?));
    danger.set(true);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.danger, paintedTextColor(env.cx, "inherits").?));
    danger.set(false);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.fg_primary, paintedTextColor(env.cx, "inherits").?));
}

test "继承的文字颜色：currentColor 图标跟随祖先 text_color 重画" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const danger = try env.scope.createSignal(bool, false);
    const page = try inheritedColorPage(env, danger, v.icon(.{
        .style = .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } },
        .tint = v.tintBy(@as(?Color, null), StarIcon.current),
    }, @import("svg_assets.zig").common.star));
    defer closePage(env, page);
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
    danger.set(true);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.danger, paintedIconTint(env.cx).?));
}

test "继承的文字颜色：自绘的 DrawContext.current_color 跟随祖先 text_color" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const danger = try env.scope.createSignal(bool, false);
    CurrentColorProbe.seen = null;
    const page = try inheritedColorPage(env, danger, v.canvas(.{ .style = .{ .width = .{ .px = 4 }, .height = .{ .px = 4 } } }, v.paint(.{}, CurrentColorProbe.draw)));
    defer closePage(env, page);
    try testing.expect(Color.eql(t.fg_primary, CurrentColorProbe.seen.?));
    CurrentColorProbe.seen = null;
    danger.set(true);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.danger, CurrentColorProbe.seen.?));
}

test "currentColor 图标：没有祖先声明文字颜色时用 fg-primary；tintBy 返回颜色时照常着色" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const tint = try env.scope.createSignal(?Color, null);
    const page = try v.render(env.scope, env.cx, v.box(.{ .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } } }, .{
        v.icon(.{ .style = .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }, .tint = v.tintBy(tint, StarIcon.current) }, @import("svg_assets.zig").common.star),
    }));
    env.cx.root = page;
    defer {
        env.cx.root = null;
        env.deinit(page);
    }
    env.cx.setViewport(50, 50);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
    tint.set(t.accent);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.accent, paintedIconTint(env.cx).?));
    try testing.expect(!page.children.items[0].getIcon().?.tint_current_color);
    tint.set(null);
    layoutAndRender(env.cx);
    try testing.expect(page.children.items[0].getIcon().?.tint_current_color);
}

const LayeredTone = cva(.{
    .base = .{ .background = .bg_primary, ._hover = .{ .background = .bg_hover }, ._active = .{ .background = .bg_active }, ._disabled = .{ .background = .disabled_bg } },
    .variants = .{ .kind = .{ .plain = .{}, .loud = .{ .background = .accent } } },
});

test "cva .merge(layers)：运行期分状态层并进配方——调用方 base 在配方 :hover / :active / :disabled 之下，同状态层后者胜，层可来自信号" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const red = Color.rgba(200, 0, 0, 255);
    const blue = Color.rgba(0, 0, 200, 255);
    const layers = try env.scope.createSignal(core.ConditionalStyle, .{ .base = .{ .background = red, .padding = core.Padding.all(3) } });
    const disabled = try env.scope.createSignal(bool, false);
    const page = try v.render(env.scope, env.cx, v.col(.{}, .{
        v.box(.{
            .style = LayeredTone.of(.{ .kind = .plain }).merge(layers),
            .state = .{ .disabled = disabled, .invalid = false, .selected = false, .expanded = false },
        }, .{}),
    }));
    defer env.deinit(page);
    const n = page.children.items[0];
    const bg = struct {
        fn of(x: *Node) Color {
            if (x.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.background)) |slot| if (slot.active) return slot.to_color;
            return x.getBackground();
        }
    }.of;
    try testing.expect(Color.eql(red, bg(n)));
    try testing.expectEqual(core.Padding.all(3), n.style.padding);
    n.behavior.events.on_hover.?.invoke();
    try testing.expect(Color.eql(t.bg_hover, bg(n))); // recipe :hover over the caller's base
    env.cx.pressed_node = n;
    env.cx.notifyPressWatchers();
    try testing.expect(Color.eql(t.bg_active, bg(n)));
    env.cx.pressed_node = null;
    env.cx.notifyPressWatchers();
    layers.set(.{ .base = .{ .background = red }, .hover = .{ .background = blue } });
    try testing.expect(Color.eql(blue, bg(n))); // same state: the layer wins
    try testing.expectEqual(core.Padding.ZERO, n.style.padding); // dropped field falls back
    disabled.set(true);
    try testing.expect(Color.eql(t.disabled_bg, bg(n))); // :disabled short-circuits, over the base
}

fn laidOutWidth(n: *Node) f32 {
    return n.rectFromWorldOrFallback().w;
}

/// Weight-aware stand-in for the platform measure (the test build's fallback ignores weight).
fn weightedMeasure(_: [*]const u8, len: usize, font_size: f32, font_weight: u16, _: bool) f32 {
    return @as(f32, @floatFromInt(len)) * font_size * (0.4 + @as(f32, @floatFromInt(font_weight)) / 2000);
}

test "继承的字号 / 字重：布局测量与绘制用同一份解析结果；文字自己声明的优先；祖先变化后代重新测量" {
    const env = try Env.init();
    const painted = @import("core/render_engine/text_render.zig").resolveNodeLogicalTextProps;
    const big = try env.scope.createSignal(bool, false);
    const start = BoxStyle{ .direction = .column, .align_items = .start };
    const page = try v.render(env.scope, env.cx, v.box(.{ .style = start }, .{
        v.box(.{ .style = .{ start, css(.{ .font_size = 13, .font_weight = 500 }), v.when(big, css(.{ .font_size = 20, .font_weight = 700 })) } }, .{
            v.text(.{}, "Inherited label"),
            v.text(.{ .style = css(.{ .font_size = 11 }) }, "Own size"),
            v.text(.{ .style = TextStyle{ .font_size = 12, .font_weight = 400 } }, "Whole style"),
        }),
        // References: the same strings with the expected properties declared.
        v.text(.{ .style = TextStyle{ .font_size = 13, .font_weight = 500 } }, "Inherited label"),
        v.text(.{ .style = TextStyle{ .font_size = 20, .font_weight = 700 } }, "Inherited label"),
        v.text(.{ .style = TextStyle{ .font_size = 11, .font_weight = 500 } }, "Own size"),
        v.text(.{ .style = TextStyle{ .font_size = 11, .font_weight = 700 } }, "Own size"),
        v.text(.{ .style = TextStyle{ .font_size = 12, .font_weight = 400 } }, "Whole style"),
    }));
    env.cx.root = page;
    defer {
        env.cx.root = null;
        env.deinit(page);
    }
    env.cx.text.measure_fn = weightedMeasure;
    env.cx.setViewport(800, 400);
    layoutAndRender(env.cx);
    const host = page.children.items[0];
    const inherited = host.children.items[0];
    const own = host.children.items[1];
    const whole = host.children.items[2];
    const ref = page.children.items[1..];
    try testing.expect(laidOutWidth(ref[0]) != laidOutWidth(ref[1]));
    try testing.expect(laidOutWidth(ref[2]) != laidOutWidth(ref[3]));

    // Rest: undeclared size / weight come from the box, declared ones stay the text's.
    try testing.expectEqual(@as(f32, 13), painted(inherited).?.font_size);
    try testing.expectEqual(@as(u16, 500), painted(inherited).?.font_weight);
    try testing.expectEqual(@as(f32, 11), painted(own).?.font_size);
    try testing.expectEqual(@as(u16, 500), painted(own).?.font_weight);
    try testing.expectEqual(@as(f32, 12), painted(whole).?.font_size);
    try testing.expectEqual(@as(u16, 400), painted(whole).?.font_weight);
    try testing.expectApproxEqAbs(laidOutWidth(ref[0]), laidOutWidth(inherited), 0.01);
    try testing.expectApproxEqAbs(laidOutWidth(ref[2]), laidOutWidth(own), 0.01);
    try testing.expectApproxEqAbs(laidOutWidth(ref[4]), laidOutWidth(whole), 0.01);

    // The box's size / weight change: undeclared descendants re-measure at what they now paint.
    big.set(true);
    layoutAndRender(env.cx);
    try testing.expectEqual(@as(f32, 20), painted(inherited).?.font_size);
    try testing.expectEqual(@as(u16, 700), painted(inherited).?.font_weight);
    try testing.expectEqual(@as(f32, 11), painted(own).?.font_size);
    try testing.expectEqual(@as(u16, 700), painted(own).?.font_weight);
    try testing.expectEqual(@as(f32, 12), painted(whole).?.font_size);
    try testing.expectEqual(@as(u16, 400), painted(whole).?.font_weight);
    try testing.expectApproxEqAbs(laidOutWidth(ref[1]), laidOutWidth(inherited), 0.01);
    try testing.expectApproxEqAbs(laidOutWidth(ref[3]), laidOutWidth(own), 0.01);
    try testing.expectApproxEqAbs(laidOutWidth(ref[4]), laidOutWidth(whole), 0.01);

    big.set(false);
    layoutAndRender(env.cx);
    try testing.expectApproxEqAbs(laidOutWidth(ref[0]), laidOutWidth(inherited), 0.01);
    try testing.expectApproxEqAbs(laidOutWidth(ref[2]), laidOutWidth(own), 0.01);
}

test "currentColor 图标 + cva .merge(layers) 的 hover 层 icon_color：悬停用层色，离开后恢复 currentColor 模式（继续跟随祖先文字色）" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const red = Color.rgba(200, 0, 0, 255);
    const danger = try env.scope.createSignal(bool, false);
    const layers = try env.scope.createSignal(core.ConditionalStyle, .{ .hover = .{ .icon_color = red } });
    const page = try inheritedColorPage(env, danger, v.icon(.{
        .style = LayeredTone.of(.{ .kind = .plain }).merge(layers),
        // Layers may carry any condition: the a11y props give the semantic states.
        .a11y = core.A11yProps{},
        .tint = v.tintBy(@as(?Color, null), StarIcon.current),
    }, @import("svg_assets.zig").common.star));
    defer closePage(env, page);
    const icon = page.children.items[0].children.items[0].children.items[0];
    try testing.expect(icon.getIcon().?.tint_current_color);
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
    icon.behavior.events.on_hover.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(red, paintedIconTint(env.cx).?));
    icon.behavior.events.on_leave.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(icon.getIcon().?.tint_current_color);
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
    danger.set(true);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.danger, paintedIconTint(env.cx).?));
}

test "currentColor 图标：悬停层生效期间 tintBy 源变化只改元素底色，不盖过层色；层撤销后落到最新的元素着色" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const red = Color.rgba(200, 0, 0, 255);
    const danger = try env.scope.createSignal(bool, false);
    const tint = try env.scope.createSignal(?Color, null);
    const layers = try env.scope.createSignal(core.ConditionalStyle, .{ .hover = .{ .icon_color = red } });
    const page = try inheritedColorPage(env, danger, v.icon(.{
        .style = LayeredTone.of(.{ .kind = .plain }).merge(layers),
        // Layers may carry any condition: the a11y props give the semantic states.
        .a11y = core.A11yProps{},
        .tint = v.tintBy(tint, StarIcon.current),
    }, @import("svg_assets.zig").common.star));
    defer closePage(env, page);
    const icon = page.children.items[0].children.items[0].children.items[0];
    icon.behavior.events.on_hover.?.invoke();
    tint.set(t.accent);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(red, paintedIconTint(env.cx).?));
    icon.behavior.events.on_leave.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.accent, paintedIconTint(env.cx).?));
    try testing.expect(!icon.getIcon().?.tint_current_color);
    icon.behavior.events.on_hover.?.invoke();
    tint.set(null);
    icon.behavior.events.on_leave.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(icon.getIcon().?.tint_current_color);
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
}

test "currentColor 图标 + 外部叠加层（v.attrs）的 hover icon_color：离开后恢复 currentColor 模式" {
    const env = try Env.init();
    const t = theme.light.tokens.color;
    const red = Color.rgba(200, 0, 0, 255);
    const danger = try env.scope.createSignal(bool, false);
    const page = try inheritedColorPage(env, danger, v.attrs(.{ .style = css(.{ ._hover = .{ .icon_color = comptime Color.rgba(200, 0, 0, 255) } }) }, v.icon(.{
        .style = .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } },
        .tint = v.tintBy(@as(?Color, null), StarIcon.current),
    }, @import("svg_assets.zig").common.star)));
    defer closePage(env, page);
    const icon = page.children.items[0].children.items[0].children.items[0];
    try testing.expect(Color.eql(t.fg_primary, paintedIconTint(env.cx).?));
    icon.behavior.events.on_hover.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(red, paintedIconTint(env.cx).?));
    icon.behavior.events.on_leave.?.invoke();
    layoutAndRender(env.cx);
    try testing.expect(icon.getIcon().?.tint_current_color);
    danger.set(true);
    layoutAndRender(env.cx);
    try testing.expect(Color.eql(t.danger, paintedIconTint(env.cx).?));
}
