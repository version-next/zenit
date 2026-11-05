/// Event System: event definitions and dispatch.
///
/// Supports:
/// - mouse events: mouse_down, mouse_up, click, double_click, mouse_move, mouse_enter, mouse_leave,
///   scroll
/// - keyboard events: key_down, key_up
/// - text input: text_input, ime_preedit, ime_commit
/// - focus events: focus, blur
/// - event propagation: capture -> target -> bubble (DOM style)
const std = @import("std");

/// Platform's standard application shortcut modifier.
pub fn primaryModifier(modifiers: Modifiers) bool {
    return primaryModifierOn(ShortcutPlatform.native, modifiers);
}

/// Keyboard-shortcut convention family. Bindings are written once in terms of
/// the platform command key (`Chord.primary`) and resolved per family, so tests
/// can check every family's table on any host.
pub const ShortcutPlatform = enum {
    /// macOS: ⌘ is the command key; ⌃ is a separate text-navigation modifier.
    mac,
    /// Windows / Linux: Ctrl is the command key; the Windows/Super key belongs
    /// to the desktop shell and never takes part in application shortcuts.
    pc,

    pub const native: ShortcutPlatform = if (@import("builtin").target.os.tag == .macos) .mac else .pc;
};

pub fn primaryModifierOn(platform: ShortcutPlatform, modifiers: Modifiers) bool {
    return switch (platform) {
        .mac => modifiers.super,
        .pc => modifiers.ctrl,
    };
}

/// A platform-neutral modifier combination for application shortcuts.
pub const Chord = struct {
    /// ⌘ on macOS, Ctrl on Windows/Linux.
    primary: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// macOS ⌃, a modifier distinct from the command key. On Windows/Linux
    /// Ctrl *is* the command key, so a chord that needs `mac_ctrl` never
    /// matches there.
    mac_ctrl: bool = false,

    /// The chord the user pressed, or null when the modifiers have no meaning
    /// for application shortcuts on that platform (Super on Windows/Linux).
    pub fn of(modifiers: Modifiers, platform: ShortcutPlatform) ?Chord {
        return switch (platform) {
            .mac => .{ .primary = modifiers.super, .shift = modifiers.shift, .alt = modifiers.alt, .mac_ctrl = modifiers.ctrl },
            .pc => if (modifiers.super) null else .{ .primary = modifiers.ctrl, .shift = modifiers.shift, .alt = modifiers.alt },
        };
    }

    pub fn matches(self: Chord, modifiers: Modifiers, platform: ShortcutPlatform) bool {
        const actual = of(modifiers, platform) orelse return false;
        return std.meta.eql(self, actual);
    }

    /// Exact match against the host platform's conventions.
    pub fn pressed(self: Chord, modifiers: Modifiers) bool {
        return self.matches(modifiers, ShortcutPlatform.native);
    }

    /// The raw modifiers that produce this chord (null: unreachable there).
    pub fn modifiersOn(self: Chord, platform: ShortcutPlatform) ?Modifiers {
        return switch (platform) {
            .mac => .{ .super = self.primary, .shift = self.shift, .alt = self.alt, .ctrl = self.mac_ctrl },
            .pc => if (self.mac_ctrl) null else .{ .ctrl = self.primary, .shift = self.shift, .alt = self.alt },
        };
    }

    /// ⌥⌘ on macOS. Windows reads Ctrl+Alt as AltGr, which types characters on
    /// most European layouts, so the same command is Ctrl+Shift there.
    pub fn primaryAlt(platform: ShortcutPlatform) Chord {
        return switch (platform) {
            .mac => .{ .primary = true, .alt = true },
            .pc => .{ .primary = true, .shift = true },
        };
    }
};

