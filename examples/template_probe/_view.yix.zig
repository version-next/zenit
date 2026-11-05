// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
const std = @import("std");
const Palette = @import("palette.zig");
pub var format_calls: usize = 0;
pub const FancyValue = struct {
    pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        format_calls += 1;
        try writer.writeAll("fancy");
    }
};
const S = struct {
    pub const A = ui.css(.{ .gap = 3 });
    pub const B = ui.css(.{ .gap = 11 });
    const Unused = ui.css(.{ .gap = 19 });
    pub const Title = ui.css(.{ .font_size = 13 });
    pub const TextOnly = ui.css(.{ .line_height = 1.9 });
    pub const HoverBox = ui.css(.{ ._hover = .{ .gap = 4 } });
    pub const UnusedTitle = ui.css(.{ .font_size = 21 });
};

pub fn Probe(args: anytype) ui.view.ComponentOf(__yix_Probe) {
    return ui.view.component(__yix_Probe, ui.reactive.props.coerce(ProbeProps, args));
}
pub const ProbeProps = struct {
    start: ui.Source(u32) = .{ .value = 0 },
    count_id: ui.Source([]const u8) = .{ .value = "lp4.count" },
    button_id: ui.Source([]const u8) = .{ .value = "lp4.increment" },
    label_id: ui.Source([]const u8) = .{ .value = "lp4.label" },
    style_id: ui.Source([]const u8) = .{ .value = "lp4.style" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Probe;
    pub const __yix_preview_mount = __yix_Probe;
};
fn __yix_Probe(__yix_props: ProbeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const start = __yix_props.start;
    const countId = __yix_props.count_id;
    const buttonId = __yix_props.button_id;
    const labelId = __yix_props.label_id;
    const styleId = __yix_props.style_id;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(u32, start.peek());
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .countId = countId, .buttonId = buttonId, .labelId = labelId, .styleId = styleId, .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .buttonId = __yix_view_ctx.buttonId, .count = __yix_view_ctx.count, .countId = __yix_view_ctx.countId, .labelId = __yix_view_ctx.labelId, .styleId = __yix_view_ctx.styleId, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "box", .tokens = "box testId = buttonId ; onClick = count += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "buttonId ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, } }, .{ .buttonId = __yix_view_ctx.buttonId, .count = __yix_view_ctx.count, }, ui.view.box(.{ .test_id = __yix_view_ctx.buttonId, .on_click = try ui.on.bind(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run), }, .{
                ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "text", .tokens = "text ", .literal_text = "Increment", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Increment", .{ }))),
            })),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "text", .tokens = "text testId = countId ; count  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "countId ", .kind = .property, .literal = null }, } }, .{ .countId = __yix_view_ctx.countId, .count = __yix_view_ctx.count, }, ui.view.text(.{ .test_id = __yix_view_ctx.countId, }, ui.view.fmt("value " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.count, }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "text", .tokens = "text testId = labelId ; ", .literal_text = "Original", .attributes = &.{ .{ .name = "test_id", .tokens = "labelId ", .kind = .property, .literal = null }, } }, .{ .labelId = __yix_view_ctx.labelId, }, ui.view.text(.{ .test_id = __yix_view_ctx.labelId, }, ui.view.fmt("Original", .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "box", .tokens = "box testId = styleId ; style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "styleId ", .kind = .property, .literal = null }, .{ .name = "style", .tokens = "S . A ", .kind = .style, .literal = null }, } }, .{ .styleId = __yix_view_ctx.styleId, }, ui.view.box(.{ .test_id = __yix_view_ctx.styleId, .style = S.A, }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Probe", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . B ", .kind = .style, .literal = null }, } }, .{ }, ui.view.box(.{ .style = S.B, }, .{ })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Probe";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}


