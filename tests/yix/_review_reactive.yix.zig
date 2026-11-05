// GENERATED FILE, do not edit: generated from review_reactive.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");
pub var store: ?*ui.Signal(i32) = null;
fn readStore() i32 { return store.?.get(); }
fn peekStore() i32 { return store.?.peek(); }
fn storeSource() *ui.Signal(i32) { return store.?; }
fn twice(x: i32) i32 { return x * 2; }
pub fn ExternalOnly(args: anytype) ui.view.ComponentOf(__yix_ExternalOnly) {
    return ui.view.component(__yix_ExternalOnly, ui.reactive.props.coerce(ExternalOnlyProps, args));
}
pub const ExternalOnlyProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ExternalOnly;
    pub const __yix_preview_mount = __yix_ExternalOnly;
};
fn __yix_ExternalOnly(__yix_props: ExternalOnlyProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "ExternalOnly", .receiver = "text", .tokens = "text readStore ( )  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(readStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() else __yix_d1: {
        const __yix_T = @TypeOf(readStore());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(readStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() else __yix_d1: {
        const __yix_T = @TypeOf(readStore());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore();
        } }.__yix_compute);
    };
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ExternalOnly";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ExternalWithProp(args: anytype) ui.view.ComponentOf(__yix_ExternalWithProp) {
    return ui.view.component(__yix_ExternalWithProp, ui.reactive.props.coerce(ExternalWithPropProps, args));
}
pub const ExternalWithPropProps = struct {
    n: ui.Source(i32) = .{ .value = 0 },
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ExternalWithProp;
    pub const __yix_preview_mount = __yix_ExternalWithProp;
};
fn __yix_ExternalWithProp(__yix_props: ExternalWithPropProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const n = __yix_props.n;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .n = n, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "ExternalWithProp", .receiver = "text", .tokens = "text readStore ( ) + n  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .n = __yix_view_ctx.n, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(readStore() + __yix_view_ctx.n.peek());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .n = __yix_view_ctx.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return readStore() + __yix_ctx.n.get();
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(readStore() + __yix_view_ctx.n.peek());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .n = __yix_view_ctx.n, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return readStore() + __yix_ctx.n.get();
        } }.__yix_compute);
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ExternalWithProp";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn PeekOnly(args: anytype) ui.view.ComponentOf(__yix_PeekOnly) {
    return ui.view.component(__yix_PeekOnly, ui.reactive.props.coerce(PeekOnlyProps, args));
}
pub const PeekOnlyProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = PeekOnly;
    pub const __yix_preview_mount = __yix_PeekOnly;
};
fn __yix_PeekOnly(__yix_props: PeekOnlyProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "PeekOnly", .receiver = "text", .tokens = "text peekStore ( )  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(peekStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) peekStore() else __yix_d1: {
        const __yix_T = @TypeOf(peekStore());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return peekStore();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(peekStore());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) peekStore() else __yix_d1: {
        const __yix_T = @TypeOf(peekStore());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return peekStore();
        } }.__yix_compute);
    };
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "PeekOnly";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ReturnedSource(args: anytype) ui.view.ComponentOf(__yix_ReturnedSource) {
    return ui.view.component(__yix_ReturnedSource, ui.reactive.props.coerce(ReturnedSourceProps, args));
}
pub const ReturnedSourceProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ReturnedSource;
    pub const __yix_preview_mount = __yix_ReturnedSource;
};
fn __yix_ReturnedSource(__yix_props: ReturnedSourceProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "ReturnedSource", .receiver = "text", .tokens = "text storeSource ( )  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(storeSource());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) storeSource() else __yix_d1: {
        const __yix_T = @TypeOf(storeSource());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return storeSource();
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(storeSource());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) storeSource() else __yix_d1: {
        const __yix_T = @TypeOf(storeSource());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return storeSource();
        } }.__yix_compute);
    };
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ReturnedSource";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn Pure(args: anytype) ui.view.ComponentOf(__yix_Pure) {
    return ui.view.component(__yix_Pure, ui.reactive.props.coerce(PureProps, args));
}
pub const PureProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = Pure;
    pub const __yix_preview_mount = __yix_Pure;
};
fn __yix_Pure(__yix_props: PureProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "Pure", .receiver = "text", .tokens = "text twice ( 4 )  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_call2: {
        const __yix_Raw = @TypeOf(twice(4));
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) twice(4) else __yix_d1: {
        const __yix_T = @TypeOf(twice(4));
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return twice(4);
        } }.__yix_compute);
    };
    }), ""), .{ __yix_call2: {
        const __yix_Raw = @TypeOf(twice(4));
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) twice(4) else __yix_d1: {
        const __yix_T = @TypeOf(twice(4));
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return twice(4);
        } }.__yix_compute);
    };
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "Pure";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ExternalVisible(args: anytype) ui.view.ComponentOf(__yix_ExternalVisible) {
    return ui.view.component(__yix_ExternalVisible, ui.reactive.props.coerce(ExternalVisibleProps, args));
}
pub const ExternalVisibleProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ExternalVisible;
    pub const __yix_preview_mount = __yix_ExternalVisible;
};
fn __yix_ExternalVisible(__yix_props: ExternalVisibleProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "ExternalVisible", .receiver = "box", .tokens = "box visible = readStore ( ) > 0 ; ", .literal_text = null, .attributes = &.{ .{ .name = "visible", .tokens = "readStore ( ) > 0 ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ .visible = __yix_call2: {
        const __yix_Raw = @TypeOf(readStore() > 0);
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readStore() > 0 else __yix_d1: {
        const __yix_T = @TypeOf(readStore() > 0);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readStore() > 0;
        } }.__yix_compute);
    };
    }, }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ExternalVisible";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
