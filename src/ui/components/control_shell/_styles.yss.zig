// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! ControlShell styles: size recipe and variant coloring (YSS, shared source for
//! Button/Input/Select/DatePicker/Chip),
//! plus theme-computed metrics and cross-dimension geometry (literal Zig: line_height = font_size *
//! multiplier is arithmetic, read theme).
//! Structure and states in control_shell.yix; variant enum re-exported from mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const theme = core.theme;
const Sizing = core.Sizing;
const Padding = core.Padding;
const ConditionalStyle = core.ConditionalStyle;
const recipe_mod = @import("../../recipe.zig");

/// Size recipe: outer padding (vertical fractional is optical widget tweak) / radius / gap,
/// text font-size and line-height, icon size. Size tiers are recipe not theme category;
/// gap, font-size, radius, icon size still draw design-system token.
pub const SizeRecipe = ui.sva(.{ .slots = .{ .root, .content, .icon, }, .base = .{ .content = .{ .line_height = 1.2, .font_size = ui.tokenRef(.font_size, "md"), }, .root = .{ .corner_radius = ui.tokenRef(.radius, "control"), .gap = ui.tokenRef(.space, "space200"), }, .icon = .{ .width = ui.tokenRef(.size, "md"), }, }, .variants = .{ .size = .{ .xs = .{ .root = .{ .padding = .{ .y = 2.2, .x = ui.tokenRef(.space, "space300") }, }, }, .sm = .{ .root = .{ .padding = .{ .y = 4.2, .x = ui.tokenRef(.space, "space300") }, }, }, .md = .{ .root = .{ .padding = .{ .y = 8.2, .x = ui.tokenRef(.space, "space300") }, }, }, .lg = .{ .root = .{ .padding = .{ .y = 12.2, .x = ui.tokenRef(.space, "space400") }, }, }, }, }, .defaults = .{ .size = .md, }, });

/// LKxqO: finite interaction colors belong to the shared tone recipe.
pub const Tone = ui.previewCva("src/ui/components/control_shell/styles.yss", "Tone", @embedFile("styles.yss"), .{ .variants = .{ .kind = .{ .primary = .{ .background = ui.tokenRef(.color, "button-primary-bg"), .color = ui.tokenRef(.color, "button-primary-fg"), .font_weight = 500, .border_overlay = true, .border_width = 0, .border_color = ui.Color.TRANSPARENT, ._hover = .{ .background = ui.tokenRef(.color, "accent-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "accent-pressed"), }, ._disabled = .{ .background = ui.tokenRef(.color, "disabled-bg"), .color = ui.tokenRef(.color, "fg-disabled"), }, }, .secondary = .{ .background = ui.tokenRef(.color, "bg-primary"), .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 500, .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "border"), .shadow = ui.tokenRef(.shadow, "xs"), ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, ._disabled = .{ .background = ui.tokenRef(.color, "disabled-bg"), .color = ui.tokenRef(.color, "fg-disabled"), }, }, .ghost = .{ .background = ui.Color.TRANSPARENT, .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 500, .border_overlay = true, .border_width = 0, .border_color = ui.Color.TRANSPARENT, ._hover = .{ .background = ui.tokenRef(.color, "bg-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "button-pressed-bg"), }, ._disabled = .{ .background = ui.Color.TRANSPARENT, .color = ui.tokenRef(.color, "fg-disabled"), }, }, .danger = .{ .background = ui.tokenRef(.color, "danger"), .color = ui.tokenRef(.color, "fg-inverse"), .font_weight = 500, .border_overlay = true, .border_width = 1, .border_color = ui.Color.TRANSPARENT, .shadow = ui.tokenRef(.shadow, "xs"), ._hover = .{ .background = ui.tokenRef(.color, "danger-hover"), }, ._active = .{ .background = ui.tokenRef(.color, "danger-pressed"), }, ._disabled = .{ .background = ui.tokenRef(.color, "disabled-bg"), .color = ui.tokenRef(.color, "fg-disabled"), .border_color = ui.tokenRef(.color, "border"), .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 0, .spread = 0, .color = ui.Color.TRANSPARENT }, }, }, .link = .{ .background = ui.Color.TRANSPARENT, .color = ui.tokenRef(.color, "accent"), .font_weight = 500, .border_overlay = true, .border_width = 0, .border_color = ui.Color.TRANSPARENT, ._hover = .{ .color = ui.tokenRef(.color, "accent-hover"), }, ._active = .{ .color = ui.tokenRef(.color, "accent-pressed"), }, ._disabled = .{ .background = ui.Color.TRANSPARENT, .color = ui.tokenRef(.color, "fg-disabled"), }, }, .field = .{ .background = ui.tokenRef(.color, "input-bg"), .color = ui.tokenRef(.color, "fg-primary"), .font_weight = 400, .border_overlay = true, .border_width = 1, .border_color = ui.tokenRef(.color, "input-border"), .shadow = ui.tokenRef(.shadow, "xs"), ._hover = .{ .border_color = ui.tokenRef(.color, "accent"), }, ._expanded = .{ .border_color = ui.tokenRef(.color, "accent"), }, ._focus = .{ .border_color = ui.tokenRef(.color, "accent"), .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 5, .spread = 0, .color = ui.tokenRef(.color, "focus-halo") }, }, ._invalid = .{ .border_color = ui.tokenRef(.color, "danger"), }, ._disabled = .{ .background = ui.tokenRef(.color, "disabled-bg"), .color = ui.tokenRef(.color, "fg-disabled"), .border_color = ui.tokenRef(.color, "border"), .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 0, .spread = 0, .color = ui.Color.TRANSPARENT }, }, }, .base = .{ .background = ui.tokenRef(.color, "button-base-bg"), .color = ui.tokenRef(.color, "button-base-fg"), .font_weight = 500, .border_overlay = true, .border_width = 0, .border_color = ui.Color.TRANSPARENT, ._hover = .{ .background = ui.tokenRef(.color, "button-base-hover-bg"), }, ._active = .{ .background = ui.tokenRef(.color, "button-base-pressed-bg"), }, ._disabled = .{ .background = ui.tokenRef(.color, "disabled-bg"), .color = ui.tokenRef(.color, "fg-disabled"), .border_color = ui.tokenRef(.color, "border"), }, }, }, }, .defaults = .{ .kind = .secondary, }, });

