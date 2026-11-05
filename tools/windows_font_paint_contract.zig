const std = @import("std");
const ui = @import("ui");
const text = @import("text");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern fn zenit_windows_contract_background(c_int) c_int;
extern fn zenit_d3d11_contract_text_stats(*anyopaque, *[2]u64) void;
const sample = "AV ffi Windows";
var label: *ui.Node = undefined;
fn require(ok: bool) !void {
    if (!ok) return error.FontPaintContractFailed;
}
fn mount(cx: *ui.Cx, _: *ui.Scope) !*ui.Node {
    const root = try ui.box(cx, .{ .padding = ui.Padding.all(8) }, .{});
    label = try ui.text(cx, sample, .{ .font_size = 24, .color = ui.Color.rgb(0, 0, 0) });
    try root.appendChild(cx.allocator, label);
    return root;
}
const Provider = struct {
    selected: *text.Font,
    calls: u32 = 0,
    fn ranges(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts, _: *text.Font, allocator: std.mem.Allocator) !?*text.FontRanges {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const snapshot = try allocator.create(text.FontRanges);
        errdefer allocator.destroy(snapshot);
        snapshot.* = try text.FontRanges.init(allocator, opts.text, &.{.{ .font = self.selected, .start = 0, .length = @intCast(opts.text.len), .size = opts.font_size }});
        self.calls += 1;
        return snapshot;
    }
};
fn pixelHash(app: *App, path: [:0]const u8) !u64 {
    try require(try app.painter.captureBmp(path));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.cx.io, path, app.allocator, .limited(8 * 1024 * 1024));
    defer app.allocator.free(bytes);
    try require(bytes.len >= 54 and std.mem.eql(u8, bytes[0..2], "BM"));
    const start = std.mem.readInt(u32, bytes[10..14], .little);
    try require(start < bytes.len);
    return std.hash.Wyhash.hash(0, bytes[start..]);
}
pub fn run(io: std.Io) !void {
    const background = zenit_windows_contract_background(1);
    defer _ = zenit_windows_contract_background(background);
    var stage: []const u8 = "init";
    errdefer std.log.err("Windows font range paint stage={s}", .{stage});
    const before = Window.liveWindowCount();
    const foreground = GetForegroundWindow();
    const allocator = std.heap.page_allocator;
    const temp = try @import("zenit_environment").getOwned(allocator, "TEMP");
    defer allocator.free(temp);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}\\zenit-font-paint-{x}.bmp", .{ temp, randomId(io) }, 0);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const font_path = try std.fmt.allocPrintSentinel(allocator, "{s}\\zenit-font-paint-{x}.ttf", .{ temp, randomId(io) }, 0);
    defer allocator.free(font_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = font_path, .data = @embedFile("fixtures/fonts/Lora-Regular.ttf") });
    defer std.Io.Dir.cwd().deleteFile(io, font_path) catch {};
    {
        // A Latin-only primary in a fixed language: the CJK stack stages need Han text to reach
        // the fallback stack, not the system UI font (Microsoft YaHei UI on a Chinese system).
        const app = try App.init(allocator, .{ .io = io, .font = .{ .locale = "en-us", .fallback_families = &.{"Segoe UI"} }, .window = .{ .width = 640, .height = 100 }, .clear_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } });
        defer app.deinit();
        const selected = try app.font_system.loadFont(font_path, 16);
        defer selected.deinit();
        const mono = try app.font_system.findFont(.{ .family = "Consolas", .size = 16 });
        defer mono.deinit();
        var selector = @FieldType(App, "font_selector"){ .small = selected, .medium = selected, .large = selected };
        selector.initDerivedCache(allocator);
        defer selector.deinitDerivedCache();
        app.setFontSelector(&selector);
        defer app.setFontSelector(&app.font_selector);
        try app.mount(mount);
        stage = "private-reference";
        try app.frame();
        const reference = try pixelHash(app, path);
        app.setFontSelector(&app.font_selector);
        try app.frame();
        const ordinary = try pixelHash(app, path);
        try require(reference != ordinary);
        stage = "primary-italic-cache";
        label.setText(.{ .content = sample, .font_size = 24, .use_italic_font = true, .color = ui.Color.rgb(0, 0, 0) });
        try app.frame();
        try require(try pixelHash(app, path) != ordinary);
        label.setText(.{ .content = sample, .font_size = 24, .color = ui.Color.rgb(0, 0, 0) });
        try app.frame();
        try require(try pixelHash(app, path) == ordinary);
        var provider = Provider{ .selected = selected };
        defer app.setFontRangesProvider(null, null);
        app.setFontRangesProvider(&provider, Provider.ranges);
        stage = "shared-provider-pixels";
        try app.frame();
        const ranged = try pixelHash(app, path);
        std.log.info("Font range pixel hashes reference={x} ordinary={x} ranged={x}", .{ reference, ordinary, ranged });
        try require(ranged == reference);
        const derived = try selected.derive(24);
        defer derived.deinit();
        const expected = derived.measureWidth(sample);
        const opts = ui.Cx.ShapeTextOpts{ .text = sample, .font_family = "system", .font_size = 24 };
        try require(@abs((try app.cx.text.shapeText(opts)).total_advance - expected) < 0.01);
        try require(@abs((try app.cx.text.visualLine(opts)).width - expected) < 0.01);
        stage = "snapshot-cache-reuse";
        var stats: [2]u64 = .{ 0, 0 };
        if (comptime @hasField(@FieldType(App, "painter"), "native")) zenit_d3d11_contract_text_stats(app.painter.native, &stats);
        const initial_stats = stats;
        const shared_glyphs = if (comptime @hasField(@FieldType(App, "painter"), "state")) app.painter.state.renderer.text_renderer.atlas.getCacheSize() else 0;
        const calls = provider.calls;
        label.markRenderDirty();
        try app.frame();
        try require(try pixelHash(app, path) == reference and provider.calls > calls);
        if (comptime @hasField(@FieldType(App, "painter"), "native")) {
            zenit_d3d11_contract_text_stats(app.painter.native, &stats);
            try require(stats[0] > initial_stats[0] and stats[1] == initial_stats[1]);
        } else {
            try require(shared_glyphs > 0 and app.painter.state.renderer.text_renderer.atlas.getCacheSize() == shared_glyphs);
        }
        stage = "provider-rebind";
        provider.selected = mono;
        app.setFontRangesProvider(&provider, Provider.ranges);
        try app.frame();
        try require(try pixelHash(app, path) != reference);
        const mono24 = try mono.derive(24);
        defer mono24.deinit();
        try require(@abs((try app.cx.text.visualLine(opts)).width - mono24.measureWidth(sample)) < 0.01);
        stage = "provider-clear";
        app.setFontRangesProvider(null, null);
        try app.frame();
        try require(try pixelHash(app, path) == ordinary);
        stage = "shared-stack";
        const render = @import("render");
        const cjk = try app.font_system.findFont(.{ .family = "Microsoft YaHei UI", .size = 16, .weight = .bold });
        defer cjk.deinit();
        var cjk_selector = @FieldType(App, "font_selector"){ .small = cjk, .medium = cjk, .large = cjk };
        cjk_selector.initDerivedCache(allocator);
        defer cjk_selector.deinitDerivedCache();
        label.setText(.{ .content = "中文", .font_size = 24, .color = ui.Color.rgb(0, 0, 0) });
        app.setFontSelector(&cjk_selector);
        try app.frame();
        const cjk_reference = try pixelHash(app, path);
        app.setFontSelector(&app.font_selector);
        var stack = render.font_fallback_stack.FontFallbackStack.init(allocator);
        defer stack.deinit();
        const han = stack.addFamily("Chinese", .han_kana) orelse return error.FontPaintContractFailed;
        stack.addFont(han, cjk);
        app.setFallbackStack(&stack);
        defer app.setFallbackStack(null);
        try app.frame();
        const cjk_stack_hash = try pixelHash(app, path);
        std.log.info("CJK stack pixel hashes reference={x} stack={x}", .{ cjk_reference, cjk_stack_hash });
        try require(cjk_stack_hash == cjk_reference);
        stage = "shared-stack-selector-state";
        try require(!app.font_selector.stack_mode and !cjk_selector.stack_mode);
        stage = "shared-stack-measurement";
        const cjk_opts = ui.Cx.ShapeTextOpts{ .text = "中文", .font_family = "system", .font_size = 24 };
        try require(@abs((try app.cx.text.shapeText(cjk_opts)).total_advance - 48) < 0.01);
        try require(@abs((try app.cx.text.visualLine(cjk_opts)).width - 48) < 0.01);
        stage = "long-stack-segmentation";
        var long: [900]u8 = undefined;
        for (0..300) |index| @memcpy(long[index * 3 ..][0..3], "中");
        const long_opts = ui.Cx.ShapeTextOpts{ .text = &long, .font_family = "system", .font_size = 24 };
        try require(@abs((try app.cx.text.shapeText(long_opts)).total_advance - 7200) < 0.01);
        const long_line = try app.cx.text.visualLine(long_opts);
        try require(@abs(long_line.width - 7200) < 0.01 and long_line.source_end.value == 900);
        stage = "same-stack-weight-rebind";
        const cjk_regular = try app.font_system.findFont(.{ .family = "Microsoft YaHei UI", .size = 16 });
        defer cjk_regular.deinit();
        stack.addFont(han, cjk_regular);
        app.setFallbackStack(&stack);
        try app.frame();
        const cjk_regular_hash = try pixelHash(app, path);
        try require(cjk_regular_hash != cjk_reference);
        stage = "primary-coverage";
        app.setFontSelector(&cjk_selector);
        try app.frame();
        try require(try pixelHash(app, path) == cjk_reference);
        stage = "stack-italic-reference";
        const cjk_italic = try app.font_system.findFont(.{ .family = "Microsoft YaHei UI", .size = 16, .style = .italic });
        defer cjk_italic.deinit();
        var italic_selector = @FieldType(App, "font_selector"){ .small = cjk_italic, .medium = cjk_italic, .large = cjk_italic };
        italic_selector.initDerivedCache(allocator);
        defer italic_selector.deinitDerivedCache();
        app.setFallbackStack(null);
        app.setFontSelector(&italic_selector);
        label.setText(.{ .content = "中文", .font_size = 24, .use_italic_font = true, .color = ui.Color.rgb(0, 0, 0) });
        try app.frame();
        const italic_reference = try pixelHash(app, path);
        std.log.info("CJK italic pixel hashes regular={x} italic={x}", .{ cjk_regular_hash, italic_reference });
        try require(italic_reference != cjk_regular_hash);
        stage = "stack-italic-fallback";
        app.setFontSelector(&app.font_selector);
        app.setFallbackStack(&stack);
        try app.frame();
        const italic_fallback = try pixelHash(app, path);
        std.log.info("CJK italic fallback pixel hashes reference={x} fallback={x}", .{ italic_reference, italic_fallback });
        try require(italic_fallback == italic_reference);
        app.setFallbackStack(null);
        app.setFontSelector(&app.font_selector);
        stage = "stack-italic-foreground";
        try require(GetForegroundWindow() == foreground);
    }
    try require(Window.liveWindowCount() == before and GetForegroundWindow() == foreground);
    std.log.info("Windows font range paint: shared geometry/paint provider, exact private-font reference pixels, fresh snapshot cache reuse, rebind/clear, shared CJK stack pixels/geometry, long segmentation and primary coverage, foreground preserved PASS", .{});
}

fn randomId(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}
