//! Cx <-> accessibility tree: sync a11y tree from interaction table, and register C-ABI callbacks
//! to macOS bridge (execute action / set focus / set value / text geometry query). projection rules
//! themselves in a11y_projection.zig (doesn't hold *Cx).

const builtin = @import("builtin");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_input = @import("cx_input.zig");
const cx_platform = @import("cx_platform.zig");
const A11yProps = core.A11yProps;
const AXId = a11y_tree_mod.AXId;
const Node = core.Node;
const a11y_macos_bridge_mod = @import("../a11y/macos_bridge.zig");
const a11y_projection = @import("a11y_projection.zig");
const a11y_router_mod = @import("../a11y/nsaccessibility_router.zig");
const a11y_tree_mod = @import("../a11y/tree.zig");
const core_types = @import("types.zig");

pub fn syncOrDeferA11yProjection(self: *Cx, root: *Node) void {
    if (!self.a11y_on_demand or builtin.os.tag != .macos or a11y_macos_bridge_mod.clientsSeen()) {
        syncA11yTreeFromInteractions(self, root);
        return;
    }
    self.a11y_projection_stale = true;
    // Stay registered so the first query reaches this window and projects it.
    registerA11yContext(self);
    a11y_macos_bridge_mod.setProjectionDemand(cx_platform.a11yWindowKey(self), .{
        .ctx = self,
        .project = &cxA11yProjectOnDemand,
    });
}

fn cxA11yProjectOnDemand(ctx: *anyopaque) void {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    if (!self.a11y_projection_stale) return;
    const root = self.root orelse return;
    syncA11yTreeFromInteractions(self, root);
}

pub fn syncA11yTreeFromInteractions(self: *Cx, root: *Node) void {
    // Cleared first: the push flush below can call back into the bridge.
    self.a11y_projection_stale = false;
    self.a11y_label_buf.clearRetainingCapacity(self.allocator);
    self.accessibility_tree.beginProjection();
    var sibling_counter: u32 = 0;
    syncA11yNodeRecursive(self, root, AXId.NULL, &sibling_counter, false);
    self.accessibility_tree.finishProjection() catch @panic("OOM: a11y tree stale-node sweep");
    registerA11yContext(self);
    // Push the complete retained-tree diff to the exact native virtual
    // element. The legacy SystemSdk snapshot path remains available only
    // for callers which invoke it explicitly.
    self.a11y_push_cx_ref.window_id = cx_platform.a11yWindowKey(self);
    self.a11y_push_cx_ref.label_ctx = self;
    self.a11y_push_cx_ref.label_resolver = &cxA11yLabelResolver;
    a11y_router_mod.flushToBridge(
        &self.accessibility_tree,
        a11y_macos_bridge_mod.pushBridge(&self.a11y_push_cx_ref),
    );
}

fn registerA11yContext(self: *Cx) void {
    // inject active pointer into macos_bridge, ObjC NSAccessibility protocol methods (from C call
    // zenit_a11y_*) bring their own window_id back to query this table, multi-window each queries
    // its own tree. registration fail only possible if table full (MAX_WINDOWS windows), then that
    // window a11y degrades to unreadable, but render normal, count out for diagnosis, not silent.
    if (!a11y_macos_bridge_mod.setActiveContextWithFullInteractions(
        cx_platform.a11yWindowKey(self),
        &self.accessibility_tree,
        self,
        &cxA11yLabelResolver,
        self,
        &cxA11yPerformAction,
        &cxA11ySetSelection,
        &cxA11ySetFocus,
        &cxA11ySetTextValue,
        &cxA11ySetNumericValue,
        &cxA11yTextFrame,
        &cxA11yTextRangeAtPoint,
    )) {
        core.a11y_context_register_failures +%= 1;
    }
}

fn cxA11yLabelResolver(ctx: *anyopaque, hash: u64) ?[]const u8 {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    return self.a11y_label_buf.get(hash);
}

/// AX identity's corresponding node; return null when not node identity (set entries etc.).
fn nodeForAXId(self: *Cx, id: AXId) ?*Node {
    const root = self.root orelse return null;
    const eid = id.element() orelse return null;
    return findNodeByElementRaw(root, eid.raw());
}

fn findNodeByElementRaw(node: *Node, raw: u32) ?*Node {
    if (node.element_id_raw == raw) return node;
    for (node.children.items) |child| {
        if (findNodeByElementRaw(child, raw)) |found| return found;
    }
    return null;
}

fn cxA11yPerformAction(ctx: *anyopaque, id: AXId, action: a11y_macos_bridge_mod.Action) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    // collection entry's AXScrollToVisible: offset already committed to a11y layer in AX callback,
    // here (pump safe point) apply to component's scroll state.
    if (id.kind != .node) {
        if (action != .scroll_to_visible) return false;
        const applied = self.accessibility_tree.collections.applyPendingScroll(id);
        self.needs_redraw = true;
        return applied;
    }
    const node = nodeForAXId(self, id) orelse return false;
    if (action == .scroll_to_visible) return scrollNodeIntoView(self, node);
    // inferred button (no declared semantics, only click route; see a11y_projection.inferredProps)
    // has no a11y props, still allow press.
    const props = node.behavior.interaction.a11y orelse A11yProps{};
    if (props.disabled or props.hidden or !self.overlay_stack.allowsSemanticAction(node)) return false;

    if (node.behavior.interaction.focusable) self.setFocus(node);
    if (action == .increment or action == .decrement) if (props.value_range) |range| if (range.step) |step| if (range.context) |context| {
        const stepped = step(context, if (action == .increment) 1 else -1);
        self.needs_redraw = true;
        cx_input.rebuildRuntimeIndexesIfCurrentRootDirty(self);
        return stepped;
    };
    const rect = node.globalRect();
    const result = switch (action) {
        .press, .toggle => self.dispatcher.dispatch(.{ .click = .{
            .x = rect.x + rect.w / 2,
            .y = rect.y + rect.h / 2,
        } }, node),
        // Native AX increment/decrement is logical, independent of layout
        // direction. Existing widgets already map right/left to their
        // canonical step handlers, so route through the same key pipeline.
        .increment => self.dispatcher.dispatch(.{ .key_down = .{ .key = .right } }, node),
        .decrement => self.dispatcher.dispatch(.{ .key_down = .{ .key = .left } }, node),
        // already branched at function head (doesn't depend on props, also doesn't change focus).
        .scroll_to_visible => unreachable,
    };
    self.needs_redraw = true;
    cx_input.rebuildRuntimeIndexesIfCurrentRootDirty(self);
    return result != .ignored;
}

/// AXScrollToVisible: scroll each enclosing scroll container, from the innermost outward, until
/// node is visible. After buffered rows of a virtualized list scroll into the viewport, the list
/// binds more rows, so VoiceOver's 'next item' does not hit a wall.
fn scrollNodeIntoView(self: *Cx, node: *Node) bool {
    const hook = core.a11y_scroll_into_view_hook orelse return false;
    var moved = false;
    var cursor: ?*Node = node.parent;
    while (cursor) |n| : (cursor = n.parent) {
        if (n.tag == .scroll and hook(n, node)) moved = true;
    }
    if (moved) {
        self.needs_redraw = true;
        cx_input.rebuildRuntimeIndexesIfCurrentRootDirty(self);
    }
    return true;
}

