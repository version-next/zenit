/// Tag Component
///
/// 标签/标记组件，用于分类、过滤等场景
///
/// 特性:
/// - 多种颜色变体
/// - 可关闭
/// - outline 模式
/// - 两种尺寸
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const Border = core.Border;
const svg_assets = @import("../../svg_assets.zig");
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const recipe_mod = @import("../../recipe.zig");

/// Tag 颜色
pub const TagColor = enum {
    neutral,
    accent,
    success,
    warning,
    danger,
    info,
};

/// Tag 变体
pub const TagVariant = enum {
    default,
    outline,
};

/// Tag 尺寸
pub const TagSize = enum {
    sm,
    md,

    pub fn height(self: TagSize) f32 {
        return switch (self) {
            .sm => 22,
            .md => 26,
        };
    }

    pub fn fontSize(self: TagSize) f32 {
        return switch (self) {
            .sm => 11,
            .md => 12,
        };
    }

    pub fn padding(self: TagSize) Padding {
        return switch (self) {
            .sm => Padding.symmetric(2, 6),
            .md => Padding.symmetric(3, 8),
        };
    }
};

// 样式层析出至 styles.zig；下列别名保持调用点与公共 API 不变。
const styles = @import("styles.zig");
pub const TagRecipe = styles.TagRecipe;
const tagCloseButtonStyle = styles.tagCloseButtonStyle;
const tagCloseIconStyle = styles.tagCloseIconStyle;
const tagCloseTextStyle = styles.tagCloseTextStyle;
const tagCloseHoverBg = styles.tagCloseHoverBg;

/// Tag 属性
pub const TagProps = struct {
    text: []const u8 = "",
    variant: TagVariant = .default,
    color: TagColor = .neutral,
    size: TagSize = .md,
    closable: bool = false,
    on_close: ?core.HandlerRef = null,
    close_icon_asset: ?svg_assets.Asset = null,
};

/// 创建 Tag
pub fn Tag(props: TagProps) TagBuilder {
    return TagBuilder{ .props = props };
}

pub const TagBuilder = struct {
    props: TagProps,

    pub fn text(self: TagBuilder, t: []const u8) TagBuilder {
        var new = self;
        new.props.text = t;
        return new;
    }

    pub fn variant(self: TagBuilder, v: TagVariant) TagBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn color(self: TagBuilder, c: TagColor) TagBuilder {
        var new = self;
        new.props.color = c;
        return new;
    }

    pub fn size(self: TagBuilder, s: TagSize) TagBuilder {
        var new = self;
        new.props.size = s;
        return new;
    }

    pub fn closable(self: TagBuilder, c: bool) TagBuilder {
        var new = self;
        new.props.closable = c;
        return new;
    }

    pub fn onClose(self: TagBuilder, handler_ref: core.HandlerRef) TagBuilder {
        var new = self;
        new.props.on_close = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: TagBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        // 绑定成功之前 my_scope 无人持有；绑定后 tag_node 归 my_scope、
        // my_scope 归父 scope（下游编辑器 git_diff sweep index 373 实测）。
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        // Recipe resolve：color × variant × size 三维度统一合并
        const cs = TagRecipe.resolve(.{
            .color = p.color,
            .variant = p.variant,
            .size = p.size,
        }, t);
        const resolved = cs.resolve(.{});

        const fg = resolved.text_color orelse t.color.fg_primary;

        // 几何来自 recipe derived；pill 圆角 = height/2 从 resolved 高度折算
        const tag_height: f32 = if (resolved.height) |h| h.px else p.size.height();

        // border: radius = height/2（pill 形状），color/width 来自 recipe
        // 用细粒度字段组合，不做整体 Border 覆盖
        var final_border = Border{ .radius = tag_height / 2 };
        if (resolved.border_width) |bw| final_border.width = bw;
        if (resolved.border_color) |bc| final_border.color = bc;

        const tag_node = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .px = tag_height },
            .direction = .row,
            .align_items = .center,
            .gap = resolved.gap orelse 4,
            .padding = resolved.padding,
            .background = resolved.background orelse Color.TRANSPARENT,
            .border = final_border,
        }, .{});
        tag_node.meta.ownership.meta.component_name = "Tag";
        // ⚠️ 这条守卫**不能**随 bindScopeToNode 成功而解除：
        // ScopeBinding 的 destroy 只解绑、从不释放节点，所以绑定之后
        // tag_node 依然无人回收，而下面 label / close_btn 都可失败
        // （index 375 实测：绑定后解除守卫仍漏 tag_node）。
        // freeNode 会顺带 dispose 绑定的 my_scope，故两者合成一条。
        errdefer cx.freeNode(tag_node);
        try core.bindScopeToNode(my_scope, tag_node);
        scope_bound = true;

        // 文本标签
        if (p.text.len > 0) {
            const label_node = try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{});
            label_node.setText(.{
                .content = p.text,
                .color = fg,
                .font_size = resolved.font_size orelse p.size.fontSize(),
            });
            _ = try adoptTagChild(cx, allocator, tag_node, label_node);
        }

        // 关闭按钮
        if (p.closable) {
            // 建好即挂：下面 icon / txt_node / useAnimatedBackground 全可失败。
            const close_btn = try adoptTagChild(cx, allocator, tag_node, try box(cx, tagCloseButtonStyle(t), .{}));
            close_btn.style.cursor = .pointer;

            if (p.close_icon_asset) |asset| {
                _ = try adoptTagChild(cx, allocator, close_btn, try core.iconTint(cx, asset, fg, tagCloseIconStyle()));
            } else {
                const txt_node = try box(cx, .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                }, .{});
                txt_node.setText(tagCloseTextStyle(fg));
                _ = try adoptTagChild(cx, allocator, close_btn, txt_node);
            }

            _ = try hooks.useAnimatedBackground(my_scope, cx, close_btn, .{
                .normal = Color.TRANSPARENT,
                .hover = tagCloseHoverBg(fg),
            });

            close_btn.behavior.events.on_click = p.on_close;
        }

        return tag_node;
    }
};