fn nullValue() @TypeOf(null) { return null; }
fn NullReceiver(args: anytype) @TypeOf(ui.view.text(.{}, "nil")) {
    return ui.view.text(.{}, if (args.value == null) "nil" else "set");
}
const TypeConfig = struct { T: type };
fn typeConfig() TypeConfig { return .{ .T = i32 }; }
fn TypeReceiver(args: anytype) @TypeOf(ui.view.text(.{}, "i32")) {
    return ui.view.text(.{}, @typeName(args.config.T));
}
pub fn NullCall(args: anytype) ui.view.ComponentOf(__yix_NullCall) {
    return ui.view.component(__yix_NullCall, ui.reactive.props.coerce(NullCallProps, args));
}
pub const NullCallProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = NullCall;
    pub const __yix_preview_mount = __yix_NullCall;
};
fn __yix_NullCall(__yix_props: NullCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "NullCall", .receiver = "NullReceiver", .tokens = "< NullReceiver value = { nullValue ( ) } / > ", .literal_text = null, .attributes = &.{ .{ .name = "value", .tokens = "nullValue ( ) ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_1098: { try ui.view.previewCheckBuilder(__yix_view_scope, NullReceiver); break :__yix_builder_1098 NullReceiver(.{ .value = __yix_call2: {
        const __yix_Raw = @TypeOf(nullValue());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) nullValue() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(NullReceiver, "value")) |__yix_A| __yix_A else @TypeOf(nullValue());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return nullValue();
        } }.__yix_compute);
    };
    }, }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "NullCall";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn ComptimeStructCall(args: anytype) ui.view.ComponentOf(__yix_ComptimeStructCall) {
    return ui.view.component(__yix_ComptimeStructCall, ui.reactive.props.coerce(ComptimeStructCallProps, args));
}
pub const ComptimeStructCallProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = ComptimeStructCall;
    pub const __yix_preview_mount = __yix_ComptimeStructCall;
};
fn __yix_ComptimeStructCall(__yix_props: ComptimeStructCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "ComptimeStructCall", .receiver = "TypeReceiver", .tokens = "< TypeReceiver config = { typeConfig ( ) } / > ", .literal_text = null, .attributes = &.{ .{ .name = "config", .tokens = "typeConfig ( ) ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_1180: { try ui.view.previewCheckBuilder(__yix_view_scope, TypeReceiver); break :__yix_builder_1180 TypeReceiver(.{ .config = __yix_call2: {
        const __yix_Raw = @TypeOf(typeConfig());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) typeConfig() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(TypeReceiver, "config")) |__yix_A| __yix_A else @TypeOf(typeConfig());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return typeConfig();
        } }.__yix_compute);
    };
    }, }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "ComptimeStructCall";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
