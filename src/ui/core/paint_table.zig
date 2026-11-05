//! PaintTable + PaintChunk: retained rendering artifacts split out of Node.
//!
//! Each element holds one PaintChunk:
//!   - display_items[]: high-level semantic paint items (rect / text / image / path / shadow)
//!   - property_state_ref: (transform_id, clip_id, effect_id, scroll_id) u32 refs into PropertyTree
//!   - bounds: world-space AABB (for culling / hit broad-phase)
//!   - content_hash: content-stable hash; on hit, skip recording and reuse previous display_items
//!
//! Design:
//! - chunk is retained across frames; regenerated only on content_hash mismatch
//! - no GPU resources held (those go to ResourcePool); chunk is CPU-side IR only
//! - paint_epoch and layout_epoch are decoupled: color change bumps paint_epoch only
//!
//! Layers group by chunk and track damage rect.

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const types = @import("types.zig");
const display_list_mod = @import("display_list.zig");
const icon_ir = @import("icon_ir");

pub const ElementId = element_id_mod.ElementId;

/// Property tree references: four u32 indices into 4 PropertyTree trees.
/// INVALID_ID = no reference on this axis (inherit from parent).
pub const PropertyStateRef = packed struct(u128) {
    transform_id: u32 = std.math.maxInt(u32),
    clip_id: u32 = std.math.maxInt(u32),
    effect_id: u32 = std.math.maxInt(u32),
    scroll_id: u32 = std.math.maxInt(u32),

    pub const NONE: PropertyStateRef = .{};
};

/// World-space bounds (post-transformed AABB)
pub const Bounds = struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    pub const ZERO: Bounds = .{};

    pub fn isEmpty(self: Bounds) bool {
        return self.max_x <= self.min_x or self.max_y <= self.min_y;
    }

    pub fn unionWith(a: Bounds, b: Bounds) Bounds {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }
};

/// High-level display item category. Currently lists basic types; add more as needed during paint
/// pass transitions.
pub const DisplayItemKind = enum(u8) {
    /// Placeholder (for chunk creation)
    none,
    /// Solid rect (with corner radius)
    rect,
    /// Text run
    text,
    /// Image / SVG icon
    image,
    /// Path fill
    path,
    /// Shadow
    shadow,
    /// Gradient fill
    gradient,
    /// effect/clip control token (begin/end_opacity/blur/rounded_clip + push/pop_clip)
    control,
};

/// Control sub-kind (B-7-C): distinguishes 8 token types when DisplayItemKind == .control.
/// .none for non-control items (paint kind).
pub const ControlKind = enum(u8) {
    none = 0,
    push_clip = 1,
    pop_clip = 2,
    begin_opacity_layer = 3,
    end_opacity_layer = 4,
    begin_blur_layer = 5,
    end_blur_layer = 6,
    begin_rounded_clip = 7,
    end_rounded_clip = 8,
};

/// fill_rect kind geometric payload (x,y,w,h packed). 32-bit f16 quantized saves space, but
/// currently use f32 for simplicity; quantize later when truly managing batch.
pub const RectGeom = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// 4-corner radius (TL/TR/BR/BL)
pub const CornerRadii = struct {
    tl: f32 = 0,
    tr: f32 = 0,
    br: f32 = 0,
    bl: f32 = 0,

    /// Convert to [4]f32 order TL/TR/BR/BL, format directly consumed by
    /// sdf_renderer.addRoundedRect. No conversion needed when encoder switches to paint_table.
    pub fn toArray(self: CornerRadii) [4]f32 {
        return .{ self.tl, self.tr, self.br, self.bl };
    }

    pub fn fromArray(arr: [4]f32) CornerRadii {
        return .{ .tl = arr[0], .tr = arr[1], .br = arr[2], .bl = arr[3] };
    }
};

/// RGBA8 packed color (same layout as types.Color but module doesn't depend on types)
pub const RGBA = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    /// Convert to normalized [4]f32 for GPU shader (linear RGB convention). Direct to sdf_renderer
    /// when encoder switches to paint_table.
    pub fn toFloat4(self: RGBA) [4]f32 {
        const inv: f32 = 1.0 / 255.0;
        return .{
            @as(f32, @floatFromInt(self.r)) * inv,
            @as(f32, @floatFromInt(self.g)) * inv,
            @as(f32, @floatFromInt(self.b)) * inv,
            @as(f32, @floatFromInt(self.a)) * inv,
        };
    }

    /// Convert to types.Color (same r/g/b/a u8 fields, consistent order -> bitcast equivalent but
    /// explicit field copy clearer, lets caller use Color.eql/Color.rgba etc APIs). For tests
    /// fixture.
    pub fn toColor(self: RGBA) types.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

