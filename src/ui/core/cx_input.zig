//! Cx input event entry: mouse down/up/move (including pointer capture resync, focus decision on
//! press), click / command / action, keyboard, text input & IME, wheel / zoom gestures, drag-drop.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_render = @import("cx_render.zig");
const cx_platform = @import("cx_platform.zig");
const event_dispatcher_mod = @import("../event_dispatcher.zig");
const system_sdk_mod = @import("system_sdk");
const CursorShape = core.CursorShape;
const CursorToken = core.CursorToken;
const CustomCursorDesc = core.CustomCursorDesc;
const Event = core.Event;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;
const MouseButton = core.MouseButton;
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const a11y_macos_bridge_mod = @import("../a11y/macos_bridge.zig");
const actions_mod = @import("../actions.zig");
const cx_cursor = @import("cx_cursor.zig");
const cx_hit_target = @import("cx_hit_target.zig");
const cx_hover = @import("cx_hover.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const devtoolsHitDebugEnabled = debug_env.devtoolsHitDebugEnabled;
const ensureDevtoolsHitDebugBanner = cx_hit_target.ensureDevtoolsHitDebugBanner;
const events_mod = @import("../events.zig");
const hitSceneDebugEnabled = debug_env.hitSceneDebugEnabled;
const inspector_mod = @import("inspector.zig");
const interaction_drag = @import("../interaction/drag.zig");
const logDebugNodeSummary = cx_hit_target.logDebugNodeSummary;
const resolveInteractionTarget = cx_hit_target.resolveInteractionTarget;
const shouldPreserveFocusForOverlayPointerTarget = cx_hit_target.shouldPreserveFocusForOverlayPointerTarget;

pub fn handleMouseDown(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
    self.handleMouseDownEx(x, y, .left, modifiers);
}

pub fn handleMouseDownEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
    self.focus_manager.noteInputModality(.pointer);
    self.mouse_x = x;
    self.mouse_y = y;
    self.cursor_state.pointer_valid = true;
    self.hover_sync.pointer_over_content = true;
    defer cx_cursor.updateCursorShape(self);
    self.needs_redraw = true;
    // New press of same key means previous press's up (if swallowed) is lost (can't have two
    // unpaired downs of same key); stale flag would swallow this press's normal up.
    if (self.swallowed_press_button == button) self.swallowed_press_button = null;
    if (button == .left and self.inspector.handleMouseDown(self, x, y)) {
        return;
    }
    // Feed gesture_arena. Only left button gets gesture arena, right/middle buttons dispatch
    // individually but don't participate in gesture recognition (UIKit same).
    if (button == .left) {
        self.gesture_arena.reset();
        self.gesture_arena.onTouchDown(x, y, @import("zenit_time").nanoTimestamp(self.io));
    }
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const target_handle = if (hit) |result| result.handle else null;
        const raw_target = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
        const target = resolveInteractionTarget(raw_target);

        if (devtoolsHitDebugEnabled()) {
            ensureDevtoolsHitDebugBanner();
            std.debug.print(
                "[devtools-hit] mouse_down win={d} button={s} xy=({d:.1},{d:.1}) modifiers=(cmd={any} shift={any} alt={any} ctrl={any})\n",
                .{ self.window_id, @tagName(button), x, y, modifiers.super, modifiers.shift, modifiers.alt, modifiers.ctrl },
            );
            if (raw_target != target) logDebugNodeSummary("raw_pointer_hit", raw_target);
            logDebugNodeSummary("pointer_hit", target);
        }

        // `close_and_consume` overlay: outside the panel, this press only closes; both press and
        // following release don't dispatch (no click synthesis, no focus change).
        // A swallowed press whose release was lost counts as released: it closes its overlay,
        // and this new press is an ordinary one.
        const finished_lost_press = self.overlay_stack.consumed_press_layer != null;
        self.overlay_stack.commitConsumedPress();
        if (!finished_lost_press and self.overlay_stack.consumeOutsidePress(target)) {
            self.swallowed_press_button = button;
            if (button == .left) self.gesture_arena.reset();
            return;
        }

        if (button != .left) {
            _ = self.dispatcher.dispatchMouseDownButton(x, y, target, button, modifiers);
            rebuildRuntimeIndexesIfCurrentRootDirty(self);
            return;
        }

        self.interaction_index.setMouseDownResult(hit);
        // Focus decision made before dispatch, based on current tree: handler can rebuild subtree,
        // later parent-chain lookup may read new tree (or dangling nodes).
        const focus_decision = resolvePointerDownFocus(target);
        const preserve_overlay_focus = shouldPreserveFocusForOverlayPointerTarget(self, target);
        const focus_target_handle_pre = switch (focus_decision) {
            .focus => |ft| self.node_registry.handleFor(ft),
            .preserve, .clear => null,
        };

        // Record which overlay this press belongs to before dispatch: handler may close it
        // immediately, invalidating references.
        const press_owner = self.overlay_stack.findPressOwner(target);
        const press_mark = self.overlay_stack.activationMark();
        _ = self.dispatcher.dispatchMouseDownButton(x, y, target, .left, modifiers);
        rebuildRuntimeIndexesIfCurrentRootDirty(self);

        const focus_target = self.node_registry.resolve(focus_target_handle_pre, &self.perf);
        if (focus_target != null) {
            self.focus_manager.setFocusWithReason(focus_target, .click);
        } else if (focus_decision != .preserve and !preserve_overlay_focus) {
            self.focus_manager.clearFocus();
        }
        // Callbacks may redirect or destroy the initial target. Read the
        // settled authority, including the explicit preserve/no-op path.
        cx_platform.syncFocusedCache(self);

        self.pressed_node = self.node_registry.resolve(target_handle, &self.perf);
        self.pressed_handle = target_handle;
        self.notifyPressWatchers();
        self.press_overlay_owner = press_owner;
        self.outside_press_armed = true;
        self.outside_press_mark = press_mark;
        self.last_mouse_down_target = self.pressed_node;
        self.last_mouse_down_handle = target_handle;
        self.has_new_mouse_down = true;

        if (devtoolsHitDebugEnabled()) {
            logDebugNodeSummary("focus_target", focus_target);
            logDebugNodeSummary("pressed_node", self.pressed_node);
        }
    }
}

