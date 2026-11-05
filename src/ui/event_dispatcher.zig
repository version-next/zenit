/// Event Dispatcher - Node tree event dispatching.
///
/// Event propagation: capture -> target -> bubble
///
/// Event flow:
/// 1. Hit test: determine target node
/// 2. Build path: root -> ... -> target
/// 3. Capture phase: root to target (**excludes target**) call
///    node.behavior.events.on_event_capture. null-handler nodes cost nothing;
///    used for ancestor preemption (focus trap / scroll lock / gesture arbitration).
/// 4. Target phase: on_event + specialized handlers (click/key) on target
/// 5. Bubble phase: target parent to root call
///
/// Returning .stop from any phase stops propagation (W3C DOM semantics; capture stop skips
/// target/bubble).
const std = @import("std");
const Allocator = std.mem.Allocator;
const events = @import("events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const EventPhase = events.EventPhase;
const KeyEvent = events.KeyEvent;
const Modifiers = events.Modifiers;

// Forward reference to core Node type
const core = @import("core.zig");
const Node = core.Node;
const NodeHandle = core.NodeHandle;
const NodeRegistry = core.NodeRegistry;
const interaction_semantics = @import("core/interaction_semantics.zig");
const debug_trace = @import("core/debug_trace.zig");

fn treeHitDebugEnabled() bool {
    return false;
}

fn scrollDebugEnabled() bool {
    return false;
}

fn devtoolsHitDebugEnabled() bool {
    const raw = @import("zenit_environment").getNative("ZENIT_DEVTOOLS_HIT_DEBUG") orelse return false;
    const value = std.mem.span(raw);
    if (value.len == 0) return true;
    return !std.mem.eql(u8, value, "0");
}

fn logDevtoolsNodeSummary(comptime label: []const u8, node: ?*Node) void {
    if (node) |n| {
        const rect = n.globalRect();
        std.debug.print(
            "[devtools-hit] {s}=id={d} tag={s} component={s} test_id={s} rect=({d:.1},{d:.1},{d:.1},{d:.1})\n",
            .{
                label,
                n.id,
                @tagName(n.tag),
                n.meta.ownership.meta.component_name orelse "<none>",
                n.meta.ownership.meta.test_id orelse "<none>",
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            },
        );
    } else {
        std.debug.print("[devtools-hit] {s}=<none>\n", .{label});
    }
}

fn isSidebarProbePoint(x: f32) bool {
    return x >= 0 and x <= 360;
}

fn logSidebarHit(comptime phase: []const u8, x: f32, y: f32, target: ?*Node) void {
    if (!treeHitDebugEnabled()) return;
    if (!isSidebarProbePoint(x)) return;
    if (target) |t| {
        std.debug.print(
            "[tree-hit] {s} ({d:.1},{d:.1}) -> id={d} tag={s} test_id={s} rect=({d:.1},{d:.1},{d:.1},{d:.1}) tx=({d:.1},{d:.1})\n",
            .{
                phase,
                x,
                y,
                t.id,
                @tagName(t.tag),
                t.meta.ownership.meta.test_id orelse "<none>",
                t.rectFromWorldOrFallback().x,
                t.rectFromWorldOrFallback().y,
                t.rectFromWorldOrFallback().w,
                t.rectFromWorldOrFallback().h,
                t.style.translate_x,
                t.style.translate_y,
            },
        );
    } else {
        std.debug.print("[tree-hit] {s} ({d:.1},{d:.1}) -> <none>\n", .{ phase, x, y });
    }
}

/// Event dispatcher - Node tree based
pub const EventDispatcher = struct {
    dispatch_depth: usize = 0,
    allocator: Allocator,
    io: std.Io,

    hovered_handle: ?NodeHandle = null,

    mouse_down_handle: ?NodeHandle = null,
    mouse_down_pos: [2]f32 = .{ 0, 0 },
    last_mouse_pos: [2]f32 = .{ 0, 0 },
    has_last_mouse: bool = false,

    /// Most recent mouse_down modifier flags (synthesize click)
    last_modifiers: events.Modifiers = .{},

    /// Multi-click detection
    last_click_instant: ?@import("zenit_time").Instant = null,
    last_click_pos: [2]f32 = .{ 0, 0 },
    consecutive_clicks: u8 = 0,

    pointer_capture_handle: ?NodeHandle = null,
    /// Distinguishes release/reacquire even when the owner is unchanged.
    pointer_capture_epoch: u64 = 0,
    hover_epoch: u64 = 0,

    /// Pointer-sequence click suppression (drag precondition, see docs/DRAG_INTERACTION_DESIGN.md
    /// §8.3).
    /// LMB down resets to false; when true, this sequence's LMB up does not synthesize
    /// click/double_click,
    /// does not update multi-click count (both normal and capture paths gated). up consumes and
    /// clears.
    suppress_click: bool = false,

    /// Scroll session owner (locked by node ID, avoid dangling ptrs across rebuilds)
    scroll_session_owner: ?NodeHandle = null,
    scroll_session_owner_ptr: ?*Node = null,
    /// Momentum phase owner (is_momentum=true dispatch fixed)
    scroll_momentum_owner: ?NodeHandle = null,
    scroll_momentum_owner_ptr: ?*Node = null,
    /// Session opened by may_begin (following began belongs same gesture)
    scroll_session_from_may_begin: bool = false,

    registry: ?*const NodeRegistry = null,

    pub fn init(allocator: Allocator, io: std.Io) EventDispatcher {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn setRegistry(self: *EventDispatcher, registry: *const NodeRegistry) void {
        self.registry = registry;
    }

    pub fn clearPersistentState(self: *EventDispatcher) void {
        self.hovered_handle = null;
        self.mouse_down_handle = null;
        self.pointer_capture_handle = null;
        self.suppress_click = false;
        self.scroll_session_owner = null;
        self.scroll_session_owner_ptr = null;
        self.scroll_momentum_owner = null;
        self.scroll_momentum_owner_ptr = null;
        self.scroll_session_from_may_begin = false;
    }

    /// Set pointer capture; subsequent mouse events go directly to this node.
    pub fn setPointerCapture(self: *EventDispatcher, node: *Node) void {
        const next = if (self.registry) |registry| registry.handleFor(node) else null;
        if (std.meta.eql(next, self.pointer_capture_handle)) return;
        const previous_epoch = self.pointer_capture_epoch;
        self.releasePointerCapture();
        if (self.pointer_capture_epoch != previous_epoch) return;
        self.pointer_capture_epoch = std.math.add(u64, self.pointer_capture_epoch, 1) catch @panic("capture epoch exhausted");
        self.pointer_capture_handle = if (self.resolveHandle(next) != null) next else null;
    }

    /// Release pointer capture.
    pub fn releasePointerCapture(self: *EventDispatcher) void {
        const previous = self.pointer_capture_handle;
        self.pointer_capture_handle = null;
        if (self.resolveHandle(previous)) |node| {
            if (node.on_capture_lost) |callback| callback(node);
        }
    }

    /// Release capture only if still owned by handle's node: capture is single slot,
    /// may have been taken over, blind clear would injure successor. Return whether actually
    /// released.
    pub fn releasePointerCaptureFor(self: *EventDispatcher, handle: NodeHandle) bool {
        const current = self.pointer_capture_handle orelse return false;
        if (current.id != handle.id or current.generation != handle.generation) return false;
        self.releasePointerCapture();
        return true;
    }

    /// Suppress click/double_click synthesis for current pointer sequence (internal API,
    /// called when drag exceeds threshold / can_start refuses / forced cancel). This sequence only.
    pub fn cancelClickSynthesisForActivePointer(self: *EventDispatcher) void {
        self.suppress_click = true;
    }

    /// End the active press sequence without a release (pointer cancel, window blur): the
    /// release may never arrive, so the sequence must not keep routing moves to the pressed node
    /// or hold off stationary hover re-resolution (`hoverFollowsScene`). A late release still
    /// dispatches mouse_up but cannot synthesize a click.
    pub fn cancelActivePress(self: *EventDispatcher) void {
        self.suppress_click = true;
        self.mouse_down_handle = null;
    }

    pub fn hasPointerCapture(self: *EventDispatcher) bool {
        return self.resolveHandle(self.pointer_capture_handle) != null;
    }

    /// Current LMB sequence's mouse_down target (null if no press or node invalid).
    ///
    /// For 'press-then-drag' hosts: the on_event callback has no node pointer, but the host needs
    /// the pressed node in its mouse_down handler to setPointerCapture. Without capture, mouse_up
    /// on another node does not route back to the drag initiator and drag state leaks.
    /// dispatchMouseDownButton records mouse_down_handle **before** dispatch.
    pub fn mouseDownNode(self: *EventDispatcher) ?*Node {
        return self.resolveHandle(self.mouse_down_handle);
    }

    pub fn syncHover(self: *EventDispatcher, new_hovered: ?*Node) ?*Node {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        self.updateHoveredNode(new_hovered);
        return self.currentHovered();
    }

    /// Whether hover may follow the scene under a pointer that is not moving. False while a
    /// pointer sequence owns the pointer: capture (drag, scrollbar thumb, slider) or a left press
    /// in progress. AppKit tracking areas without NSTrackingEnabledDuringMouseDrag deliver no
    /// mouseEntered/mouseExited while a button is held, and browsers skip the post-scroll hover
    /// update while a button is pressed. The re-resolution is deferred, not dropped: the caller
    /// keeps its scene stamp stale and retries once the sequence ends.
    pub fn hoverFollowsScene(self: *EventDispatcher) bool {
        return self.resolveHandle(self.pointer_capture_handle) == null and
            self.resolveHandle(self.mouse_down_handle) == null;
    }

    /// Re-resolve hover for a stationary pointer after the scene under it changed (scroll,
    /// layout, mount/unmount). Delivers exactly the mouse_leave / mouse_enter / on_leave /
    /// on_hover transitions a pointer move to the same point would, but no mouse_move: the
    /// pointer did not move (AppKit sends only mouseEntered/mouseExited here). No-op while
    /// `hoverFollowsScene()` is false. Returns the hovered leaf afterwards.
    pub fn reconcileHover(self: *EventDispatcher, new_hovered: ?*Node) ?*Node {
        if (!self.hoverFollowsScene()) return self.currentHovered();
        return self.syncHover(new_hovered);
    }

    pub fn deinit(self: *EventDispatcher) void {
        _ = self;
    }

    pub fn invalidateHandlesInSubtree(self: *EventDispatcher, subtree_root: *Node) void {
        if (self.hovered_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.hovered_handle = null;
            }
        }
        if (self.mouse_down_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.mouse_down_handle = null;
            }
        }
        if (self.pointer_capture_handle) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) {
                self.releasePointerCapture();
            }
        }
        if (self.scroll_session_owner) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) self.scroll_session_owner = null;
        }
        if (self.scroll_session_owner_ptr) |node| {
            if (isNodeInSubtree(subtree_root, node.id)) self.scroll_session_owner_ptr = null;
        }
        if (self.scroll_momentum_owner) |h| {
            if (isNodeInSubtree(subtree_root, h.id)) self.scroll_momentum_owner = null;
        }
        if (self.scroll_momentum_owner_ptr) |node| {
            if (isNodeInSubtree(subtree_root, node.id)) self.scroll_momentum_owner_ptr = null;
        }
    }

    /// Dispatch captures the propagation path per invocation; nested events have
    /// independent paths. Registry-backed nodes are revalidated between callbacks.
    /// Without a registry, the caller must keep every path node and its handler
    /// contexts alive until dispatch returns (including nested dispatches).
    pub fn dispatch(self: *EventDispatcher, event: Event, target: *Node) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        // Build path from root to target
        var path_buf: [128]*Node = undefined;
        const storage = pathStorage(*Node, self.allocator, &path_buf, pathDepth(target)) catch return .stop;
        defer releasePathStorage(*Node, self.allocator, storage);
        const path = buildPathInto(target, storage);
        if (path.len == 0) return .ignored;
        var handled = false;

        // Extract event pointer coordinate (for trace)
        const ptr_xy = eventPointerXY(event);
        const event_kind = eventToKindTag(event);
        const target_id = target.id;

        // Prefer handle resolution, avoid handler mid-tree destruction invalidating path ptrs.
        if (self.registry) |registry| {
            var path_handle_buf: [128]NodeHandle = undefined;
            const path_handles = pathStorage(NodeHandle, self.allocator, &path_handle_buf, path.len) catch return .stop;
            defer releasePathStorage(NodeHandle, self.allocator, path_handles);
            for (path, 0..) |node, i| {
                path_handles[i] = registry.handleFor(node);
            }
            const target_handle = path_handles[path_handles.len - 1];

            // Phase 1: Capture (root -> target, excludes target)
            if (path_handles.len > 1) {
                for (path_handles[0 .. path_handles.len - 1]) |node_handle| {
                    const node = registry.resolve(node_handle, null) orelse continue;
                    const result = invokeHandler(registry, node, event, .capture);
                    if (result != .ignored) {
                        debug_trace.maybeRecordEvent(event_kind, .capture, target_id, node_handle.id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                    }
                    if (result == .stop) return .stop;
                    if (result == .handled) handled = true;
                }
            }

            // Phase 2: Target
            if (registry.resolve(target_handle, null)) |resolved_target| {
                const target_result = invokeHandler(registry, resolved_target, event, .target);
                if (target_result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .target, target_id, target_id, eventResultToTag(target_result), ptr_xy[0], ptr_xy[1]);
                }
                if (target_result == .stop) return .stop;
                if (target_result == .handled) handled = true;
            } else {
                return if (handled) .handled else .ignored;
            }

            // Phase 3: Bubble (target's parent -> root)
            if (path_handles.len > 1) {
                var i = path_handles.len - 1;
                while (i > 0) {
                    i -= 1;
                    const node_handle = path_handles[i];
                    const node = registry.resolve(node_handle, null) orelse continue;
                    const result = invokeHandler(registry, node, event, .bubble);
                    if (result != .ignored) {
                        debug_trace.maybeRecordEvent(event_kind, .bubble, target_id, node_handle.id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                    }
                    if (result == .stop) return .stop;
                    if (result == .handled) handled = true;
                }
            }

            return if (handled) .handled else .ignored;
        }

        // Phase 1: Capture (root -> target, excludes target)
        if (path.len > 1) {
            for (path[0 .. path.len - 1]) |node| {
                const node_id = node.id;
                const result = invokeHandler(null, node, event, .capture);
                if (result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .capture, target_id, node_id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                }
                if (result == .stop) return .stop;
                if (result == .handled) handled = true;
            }
        }

        // Phase 2: Target
        const target_result = invokeHandler(null, target, event, .target);
        if (target_result != .ignored) {
            debug_trace.maybeRecordEvent(event_kind, .target, target_id, target_id, eventResultToTag(target_result), ptr_xy[0], ptr_xy[1]);
        }
        if (target_result == .stop) return .stop;
        if (target_result == .handled) handled = true;

        // Phase 3: Bubble (target's parent -> root)
        if (path.len > 1) {
            var i = path.len - 1;
            while (i > 0) {
                i -= 1;
                const node = path[i];
                const node_id = node.id;
                const result = invokeHandler(null, node, event, .bubble);
                if (result != .ignored) {
                    debug_trace.maybeRecordEvent(event_kind, .bubble, target_id, node_id, eventResultToTag(result), ptr_xy[0], ptr_xy[1]);
                }
                if (result == .stop) return .stop;
                if (result == .handled) handled = true;
            }
        }

        return if (handled) .handled else .ignored;
    }

    /// Dispatch mouse move, handle hover change (modifiers degrade to `.{}` compat entry)
    pub fn dispatchMouseMove(self: *EventDispatcher, x: f32, y: f32, new_hovered: ?*Node) ?*Node {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        return self.dispatchMouseMoveEx(x, y, new_hovered, .{});
    }

    /// Dispatch mouse move with movement-time modifier flags
    pub fn dispatchMouseMoveEx(self: *EventDispatcher, x: f32, y: f32, new_hovered: ?*Node, modifiers: events.Modifiers) ?*Node {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const dx: f32 = if (self.has_last_mouse) x - self.last_mouse_pos[0] else 0;
        const dy: f32 = if (self.has_last_mouse) y - self.last_mouse_pos[1] else 0;
        self.last_mouse_pos = .{ x, y };
        self.has_last_mouse = true;

        // Pointer capture: direct to captured node, skip hover
        const capture_target = self.resolveHandle(self.pointer_capture_handle);
        if (capture_target) |capture| {
            const event = Event{ .mouse_move = .{ .x = x, .y = y, .dx = dx, .dy = dy, .modifiers = modifiers } };
            _ = self.dispatch(event, capture);
            return self.currentHovered();
        }

        self.updateHoveredNode(new_hovered);

        const target = self.resolveHandle(self.mouse_down_handle) orelse
            (if (self.registry != null) self.currentHovered() else new_hovered);
        if (target) |t| {
            const event = Event{ .mouse_move = .{ .x = x, .y = y, .dx = dx, .dy = dy, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }
        return self.currentHovered();
    }

    /// Dispatch mouse down (button support)
    pub fn dispatchMouseDownButton(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, button: events.MouseButton, modifiers: events.Modifiers) ?*Node {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const identity = if (target) |node| HandlerTarget.init(self.registry, node) else null;
        // RMB/MMB skip click synthesis and press tracking; dispatch raw down only.
        if (button != .left) {
            if (target) |t| {
                const event = Event{ .mouse_down = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
                _ = self.dispatch(event, t);
            }
            return if (identity) |ref| ref.resolve() else null;
        }
        logSidebarHit("down", x, y, target);
        self.mouse_down_handle = if (target) |t|
            if (self.registry) |registry| registry.handleFor(t) else null
        else
            null;
        self.mouse_down_pos = .{ x, y };
        self.last_modifiers = modifiers;
        self.suppress_click = false;

        if (target) |t| {
            const event = Event{ .mouse_down = .{ .x = x, .y = y, .button = .left, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }

        return if (identity) |ref| ref.resolve() else null;
    }

    /// Dispatch mouse down, LMB default convenience overload
    pub fn dispatchMouseDown(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, modifiers: events.Modifiers) ?*Node {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        return self.dispatchMouseDownButton(x, y, target, .left, modifiers);
    }

    /// Dispatch mouse up (button support); LMB synthesizes click.
    /// `modifiers` is the **up-time** modifier state, mirroring mouse_down.
    /// Deliberately not reusing `self.last_modifiers` (down-time value): they may differ (e.g.
    /// Shift pressed after down), and hosts need up-time truth for 'add-select vs exclusive
    /// select'. The synthesized click still uses last_modifiers; click's semantic anchor is down.
    pub fn dispatchMouseUpButton(self: *EventDispatcher, x: f32, y: f32, target: ?*Node, button: events.MouseButton, modifiers: events.Modifiers) void {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const target_handle = if (target) |t|
            if (self.registry) |registry| registry.handleFor(t) else null
        else
            null;

        // Pointer capture: send to captured, auto-release after. click/double_click still
        // synthesized (browser setPointerCapture semantics: capture element receives synthetic
        // click), else down-then-capture hosts (canvas drag) never see double-click.
        const capture_target = self.resolveHandle(self.pointer_capture_handle);
        if (capture_target) |capture| {
            const capture_handle = self.pointer_capture_handle;
            const capture_epoch = self.pointer_capture_epoch;
            const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
            _ = self.dispatch(event, capture);
            if (button == .left) {
                if (self.pointer_capture_epoch == capture_epoch) {
                    if (capture_handle) |h| _ = self.releasePointerCaptureFor(h);
                }
                self.mouse_down_handle = null;
                if (!self.suppress_click) {
                    self.synthesizeClick(x, y, capture_handle, capture);
                }
                self.suppress_click = false;
            }
            return;
        }
        if (button != .left) {
            if (resolveDispatchTarget(self, target_handle, target)) |t| {
                const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = button, .modifiers = modifiers } };
                _ = self.dispatch(event, t);
            }
            return;
        }
        logSidebarHit("up", x, y, target);

        // Dispatch mouse_up
        if (resolveDispatchTarget(self, target_handle, target)) |t| {
            const event = Event{ .mouse_up = .{ .x = x, .y = y, .button = .left, .modifiers = modifiers } };
            _ = self.dispatch(event, t);
        }

        // Synthesize click (down and up on same element)
        const down_target = self.resolveHandle(self.mouse_down_handle);
        const click_match = if (self.registry != null)
            nodeHandleEqual(self.mouse_down_handle, target_handle)
        else if (down_target != null and down_target == target)
            true
        else
            false;
        if (click_match and !self.suppress_click) {
            self.synthesizeClick(x, y, target_handle, target);
        }

        self.suppress_click = false;
        self.mouse_down_handle = null;
    }

    /// Synthesize click/double_click (multi-click detection shared). Normal and
    /// pointer-capture paths reuse; handle priority, raw ptr fallback if registry absent.
    fn synthesizeClick(self: *EventDispatcher, x: f32, y: f32, target_handle: ?NodeHandle, target: ?*Node) void {
        {
            // mouse_up handler already ran, may have destroyed target subtree (e.g. folder toggle).
            // Raw ptr now dangling; must trust handle. registry absent -> can only gamble on raw.
            const click_target: ?*Node = if (self.registry != null)
                self.resolveHandle(target_handle)
            else
                target;
            if (click_target) |t| {
                // Multi-click detect: shared threshold, avoid double/triple judgment too tight.
                const dx = x - self.last_click_pos[0];
                const dy = y - self.last_click_pos[1];
                const dist_sq = dx * dx + dy * dy;
                var is_multi_click = false;
                const now_instant = @import("zenit_time").Instant.now(self.io) catch null;
                if (now_instant) |now| {
                    if (self.last_click_instant) |last| {
                        const time_delta_ns = now.since(last);
                        is_multi_click = time_delta_ns < events.multi_click_interval_ns and dist_sq < events.multi_click_slop_sq;
                    }
                    self.last_click_instant = now;
                }
                if (is_multi_click) {
                    self.consecutive_clicks +|= 1;
                } else {
                    self.consecutive_clicks = 1;
                }
                self.last_click_pos = .{ x, y };

                const click_event = Event{ .click = .{ .x = x, .y = y, .click_count = self.consecutive_clicks, .modifiers = self.last_modifiers } };
                _ = self.dispatch(click_event, t);
                if (self.consecutive_clicks == 2) {
                    // click handler may have destroyed target's subtree (e.g. folder toggle
                    // rebuilds tree).
                    // Raw ptr dangling; must trust handle: if registry present but resolve fails,
                    // abandon double_click.
                    const dc_target: ?*Node = if (self.registry != null)
                        self.resolveHandle(target_handle)
                    else
                        target;
                    if (dc_target) |double_click_target| {
                        const double_click_event = Event{ .double_click = .{
                            .x = x,
                            .y = y,
                            .click_count = self.consecutive_clicks,
                            .modifiers = self.last_modifiers,
                        } };
                        _ = self.dispatch(double_click_event, double_click_target);
                    }
                }
            }
        }
    }

    /// Dispatch mouse up, LMB default, no modifiers convenience overload
    pub fn dispatchMouseUp(self: *EventDispatcher, x: f32, y: f32, target: ?*Node) void {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        self.dispatchMouseUpButton(x, y, target, .left, .{});
    }

    /// Dispatch keyboard event to focus node
    pub fn dispatchKeyDown(self: *EventDispatcher, target: *Node, key_event: KeyEvent) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const event = Event{ .key_down = key_event };
        return self.dispatch(event, target);
    }

    pub fn dispatchKeyUp(self: *EventDispatcher, target: *Node, key_event: KeyEvent) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const event = Event{ .key_up = key_event };
        return self.dispatch(event, target);
    }

    /// Dispatch text input to focus node
    pub fn dispatchTextInput(self: *EventDispatcher, target: *Node, text: []const u8) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const event = Event{ .text_input = .{ .text = text } };
        return self.dispatch(event, target);
    }

    /// Dispatch IME preedit to focus node
    pub fn dispatchImePreedit(self: *EventDispatcher, target: *Node, text: []const u8, cursor_utf8_offset: u32) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        return self.dispatchImePreeditReplace(target, text, cursor_utf8_offset, events.ime_no_replacement, events.ime_no_replacement);
    }

    /// Dispatch IME preedit with replacementRange (reconversion); sentinel == dispatchImePreedit
    pub fn dispatchImePreeditReplace(self: *EventDispatcher, target: *Node, text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const event = Event{ .ime_preedit = .{
            .text = text,
            .cursor_utf8_offset = cursor_utf8_offset,
            .replace_start_utf8 = replace_start_utf8,
            .replace_end_utf8 = replace_end_utf8,
        } };
        return self.dispatch(event, target);
    }

    /// Dispatch IME commit to focus node
    pub fn dispatchImeCommit(self: *EventDispatcher, target: *Node, text: []const u8) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        return self.dispatchImeCommitReplace(target, text, events.ime_no_replacement, events.ime_no_replacement);
    }

    /// Dispatch IME commit with replacementRange; sentinel == dispatchImeCommit
    pub fn dispatchImeCommitReplace(self: *EventDispatcher, target: *Node, text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const event = Event{ .ime_commit = .{
            .text = text,
            .replace_start_utf8 = replace_start_utf8,
            .replace_end_utf8 = replace_end_utf8,
        } };
        return self.dispatch(event, target);
    }

    /// Called **before** hit test per scroll event: gesture started means prior ended,
    /// if its ended lost, synthesize cancelled first (old owner + ancestors not misled node
    /// still touched). Before hit test so handler's tree edits visible to following hit. may_begin
    /// then began belong same gesture.
    pub fn beginScrollEvent(self: *EventDispatcher, scroll: events.ScrollEvent) void {
        if (scroll.isMomentum() or scroll.phase == .none) return;
        switch (scroll.phase) {
            .may_begin => self.cancelScrollGesture(),
            .began => if (!self.scroll_session_from_may_begin) self.cancelScrollGesture(),
            else => {},
        }
        self.scroll_session_from_may_begin = scroll.phase == .may_begin;
    }

    /// Dispatch wheel event (call beginScrollEvent first, then hit test).
    ///
    /// Trackpad gestures lock owner on hit at may_begin/began and hold it through changed (content
    /// moves under a steady pointer, so hit changes but it is not a new gesture); released on
    /// ended/cancelled; ended transfers owner to momentum. Mouse wheel (.none) is stateless.
    pub fn dispatchScroll(self: *EventDispatcher, scroll: events.ScrollEvent, hit_target: ?*Node) EventResult {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        const hit = nearestCompatibleScrollOwner(hit_target, scroll.dx, scroll.dy) orelse hit_target;
        if (scrollDebugEnabled() and !scroll.isMomentum() and !scroll.phaseEnded() and (scroll.dy != 0 or scroll.dx != 0)) {
            logScrollHitWithoutScrollArea(hit, scroll.x, scroll.y);
        }
        if (scroll.isMomentum()) return self.dispatchMomentumScroll(scroll, hit);
        if (scroll.phase == .none) {
            // Wheel interrupts in-flight momentum.
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
            const target = hit orelse return .ignored;
            return self.dispatch(.{ .scroll = scroll }, target);
        }

        switch (scroll.phase) {
            .none => unreachable,
            .may_begin, .began => self.setScrollSessionOwner(hit),
            .changed => {
                const current = self.scrollSessionOwner(hit);
                if (current == null) {
                    self.setScrollSessionOwner(hit);
                } else if (hit != null and !scrollOwnerAcceptsGesture(current.?, scroll.dx, scroll.dy)) {
                    self.setScrollSessionOwner(hit);
                }
            },
            .ended, .cancelled => if (self.scrollSessionOwner(hit) == null) self.setScrollSessionOwner(hit),
        }

        // Any new pointer/wheel input breaks prior momentum; ended transfers owner to this
        // gesture's momentum.
        switch (scroll.phase) {
            .ended => {
                self.scroll_momentum_owner = self.scroll_session_owner;
                self.scroll_momentum_owner_ptr = self.scroll_session_owner_ptr;
            },
            else => {
                self.scroll_momentum_owner = null;
                self.scroll_momentum_owner_ptr = null;
            },
        }

        const owner = self.scrollSessionOwner(hit);
        if (devtoolsHitDebugEnabled()) {
            std.debug.print("[devtools-hit] dispatch_scroll phase={s} session_owner={any}\n", .{ @tagName(scroll.phase), self.scroll_session_owner });
            logDevtoolsNodeSummary("resolved_scroll_owner", owner);
        }
        if (scroll.phaseEnded()) {
            self.scroll_session_owner = null;
            self.scroll_session_owner_ptr = null;
        }
        const target = owner orelse return .ignored;
        return self.dispatch(.{ .scroll = scroll }, target);
    }

    /// Whether `dispatchScroll(scroll, hit)` reads `hit` for this event in the current gesture
    /// state. It does not for momentum (always the momentum owner) and for changed / ended /
    /// cancelled phases whose latched session owner is alive and, for changed, still accepts the
    /// gesture's axis: dispatchScroll then gives the same result for any hit, so the caller may skip
    /// the hit test. Pointer mode (no registry) validates owners against the hit's root, so it
    /// always needs the hit.
    pub fn scrollNeedsHitTarget(self: *EventDispatcher, scroll: events.ScrollEvent) bool {
        if (self.registry == null) return true;
        if (scroll.isMomentum()) return false;
        return switch (scroll.phase) {
            .none, .may_begin, .began => true,
            .changed => if (self.scrollSessionOwner(null)) |owner| !scrollOwnerAcceptsGesture(owner, scroll.dx, scroll.dy) else true,
            .ended, .cancelled => self.scrollSessionOwner(null) == null,
        };
    }

    /// registry mode stores handle (ptr dangling); no-registry test mode stores ptr only.
    fn setScrollSessionOwner(self: *EventDispatcher, node: ?*Node) void {
        if (self.registry) |registry| {
            self.scroll_session_owner = if (node) |n| registry.handleFor(n) else null;
            self.scroll_session_owner_ptr = null;
        } else {
            self.scroll_session_owner = null;
            self.scroll_session_owner_ptr = node;
        }
    }

    /// Current session owner; returns null if destroyed (or ptr mode + not same tree).
    fn scrollSessionOwner(self: *EventDispatcher, hit: ?*Node) ?*Node {
        if (self.registry != null) return self.resolveHandle(self.scroll_session_owner);
        const ptr = self.scroll_session_owner_ptr orelse return null;
        if (hit) |h| if (!nodesShareRoot(ptr, h)) return null;
        return ptr;
    }

    /// Momentum dispatch fixed to gesture owner. Owner cleared by new gesture (or node
    /// destroyed) means momentum broken, discard, do not fallback to hit.
    fn dispatchMomentumScroll(self: *EventDispatcher, scroll: events.ScrollEvent, hit: ?*Node) EventResult {
        const owner = if (self.registry != null)
            self.resolveHandle(self.scroll_momentum_owner)
        else if (self.scroll_momentum_owner_ptr) |ptr|
            if (hit) |h| (if (nodesShareRoot(ptr, h)) ptr else null) else ptr
        else
            null;
        const target = owner orelse {
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
            return .ignored;
        };
        if (scroll.momentum == .ended) {
            self.scroll_momentum_owner = null;
            self.scroll_momentum_owner_ptr = null;
        }
        return self.dispatch(.{ .scroll = scroll }, target);
    }

    /// System interrupt (window blur etc) ends active scroll: synthesize cancelled to
    /// gesture owner, momentum ended to momentum owner, same code path as real device end.
    pub fn cancelScrollGesture(self: *EventDispatcher) void {
        self.dispatch_depth += 1;
        defer self.dispatch_depth -= 1;
        // Extract both owners once, clear, then dispatch: handler re-entering scroll sees
        // clean state, new session it builds not overwritten. Extracted is **identity** (registry
        // handle, not raw ptr): first dispatch handler may sync-destroy second owner, second
        // dispatch must re-resolve before use. No-registry test mode by dispatch contract keeps
        // raw ptrs alive.
        const session_handle = self.scroll_session_owner;
        const momentum_handle = self.scroll_momentum_owner;
        const session_ptr = if (self.registry == null) self.scrollSessionOwner(null) else null;
        const momentum_ptr = if (self.registry == null) self.scroll_momentum_owner_ptr else null;
        self.scroll_session_owner = null;
        self.scroll_session_owner_ptr = null;
        self.scroll_momentum_owner = null;
        self.scroll_momentum_owner_ptr = null;
        self.scroll_session_from_may_begin = false;
        const session_owner = if (self.registry != null) self.resolveHandle(session_handle) else session_ptr;
        if (session_owner) |owner| {
            _ = self.dispatch(.{ .scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 0, .phase = .cancelled } }, owner);
        }
        const momentum_owner = if (self.registry != null) self.resolveHandle(momentum_handle) else momentum_ptr;
        if (momentum_owner) |owner| {
            _ = self.dispatch(.{ .scroll = .{ .x = 0, .y = 0, .dx = 0, .dy = 0, .momentum = .ended } }, owner);
        }
    }

    fn resolveHandle(self: *EventDispatcher, handle: ?NodeHandle) ?*Node {
        const registry = self.registry orelse return null;
        return registry.resolve(handle, null);
    }

    fn currentHovered(self: *EventDispatcher) ?*Node {
        return self.resolveHandle(self.hovered_handle);
    }

    fn updateHoveredNode(self: *EventDispatcher, new_hovered: ?*Node) void {
        const old_hovered = self.currentHovered();
        if (new_hovered == old_hovered) return;

        var old_path_buf: [128]*Node = undefined;
        var new_path_buf: [128]*Node = undefined;

        // Prepare both complete paths before publishing a hover transition.
        // OOM leaves the prior hover transaction unchanged, with no callbacks.
        const old_storage = pathStorage(*Node, self.allocator, &old_path_buf, if (old_hovered) |old| pathDepth(old) else 0) catch return;
        defer releasePathStorage(*Node, self.allocator, old_storage);
        const new_storage = pathStorage(*Node, self.allocator, &new_path_buf, if (new_hovered) |new| pathDepth(new) else 0) catch return;
        defer releasePathStorage(*Node, self.allocator, new_storage);
        const old_path = if (old_hovered) |old| buildPathInto(old, old_storage) else old_storage;
        const new_path = if (new_hovered) |new| buildPathInto(new, new_storage) else new_storage;

        // Find common prefix
        var common: usize = 0;
        while (common < old_path.len and common < new_path.len and old_path[common] == new_path[common]) {
            common += 1;
        }

        if (self.registry) |registry| {
            // Callbacks can detach/free either path or reenter hover dispatch.
            // Snapshot identities before calling any user code, and resolve
            // again even between on_event and the convenience hover handler.
            var old_handle_buf: [128]NodeHandle = undefined;
            var new_handle_buf: [128]NodeHandle = undefined;
            const old_handles = pathStorage(NodeHandle, self.allocator, &old_handle_buf, old_path.len) catch return;
            defer releasePathStorage(NodeHandle, self.allocator, old_handles);
            const new_handles = pathStorage(NodeHandle, self.allocator, &new_handle_buf, new_path.len) catch return;
            defer releasePathStorage(NodeHandle, self.allocator, new_handles);
            for (old_path, 0..) |node, index| old_handles[index] = registry.handleFor(node);
            for (new_path, 0..) |node, index| new_handles[index] = registry.handleFor(node);
            self.hover_epoch +%= 1;
            const epoch = self.hover_epoch;
            self.hovered_handle = if (new_path.len > 0) new_handles[new_path.len - 1] else null;
            var leaving_index = old_path.len;
            while (leaving_index > common) {
                leaving_index -= 1;
                const handle = old_handles[leaving_index];
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_event) |handler| _ = handler(.mouse_leave, node.behavior.events.event_context);
                }
                if (self.hover_epoch != epoch) return;
                if (self.resolveHandle(handle)) |node| {
                    @import("hooks.zig").assertHoverHandlers(node);
                    if (node.behavior.events.on_leave) |handler| handler.invoke();
                }
                if (self.hover_epoch != epoch) return;
            }
            for (new_handles[common..new_path.len]) |handle| {
                if (self.resolveHandle(handle)) |node| {
                    if (node.behavior.events.on_event) |handler| _ = handler(.mouse_enter, node.behavior.events.event_context);
                }
                if (self.hover_epoch != epoch) return;
                if (self.resolveHandle(handle)) |node| {
                    @import("hooks.zig").assertHoverHandlers(node);
                    if (node.behavior.events.on_hover) |handler| handler.invoke();
                }
                if (self.hover_epoch != epoch) return;
            }
            if (self.currentHovered() == null) self.hovered_handle = null;
            return;
        }

        // Trigger leave (leaf to root)
        var i = old_path.len;
        while (i > common) {
            i -= 1;
            const leaving = old_path[i];
            if (leaving.behavior.events.on_event) |handler| {
                _ = handler(.mouse_leave, leaving.behavior.events.event_context);
            }
            @import("hooks.zig").assertHoverHandlers(leaving);
            if (leaving.behavior.events.on_leave) |h| {
                h.invoke();
            }
        }

        // Trigger enter (root to leaf)
        for (new_path[common..]) |node| {
            if (node.behavior.events.on_event) |handler| {
                _ = handler(.mouse_enter, node.behavior.events.event_context);
            }
            @import("hooks.zig").assertHoverHandlers(node);
            if (node.behavior.events.on_hover) |h| {
                h.invoke();
            }
        }

        self.hovered_handle = if (new_hovered) |node|
            if (self.registry) |registry| registry.handleFor(node) else null
        else
            null;
    }

    /// Build path root to target, write to external buffer
    fn buildPathInto(target: *Node, buf: []*Node) []*Node {
        return buildPathInternal(target, buf);
    }

    fn buildPathInternal(target: *Node, buf: []*Node) []*Node {
        var i: usize = 0;
        var node: ?*Node = target;
        while (node) |n| : (node = n.parent) {
            // Callers provision the complete depth. Never dispatch a partial
            // path: losing root capture changes the event's authority.
            if (i == buf.len) return buf[0..0];
            buf[i] = n;
            i += 1;
        }

        std.mem.reverse(*Node, buf[0..i]);
        return buf[0..i];
    }
};

