//! 原生文本输入会话的对账状态机 —— 从 `Cx` 析出。
//!
//! 管一件事：**框架认为的「当前该不该开原生输入法」与平台的实际状态之间的
//! 对账**。这是个三态机，关键在 `native_enabled: ?bool`：
//!
//!   null  —— 平台状态**未知**（SDK 刚 attach / 换窗口 / 刚 init），
//!            下一次对账必须无条件下发一次，不能因为「看起来没变」而跳过
//!   true  —— 已确认开
//!   false —— 已确认关
//!
//! 把「未知」和「关」分开是这个机器存在的理由：若用裸 bool，SDK attach 之后
//! 第一次对账会因为 `false == false` 而不下发，于是焦点已在输入框上、原生
//! 输入法却没开 —— 中日韩用户打不出字，且没有任何报错。
//!
//! **这里不解析焦点**。焦点解析要碰 focus_manager / node_registry，是 `Cx`
//! 的职责；本模块只接收「解析结果」（node handle + client context）并对账。
//! 这样状态机可以脱离整棵节点树做表驱动单测。

const std = @import("std");
const NodeHandle = @import("hit_runtime.zig").NodeHandle;

/// 平台侧动作。由 `Cx` 实现（它持有 system_sdk / window_id）。
pub const Host = struct {
    ctx: *anyopaque,
    /// 开/关原生输入法。返回是否**成功下发** —— 失败时状态机保持「未知」，
    /// 下一帧会重试，而不是记成已生效。
    setEnabled: *const fn (ctx: *anyopaque, enabled: bool) bool,
    /// 丢弃进行中的 preedit（换焦点前必须做，否则半截组合串会漏进新目标）。
    discardIme: *const fn (ctx: *anyopaque) void,
};

/// 一次焦点解析的结果。两个字段都为 null 表示「当前没有文本输入目标」。
pub const Target = struct {
    node: ?NodeHandle = null,
    context: ?*anyopaque = null,
};

pub const TextInputSession = struct {
    active_node: ?NodeHandle = null,
    active_context: ?*anyopaque = null,
    /// 见模块头：null = 平台状态未知，必须无条件对账一次。
    native_enabled: ?bool = null,

    /// 把会话对账到 `target`。
    ///
    /// 顺序是合同的一部分：**先 discardIme 再切目标**。反过来会把上一个
    /// 输入框没提交完的组合串丢进新目标。
    pub fn reconcile(self: *TextInputSession, target: Target, host: Host) void {
        const changed = !std.meta.eql(self.active_node, target.node) or
            self.active_context != target.context;
        if (changed and self.active_node != null) host.discardIme(host.ctx);
        self.active_node = target.node;
        self.active_context = target.context;

        const desired = target.node != null;
        // native_enabled == null（未知）时无条件下发，这正是三态的意义。
        if (self.native_enabled == null or self.native_enabled.? != desired) {
            if (host.setEnabled(host.ctx, desired)) self.native_enabled = desired;
        }
    }

    /// 彻底停用（窗口销毁 / SDK 摘除前）。与 reconcile 不同，这里把
    /// native_enabled 钉成 false 而不是 null —— 我们刚亲手关过它。
    pub fn deactivate(self: *TextInputSession, host: Host) void {
        if (self.active_node != null) host.discardIme(host.ctx);
        _ = host.setEnabled(host.ctx, false);
        self.* = .{ .active_node = null, .active_context = null, .native_enabled = false };
    }

    /// 平台状态变得不可信时调用（换 SDK / 换窗口）：下次对账无条件重新下发。
    pub fn invalidatePlatformState(self: *TextInputSession) void {
        self.native_enabled = null;
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────

const Recorder = struct {
    enable_calls: std.ArrayList(bool) = .{},
    discard_count: u32 = 0,
    fail_enable: bool = false,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Recorder {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *Recorder) void {
        self.enable_calls.deinit(self.alloc);
    }
    fn setEnabled(ctx: *anyopaque, enabled: bool) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.enable_calls.append(self.alloc, enabled) catch {};
        return !self.fail_enable;
    }
    fn discardIme(ctx: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.discard_count += 1;
    }
    fn host(self: *Recorder) Host {
        return .{ .ctx = @ptrCast(self), .setEnabled = setEnabled, .discardIme = discardIme };
    }
};

fn handle(id: u32) NodeHandle {
    return .{ .id = id, .generation = 1 };
}

test "未知状态下即使 desired 与默认值相同也必须下发一次" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    // native_enabled = null（未知），target 为空 ⇒ desired = false。
    // 裸 bool 实现会因为 false==false 跳过；三态必须下发。
    var s = TextInputSession{};
    s.reconcile(.{}, rec.host());
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
    try std.testing.expectEqual(false, rec.enable_calls.items[0]);
    try std.testing.expectEqual(@as(?bool, false), s.native_enabled);
}

test "状态已知且未变时不重复下发" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host()); // 开
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
    s.reconcile(.{ .node = handle(1) }, rec.host()); // 同目标，应静默
    try std.testing.expectEqual(@as(usize, 1), rec.enable_calls.items.len);
}

test "换目标时先 discard 再切，且顺序不可颠倒" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    try std.testing.expectEqual(@as(u32, 0), rec.discard_count);

    s.reconcile(.{ .node = handle(2) }, rec.host());
    // 切到新目标前必须丢掉上一个的半截组合串
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
    try std.testing.expectEqual(@as(?NodeHandle, handle(2)), s.active_node);
}

test "context 变化（同节点换 client）也算换目标" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var a: u8 = 0;
    var b: u8 = 0;
    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1), .context = @ptrCast(&a) }, rec.host());
    s.reconcile(.{ .node = handle(1), .context = @ptrCast(&b) }, rec.host());
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
}

test "下发失败时保持未知，下次重试" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();
    rec.fail_enable = true;

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    // 失败 ⇒ 不能记成已生效
    try std.testing.expectEqual(@as(?bool, null), s.native_enabled);

    rec.fail_enable = false;
    s.reconcile(.{ .node = handle(1) }, rec.host());
    try std.testing.expectEqual(@as(?bool, true), s.native_enabled);
    try std.testing.expectEqual(@as(usize, 2), rec.enable_calls.items.len);
}

test "deactivate 把状态钉成 false 而不是 null" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    s.deactivate(rec.host());
    try std.testing.expectEqual(@as(?bool, false), s.native_enabled);
    try std.testing.expectEqual(@as(?NodeHandle, null), s.active_node);
    try std.testing.expectEqual(@as(u32, 1), rec.discard_count);
}

test "invalidatePlatformState 之后必须重新下发" {
    const alloc = std.testing.allocator;
    var rec = Recorder.init(alloc);
    defer rec.deinit();

    var s = TextInputSession{};
    s.reconcile(.{ .node = handle(1) }, rec.host());
    const before = rec.enable_calls.items.len;

    s.invalidatePlatformState(); // 换 SDK / 换窗口
    s.reconcile(.{ .node = handle(1) }, rec.host());
    // 目标没变，但平台状态不可信，必须再下发一次
    try std.testing.expectEqual(before + 1, rec.enable_calls.items.len);
}
