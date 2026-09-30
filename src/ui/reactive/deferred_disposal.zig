//! Intrusive FIFO for destruction requests. Entries live inside the resource,
//! so postponing its destruction never needs another allocation.
const std = @import("std");

pub const Entry = struct {
    previous: ?*Entry = null,
    next: ?*Entry = null,
    queue: ?*Queue = null,
    ptr: *anyopaque = undefined,
    dispose_fn: *const fn (*anyopaque) void = undefined,

    pub fn cancel(self: *Entry) void {
        if (self.queue) |queue| queue.remove(self);
    }
};

pub const Queue = struct {
    head: ?*Entry = null,
    tail: ?*Entry = null,
    len: usize = 0,

    pub fn append(self: *Queue, entry: *Entry, ptr: *anyopaque, dispose_fn: *const fn (*anyopaque) void) void {
        std.debug.assert(entry.queue == null);
        entry.* = .{ .previous = self.tail, .queue = self, .ptr = ptr, .dispose_fn = dispose_fn };
        if (self.tail) |tail| tail.next = entry else self.head = entry;
        self.tail = entry;
        self.len += 1;
    }

    fn remove(self: *Queue, entry: *Entry) void {
        std.debug.assert(entry.queue == self);
        if (entry.previous) |previous| previous.next = entry.next else self.head = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.tail = entry.previous;
        entry.previous = null;
        entry.next = null;
        entry.queue = null;
        self.len -= 1;
    }

    pub fn popFirst(self: *Queue) ?*Entry {
        const entry = self.head orelse return null;
        self.remove(entry);
        return entry;
    }
};
