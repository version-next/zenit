// GENERATED FILE, do not edit: generated from styles.yss; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Per-corner overflow clip fixture styles. Every specimen clips a square-cornered red fill with
//! its own corner radii; the specimen itself paints nothing, so the rounded corners that show come
//! from the overflow clip alone.
const ui = @import("ui");

pub const root = ui.previewCss("examples/storybook/corner_clip/styles.yss", "root", @embedFile("styles.yss"), .{ .direction = .column, .gap = ui.tokenRef(.space, "space600"), });
pub const heading = ui.previewCss("examples/storybook/corner_clip/styles.yss", "heading", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "lg"), .font_weight = 600, .color = ui.tokenRef(.color, "fg-primary"), });
pub const lede = ui.previewCss("examples/storybook/corner_clip/styles.yss", "lede", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "sm"), .line_height = 1.4, .color = ui.tokenRef(.color, "fg-secondary"), });
pub const grid = ui.previewCss("examples/storybook/corner_clip/styles.yss", "grid", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .direction = .row, .gap = ui.tokenRef(.space, "space800"), .align_items = .start, });
pub const cell = ui.previewCss("examples/storybook/corner_clip/styles.yss", "cell", @embedFile("styles.yss"), .{ .direction = .column, .gap = ui.tokenRef(.space, "space200"), });
pub const caption = ui.previewCss("examples/storybook/corner_clip/styles.yss", "caption", @embedFile("styles.yss"), .{ .font_size = ui.tokenRef(.font_size, "xs"), .color = ui.tokenRef(.color, "fg-secondary"), });
pub const attached = ui.previewCss("examples/storybook/corner_clip/styles.yss", "attached", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .direction = .row, });

/// 120x64 clip owner: overflow hidden, no paint of its own.
pub const specimen = ui.previewCss("examples/storybook/corner_clip/styles.yss", "specimen", @embedFile("styles.yss"), .{ .width = 120, .height = 64, .overflow_hidden = true, .flex_shrink = 0, });
/// Attached group items: rounded outer corners, square inner ones.
pub const first = ui.previewCss("examples/storybook/corner_clip/styles.yss", "first", @embedFile("styles.yss"), .{ .width = 80, .height = 64, .overflow_hidden = true, .flex_shrink = 0, .corner_radii = ui.CornerRadius{ .each = .{ 16, 0, 0, 16 } }, });
pub const middle = ui.previewCss("examples/storybook/corner_clip/styles.yss", "middle", @embedFile("styles.yss"), .{ .width = 80, .height = 64, .overflow_hidden = true, .flex_shrink = 0, });
pub const last = ui.previewCss("examples/storybook/corner_clip/styles.yss", "last", @embedFile("styles.yss"), .{ .width = 80, .height = 64, .overflow_hidden = true, .flex_shrink = 0, .corner_radii = ui.CornerRadius{ .each = .{ 0, 16, 16, 0 } }, });

/// TL 24, TR 0, BR 10, BL 0 (asymmetric, so a corner swap or a half turn is visible).
pub const corners = ui.previewCss("examples/storybook/corner_clip/styles.yss", "corners", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 24, 0, 10, 0 } }, });
/// Opacity layer: the rounded clip folds into the composite mask.
pub const faded = ui.previewCss("examples/storybook/corner_clip/styles.yss", "faded", @embedFile("styles.yss"), .{ .opacity = 0.9, });
/// Half turn about the centre: TL lands bottom-right on screen.
pub const turned = ui.previewCss("examples/storybook/corner_clip/styles.yss", "turned", @embedFile("styles.yss"), .{ .rotate = 3.14159265, });
/// Horizontal mirror: TL lands top-right on screen.
pub const mirrored = ui.previewCss("examples/storybook/corner_clip/styles.yss", "mirrored", @embedFile("styles.yss"), .{ .scale_x = -1, });

/// Square-cornered fill exactly covering a specimen.
pub const fill = ui.previewCss("examples/storybook/corner_clip/styles.yss", "fill", @embedFile("styles.yss"), .{ .width = .fill, .height = .fill, .flex_shrink = 0, .background = ui.Color.hex(0xe5484d), });
/// Backdrop blur: the overflow clip becomes a rounded_clip surface (begin_rounded_clip).
pub const glass = ui.previewCss("examples/storybook/corner_clip/styles.yss", "glass", @embedFile("styles.yss"), .{ .glass = ui.GlassParams{ .backdrop_blur = 16, .glass_intensity = 0 }, });
/// Uniformly rounded clip around a nested specimen: an outer shape clip is active, so the inner
/// rounded_clip takes the offscreen layer path (composite mask) instead of the shader mask.
pub const outer = ui.previewCss("examples/storybook/corner_clip/styles.yss", "outer", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .padding = 8, .corner_radius = 6, .overflow_hidden = true, });

