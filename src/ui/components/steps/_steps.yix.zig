// GENERATED FILE, do not edit: generated from steps.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Steps view. Styling in styles.yss; public types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const StepItem = mod.StepItem;

/// Text in circle: done is "v", otherwise number (starting from 1)
const CircleLabel = struct {
    completed: bool,
    n: usize,
    pub fn format(self: CircleLabel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.completed) return w.writeAll("v");
        try w.print("{d}", .{self.n});
    }
};

/// Circle displays number / checkmark, purely visual signals: explicitly state three
/// states -- selected = current step ("you are here"), checked = done, disabled = not
/// yet reached.
fn a11yOf(item: StepItem, completed: bool, active: bool) ui.A11yProps {
    return .{ .role = .listitem, .label = item.title, .description = item.description, .selected = active, .checked = completed, .disabled = !completed and !active };
}

/// Row key: content + borrow string address (row borrows title / description)
fn rowKey(it: StepItem) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_]?[]const u8{ it.title, it.description }) |field| {
        const f = field orelse "";
        h.update(&[_]u8{@intFromBool(field != null)});
        h.update(std.mem.asBytes(&f.len));
        h.update(f);
        h.update(std.mem.asBytes(&@intFromPtr(f.ptr)));
    }
    return h.final();
}

// Number circles retain their own text API. num_box supplies the explicit
// vertical line inset; icon circles use their flex centering.

/// Horizontal step: equal-width column (circle + title + description)
fn HStep(args: anytype) ui.view.ComponentOf(__yix_HStep) {
    return ui.view.component(__yix_HStep, ui.reactive.props.coerce(HStepProps, args));
}
const HStepProps = struct {
    item: ui.Source(StepItem),
    index: ui.Source(usize),
    current: ui.Source(usize),
    check: ui.Source(?ui.SvgAsset),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = HStep;
    pub const __yix_preview_mount = __yix_HStep;
};
fn __yix_HStep(__yix_props: HStepProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const item = __yix_props.item;
    const index = __yix_props.index;
    const current = __yix_props.current;
    const check = __yix_props.check;
    try ui.view.previewCheckSetup(scope, false);
    const completed = __yix_d1: {
        const __yix_T = @TypeOf(index.peek() < current.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() < __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const active = __yix_d2: {
        const __yix_T = @TypeOf(index.peek() == current.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() == __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.Step, .{ .completed = completed, .active = active });
    const semantics = __yix_d3: {
        const __yix_T = @TypeOf(a11yOf(item.peek(), index.peek() < current.peek(), index.peek() == current.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .item = item, .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.item.get(), __yix_ctx.index.get() < __yix_ctx.current.get(), __yix_ctx.index.get() == __yix_ctx.current.get());
        } }.__yix_compute);
    };
    const label = __yix_d4: {
        const __yix_T = @TypeOf(CircleLabel{ .completed = index.peek() < current.peek(), .n = index.peek() + 1 });
        break :__yix_d4 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return CircleLabel{ .completed = __yix_ctx.index.get() < __yix_ctx.current.get(), .n = __yix_ctx.index.get() + 1 };
        } }.__yix_compute);
    };
    const icon = __yix_d5: {
        const __yix_T = @TypeOf(if (index.peek() < current.peek()) check.peek() else null);
        break :__yix_d5 try scope.derive(__yix_T, .{ .index = index, .current = current, .check = check, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.index.get() < __yix_ctx.current.get()) __yix_ctx.check.get() else null;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .item = item, .p = p, .semantics = semantics, .label = label, .icon = icon, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep", .receiver = "box", .tokens = "box style = @static; a11y = semantics ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . h_step ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = "semantics ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .semantics = __yix_view_ctx.semantics, .icon = __yix_view_ctx.icon, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, .item = __yix_view_ctx.item, }, ui.view.box(.{ .style = S.h_step, .a11y = __yix_view_ctx.semantics, }, .{
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep", .receiver = "control", .tokens = "if ( icon ) | asset | < box style = { p . circle } > < icon style = { p . icon } src = { asset } / > < / box > else < text style = { p . num } box = { . { p . circle , S . num_box } } > { label } < / text > " }, .{ .icon = __yix_view_ctx.icon, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, ui.view.lazyIfSome(__yix_view_ctx.icon, .{ .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep/keyword_if:1/branch:0", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . circle ", .kind = .style, .literal = null }, } }, .{ .p = __yix_b1_0.p, .asset = asset, }, ui.view.box(.{ .style = __yix_b1_0.p.circle, }, .{
                    ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep/keyword_if:1/branch:0", .receiver = "icon", .tokens = "icon style = @static; src = asset ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . icon ", .kind = .style, .literal = null }, .{ .name = "src", .tokens = "asset ", .kind = .property, .literal = null }, } }, .{ .p = __yix_b1_0.p, .asset = asset, }, ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset)),
                })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep/keyword_if:1/branch:1", .receiver = "text", .tokens = "text style = @static; box = . { p . circle , S . num_box } ; label  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . num ", .kind = .style, .literal = null }, .{ .name = "box", .tokens = ". { p . circle , S . num_box } ", .kind = .property, .literal = null }, } }, .{ .p = __yix_b1_1.p, .label = __yix_b1_1.label, }, ui.view.text(.{ .style = __yix_b1_1.p.num, .box = .{ __yix_b1_1.p.circle, S.num_box }, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_1.label), ""), .{ __yix_b1_1.label, }))) }); } }.__yix_b)),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep", .receiver = "text", .tokens = "text style = @static; item . title  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . title ", .kind = .style, .literal = null }, } }, .{ .p = __yix_view_ctx.p, .item = __yix_view_ctx.item, }, ui.view.text(.{ .style = __yix_view_ctx.p.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d6: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().title);
        break :__yix_d6 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d6: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().title);
        break :__yix_d6 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep", .receiver = "control", .tokens = "if ( item . description ) | desc | < text style = { S . desc } > { desc } < / text > " }, .{ .item = __yix_view_ctx.item, }, ui.view.lazyIfSome(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().description);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().description;
        } }.__yix_compute);
    }, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, desc: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "HStep/keyword_if:2/branch:0", .receiver = "text", .tokens = "text style = @static; desc  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . desc ", .kind = .style, .literal = null }, } }, .{ .desc = desc, }, ui.view.text(.{ .style = S.desc, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(desc), ""), .{ desc, }))) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "HStep";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