fn cxA11ySetSelection(ctx: *anyopaque, id: AXId, start_utf8: u32, end_utf8: u32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const editable = props.editable_text orelse return false;
    if (!editable.set_selection(editable.context, start_utf8, end_utf8)) return false;
    if (node.behavior.interaction.focusable) self.setFocus(node);
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetFocus(ctx: *anyopaque, id: AXId, focused: bool) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse A11yProps{};
    if (focused) {
        if (!node.behavior.interaction.focusable or props.disabled or props.hidden or !self.overlay_stack.allowsSemanticAction(node)) return false;
        self.setFocus(node);
    } else if (self.focus_manager.getFocused() == node) {
        self.clearFocus();
    } else {
        return false;
    }
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetTextValue(ctx: *anyopaque, id: AXId, value: []const u8) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or props.readonly or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const editable = props.editable_text orelse return false;
    const setter = editable.set_value orelse return false;
    if (!setter(editable.context, value)) return false;
    // Value replacement is independent of focus. Assistive clients use the
    // explicit focus action when they want to begin editing this control.
    node.markLayoutDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11ySetNumericValue(ctx: *anyopaque, id: AXId, value: f32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or props.readonly or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const range = props.value_range orelse return false;
    const setter_ctx = range.context orelse return false;
    const setter = range.set_value orelse return false;
    if (!setter(setter_ctx, value)) return false;
    if (node.behavior.interaction.focusable) self.setFocus(node);
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

fn cxA11yTextFrame(ctx: *anyopaque, id: AXId, start_utf8: u32, end_utf8: u32, out: *a11y_tree_mod.Frame) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    const editable = props.editable_text orelse return false;
    const callback = editable.frame_for_range orelse return false;
    var rect: core_types.A11yRect = undefined;
    if (!callback(editable.context, start_utf8, end_utf8, &rect)) return false;
    out.* = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
    return out.isUsable();
}

fn cxA11yTextRangeAtPoint(ctx: *anyopaque, id: AXId, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool {
    const self: *Cx = @ptrCast(@alignCast(ctx));
    const node = nodeForAXId(self, id) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    const editable = props.editable_text orelse return false;
    const callback = editable.range_at_point orelse return false;
    return callback(editable.context, x, y, start_utf8, end_utf8);
}

fn syncA11yNodeRecursive(self: *Cx, node: *Node, parent_a11y_id: AXId, sibling_counter: *u32, ancestor_hidden: bool) void {
    a11y_projection.syncSubtree(
        self.allocator,
        &self.accessibility_tree,
        &self.a11y_label_buf,
        node,
        parent_a11y_id,
        sibling_counter,
        ancestor_hidden,
        .{ .ctx = @ptrCast(self), .isFocused = &a11yNodeIsFocused, .isBlocked = &a11yNodeIsBlocked },
    );
}

/// a11y projection focus probe: read-only 'does this node hold focus'. projection layer thus
/// doesn't need import Cx (see a11y_projection.zig module head).
fn a11yNodeIsFocused(ctx: ?*const anyopaque, node: *const Node) bool {
    const self: *const Cx = @ptrCast(@alignCast(ctx orelse return false));
    return if (self.focus_manager.current_focus) |fn_node| (fn_node == node) else false;
}

fn a11yNodeIsBlocked(ctx: ?*const anyopaque, node: *const Node) bool {
    const self: *const Cx = @ptrCast(@alignCast(ctx orelse return false));
    return !self.overlay_stack.allowsSemanticAction(node);
}

/// Item selection is a model command, independent of pointer modifiers.
pub fn setItemSelection(self: *Cx, raw: u32, operation: A11yProps.ItemSelectionOperation) bool {
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, raw) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or props.readonly or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const selection = props.item_selection orelse return false;
    if (!selection.set(selection.context, operation)) return false;
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

/// Expansion is an explicit desired state, never a synthetic pointer toggle.
pub fn setExpanded(self: *Cx, raw: u32, expanded: bool) bool {
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, raw) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or props.readonly or props.expanded == null or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const expansion = props.expansion orelse return false;
    if (!expansion.set(expansion.context, expanded)) return false;
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

/// Resolve the live layout only on the owner thread, before native publication.
/// Native COM readers receive copies and never retain widget callback/context.
pub fn textLineBoundaries(self: *Cx, raw: u32, expected: []const u8) !?[]u32 {
    const root = self.root orelse return null;
    const node = findNodeByElementRaw(root, raw) orelse return null;
    const props = node.behavior.interaction.a11y orelse return null;
    if (props.hidden or props.secure) return null;
    const editable = props.editable_text orelse return null;
    const query = editable.line_boundaries orelse return null;
    if (!@import("std").mem.eql(u8, props.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    return try query(editable.context, self.allocator);
}

/// Owned shaped pieces with affine rectangular paint clips.
/// Complex shapes remain pending work; native viewport mapping is separate.
const TextClip = struct {
    clip: @import("a11y_geometry.zig").Polygon,
    has_clip: bool,
    empty: bool,
    world: core_types.Transform2D,
};
fn buildTextClip(self: *Cx, node: *Node, viewport: ?core.ComputedRect) !TextClip {
    const std = @import("std");
    const rect_geometry = @import("render_engine/geometry.zig");
    const polygon_geometry = @import("a11y_geometry.zig");
    var clip: polygon_geometry.Polygon = .{};
    errdefer clip.deinit(self.allocator);
    var has_clip = false;
    var empty = false;
    var world: core_types.Transform2D = .{};
    if (viewport) |r| {
        const quad = try polygon_geometry.rectangle(r, .{});
        try clip.set(self.allocator, &quad);
        has_clip = true;
        if (r.w == 0 or r.h == 0) empty = true;
    }
    var ancestor: ?*Node = node;
    while (ancestor) |current| : (ancestor = current.parent) {
        if (current.style.display == .none or current.getOpacity() <= 0.001 or
            (if (current.behavior.interaction.a11y) |a| a.hidden else false)) empty = true;
    }
    if (empty) return .{ .clip = clip, .has_clip = has_clip, .empty = true, .world = world };
    const retained = @import("retained_scene.zig");
    world = retained.buildAncestorWorldTransform(node, .{ .include_rotation = true });
    if (!std.math.isFinite(world.a) or !std.math.isFinite(world.b) or
        !std.math.isFinite(world.c) or !std.math.isFinite(world.d) or
        !std.math.isFinite(world.tx) or !std.math.isFinite(world.ty)) return error.InvalidAccessibilityGeometry;
    if (@as(f64, world.a) * world.d - @as(f64, world.b) * world.c == 0) return .{ .clip = clip, .has_clip = has_clip, .empty = true, .world = world };
    ancestor = node;
    while (ancestor) |current| : (ancestor = current.parent) {
        var node_clip: ?core.ComputedRect = null;
        var node_quad: ?[4]polygon_geometry.Point = null;
        if (current.style.overflow_hidden) {
            const shape = @import("interaction_semantics.zig").nodeClipShape(current);
            if (shape == .rect or (shape == .rounded_rect and shape.rounded_rect <= 0) or (shape == .rounded_corners and @max(@max(shape.rounded_corners[0], shape.rounded_corners[1]), @max(shape.rounded_corners[2], shape.rounded_corners[3])) <= 0)) {
                const local = current.rectFromWorldOrFallback();
                const padding_clip = @import("render_engine/clip.zig").paddingBoxClipRect(current, .{ .x = 0, .y = 0, .w = local.w, .h = local.h });
                const transform = retained.buildAncestorWorldTransform(current, .{ .include_rotation = true });
                node_quad = try polygon_geometry.rectangle(padding_clip, transform);
                node_clip = transform.transformRect(padding_clip);
            }
        }
        const external = self.external_clip_rects.get(current.id);
        const external_rect: ?core.ComputedRect = if (external) |r| .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] } else null;
        const external_quad: ?[4]polygon_geometry.Point = if (external_rect) |r| try polygon_geometry.rectangle(r, .{}) else null;
        // Render traversal culls using the node clip AABB after its external
        // clip, before ancestor intersection. Keep that threshold/order.
        var cull_rect = node_clip;
        if (external_rect) |r| cull_rect = if (cull_rect) |local| rect_geometry.intersectRect(local, r) orelse core.ComputedRect.init(0, 0, 0, 0) else r;
        if (cull_rect) |r| if (r.w < 0.1 or r.h < 0.1) {
            empty = true;
        };
        const candidates = [_]?[4]polygon_geometry.Point{ node_quad, external_quad };
        for (candidates) |candidate| if (candidate) |quad| {
            if (has_clip) try clip.intersect(self.allocator, &quad) else {
                try clip.set(self.allocator, &quad);
                has_clip = true;
            }
        };
    }
    if (has_clip and try clip.bounds() == null) empty = true;
    if (empty) return .{ .clip = clip, .has_clip = has_clip, .empty = true, .world = world };
    return .{ .clip = clip, .has_clip = has_clip, .empty = false, .world = world };
}

fn validateTextGeometry(expected: []const u8, pieces: []const A11yProps.TextGeometrySegment) !void {
    const std = @import("std");
    if (pieces.len > A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
    for (pieces) |segment| {
        if (segment.start >= segment.end or segment.end > expected.len or
            (expected[segment.start] & 0xc0 == 0x80) or
            (segment.end < expected.len and expected[segment.end] & 0xc0 == 0x80) or
            !std.math.isFinite(segment.rect.x) or !std.math.isFinite(segment.rect.y) or
            !std.math.isFinite(segment.rect.width) or !std.math.isFinite(segment.rect.height) or
            segment.rect.width < 0 or segment.rect.height < 0) return error.InvalidAccessibilityGeometry;
    }
}

pub fn textGeometry(self: *Cx, raw: u32, expected: []const u8) !?[]A11yProps.TextGeometrySegment {
    return textGeometryClipped(self, raw, expected, null);
}

pub fn textGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: ?core.ComputedRect) !?[]A11yProps.TextGeometrySegment {
    const std = @import("std");
    const root = self.root orelse return null;
    const node = findNodeByElementRaw(root, raw) orelse return null;
    const props = node.behavior.interaction.a11y orelse return null;
    if (props.hidden or props.secure) return null;
    const editable = props.editable_text orelse return null;
    const query = editable.geometry_segments orelse return null;
    if (!std.mem.eql(u8, props.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    const polygon_geometry = @import("a11y_geometry.zig");
    var state = try buildTextClip(self, node, viewport);
    defer state.clip.deinit(self.allocator);
    if (state.empty) return try self.allocator.alloc(A11yProps.TextGeometrySegment, 0);
    const world = state.world;
    const has_clip = state.has_clip;
    const clip = &state.clip;
    const raw_origin = node.globalRect();
    const owned = try query(editable.context, self.allocator);
    errdefer self.allocator.free(owned);
    if (owned.len > A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
    try validateTextGeometry(expected, owned);
    var count: usize = 0;
    var piece_polygon: polygon_geometry.Polygon = .{};
    defer piece_polygon.deinit(self.allocator);
    for (owned) |segment| {
        const r = segment.rect;
        const quad = try polygon_geometry.rectangle(.{ .x = r.x - raw_origin.x, .y = r.y - raw_origin.y, .w = r.width, .h = r.height }, world);
        try piece_polygon.set(self.allocator, &quad);
        if (has_clip) try piece_polygon.intersect(self.allocator, clip.points.items);
        if (try piece_polygon.bounds()) |visible| {
            owned[count] = .{ .start = segment.start, .end = segment.end, .rect = .{ .x = visible.x, .y = visible.y, .width = visible.w, .height = visible.h } };
            count += 1;
        }
    }
    return try self.allocator.realloc(owned, count);
}

fn validateTextRows(expected: []const u8, rows: []const A11yProps.TextRowGeometry) !void {
    const std = @import("std");
    if (rows.len > A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
    for (rows, 0..) |row, index| {
        const r = row.rect;
        if (row.start > row.end or row.end > expected.len or
            (index > 0 and row.start < rows[index - 1].end) or
            (row.start < expected.len and expected[row.start] & 0xc0 == 0x80) or
            (row.end < expected.len and expected[row.end] & 0xc0 == 0x80) or
            !std.math.isFinite(r.x) or !std.math.isFinite(r.y) or
            !std.math.isFinite(r.width) or !std.math.isFinite(r.height) or
            r.width < 0 or r.height <= 0) return error.InvalidAccessibilityGeometry;
    }
}

pub fn textRowGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: core.ComputedRect) !?[]A11yProps.TextRowGeometry {
    const std = @import("std");
    const root = self.root orelse return null;
    const node = findNodeByElementRaw(root, raw) orelse return null;
    const props = node.behavior.interaction.a11y orelse return null;
    if (props.hidden or props.secure) return null;
    const editable = props.editable_text orelse return null;
    const query = editable.row_geometry orelse return null;
    if (!std.mem.eql(u8, props.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    var state = try buildTextClip(self, node, viewport);
    defer state.clip.deinit(self.allocator);
    if (state.empty) return try self.allocator.alloc(A11yProps.TextRowGeometry, 0);
    const owned = try query(editable.context, self.allocator);
    errdefer self.allocator.free(owned);
    if (owned.len > A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
    try validateTextRows(expected, owned);
    const current = node.behavior.interaction.a11y orelse return error.AccessibilityTextChanged;
    if (current.hidden or current.secure or !std.mem.eql(u8, current.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    const polygon = @import("a11y_geometry.zig");
    const origin = node.globalRect();
    var piece_polygon: polygon.Polygon = .{};
    defer piece_polygon.deinit(self.allocator);
    var count: usize = 0;
    for (owned) |row| {
        const r = row.rect;
        const quad = try polygon.rectangle(.{ .x = r.x - origin.x, .y = r.y - origin.y, .w = r.width, .h = r.height }, state.world);
        try piece_polygon.set(self.allocator, &quad);
        if (state.has_clip) try piece_polygon.intersect(self.allocator, state.clip.points.items);
        if (try piece_polygon.bounds()) |visible| {
            owned[count] = .{ .start = row.start, .end = row.end, .rect = .{ .x = visible.x, .y = visible.y, .width = visible.w, .height = visible.h } };
            count += 1;
        }
    }
    return try self.allocator.realloc(owned, count);
}

pub fn textCaretGeometryClipped(self: *Cx, raw: u32, expected: []const u8, viewport: core.ComputedRect) !?[]A11yProps.TextCaretSegment {
    const candidates = (try collectCaretCandidates(self, raw, expected, viewport, false)) orelse return null;
    defer self.allocator.free(candidates);
    const output = try self.allocator.alloc(A11yProps.TextCaretSegment, candidates.len);
    for (candidates, output) |candidate, *segment| {
        const visible = candidate.visible.?;
        segment.* = .{ .offset = candidate.offset, .first = visible.first, .last = visible.last, .downstream = candidate.downstream };
    }
    return output;
}

pub fn textCaretCandidates(self: *Cx, raw: u32, expected: []const u8, viewport: core.ComputedRect) !?[]A11yProps.TextCaretCandidate {
    return collectCaretCandidates(self, raw, expected, viewport, true);
}

fn collectCaretCandidates(self: *Cx, raw: u32, expected: []const u8, viewport: core.ComputedRect, include_text_edges: bool) !?[]A11yProps.TextCaretCandidate {
    const std = @import("std");
    const root = self.root orelse return null;
    const node = findNodeByElementRaw(root, raw) orelse return null;
    const props = node.behavior.interaction.a11y orelse return null;
    if (props.hidden or props.secure) return null;
    const editable = props.editable_text orelse return null;
    const query = editable.caret_geometry orelse return null;
    if (!std.mem.eql(u8, props.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    var state = try buildTextClip(self, node, viewport);
    defer state.clip.deinit(self.allocator);
    if (state.empty) return try self.allocator.alloc(A11yProps.TextCaretCandidate, 0);
    const carets = try query(editable.context, self.allocator);
    defer self.allocator.free(carets);
    if (carets.len > A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
    for (carets) |caret| {
        const r = caret.rect;
        if (caret.offset > expected.len or (caret.offset < expected.len and expected[caret.offset] & 0xc0 == 0x80) or
            !std.math.isFinite(r.x) or !std.math.isFinite(r.y) or !std.math.isFinite(r.height) or
            r.width != 0 or r.height <= 0) return error.InvalidAccessibilityGeometry;
    }
    const polygon = @import("a11y_geometry.zig");
    const origin = node.globalRect();
    const visible_neighbors = try self.allocator.alloc(bool, carets.len);
    defer self.allocator.free(visible_neighbors);
    @memset(visible_neighbors, false);
    if (include_text_edges and expected.len > 0) {
        const geometry_query = editable.geometry_segments orelse return error.AccessibilityLayoutPending;
        var pieces = try geometry_query(editable.context, self.allocator);
        defer self.allocator.free(pieces);
        try validateTextGeometry(expected, pieces);
        if (editable.row_geometry) |row_query| {
            const rows = try row_query(editable.context, self.allocator);
            defer self.allocator.free(rows);
            try validateTextRows(expected, rows);
            var blank_count: usize = 0;
            for (rows) |row| {
                var blank = true;
                for (expected[row.start..row.end]) |char| if (char != '\r' and char != '\n') {
                    blank = false;
                    break;
                };
                if (blank) blank_count += 1;
            }
            const original_count = pieces.len;
            pieces = try self.allocator.realloc(pieces, original_count + blank_count);
            var next = original_count;
            for (rows) |row| {
                var blank = true;
                for (expected[row.start..row.end]) |char| if (char != '\r' and char != '\n') {
                    blank = false;
                    break;
                };
                if (blank) {
                    pieces[next] = .{ .start = row.start, .end = row.end, .rect = row.rect };
                    next += 1;
                }
            }
        }
        const CaretIndex = struct { offset: u32, index: usize };
        const indices = try self.allocator.alloc(CaretIndex, carets.len);
        defer self.allocator.free(indices);
        for (carets, indices, 0..) |caret, *index, i| index.* = .{ .offset = caret.offset, .index = i };
        std.mem.sort(CaretIndex, indices, {}, struct {
            fn less(_: void, a: CaretIndex, b: CaretIndex) bool {
                return a.offset < b.offset;
            }
        }.less);
        var piece_polygon: polygon.Polygon = .{};
        defer piece_polygon.deinit(self.allocator);
        var associations: usize = 0;
        for (pieces) |piece| {
            const r = piece.rect;
            const quad = try polygon.rectangle(.{ .x = r.x - origin.x, .y = r.y - origin.y, .w = r.width, .h = r.height }, state.world);
            try piece_polygon.set(self.allocator, &quad);
            if (state.has_clip) try piece_polygon.intersect(self.allocator, state.clip.points.items);
            if (try piece_polygon.bounds() == null) continue;
            var lo: usize = 0;
            var hi = indices.len;
            while (lo < hi) {
                const middle = lo + (hi - lo) / 2;
                if (indices[middle].offset < piece.start) lo = middle + 1 else hi = middle;
            }
            while (lo < indices.len and indices[lo].offset <= piece.end) : (lo += 1) {
                // Bound pathological overlapping provider spans without
                // letting optional geometry monopolize a publication frame.
                if (associations == A11yProps.max_text_geometry_segments * 8) return error.AccessibilityGeometryQuota;
                associations += 1;
                const index = indices[lo].index;
                const caret = carets[index].rect;
                const right = r.x + r.width;
                const tolerance = 4 * std.math.floatEps(f32) * @max(@as(f32, 1), @abs(caret.x), @abs(r.x), @abs(right));
                // Match in the original layout coordinates: wrap affinities
                // can share a logical offset while belonging to different
                // rows. Rotation/reflection must not mix those rows via AABBs.
                if (caret.x >= r.x - tolerance and caret.x <= right + tolerance and
                    caret.y < r.y + r.height and caret.y + caret.height > r.y)
                    visible_neighbors[index] = true;
            }
        }
    }
    const current_props = node.behavior.interaction.a11y orelse return error.AccessibilityTextChanged;
    if (current_props.hidden or current_props.secure or !std.mem.eql(u8, current_props.value_text orelse "", expected)) return error.AccessibilityTextChanged;
    var output = try self.allocator.alloc(A11yProps.TextCaretCandidate, carets.len);
    errdefer self.allocator.free(output);
    var count: usize = 0;
    for (carets, 0..) |caret, index| {
        const r = caret.rect;
        const first = state.world.applyPoint(r.x - origin.x, r.y - origin.y);
        const last = state.world.applyPoint(r.x - origin.x, r.y + r.height - origin.y);
        const line = try polygon.clipSegment(.{ .x = first.x, .y = first.y }, .{ .x = last.x, .y = last.y }, state.clip.points.items);
        if (line == null and !visible_neighbors[index]) continue;
        output[count] = .{
            .offset = caret.offset,
            .first = first,
            .last = last,
            .visible = if (line) |clipped| .{
                .first = .{ .x = @floatCast(clipped[0].x), .y = @floatCast(clipped[0].y) },
                .last = .{ .x = @floatCast(clipped[1].x), .y = @floatCast(clipped[1].y) },
            } else null,
            .downstream = caret.downstream,
        };
        count += 1;
    }
    return try self.allocator.realloc(output, count);
}

pub fn scrollTextRange(self: *Cx, raw: u32, start: u32, end: u32, align_top: bool) bool {
    const root = self.root orelse return false;
    const node = findNodeByElementRaw(root, raw) orelse return false;
    const props = node.behavior.interaction.a11y orelse return false;
    if (props.disabled or props.hidden or props.secure or !self.overlay_stack.allowsSemanticAction(node)) return false;
    const editable = props.editable_text orelse return false;
    const scroll = editable.scroll_into_view orelse return false;
    if (!scroll(editable.context, start, end, align_top)) return false;
    node.markRenderDirty();
    self.needs_redraw = true;
    return true;
}

test "a11y readonly text permits selection but refuses value and disabled actions" {
    const t = @import("std").testing;
    const Fixture = struct {
        calls: usize = 0,
        fn select(ctx: *anyopaque, start: u32, end: u32) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return start == 0 and end == 3;
        }
        fn value(_: *anyopaque, _: []const u8) bool {
            @panic("readonly value setter called");
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.behavior.interaction.a11y = .{ .role = .textbox, .readonly = true, .value_text = "中A", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .set_value = Fixture.value,
    } };
    const id = AXId.node(core.ElementId.fromRaw(node.element_id_raw));
    try t.expect(cxA11ySetSelection(cx, id, 0, 3));
    try t.expect(!cxA11ySetTextValue(cx, id, "changed"));
    node.behavior.interaction.a11y.?.disabled = true;
    try t.expect(!cxA11ySetSelection(cx, id, 0, 3));
    node.behavior.interaction.a11y.?.disabled = false;
    node.behavior.interaction.a11y.?.hidden = true;
    try t.expect(!cxA11ySetSelection(cx, id, 0, 3));
    try t.expectEqual(@as(usize, 1), fixture.calls);
}

test "a11y text value preserves focus and refuses protected controls" {
    const t = @import("std").testing;
    const Fixture = struct {
        calls: usize = 0,
        fn set(ctx: *anyopaque, value: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return @import("std").mem.eql(u8, value, "中文 🧪");
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const target = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, target);
    root.behavior.interaction.focusable = true;
    target.behavior.interaction.focusable = true;
    target.behavior.interaction.a11y = .{ .role = .textbox, .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .set_value = Fixture.set,
    } };
    try t.expect(cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "中文 🧪"));
    try t.expect(cx.focus_manager.getFocused() == null);
    cx.setFocus(root);
    try t.expect(cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "中文 🧪"));
    try t.expect(cx.focus_manager.getFocused() == root);
    try t.expect(!cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "rejected"));
    try t.expect(cx.focus_manager.getFocused() == root);
    target.behavior.interaction.a11y.?.readonly = true;
    try t.expect(!cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "中文 🧪"));
    target.behavior.interaction.a11y.?.readonly = false;
    target.behavior.interaction.a11y.?.disabled = true;
    try t.expect(!cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "中文 🧪"));
    target.behavior.interaction.a11y.?.disabled = false;
    target.behavior.interaction.a11y.?.hidden = true;
    try t.expect(!cxA11ySetTextValue(cx, AXId.node(core.ElementId.fromRaw(target.element_id_raw)), "中文 🧪"));
    try t.expectEqual(@as(usize, 3), fixture.calls);
    try t.expect(cx.focus_manager.getFocused() == root);
}

test "a11yTextGeometry owns results and fences stale secure hidden and malformed data" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        calls: usize = 0,
        segment: A11yProps.TextGeometrySegment = .{ .start = 1, .end = 4, .rect = .{ .x = 10, .y = 20, .width = 30, .height = 16 } },
        fn query(ctx: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextGeometrySegment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return allocator.dupe(A11yProps.TextGeometrySegment, &.{self.segment});
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "A中B", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .geometry_segments = Fixture.query,
    } };
    const owned = (try cx.a11yTextGeometry(node.element_id_raw, "A中B")).?;
    defer t.allocator.free(owned);
    try t.expectEqualDeep(fixture.segment, owned[0]);
    fixture.segment.rect.x = 99;
    try t.expectEqual(@as(f32, 10), owned[0].rect.x);
    try t.expectError(error.AccessibilityTextChanged, cx.a11yTextGeometry(node.element_id_raw, "other"));
    try t.expectEqual(@as(usize, 1), fixture.calls);
    node.behavior.interaction.a11y.?.secure = true;
    try t.expect(try cx.a11yTextGeometry(node.element_id_raw, "A中B") == null);
    node.behavior.interaction.a11y.?.secure = false;
    node.behavior.interaction.a11y.?.hidden = true;
    try t.expect(try cx.a11yTextGeometry(node.element_id_raw, "A中B") == null);
    try t.expectEqual(@as(usize, 1), fixture.calls);
    node.behavior.interaction.a11y.?.hidden = false;
    node.behavior.interaction.a11y.?.disabled = true;
    node.behavior.interaction.a11y.?.readonly = true;
    const readable = (try cx.a11yTextGeometry(node.element_id_raw, "A中B")).?;
    defer t.allocator.free(readable);
    fixture.segment.start = 2;
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextGeometry(node.element_id_raw, "A中B"));
    fixture.segment.start = 1;
    fixture.segment.rect.width = std.math.nan(f32);
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextGeometry(node.element_id_raw, "A中B"));
    fixture.segment.rect.width = 30;
    fixture.segment.end = 100;
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextGeometry(node.element_id_raw, "A中B"));
}

test "a11yTextGeometry intersects nested paint rectangles borders and external clips" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        calls: usize = 0,
        fn query(ctx: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextGeometrySegment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return allocator.dupe(A11yProps.TextGeometrySegment, &.{
                .{ .start = 0, .end = 1, .rect = .{ .x = 10, .y = 20, .width = 20, .height = 20 } },
                .{ .start = 1, .end = 2, .rect = .{ .x = 40, .y = 30, .width = 20, .height = 10 } },
                .{ .start = 2, .end = 3, .rect = .{ .x = 60, .y = 30, .width = 10, .height = 10 } },
            });
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const root = try core.box(cx, .{ .overflow_hidden = true }, .{});
    cx.root = root;
    root.setLayoutRect(.{ .x = 10, .y = 20, .w = 100, .h = 100 });
    const parent = try core.box(cx, .{ .overflow_hidden = true, .border = .{ .width = 2, .color = core.Color.WHITE } }, .{});
    try root.appendChild(t.allocator, parent);
    parent.setLayoutRect(.{ .x = 5, .y = 5, .w = 30, .h = 30 });
    const node = try core.box(cx, .{}, .{});
    try parent.appendChild(t.allocator, node);
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "abc", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .geometry_segments = Fixture.query,
    } };
    const bordered = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(bordered);
    try t.expectEqual(@as(usize, 2), bordered.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 17, .y = 27, .width = 13, .height = 13 }, bordered[0].rect);
    try t.expectEqualDeep(core.A11yRect{ .x = 40, .y = 30, .width = 3, .height = 10 }, bordered[1].rect);
    try t.expectEqual(@as(u32, 1), bordered[1].start);
    cx.setNodeExternalClipRect(parent.id, .{ 20, 30, 15, 15 });
    const external = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(external);
    try t.expectEqual(@as(usize, 1), external.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 20, .y = 30, .width = 10, .height = 10 }, external[0].rect);
    const before_empty = fixture.calls;
    cx.setNodeExternalClipRect(root.id, .{ 50, 30, 10, 10 });
    const outside = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(outside);
    try t.expectEqual(@as(usize, 0), outside.len);
    try t.expectEqual(before_empty, fixture.calls);
    cx.setNodeExternalClipRect(root.id, null);
    cx.setNodeExternalClipRect(parent.id, null);
    parent.style.border.color = core.Color.TRANSPARENT;
    const transparent_border = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(transparent_border);
    try t.expectEqualDeep(core.A11yRect{ .x = 15, .y = 25, .width = 15, .height = 15 }, transparent_border[0].rect);
    parent.style.border.color = core.Color.WHITE;
    parent.style.ensureExtPanic(t.allocator).glass = .{ .backdrop_blur = 1 };
    const glass = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(glass);
    try t.expectEqualDeep(transparent_border, glass);
    parent.style.ensureExtPanic(t.allocator).clip_shape = .none;
    const no_clip = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(no_clip);
    try t.expectEqual(@as(usize, 3), no_clip.len);
    try t.expectEqual(@as(f32, 10), no_clip[0].rect.x);
    parent.style.ensureExtPanic(t.allocator).scale_x = 2;
    const scaled = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(scaled);
    try t.expectEqual(@as(usize, 3), scaled.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 10, .y = 20, .width = 20, .height = 20 }, scaled[0].rect);
    try t.expectEqualDeep(core.A11yRect{ .x = 50, .y = 30, .width = 40, .height = 10 }, scaled[1].rect);
    try t.expectEqualDeep(core.A11yRect{ .x = 90, .y = 30, .width = 20, .height = 10 }, scaled[2].rect);
    parent.style.ensureExtPanic(t.allocator).clip_shape = .rect;
    const scaled_clip = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(scaled_clip);
    try t.expectEqual(@as(usize, 2), scaled_clip.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 10, .y = 25, .width = 20, .height = 15 }, scaled_clip[0].rect);
    try t.expectEqualDeep(core.A11yRect{ .x = 50, .y = 30, .width = 10, .height = 10 }, scaled_clip[1].rect);
    cx.setNodeExternalClipRect(parent.id, .{ 20, 30, 15, 15 });
    const scaled_external = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(scaled_external);
    try t.expectEqual(@as(usize, 1), scaled_external.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 20, .y = 30, .width = 10, .height = 10 }, scaled_external[0].rect);
    cx.setNodeExternalClipRect(parent.id, null);
    parent.style.ensureExtPanic(t.allocator).scale_x = -2;
    const reflected = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(reflected);
    try t.expectEqual(@as(usize, 1), reflected.len);
    try t.expectEqualDeep(core.A11yRect{ .x = 30, .y = 25, .width = 30, .height = 15 }, reflected[0].rect);
    const calls_before_zero = fixture.calls;
    parent.style.ensureExtPanic(t.allocator).scale_x = 0;
    const collapsed = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(collapsed);
    try t.expectEqual(@as(usize, 0), collapsed.len);
    try t.expectEqual(calls_before_zero, fixture.calls);
    parent.style.ensureExtPanic(t.allocator).scale_x = std.math.nan(f32);
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextGeometry(node.element_id_raw, "abc"));
    parent.style.ensureExtPanic(t.allocator).scale_x = 2;
    parent.setOpacityRaw(0);
    const invisible = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(invisible);
    try t.expectEqual(@as(usize, 0), invisible.len);
    parent.setOpacityRaw(1);
    parent.style.ensureExtPanic(t.allocator).scale_x = 1;
    parent.style.ensureExtPanic(t.allocator).rotate = 0.1;
    const rotated = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(rotated);
    try t.expect(rotated.len > 0);
    parent.style.ensureExtPanic(t.allocator).rotate = std.math.pi / 4.0;
    const calls_before_corner = fixture.calls;
    cx.setNodeExternalClipRect(parent.id, .{ 10, 20, 2, 2 });
    const corner = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(corner);
    try t.expectEqual(@as(usize, 0), corner.len);
    try t.expectEqual(calls_before_corner, fixture.calls);
    cx.setNodeExternalClipRect(parent.id, .{ 29, 39, 2, 2 });
    const triangle = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(triangle);
    try t.expectEqual(@as(usize, 1), triangle.len);
    try t.expectEqual(@as(u32, 0), triangle[0].start);
    try t.expectEqual(@as(u32, 1), triangle[0].end);
    try t.expectApproxEqAbs(@as(f32, 29), triangle[0].rect.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 39), triangle[0].rect.y, 0.001);
    try t.expectApproxEqAbs(@as(f32, 2), triangle[0].rect.width, 0.001);
    try t.expectApproxEqAbs(@as(f32, 1), triangle[0].rect.height, 0.001);
    const calls_before_thin = fixture.calls;
    cx.setNodeExternalClipRect(parent.id, .{ 29, 39, 0.05, 2 });
    const thin = (try cx.a11yTextGeometry(node.element_id_raw, "abc")).?;
    defer t.allocator.free(thin);
    try t.expectEqual(@as(usize, 0), thin.len);
    try t.expectEqual(calls_before_thin, fixture.calls);
    cx.setNodeExternalClipRect(parent.id, null);
    const viewport_calls = fixture.calls;
    const viewport_corner = (try cx.a11yTextGeometryClipped(node.element_id_raw, "abc", .{ .x = 10, .y = 20, .w = 2, .h = 2 })).?;
    defer t.allocator.free(viewport_corner);
    try t.expectEqual(@as(usize, 0), viewport_corner.len);
    try t.expectEqual(viewport_calls, fixture.calls);
    const viewport_triangle = (try cx.a11yTextGeometryClipped(node.element_id_raw, "abc", .{ .x = 29, .y = 39, .w = 2, .h = 2 })).?;
    defer t.allocator.free(viewport_triangle);
    try t.expectEqual(@as(usize, 1), viewport_triangle.len);
    try t.expectApproxEqAbs(@as(f32, 29), viewport_triangle[0].rect.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 39), viewport_triangle[0].rect.y, 0.001);
    try t.expectApproxEqAbs(@as(f32, 2), viewport_triangle[0].rect.width, 0.001);
    try t.expectApproxEqAbs(@as(f32, 1), viewport_triangle[0].rect.height, 0.001);
    const zero_viewport_calls = fixture.calls;
    const zero_viewport = (try cx.a11yTextGeometryClipped(node.element_id_raw, "abc", .{ .x = 0, .y = 0, .w = 0, .h = 100 })).?;
    defer t.allocator.free(zero_viewport);
    try t.expectEqual(@as(usize, 0), zero_viewport.len);
    try t.expectEqual(zero_viewport_calls, fixture.calls);
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextGeometryClipped(node.element_id_raw, "abc", .{ .x = 0, .y = 0, .w = std.math.nan(f32), .h = 100 }));
}

