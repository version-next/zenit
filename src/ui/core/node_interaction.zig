//! node_interaction, v0.12 §N3 god-object split: 从 node.zig 抽出
//! 交互/焦点/Hit-Test 子域（17 方法）。
//!
//! 范式同 §N1/§N2：Node-typed free function + @import("node.zig") 循环
//! import；node.zig 保留 thin delegate（原 pub/private 可见性）。
//!
//! 与前两刀差异：本子域方法在 node.zig 里**非连续**（与树结构/调试
//! 元数据/geometry 方法交错），逐方法迁移而非整块切。
//!
//! 跨子域依赖（生命周期 §N4 才抽，本刀先升 pub）：
//!   - rectFromWorldOrFallback（已 §N1 前就 pub）
//!   - releasePathGeometry / releaseCustomClipGeometry -> §N3 升 pub
//!   - invalidateCustomClipGeometryCache（§N1 已升 pub，本刀随迁过来）
//! ProviderFn 类型（HitProxyProviderFn/CustomClipGeometryProviderFn）
//! 留 node.zig（Node struct 内 pub const，签名含 *const Node，无外部
//! caller），本模块经 node_mod.Node.XxxFn 引用。

const std = @import("std");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const focus_mod = @import("../focus.zig");
const svg_path = @import("svg_path.zig");
const render_engine = @import("render_engine/mod.zig");

const Node = node_mod.Node;
const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;
const DrawContext = render_engine.DrawContext;
const clonePathGeometry = svg_path.clonePathGeometry;
const freePathGeometry = svg_path.freePathGeometry;
const computePathBounds = svg_path.computePathBounds;
const parseSvgPathCommands = svg_path.parseSvgPathCommands;
const parseSvgDocumentPathCommands = svg_path.parseSvgDocumentPathCommands;

const HitProxyProviderFn = node_mod.Node.HitProxyProviderFn;
const CustomClipGeometryProviderFn = node_mod.Node.CustomClipGeometryProviderFn;

// ─────────────────────────────────────────────────────────────────────
// 焦点 / 交互可见性
// ─────────────────────────────────────────────────────────────────────

pub fn setFocusable(self: *Node, focusable: bool) void {
    if (self.behavior.interaction.focusable == focusable) return;
    self.behavior.interaction.focusable = focusable;
    self.markOrderDirty();
}

pub fn setInteractionDelegate(self: *Node, delegate: ?*Node) void {
    self.meta.ownership.delegate.interaction = delegate;
}

pub fn setInspectPickDisabled(self: *Node, disabled: bool) void {
    if (self.frame_state.state_bits.flags.inspect_pick_disabled == disabled) return;
    self.frame_state.state_bits.flags.inspect_pick_disabled = disabled;
    self.markHitSemanticsDirty();
}

pub fn setHitTestVisible(self: *Node, visible: bool) void {
    if (self.frame_state.state_bits.flags.hit_test_visible == visible) return;
    self.frame_state.state_bits.flags.hit_test_visible = visible;
    self.markInteractionDirty();
}

pub fn setTabIndex(self: *Node, tab_index: ?i32) void {
    if (self.behavior.interaction.tab_index == tab_index) return;
    self.behavior.interaction.tab_index = tab_index;
    if (tab_index) |ti| {
        if (ti >= 0 and !self.behavior.interaction.focusable) {
            self.behavior.interaction.focusable = true;
        }
    }
    self.markOrderDirty();
}

pub fn setFocusScope(self: *Node, focus_scope: ?focus_mod.FocusScopeConfig) void {
    if (std.meta.eql(self.behavior.interaction.focus_scope, focus_scope)) return;
    self.behavior.interaction.focus_scope = focus_scope;
    self.markOrderDirty();
}

/// 只在左键按下时被读取（Cx.handleMouseDownEx），不参与 focus order / 命中 /
/// 布局，因此无需标脏。
pub fn setPointerDownFocus(self: *Node, policy: node_mod.PointerDownFocus) void {
    self.behavior.interaction.pointer_down_focus = policy;
}

// ─────────────────────────────────────────────────────────────────────
// custom draw / hit proxy / clip geometry
// ─────────────────────────────────────────────────────────────────────

