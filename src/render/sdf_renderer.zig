/// SDF Renderer - GPU-instanced SDF primitive rendering (pipeline: sdf_primitives.metal).
///
/// - True SDF shadows (fuzzy edges, no fill inside)
/// - Hollow rounded borders (single draw call)
/// - Rounded rects / circles / lines
const std = @import("std");
const idle_storage = @import("idle_storage.zig");
const SlotBuffer = @import("slot_buffer.zig").SlotBuffer;
const gpu = @import("gpu");
const shape_clip_pair = @import("shape_clip_pair.zig");
const corner_radii = @import("zenit_corner_radii");

const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

/// SDF shader source (single source of truth)
const sdf_shader_source: []const u8 = @import("shader_sources.zig").sdf;

/// Uniforms struct, aligned with sdf_primitives.metal
const Uniforms = extern struct {
    viewport_size: [2]f32, // Physical pixels
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    /// Keeps the polygon arrays on a 16-byte (cbuffer register) boundary after `clip_radii`.
    _clip_pad: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    /// Per-frame seed increment; supplies film_grain shader with per-frame noise variation.
    frame_seed: u32 = 0,
    raster_clip_pos: u32 = 0,
    /// Second shape clip (shape_clip_pair.zig); zero-sized off Metal.
    clip2: shape_clip_pair.Field = shape_clip_pair.none,
};

// Shared clip header ABI (Metal struct / HLSL cbuffer / GLSL std140): per-corner radii sit on their own
// 16-byte register and the polygon arrays start at the next one.
comptime {
    std.debug.assert(@offsetOf(Uniforms, "clip_rect") == 16);
    std.debug.assert(@offsetOf(Uniforms, "clip_radii") == 32);
    std.debug.assert(@offsetOf(Uniforms, "clip_fill_rule") == 48);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_end_points") == 64);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_points") == 96);
}

/// SDF instance data, aligned with sdf_primitives.metal InstanceData (176 bytes).
pub const SDFInstance = extern struct {
    rect: [4]f32, // x, y, w, h (logical pixels)
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h; negative size = disabled
    fill_color: [4]f32, // RGBA float (gradient: from color)
    border_color: [4]f32, // RGBA float
    shadow_color: [4]f32, // RGBA float (outer shadow + inset shadow reuse)
    gradient_to_color: [4]f32, // RGBA float (gradient: to color; stop_count=0 uses this)
    corner_radii: [4]f32, // TL, TR, BR, BL
    border_width: f32,
    shadow_blur: f32,
    shadow_offset_x: f32,
    shadow_offset_y: f32,
    shape_type: u32, // 0=rect, 1=circle, 2=line, 3=arc
    /// packed_flags encoding:
    ///   bit 0-7:   gradient_direction (GradientDir)
    ///   bit 8-15:  noise_mode (NoiseMode)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:    inset_shadow (0/1)
    ///   bit 25:    has_shadow2  (0/1)
    packed_flags: u32 = 0,
    noise_scale: f32 = 0, // Noise grid spacing (logical pixels, 0=disabled)
    noise_intensity: f32 = 0, // Noise strength [0..1]
    border_widths: [4]f32 = .{ 0, 0, 0, 0 }, // per-side: top, right, bottom, left
    gradient_stop_offset: u32 = 0, // GradientStop buffer start index
    gradient_stop_count: u32 = 0, // 0 = legacy two-color mode (backward compatible)
    shadow2_index: u32 = 0, // Second shadow index in ShadowParam buffer
    _ext_reserved: u32 = 0,

    comptime {
        // 7×float4(112) + 4×float(16) + 2×uint(8) + 2×float(8) + 1×float4(16) + 4×uint(16) = 176 bytes
        if (@sizeOf(SDFInstance) != 176) @compileError("SDFInstance must be 176 bytes (Metal float4 aligned)");
    }

    /// Pack gradient_direction + noise_mode + noise_seed + extend_mode into packed_flags.
    /// packed_flags layout:
    ///   bit 0-7:   gradient_direction (GradientDir)
    ///   bit 8-15:  noise_mode (NoiseMode)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:    inset_shadow (0/1)
    ///   bit 25:    has_shadow2  (0/1)
    ///   bit 26-27: extend_mode (GradientExtendMode: 0=pad, 1=repeat, 2=reflect)
    ///   bit 28-31: reserved
    pub fn packFlags(
        grad_dir: GradientDir,
        noise_mode: NoiseMode,
        noise_seed: u8,
        inset_shadow: bool,
        has_shadow2: bool,
    ) u32 {
        return packFlagsEx(grad_dir, noise_mode, noise_seed, inset_shadow, has_shadow2, .pad);
    }

    /// Full version with extend_mode
    pub fn packFlagsEx(
        grad_dir: GradientDir,
        noise_mode: NoiseMode,
        noise_seed: u8,
        inset_shadow: bool,
        has_shadow2: bool,
        extend_mode: GradientExtendMode,
    ) u32 {
        return @backingInt(grad_dir) |
            (@as(u32, @backingInt(noise_mode)) << 8) |
            (@as(u32, noise_seed) << 16) |
            (if (inset_shadow) @as(u32, 1) << 24 else 0) |
            (if (has_shadow2) @as(u32, 1) << 25 else 0) |
            (@as(u32, @backingInt(extend_mode)) << 26);
    }
};

/// Shape type
/// WARNING: order must match the 4 `switch (inst.shape_type)` in sdf_primitives.metal
/// (fill / outer shadow / second outer shadow / inset shadow). **Add members to all four**:
/// the defaults differ. Fill and outer shadows default to `1.0` (miss -> shape/shadow
/// **silently vanishes**); inset shadow defaults to `-1.0` (miss -> it **fills the entire
/// shape**). Opposite symptoms for the same mistake.
pub const ShapeType = enum(u32) {
    rect = 0,
    circle = 1,
    line = 2,
    arc = 3,
    /// Ellipse inscribed in rect (semi-axes = w/2, h/2). Stroked via uniform fast path
    /// (`sdf + border_width`, inside semantics, matching rect); per-side strokes gated in
    /// shader, entry folds to uniform width.
    ellipse = 4,
};

/// Gradient direction (shader packed_flags bit 0-7)
pub const GradientDir = enum(u32) {
    none = 0,
    vertical = 1,
    horizontal = 2,
    diagonal = 3,
    radial = 4,
    conic = 5,
};

/// Gradient extend mode (shader packed_flags bit 26-27)
/// Controls gradient t beyond [0,1]
pub const GradientExtendMode = enum(u2) {
    pad = 0, // Clamp to edge color (default)
    repeat = 1, // Loop repeat
    reflect = 2, // Mirror reflect
};

/// Procedural noise mode (shader packed_flags bit 8-15)
/// Must sync with NoiseMode in src/ui/core/types.zig (passed as u8).
pub const NoiseMode = enum(u8) {
    none = 0,
    value = 1, // Value Noise (grid interpolation, suitable for rough textures)
    film_grain = 2, // Film Grain (high-freq screen grain, suitable for glass/paper feel)
};
// Compile-time assert: enum count correct (sync when updating types.zig)
comptime {
    std.debug.assert(@backingInt(NoiseMode.none) == 0);
    std.debug.assert(@backingInt(NoiseMode.value) == 1);
    std.debug.assert(@backingInt(NoiseMode.film_grain) == 2);
}

/// Multi-color gradient stops (triple-buffered GradientStop buffer, slot 2)
pub const GradientStop = extern struct {
    color: [4]f32, // RGBA linear float
    position: f32, // [0.0, 1.0]
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,

    comptime {
        if (@sizeOf(GradientStop) != 32) @compileError("GradientStop must be 32 bytes");
    }
};

/// Second shadow params (triple-buffered ShadowParam buffer, slot 3)
pub const ShadowParam = extern struct {
    color: [4]f32,
    blur: f32,
    offset_x: f32,
    offset_y: f32,
    _pad: f32 = 0,

    comptime {
        if (@sizeOf(ShadowParam) != 32) @compileError("ShadowParam must be 32 bytes");
    }
};

/// Starting per-slot instance capacity; slots grow with the frame's demand.
const MIN_INSTANCE_BYTES = @sizeOf(SDFInstance) * 512;
const MAX_UNIFORM_UPDATES = 256;
// D3D12 CBV addresses require 256-byte alignment (append aligned slots so
// normal shared draws can bind the retained frame buffer without snapshots);
// Metal buffer offsets must be multiples of 16 (the struct is not).
const UNIFORM_STRIDE = std.mem.alignForward(usize, @sizeOf(Uniforms), if (gpu.is_direct3d) 256 else 16);

/// TRANSPARENT color
const TRANSPARENT: [4]f32 = .{ 0, 0, 0, 0 };

/// Triple-buffering constant, eliminate CPU/GPU buffer contention (ref Zed 120fps approach)
const BUFFER_COUNT = 3;

/// Max gradient stops per frame (indices are u32 but the cap bounds a runaway
/// frame); storage grows from a small start.
const MAX_GRADIENT_STOPS = 32768;
/// Max second shadows per frame.
const MAX_SHADOW2 = 8192;
const MIN_STOP_BYTES = @sizeOf(GradientStop) * 256;
const MIN_SHADOW2_BYTES = @sizeOf(ShadowParam) * 128;

/// Metal SDF Renderer
/// Module-level cumulative GPU draw count (FrameStats takes delta per frame)
pub var sdf_draw_calls: u64 = 0;

