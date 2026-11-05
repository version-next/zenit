/// Path Renderer: vector path GPU rendering (includes edge AA).
///
/// Pipeline:
///   1. addFillPath() receives Contour list (from PathTessellator)
///   2. CPU Earcut generates fill triangles
///   3. AA fringe strip along contour (outer alpha_scale=0, inner=1)
///   4. flush() uploads via vertex buffer to GPU, draw renders.
const std = @import("std");
const pixel_domain = @import("command_encoder/pixel_domain.zig");
const gpu = @import("gpu");
const shape_clip_pair = @import("shape_clip_pair.zig");
const Contour = @import("path_tessellator.zig").Contour;
const TPoint = @import("path_tessellator.zig").TPoint;
const path_fill_rule = @import("path_fill_rule.zig");
pub const FillRule = path_fill_rule.FillRule;

pub const max_polygon_points: usize = 32;
pub const max_polygon_contours: usize = 8;

pub const LineJoin = enum {
    miter,
    bevel,
    round,
};

pub const PathPolygon = struct {
    point_count: u32 = 0,
    contour_count: u32 = 0,
    fill_rule: u32 = 0,
    contour_end_points: [max_polygon_contours]u32 = @as([max_polygon_contours]u32, @splat(0)),
    points: [max_polygon_points][2]f32 = @as([max_polygon_points][2]f32, @splat(.{ 0, 0 })),

    pub fn fromClipPolygon(polygon: anytype) PathPolygon {
        var out = PathPolygon{
            .point_count = polygon.point_count,
            .contour_count = polygon.contour_count,
            .fill_rule = @backingInt(polygon.fill_rule),
        };
        const contour_count = @min(@as(usize, polygon.contour_count), max_polygon_contours);
        for (0..contour_count) |i| out.contour_end_points[i] = polygon.contour_end_points[i];
        const point_count = @min(@as(usize, polygon.point_count), max_polygon_points);
        for (0..point_count) |i| out.points[i] = polygon.points[i];
        return out;
    }
};

const path_shader_source: []const u8 = @import("shader_sources.zig").path;

// ============================================================================
// Uniforms: align with path.metal PathUniforms
// ============================================================================

const PathUniforms = extern struct {
    viewport_size: [2]f32,
    scale_factor: f32,
    draw_mode: u32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    fill_rule: u32 = 0,
    point_count: u32 = 0,
    contour_count: u32 = 0,
    _pad0: u32 = 0,
    contour_end_points: [max_polygon_contours]u32 = @as([max_polygon_contours]u32, @splat(0)),
    polygon_points: [max_polygon_points][2]f32 = @as([max_polygon_points][2]f32, @splat(.{ 0, 0 })),
    // shape clip mask (aligned with path.metal; kind 0=none / 1=rounded_rect / 2=ellipse)
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 }, // TL, TR, BR, BL
    clip_shape_kind: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    _pad6: u32 = 0,
    // draw_mode 2 (gradient): radial/conic gradient evaluated per fragment
    // over `rect` (the gradient bounds). Same t and stop rules as FillGradient.
    grad_dir: u32 = 0,
    grad_stop_count: u32 = 0,
    grad_center: [2]f32 = .{ 0.5, 0.5 },
    grad_angle: f32 = 0,
    _pad3: u32 = 0,
    _pad4: u32 = 0,
    _pad5: u32 = 0,
    grad_colors: [max_gradient_stops][4]f32 = @as([max_gradient_stops][4]f32, @splat(.{ 0, 0, 0, 0 })),
    grad_positions: [max_gradient_stops]f32 = @as([max_gradient_stops]f32, @splat(0)),
    /// Second shape clip (shape_clip_pair.zig); zero-sized off Metal.
    clip2: shape_clip_pair.Field = shape_clip_pair.none,
};

comptime {
    // path.metal / path.hlsl cbuffer: the clip block is two 16-byte registers (rect, radii) + kind/pad.
    std.debug.assert(@offsetOf(PathUniforms, "clip_rect") == 352);
    std.debug.assert(@offsetOf(PathUniforms, "clip_radii") == 368);
    std.debug.assert(@offsetOf(PathUniforms, "grad_dir") == 400);
}
const max_gradient_stops = 16;

// ============================================================================
// Vertex format: align with path.metal PathVertex
// ============================================================================

const PathVertex = extern struct {
    x: f32,
    y: f32,
    /// AA weight: fill triangle = 1.0; fringe outer vertex = 0.0, inner = 1.0.
    alpha_scale: f32,
    /// linear RGB + alpha (unpremultiplied; shader premultiplies). per-vertex color
    /// lets adjacent triangles merge into one draw. All add* entries fill back.
    color: [4]f32 = .{ 0, 0, 0, 0 },
};

// ============================================================================
// Single draw command (one fill path call)
// ============================================================================

const DrawCall = struct {
    mode: DrawMode = .triangles,
    vertex_start: u32, // Start index in vertex_buf.
    vertex_count: u32, // Vertex count (= index_count, triangle list).
    color: [4]f32, // RGBA linear + alpha (polygon_fill via uniforms; triangles per-vertex).
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    polygon: PathPolygon = .{},
    /// rect_clip at add time (w/h < 0 = no clip). After batching, flush crosses clip
    /// changes, scissor must group by draw call, not single flush state.
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    /// .gradient mode: the per-fragment gradient (rect = its bounds).
    gradient: GradientUniform = .{},
};

const GradientUniform = struct {
    dir: u32 = 0,
    stop_count: u32 = 0,
    center: [2]f32 = .{ 0.5, 0.5 },
    angle: f32 = 0,
    colors: [max_gradient_stops][4]f32 = @as([max_gradient_stops][4]f32, @splat(.{ 0, 0, 0, 0 })),
    positions: [max_gradient_stops]f32 = @as([max_gradient_stops]f32, @splat(0)),
};

const DrawMode = enum(u32) {
    triangles = 0,
    polygon_fill = 1,
    /// Triangles whose colour is a radial/conic gradient evaluated per
    /// fragment (vertex colour carries only opacity); never coalesced.
    gradient = 2,
};

/// Max vertex count (per frame, dynamic alloc).
///
/// 65K holds only ~1K vector connector lines with dual markers; a canvas at fit/pan legally
/// mounts more, and a low limit makes normal documents hit TooManyPathVertices. The buffer grows
/// by actual use; the valve is ~56MiB raw vertex data, covering a 42x42 endpoint gallery fit-all.
const MAX_VERTICES_PER_FRAME = 2097152;

// Phase C mesh cache: total vertex budget + idle eviction TTL (frames).
const MESH_CACHE_MAX_VERTICES = 262144;
const MESH_CACHE_TTL_FRAMES = 240;

// -- Vertex buffer high water shrinking --
//
// ensureVertexBufferCapacity only expands: a large canvas fit-all leaves a ~56MiB peak
// permanently resident. Shrink when **consecutive** SHRINK_FRAMES frames stay below
// capacity/SHRINK_DIVISOR. A single-frame test would oscillate (pan/zoom frames vary); any
// frame back at peak resets the counter. Once shrunk, it rebuilds on demand for real paths.
const SHRINK_DIVISOR: usize = 4;
/// ~4s @ 60fps, same order as MESH_CACHE_TTL_FRAMES.
const SHRINK_FRAMES: u32 = 240;
/// Below this, shrink not worth (rebuild cost > memory savings).
const SHRINK_MIN_CAPACITY: usize = 256 * 1024;

/// Aligns glyph_atlas.MAX_FRAMES_IN_FLIGHT (triple-buffer FrameSync): buffer
/// retired then delayed FRAMES frames before true destroy, in-flight command buffers
/// don't reference freed GPU buffer.
const BUFFER_MAX_FRAMES_IN_FLIGHT: u64 = 3;

/// Shrink decision state machine. Device-agnostic pure logic, deterministic unit
/// tests. Call once per frame `noteFrame(prev_bytes, capacity)`, returns true = shrink.
pub const ShrinkPolicy = struct {
    low_frames: u32 = 0,

    pub fn noteFrame(self: *ShrinkPolicy, used_bytes: usize, capacity: usize) bool {
        if (capacity <= SHRINK_MIN_CAPACITY or
            used_bytes >= capacity / SHRINK_DIVISOR)
        {
            self.low_frames = 0;
            return false;
        }
        self.low_frames += 1;
        if (self.low_frames < SHRINK_FRAMES) return false;
        self.low_frames = 0;
        return true;
    }
};

/// Extracted from vertex_buffer but possibly referenced by in-flight command.
/// Semantics match glyph_atlas.RetiredTexture: epoch-delayed cleanup.
const RetiredBuffer = struct {
    buffer: gpu.Backend.Buffer,
    retired_at_frame: u64,
};

/// Is retire frame past in-flight window, safe to destroy.
fn retiredBufferReady(retired_at_frame: u64, current_frame: u64) bool {
    return current_frame -| retired_at_frame >= BUFFER_MAX_FRAMES_IN_FLIGHT;
}

const MeshEntry = struct {
    verts: []PathVertex,
    last_used: u64,
};

/// Vector fill gradient spec (optional). The fill_path GPU path **already supports per-vertex
/// color** (PathVertex.color, path.metal fragment interpolates fill_color); the CPU side
/// fills it uniformly unless a gradient is given.
///
/// Method: after triangulate, compute t from each vertex's normalized bbox position and
/// interpolate by stop into PathVertex.color. Vertex interpolation is exact for convex and
/// triangulated-concave shapes (rasterizer interpolates linearly inside a triangle).
///
/// Known difference: radial/conic is evaluated at **vertices**, so curved isolines are
/// linearly approximated inside triangles. Shapes with few vertices (triangle/star) look
/// faceted; exact results need fragment evaluation (gradient uniform in path.metal).
pub const FillGradient = struct {
    /// Matches sdf_renderer.GradientDir (1=vertical 2=horizontal 3=diagonal
    /// 4=radial 5=conic). 0=none means no gradient.
    dir: u32 = 0,
    stops: []const GradientStopIn = &.{},
    /// radial/conic center (bbox-normalized, 0.5,0.5 = center).
    center_x: f32 = 0.5,
    center_y: f32 = 0.5,
    /// conic start angle (radians).
    start_angle: f32 = 0,

    pub const GradientStopIn = struct { color: [4]f32, position: f32 };

    /// Gradient t at normalized position (u,v in [0,1]).
    fn tAt(self: *const FillGradient, u: f32, v: f32) f32 {
        return switch (self.dir) {
            1 => v, // vertical
            2 => u, // horizontal
            3 => (u + v) * 0.5, // diagonal
            4 => blk: { // radial: normalized distance to center (* 2 edge ~ 1).
                const dx = u - self.center_x;
                const dy = v - self.center_y;
                break :blk std.math.clamp(@sqrt(dx * dx + dy * dy) * 2.0, 0, 1);
            },
            5 => blk: { // conic: angle around center.
                const dx = u - self.center_x;
                const dy = v - self.center_y;
                var ang = std.math.atan2(dy, dx) - self.start_angle;
                const tau = std.math.tau;
                ang = @mod(ang, tau);
                if (ang < 0) ang += tau;
                break :blk @as(f32, @floatCast(ang / tau));
            },
            else => 0,
        };
    }

    /// Interpolate color by stop list (stops ascending by position; pad semantics).
    fn colorAt(self: *const FillGradient, t_in: f32) [4]f32 {
        if (self.stops.len == 0) return .{ 0, 0, 0, 0 };
        if (self.stops.len == 1) return self.stops[0].color;
        const t = std.math.clamp(t_in, 0, 1);
        if (t <= self.stops[0].position) return self.stops[0].color;
        const last = self.stops[self.stops.len - 1];
        if (t >= last.position) return last.color;
        var i: usize = 1;
        while (i < self.stops.len) : (i += 1) {
            const a = self.stops[i - 1];
            const b = self.stops[i];
            if (t <= b.position) {
                const span = b.position - a.position;
                const k: f32 = if (span > 1e-6) (t - a.position) / span else 0;
                var out: [4]f32 = undefined;
                for (0..4) |c| out[c] = a.color[c] + (b.color[c] - a.color[c]) * k;
                return out;
            }
        }
        return last.color;
    }
};