/// Is node focusable (has focusable or tab_index != null)
fn isNodeFocusable(n: *Node) bool {
    return n.behavior.interaction.focusable or n.behavior.interaction.tab_index != null;
}

const PointerDownFocusDecision = union(enum) {
    /// Transfer focus to this node (hit node itself or nearest focusable ancestor).
    focus: *Node,
    /// Found `pointer_down_focus = .preserve` in parent chain: focus stays.
    preserve,
    /// Neither focusable nor preserve in parent chain: clear focus (overlay exempt, separate rule).
    clear,
};

/// Traverse parent chain from hit node upward, take first `.preserve` or focusable node.
/// `.preserve` takes priority if same node has both.
fn resolvePointerDownFocus(node_opt: ?*Node) PointerDownFocusDecision {
    var current = node_opt;
    while (current) |n| {
        if (n.behavior.interaction.pointer_down_focus == .preserve) return .preserve;
        if (isNodeFocusable(n)) return .{ .focus = n };
        current = n.parent;
    }
    return .clear;
}

pub fn handleMouseUp(self: *Cx, x: f32, y: f32) void {
    self.handleMouseUpEx(x, y, .left, .{});
}

pub fn handleMouseUpEx(self: *Cx, x: f32, y: f32, button: MouseButton, modifiers: Modifiers) void {
    self.mouse_x = x;
    self.mouse_y = y;
    self.cursor_state.pointer_valid = true;
    self.hover_sync.pointer_over_content = true;
    defer cx_cursor.updateCursorShape(self);
    self.needs_redraw = true;
    // Feed gesture_arena (primary button only)
    if (button == .left) {
        self.gesture_arena.onTouchUp(x, y, @import("zenit_time").nanoTimestamp(self.io));
    }
    if (self.swallowed_press_button) |swallowed| {
        if (swallowed == button) {
            self.swallowed_press_button = null;
            if (button == .left) self.gesture_arena.reset();
            self.overlay_stack.commitConsumedPress();
            return;
        }
    }
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const had_pointer_capture = button == .left and self.dispatcher.hasPointerCapture();
        const hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const target_handle = if (hit) |result| result.handle else null;
        const raw_target = if (hit) |result| self.node_registry.resolve(result.handle, &self.perf) else null;
        const target = resolveInteractionTarget(raw_target);
        self.dispatcher.dispatchMouseUpButton(x, y, target, button, modifiers);
        rebuildRuntimeIndexesIfCurrentRootDirty(self);
        // Overlays the press began outside of close now (render phase), after this click's own
        // handlers ran: a click that navigates away unmounts them with their page.
        if (button == .left and self.outside_press_armed) {
            self.outside_press_armed = false;
            self.has_new_press_release = true;
            const record: core.PressRelease = .{ .press_handle = self.last_mouse_down_handle, .press_owner = self.press_overlay_owner, .press_mark = self.outside_press_mark };
            if (self.press_release_count == self.press_releases.len) {
                // Full batch: keep the newest; the oldest clicks were already superseded.
                std.mem.copyForwards(core.PressRelease, self.press_releases[0 .. self.press_releases.len - 1], self.press_releases[1..]);
                self.press_release_count -= 1;
            }
            self.press_releases[self.press_release_count] = record;
            self.press_release_count += 1;
        }
        if (button == .left and had_pointer_capture) {
            self.resyncPointerAfterCaptureRelease(x, y, target_handle);
        }
    }
    if (button == .left) {
        self.pressed_node = null; // Release press state
        self.pressed_handle = null;
        self.notifyPressWatchers();
    }
}

