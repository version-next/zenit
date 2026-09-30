/// Modal — 样式层
///
/// 具名样式函数（迁移自 mount 内联样式，数值原样保留）；
/// overlay/焦点陷阱/动画结构在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const Padding = core.Padding;

pub const close_icon_size: f32 = 14;

pub fn dialogStyle(w: f32, max_h: f32, bg_override: ?Color, t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = w },
        .height = .{ .fit = .{ .max = max_h } },
        .background = bg_override orelse t.color.bg_secondary,
        .direction = .column,
        .border = .{ .radius = 8 },
    };
}

/// 环境光阴影层：超大范围软阴影，模拟 modal 极高 elevation（MD3 风格）。
/// 与 t.shadow.lg 一起经 setShadows 双层写入（BoxStyle 只装得下单 shadow）。
pub fn dialogAmbientShadow() core.Shadow {
    return .{ .color = Color.rgba(0, 0, 0, 25), .blur = 80, .offset_x = 0, .offset_y = 32 };
}

pub fn headerStyle(t: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .row,
        .justify = .space_between,
        .align_items = .center,
        .gap = 12,
        .padding = Padding.symmetric(12, 16),
        .width = .{ .grow = .{} },
        .border = .{ .width = 0, .color = t.color.separator, .radius = 0 },
    };
}

/// 标题盒吃满 header 剩余宽（而非 fit 内容宽），超长标题在盒内折行，
/// 高度随折行数增长——固定 20px 高会把第二行裁掉。
pub fn titleBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{ .width = .{ .grow = .{} } };
}

pub fn titleTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_primary, .font_size = 14, .font_weight = 600, .wrap = .word };
}

pub fn closeBtnStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .background = Color.TRANSPARENT,
        .justify = .center,
        .align_items = .center,
        .border = .{ .radius = 4 },
    };
}

/// 无 icon 资产时的文本 ✕ 回退（内层 24×24 容器复用 closeBtnStyle 的几何，无圆角）
pub fn closeGlyphBoxStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .background = Color.TRANSPARENT,
        .justify = .center,
        .align_items = .center,
    };
}

pub fn closeGlyphTextStyle(t: *const theme.ThemeTokens) core.TextProps {
    return .{ .content = "", .color = t.color.fg_secondary, .font_size = 14 };
}

pub fn bodyStyle(_: *const theme.ThemeTokens) core.BoxStyle {
    return .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .padding = Padding.all(16),
    };
}