pub const PathRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Current frame slot's vertex buffer.
    ///
    /// Round-robin by slot: a frame's buffer parks at parked_buffers[buffer_slot] and is reused
    /// after BUFFER_MAX_FRAMES_IN_FLIGHT frames. A single buffer would let frame N+1's memcpy
    /// overwrite data frame N's GPU work has not consumed yet.
    vertex_buffer: ?gpu.Backend.Buffer,
    vertex_buffer_capacity: usize,
    buffer_write_offset: usize,
    parked_buffers: [BUFFER_MAX_FRAMES_IN_FLIGHT]?gpu.Backend.Buffer = @as([BUFFER_MAX_FRAMES_IN_FLIGHT]?gpu.Backend.Buffer, @splat(null)),
    parked_capacities: [BUFFER_MAX_FRAMES_IN_FLIGHT]usize = @as([BUFFER_MAX_FRAMES_IN_FLIGHT]usize, @splat(0)),
    buffer_slot: usize = 0,

    // CPU vertex accumulation (reset per frame).
    vertices: std.ArrayList(PathVertex),
    draw_calls: std.ArrayList(DrawCall),
    // earclip per-contour scratch point table, reused across addFillPath.
    earclip_pts: std.ArrayList(TPoint) = .empty,

    // -- Phase C: cross-frame mesh cache --
    // key = wyhash(path command per-tag payload + fill/stroke flag + scale + stroke params)
    // (encoder side). value = **path-local** vertices (offset removed, translation-invariant;
    // earclip/fringe/stroke are all additive). Hit = skip flatten+earclip, translate-fill directly.
    mesh_cache: std.AutoHashMapUnmanaged(u64, MeshEntry) = .{},
    mesh_cache_vertex_total: usize = 0,
    current_frame: u64 = 0,
    frame_mesh_hits: u32 = 0,
    frame_mesh_misses: u32 = 0,
    /// GPU draw count last flush actually emitted (after batch <= draw_calls), debug.
    last_flush_draw_count: u32 = 0,
    /// damage-rect partial: this pass dirty scissor (pixels x,y,w,h). path renderer
    /// self-manages per-DrawCall scissor, every setScissorRect must intersect, else
    /// overwrites old pixels outside damage. Maintained by encoder (beginOpacityLayerInto /
    /// applyOffscreenTargetViewport).
    damage_scissor: ?[4]u32 = null,
    /// Per-frame accum: logical draw calls submitted / actual after batching (clear beginFrame).
    frame_call_count: u32 = 0,
    frame_draw_count: u32 = 0,

    // -- Vertex buffer high water shrink state --
    /// Local frame counter incremented by beginFrame. Unlike Phase C current_frame
    /// (driven by encoder setFrame, empty frames skip), shrink criteria and delayed
    /// release must count empty frames as low-water, so walk table every frame.
    shrink_frame: u64 = 0,
    shrink_policy: ShrinkPolicy = .{},
    /// Delayed-free queue (see RetiredBuffer / drainRetiredBuffers).
    retired_buffers: std.ArrayListUnmanaged(RetiredBuffer) = .empty,

    raster_viewport: [2]f32 = .{ 800, 600 },
    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_shape_kind: u32 = 0,
    clip2: shape_clip_pair.Uniform = .{},

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !PathRenderer {
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, path_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("path_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("path_fragment_main");
        defer fragment_func.deinit();

        const pipeline = try gpu.Backend.createRenderPipeline(device, .{
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

        return PathRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = null,
            .vertex_buffer_capacity = 0,
            .buffer_write_offset = 0,
            .vertices = .empty,
            .draw_calls = .empty,
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
            .current_rect_clip = .{ 0, 0, -1, -1 },
        };
    }

    pub fn deinit(self: *PathRenderer) void {
        var it = self.mesh_cache.valueIterator();
        while (it.next()) |e| self.allocator.free(e.verts);
        self.mesh_cache.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.draw_calls.deinit(self.allocator);
        self.earclip_pts.deinit(self.allocator);
        if (self.vertex_buffer) |*buffer| buffer.destroy();
        for (&self.parked_buffers) |*maybe| {
            if (maybe.*) |*buffer| buffer.destroy();
        }
        // deinit contract matches offscreen_pool: owner calls after GPU drain, then
        // sync-destroying retired buffer is safe.
        for (self.retired_buffers.items) |*entry| entry.buffer.destroy();
        self.retired_buffers.deinit(self.allocator);
        self.pipeline.deinit();
    }

    pub fn setViewport(self: *PathRenderer, w: f32, h: f32, scale: f32) void {
        self.viewport_width = w;
        self.viewport_height = h;
        self.scale_factor = scale;
        self.raster_viewport = .{ @floatFromInt(pixel_domain.physicalPixelExtent(w, scale)), @floatFromInt(pixel_domain.physicalPixelExtent(h, scale)) };
    }

    pub fn setDrawableExtent(self: *PathRenderer, width: u32, height: u32) void {
        self.raster_viewport = .{ @floatFromInt(width), @floatFromInt(height) };
    }

    pub fn setOffscreenViewport(self: *PathRenderer) void {
        self.raster_viewport = .{ self.viewport_width * self.scale_factor, self.viewport_height * self.scale_factor };
    }

    /// Start a GPU frame.
    pub fn beginFrame(self: *PathRenderer, w: f32, h: f32, scale: f32) void {
        self.beginFrameFor(w, h, scale, true);
    }

    /// `gpu_frame` false: a CPU patch encode (cpu_flat), which reads only the
    /// CPU-side batches: the triple-buffered GPU slots keep rotating with GPU
    /// frames alone, so a slot an in-flight frame reads is never reused.
    pub fn beginFrameFor(self: *PathRenderer, w: f32, h: f32, scale: f32, gpu_frame: bool) void {
        self.setViewport(w, h, scale);
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.frame_call_count = 0;
        self.frame_draw_count = 0;
        if (!gpu_frame) return;
        self.shrink_frame += 1;
        self.drainRetiredBuffers();
        // buffer_write_offset still holds prev-frame accum (cross-pass flushes total),
        // exactly shrink input; cleared after. Criteria use max-capacity per-slot: after
        // rotate, slot capacity varies, current-slot with empty (capacity 0 -> 'no shrink')
        // resets count every frame, never shrinks.
        if (self.shrink_policy.noteFrame(self.buffer_write_offset, self.peakSlotCapacity())) {
            // Slot capacities may vary, retire all (delayed, in-flight unaffected); rebuild
            // on-demand.
            self.retireVertexBuffer();
            self.retireParkedBuffers();
            // CPU vertex/draw table also peak-resident (56MiB source), released together.
            // Tables already cleared by prev flush, free only idle capacity.
            self.vertices.clearAndFree(self.allocator);
            self.draw_calls.clearAndFree(self.allocator);
        }
        self.rotateVertexBufferSlot();
        self.buffer_write_offset = 0;
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.frame_call_count = 0;
        self.frame_draw_count = 0;
    }

    pub fn setRectClip(self: *PathRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// Second shape clip intersected with the primary one (shape_clip_pair.zig).
    pub fn setPartnerClip(self: *PathRenderer, clip: shape_clip_pair.Uniform) void {
        self.clip2 = clip;
    }

    /// shape clip mask. path supports rounded_rect(1) / ellipse(2); polygon(3) inert
    /// to path pipeline (caller ensures polygon-clip scenariosse avoids shader-clip).
    pub fn setClipMask(self: *PathRenderer, shape_kind: u32, rect: ?[4]f32, radii: [4]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radii = radii;
            self.clip_shape_kind = if (shape_kind <= 2) shape_kind else 0;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radii = .{ 0, 0, 0, 0 };
            self.clip_shape_kind = 0;
            self.clip2 = .{};
        }
    }

    /// Multi-contour fill: plans outer contours and holes under `rule`, joins
    /// each outer with its holes into one polygon, ear-clips it, and adds the
    /// AA fringe on the unfilled side of every boundary (outer contours
    /// oriented positive, holes negative).
    fn fillContoursWithRule(self: *PathRenderer, contours: []const Contour, rule: FillRule, off_x: f32, off_y: f32) !void {
        const allocator = self.allocator;
        if (!std.math.isFinite(off_x) or !std.math.isFinite(off_y)) return;
        var pool: std.ArrayList(TPoint) = .empty;
        defer pool.deinit(allocator);
        const spans = try allocator.alloc([2]usize, contours.len);
        defer allocator.free(spans);
        for (contours, spans) |contour, *span| {
            const start = pool.items.len;
            span.* = .{ start, start };
            const n = contour.pointCount();
            if (n < 3 or n > MAX_EARCLIP_POINTS) continue;
            var finite = true;
            for (0..n) |i| {
                const p = contour.point(i);
                const point = TPoint{ .x = p.x + off_x, .y = p.y + off_y };
                finite = finite and std.math.isFinite(point.x) and std.math.isFinite(point.y);
                try pool.append(allocator, point);
            }
            var end = pool.items.len;
            // A closed path may repeat its start point at the end.
            while (end - start > 3 and @abs(pool.items[end - 1].x - pool.items[start].x) < 1e-3 and @abs(pool.items[end - 1].y - pool.items[start].y) < 1e-3) end -= 1;
            span.* = if (finite) .{ start, end } else .{ start, start };
        }
        const rings = try allocator.alloc([]const TPoint, contours.len);
        defer allocator.free(rings);
        for (rings, spans) |*ring, span| ring.* = pool.items[span[0]..span[1]];
        const plan = try path_fill_rule.plan(allocator, rings, rule);
        defer plan.deinit(allocator);

        var oriented: std.ArrayList(TPoint) = .empty;
        defer oriented.deinit(allocator);
        var hole_spans: std.ArrayList([2]usize) = .empty;
        defer hole_spans.deinit(allocator);
        var holes: std.ArrayList([]const TPoint) = .empty;
        defer holes.deinit(allocator);
        for (plan.roles, 0..) |role, outer_index| {
            if (role != .outer) continue;
            // Outer positive, its holes negative, all in one buffer.
            oriented.clearRetainingCapacity();
            hole_spans.clearRetainingCapacity();
            try appendOriented(allocator, &oriented, rings[outer_index], true);
            const outer_len = oriented.items.len;
            for (plan.roles, plan.owner, 0..) |hole_role, owner, hole_index| {
                if (hole_role != .hole or owner != outer_index) continue;
                const start = oriented.items.len;
                try appendOriented(allocator, &oriented, rings[hole_index], false);
                try hole_spans.append(allocator, .{ start, oriented.items.len });
            }
            holes.clearRetainingCapacity();
            for (hole_spans.items) |span| try holes.append(allocator, oriented.items[span[0]..span[1]]);
            self.earclip_pts.clearRetainingCapacity();
            const joined = try path_fill_rule.bridgeHoles(allocator, &self.earclip_pts, oriented.items[0..outer_len], holes.items);
            // Only degenerate geometry leaves a hole unbridged (a nested hole's
            // +x ray always meets its outer ring); it is then filled over.
            if (joined != holes.items.len) std.log.warn("path fill: {d} of {d} holes could not be bridged and are filled", .{ holes.items.len - joined, holes.items.len });
            if (self.earclip_pts.items.len > MAX_EARCLIP_POINTS) continue;
            const fill_start = self.vertices.items.len;
            try earclipRing(allocator, &self.earclip_pts, &self.vertices);
            if (self.vertices.items.len == fill_start) continue;
            try buildAaFringeRing(allocator, &self.vertices, oriented.items[0..outer_len], self.scale_factor);
            for (holes.items) |hole| try buildAaFringeRing(allocator, &self.vertices, hole, self.scale_factor);
        }
    }

    /// Add fill path (contours -> Earcut + AA fringe -> triangles).
    /// Returns produced vertex range (Phase C storeMesh); null = no valid triangles.
    pub fn addFillPath(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        offset_x: f32,
        offset_y: f32,
    ) !?[2]u32 {
        return self.addFillPathGradient(contours, color_rgba, offset_x, offset_y, null, .nonzero);
    }

    /// Like addFillPath, optionally per-vertex gradient color (null = uniform).
    pub fn addFillPathGradient(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        offset_x: f32,
        offset_y: f32,
        grad: ?FillGradient,
        rule: FillRule,
    ) !?[2]u32 {
        const vertex_start: u32 = @intCast(self.vertices.items.len);

        // Several contours: the fill rule decides which nested regions are
        // filled (holes of rings, letters, cut-out icons). Triangulating each
        // contour on its own fills every hole.
        if (contours.len > 1) try self.fillContoursWithRule(contours, rule, offset_x, offset_y) else for (contours) |contour| {
            const point_count = contour.pointCount();
            if (point_count < 3 or point_count > MAX_EARCLIP_POINTS) continue;
            const contour_vertex_start = self.vertices.items.len;
            // Fill triangles (alpha_scale = 1.0).
            try earclipFill(self.allocator, &self.earclip_pts, &self.vertices, contour, offset_x, offset_y);
            // Triangulate rejected non-finite/degenerate, fringe must skip too; else
            // resubmits NaN vertices to GPU, bypasses earclip budget.
            if (self.vertices.items.len == contour_vertex_start) continue;
            // AA fringe strip along contour (outer alpha_scale = 0.0).
            try buildAaFringe(self.allocator, &self.vertices, contour, offset_x, offset_y, self.scale_factor);
        }

        if (self.vertices.items.len == vertex_start) return null; // No valid triangles.
        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        if (grad) |g| if (g.dir != 0 and g.stops.len > 0) {
            // Per-vertex gradient: compute added vertices bbox (geometry has offset), then
            // normalize position to t -> color. GPU interpolates, fragment unchanged.
            var min_x: f32 = std.math.floatMax(f32);
            var min_y: f32 = std.math.floatMax(f32);
            var max_x: f32 = -std.math.floatMax(f32);
            var max_y: f32 = -std.math.floatMax(f32);
            // Gradient bounds are the geometry's: skip the AA fringe's outer
            // vertices (alpha_scale 0), which lie one device pixel outside it.
            for (self.vertices.items[vertex_start..]) |v| {
                if (v.alpha_scale == 0) continue;
                min_x = @min(min_x, v.x);
                min_y = @min(min_y, v.y);
                max_x = @max(max_x, v.x);
                max_y = @max(max_y, v.y);
            }
            const span_x = @max(max_x - min_x, 1e-6);
            const span_y = @max(max_y - min_y, 1e-6);
            // Colour is piecewise linear in t; per-vertex colours interpolate
            // linearly across a triangle, so a triangle spanning a stop shows
            // the wrong colour (red-to-blue straight past a green middle stop).
            // Linear gradients are affine in position: cut every triangle at
            // each stop's iso-line and the interpolation becomes exact.
            // Radial and conic t is not affine in position: no triangulation makes
            // per-vertex colour exact. Evaluate them per fragment instead.
            if ((g.dir == 4 or g.dir == 5) and g.stops.len <= max_gradient_stops) {
                const vertex_end: u32 = @intCast(self.vertices.items.len);
                for (self.vertices.items[vertex_start..]) |*v| v.color = .{ 1, 1, 1, color_rgba[3] };
                var gu = GradientUniform{ .dir = g.dir, .stop_count = @intCast(g.stops.len), .center = .{ g.center_x, g.center_y }, .angle = g.start_angle };
                for (g.stops, 0..) |stop, k| {
                    gu.colors[k] = stop.color;
                    gu.positions[k] = stop.position;
                }
                try self.draw_calls.append(self.allocator, DrawCall{
                    .mode = .gradient,
                    .vertex_start = vertex_start,
                    .vertex_count = vertex_end - vertex_start,
                    .color = color_rgba,
                    .rect = .{ min_x, min_y, span_x, span_y },
                    .rect_clip = self.current_rect_clip,
                    .gradient = gu,
                });
                return .{ vertex_start, vertex_end };
            }
            if (g.dir >= 1 and g.dir <= 3 and g.stops.len >= 2) {
                try splitAtGradientStops(self.allocator, &self.vertices, vertex_start, g, .{ min_x, min_y, span_x, span_y });
                if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;
            }
            const vertex_end: u32 = @intCast(self.vertices.items.len);
            for (self.vertices.items[vertex_start..]) |*v| {
                const uu = (v.x - min_x) / span_x;
                const vv = (v.y - min_y) / span_y;
                var c = g.colorAt(g.tAt(uu, vv));
                // alpha multiplied by caller's overall opacity; AA fringe alpha_scale shader-
                // multiplied separately, untouched here.
                c[3] *= color_rgba[3];
                v.color = c;
            }
            try self.draw_calls.append(self.allocator, DrawCall{
                .mode = .triangles,
                .vertex_start = vertex_start,
                .vertex_count = vertex_end - vertex_start,
                .color = color_rgba,
                .rect_clip = self.current_rect_clip,
            });
            return .{ vertex_start, vertex_end };
        };

        const vertex_end: u32 = @intCast(self.vertices.items.len);
        for (self.vertices.items[vertex_start..]) |*v| v.color = color_rgba;
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = vertex_end - vertex_start,
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        return .{ vertex_start, vertex_end };
    }

    pub fn addPolygonFillPath(
        self: *PathRenderer,
        polygon: PathPolygon,
        color_rgba: [4]f32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) !void {
        if (w <= 0 or h <= 0) return;
        if (polygon.point_count < 3 or polygon.contour_count == 0) return;

        const vertex_start: u32 = @intCast(self.vertices.items.len);

        try self.vertices.append(self.allocator, .{ .x = x, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x, .y = y + h, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y + h, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x, .y = y + h, .alpha_scale = 1.0 });

        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .polygon_fill,
            .vertex_start = vertex_start,
            .vertex_count = 6,
            .color = color_rgba,
            .rect = .{ x, y, w, h },
            .polygon = polygon,
            .rect_clip = self.current_rect_clip,
        });
    }

    /// Add stroke path (contours -> expand rect quads + AA fringe -> triangles).
    pub fn addStrokePath(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        stroke_width: f32,
        line_join: LineJoin,
        offset_x: f32,
        offset_y: f32,
    ) !?[2]u32 {
        const vertex_start: u32 = @intCast(self.vertices.items.len);
        const half_w = stroke_width * 0.5;

        for (contours) |contour| {
            if (contour.pointCount() < 2) continue;
            try buildStrokeExpand(self.allocator, &self.vertices, contour, offset_x, offset_y, half_w, self.scale_factor, line_join);
        }

        const vertex_end: u32 = @intCast(self.vertices.items.len);
        if (vertex_end == vertex_start) return null;
        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        for (self.vertices.items[vertex_start..]) |*v| v.color = color_rgba;
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = vertex_end - vertex_start,
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        return .{ vertex_start, vertex_end };
    }

    /// Phase C: advance frame + periodically evict idle mesh. Called by encoder pre-encode.
    pub fn setFrame(self: *PathRenderer, frame: u64) void {
        if (frame == self.current_frame) return;
        self.current_frame = frame;
        self.frame_mesh_hits = 0;
        self.frame_mesh_misses = 0;
        if (frame % 120 != 0) return;
        var stale: [64]u64 = undefined;
        var n: usize = 0;
        var it = self.mesh_cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.last_used + MESH_CACHE_TTL_FRAMES < frame and n < stale.len) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| {
            if (self.mesh_cache.fetchRemove(k)) |kv| {
                self.mesh_cache_vertex_total -= kv.value.verts.len;
                self.allocator.free(kv.value.verts);
            }
        }
    }

    /// Phase C: cache hit, translate-fill + recolor + note draw. false = miss
    /// (caller flatten + add*Path then storeMesh).
    pub fn appendCachedMesh(self: *PathRenderer, key: u64, color_rgba: [4]f32, offset_x: f32, offset_y: f32) !bool {
        const e = self.mesh_cache.getPtr(key) orelse {
            self.frame_mesh_misses += 1;
            return false;
        };
        e.last_used = self.current_frame;
        const vertex_start: u32 = @intCast(self.vertices.items.len);
        if (self.vertices.items.len + e.verts.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;
        try self.vertices.ensureUnusedCapacity(self.allocator, e.verts.len);
        for (e.verts) |v| {
            self.vertices.appendAssumeCapacity(.{
                .x = v.x + offset_x,
                .y = v.y + offset_y,
                .alpha_scale = v.alpha_scale,
                .color = color_rgba,
            });
        }
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = @intCast(e.verts.len),
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        self.frame_mesh_hits += 1;
        return true;
    }

    /// Phase C: store just-added vertices (frame vertices) as path-local in cache.
    /// Any failure silent (cache pure optimization).
    pub fn storeMesh(self: *PathRenderer, key: u64, vertex_start: u32, vertex_end: u32, offset_x: f32, offset_y: f32) void {
        if (vertex_end <= vertex_start) return;
        if (self.mesh_cache.contains(key)) return;
        const n = vertex_end - vertex_start;
        if (self.mesh_cache_vertex_total + n > MESH_CACHE_MAX_VERTICES) return;
        const copy = self.allocator.alloc(PathVertex, n) catch return;
        for (self.vertices.items[vertex_start..vertex_end], 0..) |v, i| {
            copy[i] = .{ .x = v.x - offset_x, .y = v.y - offset_y, .alpha_scale = v.alpha_scale };
        }
        self.mesh_cache.put(self.allocator, key, .{ .verts = copy, .last_used = self.current_frame }) catch {
            self.allocator.free(copy);
            return;
        };
        self.mesh_cache_vertex_total += n;
    }

    /// Submit all frame path draw commands.
    pub fn flush(self: *PathRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        defer {
            self.vertices.clearRetainingCapacity();
            self.draw_calls.clearRetainingCapacity();
        }

        if (self.draw_calls.items.len == 0) return;

        render_pass.setPipeline(&self.pipeline);
        render_pass.setViewport(
            0,
            0,
            self.raster_viewport[0],
            self.raster_viewport[1],
            0,
            1,
        );

        if (self.vertices.items.len > 0) {
            const vertex_bytes = std.mem.sliceAsBytes(self.vertices.items);
            const byte_offset = self.buffer_write_offset;
            try self.ensureVertexBufferCapacity(byte_offset + vertex_bytes.len);
            if (self.vertex_buffer) |*vertex_buffer| {
                const mapped = try vertex_buffer.getMappedRange(byte_offset, vertex_bytes.len);
                @memcpy(mapped, vertex_bytes);
                gpu.setVertexBufferRange(render_pass, 0, vertex_buffer, @intCast(byte_offset), @intCast(vertex_bytes.len));
            } else unreachable;
            self.buffer_write_offset = byte_offset + vertex_bytes.len;
        }

        // Group by rect_clip apply scissor; adjacent same-clip triangles (vertex
        // continuous, per-vertex colors) merge into one draw.
        var draws_issued: u32 = 0;
        var applied_scissor: ?[4]f32 = null;
        var triangles_uniforms_bound = false;
        var i: usize = 0;
        while (i < self.draw_calls.items.len) {
            const dc = self.draw_calls.items[i];

            if (applied_scissor == null or !std.mem.eql(f32, &applied_scissor.?, &dc.rect_clip)) {
                self.applyScissor(render_pass, dc.rect_clip);
                applied_scissor = dc.rect_clip;
            }

            if (dc.mode == .triangles) {
                if (!triangles_uniforms_bound) {
                    // triangles group shares one uniforms (color per-vertex).
                    const uniforms = PathUniforms{
                        .viewport_size = .{ self.viewport_width, self.viewport_height },
                        .scale_factor = self.scale_factor,
                        .draw_mode = @backingInt(DrawMode.triangles),
                        .clip_rect = self.clip_rect,
                        .clip_radii = self.clip_radii,
                        .clip_shape_kind = self.clip_shape_kind,
                        .clip2 = shape_clip_pair.field(self.clip2),
                    };
                    render_pass.setVertexBytes(1, std.mem.asBytes(&uniforms));
                    render_pass.setFragmentBytes(1, std.mem.asBytes(&uniforms));
                    triangles_uniforms_bound = true;
                }
                var merged_count: u32 = dc.vertex_count;
                var j = i + 1;
                while (j < self.draw_calls.items.len and
                    canCoalesce(dc, merged_count, self.draw_calls.items[j])) : (j += 1)
                {
                    merged_count += self.draw_calls.items[j].vertex_count;
                }
                render_pass.draw(merged_count, 1, dc.vertex_start, 0);
                draws_issued += 1;
                i = j;
            } else {
                const uniforms = PathUniforms{
                    .viewport_size = .{ self.viewport_width, self.viewport_height },
                    .scale_factor = self.scale_factor,
                    .draw_mode = @backingInt(dc.mode),
                    .color = dc.color,
                    .rect = dc.rect,
                    .fill_rule = dc.polygon.fill_rule,
                    .point_count = dc.polygon.point_count,
                    .contour_count = dc.polygon.contour_count,
                    .contour_end_points = dc.polygon.contour_end_points,
                    .polygon_points = dc.polygon.points,
                    .clip_rect = self.clip_rect,
                    .clip_radii = self.clip_radii,
                    .clip_shape_kind = self.clip_shape_kind,
                    .clip2 = shape_clip_pair.field(self.clip2),
                    .grad_dir = dc.gradient.dir,
                    .grad_stop_count = dc.gradient.stop_count,
                    .grad_center = dc.gradient.center,
                    .grad_angle = dc.gradient.angle,
                    .grad_colors = dc.gradient.colors,
                    .grad_positions = dc.gradient.positions,
                };
                render_pass.setVertexBytes(1, std.mem.asBytes(&uniforms));
                render_pass.setFragmentBytes(1, std.mem.asBytes(&uniforms));
                render_pass.draw(dc.vertex_count, 1, dc.vertex_start, 0);
                draws_issued += 1;
                triangles_uniforms_bound = false;
                i += 1;
            }
        }
        // Restore pass scissor: path is the only pipeline using hardware scissor for rect clip;
        // others (sdf/text/icon/image) shader-clip by rect_clip (default pass scissor =
        // drawable or damage). If not restored, the last draw's scissor leaks into all later
        // batches,
        // making UI outside the vector diagram's viewport (status bar, cards below text) vanish.
        if (applied_scissor != null) self.applyScissor(render_pass, .{ 0, 0, -1, -1 });
        self.last_flush_draw_count = draws_issued;
        self.frame_call_count += @intCast(self.draw_calls.items.len);
        self.frame_draw_count += draws_issued;
    }

    /// rect_clip: logical pixels x,y,w,h; w/h < 0 = no clipping (full viewport)
    fn applyScissor(self: *PathRenderer, render_pass: *gpu.Backend.RenderPass, rect_clip: [4]f32) void {
        var sx: u32 = 0;
        var sy: u32 = 0;
        var sw = nonNegativeFloatToU32(@ceil(self.raster_viewport[0]));
        var sh = nonNegativeFloatToU32(@ceil(self.raster_viewport[1]));
        if (rect_clip[2] >= 0 and rect_clip[3] >= 0) {
            const clip_x0 = std.math.clamp(rect_clip[0], 0, self.viewport_width);
            const clip_y0 = std.math.clamp(rect_clip[1], 0, self.viewport_height);
            const clip_x1 = std.math.clamp(rect_clip[0] + rect_clip[2], clip_x0, self.viewport_width);
            const clip_y1 = std.math.clamp(rect_clip[1] + rect_clip[3], clip_y0, self.viewport_height);
            // A hard rect clip includes exactly the pixel centers in [start, end).
            sx = if (clip_x0 == self.viewport_width) sw else nonNegativeFloatToU32(@ceil(clip_x0 * self.scale_factor - 0.5));
            sy = if (clip_y0 == self.viewport_height) sh else nonNegativeFloatToU32(@ceil(clip_y0 * self.scale_factor - 0.5));
            const ex = if (clip_x1 == self.viewport_width) sw else @min(sw, nonNegativeFloatToU32(@ceil(clip_x1 * self.scale_factor - 0.5)));
            const ey = if (clip_y1 == self.viewport_height) sh else @min(sh, nonNegativeFloatToU32(@ceil(clip_y1 * self.scale_factor - 0.5)));
            if (clip_x0 == clip_x1 or clip_y0 == clip_y1) {
                sw = 0;
                sh = 0;
            } else {
                sw = ex -| sx;
                sh = ey -| sy;
            }
        }
        // Partial redraw pass: intersect with dirty-area scissor; pixels outside dirty area must
        // not be touched
        if (self.damage_scissor) |d| {
            const x1 = @min(sx +| sw, d[0] +| d[2]);
            const y1 = @min(sy +| sh, d[1] +| d[3]);
            sx = @max(sx, d[0]);
            sy = @max(sy, d[1]);
            sw = x1 -| sx;
            sh = y1 -| sy;
        }
        render_pass.setScissorRect(sx, sy, sw, sh);
    }

    pub fn clearRetainingCapacity(self: *PathRenderer) void {
        self.vertices.clearRetainingCapacity();
        self.draw_calls.clearRetainingCapacity();
    }

    fn ensureVertexBufferCapacity(self: *PathRenderer, required_size: usize) !void {
        if (required_size == 0) return;
        if (self.vertex_buffer_capacity >= required_size and self.vertex_buffer != null) return;

        var new_capacity: usize = if (self.vertex_buffer_capacity == 0)
            4096
        else
            self.vertex_buffer_capacity;
        while (new_capacity < required_size) {
            new_capacity *= 2;
        }

        const new_buffer = try self.device.createBuffer(self.allocator, .{
            .label = "Zenit.Path.Vertices",
            .size = new_capacity,
            .usage = .{ .vertex = true, .map_write = true },
        });
        // Old buffer may be referenced by earlier passes in this frame (already recorded in
        // setVertexBuffer
        // to current command buffer) or in-flight from preceding frames. Use retire queue for
        // delayed
        // destroy, not synchronous free like old code (same bug class as glyph_atlas evictPage
        // fix).
        self.retireVertexBuffer();
        self.vertex_buffer = new_buffer;
        self.vertex_buffer_capacity = new_capacity;
    }

    /// Remove current vertex buffer and enqueue for delayed release. Capacity resets to zero.
    /// ensureVertexBufferCapacity rebuilds on next flush if needed, sized to actual usage.
    fn retireVertexBuffer(self: *PathRenderer) void {
        const buffer = self.vertex_buffer orelse return;
        self.vertex_buffer = null;
        self.vertex_buffer_capacity = 0;
        self.retired_buffers.append(self.allocator, .{
            .buffer = buffer,
            .retired_at_frame = self.shrink_frame,
        }) catch {
            // OOM fallback: synchronous destroy. Metal command buffer retains resource refs by
            // default,
            // so no actual dangling pointer; we just give up our conservative timing guarantee
            // here.
            var b = buffer;
            b.destroy();
        };
    }

    /// Retire current frame's buffer to this slot, switch to next slot's buffer (may be null,
    /// created on-demand at first flush). GPU is guaranteed to have consumed the next slot last
    /// written BUFFER_MAX_FRAMES_IN_FLIGHT frames ago (frame_sync ensures this).
    fn rotateVertexBufferSlot(self: *PathRenderer) void {
        self.restoreFrameBufferSlot(@intCast((self.buffer_slot + 1) % BUFFER_MAX_FRAMES_IN_FLIGHT));
    }

    /// Undo an unsubmitted frame's rotation without losing ownership of either
    /// slot's allocation. Failed-frame storage remains parked for its retry.
    pub fn restoreFrameBufferSlot(self: *PathRenderer, slot: usize) void {
        if (slot == self.buffer_slot) return;
        self.parked_buffers[self.buffer_slot] = self.vertex_buffer;
        self.parked_capacities[self.buffer_slot] = self.vertex_buffer_capacity;
        self.buffer_slot = slot;
        self.vertex_buffer = self.parked_buffers[self.buffer_slot];
        self.vertex_buffer_capacity = self.parked_capacities[self.buffer_slot];
        self.parked_buffers[self.buffer_slot] = null;
        self.parked_capacities[self.buffer_slot] = 0;
    }

    fn peakSlotCapacity(self: *const PathRenderer) usize {
        var peak = self.vertex_buffer_capacity;
        for (self.parked_capacities) |cap| peak = @max(peak, cap);
        return peak;
    }

    /// Count live vertex buffers in current + parked slots (test/diagnostics).
    fn liveSlotBufferCount(self: *const PathRenderer) usize {
        var n: usize = @intFromBool(self.vertex_buffer != null);
        for (self.parked_buffers) |maybe| n += @intFromBool(maybe != null);
        return n;
    }

    fn retireParkedBuffers(self: *PathRenderer) void {
        for (&self.parked_buffers, &self.parked_capacities) |*maybe, *cap| {
            const buffer = maybe.* orelse continue;
            maybe.* = null;
            cap.* = 0;
            self.retired_buffers.append(self.allocator, .{
                .buffer = buffer,
                .retired_at_frame = self.shrink_frame,
            }) catch {
                var b = buffer;
                b.destroy();
            };
        }
    }

    /// Release retired buffers that have exited the in-flight window. Called at beginFrame each
    /// frame.
    fn drainRetiredBuffers(self: *PathRenderer) void {
        var i: usize = 0;
        while (i < self.retired_buffers.items.len) {
            if (retiredBufferReady(self.retired_buffers.items[i].retired_at_frame, self.shrink_frame)) {
                var entry = self.retired_buffers.swapRemove(i);
                entry.buffer.destroy();
            } else {
                i += 1;
            }
        }
    }
};