pub fn resyncPointerAfterCaptureRelease(self: *Cx, x: f32, y: f32, fallback_handle: ?NodeHandle) void {
    var synced_target: ?*Node = null;
    if (self.root != null) {
        cx_render.ensureHitTestSceneFresh(self);
        const synced_hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = x,
            .world_y = y,
        });
        const synced_handle = if (synced_hit) |result| result.handle else fallback_handle;
        const synced_raw_target = self.node_registry.resolve(synced_handle, &self.perf);
        synced_target = resolveInteractionTarget(synced_raw_target);
        cx_hover.noteResolved(self);
    }
    self.hovered_node = self.dispatcher.syncHover(synced_target);
    self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    cx_cursor.updateCursorShape(self);
}

/// OOM during index rebuild always panics, never silenced.
///
/// rebuildRuntimeStateRecursive **clears dirty first, then does fallible
/// node_registry.put / focus_order.append**. OOM midway leaves a node marked clean but missing
/// from node_registry / focus_order: it fails hit-test, Tab can't reach it, and no dirty bit
/// triggers a retry (silent permanent corruption). fullRebuildRuntimeIndexes is worse: it clears
/// first, and OOM leaves the whole tree's index empty while all nodes are clean.
///
/// These callsites sit under Stable signatures like handleMouse*/render
/// (see docs/API_STABILITY.md) and can't propagate `!`, so panic.
pub fn rebuildRuntimeIndexesIfCurrentRootDirty(self: *Cx) void {
    const root = self.root orelse return;
    if (!root.frame_state.state_bits.dirty.runtime.subtree_dirty) return;
    // Structure change almost always comes with layout dirty (newly swapped-in subtree still has
    // rect 0). Rebuilding directly now would build empty hit proxies from unlaid-out geometry
    // (0-size emits no proxy, but plannedProxyCount ignores size, so partial validation still
    // passes); clearInteractionDirtyRecursive then consumes the whole subtree's hit dirty bits,
    // later layout will not trigger a hit rebuild again, and these nodes can never be hit. Lay out
    // first, then rebuild: same path as event entry ensureHitTestSceneFresh.
    if ((root.frame_state.state_bits.dirty.core.layout or root.frame_state.state_bits.dirty.core.subtree_layout) and
        self.tick_depth == 0 and !self.draining_deferred_frees)
    {
        cx_render.forceTickAndRebuildForHitTest(self);
        return;
    }
    cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (current root dirty)");
}

pub fn handleMouseMove(self: *Cx, x: f32, y: f32) void {
    self.handleMouseMoveEx(x, y, .{});
}

pub fn handleMouseMoveEx(self: *Cx, x: f32, y: f32, modifiers: Modifiers) void {
    // R4a: mark dirty only when mouse actually moves, hover hit changes with cursor position, needs
    // frame to re-dispatch; stationary move events shouldn't wake new frame (idle frame-gating
    // depends on this).
    const hit_tests_before = self.perf.hit_test_count;
    self.input_perf.in_pointer_moves += 1;
    cx_render.ensureHitTestSceneFresh(self);
    if (x != self.mouse_x or y != self.mouse_y) {
        self.needs_redraw = true;
    }
    self.mouse_x = x;
    self.mouse_y = y;
    // feed gesture_arena
    self.cursor_state.pointer_valid = true;
    self.hover_sync.pointer_over_content = true;
    self.gesture_arena.onTouchMove(x, y, @import("zenit_time").nanoTimestamp(self.io));
    if (self.root != null) {
        const has_capture = self.dispatcher.hasPointerCapture();
        const hit = if (has_capture)
            null
        else
            self.hitTestQuery(.{
                .kind = .pointer,
                .world_x = x,
                .world_y = y,
            });
        self.interaction_index.setHoveredResult(hit);
        // Hysteresis on MISS lives in hoverTargetForHit (shared with stationary re-resolution).
        const hovered = if (has_capture) null else cx_hover.hoverTargetForHit(self, hit, x, y);
        // Hover below is resolved against this committed scene; under capture it is not
        // resolved at all and stays stale, so release re-resolves (cx_hover.reconcile).
        if (!has_capture) cx_hover.noteResolved(self);
        if (hitSceneDebugEnabled()) {
            if (hit) |h| {
                const proxy = self.interaction_index.proxies.items[h.proxy_id];
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> id={d} comp={s} aabb=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{
                    x,                            y,
                    if (hovered) |n| n.id else 0, if (hovered) |n| (n.meta.ownership.meta.component_name orelse "-") else "-",
                    proxy.true_aabb.x,            proxy.true_aabb.y,
                    proxy.true_aabb.w,            proxy.true_aabb.h,
                });
            } else if (hovered) |kept| {
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> MISS (hover 滞回保持 id={d})\n", .{ x, y, kept.id });
            } else {
                std.debug.print("[hit-move] ({d:.0},{d:.0}) -> MISS\n", .{ x, y });
            }
        }
        self.perf.mouse_move_hit_test_count += 1;
        self.hovered_node = self.dispatcher.dispatchMouseMoveEx(x, y, hovered, modifiers);
        self.hovered_handle = if (self.hovered_node) |n| self.node_registry.handleFor(n) else null;
    }
    std.debug.assert(self.perf.hit_test_count - hit_tests_before <= 1);
    // Update system cursor
    cx_cursor.updateCursorShape(self);
    self.inspector.handleMouseMove(self, x, y);
}

