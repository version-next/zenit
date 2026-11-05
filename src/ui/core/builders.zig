//! Top-level node-tree builder functions: `box`, `text`, `image`, `icon`,
//! `svg`, `spacer`, `grid`, `clickable`, `hstack`/`vstack`, plus the
//! `appendChildrenFromTuple` helper used by all container builders.
//!
//! Extracted from `core.zig` to keep that file focused on the `Cx` runtime.
//! These functions take `cx: anytype` (a `*core.Cx`), using anytype avoids
//! a build-time import cycle between core.zig (which re-exports the builders)
//! and this file (which would otherwise need to `@import("../core.zig")`).
//!
//! No behavior change.

const std = @import("std");
const icon_ir = @import("icon_ir");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const svg_geometry = @import("svg_geometry.zig");
const svg_assets_mod = @import("../svg_assets.zig");
const theme = @import("../theme.zig");

const Node = node_mod.Node;
const Color = types.Color;
const Style = types.Style;
const BoxStyle = types.BoxStyle;
const Sizing = types.Sizing;
const Padding = types.Padding;
const Border = types.Border;
const JustifyContent = types.JustifyContent;
const AlignItems = types.AlignItems;
const HandlerRef = types.HandlerRef;
const GridTrackSize = types.GridTrackSize;
const GridConfig = types.GridConfig;

/// Unified node creation entry, does not depend on process-level globals.
/// Node.create used g_node_create_hook + g_active_world, which with multiple Cx picks the
/// last-init'd
/// Cx, not the caller's. @hasField probes cx anytype compatibility (lean test mocks lack
/// world/world_id): falls back to the old path. Takes ownership of the style heap (StyleExt and
/// GridConfig above it): success transfers to the node, failure releases here; caller must not
/// reclaim.
fn createNode(cx: anytype, tag: types.ElementTag, style: Style) !*Node {
    const CxT = @TypeOf(cx.*);
    const created = if (@hasField(CxT, "world") and @hasField(CxT, "world_id"))
        node_mod.createIn(cx.allocator, &cx.world, cx.world_id, cx.nextId(), tag, style)
    else
        Node.create(cx.allocator, cx.nextId(), tag, style);
    return created catch |err| {
        discardStyleExt(cx.allocator, style);
        return err;
    };
}

/// Release heap part of Style not handed to node (matches node-release reclamation).
fn discardStyleExt(allocator: std.mem.Allocator, style: Style) void {
    const ext = style.ext orelse return;
    if (ext.grid) |gc| allocator.destroy(gc);
    allocator.destroy(ext);
}

/// box - generic container node
///
/// Usage:
/// ```
/// try ui.box(cx, .{ .direction = .row, .gap = 8 }, .{
///     ui.text("Hello", .{}),
///     ui.text("World", .{}),
/// });
/// ```
/// BoxStyle background/opacity (not in Style) are written via the SoA write port into
/// World.paint_state. Must be called after linkNodeToWorld so element_id is allocated and
/// setBackgroundRaw routes to World, not standalone.
pub fn applyPaintOverride(node: *Node, ov: types.BoxStyle.PaintOverride) void {
    if (ov.background) |c| node.setBackgroundRaw(c);
    if (ov.opacity) |o| node.setOpacityRaw(o);
}

fn boxWithOrigin(
    cx: anytype,
    style: BoxStyle,
    children_tuple: anytype,
    origin_address: usize,
    origin_kind: @import("world.zig").StyleOriginKind,
) !*Node {
    const resolved = try style.toStyleFallible(cx.allocator);
    const node = try createNode(cx, .box, resolved);
    // From node creation until return, subtree is orphaned: any alloc failure in
    // appendChildrenFromTuple leaks it. Downstream OOM injection at mount path cross-review
    // marked box transaction safety for verification; answer is no. Box highest-frequency
    // constructor repo-wide, fix covers large surface.
    errdefer cx.freeDetachedNodeAfterScopeDispose(node);
    cx.linkNodeToWorld(node);
    applyPaintOverride(node, style.paintOverride());
    node.recordStyleBaseOrigin(style.styleFieldMask(), origin_address, origin_kind);
    try appendChildrenFromTuple(cx, node, children_tuple);
    return node;
}

pub fn box(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    return boxWithOrigin(cx, style, children_tuple, @returnAddress(), .inline_builder);
}

// Styled builders: theme-safe named style function consumption.
//
// styles.zig convention: style is fn(*const ThemeTokens) BoxStyle pure function, evaluated once at
// mount, hooks on_theme; Cx.setTheme tree-traverses with new tokens replaying styles (applyTo +
// paint override + markLayoutDirty). Literal-style box(cx, .{...}) dead-valued after theme change;
// not so here. on_theme is not before_render hook: not per-frame, does not affect promoted render
// cache eligibility. Coverage: setTheme traverses only cx.root subtree; independent overlay tree
// outside scope.

