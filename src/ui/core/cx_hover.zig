//! Stationary-pointer hover: hover follows the node under a pointer that does not move when the
//! scene under it changes (wheel/momentum/spring scroll, programmatic scroll, layout change,
//! mount/unmount, hit semantics).
//!
//! Native contract (measured with an AppKit probe, docs/UI_FRAMEWORK_CORE.md "Hover Under a
//! Stationary Pointer"): an NSScrollView scrolled under a stationary cursor sends mouseExited to
//! the row that left and mouseEntered to the row that arrived right after the bounds change; a
//! frame change without scrolling and a window moving away from the cursor are re-evaluated on
//! the next display cycle. Browsers
//! re-hit the pointer position after scroll/layout at the next frame and update :hover and
//! mouseover/mouseout without dispatching mousemove.
//!
//! Model: the committed hit scene carries `HitRuntime.sceneEpoch()`, advanced by every rebuild and
//! every hit-layer move (scroll offset).
//! Each hover resolution (pointer move, capture-release resync, this re-resolution) records the
//! epoch it was computed against. At the start of each rendered frame, if the epoch moved and
//! the pointer position is live, the pointer is hit-tested once against the committed scene (the
//! geometry the user is looking at) and hover transitions are dispatched as a pointer move to the
//! same point would, minus the mouse_move event. Unchanged scene = no hit test.
const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const HitResult = core.HitResult;
const cx_cursor = @import("cx_cursor.zig");
const cx_hit_target = @import("cx_hit_target.zig");

pub const HoverSync = struct {
    /// The platform reports the pointer over this window's visible content: set by every pointer
    /// event (backends deliver hover motion only while the pointer is over the content, or while a
    /// button sequence owns it), cleared by `pointer_left` (macOS content tracking-area exit or a
    /// window covering the pointer, Windows WM_MOUSELEAVE, Wayland wl_pointer.leave). Independent
    /// of activation: every platform keeps hover tracking in inactive windows (measured; see
    /// docs/UI_FRAMEWORK_CORE.md "Hover Under a Stationary Pointer").
    pointer_over_content: bool = false,
    /// A platform drag-and-drop session is over the window: the OS owns the pointer and sends no
    /// motion, so the last position is stale until the session ends.
    platform_drag_active: bool = false,
    /// `HitRuntime.sceneEpoch()` the current hover was resolved against.
    scene_epoch: u64 = 0,
    /// Diagnostics (tests, harness /stats): hit tests issued by re-resolution, and the
    /// re-resolutions that changed the hovered node.
    reconcile_hit_tests: u64 = 0,
    reconcile_changes: u64 = 0,
};

/// The last pointer position still describes where the pointer is: the platform delivered it,
/// has not reported a leave since, no OS drag session owns the pointer, and it lies inside the
/// content. Window activation is deliberately not part of it: inactive windows keep receiving
/// hover motion and leave notifications on macOS (activeAlways tracking areas, the option
/// AppKit's own hover controls use), Windows and Wayland, and wheel-scroll under the pointer.
pub fn pointerLive(self: *const Cx) bool {
    const sync = self.hover_sync;
    if (!self.cursor_state.pointer_valid or !sync.pointer_over_content or sync.platform_drag_active) return false;
    return self.mouse_x >= 0 and self.mouse_y >= 0 and
        self.mouse_x < self.viewport.width and self.mouse_y < self.viewport.height;
}

/// Hover is stale with respect to the committed scene and may be re-resolved now. Also feeds
/// `wantsFrame`: a scene committed outside a frame (event-time refresh) still gets its frame.
pub fn pending(self: *Cx) bool {
    if (self.root == null) return false;
    if (self.hover_sync.scene_epoch == self.interaction_index.sceneEpoch()) return false;
    if (!pointerLive(self)) return false;
    return self.dispatcher.hoverFollowsScene();
}

/// Record that hover was just resolved against the current committed scene.
pub fn noteResolved(self: *Cx) void {
    self.hover_sync.scene_epoch = self.interaction_index.sceneEpoch();
}

/// Hover target for a pointer hit, shared by pointer moves and re-resolution so both resolve
/// the same point identically.
///
/// Hysteresis: partial interaction rebuild has gaps in collecting new nodes between subtree
/// rebuilds (hit in several apps), so queries can intermittently MISS at valid coordinates. On
/// MISS, if the previous hovered node is still alive and geometrically still contains the
/// pointer, keep hover; otherwise the cursor flickers between pointer and default (seen near
/// file-tab close buttons). On a real leave the old node's rect no longer contains the pointer
/// and hover is cleared as usual.
pub fn hoverTargetForHit(self: *Cx, hit: ?HitResult, x: f32, y: f32) ?*Node {
    var raw = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
    if (raw == null) {
        if (self.hovered_handle) |h| {
            if (self.node_registry.resolve(h, &self.perf)) |prev| {
                const r = prev.rectFromWorldOrFallback();
                if (r.w > 0 and r.h > 0 and r.contains(x, y)) raw = prev;
            }
        }
    }
    return cx_hit_target.resolveInteractionTarget(raw);
}

/// Re-resolve hover under a stationary pointer if the committed scene changed since hover was
/// last resolved. Runs at the start of each rendered frame (cx_render.render) inside a host
/// entry, before the before-render tick, so callbacks behave like a pointer move delivered just
/// before the frame and their effects render in it. At most one hit test.
pub fn reconcile(self: *Cx) void {
    // The scene is being mutated; the outer refresh publishes the next usable scene.
    if (self.tick_depth > 0 or self.draining_deferred_frees) return;
    if (!pending(self)) return;
    noteResolved(self);
    // Query the committed scene directly: event-time freshening (Cx.hitTestQuery) would run a
    // zero-dt before-render tick here, ahead of this frame's real one.
    const hit = self.interaction_index.hitTestQuery(.{
        .kind = .pointer,
        .world_x = self.mouse_x,
        .world_y = self.mouse_y,
    }, &self.node_registry, &self.perf);
    self.hover_sync.reconcile_hit_tests += 1;
    self.interaction_index.setHoveredResult(hit);
    const target = hoverTargetForHit(self, hit, self.mouse_x, self.mouse_y);
    const before = self.hovered_handle;
    self.hovered_node = self.dispatcher.reconcileHover(target);
    self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    if (!std.meta.eql(before, self.hovered_handle)) self.hover_sync.reconcile_changes += 1;
    cx_cursor.updateCursorShape(self);
}

/// The platform reports that the pointer is no longer over this window's visible content (it
/// left the window, or another window now covers it). Its last position no longer describes the
/// pointer: drop hover (mouse_leave / on_leave along the hovered path, like a browser's mouseout
/// on leaving the window or AppKit's mouseExited) and stop re-resolving until the next pointer
/// event. During a capture or press sequence hover belongs to the sequence; its release
/// re-resolves.
pub fn handlePointerLeave(self: *Cx) void {
    self.hover_sync.pointer_over_content = false;
    if (self.root == null or !self.dispatcher.hoverFollowsScene()) return;
    self.needs_redraw = true;
    self.interaction_index.setHoveredResult(null);
    self.hovered_node = self.dispatcher.syncHover(null);
    self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    cx_cursor.updateCursorShape(self);
}