fn pathDepth(target: *Node) usize {
    var depth: usize = 0;
    var node: ?*Node = target;
    while (node) |n| : (node = n.parent) depth += 1;
    return depth;
}

/// Ordinary paths stay allocation-free. Deep dispatch snapshots the complete
/// ancestry, including handles, before any callback can mutate the tree.
fn pathStorage(comptime T: type, allocator: Allocator, stack: *[128]T, count: usize) ![]T {
    return if (count <= stack.len) stack[0..count] else try allocator.alloc(T, count);
}

fn releasePathStorage(comptime T: type, allocator: Allocator, storage: []T) void {
    if (storage.len > 128) allocator.free(storage);
}

fn nodeHandleEqual(a: ?NodeHandle, b: ?NodeHandle) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.id == b.?.id and a.?.generation == b.?.generation;
}

fn resolveDispatchTarget(self: *EventDispatcher, handle: ?NodeHandle, raw: ?*Node) ?*Node {
    // Prefer handle (prevent dangling: node may be freed); fallback to raw ptr when
    // registry absent, keep hit-test's original node ptr from getting dropped (click/hover
    // unresponsive). v1 strict mode (invalid handle -> drop) loses unregistered events, high cost.
    return self.resolveHandle(handle) orelse raw;
}

fn scrollOwnerDirection(node: *Node) ?core.ScrollDirectionHint {
    const name = node.meta.ownership.meta.component_name orelse return null;
    if (std.mem.eql(u8, name, "md.table.viewport")) return .horizontal;
    if (!(std.mem.eql(u8, name, "ScrollArea") or
        std.mem.eql(u8, name, "VirtualList") or
        std.mem.eql(u8, name, "Grid.ScrollArea") or
        std.mem.eql(u8, name, "md.table.viewport") or
        std.mem.eql(u8, name, "LineVirtualList"))) return null;
    return node.behavior.events.scroll_direction_hint;
}

