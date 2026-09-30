//! Markdown 样式层 — 全部由 MarkdownOptions 参数化（markdown 刻意不依赖 theme，
//! 颜色/字号从 opts 注入）。mod.zig 的 emitter 只消费这些函数。
const core = @import("../../core.zig");
const Padding = core.Padding;
const TextSpan = core.TextSpan;
const mod = @import("mod.zig");
const MarkdownOptions = mod.MarkdownOptions;

pub fn mdRootStyle(opts: MarkdownOptions) core.BoxStyle {
    return .{
        .direction = .column,
        .gap = opts.paragraph_gap,
        .width = .{ .grow = .{} },
    };
}

pub fn mdHeadingSizeMul(level: u8) f32 {
    return switch (level) {
        1 => 1.4,
        2 => 1.25,
        3 => 1.15,
        4 => 1.08,
        5 => 1.04,
        else => 1.0,
    };
}

pub fn mdCodeBlockStyle(opts: MarkdownOptions) core.BoxStyle {
    return .{
        .direction = .column,
        .padding = Padding.all(6),
        .background = opts.code_bg,
        .border = .{ .radius = 4 },
        .width = .{ .grow = .{} },
    };
}

pub fn mdCodeLineText(opts: MarkdownOptions) core.TextProps {
    return .{
        .content = "",
        .font_size = opts.code_font_size,
        .color = opts.code_color,
        .font_weight = 450,
        .line_height = opts.code_line_height,
        .use_monospace_font = true,
    };
}

pub fn mdRuleStyle(opts: MarkdownOptions) core.BoxStyle {
    return .{
        .height = .{ .px = 1 },
        .background = opts.rule_color,
        .width = .{ .grow = .{} },
    };
}

pub fn mdBlockquoteStyle() core.BoxStyle {
    return .{
        .direction = .row,
        .padding = .{ .left = 8, .right = 0, .top = 2, .bottom = 2 },
        .width = .{ .grow = .{} },
    };
}

pub fn mdBlockquoteBarStyle(opts: MarkdownOptions) core.BoxStyle {
    return .{
        .width = .{ .px = 3 },
        .background = opts.rule_color,
        .height = .{ .grow = .{} },
    };
}

pub fn mdBlockquoteBodyStyle() core.BoxStyle {
    return .{
        .padding = .{ .left = 8, .right = 0, .top = 0, .bottom = 0 },
        .width = .{ .grow = .{} },
    };
}

pub fn mdListRowStyle() core.BoxStyle {
    return .{
        .direction = .row,
        .gap = 6,
        .width = .{ .grow = .{} },
    };
}

pub fn mdListMarkerText(opts: MarkdownOptions) core.TextProps {
    return .{
        .content = "",
        .font_size = opts.base_font_size,
        .color = opts.text_color,
        .line_height = opts.line_height,
    };
}

// ── inline span 样式（`code` / [alt] 图像 chip / [text](url) 链接） ──

pub fn mdCodeSpanStyle(opts: MarkdownOptions) TextSpan {
    return .{
        .start = 0,
        .end = 0,
        .use_monospace_font = true,
        .bg_color = opts.code_bg,
        .color = opts.code_color,
        .inline_box_padding_left = 2,
        .inline_box_padding_right = 2,
        .inline_box_corner_radius = 3,
    };
}

pub fn mdImageChipSpanStyle(opts: MarkdownOptions) TextSpan {
    return .{
        .start = 0,
        .end = 0,
        .color = opts.code_color,
        .bg_color = opts.code_bg,
        .inline_box_padding_left = 3,
        .inline_box_padding_right = 3,
        .inline_box_corner_radius = 3,
        .font_weight = 500,
    };
}

pub fn mdLinkSpanStyle(opts: MarkdownOptions) TextSpan {
    return .{
        .start = 0,
        .end = 0,
        .color = opts.link_color,
        .underline = true,
    };
}

pub fn mdBoldSpanStyle() TextSpan {
    return .{ .start = 0, .end = 0, .font_weight = 700 };
}

pub fn mdItalicSpanStyle() TextSpan {
    return .{ .start = 0, .end = 0, .use_italic_font = true };
}
