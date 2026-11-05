// GENERATED FILE, do not edit: generated from other.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
pub fn Other(args: anytype) ui.view.ComponentOf(__yix_Other) {
    return ui.view.component(__yix_Other, ui.reactive.props.coerce(OtherProps, args));
}
pub const OtherProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Other;
    pub const __yix_preview_mount = __yix_Other;
};
fn __yix_Other(__yix_props: OtherProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/other.yix", .path = "Other", .receiver = "box", .tokens = "box testId = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"other.original\" ", .kind = .property, .literal = .{ .text = "other.original" } }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ .test_id = "other.original", }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/other.yix", .path = "Other", .receiver = "text", .tokens = "text ", .literal_text = "OriginalOther", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("OriginalOther", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Other";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x4f\x74\x68\x65\x72\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6f\x74\x68\x65\x72\x2e\x6f\x72\x69\x67\x69\x6e\x61\x6c\x22\x3e\x3c\x74\x65\x78\x74\x3e\x4f\x72\x69\x67\x69\x6e\x61\x6c\x4f\x74\x68\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ }) else void;

//# yix-map-data [[30,30]]

//# yix-map other.yix