pub fn Fancy(args: anytype) ui.view.ComponentOf(__yix_Fancy) {
    return ui.view.component(__yix_Fancy, ui.reactive.props.coerce(FancyProps, args));
}
pub const FancyProps = struct {
    custom: ui.Source(FancyValue) = .{ .value = .{} },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Fancy;
    pub const __yix_preview_mount = __yix_Fancy;
};
fn __yix_Fancy(__yix_props: FancyProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const custom = __yix_props.custom;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .custom = custom, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Fancy", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .custom = __yix_view_ctx.custom, }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Fancy", .receiver = "text", .tokens = "text custom  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .custom = __yix_view_ctx.custom, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.custom), ""), .{ __yix_view_ctx.custom, }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Fancy", .receiver = "text", .tokens = "text ", .literal_text = "OriginalFancy", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("OriginalFancy", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Fancy";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn DerivedProbe(args: anytype) ui.view.ComponentOf(__yix_DerivedProbe) {
    return ui.view.component(__yix_DerivedProbe, ui.reactive.props.coerce(DerivedProbeProps, args));
}
pub const DerivedProbeProps = struct {
    value: ui.Source(u32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = DerivedProbe;
    pub const __yix_preview_mount = __yix_DerivedProbe;
};
fn __yix_DerivedProbe(__yix_props: DerivedProbeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const value = __yix_props.value;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "DerivedProbe", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .value = __yix_view_ctx.value, }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "DerivedProbe", .receiver = "text", .tokens = "text value + 1  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .value = __yix_view_ctx.value, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.value.peek() + 1);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .value = __yix_view_ctx.value, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.value.get() + 1;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.value.peek() + 1);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .value = __yix_view_ctx.value, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.value.get() + 1;
        } }.__yix_compute);
    }, }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "DerivedProbe", .receiver = "text", .tokens = "text ", .literal_text = "DerivedOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("DerivedOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "DerivedProbe";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}


