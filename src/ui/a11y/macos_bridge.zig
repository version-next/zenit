//! macOS NSAccessibility C ABI bridge (zig 侧 export)
//!
//! v0.6 §2.1，让 macOS NSAccessibility 协议方法 (accessibilityChildren /
//! accessibilityHitTest: / accessibilityRole / etc.) 通过 C ABI 回弹 zig，
//! 从 cx.accessibility_tree 拉 a11y node 数据。
//!
//! 反向 (zig -> ObjC notify_*) 由本模块的 retained-tree push hooks 精确定位；
//! system_sdk 的 snapshot API 仅作为显式兼容入口保留。
//!
//! 设计:
//! - element_handle = ElementId.raw() (u32 packed)。ObjC 侧懒生成 NSAccessibilityElement
//!   代理对象时只持 handle，不持 zig 内存
//! - 字符串通过 cx.a11y_label_buf hash -> []const u8 反查；C ABI 把 UTF-8 字节 copy 到
//!   ObjC 提供的 buffer
//! - active context 按 window_id 路由（见 `g_active` 表）。ObjC 侧的
//!   ZenitA11yElement / MetalView 代理各自持所属 window_id，每次回调带进来

const std = @import("std");
const tree_mod = @import("tree.zig");
const router_mod = @import("nsaccessibility_router.zig");
const element_id_mod = @import("../core/element_id.zig");
const core_types = @import("../core/types.zig");

pub const ElementId = element_id_mod.ElementId;
pub const A11yNode = tree_mod.A11yNode;
pub const AccessibilityTree = tree_mod.AccessibilityTree;
pub const PlatformBridge = router_mod.PlatformBridge;

// compile-time invariant: tree.Role enum 顺序与 window_bridge.m 的
// ZenitA11yTreeRole NS_ENUM 必须一致。改 tree.Role 顺序要同步改 ObjC 端。
comptime {
    const r = tree_mod.Role;
    std.debug.assert(@intFromEnum(r.none) == 0);
    std.debug.assert(@intFromEnum(r.button) == 2);
    std.debug.assert(@intFromEnum(r.checkbox) == 3);
    std.debug.assert(@intFromEnum(r.progressbar) == 8);
    std.debug.assert(@intFromEnum(r.textbox) == 10);
    std.debug.assert(@intFromEnum(r.dialog) == 28);
    std.debug.assert(@intFromEnum(r.generic) == 51);
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .disabled = true })) == (@as(u32, 1) << 0));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .focused = true })) == (@as(u32, 1) << 12));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .secure = true })) == (@as(u32, 1) << 17));
    std.debug.assert(@as(u32, @bitCast(tree_mod.State{ .expanded_present = true })) == (@as(u32, 1) << 18));
    std.debug.assert(@as(u16, @bitCast(tree_mod.A11yDirtyFlag{ .geometry_changed = true })) == (@as(u16, 1) << 8));
    std.debug.assert(@as(u16, @bitCast(tree_mod.A11yDirtyFlag{ .selection_changed = true })) == (@as(u16, 1) << 9));
}

/// caller 必须实现的"从 ID 查 cx-level 字符串"接口。Cx 持有 a11y_label_buf
/// (hash -> []const u8)，把指向 buf 的 fn ptr 注入 setActiveContext。
pub const LabelResolver = *const fn (ctx: *anyopaque, hash: u64) ?[]const u8;

pub const Action = enum(u8) { press = 0, toggle = 1, increment = 2, decrement = 3 };
pub const ActionHandler = *const fn (ctx: *anyopaque, element: ElementId, action: Action) bool;
pub const SelectionHandler = *const fn (ctx: *anyopaque, element: ElementId, start_utf8: u32, end_utf8: u32) bool;
pub const FocusHandler = *const fn (ctx: *anyopaque, element: ElementId, focused: bool) bool;
pub const TextValueHandler = *const fn (ctx: *anyopaque, element: ElementId, value: []const u8) bool;
pub const NumericValueHandler = *const fn (ctx: *anyopaque, element: ElementId, value: f32) bool;
pub const TextFrameHandler = *const fn (ctx: *anyopaque, element: ElementId, start_utf8: u32, end_utf8: u32, out: *tree_mod.Frame) bool;
pub const TextRangeAtPointHandler = *const fn (ctx: *anyopaque, element: ElementId, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool;

const ActiveContext = struct {
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque = null,
    action_handler: ?ActionHandler = null,
    selection_handler: ?SelectionHandler = null,
    focus_handler: ?FocusHandler = null,
    text_value_handler: ?TextValueHandler = null,
    numeric_value_handler: ?NumericValueHandler = null,
    text_frame_handler: ?TextFrameHandler = null,
    text_range_at_point_handler: ?TextRangeAtPointHandler = null,
};

/// 同时可注册的窗口数上限。定长数组而非 HashMap：这张表在 NSAccessibility
/// 回调路径上被**高频**读（VoiceOver 每次导航都会走一遍 children/role/label），
/// 需要无分配的确定性查找；窗口数天然是个位数。
///
/// ⚠️ 线程模型：本表**依赖主线程串行化**，槽位写入（?Slot 多字 struct）不是
/// 原子的。AppKit 的 NSAccessibility 协议方法在主线程投递，zenit 渲染循环也在
/// 主线程，生产路径串行。若将来出现非主线程回调，需给槽位加原子指针/seqlock。
pub const MAX_WINDOWS = 16;

const Slot = struct {
    window_id: u32,
    ctx: ActiveContext,
};

var g_active: [MAX_WINDOWS]?Slot = @splat(null);

pub const TextInputAppliedHook = *const fn (window_id: u32, start_utf16: u64, end_utf16: u64, start_utf8: u32, end_utf8: u32) callconv(.c) c_int;
var g_text_input_applied_hook: ?TextInputAppliedHook = null;

pub fn setTextInputAppliedHook(hook: ?TextInputAppliedHook) void {
    g_text_input_applied_hook = hook;
}

/// Publish only an applied projection, never the speculative native packet.
/// Resolve focus afresh after dispatch: the handler may have removed its node.
pub fn publishAppliedPreedit(window_id: u32) void {
    const hook = g_text_input_applied_hook orelse return;
    const client = lookupTextInput(window_id) orelse return;
    if (client.secure) return;
    const marked = client.marked_range orelse return;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!marked(client.context, &start, &end) or start > end or end > client.text_len(client.context)) return;
    const start16 = utf16ForUtf8(client, start) orelse return;
    const end16 = utf16ForUtf8(client, end) orelse return;
    _ = hook(window_id, start16, end16, start, end);
}

/// Text input is registered independently from the retained accessibility
/// tree. AppKit calls NSTextInputClient synchronously during event handling;
/// consulting the last rendered AX snapshot here would be one frame stale.
pub const TextInputClientResolver = *const fn (ctx: *anyopaque) ?core_types.TextInputClient;
const TextInputSlot = struct {
    window_id: u32,
    context: *anyopaque,
    resolver: TextInputClientResolver,
};
var g_text_input: [MAX_WINDOWS]?TextInputSlot = @splat(null);

fn lookupTextInput(window_id: u32) ?core_types.TextInputClient {
    if (window_id == ANY_WINDOW) {
        for (g_text_input) |maybe| if (maybe) |slot| return slot.resolver(slot.context);
        return null;
    }
    for (g_text_input) |maybe| if (maybe) |slot| {
        if (slot.window_id == window_id) return slot.resolver(slot.context);
    };
    return null;
}

pub fn setTextInputResolver(window_id: u32, context: *anyopaque, resolver: TextInputClientResolver) bool {
    var free_idx: ?usize = null;
    for (&g_text_input, 0..) |*maybe, i| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                maybe.* = .{ .window_id = window_id, .context = context, .resolver = resolver };
                return true;
            }
        } else if (free_idx == null) free_idx = i;
    }
    const idx = free_idx orelse return false;
    g_text_input[idx] = .{ .window_id = window_id, .context = context, .resolver = resolver };
    return true;
}

/// Unregister only the synchronous text client. Accessibility snapshots have
/// an independent lifetime and must not be torn down merely because a system
/// SDK/window backend is being replaced.
pub fn clearTextInputResolver(window_id: u32) void {
    for (&g_text_input) |*maybe| if (maybe.*) |slot| {
        if (slot.window_id == window_id) maybe.* = null;
    };
}

pub fn clearTextInputResolverForOwner(window_id: u32, owner: *anyopaque) void {
    for (&g_text_input) |*maybe| if (maybe.*) |slot| {
        if (slot.window_id == window_id and slot.context == owner) maybe.* = null;
    };
}

/// ObjC 端在拿不到具体 window_id 时传的通配值（旧 single-window 代理、
/// 未接线的 test harness）。查找时退化成"表里第一个有效窗口"。
pub const ANY_WINDOW: u32 = 0;
/// C ABI missing-handle sentinel. Handle zero is a valid first ElementId and
/// must never be overloaded as failure.
pub const INVALID_HANDLE: u32 = ElementId.NULL.raw();

