const std = @import("std");
const Allocator = std.mem.Allocator;

const backend_mod = @import("vtable.zig");
const events_mod = @import("events.zig");
const capabilities_mod = @import("capabilities.zig");
const accessibility_mod = @import("accessibility.zig");
const platform = @import("platform");
const SdkError = @import("errors.zig").SdkError;

pub const ClipboardKinds = packed struct {
    text: bool = false,
    image: bool = false,
    file_urls: bool = false,
};

pub const ClipboardImage = backend_mod.ClipboardImage;

pub const SystemSdk = struct {
    allocator: Allocator,
    backend_ctx: *anyopaque,
    vtable: *const backend_mod.BackendVTable,
    capabilities: capabilities_mod.Capabilities,
    event_queue: events_mod.EventQueue,
    owner_thread_id: std.Thread.Id,
    /// runtime 正在遍历 events() 借出的切片。此期间重入 pump() 会先
    /// clear() 释放正被遍历的 payload（UAF）——用断言把契约钉死
    /// （对齐 MultiWindowApp 的 iterating 先例）。
    dispatching: bool = false,

    pub fn init(
        allocator: Allocator,
        backend_ctx: *anyopaque,
        vtable: *const backend_mod.BackendVTable,
        capabilities: capabilities_mod.Capabilities,
    ) SystemSdk {
        return .{
            .allocator = allocator,
            .backend_ctx = backend_ctx,
            .vtable = vtable,
            .capabilities = capabilities,
            .event_queue = events_mod.EventQueue.init(allocator),
            .owner_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn deinit(self: *SystemSdk) void {
        std.debug.assert(self.owner_thread_id == std.Thread.getCurrentId());
        self.event_queue.deinit();
        self.vtable.deinit(self.backend_ctx, self.allocator);
    }

    fn ensureOwnerThread(self: *const SystemSdk) SdkError!void {
        if (self.owner_thread_id != std.Thread.getCurrentId()) return SdkError.WrongThread;
    }

    pub fn getCapabilities(self: *const SystemSdk) capabilities_mod.Capabilities {
        return self.capabilities;
    }

    pub fn events(self: *const SystemSdk) []const events_mod.Event {
        return self.event_queue.items();
    }

    pub fn pump(self: *SystemSdk, timeout_ms: u32) SdkError!backend_mod.PumpResult {
        try self.ensureOwnerThread();
        // events() 切片遍历期间禁止重入：clear() 会释放正被遍历的 payload
        std.debug.assert(!self.dispatching);
        self.event_queue.clear();
        return self.vtable.pump_events(self.backend_ctx, &self.event_queue, timeout_ms);
    }

    /// Request feedback only for a user action. The OS may suppress physical
    /// output based on current input hardware, contact, and user preferences.
    pub fn performHapticFeedback(self: *SystemSdk, pattern: backend_mod.HapticFeedbackPattern) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.haptic_feedback)) return SdkError.NotSupported;
        const perform = self.vtable.perform_haptic_feedback orelse return SdkError.NotSupported;
        try perform(self.backend_ctx, pattern);
    }

    pub fn requestRedraw(self: *SystemSdk) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.request_redraw)) return SdkError.NotSupported;
        const func = self.vtable.request_redraw orelse return SdkError.NotSupported;
        try func(self.backend_ctx);
    }

    /// 静默同步输入状态（不产生事件）。
    /// 在 liveResize 等系统代理鼠标的场景结束后调用，
    /// 防止恢复轮询时 emitMouseButtonDelta 产生虚假事件。
    pub fn syncInputState(self: *SystemSdk) void {
        std.debug.assert(self.owner_thread_id == std.Thread.getCurrentId());
        if (self.vtable.sync_input_state) |func| {
            func(self.backend_ctx);
        }
    }

    pub fn clipboardSetText(self: *SystemSdk, text: []const u8) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        try api.set_text(self.backend_ctx, text);
    }

    pub fn clipboardGetText(self: *SystemSdk, buffer: []u8) SdkError![]const u8 {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        return api.get_text(self.backend_ctx, buffer);
    }

    /// 动态分配版：查询剪贴板文本长度后按需分配缓冲区
    pub fn clipboardGetTextAlloc(self: *SystemSdk, alloc: Allocator) SdkError!?[]const u8 {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const get_len = api.get_text_len orelse return SdkError.NotSupported;
        return self.readClipboardAlloc(alloc, get_len, api.get_text);
    }

    /// 富文本写入：plain text + 可选 HTML 写入同一 pasteboard item 的多 representation。
    /// RTF 暂不支持（macOS HTML→RTF 依赖 WebKit 主线程转换，见 backend 注释）。
    pub fn clipboardSetRichText(self: *SystemSdk, rich: backend_mod.ClipboardRichText) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        try rich.validate();
        const set_rich = api.set_rich_text orelse return SdkError.NotSupported;
        try set_rich(self.backend_ctx, rich);
    }

    /// 读取剪贴板 HTML representation（动态分配）。null = 剪贴板无 HTML；
    /// 是否回退 plain text（clipboardGetTextAlloc）由调用方决定。
    pub fn clipboardGetHtmlAlloc(self: *SystemSdk, alloc: Allocator) SdkError!?[]const u8 {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const get_len = api.get_html_len orelse return SdkError.NotSupported;
        const get_html = api.get_html orelse return SdkError.NotSupported;
        return self.readClipboardAlloc(alloc, get_len, get_html);
    }

    /// Query/read are separate OS operations. Retry boundedly on content growth;
    /// every nonempty successful result is an exact allocator-owned slice.
    fn readClipboardAlloc(
        self: *SystemSdk,
        alloc: Allocator,
        get_len: *const fn (*anyopaque) SdkError!usize,
        get: *const fn (*anyopaque, []u8) SdkError![]const u8,
    ) SdkError!?[]const u8 {
        for (0..3) |attempt| {
            const len = try get_len(self.backend_ctx);
            if (len == 0) return null;
            const capacity = std.math.add(usize, len, 1) catch return error.BufferTooSmall;
            const buf = alloc.alloc(u8, capacity) catch return error.OutOfMemory;
            errdefer alloc.free(buf);
            const text = get(self.backend_ctx, buf) catch |err| {
                if (err == error.BufferTooSmall and attempt < 2) {
                    alloc.free(buf);
                    continue;
                }
                return err;
            };
            if (text.len == 0) {
                alloc.free(buf);
                return null;
            }
            const start = @intFromPtr(buf.ptr);
            const address = @intFromPtr(text.ptr);
            if (address < start) return error.BackendFailure;
            const offset = address - start;
            if (offset > buf.len or text.len > buf.len - offset) return error.BackendFailure;
            // A backend may return an interior slice; move it to the allocation
            // base before shrinking, so callers can free the returned pointer.
            if (offset != 0) std.mem.copyForwards(u8, buf[0..text.len], text);
            if (text.len == buf.len) return buf;
            // On failure errdefer releases the original, still-live allocation.
            return alloc.realloc(buf, text.len) catch return error.OutOfMemory;
        }
        unreachable;
    }

    /// 探测剪贴板可提供的类型。不解码，成本极低，可在每次 Cmd+V 时调用。
    pub fn clipboardProbe(self: *SystemSdk) SdkError!ClipboardKinds {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard_image)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const probe = api.probe orelse return SdkError.NotSupported;
        const kinds = probe(self.backend_ctx);
        return .{
            .text = (kinds & 1) != 0,
            .image = (kinds & 2) != 0,
            .file_urls = (kinds & 4) != 0,
        };
    }

    /// 剪贴板中的图片项数（支持 Finder 多选复制）
    pub fn clipboardImageCount(self: *SystemSdk) SdkError!usize {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard_image)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const image_count = api.image_count orelse return SdkError.NotSupported;
        return image_count(self.backend_ctx);
    }

    /// 读取第 index 项剪贴板图片并解码为 premultiplied RGBA8。
    /// null = 该 index 无图片。返回值用 `ClipboardImage.deinit(alloc)` 释放。
    pub fn clipboardGetImageAlloc(self: *SystemSdk, alloc: Allocator, index: usize) SdkError!?ClipboardImage {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard_image)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const get_image = api.get_image orelse return SdkError.NotSupported;
        return get_image(self.backend_ctx, alloc, index);
    }

    /// 写入 PNG 编码图片到剪贴板（清空原内容）
    pub fn clipboardSetImagePng(self: *SystemSdk, png_bytes: []const u8) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.clipboard_image)) return SdkError.NotSupported;
        const api = self.vtable.clipboard orelse return SdkError.NotSupported;
        const set_image = api.set_image_png orelse return SdkError.NotSupported;
        return set_image(self.backend_ctx, png_bytes);
    }

    /// 弹出原生文件对话框（同步阻塞）。返回写入 buffer 的路径 slice；null = 用户取消。
    pub fn runDialog(self: *SystemSdk, request: backend_mod.DialogRequest, buffer: []u8) SdkError!?[]const u8 {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.file_dialog)) return SdkError.NotSupported;
        const api = self.vtable.dialog orelse return SdkError.NotSupported;
        return api.run(self.backend_ctx, request, buffer);
    }

    pub fn setMenuModel(self: *SystemSdk, model: backend_mod.MenuModel) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.menu_bar)) return SdkError.NotSupported;
        try model.validate();
        const menu = self.vtable.menu orelse return SdkError.NotSupported;
        try menu.set_model(self.backend_ctx, model);
    }

    /// Begin an AppKit drag session from the current pointer event. The request
    /// is copied synchronously. Completion/cancellation arrives as `.drag`
    /// kind 4 with the returned `source_token`; operation 0 means cancelled.
    pub fn beginDrag(self: *SystemSdk, window_id: events_mod.WindowId, request: backend_mod.DragRequest) SdkError!u64 {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.drag_source)) return SdkError.NotSupported;
        try request.validate();
        const api = self.vtable.drag_source orelse return SdkError.NotSupported;
        return api.start(self.backend_ctx, window_id, request);
    }

    /// Set the window-level destination operation policy. Empty operations
    /// reject incoming drags; AppKit still intersects this with source policy
    /// and keyboard modifiers.
    pub fn setDragTargetOperations(self: *SystemSdk, window_id: events_mod.WindowId, operations: backend_mod.DragOperations) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.drag_drop_target)) return SdkError.NotSupported;
        const api = self.vtable.drag_target orelse return SdkError.NotSupported;
        try api.set_allowed_operations(self.backend_ctx, window_id, operations);
    }

    pub fn setImeCursorRect(self: *SystemSdk, window_id: events_mod.WindowId, x: f32, y: f32, width: f32, height: f32) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.ime)) return SdkError.NotSupported;
        const api = self.vtable.ime orelse return SdkError.NotSupported;
        try api.set_cursor_rect(self.backend_ctx, window_id, x, y, width, height);
    }

    pub fn setTextInputEnabled(self: *SystemSdk, window_id: events_mod.WindowId, enabled: bool) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.ime)) return SdkError.NotSupported;
        const api = self.vtable.ime orelse return SdkError.NotSupported;
        try api.set_enabled(self.backend_ctx, window_id, enabled);
    }

    pub fn discardIme(self: *SystemSdk, window_id: events_mod.WindowId) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.ime)) return SdkError.NotSupported;
        const api = self.vtable.ime orelse return SdkError.NotSupported;
        try api.discard(self.backend_ctx, window_id);
    }

    pub fn setCursorShape(self: *SystemSdk, window_id: events_mod.WindowId, shape: u8) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.cursor)) return SdkError.NotSupported;
        const api = self.vtable.cursor orelse return SdkError.NotSupported;
        try api.set_shape(self.backend_ctx, window_id, shape);
    }

    /// 位图光标是否可用（vtable.cursor.set_custom 存在）。UI 层用它决定
    /// `.custom` 形状是下发位图还是降级到固定形状，避免每次切换都试错。
    pub fn customCursorSupported(self: *const SystemSdk) bool {
        const api = self.vtable.cursor orelse return false;
        return api.set_custom != null;
    }

    pub const CustomCursorRequest = struct {
        /// 预乘 RGBA8，长度必须等于 width*height*4，调用期借用
        rgba: []const u8,
        width: u32,
        height: u32,
        /// 设备像素比（width/scale = 逻辑宽度）
        scale: f32,
        /// 热点，左上原点像素坐标
        hot_x: f32,
        hot_y: f32,
        /// 内容寻址键：同一位图必须同键；后端按键缓存原生光标对象
        key: u64,
    };

    pub fn setCustomCursor(self: *SystemSdk, window_id: events_mod.WindowId, request: CustomCursorRequest) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.cursor)) return SdkError.NotSupported;
        const api = self.vtable.cursor orelse return SdkError.NotSupported;
        const set_custom = api.set_custom orelse return SdkError.NotSupported;
        try set_custom(self.backend_ctx, window_id, request.rgba.ptr, request.rgba.len, request.width, request.height, request.scale, request.hot_x, request.hot_y, request.key);
    }

    pub fn announceAccessibilityText(self: *SystemSdk, window_id: events_mod.WindowId, text: []const u8) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.accessibility)) return SdkError.NotSupported;
        const api = self.vtable.accessibility orelse return SdkError.NotSupported;
        try api.announce_text(self.backend_ctx, window_id, text);
    }

    pub fn notifyAccessibilityFocus(self: *SystemSdk, window_id: events_mod.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.accessibility)) return SdkError.NotSupported;
        const api = self.vtable.accessibility orelse return SdkError.NotSupported;
        try api.notify_focus(self.backend_ctx, window_id, snapshot);
    }

    pub fn notifyAccessibilityPropertyChange(self: *SystemSdk, window_id: events_mod.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.accessibility)) return SdkError.NotSupported;
        const api = self.vtable.accessibility orelse return SdkError.NotSupported;
        try api.notify_property_change(self.backend_ctx, window_id, snapshot);
    }

    /// Register an additional window. The backend copies/retains only the
    /// platform window value needed for synchronous event pumping.
    pub fn registerWindow(self: *SystemSdk, window: *platform.Window, window_id: events_mod.WindowId) SdkError!void {
        try self.ensureOwnerThread();
        if (window_id == 0) return SdkError.InvalidState;
        if (!self.capabilities.has(.multi_window)) return SdkError.NotSupported;
        const register = self.vtable.register_window orelse return SdkError.NotSupported;
        try register(self.backend_ctx, window, window_id);
    }

    /// Invalidate all window-owned operations before the native window dies.
    pub fn unregisterWindow(self: *SystemSdk, window_id: events_mod.WindowId) SdkError!void {
        try self.ensureOwnerThread();
        if (window_id == 0) return SdkError.InvalidState;
        if (!self.capabilities.has(.multi_window)) return SdkError.NotSupported;
        const unregister = self.vtable.unregister_window orelse return SdkError.NotSupported;
        unregister(self.backend_ctx, window_id);
    }

    /// Borrowed native handle; valid only until `unregisterWindow` for this id.
    pub fn rawWindowHandle(self: *SystemSdk, window_id: events_mod.WindowId) SdkError!*anyopaque {
        try self.ensureOwnerThread();
        if (!self.capabilities.has(.raw_window_handle)) return SdkError.NotSupported;
        const get_handle = self.vtable.raw_window_handle orelse return SdkError.NotSupported;
        return get_handle(self.backend_ctx, window_id);
    }
};