pub fn cancelPointerInteractions(self: *Cx, reason: interaction_drag.CancelReason) void {
    self.drag_manager.cancel(self, reason);
    // Press swallowed by consume becomes invalid with interaction: its release won't come again (or
    // shouldn't), flag left standing would swallow next normal click's release.
    self.swallowed_press_button = null;
    // A cancelled press is not a click: it dismisses nothing on a later release.
    self.outside_press_armed = false;
    self.overlay_stack.consumed_press_layer = null;
    self.dispatcher.cancelActivePress();
    self.dispatcher.releasePointerCapture();
    self.cursor_state.leases.clearRetainingCapacity();
    self.cursor_override = null;
    // Gesture: abort converts began/changed -> cancelled (no one wrote .cancelled before,
    // system-level abort left recognizer stuck mid-state)
    self.gesture_arena.onTouchCancel(@import("zenit_time").nanoTimestamp(self.io));
    // Same for in-flight trackpad scroll: end signal may never come, proactively emit end
    self.dispatcher.cancelScrollGesture();
    cx_cursor.updateCursorShape(self);
}

pub fn acquireCursor(self: *Cx, owner: *Node, shape: CursorShape) !CursorToken {
    return cx_cursor.acquireCursor(self, owner, shape);
}

pub fn updateCursor(self: *Cx, token: CursorToken, shape: CursorShape) void {
    return cx_cursor.updateCursor(self, token, shape);
}

pub fn releaseCursor(self: *Cx, token: CursorToken) void {
    return cx_cursor.releaseCursor(self, token);
}

pub fn refreshCursor(self: *Cx) void {
    return cx_cursor.refreshCursor(self);
}

pub fn replayCursor(self: *Cx) void {
    return cx_cursor.replayCursor(self);
}

pub fn setCursorOverride(self: *Cx, shape: ?CursorShape) void {
    return cx_cursor.setCursorOverride(self, shape);
}

pub fn setCustomCursor(self: *Cx, desc: CustomCursorDesc) void {
    return cx_cursor.setCustomCursor(self, desc);
}

pub fn activeCustomCursorKey(self: *const Cx) ?u64 {
    return cx_cursor.activeCustomCursorKey(self);
}

pub fn updateAutomationCursor(self: *Cx, x: f32, y: f32, pressed: ?bool) void {
    return cx_cursor.updateAutomationCursor(self, x, y, pressed);
}

pub fn handleClick(self: *Cx, x: f32, y: f32) void {
    self.handleMouseDown(x, y, .{});
    self.handleMouseUp(x, y);
}

pub fn bindCommandAction(self: *Cx, command_id: u64, action: actions_mod.Action) void {
    self.action_dispatcher.bindCommand(command_id, action);
}

pub fn handleCommand(self: *Cx, command_id: u64) void {
    const action = self.action_dispatcher.matchCommand(command_id) orelse return;
    const target = self.focus_manager.getFocused() orelse self.root orelse return;
    const delivery = self.action_dispatcher.dispatchActionWithDelivery(action, target);
    // No handler in the focus chain: menu commands are app-level and must not be silently dropped
    // just because focus is not inside a binding context (cx.root is App's internal wrapper, so a
    // context bound on the user's mount root is never reached walking upward; caught by
    // verify_menu.sh on real menu clicks). Fall back to searching the whole tree for the first node
    // matching the context.
    if (delivery.result == .ignored and !delivery.delivered) {
        if (self.root) |root| {
            if (findActionContextNode(root, action.context)) |node| {
                if (node.behavior.events.on_action) |action_handler| {
                    _ = action_handler(action, node.behavior.events.action_context);
                }
            }
        }
    }
    self.needs_redraw = true;
}

fn findActionContextNode(node: *Node, context: []const u8) ?*Node {
    if (node.behavior.interaction.key_context) |ctx| {
        if (std.mem.eql(u8, ctx, context) and node.behavior.events.on_action != null) return node;
    }
    for (node.children.items) |child| {
        if (findActionContextNode(child, context)) |found| return found;
    }
    return null;
}

