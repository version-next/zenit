// GENERATED FILE, do not edit: generated from menu.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Menu's row view: divider and menu item. Popover, keyboard nav and selection pipeline in mod.zig,
//! styles in styles.yss.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Divider: vertical padding, line itself 1px
pub fn MenuSeparator(args: anytype) ui.view.ComponentOf(__yix_MenuSeparator) {
    return ui.view.component(__yix_MenuSeparator, ui.reactive.props.coerce(MenuSeparatorProps, args));
}
pub const MenuSeparatorProps = struct {
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = MenuSeparator;
    pub const __yix_preview_mount = __yix_MenuSeparator;
};
fn __yix_MenuSeparator(__yix_props: MenuSeparatorProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    try ui.view.previewCheckSetup(scope, true);
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    _ = __yix_view_ctx;
    try ui.view.previewCheckSetup(__yix_view_scope, true);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuSeparator", .receiver = "box", .tokens = "box style = @static; a11y = . { . role = . separator } ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . separator ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = ". { . role = . separator } ", .kind = .property, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ }, ui.view.box(.{ .style = S.separator, .a11y = .{ .role = .separator }, }, .{
            ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuSeparator", .receiver = "box", .tokens = "box style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . separator_line ", .kind = .style, .literal = null }, } }, .{ }, ui.view.box(.{ .style = S.separator_line, }, .{ })),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "MenuSeparator";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

/// One menu item. highlighted is menu's current virtual highlight index (keyboard move, pointer
/// enter both write it), when == index shows highlight.
/// Report disabled items as-is (AT users otherwise retry activating unresponsive item), shortcut
/// goes to a11y description.
pub fn MenuEntry(args: anytype) ui.view.ComponentOf(__yix_MenuEntry) {
    return ui.view.component(__yix_MenuEntry, ui.reactive.props.coerce(MenuEntryProps, args));
}
pub const MenuEntryProps = struct {
    label: ui.Source([]const u8),
    index: ui.Source(usize),
    highlighted: ui.Source(usize),
    keyboard_focus: ui.Source(bool) = .{ .value = false },
    danger: ui.Source(bool) = .{ .value = false },
    disabled: ui.Source(bool) = .{ .value = false },
    shortcut: ui.Source(?[]const u8) = .{ .value = null },
    icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    on_pick: ui.Handler(usize),
    on_enter: ui.Handler(usize),
    pub const __yix_preview_setup = true;
    pub const __yix_preview_builder = MenuEntry;
    pub const __yix_preview_mount = __yix_MenuEntry;
};
fn __yix_MenuEntry(__yix_props: MenuEntryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const index = __yix_props.index;
    const highlighted = __yix_props.highlighted;
    const keyboardFocus = __yix_props.keyboard_focus;
    const danger = __yix_props.danger;
    const disabled = __yix_props.disabled;
    const shortcut = __yix_props.shortcut;
    const iconAsset = __yix_props.icon_asset;
    const onPick = __yix_props.on_pick;
    const onEnter = __yix_props.on_enter;
    try ui.view.previewCheckSetup(scope, false);
    const lit = __yix_d1: {
        const __yix_T = @TypeOf(highlighted.peek() == index.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .highlighted = highlighted, .index = index, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.highlighted.get() == __yix_ctx.index.get();
        } }.__yix_compute);
    };
    const focusVisible = __yix_d2: {
        const __yix_T = @TypeOf(keyboardFocus.peek() and lit.peek() and !disabled.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .keyboardFocus = keyboardFocus, .lit = lit, .disabled = disabled, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.keyboardFocus.get() and __yix_ctx.lit.get() and !__yix_ctx.disabled.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.MenuRow, .{ .danger = danger, .disabled = disabled, .lit = lit });
    const __yix_view = try ui.view.renderComponentView(scope, cx, .{ .label = label, .index = index, .disabled = disabled, .shortcut = shortcut, .iconAsset = iconAsset, .onPick = onPick, .onEnter = onEnter, .focusVisible = focusVisible, .p = p, }, struct { fn __yix_render(__yix_view_ctx: anytype, __yix_view_scope: *ui.Scope, __yix_view_cx: *ui.Cx, __yix_sink: ui.view.Sink) anyerror!*ui.Node {
    try ui.view.previewCheckSetup(__yix_view_scope, false);
    try ui.view.emit(__yix_view_scope, __yix_view_cx, __yix_sink, ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry", .receiver = "row", .tokens = "row style = . { p . root , S . virtual_focus . of ( . { . visible = focusVisible } ) } ; a11y = . { . role = . menuitem , . label = label , . disabled = disabled , . description = shortcut } ; onClick = if ( ! disabled ) onPick ( index ) ; onHover = if ( ! disabled ) onEnter ( index ) ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = ". { p . root , S . virtual_focus . of ( . { . visible = focusVisible } ) } ", .kind = .style, .literal = null }, .{ .name = "a11y", .tokens = ". { . role = . menuitem , . label = label , . disabled = disabled , . description = shortcut } ", .kind = .property, .literal = null }, .{ .name = "on_click", .tokens = "if ( ! disabled ) onPick ( index ) ", .kind = .event, .literal = null }, .{ .name = "on_hover", .tokens = "if ( ! disabled ) onEnter ( index ) ", .kind = .event, .literal = null }, }, .source = __yix_preview_source, .catalog = __YixStyleCatalog }, .{ .p = __yix_view_ctx.p, .focusVisible = __yix_view_ctx.focusVisible, .label = __yix_view_ctx.label, .disabled = __yix_view_ctx.disabled, .shortcut = __yix_view_ctx.shortcut, .onPick = __yix_view_ctx.onPick, .index = __yix_view_ctx.index, .onEnter = __yix_view_ctx.onEnter, .iconAsset = __yix_view_ctx.iconAsset, }, ui.view.row(.{ .style = .{ __yix_view_ctx.p.root, S.virtual_focus.of(.{ .visible = __yix_view_ctx.focusVisible }) }, .a11y = .{ .role = .menuitem, .label = __yix_view_ctx.label, .disabled = __yix_view_ctx.disabled, .description = __yix_view_ctx.shortcut }, .on_click = try ui.on.bind(__yix_view_scope, .{ .disabled = __yix_view_ctx.disabled, .onPick = __yix_view_ctx.onPick, .index = __yix_view_ctx.index, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onPick, .{__yix_ctx.index.peek()}); }  } }.__yix_run), .on_hover = try ui.on.bind(__yix_view_scope, .{ .disabled = __yix_view_ctx.disabled, .onEnter = __yix_view_ctx.onEnter, .index = __yix_view_ctx.index, .__yix_owner = __yix_view_scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onEnter, .{__yix_ctx.index.peek()}); }  } }.__yix_run), }, .{
            ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry", .receiver = "row", .tokens = "row style = @static; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . item_left ", .kind = .style, .literal = null }, } }, .{ .iconAsset = __yix_view_ctx.iconAsset, .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, ui.view.row(.{ .style = S.item_left, }, .{
                ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry", .receiver = "control", .tokens = "if ( iconAsset ) | asset | < icon style = { p . icon } src = { asset } / > " }, .{ .iconAsset = __yix_view_ctx.iconAsset, .p = __yix_view_ctx.p, }, ui.view.lazyIfSome(__yix_view_ctx.iconAsset, .{ .p = __yix_view_ctx.p, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry/keyword_if:1/branch:0", .receiver = "icon", .tokens = "icon style = @static; src = asset ; ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "p . icon ", .kind = .style, .literal = null }, .{ .name = "src", .tokens = "asset ", .kind = .property, .literal = null }, } }, .{ .p = __yix_b1_0.p, .asset = asset, }, ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset)) }); } }.__yix_b, null)),
                ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry", .receiver = "text", .tokens = "text style = . { S . rowText , p . label } ; label  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = ". { S . rowText , p . label } ", .kind = .style, .literal = null }, } }, .{ .p = __yix_view_ctx.p, .label = __yix_view_ctx.label, }, ui.view.text(.{ .style = .{ S.rowText, __yix_view_ctx.p.label }, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_view_ctx.label), ""), .{ __yix_view_ctx.label, }))),
            })),
            ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry", .receiver = "control", .tokens = "if ( shortcut ) | keys | < text style = { S . shortcut } > { keys } < / text > " }, .{ .shortcut = __yix_view_ctx.shortcut, }, ui.view.lazyIfSome(__yix_view_ctx.shortcut, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, keys: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.templateSite(.{ .module = "src/ui/components/menu/menu.yix", .path = "MenuEntry/keyword_if:2/branch:0", .receiver = "text", .tokens = "text style = @static; keys  @interpolation ", .literal_text = null, .attributes = &.{ .{ .name = "style", .tokens = "S . shortcut ", .kind = .style, .literal = null }, } }, .{ .keys = keys, }, ui.view.text(.{ .style = S.shortcut, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(keys), ""), .{ keys, }))) }); } }.__yix_b, null)),
        })));
    const __yix_root = __yix_sink.root.?.* orelse return error.ViewEmptyRoot;
    __yix_root.meta.ownership.meta.component_name = "MenuEntry";
    return __yix_root;
    } }.__yix_render);
    return __yix_view;

}