test "Chord: primary is Cmd on mac and Ctrl on Windows/Linux" {
    const undo = Chord{ .primary = true };
    try std.testing.expect(undo.matches(.{ .super = true }, .mac));
    try std.testing.expect(!undo.matches(.{ .ctrl = true }, .mac));
    try std.testing.expect(undo.matches(.{ .ctrl = true }, .pc));
    try std.testing.expect(!undo.matches(.{ .super = true }, .pc));
    // Super never takes part in shortcuts on Windows/Linux.
    try std.testing.expect(Chord.of(.{ .ctrl = true, .super = true }, .pc) == null);
    // A macOS-only ⌃ chord is unreachable elsewhere.
    const emacs = Chord{ .mac_ctrl = true };
    try std.testing.expect(emacs.matches(.{ .ctrl = true }, .mac));
    try std.testing.expect(!emacs.matches(.{ .ctrl = true }, .pc));
    try std.testing.expect(emacs.modifiersOn(.pc) == null);
    try std.testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, (Chord{ .primary = true, .shift = true }).modifiersOn(.pc).?);
}

/// Multi-click detection window and pixel tolerance. 300ms / 5px is tight in desktop editors,
/// making double-click/triple-click feel one frame late or missed.
pub const multi_click_interval_ns: u64 = 450 * std.time.ns_per_ms;
pub const multi_click_slop_px: f32 = 8.0;
pub const multi_click_slop_sq: f32 = multi_click_slop_px * multi_click_slop_px;

/// Mouse button
pub const MouseButton = enum {
    left,
    right,
    middle,
};

/// Mouse button events (mouse_down / mouse_up)
pub const MouseButtonEvent = struct {
    x: f32,
    y: f32,
    button: MouseButton = .left,
    modifiers: Modifiers = .{},
};

/// Click event (complete click: down + up on same element)
pub const ClickEvent = struct {
    x: f32,
    y: f32,
    button: MouseButton = .left,
    modifiers: Modifiers = .{},
    click_count: u8 = 1,
};

/// Mouse move event
pub const MouseMoveEvent = struct {
    x: f32,
    y: f32,
    dx: f32 = 0,
    dy: f32 = 0,
    /// Host passes real-time value via Cx.handleMouseMoveEx; old handleMouseMove degenerates to .{}
    /// (does not feign real-time).
    modifiers: Modifiers = .{},
};

