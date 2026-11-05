//! Input / Textarea style layer
//!
//! The field frame (border / background per hover, focus, invalid, disabled) is ControlShell's
//! `.field` tone; this layer adds field geometry overlays, text styles and colors.
//! Edit logic (cursor/IME/scroll) is not here.
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;

// ============================================================================
// Text and icon color
// ============================================================================

/// Validation changes border/helper; value text keeps its normal foreground.
pub fn displayTextColor(t: *const theme.ThemeTokens, has_error: bool, has_content: bool, placeholder_color: ?Color) Color {
    _ = has_error;
    if (has_content) return t.tokens.color.fg_primary;
    return placeholder_color orelse t.tokens.color.fg_secondary;
}

/// Invalid icons use secondary; normal leading/append icons use tertiary.
pub fn iconTintColor(t: *const theme.ThemeTokens, has_error: bool) Color {
    return if (has_error) t.tokens.color.fg_secondary else t.tokens.color.fg_tertiary;
}

/// Input label text
pub fn labelTextStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.sm, .font_weight = 600 };
}

/// Required asterisk (content "*")
pub fn requiredMarkStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.danger, .font_size = t.tokens.font_size.sm, .font_weight = 600 };
}

/// Input helper/error text
pub fn helperTextStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextStyle {
    return .{
        .color = if (has_error) t.tokens.color.danger else t.tokens.color.fg_tertiary,
        .font_size = t.tokens.font_size.xs,
    };
}

/// append text (1 size smaller than input, min 11)
pub fn appendTextStyle(t: *const theme.ThemeTokens, input_font_size: f32) core.TextStyle {
    return .{
        .color = t.tokens.color.fg_tertiary,
        .font_size = @max(@as(f32, 11), input_font_size - 1),
    };
}

// ── Textarea-specific typography and disabled chrome ──

/// r4MT7 field label: 12px semibold primary.
pub fn textareaLabelStyle(t: *const theme.ThemeTokens) core.TextStyle {
    return .{ .color = t.tokens.color.fg_primary, .font_size = t.tokens.font_size.sm, .font_weight = 600 };
}

/// Textarea helper/error text (11pt)
pub fn textareaHelperStyle(t: *const theme.ThemeTokens, has_error: bool) core.TextStyle {
    return .{
        .color = if (has_error) t.tokens.color.danger else t.tokens.color.fg_tertiary,
        .font_size = t.tokens.font_size.xs,
    };
}

// ============================================================================
// Overlay / effect color
// ============================================================================

/// Fade overflowing glyphs into the field, rather than darkening its blank
/// padding with an inner-shadow rectangle. The render hook follows the actual
/// field paint when custom styles, disabled colors or transitions change it.
pub fn overflowFadeColor(t: *const theme.ThemeTokens) Color {
    return t.tokens.color.input_bg;
}

/// IME preedit underline (accent high opacity)
pub fn imePreeditUnderlineColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.tokens.color.accent.r, t.tokens.color.accent.g, t.tokens.color.accent.b, 220);
}

/// IME highlight / preedit selection background (accent semi-transparent)
pub fn imeHighlightColor(t: *const theme.ThemeTokens) Color {
    return Color.rgba(t.tokens.color.accent.r, t.tokens.color.accent.g, t.tokens.color.accent.b, 64);
}

/// RYMhT: field sizes use the shared control tiers, body 13 and label 12.
/// Kept here because the shared SizeRecipe is owned by the controls workstream.
pub fn fieldMetrics(t: *const theme.ThemeTokens, size: @import("../control_shell/mod.zig").ControlSize) @import("../control_shell/mod.zig").ControlMetrics {
    var m = @import("../control_shell/mod.zig").metrics(t, size);
    const h = m.derivedHeight();
    m.font_size = switch (size) {
        .xs => t.tokens.font_size.xs,
        .sm => t.tokens.font_size.sm,
        .md => t.tokens.font_size.md,
        .lg => t.tokens.font_size.lg,
    };
    // TODO(token): line_height.body = 1.4 (RYMhT field text).
    m.line_height = @import("../../ui.zig").arb.px(1.4);
    m.padding_y = (h - m.lineHeightPx()) / 2;
    m.padding_h = switch (size) {
        .xs => t.tokens.space.space150,
        .sm => t.tokens.space.space200,
        .md => t.tokens.space.space300,
        .lg => t.tokens.space.space300 + t.tokens.space.space50,
    };
    m.padding_leading_icon = m.padding_h;
    m.radius = switch (size) {
        .xs, .sm => t.tokens.radius.md,
        .md, .lg => t.tokens.radius.control,
    };
    m.icon_size = switch (size) {
        .xs => t.tokens.font_size.sm,
        .sm => t.tokens.font_size.lg,
        .md, .lg => t.tokens.size.icon,
    };
    m.icon_size = @min(m.icon_size, m.lineHeightPx());
    m.gap = t.tokens.space.space150;
    return m;
}

pub fn editableChrome(t: *const theme.ThemeTokens) ConditionalStyle {
    return .{ .base = .{ .background = t.tokens.color.transparent, .border_color = t.tokens.color.transparent, .border_overlay = true, .border_width = 1, .corner_radius = t.tokens.radius.control }, .hover = .{ .border_color = t.tokens.color.border, .background = t.tokens.color.bg_hover }, .focus = .{ .border_color = t.tokens.color.focus_ring, .background = t.tokens.color.bg_primary } };
}

