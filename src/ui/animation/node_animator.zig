/// Node imperative animation, animateNode
///
/// Issues imperative animations directly on node properties; supports multi-property parallel,
/// conflicts auto-overwrite. Complements TransitionSlots (declarative, auto-transitions property
/// changes once a transition is set); animateNode actively starts A->B animations.
///
/// Usage:
/// ```zig
/// const node_animator = @import("animation/node_animator.zig");
///
/// // single property animation
/// node_animator.animateNode(node, allocator, .{
///     .prop = .opacity,
///     .from = 0, .to = 1,
///     .duration = 0.3,
/// });
///
/// // multi-property parallel
/// node_animator.animateNode(node, allocator, .{ .prop = .translate_y, .from = 20, .to = 0 });
/// node_animator.animateNode(node, allocator, .{ .prop = .opacity, .to = 1 });
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const ctrl_mod = @import("controller.zig");
const AnimationController = ctrl_mod.AnimationController;
const Easing = @import("easing.zig").Easing;
const render_engine = @import("../core/render_engine/mod.zig");

/// Animatable properties.
pub const AnimatableProp = enum(u6) {
    // Base properties aligned with TransitionProp.
    opacity = 0,
    translate_x = 1,
    translate_y = 2,
    scale_x = 3,
    scale_y = 4,
    corner_radius = 5,
    border_width = 6,
    width = 7,
    // Extended properties.
    height = 8,
    margin_top = 9,
    margin_left = 10,
    gap = 11,
    rotate = 12,
};

/// Animation config.
pub const AnimateConfig = struct {
    /// Target property.
    prop: AnimatableProp,
    /// Start value (null = auto-get from current).
    from: ?f32 = null,
    /// Target value.
    to: f32,
    /// Duration (seconds).
    duration: f32 = 0.3,
    /// Easing function.
    easing: Easing = .ease_out_quad,
    /// Delay (seconds).
    delay: f32 = 0,
    /// Completion callback.
    on_complete: ?ctrl_mod.CallbackFn = null,
    on_complete_ctx: ?*anyopaque = null,
};

