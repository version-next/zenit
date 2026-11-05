// GENERATED FILE, do not edit: generated from remount.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
pub const Mode = enum { a, b };
pub var mounts: usize = 0;
pub var unmounts: usize = 0;
pub var unsafe_calls: usize = 0;
pub var fail_mount: bool = false;
pub var parent_ref: ?*ui.view.Ref(*ui.Node) = null;
fn remember(r: *ui.view.Ref(*ui.Node)) void { parent_ref = r; }
pub var mounted_hook: ?*const fn () anyerror!void = null;
pub var unmounted_hook: ?*const fn () void = null;
fn didMount() !void {
    if (fail_mount) return error.ProbeMountFailed;
    mounts += 1;
    if (mounted_hook) |hook| try hook();
}
fn didUnmount() void { unmounts += 1; if (unmounted_hook) |hook| hook(); }
fn unknownSetup() u32 { unsafe_calls += 1; return 0; }

pub fn Child(args: anytype) ui.view.ComponentOf(__yix_Child) {
    return ui.view.component(__yix_Child, ui.reactive.props.coerce(ChildProps, args));
}
pub const ChildProps = struct {
    id: ui.Source([]const u8) = .{ .value = "r3.child" },
    button: ui.Source([]const u8) = .{ .value = "r3.child.button" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Child;
    pub const __yix_preview_mount = __yix_Child;
};
fn __yix_Child(__yix_props: ChildProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const id = __yix_props.id;
    const button = __yix_props.button;
    try ui.view.previewCheckSetup(scope, true);
    const value = try scope.createSignalFor(u32, 3);
    try ui.view.setupCleanup(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onUnmount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); didUnmount();  } }.__yix_run);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .id = id, .button = button, .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Child", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .button = __yix_view_ctx.button, .value = __yix_view_ctx.value, .id = __yix_view_ctx.id, }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Child", .receiver = "box", .tokens = "box testId = button ; onClick = value += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "button ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "value += 1 ", .kind = .event, .literal = null }, } }, .{ .button = __yix_view_ctx.button, .value = __yix_view_ctx.value, }, ui.view.box(.{ .test_id = __yix_view_ctx.button, .on_click = try ui.on.bind(__yix_view_scope, .{ .value = __yix_view_ctx.value, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.value.set(__yix_ctx.value.peek() + (1));  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Child", .receiver = "text", .tokens = "text testId = id ; value  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "id ", .kind = .property, .literal = null }, } }, .{ .id = __yix_view_ctx.id, .value = __yix_view_ctx.value, }, ui.view.text(.{ .test_id = __yix_view_ctx.id, }, ui.view.fmt("child " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Child";
    return __yix_root;
    } }.__yix_render);
    try ui.view.runLifecycleAction(scope, "onMount", .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) anyerror!void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onMount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); try didMount();  } }.__yix_run);
    return __yix_view;

}

