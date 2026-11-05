// GENERATED FILE, do not edit: generated from stories.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const std = @import("std");
const ui = @import("ui");
const Button = ui.widgets.Button;
const W = ui.widgets;
const States = @import("_states.yss.zig");
const Tab = enum { home, settings };
pub const Item = struct { id: u32, title: []const u8 };
const items = [_]Item{ .{ .id = 1, .title = "first" }, .{ .id = 2, .title = "second" } };
pub var batch_updates: usize = 0;
pub var batch_values: [8]i32 = @splat(-1);
fn observeBatch(value: i32) i32 {
    batch_values[batch_updates] = value;
    batch_updates += 1;
    return value;
}

// M0 samples corresponding to storybook: layout, button, card, controlled
// visibility, tabs, keyed rows, and a component receiving reactive props.
pub fn Layout(args: anytype) ui.view.ComponentOf(__yix_Layout) {
    return ui.view.component(__yix_Layout, ui.reactive.props.coerce(LayoutProps, args));
}
pub const LayoutProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Layout;
    pub const __yix_preview_mount = __yix_Layout;
};
fn __yix_Layout(__yix_props: LayoutProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Layout", .receiver = "row", .tokens = "row style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = ". { . gap = . space200 } ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.row(.{ .style = .{ .gap = .space200 }, }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Layout", .receiver = "W.ScrollArea", .tokens = "< W . ScrollArea parts = { . { . content = . { . style = ui . css ( . { . gap = 21 } ) } } } > < text > Before < / text > < / W . ScrollArea > ", .literal_text = null, .attributes = &.{ .{ .name = "parts", .tokens = ". { . content = . { . style = ui . css ( . { . gap = 21 } ) } } ", .kind = .property, .literal = null }, } }, .{ }, ui.view.templateAttrs(.{ .parts = .{ .content = .{ .style = ui.css(.{ .gap = 21 }) } }, }, __yix_builder_747: { try ui.view.previewCheckBuilder(__yix_view_scope, W.ScrollArea); break :__yix_builder_747 ui.view.with(W.ScrollArea(.{ }), .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Layout", .receiver = "text", .tokens = "text ", .literal_text = "Before", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Before", .{ }))),
            }); })),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Layout", .receiver = "spacer", .tokens = "spacer ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.spacer()),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Layout", .receiver = "text", .tokens = "text ", .literal_text = "After", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("After", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Layout";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ButtonStory(args: anytype) ui.view.ComponentOf(__yix_ButtonStory) {
    return ui.view.component(__yix_ButtonStory, ui.reactive.props.coerce(ButtonStoryProps, args));
}
pub const ButtonStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ButtonStory;
    pub const __yix_preview_mount = __yix_ButtonStory;
};
fn __yix_ButtonStory(__yix_props: ButtonStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(i32, 0);
    const double = __yix_d1: {
        const __yix_T = @TypeOf(count.peek() * 2);
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .count = count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.count.get() * 2;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, .double = double, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ButtonStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, .double = __yix_view_ctx.double, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ButtonStory", .receiver = "text", .tokens = "text count  @interpolation double  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .count = __yix_view_ctx.count, .double = __yix_view_ctx.double, }, ui.view.text(.{ }, ui.view.fmt("Count " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), "") ++ "; double " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.double), ""), .{ __yix_view_ctx.count, __yix_view_ctx.double, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ButtonStory", .receiver = "Button", .tokens = "< Button onClick = { count += 1 } > Increment < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, __yix_builder_1053: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_1053 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Increment", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ButtonStory", .receiver = "text", .tokens = "text", .literal_text = "Increment" }, .{ }, ui.view.text(.{}, ui.view.fmt("Increment", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ButtonStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn CardStory(args: anytype) ui.view.ComponentOf(__yix_CardStory) {
    return ui.view.component(__yix_CardStory, ui.reactive.props.coerce(CardStoryProps, args));
}
pub const CardStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = CardStory;
    pub const __yix_preview_mount = __yix_CardStory;
};
fn __yix_CardStory(__yix_props: CardStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "CardStory", .receiver = "ui.widgets.Card", .tokens = "< ui . widgets . Card style = { ui . css ( . { . opacity = 0.5 } ) } > < text > Card body < / text > < / ui . widgets . Card > ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "ui . css ( . { . opacity = 0.5 } ) ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.templateAttrs(.{ .style = ui.css(.{ .opacity = 0.5 }), }, __yix_builder_1147: { try ui.view.previewCheckBuilder(__yix_view_scope, ui.widgets.Card); break :__yix_builder_1147 ui.view.with(ui.widgets.Card(.{ }), .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "CardStory", .receiver = "text", .tokens = "text ", .literal_text = "Card body", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Card body", .{ }))),
        }); })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "CardStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn BranchStory(args: anytype) ui.view.ComponentOf(__yix_BranchStory) {
    return ui.view.component(__yix_BranchStory, ui.reactive.props.coerce(BranchStoryProps, args));
}
pub const BranchStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = BranchStory;
    pub const __yix_preview_mount = __yix_BranchStory;
};
fn __yix_BranchStory(__yix_props: BranchStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const expanded = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .expanded = expanded, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .expanded = __yix_view_ctx.expanded, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory", .receiver = "Button", .tokens = "< Button onClick = { expanded = ! expanded } > Toggle < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "expanded = ! expanded ", .kind = .event, .literal = null }, } }, .{ .expanded = __yix_view_ctx.expanded, }, __yix_builder_1328: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_1328 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .expanded = __yix_view_ctx.expanded, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.expanded.set(!__yix_ctx.expanded.peek());  } }.__yix_run)), }, "Toggle", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory", .receiver = "text", .tokens = "text", .literal_text = "Toggle" }, .{ }, ui.view.text(.{}, ui.view.fmt("Toggle", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory", .receiver = "control", .tokens = "if ( expanded ) < text > Expanded < / text > else < text > Collapsed < / text > " }, .{ .expanded = __yix_view_ctx.expanded, }, ui.view.lazyIf(__yix_view_ctx.expanded, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "Expanded", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Expanded", .{ }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BranchStory/keyword_if:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "Collapsed", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Collapsed", .{ }))) }); } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "BranchStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn TabsStory(args: anytype) ui.view.ComponentOf(__yix_TabsStory) {
    return ui.view.component(__yix_TabsStory, ui.reactive.props.coerce(TabsStoryProps, args));
}
pub const TabsStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TabsStory;
    pub const __yix_preview_mount = __yix_TabsStory;
};
fn __yix_TabsStory(__yix_props: TabsStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const tab = try scope.createSignalFor(Tab, .home);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .tab = tab, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .tab = __yix_view_ctx.tab, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory", .receiver = "Button", .tokens = "< Button onClick = { tab = . settings } > Settings < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "tab = . settings ", .kind = .event, .literal = null }, } }, .{ .tab = __yix_view_ctx.tab, }, __yix_builder_1533: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_1533 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .tab = __yix_view_ctx.tab, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.tab.set(.settings);  } }.__yix_run)), }, "Settings", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory", .receiver = "text", .tokens = "text", .literal_text = "Settings" }, .{ }, ui.view.text(.{}, ui.view.fmt("Settings", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory", .receiver = "control", .tokens = "switch ( tab ) { . home => < text > Home < / text > , . settings => < text > Settings body < / text > } " }, .{ .tab = __yix_view_ctx.tab, }, ui.view.lazySwitch(__yix_view_ctx.tab, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bt1_0: anytype, __yix_bv1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; _ = __yix_bv1_0; switch (__yix_bt1_0) { .home => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory/keyword_switch:1/case:.home", .receiver = "text", .tokens = "text ", .literal_text = "Home", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Home", .{ }))) }); }, .settings => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TabsStory/keyword_switch:1/case:.settings", .receiver = "text", .tokens = "text ", .literal_text = "Settings body", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Settings body", .{ }))) }); }, } } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TabsStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ListStory(args: anytype) ui.view.ComponentOf(__yix_ListStory) {
    return ui.view.component(__yix_ListStory, ui.reactive.props.coerce(ListStoryProps, args));
}
pub const ListStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ListStory;
    pub const __yix_preview_mount = __yix_ListStory;
};
fn __yix_ListStory(__yix_props: ListStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory", .receiver = "control", .tokens = "for ( rows ) | item | < text > { item . title } < / text > else < text > Empty < / text > " }, .{ .rows = __yix_view_ctx.rows, }, ui.view.lazyIf(__yix_d2: {
        const __yix_T = @TypeOf(__yix_view_ctx.rows.peek().len != 0);
        break :__yix_d2 try __yix_view_scope.createMemo(__yix_T, .{ .rows = __yix_view_ctx.rows, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.rows.get().len != 0;
        } }.__yix_compute);
    }, .{ .rows = __yix_view_ctx.rows, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ __yix_e1: { const __yix_items_1 = __yix_b1_0.rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory/keyword_for:1", .receiver = "text", .tokens = "text item . title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })))); } }.__yix_row); } }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory/keyword_for:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "Empty", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("Empty", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory", .receiver = "Button", .tokens = "< Button onClick = { rows = & . { } } > Clear < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "rows = & . { } ", .kind = .event, .literal = null }, } }, .{ .rows = __yix_view_ctx.rows, }, __yix_builder_1836: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_1836 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .rows = __yix_view_ctx.rows, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{});  } }.__yix_run)), }, "Clear", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ListStory", .receiver = "text", .tokens = "text", .literal_text = "Clear" }, .{ }, ui.view.text(.{}, ui.view.fmt("Clear", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ListStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Local variable shares name with generated function (b / row / k / run / compute): branch/row
/// references cannot corrupt generated function names.
pub fn GeneratedNameStory(args: anytype) ui.view.ComponentOf(__yix_GeneratedNameStory) {
    return ui.view.component(__yix_GeneratedNameStory, ui.reactive.props.coerce(GeneratedNameStoryProps, args));
}
pub const GeneratedNameStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = GeneratedNameStory;
    pub const __yix_preview_mount = __yix_GeneratedNameStory;
};
fn __yix_GeneratedNameStory(__yix_props: GeneratedNameStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const b = try scope.createSignalFor(i32, 1);
    const row = try scope.createSignalFor(i32, 2);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .b = b, .row = row, .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .b = __yix_view_ctx.b, .row = __yix_view_ctx.row, .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory", .receiver = "control", .tokens = "if ( b > 0 ) < text > b = { b } row = { row } < / text > " }, .{ .b = __yix_view_ctx.b, .row = __yix_view_ctx.row, }, ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.b.peek() > 0);
        break :__yix_d1 try __yix_view_scope.createMemo(__yix_T, .{ .b = __yix_view_ctx.b, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.b.get() > 0;
        } }.__yix_compute);
    }, .{ .b = __yix_view_ctx.b, .row = __yix_view_ctx.row, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory/keyword_if:1/branch:0", .receiver = "text", .tokens = "text b  @interpolation row  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .b = __yix_b1_0.b, .row = __yix_b1_0.row, }, ui.view.text(.{ }, ui.view.fmt("b=" ++ ui.view.yixFormat(@TypeOf(__yix_b1_0.b), "") ++ " row=" ++ ui.view.yixFormat(@TypeOf(__yix_b1_0.row), ""), .{ __yix_b1_0.b, __yix_b1_0.row, }))) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory", .receiver = "control", .tokens = "for ( rows ) | item | < text > { item . title } { b } { row } < / text > " }, .{ .rows = __yix_view_ctx.rows, .b = __yix_view_ctx.b, .row = __yix_view_ctx.row, }, __yix_e2: { const __yix_items_2 = __yix_view_ctx.rows; break :__yix_e2 ui.view.eachWith(.{ .b = __yix_view_ctx.b, .row = __yix_view_ctx.row, }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory/keyword_for:2", .receiver = "text", .tokens = "text item . title  @interpolation b  @interpolation row  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, .b = __yix_row_1.b, .row = __yix_row_1.row, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ ui.view.yixFormat(@TypeOf(__yix_row_1.b), "") ++ ui.view.yixFormat(@TypeOf(__yix_row_1.row), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.b, __yix_row_1.row, })))); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory", .receiver = "Button", .tokens = "< Button onClick = { b += 1 } > bump < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "b += 1 ", .kind = .event, .literal = null }, } }, .{ .b = __yix_view_ctx.b, }, __yix_builder_2291: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_2291 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .b = __yix_view_ctx.b, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.b.set(__yix_ctx.b.peek() + (1));  } }.__yix_run)), }, "bump", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GeneratedNameStory", .receiver = "text", .tokens = "text", .literal_text = "bump" }, .{ }, ui.view.text(.{}, ui.view.fmt("bump", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "GeneratedNameStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Controlled (read-only): list row fields drive Checkbox; click only fires onChange, parent
/// updates data.
pub const Task = struct { id: u32, title: []const u8, done: bool };
const tasks0 = [_]Task{ .{ .id = 1, .title = "a", .done = false }, .{ .id = 2, .title = "b", .done = true } };
pub var task_store: [2]Task = tasks0;
pub var toggles: usize = 0;
fn toggleTask(id: u32) []const Task {
    toggles += 1;
    for (&task_store) |*t| if (t.id == id) { t.done = !t.done; };
    return &task_store;
}
pub fn ControlledStory(args: anytype) ui.view.ComponentOf(__yix_ControlledStory) {
    return ui.view.component(__yix_ControlledStory, ui.reactive.props.coerce(ControlledStoryProps, args));
}
pub const ControlledStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ControlledStory;
    pub const __yix_preview_mount = __yix_ControlledStory;
};
fn __yix_ControlledStory(__yix_props: ControlledStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const list = try scope.createSignalFor([]const Task, &task_store);
    const frozen = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .list = list, .frozen = frozen, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ControlledStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .list = __yix_view_ctx.list, .frozen = __yix_view_ctx.frozen, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ControlledStory", .receiver = "control", .tokens = "for ( list ) | task | < W . Checkbox key = { task . id } label = { task . title } checked = { task . done } onChange = { { if ( ! frozen ) list = toggleTask ( task . id ) ; } } / > " }, .{ .list = __yix_view_ctx.list, .frozen = __yix_view_ctx.frozen, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.list; break :__yix_e1 ui.view.eachWith(.{ .list = __yix_view_ctx.list, .frozen = __yix_view_ctx.frozen, }, __yix_items_1, struct { fn __yix_k(task: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(task.id); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, task: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ControlledStory/keyword_for:1", .receiver = "W.Checkbox", .tokens = "< W . Checkbox key = { task . id } label = { task . title } checked = { task . done } onChange = { { if ( ! frozen ) list = toggleTask ( task . id ) ; } } / > ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "task . id ", .kind = .property, .literal = null }, .{ .name = "label", .tokens = "task . title ", .kind = .property, .literal = null }, .{ .name = "checked", .tokens = "task . done ", .kind = .property, .literal = null }, .{ .name = "on_change", .tokens = "{ if ( ! frozen ) list = toggleTask ( task . id ) ; } ", .kind = .event, .literal = null }, } }, .{ .task = task, .frozen = __yix_row_1.frozen, .list = __yix_row_1.list, }, __yix_builder_18: { try ui.view.previewCheckBuilder(__yix_scope_1, W.Checkbox); break :__yix_builder_18 W.Checkbox(.{ .label = __yix_d1: {
        const __yix_T = if (ui.view.attrType(W.Checkbox, "label")) |__yix_A| __yix_A else @TypeOf(task.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .task = task, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.task.get().title;
        } }.__yix_compute);
    }, .checked = __yix_d2: {
        const __yix_T = if (ui.view.attrType(W.Checkbox, "checked")) |__yix_A| __yix_A else @TypeOf(task.peek().done);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .task = task, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.task.get().done;
        } }.__yix_compute);
    }, .on_change = ui.view.eventProp(W.Checkbox, "on_change", try ui.on.bindAny(__yix_scope_1, .{ .frozen = __yix_row_1.frozen, .list = __yix_row_1.list, .task = task, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.frozen.peek()) { __yix_ctx.list.set(toggleTask(__yix_ctx.task.peek().id)); }  } }.__yix_run)), }); })); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ControlledStory", .receiver = "Button", .tokens = "< Button onClick = { frozen = ! frozen } > freeze < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "frozen = ! frozen ", .kind = .event, .literal = null }, } }, .{ .frozen = __yix_view_ctx.frozen, }, __yix_builder_3123: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_3123 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .frozen = __yix_view_ctx.frozen, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.frozen.set(!__yix_ctx.frozen.peek());  } }.__yix_run)), }, "freeze", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ControlledStory", .receiver = "text", .tokens = "text", .literal_text = "freeze" }, .{ }, ui.view.text(.{}, ui.view.fmt("freeze", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ControlledStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Typed events on component element: installed in component root's capture slot, fire before
/// component's own handlers; consume blocks component default behavior.
pub fn ComponentKeys(args: anytype) ui.view.ComponentOf(__yix_ComponentKeys) {
    return ui.view.component(__yix_ComponentKeys, ui.reactive.props.coerce(ComponentKeysProps, args));
}
pub const ComponentKeysProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ComponentKeys;
    pub const __yix_preview_mount = __yix_ComponentKeys;
};
fn __yix_ComponentKeys(__yix_props: ComponentKeysProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const text = try scope.createSignalFor([]const u8, "ab");
    const keys = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .text = text, .keys = keys, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ComponentKeys", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .keys = __yix_view_ctx.keys, .text = __yix_view_ctx.text, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ComponentKeys", .receiver = "W.Input", .tokens = "< W . Input testId = \"field\" value = { text } onKeyDown = { | e | if ( e . key == . delete and keys == 0 ) { keys += 1 ; e . consume ( ) ; } else keys += 10 } / > ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"field\" ", .kind = .property, .literal = .{ .text = "field" } }, .{ .name = "value", .tokens = "text ", .kind = .property, .literal = null }, .{ .name = "on_key_down", .tokens = "| e | if ( e . key == . delete and keys == 0 ) { keys += 1 ; e . consume ( ) ; } else keys += 10 ", .kind = .event, .literal = null }, } }, .{ .keys = __yix_view_ctx.keys, .text = __yix_view_ctx.text, }, ui.view.templateAttrs(.{ .test_id = "field", .on_key_down = try ui.on.bindAny(__yix_view_scope, .{ .keys = __yix_view_ctx.keys, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (e.key == .delete and __yix_ctx.keys.peek() == 0) { __yix_ctx.keys.set(__yix_ctx.keys.peek() + (1)); e.consume(); } else { __yix_ctx.keys.set(__yix_ctx.keys.peek() + (10)); }  } }.__yix_run), }, __yix_builder_3469: { try ui.view.previewCheckBuilder(__yix_view_scope, W.Input); break :__yix_builder_3469 W.Input(.{ .value = __yix_view_ctx.text, }); })),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ComponentKeys", .receiver = "text", .tokens = "text keys  @interpolation text  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .keys = __yix_view_ctx.keys, .text = __yix_view_ctx.text, }, ui.view.text(.{ }, ui.view.fmt("keys " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.keys), "") ++ " text " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.text), ""), .{ __yix_view_ctx.keys, __yix_view_ctx.text, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ComponentKeys";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Component root's typed events toggle mount/unmount across branches (table freed with component
/// scope, no dangling pointers).
pub fn ToggledKeys(args: anytype) ui.view.ComponentOf(__yix_ToggledKeys) {
    return ui.view.component(__yix_ToggledKeys, ui.reactive.props.coerce(ToggledKeysProps, args));
}
pub const ToggledKeysProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ToggledKeys;
    pub const __yix_preview_mount = __yix_ToggledKeys;
};
fn __yix_ToggledKeys(__yix_props: ToggledKeysProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const show = try scope.createSignalFor(bool, true);
    const keys = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .show = show, .keys = keys, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .show = __yix_view_ctx.show, .keys = __yix_view_ctx.keys, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys", .receiver = "control", .tokens = "if ( show ) < W . Input testId = \"tfield\" onKeyDown = { keys += 1 } / > " }, .{ .show = __yix_view_ctx.show, .keys = __yix_view_ctx.keys, }, ui.view.lazyIf(__yix_view_ctx.show, .{ .keys = __yix_view_ctx.keys, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys/keyword_if:1/branch:0", .receiver = "W.Input", .tokens = "< W . Input testId = \"tfield\" onKeyDown = { keys += 1 } / > ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"tfield\" ", .kind = .property, .literal = .{ .text = "tfield" } }, .{ .name = "on_key_down", .tokens = "keys += 1 ", .kind = .event, .literal = null }, } }, .{ .keys = __yix_b1_0.keys, }, ui.view.templateAttrs(.{ .test_id = "tfield", .on_key_down = try ui.on.bindAny(__yix_bs1_0, .{ .keys = __yix_b1_0.keys, .__yix_owner = __yix_bs1_0.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.keys.set(__yix_ctx.keys.peek() + (1));  } }.__yix_run), }, __yix_builder_10: { try ui.view.previewCheckBuilder(__yix_bs1_0, W.Input); break :__yix_builder_10 W.Input(.{ }); })) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys", .receiver = "Button", .tokens = "< Button onClick = { show = ! show } > toggle < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "show = ! show ", .kind = .event, .literal = null }, } }, .{ .show = __yix_view_ctx.show, }, __yix_builder_3954: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_3954 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .show = __yix_view_ctx.show, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.show.set(!__yix_ctx.show.peek());  } }.__yix_run)), }, "toggle", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys", .receiver = "text", .tokens = "text", .literal_text = "toggle" }, .{ }, ui.view.text(.{}, ui.view.fmt("toggle", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggledKeys", .receiver = "text", .tokens = "text keys  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .keys = __yix_view_ctx.keys, }, ui.view.text(.{ }, ui.view.fmt("tk " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.keys), ""), .{ __yix_view_ctx.keys, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ToggledKeys";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Controlled rewrite: read-only value + onChange normalized by props into split; Input corrects
