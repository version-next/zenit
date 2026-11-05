//! text_ink containment oracle (live Metal device: the glyph atlas and CoreText).
//!
//! For each case, the encoder's own `.text` arm (RenderCommandEncoder.encodeTextCommand) draws
//! the command into the TextRenderer; the union of glyphQuad over the instances it emitted is
//! what the GPU (and cpu_flat) paints. text_ink.Cache.bounds must contain it, and should be
//! that union padded by exactly one device pixel (the probe runs the same emit code).
const std = @import("std");
const gpu = @import("gpu");
const text = @import("text");
const text_renderer_mod = @import("text_renderer.zig");
const RenderCommandEncoder = @import("command_encoder.zig").RenderCommandEncoder;
const FontSelector = @import("command_encoder/font_selector.zig").FontSelector;
const paint_fp = @import("command_encoder/paint_fingerprint.zig");
const text_ink = @import("text_ink.zig");
const a = std.testing.allocator;

const Span = struct { start: u32, end: u32, color: ?Color = null };
const Color = extern struct { r: u8 = 20, g: u8 = 20, b: u8 = 20, a: u8 = 255 };
const Item = struct {
    kind: enum { text, rect, control } = .text,
    geom: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = .{},
    color: Color = .{},
    rotate: f32 = 0,
    use_draw_transform: bool = false,
    stroke_width: f32 = 0,
    shadow_blur: f32 = 0,
    shadow_offset_x: f32 = 0,
    shadow_offset_y: f32 = 0,
    shadow_spread: f32 = 0,
    shadow2_blur: f32 = 0,
    shadow2_offset_x: f32 = 0,
    shadow2_offset_y: f32 = 0,
    text_content: []const u8 = "",
    text_font_size: f32 = 13,
    text_font_weight: u16 = 400,
    text_font_family: u16 = 0,
    text_font_flags: u8 = 0,
    text_monospace_char_width: f32 = 0,
    text_raster_policy: u8 = 0,
    text_fade_dx0: f32 = 0,
    text_fade_dx1: f32 = 0,
    text_spans: ?[]const Span = null,
};

const Fixture = struct {
    device: gpu.Backend.Device,
    queue: gpu.Backend.Queue,
    adapter: gpu.Backend.Adapter,
    instance: gpu.Backend.Instance,
    tr: text_renderer_mod.TextRenderer,
    fs: text.FontSystem,
    fonts: [5]*text.Font,
    selector: FontSelector,
    cache: text_ink.Cache = .{},

    fn init(self: *Fixture) !void {
        self.cache = .{};
        self.instance = try gpu.Backend.Instance.init(a, .{});
        errdefer self.instance.deinit();
        const adapters = try self.instance.enumerateAdapters();
        defer a.free(adapters);
        if (adapters.len == 0) return error.MetalAdapterUnavailable;
        self.adapter = adapters[0];
        errdefer self.adapter.deinit();
        const dq = try self.adapter.requestDevice(a, .{});
        self.device = dq.device;
        self.queue = dq.queue;
        self.tr = try text_renderer_mod.TextRenderer.init(a, &self.device);
        self.fs = try text.FontSystem.init(a, std.testing.io);
        self.fonts = .{
            try self.fs.findFont(.{ .family = "Helvetica", .size = 12 }),
            try self.fs.findFont(.{ .family = "Helvetica", .size = 14 }),
            try self.fs.findFont(.{ .family = "Helvetica", .size = 16 }),
            try self.fs.findFont(.{ .family = "Helvetica", .size = 14, .weight = .bold }),
            try self.fs.findFont(.{ .family = "Menlo", .size = 14 }),
        };
        self.selector = .{ .small = self.fonts[0], .medium = self.fonts[1], .large = self.fonts[2] };
        self.selector.bold_fonts[0] = self.fonts[3];
        self.selector.bold_count = 1;
        self.selector.mono_fonts[0] = self.fonts[4];
        self.selector.mono_count = 1;
        self.selector.initDerivedCache(a);
    }

    fn deinit(self: *Fixture) void {
        self.cache.deinit(a);
        self.selector.deinitDerivedCache();
        // Fallback wrappers held by the renderer reference the fonts.
        self.tr.deinit();
        for (self.fonts) |f| f.deinit();
        self.fs.deinit();
        self.device.deinit();
        self.queue.deinit();
        self.adapter.deinit();
        self.instance.deinit();
    }

    /// What the encoder's text arm emits for `it` at `scale` (union of glyph quads, x0 y0 x1 y1),
    /// null when it emitted nothing.
    fn drawn(self: *Fixture, it: Item, scale: f32) !?[4]f32 {
        self.tr.beginFrame(4000, 2000, scale);
        var encoder = RenderCommandEncoder{
            .sdf_renderer = undefined,
            .text_renderer = &self.tr,
            .offscreen_pool = undefined,
            .persistent = undefined,
            .fonts = &self.selector,
        };
        try encoder.encodeTextCommand(it, 0, 0);
        var u: ?[4]f32 = null;
        for ([_][]const @TypeOf(self.tr.instances_nearest.items[0]){ self.tr.instances_nearest.items, self.tr.instances_linear.items }) |list| for (list) |*g| {
            const q = text_ink.glyphQuad(g);
            u = if (u) |r| .{ @min(r[0], q[0]), @min(r[1], q[1]), @max(r[2], q[2]), @max(r[3], q[3]) } else q;
        };
        return u;
    }
};