pub const ControlSize = SizeRecipe.Dim(.size);
/// Control tones (Tone recipe is the single source): Button defaults to primary, ControlShell to
/// secondary; base = neutral emphasis, field = Input / Select frame.
pub const ControlVariant = Tone.Dim(.kind);
pub const ControlMetrics = struct {
    /// Text font size
    font_size: f32,
    /// Line-height multiplier (relative to font_size). Line height px = font_size * line_height
    line_height: f32,
    /// Radius
    radius: f32,
    /// Top/bottom padding (outer height = padding_y * 2 + line-height)
    padding_y: f32,
    /// Left/right padding
    padding_h: f32,
    /// Left padding when leading icon (top/bottom/right stay padding_y / padding_h)
    padding_leading_icon: f32,
    /// Icon size (<= line height)
    icon_size: f32,
    /// Icon-to-text gap
    gap: f32,

    /// Line height (px) = font_size * line_height
    pub fn lineHeightPx(self: ControlMetrics) f32 {
        return self.font_size * self.line_height;
    }

    /// Outer height (padding_y * 2 + line-height) derived from metrics.
    /// Read-only for measure/assert/position calc, **don't** write back to style.height;
    /// height from layout fit.
    pub fn derivedHeight(self: ControlMetrics) f32 {
        return self.padding_y * 2 + self.lineHeightPx();
    }
};

/// Measurement adapter for controls sharing the shell's line-box contract.
/// The recipe is the sole owner of the size mapping.
pub fn metrics(t: *const theme.ThemeTokens, size: ControlSize) ControlMetrics {
    const frame = SizeRecipe.Slot(.root).resolve(.{ .size = size }, t).base;
    const text = SizeRecipe.Slot(.content).resolveText(.{ .size = size }, .{}, t);
    const glyph = SizeRecipe.Slot(.icon).resolve(.{ .size = size }, t).base;
    return .{
        .font_size = text.font_size,
        .line_height = text.line_height,
        .radius = frame.corner_radius.?,
        .padding_y = frame.padding.?.top,
        .padding_h = frame.padding.?.right,
        .padding_leading_icon = @max(0, frame.padding.?.left - t.tokens.space.space50),
        .icon_size = @min(glyph.width.?.px, text.font_size * text.line_height),
        .gap = frame.gap.?,
    };
}

// ============================================================================
// ControlShell element styles (control_shell.yix). Geometry derives from the size recipe through
// metrics(t, size): one source for outer height = padding_y * 2 + line box.
// ============================================================================

/// Root: a row whose hit / clip shapes follow its corner radii (core .auto derivation, per-corner
/// inside a Group).
pub const root = ui.previewCss("src/ui/components/control_shell/styles.yss", "root", @embedFile("styles.yss"), .{ .direction = .row, .align_items = .center, });

/// Interaction colors ease like the old animated background (0.15s ease-out = ease_out_quad).
pub const fade = ui.previewCss("src/ui/components/control_shell/styles.yss", "fade", @embedFile("styles.yss"), .{ .transition = ui.transition("background 150ms ease-out, border-color 150ms ease-out"), });

/// Padding / radius / gap per size and icon fit (see IconFit).
pub const geometry = ui.paramStyle(struct { size: ControlSize, pill: bool, icon_only: bool, leading_icon: bool, icon_fit: IconFit, pub const declared = &[_][]const u8{ "width", "no_cross_stretch", "height", "padding", "corner_radius", "gap", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .width = .fit, .no_cross_stretch = true, .height = .fit, .padding = geometryPadding(t, args.size, args.icon_only, args.leading_icon, args.icon_fit), .corner_radius = if (args.pill) @as(f32, 999) else metrics(t, args.size).radius, .gap = geometryGap(t, args.size, args.leading_icon, args.icon_fit), }, t); } });

