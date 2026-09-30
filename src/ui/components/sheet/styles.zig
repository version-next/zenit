/// Sheet — 样式层
///
/// 遮罩/面板取色、阴影与内容区样式；overlay 生命周期与滑入动画在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;
const Shadow = core.Shadow;

/// 遮罩色 — props 覆盖优先，默认 overlay token
pub fn sheetBarrierColor(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.color.overlay;
}

/// 面板背景 — props 覆盖优先
pub fn sheetPanelBackground(override: ?Color, t: *const theme.ThemeTokens) Color {
    return override orelse t.color.bg_secondary;
}

/// 主投影层 — token shadow.lg
pub fn sheetKeyShadow(t: *const theme.ThemeTokens) Shadow {
    return t.shadow.lg;
}

/// 环境光阴影层：sheet 从侧边滑入，横向偏移阴影强调深度感
pub const sheet_ambient_shadow: Shadow = .{
    .color = Color.rgba(0, 0, 0, 20),
    .blur = 60,
    .offset_x = -8,
    .offset_y = 0,
};

pub fn sheetContentStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .padding = Padding.all(16),
    };
}
