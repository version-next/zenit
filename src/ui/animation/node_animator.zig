/// 节点命令式动画，animateNode
///
/// 直接对节点属性发起命令式动画，支持多属性并行，冲突自动覆盖 (overwrite)。
/// 与 TransitionSlots (声明式) 互补：TransitionSlots 是 "设了 transition 后属性变化自动过渡"，
/// animateNode 是 "主动发起一个从 A 到 B 的动画"。
///
/// 用法:
/// ```zig
/// const node_animator = @import("animation/node_animator.zig");
///
/// // 单属性动画
/// node_animator.animateNode(node, allocator, .{
///     .prop = .opacity,
///     .from = 0, .to = 1,
///     .duration = 0.3,
/// });
///
/// // 多属性并行
/// node_animator.animateNode(node, allocator, .{ .prop = .translate_y, .from = 20, .to = 0 });
/// node_animator.animateNode(node, allocator, .{ .prop = .opacity, .to = 1 });
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const ctrl_mod = @import("controller.zig");
const AnimationController = ctrl_mod.AnimationController;
const Easing = @import("easing.zig").Easing;
const render_engine = @import("../core/render_engine/mod.zig");

/// 可动画属性
pub const AnimatableProp = enum(u6) {
    // 与 TransitionProp 对齐的基础属性
    opacity = 0,
    translate_x = 1,
    translate_y = 2,
    scale_x = 3,
    scale_y = 4,
    corner_radius = 5,
    border_width = 6,
    width = 7,
    // 扩展属性
    height = 8,
    margin_top = 9,
    margin_left = 10,
    gap = 11,
    rotate = 12,
};

/// 动画配置
pub const AnimateConfig = struct {
    /// 目标属性
    prop: AnimatableProp,
    /// 起始值 (null = 从当前值自动获取)
    from: ?f32 = null,
    /// 目标值
    to: f32,
    /// 持续时间（秒）
    duration: f32 = 0.3,
    /// 缓动函数
    easing: Easing = .ease_out_quad,
    /// 延迟（秒）
    delay: f32 = 0,
    /// 完成回调
    on_complete: ?ctrl_mod.CallbackFn = null,
    on_complete_ctx: ?*anyopaque = null,
};