pub const SdfRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    solid_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// Metal-specialized fragment entries (same template math, dead branches deleted):
    /// fill / bordered / shadow_only. Missing -> fallback to general pipeline (see metalKind).
    specialized_shape_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null),
    material_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null),
    region_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null),
    rect_pipeline: ?gpu.Backend.RenderPipeline = null,
    rounded_clip_rect_pipeline: ?gpu.Backend.RenderPipeline = null,
    plain_rect_pipeline: ?gpu.Backend.RenderPipeline = null,
    tiled_rect_pipeline: ?gpu.Backend.RenderPipeline = null,
    tiled_border_pipeline: ?gpu.Backend.RenderPipeline = null,
    shadow_ring_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// D3D12 layer passes of the general material (see splitLayers), indexed
    /// by LayerPass: outer shadows, inset shadow, border.
    layer_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null),
    transparent_interior_batches: u64 = 0,
    /// Enabled only with the Windows per-draw GPU timing diagnostic.
    trace_materials: bool = false,
    dual_shadow_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// Triple-buffered uniform buffers; must rotate sync with instance_buffers per frame.
    /// Old design: single buffer, uniform_write_offset zeroed each frame. With 3 in-flight
    /// frames, frame N+1 overwrites GPU-unconsumed frame N's viewport/clip/scale/frame_seed;
    /// shows as random flicker, wrong clip, parameter ghosting (only when GPU lags; hard to root
    /// cause).
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// Per-frame uniform slot overflow count (diagnostic). On overflow, switch to an
    /// on-demand-growing overflow uniform buffer retained across frames (same as TextRenderer).
    /// Clamping to the last
    /// slot would alias multiple draws onto memory that is overwritten later and silently corrupt
    /// output; returning an error is also wrong since opacity_layer / encoder.flush `try` it and
    /// >256 flushes in one frame would crash App.run.
    uniform_overflow_count: u64 = 0,
    uniform_overflow: SlotBuffer(BUFFER_COUNT) = .init("Zenit.SDF.OverflowUniforms", UNIFORM_STRIDE * 64),
    /// Overflow uniform slots used this frame.
    uniform_overflow_used: usize = 0,
    /// Triple-buffered instance storage sized by demand; rotate per frame, no
    /// CPU/GPU contention.
    instance_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.SDF.InstanceBuffer", MIN_INSTANCE_BYTES),
    /// Triple-buffered GradientStop storage (slot 2).
    stop_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.SDF.StopBuffer", MIN_STOP_BYTES),
    /// Triple-buffered ShadowParam storage (slot 3).
    shadow2_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.SDF.Shadow2Buffer", MIN_SHADOW2_BYTES),
    current_buffer: usize = 0,
    /// Count of entries uploaded to current stop/shadow2 buffer this frame. Stops grow
    /// only within frame with stable byte positions; flush appends tail only (old impl
    /// retransmitted all from 0, O(flush_count * total_stops) waste on repeated flushes).
    grad_stops_uploaded: usize = 0,
    shadow2_uploaded: usize = 0,

    instances: std.ArrayList(SDFInstance),
    /// Scratch of scheduleMetalRuns (kept across flushes).
    run_scratch: RunScratch = .{},
    /// GradientStop array accumulated this frame.
    grad_stops: std.ArrayList(GradientStop),
    /// ShadowParam array accumulated this frame.
    shadow2_params: std.ArrayList(ShadowParam),
    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_shape_kind: u32 = 0,
    clip2: shape_clip_pair.Uniform = .{},
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    /// Shape override: when != .rect, all downstream add*Rect APIs use this shape's SDF.
    /// Rationale: gradient/noise/shadow each have their own entry (11 add* functions); a per-member
    /// shape parameter would explode signatures. Shape is the node's 'render as' context, same
    /// nature as rect_clip.
    ///
    /// Rule: set/reset **before/after each command** (like rect_clip), never leak across
    /// commands. Leaking draws unrelated rects as ellipses.
    current_shape: ShapeType = .rect,
    instance_high_water_mark: usize = 0,
    /// Current frame seed, supplied externally, drives film_grain dynamic noise.
    frame_seed: u32 = 0,
    /// Flush offset: append across multiple flushes in same frame.
    buffer_write_offset: usize = 0,

    /// Initialize
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !SdfRenderer {
        // Compile shader (inline source)
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, sdf_shader_source);
        defer shader.deinit();

        // Get functions
        var vertex_func = try shader.getFunction("sdf_vertex_main");
        defer vertex_func.deinit();
        // D3D12 splits the material program into layer passes (see
        // splitLayers), so the mandatory pipeline is the body entry.
        var fragment_func = try shader.getFunction(if (gpu.is_direct3d) "sdf_body_fragment_main" else "sdf_fragment_main");
        defer fragment_func.deinit();

        // Create pipeline (with alpha blend). After this, every failure must release built
        // GPU objects; errdefer must be outside loop (inside, scope exits per iteration -> dead
        // code).
        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &fragment_func,
            .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
            .blend_state = .{
                .source_rgb = .one,
                .destination_rgb = .one_minus_src_alpha,
                .rgb_operation = .add,
                .source_alpha = .one,
                .destination_alpha = .one_minus_src_alpha,
                .alpha_operation = .add,
            },
        });
        errdefer pipeline.deinit();
        var layer_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null);
        errdefer for (&layer_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        if (gpu.is_direct3d) for (&layer_pipelines, [_][]const u8{ "sdf_outer_shadow_fragment_main", "sdf_inset_layer_fragment_main", "sdf_border_layer_fragment_main" }) |*slot, entry| {
            var layer_fragment = try shader.getFunction(entry);
            defer layer_fragment.deinit();
            slot.* = try gpu.Backend.createRenderPipeline(device, .{
                .vertex_function = &vertex_func,
                .fragment_function = &layer_fragment,
                .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
                .blend_state = .{
                    .source_rgb = .one,
                    .destination_rgb = .one_minus_src_alpha,
                    .rgb_operation = .add,
                    .source_alpha = .one,
                    .destination_alpha = .one_minus_src_alpha,
                    .alpha_operation = .add,
                },
            });
        };
        var specialized_shape_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null);
        errdefer for (&specialized_shape_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        // Diagnostic switch: ZENIT_SDF_GENERAL_ONLY disables Metal specializations, all
        // use general pipeline (A/B test).
        if (comptime gpu.backend_kind == .metal) metal: {
            if (@import("zenit_environment").flag("ZENIT_SDF_GENERAL_ONLY")) break :metal;
            const names = [_][]const u8{ "sdf_fill_fragment_main", "sdf_bordered_fragment_main", "sdf_shadow_only_fragment_main" };
            for (names, &specialized_shape_pipelines) |name, *slot| {
                // Specialization is acceleration only: missing entry or pipeline failure -> drop
                // whole group, use general pipeline.
                var fragment = shader.getFunction(name) catch break;
                defer fragment.deinit();
                // Shadow-only uses outer-ring vertex function (sdf_shadow_ring_vertex_main);
                // others use clipped quad (sdf_clipped_vertex_main); both clip quad into instance
                // rect.
                const ring = slot == &specialized_shape_pipelines[2];
                var vertex = shader.getFunction(if (ring) "sdf_shadow_ring_vertex_main" else "sdf_clipped_vertex_main") catch break;
                defer vertex.deinit();
                slot.* = gpu.Backend.createRenderPipeline(device, .{
                    .vertex_function = &vertex,
                    .fragment_function = &fragment,
                    .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
                    .blend_state = .{
                        .source_rgb = .one,
                        .destination_rgb = .one_minus_src_alpha,
                        .rgb_operation = .add,
                        .source_alpha = .one,
                        .destination_alpha = .one_minus_src_alpha,
                        .alpha_operation = .add,
                    },
                }) catch break;
            }
            if (specialized_shape_pipelines[2] == null) {
                for (&specialized_shape_pipelines) |*slot| if (slot.*) |*value| value.deinit();
                specialized_shape_pipelines = @splat(null);
                std.log.warn("[sdf] Metal specialized fragments unavailable; using general pipeline", .{});
            }
        }
        var region_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null);
        errdefer for (&region_pipelines) |*entry| if (entry.*) |*pipeline_entry| pipeline_entry.deinit();
        var solid_pipeline: ?gpu.Backend.RenderPipeline = null;
        var rounded_clip_rect_pipeline: ?gpu.Backend.RenderPipeline = null;
        errdefer if (rounded_clip_rect_pipeline) |*value| value.deinit();
        var rect_pipeline: ?gpu.Backend.RenderPipeline = null;
        errdefer if (rect_pipeline) |*value| value.deinit();
        var material_pipelines: [3]?gpu.Backend.RenderPipeline = @splat(null);
        errdefer for (&material_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        var plain_rect_pipeline: ?gpu.Backend.RenderPipeline = null;
        var tiled_rect_pipeline: ?gpu.Backend.RenderPipeline = null;
        var tiled_border_pipeline: ?gpu.Backend.RenderPipeline = null;
        errdefer if (tiled_border_pipeline) |*value| value.deinit();
        errdefer if (tiled_rect_pipeline) |*value| value.deinit();
        var shadow_ring_pipeline: ?gpu.Backend.RenderPipeline = null;
        var dual_shadow_pipeline: ?gpu.Backend.RenderPipeline = null;
        errdefer if (dual_shadow_pipeline) |*value| value.deinit();
        errdefer if (shadow_ring_pipeline) |*value| value.deinit();
        errdefer if (plain_rect_pipeline) |*value| value.deinit();
        errdefer if (solid_pipeline) |*value| value.deinit();
        // Specialized shaders are accelerators. Their absence must not prevent
        // core UI initialization; the general SDF pipeline implements all cases.
        var optimized_ready = false;
        optimized: {
            if (gpu.is_direct3d and @import("zenit_environment").flag("ZENIT_D3D12_SDF_GENERAL_ONLY")) break :optimized;
            if (gpu.is_direct3d) {
                if (device.supportsVertexViewportIndex()) {
                    var region_vertex = shader.getFunction("sdf_region_vertex_main") catch break :optimized;
                    defer region_vertex.deinit();
                    const region_names = [_][]const u8{ "sdf_plain_rect_fragment_main", "sdf_rect_fragment_main", "sdf_rounded_clip_rect_fragment_main" };
                    for (region_names, &region_pipelines) |name, *destination| {
                        var fragment = shader.getFunction(name) catch break :optimized;
                        defer fragment.deinit();
                        destination.* = gpu.Backend.createRenderPipeline(device, .{
                            .vertex_function = &region_vertex,
                            .fragment_function = &fragment,
                            .color_attachment_formats = &.{gpu.color_format},
                            .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha },
                        }) catch break :optimized;
                    }
                }
            }
            if (gpu.is_direct3d) {
                var tiled_vertex = shader.getFunction("sdf_tiled_rect_vertex_main") catch break :optimized;
                defer tiled_vertex.deinit();
                const names = [_][]const u8{ "sdf_solid_fragment_main", "sdf_plain_rect_fragment_main", "sdf_rect_fragment_main", "sdf_plain_rect_fragment_main", "sdf_rect_fragment_main", "sdf_rounded_clip_rect_fragment_main", "sdf_linear_x_fragment_main", "sdf_linear_y_fragment_main", "sdf_inset_rect_fragment_main" };
                const pipelines = [_]*?gpu.Backend.RenderPipeline{ &solid_pipeline, &plain_rect_pipeline, &rect_pipeline, &tiled_rect_pipeline, &tiled_border_pipeline, &rounded_clip_rect_pipeline, &material_pipelines[0], &material_pipelines[1], &material_pipelines[2] };
                for (names, pipelines) |name, destination| {
                    var solid_fragment = shader.getFunction(name) catch break :optimized;
                    defer solid_fragment.deinit();
                    destination.* = gpu.Backend.createRenderPipeline(device, .{
                        .vertex_function = if (destination == &tiled_rect_pipeline or destination == &tiled_border_pipeline) &tiled_vertex else &vertex_func,
                        .fragment_function = &solid_fragment,
                        .color_attachment_formats = &.{gpu.color_format},
                        .blend_state = .{
                            .source_rgb = .one,
                            .destination_rgb = .one_minus_src_alpha,
                            .rgb_operation = .add,
                            .source_alpha = .one,
                            .destination_alpha = .one_minus_src_alpha,
                            .alpha_operation = .add,
                        },
                    }) catch break :optimized;
                }
            }

            if (gpu.is_direct3d) {
                var dual_fragment = shader.getFunction("sdf_dual_shadow_fragment_main") catch break :optimized;
                defer dual_fragment.deinit();
                var dual_vertex = shader.getFunction("sdf_dual_shadow_vertex_main") catch break :optimized;
                defer dual_vertex.deinit();
                dual_shadow_pipeline = gpu.Backend.createRenderPipeline(device, .{
                    .vertex_function = &dual_vertex,
                    .fragment_function = &dual_fragment,
                    .color_attachment_formats = &.{gpu.color_format},
                    .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha },
                }) catch break :optimized;
                var ring_vertex = shader.getFunction("sdf_shadow_ring_vertex_main") catch break :optimized;
                defer ring_vertex.deinit();
                var ring_fragment = shader.getFunction("sdf_shadow_ring_fragment_main") catch break :optimized;
                defer ring_fragment.deinit();
                shadow_ring_pipeline = gpu.Backend.createRenderPipeline(device, .{
                    .vertex_function = &ring_vertex,
                    .fragment_function = &ring_fragment,
                    .color_attachment_formats = &.{gpu.color_format},
                    .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha },
                }) catch break :optimized;
            }

            optimized_ready = true;
        }
        if (!optimized_ready) {
            for (&region_pipelines) |*slot| {
                if (slot.*) |*value| value.deinit();
                slot.* = null;
            }
            for (&material_pipelines) |*slot| {
                if (slot.*) |*value| value.deinit();
                slot.* = null;
            }
            if (solid_pipeline) |*value| value.deinit();
            solid_pipeline = null;
            if (plain_rect_pipeline) |*value| value.deinit();
            plain_rect_pipeline = null;
            if (rect_pipeline) |*value| value.deinit();
            rect_pipeline = null;
            if (tiled_rect_pipeline) |*value| value.deinit();
            tiled_rect_pipeline = null;
            if (tiled_border_pipeline) |*value| value.deinit();
            tiled_border_pipeline = null;
            if (rounded_clip_rect_pipeline) |*value| value.deinit();
            rounded_clip_rect_pipeline = null;
            if (shadow_ring_pipeline) |*value| value.deinit();
            shadow_ring_pipeline = null;
            if (dual_shadow_pipeline) |*value| value.deinit();
            dual_shadow_pipeline = null;
            std.log.warn("[sdf] using general pipeline; optional optimizations unavailable", .{});
        }

        // Create triple-buffered uniform buffers (sync rotation with instance buffers).
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*b| b.destroy();
        for (&uniform_buffers) |*buf| {
            buf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.SDF.Uniforms",
                .size = UNIFORM_STRIDE * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        std.log.info("[SdfRenderer] Initialized (triple-buffered SDF pipeline)", .{});

        return SdfRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .solid_pipeline = solid_pipeline,
            .specialized_shape_pipelines = specialized_shape_pipelines,
            .region_pipelines = region_pipelines,
            .rect_pipeline = rect_pipeline,
            .rounded_clip_rect_pipeline = rounded_clip_rect_pipeline,
            .plain_rect_pipeline = plain_rect_pipeline,
            .material_pipelines = material_pipelines,
            .tiled_rect_pipeline = tiled_rect_pipeline,
            .tiled_border_pipeline = tiled_border_pipeline,
            .shadow_ring_pipeline = shadow_ring_pipeline,
            .layer_pipelines = layer_pipelines,
            .dual_shadow_pipeline = dual_shadow_pipeline,
            .trace_materials = gpu.is_direct3d and @import("zenit_environment").flag("ZENIT_WINDOWS_SDF_MATERIAL_TRACE"),
            .uniform_buffers = uniform_buffers,
            .instances = .empty,
            .grad_stops = .empty,
            .shadow2_params = .empty,
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    pub const MetalKind = enum { general, fill, bordered, shadow_only };

    /// Pick Metal specialization. Select only if deleted branches have false runtime
    /// conditions already; output per-pixel identical to general pipeline (sdf_fragment_impl).
    /// Scratch storage of scheduleMetalRuns.
    pub const RunScratch = struct {
        reordered: std.ArrayList(SDFInstance) = .empty,
        run_of: std.ArrayList(u16) = .empty,
        quads: std.ArrayList([4]f32) = .empty,

        fn deinit(self: *RunScratch, allocator: std.mem.Allocator) void {
            self.reordered.deinit(allocator);
            self.run_of.deinit(allocator);
            self.quads.deinit(allocator);
        }
    };

    /// The pixels an instance's vertex quad can cover (logical x0, y0, x1, y1), as
    /// sdf_vertex_impl expands it: shadow blur and offset, positive spread, a second shadow.
    /// Padded by one logical pixel; the clip clamp only shrinks it.
    pub fn instanceQuad(item: *const SDFInstance, shadow2: []const ShadowParam) [4]f32 {
        var expand: f32 = if (item.shape_type == 3) 0 else item.shadow_blur * 2 + @abs(item.shadow_offset_x) + @abs(item.shadow_offset_y);
        if (item.packed_flags & shadow_spread_flag != 0) expand += @max(item.noise_scale, 0);
        if (item.packed_flags & (1 << 25) != 0) {
            if (item.shadow2_index < shadow2.len) {
                const s2 = shadow2[item.shadow2_index];
                expand = @max(expand, s2.blur * 2 + @abs(s2.offset_x) + @abs(s2.offset_y));
            } else expand = std.math.inf(f32);
        }
        const r = item.rect;
        return .{ r[0] - expand - 1, r[1] - expand - 1, r[0] + r[2] + expand + 1, r[1] + r[3] + expand + 1 };
    }

    /// Group the batch by Metal pipeline kind, moving an instance earlier only past instances
    /// whose quads it does not touch (so every pixel blends in the same order): each instance
    /// joins the first run of its kind after the last run it overlaps, or opens a new run.
    /// A label grid (shadow, fill, border per control) otherwise splits into one draw per
    /// instance. Leaves the batch as is when it cannot allocate or has too many runs.
    pub fn scheduleMetalRuns(items: []SDFInstance, shadow2: []const ShadowParam, scratch: *RunScratch, allocator: std.mem.Allocator) void {
        if (items.len < 3) return;
        const max_runs = 64;
        scratch.run_of.resize(allocator, items.len) catch return;
        scratch.quads.resize(allocator, items.len) catch return;
        scratch.reordered.resize(allocator, items.len) catch return;
        var run_kind: [max_runs]MetalKind = undefined;
        var run_bounds: [max_runs][4]f32 = undefined;
        var run_len: [max_runs]usize = @splat(0);
        var runs: usize = 0;
        var changed = false;
        for (items, 0..) |*item, i| {
            const q = instanceQuad(item, shadow2);
            scratch.quads.items[i] = q;
            const kind = metalKind(item.*);
            // Last run this instance must stay above.
            var floor: usize = 0;
            var r = runs;
            outer: while (r > 0) {
                r -= 1;
                const b = run_bounds[r];
                if (!(q[0] < b[2] and b[0] < q[2] and q[1] < b[3] and b[1] < q[3])) continue;
                for (scratch.quads.items[0..i], scratch.run_of.items[0..i]) |m, mr| {
                    if (mr == r and q[0] < m[2] and m[0] < q[2] and q[1] < m[3] and m[1] < q[3]) {
                        floor = r;
                        break :outer;
                    }
                }
            }
            var target: ?usize = null;
            for (floor..runs) |k| if (run_kind[k] == kind) {
                target = k;
                break;
            };
            const t = target orelse blk: {
                if (runs == max_runs) return;
                run_kind[runs] = kind;
                run_bounds[runs] = q;
                runs += 1;
                break :blk runs - 1;
            };
            // Joining an earlier run is the only way the order changes.
            if (t != runs - 1) changed = true;
            const b = run_bounds[t];
            run_bounds[t] = .{ @min(b[0], q[0]), @min(b[1], q[1]), @max(b[2], q[2]), @max(b[3], q[3]) };
            run_len[t] += 1;
            scratch.run_of.items[i] = @intCast(t);
        }
        if (!changed) return;
        var start: [max_runs]usize = undefined;
        var acc: usize = 0;
        for (0..runs) |k| {
            start[k] = acc;
            acc += run_len[k];
        }
        for (items, scratch.run_of.items) |item, rk| {
            scratch.reordered.items[start[rk]] = item;
            start[rk] += 1;
        }
        @memcpy(items, scratch.reordered.items);
    }

    pub fn metalKind(item: SDFInstance) MetalKind {
        if (item.shape_type != 0) return .general;
        const per_side = item.border_widths[0] != 0 or item.border_widths[1] != 0 or
            item.border_widths[2] != 0 or item.border_widths[3] != 0;
        const has_border = item.border_width != 0 or per_side;
        const has_shadow = item.shadow_blur != 0;
        if (item.packed_flags == 0 and !has_shadow) return if (has_border) .bordered else .fill;
        // Shadow-only: transparent fill, no stroke, spread bit only (bit 28, read in shadow
        // branch only). Blur must be positive: ring geometry expands by quad extent (blur*2),
        // negative would flip/overlap tiles.
        if (item.packed_flags & ~shadow_spread_flag == 0 and item.shadow_blur > 0 and !has_border and item.fill_color[3] == 0) return .shadow_only;
        return .general;
    }

    const PipelineKind = enum { general, solid, solid_rect, plain_rect, shadow_ring, dual_shadow, linear_x, linear_y, inset_rect, layer };
    /// packed_flags bits 30-31 mark the layer-pass copies of a split instance
    /// (the shaders ignore them; bits 0-29 carry material flags).
    const LayerPass = enum(u2) { outer_shadow = 1, inset = 2, border = 3 };
    const layer_pass_shift = 30;
    const inset_shadow_flag: u32 = 1 << 24;
    fn layerPass(item: SDFInstance) ?LayerPass {
        const bits: u2 = @intCast(item.packed_flags >> layer_pass_shift);
        return if (bits == 0) null else @fromBackingInt(@intCast(bits));
    }
    fn hasOuterShadow(item: SDFInstance) bool {
        return (item.shadow_color[3] > 0 and item.shadow_blur > 0) or item.packed_flags & (1 << 25) != 0;
    }
    /// Instances drawn with the D3D12 body program (sdf_body_fragment_main):
    /// general ones, and every instance when the optional pipelines are
    /// unavailable.
    fn drawsWithBody(self: *const SdfRenderer, item: SDFInstance) bool {
        return self.solid_pipeline == null or self.pipelineKind(item) == .general;
    }
    /// The one-pass program composites front to back (composite_premul puts
    /// each later layer under the result): outer shadows, fill, inset shadow,
    /// border. The Windows 10 WARP JIT cannot compile a program holding more
    /// than two shape SDF evaluations (process crash / device removed), so on
    /// D3D12 the body program holds only the fill (and the border when there is
    /// no inset shadow), and an instance is drawn bottom-up as over-blended
    /// layer passes, which reproduce the one pass:
    ///   border copy, inset copy (inset shadow only), body, outer-shadow copy.
    /// Shadow ring / dual-shadow pipelines draw their own shadows and the
    /// inset-rect specialization (constant shape and flags) its own inset and
    /// border.
    fn needsOuterShadowPass(self: *const SdfRenderer, item: SDFInstance) bool {
        if (!hasOuterShadow(item)) return false;
        return self.drawsWithBody(item) or self.pipelineKind(item) == .inset_rect;
    }
    fn needsInsetPasses(self: *const SdfRenderer, item: SDFInstance) bool {
        return item.packed_flags & inset_shadow_flag != 0 and self.drawsWithBody(item);
    }
    fn layerCopy(item: SDFInstance, pass: LayerPass) SDFInstance {
        var copy = item;
        copy.packed_flags |= @as(u32, @backingInt(pass)) << layer_pass_shift;
        return copy;
    }
    fn splitLayers(self: *SdfRenderer) !void {
        if (comptime !gpu.is_direct3d) return;
        var extra: usize = 0;
        for (self.instances.items) |item| {
            // Already split by an earlier render() of the same list (render
            // without flush keeps the instances): splitting again would add a
            // second layer pass per body.
            if (layerPass(item) != null) return;
            extra += @intFromBool(self.needsOuterShadowPass(item)) + 2 * @as(usize, @intFromBool(self.needsInsetPasses(item)));
        }
        if (extra == 0) return;
        const old_len = self.instances.items.len;
        try self.instances.resize(self.allocator, old_len + extra);
        const items = self.instances.items;
        var write = items.len;
        var read = old_len;
        while (read > 0) {
            read -= 1;
            const item = items[read];
            const outer = self.needsOuterShadowPass(item);
            const inset = self.needsInsetPasses(item);
            if (outer) {
                write -= 1;
                items[write] = layerCopy(item, .outer_shadow);
            }
            write -= 1;
            items[write] = item;
            if (inset) {
                write -= 1;
                items[write] = layerCopy(item, .inset);
                write -= 1;
                items[write] = layerCopy(item, .border);
            }
        }
        std.debug.assert(write == 0);
    }
    fn pipelineKind(self: *const SdfRenderer, item: SDFInstance) PipelineKind {
        if (comptime gpu.is_direct3d) if (layerPass(item) != null) return .layer;
        if (item.shape_type == 0 and item.rect[2] > 0 and item.rect[3] > 0 and item.fill_color[3] == 0 and item.shadow_color[3] > 0 and
            item.shadow_blur > 0 and item.border_width == 0 and item.packed_flags & ~shadow_spread_flag == 0)
        {
            var borderless = true;
            for (item.border_widths) |width| borderless = borderless and width == 0;
            if (borderless) return .shadow_ring;
        }
        if (item.shape_type == 0 and item.packed_flags == 1 << 25 and item.border_width == 0) {
            var borderless = true;
            for (item.border_widths) |width| borderless = borderless and width == 0;
            if (borderless) return .dual_shadow;
        }
        if (item.shape_type == 0) {
            if (item.packed_flags == 1 << 24) return .inset_rect;
            if (item.shadow_color[3] == 0) {
                if (item.packed_flags == 1) return .linear_x;
                if (item.packed_flags == 2) return .linear_y;
            }
        }
        if (!solidEligible(item)) return .general;
        // Specialized pipelines evaluate one shape clip at most.
        if (self.clip2.kind != 0) return .general;
        if (item.shape_type != 0) return .solid;
        if (self.clip_shape_kind != 0 or item.border_width != 0) return .solid_rect;
        for (item.corner_radii) |radius| if (radius != 0) return .solid_rect;
        for (item.border_widths) |width| if (width != 0) return .solid_rect;
        return .plain_rect;
    }

    /// Destroy
    /// Per-slot scratch storage is rewritten every frame; see idle_storage.
    pub fn setScratchVolatile(self: *SdfRenderer, make_volatile: bool) void {
        idle_storage.setBuffersVolatile(&self.uniform_buffers, make_volatile);
        self.uniform_overflow.setVolatile(make_volatile);
        self.instance_buffers.setVolatile(make_volatile);
        self.stop_buffers.setVolatile(make_volatile);
        self.shadow2_buffers.setVolatile(make_volatile);
    }

    /// Drop demand-sized scratch so the next frame regrows it to what it
    /// draws. Only while no submitted frame is executing.
    pub fn releaseScratch(self: *SdfRenderer) void {
        self.uniform_overflow.release();
        self.instance_buffers.release();
        self.stop_buffers.release();
        self.shadow2_buffers.release();
    }

    pub fn deinit(self: *SdfRenderer) void {
        self.instances.deinit(self.allocator);
        self.run_scratch.deinit(self.allocator);
        self.grad_stops.deinit(self.allocator);
        self.shadow2_params.deinit(self.allocator);
        self.instance_buffers.deinit(self.allocator);
        self.stop_buffers.deinit(self.allocator);
        self.shadow2_buffers.deinit(self.allocator);
        for (&self.uniform_buffers) |*buf| buf.destroy();
        self.uniform_overflow.deinit(self.allocator);
        self.pipeline.deinit();
        if (self.solid_pipeline) |*value| value.deinit();
        for (&self.specialized_shape_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        for (&self.region_pipelines) |*entry| if (entry.*) |*value| value.deinit();
        if (self.rect_pipeline) |*value| value.deinit();
        if (self.rounded_clip_rect_pipeline) |*value| value.deinit();
        for (&self.material_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        if (self.plain_rect_pipeline) |*value| value.deinit();
        if (self.tiled_rect_pipeline) |*value| value.deinit();
        if (self.tiled_border_pipeline) |*value| value.deinit();
        if (self.shadow_ring_pipeline) |*value| value.deinit();
        for (&self.layer_pipelines) |*slot| if (slot.*) |*value| value.deinit();
        if (self.dual_shadow_pipeline) |*value| value.deinit();
        std.log.info("[SdfRenderer] Destroyed", .{});
    }

    /// Ensure frame slot's overflow uniform buffer holds at least `slots` Uniforms.
    fn ensureUniformOverflowCapacity(self: *SdfRenderer, slots: usize) !*gpu.Backend.Buffer {
        return (try self.uniform_overflow.ensure(self.allocator, self.device, self.current_buffer, slots * UNIFORM_STRIDE)).buffer;
    }

    /// Begin new frame
    /// width/height: logical pixels; scale: DPI scale factor (Retina=2.0)
    /// Start a GPU frame.
    pub fn beginFrame(self: *SdfRenderer, width: f32, height: f32, scale: f32, frame_seed: u32) void {
        self.beginFrameFor(width, height, scale, frame_seed, true);
    }

    /// `gpu_frame` false: a CPU patch encode (cpu_flat), which reads only the
    /// CPU-side batches: the triple-buffered GPU slots keep rotating with GPU
    /// frames alone, so a slot an in-flight frame reads is never reused.
    pub fn beginFrameFor(self: *SdfRenderer, width: f32, height: f32, scale: f32, frame_seed: u32, gpu_frame: bool) void {
        self.instances.clearRetainingCapacity();
        self.grad_stops.clearRetainingCapacity();
        self.shadow2_params.clearRetainingCapacity();
        self.grad_stops_uploaded = 0;
        self.shadow2_uploaded = 0;
        self.buffer_write_offset = 0;
        // Rotate to next buffer (triple buffering, no CPU/GPU contention).
        if (gpu_frame) {
            self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
            self.uniform_overflow.beginSlot(self.current_buffer);
            self.instance_buffers.beginSlot(self.current_buffer);
            self.stop_buffers.beginSlot(self.current_buffer);
            self.shadow2_buffers.beginSlot(self.current_buffer);
        }
        self.uniform_write_offset = 0;
        self.uniform_overflow_used = 0;
        // Pass viewport_size in physical pixels to shader.
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radii = .{ 0, 0, 0, 0 };
        self.clip_shape_kind = 0;
        self.clip2 = .{};
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
        self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.current_shape = .rect;
        self.frame_seed = frame_seed;
    }

    /// Update viewport size only (offscreen composite render pass switching).
    /// No buffer/instance reset; frame state continues.
    pub fn setViewport(self: *SdfRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    /// Second shape clip intersected with the primary one (shape_clip_pair.zig).
    pub fn setPartnerClip(self: *SdfRenderer, clip: shape_clip_pair.Uniform) void {
        self.clip2 = clip;
    }

    pub fn setClipMask(self: *SdfRenderer, shape_kind: u32, rect: ?[4]f32, radii: [4]f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radii = radii;
            self.clip_shape_kind = shape_kind;
            self.clip_fill_rule = fill_rule;
            self.clip_point_count = point_count;
            self.clip_contour_count = contour_count;
            for (0..MAX_CLIP_POLYGON_CONTOURS) |i| self.clip_polygon_end_points[i] = contour_end_points[i];
            self.clip_polygon_points = polygon_points;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radii = .{ 0, 0, 0, 0 };
            self.clip_shape_kind = 0;
            self.clip2 = .{};
            self.clip_fill_rule = 0;
            self.clip_point_count = 0;
            self.clip_contour_count = 0;
            self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
            self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        }
    }

    pub fn setRectClip(self: *SdfRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// Clamp corner radii to min(w,h)/2, prevent huge radii causing full SDF discard. Same
    /// normalisation as every clip / composite mask (corner_radii.zig), so outlines match.
    inline fn clampRadii(radii: [4]f32, w: f32, h: f32) [4]f32 {
        return corner_radii.normalize(radii, w, h);
    }

    /// Add rounded rect (simplified API).
    pub fn addRoundedRect(self: *SdfRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32, radii: [4]f32) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = 0,
        });
    }

    // ========== SDF Native API ==========

    /// Add bordered rounded rect (single draw call hollow border).
    pub fn addBorderedRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_width: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = border_width,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = 0,
        });
    }

    /// Add per-side border rounded rect (single draw call, no clipping).
    /// border_widths: [top, right, bottom, left]
    pub fn addBorderedRectPerSide(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_widths: [4]f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = 0,
            .border_widths = border_widths,
        });
    }

    /// Add shadowed rounded rect.
    pub fn addShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = 0,
        });
    }

    /// Outer shadow with CSS spread. Spread packed in noise_scale (shadow-only instance
    /// does not fill/noise), marked by packed_flags bit 28; spread == 0 equals addShadowRect.
    pub fn addShadowRectSpread(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        spread: f32,
        radii: [4]f32,
    ) !void {
        if (spread == 0) return self.addShadowRect(x, y, w, h, fill_color, shadow_color, shadow_blur, shadow_offset_x, shadow_offset_y, radii);
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = shadow_spread_flag,
            .noise_scale = spread,
        });
    }

    /// packed_flags bit 28: outer shadow has spread (value in noise_scale).
    pub const shadow_spread_flag: u32 = 1 << 28;

    /// Add gradient rect (single instance, shader native interpolation).
    pub fn addGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        direction: GradientDir,
        radii: [4]f32,
    ) !void {
        return self.addGradientRectEx(x, y, w, h, from_color, to_color, direction, radii, .pad);
    }

    /// Add gradient rect (with extend mode).
    pub fn addGradientRectEx(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        direction: GradientDir,
        radii: [4]f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(direction, .none, 0, false, false, extend_mode),
        });
    }

    /// Add radial gradient rect, custom center and extend mode.
    /// center_x/center_y: UV space offset, 0,0 = center; range [-0.5, 0.5] suggested.
    /// Note: radial gradient and outer shadow mutually exclusive (shadow_offset reused for center).
    pub fn addRadialGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        radii: [4]f32,
        center_x: f32,
        center_y: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = center_x, // Reused as center UV X offset.
            .shadow_offset_y = center_y, // Reused as center UV Y offset.
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(.radial, .none, 0, false, false, extend_mode),
        });
    }

    /// Add conic gradient rect, custom start angle and extend mode.
    /// start_angle_rad: start angle (radians, 0 = right, clockwise positive).
    pub fn addConicGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        radii: [4]f32,
        start_angle_rad: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(.conic, .none, 0, false, false, extend_mode),
            ._ext_reserved = @bitCast(start_angle_rad), // Reused as start angle.
        });
    }

    /// Add multi-color gradient rect (multi-stop, no banding).
    /// radial_center_x/y: radial center UV offset (0,0 = center).
    /// conic_start_angle: conic start angle (radians).
    /// extend_mode: gradient extend mode (pad/repeat/reflect).
    pub fn addMultiGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        stops: []const GradientStop,
        direction: GradientDir,
        radii: [4]f32,
        radial_center_x: f32,
        radial_center_y: f32,
        conic_start_angle: f32,
        extend_mode: GradientExtendMode,
        /// Radial ellipse radii (UV; 0.5 = inscribed). Non-default via bit 29 +
        /// noise_scale/intensity.
        radial_radius: [2]f32,
    ) !void {
        const stop_offset: u32 = @intCast(self.grad_stops.items.len);
        // Prevent u32 underflow: skip when stop_offset full.
        if (stop_offset >= MAX_GRADIENT_STOPS) {
            std.log.warn("[SDFRenderer] GradientStop buffer full ({} stops used), skipping multi_gradient", .{stop_offset});
            return;
        }
        const available = MAX_GRADIENT_STOPS - stop_offset;
        const stop_count: u32 = @intCast(@min(stops.len, available));
        if (stop_count < stops.len) {
            std.log.warn("[SDFRenderer] GradientStop clamped: requested {}, available {}", .{ stops.len, available });
        }
        try self.grad_stops.appendSlice(self.allocator, stops[0..stop_count]);
        // Radial/conic reuse shadow_offset and _ext_reserved.
        const custom_radius = direction == .radial and
            (@abs(radial_radius[0] - 0.5) > 1e-4 or @abs(radial_radius[1] - 0.5) > 1e-4) and
            radial_radius[0] > 0 and radial_radius[1] > 0;
        const shadow_offset_x: f32 = if (direction == .radial) radial_center_x else 0;
        const shadow_offset_y: f32 = if (direction == .radial) radial_center_y else 0;
        const ext_reserved: u32 = if (direction == .conic) @bitCast(conic_start_angle) else 0;
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = if (stops.len > 0) stops[0].color else TRANSPARENT,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = if (stops.len > 1) stops[stops.len - 1].color else TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(direction, .none, 0, false, false, extend_mode) |
                (if (custom_radius) radial_radius_flag else 0),
            .noise_scale = if (custom_radius) radial_radius[0] else 0,
            .noise_intensity = if (custom_radius) radial_radius[1] else 0,
            .gradient_stop_offset = stop_offset,
            .gradient_stop_count = stop_count,
            ._ext_reserved = ext_reserved,
        });
    }

    /// packed_flags bit 29: radial gradient has custom ellipse radii (noise_scale=rx,
    /// noise_intensity=ry).
    pub const radial_radius_flag: u32 = 1 << 29;

    /// Add rounded rect with noise texture.
    pub fn addNoiseRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        noise_mode: NoiseMode,
        noise_scale: f32,
        noise_intensity: f32,
        noise_seed: u8,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, noise_mode, noise_seed, false, false),
            .noise_scale = @max(noise_scale, 1.0),
            .noise_intensity = noise_intensity,
        });
    }

    /// Add rounded rect with inset shadow.
    /// shadow_color: inset shadow color; shadow_blur/offset_x/y: inset shadow params.
    pub fn addInsetShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, .none, 0, true, false),
        });
    }

    /// Add rounded rect with two shadows (outer shadow 1 + outer shadow 2).
    pub fn addDualShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow1_color: [4]f32,
        shadow1_blur: f32,
        shadow1_offset_x: f32,
        shadow1_offset_y: f32,
        shadow2: ShadowParam,
        radii: [4]f32,
    ) !void {
        const s2_index: u32 = @intCast(self.shadow2_params.items.len);
        if (s2_index >= MAX_SHADOW2) {
            std.log.warn("[SDFRenderer] ShadowParam buffer full ({} params), skipping dual_shadow", .{s2_index});
            return;
        }
        try self.shadow2_params.append(self.allocator, shadow2);
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow1_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow1_blur,
            .shadow_offset_x = shadow1_offset_x,
            .shadow_offset_y = shadow1_offset_y,
            .shape_type = @backingInt(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, .none, 0, false, true),
            .shadow2_index = s2_index,
        });
    }

    /// Add arc (ring segment).
    /// cx, cy: center (logical pixels).
    /// outer_radius: outer radius.
    /// stroke_width: line width.
    /// start_angle: start angle (radians, 0 = 3 o'clock, counter-clockwise positive).
    /// end_angle: end angle (radians).
    /// color: arc color.
    ///
    /// Ellipse inscribed in (x,y,w,h). `border_width <= 0` means no stroke.
    ///
    /// Per-side stroke is meaningless for an ellipse (no 'four edges') and the shader hard-codes a
    /// rect inner outline. Entry folds the four values to their **max**, not the first:
    /// {0,0,0,4} taking the first would silently become 0 width.
    pub fn addEllipse(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_width: f32,
        border_widths: [4]f32,
    ) !void {
        const uniform_w = @max(border_width, @max(
            @max(border_widths[0], border_widths[1]),
            @max(border_widths[2], border_widths[3]),
        ));
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            // Ellipse ignores corner_radii (SDF from semi-axes), zero to avoid confusion.
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_width = uniform_w,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @backingInt(ShapeType.ellipse),
            .packed_flags = 0,
        });
    }

    pub fn addArc(
        self: *SdfRenderer,
        cx: f32,
        cy: f32,
        outer_radius: f32,
        stroke_width: f32,
        start_angle: f32,
        end_angle: f32,
        color: [4]f32,
    ) !void {
        // Bounding box: centered on the arc center, side length = 2 * outer_radius (center +/-
        // outer_radius).
        const size = outer_radius * 2;
        try self.instances.append(self.allocator, .{
            .rect = .{ cx - outer_radius, cy - outer_radius, size, size },
            .rect_clip = self.current_rect_clip,
            .fill_color = color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = .{ outer_radius, outer_radius, outer_radius, outer_radius },
            .border_width = stroke_width,
            .shadow_blur = 0,
            .shadow_offset_x = start_angle,
            .shadow_offset_y = end_angle,
            .shape_type = @backingInt(ShapeType.arc),
            .packed_flags = 0,
        });
    }

    /// Render all instances (auto-batch, prevent buffer overflow).
    pub fn render(self: *SdfRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;
        try self.splitLayers();
        self.instance_high_water_mark = @max(self.instance_high_water_mark, self.instances.items.len);

        // Update uniform buffer (once). Overflow **cannot** clamp to last slot; that aliases
        // multiple draws to overwritten memory, silent wrong output. Cannot error-drop batch:
        // most callers `try` propagate, crashes App.run. Insufficient slots -> use overflow buffer.
        const uniform_buffer, const uniform_byte_offset = blk: {
            if (self.uniform_write_offset < MAX_UNIFORM_UPDATES) {
                const slot = self.uniform_write_offset;
                self.uniform_write_offset += 1;
                break :blk .{ &self.uniform_buffers[self.current_buffer], slot * UNIFORM_STRIDE };
            }
            self.uniform_overflow_count += 1;
            const slot = self.uniform_overflow_used;
            const buf = try self.ensureUniformOverflowCapacity(slot + 1);
            self.uniform_overflow_used += 1;
            break :blk .{ buf, slot * UNIFORM_STRIDE };
        };
        // Only film-grain batches consume the frame seed in the shader.
        // Keep other constants stable so Direct3D can reuse their immutable
        // GPU storage across frames without changing any pixels.
        const batch_seed = blk: {
            for (self.instances.items) |inst| {
                if (((inst.packed_flags >> 8) & 0xff) == @backingInt(NoiseMode.film_grain) and inst.noise_scale > 0) break :blk self.frame_seed;
            }
            break :blk @as(u32, 0);
        };
        const uniforms = Uniforms{
            .viewport_size = .{ self.viewport_width, self.viewport_height },
            .scale_factor = self.scale_factor,
            .clip_shape_kind = self.clip_shape_kind,
            .clip2 = shape_clip_pair.field(self.clip2),
            .clip_rect = self.clip_rect,
            .clip_radii = self.clip_radii,
            .clip_fill_rule = self.clip_fill_rule,
            .clip_point_count = self.clip_point_count,
            .clip_contour_count = self.clip_contour_count,
            .clip_polygon_end_points = self.clip_polygon_end_points,
            .clip_polygon_points = self.clip_polygon_points,
            .frame_seed = batch_seed,
            .raster_clip_pos = if (comptime gpu.is_direct3d)
                @intFromBool(render_pass.matchesViewport(.{ self.viewport_width, self.viewport_height }))
            else
                0,
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        // Set pipeline (once).
        render_pass.setPipeline(&self.pipeline);
        // One uniform slot, not the rest of the ring: Direct3D snapshots the bound
        // range per draw (constant buffers over 4 KiB are copied into a new buffer).
        gpu.setVertexBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);
        gpu.setFragmentBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);

        // Upload GradientStop data to slot 2 (append: tail only).
        {
            const stop_count = self.grad_stops.items.len;
            const stops = try self.stop_buffers.ensure(self.allocator, self.device, self.current_buffer, @sizeOf(GradientStop) * @max(@as(usize, 1), stop_count));
            // Earlier draws keep the retired buffer; this one starts empty.
            if (stops.replaced) self.grad_stops_uploaded = 0;
            const stop_buf = stops.buffer;
            if (stop_count > self.grad_stops_uploaded) {
                const byte_off = @sizeOf(GradientStop) * self.grad_stops_uploaded;
                const new_bytes = @sizeOf(GradientStop) * (stop_count - self.grad_stops_uploaded);
                if (stop_buf.getMappedRange(byte_off, new_bytes)) |stop_data| {
                    @memcpy(stop_data, std.mem.sliceAsBytes(self.grad_stops.items[self.grad_stops_uploaded..]));
                    self.grad_stops_uploaded = stop_count;
                } else |_| {}
            }
            // Only the uploaded stops (shaders index from 0); at least one element.
            gpu.setFragmentBufferRange(render_pass, 2, stop_buf, 0, @sizeOf(GradientStop) * @max(@as(usize, 1), self.grad_stops_uploaded));
        }

        // Upload ShadowParam data to slot 3 (append: tail only).
        {
            const s2_count = self.shadow2_params.items.len;
            const shadows = try self.shadow2_buffers.ensure(self.allocator, self.device, self.current_buffer, @sizeOf(ShadowParam) * @max(@as(usize, 1), s2_count));
            if (shadows.replaced) self.shadow2_uploaded = 0;
            const s2_buf = shadows.buffer;
            if (s2_count > self.shadow2_uploaded) {
                const byte_off = @sizeOf(ShadowParam) * self.shadow2_uploaded;
                const new_bytes = @sizeOf(ShadowParam) * (s2_count - self.shadow2_uploaded);
                if (s2_buf.getMappedRange(byte_off, new_bytes)) |s2_data| {
                    @memcpy(s2_data, std.mem.sliceAsBytes(self.shadow2_params.items[self.shadow2_uploaded..]));
                    self.shadow2_uploaded = s2_count;
                } else |_| {}
            }
            const s2_bytes = @sizeOf(ShadowParam) * @max(@as(usize, 1), self.shadow2_uploaded);
            gpu.setFragmentBufferRange(render_pass, 3, s2_buf, 0, s2_bytes);
            // Vertex also reads shadow_params (dual-shadow quad expansion takes max of both).
            gpu.setVertexBufferRange(render_pass, 3, s2_buf, 0, s2_bytes);
        }

        // Batch render: batches split only where the pipeline changes. The
        // slot's storage grows to hold the whole frame (never wraps: deferred
        // execution would read overwritten ranges).
        if (self.specialized_shape_pipelines[0] != null)
            scheduleMetalRuns(self.instances.items, self.shadow2_params.items, &self.run_scratch, self.allocator);
        var offset: usize = 0;
        while (offset < self.instances.items.len) {
            var batch_count = self.instances.items.len - offset;
            var vertex_count: u32 = 6;
            var edge_hole: ?[4]u32 = null;
            const original_item = self.instances.items[offset];
            const original_offset = offset;
            defer self.instances.items[original_offset] = original_item;
            if (self.specialized_shape_pipelines[0] != null) {
                // Merge consecutive same-type instances; switch pipeline only at category
                // boundaries, never reorder (blend order preserved).
                const kind = metalKind(self.instances.items[offset]);
                var run: usize = 1;
                while (run < batch_count and metalKind(self.instances.items[offset + run]) == kind) : (run += 1) {}
                batch_count = run;
                render_pass.setPipeline(switch (kind) {
                    .general => &self.pipeline,
                    .fill => &self.specialized_shape_pipelines[0].?,
                    .bordered => &self.specialized_shape_pipelines[1].?,
                    .shadow_only => &self.specialized_shape_pipelines[2].?,
                });
                if (kind == .shadow_only) vertex_count = 24;
            } else if (self.solid_pipeline) |*solid| {
                const kind = self.pipelineKind(self.instances.items[offset]);
                if (kind == .shadow_ring) vertex_count = 24;
                // Split only at material boundaries; never reorder blended items.
                var run: usize = 1;
                if (comptime gpu.is_direct3d) {
                    const exact_viewport = render_pass.matchesViewport(.{ self.viewport_width, self.viewport_height });
                    if (!(exact_viewport and self.constantInterior(original_item) != null)) {
                        // Layer copies share .layer; each pass is its own pipeline.
                        while (run < batch_count and self.pipelineKind(self.instances.items[offset + run]) == kind and
                            layerPass(self.instances.items[offset + run]) == layerPass(original_item) and
                            !(exact_viewport and self.constantInterior(self.instances.items[offset + run]) != null)) : (run += 1)
                        {}
                    }
                } else {
                    while (run < batch_count and self.pipelineKind(self.instances.items[offset + run]) == kind) : (run += 1) {}
                }
                batch_count = run;
                render_pass.setPipeline(switch (kind) {
                    .general => &self.pipeline,
                    .linear_x => &self.material_pipelines[0].?,
                    .linear_y => &self.material_pipelines[1].?,
                    .inset_rect => &self.material_pipelines[2].?,
                    .solid => solid,
                    .solid_rect => if (self.clip_shape_kind == 1) &(self.rounded_clip_rect_pipeline.?) else &(self.rect_pipeline.?),
                    .plain_rect => &(self.plain_rect_pipeline.?),
                    .shadow_ring => &(self.shadow_ring_pipeline.?),
                    .dual_shadow => &(self.dual_shadow_pipeline.?),
                    .layer => &(self.layer_pipelines[@backingInt(layerPass(original_item).?) - 1].?),
                });
                if (comptime gpu.is_direct3d) {
                    var can_tile = (kind == .plain_rect or (kind == .solid_rect and self.clip_shape_kind == 0)) and render_pass.matchesViewport(.{ self.viewport_width, self.viewport_height });
                    // Even a transparent shadow can expand the original quad.
                    // Retain that interpolation/AA path byte-for-byte.
                    for (self.instances.items[offset .. offset + batch_count]) |item| {
                        can_tile = can_tile and item.shadow_blur == 0 and item.shadow_offset_x == 0 and item.shadow_offset_y == 0;
                        can_tile = can_tile and item.border_width >= 0;
                        for (item.border_widths) |width| can_tile = can_tile and width >= 0;
                        for (item.corner_radii) |radius| can_tile = can_tile and radius >= 0;
                    }
                    if ((self.clip_shape_kind == 1 or original_item.fill_color[3] == 0) and batch_count == 1 and render_pass.matchesViewport(.{ self.viewport_width, self.viewport_height })) {
                        if (self.constantInterior(original_item)) |bounds| {
                            if (original_item.fill_color[3] == 0) {
                                edge_hole = bounds;
                                self.transparent_interior_batches += 1;
                            } else if (render_pass.clearOpaque(original_item.fill_color, bounds)) edge_hole = bounds;
                        }
                    }
                    if (can_tile and edge_hole == null) {
                        render_pass.setPipeline(if (kind == .plain_rect) &self.tiled_rect_pipeline.? else &self.tiled_border_pipeline.?);
                        vertex_count = 30;
                        if (batch_count == 1) {
                            if (self.constantInterior(original_item)) |bounds| {
                                if (render_pass.clearOpaque(original_item.fill_color, bounds)) {
                                    self.instances.items[offset]._ext_reserved = 1;
                                    self.instances.items[offset].gradient_to_color = .{ @floatFromInt(bounds[0]), @floatFromInt(bounds[1]), @floatFromInt(bounds[0] + bounds[2]), @floatFromInt(bounds[1] + bounds[3]) };
                                    vertex_count = 24;
                                }
                            }
                        }
                    }
                }
            } else if (comptime gpu.is_direct3d) {
                // Without the optional pipelines everything is the body program,
                // except the layer-pass copies of split instances.
                const layer = layerPass(self.instances.items[offset]);
                var run: usize = 1;
                while (run < batch_count and layerPass(self.instances.items[offset + run]) == layer) : (run += 1) {}
                batch_count = run;
                render_pass.setPipeline(if (layer) |pass| &(self.layer_pipelines[@backingInt(pass) - 1].?) else &self.pipeline);
            }
            const instance_size = @sizeOf(SDFInstance) * batch_count;

            const byte_offset = self.buffer_write_offset * @sizeOf(SDFInstance);
            const slot = try self.instance_buffers.ensure(self.allocator, self.device, self.current_buffer, byte_offset + instance_size);
            const instance_data = try slot.buffer.getMappedRange(byte_offset, instance_size);
            @memcpy(instance_data, std.mem.sliceAsBytes(self.instances.items[offset .. offset + batch_count]));
            gpu.setVertexBufferRange(render_pass, 1, slot.buffer, @intCast(byte_offset), @intCast(instance_size));
            gpu.setFragmentBufferRange(render_pass, 1, slot.buffer, @intCast(byte_offset), @intCast(instance_size));
            self.buffer_write_offset += batch_count;

            if (self.trace_materials) {
                const item = self.instances.items[offset];
                std.log.info("[sdf-material] kind={s} vertices={d} target={any} count={d} shape={d} flags={x} rect={any} fill={d} shadow={d} blur={d} offset={any} mask={d} mask_rect={any} mask_radii={any} clip={any}", .{ @tagName(self.pipelineKind(item)), vertex_count, [2]f32{ self.viewport_width, self.viewport_height }, batch_count, item.shape_type, item.packed_flags, item.rect, item.fill_color[3], item.shadow_color[3], item.shadow_blur, [2]f32{ item.shadow_offset_x, item.shadow_offset_y }, self.clip_shape_kind, self.clip_rect, self.clip_radii, item.rect_clip });
            }
            if (comptime gpu.is_direct3d) {
                if (edge_hole) |hole| {
                    // Original six vertices/interpolation, clipped into four
                    // disjoint edge bands. Mask-AA derivatives stay unchanged.
                    const w: u32 = @intFromFloat(@ceil(self.viewport_width));
                    const h: u32 = @intFromFloat(@ceil(self.viewport_height));
                    const right = hole[0] + hole[2];
                    const bottom = hole[1] + hole[3];
                    const bands = [_][4]u32{
                        .{ 0, 0, hole[0], h },             .{ right, 0, w -| right, h },
                        .{ hole[0], 0, hole[2], hole[1] }, .{ hole[0], bottom, hole[2], h -| bottom },
                    };
                    const batch_clip = self.solidBatchClipBounds(self.instances.items[offset .. offset + batch_count]);
                    var regions = bands;
                    for (&regions) |*region| {
                        const band = region.*;
                        if (batch_clip) |clip| {
                            const x = @max(band[0], clip[0]);
                            const y = @max(band[1], clip[1]);
                            region.* = .{ x, y, @min(band[0] + band[2], clip[0] + clip[2]) -| x, @min(band[1] + band[3], clip[1] + clip[3]) -| y };
                        }
                    }
                    const region_index: usize = if (self.pipelineKind(original_item) == .plain_rect) 0 else if (self.clip_shape_kind == 1) 2 else 1;
                    var merged = false;
                    if (self.region_pipelines[region_index]) |*region_pipeline| {
                        render_pass.setPipeline(region_pipeline);
                        merged = render_pass.drawFourRegions(&regions);
                    }
                    if (!merged) for (regions) |region| {
                        if (region[2] > 0 and region[3] > 0) render_pass.drawRegion(region, 6, 1);
                    };
                } else if (self.solidBatchClipBounds(self.instances.items[offset .. offset + batch_count])) |bounds| {
                    render_pass.drawClipped(bounds, .{ self.viewport_width, self.viewport_height }, vertex_count, @intCast(batch_count));
                } else render_pass.draw(vertex_count, @intCast(batch_count), 0, 0);
            } else render_pass.draw(vertex_count, @intCast(batch_count), 0, 0);
            sdf_draw_calls += 1;
            offset += batch_count;
        }
    }

    fn solidEligible(instance: SDFInstance) bool {
        return instance.packed_flags == 0 and instance.shadow_color[3] == 0;
    }

    fn tileMaskEligible(self: *const SdfRenderer) bool {
        if (self.clip2.kind != 0) return false;
        if (self.clip_shape_kind == 0) return true;
        if (self.clip_shape_kind != 1) return false;
        for (self.clip_radii) |r| if (!std.math.isFinite(r) or r < 0) return false;
        for (self.clip_rect) |v| if (!std.math.isFinite(v)) return false;
        return self.clip_rect[2] > 0 and self.clip_rect[3] > 0;
    }

    // Alpha-zero rectangles contain no fill in this conservative core. Opaque
    // rectangles may clear it; both retain the original edge coverage.
    fn constantInterior(self: *const SdfRenderer, item: SDFInstance) ?[4]u32 {
        const kind = self.pipelineKind(item);
        if ((kind != .plain_rect and kind != .solid_rect) or !self.tileMaskEligible() or (item.fill_color[3] != 1 and item.fill_color[3] != 0) or
            item.shadow_blur != 0 or item.shadow_offset_x != 0 or item.shadow_offset_y != 0) return null;
        if (!std.math.isFinite(self.scale_factor) or self.scale_factor <= 0) return null;
        for ([_]f32{ self.viewport_width, self.viewport_height }) |v| if (!std.math.isFinite(v) or v <= 0 or v > 1_000_000) return null;
        for (item.fill_color) |v| if (!std.math.isFinite(v) or v < 0 or v > 1) return null;
        for (item.rect) |v| if (!std.math.isFinite(v)) return null;
        for (item.rect_clip) |v| if (!std.math.isFinite(v)) return null;
        var radius: f32 = 0;
        var border = item.border_width;
        if (!std.math.isFinite(border) or border < 0) return null;
        for (item.corner_radii) |v| {
            if (!std.math.isFinite(v) or v < 0) return null;
            radius = @max(radius, v);
        }
        for (item.border_widths) |v| {
            if (!std.math.isFinite(v) or v < 0) return null;
            border = @max(border, v);
        }
        const inset = (radius + border) * self.scale_factor + 3;
        var bounds: [4]u32 = undefined;
        for ([_]f32{ self.viewport_width, self.viewport_height }, 0..) |extent, axis| {
            var lo = item.rect[axis] * self.scale_factor + inset;
            var hi = (item.rect[axis] + item.rect[axis + 2]) * self.scale_factor - inset;
            if (item.rect_clip[2] >= 0 and item.rect_clip[3] >= 0) {
                lo = @max(lo, item.rect_clip[axis] * self.scale_factor + 3);
                hi = @min(hi, (item.rect_clip[axis] + item.rect_clip[axis + 2]) * self.scale_factor - 3);
            }
            if (self.clip_shape_kind == 1) {
                // Conservative: the largest corner bounds every corner's excluded square.
                const mask_radius = @max(@max(self.clip_radii[0], self.clip_radii[1]), @max(self.clip_radii[2], self.clip_radii[3]));
                const mask_inset = mask_radius * self.scale_factor + 3;
                lo = @max(lo, self.clip_rect[axis] * self.scale_factor + mask_inset);
                hi = @min(hi, (self.clip_rect[axis] + self.clip_rect[axis + 2]) * self.scale_factor - mask_inset);
            }
            if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return null;
            const low = @ceil(std.math.clamp(lo, 0, extent));
            const high = @floor(std.math.clamp(hi, 0, extent));
            if (high <= low) return null;
            bounds[axis] = @intFromFloat(low);
            bounds[axis + 2] = @intFromFloat(high - low);
        }
        if (@as(u64, bounds[2]) * bounds[3] < 4096) return null;
        return bounds;
    }

    fn solidBatchClipBounds(self: *const SdfRenderer, items: []const SDFInstance) ?[4]u32 {
        if (!std.math.isFinite(self.scale_factor) or self.scale_factor <= 0) return null;
        for ([_]f32{ self.viewport_width, self.viewport_height }) |v|
            if (!std.math.isFinite(v) or v <= 0 or v > 1_000_000) return null;
        var lo = [2]f32{ self.viewport_width, self.viewport_height };
        var hi = [2]f32{ 0, 0 };
        for (items) |item| {
            const kind = self.pipelineKind(item);
            if (kind != .plain_rect and kind != .solid_rect) return null;
            const clip = item.rect_clip;
            for (clip) |v| if (!std.math.isFinite(v)) return null;
            if (clip[2] < 0 or clip[3] < 0) return null;
            for (0..2) |axis| {
                // Retain AA coverage and derivative helper lanes. Scissoring
                // does not change vertices or their interpolation plane.
                lo[axis] = @min(lo[axis], clip[axis] * self.scale_factor - 2);
                hi[axis] = @max(hi[axis], (clip[axis] + clip[axis + 2]) * self.scale_factor + 2);
            }
        }
        var bounds: [4]u32 = undefined;
        for ([_]f32{ self.viewport_width, self.viewport_height }, 0..) |extent, axis| {
            const lower: u32 = @intFromFloat(@floor(std.math.clamp(lo[axis], 0, extent)));
            const upper: u32 = @intFromFloat(@ceil(std.math.clamp(hi[axis], 0, extent)));
            bounds[axis] = lower;
            bounds[axis + 2] = upper -| lower;
        }
        return bounds;
    }

    /// Flush current instances to GPU then clear list.
    /// Used when clip stack switches, must render pending first.
    pub fn flush(self: *SdfRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;
        // render() already updated buffer_write_offset, no need to append further.
        try self.render(render_pass);
        self.instances.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

/// **Byte-for-byte clone** of sdf_primitives.metal's sdf_ellipse on CPU side.
/// Sole reason: shader is @embedFile compiled at runtime, `zig build` all-green
/// does not guarantee numeric correctness. Pin formula here; if someone 'optimizes' it back to
/// `(length(p/r)-1) * min(rx,ry)` dimensionless/wrong-dimension form, assertion below fires.
fn sdfEllipseRef(px: f64, py: f64, rx: f64, ry: f64) f64 {
    const r_x = @max(rx, 0.001);
    const r_y = @max(ry, 0.001);
    const qx = px / r_x;
    const qy = py / r_y;
    const k = @sqrt(qx * qx + qy * qy);
    if (k < 1e-6) return -@min(r_x, r_y);
    const gx = px / (r_x * r_x);
    const gy = py / (r_y * r_y);
    const g = @sqrt(gx * gx + gy * gy) / k;
    return (k - 1.0) / @max(g, 1e-6);
}

test "sdf_ellipse 返回真实像素距离（而不是无量纲值或错量纲）" {
    const testing = std.testing;
    // Exact circle: analytical solution exact, pins 'dimension is pixels'.
    try testing.expectApproxEqAbs(@as(f64, 10.0), sdfEllipseRef(60, 0, 50, 50), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10.0), sdfEllipseRef(40, 0, 50, 50), 1e-9);

    // 10:1 flat ellipse major endpoint: true distance = 20.
    // Old `* min(rx,ry)` gives 2.0 (10x off), AA band pulled to 10x width,
    // major ends visibly soft. 10% tolerance allows 1st-order approximation error.
    const d = sdfEllipseRef(220, 0, 200, 20);
    try testing.expect(d > 18.0 and d < 22.0);

    // Minor endpoint also correct (anisotropy -> both axes matter).
    const d2 = sdfEllipseRef(0, 24, 200, 20);
    try testing.expect(d2 > 3.6 and d2 < 4.4);

    // Center: zero gradient, degenerates to shortest semi-axis negative distance.
    try testing.expectApproxEqAbs(@as(f64, -20.0), sdfEllipseRef(0, 0, 200, 20), 1e-9);
}

