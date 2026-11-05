const std = @import("std");

/// null preserves the complete canonical registry; an explicit empty selection
/// is an error so a typo cannot silently produce an unusable preview shell.
pub fn validate(registry: anytype, selection: ?[]const u8) error{ EmptyKey, UnknownKey, DuplicateKey }!void {
    const csv = selection orelse return;
    var keys = std.mem.splitScalar(u8, csv, ',');
    var offset: usize = 0;
    while (keys.next()) |raw| {
        const key = std.mem.trim(u8, raw, " \t");
        if (key.len == 0) return error.EmptyKey;
        var found = false;
        for (registry) |info| {
            if (std.mem.eql(u8, key, info.key)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownKey;
        if (offset > 0 and includes(csv[0 .. offset - 1], key)) return error.DuplicateKey;
        offset += raw.len + 1;
    }
}

pub fn includes(selection: ?[]const u8, key: []const u8) bool {
    const csv = selection orelse return true;
    var keys = std.mem.splitScalar(u8, csv, ',');
    while (keys.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), key)) return true;
    }
    return false;
}

test "selection keeps all by default and matches exact trimmed keys" {
    const registry = [_]struct { key: []const u8 }{ .{ .key = "button" }, .{ .key = "card" } };
    try validate(&registry, null);
    try validate(&registry, " card, button ");
    try std.testing.expect(includes(null, "button"));
    try std.testing.expect(includes(" card, button ", "button"));
    try std.testing.expect(!includes("button", "but"));
    try std.testing.expect(!includes("card", "button"));
}

test "selection rejects empty unknown and duplicate keys" {
    const registry = [_]struct { key: []const u8 }{ .{ .key = "button" }, .{ .key = "card" } };
    try std.testing.expectError(error.EmptyKey, validate(&registry, ""));
    try std.testing.expectError(error.EmptyKey, validate(&registry, "button,"));
    try std.testing.expectError(error.EmptyKey, validate(&registry, "button,,card"));
    try std.testing.expectError(error.UnknownKey, validate(&registry, "Button"));
    try std.testing.expectError(error.DuplicateKey, validate(&registry, "button, button"));
}
