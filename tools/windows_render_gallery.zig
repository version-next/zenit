//! Public App image API fixture; exercised through the shared HTTP harness.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const texture_fixture = @import("windows_gpu_device_fixture.zig");
const init_contract = if (@hasField(@FieldType(App, "painter"), "native")) @import("windows_app_init_contract.zig") else @import("windows_shared_app_init_contract.zig");
const cursor_contract = @import("windows_cursor_contract.zig");
const pointer_contract = @import("windows_pointer_contract.zig");
const window_contract = @import("windows_window_contract.zig");
const size_contract = @import("windows_size_contract.zig");
const menu_contract = @import("windows_menu_contract.zig");
const clipboard_contract = @import("windows_clipboard_contract.zig");
const background_contract = @import("windows_background_contract.zig");
const drop_contract = @import("windows_drop_contract.zig");
const dialog_contract = @import("windows_dialog_contract.zig");
const noise_contract = @import("windows_noise_contract.zig");
const gradient_contract = @import("windows_gradient_contract.zig");
const path_contract = @import("windows_path_contract.zig");
const blend_contract = @import("windows_blend_contract.zig");
const optical_contract = @import("windows_optical_glass_contract.zig");
const glass_contract = @import("windows_glass_contract.zig");
const backdrop_contract = @import("windows_backdrop_contract.zig");
const retained_contract = @import("windows_retained_contract.zig");
var drop_gallery: *ui.Node = undefined;
var dialog_gallery: *ui.Node = undefined;
var noise_gallery: *ui.Node = undefined;
var gradient_gallery: *ui.Node = undefined;
var path_gallery: *ui.Node = undefined;
var icon_gallery: *ui.Node = undefined;
var blend_gallery: *ui.Node = undefined;
var optical_gallery: *ui.Node = undefined;
var glass_gallery: *ui.Node = undefined;
var backdrop_gallery: *ui.Node = undefined;
var hidden_for_paths: [3]*ui.Node = undefined;
var app: *App = undefined;
var quadrant_id: u32 = 0;
var white_id: u32 = 0;
var first_image: *ui.Node = undefined;
var status: *ui.Node = undefined;
var clipboard_status: *ui.Node = undefined;
var luminance_status: *ui.Node = undefined;
var luminance_buffer: [512]u8 = undefined;
const background = ui.Color{ .r = 20, .g = 40, .b = 60, .a = 255 };
const quadrant = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128 };
const ArcSpec = struct { start: f32, end: f32 };
var arc_specs = [_]ArcSpec{
    .{ .start = 0, .end = std.math.pi / 2.0 },
    .{ .start = -2 * std.math.pi, .end = 0 },
    .{ .start = -std.math.pi / 2.0, .end = 0 },
    .{ .start = 0, .end = std.math.pi },
    .{ .start = 1, .end = 1 },
};

fn drawArc(ctx: ui.DrawContext, context: ?*anyopaque) anyerror!void {
    const spec: *const ArcSpec = @ptrCast(@alignCast(context orelse return));
    if (ctx.display_list) |dl| {
        if (ctx.display_header) |header| try dl.append(.{ .arc = .{
            .header = header,
            .cx = ctx.local_w / 2,
            .cy = ctx.local_h / 2,
            .outer_radius = 40,
            .stroke_width = 12,
            .start_angle = spec.start,
            .end_angle = spec.end,
            .color = ui.Color.WHITE,
        } });
    }
}

fn arcNode(cx: *ui.Cx, parent: *ui.Node, id: []const u8, index: usize, opacity: f32) !void {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .opacity = opacity }, .{});
    node.meta.ownership.meta.test_id = id;
    node.setCustomDraw(drawArc, &arc_specs[index]);
    try parent.appendChild(cx.allocator, node);
}