/// Keyboard key codes
pub const KeyCode = enum(u16) {
    // Letter keys
    a = 0,
    s = 1,
    d = 2,
    f = 3,
    h = 4,
    g = 5,
    z = 6,
    x = 7,
    c = 8,
    v = 9,
    b = 11,
    q = 12,
    w = 13,
    e = 14,
    r = 15,
    y = 16,
    t = 17,
    o = 31,
    u = 32,
    i = 34,
    p = 35,
    l = 37,
    j = 38,
    k = 40,
    n = 45,
    m = 46,

    // Number keys
    @"1" = 18,
    @"2" = 19,
    @"3" = 20,
    @"4" = 21,
    @"5" = 23,
    @"6" = 22,
    @"7" = 26,
    @"8" = 28,
    @"9" = 25,
    @"0" = 29,

    // Function keys
    @"return" = 36,
    tab = 48,
    space = 49,
    delete = 51,
    escape = 53,
    forward_delete = 117,

    // Arrow keys
    left = 123,
    right = 124,
    down = 125,
    up = 126,

    // Modifier keys
    left_shift = 56,
    right_shift = 60,
    left_ctrl = 59,
    right_ctrl = 62,
    left_alt = 58,
    right_alt = 61,
    left_super = 55,
    right_super = 54,

    // Symbol keys
    slash = 44,
    minus = 27,
    equal = 24,
    left_bracket = 33,
    right_bracket = 30,
    period = 47,
    comma = 43,
    semicolon = 41,
    quote = 39,
    backslash = 42,
    grave = 50,

    // Special keys
    home = 115,
    end = 119,
    page_up = 116,
    page_down = 121,
    /// Insert (PC keyboards; the Help key on Apple keyboards).
    insert = 114,

    // Function keys F1-F12 (macOS keycode)
    f1 = 122,
    f2 = 120,
    f3 = 99,
    f4 = 118,
    f5 = 96,
    f6 = 97,
    f7 = 98,
    f8 = 100,
    f9 = 101,
    f10 = 109,
    f11 = 103,
    f12 = 111,

    // Unknown
    unknown = 0xFFFF,

    pub fn fromRawKeycode(raw: u16) KeyCode {
        return std.enums.fromInt(KeyCode, raw) orelse .unknown;
    }

    /// Translate Win32 virtual-key codes into Zenit's logical key enum.
    /// Letter and digit VKs are layout-independent physical shortcuts here;
    /// committed characters continue to arrive through text_input.
    /// Linux/Wayland uses evdev key codes, without the XKB-only +8 offset.
    pub fn fromLinuxEvdev(raw: u16) KeyCode {
        return switch (raw) {
            1 => .escape,
            2 => .@"1",
            3 => .@"2",
            4 => .@"3",
            5 => .@"4",
            6 => .@"5",
            7 => .@"6",
            8 => .@"7",
            9 => .@"8",
            10 => .@"9",
            11 => .@"0",
            12 => .minus,
            13 => .equal,
            14 => .delete,
            15 => .tab,
            16 => .q,
            17 => .w,
            18 => .e,
            19 => .r,
            20 => .t,
            21 => .y,
            22 => .u,
            23 => .i,
            24 => .o,
            25 => .p,
            26 => .left_bracket,
            27 => .right_bracket,
            28 => .@"return",
            29 => .left_ctrl,
            30 => .a,
            31 => .s,
            32 => .d,
            33 => .f,
            34 => .g,
            35 => .h,
            36 => .j,
            37 => .k,
            38 => .l,
            39 => .semicolon,
            40 => .quote,
            41 => .grave,
            42 => .left_shift,
            43 => .backslash,
            44 => .z,
            45 => .x,
            46 => .c,
            47 => .v,
            48 => .b,
            49 => .n,
            50 => .m,
            51 => .comma,
            52 => .period,
            53 => .slash,
            54 => .right_shift,
            56 => .left_alt,
            57 => .space,
            59 => .f1,
            60 => .f2,
            61 => .f3,
            62 => .f4,
            63 => .f5,
            64 => .f6,
            65 => .f7,
            66 => .f8,
            67 => .f9,
            68 => .f10,
            87 => .f11,
            88 => .f12,
            96 => .@"return",
            97 => .right_ctrl,
            100 => .right_alt,
            102 => .home,
            103 => .up,
            104 => .page_up,
            105 => .left,
            106 => .right,
            107 => .end,
            108 => .down,
            109 => .page_down,
            110 => .insert,
            111 => .forward_delete,
            125 => .left_super,
            126 => .right_super,
            else => .unknown,
        };
    }

    pub fn fromWindowsVirtualKey(vk: u16) KeyCode {
        return switch (vk) {
            0x41 => .a,
            0x42 => .b,
            0x43 => .c,
            0x44 => .d,
            0x45 => .e,
            0x46 => .f,
            0x47 => .g,
            0x48 => .h,
            0x49 => .i,
            0x4A => .j,
            0x4B => .k,
            0x4C => .l,
            0x4D => .m,
            0x4E => .n,
            0x4F => .o,
            0x50 => .p,
            0x51 => .q,
            0x52 => .r,
            0x53 => .s,
            0x54 => .t,
            0x55 => .u,
            0x56 => .v,
            0x57 => .w,
            0x58 => .x,
            0x59 => .y,
            0x5A => .z,
            0x30 => .@"0",
            0x31 => .@"1",
            0x32 => .@"2",
            0x33 => .@"3",
            0x34 => .@"4",
            0x35 => .@"5",
            0x36 => .@"6",
            0x37 => .@"7",
            0x38 => .@"8",
            0x39 => .@"9",
            0x0D => .@"return",
            0x09 => .tab,
            0x20 => .space,
            0x08 => .delete,
            0x1B => .escape,
            0x2D => .insert,
            0x2E => .forward_delete,
            0x25 => .left,
            0x27 => .right,
            0x28 => .down,
            0x26 => .up,
            0x24 => .home,
            0x23 => .end,
            0x21 => .page_up,
            0x22 => .page_down,
            0xA0 => .left_shift,
            0xA1 => .right_shift,
            0xA2 => .left_ctrl,
            0xA3 => .right_ctrl,
            0xA4 => .left_alt,
            0xA5 => .right_alt,
            0x5B => .left_super,
            0x5C => .right_super,
            0xBF => .slash,
            0xBD => .minus,
            0xBB => .equal,
            0xDB => .left_bracket,
            0xDD => .right_bracket,
            0xBE => .period,
            0xBC => .comma,
            0xBA => .semicolon,
            0xDE => .quote,
            0xDC => .backslash,
            0xC0 => .grave,
            0x70 => .f1,
            0x71 => .f2,
            0x72 => .f3,
            0x73 => .f4,
            0x74 => .f5,
            0x75 => .f6,
            0x76 => .f7,
            0x77 => .f8,
            0x78 => .f9,
            0x79 => .f10,
            0x7A => .f11,
            0x7B => .f12,
            else => .unknown,
        };
    }
};