pub fn handleKeyDown(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
    switch (key) {
        .left_shift, .right_shift, .left_ctrl, .right_ctrl, .left_alt, .right_alt, .left_super, .right_super, .unknown => {},
        else => self.focus_manager.noteInputModality(.keyboard),
    }
    self.needs_redraw = true;
    // The inspector is a development overlay: its chord (Ctrl+Shift+I on
    // Windows/Linux) is also an ordinary application shortcut there, so the
    // application gets the key first and the inspector only opens when nothing
    // handled it. Closing an open inspector always works.
    const inspector_key = inspector_mod.isToggleShortcut(key, modifiers);
    if (inspector_key and self.inspector.enabled) {
        self.inspector.enabled = false;
        self.inspector.pick_mode = false;
        self.inspector.clearSelection();
        return;
    }
    if (routeKeyDown(self, key, modifiers)) return;
    if (inspector_key) self.inspector.enabled = true;
}

/// Delivers a key press; true when something consumed it.
fn routeKeyDown(self: *Cx, key: KeyCode, modifiers: Modifiers) bool {
    // Drag session consumes Escape first (must be before overlay stack, else one Escape both
    // cancels the drag and dismisses the top overlay). Pending is silently cleaned, active emits
    // cancel; both swallow this Escape.
    if (key == .escape and self.drag_manager.handleEscape(self)) return true;
    if (key == .escape) {
        if (self.focus_manager.getFocused()) |focused| {
            if (focused.behavior.interaction.text_input_client) |client| {
                if (client.is_composing) |composing| if (composing(client.context)) {
                    _ = self.dispatcher.dispatchKeyDown(focused, .{ .key = key, .modifiers = modifiers });
                    return true;
                };
            }
        }
    }
    // OverlayStack: Escape only closes topmost overlay
    if (key == .escape and self.overlay_stack.handleEscape()) return true;

    if (key == .tab) {
        // Dispatch to focused node first (editors need to intercept Tab for indent).
        // With nothing focused the application root gets the same first refusal,
        // as for every other key: app-level chords such as Ctrl+Tab (next
        // document) must not turn into focus traversal just because the last
        // click landed on non-focusable chrome or a menu.
        const tab_target = self.focus_manager.getFocused() orelse unfocusedKeyTarget(self);
        if (tab_target) |target| {
            const result = self.dispatcher.dispatchKeyDown(target, .{
                .key = key,
                .modifiers = modifiers,
            });
            if (events_mod.preventsDefault(result)) return true;
        }
        // Node unhandled, execute default focus switch
        if (modifiers.shift) {
            self.focus_manager.focusPrev();
        } else {
            self.focus_manager.focusNext();
        }
        return true;
    }

    if (self.focus_manager.getFocused()) |focused| {
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        const keyboard_target = self.focused_handle;
        // Query Action binding first
        if (self.action_dispatcher.matchKey(key, modifiers)) |action| {
            const result = self.action_dispatcher.dispatchAction(action, focused);
            if (events_mod.preventsDefault(result)) return true;
            if (resolveKeyboardTarget(self, keyboard_target) == null) return true;
        }

        // Space/Enter: dispatch key_down first, if unhandled synthesize click
        if (key == .space or key == .@"return") {
            const key_result = self.dispatcher.dispatchKeyDown(focused, .{
                .key = key,
                .modifiers = modifiers,
            });
            if (!events_mod.preventsDefault(key_result)) {
                // A key handler may destroy/rebind its node or redirect
                // focus. Default activation belongs only to the original
                // still-live, still-focused owner of this key sequence.
                const live_target = resolveKeyboardTarget(self, keyboard_target) orelse return true;
                _ = self.dispatcher.dispatch(Event{ .click = .{
                    .x = 0,
                    .y = 0,
                    .modifiers = modifiers,
                } }, live_target);
            }
            return true;
        }

        return events_mod.preventsDefault(self.dispatcher.dispatchKeyDown(focused, .{
            .key = key,
            .modifiers = modifiers,
        }));
    } else if (unfocusedKeyTarget(self)) |root| {
        // No focused node, fallback to the application root so app/island-level shortcuts work
        return events_mod.preventsDefault(self.dispatcher.dispatchKeyDown(root, .{
            .key = key,
            .modifiers = modifiers,
        }));
    }
    return false;
}

/// Target for keys while nothing has focus: the application's mounted tree, else the root.
/// App's root wraps that tree and the overlay portal; capture runs root -> target, so a
/// target of the wrapper would never reach handlers on the application root.
fn unfocusedKeyTarget(self: *Cx) ?*Node {
    const root = self.root orelse return null;
    if (self.content_root) |content| {
        for (root.children.items) |child| if (child == content) return content;
    }
    return root;
}

fn resolveKeyboardTarget(self: *Cx, identity: ?NodeHandle) ?*Node {
    const target = self.node_registry.resolve(identity, null) orelse return null;
    return if (self.focus_manager.getFocused() == target) target else null;
}