// ============================================================================
// Ear-clipping triangulation
//
// Simple O(N^2) implementation for path contours (typically < 200 vertices).
// - Handles only simple polygons without holes.
// - Supports CW and CCW winding (auto-detect by signed area).
//
// Multiple contours triangulated independently.
// ============================================================================

const MAX_EARCLIP_POINTS: usize = 4096;
const MAX_EARCLIP_POINT_TESTS: usize = 8_000_000;

/// Whether adjacent triangle draw calls can merge: same clip and continuous vertex range.
/// prev_count = cumulative merged vertex count from prev's starting point.
fn canCoalesce(prev: DrawCall, prev_count: u32, next: DrawCall) bool {
    return prev.mode == .triangles and next.mode == .triangles and
        std.mem.eql(f32, &prev.rect_clip, &next.rect_clip) and
        next.vertex_start == prev.vertex_start + prev_count;
}

/// Triangulate contour and append to vertices (triangle list, no indices).
/// scratch: temp point array owned by caller, capacity reused across calls.
fn earclipFill(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(TPoint),
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
) !void {
    const n = contour.pointCount();
    if (n < 3 or n > MAX_EARCLIP_POINTS) return;
    if (!std.math.isFinite(off_x) or !std.math.isFinite(off_y)) return;
    const out_start = out.items.len;
    errdefer out.shrinkRetainingCapacity(out_start);

    // Copy vertices to mutable list (ear-clip removes processed vertices during iteration).
    scratch.clearRetainingCapacity();
    const pts = scratch;
    try pts.ensureTotalCapacity(allocator, n);
    for (0..n) |i| {
        const p = contour.point(i);
        const x = p.x + off_x;
        const y = p.y + off_y;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) {
            pts.clearRetainingCapacity();
            return;
        }
        pts.appendAssumeCapacity(.{ .x = x, .y = y });
    }

    // Ensure CCW winding (signed area > 0).
    ensureCCW(pts.items);
    try earclipRing(allocator, pts, out);
}