fn lookup(window_id: u32) ?ActiveContext {
    if (window_id == ANY_WINDOW) {
        for (g_active) |maybe| {
            if (maybe) |slot| return slot.ctx;
        }
        return null;
    }
    for (g_active) |maybe| {
        if (maybe) |slot| {
            if (slot.window_id == window_id) return slot.ctx;
        }
    }
    return null;
}

/// cx 在 init/render 路径设这个；deinit 清空。
///
/// 按 `window_id` 注册：多个窗口各自注册自己的 a11y 树，ObjC 侧的代理对象
/// 持所属 window_id 回调进来时命中各自的槽位，互不覆盖。
/// 同一 window_id 重复注册 = 原地更新（每帧 syncA11yTree 都会调）。
///
/// 表满时静默丢弃（返回 false），a11y 降级好过让渲染路径报错。
pub fn setActiveContext(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
) bool {
    return setActiveContextWithFullInteractions(
        window_id,
        tree,
        label_ctx,
        label_resolver,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
}

/// Production registration including callable interaction routes. Tests and
/// non-interactive consumers may keep using setActiveContext, which advertises
/// no callable native actions and therefore fails closed.
pub fn setActiveContextWithInteractions(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque,
    action_handler: ?ActionHandler,
    selection_handler: ?SelectionHandler,
) bool {
    return setActiveContextWithFullInteractions(
        window_id,
        tree,
        label_ctx,
        label_resolver,
        interaction_ctx,
        action_handler,
        selection_handler,
        null,
        null,
        null,
        null,
        null,
    );
}

pub fn setActiveContextWithFullInteractions(
    window_id: u32,
    tree: *AccessibilityTree,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
    interaction_ctx: ?*anyopaque,
    action_handler: ?ActionHandler,
    selection_handler: ?SelectionHandler,
    focus_handler: ?FocusHandler,
    text_value_handler: ?TextValueHandler,
    numeric_value_handler: ?NumericValueHandler,
    text_frame_handler: ?TextFrameHandler,
    text_range_at_point_handler: ?TextRangeAtPointHandler,
) bool {
    const ctx = ActiveContext{
        .tree = tree,
        .label_ctx = label_ctx,
        .label_resolver = label_resolver,
        .interaction_ctx = interaction_ctx,
        .action_handler = action_handler,
        .selection_handler = selection_handler,
        .focus_handler = focus_handler,
        .text_value_handler = text_value_handler,
        .numeric_value_handler = numeric_value_handler,
        .text_frame_handler = text_frame_handler,
        .text_range_at_point_handler = text_range_at_point_handler,
    };
    var free_idx: ?usize = null;
    for (&g_active, 0..) |*maybe, i| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                maybe.* = .{ .window_id = window_id, .ctx = ctx };
                return true;
            }
        } else if (free_idx == null) {
            free_idx = i;
        }
    }
    const idx = free_idx orelse return false;
    g_active[idx] = .{ .window_id = window_id, .ctx = ctx };
    return true;
}

/// 注销某个窗口的 a11y 树。其他窗口的注册不受影响。
pub fn clearActiveContext(window_id: u32) void {
    var removed = false;
    for (&g_active) |*maybe| {
        if (maybe.*) |slot| {
            if (slot.window_id == window_id) {
                maybe.* = null;
                removed = true;
            }
        }
    }
    if (removed) {
        if (g_push_hooks.window_cleared) |hook| _ = hook(window_id);
    }
    clearTextInputResolver(window_id);
}

/// A newly allocated Cx still has a default window id, and an old Cx may be
/// destroyed after its replacement registers. Neither owns the other Cx's
/// registrations merely because the numeric window id happens to match.
pub fn clearActiveContextForOwner(window_id: u32, owner: *anyopaque) void {
    var removed = false;
    for (&g_active) |*maybe| if (maybe.*) |slot| {
        if (slot.window_id == window_id and slot.ctx.label_ctx == owner) {
            maybe.* = null;
            removed = true;
        }
    };
    if (removed) {
        if (g_push_hooks.window_cleared) |hook| _ = hook(window_id);
    }
    clearTextInputResolverForOwner(window_id, owner);
}

/// 清空整张表（测试 fixture 用；生产路径应按窗口 clearActiveContext）。
pub fn clearAllActiveContexts() void {
    g_active = @splat(null);
    g_text_input = @splat(null);
}

/// 当前已注册的窗口数（诊断/测试用）。
pub fn activeContextCount() usize {
    var n: usize = 0;
    for (g_active) |maybe| {
        if (maybe != null) n += 1;
    }
    return n;
}

// ============================================================================
// C ABI exports (ObjC 调进来)
// ----------------------------------------------------------------------------
// 每个 export 的首参都是 `window_id`, ObjC 侧的 ZenitA11yElement / MetalView
// 代理持所属窗口的 id 并在每次协议方法里带进来，zig 端据此路由到该窗口自己的
// AccessibilityTree。传 ANY_WINDOW(0) 退化成"第一个已注册窗口"（旧行为）。
// ============================================================================

const INVALID_TEXT_OFFSET: u64 = std.math.maxInt(u64);

export fn zenit_text_input_length(window_id: u32) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    return @intCast(client.text_len(client.context));
}

export fn zenit_text_input_copy(window_id: u32, start_utf8: u64, buf: ?[*]u8, buf_len: c_int) c_int {
    if (buf_len < 0 or (buf_len > 0 and buf == null)) return -1;
    const client = lookupTextInput(window_id) orelse return -1;
    if (client.secure) return -1;
    const total = client.text_len(client.context);
    const start = std.math.cast(usize, start_utf8) orelse return -1;
    if (start > total) return -1;
    if (buf_len == 0) return 0;
    const out = buf.?[0..@intCast(buf_len)];
    const copied = @min(client.copy_text(client.context, start, out), out.len);
    return @intCast(copied);
}

export fn zenit_text_input_selection(window_id: u32, start: ?*u32, end: ?*u32, caret: ?*u32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const total: u32 = @intCast(@min(client.text_len(client.context), std.math.maxInt(u32)));
    const selection = client.selection(client.context);
    if (start) |out| out.* = @min(selection.start, total);
    if (end) |out| out.* = @min(selection.end, total);
    if (caret) |out| out.* = @min(selection.caret, total);
    return 1;
}

export fn zenit_text_input_frame(window_id: u32, start_utf8: u32, end_utf8: u32, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const callback = client.frame_for_range orelse return 0;
    var rect: core_types.A11yRect = undefined;
    if (!callback(client.context, start_utf8, end_utf8, &rect)) return 0;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return 0;
    if (x) |out| out.* = rect.x;
    if (y) |out| out.* = rect.y;
    if (width) |out| out.* = rect.width;
    if (height) |out| out.* = rect.height;
    return 1;
}

export fn zenit_text_input_range_at_point(window_id: u32, x: f32, y: f32, start_utf8: ?*u32, end_utf8: ?*u32) c_int {
    const client = lookupTextInput(window_id) orelse return 0;
    if (client.secure) return 0;
    const callback = client.range_at_point orelse return 0;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!callback(client.context, x, y, &start, &end)) return 0;
    if (start_utf8) |out| out.* = start;
    if (end_utf8) |out| out.* = end;
    return 1;
}

fn validUtf8ChunkPrefix(bytes: []const u8) usize {
    var len = bytes.len;
    var attempts: u3 = 0;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len]) and attempts < 4) : (attempts += 1) len -= 1;
    return if (std.unicode.utf8ValidateSlice(bytes[0..len])) len else 0;
}

/// Scan a live UTF-8 model without materialising the complete document. The
/// return values are clamped down to scalar boundaries, matching NSString's
/// behaviour for malformed half-surrogate range requests.
fn utf16ForUtf8(client: core_types.TextInputClient, requested: usize) ?u64 {
    const total = client.text_len(client.context);
    const target = @min(requested, total);
    var byte_pos: usize = 0;
    var utf16_pos: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (byte_pos < target) {
        // Read past `target` when possible. A native UTF-16 request may land
        // in the middle of a UTF-8 scalar; limiting the copy to `target`
        // would leave only an invalid prefix (for example the first two bytes
        // of a three-byte CJK scalar). Reading the complete scalar lets us
        // clamp the request down to its start, as NSTextInputClient expects.
        const wanted = @min(buf.len, total - byte_pos);
        const copied = @min(client.copy_text(client.context, byte_pos, buf[0..wanted]), wanted);
        if (copied == 0) return null;
        const valid_len = validUtf8ChunkPrefix(buf[0..copied]);
        if (valid_len == 0) return null;
        var i: usize = 0;
        while (i < valid_len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch return null;
            if (i + seq_len > valid_len) break;
            if (byte_pos + i + seq_len > target) return utf16_pos;
            const scalar = std.unicode.utf8Decode(buf[i .. i + seq_len]) catch return null;
            utf16_pos += if (scalar > 0xFFFF) 2 else 1;
            i += seq_len;
        }
        byte_pos += valid_len;
    }
    return utf16_pos;
}