/// 设置 custom_draw 回调并冒泡标记 has_custom_draw_subtree
pub fn setCustomDraw(self: *Node, draw_fn: *const fn (DrawContext, ?*anyopaque) anyerror!void, draw_ctx: ?*anyopaque) void {
    self.meta.per_frame.custom_hooks.draw = .{ .callback = draw_fn, .context = draw_ctx };
    if (!self.frame_state.state_bits.flags.has_custom_draw_subtree) {
        self.frame_state.state_bits.flags.has_custom_draw_subtree = true;
        var p = self.parent;
        while (p) |parent| {
            if (parent.frame_state.state_bits.flags.has_custom_draw_subtree) break;
            parent.frame_state.state_bits.flags.has_custom_draw_subtree = true;
            p = parent.parent;
        }
    }
}

pub fn setCustomClipGeometryProvider(self: *Node, allocator: Allocator, provider: CustomClipGeometryProviderFn, context: ?*anyopaque) void {
    self.releaseCustomClipGeometry(allocator);
    self.meta.per_frame.custom_hooks.clip_meta.provider = provider;
    self.meta.per_frame.custom_hooks.clip_meta.provider_context = context;
    self.markInteractionDirty();
}

pub fn setHitProxyProvider(self: *Node, provider: HitProxyProviderFn, context: ?*anyopaque) void {
    self.meta.per_frame.custom_hooks.hit_proxy = .{ .callback = provider, .context = context };
    self.markHitStructureDirty();
}

/// Clone before publishing so allocation failure and aliased source slices leave
/// the old value intact. The slot owns the replacement only after cloning succeeds.
fn replaceGeometry(allocator: Allocator, slot: *?PathGeometry, geometry: PathGeometry) !void {
    const replacement = try clonePathGeometry(allocator, geometry);
    var previous = slot.*;
    slot.* = replacement;
    if (previous) |*old| freePathGeometry(allocator, old);
}

pub fn setPathHitGeometry(self: *Node, allocator: Allocator, commands: []const PathCommand, fill_rule: PathFillRule) !void {
    try self.setClonedPathGeometry(allocator, .{
        .commands = commands,
        .fill_rule = fill_rule,
        .bounds = computePathBounds(commands),
    });
}

pub fn setSvgPathHitGeometry(self: *Node, allocator: Allocator, svg_path_data: []const u8, fill_rule: PathFillRule) !void {
    const commands = try parseSvgPathCommands(allocator, svg_path_data);
    defer allocator.free(commands);
    try self.setPathHitGeometry(allocator, commands, fill_rule);
}

pub fn setSvgDocumentHitGeometry(self: *Node, allocator: Allocator, svg_data: []const u8, fill_rule: PathFillRule) !void {
    const commands = try parseSvgDocumentPathCommands(allocator, svg_data);
    defer allocator.free(commands);
    try self.setPathHitGeometry(allocator, commands, fill_rule);
}

pub fn setClonedPathGeometry(self: *Node, allocator: Allocator, geometry: PathGeometry) !void {
    const lo = self.layoutOutputPtr() orelse return error.LayoutOutputUnavailable;
    try replaceGeometry(allocator, &lo.vector.fill.path, geometry);
    self.markInteractionDirty();
}

pub fn setCustomClipGeometryForNode(self: *Node, allocator: Allocator, commands: []const PathCommand, fill_rule: PathFillRule) !void {
    const lo = self.layoutOutputPtr() orelse return error.LayoutOutputUnavailable;
    try replaceGeometry(allocator, &lo.vector.fill.custom_clip, .{
        .commands = commands,
        .fill_rule = fill_rule,
        .bounds = computePathBounds(commands),
    });
    self.meta.per_frame.custom_hooks.clip_meta.cache_rect = ComputedRect.init(-1, -1, -1, -1);
    self.meta.per_frame.custom_hooks.clip_meta.cache_epoch = 0;
    self.markInteractionDirty();
}

pub fn setSvgCustomClipGeometry(self: *Node, allocator: Allocator, svg_path_data: []const u8, fill_rule: PathFillRule) !void {
    const commands = try parseSvgPathCommands(allocator, svg_path_data);
    defer allocator.free(commands);
    try setCustomClipGeometryForNode(self, allocator, commands, fill_rule);
}

