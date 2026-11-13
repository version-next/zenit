/// RenderCommandEncoder - unified encoder from UI DisplayItem to GPU calls.
///
/// Efficiently encodes the lowered DisplayItem slices produced by the UI framework into
/// SdfRenderer and TextRenderer batch calls.
///
/// usage:
/// ```
/// var encoder = RenderCommandEncoder.init(&sdf_renderer, &text_renderer);
/// encoder.beginFrame(width, height, scale);
/// _ = cx.render();
/// try encoder.encodeDisplay(cx);
/// try encoder.flush(&render_pass);
/// ```
const std = @import("std");
const text_policy = @import("text_render_policy.zig");

/// Stale texture handle: drop this frame only. Throwing would abort frame encoding, losing all
/// subsequent content.
pub fn addImageOrSkip(ir: *ImageRenderer, handle: u64, x: f32, y: f32, w: f32, h: f32, tint: [4]f32, corner_radius: f32, opacity: f32, rotate: f32) !void {
    ir.addImageUV(@intCast(handle), x, y, w, h, .{ 0, 0, 1, 1 }, tint, corner_radius, opacity, rotate) catch |err| switch (err) {
        error.UnknownTexture => logUnknownTextureOnce(handle),
        else => return err,
    };
}

/// Paint-table corner radii (`.tl/.tr/.br/.bl`, duck-typed for test mocks) as TL, TR, BR, BL.
inline fn cornerRadiiArray(r: anytype) [4]f32 {
    return .{ r.tl, r.tr, r.br, r.bl };
}

/// Largest corner: a rounded clip/mask exists when any corner is rounded (attached group items
/// round only their outer corners, so the top-left alone is not representative).
inline fn maxCornerRadius(r: anytype) f32 {
    return @max(@max(r.tl, r.tr), @max(r.br, r.bl));
}

/// Same stale handle every frame: log only on change, avoid spam and silence.
var last_unknown_texture: u64 = 0;
fn logUnknownTextureOnce(handle: anytype) void {
    const h: u64 = @intCast(handle);
    if (h == last_unknown_texture) return;
    last_unknown_texture = h;
    std.log.scoped(.command_encoder).warn("image skipped: unknown texture handle {d}", .{h});
}
const gpu = @import("gpu");
// Pure function clusters (damage bounds / content fingerprint / struct folding) extracted; see file
// head contract.
const paint_fp = @import("command_encoder/paint_fingerprint.zig");
const retained_plan = @import("command_encoder/retained_plan.zig");
const lsort = @import("command_encoder/local_sort.zig");
const wire_types = @import("command_encoder/wire_types.zig");
const script_detect = @import("command_encoder/script_detect.zig");
const clip_geometry = @import("command_encoder/clip_geometry.zig");
const shape_clip_pair = @import("shape_clip_pair.zig");
const corner_radii = @import("zenit_corner_radii");
// local-sort cluster state machine extracted: encoder's nested struct now borrows from
// same-directory module; capacity constants follow.
const cluster_mod = @import("command_encoder/local_sort_cluster.zig");
const LocalSortCluster = cluster_mod.LocalSortCluster;
const LocalSortRejectReason = cluster_mod.RejectReason;
// Pixel-domain conversion functions extracted: finitePixelCoordinate / physicalPixelExtent /
// max_safe_pixel_coordinate share 2^24 clamping semantics with backdrop_capture.zig; both import
// from
// shared zero-dependency module.
const pixel_domain = @import("command_encoder/pixel_domain.zig");
pub const finitePixelCoordinate = pixel_domain.finitePixelCoordinate;
pub const physicalPixelExtent = pixel_domain.physicalPixelExtent;
pub const max_safe_pixel_coordinate = pixel_domain.max_safe_pixel_coordinate;
// backdrop capture region parsing extracted: computeBackdropCaptureRegion was already a static
// encoder function (no self); re-export here preserves backdrop_blur's reflective call site
// (TypeOf(encoder.*).computeBackdropCaptureRegion(...)) with zero changes.
const backdrop_capture = @import("command_encoder/backdrop_capture.zig");
pub const BackdropCaptureRegion = backdrop_capture.BackdropCaptureRegion;
// Cross-frame GPU resource cache bookkeeping extracted: fields + beginFrame/deinit.
// pipeline creation in backdrop_blur / opacity_layer / blend_composite; uniform slot allocation in
// backdrop_blur; neither migrates.
const persistent_gpu_cache = @import("command_encoder/persistent_gpu_cache.zig");
const glass_reuse = @import("glass_reuse.zig");
pub const PersistentGpuCache = persistent_gpu_cache.PersistentGpuCache;
pub const LuminanceSlot = persistent_gpu_cache.LuminanceSlot;
pub const BlurLevelSlot = persistent_gpu_cache.BlurLevelSlot;
pub const LUMINANCE_SLOT_COUNT = persistent_gpu_cache.LUMINANCE_SLOT_COUNT;
pub const BLUR_LEVEL_SLOT_COUNT = persistent_gpu_cache.BLUR_LEVEL_SLOT_COUNT;
const color_conversion = @import("color_conversion.zig");
// Extracted module tests must be explicitly imported to be collected (pub const x = @import in this
// codebase does **not** pull test blocks into runner; see render.zig test block comment).
test {
    _ = @import("offscreen_maintenance_retry.zig");
    _ = @import("glass_reuse.zig");
    _ = @import("command_encoder/local_sort_cluster.zig");
    _ = @import("command_encoder/backdrop_capture.zig");
    _ = @import("command_encoder/persistent_gpu_cache.zig");
    _ = @import("command_encoder/pixel_domain.zig");
    _ = @import("command_encoder/clip_geometry.zig");
}
pub const colorToFloat4 = color_conversion.toFloat4;
const colorToRenderColor = color_conversion.toRenderColor;
const byteToShader = color_conversion.byteToShader;
// FontSelector and encoder have zero coupling, extracted; re-export here keeps render.zig's public
// surface stable.
pub const FontSelector = @import("command_encoder/font_selector.zig").FontSelector;
pub const TextFontProps = @import("command_encoder/font_selector.zig").TextFontProps;
const icon_ir = @import("icon_ir");
const sdf = @import("sdf_renderer.zig");
const SdfRenderer = sdf.SdfRenderer;
const GradientDir = sdf.GradientDir;
const GradientExtendMode = sdf.GradientExtendMode;
const img = @import("image_renderer.zig");
const ImageRenderer = img.ImageRenderer;
const IconRenderer = @import("icon_renderer.zig").IconRenderer;
const text_renderer_mod = @import("text_renderer.zig");
const TextRenderer = text_renderer_mod.TextRenderer;
const text_ink = @import("text_ink.zig");
const text_module = @import("text");
const Font = text_module.Font;

const path_tess_mod = @import("path_tessellator.zig");
const PathRenderer = @import("path_renderer.zig").PathRenderer;
const PathRendererMod = @import("path_renderer.zig");

/// PathRenderer vertices and stroke width use logical pixels. device scale applies only to
/// viewport, curve tessellation precision, and AA fringe, not stroke width again.
pub inline fn pathStrokeWidthForTessellation(logical_width: f32, device_scale: f32) f32 {
    _ = device_scale;
    return logical_width;
}

const backdrop_blur = @import("backdrop_blur.zig");
const KawaseUniforms = backdrop_blur.KawaseUniforms;
const GlassUniforms = backdrop_blur.GlassUniforms;
const offscreen_texture = @import("offscreen_texture.zig");
const OffscreenTexturePool = offscreen_texture.OffscreenTexturePool;
const TextureLease = offscreen_texture.TextureLease;
const OffscreenTextureSize = offscreen_texture.OffscreenTextureSize;
const computeOffscreenTextureSize = offscreen_texture.computeOffscreenTextureSize;
const opacity_layer = @import("opacity_layer.zig");

pub const ClipShapeKind = enum(u8) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    polygon = 3,
};

pub const PathFillRule = enum(u8) {
    evenodd = 0,
    nonzero = 1,
};

pub const max_clip_polygon_points: usize = 32;
pub const max_clip_polygon_contours: usize = 8;
pub const ClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: PathFillRule = .evenodd,
    contour_end_points: [max_clip_polygon_contours]u8 = @as([max_clip_polygon_contours]u8, @splat(0)),
    points: [max_clip_polygon_points][2]f32 = @as([max_clip_polygon_points][2]f32, @splat(.{ 0, 0 })),

    pub fn empty() ClipPolygon {
        return .{};
    }

    pub fn isEmpty(self: ClipPolygon) bool {
        return self.point_count == 0 or self.contour_count == 0;
    }
};

const RoundedClipMode = enum(u8) { shader, layer, noop };
/// How a display-list push_clip was applied; its pop_clip undoes the same thing.
/// `.isolated`: the clip crossed the active shape clip, so it opened an offscreen layer (see
/// pushClipCommand) and the pop ends that layer after popping the clip inside it.
pub const PushClipMode = enum(u8) { clip, isolated };
const OpacityLayerMode = enum(u8) { layer, noop };

const RoundedClipState = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Corner radii TL, TR, BR, BL (logical px), clamped to half the shorter side like the fill.
    radii: [4]f32,
    shape_kind: ClipShapeKind,
    polygon: ClipPolygon = ClipPolygon.empty(),
    /// Second shape clip in force with this one (shape_clip_pair.zig): the target clips to both.
    partner: ?PartnerClip = null,

    fn fromPartner(p: PartnerClip) RoundedClipState {
        return .{ .x = p.x, .y = p.y, .w = p.w, .h = p.h, .radii = p.radii, .shape_kind = p.shape_kind };
    }
};

/// A partner shape clip: a rounded rect or an ellipse (never a polygon), same frame as its
/// primary.
const PartnerClip = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radii: [4]f32,
    shape_kind: ClipShapeKind,

    fn of(clip: RoundedClipState) PartnerClip {
        std.debug.assert(clip.shape_kind == .rounded_rect or clip.shape_kind == .ellipse);
        return .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h, .radii = clip.radii, .shape_kind = clip.shape_kind };
    }

    fn uniform(partner: ?PartnerClip) shape_clip_pair.Uniform {
        const p = partner orelse return .{};
        return .{
            .rect = .{ p.x, p.y, p.w, p.h },
            .radii = p.radii,
            .kind = if (p.shape_kind == .ellipse) 2 else 1,
        };
    }
};

/// SVG/CSS blend modes mirror src/ui/core/types.zig BlendMode; render module has no ui dependency,
/// must define independently (enum values must stay in sync).
pub const BlendMode = enum(u8) {
    normal = 0,
    multiply = 1,
    screen = 2,
    overlay = 3,
    darken = 4,
    lighten = 5,
    color_dodge = 6,
    color_burn = 7,
    hard_light = 8,
    soft_light = 9,
    difference = 10,
    exclusion = 11,
};

pub const GradientDirection = enum {
    horizontal,
    vertical,
    diagonal,
    radial,
    conic,
};

