//! counter_reactive 样式表 —— 与业务逻辑（Signal / Memo / 事件绑定）分离。
//!
//! 约定（见 docs/styling.md）：
//!   - 每个样式是 `fn (*const ui.ThemeTokens) BoxStyle/TextStyle` 纯函数，
//!     可命名、可复用、可单测；只消费 token，不写颜色/字号字面量。
//!   - 经 `ui.boxStyled` / `ui.textStyled` 挂载的节点，换主题时框架会带
//!     新 tokens 重放这些函数，样式自动跟随（普通 `ui.box(cx, .{...})`
//!     的内联字面量在 setTheme 后是死值）。
const ui = @import("ui");

pub fn root(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .gap = t.space._3,
        .padding = ui.Padding.all(t.space._10),
        .background = t.color.bg_primary,
        .align_items = .center,
        .justify = .center,
    };
}

pub fn title(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{
        .font_size = t.font_size.xxxl,
        .font_weight = 600,
        .color = t.color.fg_primary,
    };
}

pub fn counterText(t: *const ui.ThemeTokens) ui.TextStyle {
    // 18px 不在 font_size scale 上（xl=16 / xxl=20），是有意的视觉决定 ——
    // 用 ui.arb.px 逃生舱显式标记（对标 Panda 的 arbitrary values）。
    return .{ .font_size = ui.arb.px(18), .color = t.color.fg_primary };
}

pub fn derivedText(t: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = t.font_size.lg, .color = t.color.fg_secondary };
}

pub fn buttonRow(t: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .gap = t.space._2 };
}