/// High-level display item, draw description.
///
/// Strongly-typed fields (geom + color + radii) let the shadow path verify content
/// equivalence; the backend consumes DisplayItem directly with no data loss.
///
/// Kind-specific fields:
/// - stroke_rect: stroke_width
/// - shadow_rect: shadow_blur + shadow_offset_x/y
/// - border_per_side: border_widths [4]f32
/// - image_quad: image_opacity
///
/// Later stages add gradient (to_color/direction/extend_mode) / text
/// (font_size/weight/italic/spans) / path / icon fields.
pub const DisplayItem = struct {
    kind: DisplayItemKind,
    /// Content fingerprint of this lowered item (0 = unknown: consumers hash
    /// the item themselves). Equal across frames only if every pixel the
    /// item paints is equal: the recorded item's ItemHeader.local_fp, the
    /// transform it was lowered through and the text resolved for it.
    paint_digest: u64 = 0,
    /// Item's AABB in element local space (for intra-chunk clipping / partial repaint)
    local_bounds: Bounds = .{},
    /// Resource handle (texture / glyph atlas / path geometry buffer etc), u64 type-erased. Phase 4
    /// integration with ResourcePool replaces with strongly-typed ResourceHandle.
    resource_handle: u64 = 0,
    /// Geometry (rect kind uses x/y/w/h; other kinds currently 0)
    geom: RectGeom = .{},
    /// Primary color (rect/stroke/shadow/text)
    color: RGBA = .{},
    /// Corner radius (rect/stroke)
    radii: CornerRadii = .{},

    // ── kind-specific extension fields (B-5+) ──
    /// stroke / outline line width (stroke_rect, outline_rect, border_side)
    stroke_width: f32 = 0,
    /// border_per_side: top/right/bottom/left per-side widths
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    /// shadow_rect: blur radius
    shadow_blur: f32 = 0,
    /// shadow_rect: shadow offset x
    shadow_offset_x: f32 = 0,
    /// shadow_rect: shadow offset y
    shadow_offset_y: f32 = 0,
    /// shadow_rect: CSS spread
    shadow_spread: f32 = 0,
    /// image_quad: opacity (0..1)
    image_opacity: f32 = 1,
    // -- gradient_rect only --
    /// gradient: end color (color field is start from)
    gradient_to_color: RGBA = .{},
    /// gradient: direction enum representation (same order as types.GradientDirection).
    /// 0=horizontal 1=vertical 2=diagonal 3=radial 4=conic
    gradient_direction: u8 = 1,
    /// gradient: extend mode (same order as types.GradientExtendMode). 0=pad 1=repeat 2=reflect
    gradient_extend_mode: u8 = 0,
    /// radial gradient: center x offset (relative to geometry center, 0..1 normalized)
    gradient_radial_center_x: f32 = 0,
    /// radial gradient: center y offset (relative to geometry center, 0..1 normalized)
    gradient_radial_center_y: f32 = 0,
    /// radial ellipse radius (UV units; 0.5 = inscribed, old behavior)
    gradient_radial_radius_x: f32 = 0.5,
    gradient_radial_radius_y: f32 = 0.5,
    /// conic gradient: start angle (radians)
    gradient_conic_start_angle: f32 = 0,
    // -- text_run only --
    /// text logical font size (not multiplied by scale)
    text_font_size: f32 = 0,
    /// text weight (400 = regular, 700 = bold)
    text_font_weight: u16 = 400,
    /// text font family id (render.FontRegistry). 0 = default family.
    text_font_family: u16 = 0,
    /// text font flags packed: bit 0 = italic, bit 1 = monospace, bit 2 = symbols
    text_font_flags: u8 = 0,
    /// monospace character width (0 = non-monospace or auto)
    text_monospace_char_width: f32 = 0,
    /// blob byte range start (for sub-string render)
    text_blob_byte_start: u32 = 0,
    /// blob byte range end (exclusive)
    text_blob_byte_end: u32 = 0,
    /// text_run.content (lifetime guaranteed by display_list / TextLayoutBlob)
    text_content: []const u8 = "",
    /// text_run.spans (?[]const TextSpan), null means no span coloring
    text_spans: ?[]const types.TextSpan = null,
    /// text_run.raster_policy wire value (one-to-one with text_blob.TextRasterPolicy): 0 =
    /// static_crisp (default), 1 = animated_stable/direct_animated, 2 = surface_cached. The encoder
    /// consumes it with an exhaustive switch; never collapse it into a boolean.
    text_raster_policy: u8 = 0,
    /// text_run right-edge fade-out mask window (offset relative to geom.x; 0/0 = disabled)
    text_fade_dx0: f32 = 0,
    text_fade_dx1: f32 = 0,
    // -- noise_rect only (B-7-B first cut: push paint_table main path cover noise) --
    /// noise mode (0=none 1=value 2=film_grain, same order as types.NoiseMode)
    noise_mode: u8 = 0,
    /// noise scale (unit: pixels per cell)
    noise_scale: f32 = 0,
    /// noise intensity (0..1). dispatchCommand .rect arm uses > 0 to detect noise path, default
    /// must be 0; non-noise_rect .rect kind items can't have nonzero intensity (B-7 main-path
    /// switch bug)
    noise_intensity: f32 = 0,
    /// noise PRNG seed
    noise_seed: u8 = 0,
    // -- multi_gradient_rect only (B-7-D) --
    /// 16 stop color array (same capacity as display_list union)
    mg_stop_colors: [16]RGBA = @as([16]RGBA, @splat(.{})),
    /// 16 stop positions (0..1 normalized)
    mg_stop_positions: [16]f32 = @as([16]f32, @splat(0)),
    /// actual stop count (<=16)
    mg_stop_count: u8 = 0,
    // -- icon_rep / fill_path / stroke_path only (B-7-D) --
    /// icon_rep: *const icon_ir.Rep.
    icon_rep_ptr: ?*const icon_ir.Rep = null,
    /// fill_path / stroke_path: *const types.PathGeometry
    path_geometry_ptr: ?*const types.PathGeometry = null,
    /// push_clip(polygon): *const display_list_mod.ClipPolygon
    clip_polygon_ptr: ?*const display_list_mod.ClipPolygon = null,
    /// begin_blur_layer.glass: *const types.ResolvedGlassParams
    glass_ptr: ?*const types.ResolvedGlassParams = null,
    /// glass owner node id (stable key for brightness region slot)
    glass_owner_id: u32 = std.math.maxInt(u32),
    /// rotate angle (image_quad/icon_rep) - radians
    rotate: f32 = 0,
    /// stroke_path: line join (same order as types.LineJoin). 0=miter 1=bevel 2=round
    path_line_join: u8 = 0,
    /// icon_rep: corner clip radius
    icon_corner_clip_radius: f32 = 0,
    /// icon_rep: tint color
    icon_tint: RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    /// icon_rep: rep_size (px hint)
    icon_rep_size: u8 = 0,
    /// icon_rep: snap the quad to device pixels (static icon)
    icon_snap: bool = true,
    /// image_quad: tint color (parallel to icon_tint; separate to avoid ambiguity)
    image_tint: RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    /// image_quad: corner_radius (differs from radii, image_quad union field is single f32)
    image_corner_radius: f32 = 0,
    // -- inset_shadow_rect / shadow_dual_rect only (B-7-E) --
    /// shadow_dual / inset_shadow secondary shadow color (shadow_dual.shadow1_color,
    /// inset_shadow.shadow_color). Primary color field reserves fill color; secondary is shadow
    /// color, analogous to gradient_to_color but semantically independent to avoid aliasing.
    shadow_secondary_color: RGBA = .{},
    /// shadow_dual second shadow color
    shadow2_color: RGBA = .{},
    /// shadow_dual second shadow blur
    shadow2_blur: f32 = 0,
    /// shadow_dual second shadow offset x
    shadow2_offset_x: f32 = 0,
    /// shadow_dual second shadow offset y
    shadow2_offset_y: f32 = 0,
    // -- arc only (B-7-E) --
    /// arc start angle (radians)
    arc_start_angle: f32 = 0,
    /// arc end angle (radians)
    arc_end_angle: f32 = 0,
    /// arc outer radius (geom.x/y store center; w/h store 0; radius stored separately to avoid
    /// ambiguity)
    arc_outer_radius: f32 = 0,
    // -- control kind only (B-7-C) --
    /// Distinguishes 8 token types when kind == .control; .none during paint kind.
    control_kind: ControlKind = .none,
    /// begin_opacity_layer.opacity / begin_*.draw_w/h etc share this field. Usually 0;
    /// begin_opacity_layer writes opacity (rect kind also shares).
    opacity: f32 = 0,
    /// Draw shape (fill_rect/stroke_rect): 0 = rounded_rect, 1 = ellipse. Same order as
    /// types.ShapeSpec. **not** clip_shape_kind, which is clip mask, clips content not stroke; this
    /// swaps the distance field of fill and stroke themselves.
    shape_kind: u8 = 0,
    /// push_clip.shape_kind (rect/rounded_rect/ellipse/polygon); 0 = rect.
    /// Same order as display_list.ClipShapeKind.
    clip_shape_kind: u8 = 0,
    /// begin_opacity_layer.blend_mode (same order as types.BlendMode; 0 = normal)
    blend_mode: u8 = 0,
    /// begin_opacity_layer.warp (see types.ContentWarp)
    warp: [4]f32 = .{ 0, 0, 0, 0 },
    /// draw_x/y/w/h for begin_opacity / begin_blur / begin_rounded_clip.
    /// NaN defaults align with union fields (caller uses isNan to distinguish).
    draw_x: f32 = 0,
    draw_y: f32 = 0,
    draw_w: f32 = 0,
    draw_h: f32 = 0,
    /// GPU retained cache key for begin_opacity_layer (see same-named field in
    /// display_list). surface_stable_id = stable layer identity across frames;
    /// INVALID_SURFACE_ID = skip retained (redraw every frame);
    /// surface_content_version = content version.
    surface_stable_id: u32 = display_list_mod.INVALID_SURFACE_ID,
    surface_content_version: u32 = 0,
    /// use_draw_transform flag + draw_transform[6] affine matrix.
    use_draw_transform: bool = false,
    draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    /// begin_* surfaces: draw_transform's translation at rest (layer_tree
    /// CompositedLayer.surface_rest_origin); null = unknown.
    surface_rest_origin: ?[2]f32 = null,
    // Complex control payloads (push_clip.polygon / begin_blur_layer.glass) not
    // inlined; use extra_ptr to pass source union variant pointers. lowerDisplayItem
    // writes the payload pointer; dispatch casts it back to read polygon/glass fields.
    // Lifetime guaranteed by caller (display_list stable across frames).

    /// Test fixture-friendly helpers (used during v0.5 sec 5 GpuDraw test refactor):
    /// allow fixtures to be written as directly as union patterns like .text_run /
    /// .fill_rect / .push_clip, without spelling out kind/control_kind combinations.
    pub fn isFillRect(self: DisplayItem) bool {
        return self.kind == .rect and self.stroke_width == 0;
    }
    pub fn isStrokeRect(self: DisplayItem) bool {
        return self.kind == .rect and self.stroke_width > 0;
    }
    pub fn isText(self: DisplayItem) bool {
        return self.kind == .text;
    }
    pub fn isShadow(self: DisplayItem) bool {
        return self.kind == .shadow;
    }
    pub fn isGradient(self: DisplayItem) bool {
        return self.kind == .gradient;
    }
    pub fn isImage(self: DisplayItem) bool {
        return self.kind == .image;
    }
    pub fn isControl(self: DisplayItem, ck: ControlKind) bool {
        return self.kind == .control and self.control_kind == ck;
    }
};

