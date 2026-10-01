/// ControlShell，统一基底布局函数
///
/// 为 Button / Input / Select 提供统一的三区域节点结构:
///   root (row, border, background, padding)
///   ├── icon_slot     (fit，调用者放 icon)
///   ├── content_slot  (grow，调用者放 text / input / label; Button 会覆盖为 fit)
///   └── append_slot   (fit，调用者放 chevron / spinner / clear)
///
/// 调用者通过返回的 ControlShellResult 拿到各 slot 引用，自行填充内容。
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Sizing = core.Sizing;
const Padding = core.Padding;
const Border = core.Border;
const CursorShape = core.CursorShape;
const StyleOverride = core.StyleOverride;
const ConditionalStyle = core.ConditionalStyle;
const Scope = core.Scope;
const theme = core.theme;
const hooks = @import("../../hooks.zig");
const recipe_mod = @import("../../recipe.zig");

/// 统一控件变体，按 UniPost 规格文档
///
/// | 风格       | 背景                 | 文字色              | 边框           | 字重 |
/// |-----------|---------------------|--------------------|--------------:|-----:|
/// | Primary   | $--text-primary     | $--text-inverse    | 无             | 600  |
/// | Secondary | $--bg (#FFF)        | $--text-primary    | $--border 1px  | 500  |
/// | Ghost     | 透明                 | $--text-secondary  | 无             | 500  |
/// | Link      | 透明                 | $--primary         | 无             | 500  |
pub const ControlVariant = enum {
    primary,
    secondary,
    ghost,
    danger,
    link,
    /// Input / Select 共享的输入框外观: 浅背景 + 边框
    field,
};

pub const ControlSize = theme.ControlSize;

// 样式层（ControlShellRecipe）析出至 styles.zig；此处重导出保住
// button/chip 等 `control_shell.ControlShellRecipe` 既有引用路径。
const styles = @import("styles.zig");
pub const ControlShellRecipe = styles.ControlShellRecipe;

/// ControlShell 配置
pub const ControlShellConfig = struct {
    size: ControlSize = .md,
    variant: ControlVariant = .secondary,
    disabled: bool = false,
    /// 是否有左侧 icon（影响 padding）
    leading_icon: bool = false,
    /// 是否仅图标、无文字（影响 padding）
    icon_only: bool = false,

    // ── 统一样式覆盖（新 API，推荐使用） ──
    /// 默认态样式覆盖
    style: StyleOverride = .{},
    /// hover 态样式覆盖
    hover_style: ?StyleOverride = null,
    /// pressed 态样式覆盖
    pressed_style: ?StyleOverride = null,
    /// disabled 态样式覆盖
    disabled_style: ?StyleOverride = null,

    /// 是否启用 hover/pressed 背景动画
    interactive: bool = true,
    /// 是否启用 focus ring
    focus_ring: bool = true,
    /// 光标样式
    cursor: CursorShape = .pointer,
    /// pill 模式（全圆角 999）
    pill: bool = false,

    /// 解析完整的 ConditionalStyle:
    /// ControlShellRecipe.resolve() 统一合并 variant × size × pill × icon_only × leading_icon
    /// -> 外部 style/hover_style/pressed_style/disabled_style 最后 override
    fn resolvedConditionalStyle(self: ControlShellConfig, t: *const theme.ThemeTokens) ConditionalStyle {
        var cs = ControlShellRecipe.resolve(.{
            .variant = self.variant,
            .size = self.size,
            .pill = self.pill,
            .icon_only = self.icon_only,
            .leading_icon = self.leading_icon,
        }, t);

        // 外部 prop 覆盖（优先级最高）
        return cs.override(.{
            .style = self.style,
            .hover_style = self.hover_style,
            .pressed_style = self.pressed_style,
            .disabled_style = self.disabled_style,
        });
    }
};

/// ControlShell 返回值，调用者通过 slot 引用填充内容
pub const ControlShellResult = struct {
    /// 根节点 (带 border / background / padding 的容器)
    node: *Node,
    /// 左侧 icon slot
    icon_slot: *Node,
    /// 中间内容 slot
    content_slot: *Node,
    /// 右侧 append slot
    append_slot: *Node,
    /// scope
    scope: *Scope,
    /// AnimBgState 引用 (运行时可改颜色)
    anim_bg: ?*hooks.AnimBgState,
};

