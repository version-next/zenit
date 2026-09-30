const std = @import("std");
const Allocator = std.mem.Allocator;
const events = @import("events.zig");
const accessibility = @import("accessibility.zig");
const SdkError = @import("errors.zig").SdkError;
const platform = @import("platform");

/// User-initiated semantic patterns, not ordered strength/amplitude levels.
/// The OS chooses the physical response; support does not guarantee output.
pub const HapticFeedbackPattern = enum {
    alignment,
    generic,
    level_change,
};

pub const PumpResult = struct {
    should_continue: bool = true,
    requested_redraw: bool = false,
};

pub const ClipboardVTable = struct {
    set_text: *const fn (ctx: *anyopaque, text: []const u8) SdkError!void,
    /// Copy the complete text into buffer and return a borrowed slice within it.
    /// Return BufferTooSmall without partial success if the current content does
    /// not fit; it may have changed since get_text_len. Empty means no text.
    get_text: *const fn (ctx: *anyopaque, buffer: []u8) SdkError![]const u8,
    get_text_len: ?*const fn (ctx: *anyopaque) SdkError!usize = null,
    /// 探测剪贴板可提供的类型（位掩码：1=text, 2=image, 4=file_urls）。不解码，成本极低。
    probe: ?*const fn (ctx: *anyopaque) u32 = null,
    /// 剪贴板中的图片项数（支持 Finder 多选复制）
    image_count: ?*const fn (ctx: *anyopaque) usize = null,
    /// 读取第 index 项：解码 RGBA + 原始字节。null = 该 index 无图片。
    /// 所有 slice 用传入 allocator 分配，调用方 ClipboardImage.deinit 释放。
    get_image: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, index: usize) SdkError!?ClipboardImage = null,
    /// 写入 PNG 编码图片（清空剪贴板原内容）
    set_image_png: ?*const fn (ctx: *anyopaque, png_bytes: []const u8) SdkError!void = null,
    /// 富文本写入：plain text + 可选 HTML 作为同一 pasteboard item 的多 representation。
    /// RTF 不在此接口内（macOS HTML→RTF 转换依赖 WebKit 主线程嵌套 runloop，见 bridge 注释）。
    set_rich_text: ?*const fn (ctx: *anyopaque, rich: ClipboardRichText) SdkError!void = null,
    /// 剪贴板 HTML representation 的字节长度；无 HTML 时返回 0。
    get_html_len: ?*const fn (ctx: *anyopaque) SdkError!usize = null,
    /// Same full-read/buffer-ownership contract as get_text. Empty means no HTML;
    /// the caller decides whether to fall back to plain text.
    get_html: ?*const fn (ctx: *anyopaque, buffer: []u8) SdkError![]const u8 = null,
};

/// 富剪贴板载荷。所有 slice 仅在 `set_rich_text` 调用期间 borrowed。
pub const ClipboardRichText = struct {
    /// plain text representation（必填，非空 UTF-8）
    text: []const u8,
    /// HTML representation（可选；提供时必须是非空 UTF-8 片段）
    html: ?[]const u8 = null,

    pub fn validate(self: ClipboardRichText) SdkError!void {
        if (self.text.len == 0) return SdkError.InvalidState;
        if (!std.unicode.utf8ValidateSlice(self.text)) return SdkError.InvalidState;
        if (self.html) |h| {
            if (h.len == 0) return SdkError.InvalidState;
            if (!std.unicode.utf8ValidateSlice(h)) return SdkError.InvalidState;
        }
    }
};

pub const ClipboardImage = struct {
    width: u32,
    height: u32,
    /// premultiplied RGBA8，长度 = width * height * 4
    rgba: []const u8,
    /// 原始编码字节（PNG/JPEG/TIFF…），用于原样归档；null = 来源无原始字节
    raw_bytes: ?[]const u8 = null,
    /// 原始字节的 UTI（如 "public.png"）；file-url 来源为 "file.<ext>"
    uti: ?[]const u8 = null,

    pub fn deinit(self: *ClipboardImage, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        if (self.raw_bytes) |b| alloc.free(b);
        if (self.uti) |u| alloc.free(u);
        self.* = undefined;
    }
};

