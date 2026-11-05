//! A recorder on a separate GPU queue must see a completed drawable. Callback
//! shape (with/without an owner context) does not establish GPU ordering.
const std = @import("std");

pub fn deliver(comptime cross_queue: bool, command: anytype, callback: anytype, args: anytype) bool {
    if (cross_queue) command.waitUntilCompleted();
    return @call(.auto, callback, args);
}

const PendingFrame = struct {
    complete: bool = false,
    waits: usize = 0,
    fn waitUntilCompleted(self: *PendingFrame) void {
        self.waits += 1;
        self.complete = true;
    }
};

test "cross-queue context recorder sees completed pixels and its own window owner" {
    var frame: PendingFrame = .{};
    var owner: usize = 42;
    const Recorder = struct {
        fn append(context: *usize, source: *const PendingFrame) bool {
            return context.* == 42 and source.complete;
        }
    };
    try std.testing.expect(deliver(true, &frame, Recorder.append, .{ &owner, &frame }));
    try std.testing.expectEqual(@as(usize, 1), frame.waits);
}

test "same-queue readback stays asynchronous" {
    var frame: PendingFrame = .{};
    const Recorder = struct {
        fn append(source: *const PendingFrame) bool {
            return !source.complete;
        }
    };
    try std.testing.expect(deliver(false, &frame, Recorder.append, .{&frame}));
    try std.testing.expectEqual(@as(usize, 0), frame.waits);
}

test "legacy cross-queue recorder retains completion and propagates failure" {
    var frame: PendingFrame = .{};
    const Recorder = struct {
        fn append(source: *const PendingFrame) bool {
            std.debug.assert(source.complete);
            return false;
        }
    };
    try std.testing.expect(!deliver(true, &frame, Recorder.append, .{&frame}));
    try std.testing.expectEqual(@as(usize, 1), frame.waits);
}