/// Keyboard event
pub const KeyEvent = struct {
    key: KeyCode = .unknown,
    raw_keycode: u16 = 0,
    modifiers: Modifiers = .{},
};

/// Text input event
pub const TextInputEvent = struct {
    text: []const u8,
};

/// IME replacementRange sentinel: this preedit/commit does not revise submitted text (current
/// behavior).
pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

/// IME preedit event
pub const ImePreeditEvent = struct {
    cursor_visible: bool = true,
    selection_end_utf8: ?u32 = null,
    text: []const u8,
    cursor_utf8_offset: u32 = 0,
    /// replacementRange converted to UTF-8 byte range (relative to document); re-convert and
    /// similar operations that pull submitted text back into composition mode when not sentinel.
    replace_start_utf8: u32 = ime_no_replacement,
    replace_end_utf8: u32 = ime_no_replacement,
};

/// IME commit event
pub const ImeCommitEvent = struct {
    text: []const u8,
    /// replacementRange converted to UTF-8 byte range (relative to document); when not sentinel,
    /// this commit should replace that range rather than land at cursor.
    replace_start_utf8: u32 = ime_no_replacement,
    replace_end_utf8: u32 = ime_no_replacement,
};

/// Trackpad scroll gesture phase (corresponds to NSEvent.phase). Mouse wheel and momentum events
/// are .none.
/// A gesture always starts with may_begin or began, ending with ended or cancelled.
pub const ScrollPhase = enum(u8) {
    none,
    /// Finger down but not yet moved; followed by began or cancelled.
    may_begin,
    began,
    changed,
    ended,
    cancelled,
};

/// Momentum phase after finger lift (corresponds to NSEvent.momentumPhase). Non-momentum events are
/// .none.
pub const MomentumPhase = enum(u8) { none, began, changed, ended };

/// Scroll wheel event
pub const ScrollEvent = struct {
    /// Scroll delta in logical points (normalized at the event bridge).
    dx: f32,
    /// Scroll delta in logical points (normalized at the event bridge).
    dy: f32,
    x: f32,
    y: f32,
    phase: ScrollPhase = .none,
    momentum: MomentumPhase = .none,
    /// Modifier key state when event occurs (Cmd/Ctrl+scroll = zoom and similar canvas interactions
    /// require this).
    modifiers: Modifiers = .{},

    /// Finger left trackpad (ended may be followed by momentum, cancelled has none).
    pub fn phaseEnded(self: ScrollEvent) bool {
        return self.phase == .ended or self.phase == .cancelled;
    }

    /// Momentum event after lift
    pub fn isMomentum(self: ScrollEvent) bool {
        return self.momentum != .none;
    }

    /// Trackpad event (has gesture phase or momentum); false = mouse wheel.
    pub fn isTrackpad(self: ScrollEvent) bool {
        return self.isMomentum() or self.phase != .none;
    }
};