/// 节点上的活跃动画列表（固定大小，零分配 tick）
pub const NodeAnimations = struct {
    entries: [max_entries]Entry = undefined,
    count: u8 = 0,
    ticking: bool = false,
    pending_completions: u64 = 0,
    next_generation: u64 = 0,

    const max_entries = 16;

    pub const Entry = struct {
        prop: AnimatableProp,
        controller: AnimationController,
        generation: u64 = 0,
    };

    /// 添加或替换属性动画（同属性自动 overwrite）。
    /// 若同 prop 已有正在跑的 controller，先取它的 current_value + velocity
    /// 调新 controller.seed, interruption-safe，避免 hover/active 切换时数值跳变。
    pub fn set(self: *NodeAnimations, prop: AnimatableProp, ctrl: AnimationController) void {
        if (ctrl.isScopeRetiring()) return;
        var accepted = ctrl.cloneForNode();
        accepted.node_owned = true;
        var stored = false;
        defer if (!stored) accepted.releaseLifetime();
        // A preceding completion callback can replace another just-finished
        // property. That property's old callback is no longer authoritative.
        self.pending_completions &= ~propBit(prop);
        self.next_generation +%= 1;
        // 查找已有同属性动画
        for (self.entries[0..self.count]) |*entry| {
            if (entry.prop == prop) {
                // 中断 seed: 从 old 读 value/velocity
                const old_value = entry.controller.value;
                const old_velocity = entry.controller.currentVelocity();
                entry.controller.releaseLifetime();
                entry.controller = accepted;
                stored = true;
                entry.controller.ticking = false;
                entry.generation = self.next_generation;
                // play() 必须先调 (spring.start 内部 reset current_value=from / velocity=0
                // 等 driver-specific 锚点)；之后再 seed 把 old current/velocity 写进去，
                // 让真正的 tick 时序从 old 状态续衔。
                entry.controller.play();
                entry.controller.seed(old_value, old_velocity);
                return;
            }
        }
        // 新增。满额时先驱逐一个已终结条目（completed/idle 的最终值早已写进
        // style，条目只是等外部 restart 的占位），此前静默丢弃新动画，而
        // animateNode 在 set 之前已把 from 值写进节点：节点被永久钉在 from，
        // 比不调用还糟。
        if (self.count >= max_entries) {
            var evict: ?u8 = null;
            for (self.entries[0..self.count], 0..) |*entry, idx| {
                const st = entry.controller.play_state;
                if (st == .completed or st == .idle) {
                    evict = @intCast(idx);
                    break;
                }
            }
            if (evict) |idx| {
                self.entries[idx].controller.releaseLifetime();
                self.entries[idx] = self.entries[self.count - 1];
                self.count -= 1;
            } else {
                // 16 条全部活跃仍要加第 17 条：真实场景不该出现，出声再丢
                std.log.warn("[node_animator] 属性动画槽满（{d}），丢弃 prop={any}", .{ max_entries, prop });
                return;
            }
        }
        self.entries[self.count] = .{ .prop = prop, .controller = accepted, .generation = self.next_generation };
        stored = true;
        self.entries[self.count].controller.ticking = false;
        self.entries[self.count].controller.play();
        self.count += 1;
    }

    pub fn deinit(self: *NodeAnimations) void {
        for (self.entries[0..self.count]) |*entry| entry.controller.releaseLifetime();
        self.count = 0;
    }

    /// 每帧 tick 所有属性动画，返回 true 表示仍有活跃动画
    /// now_ms: 当前帧的绝对时间戳（毫秒）
    pub fn tick(self: *NodeAnimations, node: anytype, allocator: Allocator, now_ms: f64) bool {
        if (nodeIsRetiring(node)) return false;
        if (self.ticking) return self.hasActive();
        self.ticking = true;
        self.pending_completions = 0;
        defer {
            self.ticking = false;
            self.pending_completions = 0;
        }
        var requested_linger = false;
        var pending_callbacks: [max_entries]struct {
            prop: AnimatableProp,
            cb: ctrl_mod.CallbackFn,
            ctx: *anyopaque,
            lifetime: ?*ctrl_mod.ScopeLifetime,
        } = undefined;
        var pending_count: usize = 0;
        defer for (pending_callbacks[0..pending_count]) |pending| {
            if (pending.lifetime) |lifetime| lifetime.release();
        };
        const Snapshot = struct { prop: AnimatableProp, generation: u64 };
        var initial: [max_entries]Snapshot = undefined;
        const initial_count = self.count;
        for (self.entries[0..initial_count], 0..) |entry, i| {
            initial[i] = .{ .prop = entry.prop, .generation = entry.generation };
        }
        const Guard = struct {
            anims: *NodeAnimations,
            node: @TypeOf(node),
            prop: AnimatableProp,
            generation: u64,
            pub fn isCurrent(g: @This()) bool {
                return !nodeIsRetiring(g.node) and g.anims.findEntry(g.prop, g.generation) != null;
            }
        };
        // Snapshot identities, not controller values or pointers. A callback
        // can replace any property; new generations begin on the next pass.
        for (initial[0..initial_count]) |item| {
            if (nodeIsRetiring(node)) return false;
            const index = self.findEntry(item.prop, item.generation) orelse continue;
            const guard = Guard{ .anims = self, .node = node, .prop = item.prop, .generation = item.generation };
            const ctrl = &self.entries[index].controller;
            if (ctrl.isScopeRetiring()) {
                self.removeEntry(index);
                continue;
            }
            if (!ctrl.isActive() and !ctrl.isCompleted()) continue;
            _ = ctrl.tickDeferredCompletion(now_ms, guard);
            if (!guard.isCurrent()) continue;
            // A callback may have moved this entry while editing other slots.
            const current_index = self.findEntry(item.prop, item.generation).?;
            const entry = &self.entries[current_index];
            if (entry.controller.isScopeRetiring()) {
                self.removeEntry(current_index);
                continue;
            }
            // Publish pause/stop/seek effects too, even when tick returns false.
            applyValue(node, allocator, entry);
            if (!entry.controller.isCompleted()) continue;
            const affects_opacity = animPropAffectsOpacity(entry.prop);
            const affects_transform = animPropAffectsTransform(entry.prop);
            if (affects_opacity or affects_transform) {
                node.requestCompositeAnimationLinger(affects_opacity, affects_transform);
                requested_linger = true;
            }
            if (entry.controller.on_complete) |cb| {
                if (entry.controller.on_complete_ctx) |ctx| {
                    const lifetime = entry.controller.scope_lifetime;
                    if (lifetime) |retained| retained.retain();
                    pending_callbacks[pending_count] = .{ .prop = entry.prop, .cb = cb, .ctx = ctx, .lifetime = lifetime };
                    self.pending_completions |= propBit(entry.prop);
                    pending_count += 1;
                }
            }
            self.removeEntry(current_index);
        }
        for (pending_callbacks[0..pending_count]) |entry| {
            if (nodeIsRetiring(node)) break;
            const bit = propBit(entry.prop);
            if (self.pending_completions & bit == 0) continue;
            self.pending_completions &= ~bit;
            if (entry.lifetime) |lifetime| {
                if (lifetime.isRetiring()) continue;
                const owner = lifetime.scope.?.owner;
                owner.beginReactiveCallback();
                defer owner.endReactiveCallback();
                entry.cb(entry.ctx);
            } else entry.cb(entry.ctx);
        }
        // Callbacks can start new work. Its playing state must keep the frame
        // loop alive even when none of the old entries remains active.
        return !nodeIsRetiring(node) and (self.hasActive() or requested_linger);
    }

    fn removeEntry(self: *NodeAnimations, index: usize) void {
        self.entries[index].controller.releaseLifetime();
        self.count -= 1;
        if (index < self.count) self.entries[index] = self.entries[self.count];
    }

    fn findEntry(self: *const NodeAnimations, prop: AnimatableProp, generation: u64) ?usize {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.prop == prop and entry.generation == generation) return i;
        }
        return null;
    }

    fn propBit(prop: AnimatableProp) u64 {
        return @as(u64, 1) << @intFromEnum(prop);
    }

    fn hasActive(self: *const NodeAnimations) bool {
        for (self.entries[0..self.count]) |entry| {
            if (!entry.controller.isScopeRetiring() and entry.controller.isActive()) return true;
        }
        return false;
    }

    /// 按属性类型应用值到节点 style
    fn applyValue(node: anytype, allocator: Allocator, entry: *const Entry) void {
        const v = entry.controller.value;
        switch (entry.prop) {
            .opacity => {
                // generic over MockNode (plain .style.opacity field)
                // vs real Node (字段已删 -> setOpacityRaw 路由 World.paint_state)。
                if (comptime @hasDecl(@TypeOf(node.*), "setOpacityRaw")) {
                    node.setOpacityRaw(v);
                } else {
                    node.style.opacity = v;
                }
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
            .translate_x => {
                node.style.translate_x = v;
                // 权威失效组合（= markCompositePropDirty；anytype MockNode 兼容故展开写）
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
            .translate_y => {
                node.style.translate_y = v;
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
            .scale_x => {
                node.style.ensureExtPanic(allocator).scale_x = v;
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
            .scale_y => {
                node.style.ensureExtPanic(allocator).scale_y = v;
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
            .corner_radius => {
                node.style.ensureExtPanic(allocator).corner_radius = .{ .all = @max(0, v) };
                node.markInteractionDirty();
                node.markRenderDirty();
            },
            .border_width => {
                node.style.border.setUniformWidth(v);
                node.markInteractionDirty();
                node.markRenderDirty();
            },
            .width => {
                node.style.width = .{ .px = @max(0, v) };
                node.markSizingDirty();
            },
            .height => {
                node.style.height = .{ .px = @max(0, v) };
                node.markSizingDirty();
            },
            .margin_top => {
                node.setMarginTop(v);
            },
            .margin_left => {
                node.setMarginLeft(v);
            },
            .gap => {
                node.style.gap = v;
                node.markLayoutDirty();
            },
            .rotate => {
                node.style.ensureExtPanic(allocator).rotate = v;
                node.markInteractionDirty();
                node.markCompositeDirty();
                node.invalidateRenderCache();
            },
        }
    }

    /// 获取节点当前属性值
    pub fn getCurrentPropValue(node: anytype, prop: AnimatableProp) f32 {
        return switch (prop) {
            // real Node 字段已删 -> getOpacity 路由 World；
            // MockNode/TestNode 仍有 plain .style.opacity 字段。
            .opacity => if (comptime @hasDecl(@TypeOf(node.*), "getOpacity"))
                node.getOpacity()
            else
                node.style.opacity,
            .translate_x => node.style.translate_x,
            .translate_y => node.style.translate_y,
            .scale_x => node.style.scale_x(),
            .scale_y => node.style.scale_y(),
            .corner_radius => blk: {
                const cr = node.style.corner_radius() orelse break :blk 0;
                break :blk cr.all;
            },
            .border_width => node.style.border.width,
            .width => switch (node.style.width) {
                .px => |v| v,
                // node 是 generic (anytype)，MockNode 有 frame_state.rect 字段；
                // 真 Node 的字段已删，走 rectFromWorldOrFallback。comptime 分支。
                else => if (comptime @hasDecl(@TypeOf(node.*), "rectFromWorldOrFallback"))
                    node.rectFromWorldOrFallback().w
                else
                    node.frame_state.rect.w,
            },
            .height => switch (node.style.height) {
                .px => |v| v,
                else => if (comptime @hasDecl(@TypeOf(node.*), "rectFromWorldOrFallback"))
                    node.rectFromWorldOrFallback().h
                else
                    node.frame_state.rect.h,
            },
            .margin_top => node.style.margin.top,
            .margin_left => node.style.margin.left,
            .gap => node.style.gap,
            .rotate => node.style.rotate(),
        };
    }
};

fn animPropAffectsOpacity(prop: AnimatableProp) bool {
    return prop == .opacity;
}

fn animPropAffectsTransform(prop: AnimatableProp) bool {
    return switch (prop) {
        .translate_x, .translate_y, .scale_x, .scale_y, .rotate => true,
        else => false,
    };
}

/// 便捷函数：对节点发起属性动画
// Real Nodes are protected by Cx's deferred reclamation while ticking. Mock
// animation hosts have no lifetime fields and retain their existing contract.
fn nodeIsRetiring(node: anytype) bool {
    if (comptime @hasField(@TypeOf(node.*), "pending_free_cx")) {
        var current: ?@TypeOf(node) = node;
        while (current) |ancestor| : (current = ancestor.parent) {
            if (ancestor.pending_free_cx != null or ancestor.freeing) return true;
        }
    }
    return false;
}

pub fn animateNode(node: anytype, allocator: Allocator, config: AnimateConfig) void {
    if (nodeIsRetiring(node)) return;
    // 确保节点有 NodeAnimations
    const anims = blk: {
        if (node.frame_state.frame_local.runtime.commands) |a| break :blk a;
        const a = allocator.create(NodeAnimations) catch return;
        a.* = .{};
        node.frame_state.frame_local.runtime.commands = a;
        break :blk a;
    };

    const from = config.from orelse NodeAnimations.getCurrentPropValue(node, config.prop);

    var ctrl = AnimationController.initTween(.{
        .from = from,
        .to = config.to,
        .duration = config.duration,
        .easing = config.easing,
        .delay = config.delay,
    });
    ctrl.on_complete = config.on_complete;
    ctrl.on_complete_ctx = config.on_complete_ctx;

    anims.set(config.prop, ctrl);
    // set may seed an interrupted controller from its current value/velocity.
    // Publish that accepted state, not the unseeded config.from value.
    for (anims.entries[0..anims.count]) |*entry| {
        if (entry.prop == config.prop) {
            NodeAnimations.applyValue(node, allocator, entry);
            break;
        }
    }
}

// ========== 测试 ==========

// 测试用的 Mock Node
const MockStyle = struct {
    opacity: f32 = 1.0,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    width: union(enum) { px: f32, fit, grow: struct {} } = .fit,
    height: union(enum) { px: f32, fit, grow: struct {} } = .fit,
    margin: struct { top: f32 = 0, left: f32 = 0 } = .{},
    gap: f32 = 0,
    border: struct {
        width: f32 = 0,
        pub fn setUniformWidth(self: *@This(), w: f32) void {
            self.width = w;
        }
    } = .{},

    fn scale_x(_: *const MockStyle) f32 {
        return 1.0;
    }
    fn scale_y(_: *const MockStyle) f32 {
        return 1.0;
    }
    fn corner_radius(_: *const MockStyle) ?struct { all: f32 } {
        return .{ .all = 0 };
    }
    fn rotate(_: *const MockStyle) f32 {
        return mock_ext.rotate;
    }
    fn ensureExtPanic(_: *MockStyle, _: Allocator) *MockStyleExt {
        return &mock_ext;
    }
};

const MockStyleExt = struct {
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    corner_radius: struct { all: f32 } = .{ .all = 0 },
    rotate: f32 = 0,
};

var mock_ext = MockStyleExt{};

const MockNode = struct {
    style: MockStyle = .{},
    frame_state: struct {
        rect: struct { w: f32 = 100, h: f32 = 50 } = .{},
        frame_local: struct {
            runtime: struct { commands: ?*NodeAnimations = null, transitions: ?*anyopaque = null } = .{},
        } = .{},
    } = .{},
    render_dirty: bool = false,
    layout_dirty: bool = false,
    dirty: struct {
        pipeline: struct {
            order: bool = false,
            subtree_order: bool = false,
            interaction: bool = false,
            subtree_interaction: bool = false,
            composite: bool = false,
            subtree_composite: bool = false,
        } = .{},
    } = .{},

    fn markRenderDirty(self: *MockNode) void {
        self.render_dirty = true;
    }
    fn markCompositeDirty(self: *MockNode) void {
        self.dirty.pipeline.composite = true;
        self.render_dirty = true;
    }
    fn markInteractionDirty(self: *MockNode) void {
        self.dirty.pipeline.interaction = true;
    }
    fn markLayoutDirty(self: *MockNode) void {
        self.layout_dirty = true;
    }
    fn markSizingDirty(self: *MockNode) void {
        self.layout_dirty = true;
    }
    fn invalidateRenderCache(_: *MockNode) void {}
    fn requestCompositeAnimationLinger(self: *MockNode, _: bool, _: bool) void {
        self.dirty.pipeline.composite = true;
    }
    fn setMarginTop(self: *MockNode, v: f32) void {
        self.style.margin.top = v;
        self.markLayoutDirty();
    }
    fn setMarginLeft(self: *MockNode, v: f32) void {
        self.style.margin.left = v;
        self.markLayoutDirty();
    }
};

/// 测试辅助：设置全局模拟时间
fn setTestTime(ms: f64) void {
    render_engine.current_frame_time_ms = ms;
}

test "NodeAnimations: single property" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};
    node.style.opacity = 0;

    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 0.5,
        .easing = .linear,
    }));

    try std.testing.expect(anims.count == 1);

    // tick 到中途
    setTestTime(1250.0);
    _ = anims.tick(&node, std.testing.allocator, 1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), node.style.opacity, 0.1);
    try std.testing.expect(node.render_dirty);

    // tick 到完成
    setTestTime(1500.0);
    _ = anims.tick(&node, std.testing.allocator, 1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), node.style.opacity, 0.01);
    try std.testing.expect(anims.count == 0); // 完成后移除
}