test "a11y caret line query preserves affine direction clips and guards" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        calls: usize = 0,
        offset: u32 = 1,
        fn query(ctx: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextCaretGeometry {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return allocator.dupe(A11yProps.TextCaretGeometry, &.{.{ .offset = self.offset, .rect = .{ .x = 20, .y = 20, .width = 0, .height = 20 }, .downstream = false }});
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "A中", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .caret_geometry = Fixture.query,
    } };
    const ext = try node.style.ensureExtFallible(cx.allocator);
    ext.transform_origin = core_types.TransformOrigin.topLeft();
    ext.rotate = std.math.pi / 2.0;
    const result = (try cx.a11yTextCaretGeometryClipped(node.element_id_raw, "A中", .{ .x = -35, .y = 15, .w = 10, .h = 10 })).?;
    defer t.allocator.free(result);
    try t.expectEqual(@as(usize, 1), result.len);
    try t.expectApproxEqAbs(@as(f32, -25), result[0].first.x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, -35), result[0].last.x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 20), result[0].first.y, 0.0001);
    try t.expectEqual(@as(u32, 1), result[0].offset);
    try t.expect(!result[0].downstream);
    ext.scale_x = -1;
    const reflected = (try cx.a11yTextCaretGeometryClipped(node.element_id_raw, "A中", .{ .x = 25, .y = 15, .w = 10, .h = 10 })).?;
    defer t.allocator.free(reflected);
    try t.expectEqual(@as(usize, 1), reflected.len);
    try t.expectApproxEqAbs(@as(f32, 25), reflected[0].first.x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 35), reflected[0].last.x, 0.0001);
    try t.expect(!reflected[0].downstream);
    try t.expectError(error.AccessibilityTextChanged, cx.a11yTextCaretGeometryClipped(node.element_id_raw, "old", .{ .x = 0, .y = 0, .w = 100, .h = 100 }));
    fixture.offset = 2;
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextCaretGeometryClipped(node.element_id_raw, "A中", .{ .x = -100, .y = -100, .w = 200, .h = 200 }));
    const calls = fixture.calls;
    const empty = (try cx.a11yTextCaretGeometryClipped(node.element_id_raw, "A中", .{ .x = 0, .y = 0, .w = 0, .h = 100 })).?;
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
    try t.expectEqual(calls, fixture.calls);
}