pub const DialogKind = enum {
    open_file,
    save_file,
    pick_folder,
};

pub const DialogRequest = struct {
    kind: DialogKind,
    title: []const u8 = "",
    default_path: []const u8 = "",
};

pub const DialogVTable = struct {
    run: *const fn (ctx: *anyopaque, request: DialogRequest, path_buffer: []u8) SdkError!?[]const u8,
};

pub const ImeVTable = struct {
    /// Enable AppKit text interpretation for the focused editable control.
    /// Raw key events are independent and must remain available when false.
    set_enabled: *const fn (ctx: *anyopaque, window_id: events.WindowId, enabled: bool) SdkError!void,
    set_cursor_rect: *const fn (ctx: *anyopaque, window_id: events.WindowId, x: f32, y: f32, width: f32, height: f32) SdkError!void,
    /// End the current composition and close its candidate UI, while
    /// preserving the enabled/disabled state. Session ownership depends on
    /// `discard` and `set_enabled(false)` being distinct transitions: moving
    /// directly between two text clients discards A but keeps the one
    /// window-level input context enabled for B.
    discard: *const fn (ctx: *anyopaque, window_id: events.WindowId) SdkError!void,
};

pub const CursorVTable = struct {
    set_shape: *const fn (ctx: *anyopaque, window_id: events.WindowId, shape: u8) SdkError!void,

    /// 可选：自定义位图光标（shape 枚举 19 = custom 时走这里，set_shape 永远收不到 19）。
    /// `rgba` 为预乘 RGBA8（len == width*height*4），调用期借用，后端须在返回前拷贝；
    /// (hot_x, hot_y) 是左上原点的热点像素坐标；
    /// `key` 为内容寻址键（调用方保证同位图同键），后端应按键缓存原生光标对象，
    /// 使高频 set 不重复解码。返回 NotSupported 表示该后端只有固定形状。
    set_custom: ?*const fn (
        ctx: *anyopaque,
        window_id: events.WindowId,
        rgba: [*]const u8,
        len: usize,
        width: u32,
        height: u32,
        scale: f32,
        hot_x: f32,
        hot_y: f32,
        key: u64,
    ) SdkError!void = null,
};

pub const AccessibilityVTable = struct {
    announce_text: *const fn (ctx: *anyopaque, window_id: events.WindowId, text: []const u8) SdkError!void,
    notify_focus: *const fn (ctx: *anyopaque, window_id: events.WindowId, snapshot: accessibility.NodeSnapshot) SdkError!void,
    notify_property_change: *const fn (ctx: *anyopaque, window_id: events.WindowId, snapshot: accessibility.NodeSnapshot) SdkError!void,
};

pub const MenuRole = enum(u8) {
    custom,
    about,
    settings,
    services,
    hide,
    hide_others,
    show_all,
    quit,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    minimize,
    zoom,
    bring_all_to_front,
};

pub const MenuNodeKind = enum(u8) { menu, item, separator };

/// Flat, parent-id-based menu tree. All strings are borrowed for `set_model`
/// only; native backends must copy them before returning.
pub const MenuNode = struct {
    id: u64,
    parent_id: u64 = 0,
    kind: MenuNodeKind,
    label: []const u8 = "",
    key_equivalent: []const u8 = "",
    modifiers: events.Modifiers = .{},
    role: MenuRole = .custom,
    command_id: u64 = 0,
    enabled: bool = true,
    checked: bool = false,
};

