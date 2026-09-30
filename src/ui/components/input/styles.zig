//! Input / Textarea 样式层
//!
//! error 态用 ConditionalStyle 的 `invalid` 条件表达：resolve 链
//! （base ← hover ← focus ← invalid）保证 error 边框压过 hover/focus——
//! 与既有语义逐条等价（error 时抑制交互态的边框变化）。
//! 编辑器逻辑（光标/IME/滚动）不在此层，这里只有取色与文本样式声明。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;

// ============================================================================
// 边框取色 — 单一来源
// ============================================================================

/// Input 静息边框色：danger > 有值 border_strong > 空值 input_border。
/// （TextInputState.restingBorderColor 委托到这里。）
pub fn restingBorderColor(t: *const theme.ThemeTokens, has_error: bool, has_value: bool) Color {
    if (has_error) return t.color.danger;
    return if (has_value) t.color.border_strong else t.color.input_border;
}

/// 边框条件样式：resting 由调用方给定（Input 与 Textarea 静息色不同——
/// Input 按有无值取 border_strong/input_border，Textarea 恒 input_border）。
pub fn borderConditional(t: *const theme.ThemeTokens, resting: Color) ConditionalStyle {
    return .{
        .base = .{ .border_color = resting },
        .hover = .{ .border_color = t.color.accent },
        .focus = .{ .border_color = t.color.accent },
        .invalid = .{ .border_color = t.color.danger },
    };
}

/// 交互时点边框色：hover/focus → accent，invalid 压过一切交互态。
pub fn borderColor(t: *const theme.ThemeTokens, resting: Color, hovered: bool, focused: bool, has_error: bool) Color {
    const resolved = borderConditional(t, resting).resolve(.{
        .is_hovered = hovered,
        .is_focused = focused,
        .is_invalid = has_error,
    });
    // 每个条件态都声明了 border_color，恒有值
    return resolved.border_color.?;
}

/// hover 边框效果的生效条件（Input 与 Textarea 共同 gating：
/// 聚焦或 error 时抑制 hover 变色——focus/error 的边框优先）。
pub fn hoverBorderApplies(focused: bool, has_error: bool) bool {
    return !focused and !has_error;
}

// ============================================================================
// 文本与图标取色
// ============================================================================

/// 显示文本色：error > 有内容 fg_primary > placeholder（可被 props 覆盖）
pub fn displayTextColor(t: *const theme.ThemeTokens, has_error: bool, has_content: bool, placeholder_color: ?Color) Color {
    if (has_error) return t.color.danger;
    if (has_content) return t.color.fg_primary;
    return placeholder_color orelse t.color.fg_secondary;
}

/// leading/append 图标 tint：error 时 danger，否则弱化 tertiary
pub fn iconTintColor(t: *const theme.ThemeTokens, has_error: bool) Color {
    return if (has_error) t.color.danger else t.color.fg_tertiary;
}

/// Input 标签文本
pub fn labelTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_primary, .font_size = 14, .font_weight = 500 };
}

/// 必填星号
pub fn requiredMarkStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "*", .color = t.color.danger, .font_size = 14, .font_weight = 500 };
}

/// Input 辅助/错误文本
pub fn helperTextStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextProps {
    return .{
        .content = "",
        .color = if (has_error) t.color.danger else t.color.fg_secondary,
        .font_size = 12,
    };
}

/// append 文案（比输入字号小 1，下限 11）
pub fn appendTextStyle(t: *const theme.ThemeTokens, input_font_size: f32) core.TextProps {
    return .{
        .content = "",
        .color = t.color.fg_tertiary,
        .font_size = @max(@as(f32, 11), input_font_size - 1),
    };
}

// ── Textarea 专属（字号/静息色与 Input 刻意不同，保持既有视觉）──

/// Textarea 标签文本（12/fg_secondary，与 Input 的 14/fg_primary 不同）
pub fn textareaLabelStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_secondary, .font_size = 12 };
}

/// Textarea 辅助/错误文本（11 号）
pub fn textareaHelperStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextProps {
    return .{
        .content = "",
        .color = if (has_error) t.color.danger else t.color.fg_secondary,
        .font_size = 11,
    };
}

/// Textarea 底色（disabled 降级 bg_secondary）
pub fn textareaBackground(t: *const theme.ThemeTokens, disabled: bool) Color {
    return if (disabled) t.color.bg_secondary else t.color.input_bg;
}

/// Textarea mount 初始边框：danger > disabled separator > border_strong。
/// 注意与失焦后的静息色（input_border）刻意不同——历史行为，保持。
pub fn textareaInitialBorderColor(t: *const theme.ThemeTokens, has_error: bool, disabled: bool) Color {
    if (has_error) return t.color.danger;
    if (disabled) return t.color.separator;
    return t.color.border_strong;
}

// ============================================================================
// 覆盖层/特效取色
// ============================================================================

/// 按输入框底色亮度选水平 overflow fade 的强度：深底需要更实的
/// 内阴影才在视觉上可见（浅底同 alpha 会糊成灰边）。
pub fn innerShadowAlpha(t: *const theme.ThemeTokens) u8 {
    return if (t.color.input_bg.r <= 64 and t.color.input_bg.g <= 64 and t.color.input_bg.b <= 64) 90 else 44;
}

/// overflow fade 的颜色（黑色 + 亮度自适应 alpha）
pub fn overflowFadeColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(0, 0, 0, innerShadowAlpha(t));
}

/// IME preedit 下划线色（accent 高不透明）
pub fn imePreeditUnderlineColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.color.accent.r, t.color.accent.g, t.color.accent.b, 220);
}

/// IME 高亮/preedit 选段背景色（accent 半透明）
pub fn imeHighlightColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.color.accent.r, t.color.accent.g, t.color.accent.b, 64);
}