const MockBackend = struct {
    clipboard_store: [256]u8 = [_]u8{0} ** 256,
    clipboard_len: usize = 0,
    clipboard_html_store: [256]u8 = [_]u8{0} ** 256,
    clipboard_html_len: usize = 0,
    redraw_requests: u32 = 0,
    announce_requests: u32 = 0,
    focus_notifications: u32 = 0,
    property_notifications: u32 = 0,
    last_announcement: [128]u8 = [_]u8{0} ** 128,
    last_announcement_len: usize = 0,
    last_focus_snapshot: accessibility_mod.NodeSnapshot = .{},
    last_property_snapshot: accessibility_mod.NodeSnapshot = .{},

    fn deinit(_: *anyopaque, _: Allocator) void {}

    fn pump(_: *anyopaque, queue: *events_mod.EventQueue, timeout_ms: u32) SdkError!backend_mod.PumpResult {
        _ = timeout_ms;
        try queue.push(.{ .window_resized = .{
            .window_id = 1,
            .width = 800,
            .height = 600,
            .scale_factor = 2.0,
        } });
        try queue.push(.{ .text_input = .{
            .window_id = 1,
            .text = "hello",
        } });
        return .{ .should_continue = true };
    }

    fn requestRedraw(ctx: *anyopaque) SdkError!void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        self.redraw_requests += 1;
    }

    fn clipboardSet(ctx: *anyopaque, text: []const u8) SdkError!void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (text.len > self.clipboard_store.len) return SdkError.BufferTooSmall;
        @memcpy(self.clipboard_store[0..text.len], text);
        self.clipboard_len = text.len;
    }

    fn clipboardGet(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (buffer.len < self.clipboard_len) return SdkError.BufferTooSmall;
        @memcpy(buffer[0..self.clipboard_len], self.clipboard_store[0..self.clipboard_len]);
        return buffer[0..self.clipboard_len];
    }

    fn clipboardSetRich(ctx: *anyopaque, rich: backend_mod.ClipboardRichText) SdkError!void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (rich.text.len > self.clipboard_store.len) return SdkError.BufferTooSmall;
        @memcpy(self.clipboard_store[0..rich.text.len], rich.text);
        self.clipboard_len = rich.text.len;
        self.clipboard_html_len = 0;
        if (rich.html) |h| {
            if (h.len > self.clipboard_html_store.len) return SdkError.BufferTooSmall;
            @memcpy(self.clipboard_html_store[0..h.len], h);
            self.clipboard_html_len = h.len;
        }
    }

    fn clipboardGetHtmlLen(ctx: *anyopaque) SdkError!usize {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        return self.clipboard_html_len;
    }

    fn clipboardGetHtml(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (buffer.len < self.clipboard_html_len) return SdkError.BufferTooSmall;
        @memcpy(buffer[0..self.clipboard_html_len], self.clipboard_html_store[0..self.clipboard_html_len]);
        return buffer[0..self.clipboard_html_len];
    }

    fn announceAccessibility(ctx: *anyopaque, window_id: events_mod.WindowId, text: []const u8) SdkError!void {
        _ = window_id;
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (text.len > self.last_announcement.len) return SdkError.BufferTooSmall;
        @memcpy(self.last_announcement[0..text.len], text);
        self.last_announcement_len = text.len;
        self.announce_requests += 1;
    }

    fn notifyAccessibilityFocus(ctx: *anyopaque, window_id: events_mod.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        _ = window_id;
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        self.last_focus_snapshot = snapshot;
        self.focus_notifications += 1;
    }

    fn notifyAccessibilityPropertyChange(ctx: *anyopaque, window_id: events_mod.WindowId, snapshot: accessibility_mod.NodeSnapshot) SdkError!void {
        _ = window_id;
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        self.last_property_snapshot = snapshot;
        self.property_notifications += 1;
    }

    fn rawWindowHandle(ctx: *anyopaque, _: events_mod.WindowId) SdkError!*anyopaque {
        return ctx;
    }
};