/// Diagnostic: hit node's ancestors lack ScrollArea/VirtualList (scroll gets dropped).
fn logScrollHitWithoutScrollArea(hit: ?*Node, x: f32, y: f32) void {
    const ht = hit orelse {
        std.debug.print("[scroll-dbg] hitTest=null at ({d:.0},{d:.0})\n", .{ x, y });
        return;
    };
    var p: ?*Node = ht;
    while (p) |n| : (p = n.parent) {
        if (n.meta.ownership.meta.component_name) |name| {
            if (std.mem.eql(u8, name, "VirtualList") or std.mem.eql(u8, name, "ScrollArea")) return;
        }
    }
    std.debug.print("[scroll-dbg] hit id={d} test_id={s} tag={s} at ({d:.0},{d:.0}): no ScrollArea ancestor\n", .{
        ht.id,
        ht.meta.ownership.meta.test_id orelse "(none)",
        @tagName(ht.tag),
        x,
        y,
    });
}

fn scrollOwnerAcceptsGesture(node: *Node, dx: f32, dy: f32) bool {
    const dir = scrollOwnerDirection(node) orelse return true;
    const abs_dx = @abs(dx);
    const abs_dy = @abs(dy);
    const epsilon: f32 = 0.5;
    if (abs_dx <= epsilon and abs_dy <= epsilon) return true;
    if (abs_dy > abs_dx + epsilon) return dir != .horizontal;
    if (abs_dx > abs_dy + epsilon) return dir != .vertical;
    return true;
}