/// Vertical step: indicator column (circle + connector to next step) + text column
fn VStep(args: anytype) ui.view.ComponentOf(__yix_VStep) {
    return ui.view.component(__yix_VStep, ui.reactive.props.coerce(VStepProps, args));
}
const VStepProps = struct {
    item: ui.Source(StepItem),
    index: ui.Source(usize),
    current: ui.Source(usize),
    count: ui.Source(usize),
    check: ui.Source(?ui.SvgAsset),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = VStep;
    pub const __yix_preview_mount = __yix_VStep;
};
fn __yix_VStep(__yix_props: VStepProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const item = __yix_props.item;
    const index = __yix_props.index;
    const current = __yix_props.current;
    const count = __yix_props.count;
    const check = __yix_props.check;
    try ui.view.previewCheckSetup(scope, false);
    const completed = __yix_d1: {
        const __yix_T = @TypeOf(index.peek() < current.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() < __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const active = __yix_d2: {
        const __yix_T = @TypeOf(index.peek() == current.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() == __yix_ctx.current.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.Step, .{ .completed = completed, .active = active });
    const semantics = __yix_d3: {
        const __yix_T = @TypeOf(a11yOf(item.peek(), index.peek() < current.peek(), index.peek() == current.peek()));
        break :__yix_d3 try scope.derive(__yix_T, .{ .item = item, .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.item.get(), __yix_ctx.index.get() < __yix_ctx.current.get(), __yix_ctx.index.get() == __yix_ctx.current.get());
        } }.__yix_compute);
    };
    const label = __yix_d4: {
        const __yix_T = @TypeOf(CircleLabel{ .completed = index.peek() < current.peek(), .n = index.peek() + 1 });
        break :__yix_d4 try scope.derive(__yix_T, .{ .index = index, .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return CircleLabel{ .completed = __yix_ctx.index.get() < __yix_ctx.current.get(), .n = __yix_ctx.index.get() + 1 };
        } }.__yix_compute);
    };
    const icon = __yix_d5: {
        const __yix_T = @TypeOf(if (index.peek() < current.peek()) check.peek() else null);
        break :__yix_d5 try scope.derive(__yix_T, .{ .index = index, .current = current, .check = check, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.index.get() < __yix_ctx.current.get()) __yix_ctx.check.get() else null;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .item = item, .index = index, .count = count, .p = p, .semantics = semantics, .label = label, .icon = icon, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "box", .tokens = "box style = @static; a11y = semantics ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . v_step ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = "semantics ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .semantics = __yix_view_ctx.semantics, .icon = __yix_view_ctx.icon, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, .index = __yix_view_ctx.index, .count = __yix_view_ctx.count, .item = __yix_view_ctx.item, }, ui.view.box(.{ .style = S.v_step, .a11y = __yix_view_ctx.semantics, }, .{
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . vIndicator ", .kind = .style, .literal = null }, } }, .{ .icon = __yix_view_ctx.icon, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, .index = __yix_view_ctx.index, .count = __yix_view_ctx.count, }, ui.view.box(.{ .style = S.vIndicator, }, .{
                ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "control", .tokens = "if ( icon ) | asset | < box style = { p . circle } > < icon style = { p . icon } src = { asset } / > < / box > else < text style = { p . num } box = { . { p . circle , S . num_box } } > { label } < / text > " }, .{ .icon = __yix_view_ctx.icon, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, ui.view.lazyIfSome(__yix_view_ctx.icon, .{ .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep/keyword_if:1/branch:0", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . circle ", .kind = .style, .literal = null }, } }, .{ .p = __yix_b1_0.p, .asset = asset, }, ui.view.box(.{ .style = __yix_b1_0.p.circle, }, .{
                        ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep/keyword_if:1/branch:0", .receiver = "icon", .tokens = "icon style = @static; src = asset ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . icon ", .kind = .style, .literal = null }, .{ .name = "src", .tokens = "asset ", .kind = .property, .literal = null }, } }, .{ .p = __yix_b1_0.p, .asset = asset, }, ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset)),
                    })) }); } }.__yix_b, struct { fn __yix_b(__yix_b1_1: anytype, __yix_bs1_1: *ui.Scope, __yix_bc1_1: *ui.Cx, __yix_bk1_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_1, __yix_bc1_1, __yix_bk1_1, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep/keyword_if:1/branch:1", .receiver = "text", .tokens = "text style = @static; box = . { p . circle , S . num_box } ; label  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . num ", .kind = .style, .literal = null }, .{ .name = "box", .tokens = ". { p . circle , S . num_box } ", .kind = .property, .literal = null }, } }, .{ .p = __yix_b1_1.p, .label = __yix_b1_1.label, }, ui.view.text(.{ .style = __yix_b1_1.p.num, .box = .{ __yix_b1_1.p.circle, S.num_box }, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_1.label), ""), .{ __yix_b1_1.label, }))) }); } }.__yix_b)),
                ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "control", .tokens = "if ( index + 1 < count ) < box style = { p . connector } / > " }, .{ .index = __yix_view_ctx.index, .count = __yix_view_ctx.count, .p = __yix_view_ctx.p, }, ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.index.peek() + 1 < __yix_view_ctx.count.peek());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .index = __yix_view_ctx.index, .count = __yix_view_ctx.count, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.index.get() + 1 < __yix_ctx.count.get();
        } }.__yix_compute);
    }, .{ .p = __yix_view_ctx.p, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep/keyword_if:2/branch:0", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . connector ", .kind = .style, .literal = null }, } }, .{ .p = __yix_b2_0.p, }, ui.view.box(.{ .style = __yix_b2_0.p.connector, }, .{ })) }); } }.__yix_b, null)),
            })),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . vText ", .kind = .style, .literal = null }, } }, .{ .p = __yix_view_ctx.p, .item = __yix_view_ctx.item, }, ui.view.box(.{ .style = S.vText, }, .{
                ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "text", .tokens = "text style = @static; item . title  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . title ", .kind = .style, .literal = null }, } }, .{ .p = __yix_view_ctx.p, .item = __yix_view_ctx.item, }, ui.view.text(.{ .style = __yix_view_ctx.p.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d6: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().title);
        break :__yix_d6 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }), ""), .{ __yix_d6: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().title);
        break :__yix_d6 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, }))),
                ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep", .receiver = "control", .tokens = "if ( item . description ) | desc | < text style = { S . desc } > { desc } < / text > " }, .{ .item = __yix_view_ctx.item, }, ui.view.lazyIfSome(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.item.peek().description);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .item = __yix_view_ctx.item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().description;
        } }.__yix_compute);
    }, .{ }, struct { fn __yix_b(__yix_b3_0: anytype, desc: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { _ = __yix_b3_0; return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "VStep/keyword_if:3/branch:0", .receiver = "text", .tokens = "text style = @static; desc  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . desc ", .kind = .style, .literal = null }, } }, .{ .desc = desc, }, ui.view.text(.{ .style = S.desc, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(desc), ""), .{ desc, }))) }); } }.__yix_b, null)),
            })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "VStep";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