test "SystemSdk: pump + clipboard + request redraw" {
    var backend = MockBackend{};

    const vtable = backend_mod.BackendVTable{
        .name = "mock",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .request_redraw = MockBackend.requestRedraw,
        .clipboard = .{
            .set_text = MockBackend.clipboardSet,
            .get_text = MockBackend.clipboardGet,
        },
    };

    var sdk = SystemSdk.init(
        std.testing.allocator,
        &backend,
        &vtable,
        .{
            .clipboard = true,
            .request_redraw = true,
            .multi_window = true,
            .ime = true,
        },
    );
    defer sdk.deinit();

    _ = try sdk.pump(0);
    try std.testing.expectEqual(@as(usize, 2), sdk.events().len);

    switch (sdk.events()[0]) {
        .window_resized => |e| {
            try std.testing.expectEqual(@as(u32, 800), e.width);
            try std.testing.expectEqual(@as(u32, 600), e.height);
        },
        else => return error.UnexpectedEventType,
    }

    try sdk.clipboardSetText("zenit");
    var read_buf: [16]u8 = undefined;
    const text = try sdk.clipboardGetText(&read_buf);
    try std.testing.expectEqualStrings("zenit", text);

    try sdk.requestRedraw();
    try std.testing.expectEqual(@as(u32, 1), backend.redraw_requests);
}