/// Monospace ASCII advance cache slot (see FontSelector.ascii_advance_cache comment).
/// Scissor rectangle (physical pixels)
pub const ScissorRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// GPU retained composite info suspended on hit. content pass fully skipped; end uses these fields
/// to composite cached texture back to parent target, equivalent to normal path endOpacityLayer
/// step 7.
const RetainedPending = struct {
    texture: TextureLease,
    /// Layer's outer-local coordinate within parent surface (same semantics as OffscreenLayer.x/y).
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opacity: f32,
    rotate: f32,
    use_draw_transform: bool,
    draw_transform: [6]f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    corner_radii: [4]f32,
    used_tex_w: u32,
    used_tex_h: u32,
    alloc_tex_w: u32,
    alloc_tex_h: u32,
    /// See OffscreenLayer.quad.
    quad: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Offscreen opacity layer state
/// damage-rect: per-item capture bounds for some top-level opacity layer (within damage_scratch).
pub const DamageRange = retained_plan.DamageRange;

// pub: single tests extracted to command_encoder_test.zig, need to construct this type.
pub const OffscreenLayer = struct {
    /// Pool-owned offscreen texture lease.
    texture: TextureLease,
    /// Offscreen render pass (lives on stack, encoder borrows via pointer)
    render_pass: gpu.Backend.RenderPass,
    /// Render target to restore to after offscreen ends (nested: parent offscreen texture, else
    /// main RT)
    restore_target: gpu.Backend.TextureBinding,
    /// Saved clip stack depth
    saved_clip_depth: usize,
    /// Saved clip overflow count (resets to 0 within offscreen pass, restored on return).
    saved_clip_overflow_depth: u32 = 0,
    /// Saved logical clip stack contents. Offscreen pass zeros clip_depth and reuses the same stack
    /// space; without backup, returning to main pass corrupts parent clip/scissor state.
    saved_logical_clip_stack: [64]RoundedClipState = undefined,
    saved_effective_rect_clip_stack: [64][4]f32 = @as([64][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// Saved viewport
    saved_viewport_width: f32,
    saved_viewport_height: f32,
    /// Layer position on screen in restore target (logical pixels)
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// Composite opacity
    opacity: f32,
    /// Raster scale before entering layer (endOpacityLayer restores). layer's effective scale =
    /// parent scale * composite transform magnification (see opacity_layer.layerMagnification).
    saved_scale: f32 = 1,
    /// This layer's own raster scale (texels per logical unit; 0 = unknown, composite the whole
    /// used region). See opacity_layer.contentUv.
    raster_scale: f32 = 0,
    /// Composite quad inside the layer bounds {x, y inset, w, h} (layer-local logical units;
    /// w = 0: the whole layer). A rounded layer keeps its own rect for the mask while its
    /// texture is aligned to the target's pixel grid (opacity_layer.alignTranslationSurface
    /// widened the bounds); the composite samples the matching texel sub-rect.
    quad: [4]f32 = .{ 0, 0, 0, 0 },
    /// Clockwise rotation in radians, origin at layer center
    rotate: f32 = 0,
    /// Whether to composite offscreen layer back with full 2D affine transform
    use_draw_transform: bool = false,
    draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    /// Composite destination rect; defaults to source
    draw_x: f32 = 0,
    draw_y: f32 = 0,
    draw_w: f32 = 0,
    draw_h: f32 = 0,
    /// Texture ID registered in image_renderer
    texture_id: u32,
    /// Rounded clip radii TL, TR, BR, BL (all 0 = ordinary opacity layer)
    corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    /// SVG/CSS blend mode (normal = standard SrcOver)
    blend_mode: BlendMode = .normal,
    /// Lens warp at composite (see types.ContentWarp); all zero = none
    warp: [4]f32 = .{ 0, 0, 0, 0 },
    /// GPU retained: when this layer draws into a dedicated layer texture, record its stable_id.
    /// endOpacityLayer uses it to decide: mark content ready (retained) vs. return to pool
    /// (ordinary temp texture); never mix them up. Returning retained texture to pool lets others
    /// overwrite it; marking temp texture primed achieves nothing.
    retained_id: u32 = opacity_layer.INVALID_SURFACE_ID,
    /// retained: sequence number of this layer's begin in prescan (damage-rect baseline writeback).
    retained_seq: usize = std.math.maxInt(usize),
    /// Physical pixels actually used by content. Texture allocated in 64px buckets (see
    /// bucketDimension); scale animation's ±1px frame jitter is needed for pool reuse hit.
    /// composite uses used/alloc to clip UVs; re-opening render pass must limit viewport/scissor to
    /// used region (NDC defaults to full alloc texture, stretching content).
    used_tex_w: u32 = 0,
    used_tex_h: u32 = 0,
    /// Physical pixels of texture allocation (bucket size)
    alloc_tex_w: u32 = 0,
    alloc_tex_h: u32 = 0,
    /// damage-rect partial repaint: this layer's content pass dirty scissor (texture-local physical
    /// pixels). Nested pass end must re-intersect when restoring this layer (scissor is per-pass
    /// state, re-begin resets); see applyOffscreenTargetViewport. null = full layer repaint.
    damage_scissor: ?opacity_layer.PartialRepaint = null,
};

/// RenderCommandEncoder: encodes lowered DisplayItem slices to GPU calls.
/// The cross-frame PersistentGpuCache lives in command_encoder/persistent_gpu_cache.zig (see that
/// file's head, 'what not to move').
/// Is a command an arc?
///
/// An arc reuses the .path kind and is distinguished by `arc_outer_radius > 0`, **only** by it:
/// stroke width and color alpha decide "can it be drawn", not "is it an arc".
/// Mixing visibility into the type check creates a gap ("not an arc, so treat as fill_path") that
/// is neither arc nor path; arc commands never carry path_geometry_ptr, so falling into the
/// fill_path branch ends in a silent orelse return.
pub fn isArcCommand(it: anytype) bool {
    return it.kind == .path and it.arc_outer_radius > 0;
}

pub const GlassCapture = struct {
    ctx: *anyopaque,
    target: *const fn (ctx: *anyopaque, item: *const anyopaque, rect: [4]u32) ?gpu.Backend.TextureBinding,
};

/// Bounding boxes covering one renderer's pending instance quads (one per scanned run of
/// instances; folded into one box when full, which only over-covers): glyphs, icons, images.
pub const InkSet = struct {
    generation: u64 = std.math.maxInt(u64),
    /// Pending instances (nearest, linear) already covered.
    covered: [2]usize = .{ 0, 0 },
    rects: [32][4]f32 = undefined,
    count: usize = 0,

    /// Whether a command painting within `bounds` (x0, y0, x1, y1) misses every pending
    /// instance quad of `lists` (one renderer's pending instance lists, `generation` its
    /// pending_generation). Covers the instances appended since the last call, whatever path
    /// emitted them, and starts over whenever the renderer dropped them.
    pub fn allows(self: *InkSet, generation: u64, lists: anytype, bounds: [4]f32) bool {
        var stale = self.generation != generation;
        inline for (0..lists.len) |li| stale = stale or lists[li].len < self.covered[li];
        if (stale) self.* = .{ .generation = generation };
        var run: ?[4]f32 = null;
        inline for (0..lists.len) |li| {
            for (lists[li][self.covered[li]..]) |*g| {
                const q = quadOf(g);
                run = if (run) |r| .{ @min(r[0], q[0]), @min(r[1], q[1]), @max(r[2], q[2]), @max(r[3], q[3]) } else q;
            }
            self.covered[li] = lists[li].len;
        }
        if (run) |r| self.add(r);
        for (self.rects[0..self.count]) |r| {
            if (bounds[0] < r[2] and r[0] < bounds[2] and bounds[1] < r[3] and r[1] < bounds[3]) return false;
        }
        return true;
    }

    /// An instance's quad as its vertex shader places it (logical pixels of the target, padded
    /// by one logical pixel for snapping).
    pub fn quadOf(g: anytype) [4]f32 {
        const G = @typeInfo(@TypeOf(g)).pointer.child;
        if (comptime @hasField(G, "skew_x")) return glyphQuad(g);
        if (comptime @hasField(G, "transform_linear")) {
            // Image: an affine map of its rect (text.metal / image.metal logical_pos).
            const r = g.rect;
            const m = g.transform_linear;
            const t = g.transform_translation;
            var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
            var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
            for ([_][2]f32{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0], r[1] + r[3] }, .{ r[0] + r[2], r[1] + r[3] } }) |c| {
                const x = m[0] * c[0] + m[2] * c[1] + t[0];
                const y = m[1] * c[0] + m[3] * c[1] + t[1];
                lo = .{ @min(lo[0], x), @min(lo[1], y) };
                hi = .{ @max(hi[0], x), @max(hi[1], y) };
            }
            return .{ lo[0] - 1, lo[1] - 1, hi[0] + 1, hi[1] + 1 };
        }
        // Icon: its rect, rotated about the center (icon.metal).
        const r = g.rect;
        if (@abs(g.rotate) > 0.0001) {
            const radius = 0.5 * @sqrt(r[2] * r[2] + r[3] * r[3]);
            const cx = r[0] + r[2] * 0.5;
            const cy = r[1] + r[3] * 0.5;
            return .{ cx - radius - 1, cy - radius - 1, cx + radius + 1, cy + radius + 1 };
        }
        return .{ r[0] - 1, r[1] - 1, r[0] + r[2] + 1, r[1] + r[3] + 1 };
    }

    /// A glyph instance's quad as the text vertex shader places it (text_renderer.glyphQuad,
    /// shared with text ink bounds).
    pub const glyphQuad = text_renderer_mod.glyphQuad;

    fn add(self: *InkSet, r: [4]f32) void {
        if (self.count == self.rects.len) {
            var u = r;
            for (self.rects) |q| u = .{ @min(u[0], q[0]), @min(u[1], q[1]), @max(u[2], q[2]), @max(u[3], q[3]) };
            self.rects[0] = u;
            self.count = 1;
            return;
        }
        self.rects[self.count] = r;
        self.count += 1;
    }
};

pub const RenderCommandEncoder = struct {
    const local_sort_cluster_capacity: usize = cluster_mod.capacity;
    const max_kawase_uniform_updates: u32 = backdrop_blur.max_kawase_uniform_updates;
    const max_glass_uniform_updates: u32 = backdrop_blur.max_glass_uniform_updates;

    // local-sort cluster state machine extracted to command_encoder/local_sort_cluster.zig
    // (refs+len and four methods reference only each other; encoder uses only at encodeCommands /
    // flushLocalSortCluster). reject reason migrates; switch branch names unchanged.
    const LocalSortRejectReason = cluster_mod.RejectReason;

    /// Borrowed timing context; detached encoders can omit optional profiling.
    io: ?std.Io = null,
    visual_quality: @import("visual_quality.zig").Quality = .full,
    retained_enabled: bool = true,
    sdf_renderer: *SdfRenderer,
    text_renderer: *TextRenderer,
    image_renderer: ?*ImageRenderer = null,
    icon_renderer: ?*IconRenderer = null,
    fonts: ?*FontSelector = null,

    // Clip stack, logical clip state remains stack-based, but axis-aligned
    // rect clip is now captured per instance to avoid flushes on common
    // overflow_hidden transitions.
    clip_stack: [64]ScissorRect = undefined,
    logical_clip_stack: [64]RoundedClipState = undefined,
    /// syncRendererClipMask memo: skip state copy across all renderers when clip hasn't changed
    /// (each sync is 4-5 renderers * ~300B value copy; push/pop clip and begin/end layer trigger).
    /// encoder rebuilt each frame, unsynced by default.
    last_synced_clip_mask: ?RoundedClipState = null,
    /// false: crossing shape clips isolate as off Metal (shape_clip_pair.zig). Test hooks use it
    /// to exercise isolation where the scene would pair.
    pair_shape_clips: bool = true,
    clip_mask_synced: bool = false,
    /// begin_rounded_clip implementation path stack: end_rounded_clip must know whether begin took
    /// shader clip or offscreen layer path. Shader path saves 2 render passes + full RT load/store
    /// (core benefit of rounded-clip shader on tile GPU).
    rounded_clip_mode_stack: [32]RoundedClipMode = undefined,
    rounded_clip_mode_depth: u32 = 0,
    rounded_clip_overflow_depth: u32 = 0,
    /// push_clip implementation path stack (pushClipCommand): pop_clip must know whether its
    /// push opened an isolation layer. Pushes past the stack depth are plain clips (counted in
    /// push_clip_mode_overflow_depth so their pops stay paired).
    push_clip_mode_stack: [64]PushClipMode = undefined,
    push_clip_mode_depth: u32 = 0,
    push_clip_mode_overflow_depth: u32 = 0,
    /// Isolation layers that could not open this frame (diagnostic; the clip then degrades to
    /// the innermost shape only).
    isolated_clip_fallbacks: u32 = 0,
    /// Escape valve: ZENIT_ROUNDED_CLIP_LAYER=1 forces all old offscreen path (process-level
    /// cache).
    force_rounded_clip_layer: ?bool = null,
    effective_rect_clip_stack: [64][4]f32 = @as([64][4]f32, @splat(.{ 0, 0, 0, 0 })),
    clip_depth: usize = 0,
    /// Count of ignored push_clip after stack full. Paired pop_clip must offset these first, or
    /// parent clip pops incorrectly (push silent / pop unconditional = mismatch).
    clip_overflow_depth: u32 = 0,
    render_pass: ?*gpu.Backend.RenderPass = null,
    /// CPU damage patch target (render/cpu_flat.zig): pending batches are
    /// rasterized on the CPU instead of submitted. Borrowed for one encode.
    cpu_flat_target: ?*anyopaque = null,
    /// With `cpu_flat_target`: check every batch is supported and drop it
    /// without rasterizing (the target is not touched).
    cpu_flat_validate_only: bool = false,
    /// Glass underlay capture (zenit_app/cpu_patch.zig): after a main-target
    /// glass composite the pixels it produced are copied out, so a later CPU
    /// patch can reuse them while the glass and its backdrop are unchanged.
    /// `target` returns the copy destination for the begin token at `item`
    /// (a pointer into the encoded command list) covering `rect` (device px).
    glass_capture: ?GlassCapture = null,
    /// Command being dispatched by encodeCommands (identifies glass tokens).
    dispatch_item: ?*const anyopaque = null,
    /// Cross-frame glass composite reuse (glass_reuse.zig): keys a glass
    /// token's backdrop from the frame's paint table. Unset: every glass
    /// composites anew.
    glass_reuse: ?glass_reuse.Hook = null,
    /// Backdrop keys of the glass encoded so far this frame.
    glass_frame_keys: glass_reuse.FrameKeys = .{},
    /// Glass composites drawn from a retained texture this frame.
    glass_reuse_hits: u32 = 0,
    /// Device-pixel capture rect of the last main-target glass composite;
    /// set by backdrop_blur.applyBackdropBlur.
    last_glass_capture: ?[4]u32 = null,
    drawable_extent: [2]u32 = .{ 0, 0 },
    viewport_width: f32 = 0,
    /// Pixel-aligned root crop, used by small caret render targets. Nested
    /// surfaces still accumulate their own offsets through the same algebra.
    root_crop_origin: [2]f32 = .{ 0, 0 },
    /// Raster mapping of the main attachment. Passes may be reopened by
    /// nested clip isolation; keep this mapping with the target, not the pass.
    root_target_crop: ?[4]u32 = null,
    root_target_offset: [2]u32 = .{ 0, 0 },
    viewport_height: f32 = 0,
    scale: f32 = 1,
    main_destination_opaque: bool = false,
    text_backdrop: text_policy.Backdrop = .{},
    text_layers: text_policy.State = .{},
    frame_index: u64 = 0,
    /// v0.9-S1D audit (2026-05-13): beginRenderPass call count per frame.
    /// main pass + offscreen opacity_layer + backdrop_blur + clearTexture etc. share counter.
    /// reset in beginFrame; caller (encoder.beginFrame caller) reads last frame via pass_count for
    /// perf monitoring. Later stages target: merge single-pass + stencil/blend replacing offscreen,
    /// complex scenarios (nested opacity layers) yield most.
    pass_count: u32 = 0,
    /// Diagnostics (ZENIT_DEBUG_PASSCOUNT): pass count categorized by callsite, answer "what are
    /// this frame's N passes". See PassSite for index.
    pass_sites: [8]u32 = @splat(0),
    /// Where the pending text / image / icon instances can paint (see pendingInkAllows).
    text_ink: InkSet = .{},
    image_ink: InkSet = .{},
    icon_ink: InkSet = .{},
    /// Actual layer-open result for each ordinary opacity begin. Must log per-layer; noop depth
    /// count alone can't represent "noop outer with real inner" legal nesting.
    /// Skip beginOpacityLayer offscreen pass + image composite when opacity ~= 1.0 && blend_mode =
    /// normal && no transform/rotate; equivalent to not opening layer.
    opacity_mode_stack: [64]OpacityLayerMode = undefined,
    opacity_mode_depth: usize = 0,
    opacity_mode_overflow_depth: u32 = 0,
    /// GPU retained: on cache hit, **all content commands between begin..end skipped** (pixels
    /// already in texture); only do one composite draw at end.
    /// Track nesting depth skipped, not just bool: skipped subtree may contain its own begin/end
    /// opacity layer pairs; depth counting finds correct end.
    retained_skip_depth: u32 = 0,
    /// retained hit suspends composite info, content pass skipped, but still composite cached
    /// texture to parent at end.
    retained_pending: [8]RetainedPending = undefined,
    retained_pending_depth: usize = 0,
    /// This frame's retained hit/miss counts (diagnostic; one hit = skip one whole offscreen
    /// clear+content pass re-rasterization).
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    /// Miss count where damage-rect partial repaint was used (diagnostic)
    retained_partial_repaints: u32 = 0,
    /// Content fingerprint for each begin_opacity_layer (in order). See
    /// computeRetainedContentHashes; this is retained's real cache key.
    retained_hashes: [64]u64 = @as([64]u64, @splat(0)),
    retained_hash_count: usize = 0,
    /// Set of owner node ids that composited glass backdrop this frame.
    /// begin token for same blur effect instance may appear multiple times per frame (display_list
    /// multi-pass assembly puts stray items of same subtree at storage tail -> effect chain
    /// re-opens); recompositing backdrop captures+blurs+covers prior content (downstream app
    /// sidebar "glass obscures content" real capture).
    /// Semantic contract: one owner gets at most one backdrop per frame; repeated begin skips.
    blur_applied_owners: [64]u32 = undefined,
    blur_applied_count: usize = 0,
    /// Backdrops with visible geometry and a valid capture region. The family
    /// probe waits for these owners, while blur_applied_owners only deduplicates.
    glass_probe_owners: [64]u32 = undefined,
    glass_probe_owner_count: usize = 0,
    /// The frame's glass quarter-grid bank (backdrop_blur.frameQuarter) and
    /// the window-space (logical px) union of everything drawn into the main
    /// target since it was last brought up to date: the ink bounds of each
    /// command dispatched at main-target depth (a group begin token covers its
    /// whole group, its later composite included). `glass_open_group` holds
    /// the ink bounds of the offscreen group open at main-target depth, whose
    /// composite is still to come. `glass_bank_scale` maps them to target
    /// pixels of a frame whose main target spans `glass_bank_extent` (the
    /// whole window; a cropped target such as a caret patch keeps no bank).
    /// Frame state: reset in beginFrame.
    glass_quarter: ?backdrop_blur.FrameQuarter = null,
    glass_bank_dirty: ?[4]f32 = null,
    glass_open_group: ?[4]f32 = null,
    glass_bank_scale: f32 = 1,
    glass_bank_extent: [2]f32 = .{ 0, 0 },
    /// dispatch is at which begin_opacity_layer (aligns with prescan sequence number).
    retained_begin_seq: usize = 0,
    /// damage-rect: per-item {single fingerprint, expanded bounds} for each **top-level** opacity
    /// layer this frame, same index order as retained_hashes. On miss, diff with pool's last-frame
    /// baseline to find dirty region; only repaint dirty area.
    damage_scratch: [1024]offscreen_texture.DamageItem = undefined,
    damage_scratch_count: usize = 0,
    /// layer_tree damage path convergence (2026-07-30): read direction, encodeDisplay snapshots
    /// {stable_id, local-space damage bounds} from LayerTree each frame (addDamage producer side),
    /// computePartialDamage merges diff dirty regions (safe direction: expand only, shrink never).
    /// Write direction, retained layer actual decisions (hit/full/partial repaint) via
    /// writebackLayerOutcomes write back to LayerTree.needs_repaint/damage_rect; both paths now
    /// share one state source (single observation/test truth).
    layer_damage_ids: [32]u32 = undefined,
    layer_damage_rects: [32][4]f32 = undefined, // local space {min_x,min_y,max_x,max_y}
    layer_damage_count: usize = 0,
    layer_outcome_ids: [64]u32 = undefined,
    layer_outcome_kinds: [64]u8 = undefined, // 0=hit 1=full repaint 2=partial repaint
    layer_outcome_rects: [64][4]f32 = undefined, // local space {min_x,min_y,max_x,max_y}
    layer_outcome_count: usize = 0,
    damage_ranges: [64]DamageRange = @as([64]DamageRange, @splat(.{})),
    // Phase C2/C3: offscreen opacity layers
    /// GPU command encoder (create multiple render passes within one command buffer)
    gpu_command_encoder: ?*gpu.Backend.CommandEncoder = null,
    /// Main render target texture (restore point after ending offscreen)
    main_render_target: ?gpu.Backend.TextureBinding = null,
    frame_damage_scissor: ?[4]u32 = null,
    /// With frame_damage_scissor: paint index ranges [first, last] of the
    /// frame's table (ascending) that paint nothing inside it
    /// (FrameDamage.prepareEffects). encodeDisplay does not encode them.
    frame_damage_skip: []const [2]u32 = &.{},
    /// Glass composited under frame_damage_scissor whose capture reached
    /// outside it (the backdrop prediction missed): the frame is wrong there.
    frame_damage_violations: u32 = 0,
    /// Offscreen layer stack (supports nesting)
    offscreen_stack: [8]OffscreenLayer = undefined,
    offscreen_depth: usize = 0,
    /// Offscreen texture pool, points to **owner (AppRenderer) persistent pool**. encoder is
    /// per-frame local value; embedding pool would release entire pool on deinit, cross-frame reuse
    /// (pool's only purpose) never happens; each frame with offscreen effects create/release
    /// textures. owner calls pool.deinit() (must be after GPU drain).
    offscreen_pool: *OffscreenTexturePool,
    pool_session_active: bool = false,
    /// Manual encoders lack a renderer-registered submission fence. Preserve
    /// their original frame-age quarantine/retirement between encoding frames.
    external_pool_aging: bool = false,

    /// **Cross-frame persistent** GPU resource cache (borrowed, not owned), same rationale as
    /// offscreen_pool.
    ///
    /// The path renderer / tessellator / blur & glass pipelines / buffers / samplers must not live
    /// in
    /// the **per-frame** encoder: its deinit would delete them at frame end, and the next frame
    /// using
    /// path/blur would redo MSL compile, PSO creation and buffer/sampler rebuilds, causing
    /// per-frame
    /// overhead and jitter in any continuous SVG/path/GlassBox animation.
    ///
    /// They live in AppRenderer's PersistentGpuCache; the encoder only borrows. Accessor paths are
    /// unchanged (below).
    persistent: *PersistentGpuCache,

    /// Initialize encoder
    pub fn init(
        sdf_renderer: *SdfRenderer,
        text_renderer: *TextRenderer,
        offscreen_pool: *OffscreenTexturePool,
        persistent: *PersistentGpuCache,
    ) RenderCommandEncoder {
        return .{
            .sdf_renderer = sdf_renderer,
            .text_renderer = text_renderer,
            .offscreen_pool = offscreen_pool,
            .persistent = persistent,
        };
    }

    pub fn initWithImageAndIcon(
        sdf_renderer: *SdfRenderer,
        text_renderer: *TextRenderer,
        image_renderer: *ImageRenderer,
        icon_renderer: *IconRenderer,
        offscreen_pool: *OffscreenTexturePool,
        persistent: *PersistentGpuCache,
    ) RenderCommandEncoder {
        return .{
            .sdf_renderer = sdf_renderer,
            .text_renderer = text_renderer,
            .image_renderer = image_renderer,
            .icon_renderer = icon_renderer,
            .offscreen_pool = offscreen_pool,
            .persistent = persistent,
        };
    }

    /// Free encoder's lazily-allocated temporary GPU/path resources.
    ///
    /// RenderCommandEncoder often used as per-frame local value; if some frame hits path/blur/glass
    /// paths without explicit cleanup, these resources leak when encoder leaves scope.
    pub fn deinit(self: *RenderCommandEncoder) void {
        defer self.endPoolSession();
        // encoder is per-frame local value (AppRenderer.getEncoder creates fresh each frame),
        // deinit is frame end; pass_count here is full-frame final value.
        if (@import("zenit_environment").flag("ZENIT_DEBUG_PASSCOUNT")) {
            std.debug.print("[passcount] passes={d} retained_hit={d} retained_miss={d} | op_restore={d} op_begin={d} op_composite={d} clear_tex={d} blur={d}/{d}/{d}\n", .{
                self.pass_count,    self.retained_hits, self.retained_misses,
                self.pass_sites[0], self.pass_sites[1], self.pass_sites[2],
                self.pass_sites[4], self.pass_sites[5], self.pass_sites[6],
                self.pass_sites[7],
            });
            if (self.persistent.path_renderer) |*pr| {
                if (pr.frame_call_count > 0) {
                    std.debug.print("[pathbatch] calls={d} draws={d}\n", .{ pr.frame_call_count, pr.frame_draw_count });
                }
            }
        }

        // Frame mid-error (encodeDisplay/flush try early return) leaves unflushed layers in
        // offscreen stack: external texture slots they borrowed must return here.
        // external slots only EXTERNAL_SLOT_COUNT exist, handles don't cross frames; leak =
        // permanently lose one slot.
        self.releaseAbandonedOffscreenBindings();

        // WARNING: path/blur/glass pipeline, buffer, sampler, tessellator **no longer** freed here;
        // promoted to AppRenderer's PersistentGpuCache, cross-frame reused (prev: create+destroy
        // per frame; continuous path/blur animation re-ran MSL compile every frame, see review
        // report P1).
        // encoder borrows, nothing to do at frame end; AppRenderer.deinit releases cache uniformly.
    }

    /// Account a command dispatched at main-target depth for the glass
    /// quarter bank: grow glass_bank_dirty by the pixels it can change in the
    /// main target (paint_fingerprint.inkWorldBounds; unbounded when unknown),
    /// and track the offscreen group it opens or closes.
    fn noteGlassBankDirty(self: *RenderCommandEncoder, it: anytype) void {
        const opened_layer = self.offscreen_depth > 0;
        if (!opened_layer) self.glass_open_group = null;
        if (self.glass_quarter == null and !opened_layer) return;
        const T = @TypeOf(it);
        var b: [4]f32 = if (comptime @hasField(T, "shadow2_blur") and @hasField(T, "glass_ptr") and @hasField(T, "path_geometry_ptr") and @hasField(T, "text_content"))
            paint_fp.inkWorldBounds(it)
        else
            unbounded_ink;
        if (!(b[2] >= 0 and b[3] >= 0)) b = unbounded_ink; // NaN or inverted: never hide pixels
        // This command opened an offscreen layer: it composites into the main
        // target at its end token, possibly after the bank's next update.
        if (opened_layer) self.glass_open_group = if (b[2] > 0 and b[3] > 0) b else unbounded_ink;
        if (self.glass_quarter == null or b[2] == 0 or b[3] == 0) return;
        self.glass_bank_dirty = if (self.glass_bank_dirty) |d| unionRect(d, b) else b;
    }

    const unbounded_ink: [4]f32 = .{ -1e7, -1e7, 2e7, 2e7 };

    fn unionRect(a: [4]f32, b: [4]f32) [4]f32 {
        const x0 = @min(a[0], b[0]);
        const y0 = @min(a[1], b[1]);
        const x1 = @max(a[0] + a[2], b[0] + b[2]);
        const y1 = @max(a[1] + a[3], b[1] + b[3]);
        return .{ x0, y0, x1 - x0, y1 - y0 };
    }

    fn releaseAbandonedOffscreenBindings(self: *RenderCommandEncoder) void {
        const ir = self.image_renderer orelse {
            self.offscreen_depth = 0;
            return;
        };
        for (self.offscreen_stack[0..self.offscreen_depth]) |layer| {
            ir.unregisterTextureBinding(layer.texture_id);
        }
        self.offscreen_depth = 0;
    }

    /// Set font selector.
    ///
    /// WARNING: **don't attach drawn-width callback here**. RenderCommandEncoder is
    /// **per-frame-by-value new stack temporary** (AppRenderer.getEncoder returns one each frame);
    /// storing `self` into FontSelector's cross-frame lifespan = dangling pointer at frame end, hit
    /// on next layout measurement as e2e "RPC timeout" not crash stack, extremely hard to
    /// attribute.
    /// Callback must bind to stable-lifetime TextRenderer, installed by host at window creation,
    /// removed at window destruction (host's font loading code responsible).
    pub fn setFonts(self: *RenderCommandEncoder, fonts: *FontSelector) void {
        self.fonts = fonts;
    }

    /// Initialize renderer's internal FontSelector lazy derived font cache must be called after
    /// setFonts (setFonts is borrowed pointer, no copy)
    pub fn initFontDerivedCache(self: *RenderCommandEncoder, allocator: std.mem.Allocator) void {
        if (self.fonts) |fs| {
            fs.initDerivedCache(allocator);
        }
    }

    /// Free renderer's internal FontSelector lazy derived font cache
    pub fn deinitFontDerivedCache(self: *RenderCommandEncoder) void {
        if (self.fonts) |fs| {
            fs.deinitDerivedCache();
        }
    }

    /// Begin new frame
    /// width/height: logical pixels; scale: DPI scale factor (Retina=2.0)
    pub fn beginFrame(self: *RenderCommandEncoder, width: f32, height: f32, scale: f32) void {
        self.frame_index += 1;
        paint_fp.nextFrameSalt();
        // reset global draw call counter
        gpu.Backend.RenderPass.frame_draw_call_count = 0;
        // reset per-frame pass count audit counter
        self.pass_count = 0;
        self.text_backdrop.reset(width, height, self.main_destination_opaque);
        self.text_layers = .{};
        self.pass_sites = @splat(0);
        self.glass_quarter = null;
        self.glass_bank_dirty = null;
        self.glass_open_group = null;
        self.glass_bank_scale = scale;
        self.glass_bank_extent = .{ width * scale, height * scale };
        self.opacity_mode_depth = 0;
        self.opacity_mode_overflow_depth = 0;
        self.retained_skip_depth = 0;
        self.retained_pending_depth = 0;
        self.retained_begin_seq = 0;
        self.retained_hash_count = 0;
        self.rounded_clip_mode_depth = 0;
        self.rounded_clip_overflow_depth = 0;
        self.push_clip_mode_depth = 0;
        self.push_clip_mode_overflow_depth = 0;
        self.isolated_clip_fallbacks = 0;
        // A CPU patch target (set before beginFrame) leaves the GPU slots alone.
        const gpu_frame = self.cpu_flat_target == null;
        self.sdf_renderer.beginFrameFor(width, height, scale, @truncate(self.frame_index), gpu_frame);
        self.text_renderer.beginFrameFor(width, height, scale, gpu_frame);
        if (self.image_renderer) |ir| ir.beginFrameFor(width, height, scale, gpu_frame);
        if (self.icon_renderer) |ir| ir.beginFrameFor(width, height, scale, gpu_frame);
        if (self.persistent.path_renderer) |*pr| pr.beginFrameFor(width, height, scale, gpu_frame);
        self.clip_depth = 0;
        self.clip_overflow_depth = 0;
        self.offscreen_depth = 0;
        self.beginOffscreenFrame();
        self.root_crop_origin = .{ 0, 0 };
        self.root_target_crop = null;
        self.root_target_offset = .{ 0, 0 };
        // Idle retirement is performed by the host between frames, using
        // monotonic deadlines and a completed submission fence.
        backdrop_blur.resetDynamicUniformOffsets(self);
        self.viewport_width = width;
        self.viewport_height = height;
        self.scale = scale;
        self.drawable_extent = .{ pixel_domain.physicalPixelExtent(width, scale), pixel_domain.physicalPixelExtent(height, scale) };
        self.applyDrawableViewport();
        self.syncRectClipState();
        self.syncTextClipX();
        self.syncRendererClipMask();
    }

    /// Hand the shared offscreen pool back once this frame is submitted, so
    /// another encoder (sprite builds after present) may begin before this
    /// one is deinitialized. Idempotent; deinit calls it too.
    pub fn endPoolSession(self: *RenderCommandEncoder) void {
        if (!self.pool_session_active) return;
        self.offscreen_pool.releaseTransients();
        self.offscreen_pool.encoder_active = false;
        self.pool_session_active = false;
    }

    fn beginOffscreenFrame(self: *RenderCommandEncoder) void {
        // Reusing one manual encoder explicitly ends its previous frame.
        if (self.pool_session_active) self.offscreen_pool.encoder_active = false;
        std.debug.assert(!self.offscreen_pool.encoder_active);
        self.offscreen_pool.resetFrame();
        if (self.external_pool_aging) {
            self.offscreen_pool.sweepRetained(self.frame_index);
            self.offscreen_pool.sweepIdle(self.frame_index);
        }
        self.offscreen_pool.encoder_active = true;
        self.pool_session_active = true;
    }

    test "external encoder ages retained and idle entries between frames" {
        // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
        if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
        var device = gpu.Backend.Device{};
        var pool: OffscreenTexturePool = .{};
        defer pool.deinit();
        const old = pool.acquireRetained(&device, 17, 1, 64, 64, 1).?;
        var enc = RenderCommandEncoder.init(undefined, undefined, &pool, undefined);
        enc.external_pool_aging = true;
        enc.frame_index = 70;
        enc.beginOffscreenFrame();
        try std.testing.expect(pool.resolveTexture(old.lease) == null);
        try std.testing.expect(pool.encoder_active);
        enc.frame_index = 200;
        enc.beginOffscreenFrame();
        try std.testing.expect(pool.nextMaintenanceDelayNs(0) == null);
        enc.deinit();
        try std.testing.expect(!pool.encoder_active);
    }

    test "a submitted frame lets a second encoder use the pool before it is deinitialized" {
        // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
        if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
        var pool: OffscreenTexturePool = .{};
        defer pool.deinit();
        var frame = RenderCommandEncoder.init(undefined, undefined, &pool, undefined);
        frame.beginOffscreenFrame();
        try std.testing.expect(pool.encoder_active);
        frame.endPoolSession();
        try std.testing.expect(!pool.encoder_active);
        var sprite = RenderCommandEncoder.init(undefined, undefined, &pool, undefined);
        sprite.beginOffscreenFrame();
        try std.testing.expect(pool.encoder_active);
        sprite.deinit();
        frame.deinit();
        try std.testing.expect(!pool.encoder_active);
    }

    test "encoder teardown hands transients back and idle maintenance frees them without another frame" {
        // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
        if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
        var device = gpu.Backend.Device{};
        var pool: OffscreenTexturePool = .{};
        defer pool.deinit();
        var enc = RenderCommandEncoder.init(undefined, undefined, &pool, undefined);
        enc.beginOffscreenFrame();
        for (0..OffscreenTexturePool.MAX_POOL) |_| {
            _ = pool.acquire(&device, 64, 64, 1) orelse return error.TestUnexpectedResult;
        }
        const transient = pool.acquire(&device, 64, 64, 1).?;
        try std.testing.expectEqual(@import("offscreen_texture.zig").TextureLease.Kind.transient, transient.kind);
        enc.deinit();
        // Kept for later frames (no per-frame recreate), but no longer in use.
        try std.testing.expect(pool.resolveTexture(transient) != null);
        try std.testing.expect(!pool.transients[transient.slot].?.in_use);
        // The idle deadline still wakes maintenance when no frame follows.
        const deadline = pool.nextMaintenanceDelayNs(0) orelse return error.TestUnexpectedResult;
        pool.maintain(deadline, true);
        try std.testing.expect(pool.resolveTexture(transient) == null);
        try std.testing.expectEqual(@as(u32, 0), pool.memorySnapshot(1).transient);
    }

    /// Encode cx's lowered DisplayItem slice to sdf/image/text renderer, flush() sends to GPU once.
    /// Caller doesn't hold IR slice directly; encoder calls cx.lowerForEncoderPaintTable() itself
    /// (B-7 main path switch).
    pub fn encodeDisplay(self: *RenderCommandEncoder, cx: anytype) !void {
        return self.encodeDisplayFrom(cx, 0);
    }

    /// A previously encoded/copied prefix must end with an empty clip stack
    /// and contain no offscreen layers. All layer bookkeeping belongs here.
    pub fn encodeDisplayFrom(self: *RenderCommandEncoder, cx: anytype, first: usize) !void {
        self.layer_outcome_count = 0;
        self.captureLayerTreeDamage(&cx.layer_tree);
        const skip = self.frame_damage_skip;
        defer self.frame_damage_skip = skip;
        if (first != 0 or self.frame_damage_scissor == null) self.frame_damage_skip = &.{};
        try self.encodeCommands(cx.lowerForEncoderPaintTable()[first..]);
        self.writebackLayerOutcomes(&cx.layer_tree);
    }

    /// layer_tree -> encoder: snapshot per-layer damage regions produced by addDamage.
    /// consume-clear: take and clear, production doesn't guarantee LayerTree.beginFrame each frame;
    /// uncleaned one-time declaration becomes permanent (partial feedback loop = damage forever
    /// 100%).
    fn captureLayerTreeDamage(self: *RenderCommandEncoder, lt: anytype) void {
        self.layer_damage_count = 0;
        for (lt.layers.items) |*l| {
            if (!l.alive or !l.needs_repaint) continue;
            const comp = l.composited orelse continue;
            const d = l.damage_rect;
            l.needs_repaint = false;
            l.damage_rect = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
            if (d.max_x <= d.min_x or d.max_y <= d.min_y) continue;
            if (self.layer_damage_count >= self.layer_damage_ids.len) continue;
            self.layer_damage_ids[self.layer_damage_count] = comp.stable_id;
            self.layer_damage_rects[self.layer_damage_count] = .{ d.min_x, d.min_y, d.max_x, d.max_y };
            self.layer_damage_count += 1;
        }
    }

    /// encoder -> layer_tree: write back retained layer's actual repaint decision this frame.
    fn writebackLayerOutcomes(self: *RenderCommandEncoder, lt: anytype) void {
        var i: usize = 0;
        while (i < self.layer_outcome_count) : (i += 1) {
            lt.noteEncoderOutcome(
                self.layer_outcome_ids[i],
                self.layer_outcome_kinds[i],
                self.layer_outcome_rects[i],
            );
        }
    }

    /// opacity_layer calls during retained begin decision point (hit/opened_for_repaint).
    pub fn recordLayerOutcome(self: *RenderCommandEncoder, stable_id: u32, kind: u8, rect: [4]f32) void {
        if (self.layer_outcome_count >= self.layer_outcome_ids.len) return;
        self.layer_outcome_ids[self.layer_outcome_count] = stable_id;
        self.layer_outcome_kinds[self.layer_outcome_count] = kind;
        self.layer_outcome_rects[self.layer_outcome_count] = rect;
        self.layer_outcome_count += 1;
    }

    /// Prewarm text atlas, pre-generate glyphs before GPU wait, avoid render stall.
    pub fn prewarmDisplay(self: *RenderCommandEncoder, cx: anytype) !void {
        try self.prewarmTextCommands(cx.lowerForEncoderPaintTable());
    }

    /// Fingerprint fonts, text, phase positions and raster policy; colors never
    /// change mask keys. Windows layer geometry also determines raster scale.
    fn prewarmSignature(commands: anytype) u64 {
        var h = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        for (commands) |it| {
            if (comptime @import("builtin").os.tag == .windows) {
                if (it.kind == .control) {
                    h.update(std.mem.asBytes(&it.control_kind));
                    h.update(std.mem.asBytes(&it.geom));
                    h.update(std.mem.asBytes(&it.use_draw_transform));
                    h.update(std.mem.asBytes(&it.draw_transform));
                    h.update(std.mem.asBytes(&it.draw_w));
                    h.update(std.mem.asBytes(&it.draw_h));
                }
            }
            if (it.kind != .text) continue;
            if (it.text_content.len == 0 or it.text_font_size <= 0) continue;
            h.update(it.text_content);
            if (comptime @import("builtin").os.tag == .windows) {
                h.update(std.mem.asBytes(&it.geom));
                h.update(std.mem.asBytes(&it.text_font_family));
            }
            // One update for the fixed fields: the streaming hasher's per-call
            // cost dominated this per-frame scan of every text item.
            var fixed: [12]u8 = undefined;
            @memcpy(fixed[0..4], std.mem.asBytes(&it.text_font_size));
            @memcpy(fixed[4..6], std.mem.asBytes(&it.text_font_weight));
            fixed[6] = it.text_font_flags;
            @memcpy(fixed[7..11], std.mem.asBytes(&it.text_monospace_char_width));
            fixed[11] = it.text_raster_policy;
            h.update(&fixed);
        }
        return h.final();
    }

    fn prewarmTextCommands(self: *RenderCommandEncoder, commands: anytype) !void {
        // Frame skip: text payload identical to last frame && atlas never evicted pages -> glyphs
        // must all exist, whole prewarm has no output. See TextRenderer.prewarm_signature.
        const signature = prewarmSignature(commands) ^ @as(u64, @bitCast(@as(f64, self.scale)));
        const gc_gen = self.text_renderer.atlas.gc_generation;
        if (self.text_renderer.prewarm_signature_valid and
            self.text_renderer.prewarm_signature == signature and
            self.text_renderer.prewarm_gc_generation == gc_gen)
        {
            return;
        }

        self.text_renderer.prewarm_full_passes += 1;
        const tr = self.text_renderer;
        // Items covered by the previous pass skip, unless its baseline is gone.
        const reuse_known = tr.prewarm_signature_valid and tr.prewarm_gc_generation == gc_gen;
        if (!reuse_known) tr.prewarm_known.clearRetainingCapacity();
        tr.prewarm_seen.clearRetainingCapacity();
        var seen_complete = true;
        // Only pre-stuff missing glyphs into atlas, turn off instance output, avoid "text encoded
        // twice" (review report P1). base_* kept as assertion: theory says glyph_only shouldn't
        // change instance count; if it does, some path bypassed this flag.
        const base_nearest = self.text_renderer.instances_nearest.items.len;
        const base_linear = self.text_renderer.instances_linear.items.len;
        self.text_renderer.glyph_only = true;
        defer self.text_renderer.glyph_only = false;
        var offscreen_x: [8]f32 = @as([8]f32, @splat(0));
        var offscreen_y: [8]f32 = @as([8]f32, @splat(0));
        var offscreen_depth: usize = 0;
        var prewarm_scales: [9]f32 = @splat(self.scale);
        var prewarm_layer_depth: usize = 0;
        var prewarm_overflow: usize = 0;
        defer {
            self.text_renderer.prewarm_layered = false;
            self.text_renderer.prewarm_scale_count = 0;
            self.text_renderer.setViewport(self.viewport_width, self.viewport_height, self.scale);
        }

        for (commands) |it| {
            switch (it.kind) {
                .text => {
                    if (it.text_content.len == 0 or it.text_font_size <= 0) continue;
                    var ox: f32 = 0;
                    var oy: f32 = 0;
                    for (0..offscreen_depth) |idx| {
                        ox -= offscreen_x[idx];
                        oy -= offscreen_y[idx];
                    }
                    const item_key = prewarmItemKey(it, prewarm_scales[@min(offscreen_depth, prewarm_scales.len - 1)]);
                    tr.prewarm_seen.put(tr.allocator, item_key, {}) catch {
                        seen_complete = false;
                    };
                    if (tr.prewarm_known.contains(item_key)) continue;
                    if (comptime @import("builtin").os.tag == .windows) {
                        self.text_renderer.prewarm_layered = prewarm_layer_depth > 0;
                        self.text_renderer.prewarm_scales = prewarm_scales;
                        self.text_renderer.prewarm_scale_count = offscreen_depth + 1;
                        self.text_renderer.setViewport(self.viewport_width, self.viewport_height, prewarm_scales[offscreen_depth]);
                    }
                    const use_italic = (it.text_font_flags & 1) != 0;
                    const use_mono = (it.text_font_flags & 2) != 0;
                    const use_sym = (it.text_font_flags & 4) != 0;
                    const raster = wire_types.textRasterControls(it.text_raster_policy);
                    self.text_renderer.smooth_fonts = (it.text_font_flags & 8) == 0;
                    defer self.text_renderer.smooth_fonts = true;
                    if (it.text_spans) |s| {
                        try self.encodeTextWithSpans(
                            it.geom.x + ox,
                            it.geom.y + oy,
                            it.text_content,
                            it.color,
                            it.text_font_size,
                            it.text_font_weight,
                            it.text_font_family,
                            use_sym,
                            use_mono,
                            it.text_monospace_char_width,
                            use_italic,
                            raster.force_linear,
                            raster.shader_snap,
                            s,
                        );
                    } else {
                        try self.encodeText(
                            it.geom.x + ox,
                            it.geom.y + oy,
                            it.text_content,
                            it.color,
                            it.text_font_size,
                            it.text_font_weight,
                            it.text_font_family,
                            use_sym,
                            use_mono,
                            it.text_monospace_char_width,
                            use_italic,
                            raster.force_linear,
                            raster.shader_snap,
                        );
                    }
                },
                .control => switch (it.control_kind) {
                    .begin_opacity_layer, .begin_rounded_clip => {
                        prewarm_layer_depth += 1;
                        if (offscreen_depth == offscreen_x.len) {
                            prewarm_overflow += 1;
                            continue;
                        }
                        if (comptime @import("builtin").os.tag == .windows) {
                            const parent = prewarm_scales[offscreen_depth];
                            const candidate = parent * opacity_layer.layerMagnification(it.use_draw_transform, it.draw_transform, it.geom.w, it.geom.h, it.draw_w, it.draw_h);
                            prewarm_scales[offscreen_depth + 1] = if (computeOffscreenTextureSize(it.geom.w, it.geom.h, candidate, self.sdf_renderer.device.limits.max_texture_dimension_2d) != null) candidate else parent;
                        }

                        if (offscreen_depth < offscreen_x.len) {
                            offscreen_x[offscreen_depth] = it.geom.x;
                            offscreen_y[offscreen_depth] = it.geom.y;
                            offscreen_depth += 1;
                        }
                    },
                    .end_opacity_layer, .end_rounded_clip => {
                        prewarm_layer_depth -|= 1;
                        if (prewarm_overflow > 0) {
                            prewarm_overflow -= 1;
                            continue;
                        }

                        if (offscreen_depth > 0) offscreen_depth -= 1;
                    },
                    .begin_blur_layer => prewarm_layer_depth += 1,
                    .end_blur_layer => prewarm_layer_depth -|= 1,
                    else => {},
                },
                else => {},
            }
        }

        // glyph_only should produce no new instances; if some path bypasses flag, truncate here
        // anyway, stay consistent with old behavior (multi-shrink OK, better than leaking prewarm
        // instances into actual pass causing double-draw).
        self.text_renderer.instances_nearest.shrinkRetainingCapacity(base_nearest);
        self.text_renderer.instances_linear.shrinkRetainingCapacity(base_linear);

        // Only record signature after completing full prewarm pass, at that point atlas must be
        // complete for this text.
        // Note reading **after-pass** gc_generation: if forceEvictOldestPage triggers during
        // insertion, generation changes, can't use old value as baseline.
        self.text_renderer.prewarm_signature = signature;
        self.text_renderer.prewarm_gc_generation = self.text_renderer.atlas.gc_generation;
        self.text_renderer.prewarm_signature_valid = !self.text_renderer.atlas.had_transient_failure and seen_complete;
        std.mem.swap(std.AutoHashMapUnmanaged(u64, void), &tr.prewarm_known, &tr.prewarm_seen);
    }

    /// Identity of a text item for the prewarm: everything that selects its glyphs (the
    /// signature's per-item part; on Windows also its position, family and raster scale).
    fn prewarmItemKey(it: anytype, raster_scale: f32) u64 {
        var h = std.hash.Wyhash.init(0x7072_6577_61726d);
        h.update(it.text_content);
        var fixed: [12]u8 = undefined;
        @memcpy(fixed[0..4], std.mem.asBytes(&it.text_font_size));
        @memcpy(fixed[4..6], std.mem.asBytes(&it.text_font_weight));
        fixed[6] = it.text_font_flags;
        @memcpy(fixed[7..11], std.mem.asBytes(&it.text_monospace_char_width));
        fixed[11] = it.text_raster_policy;
        h.update(&fixed);
        if (comptime @import("builtin").os.tag == .windows) {
            h.update(std.mem.asBytes(&it.geom));
            h.update(std.mem.asBytes(&it.text_font_family));
            h.update(std.mem.asBytes(&raster_scale));
        }
        return h.final();
    }

    /// Unified encoding loop:
    /// 1. Skip empty struct blocks (supports nesting)
    /// 2. Build locally-sortable clusters between struct boundaries
    /// 3. Remaining commands take normal dispatch
    pub fn encodeCommands(self: *RenderCommandEncoder, commands: anytype) !void {
        self.blur_applied_count = 0;
        self.glass_probe_owner_count = 0;
        if (@import("zenit_environment").flag("ZENIT_DEBUG_CMDSTREAM")) {
            std.debug.print("[cmdstream] ── frame {d} commands={d} ──\n", .{ self.frame_index, commands.len });
            for (commands, 0..) |it, ci| {
                if (it.kind == .control) {
                    std.debug.print("[cmdstream] {d}: ctl {s} geom=({d:.0},{d:.0},{d:.0}x{d:.0}) draw=({d:.0},{d:.0}) dt=({d:.0},{d:.0}) udt={}\n", .{
                        ci, @tagName(it.control_kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.draw_x, it.draw_y, it.draw_transform[4], it.draw_transform[5], it.use_draw_transform,
                    });
                } else {
                    std.debug.print("[cmdstream] {d}: {s} geom=({d:.0},{d:.0},{d:.0}x{d:.0}) a={d} txt=\"{s}\"\n", .{
                        ci, @tagName(it.kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.color.a, if (it.kind == .text) it.text_content[0..@min(it.text_content.len, 16)] else "",
                    });
                }
            }
        }
        self.computeRetainedContentHashes(commands);
        // A fixed zero-length array cannot instantiate dispatch indexing,
        // even though the normal loop would have no work at runtime.
        if (commands.len == 0) return;
        var cluster = LocalSortCluster{};
        var i: usize = 0;
        const skip = self.frame_damage_skip;
        var next_skip: usize = 0;
        while (i < commands.len) {
            // Outside the damage scissor: nothing of it would reach the target.
            if (next_skip < skip.len and skip[next_skip][0] == i) {
                // Keep the exclusive end address-sized even for a fixed array
                // of length zero or one (@min otherwise infers u0 for last).
                const end: usize = @min(@as(usize, skip[next_skip][1]) +| 1, commands.len);
                // Keep the prescan's begin_opacity_layer numbering (see the no-op block skip).
                for (commands[i..end]) |sk| {
                    if (sk.kind == .control and sk.control_kind == .begin_opacity_layer) self.retained_begin_seq += 1;
                }
                next_skip += 1;
                i = end;
                continue;
            }
            while (next_skip < skip.len and skip[next_skip][0] < i) next_skip += 1;
            const tok = paint_fp.structuralToken(commands[i]);
            if (paint_fp.isBeginStructuralToken(tok)) {
                if (paint_fp.tryFindNoOpStructuralBlock(commands, i)) |block| {
                    // GPU retained (2026-07-30 review fix): empty struct blocks fully skipped may
                    // contain begin_opacity_layer, prescan already numbered them; the code below
                    // must advance retained_begin_seq for each skipped begin_opacity_layer: if it
                    // did not, all subsequent layers would get a fingerprint shifted by one slot;
                    // a wrong fingerprint that is stable across frames means changed content is
                    // judged a cache hit and the screen shows stale content.
                    for (commands[i .. block.end_index + 1]) |sk| {
                        if (sk.kind == .control and sk.control_kind == .begin_opacity_layer) {
                            self.retained_begin_seq += 1;
                        }
                    }
                    i = block.end_index + 1;
                    continue;
                }
            }
            if (tok != .none) {
                try self.flushLocalSortCluster(commands, &cluster);
                self.dispatch_item = @ptrCast(&commands[i]);
                try self.dispatchCommand(commands[i]);
                i += 1;
                continue;
            }

            switch (cluster.tryAppend(commands, i)) {
                .none => {},
                .overlap => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    const retry = cluster.tryAppend(commands, i);
                    if (retry != .none) {
                        self.dispatch_item = @ptrCast(&commands[i]);
                        try self.dispatchCommand(commands[i]);
                    }
                },
                .capacity => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    const retry = cluster.tryAppend(commands, i);
                    if (retry != .none) {
                        self.dispatch_item = @ptrCast(&commands[i]);
                        try self.dispatchCommand(commands[i]);
                    }
                },
                .unsortable => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    self.dispatch_item = @ptrCast(&commands[i]);
                    try self.dispatchCommand(commands[i]);
                },
            }
            i += 1;
        }
        try self.flushLocalSortCluster(commands, &cluster);
    }

    /// GPU retained **content fingerprint** prescan.
    ///
    /// Why not use DisplayItem's `surface_content_version` directly: it is the layer's **own root**
    /// content version (node_dirty markLayoutDirty etc. +1); descendant content changes do not bump
    /// it. The CPU-side cache is safe only because it separately checks the `subtree_render` dirty
    /// bit, which the encoder cannot see. Using it directly makes Modal reuse a cached empty
    /// texture from the previous frame and the whole dialog fails to draw.
    ///
    /// Instead, hash the **actual commands to encode** within begin..end: changed content must
    /// change
    /// the fingerprint, unchanged content keeps it; independent of descendant depth and of upstream
    /// dirty-mark semantics. Cost: one linear scan per frame (no allocation, pure arithmetic).
    ///
    /// The fingerprint covers fields affecting **offscreen texture pixels only**. Composite params
    /// (opacity/transform/draw_*) are **intentionally excluded**: they only affect compositing, and
    /// retained exists to save work when "content is unchanged, only transform/opacity changed".
    pub fn computeRetainedContentHashes(self: *RenderCommandEncoder, commands: anytype) void {
        retained_plan.scan(self, commands, self.image_renderer);
    }

    /// Feed paint command's **pixel-affecting** fields into fingerprint. Overfeed OK (extra
    /// repaint); underfeed fatal (content changed but hit = stale screen).
    fn flushLocalSortCluster(self: *RenderCommandEncoder, commands: anytype, cluster: *LocalSortCluster) !void {
        if (cluster.isEmpty()) return;

        var dispatch_order_buf: [local_sort_cluster_capacity]usize = undefined;
        const dispatch_order = cluster.buildDispatchOrder(&dispatch_order_buf);

        for (dispatch_order) |index| {
            try self.dispatchCommand(commands[index]);
        }
        cluster.clear();
    }

    /// Unified command dispatch via anytype on the DisplayItem union (render module does not depend
    /// on ui directly).
    ///
    /// Z-order barrier: SDF (rect/border/shadow) and text use different GPU pipelines; instances
    /// accumulate separately and flush in batches. The default flush order SDF->Image->Text puts
    /// backgrounds under text, but the node tree z-order may want a "later background covers
    /// earlier
    /// text" (sticky gutter over scroll text, z-index overlay).
    /// So before dispatching an SDF command, if the text/image/icon pipelines have pending
    /// instances, this SDF must paint above them: flush all pipelines first and start a new batch.
    /// Get the current offscreen layer coordinate offset (screen coord -> offscreen local coord).
    /// Returns (0, 0) in the main pass; (-layer.x, -layer.y) in an offscreen layer.
    pub inline fn offscreenOffset(self: *const RenderCommandEncoder) [2]f32 {
        // Accumulate all nested layer offsets
        // Note: offscreen_stack[i].x/y is **that layer's outer-local coord within parent surface**
        // (not world).
        // beginOpacityLayer subtracts outer-layer accumulation before pushing (see
        // beginOpacityLayer's outer-local conversion).
        // Thus child paint's world coord minus accumulation = inner-surface-local.
        var dx: f32 = -self.root_crop_origin[0];
        var dy: f32 = -self.root_crop_origin[1];
        for (self.offscreen_stack[0..self.offscreen_depth]) |layer| {
            dx -= layer.x;
            dy -= layer.y;
        }
        return .{ dx, dy };
    }

    test "root crop composes with nested target coordinates" {
        var enc = RenderCommandEncoder.init(undefined, undefined, undefined, undefined);
        enc.root_crop_origin = .{ 20, 40 };
        try std.testing.expectEqual([2]f32{ -20, -40 }, enc.offscreenOffset());
        enc.offscreen_stack[0] = undefined;
        enc.offscreen_stack[0].x = 3;
        enc.offscreen_stack[0].y = 4;
        enc.offscreen_depth = 1;
        try std.testing.expectEqual([2]f32{ -23, -44 }, enc.offscreenOffset());
    }

    pub inline fn localizeDrawTransformForCurrentTarget(self: *const RenderCommandEncoder, draw_transform: [6]f32) [6]f32 {
        var localized = draw_transform;
        const off = self.offscreenOffset();
        localized[4] += off[0];
        localized[5] += off[1];
        return localized;
    }

    // Clip geometry algebra pure function cluster extracted to command_encoder/clip_geometry.zig
    // (compare/intersect/normalize); encoder keeps **stack** push/pop only.
    const roundedClipEqual = clip_geometry.roundedClipEqual;
    const clipPolygonEqual = clip_geometry.clipPolygonEqual;

    /// The shape clip in force in the current target: the innermost non-rect stack entry. It is
    /// the target's whole shape clip, not just the innermost one, because display-list pushes go
    /// through pushClipCommand, which never leaves an outer shape that still matters behind it.
    pub fn activeRoundedClip(self: *const RenderCommandEncoder) ?RoundedClipState {
        var i = self.clip_depth;
        while (i > 0) {
            i -= 1;
            const clip = self.logical_clip_stack[i];
            if (clip.shape_kind != .rect) return clip;
        }
        return null;
    }

    pub fn currentRectClip(self: *const RenderCommandEncoder) ?[4]f32 {
        if (self.clip_depth == 0) return null;
        return self.effective_rect_clip_stack[self.clip_depth - 1];
    }

    /// Bind the acquired target's physical extent, including fractional Cocoa bounds.
    pub fn setDrawableExtent(self: *RenderCommandEncoder, width: u32, height: u32) void {
        self.drawable_extent = .{ width, height };
        self.applyDrawableViewport();
    }

    fn applyDrawableViewport(self: *RenderCommandEncoder) void {
        const w: f32 = @floatFromInt(self.drawable_extent[0]);
        const h: f32 = @floatFromInt(self.drawable_extent[1]);
        self.sdf_renderer.viewport_width = w;
        self.sdf_renderer.viewport_height = h;
        self.text_renderer.viewport_width = w;
        self.text_renderer.viewport_height = h;
        if (self.image_renderer) |ir| {
            ir.viewport_width = w;
            ir.viewport_height = h;
        }
        if (self.icon_renderer) |ir| {
            ir.viewport_width = w;
            ir.viewport_height = h;
        }
        if (self.persistent.path_renderer) |*pr| pr.raster_viewport = .{ w, h };
    }

    /// Unified viewport+scissor setup after render pass re-open: when target is offscreen, clip to
    /// layer's used region (bucket-allocated larger than content, NDC default fills alloc,
    /// stretching); main target, scissor full drawable.
    pub fn applyOffscreenTargetViewport(self: *RenderCommandEncoder) void {
        const rp = self.render_pass orelse return;
        if (comptime gpu.backend_kind == .metal) {
            rp.root_crop = if (self.offscreen_depth == 0) self.root_target_crop else null;
            rp.root_offset = if (self.offscreen_depth == 0) self.root_target_offset else .{ 0, 0 };
        }
        if (self.offscreen_depth > 0) {
            const layer = self.offscreen_stack[self.offscreen_depth - 1];
            if (layer.used_tex_w == 0 or layer.used_tex_h == 0) return;
            // the content's exact extent, as when the layer opened (opacity_layer: w x raster scale)
            const vw: f32 = if (layer.raster_scale > 0) layer.w * layer.raster_scale else @floatFromInt(layer.used_tex_w);
            const vh: f32 = if (layer.raster_scale > 0) layer.h * layer.raster_scale else @floatFromInt(layer.used_tex_h);
            rp.setViewport(0, 0, vw, vh, 0, 1);
            // damage-rect: partial-repaint layer scissor must re-intersect after each pass restore
            // (nested pass re-begin resets scissor to full texture).
            if (layer.damage_scissor) |d| {
                const x1 = @min(d.x + d.w, layer.used_tex_w);
                const y1 = @min(d.y + d.h, layer.used_tex_h);
                rp.setScissorRect(d.x, d.y, x1 -| d.x, y1 -| d.y);
                if (self.persistent.path_renderer) |*pr| pr.damage_scissor = .{ d.x, d.y, x1 -| d.x, y1 -| d.y };
            } else {
                rp.setScissorRect(0, 0, layer.used_tex_w, layer.used_tex_h);
                if (self.persistent.path_renderer) |*pr| pr.damage_scissor = null;
            }
        } else {
            const vw = self.drawable_extent[0];
            const vh = self.drawable_extent[1];
            self.applyDrawableViewport();
            rp.setViewport(0, 0, @floatFromInt(vw), @floatFromInt(vh), 0, 1);
            const rect = self.frame_damage_scissor orelse [4]u32{ 0, 0, vw, vh };
            rp.setScissorRect(rect[0], rect[1], rect[2], rect[3]);
            if (self.persistent.path_renderer) |*pr| pr.damage_scissor = self.frame_damage_scissor;
        }
    }

    pub fn syncRectClipState(self: *RenderCommandEncoder) void {
        const rect = self.currentRectClip();
        self.sdf_renderer.setRectClip(rect);
        self.text_renderer.setRectClip(rect);
        if (self.image_renderer) |ir| ir.setRectClip(rect);
        if (self.icon_renderer) |ir| ir.setRectClip(rect);
        if (self.persistent.path_renderer) |*pr| pr.setRectClip(rect);
    }

    pub const intersectClipRects = clip_geometry.intersectClipRects;

    // backdrop capture region parsing (static, no self) extracted to
    // command_encoder/backdrop_capture.zig. backdrop_blur.zig call is
    // TypeOf(encoder.*).computeBackdropCaptureRegion(...) reflective; keeping same decl here = zero
    // changes; type re-exported.
    // Pixel-domain primitives at file head (pixel_domain.zig); don't re-forward from here to avoid
    // ambiguity.
    pub const BackdropCaptureRegion = backdrop_capture.BackdropCaptureRegion;
    pub const computeBackdropCaptureRegion = backdrop_capture.computeBackdropCaptureRegion;

    /// Copy the pixels a main-target glass composite just produced (its whole
    /// capture rect) for glass_capture. Only for a full repaint of the main
    /// target: a damage scissor leaves stale pixels inside the rect.
    fn captureGlassUnderlay(self: *RenderCommandEncoder) !void {
        const capture = self.glass_capture orelse return;
        const rect = self.last_glass_capture orelse return;
        const item = self.dispatch_item orelse return;
        if (self.offscreen_depth != 0 or self.render_pass == null) return;
        // Under a damage scissor the target outside it still shows the presented
        // frame: only a rect inside it holds what this composite produced.
        if (self.frame_damage_scissor) |d| {
            if (rect[0] < d[0] or rect[1] < d[1] or rect[0] + rect[2] > d[0] + d[2] or rect[1] + rect[3] > d[1] + d[3]) return;
        }
        const rt = self.main_render_target orelse return;
        const ir = self.image_renderer orelse return;
        const destination = capture.target(capture.ctx, item, rect) orelse return;
        try self.flushAllPending();
        self.render_pass.?.end();
        self.render_pass = null;
        defer if (self.render_pass == null) {
            _ = backdrop_blur.restoreRenderTargetPass(self, rt, ir, self.scale);
        };
        try self.copyTextureRegion(rt, rect[0], rect[1], rect[2], rect[3], destination, 0, 0, false);
    }

    pub fn copyTextureRegion(self: *RenderCommandEncoder, source: gpu.Backend.TextureBinding, sx: u32, sy: u32, width: u32, height: u32, destination: gpu.Backend.TextureBinding, dx: u32, dy: u32, clear: bool) !void {
        return gpu.copyTextureRegionAudited(self.gpu_command_encoder.?, source, sx, sy, width, height, destination, dx, dy, clear, .{
            .pass_count = &self.pass_count,
            .pass_sites = &self.pass_sites,
        });
    }

    pub fn clearTextureToTransparent(self: *RenderCommandEncoder, texture: gpu.Backend.TextureBinding) bool {
        var view = texture.createView();
        const pass = self.gpu_command_encoder.?.beginRenderPass(.{
            .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            }},
        }) catch {
            view.destroy();
            return false;
        };
        self.pass_count += 1; // v0.9-§D audit
        self.pass_sites[4] += 1; // clear_texture
        view.destroy();
        var mutable_pass = pass;
        mutable_pass.end();
        return true;
    }

    /// Flush all pending batches.
    ///
    /// WARNING: **exhaustion of a single renderer's resources must not abort whole-frame
    /// encoding**.
    ///
    /// If every flush used `try`, any renderer returning `UniformSlotsExhausted` (256 per-frame
    /// slots, one rounded-clip change = one slot) would propagate via `flushAllPending ->
    /// dispatchCommand -> encodeCommands` to the top, where the caller's
    /// `enc.encodeDisplay(...) catch {}` swallows it and all later commands are silently dropped.
    /// E.g. a 52-line git diff on scroll (one clip change per line) exhausted 256 slots mid-frame
    /// and
    /// the action bar vanished, while layout rects / display list / command stream all looked
    /// normal.
    ///
    /// So each renderer catches separately: one failure only loses its own batch; later renderers
    /// and
    /// commands encode normally. Error counts stay in the renderers for diagnostics.
    pub fn flushAllPending(self: *RenderCommandEncoder) !void {
        if (comptime gpu.backend_kind == .metal) if (self.cpu_flat_target) |target| {
            const path_pending = if (self.persistent.path_renderer) |*pr| pr.vertices.items.len > 0 else false;
            if (path_pending) return error.CpuFlatUnsupportedPath;
            return self.cpuFlushRenderers(target, true, true, true);
        };
        const rp = self.render_pass orelse return;
        if (self.sdf_renderer.instances.items.len > 0) {
            self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
        }
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
        }
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
        }
        if (self.persistent.path_renderer) |*pr| {
            if (pr.vertices.items.len > 0) pr.flush(rp) catch |err| self.noteFlushDropped("path", err);
        }
        if (self.text_renderer.getPendingInstanceCount() > 0) {
            self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn noteFlushDropped(self: *RenderCommandEncoder, comptime which: []const u8, err: anyerror) void {
        _ = self;
        std.log.warn("[encoder] " ++ which ++ " flush dropped a batch: {s} (frame continues)", .{@errorName(err)});
    }

    /// Before encoding path command: flush all except path (ensure path paints on top), path itself
    /// stays in path_renderer for cross-command batching.
    fn flushNonPathPending(self: *RenderCommandEncoder) !void {
        if (comptime gpu.backend_kind == .metal) if (self.cpu_flat_target) |target| return self.cpuFlushRenderers(target, true, true, true);
        const rp = self.render_pass orelse return;
        if (self.sdf_renderer.instances.items.len > 0) self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
        }
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
        }
        if (self.text_renderer.getPendingInstanceCount() > 0) {
            self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn flushPathPending(self: *RenderCommandEncoder) !void {
        if (self.persistent.path_renderer) |*pr| {
            if (pr.draw_calls.items.len > 0) {
                if (self.render_pass) |rp| pr.flush(rp) catch |err| self.noteFlushDropped("path", err);
            }
        }
    }

    fn syncClipStateAfterMutation(self: *RenderCommandEncoder, prev_shape_clip: ?RoundedClipState) !void {
        const next_shape_clip = self.activeRoundedClip();
        if (!roundedClipEqual(prev_shape_clip, next_shape_clip)) {
            try self.flushAllPending();
        }
        self.syncRectClipState();
        self.syncRendererClipMask();
        self.syncTextClipX();
    }

    fn forceRoundedClipLayer(self: *RenderCommandEncoder) bool {
        return self.force_rounded_clip_layer orelse blk: {
            const forced = @import("zenit_environment").flag("ZENIT_ROUNDED_CLIP_LAYER");
            self.force_rounded_clip_layer = forced;
            break :blk forced;
        };
    }

    pub fn syncRendererClipMask(self: *RenderCommandEncoder) void {
        const active = self.activeRoundedClip();
        if (self.clip_mask_synced and roundedClipEqual(self.last_synced_clip_mask, active)) return;
        self.clip_mask_synced = true;
        self.last_synced_clip_mask = active;
        if (active) |clip| {
            const rect = [4]f32{ clip.x, clip.y, clip.w, clip.h };
            const fill_rule: u32 = @backingInt(clip.polygon.fill_rule);
            const point_count: u32 = clip.polygon.point_count;
            const contour_count: u32 = clip.polygon.contour_count;
            self.sdf_renderer.setClipMask(@backingInt(clip.shape_kind), rect, clip.radii, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            self.text_renderer.setClipMask(@backingInt(clip.shape_kind), rect, clip.radii, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.image_renderer) |ir| ir.setClipMask(@backingInt(clip.shape_kind), rect, clip.radii, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.icon_renderer) |ir| ir.setClipMask(@backingInt(clip.shape_kind), rect, clip.radii, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.persistent.path_renderer) |*pr| pr.setClipMask(@backingInt(clip.shape_kind), rect, clip.radii);
            const partner = PartnerClip.uniform(clip.partner);
            self.sdf_renderer.setPartnerClip(partner);
            self.text_renderer.setPartnerClip(partner);
            if (self.image_renderer) |ir| ir.setPartnerClip(partner);
            if (self.icon_renderer) |ir| ir.setPartnerClip(partner);
            if (self.persistent.path_renderer) |*pr| pr.setPartnerClip(partner);
        } else {
            const empty_points = @as([max_clip_polygon_points][2]f32, @splat(.{ 0, 0 }));
            const empty_contours = @as([max_clip_polygon_contours]u8, @splat(0));
            self.sdf_renderer.setClipMask(0, null, .{ 0, 0, 0, 0 }, 0, 0, 0, empty_contours, empty_points);
            self.text_renderer.setClipMask(0, null, .{ 0, 0, 0, 0 }, 0, 0, 0, empty_contours, empty_points);
            if (self.image_renderer) |ir| ir.setClipMask(0, null, .{ 0, 0, 0, 0 }, 0, 0, 0, empty_contours, empty_points);
            if (self.icon_renderer) |ir| ir.setClipMask(0, null, .{ 0, 0, 0, 0 }, 0, 0, 0, empty_contours, empty_points);
            if (self.persistent.path_renderer) |*pr| pr.setClipMask(0, null, .{ 0, 0, 0, 0 });
        }
    }

    inline fn coerceClipShapeKind(shape_kind: anytype) ClipShapeKind {
        return @fromBackingInt(@intCast(@backingInt(shape_kind)));
    }

    inline fn coercePathFillRule(fill_rule: anytype) PathFillRule {
        return @fromBackingInt(@intCast(@backingInt(fill_rule)));
    }

    fn coerceClipPolygon(polygon: anytype) ClipPolygon {
        return clip_geometry.coerceClipPolygon(ClipPolygon, polygon, coercePathFillRule);
    }

    /// dispatchCommand main path, takes paint_table.DisplayItem.
    ///
    /// `it` is anytype so the encoder does not reference ui-side types; duck-types the
    /// .kind/.control_kind/.geom/.color/.radii etc. fields.
    ///
    /// kind to source variant mapping (written by lowerDisplayItem):
    ///   .rect: fill_rect (stroke_width=0, noise_intensity=0, border_widths=0) /
    ///          stroke_rect (stroke_width>0) / outline_rect (stroke_width>0) /
    ///          border_per_side (border_widths!=0) / noise_rect (noise_intensity>0)
    ///   .text: text_run
    ///   .image: image_quad (icon_rep_ptr=null) / icon_rep (icon_rep_ptr!=null)
    ///   .shadow: shadow_rect (shadow_secondary.a=0 shadow2_color.a=0) /
    ///            inset_shadow_rect (shadow_secondary.a>0 shadow2_color.a=0) /
    ///            shadow_dual_rect (shadow2_color.a>0)
    ///   .gradient: gradient_rect (mg_stop_count=0) / multi_gradient_rect (mg_stop_count>0)
    ///   .path: arc (arc_outer_radius>0) / fill_path (path_geometry_ptr stroke_width=0) /
    ///          stroke_path (path_geometry_ptr stroke_width>0)
    ///   .control: 8 control kinds via control_kind enum
    fn hasOpaqueTextBackdrop(self: *const RenderCommandEncoder, item: anytype) bool {
        var state = self.text_layers;
        state.offscreen_depth = self.offscreen_depth;
        state.transformed = item.use_draw_transform;
        state.animated = item.text_raster_policy != 0;
        state.clip_overflow = self.clip_overflow_depth != 0 or self.rounded_clip_overflow_depth != 0;
        state.alpha = @as(f32, @floatFromInt(item.color.a)) / 255;
        // The renderer checks the actual raster quad against this frame's proof.
        return state.allowsLCD(self.text_backdrop.any_opaque);
    }

    fn dispatchCommand(self: *RenderCommandEncoder, it: anytype) !void {
        const at_main_depth = self.offscreen_depth == 0;
        defer if (at_main_depth) self.noteGlassBankDirty(it);
        if (comptime @import("builtin").os.tag == .windows) {
            if (it.kind == .control) switch (it.control_kind) {
                .begin_opacity_layer => self.text_layers.opacity_depth += 1,
                .end_opacity_layer => self.text_layers.opacity_depth -|= 1,
                .begin_blur_layer => self.text_layers.blur_depth += 1,
                .end_blur_layer => self.text_layers.blur_depth -|= 1,
                .begin_rounded_clip => self.text_layers.rounded_depth += 1,
                .end_rounded_clip => self.text_layers.rounded_depth -|= 1,
                .none, .push_clip, .pop_clip => {},
            };
        }
        // GPU retained hit: begin..end content already in cached texture, skip all.
        // Just count paired begin/end to find this layer's end position.
        if (self.retained_skip_depth > 0) {
            if (it.kind == .control) {
                switch (it.control_kind) {
                    .begin_opacity_layer => {
                        // Skipped inner begin also takes prescan slot, sequence number must advance
                        // or later layers read wrong fingerprints.
                        self.retained_begin_seq += 1;
                        self.retained_skip_depth += 1;
                    },
                    .begin_blur_layer, .begin_rounded_clip => {
                        self.retained_skip_depth += 1;
                    },
                    .end_opacity_layer, .end_blur_layer, .end_rounded_clip => {
                        self.retained_skip_depth -= 1;
                        if (self.retained_skip_depth == 0) try self.compositeRetainedLayer();
                    },
                    else => {},
                }
            }
            return;
        }

        const off = self.offscreenOffset();
        const ox = off[0];
        const oy = off[1];

        // path batching order fence: when path pending exists, any non-path-pipeline command
        // (including arc via sdf) must flush path first, else late path flush covers later content.
        // path command itself does reverse flushNonPathPending in .path branch.
        // WARNING: "is it arc" must have one criterion only. Previously here arc_outer_radius <= 0,
        // .path branch used (radius>0 and stroke>0 and alpha>0), difference
        // (zero-width/fully-transparent arc) falls into fill_path branch, but arc command never
        // sets path_geometry_ptr => orelse return silently drops.
        const is_arc = isArcCommand(it);
        const is_batched_path = it.kind == .path and !is_arc;
        if (!is_batched_path) try self.flushPathPending();

        switch (it.kind) {
            .none => return,
            .rect => {
                // Shape context: non-rect (ellipse) means all instances from this command
                // (fill/stroke/gradient/noise/shadow) use that shape's SDF.
                // defer reset **mandatory**, residual taints unrelated rects with ellipse.
                self.sdf_renderer.current_shape =
                    if (it.shape_kind == 1) .ellipse else .rect;
                defer self.sdf_renderer.current_shape = .rect;
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPendingUnder(it, ox, oy);
                const radii = it.radii.toArray();
                if (comptime @import("builtin").os.tag == .windows) {
                    if (self.text_layers.allowsLCD(true) and self.offscreen_depth == 0 and self.activeRoundedClip() == null and !it.use_draw_transform and it.color.a == 255 and it.shape_kind == 0 and
                        it.stroke_width == 0 and it.noise_intensity == 0 and it.border_widths[0] == 0 and it.border_widths[1] == 0 and it.border_widths[2] == 0 and it.border_widths[3] == 0)
                    {
                        const inset = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3])) + 1 / self.scale;
                        var rect: [4]f32 = .{ if (inset <= 1 / self.scale and it.geom.x <= 0) 0 else it.geom.x + inset, if (inset <= 1 / self.scale and it.geom.y <= 0) 0 else it.geom.y + inset, if (inset <= 1 / self.scale and it.geom.x + w >= self.viewport_width) self.viewport_width else it.geom.x + w - inset, if (inset <= 1 / self.scale and it.geom.y + h >= self.viewport_height) self.viewport_height else it.geom.y + h - inset };
                        if (self.currentRectClip()) |clip| {
                            const r = &rect;
                            r[0] = @max(r[0], clip[0]);
                            r[1] = @max(r[1], clip[1]);
                            r[2] = @min(r[2], clip[0] + clip[2]);
                            r[3] = @min(r[3], clip[1] + clip[3]);
                        }
                        self.text_backdrop.add(rect);
                    }
                }
                // noise_rect: noise_intensity > 0 is condition (even if fill.a == 0, still draw)
                if (it.noise_intensity > 0 and self.visual_quality != .basic) {
                    try self.sdf_renderer.addNoiseRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        @fromBackingInt(@intCast(it.noise_mode)),
                        it.noise_scale,
                        it.noise_intensity,
                        it.noise_seed,
                        radii,
                    );
                    return;
                }
                if (it.color.a == 0) return;
                // border_per_side: any width > 0
                const any_border_width = it.border_widths[0] > 0 or it.border_widths[1] > 0 or
                    it.border_widths[2] > 0 or it.border_widths[3] > 0;
                // Ellipse: fill+stroke both call addEllipse (shape_type=4 SDF) **before** per-side
                // / stroke / fill rect paths: all three write shape_type=rect, ellipse falls
                // through to rounded rect (wide aspect ratio = "capsule").
                // per-side width collapses to uniform at entry; ellipse has no "four edges", shader
                // per-side branch hardcodes rect inner contour.
                if (it.shape_kind == 1) {
                    try self.sdf_renderer.addEllipse(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        if (it.stroke_width > 0 or any_border_width)
                            .{ 0, 0, 0, 0 }
                        else
                            colorToFloat4(it.color),
                        if (it.stroke_width > 0 or any_border_width)
                            colorToFloat4(it.color)
                        else
                            .{ 0, 0, 0, 0 },
                        it.stroke_width,
                        it.border_widths,
                    );
                    return;
                }
                if (any_border_width) {
                    try self.sdf_renderer.addBorderedRectPerSide(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        .{ 0, 0, 0, 0 },
                        colorToFloat4(it.color),
                        it.border_widths,
                        radii,
                    );
                    return;
                }
                // stroke_rect / outline_rect (both use addBorderedRect)
                if (it.stroke_width > 0) {
                    try self.sdf_renderer.addBorderedRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        .{ 0, 0, 0, 0 },
                        colorToFloat4(it.color),
                        it.stroke_width,
                        radii,
                    );
                    return;
                }
                // fill_rect (default)
                try self.sdf_renderer.addRoundedRect(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    colorToFloat4(it.color),
                    radii,
                );
            },
            .text => try self.encodeTextCommand(it, ox, oy),
            .image => {
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0 or it.image_opacity <= 0) return;
                try self.flushIfTextPendingUnder(it, ox, oy);
                if (it.icon_rep_ptr) |rep_ptr| {
                    // icon_rep
                    try self.flushIfImagePending();
                    if (self.icon_renderer) |ir| {
                        try ir.addIcon(
                            @intCast(it.resource_handle),
                            rep_ptr.*,
                            it.geom.x + ox,
                            it.geom.y + oy,
                            w,
                            h,
                            colorToFloat4(it.icon_tint),
                            it.icon_corner_clip_radius,
                            it.image_opacity,
                            it.rotate,
                            it.icon_snap,
                        );
                    }
                } else {
                    // image_quad
                    try self.flushIfIconPending();
                    if (self.image_renderer) |ir| {
                        try addImageOrSkip(
                            ir,
                            it.resource_handle,
                            it.geom.x + ox,
                            it.geom.y + oy,
                            w,
                            h,
                            colorToFloat4(it.image_tint),
                            it.image_corner_radius,
                            it.image_opacity,
                            it.rotate,
                        );
                    }
                }
            },
            .shadow => {
                if (self.visual_quality == .basic) {
                    // Inset/dual shadow commands carry the surface fill too.
                    // Drop only decoration, never the underlying control body.
                    if ((it.shadow_secondary_color.a > 0 or it.shadow2_color.a > 0) and it.color.a > 0) {
                        try self.flushIfTextPendingUnder(it, ox, oy);
                        try self.sdf_renderer.addRoundedRect(it.geom.x + ox, it.geom.y + oy, it.geom.w, it.geom.h, colorToFloat4(it.color), it.radii.toArray());
                    }
                    return;
                }
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPendingUnder(it, ox, oy);
                const radii = it.radii.toArray();
                // shadow_dual: shadow2_color.a > 0
                if (it.shadow2_color.a > 0) {
                    try self.sdf_renderer.addDualShadowRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        colorToFloat4(it.shadow_secondary_color),
                        it.shadow_blur,
                        it.shadow_offset_x,
                        it.shadow_offset_y,
                        sdf.ShadowParam{
                            .color = colorToFloat4(it.shadow2_color),
                            .blur = it.shadow2_blur,
                            .offset_x = it.shadow2_offset_x,
                            .offset_y = it.shadow2_offset_y,
                        },
                        radii,
                    );
                    return;
                }
                // inset_shadow: shadow_secondary.a > 0 (shadow_color field)
                if (it.shadow_secondary_color.a > 0) {
                    try self.sdf_renderer.addInsetShadowRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        colorToFloat4(it.shadow_secondary_color),
                        it.shadow_blur,
                        it.shadow_offset_x,
                        it.shadow_offset_y,
                        radii,
                    );
                    return;
                }
                // Normal shadow_rect
                if (it.color.a == 0) return;
                try self.sdf_renderer.addShadowRectSpread(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    .{ 0, 0, 0, 0 },
                    colorToFloat4(it.color),
                    it.shadow_blur,
                    it.shadow_offset_x,
                    it.shadow_offset_y,
                    it.shadow_spread,
                    radii,
                );
            },
            .gradient => {
                // Gradient must obey shape: else ellipse/circle gradient fills bounding box (user
                // real capture: gradient quad outside ellipse).
                // Same discipline as .rect; defer reset prevents residual tainting later rects.
                self.sdf_renderer.current_shape =
                    if (it.shape_kind == 1) .ellipse else .rect;
                defer self.sdf_renderer.current_shape = .rect;
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPendingUnder(it, ox, oy);
                const radii = it.radii.toArray();
                if (it.mg_stop_count > 0) {
                    // multi_gradient_rect
                    var stops_buf: [16]sdf.GradientStop = undefined;
                    const cnt = @min(@as(usize, it.mg_stop_count), 16);
                    for (0..cnt) |i| {
                        stops_buf[i] = .{
                            .color = colorToFloat4(it.mg_stop_colors[i]),
                            .position = it.mg_stop_positions[i],
                        };
                    }
                    try self.sdf_renderer.addMultiGradientRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        stops_buf[0..cnt],
                        gradientDirToSDFFromU8(it.gradient_direction),
                        radii,
                        it.gradient_radial_center_x,
                        it.gradient_radial_center_y,
                        it.gradient_conic_start_angle,
                        extendModeToSDFFromU8(it.gradient_extend_mode),
                        .{ it.gradient_radial_radius_x, it.gradient_radial_radius_y },
                    );
                    return;
                }
                // Normal gradient_rect
                if (it.color.a == 0 and it.gradient_to_color.a == 0) return;
                try self.encodeGradient(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    it.color,
                    it.gradient_to_color,
                    gradientDirToSDFFromU8(it.gradient_direction),
                    radii,
                    it.gradient_radial_center_x,
                    it.gradient_radial_center_y,
                    it.gradient_conic_start_angle,
                    extendModeToSDFFromU8(it.gradient_extend_mode),
                );
            },
            .path => {
                if (is_arc) {
                    // Zero-width / fully-transparent arc has no visible pixels, early exit.
                    // Key: **can't** continue down: arc command carries no path_geometry_ptr,
                    // fill_path branch silently drops.
                    if (it.stroke_width <= 0 or it.color.a == 0) return;
                    try self.flushIfTextPendingUnder(it, ox, oy);
                    try self.sdf_renderer.addArc(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.arc_outer_radius,
                        it.stroke_width,
                        it.arc_start_angle,
                        it.arc_end_angle,
                        colorToFloat4(it.color),
                    );
                    return;
                }
                // fill_path / stroke_path: flush other pipelines first for z-order, self
                // accumulates in path_renderer, consecutive paths merge into one flush (reverse
                // fence at dispatchCommand top: non-path command flushes path pending).
                const geo_ptr = it.path_geometry_ptr orelse return;
                try self.flushNonPathPending();
                if (it.stroke_width > 0) {
                    try self.encodeStrokePathPaint(it, geo_ptr);
                } else {
                    try self.encodeFillPathPaint(it, geo_ptr);
                }
            },
            .control => {
                try self.dispatchControlKind(it);
            },
        }
    }

    /// GPU retained hit composite finish (content pass skipped, composite cached texture once).
    fn compositeRetainedLayer(self: *RenderCommandEncoder) !void {
        try opacity_layer.compositeRetainedLayer(self);
    }

    /// control kind dispatch (8 sub-kinds via control_kind enum)
    fn dispatchControlKind(self: *RenderCommandEncoder, it: anytype) !void {
        const off = self.offscreenOffset();
        const ox = off[0];
        const oy = off[1];
        switch (it.control_kind) {
            .none => return,
            .push_clip => {
                if (@import("zenit_environment").flag("ZENIT_DEBUG_SURFDUMP") and self.offscreen_depth > 0) {
                    std.debug.print("[surfclip] depth={d} clip=({d:.1},{d:.1},{d:.1},{d:.1}) off=({d:.1},{d:.1})\n", .{
                        self.offscreen_depth, it.geom.x, it.geom.y, it.geom.w, it.geom.h, ox, oy,
                    });
                }
                // shape_kind 0/1/2/3 (rect/rounded_rect/ellipse/polygon). polygon gets source
                // ClipPolygon ptr via clip_polygon_ptr, others use inline fields.
                const polygon: ClipPolygon = if (it.clip_polygon_ptr) |pp|
                    coerceClipPolygon(pp.*)
                else
                    ClipPolygon.empty();
                const mode = try self.pushClipCommand(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    it.geom.w,
                    it.geom.h,
                    cornerRadiiArray(it.radii),
                    @fromBackingInt(@intCast(it.clip_shape_kind)),
                    polygon,
                );
                if (self.push_clip_mode_overflow_depth > 0 or self.push_clip_mode_depth >= self.push_clip_mode_stack.len) {
                    // Only a plain clip can land here: pushClipCommand never isolates once the
                    // mode stack is full (see there).
                    self.push_clip_mode_overflow_depth +|= 1;
                } else {
                    self.push_clip_mode_stack[self.push_clip_mode_depth] = mode;
                    self.push_clip_mode_depth += 1;
                }
            },
            .pop_clip => {
                if (self.push_clip_mode_overflow_depth > 0) {
                    self.push_clip_mode_overflow_depth -= 1;
                    try self.popClip();
                    return;
                }
                const mode: PushClipMode = if (self.push_clip_mode_depth > 0) blk: {
                    self.push_clip_mode_depth -= 1;
                    break :blk self.push_clip_mode_stack[self.push_clip_mode_depth];
                } else .clip;
                try self.popClip();
                if (mode == .isolated) try opacity_layer.endOpacityLayer(self);
            },
            .begin_opacity_layer => {
                const aligned = opacity_layer.alignTranslationSurface(it, self.scale, self.offscreenOffset());
                // A rounded layer composites its own rect (the mask) from the aligned texture.
                const quad: [4]f32 = if (maxCornerRadius(it.radii) >= 0.5) opacity_layer.maskQuad(it, aligned) else .{ 0, 0, 0, 0 };
                const content_seq = self.retained_begin_seq;
                var content_hash: u64 = blk: {
                    const seq = self.retained_begin_seq;
                    self.retained_begin_seq += 1;
                    if (seq >= self.retained_hashes.len) break :blk 0;
                    if (seq >= self.retained_hash_count) break :blk 0;
                    break :blk self.retained_hashes[seq];
                };
                // A changed pixel phase must invalidate retained pixels even
                // when the allocation remains in the same size bucket.
                content_hash = opacity_layer.rasterContentHash(content_hash, aligned.geom, self.scale);
                const draw_x = if (std.math.isNan(aligned.draw_x)) aligned.geom.x else aligned.draw_x;
                const draw_y = if (std.math.isNan(aligned.draw_y)) aligned.geom.y else aligned.draw_y;
                const draw_w = if (std.math.isNan(aligned.draw_w)) aligned.geom.w else aligned.draw_w;
                const draw_h = if (std.math.isNan(aligned.draw_h)) aligned.geom.h else aligned.draw_h;
                const blend_mode_val: BlendMode = @fromBackingInt(@intCast(aligned.blend_mode));
                // Malformed/deep display lists degrade to a direct-rendering noop layer.
                // Never open an offscreen layer that cannot be paired in our mode stack.
                if (self.opacity_mode_overflow_depth > 0 or self.opacity_mode_depth >= self.opacity_mode_stack.len) {
                    self.opacity_mode_overflow_depth +|= 1;
                    return;
                }
                // With corner_radius (rounded-clip folded into opacity layer) can't take noop
                // shortcut, mask depends on composite blit.
                // A surface matrix maps local coordinates back to its envelope. Identity linear
                // terms plus the envelope origin cancel the localization; opaque normal groups need
                // no intermediate RT.
                const identity_surface = gpu.is_direct3d and aligned.use_draw_transform and
                    aligned.draw_transform[0] == 1 and aligned.draw_transform[1] == 0 and
                    aligned.draw_transform[2] == 0 and aligned.draw_transform[3] == 1 and
                    aligned.draw_transform[4] == aligned.geom.x and aligned.draw_transform[5] == aligned.geom.y;
                // A draw rect other than the source rect moves/scales the
                // layer's pixels: that needs the offscreen copy even when
                // opaque (a noop drew nested legacy layers at their source).
                const same_rect = @abs(draw_x - aligned.geom.x) < 1e-3 and @abs(draw_y - aligned.geom.y) < 1e-3 and
                    @abs(draw_w - aligned.geom.w) < 1e-3 and @abs(draw_h - aligned.geom.h) < 1e-3;
                const warp_active = aligned.warp[0] != 0 or aligned.warp[1] != 0;
                const trivial = aligned.opacity >= 0.999 and
                    blend_mode_val == .normal and
                    !warp_active and
                    (!aligned.use_draw_transform or identity_surface) and
                    (aligned.use_draw_transform or same_rect) and
                    aligned.rotate == 0 and
                    maxCornerRadius(aligned.radii) < 0.5;
                if (trivial) {
                    self.pushOpacityMode(.noop);
                } else switch (if (warp_active) opacity_layer.RetainedBegin.declined else try opacity_layer.tryBeginRetainedOpacityLayer(
                    self,
                    aligned.geom.x,
                    aligned.geom.y,
                    aligned.geom.w,
                    aligned.geom.h,
                    aligned.opacity,
                    aligned.rotate,
                    draw_x,
                    draw_y,
                    draw_w,
                    draw_h,
                    aligned.use_draw_transform,
                    aligned.draw_transform,
                    blend_mode_val,
                    cornerRadiiArray(aligned.radii),
                    aligned.surface_stable_id,
                    content_hash,
                    content_seq,
                )) {
                    // Hit: content pass fully skipped, end does one composite draw.
                    .hit => {
                        self.retained_skip_depth = 1;
                        if (self.retained_pending_depth > 0) self.retained_pending[self.retained_pending_depth - 1].quad = quad;
                    },
                    // retained already opened layer for us (draws to dedicated texture), encode
                    // content normally. **Must not call beginOpacityLayer again**, that stacks two
                    // layers.
                    .opened_for_repaint => {
                        self.pushOpacityMode(.layer);
                        if (self.offscreen_depth > 0) self.offscreen_stack[self.offscreen_depth - 1].quad = quad;
                    },
                    .declined => {
                        const opened = try opacity_layer.beginOpacityLayer(
                            self,
                            aligned.geom.x,
                            aligned.geom.y,
                            aligned.geom.w,
                            aligned.geom.h,
                            aligned.opacity,
                            aligned.rotate,
                            draw_x,
                            draw_y,
                            draw_w,
                            draw_h,
                            aligned.use_draw_transform,
                            aligned.draw_transform,
                            blend_mode_val,
                        );
                        self.pushOpacityMode(if (opened) .layer else .noop);
                        if (opened and maxCornerRadius(aligned.radii) >= 0.5 and self.offscreen_depth > 0) {
                            self.offscreen_stack[self.offscreen_depth - 1].corner_radii = cornerRadiiArray(aligned.radii);
                            self.offscreen_stack[self.offscreen_depth - 1].quad = quad;
                        }
                        if (opened and warp_active and self.offscreen_depth > 0) {
                            self.offscreen_stack[self.offscreen_depth - 1].warp = aligned.warp;
                        }
                    },
                }
            },
            .end_opacity_layer => {
                if (self.opacity_mode_overflow_depth > 0) {
                    self.opacity_mode_overflow_depth -= 1;
                    return;
                }
                const mode = self.popOpacityMode() orelse return;
                if (mode == .layer) try opacity_layer.endOpacityLayer(self);
            },
            .begin_rounded_clip => {
                if (self.rounded_clip_overflow_depth > 0 or self.rounded_clip_mode_depth >= self.rounded_clip_mode_stack.len) {
                    self.rounded_clip_overflow_depth +|= 1;
                    return;
                }
                // Shader clip path: axis-aligned (no rotate/draw_transform) && no other shape clip
                // occupying mask slot -> rounded-clip uses pipeline's existing fragment SDF clip,
                // saves whole offscreen round-trip (flush + end pass + clear pass + content +
                // composite pass). Else fallback to old offscreen layer path.
                const can_shader_clip = it.rotate == 0 and
                    !it.use_draw_transform and
                    self.activeRoundedClip() == null and
                    !self.forceRoundedClipLayer();
                if (@import("zenit_environment").flag("ZENIT_DEBUG_PASSCOUNT")) {
                    std.debug.print("[rclip] mode={s}\n", .{if (can_shader_clip) "shader" else "layer"});
                }
                if (can_shader_clip) {
                    try self.pushClip(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.geom.w,
                        it.geom.h,
                        cornerRadiiArray(it.radii),
                        .rounded_rect,
                        ClipPolygon.empty(),
                    );
                    self.rounded_clip_mode_stack[self.rounded_clip_mode_depth] = .shader;
                    self.rounded_clip_mode_depth += 1;
                } else {
                    // Same pixel-grid alignment as an opacity layer: a fractional surface origin
                    // would composite the whole clipped subtree (text, borders, icons) through a
                    // bilinear half-pixel resample. The mask keeps the original rect (quad).
                    const aligned = opacity_layer.alignTranslationSurface(it, self.scale, self.offscreenOffset());
                    const quad = opacity_layer.maskQuad(it, aligned);
                    const draw_x = if (std.math.isNan(aligned.draw_x)) aligned.geom.x else aligned.draw_x;
                    const draw_y = if (std.math.isNan(aligned.draw_y)) aligned.geom.y else aligned.draw_y;
                    const draw_w = if (std.math.isNan(aligned.draw_w)) aligned.geom.w else aligned.draw_w;
                    const draw_h = if (std.math.isNan(aligned.draw_h)) aligned.geom.h else aligned.draw_h;
                    const opened = try opacity_layer.beginOpacityLayer(
                        self,
                        aligned.geom.x,
                        aligned.geom.y,
                        aligned.geom.w,
                        aligned.geom.h,
                        1.0,
                        aligned.rotate,
                        draw_x,
                        draw_y,
                        draw_w,
                        draw_h,
                        aligned.use_draw_transform,
                        aligned.draw_transform,
                        .normal,
                    );
                    if (opened and self.offscreen_depth > 0) {
                        self.offscreen_stack[self.offscreen_depth - 1].corner_radii = cornerRadiiArray(it.radii);
                        self.offscreen_stack[self.offscreen_depth - 1].quad = quad;
                    }
                    if (self.rounded_clip_mode_depth < self.rounded_clip_mode_stack.len) {
                        self.rounded_clip_mode_stack[self.rounded_clip_mode_depth] = if (opened) .layer else .noop;
                        self.rounded_clip_mode_depth += 1;
                    }
                }
            },
            .end_rounded_clip => {
                if (self.rounded_clip_overflow_depth > 0) {
                    self.rounded_clip_overflow_depth -= 1;
                    return;
                }
                if (self.rounded_clip_mode_depth > 0) {
                    self.rounded_clip_mode_depth -= 1;
                    switch (self.rounded_clip_mode_stack[self.rounded_clip_mode_depth]) {
                        .shader => try self.popClip(),
                        .layer => try opacity_layer.endOpacityLayer(self),
                        .noop => {},
                    }
                }
            },
            .begin_blur_layer => {
                const glass_ptr = it.glass_ptr orelse return;
                const g = glass_ptr.*;
                const draw_x = if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x;
                const draw_y = if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y;
                const draw_w = if (std.math.isNan(it.draw_w)) it.geom.w else it.draw_w;
                const draw_h = if (std.math.isNan(it.draw_h)) it.geom.h else it.draw_h;
                // test mock item lacks this field, @hasField guard (production PaintItem always
                // has).
                const glass_owner: u32 = if (@hasField(@TypeOf(it), "glass_owner_id")) it.glass_owner_id else std.math.maxInt(u32);
                // Same owner composites backdrop once per frame (see blur_applied_owners comment).
                if (glass_owner != std.math.maxInt(u32)) {
                    for (self.blur_applied_owners[0..self.blur_applied_count]) |applied| {
                        if (applied == glass_owner) return;
                    }
                    if (self.blur_applied_count < self.blur_applied_owners.len) {
                        self.blur_applied_owners[self.blur_applied_count] = glass_owner;
                        self.blur_applied_count += 1;
                    }
                }
                // GlassGroup: container surface has shape table -> one sample, one composite for N
                // shapes; empty table draws nothing.
                var group_count: u8 = 0;
                var group_spacing: f32 = 0;
                var group_blend: f32 = 1;
                var group_motion: f32 = 0;
                var group_continuous = false;
                var group_shapes: [backdrop_blur.max_group_shapes]backdrop_blur.GroupShape = undefined;
                var group_aliases: [backdrop_blur.max_group_shapes][2]u32 = undefined;
                var group_alias_count: u8 = 0;
                if (comptime @hasField(@TypeOf(g), "group")) {
                    if (g.group) |grp| {
                        group_spacing = grp.spacing;
                        group_blend = grp.blend;
                        group_motion = grp.motion;
                        group_continuous = grp.continuous;
                        const n: usize = @min(grp.count, group_shapes.len);
                        var union_keys: [backdrop_blur.max_group_shapes]u32 = @splat(0);
                        shapes: for (grp.shapes[0..n]) |sh| {
                            // Empty slots (member unregistered / not yet written) and zero-size
                            // members skip composite
                            if (sh.node_id == std.math.maxInt(u32) or sh.w <= 0.5 or sh.h <= 0.5) continue;
                            // glassEffectUnion: same-key members merge into first entry (overall
                            // bounding box same-shape).
                            if (sh.union_key != 0) {
                                for (union_keys[0..group_count], 0..) |k, j| {
                                    if (k == sh.union_key) {
                                        backdrop_blur.mergeUnionInto(&group_shapes[j], sh.x, sh.y, sh.w, sh.h, sh.capsule);
                                        if (group_alias_count < group_aliases.len) {
                                            group_aliases[group_alias_count] = .{ sh.node_id, @intCast(j) };
                                            group_alias_count += 1;
                                        }
                                        continue :shapes;
                                    }
                                }
                            }
                            union_keys[group_count] = sh.union_key;
                            const m = sh.material;
                            group_shapes[group_count] = .{
                                .node_id = sh.node_id,
                                .x = sh.x,
                                .y = sh.y,
                                .w = sh.w,
                                .h = sh.h,
                                .radius = sh.radius,
                                .lens = .{ m.lens_bezel_px, m.lens_height_px, m.lens_base_px, m.lens_edge_blur },
                                .tint = m.glass_tint,
                                .specular_opacity = m.specular_opacity,
                                .rim = .{ m.native_rim_offset, m.native_rim_luma, m.native_rim_chroma, m.native_rim_ratio },
                                .tint_response = .{ m.native_tint_mode, m.native_tint_dark, m.native_tint_chroma_base, m.native_tint_chroma_slope },
                                .tint_mode = m.tint_mode,
                                .shadow = .{ sh.shadow_alpha, sh.shadow_blur, sh.shadow_offset_x, sh.shadow_offset_y },
                                .level = sh.level,
                                .base_veil = sh.base_veil,
                                .press_offset = sh.press_offset,
                            };
                            group_count += 1;
                        }
                        if (group_count == 0) return;
                    }
                }
                if (@import("zenit_environment").flag("ZENIT_DEBUG_GLASS")) {
                    std.debug.print("[glassenc-params] owner={d} tab_lens=({d:.1},{d:.1},{d:.1}) lens_bezel={d:.2} gi={d:.2} surface={d} tint_mode={d} tint=({d:.2},{d:.2},{d:.2},{d:.2}) native_tint_mode={d:.0} sat={d:.3} bri={d:.3} fine=({d:.2},{d:.2}) coarse=({d:.2},{d:.2}) chroma=({d:.2},{d:.2},{d:.0}) blur_level={d:.2} group_count={d} rect=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{ glass_owner, g.tab_lens[0], g.tab_lens[1], g.tab_lens[2], g.lens_bezel_px, g.glass_intensity, coerceGlassSurfaceValue(g.surface), g.tint_mode, g.glass_tint[0], g.glass_tint[1], g.glass_tint[2], g.glass_tint[3], g.native_tint_mode, g.backdrop_saturation, g.backdrop_brightness, g.native_fine_sigma, g.native_fine_weight, g.native_coarse_sigma, g.native_coarse_weight, g.native_chroma_fine, g.native_chroma_coarse, g.native_chroma_enabled, g.blur_level, group_count, it.geom.x, it.geom.y, it.geom.w, it.geom.h });
                }
                try backdrop_blur.applyBackdropBlur(self, .{
                    .glass_owner_id = glass_owner,
                    .group_count = group_count,
                    .group_spacing = group_spacing,
                    .group_blend = group_blend,
                    .group_motion = group_motion,
                    .group_continuous = group_continuous,
                    .group_shapes = group_shapes,
                    .group_aliases = group_aliases,
                    .group_alias_count = group_alias_count,
                    .x = it.geom.x,
                    .y = it.geom.y,
                    .w = it.geom.w,
                    .h = it.geom.h,
                    .blur_radius = g.backdrop_blur,
                    .corner_radii = it.radii.toArray(),
                    .glass_tint = g.glass_tint,
                    .tint_mode = g.tint_mode,
                    .base_veil = g.base_veil,
                    .veil_curve = g.veil_curve,
                    .tab_lens = g.tab_lens,
                    .glass_intensity = g.glass_intensity,
                    .specular_opacity = g.specular_opacity,
                    .specular_saturation = g.specular_saturation,
                    .refraction_level = g.refraction_level,
                    .blur_level = g.blur_level,
                    .warp_gain = g.warp_gain,
                    .center_thickness = g.center_thickness,
                    .surface_kind = coerceGlassSurfaceValue(g.surface),
                    .bezel_width = g.bezel_width,
                    .bottom_surface_kind = coerceGlassSurfaceValue(g.bottom_surface),
                    .bottom_bezel_width = g.bottom_bezel_width,
                    .backdrop_saturation = g.backdrop_saturation,
                    .backdrop_brightness = g.backdrop_brightness,
                    .specular_angle = g.specular_angle,
                    .magnification = g.magnification,
                    .scale_ratio = g.scale_ratio,
                    .edge_field_strength = g.edge_field_strength,
                    .center_zoom_radius = g.center_zoom_radius,
                    .center_zoom_falloff = g.center_zoom_falloff,
                    .backdrop_distance = g.backdrop_distance,
                    .native_params = .{ g.lens_bezel_px, g.lens_height_px, g.lens_base_px, g.lens_edge_blur },
                    .native_blur = .{ g.native_fine_sigma, g.native_coarse_sigma, g.native_fine_weight, g.native_coarse_weight },
                    .native_blur_profile = .{ g.native_fine_slope, g.native_fine_curve, g.native_coarse_slope, g.native_coarse_curve },
                    .native_rim = .{ g.native_rim_offset, g.native_rim_luma, g.native_rim_chroma, g.native_rim_ratio },
                    .native_chroma = .{ g.native_chroma_fine, g.native_chroma_coarse, g.native_chroma_enabled, g.native_main_grid_mix },
                    .native_continuous_geometry = g.native_continuous_geometry,
                    .press_offset = g.press_offset,
                    .arrow = g.arrow,
                    .knob_rim_dark = g.knob_rim_dark,
                    .knob_rim_light = g.knob_rim_light,
                    .a11y = g.a11y,
                    .capture_clamp = g.capture_clamp,
                    .native_chroma_profile = .{ g.native_chroma_fine_slope, g.native_chroma_fine_curve, g.native_chroma_coarse_slope, g.native_chroma_coarse_curve },
                    .native_tint_response = .{ g.native_tint_mode, g.native_tint_dark, g.native_tint_chroma_base, g.native_tint_chroma_slope },
                    .blur_gradient_direction = @floatFromInt(g.blur_gradient_direction),
                    .blur_gradient_strength = g.blur_gradient_strength,
                    .blur_gradient_stop_pos = g.blur_gradient_stop_pos,
                    .blur_gradient_stop_str = g.blur_gradient_stop_str,
                    .blur_gradient_stop_count = @floatFromInt(g.blur_gradient_stop_count),
                    .draw_x = draw_x,
                    .draw_y = draw_y,
                    .draw_w = draw_w,
                    .draw_h = draw_h,
                    .use_draw_transform = it.use_draw_transform,
                    .draw_transform = it.draw_transform,
                    .rotate = it.rotate,
                });
                try self.captureGlassUnderlay();
            },
            .end_blur_layer => {
                // backdrop blur completes at begin, end needs no action
            },
        }
    }

    /// paint_table.DisplayItem main path fill_path encoding.
    /// it is paint_table.DisplayItem (anytype), geo is source PathGeometry ptr (from
    /// it.path_geometry_ptr).
    /// Phase C: path mesh cache key: geometry per tag payload + fill/stroke decision + scale
    /// (fringe/stroke expand AA width depends on scale) + stroke params.
    /// offset not in key (mesh translation-invariant, cache stores path-local vertices).
    fn pathMeshKey(geo: anytype, scale: f32, is_stroke: bool, stroke_width: f32, line_join: u8) u64 {
        var h = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        h.update(std.mem.asBytes(&geo.fill_rule));
        var cmd_len: usize = geo.commands.len;
        h.update(std.mem.asBytes(&cmd_len));
        for (geo.commands) |cmd| {
            const tag: u8 = @backingInt(cmd);
            h.update(std.mem.asBytes(&tag));
            switch (cmd) {
                .move_to, .line_to => |pt| h.update(std.mem.asBytes(&pt)),
                .quad_to => |q| h.update(std.mem.asBytes(&q)),
                .cubic_to => |c| h.update(std.mem.asBytes(&c)),
                .close => {},
            }
        }
        h.update(std.mem.asBytes(&scale));
        h.update(std.mem.asBytes(&is_stroke));
        if (is_stroke) {
            h.update(std.mem.asBytes(&stroke_width));
            h.update(std.mem.asBytes(&line_join));
        }
        return h.final();
    }

    fn encodeFillPathPaint(self: *RenderCommandEncoder, it: anytype, geo: anytype) !void {
        if (self.persistent.path_renderer == null) {
            const device = self.sdf_renderer.device;
            self.persistent.path_renderer = try PathRenderer.init(self.sdf_renderer.allocator, device);
        }
        if (self.persistent.path_tessellator == null) {
            self.persistent.path_tessellator = path_tess_mod.PathTessellator.init(self.sdf_renderer.allocator);
        }
        var tess = &self.persistent.path_tessellator.?;
        var path_rend = &self.persistent.path_renderer.?;
        path_rend.setViewport(self.viewport_width, self.viewport_height, self.scale);
        if (self.offscreen_depth > 0) path_rend.setOffscreenViewport() else path_rend.setDrawableExtent(self.drawable_extent[0], self.drawable_extent[1]);

        const off = self.offscreenOffset();
        const ox = it.geom.x + off[0];
        const oy = it.geom.y + off[1];

        const c = it.color;
        const a = @as(f32, @floatFromInt(c.a)) / 255.0 * it.image_opacity;
        const color = [4]f32{
            byteToShader(c.r),
            byteToShader(c.g),
            byteToShader(c.b),
            a,
        };

        // Vector fill+stroke use **same** adaptive tessellation pipeline (tess.flatten by
        // FLATNESS_THRESHOLD/scale, no point limit), only correct form: previously fast path for
        // <=32-point clip polygon (straight-edge chord polygon, <=12 steps per cubic), fill and
        // stroke boundaries two tessellation resolutions, seam error visible, stroke-fill gap.
        // clip polygon is clip's own struct (display_list 32-point limit), shouldn't reuse for fill
        // renderer.
        // Known tradeoff: earclip triangulates per contour, multicontour holes (nonzero/evenodd
        // hole semantics) don't reconcile, this limit always existed for >32 point fills; actual
        // fill use (single contour) unaffected; multicontour correctness belongs to offscreen alpha
        // mask layer.
        if (geo.commands.len == 0) return;
        // Gradient fill: convert DisplayItem stop list to renderer's FillGradient.
        // Per-vertex coloring (GPU PathVertex.color supported in path.metal), gradients for
        // polygons (triangle/star) rely on this, previously degenerated to solid.
        var grad_stops: [16]PathRendererMod.FillGradient.GradientStopIn = undefined;
        var fill_grad: ?PathRendererMod.FillGradient = null;
        if (it.gradient_direction != 0 and it.mg_stop_count > 0) {
            const cnt = @min(@as(usize, it.mg_stop_count), grad_stops.len);
            for (0..cnt) |i| {
                const sc = it.mg_stop_colors[i];
                grad_stops[i] = .{
                    .color = .{
                        byteToShader(sc.r),
                        byteToShader(sc.g),
                        byteToShader(sc.b),
                        @as(f32, @floatFromInt(sc.a)) / 255.0,
                    },
                    .position = it.mg_stop_positions[i],
                };
            }
            fill_grad = .{
                .dir = it.gradient_direction,
                .stops = grad_stops[0..cnt],
                .center_x = it.gradient_radial_center_x,
                .center_y = it.gradient_radial_center_y,
                .start_angle = it.gradient_conic_start_angle,
            };
        }
        // Phase C: mesh cache, hit skips flatten + earclip/fringe.
        // WARNING: gradient **must bypass cache**: appendCachedMesh replay rewrites uniform color
        // into every vertex (designed for solid), one gradient hit flattens to solid.
        path_rend.setFrame(self.frame_index);
        const mesh_key = pathMeshKey(geo.*, self.scale, false, 0, 0);
        if (fill_grad == null) {
            if (try path_rend.appendCachedMesh(mesh_key, color, ox, oy)) return;
        }
        const PathCommand = @TypeOf(geo.commands[0]);
        const contours = try tess.flatten(PathCommand, geo.commands, self.scale);
        const rule: PathRendererMod.FillRule = switch (coercePathFillRule(geo.fill_rule)) {
            .evenodd => .evenodd,
            .nonzero => .nonzero,
        };
        if (try path_rend.addFillPathGradient(contours, color, ox, oy, fill_grad, rule)) |range| {
            if (fill_grad == null) path_rend.storeMesh(mesh_key, range[0], range[1], ox, oy);
        }
    }

    /// paint_table.DisplayItem main path stroke_path encoding.
    fn encodeStrokePathPaint(self: *RenderCommandEncoder, it: anytype, geo: anytype) !void {
        if (self.persistent.path_renderer == null) {
            const device = self.sdf_renderer.device;
            self.persistent.path_renderer = try PathRenderer.init(self.sdf_renderer.allocator, device);
        }
        if (self.persistent.path_tessellator == null) {
            self.persistent.path_tessellator = path_tess_mod.PathTessellator.init(self.sdf_renderer.allocator);
        }
        var tess = &self.persistent.path_tessellator.?;
        var path_rend = &self.persistent.path_renderer.?;
        path_rend.setViewport(self.viewport_width, self.viewport_height, self.scale);
        if (self.offscreen_depth > 0) path_rend.setOffscreenViewport() else path_rend.setDrawableExtent(self.drawable_extent[0], self.drawable_extent[1]);

        const off = self.offscreenOffset();
        const ox = it.geom.x + off[0];
        const oy = it.geom.y + off[1];

        if (geo.commands.len == 0) return;

        const c = it.color;
        const a = @as(f32, @floatFromInt(c.a)) / 255.0 * it.image_opacity;
        const color = [4]f32{
            byteToShader(c.r),
            byteToShader(c.g),
            byteToShader(c.b),
            a,
        };

        const PathLineJoin = @import("path_renderer.zig").LineJoin;
        const line_join: PathLineJoin = @fromBackingInt(@intCast(it.path_line_join));
        // Phase C: mesh cache, hit skips flatten + stroke expand
        path_rend.setFrame(self.frame_index);
        // `stroke_width` and path vertices already logical pixels. PathRenderer viewport/shader
        // maps logical to Retina physical; here only use device scale for curve tessellation
        // tolerance and 1px AA fringe. Old code multiplied by `self.scale` again, 3px stroke on 2x
        // became 6 logical pixels (12 device), but Box border stayed correct 3px.
        const logical_stroke_width = pathStrokeWidthForTessellation(it.stroke_width, self.scale);
        const mesh_key = pathMeshKey(geo.*, self.scale, true, logical_stroke_width, it.path_line_join);
        if (try path_rend.appendCachedMesh(mesh_key, color, ox, oy)) return;
        const PathCommand = @TypeOf(geo.commands[0]);
        const contours = try tess.flatten(PathCommand, geo.commands, self.scale);
        if (try path_rend.addStrokePath(contours, color, logical_stroke_width, line_join, ox, oy)) |range| {
            path_rend.storeMesh(mesh_key, range[0], range[1], ox, oy);
        }
    }

    fn coerceAffineTransform(transform: anytype) [6]f32 {
        return .{
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.tx,
            transform.ty,
        };
    }

    fn coerceGlassSurfaceValue(surface: anytype) f32 {
        return switch (@typeInfo(@TypeOf(surface))) {
            .@"enum" => @floatFromInt(@backingInt(surface)),
            .int, .comptime_int => @floatFromInt(surface),
            else => 1.0,
        };
    }

    /// z-order barrier: when dispatching SDF command, if text/image/icon pipeline has pending, this
    /// SDF needs above them; default flush SDF->Image->Text sinks later SDF below (canvas first
    /// child is full-frame tile base, all following SDF boxes covered).
    /// Flush all first, start new batch. Cost: SDF-image/icon interleave fragments batches; correct
    /// first, fast later (downstream app).
    /// CPU patch counterpart of the GPU flush sequence sdf, image, icon, text
    /// (render/cpu_flat.zig); images cannot be drawn on the CPU.
    fn cpuFlushRenderers(self: *RenderCommandEncoder, target: *anyopaque, sdf_too: bool, image_too: bool, text_too: bool) !void {
        const cpu = @import("cpu_flat.zig");
        const raster = !self.cpu_flat_validate_only;
        if (sdf_too) try cpu.flushSdf(target, self.sdf_renderer, raster);
        if (image_too) if (self.image_renderer) |ir| if (ir.instances.items.len > 0) return error.CpuFlatUnsupportedImage;
        try cpu.flushIcons(target, self.icon_renderer, raster);
        if (text_too) try cpu.flushText(target, self.text_renderer, raster);
    }

    /// Z-order barrier before an SDF or image command `it`: pending image, icon and text
    /// instances come from earlier commands, which must stay beneath `it` but would draw over it
    /// (their pipelines flush later), so they are flushed first. Pending text alone is kept when `it` cannot reach any pending glyph:
    /// disjoint quads paint the same pixels in either order, so the SDF batch may draw before
    /// that text (the per-text flush made a row of label buttons cost two draws per button).
    fn flushIfTextPendingUnder(self: *RenderCommandEncoder, it: anytype, ox: f32, oy: f32) !void {
        const text_pending = self.text_renderer.getPendingInstanceCount() > 0;
        const image_pending = if (self.image_renderer) |ir| ir.instances.items.len > 0 else false;
        const icon_pending = if (self.icon_renderer) |ir| ir.instances.items.len > 0 else false;
        if (!(text_pending or image_pending or icon_pending)) return;
        if (self.cpu_flat_target == null) if (commandPaintBounds(it, ox, oy)) |bounds| {
            // An image or icon command goes on to flush the other image-like batch alone
            // (flushIfIconPending / flushIfImagePending), which must not overtake pending SDF:
            // only pending text may stay for it.
            const sdf_command = it.kind != .image;
            const tr = self.text_renderer;
            const clear = (!text_pending or self.text_ink.allows(tr.pending_generation, .{ tr.instances_nearest.items, tr.instances_linear.items }, bounds)) and
                (!image_pending or (sdf_command and self.image_ink.allows(self.image_renderer.?.pending_generation, .{self.image_renderer.?.instances.items}, bounds))) and
                (!icon_pending or (sdf_command and self.icon_ink.allows(self.icon_renderer.?.pending_generation, .{self.icon_renderer.?.instances.items}, bounds)));
            if (clear) return;
        };
        return self.flushIfTextPending();
    }

    /// Target-space bounds (x0, y0, x1, y1) of every pixel `it` can paint, padded by one
    /// logical pixel; null when unknown (transformed or rotated), which keeps the barrier.
    pub fn commandPaintBounds(it: anytype, ox: f32, oy: f32) ?[4]f32 {
        if (it.use_draw_transform or @abs(it.rotate) > 0.0001) return null;
        const b = lsort.localSortBoundsForCommand(it) orelse return null;
        return .{ b[0] + ox - 1, b[1] + oy - 1, b[0] + b[2] + ox + 1, b[1] + b[3] + oy + 1 };
    }

    fn flushIfTextPending(self: *RenderCommandEncoder) !void {
        const text_pending = self.text_renderer.getPendingInstanceCount() > 0;
        const image_pending = if (self.image_renderer) |ir| ir.instances.items.len > 0 else false;
        const icon_pending = if (self.icon_renderer) |ir| ir.instances.items.len > 0 else false;
        if (!(text_pending or image_pending or icon_pending)) return;
        if (comptime gpu.backend_kind == .metal) if (self.cpu_flat_target) |target| return self.cpuFlushRenderers(target, true, true, true);
        if (self.render_pass) |rp| {
            if (self.sdf_renderer.instances.items.len > 0) {
                self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
            }
            if (image_pending) {
                if (self.image_renderer) |ir| ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
            }
            if (icon_pending) {
                if (self.icon_renderer) |ir| ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
            }
            if (text_pending) self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn flushIfImagePending(self: *RenderCommandEncoder) !void {
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) {
                if (self.cpu_flat_target != null) return error.CpuFlatUnsupportedImage;
                if (self.render_pass) |rp| ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
            }
        }
    }

    fn flushIfIconPending(self: *RenderCommandEncoder) !void {
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) {
                if (comptime gpu.backend_kind == .metal) if (self.cpu_flat_target) |target| return @import("cpu_flat.zig").flushIcons(target, self.icon_renderer, !self.cpu_flat_validate_only);
                if (self.render_pass) |rp| ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
            }
        }
    }

    // Script detection / ASCII classification pure function cluster extracted to
    /// dispatchCommand's `.text` arm: draw text command `it` offset by (ox, oy) (the offscreen
    /// surface origin). Every glyph it paints is a TextRenderer instance; text_ink bounds them.
    pub fn encodeTextCommand(self: *RenderCommandEncoder, it: anytype, ox: f32, oy: f32) !void {
        const dbg_surf = @import("zenit_environment").flag("ZENIT_DEBUG_SURFDUMP") and self.offscreen_depth > 0;
        const dbg_before = if (dbg_surf) self.text_renderer.instances_nearest.items.len + self.text_renderer.instances_linear.items.len else 0;
        defer if (dbg_surf) {
            const after = self.text_renderer.instances_nearest.items.len + self.text_renderer.instances_linear.items.len;
            std.debug.print("[surftext] depth={d} x={d:.1} y={d:.1} len={d} fs={d:.1} pol={d} added={d}\n", .{
                self.offscreen_depth, it.geom.x, it.geom.y, it.text_content.len, it.text_font_size, it.text_raster_policy, after - dbg_before,
            });
        };
        if (it.text_content.len == 0 or it.text_font_size <= 0) return;
        const use_italic = (it.text_font_flags & 1) != 0;
        const use_mono = (it.text_font_flags & 2) != 0;
        const use_sym = (it.text_font_flags & 4) != 0;
        const raster = wire_types.textRasterControls(it.text_raster_policy);
        if (comptime @import("builtin").os.tag == .windows) self.text_renderer.cleartype_allowed =
            self.hasOpaqueTextBackdrop(it);
        self.text_renderer.lcd_backdrop = &self.text_backdrop;
        defer {
            self.text_renderer.lcd_backdrop = null;
            self.text_renderer.cleartype_allowed = false;
        }
        // TextFontFlag.no_smoothing (TextProps.font_smoothing = false)
        self.text_renderer.smooth_fonts = (it.text_font_flags & 8) == 0;
        defer self.text_renderer.smooth_fonts = true;
        // Right-edge fade mask: convert to absolute x for renderer, set per-command and
        // reset (same pattern as clip_x_*; fade affects alpha only, not glyph atlas).
        if (it.text_fade_dx1 > it.text_fade_dx0) {
            self.text_renderer.fade_x0 = it.geom.x + ox + it.text_fade_dx0;
            self.text_renderer.fade_x1 = it.geom.x + ox + it.text_fade_dx1;
        }
        defer {
            self.text_renderer.fade_x0 = std.math.inf(f32);
            self.text_renderer.fade_x1 = std.math.inf(f32);
        }
        if (it.text_spans) |s| {
            try self.encodeTextWithSpans(
                it.geom.x + ox,
                it.geom.y + oy,
                it.text_content,
                it.color,
                it.text_font_size,
                it.text_font_weight,
                it.text_font_family,
                use_sym,
                use_mono,
                it.text_monospace_char_width,
                use_italic,
                raster.force_linear,
                raster.shader_snap,
                s,
            );
        } else {
            try self.encodeText(
                it.geom.x + ox,
                it.geom.y + oy,
                it.text_content,
                it.color,
                it.text_font_size,
                it.text_font_weight,
                it.text_font_family,
                use_sym,
                use_mono,
                it.text_monospace_char_width,
                use_italic,
                raster.force_linear,
                raster.shader_snap,
            );
        }
    }

    // command_encoder/script_detect.zig.
    // Keep same re-export here, public API (RenderCommandEncoder.preferCjkFallback etc.) and
    // callsites/tests all unchanged.
    const isAllAscii = script_detect.isAllAscii;
    const fixedMonospaceAdvance = script_detect.fixedMonospaceAdvance;

    /// Encode text
    fn encodeText(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        content: []const u8,
        color: anytype,
        font_size: f32,
        font_weight: u16,
        font_family: u16,
        use_symbols_font: bool,
        use_monospace_font: bool,
        monospace_char_width: f32,
        use_italic_font: bool,
        force_linear: bool,
        shader_snap: bool,
    ) !void {
        if (self.fonts) |fonts| {
            // Font decisions **all** to FontSelector.resolveFonts, same function as measure side.
            // This used to have inline if chain + selectCjkFallbackFont; measureTextWidth chose
            // differently, same text measured and drawn different widths (symbols cover / CJK
            // content-fallback / force_linear three forks).
            // Don't move font logic back here: text_ink.chooseFonts is also what text ink
            // bounds (caret occlusion, CPU damage) are computed with.
            const choice = text_ink.chooseFonts(fonts, self.text_renderer, content, font_size, font_weight, font_family, use_symbols_font, use_monospace_font, monospace_char_width, use_italic_font, force_linear);
            const font = choice.font;
            var ranges: ?*@import("text").FontRanges = null;
            if (comptime @import("builtin").os.tag == .windows) {
                if (self.text_renderer.font_ranges_provider) |provider| {
                    const context = self.text_renderer.font_ranges_context orelse return error.MissingFontRangesContext;
                    ranges = try provider(context, .{ .text = content, .font_size = font_size, .font_weight = font_weight, .font_family = font_family, .use_italic = use_italic_font, .use_monospace = use_monospace_font, .use_symbols = use_symbols_font }, font, self.text_renderer.allocator);
                }
            }
            self.text_renderer.active_font_ranges = ranges;
            // Animated raster draws the primary's glyphs from a stable instance; never a script
            // fallback's (its glyph ids belong to another face).
            self.text_renderer.raster_font = if (font == choice.primary) choice.raster else null;
            defer {
                self.text_renderer.raster_font = null;
                self.text_renderer.active_font_ranges = null;
                if (comptime @import("builtin").os.tag == .windows) {
                    if (ranges) |owned| {
                        owned.deinit();
                        self.text_renderer.allocator.destroy(owned);
                    }
                }
            }
            const render_color = colorToRenderColor(color);
            const cjk_fallback = choice.fallback;
            const fixed_advance = choice.fixed_advance;
            self.text_renderer.drawTextWithOptions(
                content,
                x,
                y,
                font,
                render_color,
                font_size,
                use_italic_font,
                cjk_fallback,
                force_linear,
                shader_snap,
                fixed_advance,
            ) catch |err| {
                if (err == error.TextShapingFailed or err == error.OutOfMemory) {
                    return;
                }
                return err;
            };
        }
    }

    /// Encode text with color spans (whole line one shape + per-glyph span color)
    fn encodeTextWithSpans(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        content: []const u8,
        color: anytype,
        font_size: f32,
        font_weight: u16,
        font_family: u16,
        use_symbols_font: bool,
        use_monospace_font: bool,
        monospace_char_width: f32,
        use_italic_font: bool,
        force_linear: bool,
        shader_snap: bool,
        spans: anytype,
    ) !void {
        if (self.fonts) |fonts| {
            // Like drawText: font decisions route to FontSelector.resolveFonts (chooseFonts).
            // Was second identical if chain, both copies diverged = "measure and draw width
            // mismatch" kept recurring.
            const choice = text_ink.chooseFonts(fonts, self.text_renderer, content, font_size, font_weight, font_family, use_symbols_font, use_monospace_font, monospace_char_width, use_italic_font, force_linear);
            const font = choice.font;
            var ranges: ?*@import("text").FontRanges = null;
            if (comptime @import("builtin").os.tag == .windows) {
                if (self.text_renderer.font_ranges_provider) |provider| {
                    const context = self.text_renderer.font_ranges_context orelse return error.MissingFontRangesContext;
                    ranges = try provider(context, .{ .text = content, .font_size = font_size, .font_weight = font_weight, .font_family = font_family, .use_italic = use_italic_font, .use_monospace = use_monospace_font, .use_symbols = use_symbols_font }, font, self.text_renderer.allocator);
                }
            }
            self.text_renderer.active_font_ranges = ranges;
            // Animated raster draws the primary's glyphs from a stable instance; never a script
            // fallback's (its glyph ids belong to another face).
            self.text_renderer.raster_font = if (font == choice.primary) choice.raster else null;
            defer {
                self.text_renderer.raster_font = null;
                self.text_renderer.active_font_ranges = null;
                if (comptime @import("builtin").os.tag == .windows) {
                    if (ranges) |owned| {
                        owned.deinit();
                        self.text_renderer.allocator.destroy(owned);
                    }
                }
            }
            const render_color = colorToRenderColor(color);
            const cjk_fallback = choice.fallback;
            const fixed_advance = choice.fixed_advance;

            // Build render-level color spans
            var render_spans_buf: [text_ink.max_spans]TextRenderer.ColorSpan = undefined;
            const span_count = @min(spans.len, render_spans_buf.len);
            for (spans[0..span_count], 0..) |s, i| {
                render_spans_buf[i] = .{
                    .start = s.start,
                    .end = s.end,
                    .color = if (s.color) |c| colorToRenderColor(c) else render_color,
                };
            }

            self.text_renderer.drawTextWithSpans(
                content,
                x,
                y,
                font,
                render_color,
                font_size,
                use_italic_font,
                cjk_fallback,
                force_linear,
                shader_snap,
                fixed_advance,
                render_spans_buf[0..span_count],
            ) catch |err| {
                if (err == error.TextShapingFailed) {
                    // Graceful fallback: if span-aware shaping fails, render plain text without spans
                    // so editor body remains visible (syntax colors temporarily degraded).
                    self.text_renderer.drawTextWithOptions(
                        content,
                        x,
                        y,
                        font,
                        render_color,
                        font_size,
                        use_italic_font,
                        cjk_fallback,
                        force_linear,
                        shader_snap,
                        fixed_advance,
                    ) catch |fallback_err| {
                        if (fallback_err == error.TextShapingFailed or fallback_err == error.OutOfMemory) {
                            return;
                        }
                        return fallback_err;
                    };
                    return;
                }
                if (err == error.OutOfMemory) {
                    return;
                }
                return err;
            };
        }
    }

    // selectCjkFallbackFont deleted (2026-08-17): content-fallback centralized to
    // FontSelector.resolveContentFallback, shared render/measure.
    // Change fallback rules there, not another copy in encoder.

    pub const preferKoreanFallback = script_detect.preferKoreanFallback;
    pub const preferCjkFallback = script_detect.preferCjkFallback;
    const containsHangul = script_detect.containsHangul;
    const containsHanOrKana = script_detect.containsHanOrKana;

    const gradientDirToSDFFromU8 = wire_types.gradientDirection;
    const extendModeToSDFFromU8 = wire_types.gradientExtendMode;

    fn encodeGradient(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from: anytype,
        to: anytype,
        dir: GradientDir,
        radius: [4]f32,
        radial_center_x: f32,
        radial_center_y: f32,
        conic_start_angle: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        switch (dir) {
            .radial => try self.sdf_renderer.addRadialGradientRect(
                x,
                y,
                w,
                h,
                colorToFloat4(from),
                colorToFloat4(to),
                radius,
                radial_center_x,
                radial_center_y,
                extend_mode,
            ),
            .conic => try self.sdf_renderer.addConicGradientRect(
                x,
                y,
                w,
                h,
                colorToFloat4(from),
                colorToFloat4(to),
                radius,
                conic_start_angle,
                extend_mode,
            ),
            else => {
                // Linear gradient: use addGradientRect but pass extend_mode
                // Support extend_mode by writing packed_flags directly
                try self.sdf_renderer.addGradientRectEx(
                    x,
                    y,
                    w,
                    h,
                    colorToFloat4(from),
                    colorToFloat4(to),
                    dir,
                    radius,
                    extend_mode,
                );
            },
        }
    }

    // ========== Clip Stack (Phase 1) ==========

    /// Push clip region (lazy flush: update clip stack only, actual GPU scissor set deferred to
    /// next draw)
    /// pub: unit tests (command_encoder_test.zig) drive clip stack directly.
    /// `radii` = TL, TR, BR, BL (logical px; read only for `.rounded_rect`).
    pub fn pushClip(self: *RenderCommandEncoder, x: f32, y: f32, w: f32, h: f32, radii: [4]f32, shape_kind: ClipShapeKind, polygon: ClipPolygon) !void {
        try self.pushClipEntry(.{ x, y, w, h }, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .radii = corner_radii.normalize(radii, w, h),
            .shape_kind = shape_kind,
            .polygon = polygon,
        });
    }

    /// Push a clip entry: `rect` narrows the rect clip, `shape` (with its partner) becomes the
    /// shape clip in force when it is not a plain rect.
    fn pushClipEntry(self: *RenderCommandEncoder, rect: [4]f32, shape: RoundedClipState) !void {
        const x = rect[0];
        const y = rect[1];
        const w = rect[2];
        const h = rect[3];
        if (self.clip_overflow_depth > 0 or self.clip_depth >= self.logical_clip_stack.len) {
            if (self.clip_overflow_depth == 0) {
                std.debug.print("[ENC pushClip] WARNING: clip stack overflow (depth=64), ignoring\n", .{});
            }
            self.clip_overflow_depth +|= 1;
            return;
        }

        const prev_rounded = self.activeRoundedClip();
        const raw_rect = [4]f32{ x, y, @max(w, 0), @max(h, 0) };
        self.effective_rect_clip_stack[self.clip_depth] = if (self.currentRectClip()) |parent_rect|
            intersectClipRects(parent_rect, raw_rect)
        else
            raw_rect;
        self.logical_clip_stack[self.clip_depth] = shape;
        self.clip_depth += 1;
        try self.syncClipStateAfterMutation(prev_rounded);
    }

    /// A display-list push_clip (coordinates already in the current target, like pushClip).
    ///
    /// Every pipeline evaluates the shape clip in force and, on Metal, its partner
    /// (shape_clip_pair.zig), so the target's clip is always "those shapes ∩ the rect clips". A
    /// shape clip pushed while others are active keeps that exact (clip_geometry.resolveShapeClips,
    /// placeNestedShapeClipWithin elsewhere): nested shapes that contain one another inside the
    /// rect clip or share a rect collapse into one shape; two that genuinely cross pair up; a
    /// further crossing shape (or any crossing pair off Metal) opens an isolation layer, an
    /// offscreen surface over the clip where the new shape is the only shape clip, composited back
    /// under the active ones. Depth is unbounded: each crossing level isolates in turn. Returns how
    /// the matching pop_clip undoes it.
    pub fn pushClipCommand(self: *RenderCommandEncoder, x: f32, y: f32, w: f32, h: f32, radii: [4]f32, shape_kind: ClipShapeKind, polygon: ClipPolygon) !PushClipMode {
        const plain = shape_kind == .rect or
            self.clip_overflow_depth > 0 or self.clip_depth >= self.logical_clip_stack.len or
            self.push_clip_mode_overflow_depth > 0 or self.push_clip_mode_depth >= self.push_clip_mode_stack.len;
        const outer = if (plain) null else self.activeRoundedClip();
        if (outer == null) {
            try self.pushClip(x, y, w, h, radii, shape_kind, polygon);
            return .clip;
        }
        const inner = RoundedClipState{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .radii = corner_radii.normalize(radii, w, h),
            .shape_kind = shape_kind,
            .polygon = polygon,
        };
        const visible = if (self.currentRectClip()) |rc| intersectClipRects(rc, .{ x, y, @max(w, 0), @max(h, 0) }) else [4]f32{ x, y, @max(w, 0), @max(h, 0) };
        if (shape_clip_pair.supported and self.pair_shape_clips) {
            var active: [2]RoundedClipState = .{ outer.?, undefined };
            var active_count: usize = 1;
            if (outer.?.partner) |partner| {
                active[1] = RoundedClipState.fromPartner(partner);
                active_count = 2;
            }
            const resolution = clip_geometry.resolveShapeClips(active[0..active_count], inner, visible);
            if (@import("zenit_environment").flag("ZENIT_DEBUG_PASSCOUNT")) {
                const tag = switch (resolution) {
                    .redundant => "keep_outer",
                    .shapes => |set| if (set.count == 2) "pair" else "replace",
                    .isolate => "isolate",
                };
                std.debug.print("[clip] nested shape clip -> {s}\n", .{tag});
            }
            switch (resolution) {
                .redundant => try self.pushClip(x, y, w, h, .{ 0, 0, 0, 0 }, .rect, ClipPolygon.empty()),
                .shapes => |set| {
                    var primary = set.shapes[0];
                    primary.partner = if (set.count == 2) PartnerClip.of(set.shapes[1]) else null;
                    try self.pushClipEntry(.{ x, y, w, h }, primary);
                },
                .isolate => return self.isolateShapeClip(x, y, w, h, radii, shape_kind, polygon),
            }
            return .clip;
        }
        const placement = clip_geometry.placeNestedShapeClipWithin(outer.?, inner, visible);
        if (@import("zenit_environment").flag("ZENIT_DEBUG_PASSCOUNT")) {
            std.debug.print("[clip] nested shape clip -> {s}\n", .{@tagName(placement)});
        }
        switch (placement) {
            .replace => try self.pushClip(x, y, w, h, radii, shape_kind, polygon),
            .keep_outer => try self.pushClip(x, y, w, h, .{ 0, 0, 0, 0 }, .rect, ClipPolygon.empty()),
            .merged => |merged| try self.pushClip(x, y, w, h, merged, .rounded_rect, ClipPolygon.empty()),
            .isolate => return self.isolateShapeClip(x, y, w, h, radii, shape_kind, polygon),
        }
        return .clip;
    }

    /// Isolate a shape clip that crosses the shape clips in force: an offscreen surface over the
    /// clip where the new shape is the only shape clip, composited back under the active ones.
    fn isolateShapeClip(self: *RenderCommandEncoder, x: f32, y: f32, w: f32, h: f32, radii: [4]f32, shape_kind: ClipShapeKind, polygon: ClipPolygon) !PushClipMode {
        const parent_off = self.offscreenOffset();
        switch (try self.beginIsolatedClipLayer(x, y, w, h)) {
            .opened => {
                // Same clip, re-expressed in the layer's target (stack starts empty there).
                const off = self.offscreenOffset();
                try self.pushClip(x - parent_off[0] + off[0], y - parent_off[1] + off[1], w, h, radii, shape_kind, polygon);
                return .isolated;
            },
            .empty => {
                // The effective rect clip already excludes every pixel;
                // no shape isolation or resource fallback is necessary.
                try self.pushClip(x, y, w, h, radii, shape_kind, polygon);
                return .clip;
            },
            .unavailable => {},
        }
        // No layer available (offscreen nesting limit / pool exhausted):
        // the innermost shape wins, as it did before isolation existed.
        self.isolated_clip_fallbacks += 1;
        if (self.isolated_clip_fallbacks == 1) {
            std.log.warn("[clip] nested shape clip could not isolate; outer shape not applied", .{});
        }
        try self.pushClip(x, y, w, h, radii, shape_kind, polygon);
        return .clip;
    }

    /// Open the isolation layer for a crossing shape clip at target-local (x, y, w, h): the clip
    /// rect ∩ the current rect clip (nothing outside both can show), aligned to the pixel grid
    /// like an opacity layer so the composite lands texel-for-pixel. No mask of its own: the
    /// shape is pushed inside, and the composite runs under the parent's clip state.
    fn beginIsolatedClipLayer(self: *RenderCommandEncoder, x: f32, y: f32, w: f32, h: f32) !enum { opened, empty, unavailable } {
        var bounds = [4]f32{ x, y, @max(w, 0), @max(h, 0) };
        if (self.currentRectClip()) |rc| bounds = intersectClipRects(rc, bounds);
        if (!(bounds[2] > 0 and bounds[3] > 0)) return .empty;
        const off = self.offscreenOffset();
        const nan = std.math.nan(f32);
        const Surface = struct {
            geom: struct { x: f32, y: f32, w: f32, h: f32 },
            rotate: f32 = 0,
            use_draw_transform: bool = false,
            draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
            draw_x: f32,
            draw_y: f32,
            draw_w: f32,
            draw_h: f32,
        };
        const src = Surface{
            .geom = .{ .x = bounds[0] - off[0], .y = bounds[1] - off[1], .w = bounds[2], .h = bounds[3] },
            .draw_x = nan,
            .draw_y = nan,
            .draw_w = nan,
            .draw_h = nan,
        };
        const aligned = opacity_layer.alignTranslationSurface(src, self.scale, off);
        const opened = try opacity_layer.beginOpacityLayer(
            self,
            aligned.geom.x,
            aligned.geom.y,
            aligned.geom.w,
            aligned.geom.h,
            1.0,
            0,
            aligned.draw_x,
            aligned.draw_y,
            aligned.draw_w,
            aligned.draw_h,
            false,
            aligned.draw_transform,
            .normal,
        );
        return if (opened) .opened else .unavailable;
    }

    /// Pop clip region (lazy flush: update clip stack only, actual GPU scissor restore deferred to
    /// next draw)
    pub fn popClip(self: *RenderCommandEncoder) !void {
        // First offset ignores at stack-full; they didn't push, corresponding pops can't pop.
        if (self.clip_overflow_depth > 0) {
            self.clip_overflow_depth -= 1;
            return;
        }
        if (self.clip_depth == 0) return;

        const prev_rounded = self.activeRoundedClip();
        self.clip_depth -= 1;
        try self.syncClipStateAfterMutation(prev_rounded);
    }

    inline fn viewportScissorRect(self: *const RenderCommandEncoder) ScissorRect {
        return .{
            .x = 0,
            .y = 0,
            .width = if (self.offscreen_depth > 0) physicalPixelExtent(self.viewport_width, self.scale) else self.drawable_extent[0],
            .height = if (self.offscreen_depth > 0) physicalPixelExtent(self.viewport_height, self.scale) else self.drawable_extent[1],
        };
    }

    fn pushOpacityMode(self: *RenderCommandEncoder, mode: OpacityLayerMode) void {
        if (self.opacity_mode_depth >= self.opacity_mode_stack.len) return;
        self.opacity_mode_stack[self.opacity_mode_depth] = mode;
        self.opacity_mode_depth += 1;
    }

    fn popOpacityMode(self: *RenderCommandEncoder) ?OpacityLayerMode {
        if (self.opacity_mode_depth == 0) return null;
        self.opacity_mode_depth -= 1;
        return self.opacity_mode_stack[self.opacity_mode_depth];
    }

    /// Sync text renderer's horizontal clip range from current clip stack
    pub fn syncTextClipX(self: *RenderCommandEncoder) void {
        if (self.currentRectClip()) |cur| {
            self.text_renderer.clip_x_min = cur[0];
            self.text_renderer.clip_x_max = cur[0] + cur[2];
        } else {
            self.text_renderer.clip_x_min = 0;
            self.text_renderer.clip_x_max = self.viewport_width;
        }
    }

    // ========== Phase C2/C3: Offscreen Opacity Layer ==========

    /// Begin offscreen opacity layer
    pub fn restoreSavedClipState(self: *RenderCommandEncoder, layer: OffscreenLayer) void {
        self.clip_depth = layer.saved_clip_depth;
        self.clip_overflow_depth = layer.saved_clip_overflow_depth;
        self.logical_clip_stack = layer.saved_logical_clip_stack;
        self.effective_rect_clip_stack = layer.saved_effective_rect_clip_stack;
    }

    /// Flush accumulated commands to GPU RenderPass
    pub fn flush(self: *RenderCommandEncoder, render_pass: *gpu.Backend.RenderPass) !void {
        // Save render_pass reference (for clip stack)
        self.render_pass = render_pass;

        // Render SDF elements first (background below)
        try self.sdf_renderer.flush(render_pass);
        // Render images (middle)
        if (self.image_renderer) |ir| {
            try ir.render(render_pass);
        }
        if (self.icon_renderer) |ir| {
            try ir.render(render_pass);
        }
        // Render vector paths (above images, below text)
        if (self.persistent.path_renderer) |*pr| {
            try pr.flush(render_pass);
        }
        // Render text last (top)
        try self.text_renderer.flush(render_pass);
        // Clear reference
        self.render_pass = null;
    }
};

test "non-Windows prewarm skips scrolling while Windows keys raster phases" {
    const Item = struct {
        kind: enum { text, control } = .text,
        control_kind: u8 = 0,
        use_draw_transform: bool = false,
        draw_transform: [6]f32 = @splat(0),
        draw_w: f32 = 0,
        draw_h: f32 = 0,
        text_content: []const u8 = "scrolling",
        geom: [4]f32 = .{ 0, 0, 100, 20 },
        text_font_family: u16 = 0,
        text_font_size: f32 = 14,
        text_font_weight: u16 = 400,
        text_font_flags: u8 = 0,
        text_monospace_char_width: f32 = 0,
        text_raster_policy: u8 = 0,
    };
    var items = [_]Item{.{}};
    const original = RenderCommandEncoder.prewarmSignature(&items);
    items[0].geom[1] = 100.25;
    items[0].text_font_family = 1;
    const moved = RenderCommandEncoder.prewarmSignature(&items);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(original != moved);
    } else try std.testing.expectEqual(original, moved);
    items[0].text_font_size = 20;
    try std.testing.expect(moved != RenderCommandEncoder.prewarmSignature(&items));
}