const reviewRecipe = ui.cva(.{ .base = .{ .gap = @as(f32, 7) } });
pub fn StaticRecipeCall(args: anytype) ui.view.ComponentOf(__yix_StaticRecipeCall) {
    return ui.view.component(__yix_StaticRecipeCall, ui.reactive.props.coerce(StaticRecipeCallProps, args));
}
pub const StaticRecipeCallProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = StaticRecipeCall;
    pub const __yix_preview_mount = __yix_StaticRecipeCall;
};
fn __yix_StaticRecipeCall(__yix_props: StaticRecipeCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "StaticRecipeCall", .receiver = "box", .tokens = "box style = reviewRecipe . of ( . { } ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "reviewRecipe . of ( . { } ) ", .kind = .style, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ .style = reviewRecipe.of(.{}), }, .{ })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "StaticRecipeCall";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
const MixedConfig = struct { comptime T: type = i32, value: i32 };
fn readMixed() MixedConfig { return .{ .value = readStore() }; }
fn MixedReceiver(args: anytype) ui.view.ComponentOf(__yix_MixedReceiver) {
    return ui.view.component(__yix_MixedReceiver, ui.reactive.props.coerce(MixedReceiverProps, args));
}
const MixedReceiverProps = struct {
    config: ui.Source(MixedConfig),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = MixedReceiver;
    pub const __yix_preview_mount = __yix_MixedReceiver;
};
fn __yix_MixedReceiver(__yix_props: MixedReceiverProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const config = __yix_props.config;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .config = config, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "MixedReceiver", .receiver = "text", .tokens = "text config . value  @interpolation ", .literal_text = null, .attributes = &.{ }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .config = __yix_view_ctx.config, }, ui.view.text(.{ }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.config.peek().value);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .config = __yix_view_ctx.config, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.config.get().value;
        } }.__yix_compute);
    }), ""), .{ __yix_d1: {
        const __yix_T = @TypeOf(__yix_view_ctx.config.peek().value);
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ .config = __yix_view_ctx.config, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.config.get().value;
        } }.__yix_compute);
    }, }))));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "MixedReceiver";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}
