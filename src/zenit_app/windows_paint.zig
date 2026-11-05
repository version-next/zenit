//! Windows paint-table presentation through a D3D11 swap chain and Direct2D.
//! This is the current Windows renderer subset; unsupported paint kinds are
//! counted so applications can report incomplete frames during porting.
const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const render = @import("render");

extern fn zenit_d3d11_probe_clear_text(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_create(hwnd: *anyopaque) ?*anyopaque;
extern fn zenit_d3d11_probe_set_font_locale(probe: *anyopaque, locale: [*:0]const u8) c_int;
extern fn zenit_d3d11_probe_set_font_family(probe: *anyopaque, family: [*:0]const u8) c_int;
extern fn zenit_d3d11_probe_render(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_capture_bmp(probe: *anyopaque, path: [*:0]const u16) c_int;
extern fn zenit_d3d11_probe_retain_submitted(probe: *anyopaque, enabled: c_int) void;
extern fn zenit_d3d11_probe_destroy(probe: *anyopaque) void;
extern fn zenit_d3d11_probe_device(probe: *anyopaque) ?*anyopaque;
extern fn zenit_d3d11_probe_items_supported(probe: *anyopaque) c_int;
extern fn zenit_d3d11_probe_item_size() usize;
extern fn zenit_d3d11_probe_set_clear_color(probe: *anyopaque, r: f32, g: f32, b: f32, a: f32) void;
extern fn zenit_d3d11_probe_set_items(probe: *anyopaque, items: [*]const PaintItem, count: u32, scale: f32) c_int;
extern fn zenit_d3d11_probe_reset_timing(probe: *anyopaque) void;
extern fn zenit_d3d11_probe_get_timing(probe: *anyopaque, out: *TimingStats) void;
extern fn zenit_d3d11_probe_set_cpu_timing(probe: *anyopaque, layout: u64, render: u64, encode: u64) void;
const Luminance = extern struct { owner_id: u32, value: f32 };
extern fn zenit_d3d11_probe_get_luminance(probe: *anyopaque, out: [*]Luminance, capacity: u32) u32;
pub const RetainedStats = extern struct { hits: u32 = 0, misses: u32 = 0, partial: u32 = 0 };
extern fn zenit_d3d11_probe_get_retained(probe: *anyopaque, out: *RetainedStats) void;
extern fn zenit_d3d11_probe_set_retained_enabled(probe: *anyopaque, enabled: c_int) void;
const DamageItem = extern struct { digest: u64, bounds: [4]f32 };
const RetainedInfo = extern struct {
    id: u32 = std.math.maxInt(u32),
    count: u32 = 0,
    hash: u64 = 0,
    damage: ?[*]const DamageItem = null,
    safe: u32 = 0,
};

pub const FrameTiming = extern struct {
    gpu_execute_us: u64 = 0,
    cpu_frame_us: u64 = 0,
    total_frame_us: u64 = 0,
    layout_us: u64 = 0,
    render_gen_us: u64 = 0,
    gpu_encode_us: u64 = 0,
};
pub const TimingStats = extern struct {
    last: FrameTiming = .{},
    gpu_p95_us: u64 = 0,
    cpu_p95_us: u64 = 0,
    total_p95_us: u64 = 0,
    timing_samples: u64 = 0,
    frame_count: u64 = 0,
    cpu_timing_samples: u64 = 0,
    disjoint_samples: u64 = 0,
    failed_samples: u64 = 0,
    pending_queries: u64 = 0,
    query_supported: u64 = 0,
};

pub const Backdrop = extern struct {
    radius: f32 = 0,
    level: f32 = 1,
    saturation: f32 = 1,
    brightness: f32 = 1,
    direction: u32 = 0,
    count: u32 = 2,
    strength: f32 = 0,
    positions: [4]f32 = .{ 0, 1, 1, 1 },
    strengths: [4]f32 = .{ 1, 0, 0, 0 },
    matrix: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    owner_id: u32 = std.math.maxInt(u32),
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    thickness: f32 = 4,
    optic: [4]f32 = .{ 0, 1, 0, 0 },
    specular: [4]f32 = .{ 0.35, 6, 1, 0 },
    surface: [4]f32 = .{ 0, 0.18, -std.math.pi / 3.0, 0 },
    bottom: [4]f32 = .{ 0, 0.12, 0, 0 },
    lens: [4]f32 = .{ 0.58, 2.2, 1, 1 },
    radii: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Gradient = extern struct {
    count: u32 = 0,
    direction: u32 = 0,
    extend_mode: u32 = 0,
    shape: u32 = 0,
    center: [2]f32 = .{ 0.5, 0.5 },
    radius: [2]f32 = .{ 0.5, 0.5 },
    colors: [16][4]f32 = @as([16][4]f32, @splat(.{ 0, 0, 0, 0 })),
    positions: [16]f32 = @as([16]f32, @splat(0)),
    start_angle: f32 = 0,
    conic_phase: f32 = 0.5,
};

fn gradientInfo(item: anytype) Gradient {
    var result: Gradient = .{
        .count = if (item.mg_stop_count > 0) @min(item.mg_stop_count, 16) else 2,
        .direction = item.gradient_direction,
        .extend_mode = item.gradient_extend_mode,
        .shape = item.shape_kind,
        .center = if (item.gradient_direction == 4) .{ 0.5, 0.5 } else .{ 0.5 + item.gradient_radial_center_x, 0.5 + item.gradient_radial_center_y },
        .radius = .{ item.gradient_radial_radius_x, item.gradient_radial_radius_y },
        .start_angle = item.gradient_conic_start_angle,
    };
    if (item.mg_stop_count > 0) {
        for (0..result.count) |i| {
            const c = item.mg_stop_colors[i];
            result.colors[i] = .{ channel(c.r), channel(c.g), channel(c.b), channel(c.a) };
            result.positions[i] = item.mg_stop_positions[i];
        }
    } else {
        const a = item.color;
        const b = item.gradient_to_color;
        result.colors[0] = .{ channel(a.r), channel(a.g), channel(a.b), channel(a.a) };
        result.colors[1] = .{ channel(b.r), channel(b.g), channel(b.b), channel(b.a) };
        result.positions[1] = 1;
    }
    return result;
}

pub const PaintItem = extern struct {
    kind: u32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    font_size: f32,
    font_weight: u32,
    text: ?[*]const u8,
    text_length: u32,
    to_r: f32,
    to_g: f32,
    to_b: f32,
    to_a: f32,
    gradient_direction: u32,
    stroke_width: f32,
    // Shared native ABI slot for TL/TR/BR/BL shadow, rect and clip radii.
    shadow_radii: [4]f32 = .{ 0, 0, 0, 0 },
    shadow_blur: f32 = 0,
    shadow_offset_x: f32 = 0,
    shadow_offset_y: f32 = 0,
    shadow_spread: f32 = 0,
    backdrop: Backdrop = .{},
    retained: RetainedInfo = .{},
    gradient: Gradient = .{},
    noise: extern struct { mode: u32 = 0, seed: u32 = 0, scale: f32 = 0, intensity: f32 = 0 } = .{},
    font_ref: ?*anyopaque = null,
    fixed_ascii_advance: f32 = 0,
    font_ranges: ?*anyopaque = null,
    italic: u32 = 0,
};

const PathPoint = extern struct { x: f32, y: f32, verb: u32 };

pub const Painter = struct {
    pub const NativePaintItem = PaintItem;
    io: std.Io,
    native: *anyopaque,
    image_renderer: @import("windows_image_renderer.zig").ImageRenderer,
    allocator: std.mem.Allocator,
    fonts: ?*@import("render").FontSelector = null,
    font_ranges_fn: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn) = null,
    font_ranges_ctx: ?*anyopaque = null,
    stack_mode: bool = false,

    unsupported_last_frame: usize = 0,
    path_draw_calls: u32 = 0,
    backdrop_luminance: ?f32 = null,

    pub fn setFontRangesProvider(self: *Painter, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        self.font_ranges_fn = provider;
        self.font_ranges_ctx = ctx;
        // Text layout and retained subtree pixels both depend on selection.
        if (zenit_d3d11_probe_clear_text(self.native) == 0) @panic("Windows font range cache reset failed");
    }

    pub fn setFonts(self: *Painter, fonts: ?*@import("render").FontSelector) void {
        self.fonts = fonts;
        if (zenit_d3d11_probe_clear_text(self.native) == 0) @panic("Windows text cache reset failed");
    }

    pub fn setDefaultFontFamily(self: *Painter, family: []const u8) !void {
        const terminated = try self.allocator.dupeSentinel(u8, family, 0);
        defer self.allocator.free(terminated);
        if (zenit_d3d11_probe_set_font_family(self.native, terminated.ptr) == 0) return error.FontFamilyConfigurationFailed;
    }

    pub fn setDefaultLocale(self: *Painter, locale: []const u8) !void {
        const terminated = try self.allocator.dupeSentinel(u8, locale, 0);
        defer self.allocator.free(terminated);
        if (zenit_d3d11_probe_set_font_locale(self.native, terminated.ptr) == 0) return error.FontLocaleConfigurationFailed;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, window: *platform.Window, clear: [4]f32) !Painter {
        if (zenit_d3d11_probe_item_size() != @sizeOf(PaintItem)) return error.PaintItemAbiMismatch;
        const native = zenit_d3d11_probe_create(window.getNativeSurfaceHandle()) orelse return error.D3D11Unavailable;
        errdefer zenit_d3d11_probe_destroy(native);
        zenit_d3d11_probe_retain_submitted(native, @intFromBool(@import("test_harness").enabled));
        if (zenit_d3d11_probe_items_supported(native) == 0) return error.Direct2DUnavailable;
        zenit_d3d11_probe_set_clear_color(native, clear[0], clear[1], clear[2], clear[3]);
        window.native_device = zenit_d3d11_probe_device(native) orelse return error.D3D11Unavailable;
        window.setRenderCallback(renderCallback, native);
        return .{ .io = io, .native = native, .image_renderer = .{ .native = native }, .allocator = allocator };
    }

    pub fn deinit(self: *Painter, window: *platform.Window) void {
        window.setRenderCallback(null, null);
        window.native_device = null;
        zenit_d3d11_probe_destroy(self.native);
    }

    pub fn captureBmp(self: *Painter, path: []const u8) !bool {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path);
        defer self.allocator.free(wide);
        return zenit_d3d11_probe_capture_bmp(self.native, wide.ptr) != 0;
    }

    pub fn refreshLuminance(self: *Painter, cx: *ui.Cx) bool {
        var samples: [12]Luminance = undefined;
        const sample_count = zenit_d3d11_probe_get_luminance(self.native, &samples, samples.len);
        var lum_sum: f32 = 0;
        var changed = cx.backdrop_luminance_region_count != sample_count;
        for (samples[0..sample_count], 0..) |sample, index| {
            if (index >= cx.backdrop_luminance_region_count or
                cx.backdrop_luminance_regions[index].node_id != sample.owner_id or
                @abs(cx.backdrop_luminance_regions[index].lum - sample.value) > 0.0001) changed = true;
            cx.backdrop_luminance_regions[index] = .{ .node_id = sample.owner_id, .lum = sample.value };
            lum_sum += sample.value;
        }
        cx.backdrop_luminance_region_count = sample_count;
        self.backdrop_luminance = if (sample_count > 0) lum_sum / @as(f32, @floatFromInt(sample_count)) else null;
        cx.backdrop_luminance = self.backdrop_luminance;
        return changed;
    }

    pub fn update(self: *Painter, cx: *ui.Cx, window: *platform.Window) !void {
        const started = try @import("zenit_time").Instant.now(self.io);
        _ = self.refreshLuminance(cx);
        // Match the shared AppRenderer frame contract. layout advances the
        // render epoch so editable-widget hooks refresh their borrowed text
        // and geometry before paint and accessibility projection consume it.
        cx.advanceFrameClock();
        cx.layout();
        const laid_out = try @import("zenit_time").Instant.now(self.io);
        _ = cx.render();
        @import("windows_accessibility.zig").publish(cx, window) catch |err| {
            @import("windows_accessibility.zig").clear(window);
            std.log.err("Windows accessibility projection: {s}", .{@errorName(err)});
        };
        const paint = cx.lowerForEncoderPaintTable();
        var retained_plan: @import("render").RetainedPlan = .{};
        retained_plan.compute(paint, window.getScaleFactor());
        // Film grain changes on every rendered frame. Do not reuse any
        // enclosing retained surface, including ancestors of nested layers.
        for (retained_plan.layers, 0..) |layer, index| {
            const end = layer.end orelse continue;
            for (paint[layer.begin + 1 .. end]) |item| {
                if (item.kind == .rect and item.noise_mode == 2 and item.noise_intensity > 0 and item.noise_scale > 0) {
                    retained_plan.retained_hashes[index] = 0;
                    break;
                }
            }
        }
        var native_damage: [1024]DamageItem = undefined;
        for (retained_plan.damage_scratch[0..retained_plan.damage_scratch_count], 0..) |entry, index|
            native_damage[index] = .{ .digest = entry.digest, .bounds = entry.bounds };
        var retained_seq: usize = 0;
        const generated = try @import("zenit_time").Instant.now(self.io);
        var items: std.ArrayList(PaintItem) = .empty;
        defer items.deinit(self.allocator);
        var font_ranges: std.ArrayList(*@import("text").FontRanges) = .empty;
        defer {
            for (font_ranges.items) |snapshot| {
                snapshot.deinit();
                self.allocator.destroy(snapshot);
            }
            font_ranges.deinit(self.allocator);
        }
        var paths: std.ArrayList([]PathPoint) = .empty;
        defer {
            for (paths.items) |points| self.allocator.free(points);
            paths.deinit(self.allocator);
        }
        var unsupported: usize = 0;
        var blur_owners: [64]u32 = undefined;
        var blur_owner_count: usize = 0;
        for (paint) |item| {
            switch (item.kind) {
                .image => {
                    const rep = item.icon_rep_ptr orelse {
                        if (item.geom.w <= 0 or item.geom.h <= 0 or item.image_opacity <= 0) continue;
                        if (item.resource_handle == 0 or item.resource_handle > std.math.maxInt(u32)) continue;
                        var bitmap = clipItem(15, item.geom, item.image_corner_radius);
                        bitmap.font_weight = @intCast(item.resource_handle);
                        bitmap.font_size = item.rotate;
                        bitmap.r = channel(item.image_tint.r);
                        bitmap.g = channel(item.image_tint.g);
                        bitmap.b = channel(item.image_tint.b);
                        bitmap.a = channel(item.image_tint.a) * item.image_opacity;
                        try items.append(self.allocator, bitmap);
                        continue;
                    };
                    if (rep.view_width <= 0 or rep.view_height <= 0 or item.geom.w <= 0 or item.geom.h <= 0 or item.image_opacity <= 0) continue;
                    // Match the shared icon mask: clip in pre-rotation local
                    // space and apply tint alpha/opacity once to all shapes.
                    const icon_alpha = channel(item.icon_tint.a) * item.image_opacity;
                    const icon_layer = item.icon_corner_clip_radius > 0 or icon_alpha < 0.999;

                    const sx = item.geom.w / rep.view_width;
                    const sy = item.geom.h / rep.view_height;
                    const center_x = item.geom.x + item.geom.w / 2;
                    const center_y = item.geom.y + item.geom.h / 2;
                    const cs = @cos(item.rotate);
                    const sn = @sin(item.rotate);
                    if (icon_layer) {
                        var layer = clipItem(13, item.geom, item.icon_corner_clip_radius);
                        layer.x = cs;
                        layer.y = sn;
                        layer.w = -sn;
                        layer.h = cs;
                        layer.r = center_x - cs * center_x + sn * center_y;
                        layer.g = center_y - sn * center_x - cs * center_y;
                        layer.a = icon_alpha;
                        layer.font_weight = 1;
                        layer.to_r = item.geom.x;
                        layer.to_g = item.geom.y;
                        layer.to_b = item.geom.w;
                        layer.to_a = item.geom.h;
                        try items.append(self.allocator, layer);
                    }
                    for (rep.shapes) |shape| {
                        if (!shape.fill and shape.stroke_width <= 0) continue;
                        var points: std.ArrayList(PathPoint) = .empty;
                        defer points.deinit(self.allocator);
                        for (shape.contours) |contour| {
                            for (contour.points, 0..) |point, index| {
                                const px = (point.x - rep.view_min_x) * sx - item.geom.w / 2;
                                const py = (point.y - rep.view_min_y) * sy - item.geom.h / 2;
                                try points.append(self.allocator, .{
                                    .x = if (icon_layer) center_x + px else center_x + px * cs - py * sn,
                                    .y = if (icon_layer) center_y + py else center_y + px * sn + py * cs,
                                    .verb = if (index == 0) 0 else 1,
                                });
                            }
                            if (contour.closed and contour.points.len > 0) try points.append(self.allocator, .{ .x = 0, .y = 0, .verb = 2 });
                        }
                        if (points.items.len == 0) continue;
                        const owned = try points.toOwnedSlice(self.allocator);
                        paths.append(self.allocator, owned) catch |err| {
                            self.allocator.free(owned);
                            return err;
                        };
                        const bytes = std.mem.sliceAsBytes(owned);
                        if (bytes.len > std.math.maxInt(u32)) return error.PathTooLarge;
                        var path = clipItem(if (shape.fill) 12 else 11, item.geom, 0);
                        path.r = channel(item.icon_tint.r);
                        path.g = channel(item.icon_tint.g);
                        path.b = channel(item.icon_tint.b);
                        path.a = if (icon_layer) 1 else icon_alpha;
                        path.stroke_width = shape.stroke_width * @min(sx, sy);
                        path.gradient_direction = if (shape.fill_rule == .evenodd) 1 else 0;
                        path.text = bytes.ptr;
                        path.text_length = @intCast(bytes.len);
                        try items.append(self.allocator, path);
                        if (shape.fill and shape.stroke_width > 0) {
                            path.kind = 11;
                            try items.append(self.allocator, path);
                        }
                    }
                    if (icon_layer) try items.append(self.allocator, clipItem(14, item.geom, 0));
                },
                .rect => {
                    if (item.shape_kind > 1 or (item.noise_intensity > 0 and item.noise_mode > 2)) {
                        unsupported += 1;
                        continue;
                    }
                    try items.append(self.allocator, .{
                        .kind = if (item.noise_intensity > 0) 22 else if (item.shape_kind == 1)
                            (if (item.stroke_width > 0) @as(u32, 8) else 6)
                        else
                            (if (item.stroke_width > 0) @as(u32, 7) else 1),
                        .x = item.geom.x,
                        .y = item.geom.y,
                        .w = item.geom.w,
                        .h = item.geom.h,
                        .r = channel(item.color.r),
                        .g = channel(item.color.g),
                        .b = channel(item.color.b),
                        .a = channel(item.color.a),
                        .radius = @min(item.radii.tl, @min(item.radii.tr, @min(item.radii.br, item.radii.bl))),
                        .font_size = 0,
                        .font_weight = 0,
                        .text = null,
                        .text_length = 0,
                        .to_r = 0,
                        .to_g = 0,
                        .to_b = 0,
                        .to_a = 0,
                        .gradient_direction = 0,
                        .stroke_width = item.stroke_width,
                        .shadow_radii = radiiArray(item.radii),
                        .noise = .{ .mode = item.noise_mode, .seed = item.noise_seed, .scale = item.noise_scale, .intensity = item.noise_intensity },
                    });
                },
                .shadow => {
                    if (item.geom.w <= 0 or item.geom.h <= 0) continue;
                    if (item.shadow2_color.a > 0) {
                        try items.append(self.allocator, shadowItem(item, item.shadow_secondary_color, item.shadow_blur, item.shadow_offset_x, item.shadow_offset_y, 0, false));
                        try items.append(self.allocator, shadowItem(item, item.shadow2_color, item.shadow2_blur, item.shadow2_offset_x, item.shadow2_offset_y, 0, false));
                    } else if (item.shadow_secondary_color.a == 0) {
                        try items.append(self.allocator, shadowItem(item, item.color, item.shadow_blur, item.shadow_offset_x, item.shadow_offset_y, item.shadow_spread, false));
                        continue;
                    }
                    if (item.color.a > 0) {
                        var fill = clipItem(1, item.geom, @min(item.radii.tl, @min(item.radii.tr, @min(item.radii.br, item.radii.bl))));
                        fill.r = channel(item.color.r);
                        fill.g = channel(item.color.g);
                        fill.b = channel(item.color.b);
                        fill.a = channel(item.color.a);
                        fill.shadow_radii = radiiArray(item.radii);
                        try items.append(self.allocator, fill);
                    }
                    if (item.shadow2_color.a == 0 and item.shadow_secondary_color.a > 0)
                        try items.append(self.allocator, shadowItem(item, item.shadow_secondary_color, item.shadow_blur, item.shadow_offset_x, item.shadow_offset_y, 0, true));
                },
                .text => {
                    if (item.text_content.len == 0) continue;
                    if (item.text_content.len > std.math.maxInt(u32)) return error.TextTooLong;
                    const font = if (self.fonts) |fonts| fonts.resolveFonts(item.text_content, .{
                        .stack_mode_override = if (self.stack_mode) true else null,
                        .font_size = item.text_font_size,
                        .font_weight = item.text_font_weight,
                        .font_family = item.text_font_family,
                        .use_italic = item.text_font_flags & 1 != 0,
                        .use_monospace = item.text_font_flags & 2 != 0,
                        .use_symbols = item.text_font_flags & 4 != 0,
                    }).shapingFont() else null;
                    var snapshot: ?*@import("text").FontRanges = null;
                    if (self.font_ranges_fn) |provider| {
                        const ctx = self.font_ranges_ctx orelse return error.MissingFontRangesContext;
                        const source_font = font orelse return error.MissingFontSelector;
                        snapshot = try provider(ctx, .{
                            .text = item.text_content,
                            .font_family = "system",
                            .font_family_id = item.text_font_family,
                            .font_size = item.text_font_size,
                            .font_weight = item.text_font_weight,
                            .use_italic = item.text_font_flags & 1 != 0,
                            .use_monospace = item.text_font_flags & 2 != 0,
                            .use_symbols = item.text_font_flags & 4 != 0,
                        }, source_font, self.allocator);
                        if (snapshot) |owned| {
                            font_ranges.append(self.allocator, owned) catch |err| {
                                owned.deinit();
                                self.allocator.destroy(owned);
                                return err;
                            };
                            try owned.validateText(item.text_content);
                        }
                    }
                    try items.append(self.allocator, .{
                        .kind = 2,
                        .font_ref = if (font) |f| f.native else null,
                        .font_ranges = if (snapshot) |r| r.native else null,
                        .italic = if (item.text_font_flags & 1 != 0) 1 else 0,
                        .fixed_ascii_advance = fixedAsciiAdvance(item),
                        .x = item.geom.x,
                        .y = item.geom.y,
                        .w = 0,
                        .h = 0,
                        .r = channel(item.color.r),
                        .g = channel(item.color.g),
                        .b = channel(item.color.b),
                        .a = channel(item.color.a),
                        .radius = 0,
                        .font_size = item.text_font_size,
                        .font_weight = item.text_font_weight,
                        .text = item.text_content.ptr,
                        .text_length = @intCast(item.text_content.len),
                        .to_r = 0,
                        .to_g = 0,
                        .to_b = 0,
                        .to_a = 0,
                        .gradient_direction = 0,
                        .stroke_width = 0,
                    });
                },
                .gradient => {
                    if (item.gradient_direction > 4 or item.gradient_extend_mode > 2 or item.shape_kind > 1) {
                        unsupported += 1;
                        continue;
                    }
                    try items.append(self.allocator, .{
                        .kind = 5,
                        .gradient = gradientInfo(item),
                        .x = item.geom.x,
                        .y = item.geom.y,
                        .w = item.geom.w,
                        .h = item.geom.h,
                        .r = channel(item.color.r),
                        .g = channel(item.color.g),
                        .b = channel(item.color.b),
                        .a = channel(item.color.a),
                        .radius = @min(item.radii.tl, @min(item.radii.tr, @min(item.radii.br, item.radii.bl))),
                        .font_size = 0,
                        .font_weight = 0,
                        .text = null,
                        .text_length = 0,
                        .to_r = channel(item.gradient_to_color.r),
                        .to_g = channel(item.gradient_to_color.g),
                        .to_b = channel(item.gradient_to_color.b),
                        .to_a = channel(item.gradient_to_color.a),
                        .gradient_direction = item.gradient_direction,
                        .stroke_width = 0,
                        .shadow_radii = radiiArray(item.radii),
                    });
                },
                .control => switch (item.control_kind) {
                    .begin_blur_layer => {
                        const glass = item.glass_ptr orelse continue;
                        if (item.geom.w <= 0 or item.geom.h <= 0) continue;
                        if (item.glass_owner_id != std.math.maxInt(u32)) {
                            var seen = false;
                            for (blur_owners[0..blur_owner_count]) |owner| {
                                if (owner == item.glass_owner_id) {
                                    seen = true;
                                    break;
                                }
                            }
                            if (seen) continue;
                            if (blur_owner_count < blur_owners.len) {
                                blur_owners[blur_owner_count] = item.glass_owner_id;
                                blur_owner_count += 1;
                            }
                        }
                        if (!item.use_draw_transform and item.rotate != 0) unsupported += 1;
                        // The glass shape fits its corners to the glass rect like the shared
                        // encoder (render backdrop_blur.shapeRadii): oversized, +inf, negative and
                        // NaN radii resolve the same way, single-radius shapes take one corner.
                        const glass_radii = render.backdrop_blur.shapeRadii(.{ .corner_radii = radiiArray(item.radii), .arrow = glass.arrow, .tab_lens = glass.tab_lens }, 1, item.geom.w, item.geom.h);
                        var blur = clipItem(21, item.geom, glass_radii[0]);
                        blur.shadow_radii = glass_radii;
                        const sx = if (!std.math.isNan(item.draw_w) and item.geom.w > 0) item.draw_w / item.geom.w else 1;
                        const sy = if (!std.math.isNan(item.draw_h) and item.geom.h > 0) item.draw_h / item.geom.h else 1;
                        var matrix: [6]f32 = if (item.use_draw_transform) item.draw_transform else .{
                            sx,                                                            0,                                                             0, sy,
                            if (std.math.isNan(item.draw_x)) item.geom.x else item.draw_x, if (std.math.isNan(item.draw_y)) item.geom.y else item.draw_y,
                        };
                        matrix[4] -= matrix[0] * item.geom.x + matrix[2] * item.geom.y;
                        matrix[5] -= matrix[1] * item.geom.x + matrix[3] * item.geom.y;
                        blur.backdrop = .{
                            .owner_id = item.glass_owner_id,
                            .tint = glass.glass_tint,
                            .thickness = glass.center_thickness,
                            .optic = .{ glass.glass_intensity, glass.warp_gain, glass.backdrop_distance, 0 },
                            .specular = .{ glass.specular_opacity, glass.specular_saturation, glass.refraction_level, 0 },
                            .surface = .{ @floatFromInt(@backingInt(glass.surface)), glass.bezel_width, glass.specular_angle, glass.magnification },
                            .bottom = .{ @floatFromInt(@backingInt(glass.bottom_surface)), glass.bottom_bezel_width, 0, 0 },
                            .lens = .{ glass.center_zoom_radius, glass.center_zoom_falloff, glass.edge_field_strength, glass.scale_ratio },
                            .radii = glass_radii,
                            .radius = glass.backdrop_blur,
                            .level = glass.blur_level,
                            .saturation = glass.backdrop_saturation,
                            .brightness = glass.backdrop_brightness,
                            .direction = glass.blur_gradient_direction,
                            .count = glass.blur_gradient_stop_count,
                            .strength = glass.blur_gradient_strength,
                            .positions = glass.blur_gradient_stop_pos,
                            .strengths = glass.blur_gradient_stop_str,
                            .matrix = matrix,
                        };
                        try items.append(self.allocator, blur);
                    },
                    .end_blur_layer => {},
                    .begin_opacity_layer, .begin_rounded_clip => {
                        if (!item.use_draw_transform and item.rotate != 0) unsupported += 1;
                        const sx = if (!std.math.isNan(item.draw_w) and item.geom.w > 0) item.draw_w / item.geom.w else 1;
                        const sy = if (!std.math.isNan(item.draw_h) and item.geom.h > 0) item.draw_h / item.geom.h else 1;
                        const matrix: [6]f32 = if (item.use_draw_transform) item.draw_transform else .{
                            sx,                                                            0,                                                             0, sy,
                            if (std.math.isNan(item.draw_x)) item.geom.x else item.draw_x, if (std.math.isNan(item.draw_y)) item.geom.y else item.draw_y,
                        };
                        var layer = clipItem(13, item.geom, 0);
                        if (item.control_kind == .begin_opacity_layer) {
                            if (retained_seq < retained_plan.retained_hashes.len) {
                                const range = retained_plan.damage_ranges[retained_seq];
                                layer.retained = .{
                                    .id = item.surface_stable_id,
                                    .hash = retained_plan.retained_hashes[retained_seq],
                                    .count = if (range.captured and range.safe and !range.overflow and range.len <= 128) range.len else 0,
                                    .damage = if (range.captured and range.safe and !range.overflow and range.len <= 128) native_damage[range.start..].ptr else null,
                                    .safe = if (range.captured and range.safe and !range.overflow and range.len <= 128) 1 else 0,
                                };
                            }
                            retained_seq += 1;
                        }
                        // Transform the source coordinates around the capture origin.
                        // Reuse fields for the six affine coefficients; this
                        // private command has no rectangle/color payload.
                        layer.x = matrix[0];
                        layer.y = matrix[1];
                        layer.w = matrix[2];
                        layer.h = matrix[3];
                        layer.r = matrix[4] - matrix[0] * item.geom.x - matrix[2] * item.geom.y;
                        layer.g = matrix[5] - matrix[1] * item.geom.x - matrix[3] * item.geom.y;
                        layer.a = if (item.control_kind == .begin_opacity_layer) std.math.clamp(item.opacity, 0, 1) else 1;
                        layer.gradient_direction = item.blend_mode;
                        layer.font_weight = if (item.control_kind == .begin_rounded_clip) 1 else 0;
                        layer.radius = item.radii.tl;
                        layer.shadow_radii = radiiArray(item.radii);
                        layer.to_r = item.geom.x;
                        layer.to_g = item.geom.y;
                        layer.to_b = item.geom.w;
                        layer.to_a = item.geom.h;
                        try items.append(self.allocator, layer);
                    },
                    .end_opacity_layer, .end_rounded_clip => try items.append(self.allocator, clipItem(14, item.geom, 0)),
                    .push_clip => {
                        if (item.clip_shape_kind == 3) {
                            const polygon = item.clip_polygon_ptr orelse return error.MissingClipPolygon;
                            if (polygon.point_count < 3 or polygon.point_count > polygon.points.len or
                                polygon.contour_count > polygon.contour_end_points.len) return error.InvalidClipPolygon;
                            var points: std.ArrayList(PathPoint) = .empty;
                            defer points.deinit(self.allocator);
                            var start: usize = 0;
                            const contours: usize = if (polygon.contour_count == 0) 1 else polygon.contour_count;
                            for (0..contours) |contour| {
                                const end: usize = if (polygon.contour_count == 0) polygon.point_count else polygon.contour_end_points[contour];
                                if (end > polygon.point_count or end < start + 3) return error.InvalidClipPolygon;
                                for (start..end) |index| {
                                    const point = polygon.points[index];
                                    if (!std.math.isFinite(point[0]) or !std.math.isFinite(point[1])) return error.InvalidClipPolygon;
                                    try points.append(self.allocator, .{ .x = point[0] + item.geom.x, .y = point[1] + item.geom.y, .verb = if (index == start) 0 else 1 });
                                }
                                try points.append(self.allocator, .{ .x = 0, .y = 0, .verb = 2 });
                                start = end;
                            }
                            if (start != polygon.point_count) return error.InvalidClipPolygon;
                            const owned = try points.toOwnedSlice(self.allocator);
                            paths.append(self.allocator, owned) catch |err| {
                                self.allocator.free(owned);
                                return err;
                            };
                            const bytes = std.mem.sliceAsBytes(owned);
                            var clip = clipItem(23, item.geom, 0);
                            clip.gradient_direction = if (polygon.fill_rule == .evenodd) 1 else 0;
                            clip.text = bytes.ptr;
                            clip.text_length = @intCast(bytes.len);
                            try items.append(self.allocator, clip);
                            continue;
                        }
                        const kind: u32 = switch (item.clip_shape_kind) {
                            0 => 3,
                            1 => 9,
                            2 => 10,
                            else => blk: {
                                unsupported += 1;
                                break :blk 3;
                            },
                        };
                        var clip = clipItem(kind, item.geom, item.radii.tl);
                        clip.shadow_radii = radiiArray(item.radii);
                        try items.append(self.allocator, clip);
                    },
                    .pop_clip => try items.append(self.allocator, clipItem(4, item.geom, 0)),
                    else => unsupported += 1,
                },
                .path => {
                    if (item.path_geometry_ptr) |geometry| {
                        const path_gradient = item.mg_stop_count > 0 and item.gradient_direction != 0;
                        if (path_gradient and item.gradient_direction > 5) unsupported += 1;
                        var points: std.ArrayList(PathPoint) = .empty;
                        defer points.deinit(self.allocator);
                        for (geometry.commands) |command| switch (command) {
                            .move_to => |p| try points.append(self.allocator, .{ .x = p.x + item.geom.x, .y = p.y + item.geom.y, .verb = 0 }),
                            .line_to => |p| try points.append(self.allocator, .{ .x = p.x + item.geom.x, .y = p.y + item.geom.y, .verb = 1 }),
                            .quad_to => |q| {
                                try points.append(self.allocator, .{ .x = q.ctrl.x + item.geom.x, .y = q.ctrl.y + item.geom.y, .verb = 10 });
                                try points.append(self.allocator, .{ .x = q.end.x + item.geom.x, .y = q.end.y + item.geom.y, .verb = 1 });
                            },
                            .cubic_to => |c| {
                                try points.append(self.allocator, .{ .x = c.ctrl1.x + item.geom.x, .y = c.ctrl1.y + item.geom.y, .verb = 11 });
                                try points.append(self.allocator, .{ .x = c.ctrl2.x + item.geom.x, .y = c.ctrl2.y + item.geom.y, .verb = 1 });
                                try points.append(self.allocator, .{ .x = c.end.x + item.geom.x, .y = c.end.y + item.geom.y, .verb = 1 });
                            },
                            .close => try points.append(self.allocator, .{ .x = 0, .y = 0, .verb = 2 }),
                        };
                        if (points.items.len == 0) continue;
                        const owned = try points.toOwnedSlice(self.allocator);
                        paths.append(self.allocator, owned) catch |err| {
                            self.allocator.free(owned);
                            return err;
                        };
                        const bytes = std.mem.sliceAsBytes(owned);
                        if (bytes.len > std.math.maxInt(u32)) return error.PathTooLarge;
                        var path = clipItem(if (item.stroke_width > 0) 20 else 19, item.geom, 0);
                        path.r = channel(item.color.r);
                        path.g = channel(item.color.g);
                        path.b = channel(item.color.b);
                        path.a = channel(item.color.a) * item.image_opacity;
                        path.stroke_width = item.stroke_width;
                        path.font_weight = item.path_line_join;
                        path.gradient_direction = if (geometry.fill_rule == .evenodd) 1 else 0;
                        if (path_gradient and item.gradient_direction <= 5) {
                            path.gradient = gradientInfo(item);
                            // Path directions use SDF numbering (1 vertical,
                            // 2 horizontal, 3 diagonal, 4 radial); rectangle
                            // directions use the public GradientDirection enum.
                            path.gradient.direction = switch (item.gradient_direction) {
                                1 => 1,
                                2 => 0,
                                3 => 2,
                                4 => 3,
                                5 => 4,
                                else => unreachable,
                            };
                            path.gradient.center = .{ item.gradient_radial_center_x, item.gradient_radial_center_y };
                            path.gradient.conic_phase = 0;
                            path.gradient.radius = .{ 0.5, 0.5 };
                            path.a = item.image_opacity;
                        }
                        path.text = bytes.ptr;
                        path.text_length = @intCast(bytes.len);
                        try items.append(self.allocator, path);
                        continue;
                    }
                    if (item.arc_outer_radius <= 0 or item.stroke_width <= 0 or item.arc_end_angle <= item.arc_start_angle) continue;
                    var arc = clipItem(18, item.geom, item.arc_outer_radius);
                    arc.r = channel(item.color.r);
                    arc.g = channel(item.color.g);
                    arc.b = channel(item.color.b);
                    arc.a = channel(item.color.a);
                    arc.stroke_width = item.stroke_width;
                    arc.to_r = item.arc_start_angle;
                    arc.to_g = item.arc_end_angle;
                    try items.append(self.allocator, arc);
                },
                .none => {},
            }
        }
        if (zenit_d3d11_probe_set_items(self.native, items.items.ptr, @intCast(items.items.len), window.getScaleFactor()) == 0)
            return error.PaintUploadFailed;
        if (unsupported > 0 and unsupported != self.unsupported_last_frame)
            std.log.warn("Windows renderer skipped or approximated {d} of {d} paint items", .{ unsupported, paint.len });
        self.unsupported_last_frame = unsupported;
        const encoded = try @import("zenit_time").Instant.now(self.io);
        zenit_d3d11_probe_set_cpu_timing(self.native, laid_out.since(started) / 1000, generated.since(laid_out) / 1000, encoded.since(generated) / 1000);
        // Present the commands generated by this frame immediately. Deferring
        // to WM_PAINT presented the previous commands while handling input and
        // added a message-pump wait on top of the swap chain's vsync wait.
        if (zenit_d3d11_probe_render(self.native) == 0) return error.PaintPresentFailed;
        @import("test_harness").observeSubmittedFrame(cx);
        self.path_draw_calls = 0;
        for (items.items) |item| if (item.kind == 19 or item.kind == 20) {
            self.path_draw_calls += 1;
        };
    }

    pub fn resetTiming(self: *Painter) void {
        zenit_d3d11_probe_reset_timing(self.native);
    }

    pub fn timingStats(self: *Painter) TimingStats {
        var result: TimingStats = .{};
        zenit_d3d11_probe_get_timing(self.native, &result);
        return result;
    }

    pub fn retainedStats(self: *Painter) RetainedStats {
        var result: RetainedStats = .{};
        zenit_d3d11_probe_get_retained(self.native, &result);
        return result;
    }

    pub fn setRetainedEnabled(self: *Painter, enabled: bool) void {
        zenit_d3d11_probe_set_retained_enabled(self.native, if (enabled) 1 else 0);
    }
};

fn shadowItem(item: anytype, color: anytype, blur: f32, offset_x: f32, offset_y: f32, spread: f32, inset: bool) PaintItem {
    var result = clipItem(if (inset) 17 else 16, item.geom, 0);
    result.r = channel(color.r);
    result.g = channel(color.g);
    result.b = channel(color.b);
    result.a = channel(color.a);
    result.shadow_radii = .{ item.radii.tl, item.radii.tr, item.radii.br, item.radii.bl };
    result.shadow_blur = blur;
    result.shadow_offset_x = offset_x;
    result.shadow_offset_y = offset_y;
    result.shadow_spread = spread;
    return result;
}

fn fixedAsciiAdvance(item: anytype) f32 {
    const advance = item.text_monospace_char_width;
    if (item.text_font_flags & 2 == 0 or !std.math.isFinite(advance) or advance <= 0) return 0;
    for (item.text_content) |byte| if (byte >= 128) return 0;
    return advance;
}

fn channel(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255;
}

fn radiiArray(radii: anytype) [4]f32 {
    return .{ radii.tl, radii.tr, radii.br, radii.bl };
}

fn clipItem(kind: u32, geom: anytype, radius: f32) PaintItem {
    return .{
        .kind = kind,
        .x = geom.x,
        .y = geom.y,
        .w = geom.w,
        .h = geom.h,
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0,
        .radius = radius,
        .font_size = 0,
        .font_weight = 0,
        .text = null,
        .text_length = 0,
        .to_r = 0,
        .to_g = 0,
        .to_b = 0,
        .to_a = 0,
        .gradient_direction = 0,
        .stroke_width = 0,
    };
}

fn renderCallback(ctx: ?*anyopaque) callconv(.c) void {
    if (ctx) |native| _ = zenit_d3d11_probe_render(native);
}
