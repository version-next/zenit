//! 光标闪烁相位 —— 从 `TextInputState` 析出。
//!
//! 原本是 `TextInputState` 上的两个字段（`blink_epoch` / `last_blink_visible`）
//! 加三个方法。它们不碰输入状态的任何其它部分（buffer / cursor / selection /
//! IME 全都无关），是一段纯时间算术，却夹在 3200 行的输入状态机里。
//!
//! 搬出来之后，相位计算可以用**构造出来的时间戳**直接单测 —— 此前要验证
//! 「闪烁半周期是否正确」「Tab 切焦点同帧 reset 会不会算出负数」只能跑真实
//! 应用用眼睛看。
//!
//! **接口切在哪**：本模块只回答「现在该不该显示光标」和「下次相位翻转还有
//! 多久」。`last_blink_visible`（上一帧可见性，用于只在翻转时标脏）留给
//! 调用方 —— 它属于渲染脏标记的账，不属于相位本身。

const std = @import("std");
const text_utils = @import("text_utils.zig");

/// 闪烁半周期：亮 500ms、灭 500ms。
pub const half_period_ns: u64 = 500 * std.time.ns_per_ms;

pub const CaretBlink = struct {
    /// 相位起点。null = 还没起过相位（首次查询时自动补一个 now）。
    epoch: ?std.time.Instant = null,

    /// 把相位拨回「刚亮起」。任何让光标应当立刻可见的动作都要调它
    /// （打字、移动光标、获得焦点…），否则用户会看到光标在自己打字时消失。
    ///
    /// `Instant.now()` 失败时存 null：下次查询会重新尝试，比记一个错误的
    /// 时间点好。
    pub fn reset(self: *CaretBlink) void {
        self.epoch = std.time.Instant.now() catch null;
    }

    /// 当前相位是否应当显示光标。
    ///
    /// 未起相位时就地补一个（所以是 `*CaretBlink` 而非 const）。
    pub fn visible(self: *CaretBlink, now: std.time.Instant) bool {
        if (self.epoch == null) self.reset();
        const epoch = self.epoch orelse return true;
        // ⚠ 安全减法：epoch 可能比 now 更晚 —— Tab 切换焦点时同一帧内先
        // reset 再查询，两个 Instant 的取样点可能倒挂。裸减会下溢成天文数字，
        // 光标随机闪。
        const elapsed = text_utils.safeElapsedNs(now, epoch);
        return ((elapsed / half_period_ns) % 2) == 0;
    }

    /// 距离下一次相位翻转还有多少纳秒。调用方用它决定下次唤醒时间，
    /// 避免为了闪光标而每帧空转。
    pub fn nextDelayNs(self: *const CaretBlink, now: std.time.Instant) u64 {
        const epoch = self.epoch orelse return half_period_ns;
        const elapsed = text_utils.safeElapsedNs(now, epoch);
        const phase_index = elapsed / half_period_ns;
        return ((phase_index + 1) * half_period_ns) - elapsed;
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 此前这三个函数只能通过跑真实应用、用眼睛看光标来"验证"。析出后可以直接
// 构造时间戳断言相位。

/// 构造一个比 base 晚 delta_ns 的 Instant。
fn advance(base: std.time.Instant, delta_ns: u64) std.time.Instant {
    var t = base;
    if (@hasField(std.time.Instant, "timestamp")) {
        // 平台表示不同（Darwin 是单个 u64，Linux 是 timespec），统一用
        // std 自己的加法语义走不通，这里按字段类型分支。
        const T = @TypeOf(t.timestamp);
        if (@typeInfo(T) == .int) {
            t.timestamp += @intCast(delta_ns);
            return t;
        }
        t.timestamp.sec += @intCast(delta_ns / std.time.ns_per_s);
        t.timestamp.nsec += @intCast(delta_ns % std.time.ns_per_s);
        if (t.timestamp.nsec >= std.time.ns_per_s) {
            t.timestamp.sec += 1;
            t.timestamp.nsec -= std.time.ns_per_s;
        }
    }
    return t;
}

test "未起相位时 visible 返回 true 并就地起相位" {
    var b = CaretBlink{};
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const now = std.time.Instant.now() catch return error.SkipZigTest;
    try std.testing.expect(b.visible(now));
    try std.testing.expect(b.epoch != null);
}

test "相位在半周期处翻转，一个整周期后回到可见" {
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const base = std.time.Instant.now() catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };

    try std.testing.expect(b.visible(base)); // t=0 亮
    try std.testing.expect(b.visible(advance(base, half_period_ns - 1)));
    try std.testing.expect(!b.visible(advance(base, half_period_ns))); // 翻转
    try std.testing.expect(!b.visible(advance(base, half_period_ns * 2 - 1)));
    try std.testing.expect(b.visible(advance(base, half_period_ns * 2))); // 回到亮
}

test "reset 把相位拨回刚亮起" {
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const base = std.time.Instant.now() catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };
    // 走到灭相位
    try std.testing.expect(!b.visible(advance(base, half_period_ns)));
    b.reset();
    // reset 之后用它自己的新 epoch 查询，必须是亮的
    const after = b.epoch.?;
    try std.testing.expect(b.visible(after));
}

test "nextDelayNs 给出到下次翻转的剩余时间" {
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const base = std.time.Instant.now() catch return error.SkipZigTest;
    var b = CaretBlink{ .epoch = base };

    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(base));
    try std.testing.expectEqual(@as(u64, 1), b.nextDelayNs(advance(base, half_period_ns - 1)));
    // 刚过翻转点 ⇒ 到下一次翻转还有整个半周期
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(advance(base, half_period_ns)));
}

test "未起相位时 nextDelayNs 回退到半周期" {
    const b = CaretBlink{};
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const now = std.time.Instant.now() catch return error.SkipZigTest;
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(now));
}

test "epoch 比 now 更晚时不下溢（Tab 切焦点同帧 reset 的形状）" {
    // SKIP-REASON: 平台不提供单调时钟时 Instant.now() 会失败，这组相位测试无从构造时间戳
    const base = std.time.Instant.now() catch return error.SkipZigTest;
    // epoch 在“未来”：safeElapsedNs 必须钳到 0，而不是下溢成天文数字
    var b = CaretBlink{ .epoch = advance(base, half_period_ns) };
    try std.testing.expect(b.visible(base)); // elapsed=0 ⇒ 亮
    try std.testing.expectEqual(half_period_ns, b.nextDelayNs(base));
}