const Actions = struct {
    pub fn drops(_: *@This()) void {
        for (hidden_for_paths) |node| node.setDisplay(.none);
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.none);
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        path_gallery.setDisplay(.none);
        blend_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        drop_gallery.setDisplay(.flex);
    }
    pub fn dialogs(_: *@This()) void {
        drop_gallery.setDisplay(.none);
        for (hidden_for_paths) |node| node.setDisplay(.none);
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.none);
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        path_gallery.setDisplay(.none);
        blend_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.flex);
    }
    pub fn noise(self: *@This()) void {
        self.gradients();
        gradient_gallery.setDisplay(.none);
        noise_gallery.setDisplay(.flex);
    }
    pub fn gradients(_: *@This()) void {
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        drop_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        for (hidden_for_paths) |node| node.setDisplay(.none);
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        path_gallery.setDisplay(.none);
        blend_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.flex);
    }
    pub fn paths(_: *@This()) void {
        drop_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.none);
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        for (hidden_for_paths) |node| node.setDisplay(.none);
        blend_gallery.setDisplay(.none);
        path_gallery.setDisplay(.flex);
    }
    pub fn icons(self: *@This()) void {
        self.paths();
        path_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.flex);
    }
    pub fn blends(_: *@This()) void {
        drop_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.none);
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        for (hidden_for_paths) |node| node.setDisplay(.none);
        path_gallery.setDisplay(.none);
        blend_gallery.setDisplay(.flex);
    }
    pub fn backdrop(_: *@This()) void {
        drop_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        noise_gallery.setDisplay(.none);
        icon_gallery.setDisplay(.none);
        gradient_gallery.setDisplay(.none);
        backdrop_contract.reset();
        for (hidden_for_paths) |node| node.setDisplay(.none);
        path_gallery.setDisplay(.none);
        blend_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.none);
        backdrop_gallery.setDisplay(.flex);
    }
    pub fn glass(self: *@This()) void {
        self.backdrop();
        backdrop_gallery.setDisplay(.none);
        glass_gallery.setDisplay(.flex);
    }
    pub fn optics(self: *@This()) void {
        self.backdrop();
        backdrop_gallery.setDisplay(.none);
        optical_gallery.setDisplay(.flex);
    }
    pub fn changeOptics(_: *@This()) void {
        optical_contract.change();
    }
    pub fn isolateBackdrop(self: *@This()) void {
        self.backdrop();
        backdrop_contract.isolate();
    }
    pub fn fadeBackdrop(_: *@This()) void {
        backdrop_contract.fade();
    }
    pub fn changeBackdrop(_: *@This()) void {
        backdrop_contract.change();
    }
    pub fn luminance(_: *@This()) void {
        luminance_status.setText(.{ .content = backdrop_contract.describe(app.cx, &luminance_buffer), .font_size = 12, .color = ui.Color.WHITE });
    }
    pub fn solidBackdrop(_: *@This()) void {
        backdrop_contract.solid();
    }
    pub fn retained(_: *@This()) void {
        drop_gallery.setDisplay(.none);
        dialog_gallery.setDisplay(.none);
        retained_contract.open();
    }
    pub fn clipboard(_: *@This()) void {
        clipboard_contract.run(app) catch |err| {
            std.log.err("Windows clipboard contract: {s}", .{@errorName(err)});
            clipboard_status.setText(.{ .content = "clipboard-contract=FAIL", .font_size = 14, .color = ui.Color.WHITE });
            return;
        };
        clipboard_status.setText(.{ .content = "clipboard-contract=PASS", .font_size = 14, .color = ui.Color.WHITE });
    }
    pub fn replace(_: *@This()) void {
        const before = app.renderer.image_renderer.getTextureMemoryStats();
        const old = quadrant_id;
        app.renderer.image_renderer.unloadTexture(old);
        app.renderer.image_renderer.unloadTexture(old);
        std.debug.assert(app.renderer.image_renderer.getTextureSize(old) == null);
        quadrant_id = app.renderer.image_renderer.loadTexture(texture_fixture.width, texture_fixture.height, texture_fixture.greenReplacementBytes()) catch @panic("reload failed");
        std.debug.assert(quadrant_id != old);
        first_image.setImage(.{ .texture_id = quadrant_id });
        status.setText(.{ .content = "texture-replaced; old-handles-invalid", .font_size = 14, .color = ui.Color.WHITE });
        const stats = app.renderer.image_renderer.getTextureMemoryStats();
        // Shared rendering stores small images in atlas pages; resident GPU
        // bytes are not the 20 bytes of source pixels. Replacement must retain
        // the live handle count, irrespective of atlas allocation strategy.
        if (comptime @hasField(@FieldType(App, "painter"), "state")) {
            std.debug.assert(stats.slots_used == before.slots_used);
        } else {
            std.debug.assert(stats.texture_count == before.texture_count and stats.estimated_bytes == before.estimated_bytes);
        }
    }
};

fn image(cx: *ui.Cx, parent: *ui.Node, id: []const u8, texture: u32, tint: ui.Color, radius: f32, opacity: f32, rotate: f32) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .corner_radius = radius, .opacity = opacity, .rotate = rotate }, .{});
    node.meta.ownership.meta.test_id = id;
    node.setImage(.{ .texture_id = texture, .tint = tint });
    try parent.appendChild(cx.allocator, node);
    return node;
}

