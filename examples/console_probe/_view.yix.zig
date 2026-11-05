// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");

/// Styles in styles.yss
const S = @import("_styles.yss.zig");

pub fn Target(args: anytype) ui.view.ComponentOf(__yix_Target) {
    return ui.view.component(__yix_Target, ui.reactive.props.coerce(TargetProps, args));
}
pub const TargetProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Target;
    pub const __yix_preview_mount = __yix_Target;
};
fn __yix_Target(__yix_props: TargetProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/console_probe/view.yix", .path = "Target", .receiver = "col", .tokens = "col style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . root ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ .style = S.root, }, .{
            ui.view.templateSite(.{ .module = "examples/console_probe/view.yix", .path = "Target", .receiver = "text", .tokens = "text style = @static; ", .literal_text = "Console probe target", .attributes = &.{ .{ .name = "style", .tokens = "S . title ", .kind = .style, .literal = null }, } }, .{ }, ui.view.text(.{ .style = S.title, }, ui.view.fmt("Console probe target", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Target";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x0a\x2f\x2f\x2f\x20\x53\x74\x79\x6c\x65\x73\x20\x69\x6e\x20\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x61\x72\x67\x65\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x72\x6f\x6f\x74\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x74\x69\x74\x6c\x65\x7d\x3e\x43\x6f\x6e\x73\x6f\x6c\x65\x20\x70\x72\x6f\x62\x65\x20\x74\x61\x72\x67\x65\x74\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[95,90]]

//# yix-map view.yix