fn boxThemeHookFor(comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle) node_mod.ThemeHook {
    return struct {
        fn hook(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
            const s = style_fn(t);
            s.applyTo(&n.style, allocator);
            applyPaintOverride(n, s.paintOverride());
            // invokeThemeHookRecursive marks render/composite only; style function may emit layout
            // fields (padding/width/font_size etc.), uniformly mark layout (theme switch rare,
            // hot-path free).
            n.markLayoutDirty();
            n.markInheritedTextDirty(.of(s));
        }
    }.hook;
}

/// boxStyled - theme-safe box: style from a named pure function, not an inline literal
///
/// Usage:
/// ```
/// // styles.zig:  pub fn card(t: *const ThemeTokens) BoxStyle { return .{ .background = t.tokens.color.bg_secondary, ... }; }
/// const node = try ui.boxStyled(cx, S.card, .{ ...children });
/// ```
pub fn boxStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const style = style_fn(cx.tokens);
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(style_fn);
    return node;
}

/// hstackStyled - theme-safe hstack (direction stays .row on replay)
pub fn hstackStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const wrapped = struct {
        fn f(t: *const theme.ThemeTokens) BoxStyle {
            var s = style_fn(t);
            s.direction = .row;
            return s;
        }
    }.f;
    var style = style_fn(cx.tokens);
    style.direction = .row;
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(wrapped);
    return node;
}