/// Ear-clips the positive-area polygon in `pts` (consumed) into `out`. The
/// polygon may be weakly simple: bridged holes repeat their bridge vertices,
/// which the strict point-in-triangle test lets through.
fn earclipRing(allocator: std.mem.Allocator, pts: *std.ArrayList(TPoint), out: *std.ArrayList(PathVertex)) !void {
    const out_start = out.items.len;
    errdefer out.shrinkRetainingCapacity(out_start);
    // Ear-clipping main loop.
    var remaining: usize = pts.items.len;
    // Remove trailing point if it coincides with start (closed paths may produce this).
    while (remaining > 3) {
        const last = pts.items[remaining - 1];
        const first = pts.items[0];
        if (@abs(last.x - first.x) < 1e-3 and @abs(last.y - first.y) < 1e-3) {
            remaining -= 1;
        } else break;
    }

    var point_test_budget = MAX_EARCLIP_POINT_TESTS;
    var completed = true;
    clip_loop: while (remaining > 3) {
        var found_ear = false;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            if (point_test_budget < remaining) {
                completed = false;
                break :clip_loop;
            }
            point_test_budget -= remaining;
            const prev = if (i == 0) remaining - 1 else i - 1;
            const next = (i + 1) % remaining;

            if (isEar(pts.items[0..remaining], prev, i, next)) {
                // Output triangle (fill, alpha_scale = 1.0).
                try out.append(allocator, .{ .x = pts.items[prev].x, .y = pts.items[prev].y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = pts.items[i].x, .y = pts.items[i].y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = pts.items[next].x, .y = pts.items[next].y, .alpha_scale = 1.0 });

                // Remove ear vertex.
                _ = pts.orderedRemove(i);
                remaining -= 1;
                found_ear = true;
                break;
            }
        }
        if (!found_ear) {
            // Under floating-point error, a "valid" ear may fail to detect (e.g., point lands on
            // edge).
            // Better to force-clip the most convex vertex than abandon early, leaving unfilled
            // wedges.
            // For simple polygons result is still correct; pathological self-intersecting input
            // worst case
            // produces light over-draw.
            var best: ?usize = null;
            var best_cross: f32 = 0;
            var k: usize = 0;
            while (k < remaining) : (k += 1) {
                const prev = if (k == 0) remaining - 1 else k - 1;
                const next = (k + 1) % remaining;
                const a = pts.items[prev];
                const b = pts.items[k];
                const c = pts.items[next];
                const cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
                if (std.math.isFinite(cross) and cross > best_cross) {
                    best_cross = cross;
                    best = k;
                }
            }
            const clip_idx = best orelse {
                completed = false;
                break :clip_loop;
            }; // No convex vertex found (fully degenerate), give up.
            const prev = if (clip_idx == 0) remaining - 1 else clip_idx - 1;
            const next = (clip_idx + 1) % remaining;
            try out.append(allocator, .{ .x = pts.items[prev].x, .y = pts.items[prev].y, .alpha_scale = 1.0 });
            try out.append(allocator, .{ .x = pts.items[clip_idx].x, .y = pts.items[clip_idx].y, .alpha_scale = 1.0 });
            try out.append(allocator, .{ .x = pts.items[next].x, .y = pts.items[next].y, .alpha_scale = 1.0 });
            _ = pts.orderedRemove(clip_idx);
            remaining -= 1;
        }
    }

    if (!completed) {
        out.shrinkRetainingCapacity(out_start);
        return;
    }

    // Last triangle.
    if (remaining >= 3) {
        const cross = triangleCross(pts.items[0], pts.items[1], pts.items[2]);
        if (!std.math.isFinite(cross) or @abs(cross) <= std.math.floatEps(f32)) {
            out.shrinkRetainingCapacity(out_start);
            return;
        }
        try out.append(allocator, .{ .x = pts.items[0].x, .y = pts.items[0].y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = pts.items[1].x, .y = pts.items[1].y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = pts.items[2].x, .y = pts.items[2].y, .alpha_scale = 1.0 });
    }
}

