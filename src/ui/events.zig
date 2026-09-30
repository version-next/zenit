/// Event System - 事件定义和调度
///
/// Phase 3.3+: 完整事件系统
///
/// 支持:
/// - 鼠标事件: mouse_down, mouse_up, click, double_click, mouse_move, mouse_enter, mouse_leave, scroll
/// - 键盘事件: key_down, key_up
/// - 文本输入: text_input, ime_preedit, ime_commit
/// - 焦点事件: focus, blur
/// - 事件传播: capture → target → bubble (DOM 风格)
const std = @import("std");

/// 多击判定窗口与像素容差。
/// 300ms / 5px 在桌面编辑器里偏紧，容易让双击/三击感觉“慢一拍”或“没吃到”。
pub const multi_click_interval_ns: u64 = 450 * std.time.ns_per_ms;
pub const multi_click_slop_px: f32 = 8.0;
pub const multi_click_slop_sq: f32 = multi_click_slop_px * multi_click_slop_px;

/// 鼠标按钮
pub const MouseButton = enum {
    left,
    right,
    middle,
};

/// 鼠标按键事件 (mouse_down / mouse_up)
pub const MouseButtonEvent = struct {
    x: f32,
    y: f32,
    button: MouseButton = .left,
    modifiers: Modifiers = .{},
};

/// 点击事件 (完整点击: down + up 在同一元素)
pub const ClickEvent = struct {
    x: f32,
    y: f32,
    button: MouseButton = .left,
    modifiers: Modifiers = .{},
    click_count: u8 = 1,
};

/// 鼠标移动事件
pub const MouseMoveEvent = struct {
    x: f32,
    y: f32,
    dx: f32 = 0,
    dy: f32 = 0,
    /// 宿主经 `Cx.handleMouseMoveEx` 传入时为实时值；旧 `handleMouseMove`
    /// 入口退化为 `.{}`（不伪称实时）。
    modifiers: Modifiers = .{},
};

/// 键盘按键代码
pub const KeyCode = enum(u16) {
    // 字母键
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

    // 数字键
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

    // 功能键
    @"return" = 36,
    tab = 48,
    space = 49,
    delete = 51,
    escape = 53,
    forward_delete = 117,

    // 箭头键
    left = 123,
    right = 124,
    down = 125,
    up = 126,

    // 修饰键
    left_shift = 56,
    right_shift = 60,
    left_ctrl = 59,
    right_ctrl = 62,
    left_alt = 58,
    right_alt = 61,
    left_super = 55,
    right_super = 54,

    // 符号键
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

    // 特殊键
    home = 115,
    end = 119,
    page_up = 116,
    page_down = 121,

    // 功能键 F1-F12（macOS keycode）
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

    // 未知
    unknown = 0xFFFF,

    pub fn fromRawKeycode(raw: u16) KeyCode {
        return std.meta.intToEnum(KeyCode, raw) catch .unknown;
    }
};

/// 键盘事件
pub const KeyEvent = struct {
    key: KeyCode = .unknown,
    raw_keycode: u16 = 0,
    modifiers: Modifiers = .{},
};

/// 文本输入事件
pub const TextInputEvent = struct {
    text: []const u8,
};

/// IME replacementRange 哨兵：本次 preedit/commit 不修订已提交文本（现行为）。
pub const ime_no_replacement: u32 = 0xFFFF_FFFF;

/// IME 预编辑事件
pub const ImePreeditEvent = struct {
    text: []const u8,
    cursor_utf8_offset: u32 = 0,
    /// replacementRange 换算成的 UTF-8 字节区间（相对文档）；再変換等把已
    /// 提交文本拉回合成态时非哨兵。
    replace_start_utf8: u32 = ime_no_replacement,
    replace_end_utf8: u32 = ime_no_replacement,
};

/// IME 提交事件
pub const ImeCommitEvent = struct {
    text: []const u8,
    /// replacementRange 换算成的 UTF-8 字节区间（相对文档）；非哨兵时本次
    /// commit 应替换该区间而不是落在光标处。
    replace_start_utf8: u32 = ime_no_replacement,
    replace_end_utf8: u32 = ime_no_replacement,
};