fn utf8ForUtf16(client: core_types.TextInputClient, requested: u64) ?u64 {
    const total = client.text_len(client.context);
    var byte_pos: usize = 0;
    var utf16_pos: u64 = 0;
    var buf: [4096]u8 = undefined;
    while (byte_pos < total) {
        const wanted = @min(buf.len, total - byte_pos);
        const copied = @min(client.copy_text(client.context, byte_pos, buf[0..wanted]), wanted);
        if (copied == 0) return null;
        const valid_len = validUtf8ChunkPrefix(buf[0..copied]);
        if (valid_len == 0) return null;
        var i: usize = 0;
        while (i < valid_len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch return null;
            if (i + seq_len > valid_len) break;
            const scalar = std.unicode.utf8Decode(buf[i .. i + seq_len]) catch return null;
            const units: u64 = if (scalar > 0xFFFF) 2 else 1;
            if (utf16_pos + units > requested) return @intCast(byte_pos + i);
            utf16_pos += units;
            i += seq_len;
            if (utf16_pos == requested) return @intCast(byte_pos + i);
        }
        byte_pos += valid_len;
    }
    return @intCast(total);
}

export fn zenit_text_input_utf16_for_utf8(window_id: u32, utf8_offset: u64) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    if (client.secure) return INVALID_TEXT_OFFSET;
    const requested = std.math.cast(usize, utf8_offset) orelse return INVALID_TEXT_OFFSET;
    return utf16ForUtf8(client, requested) orelse INVALID_TEXT_OFFSET;
}

export fn zenit_text_input_utf8_for_utf16(window_id: u32, utf16_offset: u64) u64 {
    const client = lookupTextInput(window_id) orelse return INVALID_TEXT_OFFSET;
    if (client.secure) return INVALID_TEXT_OFFSET;
    return utf8ForUtf16(client, utf16_offset) orelse INVALID_TEXT_OFFSET;
}

/// 顶级 a11y 节点数 (parent.isNull())。
export fn zenit_a11y_root_count(window_id: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    var n: c_int = 0;
    for (active.tree.nodes.items) |maybe| {
        if (maybe) |node| {
            if (node.parent.isNull() and !node.state.hidden) n += 1;
        }
    }
    return n;
}

/// 第 idx 个 root 的 handle，按 sibling_index（再按 raw handle）稳定排序。
/// 越界返回 INVALID_HANDLE；ElementId raw=0 是合法句柄。
export fn zenit_a11y_root_at(window_id: u32, idx: c_int) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    if (idx < 0) return INVALID_HANDLE;
    return nthExposedChild(active.tree, ElementId.NULL, @intCast(idx)) orelse INVALID_HANDLE;
}

/// Whether a virtual element handle still belongs to the current window tree.
/// Native bridges use this to retain live NSAccessibilityElement instances
/// while pruning stale generational handles after a rebuild.
export fn zenit_a11y_exists(window_id: u32, handle: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    return if (active.tree.get(ElementId.fromRaw(handle)) != null) 1 else 0;
}

/// 某节点的 a11y children 数。
export fn zenit_a11y_children_count(window_id: u32, parent_raw: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const parent = ElementId.fromRaw(parent_raw);
    var n: c_int = 0;
    for (active.tree.nodes.items) |maybe| {
        if (maybe) |node| {
            if (node.parent.eql(parent) and !node.state.hidden) n += 1;
        }
    }
    return n;
}

/// 第 idx 个 child handle。
export fn zenit_a11y_children_at(window_id: u32, parent_raw: u32, idx: c_int) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    if (idx < 0) return INVALID_HANDLE;
    const parent = ElementId.fromRaw(parent_raw);
    return nthExposedChild(active.tree, parent, @intCast(idx)) orelse INVALID_HANDLE;
}

fn nodeComesBefore(a: A11yNode, b: A11yNode) bool {
    if (a.sibling_index != b.sibling_index) return a.sibling_index < b.sibling_index;
    return a.element.raw() < b.element.raw();
}

/// Allocation-free nth-child selection for the high-frequency native pull
/// path. Typical sibling sets are small; deterministic O(n * idx) is preferable
/// to allocating/sorting inside AppKit callbacks.
fn nthExposedChild(tree: *const AccessibilityTree, parent: ElementId, requested: usize) ?u32 {
    var previous: ?A11yNode = null;
    var rank: usize = 0;
    while (rank <= requested) : (rank += 1) {
        var best: ?A11yNode = null;
        for (tree.nodes.items) |maybe| {
            const node = maybe orelse continue;
            if (node.state.hidden or !node.parent.eql(parent)) continue;
            if (previous) |prev| {
                if (!nodeComesBefore(prev, node)) continue;
            }
            if (best == null or nodeComesBefore(node, best.?)) best = node;
        }
        const found = best orelse return null;
        if (rank == requested) return found.element.raw();
        previous = found;
    }
    return null;
}

/// 节点 role（a11y_tree.Role 的 u16）。无效 handle 或不存在 -> .none (0)。
export fn zenit_a11y_role(window_id: u32, handle: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    return @intCast(@intFromEnum(node.role));
}

/// 节点 state packed bits (a11y_tree.State 的 u32)。
export fn zenit_a11y_state(window_id: u32, handle: u32) u32 {
    const active = lookup(window_id) orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    return @bitCast(node.state);
}

/// Parent/focus/active-descendant relationships are pulled by the native
/// proxy cache. INVALID_HANDLE means absent and is never confused with a live
/// index-zero element.
export fn zenit_a11y_parent(window_id: u32, handle: u32) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return INVALID_HANDLE;
    return if (node.parent.isNull()) INVALID_HANDLE else node.parent.raw();
}

export fn zenit_a11y_focused(window_id: u32) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const focused = active.tree.focused;
    const node = active.tree.get(focused) orelse return INVALID_HANDLE;
    if (node.state.hidden or !node.state.focused) return INVALID_HANDLE;
    return focused.raw();
}

export fn zenit_a11y_active_descendant(window_id: u32, handle: u32) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return INVALID_HANDLE;
    if (node.active_descendant.isNull()) return INVALID_HANDLE;
    const descendant = active.tree.get(node.active_descendant) orelse return INVALID_HANDLE;
    if (descendant.state.hidden) return INVALID_HANDLE;
    if (!isDescendantOf(active.tree, descendant, node.element)) return INVALID_HANDLE;
    return descendant.element.raw();
}

fn isDescendantOf(tree: *const AccessibilityTree, child: A11yNode, ancestor: ElementId) bool {
    var parent = child.parent;
    var depth: usize = 0;
    while (!parent.isNull() and depth <= tree.nodes.items.len) : (depth += 1) {
        if (parent.eql(ancestor)) return true;
        const node = tree.get(parent) orelse return false;
        parent = node.parent;
    }
    return false;
}

/// Deepest exposed element containing a window-content point. Equal-depth
/// overlap resolves to later sibling order, matching retained paint order.
export fn zenit_a11y_hit_test(window_id: u32, x: f32, y: f32) u32 {
    const active = lookup(window_id) orelse return INVALID_HANDLE;
    var best: ?A11yNode = null;
    var best_depth: usize = 0;
    for (active.tree.nodes.items) |maybe| {
        const node = maybe orelse continue;
        if (node.state.hidden or !node.frame.isUsable() or node.frame.width <= 0 or node.frame.height <= 0) continue;
        if (x < node.frame.x or y < node.frame.y or
            x > node.frame.x + node.frame.width or y > node.frame.y + node.frame.height) continue;
        const depth = nodeDepth(active.tree, node);
        if (best == null or depth > best_depth or
            (depth == best_depth and nodeComesBefore(best.?, node)))
        {
            best = node;
            best_depth = depth;
        }
    }
    return if (best) |node| node.element.raw() else INVALID_HANDLE;
}

fn nodeDepth(tree: *const AccessibilityTree, start: A11yNode) usize {
    var depth: usize = 0;
    var parent = start.parent;
    // A malformed cycle must not make an AX callback hang.
    while (!parent.isNull() and depth <= tree.nodes.items.len) : (depth += 1) {
        const node = tree.get(parent) orelse break;
        parent = node.parent;
    }
    return depth;
}

/// Element frame in window content coordinates (logical points, top-left
/// origin). Return 1 on success; invalid/stale handles return 0 and never write.
export fn zenit_a11y_frame(window_id: u32, handle: u32, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    if (!node.frame.isUsable()) return 0;
    if (x) |out| out.* = node.frame.x;
    if (y) |out| out.* = node.frame.y;
    if (width) |out| out.* = node.frame.width;
    if (height) |out| out.* = node.frame.height;
    return 1;
}