// ========== 测试 ==========

test "Tag: basic text" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{})
        .text("Hello")
        .color(.accent)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // 有 1 个子节点: label_text
    try std.testing.expectEqual(@as(usize, 1), tag_node.children.items.len);
}

test "Tag: closable" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{})
        .text("Closable")
        .closable(true)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // 有 2 个子节点: label_text + close_btn
    try std.testing.expectEqual(@as(usize, 2), tag_node.children.items.len);
}

test "Tag: outline variant" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{})
        .text("Outline")
        .variant(.outline)
        .color(.success)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // outline 有边框
    try std.testing.expectEqual(@as(f32, 1), tag_node.style.border.width);
}

test "Tag: sizes" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sm = try Tag(.{}).text("SM").size(.sm).mount(scope, ctx);
    const md = try Tag(.{}).text("MD").size(.md).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, sm);
    try root.appendChild(std.testing.allocator, md);

    try std.testing.expectEqual(@as(f32, 22), sm.style.height.px);
    try std.testing.expectEqual(@as(f32, 26), md.style.height.px);
}

test "Tag: background color is set" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{})
        .text("Test")
        .color(.accent)
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // 验证背景色不是透明的
    try std.testing.expect(tag_node.getBackground().a > 0);
    try std.testing.expect(tag_node.style.height.px > 0);

    // 验证背景色是预期的颜色 (accent 颜色使用 lerp 计算)
    try std.testing.expect(tag_node.getBackground().r > 0);
    try std.testing.expect(tag_node.getBackground().g > 0);
    try std.testing.expect(tag_node.getBackground().b > 0);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

/// 一次性收养：append 失败时自己释放 child。
fn adoptTagChild(cx: *Cx, allocator: std.mem.Allocator, parent: *Node, child: *Node) !*Node {
    errdefer cx.freeNode(child);
    try parent.appendChild(allocator, child);
    return child;
}

test "Tag: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tag", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Tag(.{}).text("Hello").color(.accent).closable(true).mount(scope, cx);
        }
    }.m);
}
