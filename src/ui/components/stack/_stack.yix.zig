// GENERATED FILE, do not edit: generated from stack.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! VStack / HStack / Spacer views. Children passed via ui.view.with(W.VStack(...), .{ ... }) or Yix
//! tag children.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Vertical stack: <W.VStack gap={8}>…</W.VStack>
pub fn VStack(args: anytype) ui.view.SlottedOf(__yix_VStack) {
    return ui.view.slotted(__yix_VStack, ui.reactive.props.coerce(VStackProps, args));
}
pub const VStackProps = struct {
    gap: ui.Source(f32) = .{ .value = 0 },
    justify: ui.Source(ui.JustifyContent) = .{ .value = .start },
    align_items: ui.Source(ui.AlignItems) = .{ .value = .stretch },
    width: ui.Source(?f32) = .{ .value = null },
    height: ui.Source(?f32) = .{ .value = null },
    padding: ui.Source(?ui.Padding) = .{ .value = null },
    background: ui.Source(?ui.Color) = .{ .value = null },
    reverse: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = VStack;
    pub const __yix_preview_mount = __yix_VStack;
};
fn __yix_VStack(__yix_props: VStackProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const gap = __yix_props.gap;
    const justify = __yix_props.justify;
    const alignItems = __yix_props.align_items;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const padding = __yix_props.padding;
    const background = __yix_props.background;
    const reverse = __yix_props.reverse;
    try ui.view.previewCheckSetup(scope, true);
    const direction = __yix_d1: {
        const __yix_T = @TypeOf(if (reverse.peek()) ui.Direction.column_reverse else .column);
        break :__yix_d1 try scope.derive(__yix_T, .{ .reverse = reverse, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.reverse.get()) ui.Direction.column_reverse else .column;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .gap = gap, .justify = justify, .alignItems = alignItems, .width = width, .height = height, .padding = padding, .background = background, .direction = direction, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/stack/stack.yix", .path = "VStack", .receiver = "box", .tokens = "box style = S . stack . of ( . { . direction = direction , . gap = gap , . justify = justify , . align_items = alignItems , . width = width , . height = height , . padding = padding , . background = background } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . stack . of ( . { . direction = direction , . gap = gap , . justify = justify , . align_items = alignItems , . width = width , . height = height , . padding = padding , . background = background } ) ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .direction = __yix_view_ctx.direction, .gap = __yix_view_ctx.gap, .justify = __yix_view_ctx.justify, .alignItems = __yix_view_ctx.alignItems, .width = __yix_view_ctx.width, .height = __yix_view_ctx.height, .padding = __yix_view_ctx.padding, .background = __yix_view_ctx.background, }, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.stack.of(.{ .direction = __yix_view_ctx.direction, .gap = __yix_view_ctx.gap, .justify = __yix_view_ctx.justify, .align_items = __yix_view_ctx.alignItems, .width = __yix_view_ctx.width, .height = __yix_view_ctx.height, .padding = __yix_view_ctx.padding, .background = __yix_view_ctx.background }), }, .{ }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "VStack";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });
    } }.__yix_render);
    return __yix_view;

}