pub const TextFontFlag = struct {
    pub const italic: u8 = 1;
    pub const monospace: u8 = 2;
    pub const symbols: u8 = 4;
    /// Rasterize without platform font smoothing (TextProps.font_smoothing = false)
    pub const no_smoothing: u8 = 8;
};

/// Paint chunk for a single element.
pub const PaintChunk = struct {
    /// Display items involved in the chunk.
    display_items: std.ArrayListUnmanaged(DisplayItem),
    /// References 4 tree states from PropertyTree.
    property_state: PropertyStateRef = .NONE,
    /// World-space bounds (envelope of all display_items).
    bounds: Bounds = .ZERO,
    /// Content hash; comparing with previous value determines if re-recording is needed.
    content_hash: u64 = 0,
    /// paint_epoch: incremented on each re-record; layer cache uses it to detect
    /// invalidation.
    paint_epoch: u64 = 0,

    pub fn deinit(self: *PaintChunk, allocator: std.mem.Allocator) void {
        self.display_items.deinit(allocator);
    }

    pub fn clear(self: *PaintChunk) void {
        self.display_items.clearRetainingCapacity();
        self.bounds = .ZERO;
    }
};

pub const PaintTable = struct {
    allocator: std.mem.Allocator,
    /// dense by ElementId.index
    chunks: std.ArrayListUnmanaged(PaintChunk),

    pub fn init(allocator: std.mem.Allocator) PaintTable {
        return .{ .allocator = allocator, .chunks = .empty };
    }

    pub fn deinit(self: *PaintTable) void {
        for (self.chunks.items) |*c| c.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureSlot(self: *PaintTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.chunks.items.len <= idx) {
            try self.chunks.append(self.allocator, .{ .display_items = .empty });
        }
    }

    pub fn get(self: *PaintTable, id: ElementId) ?*PaintChunk {
        if (id.isNull() or id.index >= self.chunks.items.len) return null;
        return &self.chunks.items[id.index];
    }

    /// Called on element destruction: free display_items memory and reset chunk to
    /// 'never recorded'. Slot retained (dense by index) but content must be cleared;
    /// otherwise: 1) long-lived windows with repeated mount/unmount only grow heap; 2)
    /// slot reuse collision: if new owner's content_hash matches old, cache-hit emits
    /// previous owner's display_items unchanged (cross-talk); 3) downstream
    /// property_state scan: stale effect references from dead elements participate in
    /// layer promotion decisions.
    pub fn release(self: *PaintTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        chunk.display_items.clearAndFree(self.allocator);
        chunk.bounds = .ZERO;
        chunk.content_hash = 0;
        chunk.paint_epoch = 0;
        chunk.property_state = .NONE;
    }

    pub fn epoch(self: *const PaintTable, id: ElementId) u64 {
        if (id.isNull() or id.index >= self.chunks.items.len) return 0;
        return self.chunks.items[id.index].paint_epoch;
    }

    /// Mirror path (Cx.ensureWorldTablesSynced): the chunk's items are always replaced,
    /// because they come from the last render's display list while the hash is taken from
    /// the node as it is *now*. Skipping the copy on a hash hit could pair a hash computed
    /// after a post-render edit with items from before it, and the next mirror would then
    /// hit on that hash and keep the stale items forever. The hash only decides whether
    /// this counts as a content change (`mirrorEnd` bumps paint_epoch). Returns that.
    pub fn mirrorBegin(self: *PaintTable, id: ElementId, content_hash: u64) !bool {
        try self.ensureSlot(id);
        const chunk = &self.chunks.items[id.index];
        const changed = chunk.paint_epoch == 0 or chunk.content_hash != content_hash;
        chunk.clear();
        chunk.content_hash = content_hash;
        return changed;
    }

    pub fn mirrorEnd(self: *PaintTable, id: ElementId, prop_ref: PropertyStateRef, changed: bool) void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        chunk.property_state = prop_ref;
        if (changed) chunk.paint_epoch +%= 1;
    }

    /// Re-record chunk only if content_hash differs; then clear and re-record.
    /// Returns true if actually re-recorded; false if hash cache-hit.
    pub fn beginRecord(self: *PaintTable, id: ElementId, new_content_hash: u64) !bool {
        try self.ensureSlot(id);
        const chunk = &self.chunks.items[id.index];
        if (chunk.content_hash == new_content_hash and chunk.paint_epoch != 0) {
            return false; // cache hit
        }
        chunk.clear();
        chunk.content_hash = new_content_hash;
        return true;
    }

    pub fn pushItem(self: *PaintTable, id: ElementId, item: DisplayItem) !void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        try chunk.display_items.append(self.allocator, item);
        chunk.bounds = chunk.bounds.unionWith(item.local_bounds);
    }

    pub fn endRecord(self: *PaintTable, id: ElementId, prop_ref: PropertyStateRef) void {
        if (id.isNull() or id.index >= self.chunks.items.len) return;
        const chunk = &self.chunks.items[id.index];
        chunk.property_state = prop_ref;
        chunk.paint_epoch +%= 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PaintTable: ensureSlot / get / epoch" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try t.ensureSlot(id);
    const chunk = t.get(id).?;
    try testing.expectEqual(@as(u64, 0), chunk.paint_epoch);
    try testing.expectEqual(@as(u64, 0), t.epoch(id));
}

