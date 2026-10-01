/// Range Hover Registry
///
/// 框架级交互原语：对一个 host Node 注册多个 **content-space 子矩形区域**，
/// 每区域带 enter/leave 回调 + hover 延迟。典型消费者：
///   - 文本中的下划线/标注 -> hover 出 detail popup
///   - 带注解的 canvas / 图表的数据点
///   - inline hint 额外信息
///
/// 为什么不用 Node 级 hit runtime：
///   - 目标 region 不是 DOM 节点（例如文本里的 byte range 标注，不是子节点）
///   - 按帧要求 host 把 byte range -> 屏幕 rect 的映射交给 registry，lazy 查询时求值
///   - host 滚动/reflow 时不需要重新 register，只要 rects_fn 返回最新坐标
///
/// 用法：
/// ```zig
/// const registry = try RangeHoverRegistry.attach(cx, host_node);
/// const id = try registry.register(.{
///     .rects_fn = myEditor.diagnosticRectsFn,
///     .ctx = @ptrCast(&my_diag_ctx),
///     .on_enter = onDiagEnter,
///     .on_leave = onDiagLeave,
/// });
/// // 取消时：registry.unregister(id); 或 registry.clear();
/// // 鼠标事件在 host 上投递，registry 的 tickMouseMove(x, y) 查所有 region 并 fire 回调。
/// ```
///
/// 注意：
///   - 坐标系是 host Node 的 content-local（caller 负责把 global -> local 转换）
///   - rects_fn 每次 tick 被调用，caller 不需要缓存
///   - scope cleanup 时 registry 自动释放
const std = @import("std");

/// 最小 forward decl, range_hover 实际只存 `*Node` 做标记用，不调用 Node 的方法。
/// 让单元测试可脱离整个 UI 栈跑（测 `attach` 以外的所有路径）。
const Node = opaque {};
const UIContext = opaque {};

pub const RangeId = u32;

/// Content-local rect（相对 host Node 左上）
pub const RangeRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: RangeRect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

/// 一个区域的注册条目
pub const RangeHoverRegion = struct {
    /// Supplier: 把 (byte_range 或其它) -> 0..N 个 content-local rects 写进 buf。
    /// 返回实际写入数量（<= buf.len）。
    rects_fn: *const fn (ctx: *anyopaque, buf: []RangeRect) usize,
    ctx: *anyopaque,
    /// 鼠标 hover delay 过后 fire。mx/my 是 content-local 坐标。
    on_enter: *const fn (ctx: *anyopaque, mx: f32, my: f32) void,
    /// 鼠标离开 region fire（无 delay）。
    on_leave: *const fn (ctx: *anyopaque) void,
    /// 鼠标停留多少毫秒后 fire on_enter（典型 300-500 ms）
    hover_delay_ms: u32 = 300,
};