pub const MenuModel = struct {
    nodes: []const MenuNode,

    pub fn validate(self: MenuModel) SdkError!void {
        if (self.nodes.len == 0) return SdkError.InvalidState;
        for (self.nodes, 0..) |node, i| {
            if (node.id == 0) return SdkError.InvalidState;
            for (self.nodes[0..i]) |previous| {
                if (previous.id == node.id) return SdkError.InvalidState;
            }
            if (node.parent_id == 0) {
                if (node.kind != .menu) return SdkError.InvalidState;
            } else {
                var parent_is_prior_menu = false;
                for (self.nodes[0..i]) |candidate| {
                    if (candidate.id == node.parent_id and candidate.kind == .menu) {
                        parent_is_prior_menu = true;
                        break;
                    }
                }
                if (!parent_is_prior_menu) return SdkError.InvalidState;
            }
            if (node.kind == .item and node.role == .custom and node.command_id == 0)
                return SdkError.InvalidState;
        }
    }
};
pub const MenuVTable = struct {
    set_model: *const fn (ctx: *anyopaque, model: MenuModel) SdkError!void,
};

/// `.file_url`: payload 是绝对路径或 file:// / 其他 scheme 的 URL 字符串。
/// 指向已存在文件时，macOS backend 会写 NSPasteboardTypeFileURL——可直接拖出
/// 到 Finder（由 Finder 执行复制）。"拖出时才生成文件"（NSFilePromiseProvider）
/// 尚未支持，见 window_bridge.m TODO(file-promise)。
pub const DragPayloadKind = enum(u8) { text, file_url, internal };

pub const DragOperations = packed struct(u8) {
    copy: bool = false,
    move: bool = false,
    link: bool = false,
    _reserved: u5 = 0,

    pub fn any(self: DragOperations) bool {
        return self.copy or self.move or self.link;
    }
};

/// All slices are borrowed for `start` only. A backend must copy payload and
/// preview data into its native drag session before returning.
pub const DragRequest = struct {
    payload_kind: DragPayloadKind,
    payload: []const u8,
    allowed_operations: DragOperations = .{ .copy = true },
    preview_png: []const u8 = "",
    preview_width: f32 = 96,
    preview_height: f32 = 32,
    hotspot_x: f32 = 0,
    hotspot_y: f32 = 0,

    pub fn validate(self: DragRequest) SdkError!void {
        if (self.payload.len == 0 or !self.allowed_operations.any()) return SdkError.InvalidState;
        if (!std.unicode.utf8ValidateSlice(self.payload)) return SdkError.InvalidState;
        if (self.payload_kind == .file_url) {
            // 绝对路径，或带 scheme 的 URL（"xx://"）。相对路径没有稳定的
            // 解释基准，backend 侧 NSURL fileURLWithPath 会静默相对 cwd，禁止。
            const is_abs_path = self.payload[0] == '/';
            const has_scheme = std.mem.indexOf(u8, self.payload, "://") != null;
            if (!is_abs_path and !has_scheme) return SdkError.InvalidState;
        }
        if (!std.math.isFinite(self.preview_width) or !std.math.isFinite(self.preview_height) or
            !std.math.isFinite(self.hotspot_x) or !std.math.isFinite(self.hotspot_y) or
            self.preview_width <= 0 or self.preview_height <= 0 or self.preview_width > 4096 or
            self.preview_height > 4096 or self.hotspot_x < 0 or self.hotspot_y < 0 or
            self.hotspot_x > self.preview_width or self.hotspot_y > self.preview_height)
            return SdkError.InvalidState;
    }
};

pub const DragSourceVTable = struct {
    start: *const fn (ctx: *anyopaque, window_id: events.WindowId, request: DragRequest) SdkError!u64,
};

pub const DragTargetVTable = struct {
    set_allowed_operations: *const fn (ctx: *anyopaque, window_id: events.WindowId, operations: DragOperations) SdkError!void,
};

