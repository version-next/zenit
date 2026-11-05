//! Access to the native process environment for diagnostic flags and overrides.
//! Values returned by getOwned are copied; Windows uses the Unicode Win32 API.
const std = @import("std");
const builtin = @import("builtin");

/// Raw POSIX-compatible lookup for diagnostic flags. Freestanding hosts have
/// no process environment; all lookups are uniformly absent.
pub fn getNative(name: [*:0]const u8) ?[*:0]const u8 {
    if (builtin.os.tag == .freestanding) return null;
    return std.c.getenv(name);
}

pub fn has(comptime name: [:0]const u8) bool {
    if (builtin.os.tag == .freestanding) return false;
    if (builtin.target.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(name)) != null;
    }
    return getNative(name) != null;
}

/// `has`, read once per process and cached (one cache per name). For switches
/// consulted on per-frame or per-item paths: a getenv scans the whole
/// environment block each call. The process environment is fixed after
/// launch for these flags; tests that mutate it use `has`.
pub fn flag(comptime name: [:0]const u8) bool {
    return FlagCache(name).get();
}

fn FlagCache(comptime name: [:0]const u8) type {
    return struct {
        // Depends on `name`, so each name gets its own storage.
        const key = name;
        var cached: ?bool = null;

        fn get() bool {
            return cached orelse blk: {
                const v = has(key);
                cached = v;
                break :blk v;
            };
        }
    };
}

/// Sets (or, with null, clears) a switch read through `flag` and keeps that
/// cache in step, for contract probes that flip a renderer switch between
/// checks. Mutating the environment directly is not observed by `flag` once
/// the name has been read.
pub fn setFlag(comptime name: [:0]const u8, value: ?[:0]const u8) error{EnvironmentMutationFailed}!void {
    if (builtin.os.tag == .freestanding) return error.EnvironmentMutationFailed;
    if (builtin.os.tag == .windows) {
        var buf: [64:0]u16 = undefined;
        const wide: ?[*:0]const u16 = if (value) |v| blk: {
            if (v.len > buf.len) return error.EnvironmentMutationFailed;
            const n = std.unicode.wtf8ToWtf16Le(&buf, v) catch return error.EnvironmentMutationFailed;
            buf[n] = 0;
            break :blk buf[0..n :0].ptr;
        } else null;
        if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), wide) == 0) return error.EnvironmentMutationFailed;
    } else {
        const result = if (value) |v| setenv(name.ptr, v.ptr, 1) else unsetenv(name.ptr);
        if (result != 0) return error.EnvironmentMutationFailed;
    }
    FlagCache(name).cached = value != null;
}

/// Borrowing matches the native POSIX getenv lifetime: environment mutation
/// may invalidate the result. Call getOwned when the value must be retained.
pub fn getBorrowed(comptime name: [:0]const u8) ?[:0]const u8 {
    if (builtin.os.tag == .freestanding) return null;
    if (builtin.target.os.tag == .windows) @compileError("use getOwned on Windows");
    const value = getNative(name) orelse return null;
    return std.mem.span(value);
}

/// Short flag values on every platform: copies the value into `buf` (Windows
/// converts from WTF-16 through `buf`, so leave room). Null when unset or too long.
pub fn getInto(comptime name: [:0]const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .freestanding) return null;
    if (builtin.target.os.tag == .windows) {
        // `buf` holds the value only: the key is a comptime UTF-16 literal.
        // (A FixedBufferAllocator over `buf` used to hold the UTF-16 key too,
        // so any name longer than about half of `buf` read as unset.)
        const environ: std.process.Environ = .{ .block = .global };
        const value_w = environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(name)) orelse return null;
        if (std.unicode.calcWtf8Len(value_w) > buf.len) return null;
        return buf[0..std.unicode.wtf16LeToWtf8(buf, value_w)];
    }
    const value = getBorrowed(name) orelse return null;
    if (value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

pub const GetError = error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8, Unexpected };
pub fn getOwned(allocator: std.mem.Allocator, name: []const u8) GetError![]u8 {
    if (builtin.os.tag == .freestanding) return error.EnvironmentVariableNotFound;
    if (builtin.target.os.tag == .windows) {
        const windows = std.os.windows;
        const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
        defer allocator.free(name_w);
        windows.teb().LastErrorValue = .SUCCESS;
        var needed = GetEnvironmentVariableW(name_w.ptr, null, 0);
        if (needed == 0) {
            if (windows.GetLastError() == .ENVVAR_NOT_FOUND) return error.EnvironmentVariableNotFound;
            if (windows.GetLastError() != .SUCCESS) return error.Unexpected;
            return allocator.dupe(u8, "");
        }
        while (true) {
            const value = try allocator.alloc(u16, needed);
            defer allocator.free(value);
            windows.teb().LastErrorValue = .SUCCESS;
            const len = GetEnvironmentVariableW(name_w.ptr, value.ptr, @intCast(value.len));
            if (len >= value.len) {
                needed = len;
                continue;
            }
            if (len == 0 and windows.GetLastError() == .ENVVAR_NOT_FOUND) return error.EnvironmentVariableNotFound;
            if (len == 0 and windows.GetLastError() != .SUCCESS) return error.Unexpected;
            return std.unicode.wtf16LeToWtf8Alloc(allocator, value[0..len]);
        }
    }
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);
    const value = getNative(name_z.ptr) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;