/// buffer in-place per rewritten value.
var upper_buf: [64]u8 = undefined;
fn upper(v: []const u8) []const u8 {
    const n = @min(v.len, upper_buf.len);
    for (v[0..n], 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    return upper_buf[0..n];
}
pub fn UpperInput(args: anytype) ui.view.ComponentOf(__yix_UpperInput) {
    return ui.view.component(__yix_UpperInput, ui.reactive.props.coerce(UpperInputProps, args));
}
pub const UpperInputProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = UpperInput;
    pub const __yix_preview_mount = __yix_UpperInput;
};
fn __yix_UpperInput(__yix_props: UpperInputProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const code = try scope.createSignalFor([]const u8, "AB");
    const shown = __yix_d1: {
        const __yix_T = @TypeOf(code.peek());
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .code = code, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.code.get();
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .code = code, .shown = shown, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UpperInput", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shown = __yix_view_ctx.shown, .code = __yix_view_ctx.code, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UpperInput", .receiver = "W.Input", .tokens = "< W . Input testId = \"up\" value = { shown } onChange = { | v | code = upper ( v ) } / > ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"up\" ", .kind = .property, .literal = .{ .text = "up" } }, .{ .name = "value", .tokens = "shown ", .kind = .property, .literal = null }, .{ .name = "on_change", .tokens = "| v | code = upper ( v ) ", .kind = .event, .literal = null }, } }, .{ .shown = __yix_view_ctx.shown, .code = __yix_view_ctx.code, }, ui.view.templateAttrs(.{ .test_id = "up", }, __yix_builder_4500: { try ui.view.previewCheckBuilder(__yix_view_scope, W.Input); break :__yix_builder_4500 W.Input(.{ .value = __yix_view_ctx.shown, .on_change = ui.view.eventProp(W.Input, "on_change", try ui.on.bindAny(__yix_view_scope, .{ .code = __yix_view_ctx.code, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.code.set(upper(v));  } }.__yix_run)), }); })),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UpperInput", .receiver = "text", .tokens = "text code  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .code = __yix_view_ctx.code, }, ui.view.text(.{ }, ui.view.fmt("code " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.code), ""), .{ __yix_view_ctx.code, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "UpperInput";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Component property branch expressions typed by property type: enum literals, unequal-length
/// string literals, `[]const u8` in type.
pub fn TypedAttrStory(args: anytype) ui.view.ComponentOf(__yix_TypedAttrStory) {
    return ui.view.component(__yix_TypedAttrStory, ui.reactive.props.coerce(TypedAttrStoryProps, args));
}
pub const TypedAttrStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TypedAttrStory;
    pub const __yix_preview_mount = __yix_TypedAttrStory;
};
fn __yix_TypedAttrStory(__yix_props: TypedAttrStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const on = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .on = on, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TypedAttrStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .on = __yix_view_ctx.on, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TypedAttrStory", .receiver = "Button", .tokens = "< Button variant = { if ( on ) . primary else . ghost } label = { if ( on ) \"done\" else \"todo\" } onClick = { on = ! on } / > ", .literal_text = null, .attributes = &.{ .{ .name = "variant", .tokens = "if ( on ) . primary else . ghost ", .kind = .property, .literal = null }, .{ .name = "label", .tokens = "if ( on ) \"done\" else \"todo\" ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "on = ! on ", .kind = .event, .literal = null }, } }, .{ .on = __yix_view_ctx.on, }, __yix_builder_4822: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_4822 Button(.{ .variant = __yix_d1: {
        const __yix_T = if (ui.view.attrType(Button, "variant")) |__yix_A| __yix_A else @TypeOf(if (__yix_view_ctx.on.peek()) .primary else .ghost);
        break :__yix_d1 try __yix_view_scope.createMemo(__yix_T, .{ .on = __yix_view_ctx.on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) .primary else .ghost;
        } }.__yix_compute);
    }, .label = __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(if (__yix_view_ctx.on.peek()) "done" else "todo");
        break :__yix_d2 try __yix_view_scope.createMemo(__yix_T, .{ .on = __yix_view_ctx.on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) "done" else "todo";
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .on = __yix_view_ctx.on, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.on.set(!__yix_ctx.on.peek());  } }.__yix_run)), }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TypedAttrStory", .receiver = "Button", .tokens = "< Button label = { if ( on ) @as ( [ ] const u8 , \"yes\" ) else \"no\" } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "if ( on ) @as ( [ ] const u8 , \"yes\" ) else \"no\" ", .kind = .property, .literal = null }, } }, .{ .on = __yix_view_ctx.on, }, __yix_builder_4925: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_4925 Button(.{ .label = __yix_d3: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(if (__yix_view_ctx.on.peek()) @as([]const u8, "yes") else "no");
        break :__yix_d3 try __yix_view_scope.createMemo(__yix_T, .{ .on = __yix_view_ctx.on, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.on.get()) @as([]const u8, "yes") else "no";
        } }.__yix_compute);
    }, }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TypedAttrStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn Label(args: anytype) ui.view.ComponentOf(__yix_Label) {
    return ui.view.component(__yix_Label, ui.reactive.props.coerce(LabelProps, args));
}
pub const LabelProps = struct {
    count: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Label;
    pub const __yix_preview_mount = __yix_Label;
};
fn __yix_Label(__yix_props: LabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const count = __yix_props.count;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Label", .receiver = "text", .tokens = "text count  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ }, ui.view.fmt("Prop " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.count, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Label";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PropsStory(args: anytype) ui.view.ComponentOf(__yix_PropsStory) {
    return ui.view.component(__yix_PropsStory, ui.reactive.props.coerce(PropsStoryProps, args));
}
pub const PropsStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PropsStory;
    pub const __yix_preview_mount = __yix_PropsStory;
};
fn __yix_PropsStory(__yix_props: PropsStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const count = try scope.createSignalFor(i32, 3);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PropsStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PropsStory", .receiver = "Label", .tokens = "< Label { count } / > ", .literal_text = null, .attributes = &.{ .{ .name = "count", .tokens = "count ", .kind = .property, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, __yix_builder_5145: { try ui.view.previewCheckBuilder(__yix_view_scope, Label); break :__yix_builder_5145 Label(.{ .count = __yix_view_ctx.count, }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PropsStory", .receiver = "Button", .tokens = "< Button onClick = { count += 1 } > Increment prop < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "count += 1 ", .kind = .event, .literal = null }, } }, .{ .count = __yix_view_ctx.count, }, __yix_builder_5162: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_5162 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }, "Increment prop", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PropsStory", .receiver = "text", .tokens = "text", .literal_text = "Increment prop" }, .{ }, ui.view.text(.{}, ui.view.fmt("Increment prop", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PropsStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn BatchStory(args: anytype) ui.view.ComponentOf(__yix_BatchStory) {
    return ui.view.component(__yix_BatchStory, ui.reactive.props.coerce(BatchStoryProps, args));
}
pub const BatchStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = BatchStory;
    pub const __yix_preview_mount = __yix_BatchStory;
};
fn __yix_BatchStory(__yix_props: BatchStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, false);
    const a = try scope.createSignalFor(i32, 0);
    const b = try scope.createSignalFor(i32, 0);
    const total = __yix_d1: {
        const __yix_T = @TypeOf(observeBatch(a.peek() + b.peek()));
        break :__yix_d1 try scope.createMemo(__yix_T, .{ .a = a, .b = b, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return observeBatch(__yix_ctx.a.get() + __yix_ctx.b.get());
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .a = a, .b = b, .total = total, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BatchStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .total = __yix_view_ctx.total, .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BatchStory", .receiver = "text", .tokens = "text total  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .total = __yix_view_ctx.total, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.total), ""), .{ __yix_view_ctx.total, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BatchStory", .receiver = "Button", .tokens = "< Button onClick = { { a += 1 ; b += 2 ; } } > Batch < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "{ a += 1 ; b += 2 ; } ", .kind = .event, .literal = null }, } }, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, }, __yix_builder_5392: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_5392 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.a.set(__yix_ctx.a.peek() + (1)); __yix_ctx.b.set(__yix_ctx.b.peek() + (2));  } }.__yix_run)), }, "Batch", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "BatchStory", .receiver = "text", .tokens = "text", .literal_text = "Batch" }, .{ }, ui.view.text(.{}, ui.view.fmt("Batch", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "BatchStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn UnicodeStory(args: anytype) ui.view.ComponentOf(__yix_UnicodeStory) {
    return ui.view.component(__yix_UnicodeStory, ui.reactive.props.coerce(UnicodeStoryProps, args));
}
pub const UnicodeStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = UnicodeStory;
    pub const __yix_preview_mount = __yix_UnicodeStory;
};
fn __yix_UnicodeStory(__yix_props: UnicodeStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const show = try scope.createSignalFor(bool, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .show = show, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .show = __yix_view_ctx.show, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory", .receiver = "control", .tokens = "if ( show ) < text > 中文 😀</text> else <text>空</text> " }, .{ .show = __yix_view_ctx.show, }, ui.view.lazyIf(__yix_view_ctx.show, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "中文 😀", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("中文 😀", .{ }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory/keyword_if:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "空", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("空", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory", .receiver = "Button", .tokens = "< Button onClick = { show = false } > 隐藏</Button> ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "show = false ", .kind = .event, .literal = null }, } }, .{ .show = __yix_view_ctx.show, }, __yix_builder_5592: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_5592 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .show = __yix_view_ctx.show, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.show.set(false);  } }.__yix_run)), }, "隐藏", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "UnicodeStory", .receiver = "text", .tokens = "text", .literal_text = "隐藏" }, .{ }, ui.view.text(.{}, ui.view.fmt("隐藏", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "UnicodeStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn RowCaptureStory(args: anytype) ui.view.ComponentOf(__yix_RowCaptureStory) {
    return ui.view.component(__yix_RowCaptureStory, ui.reactive.props.coerce(RowCaptureStoryProps, args));
}
pub const RowCaptureStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = RowCaptureStory;
    pub const __yix_preview_mount = __yix_RowCaptureStory;
};
fn __yix_RowCaptureStory(__yix_props: RowCaptureStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const selected = try scope.createSignalFor(u32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .rows = rows, .selected = selected, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .selected = __yix_view_ctx.selected, .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory", .receiver = "text", .tokens = "text selected  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .selected = __yix_view_ctx.selected, }, ui.view.text(.{ }, ui.view.fmt("Selected " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.selected), ""), .{ __yix_view_ctx.selected, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory", .receiver = "control", .tokens = "for ( rows ) | item | < row > < text > { item . title } : { selected } < / text > < Button label = { item . title } onClick = { selected = item . id } / > < / row > " }, .{ .rows = __yix_view_ctx.rows, .selected = __yix_view_ctx.selected, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.rows; break :__yix_e1 ui.view.eachWith(.{ .selected = __yix_view_ctx.selected, }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory/keyword_for:1", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, .selected = __yix_row_1.selected, }, ui.view.row(.{ }, .{
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory/keyword_for:1", .receiver = "text", .tokens = "text item . title  @interpolation selected  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, .selected = __yix_row_1.selected, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ ": " ++ ui.view.yixFormat(@TypeOf(__yix_row_1.selected), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.selected, }))),
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory/keyword_for:1", .receiver = "Button", .tokens = "< Button label = { item . title } onClick = { selected = item . id } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "item . title ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "selected = item . id ", .kind = .event, .literal = null }, } }, .{ .item = item, .selected = __yix_row_1.selected, }, __yix_builder_60: { try ui.view.previewCheckBuilder(__yix_scope_1, Button); break :__yix_builder_60 Button(.{ .label = __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(item.peek().title);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_scope_1, .{ .selected = __yix_row_1.selected, .item = item, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.selected.set(__yix_ctx.item.peek().id);  } }.__yix_run)), }); }),
                }))); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory", .receiver = "Button", .tokens = "< Button onClick = { rows = & . { items [ 1 ] , items [ 0 ] } } > Reverse < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "rows = & . { items [ 1 ] , items [ 0 ] } ", .kind = .event, .literal = null }, } }, .{ .rows = __yix_view_ctx.rows, }, __yix_builder_5934: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_5934 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .rows = __yix_view_ctx.rows, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{ items[1], items[0] });  } }.__yix_run)), }, "Reverse", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RowCaptureStory", .receiver = "text", .tokens = "text", .literal_text = "Reverse" }, .{ }, ui.view.text(.{}, ui.view.fmt("Reverse", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "RowCaptureStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn TextSignalStory(args: anytype) ui.view.ComponentOf(__yix_TextSignalStory) {
    return ui.view.component(__yix_TextSignalStory, ui.reactive.props.coerce(TextSignalStoryProps, args));
}
pub const TextSignalStoryProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TextSignalStory;
    pub const __yix_preview_mount = __yix_TextSignalStory;
};
fn __yix_TextSignalStory(__yix_props: TextSignalStoryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const message = try scope.createSignalFor([]const u8, "before");
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .message = message, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextSignalStory", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .message = __yix_view_ctx.message, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextSignalStory", .receiver = "text", .tokens = "text message  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .message = __yix_view_ctx.message, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.message), ""), .{ __yix_view_ctx.message, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextSignalStory", .receiver = "Button", .tokens = "< Button onClick = { message = \"after\" } > Change text < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "message = \"after\" ", .kind = .event, .literal = null }, } }, .{ .message = __yix_view_ctx.message, }, __yix_builder_6129: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_6129 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .message = __yix_view_ctx.message, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.message.set("after");  } }.__yix_run)), }, "Change text", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextSignalStory", .receiver = "text", .tokens = "text", .literal_text = "Change text" }, .{ }, ui.view.text(.{}, ui.view.fmt("Change text", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TextSignalStory";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Doubled(args: anytype) ui.view.ComponentOf(__yix_Doubled) {
    return ui.view.component(__yix_Doubled, ui.reactive.props.coerce(DoubledProps, args));
}
pub const DoubledProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Doubled;
    pub const __yix_preview_mount = __yix_Doubled;
};
fn __yix_Doubled(__yix_props: DoubledProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, true);
    const d = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() * 2);
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .d = d, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Doubled", .receiver = "text", .tokens = "text d  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .d = __yix_view_ctx.d, }, ui.view.text(.{ }, ui.view.fmt("double " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.d), ""), .{ __yix_view_ctx.d, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Doubled";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Panel(args: anytype) ui.view.SlottedOf(__yix_Panel) {
    return ui.view.slotted(__yix_Panel, ui.reactive.props.coerce(PanelProps, args));
}
pub const PanelProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Panel;
    pub const __yix_preview_mount = __yix_Panel;
};
fn __yix_Panel(__yix_props: PanelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Panel", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Panel", .receiver = "text", .tokens = "text title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .title = __yix_view_ctx.title, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.title), ""), .{ __yix_view_ctx.title, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Panel", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.slotEnd(&__yix_slot_children, ui.view.col(.{ }, .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Panel";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });
    } }.__yix_render);
    return __yix_view;

}
pub fn PanelUse(args: anytype) ui.view.ComponentOf(__yix_PanelUse) {
    return ui.view.component(__yix_PanelUse, ui.reactive.props.coerce(PanelUseProps, args));
}
pub const PanelUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PanelUse;
    pub const __yix_preview_mount = __yix_PanelUse;
};
fn __yix_PanelUse(__yix_props: PanelUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 1);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PanelUse", .receiver = "Panel", .tokens = "< Panel title = \"Settings\" > < text > value { n } < / text > < Button onClick = { n += 1 } > More < / Button > < / Panel > ", .literal_text = null, .attributes = &.{ .{ .name = "title", .tokens = "\"Settings\" ", .kind = .property, .literal = .{ .text = "Settings" } }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, __yix_builder_6542: { try ui.view.previewCheckBuilder(__yix_view_scope, Panel); break :__yix_builder_6542 ui.view.with(Panel(.{ .title = "Settings", }), .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PanelUse", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("value " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PanelUse", .receiver = "Button", .tokens = "< Button onClick = { n += 1 } > More < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "n += 1 ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_6588: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_6588 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PanelUse", .receiver = "text", .tokens = "text", .literal_text = "More" }, .{ }, ui.view.text(.{}, ui.view.fmt("More", .{ }))),
            }); }),
        }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PanelUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Closable(args: anytype) ui.view.ComponentOf(__yix_Closable) {
    return ui.view.component(__yix_Closable, ui.reactive.props.coerce(ClosableProps, args));
}
pub const ClosableProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    on_close: ?ui.Handler(void) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Closable;
    pub const __yix_preview_mount = __yix_Closable;
};
fn __yix_Closable(__yix_props: ClosableProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const onClose = __yix_props.on_close;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .label = label, .onClose = onClose, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Closable", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .label = __yix_view_ctx.label, .onClose = __yix_view_ctx.onClose, }, ui.view.row(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Closable", .receiver = "text", .tokens = "text label  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .label = __yix_view_ctx.label, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.label), ""), .{ __yix_view_ctx.label, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Closable", .receiver = "Button", .tokens = "< Button label = \"x\" onClick = { onClose } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "\"x\" ", .kind = .property, .literal = .{ .text = "x" } }, .{ .name = "on_click", .tokens = "onClose ", .kind = .event, .literal = null }, } }, .{ .onClose = __yix_view_ctx.onClose, }, __yix_builder_6754: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_6754 Button(.{ .label = "x", .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) __yix_view_ctx.onClose else __yix_view_ctx.onClose, }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Closable";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ClosableUse(args: anytype) ui.view.ComponentOf(__yix_ClosableUse) {
    return ui.view.component(__yix_ClosableUse, ui.reactive.props.coerce(ClosableUseProps, args));
}
pub const ClosableUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ClosableUse;
    pub const __yix_preview_mount = __yix_ClosableUse;
};
fn __yix_ClosableUse(__yix_props: ClosableUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const closed = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .closed = closed, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ClosableUse", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .closed = __yix_view_ctx.closed, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ClosableUse", .receiver = "Closable", .tokens = "< Closable label = \"tab\" onClose = { closed = true } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "\"tab\" ", .kind = .property, .literal = .{ .text = "tab" } }, .{ .name = "on_close", .tokens = "closed = true ", .kind = .event, .literal = null }, } }, .{ .closed = __yix_view_ctx.closed, }, __yix_builder_6884: { try ui.view.previewCheckBuilder(__yix_view_scope, Closable); break :__yix_builder_6884 Closable(.{ .label = "tab", .on_close = ui.view.eventProp(Closable, "on_close", try ui.on.bindAny(__yix_view_scope, .{ .closed = __yix_view_ctx.closed, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.closed.set(true);  } }.__yix_run)), }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ClosableUse", .receiver = "control", .tokens = "if ( closed ) < text > closed < / text > else < text > open < / text > " }, .{ .closed = __yix_view_ctx.closed, }, ui.view.lazyIf(__yix_view_ctx.closed, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ClosableUse/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "closed", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("closed", .{ }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ClosableUse/keyword_if:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "open", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("open", .{ }))) }); } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ClosableUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Stars(args: anytype) ui.view.ComponentOf(__yix_Stars) {
    return ui.view.component(__yix_Stars, ui.reactive.props.coerce(StarsProps, args));
}
pub const StarsProps = struct {
    total: ui.Source(usize) = .{ .value = 5 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Stars;
    pub const __yix_preview_mount = __yix_Stars;
};
fn __yix_Stars(__yix_props: StarsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const lit = try scope.createSignalFor(usize, 2);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .lit = lit, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .lit = __yix_view_ctx.lit, }, ui.view.row(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars", .receiver = "control", .tokens = "for ( 0 .. 5 ) | i | < text > { i } / { lit } < / text > " }, .{ .lit = __yix_view_ctx.lit, }, ui.view.repeat(.{ .lit = __yix_view_ctx.lit, }, @as(usize, 5), struct { fn __yix_row(__yix_row_1: anytype, i: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars/keyword_for:1", .receiver = "text", .tokens = "text i  @interpolation lit  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .i = i, .lit = __yix_row_1.lit, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ "/" ++ ui.view.yixFormat(@TypeOf(__yix_row_1.lit), ""), .{ i, __yix_row_1.lit, })))); } }.__yix_row)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars", .receiver = "control", .tokens = "for ( 0 .. 3 ) | _ | < spacer / > " }, .{ }, ui.view.repeat(.{ }, @as(usize, 3), struct { fn __yix_row(__yix_row_1: anytype, _: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars/keyword_for:2", .receiver = "spacer", .tokens = "spacer ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.spacer())); } }.__yix_row)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars", .receiver = "Button", .tokens = "< Button onClick = { lit += 1 } > More < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "lit += 1 ", .kind = .event, .literal = null }, } }, .{ .lit = __yix_view_ctx.lit, }, __yix_builder_7151: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_7151 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .lit = __yix_view_ctx.lit, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.lit.set(__yix_ctx.lit.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Stars", .receiver = "text", .tokens = "text", .literal_text = "More" }, .{ }, ui.view.text(.{}, ui.view.fmt("More", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Stars";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn GrowingStars(args: anytype) ui.view.ComponentOf(__yix_GrowingStars) {
    return ui.view.component(__yix_GrowingStars, ui.reactive.props.coerce(GrowingStarsProps, args));
}
pub const GrowingStarsProps = struct {
    total: ui.Source(usize) = .{ .value = 2 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = GrowingStars;
    pub const __yix_preview_mount = __yix_GrowingStars;
};
fn __yix_GrowingStars(__yix_props: GrowingStarsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const total = __yix_props.total;
    try ui.view.previewCheckSetup(scope, true);
    const extra = try scope.createSignalFor(usize, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .total = total, .extra = extra, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GrowingStars", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .total = __yix_view_ctx.total, .extra = __yix_view_ctx.extra, }, ui.view.row(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GrowingStars", .receiver = "control", .tokens = "for ( 0 .. total + extra ) | i | < text > star { i } < / text > " }, .{ .total = __yix_view_ctx.total, .extra = __yix_view_ctx.extra, }, ui.view.repeat(.{ }, __yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.total.peek() + __yix_view_ctx.extra.peek());
        break :__yix_d1 try __yix_view_scope.createMemo(__yix_T, .{ .total = __yix_view_ctx.total, .extra = __yix_view_ctx.extra, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.total.get() + __yix_ctx.extra.get();
        } }.__yix_compute);
    }, struct { fn __yix_row(__yix_row_1: anytype, i: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GrowingStars/keyword_for:1", .receiver = "text", .tokens = "text i  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .i = i, }, ui.view.text(.{ }, ui.view.fmt("star " ++ ui.view.yixFormat(@TypeOf(i), ""), .{ i, })))); } }.__yix_row)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GrowingStars", .receiver = "Button", .tokens = "< Button onClick = { extra += 1 } > Add < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "extra += 1 ", .kind = .event, .literal = null }, } }, .{ .extra = __yix_view_ctx.extra, }, __yix_builder_7347: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_7347 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .extra = __yix_view_ctx.extra, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.extra.set(__yix_ctx.extra.peek() + (1));  } }.__yix_run)), }, "Add", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GrowingStars", .receiver = "text", .tokens = "text", .literal_text = "Add" }, .{ }, ui.view.text(.{}, ui.view.fmt("Add", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "GrowingStars";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Forward(args: anytype) ui.view.ComponentOf(__yix_Forward) {
    return ui.view.component(__yix_Forward, ui.reactive.props.coerce(ForwardProps, args));
}
pub const ForwardProps = struct {
    disabled: ui.Source(bool) = .{ .value = false },
    on_press: ?ui.Handler(void) = null,
    on_pick: ?ui.Handler(i32) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Forward;
    pub const __yix_preview_mount = __yix_Forward;
};
fn __yix_Forward(__yix_props: ForwardProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const disabled = __yix_props.disabled;
    const onPress = __yix_props.on_press;
    const onPick = __yix_props.on_pick;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .disabled = disabled, .onPress = onPress, .onPick = onPick, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Forward", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .disabled = __yix_view_ctx.disabled, .onPress = __yix_view_ctx.onPress, .onPick = __yix_view_ctx.onPick, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Forward", .receiver = "Button", .tokens = "< Button onClick = { if ( ! disabled ) onPress } > Go < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "if ( ! disabled ) onPress ", .kind = .event, .literal = null }, } }, .{ .disabled = __yix_view_ctx.disabled, .onPress = __yix_view_ctx.onPress, }, __yix_builder_7523: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_7523 ui.view.textChild(Button, .{ .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) try ui.on.bindAny(__yix_view_scope, .{ .disabled = __yix_view_ctx.disabled, .onPress = __yix_view_ctx.onPress, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onPress, .{}); }  } }.__yix_run) else __yix_d1: {
        const __yix_T = if (ui.view.attrType(Button, "on_click")) |__yix_A| __yix_A else @TypeOf(if (!__yix_view_ctx.disabled.peek()) __yix_view_ctx.onPress);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .disabled = __yix_view_ctx.disabled, .onPress = __yix_view_ctx.onPress, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (!__yix_ctx.disabled.get()) __yix_ctx.onPress;
        } }.__yix_compute);
    }, }, "Go", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Forward", .receiver = "text", .tokens = "text", .literal_text = "Go" }, .{ }, ui.view.text(.{}, ui.view.fmt("Go", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Forward", .receiver = "Button", .tokens = "< Button onClick = { onPick ( 7 ) } > Seven < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "onPick ( 7 ) ", .kind = .event, .literal = null }, } }, .{ .onPick = __yix_view_ctx.onPick, }, __yix_builder_7575: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_7575 ui.view.textChild(Button, .{ .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) try ui.on.bindAny(__yix_view_scope, .{ .onPick = __yix_view_ctx.onPick, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); ui.on.fire(__yix_ctx.onPick, .{7});  } }.__yix_run) else __yix_call3: {
        const __yix_Raw = @TypeOf(__yix_view_ctx.onPick(7));
        break :__yix_call3 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) __yix_view_ctx.onPick(7) else __yix_d2: {
        const __yix_T = if (ui.view.attrType(Button, "on_click")) |__yix_A| __yix_A else @TypeOf(__yix_view_ctx.onPick(7));
        break :__yix_d2 try __yix_view_scope.derive(__yix_T, .{ .onPick = __yix_view_ctx.onPick, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.onPick(7);
        } }.__yix_compute);
    };
    }, }, "Seven", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Forward", .receiver = "text", .tokens = "text", .literal_text = "Seven" }, .{ }, ui.view.text(.{}, ui.view.fmt("Seven", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Forward";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn ForwardUse(args: anytype) ui.view.ComponentOf(__yix_ForwardUse) {
    return ui.view.component(__yix_ForwardUse, ui.reactive.props.coerce(ForwardUseProps, args));
}
pub const ForwardUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ForwardUse;
    pub const __yix_preview_mount = __yix_ForwardUse;
};
fn __yix_ForwardUse(__yix_props: ForwardUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const off = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, .off = off, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ForwardUse", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .off = __yix_view_ctx.off, .n = __yix_view_ctx.n, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ForwardUse", .receiver = "Forward", .tokens = "< Forward disabled = { off } onPress = { n += 1 } onPick = { | v | n = v } / > ", .literal_text = null, .attributes = &.{ .{ .name = "disabled", .tokens = "off ", .kind = .property, .literal = null }, .{ .name = "on_press", .tokens = "n += 1 ", .kind = .event, .literal = null }, .{ .name = "on_pick", .tokens = "| v | n = v ", .kind = .event, .literal = null }, } }, .{ .off = __yix_view_ctx.off, .n = __yix_view_ctx.n, }, __yix_builder_7734: { try ui.view.previewCheckBuilder(__yix_view_scope, Forward); break :__yix_builder_7734 Forward(.{ .disabled = __yix_view_ctx.off, .on_press = ui.view.eventProp(Forward, "on_press", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), .on_pick = ui.view.eventProp(Forward, "on_pick", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(v);  } }.__yix_run)), }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ForwardUse", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("presses " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ForwardUse", .receiver = "Button", .tokens = "< Button onClick = { off = ! off } > Lock < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "off = ! off ", .kind = .event, .literal = null }, } }, .{ .off = __yix_view_ctx.off, }, __yix_builder_7820: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_7820 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .off = __yix_view_ctx.off, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.off.set(!__yix_ctx.off.peek());  } }.__yix_run)), }, "Lock", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ForwardUse", .receiver = "text", .tokens = "text", .literal_text = "Lock" }, .{ }, ui.view.text(.{}, ui.view.fmt("Lock", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ForwardUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Numbered(args: anytype) ui.view.ComponentOf(__yix_Numbered) {
    return ui.view.component(__yix_Numbered, ui.reactive.props.coerce(NumberedProps, args));
}
pub const NumberedProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Numbered;
    pub const __yix_preview_mount = __yix_Numbered;
};
fn __yix_Numbered(__yix_props: NumberedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Numbered", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Numbered", .receiver = "control", .tokens = "for ( rows ) | item , i | < text > { i } . { item . title } < / text > " }, .{ .rows = __yix_view_ctx.rows, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Numbered/keyword_for:1", .receiver = "text", .tokens = "text i  @interpolation item . title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .i = i, .item = item, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ ". " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ i, __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })))); } }.__yix_row); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Numbered", .receiver = "Button", .tokens = "< Button onClick = { rows = & . { items [ 1 ] , items [ 0 ] } } > Reverse < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "rows = & . { items [ 1 ] , items [ 0 ] } ", .kind = .event, .literal = null }, } }, .{ .rows = __yix_view_ctx.rows, }, __yix_builder_8012: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_8012 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .rows = __yix_view_ctx.rows, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.rows.set(&.{ items[1], items[0] });  } }.__yix_run)), }, "Reverse", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Numbered", .receiver = "text", .tokens = "text", .literal_text = "Reverse" }, .{ }, ui.view.text(.{}, ui.view.fmt("Reverse", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Numbered";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn NestedFlow(args: anytype) ui.view.ComponentOf(__yix_NestedFlow) {
    return ui.view.component(__yix_NestedFlow, ui.reactive.props.coerce(NestedFlowProps, args));
}
pub const NestedFlowProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = NestedFlow;
    pub const __yix_preview_mount = __yix_NestedFlow;
};
fn __yix_NestedFlow(__yix_props: NestedFlowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const shown = try scope.createSignalFor(bool, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .shown = shown, .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shown = __yix_view_ctx.shown, .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow", .receiver = "control", .tokens = "if ( shown ) for ( rows ) | item | < text > row { item . title } < / text > " }, .{ .shown = __yix_view_ctx.shown, .rows = __yix_view_ctx.rows, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ .rows = __yix_view_ctx.rows, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow/keyword_if:1/branch:0", .receiver = "control", .tokens = "for ( rows ) | item | < text > row { item . title } < / text > " }, .{ .rows = __yix_b1_0.rows, }, __yix_e2: { const __yix_items_2 = __yix_b1_0.rows; break :__yix_e2 ui.view.eachWith(.{ }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow/keyword_if:1/branch:0/keyword_for:2", .receiver = "text", .tokens = "text item . title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, }, ui.view.text(.{ }, ui.view.fmt("row " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, })))); } }.__yix_row); }) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow", .receiver = "Button", .tokens = "< Button onClick = { shown = ! shown } > Hide < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "shown = ! shown ", .kind = .event, .literal = null }, } }, .{ .shown = __yix_view_ctx.shown, }, __yix_builder_8273: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_8273 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .shown = __yix_view_ctx.shown, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shown.set(!__yix_ctx.shown.peek());  } }.__yix_run)), }, "Hide", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "NestedFlow", .receiver = "text", .tokens = "text", .literal_text = "Hide" }, .{ }, ui.view.text(.{}, ui.view.fmt("Hide", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "NestedFlow";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

pub fn Toggle(args: anytype) ui.view.ComponentOf(__yix_Toggle) {
    return ui.view.component(__yix_Toggle, ui.reactive.props.coerce(ToggleProps, args));
}
pub const ToggleProps = struct {
    on: ui.Model(bool) = .{ .local = false },
    on_change: ?ui.Handler(bool) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Toggle;
    pub const __yix_preview_mount = __yix_Toggle;
};
fn __yix_Toggle(__yix_props: ToggleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const onChange = __yix_props.on_change;
    const __yix_model_on = try ui.reactive.resolveModelFor(bool, scope, __yix_props.on);
    const on = __yix_model_on.read;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .on = on, .onChange = onChange, .__yix_model_on = __yix_model_on, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .on = __yix_view_ctx.on, .onChange = __yix_view_ctx.onChange, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle", .receiver = "control", .tokens = "if ( on ) < text > on < / text > else < text > off < / text > " }, .{ .on = __yix_view_ctx.on, }, ui.view.lazyIf(__yix_view_ctx.on, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle/keyword_if:1/branch:0", .receiver = "text", .tokens = "text ", .literal_text = "on", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("on", .{ }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle/keyword_if:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "off", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("off", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle", .receiver = "Button", .tokens = "< Button onClick = { on = ! on } > Flip < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "on = ! on ", .kind = .event, .literal = null }, } }, .{ .on = __yix_view_ctx.on, .onChange = __yix_view_ctx.onChange, }, __yix_builder_8472: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_8472 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .on = __yix_view_ctx.on, .__yix_model_on = __yix_view_ctx.__yix_model_on, .onChange = __yix_view_ctx.onChange, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_on.propose(!__yix_ctx.on.peek(), __yix_ctx.onChange);  } }.__yix_run)), }, "Flip", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Toggle", .receiver = "text", .tokens = "text", .literal_text = "Flip" }, .{ }, ui.view.text(.{}, ui.view.fmt("Flip", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Toggle";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ToggleBound(args: anytype) ui.view.ComponentOf(__yix_ToggleBound) {
    return ui.view.component(__yix_ToggleBound, ui.reactive.props.coerce(ToggleBoundProps, args));
}
pub const ToggleBoundProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ToggleBound;
    pub const __yix_preview_mount = __yix_ToggleBound;
};
fn __yix_ToggleBound(__yix_props: ToggleBoundProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const flag = try scope.createSignalFor(bool, true);
    const changes = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .flag = flag, .changes = changes, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleBound", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .flag = __yix_view_ctx.flag, .changes = __yix_view_ctx.changes, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleBound", .receiver = "text", .tokens = "text flag  @interpolation changes  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .flag = __yix_view_ctx.flag, .changes = __yix_view_ctx.changes, }, ui.view.text(.{ }, ui.view.fmt("flag " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.flag), "") ++ " changes " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.changes), ""), .{ __yix_view_ctx.flag, __yix_view_ctx.changes, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleBound", .receiver = "Toggle", .tokens = "< Toggle on = { flag } onChange = { changes += 1 } / > ", .literal_text = null, .attributes = &.{ .{ .name = "on", .tokens = "flag ", .kind = .property, .literal = null }, .{ .name = "on_change", .tokens = "changes += 1 ", .kind = .event, .literal = null }, } }, .{ .flag = __yix_view_ctx.flag, .changes = __yix_view_ctx.changes, }, __yix_builder_8677: { try ui.view.previewCheckBuilder(__yix_view_scope, Toggle); break :__yix_builder_8677 Toggle(.{ .on = __yix_view_ctx.flag, .on_change = ui.view.eventProp(Toggle, "on_change", try ui.on.bindAny(__yix_view_scope, .{ .changes = __yix_view_ctx.changes, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.changes.set(__yix_ctx.changes.peek() + (1));  } }.__yix_run)), }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ToggleBound";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ToggleEcho(args: anytype) ui.view.ComponentOf(__yix_ToggleEcho) {
    return ui.view.component(__yix_ToggleEcho, ui.reactive.props.coerce(ToggleEchoProps, args));
}
pub const ToggleEchoProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ToggleEcho;
    pub const __yix_preview_mount = __yix_ToggleEcho;
};
fn __yix_ToggleEcho(__yix_props: ToggleEchoProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const last = try scope.createSignalFor(bool, false);
    const count = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .last = last, .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleEcho", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .last = __yix_view_ctx.last, .count = __yix_view_ctx.count, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleEcho", .receiver = "text", .tokens = "text last  @interpolation count  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .last = __yix_view_ctx.last, .count = __yix_view_ctx.count, }, ui.view.text(.{ }, ui.view.fmt("last " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.last), "") ++ " count " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.last, __yix_view_ctx.count, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ToggleEcho", .receiver = "Toggle", .tokens = "< Toggle onChange = { | v | { last = v ; count += 1 ; } } / > ", .literal_text = null, .attributes = &.{ .{ .name = "on_change", .tokens = "| v | { last = v ; count += 1 ; } ", .kind = .event, .literal = null }, } }, .{ .last = __yix_view_ctx.last, .count = __yix_view_ctx.count, }, __yix_builder_8880: { try ui.view.previewCheckBuilder(__yix_view_scope, Toggle); break :__yix_builder_8880 Toggle(.{ .on_change = ui.view.eventProp(Toggle, "on_change", try ui.on.bindAny(__yix_view_scope, .{ .last = __yix_view_ctx.last, .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.last.set(v); __yix_ctx.count.set(__yix_ctx.count.peek() + (1));  } }.__yix_run)), }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ToggleEcho";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn Guarded(args: anytype) ui.view.ComponentOf(__yix_Guarded) {
    return ui.view.component(__yix_Guarded, ui.reactive.props.coerce(GuardedProps, args));
}
pub const GuardedProps = struct {
    locked: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Guarded;
    pub const __yix_preview_mount = __yix_Guarded;
};
fn __yix_Guarded(__yix_props: GuardedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const locked = __yix_props.locked;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .locked = locked, .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Guarded", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, .locked = __yix_view_ctx.locked, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Guarded", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Guarded", .receiver = "Button", .tokens = "< Button onClick = { if ( ! locked ) { n += 1 ; if ( n > 2 ) n = 0 ; } else n = - 1 } > Step < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "if ( ! locked ) { n += 1 ; if ( n > 2 ) n = 0 ; } else n = - 1 ", .kind = .event, .literal = null }, } }, .{ .locked = __yix_view_ctx.locked, .n = __yix_view_ctx.n, }, __yix_builder_9047: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_9047 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .locked = __yix_view_ctx.locked, .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.locked.peek()) { __yix_ctx.n.set(__yix_ctx.n.peek() + (1)); if (__yix_ctx.n.peek() > 2) { __yix_ctx.n.set(0); } } else { __yix_ctx.n.set(-1); }  } }.__yix_run)), }, "Step", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Guarded", .receiver = "text", .tokens = "text", .literal_text = "Step" }, .{ }, ui.view.text(.{}, ui.view.fmt("Step", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Guarded";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn EventForms(args: anytype) ui.view.ComponentOf(__yix_EventForms) {
    return ui.view.component(__yix_EventForms, ui.reactive.props.coerce(EventFormsProps, args));
}
pub const EventFormsProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = EventForms;
    pub const __yix_preview_mount = __yix_EventForms;
};
fn __yix_EventForms(__yix_props: EventFormsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const a = try scope.createSignalFor(i32, 0);
    const b = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .a = a, .b = b, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EventForms", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EventForms", .receiver = "text", .tokens = "text a  @interpolation b  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, }, ui.view.text(.{ }, ui.view.fmt("a " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.a), "") ++ " b " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.b), ""), .{ __yix_view_ctx.a, __yix_view_ctx.b, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EventForms", .receiver = "Button", .tokens = "< Button onClick = { { if ( a == 0 ) a = 1 else a = 2 ; b = if ( a > 1 ) 10 else 20 ; } } > Go < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "{ if ( a == 0 ) a = 1 else a = 2 ; b = if ( a > 1 ) 10 else 20 ; } ", .kind = .event, .literal = null }, } }, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, }, __yix_builder_9266: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_9266 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .a = __yix_view_ctx.a, .b = __yix_view_ctx.b, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (__yix_ctx.a.peek() == 0) { __yix_ctx.a.set(1); } else { __yix_ctx.a.set(2); } __yix_ctx.b.set(if (__yix_ctx.a.peek() > 1) 10 else 20);  } }.__yix_run)), }, "Go", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EventForms", .receiver = "text", .tokens = "text", .literal_text = "Go" }, .{ }, ui.view.text(.{}, ui.view.fmt("Go", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "EventForms";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn FieldNamedLikeProp(args: anytype) ui.view.ComponentOf(__yix_FieldNamedLikeProp) {
    return ui.view.component(__yix_FieldNamedLikeProp, ui.reactive.props.coerce(FieldNamedLikePropProps, args));
}
pub const FieldNamedLikePropProps = struct {
    title: ui.Source([]const u8) = .{ .value = "prop" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = FieldNamedLikeProp;
    pub const __yix_preview_mount = __yix_FieldNamedLikeProp;
};
fn __yix_FieldNamedLikeProp(__yix_props: FieldNamedLikePropProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    try ui.view.previewCheckSetup(scope, true);
    const rows = try scope.createSignalFor([]const Item, &items);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldNamedLikeProp", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldNamedLikeProp", .receiver = "text", .tokens = "text title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .title = __yix_view_ctx.title, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.title), ""), .{ __yix_view_ctx.title, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldNamedLikeProp", .receiver = "control", .tokens = "for ( rows ) | item | < text > { item . title } - { title } { item . title . len + title . len } < / text > " }, .{ .rows = __yix_view_ctx.rows, .title = __yix_view_ctx.title, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.rows; break :__yix_e1 ui.view.eachWith(.{ .title = __yix_view_ctx.title, }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldNamedLikeProp/keyword_for:1", .receiver = "text", .tokens = "text item . title  @interpolation title  @interpolation item . title . len + title . len  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .item = item, .title = __yix_row_1.title, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), "") ++ "-" ++ ui.view.yixFormat(@TypeOf(__yix_row_1.title), "") ++ " " ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(item.peek().title.len + __yix_row_1.title.peek().len);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, .title = __yix_row_1.title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title.len + __yix_ctx.title.get().len;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, __yix_row_1.title, __yix_d2: {
        const __yix_T = @TypeOf(item.peek().title.len + __yix_row_1.title.peek().len);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, .title = __yix_row_1.title, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title.len + __yix_ctx.title.get().len;
        } }.__yix_compute);
    }, })))); } }.__yix_row); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "FieldNamedLikeProp";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
