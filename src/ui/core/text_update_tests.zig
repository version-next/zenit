const std = @import("std");
const ui = @import("../core.zig");
test "text publication: imperative label update relayouts" {
    var cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const label = try ui.text(cx, "a", .{ .font_size = 14 });
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 }, .align_items = .start }, .{label});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const before = label.rectFromWorldOrFallback().w;
    try label.setTextContent(cx.allocator, "a much longer label");
    cx.layout();
    _ = cx.render();
    try std.testing.expect(label.rectFromWorldOrFallback().w > before + 20);
}

test "text publication: NumberStepper resizes after digit count change" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const stepper = try @import("../components/number_stepper/mod.zig").mountNumberStepper(.{ .value = 9 }, scope, cx);
    try root.appendChild(cx.allocator, stepper.wrapper);
    cx.layout();
    _ = cx.render();
    const before = stepper.state.value_node.rectFromWorldOrFallback().w;
    stepper.state.setValue(10000);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqualStrings("10000", stepper.state.value_node.getText().?.content);
    try std.testing.expect(stepper.state.value_node.rectFromWorldOrFallback().w > before + 10);
}

test "text publication: FormField error text updates measured width" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const fm = @import("../components/form/mod.zig");
    const Data = struct { name: []const u8 };
    const form = try fm.FormOf(Data).create(scope, .{ .name = "" }, .{});
    const field = try fm.FormFieldOf(Data).field(.name, .{ .helper = "ok" }, form, scope, cx);
    // Opt into intrinsic width; the default helper stretches to its parent.
    field.helper_node.setStyle(null, .width, .{ .fit = .{} });
    field.wrapper.setStyle(null, .align_items, .start);
    try root.appendChild(cx.allocator, field.wrapper);
    cx.layout();
    _ = cx.render();
    const before = field.helper_node.rectFromWorldOrFallback().w;
    form.meta(.name).error_sig.set("first line\nsecond line\nthird line");
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqualStrings("first line\nsecond line\nthird line", field.helper_node.getText().?.content);
    try std.testing.expect(field.helper_node.rectFromWorldOrFallback().w > before + 10);
}

test "text publication: borrowed same-buffer edits change metrics and settle" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    // Deterministic proportional backend: headless default measurement assigns
    // equal advances to i and W, so it cannot prove this geometry transition.
    cx.text.measure_fn = struct {
        fn measure(ptr: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
            var width: f32 = 0;
            for (ptr[0..len]) |byte| width += if (byte == 'W') @as(f32, 12) else 3;
            return width;
        }
    }.measure;
    defer @import("text_layout.zig").setMeasureFn(null);
    var bytes = [_]u8{'i'} ** 5;
    const label = try ui.text(cx, "", .{});
    label.setText(.{ .content = &bytes });
    cx.root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 }, .align_items = .start }, .{label});
    cx.layout();
    _ = cx.render();
    const before = label.rectFromWorldOrFallback().w;
    @memset(&bytes, 'W');
    label.setText(label.getText());
    try std.testing.expect(label.frame_state.state_bits.dirty.core.layout);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(label.rectFromWorldOrFallback().w > before);
    label.setText(label.getText());
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.render);
}

test "text publication: colors repaint and span metrics remeasure" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const label = try ui.text(cx, "hello", .{});
    cx.root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{label});
    var spans = [_]ui.TextSpan{.{ .start = 0, .end = 5 }};
    var t = label.getText().?;
    t.spans = &spans;
    label.setText(t);
    cx.layout();
    _ = cx.render();
    t = label.getText().?;
    t.color = ui.Color.rgb(1, 2, 3);
    spans[0].color = ui.Color.rgb(4, 5, 6);
    label.setText(t);
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(label.frame_state.state_bits.dirty.core.render);
    _ = cx.render();
    spans[0].font_weight = 700;
    label.setText(label.getText());
    try std.testing.expect(label.frame_state.state_bits.dirty.core.layout);
    cx.layout();
    _ = cx.render();
    t = label.getText().?;
    t.spans_affect_layout = false;
    label.setText(t);
    cx.layout();
    _ = cx.render();
    spans[0].font_weight = 400;
    label.setText(label.getText());
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.layout);
}

test "text publication: presence inline and owned replacements" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const label = try ui.text(cx, "hello", .{});
    cx.root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{label});
    cx.layout();
    _ = cx.render();
    label.setText(null);
    try std.testing.expect(label.frame_state.state_bits.dirty.core.layout);
    cx.layout();
    _ = cx.render();
    var t: ui.TextProps = .{};
    try t.setInlineContent("short");
    label.setText(t);
    try std.testing.expect(label.frame_state.state_bits.dirty.core.layout);
    cx.layout();
    _ = cx.render();
    try label.setTextContent(cx.allocator, "short");
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(!label.frame_state.state_bits.dirty.core.render);
    try label.setTextContent(cx.allocator, "much longer owned content");
    try std.testing.expect(label.frame_state.state_bits.dirty.core.layout);
}

test "text publication: wrapped content remeasures height" {
    const cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const label = try ui.text(cx, "first", .{ .wrap = .newline_only });
    cx.root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{label});
    cx.layout();
    _ = cx.render();
    const before = label.rectFromWorldOrFallback().h;
    try label.setTextContent(cx.allocator, "first\nsecond\nthird");
    cx.layout();
    _ = cx.render();
    try std.testing.expect(label.rectFromWorldOrFallback().h > before + 10);
}

test "text publication: setContent 长文本经节点替换 / 销毁不泄漏、不截断" {
    const alloc = std.testing.allocator;
    const cx = try ui.Cx.init(alloc);
    defer cx.deinit();
    const node = try ui.text(cx, "", .{});
    defer cx.freeNode(node);
    inline for (.{ "first value that is longer than inline", "short", "second long value, also beyond sixteen bytes" }) |s| {
        var t = node.getText().?;
        try t.setContent(cx.allocator, s);
        node.setText(t);
        try std.testing.expectEqualStrings(s, node.getText().?.content);
    }
}