pub fn Literals(args: anytype) ui.view.ComponentOf(__yix_Literals) {
    return ui.view.component(__yix_Literals, ui.reactive.props.coerce(LiteralsProps, args));
}
pub const LiteralsProps = struct {
    start: ui.Source(u32) = .{ .value = 4 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Literals;
    pub const __yix_preview_mount = __yix_Literals;
};
fn __yix_Literals(__yix_props: LiteralsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const start = __yix_props.start;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(u32, start.peek());
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Literals", .receiver = "box", .tokens = "box testId = @static; visible = @static; style = @static; onClick = count += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"literal.root\" ", .kind = .property, .literal = .{ .text = "literal.root" } }, .{ .name = "visible", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "style", .tokens = ". { . gap = 2 } ", .kind = .style, .literal = null }, .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, }, ui.view.box(.{ .test_id = "literal.root", .visible = true, .style = .{ .gap = 2 }, .on_click = try ui.on.bind(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run), }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "Literals", .receiver = "text", .tokens = "text testId = @static; style = @static; count  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"literal.text\" ", .kind = .property, .literal = .{ .text = "literal.text" } }, .{ .name = "style", .tokens = "S . Title ", .kind = .style, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ .test_id = "literal.text", .style = S.Title, }, ui.view.fmt("before " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), "") ++ " after", .{ __yix_view_ctx.count, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Literals";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

// The imported style namespace is compiled by this module but never mounted by Probe.
pub fn PaletteCatalog(args: anytype) ui.view.ComponentOf(__yix_PaletteCatalog) {
    return ui.view.component(__yix_PaletteCatalog, ui.reactive.props.coerce(PaletteCatalogProps, args));
}
pub const PaletteCatalogProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PaletteCatalog;
    pub const __yix_preview_mount = __yix_PaletteCatalog;
};
fn __yix_PaletteCatalog(__yix_props: PaletteCatalogProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/view.yix", .path = "PaletteCatalog", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "Palette . Unused ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ .style = Palette.Unused, }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PaletteCatalog";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x73\x74\x64\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x64\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x50\x61\x6c\x65\x74\x74\x65\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x70\x61\x6c\x65\x74\x74\x65\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x66\x6f\x72\x6d\x61\x74\x5f\x63\x61\x6c\x6c\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x46\x61\x6e\x63\x79\x56\x61\x6c\x75\x65\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x66\x6e\x20\x66\x6f\x72\x6d\x61\x74\x28\x5f\x3a\x20\x40\x54\x68\x69\x73\x28\x29\x2c\x20\x77\x72\x69\x74\x65\x72\x3a\x20\x2a\x73\x74\x64\x2e\x49\x6f\x2e\x57\x72\x69\x74\x65\x72\x29\x20\x73\x74\x64\x2e\x49\x6f\x2e\x57\x72\x69\x74\x65\x72\x2e\x45\x72\x72\x6f\x72\x21\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x66\x6f\x72\x6d\x61\x74\x5f\x63\x61\x6c\x6c\x73\x20\x2b\x3d\x20\x31\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x74\x72\x79\x20\x77\x72\x69\x74\x65\x72\x2e\x77\x72\x69\x74\x65\x41\x6c\x6c\x28\x22\x66\x61\x6e\x63\x79\x22\x29\x3b\x0a\x20\x20\x20\x20\x7d\x0a\x7d\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x41\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x33\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x42\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x31\x31\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x55\x6e\x75\x73\x65\x64\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x31\x39\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x54\x69\x74\x6c\x65\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x66\x6f\x6e\x74\x5f\x73\x69\x7a\x65\x20\x3d\x20\x31\x33\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x54\x65\x78\x74\x4f\x6e\x6c\x79\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x6c\x69\x6e\x65\x5f\x68\x65\x69\x67\x68\x74\x20\x3d\x20\x31\x2e\x39\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x48\x6f\x76\x65\x72\x42\x6f\x78\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x5f\x68\x6f\x76\x65\x72\x20\x3d\x20\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x34\x20\x7d\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x55\x6e\x75\x73\x65\x64\x54\x69\x74\x6c\x65\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x66\x6f\x6e\x74\x5f\x73\x69\x7a\x65\x20\x3d\x20\x32\x31\x20\x7d\x29\x3b\x0a\x7d\x3b\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x72\x6f\x62\x65\x28\x73\x74\x61\x72\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x30\x2c\x20\x63\x6f\x75\x6e\x74\x49\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x34\x2e\x63\x6f\x75\x6e\x74\x22\x2c\x20\x62\x75\x74\x74\x6f\x6e\x49\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x34\x2e\x69\x6e\x63\x72\x65\x6d\x65\x6e\x74\x22\x2c\x20\x6c\x61\x62\x65\x6c\x49\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x34\x2e\x6c\x61\x62\x65\x6c\x22\x2c\x20\x73\x74\x79\x6c\x65\x49\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x34\x2e\x73\x74\x79\x6c\x65\x22\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x73\x74\x61\x72\x74\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x62\x75\x74\x74\x6f\x6e\x49\x64\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x49\x6e\x63\x72\x65\x6d\x65\x6e\x74\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x63\x6f\x75\x6e\x74\x49\x64\x7d\x3e\x76\x61\x6c\x75\x65\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x6c\x61\x62\x65\x6c\x49\x64\x7d\x3e\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x73\x74\x79\x6c\x65\x49\x64\x7d\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x41\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x42\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x61\x6e\x63\x79\x28\x63\x75\x73\x74\x6f\x6d\x3a\x20\x46\x61\x6e\x63\x79\x56\x61\x6c\x75\x65\x20\x3d\x20\x2e\x7b\x7d\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x63\x75\x73\x74\x6f\x6d\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x74\x65\x78\x74\x3e\x4f\x72\x69\x67\x69\x6e\x61\x6c\x46\x61\x6e\x63\x79\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x44\x65\x72\x69\x76\x65\x64\x50\x72\x6f\x62\x65\x28\x76\x61\x6c\x75\x65\x3a\x20\x75\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x76\x61\x6c\x75\x65\x20\x2b\x20\x31\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x74\x65\x78\x74\x3e\x44\x65\x72\x69\x76\x65\x64\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x69\x74\x65\x72\x61\x6c\x73\x28\x73\x74\x61\x72\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x34\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x73\x74\x61\x72\x74\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x69\x74\x65\x72\x61\x6c\x2e\x72\x6f\x6f\x74\x22\x20\x76\x69\x73\x69\x62\x6c\x65\x3d\x7b\x74\x72\x75\x65\x7d\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x32\x20\x7d\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x69\x74\x65\x72\x61\x6c\x2e\x74\x65\x78\x74\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x54\x69\x74\x6c\x65\x7d\x3e\x62\x65\x66\x6f\x72\x65\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x20\x61\x66\x74\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x54\x68\x65\x20\x69\x6d\x70\x6f\x72\x74\x65\x64\x20\x73\x74\x79\x6c\x65\x20\x6e\x61\x6d\x65\x73\x70\x61\x63\x65\x20\x69\x73\x20\x63\x6f\x6d\x70\x69\x6c\x65\x64\x20\x62\x79\x20\x74\x68\x69\x73\x20\x6d\x6f\x64\x75\x6c\x65\x20\x62\x75\x74\x20\x6e\x65\x76\x65\x72\x20\x6d\x6f\x75\x6e\x74\x65\x64\x20\x62\x79\x20\x50\x72\x6f\x62\x65\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x61\x6c\x65\x74\x74\x65\x43\x61\x74\x61\x6c\x6f\x67\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x50\x61\x6c\x65\x74\x74\x65\x2e\x55\x6e\x75\x73\x65\x64\x7d\x2f\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"Palette " = Palette, .@"S . A " = S.A, .@"S . B " = S.B, .@"S . Unused " = S.Unused, .@"S . Title " = S.Title, .@"S . TextOnly " = S.TextOnly, .@"S . HoverBox " = S.HoverBox, .@"S . UnusedTitle " = S.UnusedTitle, }) else void;

//# yix-map-data [[698,698],[5714,1239],[7769,1359],[10485,1482],[13583,1836]]

//# yix-map view.yix
