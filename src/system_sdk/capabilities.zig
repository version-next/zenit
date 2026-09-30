const std = @import("std");

/// 可探测的系统能力
pub const Capability = enum {
    clipboard,
    clipboard_image,
    file_dialog,
    menu_bar,
    tray,
    notifications,
    global_hotkey,
    ime,
    accessibility,
    raw_window_handle,
    multi_window,
    request_redraw,
    cursor,
    drag_drop_target,
    drag_source,
    haptic_feedback,
};

/// 后端能力位
pub const Capabilities = struct {
    clipboard: bool = false,
    clipboard_image: bool = false,
    file_dialog: bool = false,
    menu_bar: bool = false,
    tray: bool = false,
    notifications: bool = false,
    global_hotkey: bool = false,
    ime: bool = false,
    accessibility: bool = false,
    raw_window_handle: bool = false,
    multi_window: bool = false,
    request_redraw: bool = false,
    cursor: bool = false,
    drag_drop_target: bool = false,
    drag_source: bool = false,
    haptic_feedback: bool = false,

    pub const NONE = Capabilities{};

    pub fn has(self: Capabilities, capability: Capability) bool {
        return switch (capability) {
            .clipboard => self.clipboard,
            .clipboard_image => self.clipboard_image,
            .file_dialog => self.file_dialog,
            .menu_bar => self.menu_bar,
            .tray => self.tray,
            .notifications => self.notifications,
            .global_hotkey => self.global_hotkey,
            .ime => self.ime,
            .accessibility => self.accessibility,
            .raw_window_handle => self.raw_window_handle,
            .multi_window => self.multi_window,
            .request_redraw => self.request_redraw,
            .cursor => self.cursor,
            .drag_drop_target => self.drag_drop_target,
            .drag_source => self.drag_source,
            .haptic_feedback => self.haptic_feedback,
        };
    }
};

pub const Owner = enum {
    application,
    window,
    application_and_window,
};

pub const Execution = enum {
    main_thread_sync,
    main_thread_event_pump,
};

pub const Acceptance = enum {
    automated,
    automated_plus_manual,
    deferred,
};

pub const Contract = struct {
    capability: Capability,
    owner: Owner,
    execution: Execution,
    acceptance: Acceptance,
    candidate_required: bool,
    lifetime: []const u8,
};

/// Lifecycle truth is backend-independent; support truth comes from each
/// backend's `Capabilities` value and must match its vtable.
pub const contracts = [_]Contract{
    .{ .capability = .clipboard, .owner = .application, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "application; returned slices are copied/allocator-owned" },
    .{ .capability = .clipboard_image, .owner = .application, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "application; ClipboardImage.deinit releases owned buffers" },
    .{ .capability = .file_dialog, .owner = .application_and_window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "modal call; returned path is caller-buffer-owned" },
    .{ .capability = .menu_bar, .owner = .application_and_window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "application model; active-window command context" },
    .{ .capability = .tray, .owner = .application, .execution = .main_thread_sync, .acceptance = .deferred, .candidate_required = false, .lifetime = "application registration until explicit teardown" },
    .{ .capability = .notifications, .owner = .application, .execution = .main_thread_event_pump, .acceptance = .deferred, .candidate_required = false, .lifetime = "application registration; activation delivered through event queue" },
    .{ .capability = .global_hotkey, .owner = .application, .execution = .main_thread_event_pump, .acceptance = .deferred, .candidate_required = false, .lifetime = "registration token until unregister/application teardown" },
    .{ .capability = .ime, .owner = .window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "registered window; invalid immediately after unregister" },
    .{ .capability = .accessibility, .owner = .window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "registered window; snapshots copied during call" },
    .{ .capability = .raw_window_handle, .owner = .window, .execution = .main_thread_sync, .acceptance = .automated, .candidate_required = false, .lifetime = "borrowed until unregisterWindow; never retained by caller" },
    .{ .capability = .multi_window, .owner = .application_and_window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "MultiWindowApp owns create/route/teardown; low-level windows register before use and unregister before native destruction" },
    .{ .capability = .request_redraw, .owner = .application, .execution = .main_thread_sync, .acceptance = .automated, .candidate_required = true, .lifetime = "application; affects currently registered windows" },
    .{ .capability = .cursor, .owner = .window, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "registered window; invalid immediately after unregister" },
    .{ .capability = .drag_drop_target, .owner = .window, .execution = .main_thread_event_pump, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "registered window; borrowed event payload valid for the current pump only" },
    .{ .capability = .drag_source, .owner = .window, .execution = .main_thread_event_pump, .acceptance = .automated_plus_manual, .candidate_required = true, .lifetime = "borrowed start payload copied synchronously; token until completion/cancel/window teardown" },
    .{ .capability = .haptic_feedback, .owner = .application, .execution = .main_thread_sync, .acceptance = .automated_plus_manual, .candidate_required = false, .lifetime = "user-initiated request; current device and preferences may suppress physical output" },
};