const Choice = struct { value: []const u8, label: []const u8 };
const choices = [_]Choice{ .{ .value = "a", .label = "Apple" }, .{ .value = "b", .label = "Banana" } };
fn isPicked(value: ?[]const u8, v: []const u8) bool {
    return if (value) |x| std.mem.eql(u8, x, v) else false;
}
pub fn Picker(args: anytype) ui.view.ComponentOf(__yix_Picker) {
    return ui.view.component(__yix_Picker, ui.reactive.props.coerce(PickerProps, args));
}
pub const PickerProps = struct {
    options: ui.Source([]const Choice) = .{ .value = &choices },
    value: ui.Model(?[]const u8) = .{ .local = null },
    on_change: ?ui.Handler([]const u8) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Picker;
    pub const __yix_preview_mount = __yix_Picker;
};
fn __yix_Picker(__yix_props: PickerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const options = __yix_props.options;
    const onChange = __yix_props.on_change;
    const __yix_model_value = try ui.reactive.resolveModelFor(?[]const u8, scope, __yix_props.value);
    const value = __yix_model_value.read;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .options = options, .value = value, .onChange = onChange, .__yix_model_value = __yix_model_value, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Picker", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .options = __yix_view_ctx.options, .value = __yix_view_ctx.value, .onChange = __yix_view_ctx.onChange, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Picker", .receiver = "control", .tokens = "for ( options ) | opt | < row key = { opt . value } > < text > { opt . label } { isPicked ( value , opt . value ) } < / text > < Button label = { opt . label } onClick = { value = opt . value } / > < / row > " }, .{ .options = __yix_view_ctx.options, .value = __yix_view_ctx.value, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.options; break :__yix_e1 ui.view.eachWith(.{ .value = __yix_view_ctx.value, .onChange = __yix_view_ctx.onChange, .__yix_model_value = __yix_view_ctx.__yix_model_value, }, __yix_items_1, struct { fn __yix_k(opt: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(opt.value); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, opt: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Picker/keyword_for:1", .receiver = "row", .tokens = "row key = opt . value ; ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "opt . value ", .kind = .property, .literal = null }, } }, .{ .opt = opt, .value = __yix_row_1.value, .onChange = __yix_row_1.onChange, }, ui.view.row(.{ }, .{
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Picker/keyword_for:1", .receiver = "text", .tokens = "text opt . label  @interpolation isPicked ( value , opt . value )  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .opt = opt, .value = __yix_row_1.value, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(opt.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }), "") ++ " " ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(isPicked(__yix_row_1.value.peek(), opt.peek().value));
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .value = __yix_row_1.value, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return isPicked(__yix_ctx.value.get(), __yix_ctx.opt.get().value);
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(opt.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }, __yix_d2: {
        const __yix_T = @TypeOf(isPicked(__yix_row_1.value.peek(), opt.peek().value));
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .value = __yix_row_1.value, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return isPicked(__yix_ctx.value.get(), __yix_ctx.opt.get().value);
        } }.__yix_compute);
    }, }))),
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Picker/keyword_for:1", .receiver = "Button", .tokens = "< Button label = { opt . label } onClick = { value = opt . value } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "opt . label ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "value = opt . value ", .kind = .event, .literal = null }, } }, .{ .opt = opt, .value = __yix_row_1.value, .onChange = __yix_row_1.onChange, }, __yix_builder_94: { try ui.view.previewCheckBuilder(__yix_scope_1, Button); break :__yix_builder_94 Button(.{ .label = __yix_d3: {
        const __yix_T = if (ui.view.attrType(Button, "label")) |__yix_A| __yix_A else @TypeOf(opt.peek().label);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }, .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_scope_1, .{ .value = __yix_row_1.value, .opt = opt, .__yix_model_value = __yix_row_1.__yix_model_value, .onChange = __yix_row_1.onChange, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.__yix_model_value.propose(__yix_ctx.opt.peek().value, __yix_ctx.onChange);  } }.__yix_run)), }); }),
                }))); } }.__yix_row); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Picker";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PickerUse(args: anytype) ui.view.ComponentOf(__yix_PickerUse) {
    return ui.view.component(__yix_PickerUse, ui.reactive.props.coerce(PickerUseProps, args));
}
pub const PickerUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PickerUse;
    pub const __yix_preview_mount = __yix_PickerUse;
};
fn __yix_PickerUse(__yix_props: PickerUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const picked = try scope.createSignalFor(?[]const u8, null);
    const count = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .picked = picked, .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickerUse", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .count = __yix_view_ctx.count, .picked = __yix_view_ctx.picked, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickerUse", .receiver = "text", .tokens = "text count  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .count = __yix_view_ctx.count, }, ui.view.text(.{ }, ui.view.fmt("count " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.count), ""), .{ __yix_view_ctx.count, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickerUse", .receiver = "Picker", .tokens = "< Picker value = { picked } onChange = { | v | { count += 1 ; _ = v ; } } / > ", .literal_text = null, .attributes = &.{ .{ .name = "value", .tokens = "picked ", .kind = .property, .literal = null }, .{ .name = "on_change", .tokens = "| v | { count += 1 ; _ = v ; } ", .kind = .event, .literal = null }, } }, .{ .picked = __yix_view_ctx.picked, .count = __yix_view_ctx.count, }, __yix_builder_10342: { try ui.view.previewCheckBuilder(__yix_view_scope, Picker); break :__yix_builder_10342 Picker(.{ .value = __yix_view_ctx.picked, .on_change = ui.view.eventProp(Picker, "on_change", try ui.on.bindAny(__yix_view_scope, .{ .count = __yix_view_ctx.count, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, v: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.count.set(__yix_ctx.count.peek() + (1)); _ = v;  } }.__yix_run)), }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PickerUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

// B1: static lifting shrinks to actual dependencies. External store read via function call; static
// params must follow.
pub var external_count: ?*ui.Signal(i32) = null;
fn externalCount() i32 {
    return if (external_count) |s| s.get() else 0;
}
pub fn ExternalSum(args: anytype) ui.view.ComponentOf(__yix_ExternalSum) {
    return ui.view.component(__yix_ExternalSum, ui.reactive.props.coerce(ExternalSumProps, args));
}
pub const ExternalSumProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ExternalSum;
    pub const __yix_preview_mount = __yix_ExternalSum;
};
fn __yix_ExternalSum(__yix_props: ExternalSumProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, false);
    const total = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() + externalCount());
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() + externalCount();
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .total = total, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ExternalSum", .receiver = "text", .tokens = "text total  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .total = __yix_view_ctx.total, }, ui.view.text(.{ }, ui.view.fmt("sum " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.total), ""), .{ __yix_view_ctx.total, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ExternalSum";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn StaticTwice(args: anytype) ui.view.ComponentOf(__yix_StaticTwice) {
    return ui.view.component(__yix_StaticTwice, ui.reactive.props.coerce(StaticTwiceProps, args));
}
pub const StaticTwiceProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = StaticTwice;
    pub const __yix_preview_mount = __yix_StaticTwice;
};
fn __yix_StaticTwice(__yix_props: StaticTwiceProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, true);
    const twice = __yix_d1: {
        const __yix_T = @TypeOf(n.peek() * 2);
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .twice = twice, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "StaticTwice", .receiver = "text", .tokens = "text twice  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .twice = __yix_view_ctx.twice, }, ui.view.text(.{ }, ui.view.fmt("twice " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.twice), ""), .{ __yix_view_ctx.twice, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "StaticTwice";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Text child elements determined by component parameter type, not name: aliased Buttons still
/// treat text as label.
const Btn = W.Button;
pub fn AliasLabel(args: anytype) ui.view.ComponentOf(__yix_AliasLabel) {
    return ui.view.component(__yix_AliasLabel, ui.reactive.props.coerce(AliasLabelProps, args));
}
pub const AliasLabelProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = AliasLabel;
    pub const __yix_preview_mount = __yix_AliasLabel;
};
fn __yix_AliasLabel(__yix_props: AliasLabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "AliasLabel", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "AliasLabel", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "AliasLabel", .receiver = "Btn", .tokens = "< Btn onClick = { n += 1 } > Aliased < / Btn > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "n += 1 ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_11138: { try ui.view.previewCheckBuilder(__yix_view_scope, Btn); break :__yix_builder_11138 ui.view.textChild(Btn, .{ .on_click = ui.view.eventProp(Btn, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "Aliased", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "AliasLabel", .receiver = "text", .tokens = "text", .literal_text = "Aliased" }, .{ }, ui.view.text(.{}, ui.view.fmt("Aliased", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "AliasLabel";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Components without label parameter (with slots): text remains child element.
pub fn TextIntoSlot(args: anytype) ui.view.ComponentOf(__yix_TextIntoSlot) {
    return ui.view.component(__yix_TextIntoSlot, ui.reactive.props.coerce(TextIntoSlotProps, args));
}
pub const TextIntoSlotProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TextIntoSlot;
    pub const __yix_preview_mount = __yix_TextIntoSlot;
};
fn __yix_TextIntoSlot(__yix_props: TextIntoSlotProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextIntoSlot", .receiver = "Panel", .tokens = "< Panel title = \"p\" > plain words < / Panel > ", .literal_text = null, .attributes = &.{ .{ .name = "title", .tokens = "\"p\" ", .kind = .property, .literal = .{ .text = "p" } }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_11304: { try ui.view.previewCheckBuilder(__yix_view_scope, Panel); break :__yix_builder_11304 ui.view.textChild(Panel, .{ .title = "p", }, "plain words", .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TextIntoSlot", .receiver = "text", .tokens = "text", .literal_text = "plain words" }, .{ }, ui.view.text(.{}, ui.view.fmt("plain words", .{ }))),
        }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TextIntoSlot";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// No default value means required (for data parameters and Handlers).
pub fn Required(args: anytype) ui.view.ComponentOf(__yix_Required) {
    return ui.view.component(__yix_Required, ui.reactive.props.coerce(RequiredProps, args));
}
pub const RequiredProps = struct {
    title: ui.Source([]const u8),
    on_go: ui.Handler(void),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Required;
    pub const __yix_preview_mount = __yix_Required;
};
fn __yix_Required(__yix_props: RequiredProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const onGo = __yix_props.on_go;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, .onGo = onGo, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Required", .receiver = "Button", .tokens = "< Button label = { title } onClick = { onGo } / > ", .literal_text = null, .attributes = &.{ .{ .name = "label", .tokens = "title ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "onGo ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, .onGo = __yix_view_ctx.onGo, }, __yix_builder_11490: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_11490 Button(.{ .label = __yix_view_ctx.title, .on_click = if (comptime ui.view.isEventProp(Button, "on_click")) __yix_view_ctx.onGo else __yix_view_ctx.onGo, }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Required";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn RequiredUse(args: anytype) ui.view.ComponentOf(__yix_RequiredUse) {
    return ui.view.component(__yix_RequiredUse, ui.reactive.props.coerce(RequiredUseProps, args));
}
pub const RequiredUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = RequiredUse;
    pub const __yix_preview_mount = __yix_RequiredUse;
};
fn __yix_RequiredUse(__yix_props: RequiredUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RequiredUse", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RequiredUse", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("went " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "RequiredUse", .receiver = "Required", .tokens = "< Required title = \"Go there\" onGo = { n += 1 } / > ", .literal_text = null, .attributes = &.{ .{ .name = "title", .tokens = "\"Go there\" ", .kind = .property, .literal = .{ .text = "Go there" } }, .{ .name = "on_go", .tokens = "n += 1 ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_11626: { try ui.view.previewCheckBuilder(__yix_view_scope, Required); break :__yix_builder_11626 Required(.{ .title = "Go there", .on_go = ui.view.eventProp(Required, "on_go", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "RequiredUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// I6: optional value capture. Value changes within the same branch update only text, branch does
/// not rebuild.
pub fn PickedName(args: anytype) ui.view.ComponentOf(__yix_PickedName) {
    return ui.view.component(__yix_PickedName, ui.reactive.props.coerce(PickedNameProps, args));
}
pub const PickedNameProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PickedName;
    pub const __yix_preview_mount = __yix_PickedName;
};
fn __yix_PickedName(__yix_props: PickedNameProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const picked = try scope.createSignalFor(?[]const u8, null);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .picked = picked, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .picked = __yix_view_ctx.picked, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "control", .tokens = "if ( picked ) | name | < text > picked { name } < / text > else < text > none < / text > " }, .{ .picked = __yix_view_ctx.picked, }, ui.view.lazyIfSome(__yix_view_ctx.picked, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, name: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName/keyword_if:1/branch:0", .receiver = "text", .tokens = "text name  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .name = name, }, ui.view.text(.{ }, ui.view.fmt("picked " ++ ui.view.yixFormat(@TypeOf(name), ""), .{ name, }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName/keyword_if:1/branch:1", .receiver = "text", .tokens = "text ", .literal_text = "none", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("none", .{ }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "Button", .tokens = "< Button onClick = { picked = \"a\" } > A < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "picked = \"a\" ", .kind = .event, .literal = null }, } }, .{ .picked = __yix_view_ctx.picked, }, __yix_builder_11988: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_11988 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .picked = __yix_view_ctx.picked, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set("a");  } }.__yix_run)), }, "A", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "text", .tokens = "text", .literal_text = "A" }, .{ }, ui.view.text(.{}, ui.view.fmt("A", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "Button", .tokens = "< Button onClick = { picked = \"b\" } > B < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "picked = \"b\" ", .kind = .event, .literal = null }, } }, .{ .picked = __yix_view_ctx.picked, }, __yix_builder_12042: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_12042 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .picked = __yix_view_ctx.picked, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set("b");  } }.__yix_run)), }, "B", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "text", .tokens = "text", .literal_text = "B" }, .{ }, ui.view.text(.{}, ui.view.fmt("B", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "Button", .tokens = "< Button onClick = { picked = null } > Clear < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "picked = null ", .kind = .event, .literal = null }, } }, .{ .picked = __yix_view_ctx.picked, }, __yix_builder_12096: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_12096 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .picked = __yix_view_ctx.picked, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.picked.set(null);  } }.__yix_run)), }, "Clear", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PickedName", .receiver = "text", .tokens = "text", .literal_text = "Clear" }, .{ }, ui.view.text(.{}, ui.view.fmt("Clear", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PickedName";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub const Shape = union(enum) { circle: i32, square: i32, none };
/// I6: payload capture with tagged union.
pub fn ShapeLabel(args: anytype) ui.view.ComponentOf(__yix_ShapeLabel) {
    return ui.view.component(__yix_ShapeLabel, ui.reactive.props.coerce(ShapeLabelProps, args));
}
pub const ShapeLabelProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ShapeLabel;
    pub const __yix_preview_mount = __yix_ShapeLabel;
};
fn __yix_ShapeLabel(__yix_props: ShapeLabelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const shape = try scope.createSignalFor(Shape, .{ .circle = 1 });
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .shape = shape, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shape = __yix_view_ctx.shape, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "control", .tokens = "switch ( shape ) { . circle => | r | < text > circle { r } < / text > , . square => | w | < text > square { w } < / text > , . none => < text > no shape < / text > } " }, .{ .shape = __yix_view_ctx.shape, }, ui.view.lazySwitch(__yix_view_ctx.shape, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bt1_0: anytype, __yix_bv1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; switch (__yix_bt1_0) { .circle => { const r = try ui.view.branchValue(__yix_bs1_0, __yix_bv1_0, ui.view.payloadOf(@TypeOf(__yix_bv1_0.peek()), .circle)); return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel/keyword_switch:1/case:.circle", .receiver = "text", .tokens = "text r  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .r = r, }, ui.view.text(.{ }, ui.view.fmt("circle " ++ ui.view.yixFormat(@TypeOf(r), ""), .{ r, }))) }); }, .square => { const w = try ui.view.branchValue(__yix_bs1_0, __yix_bv1_0, ui.view.payloadOf(@TypeOf(__yix_bv1_0.peek()), .square)); return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel/keyword_switch:1/case:.square", .receiver = "text", .tokens = "text w  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .w = w, }, ui.view.text(.{ }, ui.view.fmt("square " ++ ui.view.yixFormat(@TypeOf(w), ""), .{ w, }))) }); }, .none => { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel/keyword_switch:1/case:.none", .receiver = "text", .tokens = "text ", .literal_text = "no shape", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("no shape", .{ }))) }); }, } } }.__yix_b)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "Button", .tokens = "< Button onClick = { shape = . { . circle = 2 } } > Grow < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "shape = . { . circle = 2 } ", .kind = .event, .literal = null }, } }, .{ .shape = __yix_view_ctx.shape, }, __yix_builder_12535: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_12535 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .shape = __yix_view_ctx.shape, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.{ .circle = 2 });  } }.__yix_run)), }, "Grow", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "text", .tokens = "text", .literal_text = "Grow" }, .{ }, ui.view.text(.{}, ui.view.fmt("Grow", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "Button", .tokens = "< Button onClick = { shape = . { . square = 5 } } > Square < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "shape = . { . square = 5 } ", .kind = .event, .literal = null }, } }, .{ .shape = __yix_view_ctx.shape, }, __yix_builder_12604: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_12604 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .shape = __yix_view_ctx.shape, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.{ .square = 5 });  } }.__yix_run)), }, "Square", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "text", .tokens = "text", .literal_text = "Square" }, .{ }, ui.view.text(.{}, ui.view.fmt("Square", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "Button", .tokens = "< Button onClick = { shape = . none } > None < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "shape = . none ", .kind = .event, .literal = null }, } }, .{ .shape = __yix_view_ctx.shape, }, __yix_builder_12675: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_12675 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .shape = __yix_view_ctx.shape, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shape.set(.none);  } }.__yix_run)), }, "None", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "ShapeLabel", .receiver = "text", .tokens = "text", .literal_text = "None" }, .{ }, ui.view.text(.{}, ui.view.fmt("None", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ShapeLabel";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub const ParseError = error{Bad};
/// I6: value / error capture from error union.
pub fn Parsed(args: anytype) ui.view.ComponentOf(__yix_Parsed) {
    return ui.view.component(__yix_Parsed, ui.reactive.props.coerce(ParsedProps, args));
}
pub const ParsedProps = struct {
    result: ui.Source(ParseError!i32),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Parsed;
    pub const __yix_preview_mount = __yix_Parsed;
};
fn __yix_Parsed(__yix_props: ParsedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const result = __yix_props.result;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .result = result, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Parsed", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .result = __yix_view_ctx.result, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Parsed", .receiver = "control", .tokens = "if ( result ) | v | < text > value { v } < / text > else | e | < text > error { @errorName ( e ) } < / text > " }, .{ .result = __yix_view_ctx.result, }, ui.view.lazyIfSome(__yix_view_ctx.result, .{ }, struct { fn __yix_b(__yix_b1_0: anytype, v: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { _ = __yix_b1_0; return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Parsed/keyword_if:1/branch:0", .receiver = "text", .tokens = "text v  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .v = v, }, ui.view.text(.{ }, ui.view.fmt("value " ++ ui.view.yixFormat(@TypeOf(v), ""), .{ v, }))) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, e: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { _ = __yix_b1_1; return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Parsed/keyword_if:1/branch:1", .receiver = "text", .tokens = "text @errorName ( e )  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .e = e, }, ui.view.text(.{ }, ui.view.fmt("error " ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(@errorName(e.peek()));
        break :__yix_d1 try __yix_bs1_1.derive(__yix_T, .{ .e = e, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @errorName(__yix_ctx.e.get());
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(@errorName(e.peek()));
        break :__yix_d1 try __yix_bs1_1.derive(__yix_T, .{ .e = e, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @errorName(__yix_ctx.e.get());
        } }.__yix_compute);
    }, }))) }); } }.__yix_b)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Parsed";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// I12: lazy branch construction. Hidden branches do not construct derived values inside.
