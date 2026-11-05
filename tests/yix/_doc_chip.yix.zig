// GENERATED FILE, do not edit: generated from doc_chip.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Documentation example (docs/YIX_REFERENCE.md §2.1): Chip component. Changes here must sync docs.
const ui = @import("ui");
const S = @import("_doc_chip.yss.zig");

pub const Tone = enum { neutral, accent };

/// Selectable capsule; when onRemove given, show remove button
pub fn Chip(args: anytype) ui.view.ComponentOf(__yix_Chip) {
    return ui.view.component(__yix_Chip, ui.reactive.props.coerce(ChipProps, args));
}
pub const ChipProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    tone: ui.Source(Tone) = .{ .value = .neutral },
    selected: ui.Model(bool) = .{ .local = false },
    on_change: ?ui.Handler(bool) = null,
    on_remove: ?ui.Handler(void) = null,
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Chip;
    pub const __yix_preview_mount = __yix_Chip;
};
fn __yix_Chip(__yix_props: ChipProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const tone = __yix_props.tone;
    const onChange = __yix_props.on_change;
    const onRemove = __yix_props.on_remove;
    const __yix_model_selected = try ui.reactive.resolveModelFor(bool, scope, __yix_props.selected);
    const selected = __yix_model_selected.read;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .label = label, .tone = tone, .selected = selected, .onChange = onChange, .onRemove = onRemove, .__yix_model_selected = __yix_model_selected, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/doc_chip.yix", .path = "Chip", .receiver = "row", .tokens = "row style = S . Chip . of ( . { . tone = tone , . selected = selected } ) ; focusable = @static; focusRing = @static; a11y = . { . role = . button , . label = label , . selected = selected } ; onClick = selected = ! selected ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . Chip . of ( . { . tone = tone , . selected = selected } ) ", .kind = .style, .literal = null }, .{ .name = "focusable", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "focus_ring", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "a11y", .tokens = ". { . role = . button , . label = label , . selected = selected } ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "selected = ! selected ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .tone = __yix_view_ctx.tone, .selected = __yix_view_ctx.selected, .label = __yix_view_ctx.label, .onChange = __yix_view_ctx.onChange, .onRemove = __yix_view_ctx.onRemove, }, ui.view.row(.{ .style = S.Chip.of(.{ .tone = __yix_view_ctx.tone, .selected = __yix_view_ctx.selected }), .focusable = true, .focus_ring = true, .a11y = .{ .role = .button, .label = __yix_view_ctx.label, .selected = __yix_view_ctx.selected }, .on_click = try ui.on.bind(__yix_view_scope, .{ .selected = __yix_view_ctx.selected, .__yix_model_selected = __yix_view_ctx.__yix_model_selected, .onChange = __yix_view_ctx.onChange, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_selected.propose(!__yix_ctx.selected.peek(), __yix_ctx.onChange);  } }.__yix_run), }, .{
            ui.view.templateSite(.{ .module = "tests/yix/doc_chip.yix", .path = "Chip", .receiver = "text", .tokens = "text style = @static; label  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . label ", .kind = .style, .literal = null }, } }, .{ .label = __yix_view_ctx.label, }, ui.view.text(.{ .style = S.label, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.label), ""), .{ __yix_view_ctx.label, }))),
            ui.view.templateSite(.{ .module = "tests/yix/doc_chip.yix", .path = "Chip", .receiver = "control", .tokens = "if ( onRemove != null ) < row style = { S . remove } a11y = { . { . role = . button , . label = \"Remove\" } } onClick = { onRemove } > < text > ×</text> < / row > " }, .{ .onRemove = __yix_view_ctx.onRemove, }, ui.view.lazyIf(__yix_view_ctx.onRemove != null, .{ .onRemove = __yix_view_ctx.onRemove, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/doc_chip.yix", .path = "Chip/keyword_if:1/branch:0", .receiver = "row", .tokens = "row style = @static; a11y = . { . role = . button , . label = \"Remove\" } ; onClick = onRemove ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . remove ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = ". { . role = . button , . label = \"Remove\" } ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "onRemove ", .kind = .event, .literal = null }, } }, .{ .onRemove = __yix_b1_0.onRemove, }, ui.view.row(.{ .style = S.remove, .a11y = .{ .role = .button, .label = "Remove" }, .on_click = __yix_b1_0.onRemove, }, .{
                    ui.view.templateSite(.{ .module = "tests/yix/doc_chip.yix", .path = "Chip/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "×", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("×", .{ }))),
                })) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Chip";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x2f\x2f\x21\x20\x44\x6f\x63\x75\x6d\x65\x6e\x74\x61\x74\x69\x6f\x6e\x20\x65\x78\x61\x6d\x70\x6c\x65\x20\x28\x64\x6f\x63\x73\x2f\x59\x49\x58\x5f\x52\x45\x46\x45\x52\x45\x4e\x43\x45\x2e\x6d\x64\x20\xc2\xa7\x32\x2e\x31\x29\x3a\x20\x43\x68\x69\x70\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x2e\x20\x43\x68\x61\x6e\x67\x65\x73\x20\x68\x65\x72\x65\x20\x6d\x75\x73\x74\x20\x73\x79\x6e\x63\x20\x64\x6f\x63\x73\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x64\x6f\x63\x5f\x63\x68\x69\x70\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x54\x6f\x6e\x65\x20\x3d\x20\x65\x6e\x75\x6d\x20\x7b\x20\x6e\x65\x75\x74\x72\x61\x6c\x2c\x20\x61\x63\x63\x65\x6e\x74\x20\x7d\x3b\x0a\x0a\x2f\x2f\x2f\x20\x53\x65\x6c\x65\x63\x74\x61\x62\x6c\x65\x20\x63\x61\x70\x73\x75\x6c\x65\x3b\x20\x77\x68\x65\x6e\x20\x6f\x6e\x52\x65\x6d\x6f\x76\x65\x20\x67\x69\x76\x65\x6e\x2c\x20\x73\x68\x6f\x77\x20\x72\x65\x6d\x6f\x76\x65\x20\x62\x75\x74\x74\x6f\x6e\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x68\x69\x70\x28\x0a\x20\x20\x20\x20\x6c\x61\x62\x65\x6c\x3a\x20\x54\x65\x78\x74\x20\x3d\x20\x22\x22\x2c\x0a\x20\x20\x20\x20\x74\x6f\x6e\x65\x3a\x20\x54\x6f\x6e\x65\x20\x3d\x20\x2e\x6e\x65\x75\x74\x72\x61\x6c\x2c\x0a\x20\x20\x20\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x3a\x20\x4d\x6f\x64\x65\x6c\x28\x62\x6f\x6f\x6c\x29\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x62\x6f\x6f\x6c\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x6f\x6e\x52\x65\x6d\x6f\x76\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x43\x68\x69\x70\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x74\x6f\x6e\x65\x20\x3d\x20\x74\x6f\x6e\x65\x2c\x20\x2e\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x7d\x29\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x66\x6f\x63\x75\x73\x61\x62\x6c\x65\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x66\x6f\x63\x75\x73\x52\x69\x6e\x67\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x62\x75\x74\x74\x6f\x6e\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x6c\x61\x62\x65\x6c\x2c\x20\x2e\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x7d\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x21\x73\x65\x6c\x65\x63\x74\x65\x64\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x6c\x61\x62\x65\x6c\x7d\x3e\x7b\x6c\x61\x62\x65\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x6f\x6e\x52\x65\x6d\x6f\x76\x65\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x72\x65\x6d\x6f\x76\x65\x7d\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x62\x75\x74\x74\x6f\x6e\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x22\x52\x65\x6d\x6f\x76\x65\x22\x20\x7d\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x52\x65\x6d\x6f\x76\x65\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\xc3\x97\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[281,276]]

//# yix-map doc_chip.yix