/// Active animation list on node (fixed size, zero-alloc tick).
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

    /// Add or replace property animation (same prop auto-overwrites). If same prop has running
    /// controller, take its current_value + velocity, seed new controller, interruption-safe, avoid
    /// value jumps on hover/active switch.
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
        // Find existing same-property animation.
        for (self.entries[0..self.count]) |*entry| {
            if (entry.prop == prop) {
                // Interrupt seed: read value/velocity from old.
                const old_value = entry.controller.value;
                const old_velocity = entry.controller.currentVelocity();
                entry.controller.releaseLifetime();
                entry.controller = accepted;
                stored = true;
                entry.controller.ticking = false;
                entry.generation = self.next_generation;
                // play() must be called first (spring.start internally resets current_value=from /
                // velocity=0 etc driver-specific anchors); then seed writes old current/velocity,
                // lets real tick sequence pick up from old state.
                entry.controller.play();
                entry.controller.seed(old_value, old_velocity);
                return;
            }
        }
        // Add new. When full, first evict completed entry (final value already written to style,
        // entry just placeholder for external restart); previously silently discarded new
        // animation, but animateNode pre-wrote from to node style, node stuck at from, worse than
        // not calling.
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
                // All 16 active still adding 17th: shouldn't happen in real scenarios, log then
                // drop.
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

    /// Tick all property animations each frame, return true if still active.
    /// now_ms: current frame absolute timestamp (milliseconds).
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
        return @as(u64, 1) << @backingInt(prop);
    }

    fn hasActive(self: *const NodeAnimations) bool {
        for (self.entries[0..self.count]) |entry| {
            if (!entry.controller.isScopeRetiring() and entry.controller.isActive()) return true;
        }
        return false;
    }

    /// Apply value to node style by property type.
    fn applyValue(node: anytype, allocator: Allocator, entry: *const Entry) void {
        const v = entry.controller.value;
        switch (entry.prop) {
            .opacity => {
                // generic over MockNode (plain .style.opacity field) vs real Node (field deleted ->
                // setOpacityRaw routes to World.paint_state).
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
                // Authoritative invalidation combo (= markCompositePropDirty; anytype MockNode
                // compatible, so expanded).
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
                if (comptime @hasField(@TypeOf(node.style.border), "overlay")) {
                    if (!node.style.border.overlay) node.markLayoutDirty();
                } else node.markLayoutDirty();
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

    /// Get node current property value.
    pub fn getCurrentPropValue(node: anytype, prop: AnimatableProp) f32 {
        return switch (prop) {
            // real Node field deleted -> getOpacity routes to World; MockNode/TestNode still have
            // plain .style.opacity field.
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
                // node is generic (anytype), MockNode has frame_state.rect field; real Node's field
                // deleted, uses rectFromWorldOrFallback. comptime branch.
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

/// Convenience function: initiate property animation on node.
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
    // Ensure node has NodeAnimations.
    const anims = blk: {
        if (node.frame_state.frame_local.runtime.commands) |a| break :blk a;
        const a = allocator.create(NodeAnimations) catch return;
        a.* = .{};
        node.frame_state.frame_local.runtime.commands = a;
        break :blk a;
    };
    // New tick work: the before-render tick must visit this node again (quiet-subtree skip).
    if (comptime @hasDecl(@TypeOf(node.*), "invalidateTickQuietChain")) node.invalidateTickQuietChain();

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

// ========== Tests ==========

// Test Mock Node.
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

/// Test helper: set global mock time.
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

    // Tick to midpoint.
    setTestTime(1250.0);
    _ = anims.tick(&node, std.testing.allocator, 1250.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), node.style.opacity, 0.1);
    try std.testing.expect(node.render_dirty);

    // Tick to completion.
    setTestTime(1500.0);
    _ = anims.tick(&node, std.testing.allocator, 1500.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), node.style.opacity, 0.01);
    try std.testing.expect(anims.count == 0); // Remove after completion.
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

    // Tick a bit.
    setTestTime(1100.0);
    _ = anims.tick(&node, std.testing.allocator, 1100.0);

    // Overwrite: new animation.
    anims.set(.opacity, AnimationController.initTween(.{
        .from = node.style.opacity,
        .to = 0,
        .duration = 0.5,
        .easing = .linear,
    }));

    // Still only 1 entry.
    try std.testing.expect(anims.count == 1);

    // Run to completion.
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
// v0.7 section 2.3, NodeAnimations.set auto-seed (interrupt-safe) tests
// ============================================================================

test "tween 中断 — 新 controller 从 old current_value 起步，无跳变" {
    setTestTime(1000.0);
    var anims = NodeAnimations{};
    var node = MockNode{};
    node.style.opacity = 0;

    // Segment 1: 0 -> 1, duration 1s, linear.
    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0,
        .to = 1,
        .duration = 1.0,
        .easing = .linear,
    }));
    // Tick to t=0.3s, opacity should ~= 0.3.
    setTestTime(1300.0);
    _ = anims.tick(&node, std.testing.allocator, 1300.0);
    const v_at_interrupt = node.style.opacity;
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), v_at_interrupt, 0.05);

    // Interrupt: omit from (old API required caller to read node.style.opacity), let seed auto-take
    // over.
    anims.set(.opacity, AnimationController.initTween(.{
        .from = 0, // Deliberately fill 0 -- seed should override to v_at_interrupt.
        .to = 0,
        .duration = 0.5,
        .easing = .linear,
    }));

    // After first tick (very small dt), opacity should still ~= v_at_interrupt, not jump to from=0.
    setTestTime(1316.0); // +16ms per frame.
    _ = anims.tick(&node, std.testing.allocator, 1316.0);
    // 0.5s from v_at_interrupt -> 0; after 16ms ~= 3% of path ~= 0.291. Should never jump near 0
    // (error much less than v_at_interrupt's 50%).
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
    // Tick 100ms, spring should have non-0 velocity.
    setTestTime(1100.0);
    _ = anims.tick(&node, std.testing.allocator, 1100.0);
    const v_at_interrupt = node.style.opacity;

    // Reverse spring takes over.
    anims.set(.opacity, AnimationController.initSpring(.{
        .from = 0,
        .to = 0,
        .stiffness = 170,
        .damping = 26,
        .mass = 1,
    }));

    // After first tick opacity should not jump, seed takes over to start new spring from
    // v_at_interrupt.
    setTestTime(1116.0);
    _ = anims.tick(&node, std.testing.allocator, 1116.0);
    // Error tolerance 30% (spring has inertia + damping per frame, but must never jump to from=0).
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
    // Regression: set when full had no else, silently discarded, but animateNode pre-wrote from to
    // node style, node stuck at from. Currently 13 props < 16 slots, public API won't fill;
    // manually construct full-state to lock eviction semantics, prevent landmine reactivation after
    // prop expansion.
    setTestTime(1000.0);
    var anims = NodeAnimations{};

    // Manually fill 16 slots (prop cycles 1..12, avoid .opacity to let set take new-add branch).
    for (0..16) |i| {
        anims.entries[i] = .{
            .prop = @fromBackingInt(@intCast(1 + (i % 12))),
            .controller = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 10.0, .easing = .linear }),
        };
        anims.entries[i].controller.play();
    }
    anims.count = 16;

    // Set entry 3 to completed (short animation finished).
    anims.entries[3].controller = AnimationController.initTween(.{ .from = 0, .to = 1, .duration = 0.05, .easing = .linear });
    anims.entries[3].controller.play();
    setTestTime(2000.0);
    _ = anims.entries[3].controller.tick(2000.0);
    try std.testing.expect(anims.entries[3].controller.isCompleted());

    // New prop must squeeze in (evict completed entry), not silently discard.
    anims.set(.opacity, AnimationController.initTween(.{ .from = 5, .to = 6, .duration = 1.0, .easing = .linear }));
    try std.testing.expectEqual(@as(u8, 16), anims.count);
    var found = false;
    for (anims.entries[0..anims.count]) |*e| {
        if (e.prop == .opacity) found = true;
    }
    try std.testing.expect(found);
}