/// Continuous gesture phase
pub const GesturePhase = enum(u8) { began, changed, ended, cancelled };

/// Trackpad pinch (magnify) event
pub const MagnifyEvent = struct {
    /// Relative delta: new_scale = old_scale * (1 + magnification), typical range 0.01~0.05.
    magnification: f32,
    x: f32,
    y: f32,
    phase: GesturePhase,
};

/// Drag event (Finder / browser drag-in)
pub const DragEvent = struct {
    pub const Kind = enum(u8) { entered, updated, exited, dropped };
    pub const PayloadKind = enum(u8) { none = 0, file_or_url = 1, text = 2, internal = 3 };

    x: f32,
    y: f32,
    kind: Kind,
    /// Valid when dropped. When payload_kind == .file_or_url, is newline-separated list; .text /
    /// .internal is single UTF-8 payload, may contain newlines. Slice valid only during dispatch;
    /// copy if retention needed. Content (including file-promise names) controlled by external
    /// process, must not be used as command, HTML, or unvalidated auth path.
    paths: []const u8 = "",
    payload_kind: PayloadKind = .none,
    /// Backend out of capacity: paths fully cleared to avoid consuming partial list.
    payload_truncated: bool = false,
    /// Platform drag data always untrusted; automation/internal synthesis may explicitly set false.
    payload_is_untrusted: bool = true,
};

/// Modifier key state
pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false, // Command on macOS
    _padding: u4 = 0,

    pub const NONE = Modifiers{};
};

/// A key plus exact modifiers, e.g. for `Cx.setReservedKeyChords`.
pub const KeyChord = struct {
    key: KeyCode,
    mods: Modifiers = .{},
};

/// Event propagation phase
pub const EventPhase = enum {
    /// Capture phase: root to target
    capture,
    /// Target phase: on target element
    target,
    /// Bubble phase: target to root
    bubble,
};

/// Focus change reason
pub const FocusReason = enum {
    click,
    tab,
    programmatic,
};

/// Focus event
pub const FocusEvent = struct {
    /// Related node ID (blurred node on focus, focused node on blur)
    related_node_id: ?u32 = null,
    /// Focus change reason
    reason: FocusReason = .programmatic,
};

/// Event type union
pub const Event = union(enum) {
    // Mouse event
    mouse_down: MouseButtonEvent,
    mouse_up: MouseButtonEvent,
    click: ClickEvent,
    double_click: ClickEvent,
    mouse_move: MouseMoveEvent,
    mouse_enter: void,
    mouse_leave: void,
    scroll: ScrollEvent,
    magnify: MagnifyEvent,
    drag: DragEvent,

    // Keyboard event
    key_down: KeyEvent,
    key_up: KeyEvent,

    // Text input
    text_input: TextInputEvent,
    ime_preedit: ImePreeditEvent,
    ime_commit: ImeCommitEvent,
    ime_delete_surrounding: struct { before_bytes: u32, after_bytes: u32 },

    // Focus event
    focus: FocusEvent,
    blur: FocusEvent,
};

/// Event handling result
pub const EventResult = enum {
    /// Event unhandled, continue propagation, default action allowed.
    ignored,
    /// Event handled, continue propagation, default action should be prevented.
    handled,
    /// Event handled, stop propagation, default action should be prevented.
    stop,
};

pub fn preventsDefault(result: EventResult) bool {
    return result != .ignored;
}

pub fn stopsPropagation(result: EventResult) bool {
    return result == .stop;
}

