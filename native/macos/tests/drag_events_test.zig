const std = @import("std");
const Window = @import("platform").Window;
const events = @import("events");
extern fn zenit_test_drag_window_create() *anyopaque;
extern fn zenit_test_drag_window_destroy(*anyopaque) void;
extern fn zenit_test_drag_enqueue(*anyopaque, [*]const u8, usize, u8) void;

test "real native drag head survives SDK queue OOM and full payload outlives consumption" {
    const t = std.testing;
    const ptr = zenit_test_drag_window_create();
    defer zenit_test_drag_window_destroy(ptr);
    var window: Window = .{ .window_ptr = ptr, .view_ptr = undefined, .width = 0, .height = 0 };
    const paths = "/tmp/漢.png\n" ** 1000;
    zenit_test_drag_enqueue(ptr, paths, paths.len, 3);
    zenit_test_drag_enqueue(ptr, "", 0, 4);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var queue = events.EventQueue.init(failing.allocator());
    defer queue.deinit();
    const pending = (try window.peekDragEventChecked()).?;
    const value: events.Event = .{ .drag = .{ .window_id = 1, .x = pending.event.x, .y = pending.event.y, .kind = 3, .paths = pending.event.paths } };
    try t.expectError(error.OutOfMemory, queue.push(value));
    const retry = (try window.peekDragEventChecked()).?;
    try t.expectEqual(pending.token, retry.token);
    try t.expectEqualStrings(paths, retry.event.paths);
    failing.fail_index = std.math.maxInt(usize);
    try queue.push(value);
    try window.consumeDragEventChecked(retry.token);
    const completion = (try window.peekDragEventChecked()).?;
    try t.expectEqual(@as(u8, 4), completion.event.kind);
    try t.expectEqual(@as(u64, 123456789), completion.event.source_token);
    try t.expectEqual(@as(u8, 2), completion.event.operation);
    try window.consumeDragEventChecked(completion.token);
    try t.expect((try window.peekDragEventChecked()) == null);
    try t.expectEqualStrings(paths, queue.items()[0].drag.paths);
}
