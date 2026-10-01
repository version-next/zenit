/// Form 布局容器
///
/// 纯布局组件，为 FormField 提供统一的排列方式。
/// 类似 SwiftUI 的 Form 容器。
///
/// 用法:
/// ```zig
/// const form_node = try Form(.{ .layout = .vertical, .gap = 16 }).mount(scope, cx);
/// try form_node.appendChild(allocator, field1_wrapper);
/// try form_node.appendChild(allocator, field2_wrapper);
/// ```
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Sizing = core.Sizing;
const Scope = core.Scope;
const Padding = core.Padding;

/// Form 布局方式
pub const FormLayout = enum {
    /// 字段垂直排列（默认）
    vertical,
    /// 字段水平排列
    horizontal,
};

/// Form 配置
pub const FormProps = struct {
    /// 布局方式
    layout: FormLayout = .vertical,
    /// 字段间距
    gap: f32 = 16,
    /// 内边距
    padding: ?Padding = null,
    /// 宽度
    width: ?f32 = null,
};

/// Form mount 结果
pub const FormResult = struct {
    /// 根容器节点
    node: *Node,
};

/// 创建 Form 布局容器
pub fn Form(props: FormProps) FormBuilder {
    return FormBuilder{ .props = props };
}

pub const FormBuilder = struct {
    props: FormProps,

    pub fn mount(self: FormBuilder, scope: *Scope, cx: *Cx) !FormResult {
        _ = scope;
        const p = self.props;

        const wrapper = try box(cx, .{
            .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = switch (p.layout) {
                .vertical => .column,
                .horizontal => .row,
            },
            .gap = p.gap,
            .padding = p.padding orelse Padding.all(0),
        }, .{});
        wrapper.meta.ownership.meta.component_name = "Form";

        return .{ .node = wrapper };
    }
};

/// Form 分组标题
pub fn FormSection(title: []const u8, cx: *Cx) !*Node {
    const t = cx.tokens;
    const allocator = cx.allocator;

    const section = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 12,
    }, .{});
    section.meta.ownership.meta.component_name = "FormSection";

    // 标题
    const title_node = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
    }, .{});
    title_node.setText(.{
        .content = title,
        .color = t.color.fg_primary,
        .font_size = 16,
        .font_weight = 600,
    });
    try section.appendChild(allocator, title_node);

    // 分割线
    const divider = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 1 },
        .background = t.color.separator,
    }, .{});
    try section.appendChild(allocator, divider);

    return section;
}

// ========== 测试 ==========

test "Form: vertical layout" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Form(.{ .layout = .vertical, .gap = 16 }).mount(scope, ctx);
    try root.appendChild(allocator, result.node);

    try std.testing.expectEqualStrings("Form", result.node.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(core.Direction.column, result.node.style.direction);
    try std.testing.expectEqual(@as(f32, 16), result.node.style.gap);
}

test "Form: horizontal layout" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Form(.{ .layout = .horizontal, .gap = 8 }).mount(scope, ctx);
    try root.appendChild(allocator, result.node);

    try std.testing.expectEqual(core.Direction.row, result.node.style.direction);
    try std.testing.expectEqual(@as(f32, 8), result.node.style.gap);
}

test "FormSection: title and divider" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const section = try FormSection("Personal Info", ctx);
    try root.appendChild(allocator, section);

    // section 应有 2 个子节点: title + divider
    try std.testing.expectEqual(@as(usize, 2), section.children.items.len);

    // 标题文本
    const title_node = section.children.items[0];
    try std.testing.expectEqualStrings("Personal Info", title_node.getText().?.content);

    // 分割线高度 1px
    const divider = section.children.items[1];
    try std.testing.expectEqual(Sizing{ .px = 1 }, divider.style.height);
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "form: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("form", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Form(.{}).mount(scope, cx)).node;
        }
    }.m);
}
