//! Markdown style layer, all parameterized by MarkdownOptions (markdown intentionally independent
//! of layout,
//! colors / sizes injected from opts). mod.zig's emitter only consumes these functions.
const core = @import("../../core.zig");
const Padding = core.Padding;
const TextSpan = core.TextSpan;
const mod = @import("mod.zig");
const MarkdownOptions = mod.MarkdownOptions;

pub fn resolvedColor(opts: MarkdownOptions, comptime field: []const u8) core.Color {
    return @field(opts, field) orelse @field(themeOptions(opts, &core.theme.light), field).?;
}

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
        .padding = Padding.symmetric(8, 10),
        .background = resolvedColor(opts, "code_bg"),
        .border = .{ .overlay = true, .width = 1, .color = resolvedColor(opts, "rule_color"), .radius = core.theme.light.tokens.radius.control },
        .width = .{ .grow = .{} },
    };
}

pub fn mdCodeLineText(opts: MarkdownOptions) core.TextStyle {
    return .{
        .font_size = opts.code_font_size,
        .color = resolvedColor(opts, "code_color"),
        .font_weight = 450,
        .line_height = opts.code_line_height,
        .use_monospace_font = true,
    };
}

pub fn mdRuleStyle(opts: MarkdownOptions) core.BoxStyle {
    return .{
        .height = .{ .px = 1 },
        .background = resolvedColor(opts, "rule_color"),
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
        .background = resolvedColor(opts, "rule_color"),
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
        .gap = core.theme.light.tokens.space.space150,
        .width = .{ .grow = .{} },
    };
}

pub fn mdListMarkerText(opts: MarkdownOptions) core.TextStyle {
    return .{
        .font_size = opts.base_font_size,
        .color = resolvedColor(opts, "text_color"),
        .line_height = opts.line_height,
    };
}

// ── inline span styles (code / [alt] image chip / [text](url) link) ──

pub fn mdCodeSpanStyle(opts: MarkdownOptions) TextSpan {
    return .{
        .start = 0,
        .end = 0,
        .use_monospace_font = true,
        .bg_color = resolvedColor(opts, "code_bg"),
        .color = resolvedColor(opts, "code_color"),
        .inline_box_padding_left = 2,
        .inline_box_padding_right = 2,
        .inline_box_corner_radius = 3,
    };
}

pub fn mdImageChipSpanStyle(opts: MarkdownOptions) TextSpan {
    return .{
        .start = 0,
        .end = 0,
        .color = resolvedColor(opts, "code_color"),
        .bg_color = resolvedColor(opts, "code_bg"),
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
        .color = resolvedColor(opts, "link_color"),
        .underline = true,
    };
}

pub fn mdBoldSpanStyle() TextSpan {
    return .{ .start = 0, .end = 0, .font_weight = 700 };
}

pub fn mdItalicSpanStyle() TextSpan {
    return .{ .start = 0, .end = 0, .use_italic_font = true };
}

/// Keep caller overrides, while mapping the default Markdown palette to the active theme.
pub fn themeOptions(options: MarkdownOptions, t: *const core.ThemeTokens) MarkdownOptions {
    var out = options;
    inline for (.{ "text_color", "code_color", "code_bg", "link_color", "rule_color" }, .{ "fg_primary", "fg_primary", "surface_inset", "accent", "border" }) |field, token| {
        if (@field(out, field) == null) @field(out, field) = @field(t.tokens.color, token);
    }
    return out;
}