test "uniform 槽位用尽后继续画（溢出 buffer），不再返回 UniformSlotsExhausted" {
    // Regression: old impl returned error.UniformSlotsExhausted on >256 flushes/frame;
    // opacity_layer / encoder.flush transparently `try` propagate -> App.run crash.
    // SKIP-REASON: need Null backend's deterministic createBuffer/stats (Metal -> test-metal
    // domain).
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    const created_base = gpu.Backend.stats.buffers_created;
    const destroyed_base = gpu.Backend.stats.buffers_destroyed;
    {
        var r = try SdfRenderer.init(alloc, &device);
        defer r.deinit();
        var encoder = try gpu.Backend.CommandEncoder.init(&queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{} });

        // Two frames: second lands in different slot; verify overflow buffer per-slot independent.
        for (0..2) |frame| {
            r.beginFrame(800, 600, 2.0, @intCast(frame));
            for (0..MAX_UNIFORM_UPDATES + 40) |i| {
                try r.addRoundedRect(@floatFromInt(i % 100), 0, 10, 10, .{ 1, 0, 0, 1 }, .{ 2, 2, 2, 2 });
                try r.flush(&pass);
            }
        }
        try std.testing.expectEqual(@as(usize, 40), r.uniform_overflow_used);
        try std.testing.expect(r.uniform_overflow.capacity(r.current_buffer) != 0);
        pass.end();
    }
    // deinit must release overflow uniform buffer (Null backend count balance).
    try std.testing.expectEqual(
        gpu.Backend.stats.buffers_created - created_base,
        gpu.Backend.stats.buffers_destroyed - destroyed_base,
    );
}