pub fn ensureCustomClipGeometry(self: *Node, allocator: Allocator) !void {
    const provider = self.meta.per_frame.custom_hooks.clip_meta.provider orelse return;
    const r = self.rectFromWorldOrFallback();
    const current_rect = ComputedRect.init(0, 0, r.w, r.h);
    if (self.getLayoutOutput().vector.fill.custom_clip != null and
        self.meta.per_frame.custom_hooks.clip_meta.cache_epoch == self.meta.per_frame.custom_hooks.clip_meta.epoch and
        !self.frame_state.state_bits.dirty.hit.geometry and
        std.math.approxEqAbs(f32, self.meta.per_frame.custom_hooks.clip_meta.cache_rect.w, current_rect.w, 0.0001) and
        std.math.approxEqAbs(f32, self.meta.per_frame.custom_hooks.clip_meta.cache_rect.h, current_rect.h, 0.0001))
    {
        return;
    }

    // Resolve storage before accepting ownership from the provider. Provider
    // errors still clear the stale clip, preserving the documented fallback.
    if (self.layoutOutputPtr() == null) return error.LayoutOutputUnavailable;
    self.releaseCustomClipGeometry(allocator);

    var geometry = try provider(self, allocator, self.meta.per_frame.custom_hooks.clip_meta.provider_context);
    errdefer freePathGeometry(allocator, &geometry);

    if (!geometry.owned) {
        geometry = try clonePathGeometry(allocator, geometry);
    }
    // A provider may allocate nodes and grow the layout table. Reacquire its slot.
    const lo = self.layoutOutputPtr() orelse return error.LayoutOutputUnavailable;
    lo.vector.fill.custom_clip = geometry;
    self.meta.per_frame.custom_hooks.clip_meta.cache_rect = current_rect;
    self.meta.per_frame.custom_hooks.clip_meta.cache_epoch = self.meta.per_frame.custom_hooks.clip_meta.epoch;
}

/// 冒泡标记 has_custom_draw_subtree（子节点添加时调用）
pub fn markCustomDrawSubtree(self: *Node) void {
    if (self.frame_state.state_bits.flags.has_custom_draw_subtree) return;
    self.frame_state.state_bits.flags.has_custom_draw_subtree = true;
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.flags.has_custom_draw_subtree) break;
        parent.frame_state.state_bits.flags.has_custom_draw_subtree = true;
        p = parent.parent;
    }
}

/// 冒泡标记 has_text_subtree（setText 非空时调用；appendChild 时由父链并入）。
/// 保守不清位：删文本后保持 true, collectContentFlags.has_text 的消费者
/// （auto_stabilize_text / layerize text_with_transform_animation）只会因此
/// 更保守，不会漏。
pub fn markSubtreeText(self: *Node) void {
    if (self.frame_state.state_bits.flags.has_text_subtree) return;
    self.frame_state.state_bits.flags.has_text_subtree = true;
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.flags.has_text_subtree) break;
        parent.frame_state.state_bits.flags.has_text_subtree = true;
        p = parent.parent;
    }
}

/// 冒泡标记 has_before_render_subtree（addBeforeRender 时调用）。
/// 保守不清位：hook 删除后保持 true -> hasBeforeRenderHookSubtree 多算 true
/// -> 拒绝缓存，方向安全。
pub fn markSubtreeBeforeRenderHook(self: *Node) void {
    if (self.frame_state.state_bits.flags.has_before_render_subtree) return;
    self.frame_state.state_bits.flags.has_before_render_subtree = true;
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.flags.has_before_render_subtree) break;
        parent.frame_state.state_bits.flags.has_before_render_subtree = true;
        p = parent.parent;
    }
}

/// 自增 clip_meta.epoch -> 使 ensureCustomClipGeometry 缓存失效
/// （dirty 子域 §N1 跨模块调）
pub fn invalidateCustomClipGeometryCache(self: *Node) void {
    self.meta.per_frame.custom_hooks.clip_meta.epoch +%= 1;
}