/// Steps control: `W.Steps(.{ .items = &items, .current = step })`. Steps before
/// current are done; >= step count means all done. Horizontal: each step gets an equal
/// column; connector spans first circle center to last, done segment stops at the current
/// circle center. Vertical: one row per step, connector reaches next circle.
/// items/current can come from signals (reconcile by row key; state only changes
/// appearance).
pub fn Steps(args: anytype) ui.view.ComponentOf(__yix_Steps) {
    return ui.view.component(__yix_Steps, ui.reactive.props.coerce(StepsProps, args));
}
pub const StepsProps = struct {
    items: ui.Source([]const StepItem) = .{ .value = &.{} },
    current: ui.Source(usize) = .{ .value = 0 },
    direction: ui.Source(mod.StepsDirection) = .{ .value = .horizontal },
    check_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Steps;
    pub const __yix_preview_mount = __yix_Steps;
};
fn __yix_Steps(__yix_props: StepsProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = __yix_props.items;
    const current = __yix_props.current;
    const direction = __yix_props.direction;
    const checkIconAsset = __yix_props.check_icon_asset;
    try ui.view.previewCheckSetup(scope, true);
    const horizontal = __yix_d1: {
        const __yix_T = @TypeOf(direction.peek() == .horizontal);
        break :__yix_d1 try scope.derive(__yix_T, .{ .direction = direction, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal;
        } }.__yix_compute);
    };
    const count = __yix_d2: {
        const __yix_T = @TypeOf(items.peek().len);
        break :__yix_d2 try scope.derive(__yix_T, .{ .items = items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.items.get().len;
        } }.__yix_compute);
    };
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .items = items, .current = current, .direction = direction, .checkIconAsset = checkIconAsset, .horizontal = horizontal, .count = count, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps", .receiver = "box", .tokens = "box style = S . Container . of ( . { . horizontal = horizontal } ) ; a11y = . { . role = . list , . label = \"Steps\" } ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . Container . of ( . { . horizontal = horizontal } ) ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = ". { . role = . list , . label = \"Steps\" } ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .horizontal = __yix_view_ctx.horizontal, .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, .count = __yix_view_ctx.count, .current = __yix_view_ctx.current, .checkIconAsset = __yix_view_ctx.checkIconAsset, }, ui.view.box(.{ .style = S.Container.of(.{ .horizontal = __yix_view_ctx.horizontal }), .a11y = .{ .role = .list, .label = "Steps" }, }, .{
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps", .receiver = "control", .tokens = "if ( direction == . horizontal and items . len > 1 ) < box style = { S . track . of ( . { . steps = count } ) } / > " }, .{ .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, .count = __yix_view_ctx.count, }, ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.direction.peek() == .horizontal and __yix_view_ctx.items.peek().len > 1);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal and __yix_ctx.items.get().len > 1;
        } }.__yix_compute);
    }, .{ .count = __yix_view_ctx.count, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:1/branch:0", .receiver = "box", .tokens = "box style = S . track . of ( . { . steps = count } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . track . of ( . { . steps = count } ) ", .kind = .style, .literal = null }, } }, .{ .count = __yix_b1_0.count, }, ui.view.box(.{ .style = S.track.of(.{ .steps = __yix_b1_0.count }), }, .{ })) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps", .receiver = "control", .tokens = "if ( direction == . horizontal and items . len > 1 ) < box style = { S . progress . of ( . { . steps = count , . current = current } ) } / > " }, .{ .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, .count = __yix_view_ctx.count, .current = __yix_view_ctx.current, }, ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.direction.peek() == .horizontal and __yix_view_ctx.items.peek().len > 1);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .horizontal and __yix_ctx.items.get().len > 1;
        } }.__yix_compute);
    }, .{ .current = __yix_view_ctx.current, .count = __yix_view_ctx.count, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:2/branch:0", .receiver = "box", .tokens = "box style = S . progress . of ( . { . steps = count , . current = current } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . progress . of ( . { . steps = count , . current = current } ) ", .kind = .style, .literal = null }, } }, .{ .count = __yix_b2_0.count, .current = __yix_b2_0.current, }, ui.view.box(.{ .style = S.progress.of(.{ .steps = __yix_b2_0.count, .current = __yix_b2_0.current }), }, .{ })) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps", .receiver = "control", .tokens = "if ( horizontal ) for ( items ) | item , i | < HStep key = { rowKey ( item ) } { item } index = { i } { current } check = { checkIconAsset } / > " }, .{ .horizontal = __yix_view_ctx.horizontal, .items = __yix_view_ctx.items, .current = __yix_view_ctx.current, .checkIconAsset = __yix_view_ctx.checkIconAsset, }, ui.view.lazyIf(__yix_view_ctx.horizontal, .{ .items = __yix_view_ctx.items, .current = __yix_view_ctx.current, .checkIconAsset = __yix_view_ctx.checkIconAsset, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:3/branch:0", .receiver = "control", .tokens = "for ( items ) | item , i | < HStep key = { rowKey ( item ) } { item } index = { i } { current } check = { checkIconAsset } / > " }, .{ .items = __yix_b3_0.items, .current = __yix_b3_0.current, .checkIconAsset = __yix_b3_0.checkIconAsset, }, __yix_e4: { const __yix_items_4 = __yix_b3_0.items; break :__yix_e4 ui.view.eachWith(.{ .current = __yix_b3_0.current, .checkIconAsset = __yix_b3_0.checkIconAsset, }, __yix_items_4, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_4))) u64 { return ui.view.keyOf(rowKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_4))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:3/branch:0/keyword_for:4", .receiver = "HStep", .tokens = "< HStep key = { rowKey ( item ) } { item } index = { i } { current } check = { checkIconAsset } / > ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "rowKey ( item ) ", .kind = .property, .literal = null }, .{ .name = "item", .tokens = "item ", .kind = .property, .literal = null }, .{ .name = "index", .tokens = "i ", .kind = .property, .literal = null }, .{ .name = "current", .tokens = "current ", .kind = .property, .literal = null }, .{ .name = "check", .tokens = "checkIconAsset ", .kind = .property, .literal = null }, } }, .{ .item = item, .i = i, .current = __yix_row_1.current, .checkIconAsset = __yix_row_1.checkIconAsset, }, __yix_builder_38: { try ui.view.previewCheckBuilder(__yix_scope_1, HStep); break :__yix_builder_38 HStep(.{ .item = item, .index = i, .current = __yix_row_1.current, .check = __yix_row_1.checkIconAsset, }); })); } }.__yix_row); }) }); } }.__yix_b, null)),
            ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps", .receiver = "control", .tokens = "if ( direction == . vertical ) for ( items ) | item , i | < VStep key = { rowKey ( item ) } { item } index = { i } { current } { count } check = { checkIconAsset } / > " }, .{ .direction = __yix_view_ctx.direction, .items = __yix_view_ctx.items, .current = __yix_view_ctx.current, .count = __yix_view_ctx.count, .checkIconAsset = __yix_view_ctx.checkIconAsset, }, ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.direction.peek() == .vertical);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .direction = __yix_view_ctx.direction, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.direction.get() == .vertical;
        } }.__yix_compute);
    }, .{ .items = __yix_view_ctx.items, .current = __yix_view_ctx.current, .checkIconAsset = __yix_view_ctx.checkIconAsset, .count = __yix_view_ctx.count, }, struct { fn __yix_b(__yix_b5_0: anytype, __yix_bs5_0: *ui.Scope, __yix_bc5_0: *ui.Cx, __yix_bk5_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs5_0, __yix_bc5_0, __yix_bk5_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:5/branch:0", .receiver = "control", .tokens = "for ( items ) | item , i | < VStep key = { rowKey ( item ) } { item } index = { i } { current } { count } check = { checkIconAsset } / > " }, .{ .items = __yix_b5_0.items, .current = __yix_b5_0.current, .count = __yix_b5_0.count, .checkIconAsset = __yix_b5_0.checkIconAsset, }, __yix_e6: { const __yix_items_6 = __yix_b5_0.items; break :__yix_e6 ui.view.eachWith(.{ .current = __yix_b5_0.current, .checkIconAsset = __yix_b5_0.checkIconAsset, .count = __yix_b5_0.count, }, __yix_items_6, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_6))) u64 { return ui.view.keyOf(rowKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_6))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateSite(.{ .module = "src/ui/components/steps/steps.yix", .path = "Steps/keyword_if:5/branch:0/keyword_for:6", .receiver = "VStep", .tokens = "< VStep key = { rowKey ( item ) } { item } index = { i } { current } { count } check = { checkIconAsset } / > ", .literal_text = null, .attributes = &.{ .{ .name = "key", .tokens = "rowKey ( item ) ", .kind = .property, .literal = null }, .{ .name = "item", .tokens = "item ", .kind = .property, .literal = null }, .{ .name = "index", .tokens = "i ", .kind = .property, .literal = null }, .{ .name = "current", .tokens = "current ", .kind = .property, .literal = null }, .{ .name = "count", .tokens = "count ", .kind = .property, .literal = null }, .{ .name = "check", .tokens = "checkIconAsset ", .kind = .property, .literal = null }, } }, .{ .item = item, .i = i, .current = __yix_row_1.current, .count = __yix_row_1.count, .checkIconAsset = __yix_row_1.checkIconAsset, }, __yix_builder_50: { try ui.view.previewCheckBuilder(__yix_scope_1, VStep); break :__yix_builder_50 VStep(.{ .item = item, .index = i, .current = __yix_row_1.current, .count = __yix_row_1.count, .check = __yix_row_1.checkIconAsset, }); })); } }.__yix_row); }) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Steps";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x2f\x2f\x21\x20\x53\x74\x65\x70\x73\x20\x76\x69\x65\x77\x2e\x20\x53\x74\x79\x6c\x69\x6e\x67\x20\x69\x6e\x20\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x3b\x20\x70\x75\x62\x6c\x69\x63\x20\x74\x79\x70\x65\x73\x20\x61\x6e\x64\x20\x74\x65\x73\x74\x73\x20\x69\x6e\x20\x6d\x6f\x64\x2e\x7a\x69\x67\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x73\x74\x64\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x64\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x2e\x2e\x2f\x2e\x2e\x2f\x75\x69\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x6d\x6f\x64\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x6d\x6f\x64\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x20\x3d\x20\x6d\x6f\x64\x2e\x53\x74\x65\x70\x49\x74\x65\x6d\x3b\x0a\x0a\x2f\x2f\x2f\x20\x54\x65\x78\x74\x20\x69\x6e\x20\x63\x69\x72\x63\x6c\x65\x3a\x20\x64\x6f\x6e\x65\x20\x69\x73\x20\x22\x76\x22\x2c\x20\x6f\x74\x68\x65\x72\x77\x69\x73\x65\x20\x6e\x75\x6d\x62\x65\x72\x20\x28\x73\x74\x61\x72\x74\x69\x6e\x67\x20\x66\x72\x6f\x6d\x20\x31\x29\x0a\x63\x6f\x6e\x73\x74\x20\x43\x69\x72\x63\x6c\x65\x4c\x61\x62\x65\x6c\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x2c\x0a\x20\x20\x20\x20\x6e\x3a\x20\x75\x73\x69\x7a\x65\x2c\x0a\x20\x20\x20\x20\x70\x75\x62\x20\x66\x6e\x20\x66\x6f\x72\x6d\x61\x74\x28\x73\x65\x6c\x66\x3a\x20\x43\x69\x72\x63\x6c\x65\x4c\x61\x62\x65\x6c\x2c\x20\x77\x3a\x20\x2a\x73\x74\x64\x2e\x49\x6f\x2e\x57\x72\x69\x74\x65\x72\x29\x20\x73\x74\x64\x2e\x49\x6f\x2e\x57\x72\x69\x74\x65\x72\x2e\x45\x72\x72\x6f\x72\x21\x76\x6f\x69\x64\x20\x7b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x69\x66\x20\x28\x73\x65\x6c\x66\x2e\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x29\x20\x72\x65\x74\x75\x72\x6e\x20\x77\x2e\x77\x72\x69\x74\x65\x41\x6c\x6c\x28\x22\x76\x22\x29\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x74\x72\x79\x20\x77\x2e\x70\x72\x69\x6e\x74\x28\x22\x7b\x64\x7d\x22\x2c\x20\x2e\x7b\x73\x65\x6c\x66\x2e\x6e\x7d\x29\x3b\x0a\x20\x20\x20\x20\x7d\x0a\x7d\x3b\x0a\x0a\x2f\x2f\x2f\x20\x43\x69\x72\x63\x6c\x65\x20\x64\x69\x73\x70\x6c\x61\x79\x73\x20\x6e\x75\x6d\x62\x65\x72\x20\x2f\x20\x63\x68\x65\x63\x6b\x6d\x61\x72\x6b\x2c\x20\x70\x75\x72\x65\x6c\x79\x20\x76\x69\x73\x75\x61\x6c\x20\x73\x69\x67\x6e\x61\x6c\x73\x3a\x20\x65\x78\x70\x6c\x69\x63\x69\x74\x6c\x79\x20\x73\x74\x61\x74\x65\x20\x74\x68\x72\x65\x65\x0a\x2f\x2f\x2f\x20\x73\x74\x61\x74\x65\x73\x20\x2d\x2d\x20\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x20\x73\x74\x65\x70\x20\x28\x22\x79\x6f\x75\x20\x61\x72\x65\x20\x68\x65\x72\x65\x22\x29\x2c\x20\x63\x68\x65\x63\x6b\x65\x64\x20\x3d\x20\x64\x6f\x6e\x65\x2c\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x3d\x20\x6e\x6f\x74\x0a\x2f\x2f\x2f\x20\x79\x65\x74\x20\x72\x65\x61\x63\x68\x65\x64\x2e\x0a\x66\x6e\x20\x61\x31\x31\x79\x4f\x66\x28\x69\x74\x65\x6d\x3a\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x2c\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x2c\x20\x61\x63\x74\x69\x76\x65\x3a\x20\x62\x6f\x6f\x6c\x29\x20\x75\x69\x2e\x41\x31\x31\x79\x50\x72\x6f\x70\x73\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x6c\x69\x73\x74\x69\x74\x65\x6d\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x2c\x20\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x20\x3d\x20\x69\x74\x65\x6d\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x2c\x20\x2e\x73\x65\x6c\x65\x63\x74\x65\x64\x20\x3d\x20\x61\x63\x74\x69\x76\x65\x2c\x20\x2e\x63\x68\x65\x63\x6b\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x2c\x20\x2e\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x3d\x20\x21\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x61\x6e\x64\x20\x21\x61\x63\x74\x69\x76\x65\x20\x7d\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x52\x6f\x77\x20\x6b\x65\x79\x3a\x20\x63\x6f\x6e\x74\x65\x6e\x74\x20\x2b\x20\x62\x6f\x72\x72\x6f\x77\x20\x73\x74\x72\x69\x6e\x67\x20\x61\x64\x64\x72\x65\x73\x73\x20\x28\x72\x6f\x77\x20\x62\x6f\x72\x72\x6f\x77\x73\x20\x74\x69\x74\x6c\x65\x20\x2f\x20\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x29\x0a\x66\x6e\x20\x72\x6f\x77\x4b\x65\x79\x28\x69\x74\x3a\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x29\x20\x75\x36\x34\x20\x7b\x0a\x20\x20\x20\x20\x76\x61\x72\x20\x68\x20\x3d\x20\x73\x74\x64\x2e\x68\x61\x73\x68\x2e\x57\x79\x68\x61\x73\x68\x2e\x69\x6e\x69\x74\x28\x30\x29\x3b\x0a\x20\x20\x20\x20\x66\x6f\x72\x20\x28\x5b\x5f\x5d\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x7b\x20\x69\x74\x2e\x74\x69\x74\x6c\x65\x2c\x20\x69\x74\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x20\x7d\x29\x20\x7c\x66\x69\x65\x6c\x64\x7c\x20\x7b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x66\x20\x3d\x20\x66\x69\x65\x6c\x64\x20\x6f\x72\x65\x6c\x73\x65\x20\x22\x22\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x68\x2e\x75\x70\x64\x61\x74\x65\x28\x26\x5b\x5f\x5d\x75\x38\x7b\x40\x69\x6e\x74\x46\x72\x6f\x6d\x42\x6f\x6f\x6c\x28\x66\x69\x65\x6c\x64\x20\x21\x3d\x20\x6e\x75\x6c\x6c\x29\x7d\x29\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x68\x2e\x75\x70\x64\x61\x74\x65\x28\x73\x74\x64\x2e\x6d\x65\x6d\x2e\x61\x73\x42\x79\x74\x65\x73\x28\x26\x66\x2e\x6c\x65\x6e\x29\x29\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x68\x2e\x75\x70\x64\x61\x74\x65\x28\x66\x29\x3b\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x68\x2e\x75\x70\x64\x61\x74\x65\x28\x73\x74\x64\x2e\x6d\x65\x6d\x2e\x61\x73\x42\x79\x74\x65\x73\x28\x26\x40\x69\x6e\x74\x46\x72\x6f\x6d\x50\x74\x72\x28\x66\x2e\x70\x74\x72\x29\x29\x29\x3b\x0a\x20\x20\x20\x20\x7d\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x68\x2e\x66\x69\x6e\x61\x6c\x28\x29\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x20\x4e\x75\x6d\x62\x65\x72\x20\x63\x69\x72\x63\x6c\x65\x73\x20\x72\x65\x74\x61\x69\x6e\x20\x74\x68\x65\x69\x72\x20\x6f\x77\x6e\x20\x74\x65\x78\x74\x20\x41\x50\x49\x2e\x20\x6e\x75\x6d\x5f\x62\x6f\x78\x20\x73\x75\x70\x70\x6c\x69\x65\x73\x20\x74\x68\x65\x20\x65\x78\x70\x6c\x69\x63\x69\x74\x0a\x2f\x2f\x20\x76\x65\x72\x74\x69\x63\x61\x6c\x20\x6c\x69\x6e\x65\x20\x69\x6e\x73\x65\x74\x3b\x20\x69\x63\x6f\x6e\x20\x63\x69\x72\x63\x6c\x65\x73\x20\x75\x73\x65\x20\x74\x68\x65\x69\x72\x20\x66\x6c\x65\x78\x20\x63\x65\x6e\x74\x65\x72\x69\x6e\x67\x2e\x0a\x0a\x2f\x2f\x2f\x20\x48\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x73\x74\x65\x70\x3a\x20\x65\x71\x75\x61\x6c\x2d\x77\x69\x64\x74\x68\x20\x63\x6f\x6c\x75\x6d\x6e\x20\x28\x63\x69\x72\x63\x6c\x65\x20\x2b\x20\x74\x69\x74\x6c\x65\x20\x2b\x20\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x29\x0a\x66\x6e\x20\x48\x53\x74\x65\x70\x28\x69\x74\x65\x6d\x3a\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x2c\x20\x69\x6e\x64\x65\x78\x3a\x20\x75\x73\x69\x7a\x65\x2c\x20\x63\x75\x72\x72\x65\x6e\x74\x3a\x20\x75\x73\x69\x7a\x65\x2c\x20\x63\x68\x65\x63\x6b\x3a\x20\x3f\x75\x69\x2e\x53\x76\x67\x41\x73\x73\x65\x74\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x61\x63\x74\x69\x76\x65\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x6e\x64\x65\x78\x20\x3d\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x70\x20\x3d\x20\x70\x61\x72\x74\x73\x28\x53\x2e\x53\x74\x65\x70\x2c\x20\x2e\x7b\x20\x2e\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x2c\x20\x2e\x61\x63\x74\x69\x76\x65\x20\x3d\x20\x61\x63\x74\x69\x76\x65\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x73\x65\x6d\x61\x6e\x74\x69\x63\x73\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x61\x31\x31\x79\x4f\x66\x28\x69\x74\x65\x6d\x2c\x20\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x2c\x20\x69\x6e\x64\x65\x78\x20\x3d\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x6c\x61\x62\x65\x6c\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x43\x69\x72\x63\x6c\x65\x4c\x61\x62\x65\x6c\x7b\x20\x2e\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x2c\x20\x2e\x6e\x20\x3d\x20\x69\x6e\x64\x65\x78\x20\x2b\x20\x31\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x69\x63\x6f\x6e\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x66\x20\x28\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x20\x63\x68\x65\x63\x6b\x20\x65\x6c\x73\x65\x20\x6e\x75\x6c\x6c\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x68\x5f\x73\x74\x65\x70\x7d\x20\x61\x31\x31\x79\x3d\x7b\x73\x65\x6d\x61\x6e\x74\x69\x63\x73\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x63\x6f\x6e\x29\x20\x7c\x61\x73\x73\x65\x74\x7c\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x63\x69\x72\x63\x6c\x65\x7d\x3e\x3c\x69\x63\x6f\x6e\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x69\x63\x6f\x6e\x7d\x20\x73\x72\x63\x3d\x7b\x61\x73\x73\x65\x74\x7d\x20\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x6e\x75\x6d\x7d\x20\x62\x6f\x78\x3d\x7b\x2e\x7b\x20\x70\x2e\x63\x69\x72\x63\x6c\x65\x2c\x20\x53\x2e\x6e\x75\x6d\x5f\x62\x6f\x78\x20\x7d\x7d\x3e\x7b\x6c\x61\x62\x65\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x74\x69\x74\x6c\x65\x7d\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x74\x65\x6d\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x29\x20\x7c\x64\x65\x73\x63\x7c\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x64\x65\x73\x63\x7d\x3e\x7b\x64\x65\x73\x63\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x56\x65\x72\x74\x69\x63\x61\x6c\x20\x73\x74\x65\x70\x3a\x20\x69\x6e\x64\x69\x63\x61\x74\x6f\x72\x20\x63\x6f\x6c\x75\x6d\x6e\x20\x28\x63\x69\x72\x63\x6c\x65\x20\x2b\x20\x63\x6f\x6e\x6e\x65\x63\x74\x6f\x72\x20\x74\x6f\x20\x6e\x65\x78\x74\x20\x73\x74\x65\x70\x29\x20\x2b\x20\x74\x65\x78\x74\x20\x63\x6f\x6c\x75\x6d\x6e\x0a\x66\x6e\x20\x56\x53\x74\x65\x70\x28\x69\x74\x65\x6d\x3a\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x2c\x20\x69\x6e\x64\x65\x78\x3a\x20\x75\x73\x69\x7a\x65\x2c\x20\x63\x75\x72\x72\x65\x6e\x74\x3a\x20\x75\x73\x69\x7a\x65\x2c\x20\x63\x6f\x75\x6e\x74\x3a\x20\x75\x73\x69\x7a\x65\x2c\x20\x63\x68\x65\x63\x6b\x3a\x20\x3f\x75\x69\x2e\x53\x76\x67\x41\x73\x73\x65\x74\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x61\x63\x74\x69\x76\x65\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x6e\x64\x65\x78\x20\x3d\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x70\x20\x3d\x20\x70\x61\x72\x74\x73\x28\x53\x2e\x53\x74\x65\x70\x2c\x20\x2e\x7b\x20\x2e\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x2c\x20\x2e\x61\x63\x74\x69\x76\x65\x20\x3d\x20\x61\x63\x74\x69\x76\x65\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x73\x65\x6d\x61\x6e\x74\x69\x63\x73\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x61\x31\x31\x79\x4f\x66\x28\x69\x74\x65\x6d\x2c\x20\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x2c\x20\x69\x6e\x64\x65\x78\x20\x3d\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x6c\x61\x62\x65\x6c\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x43\x69\x72\x63\x6c\x65\x4c\x61\x62\x65\x6c\x7b\x20\x2e\x63\x6f\x6d\x70\x6c\x65\x74\x65\x64\x20\x3d\x20\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x2c\x20\x2e\x6e\x20\x3d\x20\x69\x6e\x64\x65\x78\x20\x2b\x20\x31\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x69\x63\x6f\x6e\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x66\x20\x28\x69\x6e\x64\x65\x78\x20\x3c\x20\x63\x75\x72\x72\x65\x6e\x74\x29\x20\x63\x68\x65\x63\x6b\x20\x65\x6c\x73\x65\x20\x6e\x75\x6c\x6c\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x76\x5f\x73\x74\x65\x70\x7d\x20\x61\x31\x31\x79\x3d\x7b\x73\x65\x6d\x61\x6e\x74\x69\x63\x73\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x76\x49\x6e\x64\x69\x63\x61\x74\x6f\x72\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x63\x6f\x6e\x29\x20\x7c\x61\x73\x73\x65\x74\x7c\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x63\x69\x72\x63\x6c\x65\x7d\x3e\x3c\x69\x63\x6f\x6e\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x69\x63\x6f\x6e\x7d\x20\x73\x72\x63\x3d\x7b\x61\x73\x73\x65\x74\x7d\x20\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x20\x65\x6c\x73\x65\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x6e\x75\x6d\x7d\x20\x62\x6f\x78\x3d\x7b\x2e\x7b\x20\x70\x2e\x63\x69\x72\x63\x6c\x65\x2c\x20\x53\x2e\x6e\x75\x6d\x5f\x62\x6f\x78\x20\x7d\x7d\x3e\x7b\x6c\x61\x62\x65\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x6e\x64\x65\x78\x20\x2b\x20\x31\x20\x3c\x20\x63\x6f\x75\x6e\x74\x29\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x63\x6f\x6e\x6e\x65\x63\x74\x6f\x72\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x76\x54\x65\x78\x74\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x74\x69\x74\x6c\x65\x7d\x3e\x7b\x69\x74\x65\x6d\x2e\x74\x69\x74\x6c\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x74\x65\x6d\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x29\x20\x7c\x64\x65\x73\x63\x7c\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x64\x65\x73\x63\x7d\x3e\x7b\x64\x65\x73\x63\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x53\x74\x65\x70\x73\x20\x63\x6f\x6e\x74\x72\x6f\x6c\x3a\x20\x60\x57\x2e\x53\x74\x65\x70\x73\x28\x2e\x7b\x20\x2e\x69\x74\x65\x6d\x73\x20\x3d\x20\x26\x69\x74\x65\x6d\x73\x2c\x20\x2e\x63\x75\x72\x72\x65\x6e\x74\x20\x3d\x20\x73\x74\x65\x70\x20\x7d\x29\x60\x2e\x20\x53\x74\x65\x70\x73\x20\x62\x65\x66\x6f\x72\x65\x0a\x2f\x2f\x2f\x20\x63\x75\x72\x72\x65\x6e\x74\x20\x61\x72\x65\x20\x64\x6f\x6e\x65\x3b\x20\x3e\x3d\x20\x73\x74\x65\x70\x20\x63\x6f\x75\x6e\x74\x20\x6d\x65\x61\x6e\x73\x20\x61\x6c\x6c\x20\x64\x6f\x6e\x65\x2e\x20\x48\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x3a\x20\x65\x61\x63\x68\x20\x73\x74\x65\x70\x20\x67\x65\x74\x73\x20\x61\x6e\x20\x65\x71\x75\x61\x6c\x0a\x2f\x2f\x2f\x20\x63\x6f\x6c\x75\x6d\x6e\x3b\x20\x63\x6f\x6e\x6e\x65\x63\x74\x6f\x72\x20\x73\x70\x61\x6e\x73\x20\x66\x69\x72\x73\x74\x20\x63\x69\x72\x63\x6c\x65\x20\x63\x65\x6e\x74\x65\x72\x20\x74\x6f\x20\x6c\x61\x73\x74\x2c\x20\x64\x6f\x6e\x65\x20\x73\x65\x67\x6d\x65\x6e\x74\x20\x73\x74\x6f\x70\x73\x20\x61\x74\x20\x74\x68\x65\x20\x63\x75\x72\x72\x65\x6e\x74\x0a\x2f\x2f\x2f\x20\x63\x69\x72\x63\x6c\x65\x20\x63\x65\x6e\x74\x65\x72\x2e\x20\x56\x65\x72\x74\x69\x63\x61\x6c\x3a\x20\x6f\x6e\x65\x20\x72\x6f\x77\x20\x70\x65\x72\x20\x73\x74\x65\x70\x2c\x20\x63\x6f\x6e\x6e\x65\x63\x74\x6f\x72\x20\x72\x65\x61\x63\x68\x65\x73\x20\x6e\x65\x78\x74\x20\x63\x69\x72\x63\x6c\x65\x2e\x0a\x2f\x2f\x2f\x20\x69\x74\x65\x6d\x73\x2f\x63\x75\x72\x72\x65\x6e\x74\x20\x63\x61\x6e\x20\x63\x6f\x6d\x65\x20\x66\x72\x6f\x6d\x20\x73\x69\x67\x6e\x61\x6c\x73\x20\x28\x72\x65\x63\x6f\x6e\x63\x69\x6c\x65\x20\x62\x79\x20\x72\x6f\x77\x20\x6b\x65\x79\x3b\x20\x73\x74\x61\x74\x65\x20\x6f\x6e\x6c\x79\x20\x63\x68\x61\x6e\x67\x65\x73\x0a\x2f\x2f\x2f\x20\x61\x70\x70\x65\x61\x72\x61\x6e\x63\x65\x29\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x74\x65\x70\x73\x28\x69\x74\x65\x6d\x73\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x53\x74\x65\x70\x49\x74\x65\x6d\x20\x3d\x20\x26\x2e\x7b\x7d\x2c\x20\x63\x75\x72\x72\x65\x6e\x74\x3a\x20\x75\x73\x69\x7a\x65\x20\x3d\x20\x30\x2c\x20\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x3a\x20\x6d\x6f\x64\x2e\x53\x74\x65\x70\x73\x44\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x20\x2e\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x2c\x20\x63\x68\x65\x63\x6b\x49\x63\x6f\x6e\x41\x73\x73\x65\x74\x3a\x20\x3f\x75\x69\x2e\x53\x76\x67\x41\x73\x73\x65\x74\x20\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x3d\x20\x2e\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x63\x6f\x75\x6e\x74\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x69\x74\x65\x6d\x73\x2e\x6c\x65\x6e\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x43\x6f\x6e\x74\x61\x69\x6e\x65\x72\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x3d\x20\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x7d\x29\x7d\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x6c\x69\x73\x74\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x22\x53\x74\x65\x70\x73\x22\x20\x7d\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x3d\x20\x2e\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x61\x6e\x64\x20\x69\x74\x65\x6d\x73\x2e\x6c\x65\x6e\x20\x3e\x20\x31\x29\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x74\x72\x61\x63\x6b\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x73\x74\x65\x70\x73\x20\x3d\x20\x63\x6f\x75\x6e\x74\x20\x7d\x29\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x3d\x20\x2e\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x20\x61\x6e\x64\x20\x69\x74\x65\x6d\x73\x2e\x6c\x65\x6e\x20\x3e\x20\x31\x29\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x70\x72\x6f\x67\x72\x65\x73\x73\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x73\x74\x65\x70\x73\x20\x3d\x20\x63\x6f\x75\x6e\x74\x2c\x20\x2e\x63\x75\x72\x72\x65\x6e\x74\x20\x3d\x20\x63\x75\x72\x72\x65\x6e\x74\x20\x7d\x29\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x68\x6f\x72\x69\x7a\x6f\x6e\x74\x61\x6c\x29\x20\x66\x6f\x72\x20\x28\x69\x74\x65\x6d\x73\x29\x20\x7c\x69\x74\x65\x6d\x2c\x20\x69\x7c\x20\x3c\x48\x53\x74\x65\x70\x20\x6b\x65\x79\x3d\x7b\x72\x6f\x77\x4b\x65\x79\x28\x69\x74\x65\x6d\x29\x7d\x20\x7b\x69\x74\x65\x6d\x7d\x20\x69\x6e\x64\x65\x78\x3d\x7b\x69\x7d\x20\x7b\x63\x75\x72\x72\x65\x6e\x74\x7d\x20\x63\x68\x65\x63\x6b\x3d\x7b\x63\x68\x65\x63\x6b\x49\x63\x6f\x6e\x41\x73\x73\x65\x74\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x64\x69\x72\x65\x63\x74\x69\x6f\x6e\x20\x3d\x3d\x20\x2e\x76\x65\x72\x74\x69\x63\x61\x6c\x29\x20\x66\x6f\x72\x20\x28\x69\x74\x65\x6d\x73\x29\x20\x7c\x69\x74\x65\x6d\x2c\x20\x69\x7c\x20\x3c\x56\x53\x74\x65\x70\x20\x6b\x65\x79\x3d\x7b\x72\x6f\x77\x4b\x65\x79\x28\x69\x74\x65\x6d\x29\x7d\x20\x7b\x69\x74\x65\x6d\x7d\x20\x69\x6e\x64\x65\x78\x3d\x7b\x69\x7d\x20\x7b\x63\x75\x72\x72\x65\x6e\x74\x7d\x20\x7b\x63\x6f\x75\x6e\x74\x7d\x20\x63\x68\x65\x63\x6b\x3d\x7b\x63\x68\x65\x63\x6b\x49\x63\x6f\x6e\x41\x73\x73\x65\x74\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x62\x6f\x78\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, .@"StepItem " = StepItem, }) else void;

//# yix-map-data [[1648,1643],[10862,2602],[22829,4125]]

//# yix-map steps.yix