pub fn Parent(args: anytype) ui.view.ComponentOf(__yix_Parent) {
    return ui.view.component(__yix_Parent, ui.reactive.props.coerce(ParentProps, args));
}
pub const ParentProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Parent;
    pub const __yix_preview_mount = __yix_Parent;
};
fn __yix_Parent(__yix_props: ParentProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(u32, 7);
    const items = try scope.createSignalFor([]const u32, &.{1, 2});
    const shown = try scope.createSignalFor(bool, true);
    const mode = try scope.createSignalFor(Mode, .a);
    const handle = try ui.view.createRef(scope, *ui.Node);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, .items = items, .shown = shown, .mode = mode, .handle = handle, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, .handle = __yix_view_ctx.handle, .items = __yix_view_ctx.items, .shown = __yix_view_ctx.shown, .mode = __yix_view_ctx.mode, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "box", .tokens = "box testId = @static; onClick = count += 1 ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"r3.parent.button\" ", .kind = .property, .literal = .{ .text = "r3.parent.button" } }, .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, ui.view.box(.{ .test_id = "r3.parent.button", .on_click = try ui.on.bind(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "text", .tokens = "text testId = @static; count  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"r3.parent\" ", .kind = .property, .literal = .{ .text = "r3.parent" } }, } }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ .test_id = "r3.parent", }, ui.view.fmt("parent " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.count, }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "text", .tokens = "text ", .literal_text = "RemountOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("RemountOriginal", .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "Child", .tokens = "< Child ref = { handle } / > ", .literal_text = null, .attributes = &.{ .{ .name = "ref", .tokens = "handle ", .kind = .reference, .literal = null }, } }, .{ .handle = __yix_view_ctx.handle, }, ui.view.ref(__yix_view_ctx.handle, __yix_builder_1364: { try ui.view.previewCheckBuilder(__yix_view_scope, Child); break :__yix_builder_1364 Child(.{ }); })),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "box", .tokens = "box testId = @static; onClick = items = & . { 1 , 2 , 3 } ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"r3.list.add\" ", .kind = .property, .literal = .{ .text = "r3.list.add" } }, .{ .name = "on_click", .tokens = "items = & . { 1 , 2 , 3 } ", .kind = .event, .literal = null }, } }, .{ .items = __yix_view_ctx.items, }, ui.view.box(.{ .test_id = "r3.list.add", .on_click = try ui.on.bind(__yix_view_scope, .{ .items = __yix_view_ctx.items, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.items.set(&.{1, 2, 3});  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "box", .tokens = "box testId = @static; onClick = items = & . { 2 } ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"r3.list.remove\" ", .kind = .property, .literal = .{ .text = "r3.list.remove" } }, .{ .name = "on_click", .tokens = "items = & . { 2 } ", .kind = .event, .literal = null }, } }, .{ .items = __yix_view_ctx.items, }, ui.view.box(.{ .test_id = "r3.list.remove", .on_click = try ui.on.bind(__yix_view_scope, .{ .items = __yix_view_ctx.items, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.items.set(&.{2});  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "text", .tokens = "text testId = @static; ", .literal_text = "ListOriginal", .attributes = &.{ .{ .name = "test_id", .tokens = "\"r3.list.title\" ", .kind = .property, .literal = .{ .text = "r3.list.title" } }, } }, .{ }, ui.view.text(.{ .test_id = "r3.list.title", }, ui.view.fmt("ListOriginal", .{ }))),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "control", .tokens = "for ( items ) | item | < Child key = { item } id = \"r3.row\" button = \"r3.row.button\" / > " }, .{ .items = __yix_view_ctx.items, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.items; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(item); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; _ = item; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent/keyword_for:1", .receiver = "Child", .tokens = "< Child key = { item } id = \"r3.row\" button = \"r3.row.button\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "item ", .kind = .property, .literal = null }, .{ .name = "id", .tokens = "\"r3.row\" ", .kind = .property, .literal = .{ .text = "r3.row" } }, .{ .name = "button", .tokens = "\"r3.row.button\" ", .kind = .property, .literal = .{ .text = "r3.row.button" } }, } }, .{ }, __yix_builder_19: { try ui.view.previewCheckBuilder(__yix_scope_1, Child); break :__yix_builder_19 Child(.{ .id = "r3.row", .button = "r3.row.button", }); })); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "control", .tokens = "if ( shown ) < Child id = \"r3.show\" button = \"r3.show.button\" / > else < text > hidden < / text > " }, .{ .shown = __yix_view_ctx.shown, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent/keyword_if:2/branch:0", .receiver = "Child", .tokens = "< Child id = \"r3.show\" button = \"r3.show.button\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"r3.show\" ", .kind = .property, .literal = .{ .text = "r3.show" } }, .{ .name = "button", .tokens = "\"r3.show.button\" ", .kind = .property, .literal = .{ .text = "r3.show.button" } }, } }, .{ }, __yix_builder_11: { try ui.view.previewCheckBuilder(__yix_bs2_0, Child); break :__yix_builder_11 Child(.{ .id = "r3.show", .button = "r3.show.button", }); }) }); } }.__yix_b, struct { fn __yix_b(__yix_b2_1: anytype, __yix_bs2_1: *ui.Scope, __yix_bc2_1: *ui.Cx, __yix_bk2_1: ui.view.Sink) anyerror!void { _ = __yix_b2_1; return ui.view.emit(__yix_bs2_1, __yix_bc2_1, __yix_bk2_1, .{ ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent/keyword_if:2/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "hidden", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("hidden", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent", .receiver = "control", .tokens = "switch ( mode ) { . a => < Child id = \"r3.match\" button = \"r3.match.button\" / > , . b => < text > mode b < / text > } " }, .{ .mode = __yix_view_ctx.mode, }, ui.view.lazySwitch(__yix_view_ctx.mode, .{ }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bt3_0: anytype, __yix_bv3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { _ = __yix_b3_0; _ = __yix_bv3_0; switch (__yix_bt3_0) { .a => { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent/keyword_switch:3/case:.a", .receiver = "Child", .tokens = "< Child id = \"r3.match\" button = \"r3.match.button\" / > ", .literal_text = null, .attributes = &.{ .{ .name = "id", .tokens = "\"r3.match\" ", .kind = .property, .literal = .{ .text = "r3.match" } }, .{ .name = "button", .tokens = "\"r3.match.button\" ", .kind = .property, .literal = .{ .text = "r3.match.button" } }, } }, .{ }, __yix_builder_22: { try ui.view.previewCheckBuilder(__yix_bs3_0, Child); break :__yix_builder_22 Child(.{ .id = "r3.match", .button = "r3.match.button", }); }) }); }, .b => { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "Parent/keyword_switch:3/case:.b", .receiver = "text", .tokens = "text ", .literal_text = "mode b", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("mode b", .{ }))) }); }, } } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Parent";
    return __yix_root;
    } }.__yix_render);
    try ui.view.runLifecycleAction(scope, "onMount", .{ .handle = handle, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onMount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); remember(__yix_ctx.handle);  } }.__yix_run);
    return __yix_view;

}