test "PaintTable: beginRecord on different hash bumps epoch + clears items" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();
    const id: ElementId = .{ .index = 0, .generation = 0 };

    // First recording
    try testing.expect(try t.beginRecord(id, 0xAAAA));
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 } });
    t.endRecord(id, .NONE);

    const epoch1 = t.epoch(id);
    try testing.expect(epoch1 > 0);
    try testing.expectEqual(@as(usize, 1), t.get(id).?.display_items.items.len);

    // Same hash -> do not re-record
    try testing.expect(!(try t.beginRecord(id, 0xAAAA)));
    try testing.expectEqual(epoch1, t.epoch(id));
    try testing.expectEqual(@as(usize, 1), t.get(id).?.display_items.items.len);

    // Different hash -> re-record
    try testing.expect(try t.beginRecord(id, 0xBBBB));
    try testing.expectEqual(@as(usize, 0), t.get(id).?.display_items.items.len); // cleared
    try t.pushItem(id, .{ .kind = .text, .local_bounds = .{} });
    t.endRecord(id, .NONE);
    try testing.expect(t.epoch(id) > epoch1);
}

test "PaintTable: bounds union accumulates" {
    var t = PaintTable.init(testing.allocator);
    defer t.deinit();
    const id: ElementId = .{ .index = 0, .generation = 0 };

    _ = try t.beginRecord(id, 1);
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 } });
    try t.pushItem(id, .{ .kind = .rect, .local_bounds = .{ .min_x = 50, .min_y = 30, .max_x = 200, .max_y = 80 } });
    t.endRecord(id, .NONE);

    const chunk = t.get(id).?;
    try testing.expectEqual(@as(f32, 0), chunk.bounds.min_x);
    try testing.expectEqual(@as(f32, 0), chunk.bounds.min_y);
    try testing.expectEqual(@as(f32, 200), chunk.bounds.max_x);
    try testing.expectEqual(@as(f32, 80), chunk.bounds.max_y);
}