/// 平台 backend SPI
pub const BackendVTable = struct {
    name: []const u8,
    deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    pump_events: *const fn (ctx: *anyopaque, queue: *events.EventQueue, timeout_ms: u32) SdkError!PumpResult,

    perform_haptic_feedback: ?*const fn (ctx: *anyopaque, pattern: HapticFeedbackPattern) SdkError!void = null,
    request_redraw: ?*const fn (ctx: *anyopaque) SdkError!void = null,
    /// 静默同步输入状态（不产生事件）。
    /// 用于 liveResize 等场景：系统代理了鼠标事件，
    /// 恢复正常轮询前需要对齐内部按钮追踪状态。
    sync_input_state: ?*const fn (ctx: *anyopaque) void = null,
    clipboard: ?ClipboardVTable = null,
    dialog: ?DialogVTable = null,
    ime: ?ImeVTable = null,
    cursor: ?CursorVTable = null,
    accessibility: ?AccessibilityVTable = null,
    menu: ?MenuVTable = null,
    drag_source: ?DragSourceVTable = null,
    drag_target: ?DragTargetVTable = null,
    /// Borrowed native window handle. Valid only while the window remains
    /// registered; callers must not retain it across unregister/teardown.
    raw_window_handle: ?*const fn (ctx: *anyopaque, window_id: events.WindowId) SdkError!*anyopaque = null,
    /// 多窗口: 注册窗口到事件系统
    register_window: ?*const fn (ctx: *anyopaque, window: *platform.Window, window_id: events.WindowId) SdkError!void = null,
    /// 多窗口: 从事件系统注销窗口
    unregister_window: ?*const fn (ctx: *anyopaque, window_id: events.WindowId) void = null,
};

test {
    std.testing.refAllDecls(@This());
}

test "MenuModel requires parent-before-child, unique ids, and custom command ids" {
    const nodes = [_]MenuNode{
        .{ .id = 1, .kind = .menu, .label = "App" },
        .{ .id = 2, .parent_id = 1, .kind = .item, .label = "Do", .command_id = 9 },
    };
    try (MenuModel{ .nodes = &nodes }).validate();
    const invalid = [_]MenuNode{
        .{ .id = 2, .parent_id = 1, .kind = .item, .label = "Do", .command_id = 9 },
        .{ .id = 1, .kind = .menu, .label = "App" },
    };
    try std.testing.expectError(SdkError.InvalidState, (MenuModel{ .nodes = &invalid }).validate());
}

test "DragRequest rejects empty payload, empty operations, and invalid preview geometry" {
    try (DragRequest{ .payload_kind = .text, .payload = "hello" }).validate();
    try std.testing.expectError(SdkError.InvalidState, (DragRequest{ .payload_kind = .text, .payload = "" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (DragRequest{
        .payload_kind = .internal,
        .payload = "x",
        .allowed_operations = .{},
    }).validate());
    try std.testing.expectError(SdkError.InvalidState, (DragRequest{
        .payload_kind = .file_url,
        .payload = "/tmp/a",
        .preview_width = 10,
        .hotspot_x = 11,
    }).validate());
}

test "DragRequest file_url requires absolute path or URL with scheme" {
    try (DragRequest{ .payload_kind = .file_url, .payload = "/tmp/report.pdf" }).validate();
    try (DragRequest{ .payload_kind = .file_url, .payload = "file:///tmp/report.pdf" }).validate();
    try (DragRequest{ .payload_kind = .file_url, .payload = "https://zenit.dev/x" }).validate();
    try std.testing.expectError(SdkError.InvalidState, (DragRequest{
        .payload_kind = .file_url,
        .payload = "relative/path.txt",
    }).validate());
    // 同样的相对 payload 作为 .text 是合法的（约束只针对 file_url）
    try (DragRequest{ .payload_kind = .text, .payload = "relative/path.txt" }).validate();
}

test "ClipboardRichText validates non-empty UTF-8 text and optional HTML" {
    try (ClipboardRichText{ .text = "hello" }).validate();
    try (ClipboardRichText{ .text = "hello", .html = "<b>hello</b>" }).validate();
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "x", .html = "" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "\xff\xfe" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "x", .html = "\xff" }).validate());
}
