//! Cursor decisions are snapshots, not side effects of enter/leave callbacks.
const std = @import("std");
const types = @import("types.zig");
const hit = @import("hit_runtime.zig");

pub const Region = struct {
    shape: types.CursorShape,
    /// Stable within the declaring node (e.g. a row ID plus a handle ID).
    id: u64 = 0,
};
pub const Token = struct { controller: u64, id: u64 };
// Cx/input mutation is confined to the UI thread, like NodeRegistry.
var next_controller: u64 = 0;
pub const Source = enum { fallback, style, region, capture, override };
pub const Submission = enum { none, accepted, failed, handoff };
pub const Decision = struct {
    shape: types.CursorShape = .default,
    source: Source = .fallback,
    owner: ?hit.NodeHandle = null,
    region_id: u64 = 0,
    token: ?Token = null,
    x: f32 = 0,
    y: f32 = 0,
    revision: u64 = 0,
};
pub const Lease = struct {
    token: Token,
    owner: hit.NodeHandle,
    capture_epoch: u64,
    shape: types.CursorShape,
};

pub const State = struct {
    leases: std.ArrayListUnmanaged(Lease) = .{},
    next_token: u64 = 0,
    controller: u64 = 0,
    pointer_valid: bool = false,
    reconciling: bool = false,
    decision: Decision = .{},
    submission: Submission = .none,
    /// Adapter submission validity, not a claim about the OS's current image.
    submitted: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.leases.deinit(allocator);
    }

    pub fn acquire(self: *State, allocator: std.mem.Allocator, owner: hit.NodeHandle, epoch: u64, shape: types.CursorShape) !Token {
        if (self.controller == 0) {
            next_controller = std.math.add(u64, next_controller, 1) catch @panic("cursor controller exhausted");
            self.controller = next_controller;
        }
        self.next_token = std.math.add(u64, self.next_token, 1) catch @panic("cursor token exhausted");
        const token = Token{ .controller = self.controller, .id = self.next_token };
        try self.leases.append(allocator, .{ .token = token, .owner = owner, .capture_epoch = epoch, .shape = shape });
        return token;
    }

    pub fn release(self: *State, token: Token) void {
        for (self.leases.items, 0..) |lease, i| {
            if (std.meta.eql(lease.token, token)) {
                _ = self.leases.orderedRemove(i);
                return;
            }
        }
    }

    pub fn update(self: *State, token: Token, shape: types.CursorShape) void {
        for (self.leases.items) |*lease| {
            if (std.meta.eql(lease.token, token)) {
                lease.shape = shape;
                return;
            }
        }
    }

    pub fn prune(self: *State, registry: *const hit.NodeRegistry, capture: ?hit.NodeHandle, epoch: u64) void {
        var i: usize = 0;
        while (i < self.leases.items.len) {
            const lease = self.leases.items[i];
            const valid = if (capture) |h|
                std.meta.eql(h, lease.owner) and epoch == lease.capture_epoch and registry.resolve(h, null) != null
            else
                false;
            if (!valid) {
                _ = self.leases.orderedRemove(i);
            } else i += 1;
        }
    }
};