test "NodeAnimations: multi property parallel" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};

    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 0.3,
        .easing = .linear,
    }));
    anims.set(.translate_y, AnimationController.initTween(.{
        .from = 20,
        .to = 0,
        .duration = 0.3,
        .easing = .linear,
    }));

    try std.testing.expect(anims.count == 2);

    setTestTime(1150.0);
    _ = anims.tick(&node, std.testing.allocator, 1150.0);
    try std.testing.expect(node.style.opacity > 0);
    try std.testing.expect(node.style.translate_y < 20);
}

test "NodeAnimations: overwrite same prop" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};

    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 1.0,
        .easing = .linear,
    }));

    // tick 一点
    setTestTime(1100.0);
    _ = anims.tick(&node, std.testing.allocator, 1100.0);

    // 覆盖：新的动画
    anims.set(.opacity, AnimationController.initTween(.{
        .from = node.style.opacity,
        .to = 0,
        .duration = 0.5,
        .easing = .linear,
    }));

    // 仍然只有 1 个 entry
    try std.testing.expect(anims.count == 1);

    // 运行到完成
    const dt_ms: f32 = 1000.0 / 60.0;
    var now: f64 = 1100.0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        now += dt_ms;
        setTestTime(now);
        _ = anims.tick(&node, std.testing.allocator, now);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.05);
}