pub fn handleKeyUp(self: *Cx, key: KeyCode, modifiers: Modifiers) void {
    self.needs_redraw = true;
    if (self.focus_manager.getFocused()) |focused| {
        self.focused_node = focused;
        self.focused_handle = self.node_registry.handleFor(focused);
        _ = self.dispatcher.dispatchKeyUp(focused, .{
            .key = key,
            .modifiers = modifiers,
        });
    } else if (unfocusedKeyTarget(self)) |root| {
        _ = self.dispatcher.dispatchKeyUp(root, .{
            .key = key,
            .modifiers = modifiers,
        });
    }
}

/// Return the focused node only when it publishes the live text-input
/// contract and has an event sink. Element tags are visual/semantic hints;
/// they are no longer used as a platform-input capability switch.
fn focusedTextInput(self: *Cx) ?*Node {
    const focused = self.focus_manager.getFocused() orelse return null;
    if (focused.behavior.interaction.text_input_client == null or
        focused.behavior.events.on_event == null) return null;
    return focused;
}

pub fn handleTextInput(self: *Cx, t: []const u8) void {
    const focused = focusedTextInput(self) orelse return;
    const deferred = focused.behavior.interaction.deferred_text_input_redraw;
    if (!deferred) self.needs_redraw = true;
    const result = self.dispatcher.dispatchTextInput(focused, t);
    if (deferred and result != .stop) self.needs_redraw = true;
}

pub fn handleImePreedit(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32) void {
    self.handleImePreeditReplace(preedit_text, cursor_utf8_offset, events_mod.ime_no_replacement, events_mod.ime_no_replacement);
}

pub fn handleImePreeditReplace(self: *Cx, preedit_text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) void {
    return handleImePreeditEvent(self, .{ .text = preedit_text, .cursor_utf8_offset = cursor_utf8_offset, .replace_start_utf8 = replace_start_utf8, .replace_end_utf8 = replace_end_utf8 });
}

pub fn handleImePreeditEvent(self: *Cx, event: events_mod.ImePreeditEvent) void {
    const focused = focusedTextInput(self) orelse return;
    self.needs_redraw = true;
    const owner = self.node_registry.handleFor(focused);
    const client_context = focused.behavior.interaction.text_input_client.?.context;
    _ = self.dispatcher.dispatch(.{ .ime_preedit = event }, focused);
    const current = focusedTextInput(self) orelse return;
    if (!std.meta.eql(owner, self.node_registry.handleFor(current)) or
        current.behavior.interaction.text_input_client.?.context != client_context) return;
    a11y_macos_bridge_mod.publishAppliedPreedit(cx_platform.a11yWindowKey(self));
}

pub fn handleImeCommit(self: *Cx, commit_text: []const u8) void {
    self.handleImeCommitReplace(commit_text, events_mod.ime_no_replacement, events_mod.ime_no_replacement);
}

pub fn handleImeCommitReplace(self: *Cx, commit_text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) void {
    const focused = focusedTextInput(self) orelse return;
    const deferred = focused.behavior.interaction.deferred_text_input_redraw;
    if (!deferred) self.needs_redraw = true;
    const result = self.dispatcher.dispatchImeCommitReplace(focused, commit_text, replace_start_utf8, replace_end_utf8);
    if (deferred and result != .stop) self.needs_redraw = true;
}

pub fn handleImeDeleteSurrounding(self: *Cx, before: u32, after: u32) void {
    const focused = focusedTextInput(self) orelse return;
    self.needs_redraw = true;
    _ = self.dispatcher.dispatch(.{ .ime_delete_surrounding = .{ .before_bytes = before, .after_bytes = after } }, focused);
}

pub fn scrollEventFromSdk(wheel: system_sdk_mod.events.MouseWheel) events_mod.ScrollEvent {
    return .{
        .x = wheel.x,
        .y = wheel.y,
        .dx = wheel.dx,
        .dy = wheel.dy,
        .phase = switch (wheel.phase) {
            .none => .none,
            .may_begin => .may_begin,
            .began => .began,
            .changed => .changed,
            .ended => .ended,
            .cancelled => .cancelled,
        },
        .momentum = switch (wheel.momentum) {
            .none => .none,
            .began => .began,
            .changed => .changed,
            .ended => .ended,
        },
        .modifiers = .{
            .shift = wheel.modifiers.shift,
            .ctrl = wheel.modifiers.ctrl,
            .alt = wheel.modifiers.alt,
            .super = wheel.modifiers.super,
        },
    };
}

