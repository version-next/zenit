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
    /// Probe clipboard available types (bitmask: 1=text, 2=image, 4=file_urls). No decode, minimal
    /// cost.
    probe: ?*const fn (ctx: *anyopaque) u32 = null,
    /// Clipboard image item count (supports Finder multi-select copy)
    image_count: ?*const fn (ctx: *anyopaque) usize = null,
    /// Read item at index: decode RGBA + raw bytes. null = no image at this index.
    /// All slices allocated by passed allocator; caller ClipboardImage.deinit frees.
    get_image: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, index: usize) SdkError!?ClipboardImage = null,
    /// Write PNG-encoded image (clear clipboard original content)
    set_image_png: ?*const fn (ctx: *anyopaque, png_bytes: []const u8) SdkError!void = null,
    /// Rich text write: plain text + optional HTML as multiple representation of one pasteboard
    /// item.
    /// RTF not in this interface (macOS HTML->RTF needs WebKit main-thread nested runloop, see
    /// bridge comment).
    set_rich_text: ?*const fn (ctx: *anyopaque, rich: ClipboardRichText) SdkError!void = null,
    /// Clipboard HTML representation byte length; no HTML returns 0.
    get_html_len: ?*const fn (ctx: *anyopaque) SdkError!usize = null,
    /// Same full-read/buffer-ownership contract as get_text. Empty means no HTML;
    /// the caller decides whether to fall back to plain text.
    get_html: ?*const fn (ctx: *anyopaque, buffer: []u8) SdkError![]const u8 = null,
};

/// Rich clipboard payload. All slices borrowed only during `set_rich_text` call.
pub const ClipboardRichText = struct {
    /// plain text representation (required, non-empty UTF-8)
    text: []const u8,
    /// HTML representation (optional; when present must be non-empty UTF-8 fragment)
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
    /// Premultiplied RGBA8, length = width * height * 4
    rgba: []const u8,
    /// Raw encoded bytes (PNG/JPEG/TIFF...) for as-is archival; null = source had no raw bytes
    raw_bytes: ?[]const u8 = null,
    /// UTI of raw bytes (e.g. "public.png"); file-url source is "file.<ext>"
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
    /// Enable platform text interpretation for the focused editable control.
    /// Raw key events are independent and must remain available when false.
    set_enabled: *const fn (ctx: *anyopaque, window_id: events.WindowId, enabled: bool) SdkError!void,
    set_cursor_rect: *const fn (ctx: *anyopaque, window_id: events.WindowId, x: f32, y: f32, width: f32, height: f32) SdkError!void,
    /// End the current composition and close its candidate UI, while
    /// preserving the enabled/disabled state. Session ownership depends on
    /// `discard` and `set_enabled(false)` being distinct transitions: moving
    /// directly between two text clients discards A but keeps the one
    /// window-level input context enabled for B.
    discard: *const fn (ctx: *anyopaque, window_id: events.WindowId) SdkError!void,
    /// Optional UTF-8 editor state for protocols such as Wayland text-input-v3.
    set_surrounding: ?*const fn (ctx: *anyopaque, window_id: events.WindowId, text: []const u8, cursor: u32, anchor: u32, secure: bool) SdkError!void = null,
    /// Epoch tagging protects copied IME events from a later focus/session switch.
    generation: ?*const fn (ctx: *anyopaque) u64 = null,
    /// Optional: replace the window's reserved key chords (`Cx.setReservedKeyChords`).
    /// A reserved key-down is delivered as a key event but never interpreted
    /// by the platform input method. Platforms whose modifier chords produce
    /// no IME text leave it null.
    set_reserved_chords: ?*const fn (ctx: *anyopaque, window_id: events.WindowId, chords: []const events.ReservedChord) SdkError!void = null,
};