pub fn MixedRuntimeCall(args: anytype) ui.view.ComponentOf(__yix_MixedRuntimeCall) {
    return ui.view.component(__yix_MixedRuntimeCall, ui.reactive.props.coerce(MixedRuntimeCallProps, args));
}
pub const MixedRuntimeCallProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = MixedRuntimeCall;
    pub const __yix_preview_mount = __yix_MixedRuntimeCall;
};
fn __yix_MixedRuntimeCall(__yix_props: MixedRuntimeCallProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "tests/yix/review_reactive.yix", .path = "MixedRuntimeCall", .receiver = "MixedReceiver", .tokens = "< MixedReceiver config = { readMixed ( ) } / > ", .literal_text = null, .attributes = &.{ .{ .name = "config", .tokens = "readMixed ( ) ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, __yix_builder_1624: { try ui.view.previewCheckBuilder(__yix_view_scope, MixedReceiver); break :__yix_builder_1624 MixedReceiver(.{ .config = __yix_call2: {
        const __yix_Raw = @TypeOf(readMixed());
        break :__yix_call2 if (comptime !ui.view.yixCallMayDerive(__yix_Raw)) readMixed() else __yix_d1: {
        const __yix_T = if (ui.view.attrType(MixedReceiver, "config")) |__yix_A| __yix_A else @TypeOf(readMixed());
        break :__yix_d1 try __yix_view_scope.derive(__yix_T, .{ }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            _ = __yix_ctx;
            return readMixed();
        } }.__yix_compute);
    };
    }, }); }));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "MixedRuntimeCall";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x75\x69\x22\x29\x3b\x0a\x70\x75\x62\x20\x76\x61\x72\x20\x73\x74\x6f\x72\x65\x3a\x20\x3f\x2a\x75\x69\x2e\x53\x69\x67\x6e\x61\x6c\x28\x69\x33\x32\x29\x20\x3d\x20\x6e\x75\x6c\x6c\x3b\x0a\x66\x6e\x20\x72\x65\x61\x64\x53\x74\x6f\x72\x65\x28\x29\x20\x69\x33\x32\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x73\x74\x6f\x72\x65\x2e\x3f\x2e\x67\x65\x74\x28\x29\x3b\x20\x7d\x0a\x66\x6e\x20\x70\x65\x65\x6b\x53\x74\x6f\x72\x65\x28\x29\x20\x69\x33\x32\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x73\x74\x6f\x72\x65\x2e\x3f\x2e\x70\x65\x65\x6b\x28\x29\x3b\x20\x7d\x0a\x66\x6e\x20\x73\x74\x6f\x72\x65\x53\x6f\x75\x72\x63\x65\x28\x29\x20\x2a\x75\x69\x2e\x53\x69\x67\x6e\x61\x6c\x28\x69\x33\x32\x29\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x73\x74\x6f\x72\x65\x2e\x3f\x3b\x20\x7d\x0a\x66\x6e\x20\x74\x77\x69\x63\x65\x28\x78\x3a\x20\x69\x33\x32\x29\x20\x69\x33\x32\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x78\x20\x2a\x20\x32\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x78\x74\x65\x72\x6e\x61\x6c\x4f\x6e\x6c\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x72\x65\x61\x64\x53\x74\x6f\x72\x65\x28\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x78\x74\x65\x72\x6e\x61\x6c\x57\x69\x74\x68\x50\x72\x6f\x70\x28\x6e\x3a\x20\x69\x33\x32\x20\x3d\x20\x30\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x72\x65\x61\x64\x53\x74\x6f\x72\x65\x28\x29\x20\x2b\x20\x6e\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x65\x65\x6b\x4f\x6e\x6c\x79\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x70\x65\x65\x6b\x53\x74\x6f\x72\x65\x28\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x52\x65\x74\x75\x72\x6e\x65\x64\x53\x6f\x75\x72\x63\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x73\x74\x6f\x72\x65\x53\x6f\x75\x72\x63\x65\x28\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x50\x75\x72\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x74\x77\x69\x63\x65\x28\x34\x29\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x45\x78\x74\x65\x72\x6e\x61\x6c\x56\x69\x73\x69\x62\x6c\x65\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x76\x69\x73\x69\x62\x6c\x65\x3d\x7b\x72\x65\x61\x64\x53\x74\x6f\x72\x65\x28\x29\x20\x3e\x20\x30\x7d\x20\x2f\x3e\x3b\x20\x7d\x0a\x66\x6e\x20\x6e\x75\x6c\x6c\x56\x61\x6c\x75\x65\x28\x29\x20\x40\x54\x79\x70\x65\x4f\x66\x28\x6e\x75\x6c\x6c\x29\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x6e\x75\x6c\x6c\x3b\x20\x7d\x0a\x66\x6e\x20\x4e\x75\x6c\x6c\x52\x65\x63\x65\x69\x76\x65\x72\x28\x61\x72\x67\x73\x3a\x20\x61\x6e\x79\x74\x79\x70\x65\x29\x20\x40\x54\x79\x70\x65\x4f\x66\x28\x75\x69\x2e\x76\x69\x65\x77\x2e\x74\x65\x78\x74\x28\x2e\x7b\x7d\x2c\x20\x22\x6e\x69\x6c\x22\x29\x29\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x75\x69\x2e\x76\x69\x65\x77\x2e\x74\x65\x78\x74\x28\x2e\x7b\x7d\x2c\x20\x69\x66\x20\x28\x61\x72\x67\x73\x2e\x76\x61\x6c\x75\x65\x20\x3d\x3d\x20\x6e\x75\x6c\x6c\x29\x20\x22\x6e\x69\x6c\x22\x20\x65\x6c\x73\x65\x20\x22\x73\x65\x74\x22\x29\x3b\x0a\x7d\x0a\x63\x6f\x6e\x73\x74\x20\x54\x79\x70\x65\x43\x6f\x6e\x66\x69\x67\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x54\x3a\x20\x74\x79\x70\x65\x20\x7d\x3b\x0a\x66\x6e\x20\x74\x79\x70\x65\x43\x6f\x6e\x66\x69\x67\x28\x29\x20\x54\x79\x70\x65\x43\x6f\x6e\x66\x69\x67\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x2e\x7b\x20\x2e\x54\x20\x3d\x20\x69\x33\x32\x20\x7d\x3b\x20\x7d\x0a\x66\x6e\x20\x54\x79\x70\x65\x52\x65\x63\x65\x69\x76\x65\x72\x28\x61\x72\x67\x73\x3a\x20\x61\x6e\x79\x74\x79\x70\x65\x29\x20\x40\x54\x79\x70\x65\x4f\x66\x28\x75\x69\x2e\x76\x69\x65\x77\x2e\x74\x65\x78\x74\x28\x2e\x7b\x7d\x2c\x20\x22\x69\x33\x32\x22\x29\x29\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x75\x69\x2e\x76\x69\x65\x77\x2e\x74\x65\x78\x74\x28\x2e\x7b\x7d\x2c\x20\x40\x74\x79\x70\x65\x4e\x61\x6d\x65\x28\x61\x72\x67\x73\x2e\x63\x6f\x6e\x66\x69\x67\x2e\x54\x29\x29\x3b\x0a\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x4e\x75\x6c\x6c\x43\x61\x6c\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x4e\x75\x6c\x6c\x52\x65\x63\x65\x69\x76\x65\x72\x20\x76\x61\x6c\x75\x65\x3d\x7b\x6e\x75\x6c\x6c\x56\x61\x6c\x75\x65\x28\x29\x7d\x20\x2f\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x43\x6f\x6d\x70\x74\x69\x6d\x65\x53\x74\x72\x75\x63\x74\x43\x61\x6c\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x54\x79\x70\x65\x52\x65\x63\x65\x69\x76\x65\x72\x20\x63\x6f\x6e\x66\x69\x67\x3d\x7b\x74\x79\x70\x65\x43\x6f\x6e\x66\x69\x67\x28\x29\x7d\x20\x2f\x3e\x3b\x20\x7d\x0a\x63\x6f\x6e\x73\x74\x20\x72\x65\x76\x69\x65\x77\x52\x65\x63\x69\x70\x65\x20\x3d\x20\x75\x69\x2e\x63\x76\x61\x28\x2e\x7b\x20\x2e\x62\x61\x73\x65\x20\x3d\x20\x2e\x7b\x20\x2e\x67\x61\x70\x20\x3d\x20\x40\x61\x73\x28\x66\x33\x32\x2c\x20\x37\x29\x20\x7d\x20\x7d\x29\x3b\x0a\x70\x75\x62\x20\x66\x6e\x20\x53\x74\x61\x74\x69\x63\x52\x65\x63\x69\x70\x65\x43\x61\x6c\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x72\x65\x76\x69\x65\x77\x52\x65\x63\x69\x70\x65\x2e\x6f\x66\x28\x2e\x7b\x7d\x29\x7d\x20\x2f\x3e\x3b\x20\x7d\x0a\x63\x6f\x6e\x73\x74\x20\x4d\x69\x78\x65\x64\x43\x6f\x6e\x66\x69\x67\x20\x3d\x20\x73\x74\x72\x75\x63\x74\x20\x7b\x20\x63\x6f\x6d\x70\x74\x69\x6d\x65\x20\x54\x3a\x20\x74\x79\x70\x65\x20\x3d\x20\x69\x33\x32\x2c\x20\x76\x61\x6c\x75\x65\x3a\x20\x69\x33\x32\x20\x7d\x3b\x0a\x66\x6e\x20\x72\x65\x61\x64\x4d\x69\x78\x65\x64\x28\x29\x20\x4d\x69\x78\x65\x64\x43\x6f\x6e\x66\x69\x67\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x2e\x7b\x20\x2e\x76\x61\x6c\x75\x65\x20\x3d\x20\x72\x65\x61\x64\x53\x74\x6f\x72\x65\x28\x29\x20\x7d\x3b\x20\x7d\x0a\x66\x6e\x20\x4d\x69\x78\x65\x64\x52\x65\x63\x65\x69\x76\x65\x72\x28\x63\x6f\x6e\x66\x69\x67\x3a\x20\x4d\x69\x78\x65\x64\x43\x6f\x6e\x66\x69\x67\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x74\x65\x78\x74\x3e\x7b\x63\x6f\x6e\x66\x69\x67\x2e\x76\x61\x6c\x75\x65\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x3b\x20\x7d\x0a\x70\x75\x62\x20\x66\x6e\x20\x4d\x69\x78\x65\x64\x52\x75\x6e\x74\x69\x6d\x65\x43\x61\x6c\x6c\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x4d\x69\x78\x65\x64\x52\x65\x63\x65\x69\x76\x65\x72\x20\x63\x6f\x6e\x66\x69\x67\x3d\x7b\x72\x65\x61\x64\x4d\x69\x78\x65\x64\x28\x29\x7d\x20\x2f\x3e\x3b\x20\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ }) else void;

//# yix-map-data [[253,253],[2612,319],[4829,403],[7144,465],[9543,535],[11788,590],[14215,1070],[16336,1142],[18644,1293],[20383,1501],[22592,1588]]

//# yix-map review_reactive.yix
