//! node_interaction: interaction/focus/hit-test domain (17 methods) split out of node.zig.
//!
//! Pattern: Node-typed free functions + @import("node.zig") circular import;
//! node.zig keeps thin delegates (original pub/private visibility).
//!
//! The methods in node.zig are **non-contiguous** (interleaved with tree/debug/geometry methods).
//!
//! Cross-domain deps (promoted to pub):
//!   - rectFromWorldOrFallback
//!   - releasePathGeometry / releaseCustomClipGeometry
//!   - invalidateCustomClipGeometryCache
//! ProviderFn types (HitProxyProviderFn/CustomClipGeometryProviderFn) stay in node.zig
//! (Node struct pub const; signature has *const Node); this module refs them via
//! node_mod.Node.XxxFn.

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

// ---------------------------------------------------------------------------
// Focus / interaction visibility
// ---------------------------------------------------------------------------

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

/// Read only on left mouse down (Cx.handleMouseDownEx); not in focus order / hit / layout;
/// no need to dirty.
pub fn setPointerDownFocus(self: *Node, policy: node_mod.PointerDownFocus) void {
    self.behavior.interaction.pointer_down_focus = policy;
}

// ─────────────────────────────────────────────────────────────────────
// custom draw / hit proxy / clip geometry
// ─────────────────────────────────────────────────────────────────────

/// Set custom_draw callback and bubble-mark has_custom_draw_subtree.
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
    if ((if (self.layoutOutput()) |lo| lo.vector.fill.custom_clip != null else false) and
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

/// Bubble-mark has_custom_draw_subtree (call on child node add).
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

/// Bubble-mark has_text_subtree (call when setText non-empty; parent chains on appendChild).
/// Conservative: keep true after delete; consumers of collectContentFlags.has_text
/// (auto_stabilize_text / layerize text_with_transform_animation) only get more conservative, never
/// miss.
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

/// Bubble-mark has_before_render_subtree (call on addBeforeRender). Conservative: keep true
/// after delete; hasBeforeRenderHookSubtree over-counts true; rejects cache; safe direction.
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

/// Drop the before-render tick's quiet-subtree stamp (NodeRuntime.tick_quiet_epoch) on this node
/// and its ancestors: tick work was added here (hook registered, animation started, linger
/// requested) through a path that does not necessarily mark anything dirty.
pub fn invalidateTickQuietChain(self: *Node) void {
    var cur: ?*Node = self;
    while (cur) |n| : (cur = n.parent) n.frame_state.frame_local.runtime.tick_quiet_epoch = 0;
    // The same state (hooks, animations, linger) feeds the retained build outside the dirty bits.
    @import("render_engine/retained_memo.zig").dropMemoChain(self);
}

/// Bubble-mark has_untrusted_before_render_subtree: a before_render hook in this subtree is not
/// known to write only through dirty-marking entries (see Node.beforeRenderHooksCacheTrusted).
/// Conservative like has_before_render_subtree: never cleared.
pub fn markSubtreeUntrustedBeforeRenderHook(self: *Node) void {
    if (self.frame_state.state_bits.flags.has_untrusted_before_render_subtree) return;
    self.frame_state.state_bits.flags.has_untrusted_before_render_subtree = true;
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.flags.has_untrusted_before_render_subtree) break;
        parent.frame_state.state_bits.flags.has_untrusted_before_render_subtree = true;
        p = parent.parent;
    }
}

/// Increment clip_meta.epoch -> invalidate ensureCustomClipGeometry cache (dirty domain §N1
/// cross-module call).
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