/// Horizontal stack: <W.HStack gap={8} wrap>…</W.HStack>
pub fn HStack(args: anytype) ui.view.SlottedOf(__yix_HStack) {
    return ui.view.slotted(__yix_HStack, ui.reactive.props.coerce(HStackProps, args));
}
pub const HStackProps = struct {
    gap: ui.Source(f32) = .{ .value = 0 },
    justify: ui.Source(ui.JustifyContent) = .{ .value = .start },
    align_items: ui.Source(ui.AlignItems) = .{ .value = .center },
    width: ui.Source(?f32) = .{ .value = null },
    height: ui.Source(?f32) = .{ .value = null },
    padding: ui.Source(?ui.Padding) = .{ .value = null },
    background: ui.Source(?ui.Color) = .{ .value = null },
    reverse: ui.Source(bool) = .{ .value = false },
    wrap: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = HStack;
    pub const __yix_preview_mount = __yix_HStack;
};
fn __yix_HStack(__yix_props: HStackProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const gap = __yix_props.gap;
    const justify = __yix_props.justify;
    const alignItems = __yix_props.align_items;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const padding = __yix_props.padding;
    const background = __yix_props.background;
    const reverse = __yix_props.reverse;
    const wrap = __yix_props.wrap;
    try ui.view.previewCheckSetup(scope, true);
    const direction = __yix_d1: {
        const __yix_T = @TypeOf(if (reverse.peek()) ui.Direction.row_reverse else .row);
        break :__yix_d1 try scope.derive(__yix_T, .{ .reverse = reverse, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.reverse.get()) ui.Direction.row_reverse else .row;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .gap = gap, .justify = justify, .alignItems = alignItems, .width = width, .height = height, .padding = padding, .background = background, .wrap = wrap, .direction = direction, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/stack/stack.yix", .path = "HStack", .receiver = "box", .tokens = "box style = S . stack . of ( . { . direction = direction , . gap = gap , . justify = justify , . align_items = alignItems , . width = width , . height = height , . padding = padding , . background = background , . wrap = wrap } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . stack . of ( . { . direction = direction , . gap = gap , . justify = justify , . align_items = alignItems , . width = width , . height = height , . padding = padding , . background = background , . wrap = wrap } ) ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .direction = __yix_view_ctx.direction, .gap = __yix_view_ctx.gap, .justify = __yix_view_ctx.justify, .alignItems = __yix_view_ctx.alignItems, .width = __yix_view_ctx.width, .height = __yix_view_ctx.height, .padding = __yix_view_ctx.padding, .background = __yix_view_ctx.background, .wrap = __yix_view_ctx.wrap, }, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.stack.of(.{ .direction = __yix_view_ctx.direction, .gap = __yix_view_ctx.gap, .justify = __yix_view_ctx.justify, .align_items = __yix_view_ctx.alignItems, .width = __yix_view_ctx.width, .height = __yix_view_ctx.height, .padding = __yix_view_ctx.padding, .background = __yix_view_ctx.background, .wrap = __yix_view_ctx.wrap }), }, .{ }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "HStack";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });
    } }.__yix_render);
    return __yix_view;

}

