// GENERATED FILE, do not edit: generated from lifecycle_split.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");

pub var log: [512]i32 = @splat(0);
pub var log_len: usize = 0;
pub var last_ref: ?*ui.view.Ref(*ui.Node) = null;
pub var last_instance: ?*ui.view.ComponentInstance = null;
fn note(n: i32) void {
    log[log_len] = n;
    log_len += 1;
}
fn remember(r: *ui.view.Ref(*ui.Node)) void {
    last_ref = r;
    last_instance = ui.view.componentInstance(r.get().?);
    note(if (r.get() != null) 10 else 0);
}
fn attached(r: *ui.view.Ref(*ui.Node)) void {
    note(if (r.get() != null) 1 else 0);
}
fn detached(r: *ui.view.Ref(*ui.Node)) void {
    note(if (r.get() != null) -1 else -2);
}
pub fn Split(args: anytype) ui.view.ComponentOf(__yix_Split) {
    return ui.view.component(__yix_Split, ui.reactive.props.coerce(SplitProps, args));
}
pub const SplitProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Split;
    pub const __yix_preview_mount = __yix_Split;
};
fn __yix_Split(__yix_props: SplitProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(i32, 7);
    const doubled = __yix_d1: {
        const __yix_T = @TypeOf(count.peek() * 2);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() * 2;
        } }.__yix_compute);
    };
    const handle = try ui.view.createRef(scope, *ui.Node);
    try ui.view.setupCleanup(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onUnmount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); note(-10);  } }.__yix_run);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, .doubled = doubled, .handle = handle, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Split", .receiver = "col", .tokens = "< col ref = { handle } focusable = { count > 0 } onClick = { count += 1 } > < text > count { count } ; doubled { doubled } < / text > < text > template { count + 1 } < / text > < / col > ", .literal_text = null, .attributes = &.{ .{ .name = "ref", .tokens = "handle ", .kind = .reference, .literal = null }, .{ .name = "focusable", .tokens = "count > 0 ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .handle = __yix_view_ctx.handle, .count = __yix_view_ctx.count, .doubled = __yix_view_ctx.doubled, }, ui.view.ref(__yix_view_ctx.handle, ui.view.col(.{ .focusable = __yix_d2: {
        const __yix_T = @TypeOf(__yix_view_ctx.count.peek() > 0);
        break :__yix_d2 try __yix_view_scope.createMemo(__yix_T, .{ .count = __yix_view_ctx.count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() > 0;
        } }.__yix_compute);
    }, .on_click = try ui.on.bind(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run), }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Split", .receiver = "text", .tokens = "text count  @interpolation doubled  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .count = __yix_view_ctx.count, .doubled = __yix_view_ctx.doubled, }, ui.view.text(.{ }, ui.view.fmt("count " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), "") ++ "; doubled " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.doubled), ""), .{ __yix_view_ctx.count, __yix_view_ctx.doubled, }))),
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Split", .receiver = "text", .tokens = "text count + 1  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ }, ui.view.fmt("template " ++ ui.view.yixFormat(@TypeOf(__yix_d3: {
        const __yix_T = @TypeOf(__yix_view_ctx.count.peek() + 1);
        break :__yix_d3 try __yix_view_scope.createMemo(__yix_T, .{ .count = __yix_view_ctx.count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() + 1;
        } }.__yix_compute);
    }), ""), .{ __yix_d3: {
        const __yix_T = @TypeOf(__yix_view_ctx.count.peek() + 1);
        break :__yix_d3 try __yix_view_scope.createMemo(__yix_T, .{ .count = __yix_view_ctx.count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() + 1;
        } }.__yix_compute);
    }, }))),
        }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Split";
    try ui.view.setupCleanup(__yix_view_scope, .{ .handle = __yix_view_ctx.handle, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onViewDetach); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); detached(__yix_ctx.handle);  } }.__yix_run);
    try ui.view.runLifecycleAction(__yix_view_scope, "onViewAttach", .{ .handle = __yix_view_ctx.handle, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onViewAttach); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); attached(__yix_ctx.handle);  } }.__yix_run);
    return __yix_root;
    } }.__yix_render);
    try ui.view.runLifecycleAction(scope, "onMount", .{ .handle = handle, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onMount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); remember(__yix_ctx.handle);  } }.__yix_run);
    return __yix_view;

}
/// A component used directly as another component's single root.
pub fn Nested(args: anytype) ui.view.ComponentOf(__yix_Nested) {
    return ui.view.component(__yix_Nested, ui.reactive.props.coerce(NestedProps, args));
}
pub const NestedProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Nested;
    pub const __yix_preview_mount = __yix_Nested;
};
fn __yix_Nested(__yix_props: NestedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Nested", .receiver = "Split", .tokens = "< Split / > ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_1143: { try ui.view.previewCheckBuilder(__yix_view_scope, Split); break :__yix_builder_1143 Split(.{ }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Nested";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

// Both default and named slot insertion points move with each view.
pub fn Holder(args: anytype) ui.view.SlottedOf(__yix_Holder) {
    return ui.view.slotted(__yix_Holder, ui.reactive.props.coerce(HolderProps, args));
}
pub const HolderProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Holder;
    pub const __yix_preview_mount = __yix_Holder;
};
fn __yix_Holder(__yix_props: HolderProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    _ = __yix_view_ctx;
    var __yix_slot_header: ?ui.view.SlotPoint = null;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Holder", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Holder", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.slotEnd(&__yix_slot_header, ui.view.row(.{ }, .{ }))),
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Holder", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ }, .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Holder";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ .header = __yix_slot_header, });
    } }.__yix_render);
    return __yix_view;

}