test "static SDF uniforms stay identical across clocks while film grain preserves its seed" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var renderer = try SdfRenderer.init(std.testing.allocator, &device);
    defer renderer.deinit();
    var encoder = try gpu.Backend.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{} });
    defer pass.end();
    var previous: [@sizeOf(Uniforms)]u8 = undefined;
    for ([_]u32{ 7, 113 }, 0..) |seed, index| {
        renderer.beginFrame(800, 600, 2, seed);
        try renderer.addRoundedRect(0, 0, 10, 10, .{ 1, 0, 0, 1 }, .{ 2, 2, 2, 2 });
        try renderer.flush(&pass);
        const bytes = try renderer.uniform_buffers[renderer.current_buffer].getMappedRange(0, @sizeOf(Uniforms));
        var observed: Uniforms = undefined;
        @memcpy(std.mem.asBytes(&observed), bytes);
        try std.testing.expectEqual(@as(u32, 0), observed.frame_seed);
        if (index == 0) @memcpy(&previous, bytes) else try std.testing.expectEqualSlices(u8, &previous, bytes);
    }
    for ([_]NoiseMode{ .value, .film_grain }) |mode| {
        for ([_]u32{ 7, 113 }) |seed| {
            renderer.beginFrame(800, 600, 2, seed);
            try renderer.addNoiseRect(0, 0, 10, 10, .{ 1, 0, 0, 1 }, mode, 1, 0.2, 23, .{ 2, 2, 2, 2 });
            try renderer.flush(&pass);
            const bytes = try renderer.uniform_buffers[renderer.current_buffer].getMappedRange(0, @sizeOf(Uniforms));
            var observed: Uniforms = undefined;
            @memcpy(std.mem.asBytes(&observed), bytes);
            try std.testing.expectEqual(if (mode == .film_grain) seed else @as(u32, 0), observed.frame_seed);
        }
    }
}