/// Ensure vertex list is CCW winding (reverse if CW).
fn ensureCCW(pts: []TPoint) void {
    var area2: f32 = 0;
    const n = pts.len;
    for (0..n) |i| {
        const j = (i + 1) % n;
        area2 += pts[i].x * pts[j].y;
        area2 -= pts[j].x * pts[i].y;
    }
    if (area2 < 0) {
        // CW -> reverse to CCW.
        std.mem.reverse(TPoint, pts);
    }
}

/// Test whether vertex i is an ear (convex angle + no other vertex inside triangle).
fn isEar(pts: []const TPoint, prev: usize, i: usize, next: usize) bool {
    const a = pts[prev];
    const b = pts[i];
    const c = pts[next];

    // Cross product test: is this a convex angle (cross > 0 = convex for CCW).
    const cross = triangleCross(a, b, c);
    if (!std.math.isFinite(cross) or cross <= 0) return false;

    // Check no other vertex lies inside triangle abc.
    for (pts, 0..) |p, j| {
        if (j == prev or j == i or j == next) continue;
        if (pointInTriangle(p, a, b, c)) return false;
    }
    return true;
}

/// Test whether point p is strictly inside triangle abc (excluding boundary).
fn pointInTriangle(p: TPoint, a: TPoint, b: TPoint, c: TPoint) bool {
    const d1 = sign(p, a, b);
    const d2 = sign(p, b, c);
    const d3 = sign(p, c, a);
    // Non-finite predicates must block this candidate ear. Treating NaN as
    // "outside" accepts a corrupt triangle and forwards it to the GPU.
    if (!std.math.isFinite(d1) or !std.math.isFinite(d2) or !std.math.isFinite(d3)) return true;
    // Strictly inside: all three signs same and non-zero.
    // Use <= to exclude collinear points (points on edge don't count as "inside").
    const all_pos = (d1 > 0) and (d2 > 0) and (d3 > 0);
    const all_neg = (d1 < 0) and (d2 < 0) and (d3 < 0);
    return all_pos or all_neg;
}

fn sign(p1: TPoint, p2: TPoint, p3: TPoint) f32 {
    return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
}

fn triangleCross(a: TPoint, b: TPoint, c: TPoint) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/// Generate AA fringe strip along polygon outline.
///
/// Each contour edge [P_i, P_{i+1}] expands outward by fringe_w pixels (along outer normal),
/// producing 2 triangles (quad). Outer vertex alpha_scale=0, inner=1.
fn buildAaFringe(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
    scale_factor: f32,
) !void {
    const n = contour.pointCount();
    if (n < 2) return;
    const edge_count: usize = if (contour.closed and n >= 2) n else n - 1;
    if (edge_count == 0) return;

    // Fringe on the unfilled side: right of each edge for a positive-area
    // contour, left for a negative one (a clockwise-in-y-up path); otherwise
    // the fringe lies inside the fill and the outer edge stays aliased.
    var area2: f32 = 0;
    for (0..n) |i| {
        const p = contour.point(i);
        const q = contour.point((i + 1) % n);
        area2 += p.x * q.y - q.x * p.y;
    }
    const fringe_w = (if (area2 < 0) @as(f32, -1) else 1) / @max(scale_factor, 0.001);

    for (0..edge_count) |i| {
        const j = i + 1;
        const pi = contour.point(i);
        const pj = contour.point(if (j < n) j else 0);

        const ax = pi.x + off_x;
        const ay = pi.y + off_y;
        const bx = pj.x + off_x;
        const by = pj.y + off_y;

        const ex = bx - ax;
        const ey = by - ay;
        const len = @sqrt(ex * ex + ey * ey);
        if (len < 1e-6) continue;

        // Outer normal (for CCW polygon, right side = outer): rotate +90deg -> (ey, -ex).
        const nx = ey / len * fringe_w;
        const ny = -ex / len * fringe_w;

        const a_inner = PathVertex{ .x = ax, .y = ay, .alpha_scale = 1.0 };
        const b_inner = PathVertex{ .x = bx, .y = by, .alpha_scale = 1.0 };
        const a_outer = PathVertex{ .x = ax + nx, .y = ay + ny, .alpha_scale = 0.0 };
        const b_outer = PathVertex{ .x = bx + nx, .y = by + ny, .alpha_scale = 0.0 };

        try out.append(allocator, a_inner);
        try out.append(allocator, b_inner);
        try out.append(allocator, a_outer);

        try out.append(allocator, b_inner);
        try out.append(allocator, b_outer);
        try out.append(allocator, a_outer);
    }
}

/// Replaces the triangles in `verts[start..]` by pieces that no stop iso-line
/// of the (affine) gradient crosses: each triangle is clipped to every band
/// between consecutive interior stops and the pieces fan-triangulated, with
/// position and alpha_scale interpolated along the cut edges.
fn splitAtGradientStops(allocator: std.mem.Allocator, verts: *std.ArrayList(PathVertex), start: usize, g: FillGradient, bounds: [4]f32) !void {
    const Clip = struct {
        fn t(grad: FillGradient, b: [4]f32, v: PathVertex) f32 {
            return grad.tAt((v.x - b[0]) / b[2], (v.y - b[1]) / b[3]);
        }
        fn lerp(p: PathVertex, q: PathVertex, k: f32) PathVertex {
            var out = p;
            out.x = p.x + (q.x - p.x) * k;
            out.y = p.y + (q.y - p.y) * k;
            out.alpha_scale = p.alpha_scale + (q.alpha_scale - p.alpha_scale) * k;
            return out;
        }
        /// Keeps the part of convex `poly` where side * (t - level) >= 0.
        fn half(grad: FillGradient, b: [4]f32, poly: []const PathVertex, level: f32, side: f32, out: []PathVertex) usize {
            var n: usize = 0;
            for (poly, 0..) |p, i| {
                const q = poly[(i + 1) % poly.len];
                const dp = side * (t(grad, b, p) - level);
                const dq = side * (t(grad, b, q) - level);
                if (dp >= 0) {
                    out[n] = p;
                    n += 1;
                }
                if ((dp >= 0) != (dq >= 0)) {
                    out[n] = lerp(p, q, dp / (dp - dq));
                    n += 1;
                }
            }
            return n;
        }
    };
    // Interior breakpoints of the piecewise-linear colour (stops ascend).
    var levels: [18]f32 = undefined;
    var level_count: usize = 0;
    for (g.stops) |stop| {
        if (level_count == levels.len) break;
        if (stop.position > 0 and stop.position < 1 and (level_count == 0 or stop.position > levels[level_count - 1])) {
            levels[level_count] = stop.position;
            level_count += 1;
        }
    }
    if (level_count == 0) return;
    const source = try allocator.dupe(PathVertex, verts.items[start..]);
    defer allocator.free(source);
    verts.shrinkRetainingCapacity(start);
    var i: usize = 0;
    while (i + 2 < source.len) : (i += 3) {
        const tri = source[i .. i + 3];
        for (0..level_count + 1) |band| {
            // Clipping a triangle by two parallel lines leaves a convex
            // polygon of at most five vertices.
            var a: [8]PathVertex = undefined;
            var b: [8]PathVertex = undefined;
            var n: usize = 3;
            @memcpy(a[0..3], tri);
            if (band > 0) n = Clip.half(g, bounds, a[0..n], levels[band - 1], 1, &b) else @memcpy(b[0..3], tri);
            if (n < 3) continue;
            if (band < level_count) n = Clip.half(g, bounds, b[0..n], levels[band], -1, &a) else @memcpy(a[0..n], b[0..n]);
            if (n < 3) continue;
            for (1..n - 1) |k| try verts.appendSlice(allocator, &.{ a[0], a[k], a[k + 1] });
        }
    }
}

