//! Shared native/wasm fixture: identical input and code paths on both targets.
const std = @import("std");
const builtin = @import("builtin");
// Prevent std.debug.print in the reached core closure from selecting native
// threaded I/O. Unsupported diagnostic I/O traps through the failing vtable.
pub const std_options_debug_io = if (builtin.os.tag == .freestanding) @import("wasm_io.zig").io else std.Io.Threaded.global_single_threaded.io();
const core = @import("core.zig");
const reactive = @import("reactive.zig");
const layout = @import("core/layout_engine.zig");
const text_layout = @import("core/text_layout.zig");
const types = @import("core/types.zig");

pub fn reactiveCase(allocator: std.mem.Allocator) !i32 {
    const owner = try reactive.SignalOwner.init(allocator);
    defer owner.deinit();
    const signal = try reactive.Signal(i32).create(owner, 3);
    var observed: i32 = -1;
    try reactive.createEffect(owner, .{ .signal = signal, .observed = &observed }, struct {
        fn run(ctx: anytype) void {
            ctx.observed.* = ctx.signal.get() * 2;
        }
    }.run);
    if (observed != 6) return error.InitialEffectDidNotRun;
    signal.set(21);
    return observed;
}

pub fn layoutCase(allocator: std.mem.Allocator, io: std.Io) !types.ComputedRect {
    const cx = try core.Cx.init(allocator, io);
    defer cx.deinit();
    const root = try cx.createNode(.box, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .direction = .row, .gap = 10, .align_items = .center });
    cx.root = root;
    const first = try cx.createNode(.box, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } });
    {
        errdefer cx.destroyDetached(first);
        try root.appendChild(allocator, first);
    }
    const second = try cx.createNode(.box, .{ .width = types.Sizing.fill(), .height = .{ .px = 40 } });
    {
        errdefer cx.destroyDetached(second);
        try root.appendChild(allocator, second);
    }
    layout.layoutNode(root, .{ .width = 300, .height = 100 }, .{ .frame_allocator = cx.frame_arena.allocator() });
    return second.rectFromWorldOrFallback();
}

pub fn i18nCase(allocator: std.mem.Allocator) !u32 {
    const i18n = @import("i18n");
    const input = "abc אבג 日本語";
    var resolved = try i18n.resolveBidi(allocator, input, null);
    defer resolved.deinit();
    var breaks: std.ArrayList(u32) = .empty;
    defer breaks.deinit(allocator);
    try i18n.findBreakOpportunities(input, &breaks, allocator);
    var scripts: std.ArrayList(i18n.ScriptRun) = .empty;
    defer scripts.deinit(allocator);
    try i18n.splitScriptRuns(input, 0, input.len, &scripts, allocator);
    var hash: u32 = 2166136261;
    for (resolved.visual_to_logical) |index| hash = (hash ^ index) *% 16777619;
    for (breaks.items) |offset| hash = (hash ^ offset) *% 16777619;
    return hash ^ @as(u32, @intCast(scripts.items.len));
}

pub fn measureCase() f32 {
    const Hook = struct {
        fn measure(_: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(len)) * 7;
        }
    };
    text_layout.setMeasureFn(Hook.measure);
    defer text_layout.setMeasureFn(null);
    return text_layout.measureTextWidthWithSpans("Web", 0, 3, 10, 400, false, false, &.{});
}

fn smoke_i18n() callconv(.c) u32 {
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    return i18nCase(fba.allocator()) catch @panic("i18n smoke failed");
}
fn smoke_measure() callconv(.c) f32 {
    return measureCase();
}
fn smoke_environment() callconv(.c) u32 {
    const env = @import("zenit_environment");
    if (env.has("PATH") or env.getNative("PATH") != null or env.getBorrowed("PATH") != null) return 0;
    const value = env.getOwned(std.heap.page_allocator, "PATH") catch |err| return if (err == error.EnvironmentVariableNotFound) 1 else 0;
    std.heap.page_allocator.free(value);
    return 0;
}

var memory: [8 * 1024 * 1024]u8 = undefined;
var result_rect: [4]f32 = undefined;

fn smoke_reactive() callconv(.c) i32 {
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    return reactiveCase(fba.allocator()) catch @panic("reactive smoke failed");
}
// Return a pointer to four f32s in wasm memory: x, y, width, height.
fn smoke_layout() callconv(.c) [*]const f32 {
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const rect = layoutCase(fba.allocator(), @import("wasm_io.zig").io) catch @panic("layout smoke failed");
    result_rect = .{ rect.x, rect.y, rect.w, rect.h };
    return &result_rect;
}
fn smoke_missing_measure() callconv(.c) f32 {
    text_layout.setMeasureFn(null);
    return text_layout.measureTextWidthWithSpans("missing hook", 0, 12, 10, 400, false, false, &.{});
}
fn smoke_unsupported_font() callconv(.c) u32 {
    _ = @import("text").FontSystem.init(std.heap.page_allocator, @import("wasm_io.zig").io) catch |err| return if (err == error.Unsupported) 1 else 0;
    return 0;
}

pub fn nativeMain(init: std.process.Init) !void {
    const value = try reactiveCase(init.gpa);
    const rect = try layoutCase(init.gpa, init.io);
    const i18n = try i18nCase(init.gpa);
    var buffer: [512]u8 = undefined;
    // f32 results are also emitted as IEEE-754 bit patterns: the gate compares bits,
    // so a non-integer fixture cannot drift through decimal round-tripping.
    const bits = struct {
        fn of(v: f32) u32 {
            return @bitCast(v);
        }
    }.of;
    const json = try std.fmt.bufPrint(&buffer, "{{\"reactive\":{d},\"rect\":[{d},{d},{d},{d}],\"rect_bits\":[{d},{d},{d},{d}],\"i18n\":{d},\"measure\":{d},\"measure_bits\":{d}}}\n", .{ value, rect.x, rect.y, rect.w, rect.h, bits(rect.x), bits(rect.y), bits(rect.w), bits(rect.h), i18n, measureCase(), bits(measureCase()) });
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}

test "wasm smoke native contracts and allocation cleanup" {
    try std.testing.expectEqual(@as(i32, 42), try reactiveCase(std.testing.allocator));
    const rect = try layoutCase(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(f32, 21), measureCase());
    // Absolute anchor so a shared regression in Unicode data/algorithms cannot pass
    // by making native and wasm agree on a wrong value. Update when Unicode data is bumped.
    try std.testing.expectEqual(@as(u32, 277424183), try i18nCase(std.testing.allocator));
    try std.testing.expectEqual(types.ComputedRect.init(60, 30, 240, 40), rect);
}

comptime {
    if (builtin.os.tag == .freestanding) {
        @export(&smoke_i18n, .{ .name = "smoke_i18n" });
        @export(&smoke_measure, .{ .name = "smoke_measure" });
        @export(&smoke_environment, .{ .name = "smoke_environment" });
        @export(&smoke_reactive, .{ .name = "smoke_reactive" });
        @export(&smoke_layout, .{ .name = "smoke_layout" });
        @export(&smoke_missing_measure, .{ .name = "smoke_missing_measure" });
        @export(&smoke_unsupported_font, .{ .name = "smoke_unsupported_font" });
    }
}