pub fn Decorated(args: anytype) ui.view.ComponentOf(__yix_Decorated) {
    return ui.view.component(__yix_Decorated, ui.reactive.props.coerce(DecoratedProps, args));
}
pub const DecoratedProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Decorated;
    pub const __yix_preview_mount = __yix_Decorated;
};
fn __yix_Decorated(__yix_props: DecoratedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Decorated", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "Decorated", .receiver = "Split", .tokens = "< Split testId = \"nested attrs\" style = { . { . gap = 5 } } / > ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"nested attrs\" ", .kind = .property, .literal = .{ .text = "nested attrs" } }, .{ .name = "style", .tokens = ". { . gap = 5 } ", .kind = .style, .literal = null }, } }, .{ }, ui.view.templateAttrs(.{ .test_id = "nested attrs", .style = .{ .gap = 5 }, }, __yix_builder_1409: { try ui.view.previewCheckBuilder(__yix_view_scope, Split); break :__yix_builder_1409 Split(.{ }); })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Decorated";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub var slot_sentinel: u32 = 0;
fn slotReady(r: *ui.view.Ref(*ui.Node)) void {
    slot_sentinel = r.get().?.alive_sentinel;
}
fn slotCleanup(r: *ui.view.Ref(*ui.Node)) void {
    @import("std").debug.assert(r.get().?.alive_sentinel == slot_sentinel);
}
fn ignoreKey() void {}
pub fn SlotChild(args: anytype) ui.view.ComponentOf(__yix_SlotChild) {
    return ui.view.component(__yix_SlotChild, ui.reactive.props.coerce(SlotChildProps, args));
}
pub const SlotChildProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = SlotChild;
    pub const __yix_preview_mount = __yix_SlotChild;
};
fn __yix_SlotChild(__yix_props: SlotChildProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const handle = try ui.view.createRef(scope, *ui.Node);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .handle = handle, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "SlotChild", .receiver = "box", .tokens = "< box ref = { handle } onKeyDown = { ignoreKey ( ) } > < text > slot child < / text > < / box > ", .literal_text = null, .attributes = &.{ .{ .name = "ref", .tokens = "handle ", .kind = .reference, .literal = null }, .{ .name = "on_key_down", .tokens = "ignoreKey ( ) ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .handle = __yix_view_ctx.handle, }, ui.view.ref(__yix_view_ctx.handle, ui.view.box(.{ .on_key_down = try ui.on.bindAny(__yix_view_scope, .{ .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); ignoreKey();  } }.__yix_run), }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "SlotChild", .receiver = "text", .tokens = "text ", .literal_text = "slot child", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("slot child", .{ }))),
        }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "SlotChild";
    try ui.view.setupCleanup(__yix_view_scope, .{ .handle = __yix_view_ctx.handle, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onViewDetach); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); slotCleanup(__yix_ctx.handle);  } }.__yix_run);
    try ui.view.runLifecycleAction(__yix_view_scope, "onViewAttach", .{ .handle = __yix_view_ctx.handle, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onViewAttach); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); slotReady(__yix_ctx.handle);  } }.__yix_run);
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn SlottedForOom(args: anytype) ui.view.ComponentOf(__yix_SlottedForOom) {
    return ui.view.component(__yix_SlottedForOom, ui.reactive.props.coerce(SlottedForOomProps, args));
}
pub const SlottedForOomProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = SlottedForOom;
    pub const __yix_preview_mount = __yix_SlottedForOom;
};
fn __yix_SlottedForOom(__yix_props: SlottedForOomProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "SlottedForOom", .receiver = "Holder", .tokens = "< Holder header = { < text > header < / text > } > < SlotChild / > < / Holder > ", .literal_text = null, .attributes = &.{ .{ .name = "header", .tokens = "< text > header < / text > ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_2005: { try ui.view.previewCheckBuilder(__yix_view_scope, Holder); break :__yix_builder_2005 ui.view.with(Holder(.{ }), .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "SlottedForOom", .receiver = "SlotChild", .tokens = "< SlotChild / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2042: { try ui.view.previewCheckBuilder(__yix_view_scope, SlotChild); break :__yix_builder_2042 SlotChild(.{ }); }),
        }).slots(.{ .header = ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "SlottedForOom/slot:header", .receiver = "text", .tokens = "text ", .literal_text = "header", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("header", .{ }))), }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "SlottedForOom";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