test "SystemSdk: rich clipboard writes text+HTML, HTML read falls back to null" {
    var backend = MockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-rich-clipboard",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .clipboard = .{
            .set_text = MockBackend.clipboardSet,
            .get_text = MockBackend.clipboardGet,
            .set_rich_text = MockBackend.clipboardSetRich,
            .get_html_len = MockBackend.clipboardGetHtmlLen,
            .get_html = MockBackend.clipboardGetHtml,
        },
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .clipboard = true });
    defer sdk.deinit();

    // 只有 plain text：HTML 读取返回 null
    try sdk.clipboardSetRichText(.{ .text = "plain" });
    try std.testing.expectEqual(@as(?[]const u8, null), try sdk.clipboardGetHtmlAlloc(std.testing.allocator));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("plain", try sdk.clipboardGetText(&buf));

    // text + HTML 双 representation
    try sdk.clipboardSetRichText(.{ .text = "hello", .html = "<b>hello</b>" });
    const html = (try sdk.clipboardGetHtmlAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<b>hello</b>", html);
    try std.testing.expectEqualStrings("hello", try sdk.clipboardGetText(&buf));

    // 参数校验在 SDK 层拦截
    try std.testing.expectError(SdkError.InvalidState, sdk.clipboardSetRichText(.{ .text = "" }));
    try std.testing.expectError(SdkError.InvalidState, sdk.clipboardSetRichText(.{ .text = "x", .html = "" }));
}

test "SystemSdk: rich clipboard is NotSupported when backend lacks the hooks" {
    var backend = MockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-plain-clipboard",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .clipboard = .{
            .set_text = MockBackend.clipboardSet,
            .get_text = MockBackend.clipboardGet,
        },
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .clipboard = true });
    defer sdk.deinit();
    try std.testing.expectError(SdkError.NotSupported, sdk.clipboardSetRichText(.{ .text = "x" }));
    try std.testing.expectError(SdkError.NotSupported, sdk.clipboardGetHtmlAlloc(std.testing.allocator));
}

const DialogMockBackend = struct {
    cancel_next: bool = false,

    fn deinit(_: *anyopaque, _: Allocator) void {}
    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) SdkError!backend_mod.PumpResult {
        return .{ .should_continue = true };
    }
    fn dialogRun(ctx: *anyopaque, request: backend_mod.DialogRequest, path_buffer: []u8) SdkError!?[]const u8 {
        const self: *DialogMockBackend = @ptrCast(@alignCast(ctx));
        if (self.cancel_next) return null;
        const path = switch (request.kind) {
            .open_file => "/tmp/picked.txt",
            .save_file => "/tmp/saved.txt",
            .pick_folder => "/tmp/dir",
        };
        if (path_buffer.len < path.len) return SdkError.BufferTooSmall;
        @memcpy(path_buffer[0..path.len], path);
        return path_buffer[0..path.len];
    }
};

const MenuMockBackend = struct {
    node_count: usize = 0,
    fn deinit(_: *anyopaque, _: Allocator) void {}
    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) SdkError!backend_mod.PumpResult {
        return .{};
    }
    fn setModel(ctx: *anyopaque, model: backend_mod.MenuModel) SdkError!void {
        const self: *MenuMockBackend = @ptrCast(@alignCast(ctx));
        self.node_count = model.nodes.len;
    }
};