fn syncGroupedControlShell(node: *Node) void {
    const scope = node.meta.ownership.scope.scope orelse return;
    const corner = node.style.corner_radius() orelse return;
    const radii = corner.resolve4();
    const is_uniform = radii[0] == radii[1] and
        radii[1] == radii[2] and
        radii[2] == radii[3];
    const ext = node.style.ensureExtPanic(scope.allocator);

    node.style.border.radius = 0;
    ext.hit_shape = .auto;
    // Non-uniform attached corners should not re-enter the uniform rounded-clip path.
    ext.clip_shape = if (is_uniform) .auto else .none;
}

/// 创建统一三区域控件基底
pub fn controlShell(config: ControlShellConfig, scope: *Scope, cx: *Cx) !ControlShellResult {
    const my_scope = try scope.childScope();
    var scope_bound = false;
    errdefer if (!scope_bound) my_scope.dispose();
    const allocator = cx.allocator;
    const sz = config.size;
    const t = cx.tokens;

    // ── Recipe resolve：统一合并 variant × size × pill × icon_only × leading_icon ──
    // cs 包含 base/hover/active/disabled 全态声明，不再需要手动拼样式
    const cs = config.resolvedConditionalStyle(t);
    // 取初始渲染态（disabled 时用 disabled 态，否则 base 态）
    const resolved = cs.resolve(.{ .is_disabled = config.disabled });

    const metrics = t.control.get(sz);

    // 几何字段（padding/radius/gap）全部由 recipe derived 产出；height/width 恒为 fit，
    // 函数体只做：标量提取（hit/clip 需要 radius）+ 细粒度字段 fold 进 Border。
    const radius: f32 = resolved.corner_radius orelse metrics.radius;
    const pad: Padding = resolved.padding orelse Padding.symmetric(metrics.padding_y, metrics.padding_h);

    // ── border fold：radius 标量 + 细粒度 border_color/border_width 折进 Border ──
    // 这不是占位 patch：外部 override（style prop）与 hover/disabled 态走的是
    // StyleOverride 的细粒度字段，在 derived 之后才 merge，只能在这里 fold。
    var final_border: Border = resolved.border orelse Border{};
    final_border.radius = radius;
    if (resolved.border_color) |bc| final_border.color = bc;
    if (resolved.border_width) |bw| final_border.width = bw;

    const final_background = resolved.background orelse Color.TRANSPARENT;
    const height_sizing: Sizing = resolved.height orelse .{ .fit = .{} };
    const width_sizing: Sizing = resolved.width orelse .{ .fit = .{} };
    const final_gap: f32 = resolved.gap orelse metrics.gap;

    // root: row layout，所有样式来自 recipe resolve 结果
    const node = try box(cx, .{
        .width = width_sizing,
        .height = height_sizing,
        .background = final_background,
        .border = final_border,
        .padding = pad,
        .direction = .row,
        .align_items = .center,
        .gap = final_gap,
    }, .{});
    errdefer cx.freeNode(node);
    try core.bindScopeToNode(my_scope, node);
    scope_bound = true;
    node.meta.per_frame.hooks.before_render.main = syncGroupedControlShell;
    // syncGroupedControlShell 只读写 **本节点自身** 的 style.border.radius /
    // ext.hit_shape / ext.clip_shape（见其实现），一个后代都不碰，担保成立。
    // 意义：控件基底遍布全 app（title bar/tab bar/toolbar/input 等），不声明
    // 的话每一个都会打断整条 paint 前缀，让其后所有干净子树退回 fresh emit。
    node.frame_state.state_bits.flags.before_render_hook_affects_self_only = true;

    // 圆角 hit/clip shape 和 opacity 写入 ext
    const hit_ext = try node.style.ensureExtFallible(allocator);
    hit_ext.hit_shape = .{ .rounded_rect = radius };
    hit_ext.clip_shape = .{ .rounded_rect = radius };
    node.style.cursor = resolved.cursor orelse (if (config.disabled) .not_allowed else config.cursor);
    if (resolved.opacity) |op| node.setOpacityRaw(op);

    // ── 行盒（line box）──
    // 外框高度合同：padding_y × 2 + 行高（font_size × line_height）。三个 slot 的最小
    // 高度都是行高，控件高度由布局 fit 自然撑出，空 label / 纯 tag / 比行高矮的内容
    // 也不会让外框塌矮；任何控件都不写死外框 height。
    // icon_only：图标槽最小 icon_size 见方（配合 derived 的 icon_only padding）。
    const line_box: f32 = metrics.lineHeightPx();

    // icon_slot (fit)，调用者填入内容后再 appendChild 到 node，避免空节点占用 gap
    const icon_slot = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .align_items = .center,
        .justify = .center,
    }, .{});

    errdefer cx.freeNode(icon_slot);
    {
        const ext = try icon_slot.style.ensureExtFallible(allocator);
        if (config.icon_only) {
            ext.min_width = metrics.icon_size;
            ext.min_height = metrics.icon_size;
        } else {
            ext.min_height = line_box;
        }
    }

    // content_slot (grow, Button 会覆盖为 fit 以配合 justify 居中)
    const content_slot = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
    }, .{});
    errdefer if (content_slot.parent == null) cx.freeNode(content_slot);
    (try content_slot.style.ensureExtFallible(allocator)).min_height = line_box;
    try node.appendChild(allocator, content_slot);

    // append_slot (fit)，调用者填入内容后再 appendChild 到 node，避免空节点占用 gap
    const append_slot = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .align_items = .center,
        .gap = final_gap,
    }, .{});

    errdefer cx.freeNode(append_slot);
    (try append_slot.style.ensureExtFallible(allocator)).min_height = line_box;

    // hover/pressed 动画 + focus ring
    var anim_bg: ?*hooks.AnimBgState = null;
    if (config.interactive and !config.disabled) {
        const colors = cs.bgColors();
        _ = try hooks.useAnimatedBackground(my_scope, cx, node, .{
            .normal = colors.normal,
            .hover = colors.hover,
            .pressed = colors.pressed,
        });
        if (node.meta.per_frame.hooks.slots.animated_bg_state) |state_ptr| {
            anim_bg = @ptrCast(@alignCast(state_ptr));
        }
        if (config.focus_ring) {
            try hooks.useFocusRing(my_scope, cx, node, .{});
        }
    }

    return .{
        .node = node,
        .icon_slot = icon_slot,
        .content_slot = content_slot,
        .append_slot = append_slot,
        .scope = my_scope,
        .anim_bg = anim_bg,
    };
}