test "a11y caret candidates retain both edges of partly visible Unicode" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        pending: bool = false,
        fn carets(_: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextCaretGeometry {
            return allocator.dupe(A11yProps.TextCaretGeometry, &.{
                .{ .offset = 0, .rect = .{ .x = 10, .y = 20, .width = 0, .height = 20 }, .downstream = false },
                .{ .offset = 4, .rect = .{ .x = 30, .y = 20, .width = 0, .height = 20 }, .downstream = true },
            });
        }
        fn geometry(ctx: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextGeometrySegment {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.pending) return error.AccessibilityLayoutPending;
            return allocator.dupe(A11yProps.TextGeometrySegment, &.{.{ .start = 0, .end = 4, .rect = .{ .x = 10, .y = 20, .width = 20, .height = 20 } }});
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 });
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "😀", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .caret_geometry = Fixture.carets,
        .geometry_segments = Fixture.geometry,
    } };
    const viewport = core.ComputedRect.init(18, 25, 4, 10);
    const candidates = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀", viewport)).?;
    defer t.allocator.free(candidates);
    try t.expectEqual(@as(usize, 2), candidates.len);
    try t.expectEqual(@as(u32, 0), candidates[0].offset);
    try t.expectEqual(@as(u32, 4), candidates[1].offset);
    try t.expectEqual(@as(f32, 10), candidates[0].first.x);
    try t.expectEqual(@as(f32, 30), candidates[1].first.x);
    try t.expectEqual(@as(f32, 20), candidates[0].first.y);
    try t.expectEqual(@as(f32, 40), candidates[0].last.y);
    try t.expect(candidates[0].visible == null and candidates[1].visible == null);
    try t.expect(!candidates[0].downstream and candidates[1].downstream);
    const clipped = (try cx.a11yTextCaretGeometryClipped(node.element_id_raw, "😀", viewport)).?;
    defer t.allocator.free(clipped);
    try t.expectEqual(@as(usize, 0), clipped.len);
    const excluded = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀", .{ .x = 18, .y = 50, .w = 4, .h = 10 })).?;
    defer t.allocator.free(excluded);
    try t.expectEqual(@as(usize, 0), excluded.len);
    fixture.pending = true;
    try t.expectError(error.AccessibilityLayoutPending, cx.a11yTextCaretCandidates(node.element_id_raw, "😀", viewport));
}

