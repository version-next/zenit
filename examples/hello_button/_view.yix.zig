// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Button = ui.widgets.Button;
/// Stylesheet (styles.yss): JSON token reference + app recipe S.Panel, separated from interface
/// structure.
const S = @import("_styles.yss.zig");

fn emphasisOf(n: u32) S.PanelEmphasis {
    return if (n > 0) .highlight else .neutral;
}

/// Click +1; after clicked, count panel switches to highlight variant (cva variant directly
/// receives computed source).
pub fn HelloButton(args: anytype) ui.view.ComponentOf(__yix_HelloButton) {
    return ui.view.component(__yix_HelloButton, ui.reactive.props.coerce(HelloButtonProps, args));
}
pub const HelloButtonProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = HelloButton;
    pub const __yix_preview_mount = __yix_HelloButton;
};
fn __yix_HelloButton(__yix_props: HelloButtonProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, false);
    const count = try scope.createSignalFor(u32, 0);
    const emphasis = __yix_d1: {
        const __yix_T = @TypeOf(emphasisOf(count.peek()));
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return emphasisOf(__yix_ctx.count.get());
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, .emphasis = emphasis, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "col", .tokens = "col style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . root ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, .emphasis = __yix_view_ctx.emphasis, }, ui.view.col(.{ .style = S.root, }, .{
            ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "text", .tokens = "text style = @static; ", .literal_text = "Hello, zenit!", .attributes = &.{ .{ .name = "style", .tokens = "S . title ", .kind = .style, .literal = null }, } }, .{ }, ui.view.text(.{ .style = S.title, }, ui.view.fmt("Hello, zenit!", .{ }))),
            ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "Button", .tokens = "< Button testId = \"hello.increment\" variant = { . primary } size = { . md } onClick = { count += 1 } > Click me < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"hello.increment\" ", .kind = .property, .literal = .{ .text = "hello.increment" } }, .{ .name = "variant", .tokens = ". primary ", .kind = .property, .literal = .{ .enum_name = "primary" } }, .{ .name = "size", .tokens = ". md ", .kind = .property, .literal = .{ .enum_name = "md" } }, .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, ui.view.templateAttrs(.{ .test_id = "hello.increment", }, __yix_builder_640: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_640 ui.view.textChild(Button, .{ .variant = .primary, .size = .md, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Click me", .{
                ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "text", .tokens = "text", .literal_text = "Click me" }, .{ }, ui.view.text(.{}, ui.view.fmt("Click me", .{ }))),
            }); })),
            ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "box", .tokens = "box style = S . Panel . of ( . { . emphasis = emphasis } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . Panel . of ( . { . emphasis = emphasis } ) ", .kind = .style, .literal = null }, } }, .{ .emphasis = __yix_view_ctx.emphasis, .count = __yix_view_ctx.count, }, ui.view.box(.{ .style = S.Panel.of(.{ .emphasis = __yix_view_ctx.emphasis }), }, .{
                ui.view.templateSite(.{ .module = "examples/hello_button/view.yix", .path = "HelloButton", .receiver = "text", .tokens = "text testId = @static; style = @static; count  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"hello.counter\" ", .kind = .property, .literal = .{ .text = "hello.counter" } }, .{ .name = "style", .tokens = "S . counter_label ", .kind = .style, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ .test_id = "hello.counter", .style = S.counter_label, }, ui.view.fmt("Clicked " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), "") ++ " times", .{ __yix_view_ctx.count, }))),
            })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "HelloButton";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x42\x75\x74\x74\x6f\x6e\x20\x3d\x20\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x2e\x42\x75\x74\x74\x6f\x6e\x3b\x0a\x2f\x2f\x2f\x20\x53\x74\x79\x6c\x65\x73\x68\x65\x65\x74\x20\x28\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x29\x3a\x20\x4a\x53\x4f\x4e\x20\x74\x6f\x6b\x65\x6e\x20\x72\x65\x66\x65\x72\x65\x6e\x63\x65\x20\x2b\x20\x61\x70\x70\x20\x72\x65\x63\x69\x70\x65\x20\x53\x2e\x50\x61\x6e\x65\x6c\x2c\x20\x73\x65\x70\x61\x72\x61\x74\x65\x64\x20\x66\x72\x6f\x6d\x20\x69\x6e\x74\x65\x72\x66\x61\x63\x65\x0a\x2f\x2f\x2f\x20\x73\x74\x72\x75\x63\x74\x75\x72\x65\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x66\x6e\x20\x65\x6d\x70\x68\x61\x73\x69\x73\x4f\x66\x28\x6e\x3a\x20\x75\x33\x32\x29\x20\x53\x2e\x50\x61\x6e\x65\x6c\x45\x6d\x70\x68\x61\x73\x69\x73\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x69\x66\x20\x28\x6e\x20\x3e\x20\x30\x29\x20\x2e\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x20\x65\x6c\x73\x65\x20\x2e\x6e\x65\x75\x74\x72\x61\x6c\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x43\x6c\x69\x63\x6b\x20\x2b\x31\x3b\x20\x61\x66\x74\x65\x72\x20\x63\x6c\x69\x63\x6b\x65\x64\x2c\x20\x63\x6f\x75\x6e\x74\x20\x70\x61\x6e\x65\x6c\x20\x73\x77\x69\x74\x63\x68\x65\x73\x20\x74\x6f\x20\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x20\x76\x61\x72\x69\x61\x6e\x74\x20\x28\x63\x76\x61\x20\x76\x61\x72\x69\x61\x6e\x74\x20\x64\x69\x72\x65\x63\x74\x6c\x79\x0a\x2f\x2f\x2f\x20\x72\x65\x63\x65\x69\x76\x65\x73\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x20\x73\x6f\x75\x72\x63\x65\x29\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x48\x65\x6c\x6c\x6f\x42\x75\x74\x74\x6f\x6e\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x65\x6d\x70\x68\x61\x73\x69\x73\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x65\x6d\x70\x68\x61\x73\x69\x73\x4f\x66\x28\x63\x6f\x75\x6e\x74\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x72\x6f\x6f\x74\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x74\x69\x74\x6c\x65\x7d\x3e\x48\x65\x6c\x6c\x6f\x2c\x20\x7a\x65\x6e\x69\x74\x21\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x68\x65\x6c\x6c\x6f\x2e\x69\x6e\x63\x72\x65\x6d\x65\x6e\x74\x22\x20\x76\x61\x72\x69\x61\x6e\x74\x3d\x7b\x2e\x70\x72\x69\x6d\x61\x72\x79\x7d\x20\x73\x69\x7a\x65\x3d\x7b\x2e\x6d\x64\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x43\x6c\x69\x63\x6b\x20\x6d\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x50\x61\x6e\x65\x6c\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x65\x6d\x70\x68\x61\x73\x69\x73\x20\x3d\x20\x65\x6d\x70\x68\x61\x73\x69\x73\x20\x7d\x29\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x68\x65\x6c\x6c\x6f\x2e\x63\x6f\x75\x6e\x74\x65\x72\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x63\x6f\x75\x6e\x74\x65\x72\x5f\x6c\x61\x62\x65\x6c\x7d\x3e\x43\x6c\x69\x63\x6b\x65\x64\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x20\x74\x69\x6d\x65\x73\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[430,425]]

//# yix-map view.yix