/// vstackStyled - theme-safe vstack (direction stays .column on replay)
pub fn vstackStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) BoxStyle, children_tuple: anytype) !*Node {
    const wrapped = struct {
        fn f(t: *const theme.ThemeTokens) BoxStyle {
            var s = style_fn(t);
            s.direction = .column;
            return s;
        }
    }.f;
    var style = style_fn(cx.tokens);
    style.direction = .column;
    const node = try boxWithOrigin(cx, style, children_tuple, @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = boxThemeHookFor(wrapped);
    return node;
}

fn textThemeHookFor(comptime style_fn: fn (*const theme.ThemeTokens) TextStyle) node_mod.ThemeHook {
    return struct {
        fn hook(n: *Node, t: *const theme.ThemeTokens, allocator: std.mem.Allocator) void {
            _ = allocator;
            const s = style_fn(t);
            // getText -> mutate style fields -> setText same: content pointer unchanged,
            // ContentTable.setText guard guarantees no misfire on owned content free.
            var props = n.getText() orelse return;
            _ = s.applyTo(&props);
            n.setText(props);
            n.markLayoutDirty();
        }
    }.hook;
}

/// textStyled - theme-safe text: style from `fn (*const ThemeTokens) TextStyle` pure function
pub fn textStyled(cx: anytype, comptime style_fn: fn (*const theme.ThemeTokens) TextStyle, content: []const u8) !*Node {
    const node = try textWithOrigin(cx, content, style_fn(cx.tokens), @intFromPtr(&style_fn), .styled);
    node.meta.per_frame.hooks.on_theme = textThemeHookFor(style_fn);
    return node;
}

/// hstack - horizontal layout (direction = .row)
pub fn hstack(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    var s = style;
    s.direction = .row;
    return boxWithOrigin(cx, s, children_tuple, @returnAddress(), .inline_builder);
}

/// vstack - vertical layout (direction = .column)
pub fn vstack(cx: anytype, style: BoxStyle, children_tuple: anytype) !*Node {
    var s = style;
    s.direction = .column;
    return boxWithOrigin(cx, s, children_tuple, @returnAddress(), .inline_builder);
}

/// Text node style params (named type, reused by textStyled style functions)
pub const TextStyle = struct {
    /// Bookkeeping fields set by the style machinery, never written by authors: they are not
    /// style properties (the YSS schema and its tooling skip them).
    pub const internal_fields = [_][]const u8{ "color_set", "font_size_set", "font_weight_set" };

    color: Color = theme.dark.tokens.color.fg_primary,
    /// `color` / `font_size` / `font_weight` were declared by this style (see
    /// TextProps.color_set): the ancestor's inherited value yields to a declared one.
    color_set: bool = false,
    font_size_set: bool = false,
    font_weight_set: bool = false,
    font_size: f32 = 14,
    font_weight: u16 = 400,
    /// Font family id (zenit_app.FontRegistry). 0 = default.
    font_family: u16 = 0,
    line_height: f32 = 1.4,
    wrap: types.TextWrap = .none,
    overflow_wrap: @FieldType(types.TextProps, "overflow_wrap") = .normal,
    word_break: @FieldType(types.TextProps, "word_break") = .normal,
    max_lines: u16 = 0,
    /// Per-visual-line horizontal align (see TextProps.text_align)
    text_align: types.TextAlign = .start,
    // Below fields one-to-one match TextProps (see TextProps comment)
    selectable: bool = true,
    baseline_ratio: f32 = 0,
    use_symbols_font: bool = false,
    use_monospace_font: bool = false,
    use_italic_font: bool = false,
    font_smoothing: bool = true,
    strikethrough: bool = false,
    monospace_char_width: f32 = 0,
    text_overflow: types.TextOverflow = .clip,
    fade_right: f32 = 0,

    /// Write style fields into TextProps (content/spans/owned unchanged). Field names one-to-one
    /// TextProps, new fields auto-track. Return: any fields changed.
    pub fn applyTo(self: TextStyle, props: *types.TextProps) bool {
        var changed = false;
        inline for (@import("zenit_reflection").fields(TextStyle)) |f| {
            if (!std.meta.eql(@field(props.*, f.name), @field(self, f.name))) {
                @field(props.*, f.name) = @field(self, f.name);
                changed = true;
            }
        }
        return changed;
    }
};

/// text - text node
fn textStyleFieldMask() u64 {
    return (@as(u64, 1) << @backingInt(types.StyleField.text_color)) |
        (@as(u64, 1) << @backingInt(types.StyleField.text_font_size)) |
        (@as(u64, 1) << @backingInt(types.StyleField.text_font_weight));
}

fn textWithOrigin(
    cx: anytype,
    content: []const u8,
    props: TextStyle,
    origin_address: usize,
    origin_kind: @import("world.zig").StyleOriginKind,
) !*Node {
    const node = try createNode(cx, .text, .{
        .width = if (props.wrap != .none) .{ .grow = .{} } else .{ .fit = .{} },
        .height = .{ .fit = .{} },
    });
    errdefer cx.freeNode(node);
    // Content lifetime contract: builder takes ownership, non-empty duped to node's heap copy
    // (same strategy as Node.setTextContent, freed on node destroy/text swap). Skip <=16 bytes
    // inline_buf: inline content inside text table entry, table expand relocates, component
    // borrowing `getText().content` to a11y label/live_text dangling (Component Wall real
    // segfault).
    var t = types.TextProps{};
    _ = props.applyTo(&t);
    if (content.len > 0) {
        t.content = try cx.allocator.dupe(u8, content);
        t.owned = true;
    }
    // linkNodeToWorld before setText, ensures mirror write has element_id.
    cx.linkNodeToWorld(node);
    node.setText(t);
    node.recordStyleBaseOrigin(textStyleFieldMask(), origin_address, origin_kind);
    return node;
}

pub fn text(cx: anytype, content: []const u8, props: TextStyle) !*Node {
    return textWithOrigin(cx, content, props, @returnAddress(), .inline_builder);
}

/// image - image node (texture ID)
pub fn image(cx: anytype, texture_id: u32, style: Style) !*Node {
    const node = try createNode(cx, .image, style);
    cx.linkNodeToWorld(node);
    node.setImage(.{ .texture_id = texture_id, .tint = Color.WHITE });
    try applyRegisteredImageHitGeometry(cx, node, texture_id);
    return node;
}

pub fn imageSvgHit(cx: anytype, texture_id: u32, style: Style, svg_data: []const u8) !*Node {
    const node = try image(cx, texture_id, style);
    try node.setSvgDocumentHitGeometry(cx.allocator, svg_data, .nonzero);
    (try node.style.ensureExtFallible(cx.allocator)).hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    return node;
}

/// imageTint - image node (texture ID + tint)
pub fn imageTint(cx: anytype, texture_id: u32, tint: Color, style: Style) !*Node {
    const node = try createNode(cx, .image, style);
    errdefer cx.freeNode(node);
    cx.linkNodeToWorld(node);
    node.setImage(.{ .texture_id = texture_id, .tint = tint });
    try applyRegisteredImageHitGeometry(cx, node, texture_id);
    return node;
}

pub fn imageTintSvgHit(cx: anytype, texture_id: u32, tint: Color, style: Style, svg_data: []const u8) !*Node {
    const node = try imageTint(cx, texture_id, tint, style);
    errdefer cx.freeNode(node);
    const ext = try node.style.ensureExtFallible(cx.allocator);
    try node.setSvgDocumentHitGeometry(cx.allocator, svg_data, .nonzero);
    ext.hit_shape = .{ .path = .{ .fill_rule = .nonzero } };
    return node;
}

pub fn icon(cx: anytype, asset: svg_assets_mod.Asset, style: Style) !*Node {
    return iconTint(cx, asset, Color.WHITE, style);
}

pub fn iconTint(cx: anytype, asset: svg_assets_mod.Asset, tint: Color, style: Style) !*Node {
    const logical_size = svg_geometry.resolveIconLogicalSize(asset, style);
    const rep = asset.pickRep(logical_size) orelse return svgTint(cx, asset.svg_data, tint, style);
    const icon_id = asset.icon_id orelse return svgTint(cx, asset.svg_data, tint, style);

    const node = try createNode(cx, .image, style);
    errdefer cx.freeNode(node);
    cx.linkNodeToWorld(node);
    node.setIcon(.{
        .icon_id = icon_id,
        .rep = rep,
        .tint = tint,
    });
    try applyIconHitGeometry(cx, node, rep);
    return node;
}

/// BoxStyle variant of iconTint. Unlike the legacy Style entry point this can
/// apply SoA paint fields such as opacity at construction time.
pub fn iconTintStyled(cx: anytype, asset: svg_assets_mod.Asset, tint: Color, style: BoxStyle) !*Node {
    // Style heap part to iconTint -> createNode (fail: it recycles)
    const node = try iconTint(cx, asset, tint, try style.toStyleFallible(cx.allocator));
    applyPaintOverride(node, style.paintOverride());
    return node;
}

/// BoxStyle imageTint (texture image); style heap to createNode.
pub fn imageTintStyled(cx: anytype, texture_id: u32, tint: Color, style: BoxStyle) !*Node {
    const node = try imageTint(cx, texture_id, tint, try style.toStyleFallible(cx.allocator));
    applyPaintOverride(node, style.paintOverride());
    return node;
}

pub fn iconStyled(cx: anytype, asset: svg_assets_mod.Asset, style: BoxStyle) !*Node {
    return iconTintStyled(cx, asset, Color.WHITE, style);
}

pub fn svg(cx: anytype, svg_data: []const u8, style: Style) !*Node {
    const raster_size = svg_geometry.resolveSvgRasterSize(cx.window_scale, svg_data, style);
    // style heap to this builder (see createNode): texture load fail before node create
    // still recycles
    const texture_id = cx.svg_textures.load(svg_data, raster_size[0], raster_size[1]) catch |err| {
        discardStyleExt(cx.allocator, style);
        return err;
    };
    return imageSvgHit(cx, texture_id, style, svg_data);
}

pub fn svgTint(cx: anytype, svg_data: []const u8, tint: Color, style: Style) !*Node {
    const raster_size = svg_geometry.resolveSvgRasterSize(cx.window_scale, svg_data, style);
    // style heap to this builder (see createNode): texture load fail before node create
    // still recycles
    const texture_id = cx.svg_textures.load(svg_data, raster_size[0], raster_size[1]) catch |err| {
        discardStyleExt(cx.allocator, style);
        return err;
    };
    return imageTintSvgHit(cx, texture_id, tint, style, svg_data);
}

fn applyRegisteredImageHitGeometry(cx: anytype, node: *Node, texture_id: u32) !void {
    const geometry = cx.svg_textures.lookupHit(texture_id) orelse return;
    const ext = try node.style.ensureExtFallible(cx.allocator);
    try node.setClonedPathGeometry(cx.allocator, geometry);
    ext.hit_shape = .{ .path = .{ .fill_rule = geometry.fill_rule } };
}

fn applyIconHitGeometry(cx: anytype, node: *Node, rep: icon_ir.Rep) !void {
    const ext = try node.style.ensureExtFallible(cx.allocator);
    var geometry = try svg_geometry.createIconPathGeometry(cx.allocator, rep);
    errdefer node_mod.freePathGeometry(cx.allocator, &geometry);
    const fill_rule = geometry.fill_rule;
    try node.setClonedPathGeometry(cx.allocator, geometry);
    node_mod.freePathGeometry(cx.allocator, &geometry);
    ext.hit_shape = .{ .path = .{ .fill_rule = switch (fill_rule) {
        .nonzero => .nonzero,
        .evenodd => .evenodd,
    } } };
}

/// spacer - elastic whitespace (fill available)
pub fn spacer(cx: anytype) !*Node {
    return createNode(cx, .spacer, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    });
}