fn shadowBox(cx: *ui.Cx, parent: *ui.Node, id: []const u8, shadow: ?ui.Shadow) !*ui.Node {
    const node = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .flex_shrink = 0, .corner_radius = 16, .background = ui.Color.WHITE, .shadow = shadow }, .{});
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    return node;
}

fn scrollFixture(cx: *ui.Cx, scope: *ui.Scope, fixture: *ui.Node) !*ui.Node {
    const area = try ui.widgets.ScrollArea(.{ .rubber_band_y = false }).mount(scope, cx);
    fixture.setDisplay(.flex);
    try area.content.appendChild(cx.allocator, fixture);
    area.container.setDisplay(.none);
    return area.container;
}

fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const menu_ok = ok: {
        menu_contract.run(app) catch |err| {
            std.log.err("Windows menu contract: {s}", .{@errorName(err)});
            break :ok false;
        };
        break :ok true;
    };
    const window_ok = ok: {
        window_contract.run(app) catch |err| {
            std.log.err("Windows titlebar contract: {s}", .{@errorName(err)});
            break :ok false;
        };
        break :ok true;
    };
    const root = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .min_height = 0, .direction = .column, .padding = ui.Padding.all(20), .gap = 20, .background = background }, .{});
    status = try ui.text(cx, "textures=2 bytes=20", .{ .font_size = 14, .color = ui.Color.WHITE });
    status.meta.ownership.meta.test_id = "gallery.status";
    const status_row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .direction = .row, .gap = 20 }, .{});
    try root.appendChild(cx.allocator, status_row);
    try status_row.appendChild(cx.allocator, status);
    const live_menu = try menu_contract.mountLive(app, cx, scope, root);
    const menu_status = try ui.text(cx, if (menu_ok) "menu-contract=PASS" else "menu-contract=FAIL", .{ .font_size = 14, .color = ui.Color.WHITE });
    menu_status.meta.ownership.meta.test_id = "gallery.menu-status";
    menu_status.behavior.events.on_click = ui.Cx.simpleHandler(struct {
        fn clicked(context: *anyopaque) void {
            const state_: *menu_contract.Live = @ptrCast(@alignCast(context));
            state_.install();
        }
    }.clicked, live_menu);
    try status_row.appendChild(cx.allocator, menu_status);
    const erase_ok = ok: {
        background_contract.run(app) catch |err| {
            std.log.err("Windows background contract: {s}", .{@errorName(err)});
            break :ok false;
        };
        break :ok true;
    };
    const erase_status = try ui.text(cx, if (erase_ok) "erase-contract=PASS" else "erase-contract=FAIL", .{ .font_size = 14, .color = ui.Color.WHITE });
    erase_status.meta.ownership.meta.test_id = "gallery.erase-status";
    try status_row.appendChild(cx.allocator, erase_status);
    const window_status = try ui.text(cx, if (window_ok) "window-contract=PASS" else "window-contract=FAIL", .{ .font_size = 14, .color = ui.Color.WHITE });
    window_status.meta.ownership.meta.test_id = "gallery.window-status";
    const PointerCheck = struct {
        app_: *App,
        node: *ui.Node,
        fn clicked(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const ok = success: {
                pointer_contract.run(self.app_, self.node) catch |err| {
                    std.log.err("Windows pointer contract: {s}", .{@errorName(err)});
                    break :success false;
                };
                window_contract.runPaint(self.app_) catch |err| {
                    std.log.err("Windows native paint contract: {s}", .{@errorName(err)});
                    break :success false;
                };
                size_contract.run(self.app_) catch |err| {
                    std.log.err("Windows client size contract: {s}", .{@errorName(err)});
                    break :success false;
                };
                window_contract.runRefresh(self.app_) catch |err| {
                    std.log.err("Windows display refresh contract: {s}", .{@errorName(err)});
                    break :success false;
                };
                cursor_contract.run(self.app_) catch |err| {
                    std.log.err("Windows cursor contract: {s}", .{@errorName(err)});
                    break :success false;
                };
                break :success true;
            };
            self.node.setText(.{ .content = if (ok) "pointer-contract=PASS" else "pointer-contract=FAIL", .font_size = 14, .color = ui.Color.WHITE });
            self.app_.cx.needs_redraw = true;
        }
    };
    // Ordinary gallery builds remain interactive without compiling the owned
    // test-input route. Keep the contract and its runtime guard in test builds.
    if (@import("zenit_app").test_harness.enabled) {
        const pointer_check = try cx.bindState(PointerCheck, .{ .app_ = app, .node = window_status });
        window_status.behavior.events.on_click = ui.Cx.simpleHandler(PointerCheck.clicked, pointer_check);
    }
    try status_row.appendChild(cx.allocator, window_status);
    const row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, row);
    first_image = try image(cx, row, "gallery.quadrant", quadrant_id, ui.Color.WHITE, 0, 1, 0);
    _ = try image(cx, row, "gallery.rounded", white_id, ui.Color.WHITE, 20, 1, 0);
    _ = try image(cx, row, "gallery.rotated", quadrant_id, ui.Color.WHITE, 0, 1, std.math.pi / 2.0);
    _ = try image(cx, row, "gallery.tint", white_id, .{ .r = 128, .g = 64, .b = 255, .a = 128 }, 0, 1, 0);
    _ = try image(cx, row, "gallery.opacity", white_id, ui.Color.WHITE, 0, 0.5, 0);
    const clip = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 }, .overflow_hidden = true }, .{});
    clip.meta.ownership.meta.test_id = "gallery.clip";
    try row.appendChild(cx.allocator, clip);
    _ = try image(cx, clip, "gallery.clipped-image", quadrant_id, ui.Color.WHITE, 0, 1, 0);
    const state = try cx.bindState(Actions, .{});
    const button = try ui.widgets.Button(.{ .label = "Replace texture", .on_click = cx.on(Actions, state, Actions.replace) }).mount(scope, cx);
    button.meta.ownership.meta.test_id = "gallery.replace";
    try root.appendChild(cx.allocator, button);
    const shadows = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 160 }, .flex_shrink = 0, .direction = .row, .padding = ui.Padding.all(24), .gap = 32, .background = ui.Color.WHITE }, .{});
    shadows.meta.ownership.meta.test_id = "gallery.shadow-panel";
    try root.appendChild(cx.allocator, shadows);
    const outer = try shadowBox(cx, shadows, "shadow.outer", .{ .color = ui.Color.rgba(0, 0, 0, 200), .blur = 12, .offset_y = 8 });
    // Transparent body still punches a hole in its own outer shadow.
    outer.setBackground(ui.Color.TRANSPARENT);
    _ = try shadowBox(cx, shadows, "shadow.spread-positive", .{ .color = ui.Color.rgba(0, 0, 0, 200), .blur = 8, .spread = 6 });
    _ = try shadowBox(cx, shadows, "shadow.spread-negative", .{ .color = ui.Color.rgba(0, 0, 0, 200), .blur = 8, .spread = -6 });
    const inset = try shadowBox(cx, shadows, "shadow.inset", null);
    (try inset.style.ensureExtFallible(cx.allocator)).inset_shadow = .{ .color = ui.Color.rgba(0, 0, 0, 200), .blur = 8, .offset_y = 6 };
    const dual = try shadowBox(cx, shadows, "shadow.dual", null);
    (try dual.style.ensureExtFallible(cx.allocator)).setShadows(.{ .color = ui.Color.rgba(255, 0, 0, 180), .blur = 10, .offset_x = 6 }, .{ .color = ui.Color.rgba(0, 0, 255, 180), .blur = 10, .offset_x = -6 });
    const arcs = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, arcs);
    hidden_for_paths = .{ row, shadows, arcs };
    try arcNode(cx, arcs, "arc.quarter", 0, 1);
    try arcNode(cx, arcs, "arc.full", 1, 1);
    try arcNode(cx, arcs, "arc.negative", 2, 1);
    try arcNode(cx, arcs, "arc.opacity", 3, 0.5);
    try arcNode(cx, arcs, "arc.zero", 4, 1);
    const arc_clip = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 }, .flex_shrink = 0, .overflow_hidden = true }, .{});
    try arcs.appendChild(cx.allocator, arc_clip);
    try arcNode(cx, arc_clip, "arc.clipped", 1, 1);
    const clipboard_button = try ui.widgets.Button(.{ .label = "Verify native clipboard", .on_click = cx.on(Actions, state, Actions.clipboard) }).mount(scope, cx);
    clipboard_button.meta.ownership.meta.test_id = "gallery.clipboard";
    const clipboard_row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 40 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, clipboard_row);
    try clipboard_row.appendChild(cx.allocator, clipboard_button);
    clipboard_status = try ui.text(cx, "", .{ .font_size = 14, .color = ui.Color.WHITE });
    clipboard_status.meta.ownership.meta.test_id = "gallery.clipboard-status";
    try clipboard_row.appendChild(cx.allocator, clipboard_status);
    const paths_button = try ui.widgets.Button(.{ .label = "Show paths", .on_click = cx.on(Actions, state, Actions.paths) }).mount(scope, cx);
    paths_button.meta.ownership.meta.test_id = "gallery.paths";
    try clipboard_row.appendChild(cx.allocator, paths_button);
    const blends_button = try ui.widgets.Button(.{ .label = "Show blends", .on_click = cx.on(Actions, state, Actions.blends) }).mount(scope, cx);
    blends_button.meta.ownership.meta.test_id = "gallery.blends";
    try clipboard_row.appendChild(cx.allocator, blends_button);
    const icons_button = try ui.widgets.Button(.{ .label = "Icons", .on_click = cx.on(Actions, state, Actions.icons) }).mount(scope, cx);
    icons_button.meta.ownership.meta.test_id = "gallery.icons";
    try clipboard_row.appendChild(cx.allocator, icons_button);
    icon_gallery = try path_contract.mountIcons(cx);
    try root.appendChild(cx.allocator, icon_gallery);
    path_gallery = try scrollFixture(cx, scope, try path_contract.mount(cx));
    try root.appendChild(cx.allocator, path_gallery);
    blend_gallery = try blend_contract.mount(cx);
    try root.appendChild(cx.allocator, blend_gallery);
    const blur_button = try ui.widgets.Button(.{ .label = "Show blur", .on_click = cx.on(Actions, state, Actions.backdrop) }).mount(scope, cx);
    blur_button.meta.ownership.meta.test_id = "gallery.blur";
    try clipboard_row.appendChild(cx.allocator, blur_button);
    const fade_button = try ui.widgets.Button(.{ .label = "Fade glass", .on_click = cx.on(Actions, state, Actions.fadeBackdrop) }).mount(scope, cx);
    fade_button.meta.ownership.meta.test_id = "gallery.blur-fade";
    try clipboard_row.appendChild(cx.allocator, fade_button);
    const change_button = try ui.widgets.Button(.{ .label = "Change backdrop", .on_click = cx.on(Actions, state, Actions.changeBackdrop) }).mount(scope, cx);
    change_button.meta.ownership.meta.test_id = "gallery.blur-change";
    try clipboard_row.appendChild(cx.allocator, change_button);
    const change_optics_button = try ui.widgets.Button(.{ .label = "Change optics", .on_click = cx.on(Actions, state, Actions.changeOptics) }).mount(scope, cx);
    change_optics_button.meta.ownership.meta.test_id = "gallery.optics-change";
    try clipboard_row.appendChild(cx.allocator, change_optics_button);
    backdrop_gallery = try backdrop_contract.mount(cx);
    try root.appendChild(cx.allocator, backdrop_gallery);
    glass_gallery = try glass_contract.mount(cx);
    try root.appendChild(cx.allocator, glass_gallery);
    optical_gallery = try optical_contract.mount(cx);
    try root.appendChild(cx.allocator, optical_gallery);
    const lum_row = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 }, .flex_shrink = 0, .direction = .row, .gap = 12 }, .{});
    try root.appendChild(cx.allocator, lum_row);
    const glass_button = try ui.widgets.Button(.{ .label = "Show glass", .on_click = cx.on(Actions, state, Actions.glass) }).mount(scope, cx);
    glass_button.meta.ownership.meta.test_id = "gallery.glass";
    try lum_row.appendChild(cx.allocator, glass_button);
    const optics_button = try ui.widgets.Button(.{ .label = "Optics", .on_click = cx.on(Actions, state, Actions.optics) }).mount(scope, cx);
    optics_button.meta.ownership.meta.test_id = "gallery.optics";
    try lum_row.appendChild(cx.allocator, optics_button);
    const isolate_button = try ui.widgets.Button(.{ .label = "Fade only", .on_click = cx.on(Actions, state, Actions.isolateBackdrop) }).mount(scope, cx);
    isolate_button.meta.ownership.meta.test_id = "gallery.blur-isolate";
    try lum_row.appendChild(cx.allocator, isolate_button);
    const lum_button = try ui.widgets.Button(.{ .label = "Read luminance", .on_click = cx.on(Actions, state, Actions.luminance) }).mount(scope, cx);
    lum_button.meta.ownership.meta.test_id = "gallery.luminance";
    try lum_row.appendChild(cx.allocator, lum_button);
    const solid_button = try ui.widgets.Button(.{ .label = "Solid backgrounds", .on_click = cx.on(Actions, state, Actions.solidBackdrop) }).mount(scope, cx);
    solid_button.meta.ownership.meta.test_id = "gallery.luminance-solid";
    try lum_row.appendChild(cx.allocator, solid_button);
    const retained_button = try ui.widgets.Button(.{ .label = "Retained contract", .on_click = cx.on(Actions, state, Actions.retained) }).mount(scope, cx);
    retained_button.meta.ownership.meta.test_id = "gallery.retained";
    try lum_row.appendChild(cx.allocator, retained_button);
    luminance_status = try ui.text(cx, "", .{ .font_size = 12, .color = ui.Color.WHITE });
    luminance_status.meta.ownership.meta.test_id = "gallery.luminance-status";
    const gradient_button = try ui.widgets.Button(.{ .label = "Gradients", .on_click = cx.on(Actions, state, Actions.gradients) }).mount(scope, cx);
    gradient_button.meta.ownership.meta.test_id = "gallery.gradients";
    try lum_row.appendChild(cx.allocator, gradient_button);
    const dialogs_button = try ui.widgets.Button(.{ .label = "Native dialogs", .on_click = cx.on(Actions, state, Actions.dialogs) }).mount(scope, cx);
    dialogs_button.meta.ownership.meta.test_id = "gallery.dialogs";
    try lum_row.appendChild(cx.allocator, dialogs_button);
    const drops_button = try ui.widgets.Button(.{ .label = "OLE drops", .on_click = cx.on(Actions, state, Actions.drops) }).mount(scope, cx);
    drops_button.meta.ownership.meta.test_id = "gallery.drops";
    try lum_row.appendChild(cx.allocator, drops_button);
    const noise_button = try ui.widgets.Button(.{ .label = "Noise", .on_click = cx.on(Actions, state, Actions.noise) }).mount(scope, cx);
    noise_button.meta.ownership.meta.test_id = "gallery.noise";
    try lum_row.appendChild(cx.allocator, noise_button);
    try lum_row.appendChild(cx.allocator, luminance_status);
    drop_gallery = try drop_contract.mount(app, scope, cx);
    try root.appendChild(cx.allocator, drop_gallery);
    dialog_gallery = try dialog_contract.mount(app, scope, cx);
    try root.appendChild(cx.allocator, dialog_gallery);
    noise_gallery = try noise_contract.mount(cx, scope);
    try root.appendChild(cx.allocator, noise_gallery);
    gradient_gallery = try scrollFixture(cx, scope, try gradient_contract.mount(cx));
    try root.appendChild(cx.allocator, gradient_gallery);
    try retained_contract.mount(app, cx, scope);
    return root;
}