test "geometry transaction preserves owned data on failure and accepts aliased input" {
    const allocator = std.testing.allocator;
    const commands = [_]PathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 20, .y = 10 } },
    };
    const node = try Node.create(allocator, 1, .box, .{});
    defer node.destroy(allocator);
    inline for (.{ false, true }) |clip| {
        if (clip) try setCustomClipGeometryForNode(node, allocator, &commands, .nonzero) else try setPathHitGeometry(node, allocator, &commands, .nonzero);
        const lo = node.layoutOutputPtr().?;
        const slot = if (clip) &lo.vector.fill.custom_clip else &lo.vector.fill.path;
        const original = slot.*.?;
        if (clip) {
            node.meta.per_frame.custom_hooks.clip_meta.cache_epoch = 7;
            node.meta.per_frame.custom_hooks.clip_meta.cache_rect = ComputedRect.init(0, 0, 20, 10);
        }
        const cache_before = node.meta.per_frame.custom_hooks.clip_meta;
        const dirty_before = node.frame_state.state_bits.dirty;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        if (clip) try std.testing.expectError(error.OutOfMemory, setCustomClipGeometryForNode(node, failing.allocator(), original.commands, .evenodd)) else try std.testing.expectError(error.OutOfMemory, setPathHitGeometry(node, failing.allocator(), original.commands, .evenodd));
        try std.testing.expectEqual(original.commands.ptr, slot.*.?.commands.ptr);
        try std.testing.expectEqual(original.fill_rule, slot.*.?.fill_rule);
        try std.testing.expectEqualDeep(cache_before, node.meta.per_frame.custom_hooks.clip_meta);
        try std.testing.expectEqualDeep(dirty_before, node.frame_state.state_bits.dirty);
        if (clip) try setCustomClipGeometryForNode(node, allocator, original.commands, .evenodd) else try setPathHitGeometry(node, allocator, original.commands, .evenodd);
        try std.testing.expectEqualDeep(&commands, slot.*.?.commands);
        try std.testing.expectEqual(PathFillRule.evenodd, slot.*.?.fill_rule);
    }
    const original = node.getLayoutOutput().vector.fill.path.?;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, setClonedPathGeometry(node, failing.allocator(), original));
    try std.testing.expectEqual(original.commands.ptr, node.getLayoutOutput().vector.fill.path.?.commands.ptr);
    try setClonedPathGeometry(node, allocator, original);
    try std.testing.expectEqualDeep(&commands, node.getLayoutOutput().vector.fill.path.?.commands);
}

test "geometry transaction provider failure retains rectangle fallback contract" {
    const callbacks = struct {
        fn provide(_: *const Node, _: Allocator, _: ?*anyopaque) !PathGeometry {
            return error.ProviderUnavailable;
        }
    };
    const allocator = std.testing.allocator;
    const node = try Node.create(allocator, 2, .box, .{});
    defer node.destroy(allocator);
    node.setCustomClipGeometryProvider(allocator, callbacks.provide, null);
    try setCustomClipGeometryForNode(node, allocator, &.{.{ .move_to = .{ .x = 0, .y = 0 } }}, .nonzero);
    try std.testing.expectError(error.ProviderUnavailable, ensureCustomClipGeometry(node, allocator));
    try std.testing.expectEqual(@as(?PathGeometry, null), node.getLayoutOutput().vector.fill.custom_clip);
}

test "geometry transaction unavailable layout slot does not accept command ownership" {
    const world_mod = @import("world.zig");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var world = world_mod.World.init(failing.allocator());
    defer world.deinit();
    const node = try Node.create(std.testing.allocator, 3, .box, .{});
    defer node.destroy(std.testing.allocator);
    node.world_ref = &world;
    node.element_id_raw = 0;
    const commands = [_]PathCommand{.{ .move_to = .{ .x = 0, .y = 0 } }};
    try std.testing.expectError(error.LayoutOutputUnavailable, setPathHitGeometry(node, std.testing.allocator, &commands, .nonzero));
    try std.testing.expectError(error.LayoutOutputUnavailable, setClonedPathGeometry(node, std.testing.allocator, .{ .commands = &commands }));
    try std.testing.expectError(error.LayoutOutputUnavailable, setCustomClipGeometryForNode(node, std.testing.allocator, &commands, .nonzero));
}
