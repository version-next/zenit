//! Divider 样式层 — 具名样式函数（颜色/粗细/间距来自 props 运行时值，参数化）
//! 业务逻辑在 mod.zig；DividerOrientation 是公共 API，循环 import 取用。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const BoxStyle = core.BoxStyle;
const Padding = core.Padding;
const mod = @import("mod.zig");
const DividerOrientation = mod.DividerOrientation;

// ============================================================================
// 具名样式函数 — Divider 的样式决策集中在这里，mount 逻辑只消费
// （颜色/粗细/间距来自 props 运行时值，作为参数传入）
// ============================================================================

/// 简单实线（水平/垂直），space > 0 时带外边距
pub fn lineStyle(o: DividerOrientation, thickness: f32, line_color: Color, space: f32) BoxStyle {
    var style: BoxStyle = switch (o) {
        .horizontal => .{
            .width = .{ .grow = .{} }, // fill container
            .height = .{ .px = thickness },
            .background = line_color,
        },
        .vertical => .{
            .width = .{ .px = thickness },
            .height = .{ .grow = .{} }, // fill container
            .background = line_color,
        },
    };
    if (space > 0) {
        style.margin_spec = switch (o) {
            .horizontal => core.Margin.fromPadding(Padding.symmetric(space, 0)),
            .vertical => core.Margin.fromPadding(Padding.symmetric(0, space)),
        };
    }
    return style;
}

/// dashed/dotted 的段容器
pub fn patternedContainerStyle(o: DividerOrientation, thickness: f32, dash_gap: f32, space: f32) BoxStyle {
    return switch (o) {
        .horizontal => .{
            .width = .{ .grow = .{} },
            .height = .{ .px = thickness },
            .direction = .row,
            .align_items = .center,
            .gap = dash_gap,
            .overflow_hidden = true,
            .margin_spec = core.Margin.fromPadding(Padding.symmetric(space, 0)),
        },
        .vertical => .{
            .width = .{ .px = thickness },
            .height = .{ .grow = .{} },
            .direction = .column,
            .align_items = .center,
            .gap = dash_gap,
            .overflow_hidden = true,
            .margin_spec = core.Margin.fromPadding(Padding.symmetric(0, space)),
        },
    };
}

/// 单个 dash/dot 段
pub fn dashStyle(o: DividerOrientation, thickness: f32, dash_length: f32, line_color: Color) BoxStyle {
    return switch (o) {
        .horizontal => .{
            .width = .{ .px = dash_length },
            .height = .{ .px = thickness },
            .background = line_color,
        },
        .vertical => .{
            .width = .{ .px = thickness },
            .height = .{ .px = dash_length },
            .background = line_color,
        },
    };
}

/// 带标签分隔线的外层 flex row 容器
pub fn labelContainerStyle(space: f32) BoxStyle {
    var style: BoxStyle = .{
        .width = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .gap = 12,
    };
    if (space > 0) {
        style.padding = Padding.symmetric(space, 0);
    }
    return style;
}

/// 标签旁的线段（flex fill 由调用处设 style.flex = 1）
pub fn labelLineStyle(thickness: f32, line_color: Color) BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = thickness },
        .background = line_color,
    };
}

/// 标签文本样式
pub fn labelTextStyle(t: *const core.theme.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = 12,
    };
}

pub fn fitBoxStyle() BoxStyle {
    return .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } };
}
