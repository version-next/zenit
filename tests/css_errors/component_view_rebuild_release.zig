const ui = @import("ui");

export fn rebuildInRelease(instance: *ui.view.ComponentInstance) void {
    _ = instance.rebuild() catch {};
}