test "SystemSdk: validated menu model routes through backend" {
    var backend = MenuMockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-menu",
        .deinit = MenuMockBackend.deinit,
        .pump_events = MenuMockBackend.pump,
        .menu = .{ .set_model = MenuMockBackend.setModel },
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .menu_bar = true });
    defer sdk.deinit();
    const nodes = [_]backend_mod.MenuNode{
        .{ .id = 1, .kind = .menu, .label = "App" },
        .{ .id = 2, .parent_id = 1, .kind = .item, .label = "About", .role = .about },
        .{ .id = 3, .parent_id = 1, .kind = .item, .label = "Save", .command_id = 42, .key_equivalent = "s", .modifiers = .{ .super = true } },
    };
    try sdk.setMenuModel(.{ .nodes = &nodes });
    try std.testing.expectEqual(@as(usize, 3), backend.node_count);
}

test "SystemSdk: runDialog routes through backend; cancel → null; no capability → NotSupported" {
    var backend = DialogMockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-dialog",
        .deinit = DialogMockBackend.deinit,
        .pump_events = DialogMockBackend.pump,
        .dialog = .{ .run = DialogMockBackend.dialogRun },
    };

    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .file_dialog = true });
    defer sdk.deinit();

    var buf: [64]u8 = undefined;
    const picked = try sdk.runDialog(.{ .kind = .open_file }, &buf);
    try std.testing.expectEqualStrings("/tmp/picked.txt", picked.?);

    backend.cancel_next = true;
    try std.testing.expectEqual(@as(?[]const u8, null), try sdk.runDialog(.{ .kind = .open_file }, &buf));

    var no_cap_backend = DialogMockBackend{};
    var no_cap = SystemSdk.init(std.testing.allocator, &no_cap_backend, &vtable, .{});
    defer no_cap.deinit();
    try std.testing.expectError(SdkError.NotSupported, no_cap.runDialog(.{ .kind = .open_file }, &buf));
}

test "SystemSdk: unsupported capability returns NotSupported" {
    var backend = MockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-no-clipboard",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
    };

    var sdk = SystemSdk.init(
        std.testing.allocator,
        &backend,
        &vtable,
        .{},
    );
    defer sdk.deinit();

    var buf: [8]u8 = undefined;
    try std.testing.expectError(SdkError.NotSupported, sdk.clipboardGetText(&buf));
}

test "SystemSdk: raw handle is callable only when advertised" {
    var backend = MockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-raw-window",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .raw_window_handle = MockBackend.rawWindowHandle,
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .raw_window_handle = true });
    defer sdk.deinit();

    const handle = try sdk.rawWindowHandle(7);
    try std.testing.expectEqual(@intFromPtr(&backend), @intFromPtr(handle));
}

const WindowRegistryMockBackend = struct {
    registered_id: ?events_mod.WindowId = null,

    fn deinit(_: *anyopaque, _: Allocator) void {}
    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) SdkError!backend_mod.PumpResult {
        return .{};
    }
    fn register(ctx: *anyopaque, _: *platform.Window, window_id: events_mod.WindowId) SdkError!void {
        const self: *WindowRegistryMockBackend = @ptrCast(@alignCast(ctx));
        if (self.registered_id != null) return SdkError.InvalidState;
        self.registered_id = window_id;
    }
    fn unregister(ctx: *anyopaque, window_id: events_mod.WindowId) void {
        const self: *WindowRegistryMockBackend = @ptrCast(@alignCast(ctx));
        if (self.registered_id == window_id) self.registered_id = null;
    }
    fn rawHandle(ctx: *anyopaque, window_id: events_mod.WindowId) SdkError!*anyopaque {
        const self: *WindowRegistryMockBackend = @ptrCast(@alignCast(ctx));
        if (self.registered_id != window_id) return SdkError.InvalidState;
        return ctx;
    }
};

test "SystemSdk: window registration invalidates borrowed operations before native teardown" {
    var backend = WindowRegistryMockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-window-registry",
        .deinit = WindowRegistryMockBackend.deinit,
        .pump_events = WindowRegistryMockBackend.pump,
        .register_window = WindowRegistryMockBackend.register,
        .unregister_window = WindowRegistryMockBackend.unregister,
        .raw_window_handle = WindowRegistryMockBackend.rawHandle,
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{
        .multi_window = true,
        .raw_window_handle = true,
    });
    defer sdk.deinit();

    var native_window: platform.Window = undefined;
    try std.testing.expectError(SdkError.InvalidState, sdk.registerWindow(&native_window, 0));
    try sdk.registerWindow(&native_window, 77);
    try std.testing.expectEqual(@intFromPtr(&backend), @intFromPtr(try sdk.rawWindowHandle(77)));
    try std.testing.expectError(SdkError.InvalidState, sdk.registerWindow(&native_window, 77));
    try sdk.unregisterWindow(77);
    try std.testing.expectError(SdkError.InvalidState, sdk.rawWindowHandle(77));
}

test "SystemSdk: main-thread contract rejects cross-thread call" {
    var backend = MockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "mock-main-thread",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .request_redraw = MockBackend.requestRedraw,
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .request_redraw = true });
    defer sdk.deinit();

    var saw_wrong_thread = false;
    const Worker = struct {
        fn run(target: *SystemSdk, observed: *bool) void {
            target.requestRedraw() catch |err| {
                observed.* = err == SdkError.WrongThread;
                return;
            };
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &sdk, &saw_wrong_thread });
    thread.join();
    try std.testing.expect(saw_wrong_thread);
    try std.testing.expectEqual(@as(u32, 0), backend.redraw_requests);
}