/// 滚轮事件
pub const ScrollEvent = struct {
    dx: f32,
    dy: f32,
    x: f32,
    y: f32,
    /// true = 松手后惯性滚动（trackpad momentum），false = 手指触摸中或鼠标滚轮
    is_momentum: bool = false,
    /// true = 触摸板手指抬起 (NSEventPhaseEnded)
    phase_ended: bool = false,
    /// true = 触摸板事件（有 phase 信息），false = 鼠标滚轮
    is_trackpad: bool = false,
    /// 事件发生时的修饰键状态（Cmd/Ctrl+滚轮 = 缩放 等画布交互需要）
    modifiers: Modifiers = .{},
};

/// 连续手势阶段
pub const GesturePhase = enum(u8) { began, changed, ended, cancelled };

/// 触控板捏合（magnify）事件
pub const MagnifyEvent = struct {
    /// 相对增量：new_scale = old_scale * (1 + magnification)，典型值 0.01~0.05
    magnification: f32,
    x: f32,
    y: f32,
    phase: GesturePhase,
};

/// 拖放事件（Finder / 浏览器拖入）
pub const DragEvent = struct {
    pub const Kind = enum(u8) { entered, updated, exited, dropped };
    pub const PayloadKind = enum(u8) { none = 0, file_or_url = 1, text = 2, internal = 3 };

    x: f32,
    y: f32,
    kind: Kind,
    /// dropped 时有效。`payload_kind == .file_or_url` 时是换行分隔列表；
    /// `.text` / `.internal` 时是单个 UTF-8 payload，可合法包含换行。
    /// slice 仅事件派发期间有效，需要保留时自行 dupe。内容（含
    /// file-promise 文件名）由外部进程控制，不可直接当作命令、HTML 或
    /// 无需复验的授权路径使用。
    paths: []const u8 = "",
    payload_kind: PayloadKind = .none,
    /// 后端容量不足时为 true；此时 `paths` 会整体置空，避免消费半条路径。
    payload_truncated: bool = false,
    /// 平台拖入数据始终为不可信；自动化/应用内合成事件可显式设为 false。
    payload_is_untrusted: bool = true,
};

/// 修饰键状态
pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false, // Command on macOS
    _padding: u4 = 0,

    pub const NONE = Modifiers{};
};

/// 事件传播阶段
pub const EventPhase = enum {
    /// 捕获阶段: 从根到目标
    capture,
    /// 目标阶段: 在目标元素上
    target,
    /// 冒泡阶段: 从目标到根
    bubble,
};

/// 焦点变化原因
pub const FocusReason = enum {
    click,
    tab,
    programmatic,
};

/// 焦点事件
pub const FocusEvent = struct {
    /// 关联节点 ID (focus 时为失焦节点, blur 时为获焦节点)
    related_node_id: ?u32 = null,
    /// 焦点变化原因
    reason: FocusReason = .programmatic,
};

/// 事件类型联合
pub const Event = union(enum) {
    // 鼠标事件
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

    // 键盘事件
    key_down: KeyEvent,
    key_up: KeyEvent,

    // 文本输入
    text_input: TextInputEvent,
    ime_preedit: ImePreeditEvent,
    ime_commit: ImeCommitEvent,

    // 焦点事件
    focus: FocusEvent,
    blur: FocusEvent,
};

/// 事件处理结果
pub const EventResult = enum {
    /// 事件未处理，继续传播，默认行为允许执行
    ignored,
    /// 事件已处理，继续传播，默认行为应被阻止
    handled,
    /// 事件已处理，停止传播，默认行为应被阻止
    stop,
};

pub fn preventsDefault(result: EventResult) bool {
    return result != .ignored;
}

pub fn stopsPropagation(result: EventResult) bool {
    return result == .stop;
}

// ========== 测试 ==========

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
