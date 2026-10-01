//! Steps 样式层，圆圈/标题/描述/连接线的全部视觉决策。
//! 水平与垂直两个布局分支共用，mod.zig 只消费。
const core = @import("../../core.zig");
const Color = core.Color;

pub const circle_size: f32 = 28;
pub const circle_fg = Color.WHITE;

pub fn circleBg(is_completed: bool, is_active: bool, t: *const core.ThemeTokens) Color {
    return if (is_completed or is_active) t.color.accent else t.color.border;
}

pub fn circleStyle(bg: Color) core.BoxStyle {
    return .{
        .width = .{ .px = circle_size },
        .height = .{ .px = circle_size },
        .background = bg,
        .border = .{ .radius = circle_size / 2 },
        .justify = .center,
        .align_items = .center,
    };
}

pub fn circleTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = circle_fg,
        .font_size = t.font_size.sm,
        .font_weight = 600,
        // 节点自身单行文本：纵向由渲染按盒内容区居中，横向由 text_align 居中。
        .text_align = .center,
    };
}

pub fn titleTextProps(is_active: bool, is_completed: bool, t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (is_active) t.color.fg_primary else if (is_completed) t.color.accent else t.color.fg_secondary,
        .font_size = t.font_size.sm,
        .font_weight = if (is_active) @as(u16, 600) else @as(u16, 400),
    };
}

pub fn descTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = t.font_size.xs,
    };
}

/// 水平连接线轨道（未完成段底色）
pub fn hTrackStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .position = .absolute,
        // left+right inset 只在 width=grow 时拉伸（layout_engine.layoutAbsoluteChild）；
        // 默认 fit 会解析成 0 宽 -> 连接线整条不画。
        .width = .{ .grow = .{} },
        .height = .{ .px = 2 },
        .background = t.color.border_strong,
    };
}

/// 水平连接线已完成段（覆盖在轨道上方）
pub fn hTrackProgressStyle(t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .grow = .{} }, // 同上：由 left/right inset 拉伸
        .height = .{ .px = 2 },
        .background = t.color.accent,
    };
}

/// 垂直布局连接线的最短长度（也是步骤间最小竖向间距）
pub const v_connector_min: f32 = 24;

/// 垂直布局的步骤间连接线：grow 填满指示器列里圆圈下方的剩余高度，
/// 这样无论文本多高，线都从本步圆圈底边一直接到下一步圆圈顶边。
pub fn vConnectorStyle(is_completed: bool, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 2 },
        .height = .{ .grow = .{ .min = v_connector_min } },
        .background = if (is_completed) t.color.accent else t.color.border,
    };
}

/// 垂直布局：文本列顶部内边距，让标题首行与圆圈竖向居中对齐
/// （行是 align_items=start，圆圈钉在行顶，文本不能再靠 center 对齐）。
pub fn vTitleTopPad(t: *const core.ThemeTokens) f32 {
    const title_line_h = t.font_size.sm * (core.TextProps{}).line_height;
    return @max(0, (circle_size - title_line_h) / 2);
}