pub const CursorVTable = struct {
    set_shape: *const fn (ctx: *anyopaque, window_id: events.WindowId, shape: u8) SdkError!void,

    /// Optional: custom bitmap cursor (shape enum 19 = custom uses this; set_shape never receives
    /// 19).
    /// `rgba` is premultiplied RGBA8 (len == width*height*4), borrowed during the call; backend
    /// must copy
    /// before returning. (hot_x, hot_y) is the hot-spot pixel coordinate, origin top-left.
    /// `key` is content-addressed (same bitmap, same key); backend should cache the native cursor
    /// object by key to avoid repeat decode on high-frequency set. Return NotSupported if the
    /// backend
    /// has only fixed shapes.
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

/// `.file_url`: payload is absolute path or file:// or other scheme URL string.
/// When pointing to existing file, macOS backend writes NSPasteboardTypeFileURL, drag out to
/// Finder directly (Finder does copy). 'Generate file on drag' (NSFilePromiseProvider)
/// not yet supported, see window_bridge.m TODO(file-promise).
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

    fn windowsAbsolute(path: []const u8) bool {
        const extended = std.mem.startsWith(u8, path, "\\\\?\\");
        const rest = if (extended) path[4..] else path;
        if (rest.len >= 3 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':' and (rest[2] == '/' or rest[2] == '\\')) return true;
        const unc = if (extended) blk: {
            if (rest.len < 4 or !std.ascii.eqlIgnoreCase(rest[0..4], "UNC\\")) return false;
            break :blk rest[4..];
        } else blk: {
            if (!std.mem.startsWith(u8, path, "\\\\")) return false;
            break :blk path[2..];
        };
        const separator = std.mem.indexOfAny(u8, unc, "\\/") orelse return false;
        return separator > 0 and separator + 1 < unc.len and unc[separator + 1] != '\\' and unc[separator + 1] != '/';
    }

    pub fn validate(self: DragRequest) SdkError!void {
        if (self.payload.len == 0 or !self.allowed_operations.any() or self.allowed_operations._reserved != 0) return SdkError.InvalidState;
        if (!std.unicode.utf8ValidateSlice(self.payload)) return SdkError.InvalidState;
        if (self.payload_kind == .file_url) {
            // Absolute path or URL with scheme ("xx://"). Relative path has no stable
            // interpretation base; backend NSURL fileURLWithPath silently relative to cwd,
            // forbidden.
            if (std.mem.indexOfScalar(u8, self.payload, 0) != null) return SdkError.InvalidState;
            const is_abs_path = self.payload[0] == '/' or windowsAbsolute(self.payload);
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

/// Platform backend SPI
pub const BackendVTable = struct {
    name: []const u8,
    deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    pump_events: *const fn (ctx: *anyopaque, queue: *events.EventQueue, timeout_ms: u32) SdkError!PumpResult,

    perform_haptic_feedback: ?*const fn (ctx: *anyopaque, pattern: HapticFeedbackPattern) SdkError!void = null,
    request_redraw: ?*const fn (ctx: *anyopaque) SdkError!void = null,
    /// Silent sync input state (no events generated).
    /// Used in liveResize etc: system took mouse events;
    /// before resuming normal polling, align internal button-track state.
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
    /// Multiwindow: register window to event system
    register_window: ?*const fn (ctx: *anyopaque, window: *platform.Window, window_id: events.WindowId) SdkError!void = null,
    /// Multiwindow: unregister window from event system
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
    // Same relative payload valid as .text (constraint is file_url-specific)
    try (DragRequest{ .payload_kind = .text, .payload = "relative/path.txt" }).validate();
}

test "DragRequest accepts Windows absolute paths and rejects drive-relative and NUL paths" {
    for ([_][]const u8{ "C:\\Users\\test\\输入-🧪.txt", "D:/folder/file.txt", "\\\\server\\share\\file.txt", "\\\\?\\C:\\long\\file.txt" }) |path|
        try (DragRequest{ .payload_kind = .file_url, .payload = path }).validate();
    for ([_][]const u8{ "C:file.txt", "\\rooted.txt", "\\\\server", "\\\\server\\", "1:\\file.txt", "C:\\file\x00.txt" }) |path|
        try std.testing.expectError(SdkError.InvalidState, (DragRequest{ .payload_kind = .file_url, .payload = path }).validate());
    try std.testing.expectError(SdkError.InvalidState, (DragRequest{ .payload_kind = .text, .payload = "text", .allowed_operations = .{ .copy = true, ._reserved = 1 } }).validate());
    try (DragRequest{ .payload_kind = .internal, .payload = "row\x00payload" }).validate();
}

test "ClipboardRichText validates non-empty UTF-8 text and optional HTML" {
    try (ClipboardRichText{ .text = "hello" }).validate();
    try (ClipboardRichText{ .text = "hello", .html = "<b>hello</b>" }).validate();
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "x", .html = "" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "\xff\xfe" }).validate());
    try std.testing.expectError(SdkError.InvalidState, (ClipboardRichText{ .text = "x", .html = "\xff" }).validate());
}
