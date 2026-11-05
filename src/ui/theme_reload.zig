//! Preview token transaction. Parser storage and fixed-shape provider values share
//! a version lifetime; publication only links an already validated version.
const std = @import("std");
const theme = @import("theme.zig");
const resolver = @import("zenit_environment").preview.token_resolver;
const model = @import("zenit_environment").preview.token_model;
const A = std.mem.Allocator;
const mode_count = @import("zenit_reflection").fields(theme.Mode).len;
var versions: ?*Version = null;
pub const Version = struct {
    allocator: A,
    document: model.Document,
    values: [mode_count]theme.Values = undefined,
    result: union(enum) { ready, fallback: []const u8, diagnostic: struct { line: usize, message: []const u8 } } = .ready,
    next: ?*Version = null,
    committed: bool = false,
    pub fn commit(self: *Version) void {
        std.debug.assert(self.result == .ready and !self.committed);
        self.next = versions;
        versions = self;
        self.committed = true;
    }
    pub fn deinit(self: *Version) void {
        std.debug.assert(!self.committed);
        const a = self.allocator;
        self.document.deinit();
        a.destroy(self);
    }
};
pub fn prepare(a: A, source: []const u8) !*Version {
    const v = try a.create(Version);
    errdefer a.destroy(v);
    v.* = .{ .allocator = a, .document = try resolver.parse(a, source) };
    if (v.document.diagnostic) |d| {
        var line: usize = 1;
        for (source[0..@min(source.len, d.offset)]) |c| {
            if (c == '\n') line += 1;
        }
        v.result = .{ .diagnostic = .{ .line = line, .message = d.message } };
        return v;
    }
    v.values = theme.previewValues(&v.document) catch |err| {
        v.result = .{ .fallback = if (err == error.TokenDuration) "token_duration" else "token_shape" };
        return v;
    };
    return v;
}
/// Called only after all readers are detached. Values contain no borrowed JSON
/// strings; names come from the compiled provider.
pub fn deinit() void {
    while (versions) |v| {
        versions = v.next;
        v.committed = false;
        v.deinit();
    }
}
/// Values are exposed as ordinary borrowed pointers by Cx.tokens and theme
/// signals. Application state may retain one after a callback returns, and no
/// borrow tracking identifies its final reader. Keep every committed version
/// until session teardown rather than reclaiming a still-borrowed Values here.
/// StyleIR can use quiescent-point collection because its facade returns values;
/// the public theme pointer API has a different lifetime contract.
pub fn collect() void {}

/// Committed versions remain valid until preview-session teardown, including
/// pointers retained by application state outside a reactive callback.
pub fn retainedVersionCount() usize {
    var count: usize = 0;
    var version = versions;
    while (version) |v| : (version = v.next) count += 1;
    return count;
}
/// Version storage plus arena capacity; excludes allocator bookkeeping.
pub fn retainedBytes() usize {
    var bytes: usize = 0;
    var version = versions;
    while (version) |v| : (version = v.next) bytes += @sizeOf(Version) + v.document.arena.queryCapacity();
    return bytes;
}

pub fn owns(value: *const theme.Values) bool {
    var version = versions;
    while (version) |v| : (version = v.next) {
        for (&v.values) |*owned| if (value == owned) return true;
    }
    return false;
}

/// Null means no published replacement; it must not replace application-owned
/// custom tokens with compiled defaults during attach.
pub fn latestMode(name: []const u8) ?*const theme.Values {
    if (versions) |v| {
        for (&v.values) |*value| if (std.mem.eql(u8, name, value.name)) return value;
    }
    return null;
}
pub fn compiledMode(name: []const u8) *const theme.Values {
    inline for (@import("zenit_reflection").fields(theme.Mode)) |m| {
        if (std.mem.eql(u8, name, m.name)) return &@field(theme.modes, m.name);
    }
    return &theme.dark;
}