const __yix_preview_source: ?[]const u8 = if (ui.view.template.preview_enabled) "\x2f\x2f\x21\x20\x4d\x65\x6e\x75\x27\x73\x20\x72\x6f\x77\x20\x76\x69\x65\x77\x3a\x20\x64\x69\x76\x69\x64\x65\x72\x20\x61\x6e\x64\x20\x6d\x65\x6e\x75\x20\x69\x74\x65\x6d\x2e\x20\x50\x6f\x70\x6f\x76\x65\x72\x2c\x20\x6b\x65\x79\x62\x6f\x61\x72\x64\x20\x6e\x61\x76\x20\x61\x6e\x64\x20\x73\x65\x6c\x65\x63\x74\x69\x6f\x6e\x20\x70\x69\x70\x65\x6c\x69\x6e\x65\x20\x69\x6e\x20\x6d\x6f\x64\x2e\x7a\x69\x67\x2c\x0a\x2f\x2f\x21\x20\x73\x74\x79\x6c\x65\x73\x20\x69\x6e\x20\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x2e\x0a\x63\x6f\x6e\x73\x74\x20\x75\x69\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x2e\x2e\x2f\x2e\x2e\x2f\x75\x69\x2e\x7a\x69\x67\x22\x29\x3b\x0a\x63\x6f\x6e\x73\x74\x20\x53\x20\x3d\x20\x40\x69\x6d\x70\x6f\x72\x74\x28\x22\x73\x74\x79\x6c\x65\x73\x2e\x79\x73\x73\x22\x29\x3b\x0a\x0a\x2f\x2f\x2f\x20\x44\x69\x76\x69\x64\x65\x72\x3a\x20\x76\x65\x72\x74\x69\x63\x61\x6c\x20\x70\x61\x64\x64\x69\x6e\x67\x2c\x20\x6c\x69\x6e\x65\x20\x69\x74\x73\x65\x6c\x66\x20\x31\x70\x78\x0a\x70\x75\x62\x20\x66\x6e\x20\x4d\x65\x6e\x75\x53\x65\x70\x61\x72\x61\x74\x6f\x72\x28\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x65\x70\x61\x72\x61\x74\x6f\x72\x7d\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x73\x65\x70\x61\x72\x61\x74\x6f\x72\x20\x7d\x7d\x3e\x3c\x62\x6f\x78\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x65\x70\x61\x72\x61\x74\x6f\x72\x5f\x6c\x69\x6e\x65\x7d\x20\x2f\x3e\x3c\x2f\x62\x6f\x78\x3e\x3b\x0a\x7d\x0a\x0a\x2f\x2f\x2f\x20\x4f\x6e\x65\x20\x6d\x65\x6e\x75\x20\x69\x74\x65\x6d\x2e\x20\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x65\x64\x20\x69\x73\x20\x6d\x65\x6e\x75\x27\x73\x20\x63\x75\x72\x72\x65\x6e\x74\x20\x76\x69\x72\x74\x75\x61\x6c\x20\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x20\x69\x6e\x64\x65\x78\x20\x28\x6b\x65\x79\x62\x6f\x61\x72\x64\x20\x6d\x6f\x76\x65\x2c\x20\x70\x6f\x69\x6e\x74\x65\x72\x0a\x2f\x2f\x2f\x20\x65\x6e\x74\x65\x72\x20\x62\x6f\x74\x68\x20\x77\x72\x69\x74\x65\x20\x69\x74\x29\x2c\x20\x77\x68\x65\x6e\x20\x3d\x3d\x20\x69\x6e\x64\x65\x78\x20\x73\x68\x6f\x77\x73\x20\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x2e\x0a\x2f\x2f\x2f\x20\x52\x65\x70\x6f\x72\x74\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x69\x74\x65\x6d\x73\x20\x61\x73\x2d\x69\x73\x20\x28\x41\x54\x20\x75\x73\x65\x72\x73\x20\x6f\x74\x68\x65\x72\x77\x69\x73\x65\x20\x72\x65\x74\x72\x79\x20\x61\x63\x74\x69\x76\x61\x74\x69\x6e\x67\x20\x75\x6e\x72\x65\x73\x70\x6f\x6e\x73\x69\x76\x65\x20\x69\x74\x65\x6d\x29\x2c\x20\x73\x68\x6f\x72\x74\x63\x75\x74\x0a\x2f\x2f\x2f\x20\x67\x6f\x65\x73\x20\x74\x6f\x20\x61\x31\x31\x79\x20\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x2e\x0a\x70\x75\x62\x20\x66\x6e\x20\x4d\x65\x6e\x75\x45\x6e\x74\x72\x79\x28\x0a\x20\x20\x20\x20\x6c\x61\x62\x65\x6c\x3a\x20\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x2c\x0a\x20\x20\x20\x20\x69\x6e\x64\x65\x78\x3a\x20\x75\x73\x69\x7a\x65\x2c\x0a\x20\x20\x20\x20\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x65\x64\x3a\x20\x75\x73\x69\x7a\x65\x2c\x0a\x20\x20\x20\x20\x6b\x65\x79\x62\x6f\x61\x72\x64\x46\x6f\x63\x75\x73\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x64\x61\x6e\x67\x65\x72\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x3a\x20\x62\x6f\x6f\x6c\x20\x3d\x20\x66\x61\x6c\x73\x65\x2c\x0a\x20\x20\x20\x20\x73\x68\x6f\x72\x74\x63\x75\x74\x3a\x20\x3f\x5b\x5d\x63\x6f\x6e\x73\x74\x20\x75\x38\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x69\x63\x6f\x6e\x41\x73\x73\x65\x74\x3a\x20\x3f\x75\x69\x2e\x53\x76\x67\x41\x73\x73\x65\x74\x20\x3d\x20\x6e\x75\x6c\x6c\x2c\x0a\x20\x20\x20\x20\x6f\x6e\x50\x69\x63\x6b\x3a\x20\x48\x61\x6e\x64\x6c\x65\x72\x28\x75\x73\x69\x7a\x65\x29\x2c\x0a\x20\x20\x20\x20\x6f\x6e\x45\x6e\x74\x65\x72\x3a\x20\x48\x61\x6e\x64\x6c\x65\x72\x28\x75\x73\x69\x7a\x65\x29\x2c\x0a\x29\x20\x56\x69\x65\x77\x20\x7b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x6c\x69\x74\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x68\x69\x67\x68\x6c\x69\x67\x68\x74\x65\x64\x20\x3d\x3d\x20\x69\x6e\x64\x65\x78\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x66\x6f\x63\x75\x73\x56\x69\x73\x69\x62\x6c\x65\x20\x3d\x20\x63\x6f\x6d\x70\x75\x74\x65\x64\x28\x6b\x65\x79\x62\x6f\x61\x72\x64\x46\x6f\x63\x75\x73\x20\x61\x6e\x64\x20\x6c\x69\x74\x20\x61\x6e\x64\x20\x21\x64\x69\x73\x61\x62\x6c\x65\x64\x29\x3b\x0a\x20\x20\x20\x20\x63\x6f\x6e\x73\x74\x20\x70\x20\x3d\x20\x70\x61\x72\x74\x73\x28\x53\x2e\x4d\x65\x6e\x75\x52\x6f\x77\x2c\x20\x2e\x7b\x20\x2e\x64\x61\x6e\x67\x65\x72\x20\x3d\x20\x64\x61\x6e\x67\x65\x72\x2c\x20\x2e\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x3d\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x2c\x20\x2e\x6c\x69\x74\x20\x3d\x20\x6c\x69\x74\x20\x7d\x29\x3b\x0a\x20\x20\x20\x20\x72\x65\x74\x75\x72\x6e\x20\x28\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x70\x2e\x72\x6f\x6f\x74\x2c\x20\x53\x2e\x76\x69\x72\x74\x75\x61\x6c\x5f\x66\x6f\x63\x75\x73\x2e\x6f\x66\x28\x2e\x7b\x20\x2e\x76\x69\x73\x69\x62\x6c\x65\x20\x3d\x20\x66\x6f\x63\x75\x73\x56\x69\x73\x69\x62\x6c\x65\x20\x7d\x29\x20\x7d\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x61\x31\x31\x79\x3d\x7b\x2e\x7b\x20\x2e\x72\x6f\x6c\x65\x20\x3d\x20\x2e\x6d\x65\x6e\x75\x69\x74\x65\x6d\x2c\x20\x2e\x6c\x61\x62\x65\x6c\x20\x3d\x20\x6c\x61\x62\x65\x6c\x2c\x20\x2e\x64\x69\x73\x61\x62\x6c\x65\x64\x20\x3d\x20\x64\x69\x73\x61\x62\x6c\x65\x64\x2c\x20\x2e\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x20\x3d\x20\x73\x68\x6f\x72\x74\x63\x75\x74\x20\x7d\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x43\x6c\x69\x63\x6b\x3d\x7b\x69\x66\x20\x28\x21\x64\x69\x73\x61\x62\x6c\x65\x64\x29\x20\x6f\x6e\x50\x69\x63\x6b\x28\x69\x6e\x64\x65\x78\x29\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x6f\x6e\x48\x6f\x76\x65\x72\x3d\x7b\x69\x66\x20\x28\x21\x64\x69\x73\x61\x62\x6c\x65\x64\x29\x20\x6f\x6e\x45\x6e\x74\x65\x72\x28\x69\x6e\x64\x65\x78\x29\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x72\x6f\x77\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x69\x74\x65\x6d\x5f\x6c\x65\x66\x74\x7d\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x69\x63\x6f\x6e\x41\x73\x73\x65\x74\x29\x20\x7c\x61\x73\x73\x65\x74\x7c\x20\x3c\x69\x63\x6f\x6e\x20\x73\x74\x79\x6c\x65\x3d\x7b\x70\x2e\x69\x63\x6f\x6e\x7d\x20\x73\x72\x63\x3d\x7b\x61\x73\x73\x65\x74\x7d\x20\x2f\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x2e\x7b\x20\x53\x2e\x72\x6f\x77\x54\x65\x78\x74\x2c\x20\x70\x2e\x6c\x61\x62\x65\x6c\x20\x7d\x7d\x3e\x7b\x6c\x61\x62\x65\x6c\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x7b\x69\x66\x20\x28\x73\x68\x6f\x72\x74\x63\x75\x74\x29\x20\x7c\x6b\x65\x79\x73\x7c\x20\x3c\x74\x65\x78\x74\x20\x73\x74\x79\x6c\x65\x3d\x7b\x53\x2e\x73\x68\x6f\x72\x74\x63\x75\x74\x7d\x3e\x7b\x6b\x65\x79\x73\x7d\x3c\x2f\x74\x65\x78\x74\x3e\x7d\x0a\x20\x20\x20\x20\x20\x20\x20\x20\x3c\x2f\x72\x6f\x77\x3e\x0a\x20\x20\x20\x20\x29\x3b\x0a\x7d\x0a" else null;
const __YixStyleCatalog = if (ui.view.template.preview_enabled) ui.view.template.styleCatalog(.{ .@"S " = S, }) else void;

//# yix-map-data [[253,248],[2598,670]]

//# yix-map menu.yix