fn appendOriented(allocator: std.mem.Allocator, out: *std.ArrayList(TPoint), ring: []const TPoint, positive: bool) !void {
    const start = out.items.len;
    try out.appendSlice(allocator, ring);
    if ((path_fill_rule.signedArea2(ring) > 0) != positive) std.mem.reverse(TPoint, out.items[start..]);
}

/// AA fringe on the right of every edge of a closed ring (already offset):
/// outside for a positive-area outer contour, inside the hole for a
/// negative-area hole. Same strip geometry as `buildAaFringe`.
fn buildAaFringeRing(allocator: std.mem.Allocator, out: *std.ArrayList(PathVertex), ring: []const TPoint, scale_factor: f32) !void {
    const fringe_w = 1.0 / @max(scale_factor, 0.001);
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        const ex = q.x - p.x;
        const ey = q.y - p.y;
        const len = @sqrt(ex * ex + ey * ey);
        if (len < 1e-6) continue;
        const nx = ey / len * fringe_w;
        const ny = -ex / len * fringe_w;
        const a_inner = PathVertex{ .x = p.x, .y = p.y, .alpha_scale = 1.0 };
        const b_inner = PathVertex{ .x = q.x, .y = q.y, .alpha_scale = 1.0 };
        const a_outer = PathVertex{ .x = p.x + nx, .y = p.y + ny, .alpha_scale = 0.0 };
        const b_outer = PathVertex{ .x = q.x + nx, .y = q.y + ny, .alpha_scale = 0.0 };
        try out.appendSlice(allocator, &.{ a_inner, b_inner, a_outer, b_inner, b_outer, a_outer });
    }
}

/// Stroke expansion: single-pass per-edge emission, each vertex computes miter/bevel/round join.
///
/// For each edge [Pi, Pj], compute join expansion at Pi, emit edge quad + fringe.
/// Bevel/round connect via extra fan triangles at joins.
fn buildStrokeExpand(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
    half_w: f32,
    scale_factor: f32,
    line_join: LineJoin,
) !void {
    const n = contour.pointCount();
    if (n < 2) return;

    const fringe_w = 1.0 / @max(scale_factor, 0.001);
    const is_closed = contour.closed and n >= 3;
    const edge_count: usize = if (is_closed) n else n - 1;
    const MITER_LIMIT: f32 = 4.0;

    // ---- Phase 1: compute unit normal for each edge ----
    const edge_norms = try allocator.alloc([2]f32, edge_count);
    defer allocator.free(edge_norms);

    for (0..edge_count) |i| {
        const j = (i + 1) % n;
        const pi = contour.point(i);
        const pj = contour.point(j);
        const ex = pj.x - pi.x;
        const ey = pj.y - pi.y;
        const len = @sqrt(ex * ex + ey * ey);
        if (len < 1e-6) {
            edge_norms[i] = .{ 0, 0 };
        } else {
            edge_norms[i] = .{ ey / len, -ex / len };
        }
    }

    // ---- Phase 2: emit triangle per edge ----
    // Each edge uses its own normal for expansion; both edge endpoints stay parallel to original.
    // Join connection handled via extra triangle fan.
    for (0..edge_count) |ei| {
        const ej = (ei + 1) % n;
        const pi = contour.point(ei);
        const pj = contour.point(ej);

        const ax = pi.x + off_x;
        const ay = pi.y + off_y;
        const bx = pj.x + off_x;
        const by = pj.y + off_y;

        const nn = edge_norms[ei];
        if (nn[0] == 0 and nn[1] == 0) continue;

        const nx = nn[0];
        const ny = nn[1];

        // Four solid vertices for this edge.
        const a0x = ax - nx * half_w;
        const a0y = ay - ny * half_w;
        const a1x = ax + nx * half_w;
        const a1y = ay + ny * half_w;
        const b0x = bx - nx * half_w;
        const b0y = by - ny * half_w;
        const b1x = bx + nx * half_w;
        const b1y = by + ny * half_w;

        // Solid quad.
        try out.append(allocator, .{ .x = a0x, .y = a0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });

        // AA fringe, outer side (+n).
        const ao_x = ax + nx * (half_w + fringe_w);
        const ao_y = ay + ny * (half_w + fringe_w);
        const bo_x = bx + nx * (half_w + fringe_w);
        const bo_y = by + ny * (half_w + fringe_w);
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ao_x, .y = ao_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = ao_x, .y = ao_y, .alpha_scale = 0.0 });

        // AA fringe, inner side (-n).
        const ai_x = ax - nx * (half_w + fringe_w);
        const ai_y = ay - ny * (half_w + fringe_w);
        const bi_x = bx - nx * (half_w + fringe_w);
        const bi_y = by - ny * (half_w + fringe_w);
        try out.append(allocator, .{ .x = a0x, .y = a0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ai_x, .y = ai_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ai_x, .y = ai_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });

        // ---- Join at vertex Pj (connect current and next edge) ----
        const next_edge = (ei + 1) % edge_count;
        if (!is_closed and ej == n - 1) continue; // Open path: no join at end.

        const nn2 = edge_norms[next_edge];
        if (nn2[0] == 0 and nn2[1] == 0) continue;

        // Compute miter.
        const mx = nx + nn2[0];
        const my = ny + nn2[1];
        const mlen_sq = mx * mx + my * my;
        if (mlen_sq < 1e-6) continue; // ~180 degree bend.

        const inv_mlen = 1.0 / @sqrt(mlen_sq);
        const mdx = mx * inv_mlen;
        const mdy = my * inv_mlen;
        const cos_half = @max(mdx * nx + mdy * ny, 1e-4);
        const miter_scale = half_w / cos_half;
        const cross = nx * nn2[1] - ny * nn2[0];
        const outside_right = cross >= 0;

        const use_miter = line_join == .miter and miter_scale <= half_w * MITER_LIMIT;

        if (use_miter) {
            // Miter join: emit miter only on outer side, avoid double-expansion into
            // concave/self-intersecting paths.
            const mr_x = bx + mdx * miter_scale;
            const mr_y = by + mdy * miter_scale;
            const ml_x = bx - mdx * miter_scale;
            const ml_y = by - mdy * miter_scale;
            const fringe_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);

            if (outside_right) {
                const fr_x = bx + mdx * fringe_scale;
                const fr_y = by + mdy * fringe_scale;
                const nr_x = bx + nn2[0] * half_w;
                const nr_y = by + nn2[1] * half_w;
                const nfr_x = bx + nn2[0] * (half_w + fringe_w);
                const nfr_y = by + nn2[1] * (half_w + fringe_w);

                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });

                try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nfr_x, .y = nfr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
            } else {
                const fl_x = bx - mdx * fringe_scale;
                const fl_y = by - mdy * fringe_scale;
                const nl_x = bx - nn2[0] * half_w;
                const nl_y = by - nn2[1] * half_w;
                const nfl_x = bx - nn2[0] * (half_w + fringe_w);
                const nfl_y = by - nn2[1] * (half_w + fringe_w);

                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });

                try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nfl_x, .y = nfl_y, .alpha_scale = 0.0 });
            }

            // Inner connection: patch only, avoid double-expansion spike.
            {
                const inner_scale = @min(miter_scale, half_w * 2.0);
                var mi_x: f32 = undefined;
                var mi_y: f32 = undefined;
                if (outside_right) {
                    mi_x = bx - mdx * inner_scale;
                    mi_y = by - mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx - nn2[0] * half_w, .y = by - nn2[1] * half_w, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                } else {
                    mi_x = bx + mdx * inner_scale;
                    mi_y = by + mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx + nn2[0] * half_w, .y = by + nn2[1] * half_w, .alpha_scale = 1.0 });
                }
            }
        } else {
            // Bevel/Round join: connect two edge endpoints with fan.
            // Determine outer side (fan emission side).
            // cross > 0 -> left turn -> outer on right (+n)
            // cross < 0 -> right turn -> outer on left (-n).

            // Outer: current edge end -> next edge start.
            var s0_x: f32 = undefined;
            var s0_y: f32 = undefined;
            var s1_x: f32 = undefined;
            var s1_y: f32 = undefined;
            var fs0_x: f32 = undefined;
            var fs0_y: f32 = undefined;
            var fs1_x: f32 = undefined;
            var fs1_y: f32 = undefined;
            if (outside_right) {
                s0_x = b1x;
                s0_y = b1y;
                s1_x = bx + nn2[0] * half_w;
                s1_y = by + nn2[1] * half_w;
                fs0_x = bo_x;
                fs0_y = bo_y;
                fs1_x = bx + nn2[0] * (half_w + fringe_w);
                fs1_y = by + nn2[1] * (half_w + fringe_w);
            } else {
                s0_x = b0x;
                s0_y = b0y;
                s1_x = bx - nn2[0] * half_w;
                s1_y = by - nn2[1] * half_w;
                fs0_x = bi_x;
                fs0_y = bi_y;
                fs1_x = bx - nn2[0] * (half_w + fringe_w);
                fs1_y = by - nn2[1] * (half_w + fringe_w);
            }

            // Inner: use miter to patch two triangles connecting.
            {
                const inner_scale = @min(miter_scale, half_w * 2.0);
                var mi_x: f32 = undefined;
                var mi_y: f32 = undefined;
                if (outside_right) {
                    // Inner on left (-n), miter direction is -mdx,-mdy.
                    mi_x = bx - mdx * inner_scale;
                    mi_y = by - mdy * inner_scale;
                    // Current edge left end -> miter -> next edge left end.
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx - nn2[0] * half_w, .y = by - nn2[1] * half_w, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    // Inner fringe.
                    const fi_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);
                    const fmi_x = bx - mdx * fi_scale;
                    const fmi_y = by - mdy * fi_scale;
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    const nl = bx - nn2[0] * half_w;
                    const nly = by - nn2[1] * half_w;
                    const nfl = bx - nn2[0] * (half_w + fringe_w);
                    const nfly = by - nn2[1] * (half_w + fringe_w);
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nl, .y = nly, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nl, .y = nly, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nfl, .y = nfly, .alpha_scale = 0.0 });
                } else {
                    // Inner on right (+n), miter direction is +mdx,+mdy.
                    mi_x = bx + mdx * inner_scale;
                    mi_y = by + mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx + nn2[0] * half_w, .y = by + nn2[1] * half_w, .alpha_scale = 1.0 });
                    // Inner fringe.
                    const fi_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);
                    const fmi_x = bx + mdx * fi_scale;
                    const fmi_y = by + mdy * fi_scale;
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                    const nr = bx + nn2[0] * half_w;
                    const nry = by + nn2[1] * half_w;
                    const nfr = bx + nn2[0] * (half_w + fringe_w);
                    const nfry = by + nn2[1] * (half_w + fringe_w);
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nr, .y = nry, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nr, .y = nry, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nfr, .y = nfry, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                }
            }

            // Outer fan.
            const segments: usize = if (line_join == .round) blk: {
                const angle0 = std.math.atan2(s0_y - by, s0_x - bx);
                var angle1 = std.math.atan2(s1_y - by, s1_x - bx);
                if (outside_right) {
                    while (angle1 < angle0) angle1 += std.math.pi * 2.0;
                } else {
                    while (angle1 > angle0) angle1 -= std.math.pi * 2.0;
                }
                const sweep = @abs(angle1 - angle0);
                break :blk roundJoinSegmentCount(sweep);
            } else 1;

            if (segments == 1) {
                // Bevel: use exact coordinates.
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s0_x, .y = s0_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                // fringe
                try out.append(allocator, .{ .x = s0_x, .y = s0_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fs0_x, .y = fs0_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fs1_x, .y = fs1_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fs0_x, .y = fs0_y, .alpha_scale = 0.0 });
            } else {
                // Round: circular arc fan.
                const angle0 = std.math.atan2(s0_y - by, s0_x - bx);
                var angle1 = std.math.atan2(s1_y - by, s1_x - bx);
                if (outside_right) {
                    while (angle1 < angle0) angle1 += std.math.pi * 2.0;
                } else {
                    while (angle1 > angle0) angle1 -= std.math.pi * 2.0;
                }
                const step = (angle1 - angle0) / @as(f32, @floatFromInt(segments));
                const fr = half_w + fringe_w;

                var px = s0_x;
                var py = s0_y;
                var fx = fs0_x;
                var fy = fs0_y;

                for (0..segments) |si| {
                    var cx: f32 = undefined;
                    var cy: f32 = undefined;
                    var cfx: f32 = undefined;
                    var cfy: f32 = undefined;
                    if (si == segments - 1) {
                        cx = s1_x;
                        cy = s1_y;
                        cfx = fs1_x;
                        cfy = fs1_y;
                    } else {
                        const a = angle0 + step * @as(f32, @floatFromInt(si + 1));
                        cx = bx + @cos(a) * half_w;
                        cy = by + @sin(a) * half_w;
                        cfx = bx + @cos(a) * fr;
                        cfy = by + @sin(a) * fr;
                    }

                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = px, .y = py, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });

                    try out.append(allocator, .{ .x = px, .y = py, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fx, .y = fy, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cfx, .y = cfy, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fx, .y = fy, .alpha_scale = 0.0 });

                    px = cx;
                    py = cy;
                    fx = cfx;
                    fy = cfy;
                }
            }
        }
    }
}

