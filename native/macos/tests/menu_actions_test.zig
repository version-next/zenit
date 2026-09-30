const std = @import("std");
const Window = @import("platform").Window;
extern fn zenit_test_menu_reset() void;
extern fn zenit_test_menu_enqueue(u64, c_int) void;
test "legacy Window menu packets retain native identity and action across later invocations" {
    const t = std.testing;
    zenit_test_menu_reset();
    for (0..300) |i| zenit_test_menu_enqueue(if (i % 2 == 0) 1001 else 2002, 8);
    for (0..300) |i| {
        const event = Window.getMenuActionEvent().?;
        try t.expectEqual(@as(u64, if (i % 2 == 0) 1001 else 2002), event.native_window_id);
        try t.expectEqual(Window.MenuAction.save_as, event.action);
    }
    try t.expect(Window.getMenuActionEvent() == null);
}