test "animateNode: convenience function" {
    setTestTime(1000.0);
    var node = MockNode{};
    node.style.opacity = 0;

    animateNode(&node, std.testing.allocator, .{
        .prop = .opacity,
        .from = 0,
        .to = 1,
        .duration = 0.3,
    });
    defer if (node.frame_state.frame_local.runtime.commands) |a| std.testing.allocator.destroy(a);

    try std.testing.expect(node.frame_state.frame_local.runtime.commands != null);

    // tick
    setTestTime(1300.0);
    _ = node.frame_state.frame_local.runtime.commands.?.tick(&node, std.testing.allocator, 1300.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), node.style.opacity, 0.05);
}

test "animateNode: applies from immediately before first tick" {
    setTestTime(1000.0);
    var node = MockNode{};
    node.style.opacity = 1;

    animateNode(&node, std.testing.allocator, .{
        .prop = .opacity,
        .from = 0,
        .to = 1,
        .duration = 0.3,
        .delay = 0.1,
    });
    defer if (node.frame_state.frame_local.runtime.commands) |a| std.testing.allocator.destroy(a);

    try std.testing.expect(node.frame_state.frame_local.runtime.commands != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.0001);
    try std.testing.expect(node.render_dirty);
}

test "animateNode: opacity animation marks composite dirty on start" {
    setTestTime(1000.0);
    var node = MockNode{};
    node.style.opacity = 1;

    animateNode(&node, std.testing.allocator, .{
        .prop = .opacity,
        .from = 0,
        .to = 1,
        .duration = 0.3,
    });
    defer if (node.frame_state.frame_local.runtime.commands) |a| std.testing.allocator.destroy(a);

    try std.testing.expect(node.frame_state.frame_local.runtime.commands != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.0001);
    try std.testing.expect(node.dirty.pipeline.composite);
}