fn contains(outer: [4]f32, inner: [4]f32) bool {
    return outer[0] <= inner[0] and outer[1] <= inner[1] and outer[0] + outer[2] >= inner[2] and outer[1] + outer[3] >= inner[3];
}

const strings = [_][]const u8{
    "Hello, World",
    "0123456789 -+=",
    "!@#$%^&*()_{}|:\"<>?/\\`~",
    "gjpqy QÅÉ fiffl Wy",
    "中文字符测试，标点。",
    "日本語のテキスト 한국어",
    "emoji 😀👍🏽🇯🇵",
    "e\u{301} n\u{303} a\u{308}\u{323} Z\u{336}",
    "مرحبا بالعالم",
    "    status: Ln 42, Col 7  UTF-8",
};

test "text ink contains every glyph quad the encoder emits and is tight" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const Variant = struct { size: f32, weight: u16 = 400, flags: u8 = 0, mono: f32 = 0, policy: u8 = 0, spans: bool = false };
    const variants = [_]Variant{
        .{ .size = 13 },
        .{ .size = 9 },
        .{ .size = 16.5 },
        .{ .size = 24 },
        .{ .size = 14, .weight = 700 },
        .{ .size = 13, .flags = 1 }, // synthetic italic (no italic face)
        .{ .size = 13, .flags = 2, .mono = 7.83 }, // monospace grid
        .{ .size = 13, .flags = 2 | 1, .mono = 7.83 },
        .{ .size = 13, .flags = 8 }, // no font smoothing
        .{ .size = 13, .policy = 1 }, // direct_animated: linear, unsnapped
        .{ .size = 13, .policy = 2 }, // surface_cached
        .{ .size = 13, .spans = true },
        .{ .size = 13, .weight = 700, .spans = true, .flags = 1 },
    };
    const origins = [_][2]f32{ .{ 10, 40 }, .{ 10.25, 40.5 }, .{ 33.7, 57.33 }, .{ 800, 577.4 } };
    const scales = [_]f32{ 1, 2, 1.5 };
    var cases: usize = 0;
    var tighter: usize = 0;
    for (scales) |scale| for (variants) |v| for (strings) |s| for (origins) |o| {
        const spans = [_]Span{ .{ .start = 0, .end = 3, .color = .{ .r = 200 } }, .{ .start = 3, .end = @intCast(s.len) } };
        const it: Item = .{
            .geom = .{ .x = o[0], .y = o[1] },
            .text_content = s,
            .text_font_size = v.size,
            .text_font_weight = v.weight,
            .text_font_flags = v.flags,
            .text_monospace_char_width = v.mono,
            .text_raster_policy = v.policy,
            .text_spans = if (v.spans) &spans else null,
        };
        const drawn = (try fx.drawn(it, scale)) orelse continue;
        const ink = fx.cache.bounds(a, &fx.tr, &fx.selector, it, scale) orelse {
            std.debug.print("unknown ink: \"{s}\" size={d} flags={d} scale={d}\n", .{ s, v.size, v.flags, scale });
            return error.TestUnexpectedResult;
        };
        if (!contains(ink, drawn)) {
            std.debug.print("ink {any} misses drawn {any}: \"{s}\" size={d} weight={d} flags={d} policy={d} scale={d} origin={any}\n", .{ ink, drawn, s, v.size, v.weight, v.flags, v.policy, scale, o });
            return error.TestUnexpectedResult;
        }
        // Exact: the drawn union padded by one device pixel, nothing more.
        const pad = 1 / scale;
        const eps = 1e-3;
        try std.testing.expectApproxEqAbs(drawn[0] - pad, ink[0], eps);
        try std.testing.expectApproxEqAbs(drawn[1] - pad, ink[1], eps);
        try std.testing.expectApproxEqAbs(drawn[2] + pad, ink[0] + ink[2], eps);
        try std.testing.expectApproxEqAbs(drawn[3] + pad, ink[1] + ink[3], eps);
        // Strictly tighter vertically than the generic envelope.
        const envelope = paint_fp.damageItemBounds(it);
        try std.testing.expect(ink[1] >= envelope[1] and ink[1] + ink[3] <= envelope[1] + envelope[3]);
        if (ink[3] < envelope[3]) tighter += 1;
        cases += 1;
    };
    try std.testing.expect(cases >= strings.len * variants.len * origins.len * scales.len - 8);
    try std.testing.expectEqual(cases, tighter);
}