pub fn nearestCompatibleScrollOwner(node: ?*Node, dx: f32, dy: f32) ?*Node {
    var cur = node;
    while (cur) |n| {
        if ((interaction_semantics.nodeHitRoles(n).scroll or scrollOwnerDirection(n) != null) and scrollOwnerAcceptsGesture(n, dx, dy)) return n;
        cur = n.parent;
    }
    return null;
}

fn nodesShareRoot(a: *Node, b: *Node) bool {
    return rootOf(a) == rootOf(b);
}

fn rootOf(node: *Node) *Node {
    var cur = node;
    while (cur.parent) |parent| {
        cur = parent;
    }
    return cur;
}

fn isNodeInSubtree(root: *Node, node_id: u32) bool {
    if (root.id == node_id) return true;
    for (root.children.items) |child| {
        if (isNodeInSubtree(child, node_id)) return true;
    }
    return false;
}

// === Debug Trace helpers ===

fn eventToKindTag(event: Event) debug_trace.EventKindTag {
    return switch (event) {
        .mouse_down => .mouse_down,
        .mouse_up => .mouse_up,
        .click => .click,
        .double_click => .double_click,
        .mouse_move => .mouse_move,
        .mouse_enter => .mouse_enter,
        .mouse_leave => .mouse_leave,
        .scroll => .scroll,
        .magnify => .magnify,
        .drag => .drag,
        .key_down => .key_down,
        .key_up => .key_up,
        .text_input => .text_input,
        .ime_preedit => .ime_preedit,
        .ime_commit => .ime_commit,
        .ime_delete_surrounding => .ime_delete_surrounding,
        .focus => .focus,
        .blur => .blur,
    };
}

fn eventResultToTag(result: EventResult) debug_trace.EventResultTag {
    return switch (result) {
        .ignored => .ignored,
        .handled => .handled,
        .stop => .stop,
    };
}

fn eventPointerXY(event: Event) [2]f32 {
    return switch (event) {
        .mouse_down => |e| .{ e.x, e.y },
        .mouse_up => |e| .{ e.x, e.y },
        .click => |e| .{ e.x, e.y },
        .double_click => |e| .{ e.x, e.y },
        .mouse_move => |e| .{ e.x, e.y },
        .scroll => |e| .{ e.x, e.y },
        else => .{ 0, 0 },
    };
}

/// Identity survives callbacks; node pointers and callback contexts do not.
/// Raw borrowing is only supported under dispatch's registry-free lifetime contract.
const HandlerTarget = struct {
    registry: ?*const NodeRegistry,
    handle: ?NodeHandle,
    raw: *Node,

    fn init(registry: ?*const NodeRegistry, node: *Node) HandlerTarget {
        return .{ .registry = registry, .handle = if (registry) |r| r.handleFor(node) else null, .raw = node };
    }

    fn resolve(self: HandlerTarget) ?*Node {
        return if (self.registry) |r| r.resolve(self.handle, null) else self.raw;
    }
};

/// Call event handler on node
/// What the scroll handlers of one input scroll event did (Cx.handleScroll). A handler that
/// takes the event (any result but `.ignored`) changed something unless it says otherwise with
/// `declareInert` (ScrollArea: offset, overscroll, spring and scroller visibility all as they
/// were). An app or unknown handler that takes the event is never inert, so it keeps the redraw
/// every scroll event used to request; a handler that passes (`.ignored`, e.g. a window-level
/// key capture) changed nothing it did not mark dirty itself. Main (UI) thread only.
pub const scroll_effect = struct {
    var inert: u32 = 0;
    var changed = false;

    pub const Saved = struct { inert: u32, changed: bool };

    /// Start accounting one scroll event; pass the result to `finish`.
    pub fn begin() Saved {
        const saved: Saved = .{ .inert = inert, .changed = changed };
        inert = 0;
        changed = false;
        return saved;
    }

    /// End the accounting `begin` started: whether the event changed something. An event
    /// dispatched from inside another one's handler restores the outer accounting; a change of
    /// its own makes the outer event changed too.
    pub fn finish(saved: Saved) bool {
        const result = changed;
        inert = saved.inert;
        changed = saved.changed or result;
        return result;
    }

    /// The running handler changed nothing visible for this scroll event.
    pub fn declareInert() void {
        inert +|= 1;
    }

    /// Around one handler call: `enter` before, `leave` with its result after.
    fn enter() u32 {
        return inert;
    }

    fn leave(event: Event, mark: u32, result: EventResult) EventResult {
        if (event == .scroll and result != .ignored and inert == mark) changed = true;
        return result;
    }
};

fn invokeHandler(registry: ?*const NodeRegistry, initial_node: *Node, event: Event, phase: EventPhase) EventResult {
    const target = HandlerTarget.init(registry, initial_node);
    var node = initial_node;
    // Capture phase true dispatch, root -> target call on_event_capture. Default null
    // handler zero cost; independent of bubble, can solo stop. For focus trap, scroll lock,
    // gesture arbitration ('ancestor preemption' scenarios).
    if (phase == .capture) {
        if (node.behavior.events.on_event_capture) |handler| {
            const mark = scroll_effect.enter();
            return scroll_effect.leave(event, mark, handler(event, node.behavior.events.capture_context orelse node.behavior.events.event_context));
        }
        return .ignored;
    }

    // Target's own capture handler runs at target phase, before on_event (DOM at-target
    // order): ancestor capture is root -> target (no target), target's capture here. Without it,
    // component root as focus target (Input) never sees ancestor capture. Non-ignored stops.
    if (phase == .target) {
        if (node.behavior.events.on_event_capture) |handler| {
            const mark = scroll_effect.enter();
            const result = scroll_effect.leave(event, mark, handler(event, node.behavior.events.capture_context orelse node.behavior.events.event_context));
            if (result != .ignored) return result;
            node = target.resolve() orelse return .ignored;
        }
    }

    if (event == .click) {
        return invokeClickHandler(target, event, phase);
    }

    // Call generic event handler (if any)
    if (node.behavior.events.on_event) |handler| {
        const mark = scroll_effect.enter();
        const result = scroll_effect.leave(event, mark, handler(event, node.behavior.events.event_context));
        if (result != .ignored) return result;
        node = target.resolve() orelse return .ignored;
    }

    // on_event ignored/absent -> fallthrough to event-specific handler.
    switch (event) {
        .key_down => |ke| {
            if (node.behavior.events.on_key_down) |kh| {
                return kh(ke.key, ke.modifiers, node.behavior.events.key_context);
            }
        },
        .key_up => |ke| {
            if (node.behavior.events.on_key_up) |kh| {
                return kh(ke.key, ke.modifiers, node.behavior.events.key_context);
            }
        },
        .scroll => |se| {
            if (node.behavior.events.on_scroll) |sh| {
                const mark = scroll_effect.enter();
                return scroll_effect.leave(event, mark, sh(se, node.behavior.events.event_context));
            }
        },
        .drag => |de| {
            // Drag-specific HandlerRef channel. updated has no handler: high-frequency position
            // stream; drop target only cares enter/leave/drop.
            switch (de.kind) {
                .entered => if (node.behavior.events.on_drag_enter) |h| {
                    h.invoke();
                    return .handled;
                },
                .exited => if (node.behavior.events.on_drag_leave) |h| {
                    h.invoke();
                    return .handled;
                },
                .dropped => if (node.behavior.events.on_drop) |h| {
                    h.invokeWithDrop(.{
                        .paths = de.paths,
                        .x = de.x,
                        .y = de.y,
                        .payload_kind = @backingInt(de.payload_kind),
                        .payload_truncated = de.payload_truncated,
                        .payload_is_untrusted = de.payload_is_untrusted,
                    });
                    return .handled;
                },
                .updated => {},
            }
        },
        else => {},
    }

    return .ignored;
}

fn invokeClickHandler(target: HandlerTarget, event: Event, phase: EventPhase) EventResult {
    var node = target.resolve() orelse return .ignored;
    var handled = false;

    if (phase == .target) {
        if (node.behavior.events.on_click) |h| {
            h.invoke();
            handled = true;
            node = target.resolve() orelse return .handled;
        }
    }

    if (node.behavior.events.on_event) |handler| {
        const result = handler(event, node.behavior.events.event_context);
        if (result != .ignored) return result;
        node = target.resolve() orelse return if (handled) .handled else .ignored;
    }

    if (phase == .bubble) {
        if (node.behavior.events.on_click) |h| {
            h.invoke();
            handled = true;
        }
    }

    return if (handled) .handled else .ignored;
}

/// Hit test: traverse children back-to-front (Z-order), find topmost match.
/// overflow_hidden nodes clip children hit area. Consider parent translate_x/translate_y
/// offset (e.g. ScrollArea scroll).
fn hitTestNode(node: *Node, x: f32, y: f32) ?*Node {
    return hitTestNodeRuntime(node, x, y, .pointer);
}

/// Hit test (no handler required), unit test helper.
fn hitTestNodeAny(node: *Node, x: f32, y: f32) ?*Node {
    return hitTestNodeRuntime(node, x, y, .inspect);
}

/// Hit query helper: unit test dispatcher, unified runtime index logic.
fn hitTestNodeRuntime(node: *Node, x: f32, y: f32, kind: core.HitQueryKind) ?*Node {
    if (!interaction_semantics.nodeParticipatesInHitTest(node)) return null;
    var registry = NodeRegistry.init(std.heap.page_allocator);
    defer registry.deinit();
    var runtime = core.InteractionIndex.init(std.heap.page_allocator);
    defer runtime.deinit();

    registry.rebuild(node) catch return null;
    runtime.rebuild(node, &registry) catch return null;
    const hit = runtime.hitTestQuery(.{
        .kind = kind,
        .world_x = x,
        .world_y = y,
    }, &registry, null) orelse return null;
    return registry.resolve(hit.handle, null);
}

// ========== Tests ==========

test "EventDispatcher: init/deinit" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.hovered_handle);
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.mouse_down_handle);
}

test "EventDispatcher: dispatch to target" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var handled = false;

    const node = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &handled;

    ctx.root = node;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, node);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(handled);
}