test "NodeAnimations: completion callback can switch height back to fit" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};
    node.style.height = .{ .px = 0 };

    const CallbackState = struct {
        node: *MockNode,
    };
    var state = CallbackState{ .node = &node };

    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 42,
        .duration = 0.3,
        .easing = .linear,
    });
    ctrl.on_complete = struct {
        fn handler(ctx: *anyopaque) void {
            const s: *CallbackState = @ptrCast(@alignCast(ctx));
            s.node.style.height = .{ .fit = {} };
            s.node.markSizingDirty();
        }
    }.handler;
    ctrl.on_complete_ctx = @ptrCast(&state);
    anims.set(.height, ctrl);

    setTestTime(1300.0);
    _ = anims.tick(&node, std.testing.allocator, 1300.0);

    try std.testing.expectEqual(@as(u8, 0), anims.count);
    try std.testing.expect(node.layout_dirty);
    try std.testing.expect(switch (node.style.height) {
        .fit => true,
        else => false,
    });
}

// ============================================================================
// v0.7 §2.3, NodeAnimations.set 自动 seed (interrupt-safe) tests
// ============================================================================

test "tween 中断 — 新 controller 从 old current_value 起步，无跳变" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};
    node.style.opacity = 0;

    // 第 1 段：0 -> 1，duration 1s，linear
    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 1.0,
        .easing = .linear,
    }));
    // tick 到 t=0.3s，opacity 应 ≈ 0.3
    setTestTime(1300.0);
    _ = anims.tick(&node, std.testing.allocator, 1300.0);
    const v_at_interrupt = node.style.opacity;
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), v_at_interrupt, 0.05);

    // 中断：不指定 from (旧 API 需要 caller 自己读 node.style.opacity)，让 seed 自动接管
    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0, // 故意填 0 — seed 应把它覆盖成 v_at_interrupt
        .to = 0,
        .duration = 0.5,
        .easing = .linear,
    }));

    // 第一 tick 后 (very small dt)，opacity 应该 still ≈ v_at_interrupt，
    // 而不是跳到 from=0
    setTestTime(1316.0); // +16ms 一帧
    _ = anims.tick(&node, std.testing.allocator, 1316.0);
    // 0.5s 内从 v_at_interrupt -> 0；16ms 后大约走 16/500 ≈ 3% 的路 ≈ 0.291
    // 总之绝不应该跳到 0 附近（误差应远小于 v_at_interrupt 的 50%）
    try std.testing.expect(node.style.opacity > v_at_interrupt * 0.85);
    try std.testing.expect(node.style.opacity < v_at_interrupt * 1.01);
}

