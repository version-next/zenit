//! Timeline 样式层 — 圆点/连接线/标题/描述/时间的视觉决策。
//! 状态→颜色映射（dotColor/lineColor）是 TimelineStatus 的公共 API，留在 mod.zig。
const core = @import("../../core.zig");
const mod = @import("mod.zig");
const TimelineStatus = mod.TimelineStatus;

pub const dot_size: f32 = 12;

pub fn dotStyle(status: TimelineStatus, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = dot_size },
        .height = .{ .px = dot_size },
        .background = status.dotColor(t),
        .border = .{ .radius = dot_size / 2 },
    };
}

pub fn connectorStyle(status: TimelineStatus, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 2 },
        .height = .{ .grow = .{} },
        .background = status.lineColor(t),
    };
}

pub fn titleTextProps(status: TimelineStatus, t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = if (status == .pending) t.color.fg_secondary else t.color.fg_primary,
        .font_size = t.font_size.md,
        .font_weight = if (status == .active) @as(u16, 600) else @as(u16, 400),
    };
}

pub fn descTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_secondary,
        .font_size = t.font_size.sm,
    };
}

pub fn timeTextProps(t: *const core.ThemeTokens) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_disabled,
        .font_size = t.font_size.xs,
    };
}