test "EventDispatcher: direct click dispatch invokes target on_click" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var click_count: u32 = 0;

    const node = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    node.behavior.events.on_click = core.Cx.simpleHandler(struct {
        fn handler(context: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(context));
            ptr.* += 1;
        }
    }.handler, &click_count);

    ctx.root = node;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, node);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), click_count);
}

test "EventDispatcher: bubble propagation" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var parent_received = false;

    const parent = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    parent.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    parent.behavior.events.event_context = &parent_received;

    const child = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});

    try parent.appendChild(std.testing.allocator, child);
    ctx.root = parent;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, child);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(parent_received);
}

test "EventDispatcher: stop propagation" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var bubble_count: u32 = 0;

    const parent = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});

    const middle = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 150 },
    }, .{});
    middle.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            const ptr: *u32 = @ptrCast(@alignCast(context.?));
            ptr.* += 1;
            return .handled;
        }
    }.handler;
    middle.behavior.events.event_context = &bubble_count;

    const child = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});
    child.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            _ = event;
            _ = context;
            return .stop;
        }
    }.handler;

    try middle.appendChild(std.testing.allocator, child);
    try parent.appendChild(std.testing.allocator, middle);
    ctx.root = parent;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .click = .{ .x = 50, .y = 50 } }, child);
    try std.testing.expectEqual(EventResult.stop, result);
    // click never fires capture; child stop at target -> middle bubble should not fire.
    try std.testing.expectEqual(@as(u32, 0), bubble_count);
}

test "EventDispatcher: bubbling skips nodes torn down during target handler" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var target_calls: u32 = 0;
    var parent_calls: u32 = 0;

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});

    const parent = try core.box(ctx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 180 },
    }, .{});
    parent.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const calls: *u32 = @ptrCast(@alignCast(context.?));
                    calls.* += 1;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    parent.behavior.events.event_context = &parent_calls;

    const child = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    const TearDownCtx = struct {
        cx: *core.Cx,
        root: *core.Node,
        parent: *core.Node,
        calls: *u32,
    };
    var teardown_ctx = TearDownCtx{
        .cx = ctx,
        .root = root,
        .parent = parent,
        .calls = &target_calls,
    };
    child.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const td: *TearDownCtx = @ptrCast(@alignCast(context.?));
                    td.calls.* += 1;
                    td.cx.detachChild(td.root, td.parent);
                    td.cx.freeNode(td.parent);
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    child.behavior.events.event_context = &teardown_ctx;

    try parent.appendChild(std.testing.allocator, child);
    try root.appendChild(std.testing.allocator, parent);
    ctx.root = root;
    ctx.layout();

    const result = dispatcher.dispatch(Event{ .mouse_up = .{ .x = 12, .y = 18 } }, child);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), target_calls);
    try std.testing.expectEqual(@as(u32, 0), parent_calls);
}

test "EventDispatcher: mouse hover" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const HoverCtx = struct {
        hover_count: u32 = 0,
        leave_count: u32 = 0,
    };
    var hover_ctx = HoverCtx{};

    const root = try core.box(ctx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const btn = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 50 },
    }, .{});
    btn.behavior.events.on_hover = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const hc: *HoverCtx = @ptrCast(@alignCast(c));
            hc.hover_count += 1;
        }
    }.handler, &hover_ctx);
    btn.behavior.events.on_leave = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const hc: *HoverCtx = @ptrCast(@alignCast(c));
            hc.leave_count += 1;
        }
    }.handler, &hover_ctx);

    try root.appendChild(std.testing.allocator, btn);
    ctx.root = root;
    ctx.layout();

    // Move into button area
    _ = dispatcher.dispatchMouseMove(10, 10, hitTestNode(root, 10, 10));
    try std.testing.expectEqual(@as(u32, 1), hover_ctx.hover_count);

    // Move out
    _ = dispatcher.dispatchMouseMove(300, 300, hitTestNode(root, 300, 300));
    try std.testing.expectEqual(@as(u32, 1), hover_ctx.leave_count);
}

const StationaryHoverRig = struct {
    const Log = struct { enters: [2]u32 = .{ 0, 0 }, leaves: [2]u32 = .{ 0, 0 }, moves: u32 = 0, clicks: u32 = 0 };
    const Tag = struct { log: *Log, index: usize };

    fn onEvent(event: Event, context: ?*anyopaque) EventResult {
        const tag: *Tag = @ptrCast(@alignCast(context.?));
        switch (event) {
            .mouse_enter => tag.log.enters[tag.index] += 1,
            .mouse_leave => tag.log.leaves[tag.index] += 1,
            .mouse_move => tag.log.moves += 1,
            .click => tag.log.clicks += 1,
            else => {},
        }
        return .ignored;
    }

    fn row(cx: *core.Cx, root: *Node, tag: *Tag) !*Node {
        const node = try core.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
        node.behavior.events.on_event = onEvent;
        node.behavior.events.event_context = tag;
        try root.appendChild(std.testing.allocator, node);
        return node;
    }
};

test "EventDispatcher: stationary hover re-resolution sends enter/leave but no mouse_move" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var log = StationaryHoverRig.Log{};
    var tags = [_]StationaryHoverRig.Tag{ .{ .log = &log, .index = 0 }, .{ .log = &log, .index = 1 } };
    const root = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
    const a = try StationaryHoverRig.row(ctx, root, &tags[0]);
    const b = try StationaryHoverRig.row(ctx, root, &tags[1]);
    ctx.root = root;
    ctx.layout();

    _ = dispatcher.dispatchMouseMove(10, 10, a);
    try std.testing.expectEqual(@as(u32, 1), log.moves);
    try std.testing.expect(dispatcher.hoverFollowsScene());
    // Content moved under the pointer: b is now there.
    try std.testing.expectEqual(b, dispatcher.reconcileHover(b).?);
    try std.testing.expectEqual(@as(u32, 1), log.leaves[0]);
    try std.testing.expectEqual(@as(u32, 1), log.enters[1]);
    try std.testing.expectEqual(@as(u32, 1), log.moves);
    // Same target again: no duplicate transition.
    _ = dispatcher.reconcileHover(b);
    try std.testing.expectEqual(@as(u32, 1), log.enters[1]);
    // Nothing under the pointer any more.
    try std.testing.expect(dispatcher.reconcileHover(null) == null);
    try std.testing.expectEqual(@as(u32, 1), log.leaves[1]);
}

test "EventDispatcher: press and capture defer stationary hover; cancel ends the press" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var log = StationaryHoverRig.Log{};
    var tags = [_]StationaryHoverRig.Tag{ .{ .log = &log, .index = 0 }, .{ .log = &log, .index = 1 } };
    const root = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
    const a = try StationaryHoverRig.row(ctx, root, &tags[0]);
    const b = try StationaryHoverRig.row(ctx, root, &tags[1]);
    ctx.root = root;
    ctx.layout();
    _ = dispatcher.dispatchMouseMove(10, 10, a);

    // Left press in progress: hover belongs to the sequence.
    _ = dispatcher.dispatchMouseDown(10, 10, a, .{});
    try std.testing.expect(!dispatcher.hoverFollowsScene());
    try std.testing.expectEqual(a, dispatcher.reconcileHover(b).?);
    try std.testing.expectEqual(@as(u32, 0), log.leaves[0]);
    dispatcher.dispatchMouseUp(10, 10, a);
    try std.testing.expect(dispatcher.hoverFollowsScene());
    try std.testing.expectEqual(@as(u32, 1), log.clicks);

    // Capture (drag) likewise.
    dispatcher.setPointerCapture(a);
    try std.testing.expect(!dispatcher.hoverFollowsScene());
    try std.testing.expectEqual(a, dispatcher.reconcileHover(b).?);
    dispatcher.releasePointerCapture();
    try std.testing.expect(dispatcher.hoverFollowsScene());

    // A cancelled press (blur / pointer cancel) must not keep deferring: the release may never
    // arrive. A late release dispatches no click.
    _ = dispatcher.dispatchMouseDown(10, 10, a, .{});
    try std.testing.expect(!dispatcher.hoverFollowsScene());
    dispatcher.cancelActivePress();
    try std.testing.expect(dispatcher.hoverFollowsScene());
    try std.testing.expectEqual(b, dispatcher.reconcileHover(b).?);
    try std.testing.expectEqual(@as(u32, 1), log.leaves[0]);
    dispatcher.dispatchMouseUp(10, 10, a);
    try std.testing.expectEqual(@as(u32, 1), log.clicks);
}

test "EventDispatcher: scroll momentum keeps session owner despite hover target change" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const C = struct {
        left: u32 = 0,
        right: u32 = 0,
    };
    var counter = C{};

    const root = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});

    const left = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .scroll => {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.left += 1;
                    return .stop;
                },
                else => return .ignored,
            }
        }
    }.handler;
    left.behavior.events.event_context = &counter;

    const right = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    right.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .scroll => {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.right += 1;
                    return .stop;
                },
                else => return .ignored,
            }
        }
    }.handler;
    right.behavior.events.event_context = &counter;

    try root.appendChild(std.testing.allocator, left);
    try root.appendChild(std.testing.allocator, right);
    ctx.root = root;
    ctx.layout();
    // Touch hits left, build scroll session owner
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -8, .phase = .began }, hitTestNode(root, 20, 20));
    // Touch ends, transfer session owner to momentum owner
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = 0, .phase = .ended }, hitTestNode(root, 20, 20));
    // Momentum still dispatches to left despite pointer over right
    _ = dispatcher.dispatchScroll(.{ .x = 220, .y = 20, .dx = 0, .dy = -6, .momentum = .changed }, hitTestNode(root, 220, 20));

    try std.testing.expectEqual(@as(u32, 3), counter.left);
    try std.testing.expectEqual(@as(u32, 0), counter.right);
}

fn scrollSessionFixture(ctx: *core.Cx, counts: *[2]u32) !*Node {
    const root = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});
    for (counts) |*slot| {
        const pane = try core.box(ctx, .{
            .width = .{ .px = 150 },
            .height = .{ .px = 120 },
        }, .{});
        pane.behavior.events.on_event = struct {
            fn handler(event: Event, context: ?*anyopaque) EventResult {
                switch (event) {
                    .scroll => {
                        const c: *u32 = @ptrCast(@alignCast(context.?));
                        c.* += 1;
                        return .stop;
                    },
                    else => return .ignored,
                }
            }
        }.handler;
        pane.behavior.events.event_context = slot;
        try root.appendChild(std.testing.allocator, pane);
    }
    ctx.root = root;
    ctx.layout();
    return root;
}

fn scrollAt(dispatcher: *EventDispatcher, root: *Node, x: f32, phase: events.ScrollPhase, is_momentum: bool) void {
    const ev: events.ScrollEvent = .{ .x = x, .y = 20, .dx = 0, .dy = -8, .phase = phase, .momentum = if (is_momentum) .changed else .none };
    dispatcher.beginScrollEvent(ev);
    _ = dispatcher.dispatchScroll(ev, hitTestNode(root, x, 20));
}

test "EventDispatcher: began starts a new session even if the previous gesture never ended" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    // Old gesture on left, ended lost
    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .changed, false);
    // New gesture on right: began re-locks by hit
    scrollAt(&dispatcher, root, 220, .began, false);
    scrollAt(&dispatcher, root, 220, .changed, false);

    // left: began + changed + synthesized cancelled on new gesture start
    try std.testing.expectEqual(@as(u32, 3), counts[0]);
    try std.testing.expectEqual(@as(u32, 2), counts[1]);
}

test "EventDispatcher: changed keeps the gesture owner when the hit target moves" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 220, .changed, false);
    scrollAt(&dispatcher, root, 220, .ended, false);

    try std.testing.expectEqual(@as(u32, 3), counts[0]);
    try std.testing.expectEqual(@as(u32, 0), counts[1]);
}

