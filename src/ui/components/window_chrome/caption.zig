//! Platform caption slots. Geometry from the window contract, UI lifetime from Scope.
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const reactive = @import("../../reactive.zig");
const bind = @import("../../bind.zig");
const Button = @import("../button/mod.zig").Button;
const assets = @import("../../svg_assets.zig");
pub const chrome = @import("system_sdk").window_chrome;
pub const Props = struct {
    automatic_only: bool = false,
    state: ?*reactive.Signal(chrome.State) = null,
    appearance: ?chrome.Appearance = null,
    layout: ?chrome.ButtonLayout = null,
    side: chrome.ControlSide = .both,
    native_regions: ?bool = null,
    fullscreen_controls: bool = false,
    /// Caption row height. Windows buttons fill it (a 48 px "tall" title bar gets 46 x 48
    /// buttons, glyphs centred like the rest of the bar); round Linux buttons centre in it.
    height: f32 = 38,
    /// Windows button width; null keeps the system's 46. Round Linux buttons ignore it.
    windows_button_width: ?f32 = null,
    on_action: ?core.Handler(chrome.Action) = null,
    close_label: []const u8 = "Close window",
    minimize_label: []const u8 = "Minimize window",
    maximize_label: []const u8 = "Maximize window",
    restore_label: []const u8 = "Restore window",
    exit_fullscreen_label: []const u8 = "Exit fullscreen",
};
pub fn WindowControls(props: Props) Controls {
    return .{ .props = props };
}
const Pointer = struct { hover: bool = false, pressed: bool = false };
const Context = struct {
    cx: *core.Cx,
    state: *reactive.Signal(chrome.State),
    pointer: *reactive.Signal(Pointer),
    control: chrome.Control,
    props: Props,
    fn invoke(c: *Context) void {
        const action: chrome.Action = switch (c.control) {
            .minimize => .minimize,
            .maximize => if (c.state.peek().fullscreen) .{ .fullscreen = false } else .toggle_maximize,
            .close => .close,
            .none => return,
        };
        if (c.props.on_action) |handler| handler.call(action) else c.cx.performWindowAction(action) catch |err| std.log.warn("Window action: {s}", .{@errorName(err)});
    }
    fn event(ev: core.Event, context: ?*anyopaque) core.EventResult {
        const c: *Context = @ptrCast(@alignCast(context orelse return .ignored));
        var p = c.pointer.peek();
        switch (ev) {
            .mouse_enter => p.hover = true,
            .mouse_leave, .blur => {
                p.hover = false;
                p.pressed = false;
            },
            .mouse_down => |e| {
                if (e.button == .left) p.pressed = true;
            },
            .mouse_up => p.pressed = false,
            else => return .ignored,
        }
        c.pointer.set(p);
        return .ignored;
    }
    fn look(c: *Context) Look {
        const s = c.state.get();
        const p = c.pointer.get();
        const native = (c.props.native_regions orelse (c.props.state == null and c.props.on_action == null)) and s.appearance == .windows and s.effective_mode == .custom and !s.fullscreen;
        return .{ .appearance = c.props.appearance orelse s.appearance, .control = c.control, .restore = s.maximized or s.fullscreen, .active = s.active, .hover = if (native) s.caption_hover == c.control else p.hover, .pressed = if (native) s.caption_pressed == c.control else p.pressed };
    }
};
const Look = struct {
    appearance: chrome.Appearance,
    control: chrome.Control,
    restore: bool,
    active: bool,
    hover: bool,
    pressed: bool,
    fn tint(l: Look) core.Color {
        if (l.control == .close and l.hover and (l.appearance == .windows or l.appearance == .breeze)) return core.Color.WHITE;
        return if (l.active) core.Color.hex(0x1d1d1f) else core.Color.rgba(0x1d, 0x1d, 0x1f, 92);
    }
    fn background(l: Look) core.Color {
        if (l.appearance == .adwaita) return core.Color.rgba(0, 0, 0, if (l.pressed) 77 else if (l.hover) 38 else 26);
        if (l.control == .close and l.hover) return core.Color.hex(if (l.appearance == .breeze) 0xda4453 else if (l.pressed) 0xc83f31 else 0xc42b1c);
        return core.Color.rgba(0, 0, 0, if (l.pressed) 26 else if (l.hover) 15 else 0);
    }
    fn asset(l: Look) assets.Asset {
        const glyphs = @import("caption_assets.zig");
        return switch (l.appearance) {
            .windows => switch (l.control) {
                .minimize => glyphs.win_min,
                .maximize => if (l.restore) glyphs.win_restore else glyphs.win_max,
                else => glyphs.win_close,
            },
            .breeze => switch (l.control) {
                .minimize => glyphs.breeze_min,
                .maximize => if (l.restore) glyphs.breeze_restore else glyphs.breeze_max,
                else => glyphs.breeze_close,
            },
            else => switch (l.control) {
                .minimize => glyphs.adwaita_min,
                .maximize => if (l.restore) glyphs.adwaita_restore else glyphs.adwaita_max,
                else => glyphs.adwaita_close,
            },
        };
    }
};
const Controls = struct {
    props: Props,
    pub fn mount(self: Controls, parent_scope: *core.Scope, cx: *core.Cx) !*core.Node {
        const scope = try parent_scope.childScope();
        errdefer scope.dispose();
        const signal = self.props.state orelse try cx.windowChrome();
        const root = try view.render(scope, cx, view.row(.{ .window_region = .client, .style = .{ .height = self.props.height, .align_items = .center } }, .{}));
        errdefer cx.destroyDetached(root);
        var buttons: [3]*core.Node = undefined;
        inline for (.{ chrome.Control.minimize, chrome.Control.maximize, chrome.Control.close }, 0..) |control, i| {
            const c = try scope.createState(Context, .{ .cx = cx, .state = signal, .pointer = try scope.createSignal(Pointer, .{}), .control = control, .props = self.props });
            const look = try scope.createMemo(Look, c, Context.look);
            const icon = try scope.createMemo(?assets.Asset, look, struct {
                fn read(s: *reactive.Memo(Look)) ?assets.Asset {
                    return s.get().asset();
                }
            }.read);
            const tint = try scope.createMemo(?core.Color, look, struct {
                fn read(s: *reactive.Memo(Look)) ?core.Color {
                    return s.get().tint();
                }
            }.read);
            const s = signal.peek();
            const appearance = self.props.appearance orelse s.appearance;
            const width: f32 = if (appearance == .windows) self.props.windows_button_width orelse 46 else if (appearance == .breeze) 18 else 24;
            buttons[i] = try Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = if (appearance == .windows) @as(f32, 10) else @as(f32, 8), .icon_tint = tint, .a11y_label = switch (control) {
                .minimize => self.props.minimize_label,
                .maximize => self.props.maximize_label,
                .close => self.props.close_label,
                else => "",
            }, .on_click = cx.on(Context, c, Context.invoke), .on_event = Context.event, .event_context = @as(?*anyopaque, @ptrCast(c)), .base_style = .{ .width = .{ .px = width }, .height = .{ .px = self.props.height }, .padding = core.Padding.all(0), .border = .{ .radius = 0 }, .background = core.Color.TRANSPARENT }, .hover_style = core.BoxStyle{ .background = core.Color.TRANSPARENT }, .pressed_style = core.BoxStyle{ .background = core.Color.TRANSPARENT } }).mount(scope, cx);
            // The caption runtime keeps this array and installs native hooks.
            @import("../../view.zig").pinComponentRoot(buttons[i]);
            buttons[i].meta.ownership.meta.test_id = switch (control) {
                .minimize => "window.controls.minimize",
                .maximize => "window.controls.maximize",
                .close => "window.controls.close",
                else => unreachable,
            };
            _ = try core.adoptChild(cx, cx.allocator, root, buttons[i]);
            const circle = try view.render(scope, cx, view.box(.{ .hit_test = false, .style = .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = if (appearance == .windows) @as(f32, 0) else (self.props.height - width) / 2 } }, .width = width, .height = if (appearance == .windows) self.props.height else width, .border = .{ .radius = if (appearance == .windows) @as(f32, 0) else width / 2 } } }, .{}));
            var circle_orphan = true;
            errdefer if (circle_orphan) cx.destroyDetached(circle);
            try buttons[i].insertChildBefore(cx.allocator, circle, if (buttons[i].children.items.len > 0) buttons[i].children.items[0] else null);
            circle_orphan = false;
            try bind.bind(scope, look, .{ .node = circle, .allocator = cx.allocator }, struct {
                fn update(b: anytype, l: Look) error{OutOfMemory}!void {
                    try b.node.setStyleInlineFallible(b.allocator, .{ .background = l.background(), .opacity = if (l.active or l.appearance == .windows) @as(f32, 1) else @as(f32, 0.5) });
                }
            }.update);
        }
        const Binding = struct {
            root: *core.Node,
            buttons: [3]*core.Node,
            props: Props,
            allocator: std.mem.Allocator,
            /// All or nothing: the inline style is staged and the child order (transactional)
            /// replaced before anything else changes. The first run is part of the mount.
            fn update(b: @This(), s: chrome.State) !void {
                var ordered: [3]*core.Node = undefined;
                var count: usize = 0;
                var seen: u8 = 0;
                const layout = b.props.layout orelse s.button_layout;
                for ([_][3]chrome.Control{ layout.left, layout.right }, 0..) |side, side_index| {
                    if ((b.props.side == .left and side_index == 1) or (b.props.side == .right and side_index == 0)) continue;
                    for (side) |control| {
                        if (control == .none) continue;
                        const index: usize = @intCast(@backingInt(control) - 1);
                        const bit = @as(u8, 1) << @as(u3, @intCast(index));
                        if (seen & bit != 0) continue;
                        seen |= bit;
                        if (control == .minimize and !s.capabilities.minimize) continue;
                        if (control == .maximize and !s.capabilities.maximize and !(s.fullscreen and s.capabilities.fullscreen)) continue;
                        if (count < 3) {
                            ordered[count] = b.buttons[index];
                            count += 1;
                        }
                    }
                }
                var all = ordered;
                var n = count;
                for (b.buttons) |button| {
                    var found = false;
                    for (ordered[0..count]) |active| {
                        if (active == button) found = true;
                    }
                    if (!found) {
                        all[n] = button;
                        n += 1;
                    }
                }
                const appearance = b.props.appearance orelse s.appearance;
                const staged = try b.root.stageStyleInline(b.allocator, .{ .gap = if (appearance == .windows) @as(f32, 0) else if (appearance == .breeze) @as(f32, 8) else @as(f32, 12), .padding = core.Padding.symmetric(0, if (appearance == .windows) @as(f32, 0) else if (appearance == .breeze) @as(f32, 10) else @as(f32, 8)) });
                b.root.replaceChildOrder(b.allocator, &all) catch |err| {
                    staged.abort();
                    return err;
                };
                staged.commit();
                for (b.buttons) |button| {
                    var found = false;
                    for (ordered[0..count]) |active| {
                        if (active == button) found = true;
                    }
                    button.setDisplay(if (found) .flex else .none);
                }
                const visible = if (b.props.automatic_only) s.controls_owner == .framework else s.controls_owner != .native;
                b.root.setDisplay(if (count > 0 and visible and (!s.fullscreen or b.props.fullscreen_controls)) .flex else .none);
                for (b.buttons, 0..) |button, i| button.behavior.interaction.window_region = if ((b.props.native_regions orelse (b.props.state == null and b.props.on_action == null)) and s.appearance == .windows and s.effective_mode == .custom and !s.fullscreen) @fromBackingInt(@intCast(11 + i)) else .client;
                if (b.buttons[1].behavior.interaction.a11y) |*a| a.label = if (s.fullscreen) b.props.exit_fullscreen_label else if (s.maximized) b.props.restore_label else b.props.maximize_label;
            }
        };
        try bind.bind(scope, signal, Binding{ .root = root, .buttons = buttons, .props = self.props, .allocator = cx.allocator }, Binding.update);
        try core.Cx.bindScopeToNode(scope, root);
        return root;
    }
};