test "SystemSdk: accessibility methods route through backend" {
    var backend = MockBackend{};

    const vtable = backend_mod.BackendVTable{
        .name = "mock-accessibility",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .accessibility = .{
            .announce_text = MockBackend.announceAccessibility,
            .notify_focus = MockBackend.notifyAccessibilityFocus,
            .notify_property_change = MockBackend.notifyAccessibilityPropertyChange,
        },
    };

    var sdk = SystemSdk.init(
        std.testing.allocator,
        &backend,
        &vtable,
        .{
            .accessibility = true,
        },
    );
    defer sdk.deinit();

    const snapshot = accessibility_mod.NodeSnapshot{
        .role = .checkbox,
        .label = "Autosave",
        .checked = true,
    };

    try sdk.announceAccessibilityText(9, "Focused");
    try sdk.notifyAccessibilityFocus(9, snapshot);
    try sdk.notifyAccessibilityPropertyChange(9, snapshot);

    try std.testing.expectEqual(@as(u32, 1), backend.announce_requests);
    try std.testing.expectEqualStrings("Focused", backend.last_announcement[0..backend.last_announcement_len]);
    try std.testing.expectEqual(@as(u32, 1), backend.focus_notifications);
    try std.testing.expectEqual(accessibility_mod.Role.checkbox, backend.last_focus_snapshot.role);
    try std.testing.expectEqualStrings("Autosave", backend.last_focus_snapshot.label);
    try std.testing.expectEqual(@as(?bool, true), backend.last_focus_snapshot.checked);
    try std.testing.expectEqual(@as(u32, 1), backend.property_notifications);
    try std.testing.expectEqual(accessibility_mod.Role.checkbox, backend.last_property_snapshot.role);
    try std.testing.expectEqualStrings("Autosave", backend.last_property_snapshot.label);
}

const SequencedBackend = struct {
    call_count: u32 = 0,
    text_storage: [16]u8 = [_]u8{0} ** 16,
    text_len: usize = 0,

    fn deinit(_: *anyopaque, _: Allocator) void {}

    fn pump(ctx: *anyopaque, queue: *events_mod.EventQueue, timeout_ms: u32) SdkError!backend_mod.PumpResult {
        _ = timeout_ms;
        const self: *SequencedBackend = @ptrCast(@alignCast(ctx));
        self.call_count += 1;

        switch (self.call_count) {
            1 => {
                self.setText("abc");
                try queue.push(.{ .mouse_move = .{
                    .window_id = 7,
                    .x = 10,
                    .y = 20,
                    .dx = 3,
                    .dy = 4,
                } });
                try queue.push(.{ .mouse_button = .{
                    .window_id = 7,
                    .x = 10,
                    .y = 20,
                    .button = .left,
                    .pressed = true,
                } });
                try queue.push(.{ .key = .{
                    .window_id = 7,
                    .keycode = 36,
                    .pressed = true,
                    .modifiers = .{
                        .shift = true,
                    },
                } });
                try queue.push(.{ .text_input = .{
                    .window_id = 7,
                    .text = self.textSlice(),
                } });
                return .{ .should_continue = true };
            },
            2 => {
                self.setText("z");
                try queue.push(.{ .mouse_button = .{
                    .window_id = 7,
                    .x = 12,
                    .y = 22,
                    .button = .left,
                    .pressed = false,
                } });
                try queue.push(.{ .key = .{
                    .window_id = 7,
                    .keycode = 36,
                    .pressed = false,
                    .modifiers = .{},
                } });
                try queue.push(.{ .text_input = .{
                    .window_id = 7,
                    .text = self.textSlice(),
                } });
                return .{ .should_continue = true };
            },
            else => {
                try queue.push(.{ .quit = {} });
                return .{ .should_continue = false };
            },
        }
    }

    fn setText(self: *SequencedBackend, text: []const u8) void {
        std.debug.assert(text.len <= self.text_storage.len);
        @memcpy(self.text_storage[0..text.len], text);
        self.text_len = text.len;
    }

    fn textSlice(self: *SequencedBackend) []const u8 {
        return self.text_storage[0..self.text_len];
    }
};

test "SystemSdk: pump clears queue and preserves event order per cycle" {
    var backend = SequencedBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "sequenced",
        .deinit = SequencedBackend.deinit,
        .pump_events = SequencedBackend.pump,
    };

    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{});
    defer sdk.deinit();

    const first = try sdk.pump(0);
    try std.testing.expect(first.should_continue);
    try std.testing.expectEqual(@as(usize, 4), sdk.events().len);

    try std.testing.expect(sdk.events()[0] == .mouse_move);
    try std.testing.expect(sdk.events()[1] == .mouse_button);
    try std.testing.expect(sdk.events()[1].mouse_button.pressed);
    try std.testing.expect(sdk.events()[2] == .key);
    try std.testing.expect(sdk.events()[3] == .text_input);
    try std.testing.expectEqualStrings("abc", sdk.events()[3].text_input.text);

    const second = try sdk.pump(0);
    try std.testing.expect(second.should_continue);
    try std.testing.expectEqual(@as(usize, 3), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .mouse_button);
    try std.testing.expect(!sdk.events()[0].mouse_button.pressed);
    try std.testing.expect(sdk.events()[1] == .key);
    try std.testing.expect(!sdk.events()[1].key.pressed);
    try std.testing.expect(sdk.events()[2] == .text_input);
    try std.testing.expectEqualStrings("z", sdk.events()[2].text_input.text);

    const third = try sdk.pump(0);
    try std.testing.expect(!third.should_continue);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .quit);
}

const DragMockBackend = struct {
    copied_payload: [64]u8 = [_]u8{0} ** 64,
    copied_len: usize = 0,
    window_id: events_mod.WindowId = 0,
    target_operations: backend_mod.DragOperations = .{},

    fn deinit(_: *anyopaque, _: Allocator) void {}
    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) SdkError!backend_mod.PumpResult {
        return .{};
    }
    fn start(ctx: *anyopaque, window_id: events_mod.WindowId, request: backend_mod.DragRequest) SdkError!u64 {
        const self: *DragMockBackend = @ptrCast(@alignCast(ctx));
        if (request.payload.len > self.copied_payload.len) return SdkError.BufferTooSmall;
        @memcpy(self.copied_payload[0..request.payload.len], request.payload);
        self.copied_len = request.payload.len;
        self.window_id = window_id;
        return 41;
    }
    fn setTargetOperations(ctx: *anyopaque, window_id: events_mod.WindowId, operations: backend_mod.DragOperations) SdkError!void {
        const self: *DragMockBackend = @ptrCast(@alignCast(ctx));
        self.window_id = window_id;
        self.target_operations = operations;
    }
};

