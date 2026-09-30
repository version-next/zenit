const std = @import("std");
const events = @import("events");
extern fn zenit_test_global_reset() void;
extern fn zenit_test_global_enqueue(u64) void;
extern fn macos_menu_poll_command(*u64, *u64) c_int;

test "native menu queue survives failed SDK reservation and publishes every command once" {
    const t = std.testing;
    zenit_test_global_reset();
    for (1..301) |i| zenit_test_global_enqueue(i);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var queue = events.EventQueue.init(failing.allocator());
    defer queue.deinit();
    try t.expectError(error.OutOfMemory, queue.list.ensureUnusedCapacity(queue.allocator, 1));
    failing.fail_index = std.math.maxInt(usize);
    for (1..301) |i| {
        try queue.list.ensureUnusedCapacity(queue.allocator, 1);
        var window: u64 = 0;
        var command: u64 = 0;
        try t.expectEqual(@as(c_int, 1), macos_menu_poll_command(&window, &command));
        try t.expectEqual(@as(u64, i), command);
        queue.list.appendAssumeCapacity(.{ .menu_command = .{ .window_id = window, .command_id = command } });
    }
    try t.expectEqual(@as(usize, 300), queue.items().len);
    var window: u64 = 0;
    var command: u64 = 0;
    try t.expectEqual(@as(c_int, 0), macos_menu_poll_command(&window, &command));
}