test "EventDispatcher: cancelled releases the owner without handing it to momentum" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .cancelled, false);
    scrollAt(&dispatcher, root, 20, .none, true); // No gesture momentum -> discard
    try std.testing.expectEqual(@as(u32, 2), counts[0]);

    // Next scroll dispatches by hit, not old owner
    scrollAt(&dispatcher, root, 220, .changed, false);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: a new gesture cancels the previous one whose ended was lost" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const Phases = struct { cancelled: u32 = 0, began: u32 = 0 };
    var left_phases = Phases{};
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);
    const left = root.children.items[0];
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Phases = @ptrCast(@alignCast(context.?));
            switch (event) {
                .scroll => |sc| switch (sc.phase) {
                    .cancelled => p.cancelled += 1,
                    .began => p.began += 1,
                    else => {},
                },
                else => {},
            }
            return .stop;
        }
    }.handler;
    left.behavior.events.event_context = &left_phases;

    // may_begin -> began same gesture: no cancel
    scrollAt(&dispatcher, root, 20, .may_begin, false);
    scrollAt(&dispatcher, root, 20, .began, false);
    try std.testing.expectEqual(@as(u32, 0), left_phases.cancelled);
    scrollAt(&dispatcher, root, 20, .changed, false);
    // ended lost, new gesture from right: left gets synthesized cancelled
    scrollAt(&dispatcher, root, 220, .began, false);
    try std.testing.expectEqual(@as(u32, 1), left_phases.cancelled);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: cancelScrollGesture still ends momentum when the cancel handler re-enters" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    const Probe = struct {
        dispatcher: *EventDispatcher,
        root: *Node,
        momentum_ended_on_left: u32 = 0,
    };
    var probe = Probe{ .dispatcher = &dispatcher, .root = root };
    const left = root.children.items[0];
    const right = root.children.items[1];
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Probe = @ptrCast(@alignCast(context.?));
            if (event == .scroll and event.scroll.momentum == .ended) p.momentum_ended_on_left += 1;
            return .stop;
        }
    }.handler;
    left.behavior.events.event_context = &probe;
    right.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const p: *Probe = @ptrCast(@alignCast(context.?));
            // Re-enter scroll dispatch during synthesized cancelled
            if (event == .scroll and event.scroll.phase == .cancelled) {
                _ = p.dispatcher.dispatchScroll(.{ .x = 220, .y = 20, .dx = 0, .dy = -3, .phase = .changed }, hitTestNode(p.root, 220, 20));
            }
            return .stop;
        }
    }.handler;
    right.behavior.events.event_context = &probe;

    // left's gesture ends normally, momentum -> left
    scrollAt(&dispatcher, root, 20, .began, false);
    scrollAt(&dispatcher, root, 20, .ended, false);
    // right's gesture ended lost
    scrollAt(&dispatcher, root, 220, .began, false);
    // Manually restore left's momentum to construct both coexisting
    dispatcher.scroll_momentum_owner = ctx.node_registry.handleFor(left);
    probe.momentum_ended_on_left = 0;

    dispatcher.cancelScrollGesture();
    try std.testing.expectEqual(@as(u32, 1), probe.momentum_ended_on_left);
}

// Precondition lock: via the real scroll entry (beginScrollEvent + dispatchScroll), gesture
// owner and momentum owner are never both non-null during a callback or post-event.
// cancelScrollGesture re-resolves the handle between dispatches and does not rely on this
// for safety; this locks the behavior 'system interrupt synthesizes at most one end signal'.
// Exhausts 2 positions * 9 event types * 4-step sequences. Check inside handlers
// (cancelPointerInteractions can call cancelScrollGesture from a handler).
test "EventDispatcher: scroll session owner and momentum owner are never both set" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    const Check = struct {
        var d: *EventDispatcher = undefined;
        var violations: u32 = 0;
        fn check() void {
            if (d.scroll_session_owner != null and d.scroll_momentum_owner != null) violations += 1;
        }
        fn handler(event: Event, _: ?*anyopaque) EventResult {
            if (event == .scroll) check();
            return .stop;
        }
    };
    Check.d = &dispatcher;
    Check.violations = 0;
    for (root.children.items) |pane| {
        pane.behavior.events.on_event = Check.handler;
        pane.behavior.events.event_context = null;
    }

    const Kind = struct { phase: events.ScrollPhase, momentum: events.MomentumPhase };
    const kinds = [_]Kind{
        .{ .phase = .none, .momentum = .none },
        .{ .phase = .may_begin, .momentum = .none },
        .{ .phase = .began, .momentum = .none },
        .{ .phase = .changed, .momentum = .none },
        .{ .phase = .ended, .momentum = .none },
        .{ .phase = .cancelled, .momentum = .none },
        .{ .phase = .none, .momentum = .began },
        .{ .phase = .none, .momentum = .changed },
        .{ .phase = .none, .momentum = .ended },
    };
    const xs = [_]f32{ 20, 220 };
    const steps = 4;
    const alphabet = kinds.len * xs.len;
    var total: usize = 1;
    for (0..steps) |_| total *= alphabet;
    var seq: usize = 0;
    while (seq < total) : (seq += 1) {
        dispatcher.cancelScrollGesture();
        var code = seq;
        for (0..steps) |_| {
            const sym = code % alphabet;
            code /= alphabet;
            const k = kinds[sym % kinds.len];
            const x = xs[sym / kinds.len];
            const ev: events.ScrollEvent = .{ .x = x, .y = 20, .dx = 0, .dy = -8, .phase = k.phase, .momentum = k.momentum };
            dispatcher.beginScrollEvent(ev);
            _ = dispatcher.dispatchScroll(ev, hitTestNode(root, x, 20));
            Check.check();
        }
    }
    try std.testing.expectEqual(@as(u32, 0), Check.violations);
}

test "EventDispatcher: mouse wheel follows the hit target on every event" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .none, false);
    scrollAt(&dispatcher, root, 220, .none, false);

    try std.testing.expectEqual(@as(u32, 1), counts[0]);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
}

test "EventDispatcher: mouse wheel leaves no session for a later trackpad stream" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);
    var counts = [2]u32{ 0, 0 };
    const root = try scrollSessionFixture(ctx, &counts);

    scrollAt(&dispatcher, root, 20, .none, false);
    // Trackpad stream lacking began (old harness shape): lock by own hit, not sticky to wheel.
    scrollAt(&dispatcher, root, 220, .changed, false);
    scrollAt(&dispatcher, root, 220, .ended, false);

    try std.testing.expectEqual(@as(u32, 1), counts[0]);
    try std.testing.expectEqual(@as(u32, 2), counts[1]);
}

test "EventDispatcher: momentum owner missing should not fall back to current hover target" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const C = struct {
        right: u32 = 0,
    };
    var counter = C{};

    const root1 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});
    const left1 = try core.box(ctx, .{
        .width = .{ .px = 150 },
        .height = .{ .px = 120 },
    }, .{});
    left1.behavior.events.on_event = struct {
        fn handler(event: Event, _: ?*anyopaque) EventResult {
            return switch (event) {
                .scroll => .stop,
                else => .ignored,
            };
        }
    }.handler;
    try root1.appendChild(std.testing.allocator, left1);
    ctx.root = root1;
    ctx.layout();

    // Establish momentum owner = left1
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -8, .phase = .changed }, hitTestNode(root1, 20, 20));
    _ = dispatcher.dispatchScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -6, .momentum = .changed }, hitTestNode(root1, 20, 20));

    // New tree lacks left1, only right2; momentum should not fallback-hit right2.
    const root2 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    const right2 = try core.box(ctx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    right2.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            return switch (event) {
                .scroll => blk: {
                    const c: *C = @ptrCast(@alignCast(context.?));
                    c.right += 1;
                    break :blk .stop;
                },
                else => .ignored,
            };
        }
    }.handler;
    right2.behavior.events.event_context = &counter;
    try root2.appendChild(std.testing.allocator, right2);

    const r = dispatcher.dispatchScroll(.{ .x = 200, .y = 20, .dx = 0, .dy = -5, .momentum = .changed }, hitTestNode(root2, 200, 20));
    try std.testing.expectEqual(EventResult.ignored, r);
    try std.testing.expectEqual(@as(u32, 0), counter.right);

    // Manually release root2 tree (outside ctx.root, not auto-freed by ctx.deinit)
    ctx.freeNode(root2);
}

test "hitTest: overflow_hidden container passthrough" {
    // Simulate ScrollArea structure: container(overflow_hidden) > content > button
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    // Root node
    const root = try core.box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
    }, .{});
    ctx.root = root;

    // ScrollArea container: overflow_hidden + on_event
    const container = try core.box(ctx, .{
        .width = .{ .px = 600 },
        .height = .{ .px = 400 },
        .overflow_hidden = true,
    }, .{});
    container.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;
    try root.appendChild(std.testing.allocator, container);

    // content: fit height, grow width
    const content = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    try container.appendChild(std.testing.allocator, content);

    // button inside content
    const btn = try core.box(ctx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 32 },
    }, .{});
    btn.tag = .button;
    try content.appendChild(std.testing.allocator, btn);

    // Layout
    ctx.layout();

    // Verify layout correct
    std.debug.print("\n[TEST] container rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ container.rectFromWorldOrFallback().x, container.rectFromWorldOrFallback().y, container.rectFromWorldOrFallback().w, container.rectFromWorldOrFallback().h });
    std.debug.print("[TEST] content rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ content.rectFromWorldOrFallback().x, content.rectFromWorldOrFallback().y, content.rectFromWorldOrFallback().w, content.rectFromWorldOrFallback().h });
    std.debug.print("[TEST] btn rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ btn.rectFromWorldOrFallback().x, btn.rectFromWorldOrFallback().y, btn.rectFromWorldOrFallback().w, btn.rectFromWorldOrFallback().h });

    // hitTest on button area should hit button, not container
    const hit = hitTestNode(root, 50, 16);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(btn, hit.?);
}

test "hitTest: ScrollArea with padding and nested sections" {
    // Simulate storybook structure:
    // root(1400x900)
    //   main_area
    //     header(h=56)
    //     scroll_container(overflow_hidden, on_event, padding=32)
    //       content(fit height, grow width, direction=column)
    //         section(card)
    //           row(direction=row)
    //             radio_container(tag=button, on_event)
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 1400 }, .height = .{ .px = 900 } }, .{});
    ctx.root = root;

    // main area
    const main_area = try core.box(ctx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 900 },
        .direction = .column,
    }, .{});
    try root.appendChild(std.testing.allocator, main_area);

    // header
    const header = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 56 },
    }, .{});
    try main_area.appendChild(std.testing.allocator, header);

    // scroll container (like ScrollArea)
    const scroll = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 844 },
        .overflow_hidden = true,
        .padding = core.Padding.all(32),
        .direction = .column,
    }, .{});
    scroll.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;
    try main_area.appendChild(std.testing.allocator, scroll);

    // content
    const content = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    try scroll.appendChild(std.testing.allocator, content);

    // section
    const section = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 8,
    }, .{});
    try content.appendChild(std.testing.allocator, section);

    // row
    const row = try core.box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 16,
    }, .{});
    try section.appendChild(std.testing.allocator, row);

    // radio container (tag=button, on_event)
    const radio = try core.box(ctx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 8,
    }, .{});
    radio.tag = .button;
    radio.behavior.events.on_event = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .handled;
        }
    }.handler;
    try row.appendChild(std.testing.allocator, radio);

    // radio circle
    const circle = try core.box(ctx, .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
    }, .{});
    try radio.appendChild(std.testing.allocator, circle);

    ctx.layout();

    std.debug.print("\n[TEST2] main_area rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ main_area.rectFromWorldOrFallback().x, main_area.rectFromWorldOrFallback().y, main_area.rectFromWorldOrFallback().w, main_area.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] header rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ header.rectFromWorldOrFallback().x, header.rectFromWorldOrFallback().y, header.rectFromWorldOrFallback().w, header.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] scroll rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ scroll.rectFromWorldOrFallback().x, scroll.rectFromWorldOrFallback().y, scroll.rectFromWorldOrFallback().w, scroll.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] content rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ content.rectFromWorldOrFallback().x, content.rectFromWorldOrFallback().y, content.rectFromWorldOrFallback().w, content.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] section rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ section.rectFromWorldOrFallback().x, section.rectFromWorldOrFallback().y, section.rectFromWorldOrFallback().w, section.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] row rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ row.rectFromWorldOrFallback().x, row.rectFromWorldOrFallback().y, row.rectFromWorldOrFallback().w, row.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] radio rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ radio.rectFromWorldOrFallback().x, radio.rectFromWorldOrFallback().y, radio.rectFromWorldOrFallback().w, radio.rectFromWorldOrFallback().h });
    std.debug.print("[TEST2] circle rect: ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ circle.rectFromWorldOrFallback().x, circle.rectFromWorldOrFallback().y, circle.rectFromWorldOrFallback().w, circle.rectFromWorldOrFallback().h });

    // hitTest on radio area should hit radio (tag=button)
    const radio_global = radio.globalRect();
    const radio_center_x = radio_global.x + radio_global.w / 2;
    const radio_center_y = radio_global.y + radio_global.h / 2;
    std.debug.print("[TEST2] hitTest at ({d:.0},{d:.0})\n", .{ radio_center_x, radio_center_y });

    const hit = hitTestNode(root, radio_center_x, radio_center_y);
    try std.testing.expect(hit != null);
    std.debug.print("[TEST2] hit: id={d} tag={s}\n", .{ hit.?.id, @tagName(hit.?.tag) });
    try std.testing.expectEqual(radio, hit.?);
}

test "hitTest: opacity zero nodes do not participate" {
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    ctx.root = root;

    const visible = try core.box(ctx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    }, .{});
    visible.tag = .button;
    try root.appendChild(std.testing.allocator, visible);

    const hidden = try core.box(ctx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    }, .{});
    hidden.tag = .button;
    hidden.setOpacityRaw(0);
    try root.appendChild(std.testing.allocator, hidden);

    ctx.layout();

    const hit = hitTestNode(root, 20, 20);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(visible, hit.?);
}