test "Event creation" {
    const click = ClickEvent{ .x = 100, .y = 200 };
    try std.testing.expectEqual(@as(f32, 100), click.x);

    const modifiers = Modifiers{ .shift = true, .ctrl = true };
    try std.testing.expect(modifiers.shift);
    try std.testing.expect(modifiers.ctrl);
}

test "MouseButtonEvent" {
    const down = MouseButtonEvent{ .x = 50, .y = 60, .button = .left };
    try std.testing.expectEqual(@as(f32, 50), down.x);
    try std.testing.expectEqual(MouseButton.left, down.button);
}

test "KeyCode: fromRawKeycode" {
    try std.testing.expectEqual(KeyCode.a, KeyCode.fromRawKeycode(0));
    try std.testing.expectEqual(KeyCode.@"return", KeyCode.fromRawKeycode(36));
    try std.testing.expectEqual(KeyCode.tab, KeyCode.fromRawKeycode(48));
    try std.testing.expectEqual(KeyCode.unknown, KeyCode.fromRawKeycode(0xFFFE));
}

test "KeyCode: Win32 virtual keys" {
    try std.testing.expectEqual(KeyCode.a, KeyCode.fromWindowsVirtualKey(0x41));
    try std.testing.expectEqual(KeyCode.v, KeyCode.fromWindowsVirtualKey(0x56));
    try std.testing.expectEqual(KeyCode.escape, KeyCode.fromWindowsVirtualKey(0x1B));
    try std.testing.expectEqual(KeyCode.left, KeyCode.fromWindowsVirtualKey(0x25));
    try std.testing.expectEqual(KeyCode.insert, KeyCode.fromWindowsVirtualKey(0x2D));
    try std.testing.expectEqual(KeyCode.insert, KeyCode.fromLinuxEvdev(110));
    try std.testing.expectEqual(KeyCode.unknown, KeyCode.fromWindowsVirtualKey(0xFF));
}

test "Event union: mouse_down" {
    const event = Event{ .mouse_down = .{ .x = 10, .y = 20 } };
    switch (event) {
        .mouse_down => |e| {
            try std.testing.expectEqual(@as(f32, 10), e.x);
        },
        else => unreachable,
    }
}

test "Event union: key_down" {
    const event = Event{ .key_down = .{
        .key = .a,
        .modifiers = .{ .super = true },
    } };
    switch (event) {
        .key_down => |e| {
            try std.testing.expectEqual(KeyCode.a, e.key);
            try std.testing.expect(e.modifiers.super);
        },
        else => unreachable,
    }
}

test "EventPhase" {
    try std.testing.expectEqual(EventPhase.capture, EventPhase.capture);
    try std.testing.expectEqual(EventPhase.bubble, EventPhase.bubble);
}

test "EventResult ordering" {
    // Verify result types exist
    try std.testing.expectEqual(EventResult.ignored, EventResult.ignored);
    try std.testing.expectEqual(EventResult.handled, EventResult.handled);
    try std.testing.expectEqual(EventResult.stop, EventResult.stop);
}

test "EventResult helpers" {
    try std.testing.expect(!preventsDefault(.ignored));
    try std.testing.expect(preventsDefault(.handled));
    try std.testing.expect(preventsDefault(.stop));
    try std.testing.expect(!stopsPropagation(.handled));
    try std.testing.expect(stopsPropagation(.stop));
}

test "Linux evdev keycodes remain separate from Mac and XKB keycodes" {
    try std.testing.expectEqual(KeyCode.a, KeyCode.fromLinuxEvdev(30));
    try std.testing.expectEqual(KeyCode.c, KeyCode.fromLinuxEvdev(46));
    try std.testing.expectEqual(KeyCode.@"return", KeyCode.fromLinuxEvdev(28));
    try std.testing.expectEqual(KeyCode.left, KeyCode.fromLinuxEvdev(105));
    try std.testing.expectEqual(KeyCode.right_alt, KeyCode.fromLinuxEvdev(100));
    try std.testing.expectEqual(KeyCode.unknown, KeyCode.fromLinuxEvdev(768));
}