pub fn contractFor(capability: Capability) Contract {
    return contracts[@intFromEnum(capability)];
}

pub fn implementationPresent(capability: Capability, vtable: anytype) bool {
    return switch (capability) {
        .clipboard => vtable.clipboard != null,
        .clipboard_image => if (vtable.clipboard) |api|
            api.probe != null and api.image_count != null and api.get_image != null and api.set_image_png != null
        else
            false,
        .file_dialog => vtable.dialog != null,
        .menu_bar => vtable.menu != null,
        .tray, .notifications, .global_hotkey => false,
        .ime => vtable.ime != null,
        .accessibility => vtable.accessibility != null,
        .raw_window_handle => vtable.raw_window_handle != null,
        .multi_window => vtable.register_window != null and vtable.unregister_window != null,
        .request_redraw => vtable.request_redraw != null,
        .cursor => vtable.cursor != null,
        .drag_drop_target => vtable.drag_target != null,
        .drag_source => vtable.drag_source != null,
        .haptic_feedback => vtable.perform_haptic_feedback != null,
    };
}

pub fn validateAdvertised(caps: Capabilities, vtable: anytype) !void {
    inline for (std.meta.fields(Capability)) |field| {
        const capability: Capability = @enumFromInt(field.value);
        if (caps.has(capability) and !implementationPresent(capability, vtable)) {
            return error.CapabilityContractMismatch;
        }
    }
}

test "Capabilities.has" {
    const caps = Capabilities{
        .clipboard = true,
        .ime = true,
    };
    try std.testing.expect(caps.has(.clipboard));
    try std.testing.expect(caps.has(.ime));
    try std.testing.expect(!caps.has(.file_dialog));
}

test "capability contracts cover every enum in declaration order" {
    try std.testing.expectEqual(std.meta.fields(Capability).len, contracts.len);
    inline for (contracts, 0..) |contract, i| {
        try std.testing.expectEqual(@as(usize, @intFromEnum(contract.capability)), i);
        try std.testing.expect(contract.lifetime.len > 0);
    }
}

test "advertised capability without implementation is rejected" {
    const FakeClipboard = struct {
        probe: ?u8 = null,
        image_count: ?u8 = null,
        get_image: ?u8 = null,
        set_image_png: ?u8 = null,
    };
    const Fake = struct {
        clipboard: ?FakeClipboard = null,
        menu: ?u8 = null,
        dialog: ?u8 = null,
        ime: ?u8 = null,
        accessibility: ?u8 = null,
        raw_window_handle: ?u8 = null,
        register_window: ?u8 = null,
        unregister_window: ?u8 = null,
        request_redraw: ?u8 = null,
        cursor: ?u8 = null,
        drag_source: ?u8 = null,
        drag_target: ?u8 = null,
        perform_haptic_feedback: ?u8 = null,
    };
    try std.testing.expectError(error.CapabilityContractMismatch, validateAdvertised(.{ .menu_bar = true }, Fake{}));
}