test "missing process environment values stay missing" {
    const name = "ZENIT_MISSING_ENVIRONMENT_TEST_0D391170";
    try std.testing.expect(!has(name));
    try std.testing.expectError(error.EnvironmentVariableNotFound, getOwned(std.testing.allocator, name));
}

test "process environment preserves empty and Unicode values and owns copies" {
    const name = "ZENIT_ENVIRONMENT_COPY_TEST_F493EC17";
    if (has(name)) return error.TestEnvironmentAlreadySet;
    defer setTestValue(name, null) catch unreachable;
    try setTestValue(name, "");
    try std.testing.expect(has(name));
    const empty = try getOwned(std.testing.allocator, name);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const original = "日本語/é/🦊";
    try setTestValue(name, original);
    const copy = try getOwned(std.testing.allocator, name);
    defer std.testing.allocator.free(copy);
    try setTestValue(name, "changed");
    try std.testing.expectEqualStrings(original, copy);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("changed", getBorrowed(name).?);
    try setTestValue(name, null);
    try std.testing.expect(!has(name));
    try std.testing.expectError(error.EnvironmentVariableNotFound, getOwned(std.testing.allocator, name));
}

test "getInto reads a long name into a buffer sized for its value" {
    // The buffer is sized for the value, never for the name (every caller
    // passes a few bytes): a long name must not read as unset.
    const name = "ZENIT_ENVIRONMENT_GET_INTO_LONG_NAME_TEST_5B21C0DE";
    if (has(name)) return error.TestEnvironmentAlreadySet;
    defer setTestValue(name, null) catch unreachable;
    var small: [2]u8 = undefined;
    try std.testing.expect(getInto(name, &small) == null);
    try setTestValue(name, "1");
    try std.testing.expectEqualStrings("1", getInto(name, &small).?);
    try setTestValue(name, "é");
    try std.testing.expectEqualStrings("é", getInto(name, &small).?);
    // Too long for the buffer: unset, not truncated.
    try setTestValue(name, "123");
    try std.testing.expect(getInto(name, &small) == null);
}

fn setTestValue(comptime name: [:0]const u8, value: ?[:0]const u8) !void {
    if (builtin.os.tag == .windows) {
        const wide = if (value) |v| try std.unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, v) else null;
        defer if (wide) |w| std.testing.allocator.free(w);
        if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), if (wide) |w| w.ptr else null) == 0)
            return error.TestEnvironmentMutationFailed;
    } else {
        const result = if (value) |v| setenv(name.ptr, v.ptr, 1) else unsetenv(name.ptr);
        if (result != 0) return error.TestEnvironmentMutationFailed;
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;

test "setFlag updates a switch already read through flag" {
    const name = "ZENIT_TEST_SET_FLAG_51C2";
    try std.testing.expect(!flag(name));
    try setFlag(name, "1");
    defer setFlag(name, null) catch {};
    try std.testing.expect(flag(name));
    try std.testing.expect(has(name));
    try setFlag(name, null);
    try std.testing.expect(!flag(name));
    try std.testing.expect(!has(name));
}

test "flag reads each name once and keeps names apart" {
    const absent = "ZENIT_TEST_FLAG_ABSENT_7F3A";
    const present = "ZENIT_TEST_FLAG_PRESENT_7F3A";
    try setTestValue(present, "1");
    defer setTestValue(present, null) catch {};
    // An absent name read first must not leak its value into another name's cache.
    try std.testing.expect(!flag(absent));
    try std.testing.expect(flag(present));
    // Cached: later environment changes are not observed (has still is).
    try setTestValue(present, null);
    try std.testing.expect(flag(present));
    try std.testing.expect(!has(present));
}