test "cached text ink stays a superset when the item moves by whole device pixels" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for ([_]f32{ 1, 2, 1.5 }) |scale| for (strings) |s| for ([_]u8{ 0, 1, 2 }) |policy| {
        var it: Item = .{ .geom = .{ .x = 12.3, .y = 30.6 }, .text_content = s, .text_raster_policy = policy };
        _ = try fx.drawn(it, scale);
        _ = fx.cache.bounds(a, &fx.tr, &fx.selector, it, scale) orelse return error.TestUnexpectedResult;
        const probes = fx.cache.probes;
        // Same device-pixel phase, many offsets (incl. ones crossing f32 rounding).
        var k: f32 = 1;
        while (k < 4000) : (k = k * 1.7 + 3) {
            const dx = @round(k) / scale;
            const dy = @round(k * 0.37) / scale;
            it.geom = .{ .x = 12.3 + dx, .y = 30.6 + dy };
            const drawn = (try fx.drawn(it, scale)) orelse continue;
            const ink = fx.cache.bounds(a, &fx.tr, &fx.selector, it, scale) orelse return error.TestUnexpectedResult;
            if (!contains(ink, drawn)) {
                std.debug.print("moved ink {any} misses drawn {any}: \"{s}\" policy={d} scale={d} at {d},{d}\n", .{ ink, drawn, s, policy, scale, it.geom.x, it.geom.y });
                return error.TestUnexpectedResult;
            }
        }
        // Integer-pixel moves reuse the entry instead of probing again (policy 1 is unsnapped,
        // same phase still).
        try std.testing.expectEqual(probes, fx.cache.probes);
    };
}