/// 100x40 clip owner for nested-chain cases (no paint of its own).
pub const band = ui.previewCss("examples/storybook/corner_clip/styles.yss", "band", @embedFile("styles.yss"), .{ .width = 100, .height = 40, .overflow_hidden = true, .flex_shrink = 0, });
pub const round20 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "round20", @embedFile("styles.yss"), .{ .corner_radius = 20, });
pub const only_tr10 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_tr10", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 10, 0, 0 } }, });
pub const only_tl20 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_tl20", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 20, 0, 0, 0 } }, });
pub const only_tr20 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_tr20", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 20, 0, 0 } }, });
pub const only_br20 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_br20", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 0, 20, 0 } }, });
pub const only_tr12 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_tr12", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 12, 0, 0 } }, });
pub const only_tr16 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_tr16", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 16, 0, 0 } }, });
pub const only_bl12 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "only_bl12", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 0, 0, 0, 12 } }, });
/// Narrower left-aligned children: their shapes cross the parent's instead of sharing its rect.
pub const w70 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "w70", @embedFile("styles.yss"), .{ .width = 70, });
pub const w80 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "w80", @embedFile("styles.yss"), .{ .width = 80, });
pub const w84 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "w84", @embedFile("styles.yss"), .{ .width = 84, });
/// Non-normal blend: the owner composites through the blend pipeline (multiply over the white
/// panel leaves the red fill unchanged).
pub const multiplied = ui.previewCss("examples/storybook/corner_clip/styles.yss", "multiplied", @embedFile("styles.yss"), .{ .blend_mode = .multiply, });
/// Pill-style oversized radius on one corner; normalises to 20 (half of 40).
pub const huge_tl = ui.previewCss("examples/storybook/corner_clip/styles.yss", "huge_tl", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ 9999, 0, 0, 0 } }, });

/// Dark backdrop behind the glass-shape specimens, so the bright glass material reads against it.
pub const backdrop = ui.previewCss("examples/storybook/corner_clip/styles.yss", "backdrop", @embedFile("styles.yss"), .{ .no_cross_stretch = true, .padding = 10, .background = ui.Color.hex(0x1b2030), .flex_shrink = 0, });
/// Bright, untextured glass material: a near-opaque white surface veil over a blurred uniform
/// backdrop, so its silhouette (not its optics) is what shows.
pub const glass_lit = ui.previewCss("examples/storybook/corner_clip/styles.yss", "glass_lit", @embedFile("styles.yss"), .{ .glass = ui.GlassParams{ .backdrop_blur = 16, .glass_tint = ui.Color.rgba(255, 255, 255, 235), .tint_mode = .surface }, });
/// A negative first corner: normalises to a square TL; TR keeps its 20pt arc.
pub const neg_tl = ui.previewCss("examples/storybook/corner_clip/styles.yss", "neg_tl", @embedFile("styles.yss"), .{ .corner_radii = ui.CornerRadius{ .each = .{ -4, 20, 0, 0 } }, });
/// Pill written as an oversized uniform radius vs. the exact capsule radius (half of 40).
pub const pill_huge = ui.previewCss("examples/storybook/corner_clip/styles.yss", "pill_huge", @embedFile("styles.yss"), .{ .corner_radius = 9999, });
pub const pill_exact = ui.previewCss("examples/storybook/corner_clip/styles.yss", "pill_exact", @embedFile("styles.yss"), .{ .corner_radius = 20, });
/// Degenerate glass owners: zero width, and thinner than any arc.
pub const sliver0 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "sliver0", @embedFile("styles.yss"), .{ .width = 0, .height = 40, .flex_shrink = 0, .corner_radius = 9999, });
pub const sliver2 = ui.previewCss("examples/storybook/corner_clip/styles.yss", "sliver2", @embedFile("styles.yss"), .{ .width = 2, .height = 40, .flex_shrink = 0, .corner_radius = 9999, });
/// Gap between the slivers so each one's footprint can be probed on the backdrop.
pub const sliver_row = ui.previewCss("examples/storybook/corner_clip/styles.yss", "sliver_row", @embedFile("styles.yss"), .{ .gap = 24, .width = 100, });

//# yix-map styles.yss