pub fn LazyBranch(args: anytype) ui.view.ComponentOf(__yix_LazyBranch) {
    return ui.view.component(__yix_LazyBranch, ui.reactive.props.coerce(LazyBranchProps, args));
}
pub const LazyBranchProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = LazyBranch;
    pub const __yix_preview_mount = __yix_LazyBranch;
};
fn __yix_LazyBranch(__yix_props: LazyBranchProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, true);
    const shown = try scope.createSignalFor(bool, false);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, .shown = shown, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LazyBranch", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .shown = __yix_view_ctx.shown, .n = __yix_view_ctx.n, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LazyBranch", .receiver = "control", .tokens = "if ( shown ) < text > { n * 2 + 1 } < / text > " }, .{ .shown = __yix_view_ctx.shown, .n = __yix_view_ctx.n, }, ui.view.lazyIf(__yix_view_ctx.shown, .{ .n = __yix_view_ctx.n, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LazyBranch/keyword_if:1/branch:0", .receiver = "text", .tokens = "text n * 2 + 1  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_b1_0.n, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.n.peek() * 2 + 1);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .n = __yix_b1_0.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2 + 1;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_b1_0.n.peek() * 2 + 1);
        break :__yix_d1 try __yix_bs1_0.derive(__yix_T, .{ .n = __yix_b1_0.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.n.get() * 2 + 1;
        } }.__yix_compute);
    }, }))) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LazyBranch", .receiver = "Button", .tokens = "< Button onClick = { shown = ! shown } > Toggle < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "shown = ! shown ", .kind = .event, .literal = null }, } }, .{ .shown = __yix_view_ctx.shown, }, __yix_builder_13201: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_13201 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .shown = __yix_view_ctx.shown, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.shown.set(!__yix_ctx.shown.peek());  } }.__yix_run)), }, "Toggle", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LazyBranch", .receiver = "text", .tokens = "text", .literal_text = "Toggle" }, .{ }, ui.view.text(.{}, ui.view.fmt("Toggle", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "LazyBranch";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// B2: host element typed events (keyboard / pointer / scroll); e.consume() prevents default
/// behavior.
pub fn KeyPad(args: anytype) ui.view.ComponentOf(__yix_KeyPad) {
    return ui.view.component(__yix_KeyPad, ui.reactive.props.coerce(KeyPadProps, args));
}
pub const KeyPadProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = KeyPad;
    pub const __yix_preview_mount = __yix_KeyPad;
};
fn __yix_KeyPad(__yix_props: KeyPadProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const last = try scope.createSignalFor([]const u8, "none");
    const px = try scope.createSignalFor(f32, 0);
    const moves = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .last = last, .px = px, .moves = moves, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "KeyPad", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .last = __yix_view_ctx.last, .px = __yix_view_ctx.px, .moves = __yix_view_ctx.moves, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "KeyPad", .receiver = "box", .tokens = "box testId = @static; focusable = @static; onKeyDown = | e | if ( e . key == . escape ) { last = \"escape\" ; e . consume ( ) ; } else last = \"other\" ; onPointerDown = | e | px = e . x ; onPointerMove = moves += 1 ; onScroll = | e | e . stop ( ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"pad\" ", .kind = .property, .literal = .{ .text = "pad" } }, .{ .name = "focusable", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "on_key_down", .tokens = "| e | if ( e . key == . escape ) { last = \"escape\" ; e . consume ( ) ; } else last = \"other\" ", .kind = .event, .literal = null }, .{ .name = "on_pointer_down", .tokens = "| e | px = e . x ", .kind = .event, .literal = null }, .{ .name = "on_pointer_move", .tokens = "moves += 1 ", .kind = .event, .literal = null }, .{ .name = "on_scroll", .tokens = "| e | e . stop ( ) ", .kind = .event, .literal = null }, } }, .{ .last = __yix_view_ctx.last, .px = __yix_view_ctx.px, .moves = __yix_view_ctx.moves, }, ui.view.box(.{ .test_id = "pad", .focusable = true, .on_key_down = try ui.on.bindAny(__yix_view_scope, .{ .last = __yix_view_ctx.last, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (e.key == .escape) { __yix_ctx.last.set("escape"); e.consume(); } else { __yix_ctx.last.set("other"); }  } }.__yix_run), .on_pointer_down = try ui.on.bindAny(__yix_view_scope, .{ .px = __yix_view_ctx.px, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.px.set(e.x);  } }.__yix_run), .on_pointer_move = try ui.on.bindAny(__yix_view_scope, .{ .moves = __yix_view_ctx.moves, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.moves.set(__yix_ctx.moves.peek() + (1));  } }.__yix_run), .on_scroll = try ui.on.bindAny(__yix_view_scope, .{ .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype, e: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); e.stop();  } }.__yix_run), }, .{ })),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "KeyPad", .receiver = "text", .tokens = "text last  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .last = __yix_view_ctx.last, }, ui.view.text(.{ }, ui.view.fmt("key " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.last), ""), .{ __yix_view_ctx.last, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "KeyPad", .receiver = "text", .tokens = "text px  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .px = __yix_view_ctx.px, }, ui.view.text(.{ }, ui.view.fmt("x " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.px), ""), .{ __yix_view_ctx.px, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "KeyPad", .receiver = "text", .tokens = "text moves  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .moves = __yix_view_ctx.moves, }, ui.view.text(.{ }, ui.view.fmt("moves " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.moves), ""), .{ __yix_view_ctx.moves, }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "KeyPad";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub var lifecycle_log: [8]i32 = @splat(0);
pub var lifecycle_len: usize = 0;
fn logLifecycle(v: i32) void {
    lifecycle_log[lifecycle_len] = v;
    lifecycle_len += 1;
}
fn mounted(r: anytype) i32 {
    return if (r.get() != null) 1 else 0;
}
/// B2: effects follow source; ref attached at onMount; onUnmount executes during unmount.
pub fn Lifecycle(args: anytype) ui.view.ComponentOf(__yix_Lifecycle) {
    return ui.view.component(__yix_Lifecycle, ui.reactive.props.coerce(LifecycleProps, args));
}
pub const LifecycleProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Lifecycle;
    pub const __yix_preview_mount = __yix_Lifecycle;
};
fn __yix_Lifecycle(__yix_props: LifecycleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, true);
    const doubled = try scope.createSignalFor(i32, 0);
    const root = try ui.view.createRef(scope, *ui.Node);
    try ui.view.setupEffect(scope, .{ .doubled = doubled, .n = n, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.doubled.set(__yix_ctx.n.get() * 2);  } }.__yix_run);
    try ui.view.setupCleanup(scope, .{ .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onUnmount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); logLifecycle(-1);  } }.__yix_run);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .doubled = doubled, .root = root, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Lifecycle", .receiver = "col", .tokens = "< col ref = { root } > < text > doubled { doubled } < / text > < / col > ", .literal_text = null, .attributes = &.{ .{ .name = "ref", .tokens = "root ", .kind = .reference, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .root = __yix_view_ctx.root, .doubled = __yix_view_ctx.doubled, }, ui.view.ref(__yix_view_ctx.root, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Lifecycle", .receiver = "text", .tokens = "text doubled  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .doubled = __yix_view_ctx.doubled, }, ui.view.text(.{ }, ui.view.fmt("doubled " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.doubled), ""), .{ __yix_view_ctx.doubled, }))),
        }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Lifecycle";
    return __yix_root;
    } }.__yix_render);
    try ui.view.runLifecycleAction(scope, "onMount", .{ .root = root, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { if (comptime @import("builtin").is_test) __yix_ctx.__yix_owner.recordTestHook(.onMount); __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); logLifecycle(mounted(__yix_ctx.root));  } }.__yix_run);
    return __yix_view;

}
fn mayFail(ok: bool) !i32 {
    if (!ok) return error.Nope;
    return 5;
}
/// B2: try in event (failure reported via ui.on.reportError, following statements don't execute)
/// and const locals.
pub fn TryEvent(args: anytype) ui.view.ComponentOf(__yix_TryEvent) {
    return ui.view.component(__yix_TryEvent, ui.reactive.props.coerce(TryEventProps, args));
}
pub const TryEventProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TryEvent;
    pub const __yix_preview_mount = __yix_TryEvent;
};
fn __yix_TryEvent(__yix_props: TryEventProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("n " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "Button", .tokens = "< Button onClick = { { const v = try mayFail ( true ) ; n += v ; } } > Ok < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "{ const v = try mayFail ( true ) ; n += v ; } ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_14895: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_14895 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { body(__yix_ctx) catch |err| ui.on.reportError("onClick", err); } fn body(__yix_ctx: anytype) anyerror!void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); const v = try mayFail(true); __yix_ctx.n.set(__yix_ctx.n.peek() + (v));  } }.__yix_run)), }, "Ok", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "text", .tokens = "text", .literal_text = "Ok" }, .{ }, ui.view.text(.{}, ui.view.fmt("Ok", .{ }))),
            }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "Button", .tokens = "< Button onClick = { { const v = try mayFail ( false ) ; n += v ; } } > Fail < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "{ const v = try mayFail ( false ) ; n += v ; } ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_14978: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_14978 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { body(__yix_ctx) catch |err| ui.on.reportError("onClick", err); } fn body(__yix_ctx: anytype) anyerror!void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); const v = try mayFail(false); __yix_ctx.n.set(__yix_ctx.n.peek() + (v));  } }.__yix_run)), }, "Fail", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TryEvent", .receiver = "text", .tokens = "text", .literal_text = "Fail" }, .{ }, ui.view.text(.{}, ui.view.fmt("Fail", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TryEvent";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// P3a: :focus (click) / :focus-visible (keyboard) / :disabled (from a11y.disabled) on plain box.
pub fn StateBox(args: anytype) ui.view.ComponentOf(__yix_StateBox) {
    return ui.view.component(__yix_StateBox, ui.reactive.props.coerce(StateBoxProps, args));
}
pub const StateBoxProps = struct {
    disabled: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = StateBox;
    pub const __yix_preview_mount = __yix_StateBox;
};
fn __yix_StateBox(__yix_props: StateBoxProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const disabled = __yix_props.disabled;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .disabled = disabled, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "StateBox", .receiver = "box", .tokens = "box testId = @static; focusable = @static; style = @static; a11y = . { . role = . button , . disabled = disabled } ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"sb\" ", .kind = .property, .literal = .{ .text = "sb" } }, .{ .name = "focusable", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "style", .tokens = "States . field ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = ". { . role = . button , . disabled = disabled } ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .disabled = __yix_view_ctx.disabled, }, ui.view.box(.{ .test_id = "sb", .focusable = true, .style = States.field, .a11y = .{ .role = .button, .disabled = __yix_view_ctx.disabled }, }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "StateBox";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// P3b: named slots; {children} need not be the last child.
pub fn Frame(args: anytype) ui.view.SlottedOf(__yix_Frame) {
    return ui.view.slotted(__yix_Frame, ui.reactive.props.coerce(FrameProps, args));
}
pub const FrameProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Frame;
    pub const __yix_preview_mount = __yix_Frame;
};
fn __yix_Frame(__yix_props: FrameProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    var __yix_slot_header: ?ui.view.SlotPoint = null;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    var __yix_slot_footer: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Frame", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, }, ui.view.slotEnd(&__yix_slot_footer, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Frame", .receiver = "row", .tokens = "row ", .literal_text = null, .attributes = &.{ } }, .{ .title = __yix_view_ctx.title, }, ui.view.row(.{ }, .{
                ui.view.slotMark(&__yix_slot_header),
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Frame", .receiver = "text", .tokens = "text title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .title = __yix_view_ctx.title, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.title), ""), .{ __yix_view_ctx.title, }))),
            })),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Frame", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ } }, .{ }, ui.view.col(.{ }, .{
                ui.view.slotMark(&__yix_slot_children),
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Frame", .receiver = "text", .tokens = "text ", .literal_text = "after body", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("after body", .{ }))),
            })),
        }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Frame";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ .header = __yix_slot_header, .footer = __yix_slot_footer, });
    } }.__yix_render);
    return __yix_view;

}
pub fn FrameUse(args: anytype) ui.view.ComponentOf(__yix_FrameUse) {
    return ui.view.component(__yix_FrameUse, ui.reactive.props.coerce(FrameUseProps, args));
}
pub const FrameUseProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = FrameUse;
    pub const __yix_preview_mount = __yix_FrameUse;
};
fn __yix_FrameUse(__yix_props: FrameUseProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FrameUse", .receiver = "Frame", .tokens = "< Frame title = \"T\" header = { < text > head < / text > } footer = { < Button onClick = { n += 1 } > More < / Button > } > < text > body { n } < / text > < / Frame > ", .literal_text = null, .attributes = &.{ .{ .name = "title", .tokens = "\"T\" ", .kind = .property, .literal = .{ .text = "T" } }, .{ .name = "header", .tokens = "< text > head < / text > ", .kind = .property, .literal = null }, .{ .name = "footer", .tokens = "< Button onClick = { n += 1 } > More < / Button > ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, __yix_builder_15731: { try ui.view.previewCheckBuilder(__yix_view_scope, Frame); break :__yix_builder_15731 ui.view.with(Frame(.{ .title = "T", }), .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FrameUse", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("body " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
        }).slots(.{ .header = ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FrameUse/slot:header", .receiver = "text", .tokens = "text ", .literal_text = "head", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("head", .{ }))), .footer = ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FrameUse/slot:footer", .receiver = "Button", .tokens = "< Button onClick = { n += 1 } > More < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "n += 1 ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_0: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_0 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "More", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FrameUse/slot:footer", .receiver = "text", .tokens = "text", .literal_text = "More" }, .{ }, ui.view.text(.{}, ui.view.fmt("More", .{ }))),
            }); }), }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "FrameUse";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Optional named slots (?View): a slot box exists only when the caller filled the slot, so an