/// Cursor follows disabled (before the tone, so a composing control's root style can set it).
pub const pointer = ui.paramStyle(struct { cursor: core.CursorShape, disabled_cursor: core.CursorShape, disabled: bool, pub const declared = &[_][]const u8{ "cursor", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .cursor = if (args.disabled) args.disabled_cursor else args.cursor, }, t); } });

/// Embedded drops the frame (a compound control draws one shell); after the tone, over every state.
pub const chrome = ui.paramStyle(struct { embedded: bool, pub const declared = &[_][]const u8{ "border_overlay", "border_width", "padding", "background", "shadow", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out: ui.BoxStyle = .{}; if (args.embedded) out = out.merge(ui.boxFrom(.{ .border_overlay = true, .border_width = 0, .padding = 0, .background = ui.Color.TRANSPARENT, .shadow = .{ .offset_x = 0, .offset_y = 0, .blur = 0, .spread = 0, .color = ui.Color.TRANSPARENT }, }, t)); return out; } });

/// Slots: line-box minimum heights so empty / short content never collapses the control.
pub const icon_slot = ui.paramStyle(struct { size: ControlSize, icon_only: bool, pub const declared = &[_][]const u8{ "width", "height", "align_items", "justify", "min_height", "min_width", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { var out = ui.boxFrom(.{ .width = .fit, .height = .fit, .align_items = .center, .justify = .center, .min_height = if (args.icon_only) metrics(t, args.size).icon_size else metrics(t, args.size).lineHeightPx(), }, t); if (args.icon_only) out = out.merge(ui.boxFrom(.{ .min_width = metrics(t, args.size).icon_size, }, t)); return out; } });
/// The content slot takes the frame's remaining width and never more: `min-width: 0` opts out of
/// the CSS automatic minimum, so a long value / label (an Input's unscrolled text, a Select's
/// value) is clipped or scrolled inside the frame instead of widening the slot past it.
pub const content_slot = ui.paramStyle(struct { size: ControlSize, pub const declared = &[_][]const u8{ "direction", "width", "height", "align_items", "min_width", "min_height", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .direction = .row, .width = .{ .grow = .{} }, .height = .fit, .align_items = .center, .min_width = 0, .min_height = metrics(t, args.size).lineHeightPx(), }, t); } });
pub const append_slot = ui.paramStyle(struct { size: ControlSize, pub const declared = &[_][]const u8{ "direction", "width", "height", "align_items", "gap", "min_height", }; pub fn resolve(args: @This(), t: *const ui.theme.Values) ui.BoxStyle { return ui.boxFrom(.{ .direction = .row, .width = .fit, .height = .fit, .align_items = .center, .gap = metrics(t, args.size).gap, .min_height = metrics(t, args.size).lineHeightPx(), }, t); } });

/// How the icon slot sits in the frame's padding.
pub const IconFit = enum {
    /// The icon shares the text line box (Input / Select / DatePicker): icon-only is square at
    /// text-control height, a leading icon takes the narrower left padding.
    line_box,
    /// The icon is the tier's glyph (glyphSize, Button, LKxqO): the vertical padding absorbs it
    /// so the frame keeps the size tier's height; a leading glyph takes the narrower left padding
    /// and icon-only is square in every tier.
    glyph,
};

/// The Button glyph of each size tier (LKxqO).
pub fn glyphSize(size: ControlSize) f32 {
    return switch (size) {
        .xs => 12,
        .sm => 14,
        .md => 16,
        .lg => 20,
    };
}

/// Icon-to-label gap: a leading glyph sits closer than the tier's default (LKxqO).
pub fn geometryGap(t: *const theme.ThemeTokens, size: ControlSize, leading_icon: bool, icon_fit: IconFit) f32 {
    if (icon_fit != .glyph or !leading_icon) return metrics(t, size).gap;
    return switch (size) {
        .xs => t.tokens.space.space100,
        .sm, .md => t.tokens.space.space150,
        .lg => t.tokens.space.space200,
    };
}

pub fn geometryPadding(t: *const theme.ThemeTokens, size: ControlSize, icon_only: bool, leading_icon: bool, icon_fit: IconFit) Padding {
    const m = metrics(t, size);
    switch (icon_fit) {
        .line_box => {
            if (icon_only) return Padding.all(m.padding_y + (m.lineHeightPx() - m.icon_size) / 2);
            if (leading_icon) return .{ .top = m.padding_y, .right = m.padding_h, .bottom = m.padding_y, .left = m.padding_leading_icon };
        },
        .glyph => {
            const glyph = glyphSize(size);
            if (icon_only) return Padding.all(@max(0, (m.derivedHeight() - glyph) / 2));
            if (leading_icon) {
                const pad_y = @max(0, (m.derivedHeight() - @max(m.lineHeightPx(), glyph)) / 2);
                return .{ .top = pad_y, .right = t.tokens.space.space300, .bottom = pad_y, .left = if (size == .lg) t.tokens.space.space200 else 10 };
            }
        },
    }
    return Padding.symmetric(m.padding_y, m.padding_h);
}

//# yix-map styles.yss