fn nonNegativeFloatToU32(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const max_u32_f64: f64 = @floatFromInt(std.math.maxInt(u32));
    if (@as(f64, value) >= max_u32_f64) return std.math.maxInt(u32);
    return @intFromFloat(value);
}

fn roundJoinSegmentCount(sweep: f32) usize {
    if (!std.math.isFinite(sweep) or sweep <= 0) return 2;
    const raw = @ceil(sweep / (std.math.pi / 12.0));
    if (!std.math.isFinite(raw) or raw >= 64) return 64;
    return @max(2, @as(usize, @intFromFloat(raw)));
}

// ============================================================================
// Unit tests
// ============================================================================

test "round join and scissor conversions bound non-finite values" {
    try std.testing.expectEqual(@as(usize, 2), roundJoinSegmentCount(std.math.nan(f32)));
    try std.testing.expectEqual(@as(usize, 2), roundJoinSegmentCount(std.math.inf(f32)));
    try std.testing.expectEqual(@as(u32, 0), nonNegativeFloatToU32(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 0), nonNegativeFloatToU32(std.math.inf(f32)));
}

test "earclipFill star polygon produces correct triangle count" {
    const alloc = std.testing.allocator;
    var star_verts = [_]f32{
        60.0, 5.0,  73.0, 43.0,  113.0, 43.0, 82.0, 67.0, 93.0, 107.0,
        60.0, 85.0, 27.0, 107.0, 40.0,  67.0, 5.0,  43.0, 47.0, 43.0,
    };
    const contour = Contour{ .vertices = &star_verts };
    var scratch = @as(std.ArrayList(TPoint), .empty);
    defer scratch.deinit(alloc);
    var out = @as(std.ArrayList(PathVertex), .empty);
    defer out.deinit(alloc);
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    try std.testing.expectEqual(@as(usize, 24), out.items.len);
    // scratch reuse: second call yields same result.
    out.clearRetainingCapacity();
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    try std.testing.expectEqual(@as(usize, 24), out.items.len);
}

test "earclipFill 40-point burst star fills completely" {
    const alloc = std.testing.allocator;
    var verts: [80]f32 = undefined;
    for (0..40) |i| {
        const outer: f32 = 29.44;
        const inner: f32 = 29.44 * 0.72;
        const radius = if (i % 2 == 0) outer else inner;
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 20.0);
        verts[i * 2] = 32.0 + std.math.cos(angle) * radius;
        verts[i * 2 + 1] = 32.0 + std.math.sin(angle) * radius;
    }
    const contour = Contour{ .vertices = &verts, .closed = true };
    var scratch = @as(std.ArrayList(TPoint), .empty);
    defer scratch.deinit(alloc);
    var out = @as(std.ArrayList(PathVertex), .empty);
    defer out.deinit(alloc);
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    // n=40 simple polygon full triangulation = (n-2)*3 = 114 vertices.
    try std.testing.expectEqual(@as(usize, 114), out.items.len);
}

test "earclipFill rejects non-finite and oversized contours" {
    const alloc = std.testing.allocator;
    var scratch = @as(std.ArrayList(TPoint), .empty);
    defer scratch.deinit(alloc);
    var out = @as(std.ArrayList(PathVertex), .empty);
    defer out.deinit(alloc);

    var invalid = [_]f32{ 0, 0, std.math.nan(f32), 1, 1, 0 };
    try earclipFill(alloc, &scratch, &out, .{ .vertices = &invalid, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    var overflowed_predicate = [_]f32{ -std.math.floatMax(f32), 0, std.math.floatMax(f32), 0, 0, std.math.floatMax(f32) };
    try earclipFill(alloc, &scratch, &out, .{ .vertices = &overflowed_predicate, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    const oversized = try alloc.alloc(f32, (MAX_EARCLIP_POINTS + 1) * 2);
    defer alloc.free(oversized);
    @memset(oversized, 0);
    try earclipFill(alloc, &scratch, &out, .{ .vertices = oversized, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "canCoalesce merges only contiguous same-clip triangles calls" {
    const clip_a = [4]f32{ 0, 0, -1, -1 };
    const clip_b = [4]f32{ 10, 10, 50, 50 };
    const t0 = DrawCall{ .vertex_start = 0, .vertex_count = 30, .color = .{ 1, 0, 0, 1 }, .rect_clip = clip_a };
    const t1 = DrawCall{ .vertex_start = 30, .vertex_count = 12, .color = .{ 0, 1, 0, 1 }, .rect_clip = clip_a };
    const t2 = DrawCall{ .vertex_start = 42, .vertex_count = 6, .color = .{ 0, 0, 1, 1 }, .rect_clip = clip_b };
    const p0 = DrawCall{ .mode = .polygon_fill, .vertex_start = 42, .vertex_count = 6, .color = .{ 0, 0, 1, 1 }, .rect_clip = clip_a };

    // Different colors but same clip, continuous range -> mergeable (per-vertex color).
    try std.testing.expect(canCoalesce(t0, t0.vertex_count, t1));
    // Merge t0+t1 then compare to t2: different clip -> not mergeable.
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count + t1.vertex_count, t2));
    // polygon_fill never participates in merge.
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count + t1.vertex_count, p0));
    // Discontinuous range -> not mergeable.
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count, t2));
}

test "buildStrokeExpand open contour does not add implicit closing edge" {
    const alloc = std.testing.allocator;
    var open_verts = [_]f32{
        0.0,  0.0,
        10.0, 10.0,
        20.0, 0.0,
    };
    var closed_verts = open_verts;

    const open_contour = Contour{ .vertices = &open_verts, .closed = false };
    const closed_contour = Contour{ .vertices = &closed_verts, .closed = true };

    var open_out = @as(std.ArrayList(PathVertex), .empty);
    defer open_out.deinit(alloc);
    try buildStrokeExpand(alloc, &open_out, open_contour, 0, 0, 2.0, 1.0, .miter);

    var closed_out = @as(std.ArrayList(PathVertex), .empty);
    defer closed_out.deinit(alloc);
    try buildStrokeExpand(alloc, &closed_out, closed_contour, 0, 0, 2.0, 1.0, .miter);

    try std.testing.expect(open_out.items.len > 0);
    try std.testing.expect(closed_out.items.len > open_out.items.len);
}

test "buildStrokeExpand miter join stays near bevel bounds for star contour" {
    const alloc = std.testing.allocator;
    var star_verts = [_]f32{
        60.0, 5.0,  73.0, 43.0,  113.0, 43.0, 82.0, 67.0, 93.0, 107.0,
        60.0, 83.0, 27.0, 107.0, 38.0,  67.0, 7.0,  43.0, 47.0, 43.0,
    };
    const contour = Contour{ .vertices = &star_verts, .closed = true };

    var bevel_out = @as(std.ArrayList(PathVertex), .empty);
    defer bevel_out.deinit(alloc);
    try buildStrokeExpand(alloc, &bevel_out, contour, 0, 0, 3.0, 1.0, .bevel);

    var miter_out = @as(std.ArrayList(PathVertex), .empty);
    defer miter_out.deinit(alloc);
    try buildStrokeExpand(alloc, &miter_out, contour, 0, 0, 3.0, 1.0, .miter);

    try std.testing.expect(bevel_out.items.len > 0);
    try std.testing.expect(miter_out.items.len > 0);

    const bevel_bounds = vertexBounds(bevel_out.items);
    const miter_bounds = vertexBounds(miter_out.items);
    const allowance: f32 = 14.0;

    try std.testing.expect(miter_bounds.min_x >= bevel_bounds.min_x - allowance);
    try std.testing.expect(miter_bounds.max_x <= bevel_bounds.max_x + allowance);
    try std.testing.expect(miter_bounds.min_y >= bevel_bounds.min_y - allowance);
    try std.testing.expect(miter_bounds.max_y <= bevel_bounds.max_y + allowance);
}

const VertexBounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

fn vertexBounds(vertices: []const PathVertex) VertexBounds {
    std.debug.assert(vertices.len > 0);
    var bounds = VertexBounds{
        .min_x = vertices[0].x,
        .min_y = vertices[0].y,
        .max_x = vertices[0].x,
        .max_y = vertices[0].y,
    };
    for (vertices[1..]) |v| {
        bounds.min_x = @min(bounds.min_x, v.x);
        bounds.min_y = @min(bounds.min_y, v.y);
        bounds.max_x = @max(bounds.max_x, v.x);
        bounds.max_y = @max(bounds.max_y, v.y);
    }
    return bounds;
}

test "Phase C mesh cache: store → 平移回填命中 → TTL 逐出" {
    const alloc = std.testing.allocator;
    var r = PathRenderer{
        .allocator = alloc,
        .device = undefined,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .empty,
        .draw_calls = .empty,
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
        .current_rect_clip = .{ 0, 0, -1, -1 },
    };
    defer {
        var it = r.mesh_cache.valueIterator();
        while (it.next()) |e| alloc.free(e.verts);
        r.mesh_cache.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    // No hit.
    try std.testing.expect(!try r.appendCachedMesh(42, .{ 1, 1, 1, 1 }, 0, 0));

    // Simulate vertices from addFillPath (world = local + offset(10,20)).
    try r.vertices.append(alloc, .{ .x = 10, .y = 20, .alpha_scale = 1 });
    try r.vertices.append(alloc, .{ .x = 15, .y = 26, .alpha_scale = 1 });
    try r.vertices.append(alloc, .{ .x = 12, .y = 30, .alpha_scale = 0 });
    r.storeMesh(42, 0, 3, 10, 20);
    try std.testing.expectEqual(@as(usize, 3), r.mesh_cache_vertex_total);

    // Hit: new offset (100,200) translates fill result + adds color + records draw call.
    r.vertices.clearRetainingCapacity();
    r.draw_calls.clearRetainingCapacity();
    try std.testing.expect(try r.appendCachedMesh(42, .{ 0.5, 0, 0, 1 }, 100, 200));
    try std.testing.expectEqual(@as(usize, 3), r.vertices.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 100), r.vertices.items[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), r.vertices.items[0].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 105), r.vertices.items[1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.vertices.items[2].alpha_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.vertices.items[0].color[0], 0.001);
    try std.testing.expectEqual(@as(usize, 1), r.draw_calls.items.len);
    try std.testing.expectEqual(DrawMode.triangles, r.draw_calls.items[0].mode);

    // TTL eviction: last_used=0, at frame 360 (120 multiple triggers sweep) 0+240 < 360 -> remove.
    r.setFrame(360);
    try std.testing.expect(!try r.appendCachedMesh(42, .{ 1, 1, 1, 1 }, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), r.mesh_cache_vertex_total);
}

test "vertex buffer 收缩判据：连续低水位在精确帧边界触发" {
    var p = ShrinkPolicy{};
    const cap: usize = 8 * 1024 * 1024;

    // High watermark (usage >= cap/4): never triggers.
    var i: u32 = 0;
    while (i < SHRINK_FRAMES * 2) : (i += 1) {
        try std.testing.expect(!p.noteFrame(cap / 2, cap));
    }

    // Low watermark SHRINK_FRAMES-1 frames: not enough for shrink threshold.
    i = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        try std.testing.expect(!p.noteFrame(cap / SHRINK_DIVISOR - 1, cap));
    }
    // Exactly frame SHRINK_FRAMES: shrink triggered.
    try std.testing.expect(p.noteFrame(cap / SHRINK_DIVISOR - 1, cap));
    // Count resets after trigger: no re-shrink next frame.
    try std.testing.expect(!p.noteFrame(0, cap));
}