/// anchor - control flow region boundary mark (see `ElementTag.anchor`). display:none +
/// zero size: layout/gap/hit/a11y all skip, takes one slot in children only.
pub fn anchor(cx: anytype) !*Node {
    const node = try createNode(cx, .anchor, .{
        .width = .{ .px = 0 },
        .height = .{ .px = 0 },
        .display = .none,
    });
    cx.linkNodeToWorld(node);
    return node;
}

/// Grid container style config
pub const GridStyle = struct {
    columns: []const GridTrackSize = &.{},
    rows: []const GridTrackSize = &.{},
    column_gap: f32 = 0,
    row_gap: f32 = 0,

    // Common Style field pass-through
    background: Color = Color.TRANSPARENT,
    padding: Padding = Padding.ZERO,
    width: Sizing = .{ .grow = .{} },
    height: Sizing = .{ .grow = .{} },
    justify: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    overflow_hidden: bool = false,
    border: Border = .{},
    corner_radius: ?types.CornerRadius = null,
    margin: Padding = Padding.ZERO,
    /// Complete margin decl (supports auto). If set, overrides margin.
    margin_spec: ?types.Margin = null,
};

/// grid - Grid container (CSS Grid layout)
pub fn grid(cx: anytype, config: GridStyle, children_tuple: anytype) !*Node {
    var style = Style{
        .padding = config.padding,
        .width = config.width,
        .height = config.height,
        .justify = config.justify,
        .align_items = config.align_items,
        .overflow_hidden = config.overflow_hidden,
        .border = config.border,
        .margin = config.margin,
    };
    // Before createNode style heap: any step fail = recycle here
    var style_owned = true;
    errdefer if (style_owned) discardStyleExt(cx.allocator, style);
    if (config.margin_spec) |v| {
        try style.setMarginSpecFallible(cx.allocator, v);
    }
    if (config.corner_radius) |cr| {
        (try style.ensureExtFallible(cx.allocator)).corner_radius = cr;
    }

    const gc = try cx.allocator.create(GridConfig);
    gc.* = .{
        .column_gap = config.column_gap,
        .row_gap = config.row_gap,
    };

    const ncols: u8 = @intCast(@min(config.columns.len, GridConfig.MAX_TRACKS));
    for (0..ncols) |i| {
        gc.columns[i] = config.columns[i];
    }
    gc.column_count = ncols;

    const nrows: u8 = @intCast(@min(config.rows.len, GridConfig.MAX_TRACKS));
    for (0..nrows) |i| {
        gc.rows[i] = config.rows[i];
    }
    gc.row_count = nrows;

    const ext = style.ensureExtFallible(cx.allocator) catch |err| {
        cx.allocator.destroy(gc);
        return err;
    };
    ext.grid = gc;

    style_owned = false; // createNode takes over (fail: it recycles)
    const node = try createNode(cx, .box, style);
    errdefer cx.freeDetachedNodeAfterScopeDispose(node);
    cx.linkNodeToWorld(node);
    if (config.background.a != 0) node.setBackgroundRaw(config.background);
    try appendChildrenFromTuple(cx, node, children_tuple);
    return node;
}