export fn zenit_a11y_orientation(window_id: u32, handle: u32) u8 {
    const active = lookup(window_id) orelse return @intFromEnum(tree_mod.Orientation.undefined);
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return @intFromEnum(tree_mod.Orientation.undefined);
    return @intFromEnum(node.orientation);
}

export fn zenit_a11y_sort_direction(window_id: u32, handle: u32) u8 {
    const active = lookup(window_id) orelse return @intFromEnum(tree_mod.SortDirection.none);
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return @intFromEnum(tree_mod.SortDirection.none);
    return @intFromEnum(node.sort_direction);
}

export fn zenit_a11y_level(window_id: u32, handle: u32) u16 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    return node.level;
}

export fn zenit_a11y_row_index_range(window_id: u32, handle: u32, index: ?*u32, span: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    switch (node.role) {
        .row, .cell, .rowheader, .columnheader => {
            if (index) |out| out.* = node.row_index;
        },
        .treeitem => {
            if (index) |out| out.* = node.row_index;
        },
        .listitem => {
            if (index) |out| out.* = node.sibling_index;
        },
        else => return 0,
    }
    if (span) |out| out.* = @max(node.row_span, 1);
    return 1;
}

export fn zenit_a11y_column_index_range(window_id: u32, handle: u32, index: ?*u32, span: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    switch (node.role) {
        .cell, .rowheader, .columnheader => {},
        else => return 0,
    }
    if (index) |out| out.* = node.column_index;
    if (span) |out| out.* = @max(node.column_span, 1);
    return 1;
}

/// Packed tree.Actions. Capability bits are additionally masked by whether
/// this window registered a live interaction handler.
export fn zenit_a11y_actions(window_id: u32, handle: u32) u8 {
    const active = lookup(window_id) orelse return 0;
    if (active.interaction_ctx == null or active.action_handler == null) return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    if (node.state.disabled) return 0;
    return @bitCast(node.actions);
}

export fn zenit_a11y_perform_action(window_id: u32, handle: u32, action_raw: u8) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.action_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (node.state.disabled) return 0;
    const action = std.meta.intToEnum(Action, action_raw) catch return 0;
    const advertised = switch (action) {
        .press => node.actions.press,
        .toggle => node.actions.toggle,
        .increment => node.actions.increment,
        .decrement => node.actions.decrement,
    };
    if (!advertised) return 0;
    return if (handler(ctx, id, action)) 1 else 0;
}

export fn zenit_a11y_set_focus(window_id: u32, handle: u32, focused: c_int) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.focus_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    // Clearing stale focus remains legal after a control becomes disabled or
    // hidden; acquiring focus is restricted to an enabled, exposed target.
    if (focused != 0 and (!node.state.focusable or node.state.disabled or node.state.hidden)) return 0;
    if (focused == 0 and !node.state.focused) return 0;
    return if (handler(ctx, id, focused != 0)) 1 else 0;
}

/// Returns UTF-8 byte selection/caret offsets. Native bridges convert these to
/// their required unit (UTF-16 on AppKit). No complete contract => return 0.
export fn zenit_a11y_text_selection(window_id: u32, handle: u32, start: ?*u32, end: ?*u32, caret: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (start) |out| out.* = editable.selection_start;
    if (end) |out| out.* = editable.selection_end;
    if (caret) |out| out.* = editable.caret;
    return 1;
}

/// bit 0 = readable range/value contract, bit 1 = writable selection,
/// bit 2 = writable value, bit 3 = range geometry / point hit-testing.
export fn zenit_a11y_text_capabilities(window_id: u32, handle: u32) u8 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    const mutable = active.interaction_ctx != null and !node.state.disabled and !node.state.readonly;
    return @as(u8, 1) |
        (if (editable.can_set_selection and active.selection_handler != null and mutable) @as(u8, 2) else 0) |
        (if (editable.can_set_value and active.text_value_handler != null and mutable) @as(u8, 4) else 0) |
        (if (active.text_frame_handler != null and active.text_range_at_point_handler != null) @as(u8, 8) else 0);
}

export fn zenit_a11y_set_text_selection(window_id: u32, handle: u32, start_utf8: u32, end_utf8: u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.selection_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (!editable.can_set_selection or node.state.disabled or node.state.readonly) return 0;
    return if (handler(ctx, id, start_utf8, end_utf8)) 1 else 0;
}

export fn zenit_a11y_text_visible_range(window_id: u32, handle: u32, start: ?*u32, end: ?*u32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (start) |out| out.* = editable.visible_start;
    if (end) |out| out.* = editable.visible_end;
    return 1;
}

export fn zenit_a11y_set_text_value(window_id: u32, handle: u32, bytes: ?[*]const u8, len: c_int) c_int {
    if (len < 0 or (len > 0 and bytes == null)) return 0;
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_value_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const editable = node.editable_text orelse return 0;
    if (!editable.can_set_value or node.state.disabled or node.state.readonly) return 0;
    const value = if (len == 0) "" else bytes.?[0..@intCast(len)];
    return if (handler(ctx, id, value)) 1 else 0;
}

export fn zenit_a11y_text_frame(
    window_id: u32,
    handle: u32,
    start_utf8: u32,
    end_utf8: u32,
    x: ?*f32,
    y: ?*f32,
    width: ?*f32,
    height: ?*f32,
) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_frame_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (node.editable_text == null) return 0;
    var frame: tree_mod.Frame = .{};
    if (!handler(ctx, id, start_utf8, end_utf8, &frame) or !frame.isUsable()) return 0;
    if (x) |out| out.* = frame.x;
    if (y) |out| out.* = frame.y;
    if (width) |out| out.* = frame.width;
    if (height) |out| out.* = frame.height;
    return 1;
}

export fn zenit_a11y_text_range_at_point(
    window_id: u32,
    handle: u32,
    x: f32,
    y: f32,
    start_utf8: ?*u32,
    end_utf8: ?*u32,
) c_int {
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.text_range_at_point_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (node.editable_text == null) return 0;
    var start: u32 = 0;
    var end: u32 = 0;
    if (!handler(ctx, id, x, y, &start, &end)) return 0;
    if (start_utf8) |out| out.* = start;
    if (end_utf8) |out| out.* = end;
    return 1;
}

export fn zenit_a11y_set_numeric_value(window_id: u32, handle: u32, value: f32) c_int {
    if (!std.math.isFinite(value)) return 0;
    const active = lookup(window_id) orelse return 0;
    const ctx = active.interaction_ctx orelse return 0;
    const handler = active.numeric_value_handler orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    if (!validNumericNode(node) or !node.can_set_numeric_value or node.state.disabled or node.state.readonly) return 0;
    const clamped = std.math.clamp(value, node.value_min, node.value_max);
    return if (handler(ctx, id, clamped)) 1 else 0;
}

/// bit 0 = readable numeric contract, bit 1 = writable numeric value.
export fn zenit_a11y_numeric_capabilities(window_id: u32, handle: u32) u8 {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    if (!validNumericNode(node)) return 0;
    const readable: u8 = switch (node.role) {
        .slider, .spinbutton, .progressbar => 1,
        else => 0,
    };
    if (readable == 0) return 0;
    const writable = active.interaction_ctx != null and active.numeric_value_handler != null and
        node.can_set_numeric_value and !node.state.disabled and !node.state.readonly;
    return readable | (if (writable) @as(u8, 2) else 0);
}

/// label 拷贝到 buf。返回写入字节数 (UTF-8)；0 表示无 label / 失败。
/// ObjC 侧典型用法：先调一次拿长度（buf=NULL, buf_len=0 时 zig 会返实际长度供 caller 分配）。
export fn zenit_a11y_label(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .label, buf, buf_len);
}

export fn zenit_a11y_description(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .description, buf, buf_len);
}

export fn zenit_a11y_placeholder(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .placeholder, buf, buf_len);
}

export fn zenit_a11y_identifier(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .identifier, buf, buf_len);
}

