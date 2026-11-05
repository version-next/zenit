// GENERATED FILE, do not edit: generated from regions.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
pub const Mode = enum { a, b };
const S = struct {
    pub const A = ui.css(.{ .gap = 3 });
    pub const B = ui.css(.{ .gap = 17 });
};
pub var mounts: usize = 0;
pub var unmounts: usize = 0;
fn mounted() void { mounts += 1; }
fn unmounted() void { unmounts += 1; }
pub fn Row(args: anytype) ui.view.ComponentOf(__yix_Row) {
    return ui.view.component(__yix_Row, ui.reactive.props.coerce(RowProps, args));
}
pub const RowProps = struct {
    id: ui.Source([]const u8) = .{ .value = "lp5.row.value" },
    button: ui.Source([]const u8) = .{ .value = "lp5.row.button" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Row;
    pub const __yix_preview_mount = __yix_Row;
};
fn __yix_Row(__yix_props: RowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const id = __yix_props.id;
    const button = __yix_props.button;
    try ui.view.previewCheckSetup(scope, true);
    const value = try scope.createSignalFor(u32, 5);
    try ui.view.setupCleanup(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onUnmount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); unmounted();  } }.__yix_run);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .id = id, .button = button, .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Row", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .button = __yix_view_ctx.button, .value = __yix_view_ctx.value, .id = __yix_view_ctx.id, }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Row", .receiver = "box", .tokens = "box testId = button ; onClick = value += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "button ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "value += 1 ", .kind = .event, .literal = null }, } }, .{ .button = __yix_view_ctx.button, .value = __yix_view_ctx.value, }, ui.view.box(.{ .test_id = __yix_view_ctx.button, .on_click = try ui.on.bind(__yix_view_scope, .{ .value = __yix_view_ctx.value, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.value.set(__yix_ctx.value.peek() + (1));  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Row", .receiver = "text", .tokens = "text testId = id ; value  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "id ", .kind = .property, .literal = null }, } }, .{ .id = __yix_view_ctx.id, .value = __yix_view_ctx.value, }, ui.view.text(.{ .test_id = __yix_view_ctx.id, }, ui.view.fmt("row " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Row";
    return __yix_root;
    } }.__yix_render);
    try ui.view.runLifecycleAction(scope, "onMount", .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onMount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); mounted();  } }.__yix_run);
    return __yix_view;

}
pub fn Regions(args: anytype) ui.view.ComponentOf(__yix_Regions) {
    return ui.view.component(__yix_Regions, ui.reactive.props.coerce(RegionsProps, args));
}
pub const RegionsProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Regions;
    pub const __yix_preview_mount = __yix_Regions;
};
fn __yix_Regions(__yix_props: RegionsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const items = try scope.createSignalFor([]const u32, &.{1, 2});
    const shown = try scope.createSignalFor(bool, true);
    const mode = try scope.createSignalFor(Mode, .a);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .items = items, .shown = shown, .mode = mode, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .items = __yix_view_ctx.items, .shown = __yix_view_ctx.shown, .mode = __yix_view_ctx.mode, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "box", .tokens = "box testId = @static; onClick = items = & . { 1 , 2 , 3 } ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.list.add\" ", .kind = .property, .literal = .{ .text = "lp5.list.add" } }, .{ .name = "on_click", .tokens = "items = & . { 1 , 2 , 3 } ", .kind = .event, .literal = null }, } }, .{ .items = __yix_view_ctx.items, }, ui.view.box(.{ .test_id = "lp5.list.add", .on_click = try ui.on.bind(__yix_view_scope, .{ .items = __yix_view_ctx.items, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.items.set(&.{1, 2, 3});  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "box", .tokens = "box testId = @static; onClick = items = & . { 2 } ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.list.remove\" ", .kind = .property, .literal = .{ .text = "lp5.list.remove" } }, .{ .name = "on_click", .tokens = "items = & . { 2 } ", .kind = .event, .literal = null }, } }, .{ .items = __yix_view_ctx.items, }, ui.view.box(.{ .test_id = "lp5.list.remove", .on_click = try ui.on.bind(__yix_view_scope, .{ .items = __yix_view_ctx.items, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.items.set(&.{2});  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "control", .tokens = "for ( items ) | item | < box key = { item } > < Row / > < text > RowOriginal < / text > < / box > " }, .{ .items = __yix_view_ctx.items, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.items; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(item); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; _ = item; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_for:1", .receiver = "box", .tokens = "box key = item ; ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "item ", .kind = .property, .literal = null }, } }, .{ }, ui.view.box(.{ }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_for:1", .receiver = "Row", .tokens = "< Row / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_35: { try ui.view.previewCheckBuilder(__yix_scope_1, Row); break :__yix_builder_35 Row(.{ }); }),
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_for:1", .receiver = "text", .tokens = "text ", .literal_text = "RowOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("RowOriginal", .{ }))),
                }))); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "control", .tokens = "if ( shown ) < box > < text testId = \"lp5.if\" > IfOriginal < / text > < / box > else < text testId = \"lp5.if.else\" > IfElse < / text > " }, .{ .shown = __yix_view_ctx.shown, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_if:2/branch:0", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.box(.{ }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_if:2/branch:0", .receiver = "text", .tokens = "text testId = @static; ", .literal_text = "IfOriginal", .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.if\" ", .kind = .property, .literal = .{ .text = "lp5.if" } }, } }, .{ }, ui.view.text(.{ .test_id = "lp5.if", }, ui.view.fmt("IfOriginal", .{ }))),
                })) }); } }.__yix_b, struct { fn __yix_b(__yix_b2_1: anytype, __yix_bs2_1: *ui.Scope, __yix_bc2_1: *ui.Cx, __yix_bk2_1: ui.view.Sink) anyerror!void { _ = __yix_b2_1; return ui.view.emit(__yix_bs2_1, __yix_bc2_1, __yix_bk2_1, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_if:2/branch:1", .receiver = "text", .tokens = "text testId = @static; ", .literal_text = "IfElse", .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.if.else\" ", .kind = .property, .literal = .{ .text = "lp5.if.else" } }, } }, .{ }, ui.view.text(.{ .test_id = "lp5.if.else", }, ui.view.fmt("IfElse", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions", .receiver = "control", .tokens = "switch ( mode ) { . a => < box > < text testId = \"lp5.match\" > MatchOriginal < / text > < / box > , . b => < text testId = \"lp5.match.else\" > MatchElse < / text > } " }, .{ .mode = __yix_view_ctx.mode, }, ui.view.lazySwitch(__yix_view_ctx.mode, .{ }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bt3_0: anytype, __yix_bv3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { _ = __yix_b3_0; _ = __yix_bv3_0; switch (__yix_bt3_0) { .a => { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_switch:3/case:.a", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.box(.{ }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_switch:3/case:.a", .receiver = "text", .tokens = "text testId = @static; ", .literal_text = "MatchOriginal", .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.match\" ", .kind = .property, .literal = .{ .text = "lp5.match" } }, } }, .{ }, ui.view.text(.{ .test_id = "lp5.match", }, ui.view.fmt("MatchOriginal", .{ }))),
                })) }); }, .b => { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Regions/keyword_switch:3/case:.b", .receiver = "text", .tokens = "text testId = @static; ", .literal_text = "MatchElse", .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.match.else\" ", .kind = .property, .literal = .{ .text = "lp5.match.else" } }, } }, .{ }, ui.view.text(.{ .test_id = "lp5.match.else", }, ui.view.fmt("MatchElse", .{ }))) }); }, } } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Regions";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn SlotFrame(args: anytype) ui.view.SlottedOf(__yix_SlotFrame) {
    return ui.view.slotted(__yix_SlotFrame, ui.reactive.props.coerce(SlotFrameProps, args));
}
pub const SlotFrameProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = SlotFrame;
    pub const __yix_preview_mount = __yix_SlotFrame;
};
fn __yix_SlotFrame(__yix_props: SlotFrameProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    _ = __yix_view_ctx;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    var __yix_slot_header: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "SlotFrame", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "SlotFrame", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.slotEnd(&__yix_slot_header, ui.view.box(.{ }, .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "SlotFrame", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ }, .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "SlotFrame";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ .header = __yix_slot_header, });
    } }.__yix_render);
    return __yix_view;

}
pub fn Slots(args: anytype) ui.view.ComponentOf(__yix_Slots) {
    return ui.view.component(__yix_Slots, ui.reactive.props.coerce(SlotsProps, args));
}
pub const SlotsProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Slots;
    pub const __yix_preview_mount = __yix_Slots;
};
fn __yix_Slots(__yix_props: SlotsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const value = try scope.createSignalFor(u32, 11);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .value = __yix_view_ctx.value, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "box", .tokens = "box testId = @static; onClick = value += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.slot.button\" ", .kind = .property, .literal = .{ .text = "lp5.slot.button" } }, .{ .name = "on_click", .tokens = "value += 1 ", .kind = .event, .literal = null }, } }, .{ .value = __yix_view_ctx.value, }, ui.view.box(.{ .test_id = "lp5.slot.button", .on_click = try ui.on.bind(__yix_view_scope, .{ .value = __yix_view_ctx.value, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.value.set(__yix_ctx.value.peek() + (1));  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "text", .tokens = "text testId = @static; value  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.slot.value\" ", .kind = .property, .literal = .{ .text = "lp5.slot.value" } }, } }, .{ .value = __yix_view_ctx.value, }, ui.view.text(.{ .test_id = "lp5.slot.value", }, ui.view.fmt("slot setup " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "SlotFrame", .tokens = "< SlotFrame header = { < box > < text > HeaderOriginal < / text > < / box > } > < box testId = \"lp5.slot.body\" style = { S . A } > < text > DefaultOriginal < / text > < box style = { S . B } / > < / box > < / SlotFrame > ", .literal_text = null, .attributes = &.{ .{ .name = "header", .tokens = "< box > < text > HeaderOriginal < / text > < / box > ", .kind = .property, .literal = null }, } }, .{ }, __yix_builder_1519: { try ui.view.previewCheckBuilder(__yix_view_scope, SlotFrame); break :__yix_builder_1519 ui.view.with(SlotFrame(.{ }), .{
                ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "box", .tokens = "box testId = @static; style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"lp5.slot.body\" ", .kind = .property, .literal = .{ .text = "lp5.slot.body" } }, .{ .name = "style", .tokens = "S . A ", .kind = .style, .literal = null }, } }, .{ }, ui.view.box(.{ .test_id = "lp5.slot.body", .style = S.A, }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "text", .tokens = "text ", .literal_text = "DefaultOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("DefaultOriginal", .{ }))),
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . B ", .kind = .style, .literal = null }, } }, .{ }, ui.view.box(.{ .style = S.B, }, .{ })),
                })),
            }).slots(.{ .header = ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots/slot:header", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.box(.{ }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Slots/slot:header", .receiver = "text", .tokens = "text ", .literal_text = "HeaderOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("HeaderOriginal", .{ }))),
                })), }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Slots";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Moves(args: anytype) ui.view.ComponentOf(__yix_Moves) {
    return ui.view.component(__yix_Moves, ui.reactive.props.coerce(MovesProps, args));
}
pub const MovesProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Moves;
    pub const __yix_preview_mount = __yix_Moves;
};
fn __yix_Moves(__yix_props: MovesProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Moves", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Moves", .receiver = "Row", .tokens = "< Row id = \"lp5.left\" button = \"lp5.left.button\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"lp5.left\" ", .kind = .property, .literal = .{ .text = "lp5.left" } }, .{ .name = "button", .tokens = "\"lp5.left.button\" ", .kind = .property, .literal = .{ .text = "lp5.left.button" } }, } }, .{ }, __yix_builder_1731: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_1731 Row(.{ .id = "lp5.left", .button = "lp5.left.button", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Moves", .receiver = "text", .tokens = "text ", .literal_text = "MoveDivider", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("MoveDivider", .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Moves", .receiver = "Row", .tokens = "< Row id = \"lp5.right\" button = \"lp5.right.button\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"lp5.right\" ", .kind = .property, .literal = .{ .text = "lp5.right" } }, .{ .name = "button", .tokens = "\"lp5.right.button\" ", .kind = .property, .literal = .{ .text = "lp5.right.button" } }, } }, .{ }, __yix_builder_1800: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_1800 Row(.{ .id = "lp5.right", .button = "lp5.right.button", }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Moves";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn Ambiguous(args: anytype) ui.view.ComponentOf(__yix_Ambiguous) {
    return ui.view.component(__yix_Ambiguous, ui.reactive.props.coerce(AmbiguousProps, args));
}
pub const AmbiguousProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Ambiguous;
    pub const __yix_preview_mount = __yix_Ambiguous;
};
fn __yix_Ambiguous(__yix_props: AmbiguousProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Ambiguous", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Ambiguous", .receiver = "Row", .tokens = "< Row / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_1899: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_1899 Row(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Ambiguous", .receiver = "Row", .tokens = "< Row / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_1905: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_1905 Row(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Ambiguous", .receiver = "text", .tokens = "text ", .literal_text = "AmbiguousOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("AmbiguousOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Ambiguous";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn AllocatorMoves(args: anytype) ui.view.ComponentOf(__yix_AllocatorMoves) {
    return ui.view.component(__yix_AllocatorMoves, ui.reactive.props.coerce(AllocatorMovesProps, args));
}
pub const AllocatorMovesProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = AllocatorMoves;
    pub const __yix_preview_mount = __yix_AllocatorMoves;
};
fn __yix_AllocatorMoves(__yix_props: AllocatorMovesProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.left\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.left\" ", .kind = .property, .literal = .{ .text = "alloc.left" } }, } }, .{ }, __yix_builder_1999: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_1999 Row(.{ .id = "alloc.left", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "text", .tokens = "text ", .literal_text = "alloc divider", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("alloc divider", .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.right\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.right\" ", .kind = .property, .literal = .{ .text = "alloc.right" } }, } }, .{ }, __yix_builder_2047: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2047 Row(.{ .id = "alloc.right", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.0\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.0\" ", .kind = .property, .literal = .{ .text = "alloc.0" } }, } }, .{ }, __yix_builder_2079: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2079 Row(.{ .id = "alloc.0", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.1\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.1\" ", .kind = .property, .literal = .{ .text = "alloc.1" } }, } }, .{ }, __yix_builder_2098: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2098 Row(.{ .id = "alloc.1", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.2\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.2\" ", .kind = .property, .literal = .{ .text = "alloc.2" } }, } }, .{ }, __yix_builder_2117: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2117 Row(.{ .id = "alloc.2", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.3\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.3\" ", .kind = .property, .literal = .{ .text = "alloc.3" } }, } }, .{ }, __yix_builder_2136: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2136 Row(.{ .id = "alloc.3", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.4\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.4\" ", .kind = .property, .literal = .{ .text = "alloc.4" } }, } }, .{ }, __yix_builder_2164: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2164 Row(.{ .id = "alloc.4", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.5\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.5\" ", .kind = .property, .literal = .{ .text = "alloc.5" } }, } }, .{ }, __yix_builder_2183: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2183 Row(.{ .id = "alloc.5", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.6\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.6\" ", .kind = .property, .literal = .{ .text = "alloc.6" } }, } }, .{ }, __yix_builder_2202: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2202 Row(.{ .id = "alloc.6", }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "AllocatorMoves", .receiver = "Row", .tokens = "< Row id = \"alloc.7\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"alloc.7\" ", .kind = .property, .literal = .{ .text = "alloc.7" } }, } }, .{ }, __yix_builder_2221: { try ui.view.previewCheckBuilder(__yix_view_scope, Row); break :__yix_builder_2221 Row(.{ .id = "alloc.7", }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "AllocatorMoves";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn NestedDerived(args: anytype) ui.view.ComponentOf(__yix_NestedDerived) {
    return ui.view.component(__yix_NestedDerived, ui.reactive.props.coerce(NestedDerivedProps, args));
}
pub const NestedDerivedProps = struct {
    bad: ui.Source(bool),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = NestedDerived;
    pub const __yix_preview_mount = __yix_NestedDerived;
};
fn __yix_NestedDerived(__yix_props: NestedDerivedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const bad = __yix_props.bad;
    try ui.view.previewCheckSetup(scope, true);
    const shown = try scope.createSignalFor(bool, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .bad = bad, .shown = shown, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shown = __yix_view_ctx.shown, .bad = __yix_view_ctx.bad, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived", .receiver = "control", .tokens = "if ( shown ) < box > { if ( bad ) < text > nested < / text > } < text > NestedOriginal < / text > < / box > " }, .{ .shown = __yix_view_ctx.shown, .bad = __yix_view_ctx.bad, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ .bad = __yix_view_ctx.bad, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived/keyword_if:1/branch:0", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ .bad = __yix_b1_0.bad, }, ui.view.box(.{ }, .{
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived/keyword_if:1/branch:0", .receiver = "control", .tokens = "if ( bad ) < text > nested < / text > " }, .{ .bad = __yix_b1_0.bad, }, ui.view.lazyIf(__yix_b1_0.bad, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived/keyword_if:1/branch:0/keyword_if:2/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "nested", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("nested", .{ }))) }); } }.__yix_b, null)),
                    ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "NestedDerived/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "NestedOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("NestedOriginal", .{ }))),
                })) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "NestedDerived";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Branchless(args: anytype) ui.view.ComponentOf(__yix_Branchless) {
    return ui.view.component(__yix_Branchless, ui.reactive.props.coerce(BranchlessProps, args));
}
pub const BranchlessProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Branchless;
    pub const __yix_preview_mount = __yix_Branchless;
};
fn __yix_Branchless(__yix_props: BranchlessProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const shown = try scope.createSignalFor(bool, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .shown = shown, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Branchless", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shown = __yix_view_ctx.shown, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Branchless", .receiver = "control", .tokens = "if ( shown ) < text > SingleBranch < / text > " }, .{ .shown = __yix_view_ctx.shown, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Branchless/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "SingleBranch", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("SingleBranch", .{ }))) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Branchless";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub const CaseMode = enum { a, b, c };
pub fn Cases(args: anytype) ui.view.ComponentOf(__yix_Cases) {
    return ui.view.component(__yix_Cases, ui.reactive.props.coerce(CasesProps, args));
}
pub const CasesProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Cases;
    pub const __yix_preview_mount = __yix_Cases;
};
fn __yix_Cases(__yix_props: CasesProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const selected = try scope.createSignalFor(CaseMode, .a);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .selected = selected, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Cases", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .selected = __yix_view_ctx.selected, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Cases", .receiver = "control", .tokens = "switch ( selected ) { . a => < text > CaseA < / text > , else => < text > CaseDefault < / text > } " }, .{ .selected = __yix_view_ctx.selected, }, ui.view.lazySwitch(__yix_view_ctx.selected, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bt1_0: anytype, __yix_bv1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; _ = __yix_bv1_0; switch (__yix_bt1_0) { .a => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Cases/keyword_switch:1/case:.a", .receiver = "text", .tokens = "text ", .literal_text = "CaseA", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("CaseA", .{ }))) }); }, else => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/regions.yix", .path = "Cases/keyword_switch:1/case:else", .receiver = "text", .tokens = "text ", .literal_text = "CaseDefault", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("CaseDefault", .{ }))) }); }, } } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Cases";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x4d\x6f\x64\x65\x20\x3d\x20\x65\x6e\x75\x6d\x20\x7b\x20\x61\x2c\x20\x62\x20\x7d\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x41\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x33\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x42\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x31\x37\x20\x7d\x29\x3b\x0a\x7d\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6d\x6f\x75\x6e\x74\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x66\x6e\x20\x6d\x6f\x75\x6e\x74\x65\x64\x28\x29\x20\x76\x6f\x69\x64\x20\x7b\x20\x6d\x6f\x75\x6e\x74\x73\x20\x2b\x3d\x20\x31\x3b\x20\x7d\x0a\x66\x6e\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x65\x64\x28\x29\x20\x76\x6f\x69\x64\x20\x7b\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x73\x20\x2b\x3d\x20\x31\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x6f\x77\x28\x69\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x35\x2e\x72\x6f\x77\x2e\x76\x61\x6c\x75\x65\x22\x2c\x20\x62\x75\x74\x74\x6f\x6e\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x6c\x70\x35\x2e\x72\x6f\x77\x2e\x62\x75\x74\x74\x6f\x6e\x22\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x76\x61\x6c\x75\x65\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x35\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x28\x6d\x6f\x75\x6e\x74\x65\x64\x28\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x75\x6e\x6d\x6f\x75\x6e\x74\x65\x64\x28\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x62\x75\x74\x74\x6f\x6e\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x76\x61\x6c\x75\x65\x20\x2b\x3d\x20\x31\x7d\x2f\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x69\x64\x7d\x3e\x72\x6f\x77\x20\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x65\x67\x69\x6f\x6e\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x69\x74\x65\x6d\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x2e\x7b\x31\x2c\x20\x32\x7d\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6d\x6f\x64\x65\x3a\x20\x4d\x6f\x64\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x2e\x61\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x6c\x69\x73\x74\x2e\x61\x64\x64\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x74\x65\x6d\x73\x20\x3d\x20\x26\x2e\x7b\x31\x2c\x20\x32\x2c\x20\x33\x7d\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x6c\x69\x73\x74\x2e\x72\x65\x6d\x6f\x76\x65\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x74\x65\x6d\x73\x20\x3d\x20\x26\x2e\x7b\x32\x7d\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x72\x20\x28\x69\x74\x65\x6d\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x62\x6f\x78\x20\x6b\x65\x79\x3d\x7b\x69\x74\x65\x6d\x7d\x3e\x3c\x52\x6f\x77\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x52\x6f\x77\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x3c\x62\x6f\x78\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x69\x66\x22\x3e\x49\x66\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x69\x66\x2e\x65\x6c\x73\x65\x22\x3e\x49\x66\x45\x6c\x73\x65\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x73\x77\x69\x74\x63\x68\x20\x28\x6d\x6f\x64\x65\x29\x20\x7b\x20\x2e\x61\x20\x3d\x3e\x20\x3c\x62\x6f\x78\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x6d\x61\x74\x63\x68\x22\x3e\x4d\x61\x74\x63\x68\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x2c\x20\x2e\x62\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x6d\x61\x74\x63\x68\x2e\x65\x6c\x73\x65\x22\x3e\x4d\x61\x74\x63\x68\x45\x6c\x73\x65\x3c\x2f\x74\x65\x78\x74\x3e\x20\x7d\x7d\x0a\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x6c\x6f\x74\x46\x72\x61\x6d\x65\x28\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x2c\x20\x68\x65\x61\x64\x65\x72\x3a\x20\x56\x69\x65\x77\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x62\x6f\x78\x3e\x7b\x68\x65\x61\x64\x65\x72\x7d\x3c\x2f\x62\x6f\x78\x3e\x3c\x62\x6f\x78\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x62\x6f\x78\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x6c\x6f\x74\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x76\x61\x6c\x75\x65\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x31\x31\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x73\x6c\x6f\x74\x2e\x62\x75\x74\x74\x6f\x6e\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x76\x61\x6c\x75\x65\x20\x2b\x3d\x20\x31\x7d\x2f\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x73\x6c\x6f\x74\x2e\x76\x61\x6c\x75\x65\x22\x3e\x73\x6c\x6f\x74\x20\x73\x65\x74\x75\x70\x20\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x53\x6c\x6f\x74\x46\x72\x61\x6d\x65\x20\x68\x65\x61\x64\x65\x72\x3d\x7b\x3c\x62\x6f\x78\x3e\x3c\x74\x65\x78\x74\x3e\x48\x65\x61\x64\x65\x72\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x7d\x3e\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x70\x35\x2e\x73\x6c\x6f\x74\x2e\x62\x6f\x64\x79\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x41\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x44\x65\x66\x61\x75\x6c\x74\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x42\x7d\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x3c\x2f\x53\x6c\x6f\x74\x46\x72\x61\x6d\x65\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x4d\x6f\x76\x65\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x6c\x70\x35\x2e\x6c\x65\x66\x74\x22\x20\x62\x75\x74\x74\x6f\x6e\x3d\x22\x6c\x70\x35\x2e\x6c\x65\x66\x74\x2e\x62\x75\x74\x74\x6f\x6e\x22\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x4d\x6f\x76\x65\x44\x69\x76\x69\x64\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x6c\x70\x35\x2e\x72\x69\x67\x68\x74\x22\x20\x62\x75\x74\x74\x6f\x6e\x3d\x22\x6c\x70\x35\x2e\x72\x69\x67\x68\x74\x2e\x62\x75\x74\x74\x6f\x6e\x22\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x41\x6d\x62\x69\x67\x75\x6f\x75\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x52\x6f\x77\x2f\x3e\x3c\x52\x6f\x77\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x41\x6d\x62\x69\x67\x75\x6f\x75\x73\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x41\x6c\x6c\x6f\x63\x61\x74\x6f\x72\x4d\x6f\x76\x65\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x6c\x65\x66\x74\x22\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x61\x6c\x6c\x6f\x63\x20\x64\x69\x76\x69\x64\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x72\x69\x67\x68\x74\x22\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x30\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x31\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x32\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x33\x22\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x34\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x35\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x36\x22\x2f\x3e\x3c\x52\x6f\x77\x20\x69\x64\x3d\x22\x61\x6c\x6c\x6f\x63\x2e\x37\x22\x2f\x3e\x0a\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x4e\x65\x73\x74\x65\x64\x44\x65\x72\x69\x76\x65\x64\x28\x62\x61\x64\x3a\x20\x62\x6f\x6f\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x3c\x62\x6f\x78\x3e\x7b\x69\x66\x20\x28\x62\x61\x64\x29\x20\x3c\x74\x65\x78\x74\x3e\x6e\x65\x73\x74\x65\x64\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x74\x65\x78\x74\x3e\x4e\x65\x73\x74\x65\x64\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x72\x61\x6e\x63\x68\x6c\x65\x73\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x3c\x74\x65\x78\x74\x3e\x53\x69\x6e\x67\x6c\x65\x42\x72\x61\x6e\x63\x68\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x43\x61\x73\x65\x4d\x6f\x64\x65\x20\x3d\x20\x65\x6e\x75\x6d\x20\x7b\x20\x61\x2c\x20\x62\x2c\x20\x63\x20\x7d\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x61\x73\x65\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x3a\x20\x43\x61\x73\x65\x4d\x6f\x64\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x2e\x61\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x73\x77\x69\x74\x63\x68\x20\x28\x73\x65\x6c\x65\x63\x74\x65\x64\x29\x20\x7b\x20\x2e\x61\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x43\x61\x73\x65\x41\x3c\x2f\x74\x65\x78\x74\x3e\x2c\x20\x65\x6c\x73\x65\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x43\x61\x73\x65\x44\x65\x66\x61\x75\x6c\x74\x3c\x2f\x74\x65\x78\x74\x3e\x20\x7d\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S . A " = S.A, .@"S . B " = S.B, }) else void;

//# yix-map-data [[297,297],[3945,577],[12779,1225],[14878,1345],[20017,1697],[22876,1861],[25168,1956],[31472,2260],[35034,2443],[37322,2610]]

//# yix-map regions.yix