pub fn handleScroll(self: *Cx, scroll: events_mod.ScrollEvent) void {
    // During pinch suppress trackpad scroll dispatch (pinch and two-finger pan share source,
    // dispatch both causes screen jump during zoom), same gesture session doesn't receive
    // pan/scroll simultaneously.
    if (self.magnify_target_handle != null and scroll.isTrackpad()) return;
    self.input_perf.in_scroll_events += 1;
    // A scroll event requests a frame only through what its handlers changed: a handler that
    // moved content marks it dirty, and the redraw below covers every handler that does not
    // declare the event inert (event_dispatcher.scroll_effect). A wheel against a pinned end, or
    // over content that cannot scroll, changes nothing and renders nothing.
    const scroll_accounting = core.scroll_effect.begin();
    defer if (core.scroll_effect.finish(scroll_accounting)) {
        self.needs_redraw = true;
    };
    // Finish previous gesture that lost ended, then run hit-test
    self.dispatcher.beginScrollEvent(scroll);
    // A latched gesture or its momentum goes to its owner whatever is under the pointer: no hit
    // test (hover under the moved content is re-resolved at the next frame, cx_hover). The handler
    // still reads committed layout, so pending layout is committed first, as for a hit test.
    if (self.root != null and !self.dispatcher.scrollNeedsHitTarget(scroll) and !devtoolsHitDebugEnabled()) {
        self.input_perf.in_scroll_latched += 1;
        const r = self.root.?;
        if (r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout) {
            cx_render.ensureHitTestSceneFresh(self);
        }
        if (self.root != null) _ = self.dispatcher.dispatchScroll(scroll, null);
        return;
    }
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root != null) {
        const scroll_hit = self.hitTestQuery(.{
            .kind = .scroll,
            .world_x = scroll.x,
            .world_y = scroll.y,
        });
        const pointer_hit = self.hitTestQuery(.{
            .kind = .pointer,
            .world_x = scroll.x,
            .world_y = scroll.y,
        });
        const raw_pointer_target = if (pointer_hit) |result|
            self.node_registry.resolve(result.handle, &self.perf)
        else
            null;
        const pointer_target = resolveInteractionTarget(raw_pointer_target);
        const preferred_target = event_dispatcher_mod.nearestCompatibleScrollOwner(pointer_target, scroll.dx, scroll.dy);
        const scroll_target = if (scroll_hit) |result|
            self.node_registry.resolve(result.handle, &self.perf)
        else
            null;
        const hit_target = preferred_target orelse event_dispatcher_mod.nearestCompatibleScrollOwner(scroll_target, scroll.dx, scroll.dy);

        if (devtoolsHitDebugEnabled()) {
            ensureDevtoolsHitDebugBanner();
            std.debug.print(
                "[devtools-hit] scroll win={d} xy=({d:.1},{d:.1}) delta=({d:.1},{d:.1}) momentum={s} phase={s}\n",
                .{ self.window_id, scroll.x, scroll.y, scroll.dx, scroll.dy, @tagName(scroll.momentum), @tagName(scroll.phase) },
            );
            if (raw_pointer_target != pointer_target) logDebugNodeSummary("raw_pointer_hit", raw_pointer_target);
            logDebugNodeSummary("pointer_hit", pointer_target);
            logDebugNodeSummary("preferred_scroll_owner", preferred_target);
            logDebugNodeSummary("scroll_hit", scroll_target);
            logDebugNodeSummary("dispatch_scroll_target", hit_target);
        }
        if (scroll.isMomentum()) {
            self.interaction_index.setScrollMomentumOwner(scroll_hit);
        } else {
            self.interaction_index.setScrollSessionOwner(scroll_hit);
        }
        _ = self.dispatcher.dispatchScroll(scroll, hit_target);
    }
}

pub fn handleMagnify(self: *Cx, magnification: f32, x: f32, y: f32, phase: events_mod.GesturePhase) void {
    self.needs_redraw = true;
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root == null) return;
    if (phase == .began or self.magnify_target_handle == null) {
        const hit = self.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y });
        self.magnify_target_handle = if (hit) |result| result.handle else null;
    }
    const target = if (self.magnify_target_handle) |h|
        self.node_registry.resolve(h, &self.perf)
    else
        null;
    if (target) |t| {
        _ = self.dispatcher.dispatch(.{ .magnify = .{
            .magnification = magnification,
            .x = x,
            .y = y,
            .phase = phase,
        } }, t);
    }
    if (phase == .ended or phase == .cancelled) {
        self.magnify_target_handle = null;
    }
}

pub fn handleDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8) void {
    handleDragPayload(self, x, y, kind, paths, if (paths.len > 0) 1 else 0, false, false);
}

pub fn handlePlatformDrag(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8, payload_kind: u8, payload_truncated: bool, payload_is_untrusted: bool) void {
    handleDragPayload(self, x, y, kind, paths, payload_kind, payload_truncated, payload_is_untrusted);
}

