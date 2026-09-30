//! DatePicker 样式层 — trigger/panel/Today 按钮样式与交互态取色纯函数（zenit-styling-revamp）。
//! mount 初始态与运行时更新（syncTriggerVisual/updateDisplayLabel）共用同一取色源。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

// ========== 具名样式函数（样式层） ==========
// 迁移自 mount/syncTriggerVisual/updateDisplayLabel 的内联样式与颜色决策；
// 数值原样保留（zenit-styling-revamp）。

pub const panel_radius: f32 = 14;

/// trigger 边框颜色随 open / has_value 三态切换（mount 初始 + syncTriggerVisual 共用）
pub fn triggerBorderColor(open: bool, has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.color.border_focus else if (has_value) t.color.border_strong else t.color.border;
}

pub fn displayTextColor(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.color.fg_primary else t.color.fg_tertiary;
}

pub fn leadingIconTint(has_value: bool, t: *const theme.ThemeTokens) Color {
    return if (has_value) t.color.fg_secondary else t.color.fg_tertiary;
}

pub fn chevronTint(open: bool, t: *const theme.ThemeTokens) Color {
    return if (open) t.color.accent else t.color.fg_tertiary;
}



pub fn panelStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 300 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(20),
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = panel_radius },
        .shadow = Shadow{ .color = Color.rgba(0, 0, 0, 18), .blur = 24, .offset_x = 0, .offset_y = 8 },
    };
}

/// Today 按钮：Button(.secondary) 之上覆盖为浅填充、无边框、占满面板宽度。
/// 高度 / 字号 / 圆角来自 control metrics（不再写死 34 / 13 / 10）。
pub fn todayBtnOverride(t: *const theme.ThemeTokens) core.StyleOverride {
    return .{
        .width = .{ .grow = .{} },
        .background = t.color.bg_hover,
        .border = .{ .width = 0, .color = t.color.border },
    };
}