test "PropertyStateRef is exactly 16 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(PropertyStateRef));
}

test "Bounds: unionWith with empty" {
    const empty: Bounds = .{};
    const real: Bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 50 };
    try testing.expectEqual(real, empty.unionWith(real));
    try testing.expectEqual(real, real.unionWith(empty));
}

test "RGBA.toFloat4: roundtrip" {
    const c: RGBA = .{ .r = 255, .g = 128, .b = 0, .a = 255 };
    const f = c.toFloat4();
    try testing.expectEqual(@as(f32, 1.0), f[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5019608), f[1], 0.001);
    try testing.expectEqual(@as(f32, 0.0), f[2]);
    try testing.expectEqual(@as(f32, 1.0), f[3]);
}

test "CornerRadii.toArray + fromArray: roundtrip" {
    const r = CornerRadii.fromArray(.{ 4, 8, 16, 0 });
    try testing.expectEqual(@as(f32, 4), r.tl);
    try testing.expectEqual(@as(f32, 8), r.tr);
    try testing.expectEqual(@as(f32, 16), r.br);
    try testing.expectEqual(@as(f32, 0), r.bl);
    const arr = r.toArray();
    try testing.expectEqual([4]f32{ 4, 8, 16, 0 }, arr);
}

comptime {
    // GPU retained sentinel: three locations must align: display_list (producer),
    // paint_table (this file, transport), render/opacity_layer + offscreen_texture (consumer;
    // comptime assertions cross-lock those two). Consumer in render module cannot reverse-import,
    // so sentinel value pinned here to lock producer/transport sides.
    std.debug.assert(display_list_mod.INVALID_SURFACE_ID == std.math.maxInt(u32));
}