test "a11y caret candidates distinguish clipped rows at duplicate wrap offsets" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        dense: bool = false,
        fn carets(context: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextCaretGeometry {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.dense) {
                const result = try allocator.alloc(A11yProps.TextCaretGeometry, 1000);
                @memset(result, .{ .offset = 4, .rect = .{ .x = 10, .y = 40, .width = 0, .height = 20 }, .downstream = true });
                return result;
            }
            return allocator.dupe(A11yProps.TextCaretGeometry, &.{
                .{ .offset = 0, .rect = .{ .x = 10, .y = 20, .width = 0, .height = 20 }, .downstream = false },
                .{ .offset = 4, .rect = .{ .x = 30, .y = 20, .width = 0, .height = 20 }, .downstream = false },
                .{ .offset = 4, .rect = .{ .x = 10, .y = 40, .width = 0, .height = 20 }, .downstream = true },
                .{ .offset = 8, .rect = .{ .x = 30, .y = 40, .width = 0, .height = 20 }, .downstream = true },
            });
        }
        fn geometry(context: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextGeometrySegment {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.dense) {
                const result = try allocator.alloc(A11yProps.TextGeometrySegment, 1000);
                @memset(result, .{ .start = 4, .end = 8, .rect = .{ .x = 10, .y = 40, .width = 20, .height = 20 } });
                return result;
            }
            return allocator.dupe(A11yProps.TextGeometrySegment, &.{
                .{ .start = 0, .end = 4, .rect = .{ .x = 10, .y = 20, .width = 20, .height = 20 } },
                .{ .start = 4, .end = 8, .rect = .{ .x = 10, .y = 40, .width = 20, .height = 20 } },
            });
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 80 });
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "😀😀", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .caret_geometry = Fixture.carets,
        .geometry_segments = Fixture.geometry,
    } };
    const candidates = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀😀", .{ .x = 18, .y = 45, .w = 4, .h = 10 })).?;
    defer t.allocator.free(candidates);
    try t.expectEqual(@as(usize, 2), candidates.len);
    try t.expectEqual(@as(u32, 4), candidates[0].offset);
    try t.expectEqual(@as(u32, 8), candidates[1].offset);
    for (candidates) |c| {
        try t.expectEqual(@as(f32, 40), c.first.y);
        try t.expect(c.visible == null and c.downstream);
    }
    const ext = try node.style.ensureExtFallible(cx.allocator);
    ext.transform_origin = core_types.TransformOrigin.topLeft();
    ext.rotate = std.math.pi / 2.0;
    const rotated = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀😀", .{ .x = -55, .y = 18, .w = 10, .h = 4 })).?;
    defer t.allocator.free(rotated);
    try t.expectEqual(@as(usize, 2), rotated.len);
    for (rotated) |c| {
        try t.expectApproxEqAbs(@as(f32, -40), c.first.x, 0.0001);
        try t.expectApproxEqAbs(@as(f32, -60), c.last.x, 0.0001);
        try t.expect(c.visible == null and c.downstream);
    }
    ext.scale_x = -1;
    const reflected = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀😀", .{ .x = 45, .y = 18, .w = 10, .h = 4 })).?;
    defer t.allocator.free(reflected);
    try t.expectEqual(@as(usize, 2), reflected.len);
    for (reflected) |c| {
        try t.expectApproxEqAbs(@as(f32, 40), c.first.x, 0.0001);
        try t.expectApproxEqAbs(@as(f32, 60), c.last.x, 0.0001);
        try t.expect(c.visible == null and c.downstream);
    }
    fixture.dense = true;
    try t.expectError(error.AccessibilityGeometryQuota, cx.a11yTextCaretCandidates(node.element_id_raw, "😀😀", .{ .x = 45, .y = 18, .w = 10, .h = 4 }));
}