export fn zenit_a11y_value(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int {
    return resolveStringFromNode(window_id, handle, .value, buf, buf_len);
}

export fn zenit_a11y_numeric_value(window_id: u32, handle: u32, now: ?*f32, min: ?*f32, max: ?*f32) c_int {
    const active = lookup(window_id) orelse return 0;
    const node = active.tree.get(ElementId.fromRaw(handle)) orelse return 0;
    if (!validNumericNode(node)) return 0;
    switch (node.role) {
        .slider, .spinbutton, .progressbar => {},
        else => return 0,
    }
    if (now) |out| out.* = node.value_now;
    if (min) |out| out.* = node.value_min;
    if (max) |out| out.* = node.value_max;
    return 1;
}

fn validNumericNode(node: A11yNode) bool {
    return node.numeric_value_present and
        std.math.isFinite(node.value_now) and
        std.math.isFinite(node.value_min) and
        std.math.isFinite(node.value_max) and
        node.value_min <= node.value_max and
        node.value_now >= node.value_min and node.value_now <= node.value_max;
}

const StringField = enum { label, description, placeholder, identifier, value };

fn resolveStringFromNode(window_id: u32, handle: u32, field: StringField, buf: ?[*]u8, buf_len: c_int) c_int {
    const active = lookup(window_id) orelse return 0;
    const id = ElementId.fromRaw(handle);
    const node = active.tree.get(id) orelse return 0;
    const hash: u64 = switch (field) {
        .label => node.label_hash,
        .description => node.description_hash,
        .placeholder => node.placeholder_hash,
        .identifier => node.identifier_hash,
        .value => node.text_hash,
    };
    if (hash == 0) return 0;
    const str = active.label_resolver(active.label_ctx, hash) orelse return 0;
    if (str.len == 0) return 0;

    // probe 模式：buf=NULL -> 返实际长度
    if (buf == null or buf_len <= 0) return @intCast(str.len);

    const write_len = @min(@as(usize, @intCast(buf_len)), str.len);
    @memcpy(buf.?[0..write_len], str[0..write_len]);
    return @intCast(write_len);
}

// ============================================================================
// Push side (zig -> ObjC NSAccessibilityPostNotification)
// ----------------------------------------------------------------------------
// cx.render() 末尾 a11y_router.flushToBridge 把 dirty queue 推到
// 这里。window_id 由 PushCxRef 携带（cx 持的 system_sdk WindowId），ObjC 端
// zenitWrapperForWindowId 按 NSWindow.windowNumber 匹配到对应 wrapper。
//
// All retained-tree notifications use this exact-element route. The older
// SystemSdk snapshot calls remain an explicit compatibility API and Cx does
// not automatically duplicate focus notifications through that path.
// ============================================================================

/// Platform push hooks, example builds (window_bridge.m linked) override 这些 fn ptr
/// 把通知发到 NSAccessibilityPostNotification；test builds 默认 no-op 不触发 link 错误。
/// 设计上类比 weak symbol; runtime register via setPushHooks.
pub const PushHooks = struct {
    property_changed: ?*const fn (window_id: u32, element_raw: u32, flags: u16) callconv(.c) c_int = null,
    focus_changed: ?*const fn (window_id: u32, element_raw: u32) callconv(.c) c_int = null,
    children_changed: ?*const fn (window_id: u32, element_raw: u32) callconv(.c) c_int = null,
    announce: ?*const fn (window_id: u32, text_ptr: [*]const u8, text_len: c_int, priority: u8) callconv(.c) c_int = null,
    /// aria-activedescendant, caller pass container ElementId
    /// (combobox/listbox/grid) + 当前 active 子项 ElementId。当 active.isNull() 时
    /// 表示无 active descendant (popover 关闭等)。
    active_descendant_changed: ?*const fn (window_id: u32, container_raw: u32, active_raw: u32) callconv(.c) c_int = null,
    window_cleared: ?*const fn (window_id: u32) callconv(.c) c_int = null,
};

var g_push_hooks: PushHooks = .{};

pub fn setPushHooks(hooks: PushHooks) void {
    g_push_hooks = hooks;
}

/// Caller-supplied context, cx 实例化时塞 window_id + 自己的 label_buf 指针。
pub const PushCxRef = struct {
    window_id: u32,
    label_ctx: *anyopaque,
    label_resolver: LabelResolver,
};

fn pushChildrenChanged(ctx: *anyopaque, id: ElementId) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.children_changed orelse return;
    _ = hook(cx.window_id, id.raw());
}

fn pushAnnounce(ctx: *anyopaque, _: ElementId, text_hash: u64, live: tree_mod.LiveRegion) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.announce orelse return;
    const str = cx.label_resolver(cx.label_ctx, text_hash) orelse return;
    if (str.len == 0) return;
    _ = hook(cx.window_id, str.ptr, @intCast(str.len), @intFromEnum(live));
}

fn pushProperty(ctx: *anyopaque, id: ElementId, _: A11yNode, flag: tree_mod.A11yDirtyFlag) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.property_changed orelse return;
    _ = hook(cx.window_id, id.raw(), @bitCast(flag));
}

fn pushFocus(ctx: *anyopaque, id: ElementId, _: ?A11yNode) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.focus_changed orelse return;
    _ = hook(cx.window_id, if (id.isNull()) INVALID_HANDLE else id.raw());
}

fn pushActiveDescendant(ctx: *anyopaque, container: ElementId, active: ElementId) void {
    const cx: *PushCxRef = @ptrCast(@alignCast(ctx));
    const hook = g_push_hooks.active_descendant_changed orelse return;
    _ = hook(cx.window_id, container.raw(), active.raw());
}

const PUSH_VTABLE = PlatformBridge.VTable{
    .notify_property = pushProperty,
    .notify_focus = pushFocus,
    .notify_children_changed = pushChildrenChanged,
    .announce = pushAnnounce,
    .notify_active_descendant = pushActiveDescendant,
};

/// Caller-side: 拿一个绑定到 cx_ref 的 PlatformBridge 实例。
pub fn pushBridge(cx_ref: *PushCxRef) PlatformBridge {
    return .{ .ctx = cx_ref, .vtable = &PUSH_VTABLE };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// 测试用 window_id。真实值来自 NSWindow.windowNumber，测试里只要求非 0
/// （0 是 ANY_WINDOW 通配值，会退化成"第一个已注册窗口"，测不出路由）。
const WIN: u32 = 7;

const TestLabelCtx = struct {
    map: std.AutoHashMap(u64, []const u8),
    fn resolve(ctx: *anyopaque, hash: u64) ?[]const u8 {
        const self: *TestLabelCtx = @ptrCast(@alignCast(ctx));
        return self.map.get(hash);
    }
};

test "macos_bridge: root_count / root_at" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const r1: ElementId = .{ .index = 1, .generation = 0 };
    const r2: ElementId = .{ .index = 2, .generation = 0 };
    const child: ElementId = .{ .index = 3, .generation = 0 };
    try tree.upsert(.{ .element = r1, .role = .button });
    try tree.upsert(.{ .element = r2, .role = .button });
    try tree.upsert(.{ .element = child, .parent = r1, .role = .listitem });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN));
    const first = zenit_a11y_root_at(WIN, 0);
    const second = zenit_a11y_root_at(WIN, 1);
    try testing.expect(first == r1.raw() or first == r2.raw());
    try testing.expect(second == r1.raw() or second == r2.raw());
    try testing.expect(first != second);
}

test "macos_bridge: raw handle zero is valid and exposure order is semantic" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const zero: ElementId = .{ .index = 0, .generation = 0 };
    const early: ElementId = .{ .index = 3, .generation = 0 };
    const hidden: ElementId = .{ .index = 4, .generation = 0 };
    try tree.upsert(.{ .element = zero, .role = .button, .sibling_index = 20 });
    try tree.upsert(.{ .element = early, .role = .checkbox, .sibling_index = 2 });
    try tree.upsert(.{ .element = hidden, .role = .link, .sibling_index = 1, .state = .{ .hidden = true } });
    try testing.expectEqual(@as(u32, 0), zero.raw());
    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN));
    try testing.expectEqual(early.raw(), zenit_a11y_root_at(WIN, 0));
    try testing.expectEqual(zero.raw(), zenit_a11y_root_at(WIN, 1));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_root_at(WIN, 2));
    try testing.expectEqual(@as(c_int, @intFromEnum(tree_mod.Role.button)), zenit_a11y_role(WIN, 0));
}

test "macos_bridge: children_count / children_at" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const parent: ElementId = .{ .index = 1, .generation = 0 };
    const c1: ElementId = .{ .index = 2, .generation = 0 };
    const c2: ElementId = .{ .index = 3, .generation = 0 };
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = c1, .parent = parent, .role = .button, .sibling_index = 0 });
    try tree.upsert(.{ .element = c2, .parent = parent, .role = .button, .sibling_index = 1 });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, 2), zenit_a11y_children_count(WIN, parent.raw()));
    const got1 = zenit_a11y_children_at(WIN, parent.raw(), 0);
    const got2 = zenit_a11y_children_at(WIN, parent.raw(), 1);
    try testing.expect(got1 == c1.raw() or got1 == c2.raw());
    try testing.expect(got2 == c1.raw() or got2 == c2.raw());
    try testing.expect(got1 != got2);
}

test "macos_bridge: role + state" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{
        .element = id,
        .role = .checkbox,
        .state = .{ .checked = true, .focusable = true },
    });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    try testing.expectEqual(@as(c_int, @intFromEnum(tree_mod.Role.checkbox)), zenit_a11y_role(WIN, id.raw()));
    const state_bits: tree_mod.State = @bitCast(zenit_a11y_state(WIN, id.raw()));
    try testing.expect(state_bits.checked);
    try testing.expect(state_bits.focusable);
}