/// Registry 本体：一个 host Node 上可挂一个
pub const RangeHoverRegistry = struct {
    allocator: std.mem.Allocator,
    host: *Node,
    /// 注册的区域列表；ID 单调递增，unregister 用 tombstone 方式（entry 置 null）
    entries: std.ArrayListUnmanaged(?Entry) = .{},
    next_id: RangeId = 1,

    /// 当前被 hover 的区域 ID（未达 delay 时也记录）
    active_id: ?RangeId = null,
    /// active_id 首次进入该 region 的时间戳（ms）
    active_enter_ms: i64 = 0,
    /// active_id 的 on_enter 是否已 fire
    entered: bool = false,
    /// 最近一次 mouse 坐标（tickMouseMove 记录）
    last_mx: f32 = 0,
    last_my: f32 = 0,

    const Entry = struct {
        id: RangeId,
        region: RangeHoverRegion,
    };

    /// 为 host node 挂一个 registry。caller 持有 *RangeHoverRegistry，scope 负责清理。
    /// 多次 attach 同一个 node 是 caller 的责任（registry 没做 dedup）。
    ///
    /// 参数 allocator 必须长于 registry 自身；caller 负责在 scope cleanup 里 destroy()。
    /// 不让构造函数直接吃 UIContext，这样 registry 可以脱离整个 UI 栈单元测试。
    pub fn attach(allocator: std.mem.Allocator, host: *Node) !*RangeHoverRegistry {
        const self = try allocator.create(RangeHoverRegistry);
        self.* = .{
            .allocator = allocator,
            .host = host,
        };
        return self;
    }

    pub fn deinit(self: *RangeHoverRegistry) void {
        self.entries.deinit(self.allocator);
    }

    /// 销毁并从 allocator 释放；等同 deinit + destroy。
    pub fn destroy(self: *RangeHoverRegistry) void {
        const a = self.allocator;
        self.deinit();
        a.destroy(self);
    }

    pub fn register(self: *RangeHoverRegistry, region: RangeHoverRegion) !RangeId {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{ .id = id, .region = region });
        return id;
    }

    pub fn unregister(self: *RangeHoverRegistry, id: RangeId) void {
        for (self.entries.items, 0..) |entry_opt, i| {
            if (entry_opt) |e| {
                if (e.id == id) {
                    self.entries.items[i] = null;
                    if (self.active_id == id) {
                        if (self.entered) {
                            e.region.on_leave(e.region.ctx);
                        }
                        self.active_id = null;
                        self.entered = false;
                    }
                    return;
                }
            }
        }
    }

    pub fn clear(self: *RangeHoverRegistry) void {
        if (self.active_id) |aid| {
            if (self.entered) {
                for (self.entries.items) |entry_opt| {
                    if (entry_opt) |e| if (e.id == aid) e.region.on_leave(e.region.ctx);
                }
            }
        }
        self.entries.clearRetainingCapacity();
        self.active_id = null;
        self.entered = false;
    }

    /// 每帧 / 鼠标移动时投递（mx/my = host-local 坐标；now_ms = 当前单调时间）。
    /// registry 自己跑 state machine：hover delay -> on_enter -> on_leave。
    pub fn tickMouseMove(self: *RangeHoverRegistry, mx: f32, my: f32, now_ms: i64) void {
        self.last_mx = mx;
        self.last_my = my;
        var buf: [8]RangeRect = undefined;

        // 查当前坐标落到哪个 region
        var hit: ?RangeId = null;
        var hit_region: ?RangeHoverRegion = null;
        for (self.entries.items) |entry_opt| {
            const e = entry_opt orelse continue;
            const count = e.region.rects_fn(e.region.ctx, &buf);
            for (buf[0..@min(count, buf.len)]) |r| {
                if (r.contains(mx, my)) {
                    hit = e.id;
                    hit_region = e.region;
                    break;
                }
            }
            if (hit != null) break;
        }

        if (hit) |new_id| {
            if (self.active_id != new_id) {
                // 切到新 region：旧的 leave，新的起计时
                if (self.active_id) |old_id| {
                    if (self.entered) fireLeaveById(self, old_id);
                }
                self.active_id = new_id;
                self.active_enter_ms = now_ms;
                self.entered = false;
            }
            // 检查 delay（包括刚切进来的 case, delay=0 时同帧 fire）
            if (!self.entered) {
                const elapsed = now_ms - self.active_enter_ms;
                if (elapsed >= @as(i64, @intCast(hit_region.?.hover_delay_ms))) {
                    hit_region.?.on_enter(hit_region.?.ctx, mx, my);
                    self.entered = true;
                }
            }
        } else {
            // 离开所有 region
            if (self.active_id) |old_id| {
                if (self.entered) fireLeaveById(self, old_id);
                self.active_id = null;
                self.entered = false;
            }
        }
    }

    /// 鼠标离开 host Node 时调用，强制 leave 当前 active region
    pub fn onMouseLeaveHost(self: *RangeHoverRegistry) void {
        if (self.active_id) |old_id| {
            if (self.entered) fireLeaveById(self, old_id);
            self.active_id = null;
            self.entered = false;
        }
    }

    fn fireLeaveById(self: *RangeHoverRegistry, id: RangeId) void {
        for (self.entries.items) |entry_opt| {
            const e = entry_opt orelse continue;
            if (e.id == id) {
                e.region.on_leave(e.region.ctx);
                return;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestState = struct {
    rects: []const RangeRect,
    enter_count: u32 = 0,
    leave_count: u32 = 0,
    last_enter_x: f32 = 0,
    last_enter_y: f32 = 0,

    fn rectsFn(ctx: *anyopaque, buf: []RangeRect) usize {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        const n = @min(self.rects.len, buf.len);
        for (0..n) |i| buf[i] = self.rects[i];
        return n;
    }

    fn onEnter(ctx: *anyopaque, mx: f32, my: f32) void {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        self.enter_count += 1;
        self.last_enter_x = mx;
        self.last_enter_y = my;
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        self.leave_count += 1;
    }
};

fn newRegistry() RangeHoverRegistry {
    return .{
        .allocator = testing.allocator,
        .host = undefined, // 测试里不真 attach 到 Node
    };
}

test "range_hover: enter fires only after delay elapses" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 100,
    });

    // t=0 进入区域
    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 0), state.enter_count); // delay 未到

    // t=50 still in region
    registry.tickMouseMove(6, 5, 50);
    try testing.expectEqual(@as(u32, 0), state.enter_count);

    // t=100 delay 到达
    registry.tickMouseMove(6, 5, 100);
    try testing.expectEqual(@as(u32, 1), state.enter_count);
}

test "range_hover: leave fires when moving outside" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.tickMouseMove(20, 20, 1);
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}

test "range_hover: switching regions fires leave+enter" {
    var registry = newRegistry();
    defer registry.deinit();

    var a = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    var b = TestState{ .rects = &[_]RangeRect{.{ .x = 20, .y = 0, .w = 10, .h = 10 }} };

    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&a),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&b),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), a.enter_count);

    registry.tickMouseMove(25, 5, 1);
    try testing.expectEqual(@as(u32, 1), a.leave_count);
    try testing.expectEqual(@as(u32, 1), b.enter_count);
}

test "range_hover: unregister while hovering fires leave" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    const id = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.unregister(id);
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}

test "range_hover: onMouseLeaveHost fires leave on active region" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.onMouseLeaveHost();
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}