// ========== 测试 ==========

test "ControlShell: basic structure" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try controlShell(.{}, scope, ctx);
    try root.appendChild(allocator, result.node);

    // root 默认只有 1 个子节点 content_slot；icon_slot/append_slot 由调用者按需 appendChild
    try std.testing.expectEqual(@as(usize, 1), result.node.children.items.len);
    try std.testing.expect(result.node == result.content_slot.parent.?);
    // icon_slot / append_slot 尚未挂载，parent 为 null
    try std.testing.expect(result.icon_slot.parent == null);
    try std.testing.expect(result.append_slot.parent == null);
    // 清理未挂载的孤立 slot，避免内存泄漏
    result.icon_slot.destroy(allocator);
    result.append_slot.destroy(allocator);
}

test "ControlShell: disabled skips interaction" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try controlShell(.{ .disabled = true }, scope, ctx);
    try root.appendChild(allocator, result.node);

    // disabled -> no anim_bg, no hover handler
    try std.testing.expect(result.anim_bg == null);
    try std.testing.expect(result.node.behavior.events.on_hover == null);
    result.icon_slot.destroy(allocator);
    result.append_slot.destroy(allocator);
}

test "ControlShell: interactive has anim_bg" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try controlShell(.{ .interactive = true }, scope, ctx);
    try root.appendChild(allocator, result.node);

    try std.testing.expect(result.anim_bg != null);
    try std.testing.expect(result.node.behavior.events.on_hover != null);
    result.icon_slot.destroy(allocator);
    result.append_slot.destroy(allocator);
}

test "ControlShell: grouped non-uniform radii disable uniform clip" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try controlShell(.{}, scope, ctx);
    try root.appendChild(allocator, result.node);

    const ext = try result.node.style.ensureExtFallible(allocator);
    ext.corner_radius = .{ .each = .{ 8, 0, 0, 8 } };

    if (result.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(result.node);
    }

    try std.testing.expectEqual(@as(f32, 0), result.node.style.border.radius);
    try std.testing.expect(result.node.style.hit_shape() == .auto);
    try std.testing.expect(result.node.style.clip_shape() == .none);
    result.icon_slot.destroy(allocator);
    result.append_slot.destroy(allocator);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "control_shell: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("control_shell", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const r = try controlShell(.{}, scope, cx);
            // icon/append slot 由调用方按需挂；夹具全部挂上，成功路径才不会把孤儿当泄漏
            errdefer {
                if (r.icon_slot.parent == null) r.icon_slot.destroy(cx.allocator);
                if (r.append_slot.parent == null) r.append_slot.destroy(cx.allocator);
            }
            try r.node.appendChild(cx.allocator, r.icon_slot);
            try r.node.appendChild(cx.allocator, r.append_slot);
            return r.node;
        }
    }.m);
}