test "vertex buffer 收缩判据：中途一帧回到高水位即重置计数（防帧间抖动）" {
    var p = ShrinkPolicy{};
    const cap: usize = 8 * 1024 * 1024;

    var i: u32 = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) _ = p.noteFrame(0, cap);
    // One frame before threshold, insert high usage frame (cap/4 counts as high) -> counter resets.
    try std.testing.expect(!p.noteFrame(cap / SHRINK_DIVISOR, cap));
    // Refill entire window before trigger again.
    i = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        try std.testing.expect(!p.noteFrame(0, cap));
    }
    try std.testing.expect(p.noteFrame(0, cap));
}

test "vertex buffer 收缩判据：小容量不收缩" {
    var p = ShrinkPolicy{};
    var i: u32 = 0;
    while (i < SHRINK_FRAMES * 2) : (i += 1) {
        try std.testing.expect(!p.noteFrame(0, SHRINK_MIN_CAPACITY));
    }
}

test "retired buffer 延迟释放：满 in-flight 窗口才可 destroy" {
    // Retire at frame 10: frames 10/11/12 may still be in-flight, frame 13+ safe.
    try std.testing.expect(!retiredBufferReady(10, 10));
    try std.testing.expect(!retiredBufferReady(10, 11));
    try std.testing.expect(!retiredBufferReady(10, 12));
    try std.testing.expect(retiredBufferReady(10, 13));
}

test "vertex buffer 高水位收缩：beginFrame 序列驱动 retire → 延迟 destroy" {
    // Needs real createBuffer/destroy and stats counting, only deterministic with Null backend
    // (Metal needs real device, that's test-metal's domain).
    // Run: `zig build test-render -Dgpu-backend=null`.
    // SKIP-REASON: only meaningful with -Dgpu-backend=null (Metal backend runs real pipeline).
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var r = PathRenderer{
        .allocator = alloc,
        .device = &device,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .empty,
        .draw_calls = .empty,
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
    };
    defer {
        if (r.vertex_buffer) |*b| b.destroy();
        for (&r.parked_buffers) |*m| if (m.*) |*b| b.destroy();
        for (r.retired_buffers.items) |*e| e.buffer.destroy();
        r.retired_buffers.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    const destroyed_base = gpu.Backend.stats.buffers_destroyed;

    // Grow to high watermark (> SHRINK_MIN_CAPACITY).
    try r.ensureVertexBufferCapacity(2 * 1024 * 1024);
    try std.testing.expect(r.vertex_buffer_capacity >= 2 * 1024 * 1024);

    // Grow path also uses delayed release: expand one tier, old buffer enters retired queue (not
    // sync destroy).
    try r.ensureVertexBufferCapacity(4 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), r.retired_buffers.items.len);
    try std.testing.expectEqual(destroyed_base, gpu.Backend.stats.buffers_destroyed);

    // Sustained low watermark SHRINK_FRAMES-1 frames: no shrink.
    var i: u32 = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        r.buffer_write_offset = 1024; // Simulate last frame used only 1 KiB << cap/4.
        r.beginFrame(800, 600, 1.0);
        // Peak buffer still parked in some slot (rotation doesn't discard buffers).
        try std.testing.expectEqual(@as(usize, 1), r.liveSlotBufferCount());
    }
    // Old buffer from earlier grow-retire has drained by now (3 frames later).
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // Exactly frame SHRINK_FRAMES: shrink occurs, buffer removed and enters retired, capacity zero.
    r.buffer_write_offset = 1024;
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(@as(usize, 0), r.liveSlotBufferCount());
    try std.testing.expectEqual(@as(usize, 0), r.peakSlotCapacity());
    try std.testing.expectEqual(@as(usize, 1), r.retired_buffers.items.len);
    // Shrink frame itself doesn't destroy (may still be in-flight).
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // Still not destroyed 2 frames later (in-flight window = 3).
    r.beginFrame(800, 600, 1.0);
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // Frame 3: drain finally releases.
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(destroyed_base + 2, gpu.Backend.stats.buffers_destroyed);
    try std.testing.expectEqual(@as(usize, 0), r.retired_buffers.items.len);
}

test "顶点 buffer 按帧槽位轮转：在飞窗口内相邻帧不共用同一块 buffer" {
    // Regression: single buffer + reset write offset each frame means frame N+1 memcpy overwrites
    // GPU still-consuming frame N vertices.
    // SKIP-REASON: needs Null backend determinism (Metal is test-metal's domain).
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var r = PathRenderer{
        .allocator = alloc,
        .device = &device,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .empty,
        .draw_calls = .empty,
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
    };
    defer {
        if (r.vertex_buffer) |*b| b.destroy();
        for (&r.parked_buffers) |*m| if (m.*) |*b| b.destroy();
        for (r.retired_buffers.items) |*e| e.buffer.destroy();
        r.retired_buffers.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    var seen: [BUFFER_MAX_FRAMES_IN_FLIGHT + 2]?[*]u8 = undefined;
    for (&seen) |*slot| {
        r.beginFrame(800, 600, 1.0);
        try r.ensureVertexBufferCapacity(4096);
        slot.* = (try r.vertex_buffer.?.getMappedRange(0, 1)).ptr;
        r.buffer_write_offset = 4096;
    }
    // Any BUFFER_MAX_FRAMES_IN_FLIGHT consecutive frames use distinct buffers.
    for (0..seen.len) |i| {
        for (i + 1..@min(seen.len, i + BUFFER_MAX_FRAMES_IN_FLIGHT)) |j| {
            try std.testing.expect(seen[i] != seen[j]);
        }
    }
    // After full cycle reuse (not new per frame).
    try std.testing.expectEqual(seen[0], seen[BUFFER_MAX_FRAMES_IN_FLIGHT]);
}

test {
    _ = path_fill_rule;
}

test "multi-contour fill: bridged hole is triangulated with the hole left uncovered" {
    const allocator = std.testing.allocator;
    const outer = [_]TPoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const hole = [_]TPoint{ .{ .x = 3, .y = 7 }, .{ .x = 7, .y = 7 }, .{ .x = 7, .y = 3 }, .{ .x = 3, .y = 3 } };
    var ring: std.ArrayList(TPoint) = .empty;
    defer ring.deinit(allocator);
    _ = try path_fill_rule.bridgeHoles(allocator, &ring, &outer, &.{&hole});
    var tris: std.ArrayList(PathVertex) = .empty;
    defer tris.deinit(allocator);
    try earclipRing(allocator, &ring, &tris);
    var area: f32 = 0;
    var covers_hole = false;
    var covers_solid = false;
    var i: usize = 0;
    while (i + 2 < tris.items.len) : (i += 3) {
        const a = TPoint{ .x = tris.items[i].x, .y = tris.items[i].y };
        const b = TPoint{ .x = tris.items[i + 1].x, .y = tris.items[i + 1].y };
        const c = TPoint{ .x = tris.items[i + 2].x, .y = tris.items[i + 2].y };
        area += @abs(triangleCross(a, b, c)) / 2;
        covers_hole = covers_hole or pointInTriangle(.{ .x = 5, .y = 5 }, a, b, c);
        covers_solid = covers_solid or pointInTriangle(.{ .x = 1.5, .y = 5.2 }, a, b, c);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 16), area, 1e-3);
    try std.testing.expect(!covers_hole);
    try std.testing.expect(covers_solid);
}

test "splitAtGradientStops makes per-vertex colour exact across a middle stop" {
    const allocator = std.testing.allocator;
    const stops = [_]FillGradient.GradientStopIn{
        .{ .color = .{ 1, 0, 0, 1 }, .position = 0 },
        .{ .color = .{ 0, 1, 0, 1 }, .position = 0.5 },
        .{ .color = .{ 0, 0, 1, 1 }, .position = 1 },
    };
    const g = FillGradient{ .dir = 2, .stops = &stops };
    var verts: std.ArrayList(PathVertex) = .empty;
    defer verts.deinit(allocator);
    const square = [_][2]f32{ .{ 0, 0 }, .{ 80, 0 }, .{ 80, 80 }, .{ 0, 0 }, .{ 80, 80 }, .{ 0, 80 } };
    for (square) |p| try verts.append(allocator, .{ .x = p[0], .y = p[1], .alpha_scale = 1 });
    const bounds = [4]f32{ 0, 0, 80, 80 };
    try splitAtGradientStops(allocator, &verts, 0, g, bounds);
    for (verts.items) |*v| v.color = g.colorAt(g.tAt(v.x / 80, v.y / 80));
    // Interpolate at the middle (40, 30) inside whichever piece contains it.
    const p = TPoint{ .x = 40, .y = 30 };
    var found = false;
    var i: usize = 0;
    while (i + 2 < verts.items.len) : (i += 3) {
        const a = verts.items[i];
        const b = verts.items[i + 1];
        const c = verts.items[i + 2];
        const den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
        if (@abs(den) < 1e-6) continue;
        const wa = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / den;
        const wb = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / den;
        const wc = 1 - wa - wb;
        if (wa < -1e-4 or wb < -1e-4 or wc < -1e-4) continue;
        for (0..3) |ch| try std.testing.expectApproxEqAbs(@as(f32, if (ch == 1) 1 else 0), wa * a.color[ch] + wb * b.color[ch] + wc * c.color[ch], 1e-3);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "buildAaFringe puts the fringe outside the fill for either contour orientation" {
    const allocator = std.testing.allocator;
    var ccw = [_]f32{ 0, 0, 10, 0, 10, 10, 0, 10 };
    var cw = [_]f32{ 0, 0, 0, 10, 10, 10, 10, 0 };
    for ([_][]f32{ &ccw, &cw }) |pts| {
        var out: std.ArrayList(PathVertex) = .empty;
        defer out.deinit(allocator);
        try buildAaFringe(allocator, &out, .{ .vertices = pts, .closed = true }, 0, 0, 1);
        try std.testing.expect(out.items.len > 0);
        for (out.items) |v| {
            if (v.alpha_scale != 0) continue;
            // Strictly outside the square (an inward fringe vertex sits on or
            // inside its boundary).
            try std.testing.expect(v.x < 0 or v.x > 10 or v.y < 0 or v.y > 10);
        }
    }
}