pub fn UnsafeChild(args: anytype) ui.view.ComponentOf(__yix_UnsafeChild) {
    return ui.view.component(__yix_UnsafeChild, ui.reactive.props.coerce(UnsafeChildProps, args));
}
pub const UnsafeChildProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = UnsafeChild;
    pub const __yix_preview_mount = __yix_UnsafeChild;
};
fn __yix_UnsafeChild(__yix_props: UnsafeChildProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, false);
    const value = unknownSetup();
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "UnsafeChild", .receiver = "text", .tokens = "text value  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .value = __yix_view_ctx.value, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "UnsafeChild";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn UnsafeParent(args: anytype) ui.view.ComponentOf(__yix_UnsafeParent) {
    return ui.view.component(__yix_UnsafeParent, ui.reactive.props.coerce(UnsafeParentProps, args));
}
pub const UnsafeParentProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = UnsafeParent;
    pub const __yix_preview_mount = __yix_UnsafeParent;
};
fn __yix_UnsafeParent(__yix_props: UnsafeParentProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "UnsafeParent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "UnsafeParent", .receiver = "UnsafeChild", .tokens = "< UnsafeChild / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2014: { try ui.view.previewCheckBuilder(__yix_view_scope, UnsafeChild); break :__yix_builder_2014 UnsafeChild(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "UnsafeParent", .receiver = "text", .tokens = "text ", .literal_text = "UnsafeOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("UnsafeOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "UnsafeParent";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const unsafeFunction: *const fn () u32 = unknownSetup;
pub fn PointerChild(args: anytype) ui.view.ComponentOf(__yix_PointerChild) {
    return ui.view.component(__yix_PointerChild, ui.reactive.props.coerce(PointerChildProps, args));
}
pub const PointerChildProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PointerChild;
    pub const __yix_preview_mount = __yix_PointerChild;
};
fn __yix_PointerChild(__yix_props: PointerChildProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, false);
    const value = unsafeFunction.*();
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "PointerChild", .receiver = "text", .tokens = "text value  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .value = __yix_view_ctx.value, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PointerChild";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PointerParent(args: anytype) ui.view.ComponentOf(__yix_PointerParent) {
    return ui.view.component(__yix_PointerParent, ui.reactive.props.coerce(PointerParentProps, args));
}
pub const PointerParentProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PointerParent;
    pub const __yix_preview_mount = __yix_PointerParent;
};
fn __yix_PointerParent(__yix_props: PointerParentProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "PointerParent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "PointerParent", .receiver = "PointerChild", .tokens = "< PointerChild / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2269: { try ui.view.previewCheckBuilder(__yix_view_scope, PointerChild); break :__yix_builder_2269 PointerChild(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "PointerParent", .receiver = "text", .tokens = "text ", .literal_text = "PointerOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("PointerOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PointerParent";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn BlockChild(args: anytype) ui.view.ComponentOf(__yix_BlockChild) {
    return ui.view.component(__yix_BlockChild, ui.reactive.props.coerce(BlockChildProps, args));
}
pub const BlockChildProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = BlockChild;
    pub const __yix_preview_mount = __yix_BlockChild;
};
fn __yix_BlockChild(__yix_props: BlockChildProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, false);
    const value: u32 = blk: { unsafe_calls += 1; break :blk 0; };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .value = value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "BlockChild", .receiver = "text", .tokens = "text value  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .value = __yix_view_ctx.value, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.value), ""), .{ __yix_view_ctx.value, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "BlockChild";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn BlockParent(args: anytype) ui.view.ComponentOf(__yix_BlockParent) {
    return ui.view.component(__yix_BlockParent, ui.reactive.props.coerce(BlockParentProps, args));
}
pub const BlockParentProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = BlockParent;
    pub const __yix_preview_mount = __yix_BlockParent;
};
fn __yix_BlockParent(__yix_props: BlockParentProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "BlockParent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "BlockParent", .receiver = "BlockChild", .tokens = "< BlockChild / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2494: { try ui.view.previewCheckBuilder(__yix_view_scope, BlockChild); break :__yix_builder_2494 BlockChild(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "BlockParent", .receiver = "text", .tokens = "text ", .literal_text = "BlockOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("BlockOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "BlockParent";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

// A hand-written builder can return a generated component's exact type. Its
// return type alone must never attest the wrapper's external behavior.
const WrappedElement = @TypeOf(Child(.{}));
fn Wrapped(args: anytype) WrappedElement {
    unsafe_calls += 1;
    return Child(args);
}
pub fn WrappedParent(args: anytype) ui.view.ComponentOf(__yix_WrappedParent) {
    return ui.view.component(__yix_WrappedParent, ui.reactive.props.coerce(WrappedParentProps, args));
}
pub const WrappedParentProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = WrappedParent;
    pub const __yix_preview_mount = __yix_WrappedParent;
};
fn __yix_WrappedParent(__yix_props: WrappedParentProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "WrappedParent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "WrappedParent", .receiver = "Wrapped", .tokens = "< Wrapped / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2875: { try ui.view.previewCheckBuilder(__yix_view_scope, Wrapped); break :__yix_builder_2875 Wrapped(.{ }); }),
            ui.view.templateSite(.{ .module = "examples/template_probe/remount.yix", .path = "WrappedParent", .receiver = "text", .tokens = "text ", .literal_text = "WrappedOriginal", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("WrappedOriginal", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "WrappedParent";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x4d\x6f\x64\x65\x20\x3d\x20\x65\x6e\x75\x6d\x20\x7b\x20\x61\x2c\x20\x62\x20\x7d\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6d\x6f\x75\x6e\x74\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x75\x6e\x73\x61\x66\x65\x5f\x63\x61\x6c\x6c\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x66\x61\x69\x6c\x5f\x6d\x6f\x75\x6e\x74\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x70\x61\x72\x65\x6e\x74\x5f\x72\x65\x66\x3a\x20\x3f\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x66\x6e\x20\x72\x65\x6d\x65\x6d\x62\x65\x72\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x20\x70\x61\x72\x65\x6e\x74\x5f\x72\x65\x66\x20\x3d\x20\x72\x3b\x20\x7d\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6d\x6f\x75\x6e\x74\x65\x64\x5f\x68\x6f\x6f\x6b\x3a\x20\x3f\x2a\x63\x6f\x6e\x73\x74\x20\x66\x6e\x20\x28\x29\x20\x61\x6e\x79\x65\x72\x72\x6f\x72\x21\x76\x6f\x69\x64\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x65\x64\x5f\x68\x6f\x6f\x6b\x3a\x20\x3f\x2a\x63\x6f\x6e\x73\x74\x20\x66\x6e\x20\x28\x29\x20\x76\x6f\x69\x64\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x66\x6e\x20\x64\x69\x64\x4d\x6f\x75\x6e\x74\x28\x29\x20\x21\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x69\x66\x20\x28\x66\x61\x69\x6c\x5f\x6d\x6f\x75\x6e\x74\x29\x20\x72\x65\x74\x75\x72\x6e\x20\x65\x72\x72\x6f\x72\x2e\x50\x72\x6f\x62\x65\x4d\x6f\x75\x6e\x74\x46\x61\x69\x6c\x65\x64\x3b\x0a\x20\x20\x20\x20\x6d\x6f\x75\x6e\x74\x73\x20\x2b\x3d\x20\x31\x3b\x0a\x20\x20\x20\x20\x69\x66\x20\x28\x6d\x6f\x75\x6e\x74\x65\x64\x5f\x68\x6f\x6f\x6b\x29\x20\x7c\x68\x6f\x6f\x6b\x7c\x20\x74\x72\x79\x20\x68\x6f\x6f\x6b\x28\x29\x3b\x0a\x7d\x0a\x66\x6e\x20\x64\x69\x64\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x29\x20\x76\x6f\x69\x64\x20\x7b\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x73\x20\x2b\x3d\x20\x31\x3b\x20\x69\x66\x20\x28\x75\x6e\x6d\x6f\x75\x6e\x74\x65\x64\x5f\x68\x6f\x6f\x6b\x29\x20\x7c\x68\x6f\x6f\x6b\x7c\x20\x68\x6f\x6f\x6b\x28\x29\x3b\x20\x7d\x0a\x66\x6e\x20\x75\x6e\x6b\x6e\x6f\x77\x6e\x53\x65\x74\x75\x70\x28\x29\x20\x75\x33\x32\x20\x7b\x20\x75\x6e\x73\x61\x66\x65\x5f\x63\x61\x6c\x6c\x73\x20\x2b\x3d\x20\x31\x3b\x20\x72\x65\x74\x75\x72\x6e\x20\x30\x3b\x20\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x68\x69\x6c\x64\x28\x69\x64\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x72\x33\x2e\x63\x68\x69\x6c\x64\x22\x2c\x20\x62\x75\x74\x74\x6f\x6e\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x72\x33\x2e\x63\x68\x69\x6c\x64\x2e\x62\x75\x74\x74\x6f\x6e\x22\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x76\x61\x6c\x75\x65\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x33\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x28\x74\x72\x79\x20\x64\x69\x64\x4d\x6f\x75\x6e\x74\x28\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x64\x69\x64\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x62\x75\x74\x74\x6f\x6e\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x76\x61\x6c\x75\x65\x20\x2b\x3d\x20\x31\x7d\x2f\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x7b\x69\x64\x7d\x3e\x63\x68\x69\x6c\x64\x20\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x61\x72\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x37\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x69\x74\x65\x6d\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x2e\x7b\x31\x2c\x20\x32\x7d\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6d\x6f\x64\x65\x3a\x20\x4d\x6f\x64\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x2e\x61\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x68\x61\x6e\x64\x6c\x65\x20\x3d\x20\x72\x65\x66\x28\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x28\x72\x65\x6d\x65\x6d\x62\x65\x72\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x33\x2e\x70\x61\x72\x65\x6e\x74\x2e\x62\x75\x74\x74\x6f\x6e\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x33\x2e\x70\x61\x72\x65\x6e\x74\x22\x3e\x70\x61\x72\x65\x6e\x74\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x52\x65\x6d\x6f\x75\x6e\x74\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x43\x68\x69\x6c\x64\x20\x72\x65\x66\x3d\x7b\x68\x61\x6e\x64\x6c\x65\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x33\x2e\x6c\x69\x73\x74\x2e\x61\x64\x64\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x74\x65\x6d\x73\x20\x3d\x20\x26\x2e\x7b\x31\x2c\x20\x32\x2c\x20\x33\x7d\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x33\x2e\x6c\x69\x73\x74\x2e\x72\x65\x6d\x6f\x76\x65\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x74\x65\x6d\x73\x20\x3d\x20\x26\x2e\x7b\x32\x7d\x7d\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x33\x2e\x6c\x69\x73\x74\x2e\x74\x69\x74\x6c\x65\x22\x3e\x4c\x69\x73\x74\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x72\x20\x28\x69\x74\x65\x6d\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x43\x68\x69\x6c\x64\x20\x6b\x65\x79\x3d\x7b\x69\x74\x65\x6d\x7d\x20\x69\x64\x3d\x22\x72\x33\x2e\x72\x6f\x77\x22\x20\x62\x75\x74\x74\x6f\x6e\x3d\x22\x72\x33\x2e\x72\x6f\x77\x2e\x62\x75\x74\x74\x6f\x6e\x22\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x3c\x43\x68\x69\x6c\x64\x20\x69\x64\x3d\x22\x72\x33\x2e\x73\x68\x6f\x77\x22\x20\x62\x75\x74\x74\x6f\x6e\x3d\x22\x72\x33\x2e\x73\x68\x6f\x77\x2e\x62\x75\x74\x74\x6f\x6e\x22\x2f\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x68\x69\x64\x64\x65\x6e\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x73\x77\x69\x74\x63\x68\x20\x28\x6d\x6f\x64\x65\x29\x20\x7b\x20\x2e\x61\x20\x3d\x3e\x20\x3c\x43\x68\x69\x6c\x64\x20\x69\x64\x3d\x22\x72\x33\x2e\x6d\x61\x74\x63\x68\x22\x20\x62\x75\x74\x74\x6f\x6e\x3d\x22\x72\x33\x2e\x6d\x61\x74\x63\x68\x2e\x62\x75\x74\x74\x6f\x6e\x22\x2f\x3e\x2c\x20\x2e\x62\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x6d\x6f\x64\x65\x20\x62\x3c\x2f\x74\x65\x78\x74\x3e\x20\x7d\x7d\x0a\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x55\x6e\x73\x61\x66\x65\x43\x68\x69\x6c\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x76\x61\x6c\x75\x65\x20\x3d\x20\x75\x6e\x6b\x6e\x6f\x77\x6e\x53\x65\x74\x75\x70\x28\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x55\x6e\x73\x61\x66\x65\x50\x61\x72\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x55\x6e\x73\x61\x66\x65\x43\x68\x69\x6c\x64\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x55\x6e\x73\x61\x66\x65\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x63\x6f\x6e\x73\x74\x20\x75\x6e\x73\x61\x66\x65\x46\x75\x6e\x63\x74\x69\x6f\x6e\x3a\x20\x2a\x63\x6f\x6e\x73\x74\x20\x66\x6e\x20\x28\x29\x20\x75\x33\x32\x20\x3d\x20\x75\x6e\x6b\x6e\x6f\x77\x6e\x53\x65\x74\x75\x70\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x6f\x69\x6e\x74\x65\x72\x43\x68\x69\x6c\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x76\x61\x6c\x75\x65\x20\x3d\x20\x75\x6e\x73\x61\x66\x65\x46\x75\x6e\x63\x74\x69\x6f\x6e\x2e\x2a\x28\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x6f\x69\x6e\x74\x65\x72\x50\x61\x72\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x50\x6f\x69\x6e\x74\x65\x72\x43\x68\x69\x6c\x64\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x50\x6f\x69\x6e\x74\x65\x72\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x6c\x6f\x63\x6b\x43\x68\x69\x6c\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x76\x61\x6c\x75\x65\x3a\x20\x75\x33\x32\x20\x3d\x20\x62\x6c\x6b\x3a\x20\x7b\x20\x75\x6e\x73\x61\x66\x65\x5f\x63\x61\x6c\x6c\x73\x20\x2b\x3d\x20\x31\x3b\x20\x62\x72\x65\x61\x6b\x20\x3a\x62\x6c\x6b\x20\x30\x3b\x20\x7d\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x6c\x6f\x63\x6b\x50\x61\x72\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x42\x6c\x6f\x63\x6b\x43\x68\x69\x6c\x64\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x42\x6c\x6f\x63\x6b\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x41\x20\x68\x61\x6e\x64\x2d\x77\x72\x69\x74\x74\x65\x6e\x20\x62\x75\x69\x6c\x64\x65\x72\x20\x63\x61\x6e\x20\x72\x65\x74\x75\x72\x6e\x20\x61\x20\x67\x65\x6e\x65\x72\x61\x74\x65\x64\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x27\x73\x20\x65\x78\x61\x63\x74\x20\x74\x79\x70\x65\x2e\x20\x49\x74\x73\x0a\x2f\x2f\x20\x72\x65\x74\x75\x72\x6e\x20\x74\x79\x70\x65\x20\x61\x6c\x6f\x6e\x65\x20\x6d\x75\x73\x74\x20\x6e\x65\x76\x65\x72\x20\x61\x74\x74\x65\x73\x74\x20\x74\x68\x65\x20\x77\x72\x61\x70\x70\x65\x72\x27\x73\x20\x65\x78\x74\x65\x72\x6e\x61\x6c\x20\x62\x65\x68\x61\x76\x69\x6f\x72\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x57\x72\x61\x70\x70\x65\x64\x45\x6c\x65\x6d\x65\x6e\x74\x20\x3d\x20\x40\x54\x79\x70\x65\x4f\x66\x28\x43\x68\x69\x6c\x64\x28\x2e\x7b\x7d\x29\x29\x3b\x0a\x66\x6e\x20\x57\x72\x61\x70\x70\x65\x64\x28\x61\x72\x67\x73\x3a\x20\x61\x6e\x79\x74\x79\x70\x65\x29\x20\x57\x72\x61\x70\x70\x65\x64\x45\x6c\x65\x6d\x65\x6e\x74\x20\x7b\x0a\x20\x20\x20\x20\x75\x6e\x73\x61\x66\x65\x5f\x63\x61\x6c\x6c\x73\x20\x2b\x3d\x20\x31\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x43\x68\x69\x6c\x64\x28\x61\x72\x67\x73\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x57\x72\x61\x70\x70\x65\x64\x50\x61\x72\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x57\x72\x61\x70\x70\x65\x64\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x57\x72\x61\x70\x70\x65\x64\x4f\x72\x69\x67\x69\x6e\x61\x6c\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"unsafeFunction " = unsafeFunction, .@"WrappedElement " = WrappedElement, }) else void;

//# yix-map-data [[674,674],[4362,961],[15549,1876],[17116,1973],[19209,2125],[20791,2227],[22847,2326],[24435,2454],[26739,2833]]

//# yix-map remount.yix