fn handleDragPayload(self: *Cx, x: f32, y: f32, kind: u8, paths: []const u8, payload_kind_raw: u8, payload_truncated: bool, payload_is_untrusted: bool) void {
    self.needs_redraw = true;
    // kind=4 = drag-source completion receipt (beginDrag's completion/cancellation, carries
    // source_token/operation), not a pointer position event, so it does not go through hit-test
    // dispatch. Larger future kinds are likewise ignored defensively: @enumFromInt on an unknown
    // value is a checked panic (verify_interop_probe.sh: releasing a drag-out aborted the whole
    // app).
    if (kind > @backingInt(events_mod.DragEvent.Kind.dropped)) return;
    // The OS owns the pointer during a drag session and sends no motion: the last pointer
    // position is stale for stationary hover until the session leaves or drops.
    self.hover_sync.platform_drag_active = kind == @backingInt(events_mod.DragEvent.Kind.entered) or
        kind == @backingInt(events_mod.DragEvent.Kind.updated);
    // Take sequence number before any step that can run user code (hit refresh runs before_render
    // hooks): if drag-drop event re-enters during refresh, this event is replaced by it (see
    // re-entry semantics below).
    self.drag_event_seq +%= 1;
    const seq = self.drag_event_seq;
    const superseded = struct {
        fn check(cx: *const Cx, s: u64) bool {
            return cx.drag_event_seq != s;
        }
    }.check;
    cx_render.ensureHitTestSceneFresh(self);
    if (self.root == null) return;

    const drag_kind: events_mod.DragEvent.Kind = @fromBackingInt(@intCast(kind));
    const payload_kind = std.enums.fromInt(events_mod.DragEvent.PayloadKind, payload_kind_raw) orelse .none;

    // Re-entry semantics: a handler (even a hook inside hit refresh) can synchronously re-enter the
    // next drag-drop event (same Cx); the inner one carries newer pointer state. Each event takes a
    // sequence number on entry; once a newer drag-drop event starts (sequence changed), this event
    // is superseded: it no longer writes drag_hover_handle (a stale hit must not overwrite the
    // inner result), no longer emits boundary events, and no longer dispatches stale
    // updated/entered. The one exception is dropped: it carries the payload and is the session's
    // terminal state, so even when superseded it is still delivered to the live target, otherwise
    // the payload is lost.

    // exited (left window) doesn't hit-test: cursor already outside window, coordinates
    // meaningless.
    const target_handle: ?NodeHandle = if (drag_kind == .exited) null else blk: {
        const hit = self.hitTestQuery(.{ .kind = .pointer, .world_x = x, .world_y = y });
        break :blk if (hit) |result| result.handle else null;
    };
    // Previous target: resolve via handle; yields null if the node was released. Must be fetched
    // **after** the hit query: hitTestQuery internally refreshes the hit scene again, and if the
    // tree is still dirty it still runs before_render hooks, closes the batch and
    // drainDeferredFrees, so a raw pointer taken earlier may be freed here.
    const prev: ?*Node = self.node_registry.resolve(self.drag_hover_handle, &self.perf);
    const target: ?*Node = self.node_registry.resolve(target_handle, &self.perf);
    // At most three fires per call (old target exited, new target entered, new target's own event).
    // Each dispatch may synchronously free nodes in its handler (handler calls freeNode directly,
    // or synchronously drives another window's host entry whose effect frees this window's nodes),
    // so between dispatches trust only handles: target identity is fixed before dispatch,
    // re-resolve before every use, and the raw pointer is only used for the pre-dispatch
    // comparison.
    const crossed = prev != target;
    const live = struct {
        fn get(cx: *Cx, h: ?NodeHandle) ?*Node {
            return cx.node_registry.resolve(h, &cx.perf);
        }
    }.get;

    // Cross node boundary: emit exited to the old target, entered to the new target. Hover is set
    // to the post-dispatch state **before** each dispatch (commit-before-callback), and re-entering
    // events use it to determine their own boundary: while leaving prev, hover is empty (prev will
    // not get a second exited, nor will a not-yet-entered target get exited); while entering
    // target, hover is target (target already received entered, so it should receive exited on
    // leave).
    if (crossed and !superseded(self, seq)) {
        self.drag_hover_handle = null;
        if (prev) |p| {
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = .exited,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, p);
        }
        if (!superseded(self, seq)) if (live(self, target_handle)) |t| {
            self.drag_hover_handle = target_handle;
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = .entered,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, t);
        };
    }
    if (superseded(self, seq) and drag_kind != .dropped) return;

    // Already-emitted entered/exited don't re-fire.
    if (drag_kind == .updated or drag_kind == .dropped or
        (drag_kind == .entered and !crossed))
    {
        if (live(self, target_handle)) |t| {
            _ = self.dispatcher.dispatch(.{ .drag = .{
                .x = x,
                .y = y,
                .kind = drag_kind,
                .paths = paths,
                .payload_kind = payload_kind,
                .payload_truncated = payload_truncated,
                .payload_is_untrusted = payload_is_untrusted,
            } }, t);
        }
    }
    if (superseded(self, seq)) return;

    // Session end (drop or leave window): clear hover state so the next drag is not mistaken for
    // 'still on the old target'. Otherwise hover is this event's target; if the target was freed in
    // this event's handler, record null and let the next position event start over from a fresh
    // hit.
    self.drag_hover_handle = if (drag_kind == .dropped or drag_kind == .exited)
        null
    else if (live(self, target_handle) != null)
        target_handle
    else
        null;
}
