/// Chip Component
///
/// 标签组件，常用于筛选器、多选标签、分类标签等场景
/// 基于 ControlShell 构建，复用统一的背景动画 / focus ring / 圆角处理
///
/// 特性:
/// - 3 种尺寸: xs(20), sm(24), md(32)，映射 ControlSize
/// - 4 种变体: default, active, outline, disabled
/// - Pill 圆角 (radius=999, 通过 ControlShell pill 模式)
/// - 可选图标 + 可关闭
/// - 默认只读（readonly=true），仅 readonly=false 时启用 hover/click/focus 交互
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const control_shell = @import("../control_shell/mod.zig");
const controlShell = control_shell.controlShell;
const styles = @import("styles.zig");

/// Chip 样式配方（重导出：外部一律从 mod 取，不直捅 styles.zig）
pub const ChipRecipe = styles.ChipRecipe;
const Scope = @import("../../reactive.zig").Scope;
const svg_assets = @import("../../svg_assets.zig");

// ============================================================================
// 类型定义
// ============================================================================

/// Chip 尺寸，映射 ControlSize 的 xs/sm/md
pub const ChipSize = enum {
    xs,
    sm,
    md,

    pub fn controlSize(self: ChipSize) theme.ControlSize {
        return switch (self) {
            .xs => .xs,
            .sm => .sm,
            .md => .md,
        };
    }
};

/// Chip 变体
pub const ChipVariant = enum {
    default,
    active,
    outline,
    disabled,
};

// ============================================================================
// Chip 属性 + Builder
// ============================================================================

pub const ChipProps = struct {
    label: []const u8,
    size: ChipSize = .sm,
    variant: ChipVariant = .default,
    icon_asset: ?svg_assets.Asset = null,
    closable: bool = false,
    readonly: bool = true,
    on_click: ?core.HandlerRef = null,
    on_close: ?core.HandlerRef = null,
};

pub fn Chip(props: ChipProps) ChipBuilder {
    return ChipBuilder{ .props = props };
}

pub const ChipBuilder = struct {
    props: ChipProps,

    pub fn mount(self: ChipBuilder, scope: *Scope, cx: *Cx) !*Node {
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        const sz = p.size.controlSize();
        const is_disabled = p.variant == .disabled;
        const is_interactive = !is_disabled and !p.readonly;

        // Chip 自有样式全部来自 ChipRecipe（base 覆盖 + hover 目标色 + disabled 覆盖）
        const cs = styles.ChipRecipe.resolve(.{ .variant = p.variant }, t);

        // 通过 ControlShell 构建统一基底
        const has_icon = p.icon_asset != null;
        var shell = try controlShell(.{
            .size = sz,
            .variant = styles.shellVariant(p.variant),
            .disabled = is_disabled,
            .pill = true,
            .leading_icon = has_icon,
            .style = cs.base,
            .hover_style = if (is_interactive) cs.hover else null,
            .disabled_style = if (is_disabled) cs.disabled else null,
            .interactive = is_interactive,
            .focus_ring = is_interactive,
            .cursor = if (is_interactive) .pointer else .default,
        }, scope, cx);

        const node = shell.node;
        // sweep：node 守卫一直武装到 return；两个游离 slot 在挂上 / destroy 之前也要守
        errdefer cx.freeNode(node);
        var icon_slot_detached = true;
        errdefer if (icon_slot_detached) cx.freeNode(shell.icon_slot);
        var append_slot_detached = true;
        errdefer if (append_slot_detached) cx.freeNode(shell.append_slot);
        node.meta.ownership.meta.component_name = "Chip";
        // active variant 是"已选中"的视觉表达（填充色），AT 只能靠 selected 读到。
        node.behavior.interaction.a11y = .{
            .role = if (is_interactive) .button else .listitem,
            .label = p.label,
            .selected = (p.variant == .active),
            .disabled = is_disabled,
        };
        if (is_interactive) {
            if (p.on_click) |h| {
                node.behavior.events.on_click = .{ .callback = h.callback, .context = h.context };
            }
        }
        node.style.justify = .center;
        shell.content_slot.style.width = .{ .fit = .{} };

        // text color, label/icon/close 共用 recipe base 的 text_color
        const text_color: Color = cs.base.text_color orelse t.color.fg_primary;

        // leading icon -> icon_slot
        if (p.icon_asset) |asset| {
            const icon_sz = t.control.get(sz).icon_size;
            _ = try core.adoptChild(cx, allocator, shell.icon_slot, try core.iconTint(cx, asset, text_color, .{
                .width = .{ .px = icon_sz },
                .height = .{ .px = icon_sz },
            }));
            try node.replaceChildOrder(allocator, &.{ shell.icon_slot, shell.content_slot });
            icon_slot_detached = false;
        } else {
            cx.freeNode(shell.icon_slot); // Node.destroy 不回收 World element slot
            icon_slot_detached = false;
        }

        // label -> content_slot
        const label_node = try core.adoptChild(cx, allocator, shell.content_slot, try box(cx, .{}, .{}));
        label_node.setText(.{
            .content = p.label,
            .color = text_color,
            .font_size = t.control.get(sz).font_size,
            .line_height = t.control.get(sz).line_height,
            .font_weight = 500,
        });

        // close 按钮 -> append_slot
        if (p.closable) {
            const close_sz: f32 = t.control.get(sz).icon_size - 2;
            const close_node = try core.adoptChild(cx, allocator, shell.append_slot, try box(cx, .{
                .width = .{ .px = close_sz },
                .height = .{ .px = close_sz },
                .justify = .center,
                .align_items = .center,
            }, .{}));
            close_node.behavior.interaction.a11y = .{ .role = .button, .label = "Remove" };
            if (is_interactive) {
                close_node.style.cursor = .pointer;
                if (p.on_close) |h| {
                    close_node.behavior.events.on_click = .{ .callback = h.callback, .context = h.context };
                }
            }
            _ = try core.adoptChild(cx, allocator, close_node, try core.iconTint(cx, svg_assets.common.x_close, text_color, .{
                .width = .{ .px = close_sz },
                .height = .{ .px = close_sz },
            }));
            append_slot_detached = false;
            _ = try core.adoptChild(cx, allocator, node, shell.append_slot);
        } else {
            cx.freeNode(shell.append_slot); // Node.destroy 不回收 World element slot
            append_slot_detached = false;
        }

        return node;
    }
};

