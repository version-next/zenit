const std = @import("std");

pub const WorkPriority = enum(u8) {
    user_blocking,
    user_visible,
    background,

    pub fn rank(self: WorkPriority) u8 {
        return @intFromEnum(self);
    }
};

pub const WorkKey = union(enum) {
    int: u64,
    bytes: []const u8,

    pub fn clone(self: WorkKey, allocator: std.mem.Allocator) !WorkKey {
        return switch (self) {
            .int => |value| .{ .int = value },
            .bytes => |value| .{ .bytes = try allocator.dupe(u8, value) },
        };
    }

    pub fn deinit(self: *WorkKey, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bytes => |value| allocator.free(value),
            .int => {},
        }
        self.* = .{ .int = 0 };
    }

    pub fn eql(a: WorkKey, b: WorkKey) bool {
        return switch (a) {
            .int => |lhs| switch (b) {
                .int => |rhs| lhs == rhs,
                .bytes => false,
            },
            .bytes => |lhs| switch (b) {
                .int => false,
                .bytes => |rhs| std.mem.eql(u8, lhs, rhs),
            },
        };
    }
};

pub const WorkSpec = struct {
    key: WorkKey,
    priority: WorkPriority,
    version: u64,
    delay_ns: u64 = 0,
};

pub const WorkStep = union(enum) {
    done,
    again,
    sleep_ns: u64,
};

pub const WorkResult = struct {
    step: WorkStep,
    wants_redraw: bool = false,
};

pub const WorkHandle = struct {
    pub const RuntimeFns = struct {
        cancel: *const fn (*anyopaque, u64) void,
        promote: *const fn (*anyopaque, u64, WorkPriority) void,
        is_pending: *const fn (*const anyopaque, u64) bool,
    };

    runtime_ctx: ?*anyopaque = null,
    runtime_fns: ?*const RuntimeFns = null,
    task_id: u64 = 0,

    pub fn cancel(self: *WorkHandle) void {
        if (self.runtime_ctx == null or self.runtime_fns == null or self.task_id == 0) return;
        self.runtime_fns.?.cancel(self.runtime_ctx.?, self.task_id);
    }

    pub fn promote(self: *WorkHandle, priority: WorkPriority) void {
        if (self.runtime_ctx == null or self.runtime_fns == null or self.task_id == 0) return;
        self.runtime_fns.?.promote(self.runtime_ctx.?, self.task_id, priority);
    }

    pub fn isPending(self: *const WorkHandle) bool {
        if (self.runtime_ctx == null or self.runtime_fns == null or self.task_id == 0) return false;
        return self.runtime_fns.?.is_pending(self.runtime_ctx.?, self.task_id);
    }
};