/// Elastic spacing: occupies remaining space in stack
pub fn Spacer(args: anytype) ui.view.ComponentOf(__yix_Spacer) {
    return ui.view.component(__yix_Spacer, ui.reactive.props.coerce(SpacerProps, args));
}
pub const SpacerProps = struct {
    min_size: ui.Source(f32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Spacer;
    pub const __yix_preview_mount = __yix_Spacer;
};
fn __yix_Spacer(__yix_props: SpacerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const minSize = __yix_props.min_size;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .minSize = minSize, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/stack/stack.yix", .path = "Spacer", .receiver = "box", .tokens = "box style = S . spacer . of ( . { . min_size = minSize } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . spacer . of ( . { . min_size = minSize } ) ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .minSize = __yix_view_ctx.minSize, }, ui.view.box(.{ .style = S.spacer.of(.{ .min_size = __yix_view_ctx.minSize }), }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Spacer";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x2f\x2f\x21\x20\x56\x53\x74\x61\x63\x6b\x20\x2f\x20\x48\x53\x74\x61\x63\x6b\x20\x2f\x20\x53\x70\x61\x63\x65\x72\x20\x76\x69\x65\x77\x73\x2e\x20\x43\x68\x69\x6c\x64\x72\x65\x6e\x20\x70\x61\x73\x73\x65\x64\x20\x76\x69\x61\x20\x75\x69\x2e\x76\x69\x65\x77\x2e\x77\x69\x74\x68\x28\x57\x2e\x56\x53\x74\x61\x63\x6b\x28\x2e\x2e\x2e\x29\x2c\x20\x2e\x7b\x20\x2e\x2e\x2e\x20\x7d\x29\x20\x6f\x72\x20\x59\x69\x78\x0a\x2f\x2f\x21\x20\x74\x61\x67\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x2e\x2e\x2f\x2e\x2e\x2f\x75\x69\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x2f\x2f\x2f\x20\x56\x65\x72\x74\x69\x63\x61\x6c\x20\x73\x74\x61\x63\x6b\x3a\x20\x3c\x57\x2e\x56\x53\x74\x61\x63\x6b\x20\x67\x61\x70\x3d\x7b\x38\x7d\x3e\xe2\x80\xa6\x3c\x2f\x57\x2e\x56\x53\x74\x61\x63\x6b\x3e\x0a\x70\x75\x62\x20\x66\x6e\x20\x56\x53\x74\x61\x63\x6b\x28\x0a\x20\x20\x20\x20\x67\x61\x70\x3a\x20\x66\x33\x32\x20\x3d\x20\x30\x2c\x0a\x20\x20\x20\x20\x6a\x75\x73\x74\x69\x66\x79\x3a\x20\x75\x69\x2e\x4a\x75\x73\x74\x69\x66\x79\x43\x6f\x6e\x74\x65\x6e\x74\x20\x3d\x20\x2e\x73\x74\x61\x72\x74\x2c\x0a\x20\x20\x20\x20\x61\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x3a\x20\x75\x69\x2e\x41\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x20\x3d\x20\x2e\x73\x74\x72\x65\x74\x63\x68\x2c\x0a\x20\x20\x20\x20\x77\x69\x64\x74\x68\x3a\x20\x3f\x66\x33\x32\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x68\x65\x69\x67\x68\x74\x3a\x20\x3f\x66\x33\x32\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x70\x61\x64\x64\x69\x6e\x67\x3a\x20\x3f\x75\x69\x2e\x50\x61\x64\x64\x69\x6e\x67\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x3a\x20\x3f\x75\x69\x2e\x43\x6f\x6c\x6f\x72\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x72\x65\x76\x65\x72\x73\x65\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x2c\x0a\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x66\x20\x28\x72\x65\x76\x65\x72\x73\x65\x29\x20\x75\x69\x2e\x44\x69\x72\x65\x63\x74\x69\x6f\x6e\x2e\x63\x6f\x6c\x75\x6d\x6e\x5f\x72\x65\x76\x65\x72\x73\x65\x20\x65\x6c\x73\x65\x20\x2e\x63\x6f\x6c\x75\x6d\x6e\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x74\x61\x63\x6b\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x20\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x2c\x20\x2e\x67\x61\x70\x20\x3d\x20\x67\x61\x70\x2c\x20\x2e\x6a\x75\x73\x74\x69\x66\x79\x20\x3d\x20\x6a\x75\x73\x74\x69\x66\x79\x2c\x20\x2e\x61\x6c\x69\x67\x6e\x5f\x69\x74\x65\x6d\x73\x20\x3d\x20\x61\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x2c\x20\x2e\x77\x69\x64\x74\x68\x20\x3d\x20\x77\x69\x64\x74\x68\x2c\x20\x2e\x68\x65\x69\x67\x68\x74\x20\x3d\x20\x68\x65\x69\x67\x68\x74\x2c\x20\x2e\x70\x61\x64\x64\x69\x6e\x67\x20\x3d\x20\x70\x61\x64\x64\x69\x6e\x67\x2c\x20\x2e\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x20\x3d\x20\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x20\x7d\x29\x7d\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x48\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x73\x74\x61\x63\x6b\x3a\x20\x3c\x57\x2e\x48\x53\x74\x61\x63\x6b\x20\x67\x61\x70\x3d\x7b\x38\x7d\x20\x77\x72\x61\x70\x3e\xe2\x80\xa6\x3c\x2f\x57\x2e\x48\x53\x74\x61\x63\x6b\x3e\x0a\x70\x75\x62\x20\x66\x6e\x20\x48\x53\x74\x61\x63\x6b\x28\x0a\x20\x20\x20\x20\x67\x61\x70\x3a\x20\x66\x33\x32\x20\x3d\x20\x30\x2c\x0a\x20\x20\x20\x20\x6a\x75\x73\x74\x69\x66\x79\x3a\x20\x75\x69\x2e\x4a\x75\x73\x74\x69\x66\x79\x43\x6f\x6e\x74\x65\x6e\x74\x20\x3d\x20\x2e\x73\x74\x61\x72\x74\x2c\x0a\x20\x20\x20\x20\x61\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x3a\x20\x75\x69\x2e\x41\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x20\x3d\x20\x2e\x63\x65\x6e\x74\x65\x72\x2c\x0a\x20\x20\x20\x20\x77\x69\x64\x74\x68\x3a\x20\x3f\x66\x33\x32\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x68\x65\x69\x67\x68\x74\x3a\x20\x3f\x66\x33\x32\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x70\x61\x64\x64\x69\x6e\x67\x3a\x20\x3f\x75\x69\x2e\x50\x61\x64\x64\x69\x6e\x67\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x3a\x20\x3f\x75\x69\x2e\x43\x6f\x6c\x6f\x72\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x72\x65\x76\x65\x72\x73\x65\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x77\x72\x61\x70\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x2c\x0a\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x66\x20\x28\x72\x65\x76\x65\x72\x73\x65\x29\x20\x75\x69\x2e\x44\x69\x72\x65\x63\x74\x69\x6f\x6e\x2e\x72\x6f\x77\x5f\x72\x65\x76\x65\x72\x73\x65\x20\x65\x6c\x73\x65\x20\x2e\x72\x6f\x77\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x74\x61\x63\x6b\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x20\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x2c\x20\x2e\x67\x61\x70\x20\x3d\x20\x67\x61\x70\x2c\x20\x2e\x6a\x75\x73\x74\x69\x66\x79\x20\x3d\x20\x6a\x75\x73\x74\x69\x66\x79\x2c\x20\x2e\x61\x6c\x69\x67\x6e\x5f\x69\x74\x65\x6d\x73\x20\x3d\x20\x61\x6c\x69\x67\x6e\x49\x74\x65\x6d\x73\x2c\x20\x2e\x77\x69\x64\x74\x68\x20\x3d\x20\x77\x69\x64\x74\x68\x2c\x20\x2e\x68\x65\x69\x67\x68\x74\x20\x3d\x20\x68\x65\x69\x67\x68\x74\x2c\x20\x2e\x70\x61\x64\x64\x69\x6e\x67\x20\x3d\x20\x70\x61\x64\x64\x69\x6e\x67\x2c\x20\x2e\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x20\x3d\x20\x62\x61\x63\x6b\x67\x72\x6f\x75\x6e\x64\x2c\x20\x2e\x77\x72\x61\x70\x20\x3d\x20\x77\x72\x61\x70\x20\x7d\x29\x7d\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x45\x6c\x61\x73\x74\x69\x63\x20\x73\x70\x61\x63\x69\x6e\x67\x3a\x20\x6f\x63\x63\x75\x70\x69\x65\x73\x20\x72\x65\x6d\x61\x69\x6e\x69\x6e\x67\x20\x73\x70\x61\x63\x65\x20\x69\x6e\x20\x73\x74\x61\x63\x6b\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x70\x61\x63\x65\x72\x28\x6d\x69\x6e\x53\x69\x7a\x65\x3a\x20\x66\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x70\x61\x63\x65\x72\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x6d\x69\x6e\x5f\x73\x69\x7a\x65\x20\x3d\x20\x6d\x69\x6e\x53\x69\x7a\x65\x20\x7d\x29\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[251,246],[4158,905],[8235,1590]]

//# yix-map stack.yix
