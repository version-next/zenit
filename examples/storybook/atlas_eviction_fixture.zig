//! Real-window review fixtures, registered in test-mode. The VirtualList hit fixture is
//! platform-neutral and serves every platform; the device fault fixtures borrow the Metal
//! device and are compiled on macOS only.
const std = @import("std");
const zenit_app = @import("zenit_app");

var target: ?*zenit_app.App = null;

pub fn install(app: *zenit_app.App) void {
    if (!zenit_app.test_harness.enabled) return;
    target = app;
    zenit_app.test_harness.setAppRouteHandler(route);
}

fn route(path: []const u8, _: []const u8, out: []u8) ?[]const u8 {
    if (@import("vlist_hit_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (comptime @import("builtin").os.tag != .macos) return null;
    if (@import("scope_reentry_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (@import("cleanup_reentry_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (@import("event_depth_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (@import("glyph_gutter_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (@import("frame_slot_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (@import("retained_frame_fixture.zig").route(target orelse return null, path, out)) |reply| return reply;
    if (std.mem.eql(u8, path, "/review/texture-stride"))
        return textureStride(out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
    if (std.mem.eql(u8, path, "/review/local-sort-scene"))
        return @import("local_sort_fixture.zig").mount(target orelse return null, out) catch |err|
            std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
    if (std.mem.eql(u8, path, "/review/atlas-init-failure"))
        return atlasInitFailure(out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
    if (!std.mem.eql(u8, path, "/review/atlas-eviction-oom"))
        return @import("reactive_oom_fixture.zig").route(path, out);
    return inject(out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
}

fn atlasInitFailure(out: []u8) ![]const u8 {
    const app = target orelse return error.NoTarget;
    const Atlas = @TypeOf(app.renderer.text_renderer.atlas);
    // Borrow the same real Metal device, with isolated per-device fault/count
    // metadata. The two samplers are real native resources, not mock handles.
    var device = app.renderer.device.*;
    device.samplers_live_for_testing = 0;
    const created_before = device.sampler_count;
    device.fail_next_texture_for_testing = true;
    var failure: []const u8 = "accepted";
    if (Atlas.init(app.allocator, &device)) |value| {
        var atlas = value;
        atlas.deinit();
    } else |err| failure = @errorName(err);
    return std.fmt.bufPrint(out, "{{\"failure\":\"{s}\",\"samplers_created\":{d},\"samplers_live\":{d}}}", .{ failure, device.sampler_count - created_before, device.samplers_live_for_testing });
}

fn textureStride(out: []u8) ![]const u8 {
    const app = target orelse return error.NoTarget;
    var texture = try app.renderer.device.createTexture(app.allocator, .{
        .size = .{ .width = 8, .height = 2 },
        .format = .bgra8_unorm,
        .memory = .host_upload,
        .usage = .{ .copy_dst = true, .copy_src = true, .texture_binding = true },
    });
    defer texture.destroy();
    var pixels: [80]u8 = @as([80]u8, @splat(0));
    // The declared slice/stride are invalid, but its physical backing is large
    // enough for a native read. The baseline probe never exposes an OOB buffer.
    var rejection: []const u8 = "accepted";
    texture.writeRegion(0, 0, 0, 8, 2, pixels[0..2], 1) catch |err| {
        rejection = @errorName(err);
    };
    for (0..8) |x| {
        @memcpy(pixels[x * 4 ..][0..4], &[_]u8{ 0, 0, 255, 255 });
        @memcpy(pixels[40 + x * 4 ..][0..4], &[_]u8{ 0, 255, 0, 255 });
    }
    try texture.writeRegion(0, 0, 0, 8, 2, &pixels, 40);
    var readback: [64]u8 = undefined;
    try texture.readBgra8(8, 2, &readback, 32);
    const correct = std.mem.eql(u8, readback[0..32], pixels[0..32]) and
        std.mem.eql(u8, readback[32..64], pixels[40..72]);
    return std.fmt.bufPrint(out, "{{\"rejection\":\"{s}\",\"roundtrip\":{}}}", .{ rejection, correct });
}

fn inject(out: []u8) ![]const u8 {
    const app = target orelse return error.NoTarget;
    const renderer = app.renderer;
    // The fixture changes CPU atlas metadata and uploads empty pages. No
    // submitted frame may be sampling these resources while that happens.
    renderer.frame_sync.drain(3);
    const atlas = &renderer.text_renderer.atlas;
    const Atlas = @TypeOf(atlas.*);
    if (atlas.page_count == 0) return error.NoAtlasPage;
    var victim_entries: usize = 0;
    var before = atlas.cache.iterator();
    while (before.next()) |entry| {
        if (entry.value_ptr.page_index == 0 and entry.value_ptr.width > 0) victim_entries += 1;
    }
    if (victim_entries == 0) return error.NoVictimGlyphs;

    // Put the live atlas just above its real byte budget. Newly added pages
    // contain zero coverage, so an erroneous old UV hit yields missing text,
    // rather than an assertion that depends on undefined texture contents.
    const zeros = try app.allocator.alloc(u8, Atlas.ATLAS_SIZE * Atlas.ATLAS_SIZE);
    defer app.allocator.free(zeros);
    @memset(zeros, 0);
    while (atlas.bytesUsed() <= Atlas.BYTE_BUDGET) {
        if (atlas.page_count >= Atlas.MAX_PAGES) return error.TooManyPages;
        var texture = try renderer.device.createTexture(app.allocator, .{
            .label = "review-atlas-empty-page",
            .size = .{ .width = Atlas.ATLAS_SIZE, .height = Atlas.ATLAS_SIZE },
            .format = .r8_unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .memory = .host_upload,
        });
        errdefer texture.destroy();
        try texture.writeRegion(0, 0, 0, Atlas.ATLAS_SIZE, Atlas.ATLAS_SIZE, zeros, Atlas.ATLAS_SIZE);
        atlas.pages[atlas.page_count] = .{
            .texture = texture,
            .packer = .{ .width = Atlas.ATLAS_SIZE, .height = Atlas.ATLAS_SIZE, .current_x = 0, .current_y = 0, .current_row_height = 0 },
            .last_used_frame = atlas.current_frame,
            .format = .gray,
        };
        atlas.page_count += 1;
    }
    const epoch = atlas.current_frame + Atlas.EVICT_THRESHOLD + Atlas.GC_INTERVAL_FRAMES + 1;
    renderer.text_renderer.current_frame = epoch;
    atlas.current_frame = epoch;
    atlas.last_gc_frame = epoch - Atlas.GC_INTERVAL_FRAMES;
    for (atlas.pages[0..atlas.page_count]) |*page| page.*.?.last_used_frame = epoch;
    atlas.pages[0].?.last_used_frame = 0;
    const pages_before = atlas.page_count;
    const cache_before = atlas.cache.count();
    const backing = atlas.allocator;
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    atlas.allocator = failing.allocator();
    atlas.maybeCollect();
    atlas.allocator = backing;
    var stale: usize = 0;
    var after = atlas.cache.iterator();
    while (after.next()) |entry| {
        if (entry.value_ptr.page_index == 0 and entry.value_ptr.width > 0) stale += 1;
    }
    renderer.text_renderer.prewarm_signature_valid = false;
    renderer.offscreen_pool.invalidateRetainedContents();
    app.cx.needs_redraw = true;
    if (app.cx.root) |root| root.markRenderDirty();
    return std.fmt.bufPrint(out, "{{\"victim_entries\":{d},\"stale_entries\":{d},\"pages_before\":{d},\"pages_after\":{d},\"cache_before\":{d},\"cache_after\":{d},\"allocation_failed\":{}}}", .{ victim_entries, stale, pages_before, atlas.page_count, cache_before, atlas.cache.count(), failing.has_induced_failure });
}