test "SystemSdk: drag source validates, copies synchronously, and returns completion token" {
    var backend = DragMockBackend{};
    const vtable = backend_mod.BackendVTable{
        .name = "drag-mock",
        .deinit = DragMockBackend.deinit,
        .pump_events = DragMockBackend.pump,
        .drag_source = .{ .start = DragMockBackend.start },
        .drag_target = .{ .set_allowed_operations = DragMockBackend.setTargetOperations },
    };
    var sdk = SystemSdk.init(std.testing.allocator, &backend, &vtable, .{
        .drag_source = true,
        .drag_drop_target = true,
    });
    defer sdk.deinit();

    var payload = [_]u8{ 'r', 'o', 'w', '-', '7' };
    const token = try sdk.beginDrag(9, .{
        .payload_kind = .internal,
        .payload = &payload,
        .allowed_operations = .{ .copy = true, .move = true },
    });
    @memset(&payload, 0);
    try std.testing.expectEqual(@as(u64, 41), token);
    try std.testing.expectEqual(@as(events_mod.WindowId, 9), backend.window_id);
    try std.testing.expectEqualStrings("row-7", backend.copied_payload[0..backend.copied_len]);
    try sdk.setDragTargetOperations(9, .{ .move = true });
    try std.testing.expect(backend.target_operations.move);
    try std.testing.expect(!backend.target_operations.copy);
    try std.testing.expectError(SdkError.InvalidState, sdk.beginDrag(9, .{
        .payload_kind = .text,
        .payload = "",
    }));
}

const ClipboardReadTestBackend = struct {
    content: []const u8 = "abc",
    reported_len: ?usize = 8,
    read_error: ?SdkError = null,
    length_error: ?SdkError = null,
    grow_on_read: ?[]const u8 = null,
    offset: usize = 0,
    invalid: enum { none, foreign, overrun } = .none,
    reads: usize = 0,
    queries: usize = 0,

    const vtable = backend_mod.BackendVTable{
        .name = "clipboard-read-test",
        .deinit = MockBackend.deinit,
        .pump_events = MockBackend.pump,
        .clipboard = .{
            .set_text = set,
            .get_text = get,
            .get_text_len = len,
            .get_html = get,
            .get_html_len = len,
        },
    };

    fn set(_: *anyopaque, _: []const u8) SdkError!void {}
    fn len(ctx: *anyopaque) SdkError!usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.queries += 1;
        if (self.length_error) |err| return err;
        return self.reported_len orelse self.content.len;
    }
    fn get(ctx: *anyopaque, buffer: []u8) SdkError![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        if (self.read_error) |err| return err;
        if (self.grow_on_read) |content| {
            self.content = content;
            self.grow_on_read = null;
        }
        switch (self.invalid) {
            .foreign => return self.content,
            .overrun => return buffer.ptr[0 .. buffer.len + 1],
            .none => {},
        }
        if (self.offset + self.content.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[self.offset..][0..self.content.len], self.content);
        return buffer[self.offset..][0..self.content.len];
    }
    fn sdk(self: *@This()) SystemSdk {
        return SystemSdk.init(std.testing.allocator, self, &vtable, .{ .clipboard = true });
    }
};