/// absent icon leaves no gap.
pub fn Field(args: anytype) ui.view.SlottedOf(__yix_Field) {
    return ui.view.slotted(__yix_Field, ui.reactive.props.coerce(FieldProps, args));
}
pub const FieldProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Field;
    pub const __yix_preview_mount = __yix_Field;
};
fn __yix_Field(__yix_props: FieldProps, __yix_present: ui.view.SlotPresence, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .__yix_present = __yix_present, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!ui.view.ViewParts {
    var __yix_slot_icon: ?ui.view.SlotPoint = null;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    var __yix_slot_append: ?ui.view.SlotPoint = null;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Field", .receiver = "row", .tokens = "row testId = @static; style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"field\" ", .kind = .property, .literal = .{ .text = "field" } }, .{ .name = "style", .tokens = ". { . gap = 6 } ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.row(.{ .test_id = "field", .style = .{ .gap = 6 }, }, .{
            if (__yix_view_ctx.__yix_present.has("icon")) ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Field", .receiver = "box", .tokens = "box testId = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"field.icon\" ", .kind = .property, .literal = .{ .text = "field.icon" } }, } }, .{ }, ui.view.slotEnd(&__yix_slot_icon, ui.view.box(.{ .test_id = "field.icon", }, .{ }))) else null,
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Field", .receiver = "row", .tokens = "row testId = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"field.content\" ", .kind = .property, .literal = .{ .text = "field.content" } }, } }, .{ }, ui.view.slotEnd(&__yix_slot_children, ui.view.row(.{ .test_id = "field.content", }, .{ }))),
            if (__yix_view_ctx.__yix_present.has("append")) ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Field", .receiver = "box", .tokens = "box testId = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"field.append\" ", .kind = .property, .literal = .{ .text = "field.append" } }, } }, .{ }, ui.view.slotEnd(&__yix_slot_append, ui.view.box(.{ .test_id = "field.append", }, .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Field", .receiver = "text", .tokens = "text ", .literal_text = "[", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("[", .{ }))),
            }))) else null,
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Field";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ .icon = __yix_slot_icon, .append = __yix_slot_append, });
    } }.__yix_render);
    return __yix_view;

}
pub fn FieldBare(args: anytype) ui.view.ComponentOf(__yix_FieldBare) {
    return ui.view.component(__yix_FieldBare, ui.reactive.props.coerce(FieldBareProps, args));
}
pub const FieldBareProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = FieldBare;
    pub const __yix_preview_mount = __yix_FieldBare;
};
fn __yix_FieldBare(__yix_props: FieldBareProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldBare", .receiver = "Field", .tokens = "< Field > < text > body < / text > < / Field > ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_16373: { try ui.view.previewCheckBuilder(__yix_view_scope, Field); break :__yix_builder_16373 ui.view.with(Field(.{ }), .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldBare", .receiver = "text", .tokens = "text ", .literal_text = "body", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("body", .{ }))),
        }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "FieldBare";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn FieldFull(args: anytype) ui.view.ComponentOf(__yix_FieldFull) {
    return ui.view.component(__yix_FieldFull, ui.reactive.props.coerce(FieldFullProps, args));
}
pub const FieldFullProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = FieldFull;
    pub const __yix_preview_mount = __yix_FieldFull;
};
fn __yix_FieldFull(__yix_props: FieldFullProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const n = try scope.createSignalFor(i32, 0);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldFull", .receiver = "Field", .tokens = "< Field icon = { < text > ico < / text > } append = { < Button onClick = { n += 1 } > go < / Button > } > < text > body { n } < / text > < / Field > ", .literal_text = null, .attributes = &.{ .{ .name = "icon", .tokens = "< text > ico < / text > ", .kind = .property, .literal = null }, .{ .name = "append", .tokens = "< Button onClick = { n += 1 } > go < / Button > ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, __yix_builder_16474: { try ui.view.previewCheckBuilder(__yix_view_scope, Field); break :__yix_builder_16474 ui.view.with(Field(.{ }), .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldFull", .receiver = "text", .tokens = "text n  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt("body " ++ ui.view.yixFormat(@TypeOf(__yix_view_ctx.n), ""), .{ __yix_view_ctx.n, }))),
        }).slots(.{ .icon = ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldFull/slot:icon", .receiver = "text", .tokens = "text ", .literal_text = "ico", .attributes = &.{ } }, .{ }, ui.view.text(.{ }, ui.view.fmt("ico", .{ }))), .append = ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldFull/slot:append", .receiver = "Button", .tokens = "< Button onClick = { n += 1 } > go < / Button > ", .literal_text = null, .attributes = &.{ .{ .name = "on_click", .tokens = "n += 1 ", .kind = .event, .literal = null }, } }, .{ .n = __yix_view_ctx.n, }, __yix_builder_0: { try ui.view.previewCheckBuilder(__yix_view_scope, Button); break :__yix_builder_0 ui.view.textChild(Button, .{ .on_click = ui.view.eventProp(Button, "on_click", try ui.on.bindAny(__yix_view_scope, .{ .n = __yix_view_ctx.n, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.n.set(__yix_ctx.n.peek() + (1));  } }.__yix_run)), }, "go", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "FieldFull/slot:append", .receiver = "text", .tokens = "text", .literal_text = "go" }, .{ }, ui.view.text(.{}, ui.view.fmt("go", .{ }))),
            }); }), }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "FieldFull";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// P4: icon-color toggles with flag; reverts to mount-time tint on undo.
pub fn GlyphBox(args: anytype) ui.view.ComponentOf(__yix_GlyphBox) {
    return ui.view.component(__yix_GlyphBox, ui.reactive.props.coerce(GlyphBoxProps, args));
}
pub const GlyphBoxProps = struct {
    hot: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = GlyphBox;
    pub const __yix_preview_mount = __yix_GlyphBox;
};
fn __yix_GlyphBox(__yix_props: GlyphBoxProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const hot = __yix_props.hot;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .hot = hot, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GlyphBox", .receiver = "icon", .tokens = "icon testId = @static; style = States . Glyph . of ( . { . hot = hot } ) ; src = ui . icons . check ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"glyph\" ", .kind = .property, .literal = .{ .text = "glyph" } }, .{ .name = "style", .tokens = "States . Glyph . of ( . { . hot = hot } ) ", .kind = .style, .literal = null }, .{ .name = "src", .tokens = "ui . icons . check ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .hot = __yix_view_ctx.hot, }, ui.view.icon(.{ .test_id = "glyph", .style = States.Glyph.of(.{ .hot = __yix_view_ctx.hot }), }, ui.icons.check)));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "GlyphBox";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn GlyphTinted(args: anytype) ui.view.ComponentOf(__yix_GlyphTinted) {
    return ui.view.component(__yix_GlyphTinted, ui.reactive.props.coerce(GlyphTintedProps, args));
}
pub const GlyphTintedProps = struct {
    hot: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = GlyphTinted;
    pub const __yix_preview_mount = __yix_GlyphTinted;
};
fn __yix_GlyphTinted(__yix_props: GlyphTintedProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const hot = __yix_props.hot;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .hot = hot, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "GlyphTinted", .receiver = "icon", .tokens = "icon testId = @static; style = States . GlyphOnHot . of ( . { . hot = hot } ) ; src = ui . icons . check ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"glyph\" ", .kind = .property, .literal = .{ .text = "glyph" } }, .{ .name = "style", .tokens = "States . GlyphOnHot . of ( . { . hot = hot } ) ", .kind = .style, .literal = null }, .{ .name = "src", .tokens = "ui . icons . check ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .hot = __yix_view_ctx.hot, }, ui.view.icon(.{ .test_id = "glyph", .style = States.GlyphOnHot.of(.{ .hot = __yix_view_ctx.hot }), }, ui.icons.check)));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "GlyphTinted";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn LinkText(args: anytype) ui.view.ComponentOf(__yix_LinkText) {
    return ui.view.component(__yix_LinkText, ui.reactive.props.coerce(LinkTextProps, args));
}
pub const LinkTextProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = LinkText;
    pub const __yix_preview_mount = __yix_LinkText;
};
fn __yix_LinkText(__yix_props: LinkTextProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LinkText", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "LinkText", .receiver = "text", .tokens = "text testId = @static; style = @static; ", .literal_text = "Open docs", .attributes = &.{ .{ .name = "test_id", .tokens = "\"link\" ", .kind = .property, .literal = .{ .text = "link" } }, .{ .name = "style", .tokens = "States . link ", .kind = .style, .literal = null }, } }, .{ }, ui.view.text(.{ .test_id = "link", .style = States.link, }, ui.view.fmt("Open docs", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "LinkText";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PillText(args: anytype) ui.view.ComponentOf(__yix_PillText) {
    return ui.view.component(__yix_PillText, ui.reactive.props.coerce(PillTextProps, args));
}
pub const PillTextProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PillText;
    pub const __yix_preview_mount = __yix_PillText;
};
fn __yix_PillText(__yix_props: PillTextProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PillText", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PillText", .receiver = "text", .tokens = "text testId = @static; style = @static; ", .literal_text = "Beta", .attributes = &.{ .{ .name = "test_id", .tokens = "\"pill\" ", .kind = .property, .literal = .{ .text = "pill" } }, .{ .name = "style", .tokens = "States . pill ", .kind = .style, .literal = null }, } }, .{ }, ui.view.text(.{ .test_id = "pill", .style = States.pill, }, ui.view.fmt("Beta", .{ }))),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PillText";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// P5: in-place list row update -- same key, changed content does not rebuild row (focus/local
/// state preserved); event reads latest data.
pub var picked_title: []const u8 = "";
fn pick(title: []const u8) void {
    picked_title = title;
}
pub fn EditableRows(args: anytype) ui.view.ComponentOf(__yix_EditableRows) {
    return ui.view.component(__yix_EditableRows, ui.reactive.props.coerce(EditableRowsProps, args));
}
pub const EditableRowsProps = struct {
    rows: ui.Source([]const Item) = .{ .value = &.{} },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = EditableRows;
    pub const __yix_preview_mount = __yix_EditableRows;
};
fn __yix_EditableRows(__yix_props: EditableRowsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const rows = __yix_props.rows;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .rows = rows, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EditableRows", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .rows = __yix_view_ctx.rows, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EditableRows", .receiver = "control", .tokens = "for ( rows ) | item , i | < row testId = \"row\" focusable onClick = { pick ( item . title ) } > < text > { i } : { item . title } < / text > < / row > " }, .{ .rows = __yix_view_ctx.rows, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.rows; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EditableRows/keyword_for:1", .receiver = "row", .tokens = "row testId = @static; focusable = @static; onClick = pick ( item . title ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"row\" ", .kind = .property, .literal = .{ .text = "row" } }, .{ .name = "focusable", .tokens = "true ", .kind = .property, .literal = .{ .boolean = true } }, .{ .name = "on_click", .tokens = "pick ( item . title ) ", .kind = .event, .literal = null }, } }, .{ .item = item, .i = i, }, ui.view.row(.{ .test_id = "row", .focusable = true, .on_click = try ui.on.bind(__yix_scope_1, .{ .item = item, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); pick(__yix_ctx.item.peek().title);  } }.__yix_run), }, .{
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "EditableRows/keyword_for:1", .receiver = "text", .tokens = "text i  @interpolation item . title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .i = i, .item = item, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(i), "") ++ ":" ++ ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ i, __yix_d1: {
        const __yix_T = @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))),
                }))); } }.__yix_row); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "EditableRows";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Data parameters named on* (e.g., onTop: bool) pass by value; event params receiving identifier
/// call it.
pub var saved_count: u32 = 0;
fn save() void {
    saved_count += 1;
}
fn Pin(args: anytype) ui.view.ComponentOf(__yix_Pin) {
    return ui.view.component(__yix_Pin, ui.reactive.props.coerce(PinProps, args));
}
const PinProps = struct {
    on_top: ui.Source(bool) = .{ .value = false },
    on_save: ?ui.Handler(void) = null,
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Pin;
    pub const __yix_preview_mount = __yix_Pin;
};
fn __yix_Pin(__yix_props: PinProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const onTop = __yix_props.on_top;
    const onSave = __yix_props.on_save;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .onTop = onTop, .onSave = onSave, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Pin", .receiver = "box", .tokens = "box testId = @static; visible = onTop ; onClick = onSave ; ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"pin\" ", .kind = .property, .literal = .{ .text = "pin" } }, .{ .name = "visible", .tokens = "onTop ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "onSave ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .onTop = __yix_view_ctx.onTop, .onSave = __yix_view_ctx.onSave, }, ui.view.box(.{ .test_id = "pin", .visible = __yix_view_ctx.onTop, .on_click = __yix_view_ctx.onSave, }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Pin";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PinBoard(args: anytype) ui.view.ComponentOf(__yix_PinBoard) {
    return ui.view.component(__yix_PinBoard, ui.reactive.props.coerce(PinBoardProps, args));
}
pub const PinBoardProps = struct {
    pinned: ui.Source(bool) = .{ .value = false },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PinBoard;
    pub const __yix_preview_mount = __yix_PinBoard;
};
fn __yix_PinBoard(__yix_props: PinBoardProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const pinned = __yix_props.pinned;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .pinned = pinned, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PinBoard", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .pinned = __yix_view_ctx.pinned, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PinBoard", .receiver = "Pin", .tokens = "< Pin onTop = { true } / > ", .literal_text = null, .attributes = &.{ .{ .name = "on_top", .tokens = "true ", .kind = .event, .literal = .{ .boolean = true } }, } }, .{ }, __yix_builder_18102: { try ui.view.previewCheckBuilder(__yix_view_scope, Pin); break :__yix_builder_18102 Pin(.{ .on_top = ui.view.valueProp(Pin, "on_top", true), }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PinBoard", .receiver = "Pin", .tokens = "< Pin onTop = { pinned } onSave = { save } / > ", .literal_text = null, .attributes = &.{ .{ .name = "on_top", .tokens = "pinned ", .kind = .event, .literal = null }, .{ .name = "on_save", .tokens = "save ", .kind = .event, .literal = null }, } }, .{ .pinned = __yix_view_ctx.pinned, }, __yix_builder_18135: { try ui.view.previewCheckBuilder(__yix_view_scope, Pin); break :__yix_builder_18135 Pin(.{ .on_top = if (comptime ui.view.isEventProp(Pin, "on_top")) try ui.on.bindAny(__yix_view_scope, .{ .pinned = __yix_view_ctx.pinned, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.pinned.peek()();  } }.__yix_run) else __yix_view_ctx.pinned, .on_save = if (comptime ui.view.isEventProp(Pin, "on_save")) try ui.on.bindAny(__yix_view_scope, .{ .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); save();  } }.__yix_run) else save, }); }),
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "PinBoard", .receiver = "Pin", .tokens = "< Pin onTop = { ! pinned } onSave = { save ( ) } / > ", .literal_text = null, .attributes = &.{ .{ .name = "on_top", .tokens = "! pinned ", .kind = .event, .literal = null }, .{ .name = "on_save", .tokens = "save ( ) ", .kind = .event, .literal = null }, } }, .{ .pinned = __yix_view_ctx.pinned, }, __yix_builder_18184: { try ui.view.previewCheckBuilder(__yix_view_scope, Pin); break :__yix_builder_18184 Pin(.{ .on_top = if (comptime ui.view.isEventProp(Pin, "on_top")) try ui.on.bindAny(__yix_view_scope, .{ .pinned = __yix_view_ctx.pinned, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); !__yix_ctx.pinned.peek();  } }.__yix_run) else __yix_d1: {
        const __yix_T = if (ui.view.attrType(Pin, "on_top")) |__yix_A| __yix_A else @TypeOf(!__yix_view_ctx.pinned.peek());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .pinned = __yix_view_ctx.pinned, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.pinned.get();
        } }.__yix_compute);
    }, .on_save = if (comptime ui.view.isEventProp(Pin, "on_save")) try ui.on.bindAny(__yix_view_scope, .{ .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); save();  } }.__yix_run) else __yix_call3: {
        const __yix_Raw = @TypeOf(save());
        break :__yix_call3 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) save() else __yix_d2: {
        const __yix_T = if (ui.view.attrType(Pin, "on_save")) |__yix_A| __yix_A else @TypeOf(save());
        break :__yix_d2 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return save();
        } }.__yix_compute);
    };
    }, }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PinBoard";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Text child elements into component declaration's Text parameter (regardless of param name);
/// components without Text param collect as children.
fn Caption(args: anytype) ui.view.ComponentOf(__yix_Caption) {
    return ui.view.component(__yix_Caption, ui.reactive.props.coerce(CaptionProps, args));
}
const CaptionProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "title";
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Caption;
    pub const __yix_preview_mount = __yix_Caption;
};
fn __yix_Caption(__yix_props: CaptionProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .title = title, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Caption", .receiver = "text", .tokens = "text testId = @static; title  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "test_id", .tokens = "\"caption\" ", .kind = .property, .literal = .{ .text = "caption" } }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .title = __yix_view_ctx.title, }, ui.view.text(.{ .test_id = "caption", }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.title), ""), .{ __yix_view_ctx.title, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Caption";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn Captions(args: anytype) ui.view.ComponentOf(__yix_Captions) {
    return ui.view.component(__yix_Captions, ui.reactive.props.coerce(CaptionsProps, args));
}
pub const CaptionsProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Captions;
    pub const __yix_preview_mount = __yix_Captions;
};
fn __yix_Captions(__yix_props: CaptionsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Captions", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Captions", .receiver = "Caption", .tokens = "< Caption > Hello < / Caption > ", .literal_text = null, .attributes = &.{ } }, .{ }, __yix_builder_18528: { try ui.view.previewCheckBuilder(__yix_view_scope, Caption); break :__yix_builder_18528 ui.view.textChild(Caption, .{ }, "Hello", .{
                ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Captions", .receiver = "text", .tokens = "text", .literal_text = "Hello" }, .{ }, ui.view.text(.{}, ui.view.fmt("Hello", .{ }))),
            }); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Captions";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Nested for: inner row references outer row fields.
pub const Group = struct { id: u64, name: []const u8, members: []const Item };
pub fn Groups(args: anytype) ui.view.ComponentOf(__yix_Groups) {
    return ui.view.component(__yix_Groups, ui.reactive.props.coerce(GroupsProps, args));
}
pub const GroupsProps = struct {
    groups: ui.Source([]const Group) = .{ .value = &.{} },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Groups;
    pub const __yix_preview_mount = __yix_Groups;
};
fn __yix_Groups(__yix_props: GroupsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const groups = __yix_props.groups;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .groups = groups, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .groups = __yix_view_ctx.groups, }, ui.view.col(.{ }, .{
            ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups", .receiver = "control", .tokens = "for ( groups ) | g | < col > < text > { g . name } < / text > { for ( g . members ) | m | < text > { g . name } / { m . title } < / text > } < / col > " }, .{ .groups = __yix_view_ctx.groups, }, __yix_e1: { const __yix_items_1 = __yix_view_ctx.groups; break :__yix_e1 ui.view.eachWith(.{ }, __yix_items_1, .id, struct { fn __yix_row(__yix_row_1: anytype, g: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { _ = __yix_row_1; return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups/keyword_for:1", .receiver = "col", .tokens = "col ", .literal_text = null, .attributes = &.{ } }, .{ .g = g, }, ui.view.col(.{ }, .{
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups/keyword_for:1", .receiver = "text", .tokens = "text g . name  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .g = g, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(g.peek().name);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(g.peek().name);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }, }))),
                    ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups/keyword_for:1", .receiver = "control", .tokens = "for ( g . members ) | m | < text > { g . name } / { m . title } < / text > " }, .{ .g = g, }, __yix_e2: { const __yix_items_2 = __yix_d3: {
        const __yix_T = @TypeOf(g.peek().members);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .g = g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().members;
        } }.__yix_compute);
    }; break :__yix_e2 ui.view.eachWith(.{ .g = g, }, __yix_items_2, .id, struct { fn __yix_row(__yix_row_2: anytype, m: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_2))), __yix_scope_2: *ui.Scope, __yix_cx_2: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_2, __yix_cx_2, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "Groups/keyword_for:1/keyword_for:2", .receiver = "text", .tokens = "text g . name  @interpolation m . title  @interpolation ", .literal_text = null, .attributes = &.{ } }, .{ .g = __yix_row_2.g, .m = m, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_row_2.g.peek().name);
        break :__yix_d1 try __yix_scope_2.derive(__yix_T, .{ .g = __yix_row_2.g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }), "") ++ "/" ++ ui.view.yixFormat(@TypeOf(__yix_d2: {
        const __yix_T = @TypeOf(m.peek().title);
        break :__yix_d2 try __yix_scope_2.derive(__yix_T, .{ .m = m, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.m.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_row_2.g.peek().name);
        break :__yix_d1 try __yix_scope_2.derive(__yix_T, .{ .g = __yix_row_2.g, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.g.get().name;
        } }.__yix_compute);
    }, __yix_d2: {
        const __yix_T = @TypeOf(m.peek().title);
        break :__yix_d2 try __yix_scope_2.derive(__yix_T, .{ .m = m, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.m.get().title;
        } }.__yix_compute);
    }, })))); } }.__yix_row); }),
                }))); } }.__yix_row); }),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Groups";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