test "macos_bridge: frame is element-local snapshot and stale handles fail closed" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();

    const id: ElementId = .{ .index = 5, .generation = 2 };
    try tree.upsert(.{ .element = id, .role = .button, .frame = .{ .x = 12.5, .y = 31, .width = 88, .height = 24 } });
    try testing.expect(setActiveContext(WIN, &tree, &labels, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    var x: f32 = 0;
    var y: f32 = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_frame(WIN, id.raw(), &x, &y, &width, &height));
    try testing.expectEqual(@as(f32, 12.5), x);
    try testing.expectEqual(@as(f32, 31), y);
    try testing.expectEqual(@as(f32, 88), width);
    try testing.expectEqual(@as(f32, 24), height);
    const stale: ElementId = .{ .index = 5, .generation = 3 };
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_frame(WIN, stale.raw(), &x, &y, &width, &height));
}

const TestInteractionCtx = struct {
    action_count: usize = 0,
    last_action: ?Action = null,
    selection_count: usize = 0,
    selection_start: u32 = 0,
    selection_end: u32 = 0,
    focus_count: usize = 0,
    last_focused: ?bool = null,
    text_value_count: usize = 0,
    text_value_len: usize = 0,
    numeric_count: usize = 0,
    numeric_value: f32 = 0,

    fn action(ctx: *anyopaque, _: ElementId, requested: Action) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.action_count += 1;
        self.last_action = requested;
        return true;
    }

    fn selection(ctx: *anyopaque, _: ElementId, start: u32, end: u32) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.selection_count += 1;
        self.selection_start = start;
        self.selection_end = end;
        return true;
    }

    fn focus(ctx: *anyopaque, _: ElementId, focused: bool) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.focus_count += 1;
        self.last_focused = focused;
        return true;
    }

    fn textValue(ctx: *anyopaque, _: ElementId, value: []const u8) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.text_value_count += 1;
        self.text_value_len = value.len;
        return true;
    }

    fn numericValue(ctx: *anyopaque, _: ElementId, value: f32) bool {
        const self: *TestInteractionCtx = @ptrCast(@alignCast(ctx));
        self.numeric_count += 1;
        self.numeric_value = value;
        return true;
    }

    fn textFrame(_: *anyopaque, _: ElementId, start: u32, end: u32, out: *tree_mod.Frame) bool {
        out.* = .{ .x = @floatFromInt(start), .y = 8, .width = @floatFromInt(end - start), .height = 16 };
        return true;
    }

    fn rangeAtPoint(_: *anyopaque, _: ElementId, _: f32, _: f32, start: *u32, end: *u32) bool {
        start.* = 2;
        end.* = 6;
        return true;
    }
};

test "macos_bridge: actions and editable text require a live per-window route" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 31;
    const WIN_B: u32 = 32;
    const id: ElementId = .{ .index = 1, .generation = 4 };
    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    const node: A11yNode = .{
        .element = id,
        .role = .slider,
        .value_now = 42,
        .value_min = 10,
        .value_max = 90,
        .numeric_value_present = true,
        .actions = .{ .increment = true, .decrement = true },
        .editable_text = .{ .selection_start = 2, .selection_end = 5, .caret = 5, .can_set_selection = true },
    };
    try tree_a.upsert(node);
    try tree_b.upsert(node);

    var labels_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_a.map.deinit();
    var labels_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_b.map.deinit();
    var interactions_a = TestInteractionCtx{};

    try testing.expect(setActiveContextWithInteractions(
        WIN_A,
        &tree_a,
        &labels_a,
        &TestLabelCtx.resolve,
        &interactions_a,
        &TestInteractionCtx.action,
        &TestInteractionCtx.selection,
    ));
    // B intentionally has no route despite having identical handles/capability
    // snapshots; it must not call A or advertise a writable protocol.
    try testing.expect(setActiveContext(WIN_B, &tree_b, &labels_b, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(u8, 0b1100), zenit_a11y_actions(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0), zenit_a11y_actions(WIN_B, id.raw()));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_perform_action(WIN_A, id.raw(), @intFromEnum(Action.increment)));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_perform_action(WIN_B, id.raw(), @intFromEnum(Action.increment)));
    try testing.expectEqual(@as(usize, 1), interactions_a.action_count);
    try testing.expectEqual(Action.increment, interactions_a.last_action.?);
    var now: f32 = 0;
    var min: f32 = 0;
    var max: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_numeric_value(WIN_A, id.raw(), &now, &min, &max));
    try testing.expectEqual(@as(f32, 42), now);
    try testing.expectEqual(@as(f32, 10), min);
    try testing.expectEqual(@as(f32, 90), max);
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_B, id.raw()));

    var start: u32 = 0;
    var end: u32 = 0;
    var caret: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_selection(WIN_A, id.raw(), &start, &end, &caret));
    try testing.expectEqual(@as(u8, 0b11), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_text_capabilities(WIN_B, id.raw()));
    try testing.expectEqual(@as(u32, 2), start);
    try testing.expectEqual(@as(u32, 5), end);
    try testing.expectEqual(@as(u32, 5), caret);
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_text_selection(WIN_A, id.raw(), 7, 9));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_selection(WIN_B, id.raw(), 7, 9));
    try testing.expectEqual(@as(usize, 1), interactions_a.selection_count);
    try testing.expectEqual(@as(u32, 7), interactions_a.selection_start);
    try testing.expectEqual(@as(u32, 9), interactions_a.selection_end);
}

test "macos_bridge: full text numeric focus and geometry contracts stay per-window" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 41;
    const WIN_B: u32 = 42;
    const id: ElementId = .{ .index = 0, .generation = 0 };
    const node: A11yNode = .{
        .element = id,
        .role = .slider,
        .state = .{ .focused = true, .focusable = true },
        .numeric_value_present = true,
        .can_set_numeric_value = true,
        .value_now = 3,
        .value_min = 0,
        .value_max = 5,
        .editable_text = .{
            .selection_start = 1,
            .selection_end = 1,
            .caret = 1,
            .visible_start = 1,
            .visible_end = 7,
            .can_set_selection = true,
            .can_set_value = true,
        },
    };
    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    try tree_a.upsert(node);
    try tree_b.upsert(node);
    var labels_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_a.map.deinit();
    var labels_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels_b.map.deinit();
    var interactions = TestInteractionCtx{};

    try testing.expect(setActiveContextWithFullInteractions(
        WIN_A,
        &tree_a,
        &labels_a,
        &TestLabelCtx.resolve,
        &interactions,
        &TestInteractionCtx.action,
        &TestInteractionCtx.selection,
        &TestInteractionCtx.focus,
        &TestInteractionCtx.textValue,
        &TestInteractionCtx.numericValue,
        &TestInteractionCtx.textFrame,
        &TestInteractionCtx.rangeAtPoint,
    ));
    try testing.expect(setActiveContext(WIN_B, &tree_b, &labels_b, &TestLabelCtx.resolve));

    try testing.expectEqual(@as(u8, 0b1111), zenit_a11y_text_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b0001), zenit_a11y_text_capabilities(WIN_B, id.raw()));
    try testing.expectEqual(@as(u8, 0b11), zenit_a11y_numeric_capabilities(WIN_A, id.raw()));
    try testing.expectEqual(@as(u8, 0b01), zenit_a11y_numeric_capabilities(WIN_B, id.raw()));

    var visible_start: u32 = 0;
    var visible_end: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_visible_range(WIN_A, id.raw(), &visible_start, &visible_end));
    try testing.expectEqual(@as(u32, 1), visible_start);
    try testing.expectEqual(@as(u32, 7), visible_end);
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_text_value(WIN_A, id.raw(), "hello".ptr, 5));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_text_value(WIN_B, id.raw(), "wrong".ptr, 5));
    try testing.expectEqual(@as(usize, 1), interactions.text_value_count);
    try testing.expectEqual(@as(usize, 5), interactions.text_value_len);

    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_numeric_value(WIN_A, id.raw(), 99));
    try testing.expectEqual(@as(f32, 5), interactions.numeric_value);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_numeric_value(WIN_B, id.raw(), 4));

    var x: f32 = 0;
    var y: f32 = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_frame(WIN_A, id.raw(), 2, 6, &x, &y, &width, &height));
    try testing.expectEqual(@as(f32, 2), x);
    try testing.expectEqual(@as(f32, 4), width);
    var point_start: u32 = 0;
    var point_end: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_text_range_at_point(WIN_A, id.raw(), 10, 12, &point_start, &point_end));
    try testing.expectEqual(@as(u32, 2), point_start);
    try testing.expectEqual(@as(u32, 6), point_end);

    try testing.expectEqual(id.raw(), zenit_a11y_focused(WIN_A));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_set_focus(WIN_A, id.raw(), 0));
    try testing.expectEqual(false, interactions.last_focused.?);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_set_focus(WIN_B, id.raw(), 0));
}