fn clipboardShrinkFailure(comptime html: bool) !void {
    var backend = ClipboardReadTestBackend{};
    var sdk = backend.sdk();
    defer sdk.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    const result = if (html) sdk.clipboardGetHtmlAlloc(failing.allocator()) else sdk.clipboardGetTextAlloc(failing.allocator());
    // The unfixed function returns a short slice of the original 9-byte block.
    // Release that known original allocation even when the assertion fails.
    defer if (result) |text| {
        if (text) |bytes| failing.allocator().free(bytes.ptr[0..9]);
    } else |_| {};
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "allocated clipboard text releases the original block when shrinking fails" {
    try clipboardShrinkFailure(false);
}

test "allocated clipboard HTML releases the original block when shrinking fails" {
    try clipboardShrinkFailure(true);
}

fn readClipboardForTest(sdk: *SystemSdk, html: bool, alloc: Allocator) SdkError!?[]const u8 {
    return if (html) sdk.clipboardGetHtmlAlloc(alloc) else sdk.clipboardGetTextAlloc(alloc);
}

test "allocated clipboard reads normalize interior slices and own exact lengths" {
    for ([_]bool{ false, true }) |html| {
        for ([_]usize{ 0, 2 }) |offset| {
            var backend = ClipboardReadTestBackend{ .offset = offset, .content = "a\x00b" };
            var sdk = backend.sdk();
            defer sdk.deinit();
            const bytes = (try readClipboardForTest(&sdk, html, std.testing.allocator)).?;
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings("a\x00b", bytes);
        }
        // A complete result can occupy all of the queried length + one buffer.
        var backend = ClipboardReadTestBackend{ .content = "123456789" };
        var sdk = backend.sdk();
        defer sdk.deinit();
        const bytes = (try readClipboardForTest(&sdk, html, std.testing.allocator)).?;
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("123456789", bytes);
    }
}

test "clipboard growth retries without truncation and stops after three reads" {
    for ([_]bool{ false, true }) |html| {
        var backend = ClipboardReadTestBackend{ .content = "a", .reported_len = null, .grow_on_read = "larger 中文" };
        var sdk = backend.sdk();
        defer sdk.deinit();
        const bytes = (try readClipboardForTest(&sdk, html, std.testing.allocator)).?;
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings("larger 中文", bytes);
        try std.testing.expectEqual(@as(usize, 2), backend.reads);
        try std.testing.expectEqual(@as(usize, 2), backend.queries);
        backend.read_error = error.BufferTooSmall;
        backend.reads = 0;
        backend.queries = 0;
        try std.testing.expectError(error.BufferTooSmall, readClipboardForTest(&sdk, html, std.testing.allocator));
        try std.testing.expectEqual(@as(usize, 3), backend.reads);
        try std.testing.expectEqual(@as(usize, 3), backend.queries);
        backend.read_error = error.BackendFailure;
        backend.reads = 0;
        try std.testing.expectError(error.BackendFailure, readClipboardForTest(&sdk, html, std.testing.allocator));
        try std.testing.expectEqual(@as(usize, 1), backend.reads);
    }
}

test "clipboard errors and growth retry allocation failures release every buffer" {
    for ([_]bool{ false, true }) |html| {
        for (0..2) |failure| {
            var backend = ClipboardReadTestBackend{ .content = "a", .reported_len = null, .grow_on_read = "longer clipboard" };
            var sdk = backend.sdk();
            defer sdk.deinit();
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure });
            try std.testing.expectError(error.OutOfMemory, readClipboardForTest(&sdk, html, failing.allocator()));
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failing.fail_index = std.math.maxInt(usize);
            const retry = (try readClipboardForTest(&sdk, html, failing.allocator())).?;
            failing.allocator().free(retry);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "clipboard rejects overflowing lengths and foreign or out of range backend slices" {
    for ([_]bool{ false, true }) |html| {
        var backend = ClipboardReadTestBackend{ .reported_len = std.math.maxInt(usize) };
        var sdk = backend.sdk();
        defer sdk.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.BufferTooSmall, readClipboardForTest(&sdk, html, failing.allocator()));
        try std.testing.expectEqual(@as(usize, 0), backend.reads);
        try std.testing.expect(!failing.has_induced_failure);
        backend.reported_len = 8;
        for ([_]@FieldType(ClipboardReadTestBackend, "invalid"){ .foreign, .overrun }) |invalid| {
            backend.invalid = invalid;
            try std.testing.expectError(error.BackendFailure, readClipboardForTest(&sdk, html, std.testing.allocator));
        }
    }
}

test "clipboard empty content is null and missing support thread or query failures are errors" {
    for ([_]bool{ false, true }) |html| {
        var backend = ClipboardReadTestBackend{ .content = "" };
        var sdk = backend.sdk();
        defer sdk.deinit();
        try std.testing.expect((try readClipboardForTest(&sdk, html, std.testing.allocator)) == null);
        backend.reported_len = 0;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expect((try readClipboardForTest(&sdk, html, failing.allocator())) == null);
        try std.testing.expect(!failing.has_induced_failure);
        backend.length_error = error.Timeout;
        try std.testing.expectError(error.Timeout, readClipboardForTest(&sdk, html, std.testing.allocator));
        backend.length_error = null;
        sdk.capabilities.clipboard = false;
        try std.testing.expectError(error.NotSupported, readClipboardForTest(&sdk, html, std.testing.allocator));
        sdk.capabilities.clipboard = true;
        const Reader = struct {
            fn run(s: *SystemSdk, is_html: bool, err_out: *?SdkError) void {
                _ = readClipboardForTest(s, is_html, std.testing.allocator) catch |err| {
                    err_out.* = err;
                    return;
                };
            }
        };
        var err: ?SdkError = null;
        const th = try std.Thread.spawn(.{}, Reader.run, .{ &sdk, html, &err });
        th.join();
        try std.testing.expectEqual(error.WrongThread, err.?);
    }
}

test "haptic feedback honors capability implementation thread and backend errors" {
    const Mock = struct {
        calls: usize = 0,
        failure: ?SdkError = null,
        last_pattern: ?backend_mod.HapticFeedbackPattern = null,
        fn deinit(_: *anyopaque, _: Allocator) void {}
        fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) SdkError!backend_mod.PumpResult {
            return .{};
        }
        fn perform(raw: *anyopaque, pattern: backend_mod.HapticFeedbackPattern) SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.last_pattern = pattern;
            self.calls += 1;
            if (self.failure) |err| return err;
        }
        fn wrongThread(sdk: *SystemSdk, result: *?SdkError) void {
            sdk.performHapticFeedback(.alignment) catch |err| {
                result.* = err;
            };
        }
    };
    var mock = Mock{};
    var vt = backend_mod.BackendVTable{
        .name = "haptic-contract",
        .deinit = Mock.deinit,
        .pump_events = Mock.pump,
    };
    var sdk = SystemSdk.init(std.testing.allocator, &mock, &vt, .{});
    defer sdk.deinit();
    try std.testing.expectError(error.NotSupported, sdk.performHapticFeedback(.alignment));
    sdk.capabilities.haptic_feedback = true;
    try std.testing.expectError(error.CapabilityContractMismatch, capabilities_mod.validateAdvertised(sdk.capabilities, vt));
    try std.testing.expectError(error.NotSupported, sdk.performHapticFeedback(.alignment));
    vt.perform_haptic_feedback = Mock.perform;
    try capabilities_mod.validateAdvertised(sdk.capabilities, vt);
    inline for (std.meta.tags(backend_mod.HapticFeedbackPattern)) |pattern| {
        try sdk.performHapticFeedback(pattern);
        try std.testing.expectEqual(pattern, mock.last_pattern.?);
    }
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
    sdk.capabilities.haptic_feedback = false;
    try std.testing.expectError(error.NotSupported, sdk.performHapticFeedback(.alignment));
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
    sdk.capabilities.haptic_feedback = true;
    var thread_error: ?SdkError = null;
    const thread = try std.Thread.spawn(.{}, Mock.wrongThread, .{ &sdk, &thread_error });
    thread.join();
    try std.testing.expectEqual(error.WrongThread, thread_error.?);
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
    mock.failure = error.BackendFailure;
    try std.testing.expectError(error.BackendFailure, sdk.performHapticFeedback(.alignment));
}