pub fn main(init: std.process.Init) !void {
    if (try @import("windows_open_file_contract.zig").dispatchChild(init)) return;
    var reused = init_contract.ReusedAllocator{};
    // Startup contracts create temporary windows and require harness capture.
    // Run them only in test builds; an ordinary launch should open the gallery.
    if (@import("zenit_app").test_harness.enabled) try reused.beforeReuse(init.io);
    app = try App.init(reused.allocator(), .{ .io = init.io, .window = .{ .width = 800, .height = 600, .title = "Zenit Windows Render Gallery" }, .clear_color = .{ .r = 20.0 / 255.0, .g = 40.0 / 255.0, .b = 60.0 / 255.0, .a = 1 } });
    defer app.deinit();
    if (@import("zenit_app").test_harness.enabled) try reused.afterReuse(app);
    // Reject malformed uploads through the public facade before native access.
    if (app.renderer.image_renderer.loadTexture(0, 2, &quadrant)) |_| return error.AcceptedZeroWidth else |_| {}
    if (app.renderer.image_renderer.loadTexture(2, 2, quadrant[0..4])) |_| return error.AcceptedShortPixels else |_| {}
    quadrant_id = try app.renderer.image_renderer.loadTexture(2, 2, &quadrant);
    white_id = try app.renderer.image_renderer.loadTexture(1, 1, &.{ 255, 255, 255, 255 });
    const size = app.renderer.image_renderer.getTextureSize(quadrant_id) orelse return error.MissingTexture;
    if (size[0] != 2 or size[1] != 2) return error.WrongTextureSize;
    try app.runWith(mount);
}
