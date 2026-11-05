const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
extern fn metal_test_gate_new(device: *anyopaque) ?*anyopaque;
extern fn metal_test_gate_wait(buffer: *anyopaque, event: *anyopaque) void;
extern fn metal_test_gate_value(event: *anyopaque) u64;
extern fn metal_test_gate_release(event: *anyopaque) void;
extern fn metal_queue_command_buffer(queue: *anyopaque) ?*anyopaque;
extern fn metal_command_buffer_commit(buffer: *anyopaque) void;
extern fn metal_command_buffer_wait_until_completed(buffer: *anyopaque) void;
extern fn metal_command_buffer_create_blit_encoder(buffer: *anyopaque) ?*anyopaque;
extern fn metal_blit_encoder_copy_buffer(encoder: *anyopaque, src: *anyopaque, src_offset: c_ulong, dst: *anyopaque, dst_offset: c_ulong, size: c_ulong) void;
extern fn metal_blit_encoder_end_encoding(encoder: *anyopaque) void;
extern fn metal_release(object: *anyopaque) void;

pub fn route(app: *zenit_app.App, path: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.eql(u8, path, "/review/frame-slot-failure")) return null;
    return probe(app, out) catch |err| std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
}
fn draw(app: *zenit_app.App, node: *ui.Node, color: ui.Color) !void {
    node.setBackground(color);
    node.markRenderDirty();
    try app.renderer.frame(app.cx, app.viewport_w, app.viewport_h, app.scale);
}
fn probe(app: *zenit_app.App, out: []u8) ![]const u8 {
    const renderer = app.renderer;
    renderer.frame_sync.drain(3);
    const node = try ui.box(app.cx, .{ .position = .absolute, .width = .{ .px = 200 }, .height = .{ .px = 100 }, .background = ui.Color.rgba(255, 0, 0, 255) }, .{});
    (try node.style.ensureExtFallible(app.cx.allocator)).inset = .{
        .left = .{ .px = 400 },
        .top = .{ .px = 350 },
    };
    try app.cx.root.?.appendChild(app.cx.allocator, node);
    app.cx.root.?.markLayoutDirty();
    app.cx.layout();

    const event = metal_test_gate_new(@ptrCast(renderer.device.raw_device)) orelse return error.NoGate;
    defer metal_release(event);
    defer metal_test_gate_release(event);
    const gate = metal_queue_command_buffer(@ptrCast(renderer.queue.raw)) orelse return error.NoGateBuffer;
    defer metal_release(gate);
    metal_test_gate_wait(gate, event);
    metal_command_buffer_commit(gate);

    // A and B are genuinely submitted and blocked behind the GPU event. The
    // third permit is the only available one for failed C and its retry D.
    try draw(app, node, ui.Color.rgba(255, 0, 0, 255));
    const a_slot = renderer.sdf_renderer.current_buffer;
    var source = &(renderer.sdf_renderer.instance_buffers.buffers[a_slot] orelse return error.NoInstances);
    const bytes = renderer.sdf_renderer.buffer_write_offset * @sizeOf(@TypeOf(renderer.sdf_renderer.instances.items[0]));
    if (bytes == 0) return error.NoInstances;
    const expected = try app.allocator.dupe(u8, try source.getMappedRange(0, bytes));
    defer app.allocator.free(expected);
    var staging = try renderer.device.createBuffer(app.allocator, .{
        .size = bytes,
        .usage = .{ .map_read = true, .copy_dst = true },
    });
    defer staging.destroy();
    // GPU, not CPU, reads A's source after the gate opens. This copy was
    // enqueued before B/C/D, so any difference exposes an in-flight overwrite.
    const copy = metal_queue_command_buffer(@ptrCast(renderer.queue.raw)) orelse return error.NoCopyBuffer;
    defer metal_release(copy);
    const blit = metal_command_buffer_create_blit_encoder(copy) orelse return error.NoBlit;
    defer metal_release(blit);
    metal_blit_encoder_copy_buffer(blit, @ptrCast(source.raw), 0, @ptrCast(staging.raw), 0, bytes);
    metal_blit_encoder_end_encoding(blit);
    metal_command_buffer_commit(copy);
    try draw(app, node, ui.Color.rgba(0, 255, 0, 255));
    const b_slot = renderer.sdf_renderer.current_buffer;
    renderer.fail_after_encode_for_testing = true;
    var failure: []const u8 = "accepted";
    draw(app, node, ui.Color.rgba(255, 255, 0, 255)) catch |err| {
        failure = @errorName(err);
    };
    try draw(app, node, ui.Color.rgba(0, 0, 255, 255));
    const d_slot = renderer.sdf_renderer.current_buffer;
    if (metal_test_gate_value(event) != 0) return error.GateWatchdogExpired;
    metal_test_gate_release(event);
    metal_command_buffer_wait_until_completed(copy);
    renderer.frame_sync.drain(3);
    const observed = try staging.getMappedRange(0, bytes);
    var changed: usize = 0;
    for (expected, observed) |a, b| if (a != b) {
        changed += 1;
    };
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"failure\":\"{s}\",\"a_slot\":{d},\"b_slot\":{d},\"d_slot\":{d},\"gpu_changed_bytes\":{d},\"sampled_bytes\":{d}}}", .{ failure, a_slot, b_slot, d_slot, changed, bytes });
}
