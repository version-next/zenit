//! Test-mode pointer isolation shared by the macOS and Windows runtimes.
//!
//! The e2e harness injects pointer input by calling Cx directly. Real OS pointer events from a
//! person using the machine would otherwise overwrite the injected hover position, so hover
//! states and clicks land on whatever the physical cursor is over. When isolation is on, the
//! runtime drops OS pointer events and only the harness drives the pointer.
const std = @import("std");
const system_sdk = @import("system_sdk");

/// ZENIT_E2E_ISOLATE_POINTER decides explicitly ("0"/empty = off). Without it, a background e2e
/// run isolates when `background_default` is set: the Windows worker exports
/// ZENIT_E2E_BACKGROUND=1 for every job without --allow-foreground, while foreground jobs drive
/// the real cursor through SendInput and must keep OS pointer input.
pub fn enabledFrom(isolate: ?[]const u8, background: ?[]const u8, background_default: bool) bool {
    if (isolate) |v| return flag(v);
    if (background_default) if (background) |v| return flag(v);
    return false;
}

fn flag(value: []const u8) bool {
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

/// Reads the process environment once per process.
pub fn enabled(comptime background_default: bool) bool {
    const Cache = struct {
        var value: ?bool = null;
    };
    if (Cache.value) |v| return v;
    const page = std.heap.page_allocator;
    const isolate = @import("zenit_environment").getOwned(page, "ZENIT_E2E_ISOLATE_POINTER") catch null;
    defer if (isolate) |v| page.free(v);
    const background = @import("zenit_environment").getOwned(page, "ZENIT_E2E_BACKGROUND") catch null;
    defer if (background) |v| page.free(v);
    const v = enabledFrom(isolate, background, background_default);
    Cache.value = v;
    return v;
}

/// OS pointer events that isolation drops. Keyboard, IME, focus, resize and drag-and-drop
/// sessions are untouched.
pub fn isOsPointerEvent(event: system_sdk.events.Event) bool {
    return switch (event) {
        .mouse_move, .pointer_left, .mouse_button, .mouse_wheel, .magnify => true,
        else => false,
    };
}

/// ZENIT_E2E_ISOLATE_KEYBOARD decides explicitly ("0"/empty = off). Unlike pointer isolation
/// there is no background_default: keyboard isolation is a local-development escape hatch for
/// machines shared between an e2e run and a live user (zenit's own CI runs unattended, so
/// physical typing there is not a concern).
pub fn keyboardEnabledFrom(isolate: ?[]const u8) bool {
    return if (isolate) |v| flag(v) else false;
}

/// Reads ZENIT_E2E_ISOLATE_KEYBOARD once per process.
pub fn keyboardEnabled() bool {
    const Cache = struct {
        var value: ?bool = null;
    };
    if (Cache.value) |v| return v;
    const page = std.heap.page_allocator;
    const isolate = @import("zenit_environment").getOwned(page, "ZENIT_E2E_ISOLATE_KEYBOARD") catch null;
    defer if (isolate) |v| page.free(v);
    const v = keyboardEnabledFrom(isolate);
    Cache.value = v;
    return v;
}

/// OS keyboard / text / IME events that keyboard isolation drops. Same contract-injection
/// split as pointer isolation: the harness writes directly into Cx, so anything arriving
/// through the sdk event queue is physical input.
pub fn isOsKeyboardEvent(event: system_sdk.events.Event) bool {
    return switch (event) {
        .key, .text_input, .ime_preedit, .ime_commit, .ime_delete_surrounding => true,
        else => false,
    };
}

/// Discarded OS pointer and keyboard traffic must not reset an idle interval or force GPU
/// frames. Harness injection still requests its frames directly through Cx.
pub fn requestsFrame(isolated: bool, keyboard_isolated: bool, input: []const system_sdk.events.Event) bool {
    for (input) |event| {
        if (isolated and isOsPointerEvent(event)) continue;
        if (keyboard_isolated and isOsKeyboardEvent(event)) continue;
        if (!eventForcesFrame(event)) continue;
        return true;
    }
    return false;
}

/// Whether delivering this platform event must render a frame by itself. A wheel event does not:
/// it requests one through what it changes (Cx.handleScroll; a wheel against a pinned end, or over
/// content that cannot scroll, changes nothing). Every other event keeps the unconditional frame
/// (hover/cursor paths do not guarantee a redraw request of their own).
pub fn eventForcesFrame(event: system_sdk.events.Event) bool {
    return event != .mouse_wheel;
}

test "isolated pointer batches do not force frames but native lifecycle events do" {
    const input = [_]system_sdk.events.Event{
        .{ .mouse_move = .{ .window_id = 1, .x = 10, .y = 20 } },
        .{ .frame_requested = {} },
    };
    try std.testing.expect(!requestsFrame(true, false, input[0..1]));
    try std.testing.expect(requestsFrame(false, false, input[0..1]));
    try std.testing.expect(requestsFrame(true, false, &input));
    try std.testing.expect(!requestsFrame(false, false, &.{}));
}

test "a wheel event alone forces no frame; it requests one through what it changes" {
    const wheel = [_]system_sdk.events.Event{.{ .mouse_wheel = .{ .window_id = 1, .x = 1, .y = 2, .dx = 0, .dy = 3 } }};
    try std.testing.expect(!requestsFrame(false, false, &wheel));
    const mixed = [_]system_sdk.events.Event{ wheel[0], .{ .mouse_move = .{ .window_id = 1, .x = 1, .y = 2 } } };
    try std.testing.expect(requestsFrame(false, false, &mixed));
}

test "explicit ZENIT_E2E_ISOLATE_POINTER wins over the background default" {
    try std.testing.expect(enabledFrom("1", null, false));
    try std.testing.expect(!enabledFrom("0", "1", true));
    try std.testing.expect(!enabledFrom("", "1", true));
}

test "background e2e runs isolate only where the platform opts in" {
    try std.testing.expect(enabledFrom(null, "1", true));
    try std.testing.expect(!enabledFrom(null, "0", true));
    try std.testing.expect(!enabledFrom(null, null, true));
    // macOS keeps its explicit opt-in; ZENIT_E2E_BACKGROUND alone does not change it.
    try std.testing.expect(!enabledFrom(null, "1", false));
}

test "only OS pointer events are dropped" {
    const E = system_sdk.events.Event;
    inline for (@import("zenit_reflection").fields(E)) |field| {
        const expected = comptime std.mem.eql(u8, field.name, "mouse_move") or
            std.mem.eql(u8, field.name, "pointer_left") or
            std.mem.eql(u8, field.name, "mouse_button") or
            std.mem.eql(u8, field.name, "mouse_wheel") or
            std.mem.eql(u8, field.name, "magnify");
        const event = @unionInit(E, field.name, std.mem.zeroes(field.type));
        try std.testing.expectEqual(expected, isOsPointerEvent(event));
    }
}

test "explicit ZENIT_E2E_ISOLATE_KEYBOARD flag parsing" {
    try std.testing.expect(keyboardEnabledFrom("1"));
    try std.testing.expect(keyboardEnabledFrom("true"));
    try std.testing.expect(!keyboardEnabledFrom("0"));
    try std.testing.expect(!keyboardEnabledFrom(""));
    try std.testing.expect(!keyboardEnabledFrom(null));
}

test "only OS keyboard, text and IME events are dropped" {
    const E = system_sdk.events.Event;
    inline for (@import("zenit_reflection").fields(E)) |field| {
        const expected = comptime std.mem.eql(u8, field.name, "key") or
            std.mem.eql(u8, field.name, "text_input") or
            std.mem.eql(u8, field.name, "ime_preedit") or
            std.mem.eql(u8, field.name, "ime_commit") or
            std.mem.eql(u8, field.name, "ime_delete_surrounding");
        const event = @unionInit(E, field.name, std.mem.zeroes(field.type));
        try std.testing.expectEqual(expected, isOsKeyboardEvent(event));
    }
}

test "keyboard isolation never drops pointer events and vice versa" {
    const key_down: system_sdk.events.Event = .{ .key = .{
        .window_id = 1,
        .keycode = 36,
        .pressed = true,
    } };
    const click: system_sdk.events.Event = .{ .mouse_button = .{
        .window_id = 1,
        .x = 10,
        .y = 10,
        .button = .left,
        .pressed = true,
    } };
    // The two isolation domains are disjoint: keyboard isolation must not eat
    // pointer isolation's events (and the runtime applies both filters).
    try std.testing.expect(isOsKeyboardEvent(key_down));
    try std.testing.expect(!isOsPointerEvent(key_down));
    try std.testing.expect(!isOsKeyboardEvent(click));
    try std.testing.expect(isOsPointerEvent(click));
}

/// The default App path handles OS input. Only a test-mode caller that owns
/// the seeded queue may explicitly mark input as a contract injection.
pub const Source = enum { os, test_contract };
pub fn shouldDropEvent(comptime test_mode: bool, isolated: bool, keyboard_isolated: bool, comptime source: Source, event: system_sdk.events.Event) bool {
    if (source == .test_contract) {
        if (!test_mode) @compileError("owned contract input requires a test-mode build");
        return false;
    }
    return (isolated and isOsPointerEvent(event)) or (keyboard_isolated and isOsKeyboardEvent(event));
}

test "background isolation preserves owned contract input while dropping real OS pointer input" {
    const cancel: system_sdk.events.Event = .{ .mouse_button = .{
        .window_id = 1,
        .x = 10,
        .y = 10,
        .button = .left,
        .pressed = false,
        .cancelled = true,
    } };
    const down: system_sdk.events.Event = .{ .mouse_button = .{
        .window_id = 1,
        .x = 10,
        .y = 10,
        .button = .left,
        .pressed = true,
    } };
    const move: system_sdk.events.Event = .{ .mouse_move = .{
        .window_id = 1,
        .x = 10,
        .y = 10,
    } };
    for ([_]system_sdk.events.Event{ cancel, down, move }) |event| {
        try std.testing.expect(shouldDropEvent(true, true, false, .os, event));
        try std.testing.expect(!shouldDropEvent(true, true, false, .test_contract, event));
        try std.testing.expect(!shouldDropEvent(true, false, false, .os, event));
        // Production input still follows the OS path; contract source fails to compile.
        try std.testing.expect(shouldDropEvent(false, true, false, .os, event));
    }
}

test "keyboard isolation suppresses frames for every keyboard event only" {
    const E = system_sdk.events.Event;
    inline for (@import("zenit_reflection").fields(E)) |field| {
        const input = [_]E{@unionInit(E, field.name, std.mem.zeroes(field.type))};
        const forces = eventForcesFrame(input[0]);
        try std.testing.expectEqual(forces and !isOsKeyboardEvent(input[0]), requestsFrame(false, true, &input));
        try std.testing.expectEqual(forces and !isOsKeyboardEvent(input[0]) and !isOsPointerEvent(input[0]), requestsFrame(true, true, &input));
        try std.testing.expectEqual(forces, requestsFrame(false, false, &input));
    }
    const mixed = [_]E{
        .{ .key = std.mem.zeroes(@FieldType(E, "key")) },
        .{ .frame_requested = {} },
    };
    try std.testing.expect(requestsFrame(true, true, &mixed));
    try std.testing.expect(!requestsFrame(true, true, &.{}));
}

// Windows gallery contracts seed the SDK queue rather than calling Cx directly.
// Their keyboard and IME packets must survive the same opt-in OS filter.
test "keyboard isolation preserves owned contract input across every event kind" {
    const E = system_sdk.events.Event;
    inline for (@import("zenit_reflection").fields(E)) |field| {
        const event = @unionInit(E, field.name, std.mem.zeroes(field.type));
        try std.testing.expectEqual(isOsKeyboardEvent(event), shouldDropEvent(true, false, true, .os, event));
        try std.testing.expect(!shouldDropEvent(true, true, true, .test_contract, event));
        try std.testing.expect(!shouldDropEvent(false, false, false, .os, event));
        try std.testing.expectEqual(isOsPointerEvent(event) or isOsKeyboardEvent(event), shouldDropEvent(true, true, true, .os, event));
    }
}