test "text ink is unknown until the glyphs are resident, and empty text has none" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const it: Item = .{ .geom = .{ .x = 5, .y = 50 }, .text_content = "never drawn ꙮ", .text_font_size = 41.3 };
    fx.tr.beginFrame(4000, 2000, 2);
    try std.testing.expect(fx.cache.bounds(a, &fx.tr, &fx.selector, it, 2) == null);
    // The probe rasterized nothing: still unknown, and nothing pending.
    try std.testing.expect(fx.cache.bounds(a, &fx.tr, &fx.selector, it, 2) == null);
    try std.testing.expectEqual(@as(usize, 0), fx.tr.instances_nearest.items.len + fx.tr.instances_linear.items.len);
    const drawn = (try fx.drawn(it, 2)).?;
    const ink = fx.cache.bounds(a, &fx.tr, &fx.selector, it, 2).?;
    try std.testing.expect(contains(ink, drawn));
    // Spaces only: no glyph ink.
    _ = try fx.drawn(.{ .geom = .{ .x = 5, .y = 50 }, .text_content = "   " }, 2);
    const blank = fx.cache.bounds(a, &fx.tr, &fx.selector, Item{ .geom = .{ .x = 5, .y = 50 }, .text_content = "   " }, 2).?;
    try std.testing.expect(blank[2] == 0 and blank[3] == 0);
    // Not plain text: the caller keeps the conservative bound.
    try std.testing.expect(fx.cache.bounds(a, &fx.tr, &fx.selector, Item{ .geom = .{ .x = 5, .y = 50 }, .text_content = "x", .use_draw_transform = true }, 2) == null);
}

test "status bar text below the editor's last line no longer reaches the caret patch" {
    // zeditor, measured: the caret on the last visible editor line has native patch
    // (840, 549, 5, 20); the status bar's 13 px text after it has the generic envelope
    // (800, 564, 174, 40.9) (baseline 590.9), glyphs ~15 px tall at y~577.
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const patch = [4]f32{ 840, 549, 5, 20 };
    const overlaps = struct {
        fn f(p: [4]f32, q: [4]f32) bool {
            return p[0] < q[0] + q[2] and q[0] < p[0] + p[2] and p[1] < q[1] + q[3] and q[1] < p[1] + p[3];
        }
    }.f;
    for ([_]f32{ 1, 2 }) |scale| {
        var status: Item = .{ .geom = .{ .x = 800, .y = 590.9 }, .text_content = "Ln 1205, Col 18   UTF-8   LF   Plain Text", .text_font_size = 13 };
        _ = try fx.drawn(status, scale);
        const envelope = paint_fp.damageItemBounds(status);
        const ink = fx.cache.bounds(a, &fx.tr, &fx.selector, status, scale).?;
        try std.testing.expect(overlaps(envelope, patch));
        try std.testing.expect(!overlaps(ink, patch));
        try std.testing.expect(ink[3] < 20);
        // Glyphs that do reach into the patch still count.
        status.geom.y = 575;
        const drawn = (try fx.drawn(status, scale)).?;
        const reaching = fx.cache.bounds(a, &fx.tr, &fx.selector, status, scale).?;
        try std.testing.expect(drawn[1] < patch[1] + patch[3]);
        try std.testing.expect(overlaps(reaching, patch));
    }
}

test "a CPU patch frame leaves the GPU buffer slot and the frame counter alone" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    fx.tr.beginFrame(4000, 2000, 2);
    const slot = fx.tr.current_buffer;
    const frame = fx.tr.current_frame;
    // A slot an in-flight GPU frame reads must not come round again, and
    // idle trim must keep counting from the latest GPU frame.
    fx.tr.beginFrameFor(4000, 2000, 2, false);
    fx.tr.beginFrameFor(4000, 2000, 2, false);
    try std.testing.expectEqual(slot, fx.tr.current_buffer);
    try std.testing.expectEqual(frame, fx.tr.current_frame);
    fx.tr.beginFrame(4000, 2000, 2);
    try std.testing.expect(fx.tr.current_buffer != slot);
    try std.testing.expectEqual(frame + 1, fx.tr.current_frame);
}