test "spring 中断 — velocity 续衔，不视觉抖动" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};
    node.style.opacity = 0;

    anims.set(.opacity, AnimationController.initSpring(.{
        .from = 0,
        .to = 1,
        .stiffness = 170,
        .damping = 26,
        .mass = 1,
    }));
    // tick 100ms，spring 应该已经有非 0 速度
    setTestTime(1100.0);
    _ = anims.tick(&node, std.testing.allocator, 1100.0);
    const v_at_interrupt = node.style.opacity;

    // 反向 spring 接管
    anims.set(.opacity, AnimationController.initSpring(.{
        .from = 0,
        .to = 0,
        .stiffness = 170,
        .damping = 26,
        .mass = 1,
    }));

    // 第一 tick 之后 opacity 不应跳变，seed 接管使新 spring 从 v_at_interrupt 起步
    setTestTime(1116.0);
    _ = anims.tick(&node, std.testing.allocator, 1116.0);
    // 误差容忍 30% (spring 一帧内有惯性 + damping，但绝对不能跳到 from=0)
    try std.testing.expect(node.style.opacity > v_at_interrupt * 0.7);
}

test "currentVelocity — tween 线性 progress 中段速度近似 (to-from)/duration" {
    var ctrl = AnimationController.initTween(.{
        .from = 0,
        .to = 100,
        .duration = 1.0,
        .easing = .linear,
    });
    ctrl.play();
    // Publish a midpoint sample through the public seek contract.
    ctrl.seek(0.5);
    const v = ctrl.currentVelocity();
    // linear 100 in 1s = 100 unit/s
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), v, 1.0);
}