/// The field frame's border width. ControlShell(.field) draws it as an overlay (1px in every
/// state, control_shell/styles.yss `field`), so it takes no layout space; a caller's
/// `field_style` may change it.
pub fn fieldBorderWidth(field: core.StyleOverride) f32 {
    return @max(@as(f32, 0), field.border_width orelse 1);
}

/// Input's frame on its ControlShell (overlay): field geometry the shell's size recipe does not
/// own. Regular Input sinks its horizontal padding into the editable surface (same layer as the
/// overflow fade); embedded Input only flexes (the compound control draws the frame). The surface
/// still stops at the overlay border: its clip and overflow fade must not paint over the frame.
pub const Frame = struct {
    size: @import("../control_shell/mod.zig").ControlSize,
    width: ?f32,
    raised: bool,
    inline_padding: bool,
    embedded: bool,
    /// Caller's field overrides (`InputProps.field_style`), over the geometry and every frame
    /// state.
    field: core.StyleOverride = .{},
};

pub fn frame(f: Frame, t: *const theme.ThemeTokens) core.BoxStyle {
    return frameGeometry(f, t).merge(f.field);
}

fn frameGeometry(f: Frame, t: *const theme.ThemeTokens) core.BoxStyle {
    if (f.embedded) return .{ .align_self = .stretch, .width = .{ .grow = .{ .min = 0 } }, .flex_shrink = 1, .min_width = 0, .height = .{ .fit = .{} } };
    const m = fieldMetrics(t, f.size);
    return .{
        // ControlShell is fit-sized and opts out of cross-axis stretch (a Button stays its label's
        // width), so a width-less field takes the wrapper's width here; its value never sizes it.
        .width = if (f.width) |w| .{ .px = w } else .{ .grow = .{ .min = 0 } },
        .min_width = if (f.width == null) 0 else null,
        .align_self = if (f.width == null) .stretch else null,
        .corner_radius = m.radius,
        .shadow = if (f.raised) t.tokens.shadow.xs else null,
        .padding = if (f.inline_padding)
            .{ .top = m.padding_y, .right = fieldBorderWidth(f.field), .bottom = m.padding_y, .left = fieldBorderWidth(f.field) }
        else
            core.Padding.symmetric(m.padding_y, m.padding_h),
    };
}

/// Leading / append icon tone: disabled > invalid > normal.
pub const IconTone = enum { normal, invalid, disabled };

pub fn iconTint(tone: IconTone, t: *const theme.ThemeTokens) Color {
    return switch (tone) {
        .disabled => t.tokens.color.fg_disabled,
        .invalid => iconTintColor(t, true),
        .normal => iconTintColor(t, false),
    };
}

/// Textarea frame over ControlShell(.field): fixed height, no shell padding (the line list pads
/// itself), a clipped rounded scroll target that keeps wheel input from an outer ScrollArea.
/// `height` null: the field fills its wrapper (embedded Textarea; the compound control sizes the
/// wrapper).
pub const TextareaFrame = struct { width: ?f32, height: ?f32, radius: f32 };

pub fn textareaFrame(f: TextareaFrame, t: *const theme.ThemeTokens) core.BoxStyle {
    _ = t;
    return .{
        .width = if (f.width) |w| .{ .px = w } else .{ .grow = .{} },
        .height = if (f.height) |h| .{ .px = h } else .{ .grow = .{} },
        .align_self = .stretch,
        .padding = core.Padding.all(0),
        .align_items = .stretch,
        .corner_radius = f.radius,
        .overflow_hidden = true,
        .hit_shape = .{ .rounded_rect = f.radius },
        .clip_shape = .{ .rounded_rect = f.radius },
        .hit_roles = .{ .pointer = true, .scroll = true, .inspect = true },
    };
}

/// RYMhT: a focused textarea draws a 1.5px frame; an invalid one keeps the 1px danger frame.
pub const textarea_focus = @import("../../css.zig").css(.{ ._focus = .{ .border_overlay = true, .border_width = 1.5 }, ._invalid = .{ .border_overlay = true, .border_width = 1 } });

pub const TextareaMetrics = struct {
    font_size: f32,
    line_height: f32,
    padding_h: f32,
    padding_v: f32,
    radius: f32,
    height: f32,
};

/// RYMhT: standalone textarea is 100px with four 1.4em rows; explicit row counts retain their line-count semantics.
pub fn textareaMetrics(t: *const theme.ThemeTokens, size: ?@import("../control_shell/mod.zig").ControlSize, rows: u32) TextareaMetrics {
    const field = fieldMetrics(t, size orelse .md);
    const line = field.lineHeightPx();
    const count: f32 = @floatFromInt(@max(rows, 1));
    return .{
        .font_size = field.font_size,
        .line_height = line,
        .padding_h = if (size != null) field.padding_h else t.tokens.space.space300,
        .padding_v = if (size != null) @round(field.padding_y) else t.tokens.space.space300,
        .radius = field.radius,
        .height = if (size) |tier| @as(f32, switch (tier) {
            .xs => 44,
            .sm => 52,
            .md => 72,
            .lg => 88,
        }) + (count - 2) * line else 100 + (count - 4) * line,
    };
}
