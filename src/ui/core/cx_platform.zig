//! Cx ↔ 平台：SystemSdk 挂载与窗口身份（多窗口 a11y 路由键）、原生文本输入
//! 会话（焦点文本客户端解析、IME 光标矩形 / 丢弃 preedit）、无障碍播报。

const core = @import("../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const TextInputClient = core.TextInputClient;
const a11y_macos_bridge_mod = @import("../a11y/macos_bridge.zig");
const system_sdk_mod = @import("system_sdk");
const text_input_session_mod = @import("text_input_session.zig");

pub fn setSystemSdk(self: *Cx, sdk: *system_sdk_mod.SystemSdk) void {
    // Replacing a live backend must close the old window's input context
    // before its pointer becomes unreachable.
    if (self.system_sdk) |current| {
        if (current != sdk) deactivateTextInputSession(self);
    }
    self.system_sdk = sdk;
    self.cursor_state.submitted = false;
    self.text_input_session.invalidatePlatformState();
    self.focus_manager.a11y_bridge.attachSystemSdk(sdk, self.window_id);
    // Full-tree macOS push notifications target the exact virtual element.
    // Keep the compatibility bridge available for explicit announce/
    // property calls, but suppress its host-view focus announcement.
    self.focus_manager.a11y_bridge.automatic_focus_notifications = false;
    registerNativeTextInputContext(self);
    self.refreshTextInputSession();
}

pub fn setWindowId(self: *Cx, window_id: system_sdk_mod.events.WindowId) void {
    self.setWindowIdentity(window_id, if (window_id == self.window_id)
        self.native_window_id
    else
        @intCast(window_id & 0xFFFF_FFFF));
}

pub fn setWindowIdentity(self: *Cx, window_id: system_sdk_mod.events.WindowId, native_window_id: u32) void {
    if (window_id == self.window_id and native_window_id == self.native_window_id) {
        registerNativeTextInputContext(self);
        self.refreshTextInputSession();
        return;
    }
    // Disable/discard against the old id before changing the routing key.
    deactivateTextInputSession(self);
    // Native query tables use native_window_id. Remove the old owned
    // entries before rebinding so deinit cannot leave a dangling old key.
    a11y_macos_bridge_mod.clearActiveContextForOwner(a11yWindowKey(self), self);
    self.window_id = window_id;
    self.native_window_id = native_window_id;
    self.cursor_state.submitted = false;
    self.focus_manager.a11y_bridge.setWindowId(window_id);
    self.text_input_session.invalidatePlatformState();
    registerNativeTextInputContext(self);
    self.refreshTextInputSession();
}

/// Native bridge callbacks carry NSWindow.windowNumber, not the SDK id.
pub fn a11yWindowKey(self: *const Cx) u32 {
    return self.native_window_id;
}

pub fn clearSystemSdk(self: *Cx) void {
    deactivateTextInputSession(self);
    a11y_macos_bridge_mod.clearTextInputResolverForOwner(a11yWindowKey(self), self);
    self.system_sdk = null;
    self.focus_manager.a11y_bridge.clearSystemSdk();
    self.focus_manager.a11y_bridge.automatic_focus_notifications = true;
}

pub fn focusSettled(context: *anyopaque) void {
    const self: *Cx = @ptrCast(@alignCast(context));
    syncFocusedCache(self);
    self.refreshTextInputSession();
}

pub fn syncFocusedCache(self: *Cx) void {
    self.focused_node = self.focus_manager.getFocused();
    self.focused_handle = if (self.focused_node) |node| self.node_registry.handleFor(node) else null;
}

fn resolveFocusedTextInputClient(context: *anyopaque) ?TextInputClient {
    const self: *Cx = @ptrCast(@alignCast(context));
    const focused = self.focus_manager.getFocused() orelse return null;
    // A client without an event sink could answer native queries but could
    // never consume the resulting commit/preedit packets. Fail closed.
    if (focused.behavior.events.on_event == null) return null;
    return focused.behavior.interaction.text_input_client;
}

fn registerNativeTextInputContext(self: *Cx) void {
    if (!a11y_macos_bridge_mod.setTextInputResolver(
        a11yWindowKey(self),
        self,
        &resolveFocusedTextInputClient,
    )) core.a11y_context_register_failures +%= 1;
}

pub fn refreshTextInputSession(self: *Cx) void {
    const focused = self.focus_manager.getFocused();
    const next_node: ?NodeHandle = if (focused) |node| blk: {
        if (node.behavior.events.on_event == null or
            node.behavior.interaction.text_input_client == null) break :blk null;
        break :blk self.node_registry.handleFor(node);
    } else null;
    const next_context: ?*anyopaque = if (focused) |node|
        if (node.behavior.events.on_event != null)
            if (node.behavior.interaction.text_input_client) |client| client.context else null
        else
            null
    else
        null;
    // 焦点解析留在 Cx（要碰 focus_manager / node_registry），对账交给
    // 状态机（三态语义与下发失败重试在那里，可独立单测）。
    self.text_input_session.reconcile(
        .{ .node = next_node, .context = next_context },
        textInputHost(self),
    );
}

pub fn deactivateTextInputSession(self: *Cx) void {
    self.text_input_session.deactivate(textInputHost(self));
}

/// 把 Cx 的平台能力包成状态机要的 Host（它不该知道 system_sdk）。
fn textInputHost(self: *Cx) text_input_session_mod.Host {
    const Adapter = struct {
        fn setEnabled(ctx: *anyopaque, enabled: bool) bool {
            const cx: *Cx = @ptrCast(@alignCast(ctx));
            return setTextInputEnabled(cx, enabled);
        }
        fn discardIme(ctx: *anyopaque) void {
            const cx: *Cx = @ptrCast(@alignCast(ctx));
            _ = discardPlatformIme(cx);
        }
    };
    return .{ .ctx = @ptrCast(self), .setEnabled = Adapter.setEnabled, .discardIme = Adapter.discardIme };
}

pub fn announceAccessibilityText(self: *Cx, announce_text: []const u8) void {
    self.focus_manager.a11y_bridge.announceText(announce_text);
}

pub fn notifyAccessibilityPropertyChange(self: *Cx, node: *Node) void {
    self.focus_manager.a11y_bridge.notifyPropertyChange(node);
}

pub fn setImeCursorRect(self: *Cx, x: f32, y: f32, width: f32, height: f32) bool {
    const sdk = self.system_sdk orelse return false;
    sdk.setImeCursorRect(self.window_id, x, y, width, height) catch return false;
    return true;
}

pub fn measureTextWidthCallback(context: *anyopaque, text_ptr: [*]const u8, text_len: usize, font_size: f32, font_weight: u16, italic: bool) f32 {
    const self: *Cx = @ptrCast(@alignCast(context));
    return self.text.measureTextWidth(text_ptr[0..text_len], font_size, font_weight, italic);
}

/// TextInputSession-only backend transition. Keeping this private makes a
/// second component/app-level owner a compile-time error.
fn setTextInputEnabled(self: *Cx, enabled: bool) bool {
    const sdk = self.system_sdk orelse return false;
    sdk.setTextInputEnabled(self.window_id, enabled) catch return false;
    return true;
}

/// TextInputSession-only composition teardown.
fn discardPlatformIme(self: *Cx) bool {
    const sdk = self.system_sdk orelse return false;
    sdk.discardIme(self.window_id) catch return false;
    return true;
}