/// Reactive name in type position.
pub fn TypeOfProbe(args: anytype) ui.view.ComponentOf(__yix_TypeOfProbe) {
    return ui.view.component(__yix_TypeOfProbe, ui.reactive.props.coerce(TypeOfProbeProps, args));
}
pub const TypeOfProbeProps = struct {
    n: ui.Source(u32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = TypeOfProbe;
    pub const __yix_preview_mount = __yix_TypeOfProbe;
};
fn __yix_TypeOfProbe(__yix_props: TypeOfProbeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, false);
    const doubled = __yix_d1: {
        const __yix_T = @TypeOf(@as(@TypeOf(n.peek()), n.peek() * 2));
        break :__yix_d1 try scope.derive(__yix_T, .{ .n = n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return @as(@TypeOf(__yix_ctx.n.get()), __yix_ctx.n.get() * 2);
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .doubled = doubled, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/stories.yix", .path = "TypeOfProbe", .receiver = "text", .tokens = "text doubled  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .doubled = __yix_view_ctx.doubled, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.doubled), ""), .{ __yix_view_ctx.doubled, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "TypeOfProbe";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x73\x74\x64\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x64\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x42\x75\x74\x74\x6f\x6e\x20\x3d\x20\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x2e\x42\x75\x74\x74\x6f\x6e\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x57\x20\x3d\x20\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x74\x61\x74\x65\x73\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x61\x74\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x54\x61\x62\x20\x3d\x20\x65\x6e\x75\x6d\x20\x7b\x20\x68\x6f\x6d\x65\x2c\x20\x73\x65\x74\x74\x69\x6e\x67\x73\x20\x7d\x3b\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x69\x64\x3a\x20\x75\x33\x32\x2c\x20\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x7d\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x69\x74\x65\x6d\x73\x20\x3d\x20\x5b\x5f\x5d\x49\x74\x65\x6d\x7b\x20\x2e\x7b\x20\x2e\x69\x64\x20\x3d\x20\x31\x2c\x20\x2e\x74\x69\x74\x6c\x65\x20\x3d\x20\x22\x66\x69\x72\x73\x74\x22\x20\x7d\x2c\x20\x2e\x7b\x20\x2e\x69\x64\x20\x3d\x20\x32\x2c\x20\x2e\x74\x69\x74\x6c\x65\x20\x3d\x20\x22\x73\x65\x63\x6f\x6e\x64\x22\x20\x7d\x20\x7d\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x62\x61\x74\x63\x68\x5f\x75\x70\x64\x61\x74\x65\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x62\x61\x74\x63\x68\x5f\x76\x61\x6c\x75\x65\x73\x3a\x20\x5b\x38\x5d\x69\x33\x32\x20\x3d\x20\x40\x73\x70\x6c\x61\x74\x28\x2d\x31\x29\x3b\x0a\x66\x6e\x20\x6f\x62\x73\x65\x72\x76\x65\x42\x61\x74\x63\x68\x28\x76\x61\x6c\x75\x65\x3a\x20\x69\x33\x32\x29\x20\x69\x33\x32\x20\x7b\x0a\x20\x20\x20\x20\x62\x61\x74\x63\x68\x5f\x76\x61\x6c\x75\x65\x73\x5b\x62\x61\x74\x63\x68\x5f\x75\x70\x64\x61\x74\x65\x73\x5d\x20\x3d\x20\x76\x61\x6c\x75\x65\x3b\x0a\x20\x20\x20\x20\x62\x61\x74\x63\x68\x5f\x75\x70\x64\x61\x74\x65\x73\x20\x2b\x3d\x20\x31\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x76\x61\x6c\x75\x65\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x4d\x30\x20\x73\x61\x6d\x70\x6c\x65\x73\x20\x63\x6f\x72\x72\x65\x73\x70\x6f\x6e\x64\x69\x6e\x67\x20\x74\x6f\x20\x73\x74\x6f\x72\x79\x62\x6f\x6f\x6b\x3a\x20\x6c\x61\x79\x6f\x75\x74\x2c\x20\x62\x75\x74\x74\x6f\x6e\x2c\x20\x63\x61\x72\x64\x2c\x20\x63\x6f\x6e\x74\x72\x6f\x6c\x6c\x65\x64\x0a\x2f\x2f\x20\x76\x69\x73\x69\x62\x69\x6c\x69\x74\x79\x2c\x20\x74\x61\x62\x73\x2c\x20\x6b\x65\x79\x65\x64\x20\x72\x6f\x77\x73\x2c\x20\x61\x6e\x64\x20\x61\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x72\x65\x63\x65\x69\x76\x69\x6e\x67\x20\x72\x65\x61\x63\x74\x69\x76\x65\x20\x70\x72\x6f\x70\x73\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x61\x79\x6f\x75\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x72\x6f\x77\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x2e\x73\x70\x61\x63\x65\x32\x30\x30\x20\x7d\x7d\x3e\x3c\x57\x2e\x53\x63\x72\x6f\x6c\x6c\x41\x72\x65\x61\x20\x70\x61\x72\x74\x73\x3d\x7b\x2e\x7b\x20\x2e\x63\x6f\x6e\x74\x65\x6e\x74\x20\x3d\x20\x2e\x7b\x20\x2e\x73\x74\x79\x6c\x65\x20\x3d\x20\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x32\x31\x20\x7d\x29\x20\x7d\x20\x7d\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x42\x65\x66\x6f\x72\x65\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x57\x2e\x53\x63\x72\x6f\x6c\x6c\x41\x72\x65\x61\x3e\x3c\x73\x70\x61\x63\x65\x72\x20\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x41\x66\x74\x65\x72\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x72\x6f\x77\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x75\x74\x74\x6f\x6e\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x6f\x75\x62\x6c\x65\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x63\x6f\x75\x6e\x74\x20\x2a\x20\x32\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x43\x6f\x75\x6e\x74\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3b\x20\x64\x6f\x75\x62\x6c\x65\x20\x7b\x64\x6f\x75\x62\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x49\x6e\x63\x72\x65\x6d\x65\x6e\x74\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x61\x72\x64\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x2e\x43\x61\x72\x64\x20\x73\x74\x79\x6c\x65\x3d\x7b\x75\x69\x2e\x63\x73\x73\x28\x2e\x7b\x20\x2e\x6f\x70\x61\x63\x69\x74\x79\x20\x3d\x20\x30\x2e\x35\x20\x7d\x29\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x43\x61\x72\x64\x20\x62\x6f\x64\x79\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x75\x69\x2e\x77\x69\x64\x67\x65\x74\x73\x2e\x43\x61\x72\x64\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x72\x61\x6e\x63\x68\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x65\x78\x70\x61\x6e\x64\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x65\x78\x70\x61\x6e\x64\x65\x64\x20\x3d\x20\x21\x65\x78\x70\x61\x6e\x64\x65\x64\x7d\x3e\x54\x6f\x67\x67\x6c\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x7b\x69\x66\x20\x28\x65\x78\x70\x61\x6e\x64\x65\x64\x29\x20\x3c\x74\x65\x78\x74\x3e\x45\x78\x70\x61\x6e\x64\x65\x64\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x43\x6f\x6c\x6c\x61\x70\x73\x65\x64\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x61\x62\x73\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x74\x61\x62\x3a\x20\x54\x61\x62\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x2e\x68\x6f\x6d\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x74\x61\x62\x20\x3d\x20\x2e\x73\x65\x74\x74\x69\x6e\x67\x73\x7d\x3e\x53\x65\x74\x74\x69\x6e\x67\x73\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x7b\x73\x77\x69\x74\x63\x68\x20\x28\x74\x61\x62\x29\x20\x7b\x20\x2e\x68\x6f\x6d\x65\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x48\x6f\x6d\x65\x3c\x2f\x74\x65\x78\x74\x3e\x2c\x20\x2e\x73\x65\x74\x74\x69\x6e\x67\x73\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x53\x65\x74\x74\x69\x6e\x67\x73\x20\x62\x6f\x64\x79\x3c\x2f\x74\x65\x78\x74\x3e\x20\x7d\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x69\x73\x74\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x45\x6d\x70\x74\x79\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x72\x6f\x77\x73\x20\x3d\x20\x26\x2e\x7b\x7d\x7d\x3e\x43\x6c\x65\x61\x72\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x4c\x6f\x63\x61\x6c\x20\x76\x61\x72\x69\x61\x62\x6c\x65\x20\x73\x68\x61\x72\x65\x73\x20\x6e\x61\x6d\x65\x20\x77\x69\x74\x68\x20\x67\x65\x6e\x65\x72\x61\x74\x65\x64\x20\x66\x75\x6e\x63\x74\x69\x6f\x6e\x20\x28\x62\x20\x2f\x20\x72\x6f\x77\x20\x2f\x20\x6b\x20\x2f\x20\x72\x75\x6e\x20\x2f\x20\x63\x6f\x6d\x70\x75\x74\x65\x29\x3a\x20\x62\x72\x61\x6e\x63\x68\x2f\x72\x6f\x77\x0a\x2f\x2f\x2f\x20\x72\x65\x66\x65\x72\x65\x6e\x63\x65\x73\x20\x63\x61\x6e\x6e\x6f\x74\x20\x63\x6f\x72\x72\x75\x70\x74\x20\x67\x65\x6e\x65\x72\x61\x74\x65\x64\x20\x66\x75\x6e\x63\x74\x69\x6f\x6e\x20\x6e\x61\x6d\x65\x73\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x65\x6e\x65\x72\x61\x74\x65\x64\x4e\x61\x6d\x65\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x62\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x31\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x32\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x62\x20\x3e\x20\x30\x29\x20\x3c\x74\x65\x78\x74\x3e\x62\x3d\x7b\x62\x7d\x20\x72\x6f\x77\x3d\x7b\x72\x6f\x77\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x7b\x62\x7d\x7b\x72\x6f\x77\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x62\x20\x2b\x3d\x20\x31\x7d\x3e\x62\x75\x6d\x70\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x43\x6f\x6e\x74\x72\x6f\x6c\x6c\x65\x64\x20\x28\x72\x65\x61\x64\x2d\x6f\x6e\x6c\x79\x29\x3a\x20\x6c\x69\x73\x74\x20\x72\x6f\x77\x20\x66\x69\x65\x6c\x64\x73\x20\x64\x72\x69\x76\x65\x20\x43\x68\x65\x63\x6b\x62\x6f\x78\x3b\x20\x63\x6c\x69\x63\x6b\x20\x6f\x6e\x6c\x79\x20\x66\x69\x72\x65\x73\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x2c\x20\x70\x61\x72\x65\x6e\x74\x0a\x2f\x2f\x2f\x20\x75\x70\x64\x61\x74\x65\x73\x20\x64\x61\x74\x61\x2e\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x54\x61\x73\x6b\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x69\x64\x3a\x20\x75\x33\x32\x2c\x20\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x64\x6f\x6e\x65\x3a\x20\x62\x6f\x6f\x6c\x20\x7d\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x74\x61\x73\x6b\x73\x30\x20\x3d\x20\x5b\x5f\x5d\x54\x61\x73\x6b\x7b\x20\x2e\x7b\x20\x2e\x69\x64\x20\x3d\x20\x31\x2c\x20\x2e\x74\x69\x74\x6c\x65\x20\x3d\x20\x22\x61\x22\x2c\x20\x2e\x64\x6f\x6e\x65\x20\x3d\x20\x66\x61\x6c\x73\x65\x20\x7d\x2c\x20\x2e\x7b\x20\x2e\x69\x64\x20\x3d\x20\x32\x2c\x20\x2e\x74\x69\x74\x6c\x65\x20\x3d\x20\x22\x62\x22\x2c\x20\x2e\x64\x6f\x6e\x65\x20\x3d\x20\x74\x72\x75\x65\x20\x7d\x20\x7d\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x74\x61\x73\x6b\x5f\x73\x74\x6f\x72\x65\x3a\x20\x5b\x32\x5d\x54\x61\x73\x6b\x20\x3d\x20\x74\x61\x73\x6b\x73\x30\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x74\x6f\x67\x67\x6c\x65\x73\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x66\x6e\x20\x74\x6f\x67\x67\x6c\x65\x54\x61\x73\x6b\x28\x69\x64\x3a\x20\x75\x33\x32\x29\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x54\x61\x73\x6b\x20\x7b\x0a\x20\x20\x20\x20\x74\x6f\x67\x67\x6c\x65\x73\x20\x2b\x3d\x20\x31\x3b\x0a\x20\x20\x20\x20\x66\x6f\x72\x20\x28\x26\x74\x61\x73\x6b\x5f\x73\x74\x6f\x72\x65\x29\x20\x7c\x2a\x74\x7c\x20\x69\x66\x20\x28\x74\x2e\x69\x64\x20\x3d\x3d\x20\x69\x64\x29\x20\x7b\x20\x74\x2e\x64\x6f\x6e\x65\x20\x3d\x20\x21\x74\x2e\x64\x6f\x6e\x65\x3b\x20\x7d\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x26\x74\x61\x73\x6b\x5f\x73\x74\x6f\x72\x65\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x6f\x6e\x74\x72\x6f\x6c\x6c\x65\x64\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6c\x69\x73\x74\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x54\x61\x73\x6b\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x74\x61\x73\x6b\x5f\x73\x74\x6f\x72\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x66\x72\x6f\x7a\x65\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x66\x6f\x72\x20\x28\x6c\x69\x73\x74\x29\x20\x7c\x74\x61\x73\x6b\x7c\x20\x3c\x57\x2e\x43\x68\x65\x63\x6b\x62\x6f\x78\x20\x6b\x65\x79\x3d\x7b\x74\x61\x73\x6b\x2e\x69\x64\x7d\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x74\x61\x73\x6b\x2e\x74\x69\x74\x6c\x65\x7d\x20\x63\x68\x65\x63\x6b\x65\x64\x3d\x7b\x74\x61\x73\x6b\x2e\x64\x6f\x6e\x65\x7d\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3d\x7b\x7b\x20\x69\x66\x20\x28\x21\x66\x72\x6f\x7a\x65\x6e\x29\x20\x6c\x69\x73\x74\x20\x3d\x20\x74\x6f\x67\x67\x6c\x65\x54\x61\x73\x6b\x28\x74\x61\x73\x6b\x2e\x69\x64\x29\x3b\x20\x7d\x7d\x20\x2f\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x66\x72\x6f\x7a\x65\x6e\x20\x3d\x20\x21\x66\x72\x6f\x7a\x65\x6e\x7d\x3e\x66\x72\x65\x65\x7a\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x54\x79\x70\x65\x64\x20\x65\x76\x65\x6e\x74\x73\x20\x6f\x6e\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x65\x6c\x65\x6d\x65\x6e\x74\x3a\x20\x69\x6e\x73\x74\x61\x6c\x6c\x65\x64\x20\x69\x6e\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x72\x6f\x6f\x74\x27\x73\x20\x63\x61\x70\x74\x75\x72\x65\x20\x73\x6c\x6f\x74\x2c\x20\x66\x69\x72\x65\x20\x62\x65\x66\x6f\x72\x65\x0a\x2f\x2f\x2f\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x27\x73\x20\x6f\x77\x6e\x20\x68\x61\x6e\x64\x6c\x65\x72\x73\x3b\x20\x63\x6f\x6e\x73\x75\x6d\x65\x20\x62\x6c\x6f\x63\x6b\x73\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x64\x65\x66\x61\x75\x6c\x74\x20\x62\x65\x68\x61\x76\x69\x6f\x72\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x4b\x65\x79\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x74\x65\x78\x74\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x22\x61\x62\x22\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6b\x65\x79\x73\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x57\x2e\x49\x6e\x70\x75\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x66\x69\x65\x6c\x64\x22\x20\x76\x61\x6c\x75\x65\x3d\x7b\x74\x65\x78\x74\x7d\x20\x6f\x6e\x4b\x65\x79\x44\x6f\x77\x6e\x3d\x7b\x7c\x65\x7c\x20\x69\x66\x20\x28\x65\x2e\x6b\x65\x79\x20\x3d\x3d\x20\x2e\x64\x65\x6c\x65\x74\x65\x20\x61\x6e\x64\x20\x6b\x65\x79\x73\x20\x3d\x3d\x20\x30\x29\x20\x7b\x20\x6b\x65\x79\x73\x20\x2b\x3d\x20\x31\x3b\x20\x65\x2e\x63\x6f\x6e\x73\x75\x6d\x65\x28\x29\x3b\x20\x7d\x20\x65\x6c\x73\x65\x20\x6b\x65\x79\x73\x20\x2b\x3d\x20\x31\x30\x7d\x20\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x6b\x65\x79\x73\x20\x7b\x6b\x65\x79\x73\x7d\x20\x74\x65\x78\x74\x20\x7b\x74\x65\x78\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x72\x6f\x6f\x74\x27\x73\x20\x74\x79\x70\x65\x64\x20\x65\x76\x65\x6e\x74\x73\x20\x74\x6f\x67\x67\x6c\x65\x20\x6d\x6f\x75\x6e\x74\x2f\x75\x6e\x6d\x6f\x75\x6e\x74\x20\x61\x63\x72\x6f\x73\x73\x20\x62\x72\x61\x6e\x63\x68\x65\x73\x20\x28\x74\x61\x62\x6c\x65\x20\x66\x72\x65\x65\x64\x20\x77\x69\x74\x68\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x0a\x2f\x2f\x2f\x20\x73\x63\x6f\x70\x65\x2c\x20\x6e\x6f\x20\x64\x61\x6e\x67\x6c\x69\x6e\x67\x20\x70\x6f\x69\x6e\x74\x65\x72\x73\x29\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x6f\x67\x67\x6c\x65\x64\x4b\x65\x79\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6b\x65\x79\x73\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x29\x20\x3c\x57\x2e\x49\x6e\x70\x75\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x74\x66\x69\x65\x6c\x64\x22\x20\x6f\x6e\x4b\x65\x79\x44\x6f\x77\x6e\x3d\x7b\x6b\x65\x79\x73\x20\x2b\x3d\x20\x31\x7d\x20\x2f\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x6f\x77\x20\x3d\x20\x21\x73\x68\x6f\x77\x7d\x3e\x74\x6f\x67\x67\x6c\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x74\x65\x78\x74\x3e\x74\x6b\x20\x7b\x6b\x65\x79\x73\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x43\x6f\x6e\x74\x72\x6f\x6c\x6c\x65\x64\x20\x72\x65\x77\x72\x69\x74\x65\x3a\x20\x72\x65\x61\x64\x2d\x6f\x6e\x6c\x79\x20\x76\x61\x6c\x75\x65\x20\x2b\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x20\x6e\x6f\x72\x6d\x61\x6c\x69\x7a\x65\x64\x20\x62\x79\x20\x70\x72\x6f\x70\x73\x20\x69\x6e\x74\x6f\x20\x73\x70\x6c\x69\x74\x3b\x20\x49\x6e\x70\x75\x74\x20\x63\x6f\x72\x72\x65\x63\x74\x73\x0a\x2f\x2f\x2f\x20\x62\x75\x66\x66\x65\x72\x20\x69\x6e\x2d\x70\x6c\x61\x63\x65\x20\x70\x65\x72\x20\x72\x65\x77\x72\x69\x74\x74\x65\x6e\x20\x76\x61\x6c\x75\x65\x2e\x0a\x76\x61\x72\x20\x75\x70\x70\x65\x72\x5f\x62\x75\x66\x3a\x20\x5b\x36\x34\x5d\x75\x38\x20\x3d\x20\x75\x6e\x64\x65\x66\x69\x6e\x65\x64\x3b\x0a\x66\x6e\x20\x75\x70\x70\x65\x72\x28\x76\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x6e\x20\x3d\x20\x40\x6d\x69\x6e\x28\x76\x2e\x6c\x65\x6e\x2c\x20\x75\x70\x70\x65\x72\x5f\x62\x75\x66\x2e\x6c\x65\x6e\x29\x3b\x0a\x20\x20\x20\x20\x66\x6f\x72\x20\x28\x76\x5b\x30\x2e\x2e\x6e\x5d\x2c\x20\x30\x2e\x2e\x29\x20\x7c\x63\x2c\x20\x69\x7c\x20\x75\x70\x70\x65\x72\x5f\x62\x75\x66\x5b\x69\x5d\x20\x3d\x20\x73\x74\x64\x2e\x61\x73\x63\x69\x69\x2e\x74\x6f\x55\x70\x70\x65\x72\x28\x63\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x75\x70\x70\x65\x72\x5f\x62\x75\x66\x5b\x30\x2e\x2e\x6e\x5d\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x55\x70\x70\x65\x72\x49\x6e\x70\x75\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x64\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x22\x41\x42\x22\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x73\x68\x6f\x77\x6e\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x63\x6f\x64\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x57\x2e\x49\x6e\x70\x75\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x75\x70\x22\x20\x76\x61\x6c\x75\x65\x3d\x7b\x73\x68\x6f\x77\x6e\x7d\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3d\x7b\x7c\x76\x7c\x20\x63\x6f\x64\x65\x20\x3d\x20\x75\x70\x70\x65\x72\x28\x76\x29\x7d\x20\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x63\x6f\x64\x65\x20\x7b\x63\x6f\x64\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x70\x72\x6f\x70\x65\x72\x74\x79\x20\x62\x72\x61\x6e\x63\x68\x20\x65\x78\x70\x72\x65\x73\x73\x69\x6f\x6e\x73\x20\x74\x79\x70\x65\x64\x20\x62\x79\x20\x70\x72\x6f\x70\x65\x72\x74\x79\x20\x74\x79\x70\x65\x3a\x20\x65\x6e\x75\x6d\x20\x6c\x69\x74\x65\x72\x61\x6c\x73\x2c\x20\x75\x6e\x65\x71\x75\x61\x6c\x2d\x6c\x65\x6e\x67\x74\x68\x0a\x2f\x2f\x2f\x20\x73\x74\x72\x69\x6e\x67\x20\x6c\x69\x74\x65\x72\x61\x6c\x73\x2c\x20\x60\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x60\x20\x69\x6e\x20\x74\x79\x70\x65\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x79\x70\x65\x64\x41\x74\x74\x72\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6f\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x76\x61\x72\x69\x61\x6e\x74\x3d\x7b\x69\x66\x20\x28\x6f\x6e\x29\x20\x2e\x70\x72\x69\x6d\x61\x72\x79\x20\x65\x6c\x73\x65\x20\x2e\x67\x68\x6f\x73\x74\x7d\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x69\x66\x20\x28\x6f\x6e\x29\x20\x22\x64\x6f\x6e\x65\x22\x20\x65\x6c\x73\x65\x20\x22\x74\x6f\x64\x6f\x22\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x20\x3d\x20\x21\x6f\x6e\x7d\x20\x2f\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x69\x66\x20\x28\x6f\x6e\x29\x20\x40\x61\x73\x28\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x22\x79\x65\x73\x22\x29\x20\x65\x6c\x73\x65\x20\x22\x6e\x6f\x22\x7d\x20\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x61\x62\x65\x6c\x28\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x50\x72\x6f\x70\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x72\x6f\x70\x73\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x33\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x4c\x61\x62\x65\x6c\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x20\x2f\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x49\x6e\x63\x72\x65\x6d\x65\x6e\x74\x20\x70\x72\x6f\x70\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x42\x61\x74\x63\x68\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x61\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x62\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x74\x6f\x74\x61\x6c\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x6f\x62\x73\x65\x72\x76\x65\x42\x61\x74\x63\x68\x28\x61\x20\x2b\x20\x62\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x74\x6f\x74\x61\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x7b\x20\x61\x20\x2b\x3d\x20\x31\x3b\x20\x62\x20\x2b\x3d\x20\x32\x3b\x20\x7d\x7d\x3e\x42\x61\x74\x63\x68\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x55\x6e\x69\x63\x6f\x64\x65\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x29\x20\x3c\x74\x65\x78\x74\x3e\xe4\xb8\xad\xe6\x96\x87\x20\xf0\x9f\x98\x80\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\xe7\xa9\xba\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x6f\x77\x20\x3d\x20\x66\x61\x6c\x73\x65\x7d\x3e\xe9\x9a\x90\xe8\x97\x8f\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x6f\x77\x43\x61\x70\x74\x75\x72\x65\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x3a\x20\x75\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x53\x65\x6c\x65\x63\x74\x65\x64\x20\x7b\x73\x65\x6c\x65\x63\x74\x65\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x72\x6f\x77\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3a\x20\x7b\x73\x65\x6c\x65\x63\x74\x65\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x69\x74\x65\x6d\x2e\x69\x64\x7d\x20\x2f\x3e\x3c\x2f\x72\x6f\x77\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x72\x6f\x77\x73\x20\x3d\x20\x26\x2e\x7b\x20\x69\x74\x65\x6d\x73\x5b\x31\x5d\x2c\x20\x69\x74\x65\x6d\x73\x5b\x30\x5d\x20\x7d\x7d\x3e\x52\x65\x76\x65\x72\x73\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x65\x78\x74\x53\x69\x67\x6e\x61\x6c\x53\x74\x6f\x72\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6d\x65\x73\x73\x61\x67\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x22\x62\x65\x66\x6f\x72\x65\x22\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x6d\x65\x73\x73\x61\x67\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6d\x65\x73\x73\x61\x67\x65\x20\x3d\x20\x22\x61\x66\x74\x65\x72\x22\x7d\x3e\x43\x68\x61\x6e\x67\x65\x20\x74\x65\x78\x74\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x44\x6f\x75\x62\x6c\x65\x64\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x6e\x20\x2a\x20\x32\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x64\x6f\x75\x62\x6c\x65\x20\x7b\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x61\x6e\x65\x6c\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x22\x2c\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x7b\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x61\x6e\x65\x6c\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x31\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x50\x61\x6e\x65\x6c\x20\x74\x69\x74\x6c\x65\x3d\x22\x53\x65\x74\x74\x69\x6e\x67\x73\x22\x3e\x3c\x74\x65\x78\x74\x3e\x76\x61\x6c\x75\x65\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x3e\x4d\x6f\x72\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x50\x61\x6e\x65\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x6c\x6f\x73\x61\x62\x6c\x65\x28\x6c\x61\x62\x65\x6c\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x22\x2c\x20\x6f\x6e\x43\x6c\x6f\x73\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x72\x6f\x77\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x6c\x61\x62\x65\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x22\x78\x22\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x43\x6c\x6f\x73\x65\x7d\x20\x2f\x3e\x3c\x2f\x72\x6f\x77\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x6c\x6f\x73\x61\x62\x6c\x65\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6c\x6f\x73\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x43\x6c\x6f\x73\x61\x62\x6c\x65\x20\x6c\x61\x62\x65\x6c\x3d\x22\x74\x61\x62\x22\x20\x6f\x6e\x43\x6c\x6f\x73\x65\x3d\x7b\x63\x6c\x6f\x73\x65\x64\x20\x3d\x20\x74\x72\x75\x65\x7d\x20\x2f\x3e\x7b\x69\x66\x20\x28\x63\x6c\x6f\x73\x65\x64\x29\x20\x3c\x74\x65\x78\x74\x3e\x63\x6c\x6f\x73\x65\x64\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x6f\x70\x65\x6e\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x74\x61\x72\x73\x28\x74\x6f\x74\x61\x6c\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x35\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6c\x69\x74\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x32\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x72\x6f\x77\x3e\x7b\x66\x6f\x72\x20\x28\x30\x2e\x2e\x35\x29\x20\x7c\x69\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x7d\x2f\x7b\x6c\x69\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x7b\x66\x6f\x72\x20\x28\x30\x2e\x2e\x33\x29\x20\x7c\x5f\x7c\x20\x3c\x73\x70\x61\x63\x65\x72\x20\x2f\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6c\x69\x74\x20\x2b\x3d\x20\x31\x7d\x3e\x4d\x6f\x72\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x72\x6f\x77\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x72\x6f\x77\x69\x6e\x67\x53\x74\x61\x72\x73\x28\x74\x6f\x74\x61\x6c\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x32\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x65\x78\x74\x72\x61\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x72\x6f\x77\x3e\x7b\x66\x6f\x72\x20\x28\x30\x2e\x2e\x74\x6f\x74\x61\x6c\x20\x2b\x20\x65\x78\x74\x72\x61\x29\x20\x7c\x69\x7c\x20\x3c\x74\x65\x78\x74\x3e\x73\x74\x61\x72\x20\x7b\x69\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x65\x78\x74\x72\x61\x20\x2b\x3d\x20\x31\x7d\x3e\x41\x64\x64\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x72\x6f\x77\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x6f\x72\x77\x61\x72\x64\x28\x64\x69\x73\x61\x62\x6c\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x20\x6f\x6e\x50\x72\x65\x73\x73\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x20\x6f\x6e\x50\x69\x63\x6b\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x69\x33\x32\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x66\x20\x28\x21\x64\x69\x73\x61\x62\x6c\x65\x64\x29\x20\x6f\x6e\x50\x72\x65\x73\x73\x7d\x3e\x47\x6f\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x50\x69\x63\x6b\x28\x37\x29\x7d\x3e\x53\x65\x76\x65\x6e\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x6f\x72\x77\x61\x72\x64\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6f\x66\x66\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x46\x6f\x72\x77\x61\x72\x64\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x3d\x7b\x6f\x66\x66\x7d\x20\x6f\x6e\x50\x72\x65\x73\x73\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x20\x6f\x6e\x50\x69\x63\x6b\x3d\x7b\x7c\x76\x7c\x20\x6e\x20\x3d\x20\x76\x7d\x20\x2f\x3e\x3c\x74\x65\x78\x74\x3e\x70\x72\x65\x73\x73\x65\x73\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x66\x66\x20\x3d\x20\x21\x6f\x66\x66\x7d\x3e\x4c\x6f\x63\x6b\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x4e\x75\x6d\x62\x65\x72\x65\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x2c\x20\x69\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x7d\x2e\x20\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x72\x6f\x77\x73\x20\x3d\x20\x26\x2e\x7b\x20\x69\x74\x65\x6d\x73\x5b\x31\x5d\x2c\x20\x69\x74\x65\x6d\x73\x5b\x30\x5d\x20\x7d\x7d\x3e\x52\x65\x76\x65\x72\x73\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x4e\x65\x73\x74\x65\x64\x46\x6c\x6f\x77\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x74\x65\x78\x74\x3e\x72\x6f\x77\x20\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x6f\x77\x6e\x20\x3d\x20\x21\x73\x68\x6f\x77\x6e\x7d\x3e\x48\x69\x64\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x6f\x67\x67\x6c\x65\x28\x6f\x6e\x3a\x20\x4d\x6f\x64\x65\x6c\x28\x62\x6f\x6f\x6c\x29\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x62\x6f\x6f\x6c\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x6f\x6e\x29\x20\x3c\x74\x65\x78\x74\x3e\x6f\x6e\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x6f\x66\x66\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x20\x3d\x20\x21\x6f\x6e\x7d\x3e\x46\x6c\x69\x70\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x6f\x67\x67\x6c\x65\x42\x6f\x75\x6e\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x66\x6c\x61\x67\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x74\x72\x75\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x68\x61\x6e\x67\x65\x73\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x66\x6c\x61\x67\x20\x7b\x66\x6c\x61\x67\x7d\x20\x63\x68\x61\x6e\x67\x65\x73\x20\x7b\x63\x68\x61\x6e\x67\x65\x73\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x54\x6f\x67\x67\x6c\x65\x20\x6f\x6e\x3d\x7b\x66\x6c\x61\x67\x7d\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3d\x7b\x63\x68\x61\x6e\x67\x65\x73\x20\x2b\x3d\x20\x31\x7d\x20\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x6f\x67\x67\x6c\x65\x45\x63\x68\x6f\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6c\x61\x73\x74\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x6c\x61\x73\x74\x20\x7b\x6c\x61\x73\x74\x7d\x20\x63\x6f\x75\x6e\x74\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x54\x6f\x67\x67\x6c\x65\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3d\x7b\x7c\x76\x7c\x20\x7b\x20\x6c\x61\x73\x74\x20\x3d\x20\x76\x3b\x20\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x3b\x20\x7d\x7d\x20\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x75\x61\x72\x64\x65\x64\x28\x6c\x6f\x63\x6b\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x6e\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x66\x20\x28\x21\x6c\x6f\x63\x6b\x65\x64\x29\x20\x7b\x20\x6e\x20\x2b\x3d\x20\x31\x3b\x20\x69\x66\x20\x28\x6e\x20\x3e\x20\x32\x29\x20\x6e\x20\x3d\x20\x30\x3b\x20\x7d\x20\x65\x6c\x73\x65\x20\x6e\x20\x3d\x20\x2d\x31\x7d\x3e\x53\x74\x65\x70\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x76\x65\x6e\x74\x46\x6f\x72\x6d\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x61\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x62\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x61\x20\x7b\x61\x7d\x20\x62\x20\x7b\x62\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x7b\x20\x69\x66\x20\x28\x61\x20\x3d\x3d\x20\x30\x29\x20\x61\x20\x3d\x20\x31\x20\x65\x6c\x73\x65\x20\x61\x20\x3d\x20\x32\x3b\x20\x62\x20\x3d\x20\x69\x66\x20\x28\x61\x20\x3e\x20\x31\x29\x20\x31\x30\x20\x65\x6c\x73\x65\x20\x32\x30\x3b\x20\x7d\x7d\x3e\x47\x6f\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x69\x65\x6c\x64\x4e\x61\x6d\x65\x64\x4c\x69\x6b\x65\x50\x72\x6f\x70\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x70\x72\x6f\x70\x22\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x26\x69\x74\x65\x6d\x73\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x2d\x7b\x74\x69\x74\x6c\x65\x7d\x20\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x2e\x6c\x65\x6e\x20\x2b\x20\x74\x69\x74\x6c\x65\x2e\x6c\x65\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x63\x6f\x6e\x73\x74\x20\x43\x68\x6f\x69\x63\x65\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x76\x61\x6c\x75\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x6c\x61\x62\x65\x6c\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x7d\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x63\x68\x6f\x69\x63\x65\x73\x20\x3d\x20\x5b\x5f\x5d\x43\x68\x6f\x69\x63\x65\x7b\x20\x2e\x7b\x20\x2e\x76\x61\x6c\x75\x65\x20\x3d\x20\x22\x61\x22\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x22\x41\x70\x70\x6c\x65\x22\x20\x7d\x2c\x20\x2e\x7b\x20\x2e\x76\x61\x6c\x75\x65\x20\x3d\x20\x22\x62\x22\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x22\x42\x61\x6e\x61\x6e\x61\x22\x20\x7d\x20\x7d\x3b\x0a\x66\x6e\x20\x69\x73\x50\x69\x63\x6b\x65\x64\x28\x76\x61\x6c\x75\x65\x3a\x20\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x76\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x62\x6f\x6f\x6c\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x69\x66\x20\x28\x76\x61\x6c\x75\x65\x29\x20\x7c\x78\x7c\x20\x73\x74\x64\x2e\x6d\x65\x6d\x2e\x65\x71\x6c\x28\x75\x38\x2c\x20\x78\x2c\x20\x76\x29\x20\x65\x6c\x73\x65\x20\x66\x61\x6c\x73\x65\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x69\x63\x6b\x65\x72\x28\x6f\x70\x74\x69\x6f\x6e\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x43\x68\x6f\x69\x63\x65\x20\x3d\x20\x26\x63\x68\x6f\x69\x63\x65\x73\x2c\x20\x76\x61\x6c\x75\x65\x3a\x20\x4d\x6f\x64\x65\x6c\x28\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x66\x6f\x72\x20\x28\x6f\x70\x74\x69\x6f\x6e\x73\x29\x20\x7c\x6f\x70\x74\x7c\x20\x3c\x72\x6f\x77\x20\x6b\x65\x79\x3d\x7b\x6f\x70\x74\x2e\x76\x61\x6c\x75\x65\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x7b\x6f\x70\x74\x2e\x6c\x61\x62\x65\x6c\x7d\x20\x7b\x69\x73\x50\x69\x63\x6b\x65\x64\x28\x76\x61\x6c\x75\x65\x2c\x20\x6f\x70\x74\x2e\x76\x61\x6c\x75\x65\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x6f\x70\x74\x2e\x6c\x61\x62\x65\x6c\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x76\x61\x6c\x75\x65\x20\x3d\x20\x6f\x70\x74\x2e\x76\x61\x6c\x75\x65\x7d\x20\x2f\x3e\x3c\x2f\x72\x6f\x77\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x69\x63\x6b\x65\x72\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x70\x69\x63\x6b\x65\x64\x3a\x20\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x6e\x75\x6c\x6c\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x63\x6f\x75\x6e\x74\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x63\x6f\x75\x6e\x74\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x50\x69\x63\x6b\x65\x72\x20\x76\x61\x6c\x75\x65\x3d\x7b\x70\x69\x63\x6b\x65\x64\x7d\x20\x6f\x6e\x43\x68\x61\x6e\x67\x65\x3d\x7b\x7c\x76\x7c\x20\x7b\x20\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x3b\x20\x5f\x20\x3d\x20\x76\x3b\x20\x7d\x7d\x20\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x42\x31\x3a\x20\x73\x74\x61\x74\x69\x63\x20\x6c\x69\x66\x74\x69\x6e\x67\x20\x73\x68\x72\x69\x6e\x6b\x73\x20\x74\x6f\x20\x61\x63\x74\x75\x61\x6c\x20\x64\x65\x70\x65\x6e\x64\x65\x6e\x63\x69\x65\x73\x2e\x20\x45\x78\x74\x65\x72\x6e\x61\x6c\x20\x73\x74\x6f\x72\x65\x20\x72\x65\x61\x64\x20\x76\x69\x61\x20\x66\x75\x6e\x63\x74\x69\x6f\x6e\x20\x63\x61\x6c\x6c\x3b\x20\x73\x74\x61\x74\x69\x63\x0a\x2f\x2f\x20\x70\x61\x72\x61\x6d\x73\x20\x6d\x75\x73\x74\x20\x66\x6f\x6c\x6c\x6f\x77\x2e\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x65\x78\x74\x65\x72\x6e\x61\x6c\x5f\x63\x6f\x75\x6e\x74\x3a\x20\x3f\x2a\x75\x69\x2e\x53\x69\x67\x6e\x61\x6c\x28\x69\x33\x32\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x66\x6e\x20\x65\x78\x74\x65\x72\x6e\x61\x6c\x43\x6f\x75\x6e\x74\x28\x29\x20\x69\x33\x32\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x69\x66\x20\x28\x65\x78\x74\x65\x72\x6e\x61\x6c\x5f\x63\x6f\x75\x6e\x74\x29\x20\x7c\x73\x7c\x20\x73\x2e\x67\x65\x74\x28\x29\x20\x65\x6c\x73\x65\x20\x30\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x78\x74\x65\x72\x6e\x61\x6c\x53\x75\x6d\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x74\x6f\x74\x61\x6c\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x6e\x20\x2b\x20\x65\x78\x74\x65\x72\x6e\x61\x6c\x43\x6f\x75\x6e\x74\x28\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x73\x75\x6d\x20\x7b\x74\x6f\x74\x61\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x74\x61\x74\x69\x63\x54\x77\x69\x63\x65\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x74\x77\x69\x63\x65\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x6e\x20\x2a\x20\x32\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x74\x77\x69\x63\x65\x20\x7b\x74\x77\x69\x63\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x54\x65\x78\x74\x20\x63\x68\x69\x6c\x64\x20\x65\x6c\x65\x6d\x65\x6e\x74\x73\x20\x64\x65\x74\x65\x72\x6d\x69\x6e\x65\x64\x20\x62\x79\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x70\x61\x72\x61\x6d\x65\x74\x65\x72\x20\x74\x79\x70\x65\x2c\x20\x6e\x6f\x74\x20\x6e\x61\x6d\x65\x3a\x20\x61\x6c\x69\x61\x73\x65\x64\x20\x42\x75\x74\x74\x6f\x6e\x73\x20\x73\x74\x69\x6c\x6c\x0a\x2f\x2f\x2f\x20\x74\x72\x65\x61\x74\x20\x74\x65\x78\x74\x20\x61\x73\x20\x6c\x61\x62\x65\x6c\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x42\x74\x6e\x20\x3d\x20\x57\x2e\x42\x75\x74\x74\x6f\x6e\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x41\x6c\x69\x61\x73\x4c\x61\x62\x65\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x6e\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x42\x74\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x3e\x41\x6c\x69\x61\x73\x65\x64\x3c\x2f\x42\x74\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x43\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x73\x20\x77\x69\x74\x68\x6f\x75\x74\x20\x6c\x61\x62\x65\x6c\x20\x70\x61\x72\x61\x6d\x65\x74\x65\x72\x20\x28\x77\x69\x74\x68\x20\x73\x6c\x6f\x74\x73\x29\x3a\x20\x74\x65\x78\x74\x20\x72\x65\x6d\x61\x69\x6e\x73\x20\x63\x68\x69\x6c\x64\x20\x65\x6c\x65\x6d\x65\x6e\x74\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x65\x78\x74\x49\x6e\x74\x6f\x53\x6c\x6f\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x50\x61\x6e\x65\x6c\x20\x74\x69\x74\x6c\x65\x3d\x22\x70\x22\x3e\x70\x6c\x61\x69\x6e\x20\x77\x6f\x72\x64\x73\x3c\x2f\x50\x61\x6e\x65\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x4e\x6f\x20\x64\x65\x66\x61\x75\x6c\x74\x20\x76\x61\x6c\x75\x65\x20\x6d\x65\x61\x6e\x73\x20\x72\x65\x71\x75\x69\x72\x65\x64\x20\x28\x66\x6f\x72\x20\x64\x61\x74\x61\x20\x70\x61\x72\x61\x6d\x65\x74\x65\x72\x73\x20\x61\x6e\x64\x20\x48\x61\x6e\x64\x6c\x65\x72\x73\x29\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x65\x71\x75\x69\x72\x65\x64\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x6f\x6e\x47\x6f\x3a\x20\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6c\x61\x62\x65\x6c\x3d\x7b\x74\x69\x74\x6c\x65\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x47\x6f\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x65\x71\x75\x69\x72\x65\x64\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x3e\x77\x65\x6e\x74\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x52\x65\x71\x75\x69\x72\x65\x64\x20\x74\x69\x74\x6c\x65\x3d\x22\x47\x6f\x20\x74\x68\x65\x72\x65\x22\x20\x6f\x6e\x47\x6f\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x20\x2f\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x49\x36\x3a\x20\x6f\x70\x74\x69\x6f\x6e\x61\x6c\x20\x76\x61\x6c\x75\x65\x20\x63\x61\x70\x74\x75\x72\x65\x2e\x20\x56\x61\x6c\x75\x65\x20\x63\x68\x61\x6e\x67\x65\x73\x20\x77\x69\x74\x68\x69\x6e\x20\x74\x68\x65\x20\x73\x61\x6d\x65\x20\x62\x72\x61\x6e\x63\x68\x20\x75\x70\x64\x61\x74\x65\x20\x6f\x6e\x6c\x79\x20\x74\x65\x78\x74\x2c\x20\x62\x72\x61\x6e\x63\x68\x20\x64\x6f\x65\x73\x0a\x2f\x2f\x2f\x20\x6e\x6f\x74\x20\x72\x65\x62\x75\x69\x6c\x64\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x69\x63\x6b\x65\x64\x4e\x61\x6d\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x70\x69\x63\x6b\x65\x64\x3a\x20\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x6e\x75\x6c\x6c\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x70\x69\x63\x6b\x65\x64\x29\x20\x7c\x6e\x61\x6d\x65\x7c\x20\x3c\x74\x65\x78\x74\x3e\x70\x69\x63\x6b\x65\x64\x20\x7b\x6e\x61\x6d\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x3e\x6e\x6f\x6e\x65\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x70\x69\x63\x6b\x65\x64\x20\x3d\x20\x22\x61\x22\x7d\x3e\x41\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x70\x69\x63\x6b\x65\x64\x20\x3d\x20\x22\x62\x22\x7d\x3e\x42\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x70\x69\x63\x6b\x65\x64\x20\x3d\x20\x6e\x75\x6c\x6c\x7d\x3e\x43\x6c\x65\x61\x72\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x53\x68\x61\x70\x65\x20\x3d\x20\x75\x6e\x69\x6f\x6e\x28\x65\x6e\x75\x6d\x29\x20\x7b\x20\x63\x69\x72\x63\x6c\x65\x3a\x20\x69\x33\x32\x2c\x20\x73\x71\x75\x61\x72\x65\x3a\x20\x69\x33\x32\x2c\x20\x6e\x6f\x6e\x65\x20\x7d\x3b\x0a\x2f\x2f\x2f\x20\x49\x36\x3a\x20\x70\x61\x79\x6c\x6f\x61\x64\x20\x63\x61\x70\x74\x75\x72\x65\x20\x77\x69\x74\x68\x20\x74\x61\x67\x67\x65\x64\x20\x75\x6e\x69\x6f\x6e\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x68\x61\x70\x65\x4c\x61\x62\x65\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x61\x70\x65\x3a\x20\x53\x68\x61\x70\x65\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x2e\x7b\x20\x2e\x63\x69\x72\x63\x6c\x65\x20\x3d\x20\x31\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x73\x77\x69\x74\x63\x68\x20\x28\x73\x68\x61\x70\x65\x29\x20\x7b\x20\x2e\x63\x69\x72\x63\x6c\x65\x20\x3d\x3e\x20\x7c\x72\x7c\x20\x3c\x74\x65\x78\x74\x3e\x63\x69\x72\x63\x6c\x65\x20\x7b\x72\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x2c\x20\x2e\x73\x71\x75\x61\x72\x65\x20\x3d\x3e\x20\x7c\x77\x7c\x20\x3c\x74\x65\x78\x74\x3e\x73\x71\x75\x61\x72\x65\x20\x7b\x77\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x2c\x20\x2e\x6e\x6f\x6e\x65\x20\x3d\x3e\x20\x3c\x74\x65\x78\x74\x3e\x6e\x6f\x20\x73\x68\x61\x70\x65\x3c\x2f\x74\x65\x78\x74\x3e\x20\x7d\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x61\x70\x65\x20\x3d\x20\x2e\x7b\x20\x2e\x63\x69\x72\x63\x6c\x65\x20\x3d\x20\x32\x20\x7d\x7d\x3e\x47\x72\x6f\x77\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x61\x70\x65\x20\x3d\x20\x2e\x7b\x20\x2e\x73\x71\x75\x61\x72\x65\x20\x3d\x20\x35\x20\x7d\x7d\x3e\x53\x71\x75\x61\x72\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x61\x70\x65\x20\x3d\x20\x2e\x6e\x6f\x6e\x65\x7d\x3e\x4e\x6f\x6e\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x50\x61\x72\x73\x65\x45\x72\x72\x6f\x72\x20\x3d\x20\x65\x72\x72\x6f\x72\x7b\x42\x61\x64\x7d\x3b\x0a\x2f\x2f\x2f\x20\x49\x36\x3a\x20\x76\x61\x6c\x75\x65\x20\x2f\x20\x65\x72\x72\x6f\x72\x20\x63\x61\x70\x74\x75\x72\x65\x20\x66\x72\x6f\x6d\x20\x65\x72\x72\x6f\x72\x20\x75\x6e\x69\x6f\x6e\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x61\x72\x73\x65\x64\x28\x72\x65\x73\x75\x6c\x74\x3a\x20\x50\x61\x72\x73\x65\x45\x72\x72\x6f\x72\x21\x69\x33\x32\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x72\x65\x73\x75\x6c\x74\x29\x20\x7c\x76\x7c\x20\x3c\x74\x65\x78\x74\x3e\x76\x61\x6c\x75\x65\x20\x7b\x76\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x20\x65\x6c\x73\x65\x20\x7c\x65\x7c\x20\x3c\x74\x65\x78\x74\x3e\x65\x72\x72\x6f\x72\x20\x7b\x40\x65\x72\x72\x6f\x72\x4e\x61\x6d\x65\x28\x65\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x49\x31\x32\x3a\x20\x6c\x61\x7a\x79\x20\x62\x72\x61\x6e\x63\x68\x20\x63\x6f\x6e\x73\x74\x72\x75\x63\x74\x69\x6f\x6e\x2e\x20\x48\x69\x64\x64\x65\x6e\x20\x62\x72\x61\x6e\x63\x68\x65\x73\x20\x64\x6f\x20\x6e\x6f\x74\x20\x63\x6f\x6e\x73\x74\x72\x75\x63\x74\x20\x64\x65\x72\x69\x76\x65\x64\x20\x76\x61\x6c\x75\x65\x73\x20\x69\x6e\x73\x69\x64\x65\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x61\x7a\x79\x42\x72\x61\x6e\x63\x68\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x73\x68\x6f\x77\x6e\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x7b\x69\x66\x20\x28\x73\x68\x6f\x77\x6e\x29\x20\x3c\x74\x65\x78\x74\x3e\x7b\x6e\x20\x2a\x20\x32\x20\x2b\x20\x31\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x73\x68\x6f\x77\x6e\x20\x3d\x20\x21\x73\x68\x6f\x77\x6e\x7d\x3e\x54\x6f\x67\x67\x6c\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x42\x32\x3a\x20\x68\x6f\x73\x74\x20\x65\x6c\x65\x6d\x65\x6e\x74\x20\x74\x79\x70\x65\x64\x20\x65\x76\x65\x6e\x74\x73\x20\x28\x6b\x65\x79\x62\x6f\x61\x72\x64\x20\x2f\x20\x70\x6f\x69\x6e\x74\x65\x72\x20\x2f\x20\x73\x63\x72\x6f\x6c\x6c\x29\x3b\x20\x65\x2e\x63\x6f\x6e\x73\x75\x6d\x65\x28\x29\x20\x70\x72\x65\x76\x65\x6e\x74\x73\x20\x64\x65\x66\x61\x75\x6c\x74\x0a\x2f\x2f\x2f\x20\x62\x65\x68\x61\x76\x69\x6f\x72\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4b\x65\x79\x50\x61\x64\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6c\x61\x73\x74\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x22\x6e\x6f\x6e\x65\x22\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x70\x78\x3a\x20\x66\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6d\x6f\x76\x65\x73\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x70\x61\x64\x22\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x66\x6f\x63\x75\x73\x61\x62\x6c\x65\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x4b\x65\x79\x44\x6f\x77\x6e\x3d\x7b\x7c\x65\x7c\x20\x69\x66\x20\x28\x65\x2e\x6b\x65\x79\x20\x3d\x3d\x20\x2e\x65\x73\x63\x61\x70\x65\x29\x20\x7b\x20\x6c\x61\x73\x74\x20\x3d\x20\x22\x65\x73\x63\x61\x70\x65\x22\x3b\x20\x65\x2e\x63\x6f\x6e\x73\x75\x6d\x65\x28\x29\x3b\x20\x7d\x20\x65\x6c\x73\x65\x20\x6c\x61\x73\x74\x20\x3d\x20\x22\x6f\x74\x68\x65\x72\x22\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x50\x6f\x69\x6e\x74\x65\x72\x44\x6f\x77\x6e\x3d\x7b\x7c\x65\x7c\x20\x70\x78\x20\x3d\x20\x65\x2e\x78\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x50\x6f\x69\x6e\x74\x65\x72\x4d\x6f\x76\x65\x3d\x7b\x6d\x6f\x76\x65\x73\x20\x2b\x3d\x20\x31\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x53\x63\x72\x6f\x6c\x6c\x3d\x7b\x7c\x65\x7c\x20\x65\x2e\x73\x74\x6f\x70\x28\x29\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x6b\x65\x79\x20\x7b\x6c\x61\x73\x74\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x78\x20\x7b\x70\x78\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x6d\x6f\x76\x65\x73\x20\x7b\x6d\x6f\x76\x65\x73\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x69\x66\x65\x63\x79\x63\x6c\x65\x5f\x6c\x6f\x67\x3a\x20\x5b\x38\x5d\x69\x33\x32\x20\x3d\x20\x40\x73\x70\x6c\x61\x74\x28\x30\x29\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x6c\x69\x66\x65\x63\x79\x63\x6c\x65\x5f\x6c\x65\x6e\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x3b\x0a\x66\x6e\x20\x6c\x6f\x67\x4c\x69\x66\x65\x63\x79\x63\x6c\x65\x28\x76\x3a\x20\x69\x33\x32\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x6c\x69\x66\x65\x63\x79\x63\x6c\x65\x5f\x6c\x6f\x67\x5b\x6c\x69\x66\x65\x63\x79\x63\x6c\x65\x5f\x6c\x65\x6e\x5d\x20\x3d\x20\x76\x3b\x0a\x20\x20\x20\x20\x6c\x69\x66\x65\x63\x79\x63\x6c\x65\x5f\x6c\x65\x6e\x20\x2b\x3d\x20\x31\x3b\x0a\x7d\x0a\x66\x6e\x20\x6d\x6f\x75\x6e\x74\x65\x64\x28\x72\x3a\x20\x61\x6e\x79\x74\x79\x70\x65\x29\x20\x69\x33\x32\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x69\x66\x20\x28\x72\x2e\x67\x65\x74\x28\x29\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x31\x20\x65\x6c\x73\x65\x20\x30\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x42\x32\x3a\x20\x65\x66\x66\x65\x63\x74\x73\x20\x66\x6f\x6c\x6c\x6f\x77\x20\x73\x6f\x75\x72\x63\x65\x3b\x20\x72\x65\x66\x20\x61\x74\x74\x61\x63\x68\x65\x64\x20\x61\x74\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x3b\x20\x6f\x6e\x55\x6e\x6d\x6f\x75\x6e\x74\x20\x65\x78\x65\x63\x75\x74\x65\x73\x20\x64\x75\x72\x69\x6e\x67\x20\x75\x6e\x6d\x6f\x75\x6e\x74\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x69\x66\x65\x63\x79\x63\x6c\x65\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x64\x6f\x75\x62\x6c\x65\x64\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x72\x6f\x6f\x74\x20\x3d\x20\x72\x65\x66\x28\x29\x3b\x0a\x20\x20\x20\x20\x65\x66\x66\x65\x63\x74\x28\x64\x6f\x75\x62\x6c\x65\x64\x20\x3d\x20\x6e\x20\x2a\x20\x32\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x4d\x6f\x75\x6e\x74\x28\x6c\x6f\x67\x4c\x69\x66\x65\x63\x79\x63\x6c\x65\x28\x6d\x6f\x75\x6e\x74\x65\x64\x28\x72\x6f\x6f\x74\x29\x29\x29\x3b\x0a\x20\x20\x20\x20\x6f\x6e\x55\x6e\x6d\x6f\x75\x6e\x74\x28\x6c\x6f\x67\x4c\x69\x66\x65\x63\x79\x63\x6c\x65\x28\x2d\x31\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x20\x72\x65\x66\x3d\x7b\x72\x6f\x6f\x74\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x64\x6f\x75\x62\x6c\x65\x64\x20\x7b\x64\x6f\x75\x62\x6c\x65\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x66\x6e\x20\x6d\x61\x79\x46\x61\x69\x6c\x28\x6f\x6b\x3a\x20\x62\x6f\x6f\x6c\x29\x20\x21\x69\x33\x32\x20\x7b\x0a\x20\x20\x20\x20\x69\x66\x20\x28\x21\x6f\x6b\x29\x20\x72\x65\x74\x75\x72\x6e\x20\x65\x72\x72\x6f\x72\x2e\x4e\x6f\x70\x65\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x35\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x42\x32\x3a\x20\x74\x72\x79\x20\x69\x6e\x20\x65\x76\x65\x6e\x74\x20\x28\x66\x61\x69\x6c\x75\x72\x65\x20\x72\x65\x70\x6f\x72\x74\x65\x64\x20\x76\x69\x61\x20\x75\x69\x2e\x6f\x6e\x2e\x72\x65\x70\x6f\x72\x74\x45\x72\x72\x6f\x72\x2c\x20\x66\x6f\x6c\x6c\x6f\x77\x69\x6e\x67\x20\x73\x74\x61\x74\x65\x6d\x65\x6e\x74\x73\x20\x64\x6f\x6e\x27\x74\x20\x65\x78\x65\x63\x75\x74\x65\x29\x0a\x2f\x2f\x2f\x20\x61\x6e\x64\x20\x63\x6f\x6e\x73\x74\x20\x6c\x6f\x63\x61\x6c\x73\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x72\x79\x45\x76\x65\x6e\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x6e\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x7b\x20\x63\x6f\x6e\x73\x74\x20\x76\x20\x3d\x20\x74\x72\x79\x20\x6d\x61\x79\x46\x61\x69\x6c\x28\x74\x72\x75\x65\x29\x3b\x20\x6e\x20\x2b\x3d\x20\x76\x3b\x20\x7d\x7d\x3e\x4f\x6b\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x7b\x20\x63\x6f\x6e\x73\x74\x20\x76\x20\x3d\x20\x74\x72\x79\x20\x6d\x61\x79\x46\x61\x69\x6c\x28\x66\x61\x6c\x73\x65\x29\x3b\x20\x6e\x20\x2b\x3d\x20\x76\x3b\x20\x7d\x7d\x3e\x46\x61\x69\x6c\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x50\x33\x61\x3a\x20\x3a\x66\x6f\x63\x75\x73\x20\x28\x63\x6c\x69\x63\x6b\x29\x20\x2f\x20\x3a\x66\x6f\x63\x75\x73\x2d\x76\x69\x73\x69\x62\x6c\x65\x20\x28\x6b\x65\x79\x62\x6f\x61\x72\x64\x29\x20\x2f\x20\x3a\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x28\x66\x72\x6f\x6d\x20\x61\x31\x31\x79\x2e\x64\x69\x73\x61\x62\x6c\x65\x64\x29\x20\x6f\x6e\x20\x70\x6c\x61\x69\x6e\x20\x62\x6f\x78\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x74\x61\x74\x65\x42\x6f\x78\x28\x64\x69\x73\x61\x62\x6c\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x73\x62\x22\x20\x66\x6f\x63\x75\x73\x61\x62\x6c\x65\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x74\x61\x74\x65\x73\x2e\x66\x69\x65\x6c\x64\x7d\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x62\x75\x74\x74\x6f\x6e\x2c\x20\x2e\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x3d\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x7d\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x50\x33\x62\x3a\x20\x6e\x61\x6d\x65\x64\x20\x73\x6c\x6f\x74\x73\x3b\x20\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x20\x6e\x65\x65\x64\x20\x6e\x6f\x74\x20\x62\x65\x20\x74\x68\x65\x20\x6c\x61\x73\x74\x20\x63\x68\x69\x6c\x64\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x72\x61\x6d\x65\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x22\x2c\x20\x68\x65\x61\x64\x65\x72\x3a\x20\x56\x69\x65\x77\x2c\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x2c\x20\x66\x6f\x6f\x74\x65\x72\x3a\x20\x56\x69\x65\x77\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x3e\x7b\x68\x65\x61\x64\x65\x72\x7d\x3c\x74\x65\x78\x74\x3e\x7b\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x74\x65\x78\x74\x3e\x61\x66\x74\x65\x72\x20\x62\x6f\x64\x79\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x6f\x74\x65\x72\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x72\x61\x6d\x65\x55\x73\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x46\x72\x61\x6d\x65\x20\x74\x69\x74\x6c\x65\x3d\x22\x54\x22\x20\x68\x65\x61\x64\x65\x72\x3d\x7b\x3c\x74\x65\x78\x74\x3e\x68\x65\x61\x64\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x20\x66\x6f\x6f\x74\x65\x72\x3d\x7b\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x3e\x4d\x6f\x72\x65\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x62\x6f\x64\x79\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x46\x72\x61\x6d\x65\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x4f\x70\x74\x69\x6f\x6e\x61\x6c\x20\x6e\x61\x6d\x65\x64\x20\x73\x6c\x6f\x74\x73\x20\x28\x3f\x56\x69\x65\x77\x29\x3a\x20\x61\x20\x73\x6c\x6f\x74\x20\x62\x6f\x78\x20\x65\x78\x69\x73\x74\x73\x20\x6f\x6e\x6c\x79\x20\x77\x68\x65\x6e\x20\x74\x68\x65\x20\x63\x61\x6c\x6c\x65\x72\x20\x66\x69\x6c\x6c\x65\x64\x20\x74\x68\x65\x20\x73\x6c\x6f\x74\x2c\x20\x73\x6f\x20\x61\x6e\x0a\x2f\x2f\x2f\x20\x61\x62\x73\x65\x6e\x74\x20\x69\x63\x6f\x6e\x20\x6c\x65\x61\x76\x65\x73\x20\x6e\x6f\x20\x67\x61\x70\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x69\x65\x6c\x64\x28\x69\x63\x6f\x6e\x3a\x20\x3f\x56\x69\x65\x77\x2c\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x3a\x20\x56\x69\x65\x77\x2c\x20\x61\x70\x70\x65\x6e\x64\x3a\x20\x3f\x56\x69\x65\x77\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x66\x69\x65\x6c\x64\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x36\x20\x7d\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x63\x6f\x6e\x29\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x66\x69\x65\x6c\x64\x2e\x69\x63\x6f\x6e\x22\x3e\x7b\x69\x63\x6f\x6e\x7d\x3c\x2f\x62\x6f\x78\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x66\x69\x65\x6c\x64\x2e\x63\x6f\x6e\x74\x65\x6e\x74\x22\x3e\x7b\x63\x68\x69\x6c\x64\x72\x65\x6e\x7d\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x61\x70\x70\x65\x6e\x64\x29\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x66\x69\x65\x6c\x64\x2e\x61\x70\x70\x65\x6e\x64\x22\x3e\x3c\x74\x65\x78\x74\x3e\x5b\x3c\x2f\x74\x65\x78\x74\x3e\x7b\x61\x70\x70\x65\x6e\x64\x7d\x3c\x2f\x62\x6f\x78\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x69\x65\x6c\x64\x42\x61\x72\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x46\x69\x65\x6c\x64\x3e\x3c\x74\x65\x78\x74\x3e\x62\x6f\x64\x79\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x46\x69\x65\x6c\x64\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x46\x69\x65\x6c\x64\x46\x75\x6c\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x73\x69\x67\x6e\x61\x6c\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x46\x69\x65\x6c\x64\x20\x69\x63\x6f\x6e\x3d\x7b\x3c\x74\x65\x78\x74\x3e\x69\x63\x6f\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x20\x61\x70\x70\x65\x6e\x64\x3d\x7b\x3c\x42\x75\x74\x74\x6f\x6e\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6e\x20\x2b\x3d\x20\x31\x7d\x3e\x67\x6f\x3c\x2f\x42\x75\x74\x74\x6f\x6e\x3e\x7d\x3e\x3c\x74\x65\x78\x74\x3e\x62\x6f\x64\x79\x20\x7b\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x46\x69\x65\x6c\x64\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x50\x34\x3a\x20\x69\x63\x6f\x6e\x2d\x63\x6f\x6c\x6f\x72\x20\x74\x6f\x67\x67\x6c\x65\x73\x20\x77\x69\x74\x68\x20\x66\x6c\x61\x67\x3b\x20\x72\x65\x76\x65\x72\x74\x73\x20\x74\x6f\x20\x6d\x6f\x75\x6e\x74\x2d\x74\x69\x6d\x65\x20\x74\x69\x6e\x74\x20\x6f\x6e\x20\x75\x6e\x64\x6f\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x6c\x79\x70\x68\x42\x6f\x78\x28\x68\x6f\x74\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x69\x63\x6f\x6e\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x67\x6c\x79\x70\x68\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x74\x61\x74\x65\x73\x2e\x47\x6c\x79\x70\x68\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x68\x6f\x74\x20\x3d\x20\x68\x6f\x74\x20\x7d\x29\x7d\x20\x73\x72\x63\x3d\x7b\x75\x69\x2e\x69\x63\x6f\x6e\x73\x2e\x63\x68\x65\x63\x6b\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x6c\x79\x70\x68\x54\x69\x6e\x74\x65\x64\x28\x68\x6f\x74\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x69\x63\x6f\x6e\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x67\x6c\x79\x70\x68\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x74\x61\x74\x65\x73\x2e\x47\x6c\x79\x70\x68\x4f\x6e\x48\x6f\x74\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x68\x6f\x74\x20\x3d\x20\x68\x6f\x74\x20\x7d\x29\x7d\x20\x73\x72\x63\x3d\x7b\x75\x69\x2e\x69\x63\x6f\x6e\x73\x2e\x63\x68\x65\x63\x6b\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x4c\x69\x6e\x6b\x54\x65\x78\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x6c\x69\x6e\x6b\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x74\x61\x74\x65\x73\x2e\x6c\x69\x6e\x6b\x7d\x3e\x4f\x70\x65\x6e\x20\x64\x6f\x63\x73\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x69\x6c\x6c\x54\x65\x78\x74\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x70\x69\x6c\x6c\x22\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x74\x61\x74\x65\x73\x2e\x70\x69\x6c\x6c\x7d\x3e\x42\x65\x74\x61\x3c\x2f\x74\x65\x78\x74\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x50\x35\x3a\x20\x69\x6e\x2d\x70\x6c\x61\x63\x65\x20\x6c\x69\x73\x74\x20\x72\x6f\x77\x20\x75\x70\x64\x61\x74\x65\x20\x2d\x2d\x20\x73\x61\x6d\x65\x20\x6b\x65\x79\x2c\x20\x63\x68\x61\x6e\x67\x65\x64\x20\x63\x6f\x6e\x74\x65\x6e\x74\x20\x64\x6f\x65\x73\x20\x6e\x6f\x74\x20\x72\x65\x62\x75\x69\x6c\x64\x20\x72\x6f\x77\x20\x28\x66\x6f\x63\x75\x73\x2f\x6c\x6f\x63\x61\x6c\x0a\x2f\x2f\x2f\x20\x73\x74\x61\x74\x65\x20\x70\x72\x65\x73\x65\x72\x76\x65\x64\x29\x3b\x20\x65\x76\x65\x6e\x74\x20\x72\x65\x61\x64\x73\x20\x6c\x61\x74\x65\x73\x74\x20\x64\x61\x74\x61\x2e\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x70\x69\x63\x6b\x65\x64\x5f\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x22\x22\x3b\x0a\x66\x6e\x20\x70\x69\x63\x6b\x28\x74\x69\x74\x6c\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x70\x69\x63\x6b\x65\x64\x5f\x74\x69\x74\x6c\x65\x20\x3d\x20\x74\x69\x74\x6c\x65\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x64\x69\x74\x61\x62\x6c\x65\x52\x6f\x77\x73\x28\x72\x6f\x77\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x3d\x20\x26\x2e\x7b\x7d\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x72\x20\x28\x72\x6f\x77\x73\x29\x20\x7c\x69\x74\x65\x6d\x2c\x20\x69\x7c\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x72\x6f\x77\x22\x20\x66\x6f\x63\x75\x73\x61\x62\x6c\x65\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x70\x69\x63\x6b\x28\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x29\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x7b\x69\x7d\x3a\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x44\x61\x74\x61\x20\x70\x61\x72\x61\x6d\x65\x74\x65\x72\x73\x20\x6e\x61\x6d\x65\x64\x20\x6f\x6e\x2a\x20\x28\x65\x2e\x67\x2e\x2c\x20\x6f\x6e\x54\x6f\x70\x3a\x20\x62\x6f\x6f\x6c\x29\x20\x70\x61\x73\x73\x20\x62\x79\x20\x76\x61\x6c\x75\x65\x3b\x20\x65\x76\x65\x6e\x74\x20\x70\x61\x72\x61\x6d\x73\x20\x72\x65\x63\x65\x69\x76\x69\x6e\x67\x20\x69\x64\x65\x6e\x74\x69\x66\x69\x65\x72\x0a\x2f\x2f\x2f\x20\x63\x61\x6c\x6c\x20\x69\x74\x2e\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x73\x61\x76\x65\x64\x5f\x63\x6f\x75\x6e\x74\x3a\x20\x75\x33\x32\x20\x3d\x20\x30\x3b\x0a\x66\x6e\x20\x73\x61\x76\x65\x28\x29\x20\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x73\x61\x76\x65\x64\x5f\x63\x6f\x75\x6e\x74\x20\x2b\x3d\x20\x31\x3b\x0a\x7d\x0a\x66\x6e\x20\x50\x69\x6e\x28\x6f\x6e\x54\x6f\x70\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x20\x6f\x6e\x53\x61\x76\x65\x3a\x20\x3f\x48\x61\x6e\x64\x6c\x65\x72\x28\x76\x6f\x69\x64\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x70\x69\x6e\x22\x20\x76\x69\x73\x69\x62\x6c\x65\x3d\x7b\x6f\x6e\x54\x6f\x70\x7d\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x6f\x6e\x53\x61\x76\x65\x7d\x20\x2f\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x69\x6e\x42\x6f\x61\x72\x64\x28\x70\x69\x6e\x6e\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x50\x69\x6e\x20\x6f\x6e\x54\x6f\x70\x3d\x7b\x74\x72\x75\x65\x7d\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x50\x69\x6e\x20\x6f\x6e\x54\x6f\x70\x3d\x7b\x70\x69\x6e\x6e\x65\x64\x7d\x20\x6f\x6e\x53\x61\x76\x65\x3d\x7b\x73\x61\x76\x65\x7d\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x50\x69\x6e\x20\x6f\x6e\x54\x6f\x70\x3d\x7b\x21\x70\x69\x6e\x6e\x65\x64\x7d\x20\x6f\x6e\x53\x61\x76\x65\x3d\x7b\x73\x61\x76\x65\x28\x29\x7d\x20\x2f\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x54\x65\x78\x74\x20\x63\x68\x69\x6c\x64\x20\x65\x6c\x65\x6d\x65\x6e\x74\x73\x20\x69\x6e\x74\x6f\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x20\x64\x65\x63\x6c\x61\x72\x61\x74\x69\x6f\x6e\x27\x73\x20\x54\x65\x78\x74\x20\x70\x61\x72\x61\x6d\x65\x74\x65\x72\x20\x28\x72\x65\x67\x61\x72\x64\x6c\x65\x73\x73\x20\x6f\x66\x20\x70\x61\x72\x61\x6d\x20\x6e\x61\x6d\x65\x29\x3b\x0a\x2f\x2f\x2f\x20\x63\x6f\x6d\x70\x6f\x6e\x65\x6e\x74\x73\x20\x77\x69\x74\x68\x6f\x75\x74\x20\x54\x65\x78\x74\x20\x70\x61\x72\x61\x6d\x20\x63\x6f\x6c\x6c\x65\x63\x74\x20\x61\x73\x20\x63\x68\x69\x6c\x64\x72\x65\x6e\x2e\x0a\x66\x6e\x20\x43\x61\x70\x74\x69\x6f\x6e\x28\x74\x69\x74\x6c\x65\x3a\x20\x54\x65\x78\x74\x20\x3d\x20\x22\x22\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x20\x74\x65\x73\x74\x49\x64\x3d\x22\x63\x61\x70\x74\x69\x6f\x6e\x22\x3e\x7b\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x61\x70\x74\x69\x6f\x6e\x73\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x63\x6f\x6c\x3e\x3c\x43\x61\x70\x74\x69\x6f\x6e\x3e\x48\x65\x6c\x6c\x6f\x3c\x2f\x43\x61\x70\x74\x69\x6f\x6e\x3e\x3c\x2f\x63\x6f\x6c\x3e\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x4e\x65\x73\x74\x65\x64\x20\x66\x6f\x72\x3a\x20\x69\x6e\x6e\x65\x72\x20\x72\x6f\x77\x20\x72\x65\x66\x65\x72\x65\x6e\x63\x65\x73\x20\x6f\x75\x74\x65\x72\x20\x72\x6f\x77\x20\x66\x69\x65\x6c\x64\x73\x2e\x0a\x70\x75\x62\x20\x63\x6f\x6e\x73\x74\x20\x47\x72\x6f\x75\x70\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x69\x64\x3a\x20\x75\x36\x34\x2c\x20\x6e\x61\x6d\x65\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x20\x6d\x65\x6d\x62\x65\x72\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x49\x74\x65\x6d\x20\x7d\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x47\x72\x6f\x75\x70\x73\x28\x67\x72\x6f\x75\x70\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x47\x72\x6f\x75\x70\x20\x3d\x20\x26\x2e\x7b\x7d\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x72\x20\x28\x67\x72\x6f\x75\x70\x73\x29\x20\x7c\x67\x7c\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x3e\x7b\x67\x2e\x6e\x61\x6d\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x66\x6f\x72\x20\x28\x67\x2e\x6d\x65\x6d\x62\x65\x72\x73\x29\x20\x7c\x6d\x7c\x20\x3c\x74\x65\x78\x74\x3e\x7b\x67\x2e\x6e\x61\x6d\x65\x7d\x2f\x7b\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x63\x6f\x6c\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x2f\x2f\x2f\x20\x52\x65\x61\x63\x74\x69\x76\x65\x20\x6e\x61\x6d\x65\x20\x69\x6e\x20\x74\x79\x70\x65\x20\x70\x6f\x73\x69\x74\x69\x6f\x6e\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x54\x79\x70\x65\x4f\x66\x50\x72\x6f\x62\x65\x28\x6e\x3a\x20\x75\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x64\x6f\x75\x62\x6c\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x40\x61\x73\x28\x40\x54\x79\x70\x65\x4f\x66\x28\x6e\x29\x2c\x20\x6e\x20\x2a\x20\x32\x29\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x64\x6f\x75\x62\x6c\x65\x64\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"ui " = ui, .@"States " = States, .@"items " = items, .@"tasks0 " = tasks0, .@"choices " = choices, .@"Btn " = Btn, .@"ParseError " = ParseError, }) else void;

//# yix-map-data [[687,682],[3555,898],[6993,1114],[9046,1248],[12920,1461],[16681,1684],[21884,2047],[28270,2848],[34177,3355],[37816,3787],[42668,4386],[46107,4745],[50513,4998],[52037,5074],[55083,5228],[58514,5458],[62284,5652],[68878,6015],[71912,6200],[73691,6304],[75813,6482],[78985,6643],[81609,6806],[85249,7003],[89230,7206],[93094,7403],[98169,7632],[102497,7877],[106644,8093],[111359,8334],[115427,8526],[118494,8735],[121507,8945],[124710,9147],[127995,9370],[132844,9888],[139318,10202],[142532,10670],[144412,10796],[146408,11053],[149315,11268],[151302,11420],[153279,11537],[156112,11799],[162243,12280],[169081,12832],[172563,13078],[176727,13371],[182204,14315],[185533,14776],[189918,15179],[192070,15402],[194971,15671],[198782,15987],[202236,16340],[203999,16413],[207630,16662],[209542,16804],[211502,16954],[213356,17061],[215444,17407],[219700,17884],[221606,18022],[226904,18399],[228699,18491],[230789,18700],[236366,19043]]

//# yix-map stories.yix
