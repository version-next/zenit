// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const Button = ui.widgets.Button;

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

/// Each window mounts one: signal built on that window's own scope, clicking only affects this
/// window.
pub fn WindowUi(args: anytype) ui.view.ComponentOf(__yix_WindowUi) {
    return ui.view.component(__yix_WindowUi, ui.reactive.props.coerce(WindowUiProps, args));
}
pub const WindowUiProps = struct {
    tag: ui.Source([]const u8),
    heading: ui.Source([]const u8),
    button: ui.Source([]const u8),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = WindowUi;
    pub const __yix_preview_mount = __yix_WindowUi;
};
fn __yix_WindowUi(__yix_props: WindowUiProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const tag = __yix_props.tag;
    const heading = __yix_props.heading;
    const button = __yix_props.button;
    try ui.view.previewCheckSetup(scope, true);
    const clicks = try scope.createSignalFor(u32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .tag = tag, .heading = heading, .button = button, .clicks = clicks, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/multi_window/view.yix", .path = "WindowUi", .receiver = "col", .tokens = "col style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . root ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .heading = __yix_view_ctx.heading, .button = __yix_view_ctx.button, .clicks = __yix_view_ctx.clicks, .tag = __yix_view_ctx.tag, }, ui.view.col(.{ .style = S.root, }, .{
            ui.view.templateSite(.{ .module = "examples/multi_window/view.yix", .path = "WindowUi", .receiver = "text", .tokens = "text style = @static; heading  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . heading ", .kind = .style, .literal = null }, } }, .{ .heading = __yix_view_ctx.heading, }, ui.view.text(.{ .style = S.heading, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.heading), ""), .{ __yix_view_ctx.heading, }))),
            ui.view.templateSite(.{ .module = "examples/multi_window/view.yix", .path = "WindowUi", .receiver = "Button", .tokens = "< Button label = { button } variant = { . primary } onClick = { clicks += 1 } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "button ", .kind = .property, .literal = null }, .{ .name = "variant", .tokens = ". primary ", .kind = .property, .literal = .{ .enum_name = "primary" } }, .{ .name = "on_click", .tokens = "clicks += 1 ", .kind = .event, .literal = null }, } }, .{ .button = __yix_view_ctx.button, .clicks = __yix_view_ctx.clicks, }, __yix_builder_449: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_449 Button(.{ .label = __yix_view_ctx.button, .variant = .primary, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .clicks = __yix_view_ctx.clicks, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.clicks.set(__yix_ctx.clicks.peek() + (1));  } }.__yix_run)), }); }),
            ui.view.templateSite(.{ .module = "examples/multi_window/view.yix", .path = "WindowUi", .receiver = "text", .tokens = "text style = @static; tag  @interpolation clicks  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . caption ", .kind = .style, .literal = null }, } }, .{ .tag = __yix_view_ctx.tag, .clicks = __yix_view_ctx.clicks, }, ui.view.text(.{ .style = S.caption, }, ui.view.fmt("[" ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.tag), "") ++ "] clicked " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.clicks), "") ++ " times", .{ __yix_view_ctx.tag, __yix_view_ctx.clicks, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "WindowUi";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x42\x75\x74\x74\x6f\x6e\x20\x3d\x20\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x2e\x42\x75\x74\x74\x6f\x6e\x3b\x0a\x0a\x2f\x2f\x2f\x20\x53\x74\x79\x6c\x65\x73\x20\x69\x6e\x20\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x2f\x2f\x2f\x20\x45\x61\x63\x68\x20\x77\x69\x6e\x64\x6f\x77\x20\x6d\x6f\x75\x6e\x74\x73\x20\x6f\x6e\x65\x3a\x20\x73\x69\x67\x6e\x61\x6c\x20\x62\x75\x69\x6c\x74\x20\x6f\x6e\x20\x74\x68\x61\x74\x20\x77\x69\x6e\x64\x6f\x77\x27\x73\x20\x6f\x77\x6e\x20\x73\x63\x6f\x70\x65\x2c\x20\x63\x6c\x69\x63\x6b\x69\x6e\x67\x20\x6f\x6e\x6c\x79\x20\x61\x66\x66\x65\x63\x74\x73\x20\x74\x68\x69\x73\x0a\x2f\x2f\x2f\x20\x77\x69\x6e\x64\x6f\x77\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x57\x69\x6e\x64\x6f\x77\x55\x69\x28\x74\x61\x67\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x68\x65\x61\x64\x69\x6e\x67\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x62\x75\x74\x74\x6f\x6e\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6c\x69\x63\x6b\x73\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x72\x6f\x6f\x74\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x68\x65\x61\x64\x69\x6e\x67\x7d\x3e\x7b\x68\x65\x61\x64\x69\x6e\x67\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x62\x75\x74\x74\x6f\x6e\x7d\x20\x76\x61\x72\x69\x61\x6e\x74\x3d\x7b\x2e\x70\x72\x69\x6d\x61\x72\x79\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6c\x69\x63\x6b\x73\x20\x2b\x3d\x20\x31\x7d\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x63\x61\x70\x74\x69\x6f\x6e\x7d\x3e\x5b\x7b\x74\x61\x67\x7d\x5d\x20\x63\x6c\x69\x63\x6b\x65\x64\x20\x7b\x63\x6c\x69\x63\x6b\x73\x7d\x20\x74\x69\x6d\x65\x73\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[237,232]]

//# yix-map view.yix
