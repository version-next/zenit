// GENERATED FILE, do not edit: generated from fixture.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! yix-lsp smoke fixture: built-in components (hand-written Zig) and this file's Yix components,
//! test property / tag name completion.
const ui = @import("../../../src/ui/ui.zig");
const W = ui.widgets;

pub fn Card2(args: anytype) ui.view.ComponentOf(__yix_Card2) {
    return ui.view.component(__yix_Card2, ui.reactive.props.coerce(Card2Props, args));
}
pub const Card2Props = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    count: ui.Source(i32) = .{ .value = 0 },
    on_pick: ?ui.Handler(void) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Card2;
    pub const __yix_preview_mount = __yix_Card2;
};
fn __yix_Card2(__yix_props: Card2Props, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const count = __yix_props.count;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Card2", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, .count = __yix_view_ctx.count, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Card2", .receiver = "text", .tokens = "text title  @interpolation count  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .title = __yix_view_ctx.title, .count = __yix_view_ctx.count, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.title), "") ++ " " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.title, __yix_view_ctx.count, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Card2";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Demo(args: anytype) ui.view.ComponentOf(__yix_Demo) {
    return ui.view.component(__yix_Demo, ui.reactive.props.coerce(DemoProps, args));
}
pub const DemoProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Demo;
    pub const __yix_preview_mount = __yix_Demo;
};
fn __yix_Demo(__yix_props: DemoProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Demo", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Demo", .receiver = "W.Button", .tokens = "< W . Button label = \"Save\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "\"Save\" ", .kind = .property, .literal = .{ .text = "Save" } }, } }, .{ }, __yix_builder_414: { try ui.view.previewCheckBuilder(__yix_view_scope, W.Button); break :__yix_builder_414 W.Button(.{ .label = "Save", }); }),
            ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Demo", .receiver = "Card2", .tokens = "< Card2 title = \"a\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "title", .tokens = "\"a\" ", .kind = .property, .literal = .{ .text = "a" } }, } }, .{ }, __yix_builder_452: { try ui.view.previewCheckBuilder(__yix_view_scope, Card2); break :__yix_builder_452 Card2(.{ .title = "a", }); }),
            ui.view.templateSite(.{ .module = "tests/yix/lsp/fixture.yix", .path = "Demo", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.row(.{ }, .{ })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Demo";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x2f\x2f\x21\x20\x79\x69\x78\x2d\x6c\x73\x70\x20\x73\x6d\x6f\x6b\x65\x20\x66\x69\x78\x74\x75\x72\x65\x3a\x20\x62\x75\x69\x6c\x74\x2d\x69\x6e\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x73\x20\x28\x68\x61\x6e\x64\x2d\x77\x72\x69\x74\x74\x65\x6e\x20\x5a\x69\x67\x29\x20\x61\x6e\x64\x20\x74\x68\x69\x73\x20\x66\x69\x6c\x65\x27\x73\x20\x59\x69\x78\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x73\x2c\x0a\x2f\x2f\x21\x20\x74\x65\x73\x74\x20\x70\x72\x6f\x70\x65\x72\x74\x79\x20\x2f\x20\x74\x61\x67\x20\x6e\x61\x6d\x65\x20\x63\x6f\x6d\x70\x6c\x65\x74\x69\x6f\x6e\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x2e\x2e\x2f\x2e\x2e\x2f\x2e\x2e\x2f\x73\x72\x63\x2f\x75\x69\x2f\x75\x69\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x57\x20\x3d\x20\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x3b\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x61\x72\x64\x32\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x22\x2c\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x2c\x20\x6f\x6e\x50\x69\x63\x6b\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x74\x69\x74\x6c\x65\x7d\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x44\x65\x6d\x6f\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x57\x2e\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x22\x53\x61\x76\x65\x22\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x43\x61\x72\x64\x32\x20\x74\x69\x74\x6c\x65\x3d\x22\x61\x22\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ }) else void;

//# yix-map-data [[212,212],[2289,358]]

//# yix-map fixture.yix