test "hitTestAny: positive z does not escape overflow_hidden ancestor clip" {
    // Plan §9.2 item 13 (invert old 'overlay escapes overflow_hidden ancestor clip'):
    // z_index only affects sibling order, z>0 nodes still clipped by overflow_hidden ancestor
    // (hit and pixels match).
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    ctx.root = root;

    const clipper = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(std.testing.allocator, clipper);

    const overlay = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
    }, .{});
    overlay.style.ensureExtPanic(std.testing.allocator).z_index = 10;
    try clipper.appendChild(std.testing.allocator, overlay);

    ctx.layout();
    {
        // Spans clipper right-bottom: (20..60) and clipper (0..40) overlap 20x20 top-left only.
        const r = overlay.rectFromWorldOrFallback();
        overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = r.w, .h = r.h });
    }

    // Outside clipper, inside overlay -> no hit (old impl hit it).
    const outside = hitTestNodeAny(root, 50, 50);
    try std.testing.expect(outside != overlay);
    try std.testing.expect(outside == null or outside.? == root);
    // Overlap within clipper -> hit overlay.
    const inside = hitTestNodeAny(root, 30, 30);
    try std.testing.expect(inside != null);
    try std.testing.expectEqual(overlay, inside.?);
}

test "hitTest: runtime helper matches interaction index for hidden and overlay cases" {
    const allocator = std.testing.allocator;
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var index = core.InteractionIndex.init(allocator);
    defer index.deinit();

    var ctx = try core.Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try core.box(ctx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 220 },
    }, .{});
    ctx.root = root;

    const regular = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    regular.tag = .button;
    try root.appendChild(allocator, regular);

    const hidden = try core.box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    hidden.tag = .button;
    hidden.setOpacityRaw(0);
    try root.appendChild(allocator, hidden);

    const clipper = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(allocator, clipper);

    const overlay = try core.box(ctx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
    }, .{});
    overlay.tag = .button;
    overlay.style.ensureExtPanic(allocator).z_index = 10;
    try clipper.appendChild(allocator, overlay);

    ctx.layout();
    {
        const rr = regular.rectFromWorldOrFallback();
        regular.setLayoutRect(.{ .x = 0, .y = 0, .w = rr.w, .h = rr.h });
        const hr = hidden.rectFromWorldOrFallback();
        hidden.setLayoutRect(.{ .x = 0, .y = 0, .w = hr.w, .h = hr.h });
        const cr = clipper.rectFromWorldOrFallback();
        clipper.setLayoutRect(.{ .x = 0, .y = 0, .w = cr.w, .h = cr.h });
        // Overlay spans clipper right-bottom: (20..60) and clipper (0..40) overlap 20x20.
        const or_ = overlay.rectFromWorldOrFallback();
        overlay.setLayoutRect(.{ .x = 20, .y = 20, .w = or_.w, .h = or_.h });
    }

    try registry.rebuild(root);
    try index.rebuild(root, &registry);

    // Inside clipper: z=10 overlay over regular; both paths match.
    const tree_overlay = hitTestNode(root, 30, 30);
    const index_overlay = index.hitTestQuery(.{ .kind = .pointer, .world_x = 30, .world_y = 30 }, &registry, null);
    try std.testing.expect(tree_overlay != null);
    try std.testing.expect(index_overlay != null);
    try std.testing.expectEqual(overlay.id, tree_overlay.?.id);
    try std.testing.expectEqual(tree_overlay.?.id, index_overlay.?.handle.id);

    // Outside clipper, inside overlay rect: overlay clipped, hit falls through to regular; paths
    // match.
    const tree_clipped = hitTestNode(root, 50, 50);
    const index_clipped = index.hitTestQuery(.{ .kind = .pointer, .world_x = 50, .world_y = 50 }, &registry, null);
    try std.testing.expect(tree_clipped != null);
    try std.testing.expect(index_clipped != null);
    try std.testing.expectEqual(regular.id, tree_clipped.?.id);
    try std.testing.expectEqual(tree_clipped.?.id, index_clipped.?.handle.id);

    const tree_regular = hitTestNode(root, 10, 10);
    const index_regular = index.hitTestQuery(.{ .kind = .pointer, .world_x = 10, .world_y = 10 }, &registry, null);
    try std.testing.expect(tree_regular != null);
    try std.testing.expect(index_regular != null);
    try std.testing.expectEqual(tree_regular.?.id, index_regular.?.handle.id);
}

test "on_key_down: basic key event" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var key_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &key_received;
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();

    const result = dispatcher.dispatchKeyDown(node, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(key_received);
}

test "on_key_down: bubbles to parent" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var parent_key_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    parent_node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    parent_node.behavior.events.key_context = &parent_key_received;
    try root.appendChild(std.testing.allocator, parent_node);

    const child = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try parent_node.appendChild(std.testing.allocator, child);

    ctx.layout();

    // Dispatch to child, child has no handler, should bubble to parent's on_key_down
    const result = dispatcher.dispatchKeyDown(child, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(parent_key_received);
}

test "on_event takes priority over on_key_down" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var on_event_called = false;
    var on_key_down_called = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &on_event_called;
    node.behavior.events.on_key_down = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &on_key_down_called;
    try root.appendChild(std.testing.allocator, node);

    ctx.layout();

    _ = dispatcher.dispatchKeyDown(node, .{ .key = .a, .modifiers = .{} });
    // on_event handled the event, on_key_down should NOT be called
    try std.testing.expect(on_event_called);
    try std.testing.expect(!on_key_down_called);
}

test "PointerCapture: mouse_move goes to capture node" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var capture_received = false;
    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    // Normal node at (0,0,200,150)
    const normal_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    normal_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    normal_node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, normal_node);

    // Capture node at (200,0,200,150)
    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &capture_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    // Set pointer capture to capture_node
    dispatcher.setPointerCapture(capture_node);

    // Move mouse over normal_node area, should go to capture_node instead
    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(capture_received);
    try std.testing.expect(!normal_received);
}

test "PointerCapture: auto release on mouse_up" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var up_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_up => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &up_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    dispatcher.setPointerCapture(capture_node);
    try std.testing.expect(dispatcher.pointer_capture_handle != null);

    // Mouse up, should go to capture_node and auto-release
    dispatcher.dispatchMouseUp(300, 200, hitTestNode(root, 300, 200));
    try std.testing.expect(up_received);
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.pointer_capture_handle);
}

test "PointerCapture: double click is synthesized on the capture node" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var dbl_count: u32 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const host = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    host.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .double_click => {
                    const ptr: *u32 = @ptrCast(@alignCast(context.?));
                    ptr.* += 1;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    host.behavior.events.event_context = &dbl_count;
    try root.appendChild(std.testing.allocator, host);
    ctx.setViewport(400, 300);
    ctx.layout();

    // Canvas host mode: each down -> capture (drag requires), up -> auto-release.
    // Double-click = two down/up rounds; second up must synthesize double_click in capture path.
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        const t = hitTestNode(root, 100, 100);
        _ = dispatcher.dispatchMouseDown(100, 100, t, .{});
        dispatcher.setPointerCapture(host);
        dispatcher.dispatchMouseUp(100, 100, t);
    }
    try std.testing.expectEqual(@as(u32, 1), dbl_count);
}

test "PointerCapture: uses handle-based state" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var capture_received = false;
    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const normal_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    normal_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    normal_node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, normal_node);

    const capture_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    capture_node.behavior.events.on_event = struct {
        fn handler(_: Event, context: ?*anyopaque) EventResult {
            const ptr: *bool = @ptrCast(@alignCast(context.?));
            ptr.* = true;
            return .handled;
        }
    }.handler;
    capture_node.behavior.events.event_context = &capture_received;
    try root.appendChild(std.testing.allocator, capture_node);

    ctx.setViewport(400, 300);
    ctx.layout();

    dispatcher.setPointerCapture(capture_node);
    try std.testing.expect(dispatcher.pointer_capture_handle != null);

    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(capture_received);
    try std.testing.expect(!normal_received);
}

test "EventDispatcher: mouse down stores handle" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;
    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    try std.testing.expect(dispatcher.mouse_down_handle != null);
}

test "EventDispatcher: mouse move stores hover handle" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;
    ctx.layout();

    _ = dispatcher.dispatchMouseMove(20, 20, node);
    try std.testing.expect(dispatcher.hovered_handle != null);
}

test "EventDispatcher: double click skips freed target after click handler teardown" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    const TestCtx = struct {
        cx: *core.Cx,
        parent: *core.Node,
        node: *core.Node,
        click_count: u32 = 0,
        double_click_count: u32 = 0,
    };
    var test_ctx = TestCtx{
        .cx = ctx,
        .parent = root,
        .node = node,
    };
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const tc: *TestCtx = @ptrCast(@alignCast(context.?));
            switch (event) {
                .click => {
                    tc.click_count += 1;
                    tc.cx.detachChild(tc.parent, tc.node);
                    tc.cx.freeNode(tc.node);
                },
                .double_click => {
                    tc.double_click_count += 1;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &test_ctx;
    try root.appendChild(std.testing.allocator, node);

    ctx.setViewport(200, 100);
    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.last_click_pos = .{ 20, 20 };
    dispatcher.last_click_instant = @import("zenit_time").Instant.now(std.testing.io) catch null;
    dispatcher.consecutive_clicks = 1;

    dispatcher.dispatchMouseUp(20, 20, node);

    try std.testing.expectEqual(@as(u32, 1), test_ctx.click_count);
    try std.testing.expectEqual(@as(u32, 0), test_ctx.double_click_count);
}

test "EventDispatcher: registry mode with invalid handle falls back to raw target" {
    // When handle invalid (generation mismatch / registry unregistered), fallback to raw ptr.
    // Avoids dropping events from unregistered nodes.
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, node);
    ctx.setViewport(200, 100);
    ctx.layout();

    const invalid_handle = NodeHandle{ .id = node.id, .generation = 999999 };
    try std.testing.expect(dispatcher.resolveHandle(invalid_handle) == null);
    // Fallback to raw -> return node ptr.
    try std.testing.expect(resolveDispatchTarget(&dispatcher, invalid_handle, node) == node);
}

test "PointerCapture: normal when no capture" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var normal_received = false;

    const root = try core.box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 150 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .mouse_move => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                },
                else => {},
            }
            return .handled;
        }
    }.handler;
    node.behavior.events.event_context = &normal_received;
    try root.appendChild(std.testing.allocator, node);

    ctx.setViewport(400, 300);
    ctx.layout();

    // No capture, normal dispatch
    try std.testing.expectEqual(@as(?NodeHandle, null), dispatcher.pointer_capture_handle);
    _ = dispatcher.dispatchMouseMove(50, 50, hitTestNode(root, 50, 50));
    try std.testing.expect(normal_received);
}

test "EventDispatcher: dispatchKeyUp invokes on_key_up" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    var key_up_count: u32 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    node.behavior.events.on_key_up = struct {
        fn handler(_: core.KeyCode, _: core.Modifiers, context: ?*anyopaque) EventResult {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &key_up_count;
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    ctx.layout();

    const result = dispatcher.dispatchKeyUp(node, .{ .key = .a, .modifiers = .{} });
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(u32, 1), key_up_count);
}

const MouseUpProbe = struct {
    up_modifiers: core.Modifiers = .{},
    click_modifiers: core.Modifiers = .{},
    up_count: u32 = 0,

    fn onEvent(event: core.Event, context: ?*anyopaque) EventResult {
        const self: *MouseUpProbe = @ptrCast(@alignCast(context.?));
        switch (event) {
            .mouse_up => |e| {
                self.up_modifiers = e.modifiers;
                self.up_count += 1;
            },
            .click => |e| self.click_modifiers = e.modifiers,
            else => {},
        }
        return .handled;
    }
};

fn mouseUpProbeCx(ctx: *core.Cx, probe: *MouseUpProbe) !void {
    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    root.behavior.events.on_event = MouseUpProbe.onEvent;
    root.behavior.events.event_context = probe;
    ctx.root = root;
    ctx.layout();
}

test "Cx: mouse_up carries release-time modifiers" {
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // Pass 1: hold Shift down -> up still Shift -> mouse_up.shift == true
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUpEx(50, 50, .left, .{ .shift = true });
    try std.testing.expectEqual(@as(u32, 1), probe.up_count);
    try std.testing.expect(probe.up_modifiers.shift);
}

test "Cx: mouse_up reflects modifier released before lift, not press-time latch" {
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // Pass 2: hold Shift down -> **release Shift before up** -> mouse_up.shift == false.
    // Proves not reusing last_modifiers (would wrongly be true).
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUpEx(50, 50, .left, .{});
    try std.testing.expect(!probe.up_modifiers.shift);

    // Synthesized click anchor still down-time, preserve existing semantics.
    try std.testing.expect(probe.click_modifiers.shift);
}