/// clickable - add click event to any node
pub fn clickable(node: *Node, on_click: HandlerRef) *Node {
    node.behavior.events.on_click = on_click;
    return node;
}

/// Expand comptime children tuple to Node children. Tuple elements can be:
///   - *Node: direct add
///   - struct with render(*Cx) !*Node: call render()
///   - ?*Node: optional node (null skip)
pub fn appendChildrenFromTuple(cx: anytype, parent: *Node, children_tuple: anytype) !void {
    const T = @TypeOf(children_tuple);
    const fields = @import("zenit_reflection").fields(T);

    inline for (fields) |field| {
        const child = @field(children_tuple, field.name);
        try appendSingleChild(cx, parent, child);
    }
}

fn appendSingleChild(cx: anytype, parent: *Node, child: anytype) !void {
    const T = @TypeOf(child);

    // null literal - skip (conditional rendering)
    if (T == @TypeOf(null)) {
        return;
    }

    // *Node - direct add
    if (T == *Node) {
        try parent.appendChild(cx.allocator, child);
        return;
    }

    // ?*Node - conditional render
    if (T == ?*Node) {
        if (child) |c| {
            try parent.appendChild(cx.allocator, c);
        }
        return;
    }

    // Component protocol: struct with render(self, *Cx) !*Node
    if (@typeInfo(T) == .@"struct") {
        if (@hasDecl(T, "render")) {
            const node = try child.render(cx);
            try parent.appendChild(cx.allocator, node);
            return;
        }
    }

    @compileError("Unsupported child type: " ++ @typeName(T) ++
        ". Expected *Node, ?*Node, null, or a struct with pub fn render(self, *Cx) !*Node");
}