test "macos_bridge: parent active descendant and deepest hit test are exact" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    const root: ElementId = .{ .index = 0, .generation = 0 };
    const child: ElementId = .{ .index = 1, .generation = 0 };
    const active: ElementId = .{ .index = 2, .generation = 0 };
    try tree.upsert(.{
        .element = root,
        .role = .listbox,
        .active_descendant = active,
        .frame = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
    });
    try tree.upsert(.{
        .element = child,
        .parent = root,
        .role = .group,
        .frame = .{ .x = 10, .y = 10, .width = 80, .height = 80 },
    });
    try tree.upsert(.{
        .element = active,
        .parent = child,
        .role = .listitem,
        .state = .{ .selected = true },
        .frame = .{ .x = 20, .y = 20, .width = 20, .height = 20 },
    });
    try testing.expect(setActiveContext(WIN, &tree, &labels, &TestLabelCtx.resolve));

    try testing.expectEqual(root.raw(), zenit_a11y_parent(WIN, child.raw()));
    try testing.expectEqual(child.raw(), zenit_a11y_parent(WIN, active.raw()));
    try testing.expectEqual(active.raw(), zenit_a11y_active_descendant(WIN, root.raw()));
    try testing.expectEqual(active.raw(), zenit_a11y_hit_test(WIN, 25, 25));
    try testing.expectEqual(child.raw(), zenit_a11y_hit_test(WIN, 50, 50));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_hit_test(WIN, 150, 150));
}

test "macos_bridge: label resolve + probe length" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    const label = "Click Me";
    const label_hash: u64 = std.hash.Wyhash.hash(0, label);
    try ctx.map.put(label_hash, label);

    try tree.upsert(.{ .element = id, .role = .button, .label_hash = label_hash });

    try testing.expect(setActiveContext(WIN, &tree, &ctx, &TestLabelCtx.resolve));
    defer clearActiveContext(WIN);

    // probe: buf=null 返实际长度
    try testing.expectEqual(@as(c_int, @intCast(label.len)), zenit_a11y_label(WIN, id.raw(), null, 0));

    // copy: 写入 buf
    var buf: [32]u8 = undefined;
    const n = zenit_a11y_label(WIN, id.raw(), &buf, buf.len);
    try testing.expectEqual(@as(c_int, @intCast(label.len)), n);
    try testing.expectEqualStrings(label, buf[0..@intCast(n)]);
}

test "macos_bridge: no active context returns zero" {
    clearAllActiveContexts();
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(WIN));
    try testing.expectEqual(INVALID_HANDLE, zenit_a11y_root_at(WIN, 0));
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_children_count(WIN, 0));
}

// 多窗口路由的核心验收：两个窗口各注册各的树，按 window_id 查各自的内容，
// 且注销其中一个不影响另一个。改这个文件前先让这三个断言过。
test "macos_bridge: two windows route independently" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const WIN_A: u32 = 11;
    const WIN_B: u32 = 22;

    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();

    var ctx_a = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx_a.map.deinit();
    var ctx_b = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx_b.map.deinit();

    // A: 1 个 root，label "Alpha"。B: 2 个 root，第一个 label "Bravo"。
    const a_root: ElementId = .{ .index = 1, .generation = 0 };
    const label_a = "Alpha";
    const hash_a = std.hash.Wyhash.hash(0, label_a);
    try ctx_a.map.put(hash_a, label_a);
    try tree_a.upsert(.{ .element = a_root, .role = .button, .label_hash = hash_a });

    const b_root1: ElementId = .{ .index = 1, .generation = 0 };
    const b_root2: ElementId = .{ .index = 2, .generation = 0 };
    const label_b = "Bravo";
    const hash_b = std.hash.Wyhash.hash(0, label_b);
    try ctx_b.map.put(hash_b, label_b);
    try tree_b.upsert(.{ .element = b_root1, .role = .checkbox, .label_hash = hash_b });
    try tree_b.upsert(.{ .element = b_root2, .role = .textbox });

    try testing.expect(setActiveContext(WIN_A, &tree_a, &ctx_a, &TestLabelCtx.resolve));
    try testing.expect(setActiveContext(WIN_B, &tree_b, &ctx_b, &TestLabelCtx.resolve));
    try testing.expectEqual(@as(usize, 2), activeContextCount());

    // 各查各的 root 数，旧的单槽实现下 B 会覆盖 A，这里 A 会变成 2。
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(WIN_A));
    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN_B));

    // 同一个 handle raw 值在两个窗口里指向不同节点，role 必须各自解析。
    try testing.expectEqual(
        @as(c_int, @intFromEnum(tree_mod.Role.button)),
        zenit_a11y_role(WIN_A, a_root.raw()),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(tree_mod.Role.checkbox)),
        zenit_a11y_role(WIN_B, b_root1.raw()),
    );

    // label 走各自的 label_ctx（不同的 hash 表）。
    var buf: [32]u8 = undefined;
    const na = zenit_a11y_label(WIN_A, a_root.raw(), &buf, buf.len);
    try testing.expectEqualStrings(label_a, buf[0..@intCast(na)]);
    const nb = zenit_a11y_label(WIN_B, b_root1.raw(), &buf, buf.len);
    try testing.expectEqualStrings(label_b, buf[0..@intCast(nb)]);
    // A 的 hash 在 B 的表里查不到，证明 label_ctx 没串。
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_label(WIN_B, b_root2.raw(), &buf, buf.len));

    // 注销 A 不影响 B。
    clearActiveContext(WIN_A);
    try testing.expectEqual(@as(usize, 1), activeContextCount());
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(WIN_A));
    try testing.expectEqual(@as(c_int, 2), zenit_a11y_root_count(WIN_B));
}

test "macos_bridge: ANY_WINDOW falls back to first registered window" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();
    try tree.upsert(.{ .element = .{ .index = 1, .generation = 0 }, .role = .button });

    try testing.expect(setActiveContext(99, &tree, &ctx, &TestLabelCtx.resolve));
    // 未接线的 ObjC 代理传 0 时仍能拿到树（旧 single-window 行为兼容）。
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(ANY_WINDOW));
    // 但错的具体 window_id 查不到，通配不等于"任何 id 都命中"。
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(98));
}

test "macos_bridge: table full degrades instead of erroring" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var ctx = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer ctx.map.deinit();

    for (0..MAX_WINDOWS) |i| {
        try testing.expect(setActiveContext(@intCast(i + 1), &tree, &ctx, &TestLabelCtx.resolve));
    }
    // 第 MAX_WINDOWS+1 个窗口注册失败但不 panic / 不报错。
    try testing.expect(!setActiveContext(9999, &tree, &ctx, &TestLabelCtx.resolve));
    // 已注册的照常工作。
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(9999));
}

const PushTestState = struct {
    property_count: usize = 0,
    property_window: u32 = 0,
    property_handle: u32 = INVALID_HANDLE,
    property_flags: u16 = 0,
    focus_count: usize = 0,
    focus_handle: u32 = INVALID_HANDLE,
    announce_count: usize = 0,
    announce_priority: u8 = 0,
    clear_count: usize = 0,
    cleared_window: u32 = 0,
};

var g_push_test = PushTestState{};

fn testPushProperty(window_id: u32, handle: u32, flags: u16) callconv(.c) c_int {
    g_push_test.property_count += 1;
    g_push_test.property_window = window_id;
    g_push_test.property_handle = handle;
    g_push_test.property_flags = flags;
    return 1;
}

fn testPushFocus(_: u32, handle: u32) callconv(.c) c_int {
    g_push_test.focus_count += 1;
    g_push_test.focus_handle = handle;
    return 1;
}

fn testPushAnnounce(_: u32, _: [*]const u8, _: c_int, priority: u8) callconv(.c) c_int {
    g_push_test.announce_count += 1;
    g_push_test.announce_priority = priority;
    return 1;
}

fn testPushWindowCleared(window_id: u32) callconv(.c) c_int {
    g_push_test.clear_count += 1;
    g_push_test.cleared_window = window_id;
    return 1;
}

