//! Portable, data-only LP0 snapshot. Callback context is never encoded.
const std = @import("std");
const A = std.mem.Allocator;
pub const max_bytes = 16 * 1024 * 1024;
pub const Frame = struct { x: f64 = 0, y: f64 = 0, w: f64 = 800, h: f64 = 600 };
pub const Scroll = struct {
    key: []const u8,
    x: f32 = 0,
    y: f32 = 0,
    item_key: ?[]const u8 = null,
    item_offset: ?f32 = null,
};
pub const Window = struct {
    key: []const u8,
    role: []const u8 = "window",
    owner: ?[]const u8 = null,
    route: ?[]const u8 = null,
    active: bool = false,
    frame: Frame = .{},
    screen: []const u8 = "",
    scroll: []const Scroll = &.{},
    focus: ?[]const u8 = null,
};
pub const Entry = struct { key: []const u8, schema_version: u32, data: []const u8 };
pub const Snapshot = struct {
    schema_version: u32 = 1,
    revision: []const u8,
    generation: []const u8,
    application: []const Entry = &.{},
    windows: []const Window = &.{},
};
pub fn encode(a: A, value: Snapshot) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    errdefer a.free(bytes);
    if (bytes.len > max_bytes) return error.SnapshotTooLarge;
    return bytes;
}
pub fn decode(a: A, bytes: []const u8) !std.json.Parsed(Snapshot) {
    if (bytes.len > max_bytes) return error.SnapshotTooLarge;
    const parsed = try std.json.parseFromSlice(Snapshot, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.UnsupportedSnapshotVersion;
    for (parsed.value.windows) |w| if (!validFrame(w.frame)) return error.InvalidFrame;
    return parsed;
}
pub fn validFrame(f: Frame) bool {
    return std.math.isFinite(f.x) and std.math.isFinite(f.y) and std.math.isFinite(f.w) and std.math.isFinite(f.h) and f.w > 0 and f.h > 0;
}
/// Coordinates are logical desktop points (platform Y axis); no scale is persisted.
pub fn clampFrame(frame: Frame, visible: Frame) Frame {
    if (!validFrame(visible)) return .{};
    const f = if (validFrame(frame)) frame else Frame{};
    const w = @min(f.w, visible.w);
    const h = @min(f.h, visible.h);
    return .{ .x = std.math.clamp(f.x, visible.x, visible.x + visible.w - w), .y = std.math.clamp(f.y, visible.y, visible.y + visible.h - h), .w = w, .h = h };
}
pub fn clampOffset(value: f32, maximum: f32) f32 {
    if (!std.math.isFinite(value) or !std.math.isFinite(maximum)) return 0;
    return std.math.clamp(value, 0, @max(0, maximum));
}

pub const Registry = struct {
    pub const Encode = *const fn (*anyopaque, A) anyerror![]u8;
    /// null version/data means missing. A version mismatch is deliberately delivered
    /// to the application, which can migrate or ignore it. Errors discard this key.
    pub const Decode = *const fn (*anyopaque, ?u32, ?[]const u8) anyerror!void;
    const Binding = struct { active: bool = true, key: []const u8, version: u32, ctx: *anyopaque, encode: Encode, decode: Decode };
    allocator: A,
    bindings: std.ArrayList(Binding) = .empty,
    busy: bool = false,
    pub fn deinit(self: *Registry) void {
        for (self.bindings.items) |b| self.allocator.free(b.key);
        self.bindings.deinit(self.allocator);
    }
    pub fn persist(self: *Registry, key: []const u8, version: u32, ctx: *anyopaque, enc: Encode, dec: Decode, restored: []const Entry) !void {
        if (self.busy) return error.RegistryBusy;
        for (self.bindings.items) |b| if (b.active and std.mem.eql(u8, key, b.key)) return error.DuplicatePersistKey;
        if (key.len == 0) return error.EmptyPersistKey;
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.bindings.append(self.allocator, .{ .key = owned, .version = version, .ctx = ctx, .encode = enc, .decode = dec });
        self.busy = true;
        defer self.busy = false;
        for (restored) |entry| if (std.mem.eql(u8, key, entry.key)) {
            dec(ctx, entry.schema_version, entry.data) catch {};
            return;
        };
        dec(ctx, null, null) catch {};
    }
    /// Dev file-command navigation uses the same application decoder as startup.
    /// Callback removal is supported; no borrowed binding is used after decode.
    pub fn apply(self: *Registry, entry: Entry) !void {
        if (self.busy) return error.RegistryBusy;
        for (self.bindings.items) |b| if (b.active and std.mem.eql(u8, b.key, entry.key)) {
            self.busy = true;
            defer self.busy = false;
            return b.decode(b.ctx, entry.schema_version, entry.data);
        };
        return error.UnknownPersistKey;
    }
    /// Call before destroying callback context (normally from scope cleanup).
    pub fn remove(self: *Registry, key: []const u8) !void {
        for (self.bindings.items, 0..) |b, i| if (b.active and std.mem.eql(u8, key, b.key)) {
            if (self.busy) {
                // Tombstone during callbacks: no iterator invalidation, and a later
                // encoder whose context was just destroyed is never invoked.
                self.bindings.items[i].active = false;
            } else {
                self.allocator.free(b.key);
                _ = self.bindings.orderedRemove(i);
            }
            return;
        };
    }
    /// Output and encoded payloads belong to the supplied arena.
    pub fn capture(self: *Registry, arena: A) ![]Entry {
        if (self.busy) return error.RegistryBusy;
        self.busy = true;
        defer self.busy = false;
        const entries = try arena.alloc(Entry, self.bindings.items.len);
        var count: usize = 0;
        for (0..self.bindings.items.len) |i| {
            const b = self.bindings.items[i];
            if (!b.active) continue;
            const key = try arena.dupe(u8, b.key);
            const data = try b.encode(b.ctx, arena);
            if (!self.bindings.items[i].active) continue;
            entries[count] = .{ .key = key, .schema_version = b.version, .data = data };
            count += 1;
        }
        return entries[0..count];
    }
};

test "snapshot v1 roundtrip, large state, unknown fields and future version rejection" {
    const a = std.testing.allocator;
    const data = try a.alloc(u8, 4096);
    defer a.free(data);
    @memset(data, 'x');
    const bytes = try encode(a, .{ .revision = "r", .generation = "2", .application = &.{.{ .key = "model", .schema_version = 3, .data = data }}, .windows = &.{.{ .key = "main", .frame = .{ .x = -800 }, .scroll = &.{.{ .key = "list", .item_key = "item-3", .item_offset = 2 }}, .focus = "input" }} });
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(data, parsed.value.application[0].data);
    try std.testing.expectEqualStrings("item-3", parsed.value.windows[0].scroll[0].item_key.?);
    try std.testing.expectError(error.UnsupportedSnapshotVersion, decode(a, "{\"schema_version\":2,\"revision\":\"r\",\"generation\":\"1\"}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, decode(a, "{"));
}
const Fixture = struct {
    registry: ?*Registry = null,
    seen: ?u32 = null,
    missing: bool = false,
    fn enc(raw: *anyopaque, a: A) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.registry) |r| try std.testing.expectError(error.RegistryBusy, r.persist("reentry", 1, self, enc, dec, &.{}));
        return a.dupe(u8, "migrated");
    }
    fn dec(raw: *anyopaque, version: ?u32, data: ?[]const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.seen = version;
        self.missing = data == null;
        if (self.registry) |r| try std.testing.expectError(error.RegistryBusy, r.persist("reentry", 1, self, enc, dec, &.{}));
    }
};
test "persist missing, deleted, migration, unregister and callback reentry" {
    var r: Registry = .{ .allocator = std.testing.allocator };
    defer r.deinit();
    var f: Fixture = .{ .registry = &r };
    const old = [_]Entry{ .{ .key = "story", .schema_version = 1, .data = "old" }, .{ .key = "deleted", .schema_version = 1, .data = "gone" } };
    try r.persist("story", 2, &f, Fixture.enc, Fixture.dec, &old);
    try std.testing.expectEqual(@as(?u32, 1), f.seen);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try r.capture(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u32, 2), entries[0].schema_version);
    try r.remove("story");
    try r.persist("new", 1, &f, Fixture.enc, Fixture.dec, &old);
    try std.testing.expect(f.missing);
}
fn allocationFixture(a: A) !void {
    var r: Registry = .{ .allocator = a };
    defer r.deinit();
    var f: Fixture = .{};
    try r.persist("story", 1, &f, Fixture.enc, Fixture.dec, &.{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const entries = try r.capture(arena.allocator());
    const bytes = try encode(a, .{ .revision = "r", .generation = "1", .application = entries });
    defer a.free(bytes);
    const restored = try decode(a, bytes);
    defer restored.deinit();
}
test "persist and snapshot partial initialization OOM sweep" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
test "window frame clamp disconnected displays, negative origin, oversized and invalid" {
    const area: Frame = .{ .x = -1000, .y = 20, .w = 1000, .h = 700 };
    try std.testing.expectEqual(Frame{ .x = -800, .y = 120, .w = 800, .h = 600 }, clampFrame(.{ .x = 9000, .y = 9000 }, area));
    try std.testing.expectEqual(area, clampFrame(.{ .w = 2000, .h = 2000 }, area));
    try std.testing.expect(validFrame(clampFrame(.{ .x = std.math.nan(f64) }, area)));
    try std.testing.expectEqual(@as(f32, 0), clampOffset(std.math.nan(f32), 10));
    try std.testing.expectEqual(@as(f32, 10), clampOffset(100, 10));
}

test "encode callback removes and destroys a later binding without invoking it" {
    const Context = struct {
        registry: *Registry,
        calls: usize = 0,
        fn first(raw: *anyopaque, a: A) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.registry.remove("later");
            return a.dupe(u8, "first");
        }
        fn later(raw: *anyopaque, a: A) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return a.dupe(u8, "later");
        }
        fn restore(_: *anyopaque, _: ?u32, _: ?[]const u8) !void {}
    };
    var r: Registry = .{ .allocator = std.testing.allocator };
    defer r.deinit();
    var context: Context = .{ .registry = &r };
    try r.persist("first", 1, &context, Context.first, Context.restore, &.{});
    try r.persist("later", 1, &context, Context.later, Context.restore, &.{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try r.capture(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}

test "application may discard an incompatible schema and future optional fields are ignored" {
    const Reject = struct {
        calls: u32 = 0,
        fn enc(_: *anyopaque, a: A) ![]u8 {
            return a.dupe(u8, "default");
        }
        fn dec(raw: *anyopaque, version: ?u32, _: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (version != 7) return error.UnsupportedApplicationSchema;
        }
    };
    var registry: Registry = .{ .allocator = std.testing.allocator };
    defer registry.deinit();
    var context: Reject = .{};
    try registry.persist("model", 7, &context, Reject.enc, Reject.dec, &.{.{ .key = "model", .schema_version = 1, .data = "obsolete" }});
    try std.testing.expectEqual(@as(u32, 1), context.calls);
    const parsed = try decode(std.testing.allocator, "{\"revision\":\"r\",\"generation\":\"1\",\"future_optional_field\":true}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.application.len);
    try std.testing.expectError(error.InvalidFrame, decode(std.testing.allocator, "{\"revision\":\"r\",\"generation\":\"1\",\"windows\":[{\"key\":\"main\",\"frame\":{\"w\":0}}]}"));
}

test "oversized state cannot publish a snapshot that the same runtime cannot restore" {
    const a = std.testing.allocator;
    const data = try a.alloc(u8, max_bytes + 1);
    defer a.free(data);
    @memset(data, 'x');
    try std.testing.expectError(error.SnapshotTooLarge, encode(a, .{ .revision = "r", .generation = "1", .application = &.{.{ .key = "large", .schema_version = 1, .data = data }} }));
    try std.testing.expectError(error.SnapshotTooLarge, decode(a, data));
}

test "dev navigation decoder receives schema and rejects unknown keys" {
    var registry: Registry = .{ .allocator = std.testing.allocator };
    defer registry.deinit();
    var fixture: Fixture = .{ .registry = &registry };
    try registry.persist("route", 1, &fixture, Fixture.enc, Fixture.dec, &.{});
    try registry.apply(.{ .key = "route", .schema_version = 7, .data = "second" });
    try std.testing.expectEqual(@as(?u32, 7), fixture.seen);
    try std.testing.expectError(error.UnknownPersistKey, registry.apply(.{ .key = "missing", .schema_version = 1, .data = "" }));
}