test "Cx: mouse_up without modifiers stays all-false" {
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    var probe = MouseUpProbe{};
    try mouseUpProbeCx(ctx, &probe);

    // Pass 3: no modifiers -> all false (no regression)
    ctx.handleMouseDownEx(50, 50, .left, .{});
    ctx.handleMouseUpEx(50, 50, .left, .{});
    try std.testing.expect(!probe.up_modifiers.shift);
    try std.testing.expect(!probe.up_modifiers.super);
    try std.testing.expect(!probe.up_modifiers.ctrl);
    try std.testing.expect(!probe.up_modifiers.alt);

    // Pass 4: old handleMouseUp(x, y) still compiles, behavior matches no modifiers.
    ctx.handleMouseDownEx(50, 50, .left, .{ .shift = true });
    ctx.handleMouseUp(50, 50);
    try std.testing.expect(!probe.up_modifiers.shift);
}

test "EventDispatcher: second click emits double_click" {
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();

    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    dispatcher.setRegistry(&ctx.node_registry);

    const DoubleClickState = struct {
        double_clicks: *u32,
        last_click_count: *u8,
    };

    var double_clicks: u32 = 0;
    var last_click_count: u8 = 0;

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const node = try core.box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const state: *DoubleClickState = @ptrCast(@alignCast(context.?));
            switch (event) {
                .click => |e| state.last_click_count.* = e.click_count,
                .double_click => {
                    state.double_clicks.* += 1;
                },
                else => {},
            }
            return .ignored;
        }
    }.handler;
    var state = DoubleClickState{
        .double_clicks = &double_clicks,
        .last_click_count = &last_click_count,
    };
    node.behavior.events.event_context = &state;
    try root.appendChild(std.testing.allocator, node);
    ctx.root = root;

    ctx.layout();

    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.dispatchMouseUp(20, 20, node);
    _ = dispatcher.dispatchMouseDown(20, 20, node, .{});
    dispatcher.dispatchMouseUp(20, 20, node);

    try std.testing.expectEqual(@as(u8, 2), last_click_count);
    try std.testing.expectEqual(@as(u32, 1), double_clicks);
}

test "EventDispatcher: nested dispatch preserves outer bubble path with and without registry" {
    for ([_]bool{ true, false }) |with_registry| {
        var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const a_parent = try core.box(cx, .{}, .{});
        const b_parent = try core.box(cx, .{}, .{});
        const a = try core.box(cx, .{}, .{});
        const b = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, a_parent);
        try root.appendChild(cx.allocator, b_parent);
        try a_parent.appendChild(cx.allocator, a);
        try b_parent.appendChild(cx.allocator, b);
        const State = struct {
            cx: *core.Cx,
            other: *core.Node,
            a_count: usize = 0,
            b_count: usize = 0,
            fn capture(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) {
                    _ = self.cx.dispatcher.dispatch(.{ .text_input = .{ .text = "nested" } }, self.other);
                }
                return .ignored;
            }
            fn parentA(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) self.a_count += 1;
                return .ignored;
            }
            fn parentB(e: core.Event, raw: ?*anyopaque) core.EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (e == .mouse_down) self.b_count += 1;
                return .ignored;
            }
        };
        var state = State{ .cx = cx, .other = b };
        root.behavior.events.on_event_capture = State.capture;
        root.behavior.events.event_context = &state;
        a_parent.behavior.events.on_event = State.parentA;
        a_parent.behavior.events.event_context = &state;
        b_parent.behavior.events.on_event = State.parentB;
        b_parent.behavior.events.event_context = &state;
        cx.layout();
        _ = cx.render();
        if (!with_registry) cx.dispatcher.registry = null;
        _ = cx.dispatcher.dispatch(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left, .modifiers = .{} } }, a);
        try std.testing.expectEqual(@as(usize, 0), state.b_count);
        try std.testing.expectEqual(@as(usize, 1), state.a_count);
    }
}

test "EventDispatcher: destroyed click target receives no followup handler" {
    const cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const node = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, node);
    const State = struct {
        cx: *core.Cx,
        node: *core.Node,
        followups: usize = 0,
        fn click(self: *@This()) void {
            self.cx.detachChild(self.node.parent.?, self.node);
            self.cx.freeNode(self.node);
        }
        fn event(e: core.Event, raw: ?*anyopaque) core.EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (e == .click) self.followups += 1;
            return .ignored;
        }
    };
    var state = State{ .cx = cx, .node = node };
    node.behavior.events.on_click = core.Cx.handlerFrom(State, &state, State.click);
    node.behavior.events.on_event = State.event;
    node.behavior.events.event_context = &state;
    cx.layout();
    _ = cx.render();
    _ = cx.dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0, .modifiers = .{} } }, node);
    try std.testing.expectEqual(@as(usize, 0), state.followups);
}

test "EventDispatcher: generic callback destruction suppresses specialized followups" {
    for ([_]Event{
        .{ .key_down = .{ .key = .a, .modifiers = .{} } },
        .{ .click = .{ .x = 0, .y = 0 } },
    }) |input_event| {
        const cx = try core.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const victim = try core.box(cx, .{}, .{});
        const leaf = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, victim);
        try victim.appendChild(cx.allocator, leaf);
        const State = struct {
            cx: *core.Cx,
            victim: *Node,
            followups: usize = 0,
            fn event(_: Event, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.cx.detachChild(self.victim.parent.?, self.victim);
                self.cx.freeNode(self.victim);
                return .ignored;
            }
            fn key(_: events.KeyCode, _: Modifiers, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.followups += 1;
                return .handled;
            }
            fn click(self: *@This()) void {
                self.followups += 1;
            }
        };
        var state = State{ .cx = cx, .victim = victim };
        victim.behavior.events.on_event = State.event;
        victim.behavior.events.event_context = &state;
        victim.behavior.events.on_key_down = State.key;
        victim.behavior.events.key_context = &state;
        victim.behavior.events.on_click = core.Cx.handlerFrom(State, &state, State.click);
        cx.layout();
        // Click reaches victim during bubble (generic handler before on_click).
        _ = cx.dispatcher.dispatch(input_event, if (input_event == .click) leaf else victim);
        try std.testing.expectEqual(@as(usize, 0), state.followups);
    }
}

test "EventDispatcher: mouse down returns only a surviving target" {
    for ([_]events.MouseButton{ .left, .right, .middle }) |button| {
        const cx = try core.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const node = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, node);
        const State = struct {
            cx: *core.Cx,
            node: *Node,
            fn event(_: Event, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.cx.detachChild(self.node.parent.?, self.node);
                self.cx.freeNode(self.node);
                return .handled;
            }
        };
        var state = State{ .cx = cx, .node = node };
        node.behavior.events.on_event = State.event;
        node.behavior.events.event_context = &state;
        cx.layout();
        try std.testing.expect(cx.dispatcher.dispatchMouseDownButton(0, 0, node, button, .{}) == null);
    }
}

test "dispatch: nested dispatch from handler must not clobber outer bubble path" {
    // root->A->B, root->C->D. B's mouse_up handler calls cx.setFocus(D), nested
    // blur/focus dispatch (path root->C->D). Outer bubble must still walk B->A->root,
    // not overwritten by shared path buffer.
    var ctx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const Counter = struct { n: u32 = 0 };
    var a_calls = Counter{};
    var c_calls = Counter{};
    const countUp = struct {
        fn h(e: Event, cx_: ?*anyopaque) EventResult {
            if (e == .mouse_up) @as(*Counter, @ptrCast(@alignCast(cx_.?))).n += 1;
            return .ignored;
        }
    }.h;
    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    const a = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const b = try core.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    const c = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const d = try core.box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    a.behavior.events.on_event = countUp;
    a.behavior.events.event_context = &a_calls;
    c.behavior.events.on_event = countUp;
    c.behavior.events.event_context = &c_calls;
    d.behavior.interaction.focusable = true;
    const BCtx = struct { cx: *core.Cx, d: *core.Node };
    var bctx = BCtx{ .cx = ctx, .d = d };
    b.behavior.events.on_event = struct {
        fn h(e: Event, p: ?*anyopaque) EventResult {
            const t: *BCtx = @ptrCast(@alignCast(p.?));
            if (e == .mouse_up) t.cx.setFocus(t.d);
            return .ignored;
        }
    }.h;
    b.behavior.events.event_context = &bctx;
    try a.appendChild(std.testing.allocator, b);
    try c.appendChild(std.testing.allocator, d);
    try root.appendChild(std.testing.allocator, a);
    try root.appendChild(std.testing.allocator, c);
    ctx.root = root;
    ctx.setViewport(200, 200);
    ctx.layout();
    _ = ctx.dispatcher.dispatch(Event{ .mouse_up = .{ .x = 10, .y = 10 } }, b);
    try std.testing.expectEqual(@as(u32, 1), a_calls.n);
    try std.testing.expectEqual(@as(u32, 0), c_calls.n);
}

const DeepPathProbe = struct {
    captures: usize = 0,
    clicks: usize = 0,
    bubbles: usize = 0,
    enters: usize = 0,
    leaves: usize = 0,
    fn capture(_: Event, context: ?*anyopaque) EventResult {
        const self: *DeepPathProbe = @ptrCast(@alignCast(context.?));
        self.captures += 1;
        return .stop;
    }
    fn clicked(context: *anyopaque) void {
        const self: *DeepPathProbe = @ptrCast(@alignCast(context));
        self.clicks += 1;
    }
    fn observe(event: Event, context: ?*anyopaque) EventResult {
        const self: *DeepPathProbe = @ptrCast(@alignCast(context.?));
        switch (event) {
            .click => self.bubbles += 1,
            .mouse_enter => self.enters += 1,
            .mouse_leave => self.leaves += 1,
            else => {},
        }
        return .ignored;
    }
    fn tree(self: *DeepPathProbe, cx: *core.Cx, depth: usize) !*Node {
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        root.behavior.events.on_event_capture = capture;
        root.behavior.events.capture_context = self;
        root.behavior.events.on_event = observe;
        root.behavior.events.event_context = self;
        var leaf = root;
        for (1..depth) |_| {
            const node = try core.box(cx, .{}, .{});
            try leaf.appendChild(std.testing.allocator, node);
            leaf = node;
        }
        leaf.behavior.events.on_click = core.Cx.simpleHandler(clicked, self);
        try cx.node_registry.rebuild(root);
        return leaf;
    }
};

test "deep dispatch retains root capture and bubble with and without registry" {
    for ([_]bool{ false, true }) |with_registry| {
        var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        var probe: DeepPathProbe = .{};
        const leaf = try probe.tree(cx, 180);
        var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
        defer dispatcher.deinit();
        if (with_registry) dispatcher.setRegistry(&cx.node_registry);
        const click: Event = .{ .click = .{ .x = 0, .y = 0 } };
        try std.testing.expectEqual(EventResult.stop, dispatcher.dispatch(click, leaf));
        try std.testing.expectEqual(@as(usize, 1), probe.captures);
        try std.testing.expectEqual(@as(usize, 0), probe.clicks);
        cx.root.?.behavior.events.on_event_capture = null;
        _ = dispatcher.dispatch(click, leaf);
        try std.testing.expectEqual(@as(usize, 1), probe.clicks);
        try std.testing.expectEqual(@as(usize, 1), probe.bubbles);
    }
}

test "deep dispatch allocation failures cannot bypass capture policy" {
    for (0..2) |fail_index| {
        var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        var probe: DeepPathProbe = .{};
        const leaf = try probe.tree(cx, 180);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var dispatcher = EventDispatcher.init(failing.allocator(), std.testing.io);
        defer dispatcher.deinit();
        dispatcher.setRegistry(&cx.node_registry);
        try std.testing.expectEqual(EventResult.stop, dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, leaf));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), probe.clicks);
        try std.testing.expectEqual(@as(usize, 0), probe.captures);
    }
}

test "128-node dispatch stays allocation-free" {
    var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var probe: DeepPathProbe = .{};
    const leaf = try probe.tree(cx, 128);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var dispatcher = EventDispatcher.init(failing.allocator(), std.testing.io);
    defer dispatcher.deinit();
    dispatcher.setRegistry(&cx.node_registry);
    try std.testing.expectEqual(EventResult.stop, dispatcher.dispatch(.{ .click = .{ .x = 0, .y = 0 } }, leaf));
    try std.testing.expectEqual(@as(usize, 1), probe.captures);
    try std.testing.expect(!failing.has_induced_failure);
}

test "deep hover visits root and OOM preserves prior hover transaction" {
    var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var probe: DeepPathProbe = .{};
    const leaf = try probe.tree(cx, 180);
    var dispatcher = EventDispatcher.init(std.testing.allocator, std.testing.io);
    defer dispatcher.deinit();
    dispatcher.setRegistry(&cx.node_registry);
    _ = dispatcher.syncHover(leaf);
    try std.testing.expectEqual(@as(usize, 1), probe.enters);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    dispatcher.allocator = failing.allocator();
    try std.testing.expectEqual(leaf, dispatcher.syncHover(null).?);
    try std.testing.expectEqual(@as(usize, 0), probe.leaves);
    dispatcher.allocator = std.testing.allocator;
    try std.testing.expect(dispatcher.syncHover(null) == null);
    try std.testing.expectEqual(@as(usize, 1), probe.leaves);
}