test "currentVelocity — spring 0 起步速度 = 0" {
    var ctrl = AnimationController.initSpring(.{
        .from = 0,
        .to = 1,
        .initial_velocity = 0,
    });
    ctrl.play();
    const v = ctrl.currentVelocity();
    try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.001);
}

test "NodeAnimations: 槽满时驱逐已终结条目而非静默丢弃新动画" {
    // 回归：set 满额后无 else 静默丢弃，而 animateNode 已提前把 from 写进
    // 节点 style，节点被永久钉在 from。当前 13 个 prop < 16 槽，公开 API
    // 尚打不满；手工构造满额态锁住驱逐语义，防 prop 扩容后地雷复活。
    setTestTime(1000.0);
    var anims = NodeAnimations{};

    // 手工填满 16 槽（prop 用 1..12 循环，避开 .opacity 让 set 走新增分支）
    for (0..16) |i| {
        anims.entries[i] = .{
            .prop = @enumFromInt(1 + (i % 12)),
            .controller = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 10.0, .easing = .linear }),
        };
        anims.entries[i].controller.play();
    }
    anims.count = 16;

    // 把第 3 条置为 completed（短动画跑完）
    anims.entries[3].controller = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.05, .easing = .linear });
    anims.entries[3].controller.play();
    setTestTime(2000.0);
    _ = anims.entries[3].controller.tick(2000.0);
    try std.testing.expect(anims.entries[3].controller.isCompleted());

    // 新 prop 必须挤进来（驱逐 completed 条目），不得静默丢弃
    anims.set(.opacity, AnimationController.initTween(.{ .from = 5, .to = 6, .duration = 1.0, .easing = .linear }));
    try std.testing.expectEqual(@as(u8, 16), anims.count);
    var found = false;
    for (anims.entries[0..anims.count]) |*e| {
        if (e.prop == .opacity) found = true;
    }
    try std.testing.expect(found);
}