// ============================================================================
// 测试
// ============================================================================

test "Chip: basic creation" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{ .label = "Tag" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expectEqualStrings("Chip", node.meta.ownership.meta.component_name.?);
    // sm -> ControlSize.sm -> height=24
    ctx.layout();
    // 高度由 padding_y × 2 + 行高 fit 撑出（不再是 style.height px）
    try std.testing.expectEqual(@as(f32, 24), node.rectFromWorldOrFallback().h);
}

test "Chip: 反复 mount/free 不泄漏 World element slot（未用 slot 走 freeNode）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Cycle = struct {
        fn run(c: *Cx, s: *Scope, r: *Node) !void {
            const sub = try s.childScope();
            const n = try Chip(.{ .label = "x" }).mount(sub, c); // 无 icon、不可关闭：两个 slot 都未用
            try r.appendChild(c.allocator, n);
            c.detachChild(r, n);
            c.freeNode(n);
            sub.dispose();
        }
    };
    try Cycle.run(ctx, scope, root);
    const baseline = ctx.world.elements.count();
    var i: usize = 0;
    while (i < 20) : (i += 1) try Cycle.run(ctx, scope, root);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

test "Chip: with icon and close" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Filter",
        .icon_asset = svg_assets.common.search,
        .closable = true,
        .size = .md,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    // md -> ControlSize.md -> height=32
    ctx.layout();
    // 高度由 padding_y × 2 + 行高 fit 撑出（不再是 style.height px）
    try std.testing.expectEqual(@as(f32, 32), node.rectFromWorldOrFallback().h);
}

test "Chip: xs size" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Mini",
        .size = .xs,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    // xs -> ControlSize.xs -> height=20
    ctx.layout();
    // 高度由 padding_y × 2 + 行高 fit 撑出（不再是 style.height px）
    try std.testing.expectEqual(@as(f32, 20), node.rectFromWorldOrFallback().h);
}

test "Chip: disabled variant" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Disabled",
        .variant = .disabled,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expectEqual(@as(f32, 1.0), node.getOpacity());
    try std.testing.expectEqual(thematicColor(ctx.tokens.color.bg_secondary), thematicColor(node.getBackground()));
    try std.testing.expectEqual(thematicColor(ctx.tokens.color.separator), thematicColor(node.style.border.color));
}

fn thematicColor(color: Color) u32 {
    return @bitCast(color);
}

test "Chip: readonly by default disables hover interaction" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{ .label = "Readonly by default" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expect(node.behavior.events.on_hover == null);
    try std.testing.expectEqual(core.CursorShape.default, node.style.cursor);
}

test "Chip: readonly false enables hover interaction" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Interactive",
        .readonly = false,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    try std.testing.expect(node.behavior.events.on_hover != null);
    try std.testing.expectEqual(core.CursorShape.pointer, node.style.cursor);
}

test "Chip: render emits background and label text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(240, 80);

    const root = try box(ctx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 80 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try Chip(.{
        .label = "Filter",
        .variant = .default,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_bg = false;
    var saw_label = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.bg_primary) and r.geom.w >= 40 and r.geom.h >= 20) {
            saw_bg = true;
        }
    } else if (cmd.isText()) {
        const tcmd = cmd;
        if (std.mem.eql(u8, tcmd.text_content, "Filter")) saw_label = true;
    };

    try std.testing.expect(saw_bg);
    try std.testing.expect(saw_label);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "chip(closable): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("chip(closable)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Chip(.{ .label = "chip", .closable = true, .readonly = false }).mount(scope, cx);
        }
    }.m);
}