test "macos_bridge: retained push preserves exact target flags priority and focus clear" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    g_push_test = .{};
    setPushHooks(.{
        .property_changed = testPushProperty,
        .focus_changed = testPushFocus,
        .announce = testPushAnnounce,
    });
    defer setPushHooks(.{});

    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    const text = "Danger";
    const hash = std.hash.Wyhash.hash(0, text);
    try labels.map.put(hash, text);
    const id: ElementId = .{ .index = 0, .generation = 0 };
    var ref = PushCxRef{ .window_id = 77, .label_ctx = &labels, .label_resolver = &TestLabelCtx.resolve };
    try tree.upsert(.{
        .element = id,
        .role = .alert,
        .live = .assertive,
        .text_hash = hash,
        .state = .{ .focused = true, .focusable = true },
    });
    router_mod.flushToBridge(&tree, pushBridge(&ref));
    try testing.expectEqual(@as(usize, 1), g_push_test.announce_count);
    try testing.expectEqual(@as(u8, @intFromEnum(tree_mod.LiveRegion.assertive)), g_push_test.announce_priority);
    try testing.expectEqual(@as(usize, 1), g_push_test.focus_count);
    try testing.expectEqual(id.raw(), g_push_test.focus_handle);

    try tree.upsert(.{
        .element = id,
        .role = .status,
        .live = .assertive,
        .text_hash = hash,
        .frame = .{ .x = 5, .y = 6, .width = 7, .height = 8 },
    });
    router_mod.flushToBridge(&tree, pushBridge(&ref));
    try testing.expectEqual(@as(usize, 1), g_push_test.property_count);
    try testing.expectEqual(@as(u32, 77), g_push_test.property_window);
    try testing.expectEqual(id.raw(), g_push_test.property_handle);
    const flags: tree_mod.A11yDirtyFlag = @bitCast(g_push_test.property_flags);
    try testing.expect(flags.role_changed);
    try testing.expect(flags.geometry_changed);
    try testing.expectEqual(@as(usize, 2), g_push_test.focus_count);
    try testing.expectEqual(INVALID_HANDLE, g_push_test.focus_handle);
}

test "macos_bridge: clearing one window emits one teardown and preserves peers" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    g_push_test = .{};
    setPushHooks(.{ .window_cleared = testPushWindowCleared });
    defer setPushHooks(.{});

    var tree_a = AccessibilityTree.init(testing.allocator);
    defer tree_a.deinit();
    var tree_b = AccessibilityTree.init(testing.allocator);
    defer tree_b.deinit();
    var labels = TestLabelCtx{ .map = std.AutoHashMap(u64, []const u8).init(testing.allocator) };
    defer labels.map.deinit();
    try tree_a.upsert(.{ .element = .{ .index = 0, .generation = 0 }, .role = .button });
    try tree_b.upsert(.{ .element = .{ .index = 0, .generation = 0 }, .role = .checkbox });
    try testing.expect(setActiveContext(81, &tree_a, &labels, &TestLabelCtx.resolve));
    try testing.expect(setActiveContext(82, &tree_b, &labels, &TestLabelCtx.resolve));

    clearActiveContext(81);
    try testing.expectEqual(@as(usize, 1), g_push_test.clear_count);
    try testing.expectEqual(@as(u32, 81), g_push_test.cleared_window);
    try testing.expectEqual(@as(c_int, 0), zenit_a11y_root_count(81));
    try testing.expectEqual(@as(c_int, 1), zenit_a11y_root_count(82));
    clearActiveContext(81);
    try testing.expectEqual(@as(usize, 1), g_push_test.clear_count);
}

const LiveTextTestState = struct {
    text: []const u8,
    marked: ?struct { start: u32, end: u32 } = null,
    secure: bool = false,
    selection: core_types.TextInputSelection = .{ .start = 0, .end = 0, .caret = 0 },

    fn length(context: *anyopaque) usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.text.len;
    }

    fn copy(context: *anyopaque, start: usize, out: []u8) usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (start >= self.text.len) return 0;
        const count = @min(out.len, self.text.len - start);
        @memcpy(out[0..count], self.text[start..][0..count]);
        return count;
    }

    fn readSelection(context: *anyopaque) core_types.TextInputSelection {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.selection;
    }

    fn readMarked(context: *anyopaque, start: *u32, end: *u32) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        const range = self.marked orelse return false;
        start.* = range.start;
        end.* = range.end;
        return true;
    }

    fn resolve(context: *anyopaque) ?core_types.TextInputClient {
        return .{
            .context = context,
            .text_len = length,
            .copy_text = copy,
            .selection = readSelection,
            .marked_range = readMarked,
            .secure = (@as(*@This(), @ptrCast(@alignCast(context)))).secure,
        };
    }
};

test "macos_bridge: live text client maps CJK and non-BMP UTF-8 UTF-16 ranges" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    const TEXT_WINDOW: u32 = 901;
    var state = LiveTextTestState{
        .text = "A中🙂한",
        .selection = .{ .start = 1, .end = 8, .caret = 8 },
    };
    try testing.expect(setTextInputResolver(TEXT_WINDOW, &state, LiveTextTestState.resolve));

    try testing.expectEqual(@as(u64, 11), zenit_text_input_length(TEXT_WINDOW));
    try testing.expectEqual(@as(u64, 0), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 0));
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 1));
    // A request inside 中 clamps to the scalar start rather than failing.
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 2));
    try testing.expectEqual(@as(u64, 2), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 4));
    try testing.expectEqual(@as(u64, 2), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 5));
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 8));
    try testing.expectEqual(@as(u64, 5), zenit_text_input_utf16_for_utf8(TEXT_WINDOW, 11));

    try testing.expectEqual(@as(u64, 0), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 0));
    try testing.expectEqual(@as(u64, 1), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 1));
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 2));
    // A UTF-16 offset between 🙂's surrogate pair clamps to its UTF-8 start.
    try testing.expectEqual(@as(u64, 4), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 3));
    try testing.expectEqual(@as(u64, 8), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 4));
    try testing.expectEqual(@as(u64, 11), zenit_text_input_utf8_for_utf16(TEXT_WINDOW, 5));

    var start: u32 = 0;
    var end: u32 = 0;
    var caret: u32 = 0;
    try testing.expectEqual(@as(c_int, 1), zenit_text_input_selection(TEXT_WINDOW, &start, &end, &caret));
    try testing.expectEqual(@as(u32, 1), start);
    try testing.expectEqual(@as(u32, 8), end);
    try testing.expectEqual(@as(u32, 8), caret);

    var copied: [7]u8 = undefined;
    try testing.expectEqual(@as(c_int, 7), zenit_text_input_copy(TEXT_WINDOW, 4, &copied, copied.len));
    try testing.expectEqualStrings("🙂한", &copied);
}

test "macos_bridge: UTF conversion preserves scalars across bridge chunk boundaries" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();

    var text: [4102]u8 = undefined;
    @memset(text[0..4095], 'a');
    @memcpy(text[4095..4098], "中");
    @memcpy(text[4098..4102], "🙂");
    var state = LiveTextTestState{ .text = &text };
    try testing.expect(setTextInputResolver(902, &state, LiveTextTestState.resolve));

    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf16_for_utf8(902, text.len));
    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf8_for_utf16(902, 4096));
    try testing.expectEqual(@as(u64, 4098), zenit_text_input_utf8_for_utf16(902, 4097));
    try testing.expectEqual(@as(u64, 4102), zenit_text_input_utf8_for_utf16(902, 4098));
}

test "macos_bridge: applied preedit publishes only a live nonsecure model range" {
    clearAllActiveContexts();
    defer clearAllActiveContexts();
    const Capture = struct {
        var calls: usize = 0;
        var received: [5]u64 = undefined;
        fn apply(window: u32, start16: u64, end16: u64, start8: u32, end8: u32) callconv(.c) c_int {
            calls += 1;
            received = .{ window, start16, end16, start8, end8 };
            return 1;
        }
    };
    Capture.calls = 0;
    setTextInputAppliedHook(Capture.apply);
    defer setTextInputAppliedHook(null);
    var state = LiveTextTestState{ .text = "A😀你好Z", .marked = .{ .start = 5, .end = 11 } };
    try testing.expect(setTextInputResolver(903, &state, LiveTextTestState.resolve));
    publishAppliedPreedit(903);
    try testing.expectEqual(@as(usize, 1), Capture.calls);
    try testing.expectEqual([5]u64{ 903, 3, 5, 5, 11 }, Capture.received);
    var boundary: [4102]u8 = undefined;
    @memset(boundary[0..4095], 'a');
    @memcpy(boundary[4095..4099], "🙂");
    @memcpy(boundary[4099..4102], "你");
    state.text = &boundary;
    state.marked = .{ .start = 4099, .end = 4102 };
    publishAppliedPreedit(903);
    try testing.expectEqual([5]u64{ 903, 4097, 4098, 4099, 4102 }, Capture.received);
    state.text = "A😀你好Z";
    state.secure = true;
    publishAppliedPreedit(903);
    state.secure = false;
    state.marked = .{ .start = 5, .end = 99 };
    publishAppliedPreedit(903);
    state.marked = .{ .start = 6, .end = 5 };
    publishAppliedPreedit(903);
    state.marked = null;
    publishAppliedPreedit(903);
    clearTextInputResolverForOwner(903, &state);
    publishAppliedPreedit(903);
    try testing.expectEqual(@as(usize, 2), Capture.calls);
}