fn runTestInstance(x: f32, y: f32, w: f32, h: f32, shadow_blur: f32, tag: f32) SDFInstance {
    return .{
        .rect = .{ x, y, w, h },
        // Shadow-only instances are transparent; fills carry the tag in their color.
        .fill_color = if (shadow_blur > 0) .{ 0, 0, 0, 0 } else .{ tag, 0, 0, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .shadow_color = if (shadow_blur > 0) .{ tag, 0, 0, 0.3 } else .{ 0, 0, 0, 0 },
        .gradient_to_color = .{ 0, 0, 0, 0 },
        .corner_radii = .{ 0, 0, 0, 0 },
        .border_width = 0,
        .shadow_blur = shadow_blur,
        .shadow_offset_x = 0,
        .shadow_offset_y = 0,
        .shape_type = 0,
    };
}

fn runTag(item: SDFInstance) f32 {
    return if (item.shadow_blur > 0) item.shadow_color[0] else item.fill_color[0];
}

test "SDF runs: a grid of shadowed controls draws as one shadow run and one fill run" {
    var scratch: SdfRenderer.RunScratch = .{};
    defer scratch.deinit(std.testing.allocator);
    var items: [8]SDFInstance = undefined;
    for (0..4) |i| {
        const x: f32 = @floatFromInt(i * 100);
        items[i * 2] = runTestInstance(x, 0, 40, 20, 3, @floatFromInt(i * 2));
        items[i * 2 + 1] = runTestInstance(x, 0, 40, 20, 0, @floatFromInt(i * 2 + 1));
    }
    SdfRenderer.scheduleMetalRuns(&items, &.{}, &scratch, std.testing.allocator);
    const expected = [_]f32{ 0, 2, 4, 6, 1, 3, 5, 7 };
    for (items, expected) |item, tag| try std.testing.expectEqual(tag, runTag(item));
}

test "SDF runs: every overlapping pair keeps its order, the batch stays a permutation" {
    var scratch: SdfRenderer.RunScratch = .{};
    defer scratch.deinit(std.testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x5d);
    const random = prng.random();
    for (0..200) |_| {
        var items: [24]SDFInstance = undefined;
        var original: [24]SDFInstance = undefined;
        for (&items, 0..) |*item, i| {
            const shadow: f32 = if (random.boolean()) 1 + random.float(f32) * 6 else 0;
            item.* = runTestInstance(random.float(f32) * 300, random.float(f32) * 300, 5 + random.float(f32) * 60, 5 + random.float(f32) * 60, shadow, @floatFromInt(i));
        }
        original = items;
        SdfRenderer.scheduleMetalRuns(&items, &.{}, &scratch, std.testing.allocator);
        var position: [24]usize = undefined;
        var seen: [24]bool = @splat(false);
        for (items, 0..) |item, p| {
            const tag: usize = @intFromFloat(runTag(item));
            try std.testing.expect(!seen[tag]);
            seen[tag] = true;
            position[tag] = p;
        }
        for (0..24) |a| for (a + 1..24) |b| {
            const qa = SdfRenderer.instanceQuad(&original[a], &.{});
            const qb = SdfRenderer.instanceQuad(&original[b], &.{});
            const overlap = qa[0] < qb[2] and qb[0] < qa[2] and qa[1] < qb[3] and qb[1] < qa[3];
            if (overlap) try std.testing.expect(position[a] < position[b]);
        };
    }
}

test "SDF runs: the quad covers shadow reach, spread and a second shadow" {
    var item = runTestInstance(10, 20, 30, 40, 2, 0);
    item.shadow_offset_x = 3;
    try std.testing.expectEqual([4]f32{ 2, 12, 48, 68 }, SdfRenderer.instanceQuad(&item, &.{}));
    item.packed_flags = SdfRenderer.shadow_spread_flag;
    item.noise_scale = 5;
    try std.testing.expectEqual([4]f32{ -3, 7, 53, 73 }, SdfRenderer.instanceQuad(&item, &.{}));
    item.packed_flags = 1 << 25;
    const second = [_]ShadowParam{.{ .color = .{ 0, 0, 0, 1 }, .blur = 10, .offset_x = 0, .offset_y = 4 }};
    try std.testing.expectEqual([4]f32{ -15, -5, 65, 85 }, SdfRenderer.instanceQuad(&item, &second));
}