// A real setup/view component exercises the Portal host lease. A plain text
// Portal cannot detect an extra attachment scope in one build configuration.
fn ComponentPortal(args: anytype) @TypeOf(ui.view.portal(Split(.{}))) {
    _ = args;
    return ui.view.portal(Split(.{}));
}
pub fn PortalOwner(args: anytype) ui.view.ComponentOf(__yix_PortalOwner) {
    return ui.view.component(__yix_PortalOwner, ui.reactive.props.coerce(PortalOwnerProps, args));
}
pub const PortalOwnerProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PortalOwner;
    pub const __yix_preview_mount = __yix_PortalOwner;
};
fn __yix_PortalOwner(__yix_props: PortalOwnerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "PortalOwner", .receiver = "box", .tokens = "box ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/lifecycle_split.yix", .path = "PortalOwner", .receiver = "ComponentPortal", .tokens = "< ComponentPortal / > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_2395: { try ui.view.previewCheckBuilder(__yix_view_scope, ComponentPortal); break :__yix_builder_2395 ComponentPortal(.{ }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PortalOwner";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x6f\x67\x3a\x20\x5b\x35\x31\x32\x5d\x69\x33\x32\x20\x3d\x20\x40\x73\x70\x6c\x61\x74\x28\x30\x29\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x6f\x67\x5f\x6c\x65\x6e\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x61\x73\x74\x5f\x72\x65\x66\x3a\x20\x3f\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x61\x73\x74\x5f\x69\x6e\x73\x74\x61\x6e\x63\x65\x3a\x20\x3f\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x49\x6e\x73\x74\x61\x6e\x63\x65\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x66\x6e\x20\x6e\x6f\x74\x65\x28\x6e\x3a\x20\x69\x33\x32\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x6c\x6f\x67\x5b\x6c\x6f\x67\x5f\x6c\x65\x6e\x5d\x20\x3d\x20\x6e\x3b\x0a\x20\x20\x20\x20\x6c\x6f\x67\x5f\x6c\x65\x6e\x20\x2b\x3d\x20\x31\x3b\x0a\x7d\x0a\x66\x6e\x20\x72\x65\x6d\x65\x6d\x62\x65\x72\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x6c\x61\x73\x74\x5f\x72\x65\x66\x20\x3d\x20\x72\x3b\x0a\x20\x20\x20\x20\x6c\x61\x73\x74\x5f\x69\x6e\x73\x74\x61\x6e\x63\x65\x20\x3d\x20\x75\x69\x2e\x76\x69\x65\x77\x2e\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x49\x6e\x73\x74\x61\x6e\x63\x65\x28\x72\x2e\x67\x65\x74\x28\x29\x2e\x3f\x29\x3b\x0a\x20\x20\x20\x20\x6e\x6f\x74\x65\x28\x69\x66\x20\x28\x72\x2e\x67\x65\x74\x28\x29\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x31\x30\x20\x65\x6c\x73\x65\x20\x30\x29\x3b\x0a\x7d\x0a\x66\x6e\x20\x61\x74\x74\x61\x63\x68\x65\x64\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x6e\x6f\x74\x65\x28\x69\x66\x20\x28\x72\x2e\x67\x65\x74\x28\x29\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x31\x20\x65\x6c\x73\x65\x20\x30\x29\x3b\x0a\x7d\x0a\x66\x6e\x20\x64\x65\x74\x61\x63\x68\x65\x64\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x6e\x6f\x74\x65\x28\x69\x66\x20\x28\x72\x2e\x67\x65\x74\x28\x29\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x2d\x31\x20\x65\x6c\x73\x65\x20\x2d\x32\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x70\x6c\x69\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x37\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x6f\x75\x62\x6c\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x63\x6f\x75\x6e\x74\x20\x2a\x20\x32\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x68\x61\x6e\x64\x6c\x65\x20\x3d\x20\x72\x65\x66\x28\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x28\x72\x65\x6d\x65\x6d\x62\x65\x72\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x6e\x6f\x74\x65\x28\x2d\x31\x30\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x56\x69\x65\x77\x41\x74\x74\x61\x63\x68\x28\x61\x74\x74\x61\x63\x68\x65\x64\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x56\x69\x65\x77\x44\x65\x74\x61\x63\x68\x28\x64\x65\x74\x61\x63\x68\x65\x64\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x20\x72\x65\x66\x3d\x7b\x68\x61\x6e\x64\x6c\x65\x7d\x20\x66\x6f\x63\x75\x73\x61\x62\x6c\x65\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x3e\x20\x30\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x63\x6f\x75\x6e\x74\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3b\x20\x64\x6f\x75\x62\x6c\x65\x64\x20\x7b\x64\x6f\x75\x62\x6c\x65\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x74\x65\x6d\x70\x6c\x61\x74\x65\x20\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x20\x31\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x41\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x75\x73\x65\x64\x20\x64\x69\x72\x65\x63\x74\x6c\x79\x20\x61\x73\x20\x61\x6e\x6f\x74\x68\x65\x72\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x27\x73\x20\x73\x69\x6e\x67\x6c\x65\x20\x72\x6f\x6f\x74\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4e\x65\x73\x74\x65\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x53\x70\x6c\x69\x74\x20\x2f\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x42\x6f\x74\x68\x20\x64\x65\x66\x61\x75\x6c\x74\x20\x61\x6e\x64\x20\x6e\x61\x6d\x65\x64\x20\x73\x6c\x6f\x74\x20\x69\x6e\x73\x65\x72\x74\x69\x6f\x6e\x20\x70\x6f\x69\x6e\x74\x73\x20\x6d\x6f\x76\x65\x20\x77\x69\x74\x68\x20\x65\x61\x63\x68\x20\x76\x69\x65\x77\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x48\x6f\x6c\x64\x65\x72\x28\x68\x65\x61\x64\x65\x72\x3a\x20\x56\x69\x65\x77\x2c\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x3e\x7b\x68\x65\x61\x64\x65\x72\x7d\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x44\x65\x63\x6f\x72\x61\x74\x65\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x53\x70\x6c\x69\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6e\x65\x73\x74\x65\x64\x20\x61\x74\x74\x72\x73\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x35\x20\x7d\x7d\x20\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x73\x6c\x6f\x74\x5f\x73\x65\x6e\x74\x69\x6e\x65\x6c\x3a\x20\x75\x33\x32\x20\x3d\x20\x30\x3b\x0a\x66\x6e\x20\x73\x6c\x6f\x74\x52\x65\x61\x64\x79\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x73\x6c\x6f\x74\x5f\x73\x65\x6e\x74\x69\x6e\x65\x6c\x20\x3d\x20\x72\x2e\x67\x65\x74\x28\x29\x2e\x3f\x2e\x61\x6c\x69\x76\x65\x5f\x73\x65\x6e\x74\x69\x6e\x65\x6c\x3b\x0a\x7d\x0a\x66\x6e\x20\x73\x6c\x6f\x74\x43\x6c\x65\x61\x6e\x75\x70\x28\x72\x3a\x20\x2a\x75\x69\x2e\x76\x69\x65\x77\x2e\x52\x65\x66\x28\x2a\x75\x69\x2e\x4e\x6f\x64\x65\x29\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x64\x22\x29\x2e\x64\x65\x62\x75\x67\x2e\x61\x73\x73\x65\x72\x74\x28\x72\x2e\x67\x65\x74\x28\x29\x2e\x3f\x2e\x61\x6c\x69\x76\x65\x5f\x73\x65\x6e\x74\x69\x6e\x65\x6c\x20\x3d\x3d\x20\x73\x6c\x6f\x74\x5f\x73\x65\x6e\x74\x69\x6e\x65\x6c\x29\x3b\x0a\x7d\x0a\x66\x6e\x20\x69\x67\x6e\x6f\x72\x65\x4b\x65\x79\x28\x29\x20\x76\x6f\x69\x64\x20\x7b\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x6c\x6f\x74\x43\x68\x69\x6c\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x68\x61\x6e\x64\x6c\x65\x20\x3d\x20\x72\x65\x66\x28\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x56\x69\x65\x77\x41\x74\x74\x61\x63\x68\x28\x73\x6c\x6f\x74\x52\x65\x61\x64\x79\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x56\x69\x65\x77\x44\x65\x74\x61\x63\x68\x28\x73\x6c\x6f\x74\x43\x6c\x65\x61\x6e\x75\x70\x28\x68\x61\x6e\x64\x6c\x65\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x72\x65\x66\x3d\x7b\x68\x61\x6e\x64\x6c\x65\x7d\x20\x6f\x6e\x4b\x65\x79\x44\x6f\x77\x6e\x3d\x7b\x69\x67\x6e\x6f\x72\x65\x4b\x65\x79\x28\x29\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x73\x6c\x6f\x74\x20\x63\x68\x69\x6c\x64\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x6c\x6f\x74\x74\x65\x64\x46\x6f\x72\x4f\x6f\x6d\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x48\x6f\x6c\x64\x65\x72\x20\x68\x65\x61\x64\x65\x72\x3d\x7b\x3c\x74\x65\x78\x74\x3e\x68\x65\x61\x64\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3e\x3c\x53\x6c\x6f\x74\x43\x68\x69\x6c\x64\x20\x2f\x3e\x3c\x2f\x48\x6f\x6c\x64\x65\x72\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x41\x20\x72\x65\x61\x6c\x20\x73\x65\x74\x75\x70\x2f\x76\x69\x65\x77\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x65\x78\x65\x72\x63\x69\x73\x65\x73\x20\x74\x68\x65\x20\x50\x6f\x72\x74\x61\x6c\x20\x68\x6f\x73\x74\x20\x6c\x65\x61\x73\x65\x2e\x20\x41\x20\x70\x6c\x61\x69\x6e\x20\x74\x65\x78\x74\x0a\x2f\x2f\x20\x50\x6f\x72\x74\x61\x6c\x20\x63\x61\x6e\x6e\x6f\x74\x20\x64\x65\x74\x65\x63\x74\x20\x61\x6e\x20\x65\x78\x74\x72\x61\x20\x61\x74\x74\x61\x63\x68\x6d\x65\x6e\x74\x20\x73\x63\x6f\x70\x65\x20\x69\x6e\x20\x6f\x6e\x65\x20\x62\x75\x69\x6c\x64\x20\x63\x6f\x6e\x66\x69\x67\x75\x72\x61\x74\x69\x6f\x6e\x2e\x0a\x66\x6e\x20\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x50\x6f\x72\x74\x61\x6c\x28\x61\x72\x67\x73\x3a\x20\x61\x6e\x79\x74\x79\x70\x65\x29\x20\x40\x54\x79\x70\x65\x4f\x66\x28\x75\x69\x2e\x76\x69\x65\x77\x2e\x70\x6f\x72\x74\x61\x6c\x28\x53\x70\x6c\x69\x74\x28\x2e\x7b\x7d\x29\x29\x29\x20\x7b\x0a\x20\x20\x20\x20\x5f\x20\x3d\x20\x61\x72\x67\x73\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x75\x69\x2e\x76\x69\x65\x77\x2e\x70\x6f\x72\x74\x61\x6c\x28\x53\x70\x6c\x69\x74\x28\x2e\x7b\x7d\x29\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x6f\x72\x74\x61\x6c\x4f\x77\x6e\x65\x72\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x3e\x3c\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x50\x6f\x72\x74\x61\x6c\x20\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ }) else void;

//# yix-map-data [[614,614],[6625,1113],[8136,1230],[10179,1371],[12486,1754],[15550,1968],[18161,2355]]

//# yix-map lifecycle_split.yix