test "a11y row geometry retains blank and terminal rows through affine clips" {
    const std = @import("std");
    const t = std.testing;
    const Fixture = struct {
        pending: bool = false,
        invalid: bool = false,
        calls: usize = 0,
        fn rows(context: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextRowGeometry {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.pending) return error.AccessibilityLayoutPending;
            return allocator.dupe(A11yProps.TextRowGeometry, &.{
                .{ .start = if (self.invalid) 1 else 0, .end = 5, .rect = .{ .x = 10, .y = 20, .width = 100, .height = 20 } },
                .{ .start = 5, .end = 6, .rect = .{ .x = 10, .y = 40, .width = 100, .height = 20 } },
                .{ .start = 6, .end = 6, .rect = .{ .x = 10, .y = 60, .width = 100, .height = 20 } },
            });
        }
        fn carets(_: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextCaretGeometry {
            return allocator.dupe(A11yProps.TextCaretGeometry, &.{
                .{ .offset = 5, .rect = .{ .x = 10, .y = 40, .width = 0, .height = 20 }, .downstream = true },
                .{ .offset = 6, .rect = .{ .x = 10, .y = 60, .width = 0, .height = 20 }, .downstream = true },
            });
        }
        fn glyphs(_: *anyopaque, allocator: std.mem.Allocator) ![]A11yProps.TextGeometrySegment {
            return allocator.alloc(A11yProps.TextGeometrySegment, 0);
        }
        fn select(_: *anyopaque, _: u32, _: u32) bool {
            return false;
        }
    };
    var fixture: Fixture = .{};
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 100 });
    node.behavior.interaction.a11y = .{ .role = .textbox, .value_text = "😀\n\n", .editable_text = .{
        .context = &fixture,
        .selection_start = 0,
        .selection_end = 0,
        .caret = 0,
        .set_selection = Fixture.select,
        .row_geometry = Fixture.rows,
        .caret_geometry = Fixture.carets,
        .geometry_segments = Fixture.glyphs,
    } };
    const blank = (try cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = 50, .y = 45, .w = 1, .h = 10 })).?;
    defer t.allocator.free(blank);
    try t.expectEqual(@as(usize, 1), blank.len);
    try t.expectEqual(@as(u32, 5), blank[0].start);
    try t.expectEqual(@as(u32, 6), blank[0].end);
    try t.expectEqual(@as(f32, 50), blank[0].rect.x);
    try t.expectEqual(@as(f32, 1), blank[0].rect.width);
    const blank_caret = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀\n\n", .{ .x = 50, .y = 45, .w = 1, .h = 10 })).?;
    defer t.allocator.free(blank_caret);
    try t.expectEqual(@as(usize, 1), blank_caret.len);
    try t.expectEqual(@as(u32, 5), blank_caret[0].offset);
    try t.expectEqual(@as(f32, 10), blank_caret[0].first.x);
    try t.expect(blank_caret[0].visible == null);
    const terminal = (try cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = 50, .y = 65, .w = 1, .h = 10 })).?;
    defer t.allocator.free(terminal);
    try t.expectEqual(@as(usize, 1), terminal.len);
    try t.expectEqual(@as(u32, 6), terminal[0].start);
    try t.expectEqual(terminal[0].start, terminal[0].end);
    const ext = try node.style.ensureExtFallible(cx.allocator);
    ext.transform_origin = core_types.TransformOrigin.topLeft();
    ext.rotate = std.math.pi / 2.0;
    const rotated = (try cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = -55, .y = 50, .w = 10, .h = 1 })).?;
    defer t.allocator.free(rotated);
    try t.expectEqual(@as(usize, 1), rotated.len);
    try t.expectEqual(@as(u32, 5), rotated[0].start);
    try t.expectApproxEqAbs(@as(f32, -55), rotated[0].rect.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 10), rotated[0].rect.width, 0.001);
    const rotated_caret = (try cx.a11yTextCaretCandidates(node.element_id_raw, "😀\n\n", .{ .x = -55, .y = 50, .w = 10, .h = 1 })).?;
    defer t.allocator.free(rotated_caret);
    try t.expectEqual(@as(usize, 1), rotated_caret.len);
    try t.expectEqual(@as(u32, 5), rotated_caret[0].offset);
    try t.expectApproxEqAbs(@as(f32, -40), rotated_caret[0].first.x, 0.001);
    try t.expect(rotated_caret[0].visible == null);
    const calls = fixture.calls;
    const empty = (try cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = 0, .y = 0, .w = 0, .h = 100 })).?;
    defer t.allocator.free(empty);
    try t.expect(empty.len == 0 and fixture.calls == calls);
    fixture.invalid = true;
    try t.expectError(error.InvalidAccessibilityGeometry, cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = -100, .y = 0, .w = 100, .h = 120 }));
    fixture.invalid = false;
    fixture.pending = true;
    try t.expectError(error.AccessibilityLayoutPending, cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = -100, .y = 0, .w = 100, .h = 120 }));
    try t.expectError(error.AccessibilityTextChanged, cx.a11yTextRowGeometryClipped(node.element_id_raw, "old", .{ .x = 0, .y = 0, .w = 120, .h = 100 }));
    node.behavior.interaction.a11y.?.secure = true;
    try t.expect((try cx.a11yTextRowGeometryClipped(node.element_id_raw, "😀\n\n", .{ .x = 0, .y = 0, .w = 120, .h = 100 })) == null);
}
