/// OverlayStack: global floating layer manager
///
/// Three framework-level primitives in one:
/// 1. OverlayStack, auto z-index allocation + layer stack management
/// 2. DismissLayer, unified Escape / outside-click / focus-out close
/// 3. ExitTransition, deferred destroy after exit animation
///
/// Design references:
/// - CSS Top Layer FIFO semantics (later opened, higher z)
/// - Radix DismissableLayer stack-based closing
/// - GPUI deferred() + anchored() + occlude() three primitives
/// - React Stack auto z-index allocation (Math.max(value, parent) + 1)
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const ComputedRect = core.ComputedRect;
const Signal = core.Signal;
const A11yProps = core.A11yProps;
const NodeHandle = core.NodeHandle;
const Scope = @import("reactive.zig").Scope;
const overlay_transition = @import("overlay_transition.zig");
const overlay_layer_refs = @import("overlay_layer_refs.zig");
// Cx split: Transition / TransitionController extracted to overlay_transition.zig
// (progress clock + curve table, testable independently). Re-export here maintains
// existing paths like `overlay_stack_mod.Transition` (popover/sheet/modal all use).
pub const Transition = overlay_transition.Transition;
pub const TransitionController = overlay_transition.TransitionController;
// These three were private fns in this file (no external callers), keep private,
// don't expand API surface.
const transitionAffectsOpacity = overlay_transition.transitionAffectsOpacity;
const transitionAffectsTransform = overlay_transition.transitionAffectsTransform;
const layerNeedsCompositedGroup = overlay_transition.layerNeedsCompositedGroup;
// Trigger/anchor generational weak refs + liveness checks live in overlay_layer_refs.zig
// (dangling-pointer invariants pinned with tests there).
// Note: don't alias `const trackNode = overlay_layer_refs.trackNode`: OverlayStack has a
// same-name method (node_registry injected, writes back layer field), and a same-name top-level
// alias makes `self.trackNode(...)` resolution ambiguous. Use namespaced access.
const render_engine = @import("core/render_engine/mod.zig");

fn overlayDebugEnabled() bool {
    return @import("zenit_environment").flag("ZENIT_POPOVER_DEBUG");
}

fn outsideClickDebugEnabled() bool {
    return @import("zenit_environment").flag("ZENIT_DEBUG_OUTSIDE_CLICK");
}

fn nodeTestId(node: ?*Node) []const u8 {
    return if (node) |n| n.meta.ownership.meta.test_id orelse "(nil)" else "(nil)";
}

fn logOutsideClickLayer(prefix: []const u8, layer: *const OverlayLayer, target: ?*Node) void {
    if (!outsideClickDebugEnabled()) return;
    std.debug.print(
        "[overlay.outside] {s} handle={d} state={s} suspended={} skip={} dismiss={s} target={s} trigger_handle={d} content={s} content_hit_test_visible={}\n",
        .{
            prefix,
            layer.handle.id,
            @tagName(layer.state),
            layer.suspended,
            layer.skip_outside_click_frame,
            @tagName(layer.config.dismiss.outside_click),
            nodeTestId(target),
            if (layer.trigger_handle) |handle| handle.id else 0,
            nodeTestId(layer.content_node),
            layer.config.content_hit_test_visible,
        },
    );
}
const floating = @import("compute_position.zig");

// ========== Public types ==========

/// Layer handle (returned from push, used for subsequent operations)
pub const LayerHandle = struct {
    id: u32,
    z_index: i16,
};

/// Layer kind
pub const LayerKind = enum {
    /// Fullscreen modal, focus trap, Escape close
    modal,
    /// No modal, external interactive, outside-click close
    non_modal,
    /// No interaction blocking, auto-dismiss after timeout
    toast,
};

/// Semantic tier, baseline z-index table for the system-level manager.
///
/// Follows zui Stack STACKING_DEFAULT_ORDER (OVERLAY < POPOVER < DIALOG) and React Stack nested
/// inheritance: actual z = max(tier baseline + same-tier activation sequence, nested parent z + 2).
/// Tier fixes the cross-category order (tooltip always caps toast/dialog/popover regardless of open
/// order); activation sequence orders within a category (later opens higher); nested inheritance
/// ensures an overlay opened from within another overlay always caps its host layer (popover opened
/// inside a modal: popover tier baseline 100 < dialog 1000, but after inheritance >= dialog z + 2).
///
/// Tier spacing >= 1000: each tier uses 2 z per layer (barrier+content), 32 layers max within a
/// tier never reaches the next tier. devtools overlay is fixed at 32000, above all tiers.
pub const StackTier = enum {
    /// popover / menu / dropdown / select etc anchored floaters
    overlay,
    /// modal / sheet etc barrier-based dialog layers
    dialog,
    /// toast notification
    toast,
    /// tooltip, pure hint, always topmost
    tooltip,

    pub fn base(self: StackTier) i16 {
        return switch (self) {
            .overlay => 100,
            .dialog => 1000,
            .toast => 2000,
            .tooltip => 3000,
        };
    }

    /// kind -> default tier (inferred when component doesn't explicitly pass tier)
    pub fn fromKind(kind: LayerKind) StackTier {
        return switch (kind) {
            .modal => .dialog,
            .toast => .toast,
            .non_modal => .overlay,
        };
    }
};

/// Layer state
pub const LayerState = enum {
    entering,
    visible,
    exiting,
};

/// Outside-click behavior
pub const OutsideClickBehavior = enum {
    /// Don't close
    none,
    /// Notify on_dismiss only, let component decide exit
    notify,
    /// Close, event continues propagating
    close,
    /// Close and consume event
    close_and_consume,
};

/// Close behavior config
pub const DismissConfig = struct {
    outside_click: OutsideClickBehavior = .close,
    escape: bool = true,
    focus_out: bool = false,
};

/// Backdrop config
pub const BarrierConfig = union(enum) {
    none,
    color: Color,
};

/// Focus config
pub const FocusConfig = struct {
    trap: bool = false,
    auto_focus: bool = true,
    restore: bool = true,
};

/// Hover trigger config
pub const HoverConfig = struct {
    leave_delay_ms: f32 = 100,
};

/// Layer config (pass to push)
pub const LayerConfig = struct {
    kind: LayerKind,
    dismiss: DismissConfig = .{},
    enter_transition: Transition = .scale_fade,
    exit_transition: Transition = .scale_fade,
    focus: FocusConfig = .{},
    barrier: BarrierConfig = .none,
    on_dismiss: ?*Signal(bool) = null,
    /// Once set, Esc / outside-click / mutex group / consuming outside-press only call it
    /// (request close), layer doesn't exit itself: component proposes open=false via write
    /// pipeline,
    /// after data source persists, component's open effect calls beginExit. Parent can thus reject
    /// close (docs/SIGNAL_API_DESIGN.md §4.4.1).
    on_dismiss_request: ?core.HandlerRef = null,
    trigger_node: ?*Node = null,
    group: ?[]const u8 = null,
    hover: ?HoverConfig = null,
    /// Entrance delay (ms): layer held at progress=0 (invisible) for this long after
    /// push/reactivate
    /// before enter_transition starts. Tooltip hover display delay; pointer leave during delay
    /// goes straight to exit (beginExit from current enter progress, 0 -> immediate vanish).
    /// Only affects layers where enter_transition != .none.
    enter_delay_ms: f32 = 0,
    a11y: A11yProps = .{},
    barrier_blocks_hover: bool = true,
    content_hit_test_visible: bool = true,
    z_index: ?i16 = null,
    /// Semantic tier; null = infer from kind (modal->dialog / toast->toast / non_modal->overlay).
    /// When z_index is set explicitly, tier does not participate in the computation.
    tier: ?StackTier = null,
};

// ========== TransitionController ==========
// Extracted to overlay_transition.zig (header re-export maintains old paths).

/// Layer instance
pub const OverlayLayer = struct {
    handle: LayerHandle,
    config: LayerConfig,
    state: LayerState,
    z_index_override: ?i16 = null,
    activation_order: u64 = 0,
    skip_outside_click_frame: bool = false,
    enter_paused: bool = false,
    content_node: ?*Node = null,
    barrier_node: ?*Node = null,
    previous_focus: ?NodeHandle = null,
    scope_pushed: bool = false,
    enter_ctrl: TransitionController = TransitionController.init(.none, .entering),
    exit_ctrl: TransitionController = TransitionController.init(.none, .exiting),
    trigger_node: ?*Node = null,
    trigger_handle: ?NodeHandle = null,
    anchor: ?AnchorConfig = null,
    anchor_target_handle: ?NodeHandle = null,
    enter_last_content_rect: ?ComputedRect = null,
    /// Layer closed but not destroyed (scope still alive), resumable via resume()
    suspended: bool = false,
    /// Which node currently holds layer accessibility semantics; invariant: null or equals
    /// content_node.
    /// See applyLayerSemantics.
    a11y_owner: ?*Node = null,
    /// Last recovered semantics from holding node (including component-applied rewrites); null
    /// means still config.a11y initial value.
    a11y_semantics: ?A11yProps = null,
};

/// Return value of overlay() factory function
pub const OverlayResult = struct {
    handle: LayerHandle,
    barrier: ?*Node,
    content: *Node,
    /// true = barrier auto-mounted to portal (cx.ensurePopoverPortalRoot()), caller should not
    /// appendChild.
    /// false = no barrier or cx.root == null unit-test scenario: caller still needs to append
    /// returned
    /// overlay node to own tree; inline-mounted floaters subject to ancestor clipping.
    portaled: bool = false,
};

// ========== OverlayStack ==========

pub const OverlayStack = struct {
    /// Layer capacity 256: suspended Tooltip/Popover occupy a slot from mount, so layer count grows
    /// with mounted UI components, not interaction depth (an app chrome of ~15 layers plus two
    /// editors
    /// of ~16 each exceeds 32 and hits TooManyLayers). Lifting the limit entirely (ArrayList) is
    /// deferred with the focus_scope refactor. Per-slot traversal is a null check; 256-slot
    /// per-frame
    /// cost is negligible.
    pub const MAX_LAYERS = 256;

    /// Layer slots (stable indices, freed slots set to null), grown on demand
    /// up to MAX_LAYERS: a full inline table kept ~310 KiB resident per Cx.
    layers: std.ArrayList(?OverlayLayer) = .empty,
    /// Cx.init installs its allocator; owners must call deinit.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    /// hasActiveAnimations generational memo: any entry that might change layer state bumps
    /// anim_gen
    /// (bumpAnimGen), same-generation query returns directly. Single-threaded UI assumption.
    anim_gen: u64 = 1,
    anim_memo_gen: u64 = 0,
    anim_memo_result: bool = false,
    // Include the full capacity (256), not just the highest slot index (255).
    layer_count: usize = 0,
    next_z: i16 = 100,
    next_id: u32 = 1,
    next_activation_order: u64 = 1,
    /// Layer a swallowed outside press dismisses on release (see consumeOutsidePress).
    consumed_press_layer: ?LayerHandle = null,
    /// commitExit queues previous_focus here if the layer configured focus.restore; Cx (holding
    /// focus_manager) drains it during the frame.
    ///
    /// Why: OverlayStack can't access cx, and focus restoration needs focus_manager. Without the
    /// drain, closing Modal/Sheet loses focus instead of returning to the trigger.
    pending_focus_restore: ?NodeHandle = null,
    node_registry: ?*core.NodeRegistry = null,

    inline fn bumpAnimGen(self: *OverlayStack) void {
        self.anim_gen +%= 1;
    }

    pub fn setRegistry(self: *OverlayStack, registry: *core.NodeRegistry) void {
        self.node_registry = registry;
    }

    /// Register new layer, allocate z-index
    pub fn push(self: *OverlayStack, config: LayerConfig) !LayerHandle {
        self.bumpAnimGen();
        if (self.layer_count >= MAX_LAYERS) {
            if (@import("zenit_environment").flag("ZENIT_DEBUG_OVERLAY")) {
                std.debug.print("[overlay-dbg] push FAIL count={d}\n", .{self.layer_count});
                for (self.layers.items, 0..) |*slot, i| {
                    if (slot.*) |*layer| {
                        const cname = if (layer.content_node) |cn| (cn.meta.ownership.meta.component_name orelse "?") else "null";
                        std.debug.print("  [{d}] kind={s} state={s} suspended={} content={s}\n", .{
                            i, @tagName(layer.config.kind), @tagName(layer.state), layer.suspended, cname,
                        });
                    }
                }
            }
            return error.TooManyLayers;
        }

        // Mutex group: non_modal layers in same group auto-close
        if (config.group) |group| {
            for (self.layers.items) |*slot| {
                if (slot.*) |*layer| {
                    if (!layer.suspended and layer.state != .exiting and layer.config.kind != .modal) {
                        if (layer.config.group) |eg| {
                            if (std.mem.eql(u8, eg, group)) {
                                self.requestDismiss(layer);
                            }
                        }
                    }
                }
            }
        }

        const z = config.z_index orelse self.next_z;
        if (config.z_index) |_| {
            self.next_z = @max(self.next_z, z +| 2);
        } else {
            self.next_z +|= 2; // barrier + content each take one
        }
        const handle = LayerHandle{
            .id = self.next_id,
            .z_index = z,
        };
        self.next_id += 1;

        // Find empty slot
        const slot = self.findEmptySlot() orelse blk: {
            if (self.layers.items.len >= MAX_LAYERS) return error.TooManyLayers;
            try self.layers.append(self.allocator, null);
            break :blk self.layers.items.len - 1;
        };
        const enter_transition = config.enter_transition;
        const initial_state: LayerState = if (enter_transition == .none) .visible else .entering;
        var stored_config = config;
        stored_config.trigger_node = null;
        self.layers.items[slot] = OverlayLayer{
            .handle = handle,
            .config = stored_config,
            .state = initial_state,
            .z_index_override = config.z_index,
            .activation_order = self.allocateActivationOrder(),
            .enter_ctrl = TransitionController.initWithTime(enter_transition, .entering, render_engine.current_frame_time_ms),
            .exit_ctrl = TransitionController.initWithTime(config.exit_transition, .exiting, render_engine.current_frame_time_ms),
            .trigger_node = config.trigger_node,
            .trigger_handle = self.trackNode(config.trigger_node),
        };
        self.layers.items[slot].?.enter_ctrl.delay_remaining_ms = config.enter_delay_ms;
        self.layer_count += 1;

        return handle;
    }

    /// Bind the overlay layer's real content node.
    /// Applies to two scenarios:
    /// - Popover/Tooltip/Toast directly pushed() floating content
    /// - Modal/Sheet via barrier mount, where animation targets the actual dialog/panel content
    ///   node
    /// Layer accessibility semantics (initial config.a11y: dialog role, title, modal) belong to the
    /// layer, recorded by a11y_owner. When swapping the content node, transfer semantics as a
    /// whole,
    /// including component-applied modifications (e.g. expanded): the old owner clears, only one
    /// owner
    /// at any time. A new node declaring its own semantics takes precedence (layer defers, no
    /// longer
    /// owns). Must be called before layer.content_node becomes node.
    ///
    /// Ownership is by target object, not value equality: a value-equality check treats
    /// component-modified copies as 'not the layer's', leaving a phantom modal=true overlay that
    /// may
    /// make the real dialog inert. Modal/Sheet replace the overlay's auto-created content with
    /// their
    /// own dialog/panel node, acquiring dialog semantics here.
    ///
    /// Invariant a11y_owner in {null, content_node}: content_node only changes via overlay()
    /// and bindContentNode, both call this first. The content node isn't freed before replacement
    /// (cleanup runs with the layer's scope), so dereferencing the owner here is safe.
    fn applyLayerSemantics(layer: *OverlayLayer, node: *Node) void {
        if (layer.config.a11y.role == .none) return;
        if (layer.a11y_owner) |owner| {
            if (owner == node) return;
            std.debug.assert(owner == layer.content_node);
            if (owner.behavior.interaction.a11y) |current| layer.a11y_semantics = current;
            owner.behavior.interaction.a11y = null;
            layer.a11y_owner = null;
        }
        // Node declares own semantics: defer, layer retains recovered copy, reuse on later swap to
        // null.
        if (node.behavior.interaction.a11y != null) return;
        node.behavior.interaction.a11y = layer.a11y_semantics orelse layer.config.a11y;
        layer.a11y_owner = node;
    }

    pub fn bindContentNode(self: *OverlayStack, allocator: Allocator, handle: LayerHandle, content_node: *Node) void {
        if (self.findLayer(handle)) |layer| {
            applyLayerSemantics(layer, content_node);
            layer.content_node = content_node;
            const ext = content_node.style.ensureExtPanic(allocator);
            // CA-pure revamp P6.1 (settle-frame children-drop root cause fixed, paint-order
            // invariants +
            // cache self-contained after: non_modal also unified to composited_group surface;
            // scale+opacity
            // fade semantics correct (no per-primitive inline modulation), text never re-rasters
            // per-frame.
            // Single CA matrix composite (surface_draw_transform = owner_world·T(src)).
            ext.composited_group = true;
            // Content (dialog/panel) must explicitly get the pointer hit role, else clicking a
            // blank area or
            // plain text (no on_click) pierce-tests to the barrier or background ScrollArea, and
            // outside-click misdetects 'clicked outside' -> close. With the pointer role, any
            // content click
            // hits the content subtree (isDescendantOf(content)=true) -> no close; inner buttons (x
            // / menu
            // items) are deeper and still take priority with their own handlers. Per-role override:
            // pointer
            // only; scroll/inspect keep derived defaults (content still owns scroll; devtools can
            // still
            // select it).
            ext.hit_roles = .{ .pointer = true };
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
        }
    }

    /// Compat helper: reserved for barrier-less floating overlay calls.
    pub fn bindFloatingContent(self: *OverlayStack, allocator: Allocator, handle: LayerHandle, content_node: *Node) void {
        self.bindContentNode(allocator, handle, content_node);
    }

    /// Whether any layer is exiting (test/diagnostic use).
    pub fn anyExiting(self: *const OverlayStack) bool {
        for (self.layers.items) |maybe| {
            if (maybe) |layer| {
                if (layer.state == .exiting) return true;
            }
        }
        return false;
    }

    /// User-triggered close (Esc / outside-click / mutex group): with on_dismiss_request only
    /// requests,
    /// else begins exit directly.
    fn requestDismiss(self: *OverlayStack, layer: *OverlayLayer) void {
        if (layer.config.on_dismiss_request) |h| {
            h.invoke();
            return;
        }
        self.beginExit(layer.handle);
    }

    /// Start exit: launch exit animation (if any), tick() auto-commits after. Note: on_dismiss
    /// Signal
    /// fires in commitExit (after exit animation), prevent Effect from shrinking node to 0x0 before
    /// animation.
    pub fn beginExit(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            logOutsideClickLayer("begin-exit-request", layer, null);
            if (layer.state == .exiting) return;
            if (layer.suspended) return;

            // No exit animation -> commit immediately (trigger sig.set(false) in commitExit)
            if (layer.config.exit_transition == .none) {
                self.commitExit(handle);
                return;
            }

            // With exit animation -> enter exiting state, wait for tick() to drive completion
            const was_entering = layer.state == .entering;
            layer.state = .exiting;
            layer.exit_ctrl = TransitionController.initWithTime(layer.config.exit_transition, .exiting, render_engine.current_frame_time_ms);
            // Leave mid-enter (including enter_delay hold, progress still 0): exit plays from
            // current enter
            // progress, not full flash from 1.0.
            if (was_entering) layer.exit_ctrl.seedFromProgress(layer.enter_ctrl.visualProgress());
            syncLayerHitTestVisibility(layer);
            logOutsideClickLayer("begin-exit-applied", layer, null);
        }
    }

    /// After exit completes: hide node + suspend layer (don't remove from stack, resumable)
    pub fn commitExit(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return;
        if (self.layers.items[idx]) |*layer| {
            if (layer.suspended) return; // Already suspended

            // Signal callback may sync-dispose scope, removePermanently, free node. Snapshot ptr
            // first,
            // trigger as final step after all layer/node writes complete.
            const dismiss_signal = layer.config.on_dismiss;

            // Hide node
            if (layer.barrier_node) |barrier| {
                // Layers with barrier (Modal/Sheet): hide barrier only, content inside barrier
                barrier.style.width = .{ .px = 0 };
                barrier.style.height = .{ .px = 0 };
                barrier.style.overflow_hidden = true;
                setManualTransitionFlags(barrier, layer.config.enter_transition, false);
                setManualTransitionFlags(barrier, layer.config.exit_transition, false);
                barrier.markLayoutDirty();
            } else if (layer.content_node) |content| {
                // Barrier-less floating overlay (Popover/Tooltip/Menu/Picker) must preserve
                // measurable geometry
                // to avoid reopen first visible frame needing 0x0->full-size relayout. For absolute
                // overlays,
                // hide visual/hit only, don't shrink to 0x0.
                content.setOpacityRaw(0);
                content.style.overflow_hidden = false;
                setManualTransitionFlags(content, layer.config.enter_transition, false);
                setManualTransitionFlags(content, layer.config.exit_transition, false);
                // suspend must preserve prewarm descendant render caches (reopen first frame
                // reuses), so can't
                // use markCompositePropDirty (invalidateRenderCache); opacity uses anim-frame +
                // overflow_hidden
                // change marks render.
                content.markCompositeAnimFrameDirty();
                content.markRenderDirty();
            }

            // Focus restore: queue previous_focus for Cx (see pending_focus_restore).
            if (layer.config.focus.restore) {
                if (layer.previous_focus) |prev| {
                    self.pending_focus_restore = prev;
                    layer.previous_focus = null;
                }
            }

            layer.scope_pushed = false;
            layer.suspended = true;
            layer.state = .visible; // Reset state for correct resume starting point
            syncLayerHitTestVisibility(layer);
            if (dismiss_signal) |sig| sig.set(false);
        }
    }

    /// Truly remove layer permanently during scope dispose (only in cleanup callback)
    pub fn removePermanently(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return;
        self.layers.items[idx] = null;
        if (self.layer_count > 0) self.layer_count -= 1;
        if (self.layer_count == 0) self.next_z = 100;
        self.syncAllLayerVisualOrder();
    }

    /// Resume suspended layer (called by component Effect on reopen)
    pub fn reactivate(self: *OverlayStack, handle: LayerHandle) void {
        self.reactivateWith(handle, .{});
    }

    pub const ReactivateOptions = struct {
        /// false: show the open state at once, as with an `.none` enter transition (an overlay
        /// whose component mounted already open is the open result, not an opening).
        animate: bool = true,
    };

    pub fn reactivateWith(self: *OverlayStack, handle: LayerHandle, options: ReactivateOptions) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            if (!layer.suspended) return;
            layer.suspended = false;
            layer.activation_order = self.allocateActivationOrder();
            layer.skip_outside_click_frame = true;
            layer.enter_paused = false;
            layer.enter_last_content_rect = null;

            // Don't recursively clear the whole floater subtree cache on reactivate. Prewarming in
            // hidden
            // state preserves full content + glyph atlas and the first visible frame reuses them.
            // Clearing
            // descendants' cache here would make Popover/Select/DatePicker cold-start render a
            // shell on the
            // first frame and content on the next. Reopen really only needs re-entering the
            // composite/interaction flow; size/content changes before open are already invalidated
            // via
            // sizing/render dirty.
            const animated = options.animate and layer.config.enter_transition != .none;
            if (layer.content_node) |content| {
                setManualTransitionFlags(content, layer.config.enter_transition, animated);
                content.markCompositeAnimFrameDirty();
            }
            if (layer.barrier_node) |barrier| {
                setManualTransitionFlags(barrier, layer.config.enter_transition, animated);
                barrier.markCompositeAnimFrameDirty();
            }

            if (animated) {
                layer.state = .entering;
                layer.enter_ctrl = TransitionController.initWithTime(layer.config.enter_transition, .entering, render_engine.current_frame_time_ms);
                layer.enter_ctrl.delay_remaining_ms = layer.config.enter_delay_ms;
            } else {
                layer.state = .visible;
                // No enter animation will undo what the last exit left (opacity 0, a shrunk
                // scale, a slid-out translate): land on the settled open state now, or a layer
                // reopened with `.none` stays invisible or off-screen.
                settleShown(layer, self.allocator);
            }
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
            logOutsideClickLayer("reactivate", layer, null);
        }
    }

    /// A layer that has not started entering shows its open state at once: its component mounted
    /// already open (the open result, not an opening), as `reactivateWith(.{ .animate = false })`
    /// does for a suspended layer. No-op for a suspended layer or one already past `.entering`.
    pub fn skipInitialEnter(self: *OverlayStack, handle: LayerHandle) void {
        self.bumpAnimGen();
        const layer = self.findLayer(handle) orelse return;
        if (layer.suspended or layer.state != .entering) return;
        layer.state = .visible;
        layer.enter_paused = false;
        if (layer.content_node) |content| {
            setManualTransitionFlags(content, layer.config.enter_transition, false);
            content.markCompositeAnimFrameDirty();
        }
        if (layer.barrier_node) |barrier| {
            setManualTransitionFlags(barrier, layer.config.enter_transition, false);
            barrier.markCompositeAnimFrameDirty();
        }
        // A geometry hold may already have drawn the enter's hidden first frame.
        settleShown(layer, self.allocator);
        syncLayerHitTestVisibility(layer);
    }

    pub fn setEnterPaused(self: *OverlayStack, handle: LayerHandle, paused: bool, allocator: Allocator) void {
        self.bumpAnimGen();
        if (self.findLayer(handle)) |layer| {
            if (layer.state != .entering) return;
            layer.enter_paused = paused;
            if (paused) {
                layer.enter_ctrl.progress = 0.0;
                return;
            }
            if (layer.content_node) |content| {
                setManualTransitionFlags(content, layer.config.enter_transition, true);
                layer.enter_ctrl.apply(content, allocator);
            }
            if (layer.barrier_node) |barrier| {
                setManualTransitionFlags(barrier, layer.config.enter_transition, true);
                barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
                barrier.markCompositeAnimFrameDirty();
            }
        }
    }

    pub fn cancelExit(self: *OverlayStack, handle: LayerHandle, next_state: LayerState) void {
        self.bumpAnimGen();
        std.debug.assert(next_state != .exiting);
        if (self.findLayer(handle)) |layer| {
            if (layer.state != .exiting) return;
            if (layer.suspended) return;
            layer.state = next_state;
            if (next_state == .entering) {
                layer.skip_outside_click_frame = true;
                layer.enter_ctrl = TransitionController.initWithTime(layer.config.enter_transition, .entering, render_engine.current_frame_time_ms);
                // Pull back mid-exit: enter continues from current exit progress (skip enter_delay,
                // quick
                // re-hover appears immediately).
                layer.enter_ctrl.seedFromProgress(layer.exit_ctrl.visualProgress());
            }
            syncLayerHitTestVisibility(layer);
            self.syncAllLayerVisualOrder();
        }
    }

    /// Current topmost (skip .exiting and .suspended)
    pub fn topmost(self: *const OverlayStack) ?*const OverlayLayer {
        var best: ?*const OverlayLayer = null;
        for (self.layers.items) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.suspended) continue;
            if (layer.state == .exiting) continue;
            if (best == null or layer.activation_order > best.?.activation_order) {
                best = layer;
            }
        }
        return best;
    }

    /// Whether handle is topmost
    pub fn isTopmost(self: *const OverlayStack, handle: LayerHandle) bool {
        if (self.topmost()) |top| {
            return top.handle.id == handle.id;
        }
        return false;
    }

    /// Unified Escape handling: find topmost layer with escape=true and not exiting, close it.
    /// Stop at modal (modal blocks Escape downward). Return true if consumed.
    pub fn handleEscape(self: *OverlayStack) bool {
        self.bumpAnimGen();
        if (self.layer_count == 0) return false;

        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);

        var i = count;
        while (i > 0) {
            i -= 1;
            if (self.layers.items[ordered[i]]) |*layer| {
                if (layer.config.dismiss.escape) {
                    self.requestDismiss(layer);
                    return true;
                }
                // modal blocks Escape downward propagation
                if (layer.config.kind == .modal) return true;
            }
        }
        return false;
    }

    /// Unified outside-click handling: traverse top-to-bottom, check each non_modal layer if click
    /// outside. Layer pressed was determined by hit at press time (topmost layer with
    /// content/trigger
    /// containing target). renderPhase handleOutsideClick fallback: pressed node may become invalid
    /// when layer exits in click callback; can't misdetect parent as "outside".
    pub fn findPressOwner(self: *OverlayStack, target: ?*Node) ?LayerHandle {
        const t = target orelse return null;
        if (self.layer_count == 0) return null;
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);
        var i = count;
        while (i > 0) {
            i -= 1;
            const layer = if (self.layers.items[ordered[i]]) |*l| l else continue;
            if (layer.suspended) continue;
            if (layer.content_node) |content| {
                if (t.isDescendantOf(content)) return layer.handle;
            }
            if (self.resolveTrigger(layer)) |trig| {
                if (t.isDescendantOf(trig)) return layer.handle;
            }
        }
        return null;
    }

    pub fn handleOutsideClick(self: *OverlayStack, has_new_mouse_down: bool, last_mouse_down_target: ?*Node) void {
        self.handleOutsideClickOwned(has_new_mouse_down, last_mouse_down_target, null);
    }

    /// `press_owner`: layer recorded at press (see `findPressOwner`). Stop at it; it and below
    /// are not "outside".
    pub fn handleOutsideClickOwned(self: *OverlayStack, has_new_mouse_down: bool, last_mouse_down_target: ?*Node, press_owner: ?LayerHandle) void {
        self.handleOutsideRelease(has_new_mouse_down, last_mouse_down_target, press_owner, std.math.maxInt(u64));
    }

    /// Activation order the next activated layer gets. A press records it so that its release
    /// dismisses only layers that were already open when the press began.
    pub fn activationMark(self: *const OverlayStack) u64 {
        return self.next_activation_order;
    }

    /// Outside dismissal happens when a press is released (a click), like native controls: a
    /// click whose own handler unmounts the overlay (navigating away) removes it with its page
    /// instead of first fading it out. `press_target` / `press_owner` describe where the press
    /// began; layers activated at or after `opened_before` (opened by this very press) are not
    /// dismissed by its release.
    pub fn handleOutsideRelease(self: *OverlayStack, released: bool, press_target: ?*Node, press_owner: ?LayerHandle, opened_before: u64) void {
        self.bumpAnimGen();
        if (!released) return;
        const last_mouse_down_target = press_target;
        if (self.layer_count == 0) return;
        const target = last_mouse_down_target;

        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);

        // Press-owning layer no longer in active list (closed itself in click callback): pressed
        // handled inside, not outside any layer.
        if (press_owner) |owner| {
            var present = false;
            for (ordered[0..count]) |idx| {
                if (self.layers.items[idx]) |*l| {
                    if (l.handle.id == owner.id) present = true;
                }
            }
            if (!present) return;
        }

        var i = count;
        while (i > 0) {
            i -= 1;
            if (self.layers.items[ordered[i]]) |*layer| {
                logOutsideClickLayer("inspect", layer, target);
                if (press_owner) |owner| {
                    if (layer.handle.id == owner.id) {
                        logOutsideClickLayer("press-owner-return", layer, target);
                        return;
                    }
                }
                if (layer.suspended) continue;
                if (layer.state == .exiting) continue;
                if (layer.skip_outside_click_frame) continue;
                if (layer.activation_order >= opened_before) continue;

                // Click inside content -> don't close
                if (layer.config.content_hit_test_visible) {
                    if (target) |target_node| {
                        if (layer.content_node) |content| {
                            if (target_node.isDescendantOf(content)) {
                                logOutsideClickLayer("inside-content-return", layer, target);
                                return;
                            }
                        }
                    }
                }

                // Click inside trigger -> let trigger handle
                if (target) |target_node| {
                    if (self.resolveTrigger(layer)) |trig| {
                        if (target_node.isDescendantOf(trig)) {
                            logOutsideClickLayer("inside-trigger-return", layer, target);
                            return;
                        }
                    }
                }

                // Click on barrier -> dismiss layer, barrier blocks
                if (target) |target_node| {
                    if (layer.barrier_node) |barrier| {
                        if (target_node.isDescendantOf(barrier)) {
                            switch (layer.config.dismiss.outside_click) {
                                .none => {},
                                .notify => {
                                    logOutsideClickLayer("barrier-notify-dismiss", layer, target);
                                    if (layer.config.on_dismiss) |sig| sig.set(false);
                                },
                                else => self.requestDismiss(layer),
                            }
                            logOutsideClickLayer("barrier-return", layer, target);
                            return; // barrier blocks
                        }
                    }
                }

                // Click outside all known areas -> dismiss
                switch (layer.config.dismiss.outside_click) {
                    .none => {},
                    .notify => {
                        logOutsideClickLayer("notify-dismiss", layer, target);
                        if (layer.config.on_dismiss) |sig| sig.set(false);
                    },
                    else => {
                        logOutsideClickLayer("outside-begin-exit", layer, target);
                        self.requestDismiss(layer);
                        // non_modal: continue downward (may close multiple nested popover)
                        // modal won't reach here (barrier already intercepted)
                    },
                }
            }
        }
    }

    /// mouse-down pre-dispatch: if topmost active overlay configured `.close_and_consume` and click
    /// outside content/trigger, return true: the caller swallows the press (and its release, which
    /// closes the overlay via commitConsumedPress), so the hit thing is not also triggered. Click inside layer content/trigger or topmost not consume-type
    /// returns false, normal dispatch and renderPhase handleOutsideClick proceed.
    pub fn consumeOutsidePress(self: *OverlayStack, target: ?*Node) bool {
        self.bumpAnimGen();
        if (self.layer_count == 0) return false;
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);
        var i = count;
        while (i > 0) {
            i -= 1;
            const layer = if (self.layers.items[ordered[i]]) |*l| l else continue;
            if (layer.suspended or layer.state == .exiting or layer.skip_outside_click_frame) continue;
            if (target) |t| {
                if (layer.config.content_hit_test_visible) {
                    if (layer.content_node) |content| {
                        if (t.isDescendantOf(content)) return false;
                    }
                }
                if (self.resolveTrigger(layer)) |trig| {
                    if (t.isDescendantOf(trig)) return false;
                }
            }
            if (layer.config.dismiss.outside_click != .close_and_consume) return false;
            logOutsideClickLayer("consume-press", layer, target);
            self.consumed_press_layer = layer.handle;
            return true;
        }
        return false;
    }

    /// The release of a press `consumeOutsidePress` swallowed: dismiss the layer it was outside of
    /// (still open and not already leaving). Also called when that release was lost and the next
    /// press arrives.
    pub fn commitConsumedPress(self: *OverlayStack) void {
        self.bumpAnimGen();
        const handle = self.consumed_press_layer orelse return;
        self.consumed_press_layer = null;
        const layer = self.findLayer(handle) orelse return;
        if (layer.suspended or layer.state == .exiting) return;
        logOutsideClickLayer("consume-begin-exit", layer, null);
        self.requestDismiss(layer);
    }

    /// Update anchor positioning before layout each frame. Geometry only, don't advance animation.
    pub fn updateAnchors(self: *OverlayStack, vp_w: f32, vp_h: f32) void {
        for (self.layers.items) |*slot| {
            if (slot.*) |*layer| {
                if (layer.suspended) continue;

                // Anchor positioning (updated each frame, trigger may move)
                if (layer.state != .exiting) {
                    updateAnchorPosition(self, layer, vp_w, vp_h);
                }
            }
        }
    }

    /// Advance transition animations after layout each frame. Return true = active animations need
    /// redraw.
    pub fn tickAnimations(self: *OverlayStack, now_ms: f64, dt: f32, allocator: Allocator) bool {
        self.bumpAnimGen();
        var any_animating = false;

        for (self.layers.items) |*slot| {
            if (slot.*) |*layer| {
                if (layer.suspended) continue;
                defer layer.skip_outside_click_frame = false;

                switch (layer.state) {
                    .entering => {
                        if (layer.enter_paused) {
                            layer.enter_ctrl.progress = 0.0;
                            if (layer.content_node) |content| {
                                setManualTransitionFlags(content, layer.config.enter_transition, true);
                                layer.enter_ctrl.apply(content, allocator);
                            }
                            if (layer.barrier_node) |barrier| {
                                setManualTransitionFlags(barrier, layer.config.enter_transition, true);
                                barrier.setOpacityRaw(0.0);
                                barrier.markCompositeAnimFrameDirty();
                            }
                            any_animating = true;
                            continue;
                        }

                        if (holdEnterUntilGeometryStable(layer, allocator)) {
                            any_animating = true;
                            continue;
                        }

                        // If anchored and content size not calculated, pause enter animation
                        // (prevent flicker)
                        if (layer.anchor != null) {
                            if (layer.content_node) |content| {
                                const cr = content.rectFromWorldOrFallback();
                                if (cr.w == 0 or cr.h == 0) {
                                    content.setOpacityRaw(0);
                                    content.markCompositeAnimFrameDirty();
                                    any_animating = true;
                                    continue;
                                }
                            }
                        }

                        const done = layer.enter_ctrl.update(now_ms);
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.enter_transition, !done);
                            layer.enter_ctrl.apply(content, allocator);
                            if (overlayDebugEnabled() and content.meta.ownership.meta.component_name != null and std.mem.eql(u8, content.meta.ownership.meta.component_name.?, "PopoverContent")) {
                                const dr = content.rectFromWorldOrFallback();
                                std.debug.print("[overlay.enter.tick] node={d} test_id={s} dt={d:.4} progress={d:.3} done={} size=({d:.1},{d:.1}) opacity={d:.3} scale=({d:.3},{d:.3})\n", .{
                                    content.id,
                                    content.meta.ownership.meta.test_id orelse "(nil)",
                                    dt,
                                    layer.enter_ctrl.progress,
                                    done,
                                    dr.w,
                                    dr.h,
                                    content.getOpacity(),
                                    content.style.scale_x(),
                                    content.style.scale_y(),
                                });
                            }
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.enter_transition, !done);
                            barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
                            barrier.markCompositeAnimFrameDirty();
                        }
                        if (done) {
                            layer.state = .visible;
                            // Restore content full visibility. Don't reset translate_x/translate_y
                            // here: Popover/anchored overlay
                            // reuse translate_* for final positioning; zeroing at enter-completion
                            // frame causes panel jump back
                            // to trigger position one frame.
                            if (layer.content_node) |content| {
                                content.setOpacityRaw(1.0);
                                content.markCompositeAnimFrameDirty();
                            }
                        } else {
                            any_animating = true;
                        }
                    },
                    .exiting => {
                        const done = layer.exit_ctrl.update(now_ms);
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.exit_transition, !done);
                            layer.exit_ctrl.apply(content, allocator);
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.exit_transition, !done);
                            barrier.setOpacityRaw(layer.exit_ctrl.currentOpacity());
                            barrier.markCompositeAnimFrameDirty();
                        }
                        if (done) {
                            // Animation complete -> truly hide and remove
                            self.commitExit(layer.handle);
                            // After commitExit still need one layout/tree-snapshot frame, else
                            // barriers like Sheet may keep old rect.
                            any_animating = true;
                        } else {
                            any_animating = true;
                        }
                    },
                    .visible => {
                        if (layer.content_node) |content| {
                            setManualTransitionFlags(content, layer.config.enter_transition, false);
                            setManualTransitionFlags(content, layer.config.exit_transition, false);
                        }
                        if (layer.barrier_node) |barrier| {
                            setManualTransitionFlags(barrier, layer.config.enter_transition, false);
                            setManualTransitionFlags(barrier, layer.config.exit_transition, false);
                        }
                    },
                }
            }
        }

        return any_animating;
    }

    pub fn tick(self: *OverlayStack, now_ms: f64, dt: f32, vp_w: f32, vp_h: f32, allocator: Allocator) bool {
        self.updateAnchors(vp_w, vp_h);
        return self.tickAnimations(now_ms, dt, allocator);
    }

    pub fn hasActiveAnimations(self: *const OverlayStack) bool {
        // Function on each wakeup check chain (per pump loop x per-window multiple times), idle
        // pure
        // polling: generational memo reduces repeat scan to O(1). All entries changing layer state
        // (push/exit/reactivate/tick/clear/findLayer...) bump anim_gen, memo may over-scan never
        // stale.
        if (self.anim_memo_gen == self.anim_gen) return self.anim_memo_result;
        // Traverse by reference: value-for over [MAX_LAYERS]?OverlayLayer copies entire slot
        // (hundreds
        // bytes x 256).
        var result = false;
        for (self.layers.items) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.suspended) continue;
            switch (layer.state) {
                .entering, .exiting => {
                    result = true;
                    break;
                },
                .visible => {},
            }
        }
        const mut = @constCast(self);
        mut.anim_memo_gen = self.anim_gen;
        mut.anim_memo_result = result;
        return result;
    }

    pub fn deinit(self: *OverlayStack) void {
        self.clear();
        self.layers.deinit(self.allocator);
        self.layers = .empty;
    }

    /// Clear all layers
    pub fn clear(self: *OverlayStack) void {
        self.bumpAnimGen();
        for (self.layers.items) |*slot| {
            slot.* = null;
        }
        self.layer_count = 0;
        self.next_z = 100;
        self.next_activation_order = 1;
    }

    /// Find layer for handle
    pub fn findLayer(self: *OverlayStack, handle: LayerHandle) ?*OverlayLayer {
        self.bumpAnimGen();
        const idx = self.findLayerIndex(handle) orelse return null;
        if (self.layers.items[idx]) |*layer| return layer;
        return null;
    }

    /// Find overlay layer for content node or descendants.
    pub fn findLayerForNode(self: *const OverlayStack, node: *Node) ?*const OverlayLayer {
        for (self.layers.items) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (layer.content_node) |content| {
                if (node.isDescendantOf(content)) return layer;
            }
            if (layer.barrier_node) |barrier| {
                if (node.isDescendantOf(barrier)) return layer;
            }
        }
        return null;
    }

    /// Semantic actions must respect the same modal boundary as pointer input.
    /// Portaled children belong through their live trigger chain, not DOM ancestry.
    pub fn allowsSemanticAction(self: *const OverlayStack, node: *const Node) bool {
        var modal: ?*const OverlayLayer = null;
        for (self.layers.items) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            const inside = layerContains(layer, node);
            if (inside and (layer.suspended or layer.state == .exiting)) return false;
            if (layer.suspended or layer.state == .exiting or layer.config.kind != .modal) continue;
            if (modal == null or layer.activation_order > modal.?.activation_order) modal = layer;
        }
        const boundary = modal orelse return true;
        if (layerContains(boundary, node)) return true;
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, true);
        var allowed: [MAX_LAYERS]bool = @splat(false);
        for (ordered[0..count], 0..) |index, position| {
            const layer = &(self.layers.items[index].?);
            if (layer.handle.id == boundary.handle.id) {
                allowed[position] = true;
                continue;
            }
            if (layer.activation_order <= boundary.activation_order) continue;
            const trigger = self.resolveTrigger(layer) orelse continue;
            for (ordered[0..position], 0..) |parent_index, parent_position| {
                if (allowed[parent_position] and layerContains(&(self.layers.items[parent_index].?), trigger)) {
                    allowed[position] = true;
                    break;
                }
            }
            if (allowed[position] and layerContains(layer, node)) return true;
        }
        return false;
    }

    fn isSemanticDescendant(node: *const Node, ancestor: *const Node) bool {
        var current: ?*const Node = node;
        while (current) |n| : (current = n.parent) {
            if (n == ancestor) return true;
        }
        return false;
    }

    fn layerContains(layer: *const OverlayLayer, node: *const Node) bool {
        if (layer.content_node) |content| if (isSemanticDescendant(node, content)) return true;
        if (layer.barrier_node) |barrier| if (isSemanticDescendant(node, barrier)) return true;
        return false;
    }

    /// Whether node in **suspended** (closed not destroyed) layer content/barrier subtree. Differs
    /// from
    /// findLayerForNode: check all layers not first hit; nested, node may belong to outer (open)
    /// and inner (suspended), any suspended ancestor means not visible. Ptr comparison only
    /// (isDescendantOf walks node parent chain), no layer node dereference.
    pub fn isNodeInSuspendedLayer(self: *const OverlayStack, node: *Node) bool {
        for (self.layers.items) |*slot| {
            const layer = if (slot.*) |*l| l else continue;
            if (!layer.suspended) continue;
            if (layer.content_node) |content| {
                if (node.isDescendantOf(content)) return true;
            }
            if (layer.barrier_node) |barrier| {
                if (node.isDescendantOf(barrier)) return true;
            }
        }
        return false;
    }

    fn findLayerIndex(self: *const OverlayStack, handle: LayerHandle) ?usize {
        for (self.layers.items, 0..) |*slot, i| {
            if (slot.*) |*layer| {
                if (layer.handle.id == handle.id) return i;
            }
        }
        return null;
    }

    fn findEmptySlot(self: *const OverlayStack) ?usize {
        for (self.layers.items, 0..) |*slot, i| {
            if (slot.* == null) return i;
        }
        return null;
    }

    fn allocateActivationOrder(self: *OverlayStack) u64 {
        const order = self.next_activation_order;
        self.next_activation_order +%= 1;
        if (self.next_activation_order == 0) self.next_activation_order = 1;
        return order;
    }

    fn collectOrderedLayerIndices(self: *const OverlayStack, indices: *[MAX_LAYERS]usize, only_active: bool) usize {
        var count: usize = 0;
        for (self.layers.items, 0..) |*slot, idx| {
            const layer = if (slot.*) |*l| l else continue;
            if (only_active and (layer.suspended or layer.state == .exiting)) continue;

            var insert_at = count;
            while (insert_at > 0) : (insert_at -= 1) {
                const prev_idx = indices[insert_at - 1];
                const prev_layer = if (self.layers.items[prev_idx]) |*p| p else break;
                if (prev_layer.activation_order <= layer.activation_order) break;
                indices[insert_at] = indices[insert_at - 1];
            }
            indices[insert_at] = idx;
            count += 1;
        }
        return count;
    }

    fn layerTier(layer: *const OverlayLayer) StackTier {
        return layer.config.tier orelse StackTier.fromKind(layer.config.kind);
    }

    /// trigger/anchor generational weak refs + liveness check: impl extracted to
    /// overlay_layer_refs.zig
    /// (invariants and tests there). OverlayStack side only injects node_registry then records.
    fn trackNode(self: *OverlayStack, node: ?*Node) ?NodeHandle {
        return overlay_layer_refs.trackNode(self.node_registry, node);
    }

    fn resolveTrackedNode(self: *const OverlayStack, handle: ?NodeHandle, cached: ?*Node) ?*Node {
        return overlay_layer_refs.resolveTrackedNode(self.node_registry, handle, cached);
    }

    /// The layer's trigger if it is still alive (generation-checked, see overlay_layer_refs), else
    /// null. The trigger lives in the caller's subtree and may be freed while the layer is still
    /// in the stack: read it only through here, never through `layer.trigger_node`.
    pub fn resolveTrigger(self: *const OverlayStack, layer: *const OverlayLayer) ?*Node {
        return self.resolveTrackedNode(layer.trigger_handle, layer.trigger_node);
    }

    pub fn setAnchor(self: *OverlayStack, handle: LayerHandle, anchor: ?AnchorConfig) void {
        const target_handle = if (anchor) |value| self.trackNode(value.target) else null;
        const layer = self.findLayer(handle) orelse return;
        layer.anchor = anchor;
        layer.anchor_target_handle = target_handle;
    }

    /// Nested inheritance: which active layer's content subtree contains this layer's trigger ->
    /// take
    /// highest z. ordered[0..upto] layers with earlier activation sequence (parent opens before
    /// child,
    /// single pass converges).
    fn nestedParentZ(self: *const OverlayStack, trigger: *Node, ordered: []const usize, computed: *const [MAX_LAYERS]i16, upto: usize) ?i16 {
        var best: ?i16 = null;
        for (ordered[0..upto]) |idx| {
            const parent = &(self.layers.items[idx].?);
            const content = parent.content_node orelse continue;
            const inside = trigger.isDescendantOf(content) or
                if (parent.barrier_node) |b| trigger.isDescendantOf(b) else false;
            if (!inside) continue;
            if (best == null or computed[idx] > best.?) best = computed[idx];
        }
        return best;
    }

    fn syncAllLayerVisualOrder(self: *OverlayStack) void {
        var ordered: [MAX_LAYERS]usize = undefined;
        const count = self.collectOrderedLayerIndices(&ordered, false);
        // Each layer actual z = max(tier baseline + same-tier sequence*2, nested parent z + 2).
        // Explicit z_index_override bypasses tier/inheritance (caller responsible).
        var computed: [MAX_LAYERS]i16 = @as([MAX_LAYERS]i16, @splat(0));
        var tier_seq = @as([@import("zenit_reflection").fields(StackTier).len]i16, @splat(0));
        // CSS Top Layer FIFO: dialog caps all previously active overlay/dialog layers. Trigger
        // inheritance
        // insufficient; Modal has no trigger_node (modal from popover gets no parent), tier
        // sequence may
        // match inherited-elevated popover, order degrades to DOM mount. tooltip/toast tiers
        // excluded
        // (tooltip always topmost semantically).
        var active_max_below_toast: i16 = 0;
        for (ordered[0..count], 0..) |idx, pos| {
            if (self.layers.items[idx]) |*layer| {
                const base_z = layer.z_index_override orelse blk: {
                    const tier = layerTier(layer);
                    const seq = &tier_seq[@backingInt(tier)];
                    var z = tier.base() +| seq.* * 2;
                    seq.* += 1;
                    if (self.resolveTrigger(layer)) |trigger| {
                        if (self.nestedParentZ(trigger, ordered[0..count], &computed, pos)) |pz| {
                            z = @max(z, pz +| 2);
                        }
                    }
                    if (tier == .dialog) z = @max(z, active_max_below_toast +| 2);
                    break :blk z;
                };
                computed[idx] = base_z;
                const tier_for_max = layerTier(layer);
                const layer_active = !layer.suspended and layer.state != .exiting;
                if (layer_active and layer.z_index_override == null and
                    (tier_for_max == .overlay or tier_for_max == .dialog))
                {
                    active_max_below_toast = @max(active_max_below_toast, base_z +| 1);
                }
                if (layer.barrier_node) |barrier| {
                    writeNodeZIndex(barrier, base_z);
                    if (layer.content_node) |content| {
                        writeNodeZIndex(content, base_z + 1);
                    }
                } else if (layer.content_node) |content| {
                    writeNodeZIndex(content, base_z);
                }
            }
        }
    }

    fn syncLayerHitTestVisibility(layer: *OverlayLayer) void {
        const visible = !layer.suspended and layer.state != .exiting;
        if (layer.barrier_node) |barrier| {
            barrier.setHitTestVisible(visible);
        }
        if (layer.content_node) |content| {
            content.setHitTestVisible(visible and layer.config.content_hit_test_visible);
        }
    }
};

fn approxRectEq(a: ComputedRect, b: ComputedRect) bool {
    return std.math.approxEqAbs(f32, a.x, b.x, 0.25) and
        std.math.approxEqAbs(f32, a.y, b.y, 0.25) and
        std.math.approxEqAbs(f32, a.w, b.w, 0.25) and
        std.math.approxEqAbs(f32, a.h, b.h, 0.25);
}

fn holdEnterUntilGeometryStable(layer: *OverlayLayer, allocator: Allocator) bool {
    const content = layer.content_node orelse return false;
    if (layer.state != .entering) return false;
    if (layer.enter_paused) return true;

    const rect = content.rectFromWorldOrFallback();
    if (rect.w <= 0.1 or rect.h <= 0.1) {
        layer.enter_last_content_rect = rect;
        setManualTransitionFlags(content, layer.config.enter_transition, true);
        layer.enter_ctrl.apply(content, allocator);
        return true;
    }

    const layout_unstable = content.frame_state.state_bits.dirty.core.layout or content.frame_state.state_bits.dirty.core.subtree_layout;
    const rect_changed = if (layer.enter_last_content_rect) |prev| !approxRectEq(prev, rect) else true;
    layer.enter_last_content_rect = rect;

    if (layout_unstable or rect_changed) {
        // Re-anchor the transition clock so frozen frames don't get paid back
        // as a large jump on the next visible frame.
        layer.enter_ctrl.last_tick_time_ms = render_engine.current_frame_time_ms;
        setManualTransitionFlags(content, layer.config.enter_transition, true);
        layer.enter_ctrl.apply(content, allocator);
        if (layer.barrier_node) |barrier| {
            setManualTransitionFlags(barrier, layer.config.enter_transition, true);
            barrier.setOpacityRaw(layer.enter_ctrl.currentOpacity());
            barrier.markCompositeAnimFrameDirty();
        }
        return true;
    }

    // This runs after layout. A clean second observation matching the recorded
    // rect is enough: extra frame-count warmup adds adapter-dependent latency
    // without stronger geometry evidence. Dirty/changing geometry above still
    // holds and re-anchors the first visible step.
    return false;
}

// transitionAffectsOpacity / transitionAffectsTransform / layerNeedsCompositedGroup extracted to
// overlay_transition.zig (header re-export).

/// Land a layer on its settled open state without an enter animation. Both controllers are
/// driven to their fully shown end through `apply`, so this undoes exactly what the last exit
/// wrote (and what an enter cut short by an instant `.none` exit left) with the transitions' own
/// definition of shown, then lifts commitExit's direct hide as the end of an animated enter does.
fn settleShown(layer: *OverlayLayer, allocator: Allocator) void {
    const enter = layer.enter_ctrl.shown();
    const exit = layer.exit_ctrl.shown();
    if (layer.content_node) |content| {
        // `.dropdown` moves its translate by the change from the node's current opacity, so it
        // must see the hidden opacity: let it go first, before the other controller lifts it.
        const enter_first = layer.config.enter_transition == .dropdown;
        (if (enter_first) enter else exit).apply(content, allocator);
        (if (enter_first) exit else enter).apply(content, allocator);
        content.setOpacityRaw(1.0);
        content.markCompositeAnimFrameDirty();
    }
    if (layer.barrier_node) |barrier| {
        barrier.setOpacityRaw(enter.currentOpacity());
        barrier.markCompositeAnimFrameDirty();
    }
}

fn setManualTransitionFlags(node: *Node, transition: Transition, active: bool) void {
    const next_opacity = active and transitionAffectsOpacity(transition);
    const next_transform = active and transitionAffectsTransform(transition);
    if (node.frame_state.state_bits.flags.manual_opacity_animation_active == next_opacity and node.frame_state.state_bits.flags.manual_transform_animation_active == next_transform) return;
    const opacity_completed = node.frame_state.state_bits.flags.manual_opacity_animation_active and !next_opacity;
    const transform_completed = node.frame_state.state_bits.flags.manual_transform_animation_active and !next_transform;
    node.frame_state.state_bits.flags.manual_opacity_animation_active = next_opacity;
    node.frame_state.state_bits.flags.manual_transform_animation_active = next_transform;
    if (opacity_completed or transform_completed) {
        node.requestCompositeAnimationLinger(opacity_completed, transform_completed);
    }
    node.markCompositeDirty();
}

// ========== Factory functions ==========

/// Create an overlay layer
pub fn overlay(scope: *Scope, cx: *core.Cx, config: LayerConfig) !OverlayResult {
    const handle = try cx.overlay_stack.push(config);
    errdefer cx.overlay_stack.removePermanently(handle);
    const allocator = cx.allocator;
    const t = cx.tokens;

    // barrier node (modal type only)
    var barrier_node: ?*Node = null;
    errdefer if (barrier_node) |barrier| cx.freeNode(barrier);
    if (config.barrier != .none) {
        const color = switch (config.barrier) {
            .color => |c| c,
            .none => unreachable,
        };
        barrier_node = try box(cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .background = color,
            .justify = .center,
            .align_items = .center,
        }, .{});
        const b_ext = try barrier_node.?.style.ensureExtFallible(allocator);
        b_ext.z_index = handle.z_index;
        // barrier must explicitly get pointer hit role: empty box defaults pointer=false (no
        // handler),
        // modal backdrop click pierces to ScrollArea/content, hit-test misses node -> outside-click
        // logic
        // says "clicked outside" -> wrong close. With pointer role backdrop blocks all clicks
        // (modal
        // semantics: block background interaction), blank click dismisses.
        b_ext.hit_roles = .{ .pointer = true };
        // P6.2: barrier no avoid_opacity_layer; settle children-drop + cache self-contain
        // fixed, nested surface (barrier surface inside dialog surface) engine general rules
        // handle correctly; opacity<0.999 engine auto surface, rest no overhead.
    }

    // content node.
    const content_node = try box(cx, .{
        .position = .absolute,
        .direction = .column,
        .background = t.tokens.color.bg_secondary,
    }, .{});
    errdefer cx.freeNode(content_node);
    (try content_node.style.ensureExtFallible(allocator)).z_index = handle.z_index +| 1;

    // focus mgmt.
    if (config.focus.trap) {
        content_node.setFocusScope(.{
            .trap = true,
            .auto_focus = config.focus.auto_focus,
        });
    }

    // a11y: semantics owned by layer, register content_node unified apply (applyLayerSemantics).

    // portal contract (@6 step 1): barrier layers (Modal/Sheet) match Popover, always via
    // cx.ensurePopoverPortalRoot() portal (standalone Cx builds under root), no 'portal null
    // = caller inline append' branch. only fallback: cx.root==null pure unit-test: caller
    // append, inline mount **subject ancestor clip** (z_index can't escape overflow_hidden).
    // take portal pre-reserve capacity before cleanup register, later appendChild can't fail.
    var barrier_portal: ?*Node = null;
    if (barrier_node != null) {
        barrier_portal = cx.ensurePopoverPortalRoot() catch |err| switch (err) {
            error.RootUnavailable => null,
            else => return err,
        };
        if (barrier_portal) |portal| try portal.children.ensureUnusedCapacity(allocator, 1);
    }

    // scope cleanup: auto remove stack on dispose, free orphan nodes.
    const cleanup_ctx = try scope.allocator.create(CleanupContext);
    errdefer scope.allocator.destroy(cleanup_ctx);
    cleanup_ctx.* = .{ .handle = handle, .cx = cx, .content_node = content_node, .barrier_node = barrier_node };
    try scope.registerResource(@ptrCast(cleanup_ctx), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const ctx: *CleanupContext = @ptrCast(@alignCast(ptr));
            ctx.cx.overlay_stack.removePermanently(ctx.handle);
            // portal barrier hangs portal root (not caller), not freed with Show unload story
            // subtree, manually detach from portal free, avoid remnant.
            if (ctx.barrier_portaled) {
                if (ctx.barrier_node) |n| {
                    if (n.parent) |p| p.removeChild(n);
                    ctx.cx.freeDetachedNodeAfterScopeDispose(n);
                }
            }
            // free orphan nodes never added to UI tree (no parent = not on-tree, freeNode won't
            // cover).
            if (ctx.content_node) |n| {
                if (n.parent == null) ctx.cx.freeDetachedNodeAfterScopeDispose(n);
            }
            if (ctx.barrier_node) |n| {
                if (!ctx.barrier_portaled and n.parent == null) ctx.cx.freeDetachedNodeAfterScopeDispose(n);
            }
            alloc.destroy(ctx);
        }
    }.cleanup);

    // update layer node reference.
    if (cx.overlay_stack.findLayer(handle)) |layer| {
        OverlayStack.applyLayerSemantics(layer, content_node);
        layer.content_node = content_node;
        layer.barrier_node = barrier_node;
        if (config.focus.restore) {
            layer.previous_focus = cx.focus_manager.current_focus_handle;
        }
        OverlayStack.syncLayerHitTestVisibility(layer);
    }
    cx.overlay_stack.syncAllLayerVisualOrder();

    // portal: barrier layers (Modal/Sheet) hang portal (window-covering containing block),
    // not caller inline append. barrier absolute grow/grow resolve to full window, dialog
    // truly full-screen mask + center.
    var portaled = false;
    if (barrier_node) |barrier| {
        if (barrier_portal) |portal| {
            portal.appendChild(allocator, barrier) catch unreachable;
            portaled = true;
            cleanup_ctx.barrier_portaled = true;
        }
    }

    return .{
        .handle = handle,
        .barrier = barrier_node,
        .content = content_node,
        .portaled = portaled,
    };
}

const CleanupContext = struct {
    handle: LayerHandle,
    cx: *core.Cx,
    content_node: ?*Node = null,
    barrier_node: ?*Node = null,
    /// barrier hung portal root (not caller). scope dispose must manually detach from
    /// portal free, else portal remnant unloaded story modal node.
    barrier_portaled: bool = false,
};

// ========== anchor positioning ==========

pub const PopoverPosition = floating.Placement;

/// anchor config (float pinned to trigger).
pub const AnchorConfig = struct {
    target: *Node,
    placement: PopoverPosition = .bottom_start,
    offset: f32 = 4,
    flip: bool = true,
    shift: bool = true,
};

/// position calc for anchor layers (call in tick).
fn updateAnchorPosition(self: *const OverlayStack, layer: *OverlayLayer, vp_w: f32, vp_h: f32) void {
    const anchor = layer.anchor orelse return;
    const content = layer.content_node orelse return;
    const target = self.resolveTrackedNode(layer.anchor_target_handle, anchor.target) orelse return;

    const target_rect = target.rectFromWorldOrFallback();
    const content_rect = content.rectFromWorldOrFallback();
    const tw = target_rect.w;
    const th = target_rect.h;
    const pw = content_rect.w;
    const ph = content_rect.h;

    // size not layout yet, skip.
    if (pw == 0 or ph == 0) return;

    const trigger_global = target.globalRect();
    const trig_x = trigger_global.x;
    const trig_y = trigger_global.y;

    var middleware_buf: [3]floating.Middleware = undefined;
    var middleware_count: usize = 0;
    middleware_buf[middleware_count] = .{ .offset = .{ .main_axis = .{ .static = anchor.offset } } };
    middleware_count += 1;
    if (anchor.flip) {
        middleware_buf[middleware_count] = .{ .flip = .{} };
        middleware_count += 1;
    }
    if (anchor.shift) {
        middleware_buf[middleware_count] = .{ .shift = .{} };
        middleware_count += 1;
    }

    const positioned = floating.computePosition(
        floating.Rect.init(trig_x, trig_y, tw, th),
        floating.Rect.init(0, 0, pw, ph),
        floating.Rect.init(0, 0, vp_w, vp_h),
        .{
            .placement = anchor.placement,
            .middleware = middleware_buf[0..middleware_count],
        },
    );

    const new_tx = positioned.x - trig_x;
    const new_ty = positioned.y - trig_y;
    if (@abs(content.style.translate_x - new_tx) < 0.01 and @abs(content.style.translate_y - new_ty) < 0.01) return;
    content.style.translate_x = new_tx;
    content.style.translate_y = new_ty;
    // Authoritative invalidation combo: calling only markInteractionDirty would make the prebuilt
    // payload replay at the old position (same class of bug fixed in popover setPopoverTranslate).
    // Note: no component currently uses the generic layer.anchor path (all use popover
    // before_render); this guards against regression if enabled later.
    content.markCompositePropDirty();
}

// ========== helpers ==========

fn writeNodeZIndex(node: *Node, z_index: i16) void {
    if (node.style.ext) |ext| {
        if (ext.z_index == z_index) return;
        ext.z_index = z_index;
        node.markInteractionDirty();
        node.markRenderDirty();
    }
}

// ========== tests ==========

test "OverlayStack: push and z-index monotonic" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const h1 = try stack.push(.{ .kind = .modal });
    const h2 = try stack.push(.{ .kind = .non_modal });
    const h3 = try stack.push(.{ .kind = .non_modal });

    try std.testing.expect(h2.z_index > h1.z_index);
    try std.testing.expect(h3.z_index > h2.z_index);
    try std.testing.expectEqual(@as(u8, 3), stack.layer_count);
}

test "OverlayStack: stale trigger and anchor pointers require live handles" {
    const allocator = std.testing.allocator;
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    stack.setRegistry(&registry);

    const node = try Node.create(allocator, 92_001, .button, .{});
    defer node.destroy(allocator);
    try registry.rebuild(node);
    const handle = try stack.push(.{ .kind = .non_modal, .trigger_node = node });
    stack.setAnchor(handle, .{ .target = node });
    const layer = stack.findLayer(handle).?;
    try std.testing.expect(stack.resolveTrigger(layer) == node);
    try std.testing.expect(stack.resolveTrackedNode(layer.anchor_target_handle, layer.anchor.?.target) == node);

    registry.unregisterSubtree(node);
    try std.testing.expectEqual(@as(?*Node, null), stack.resolveTrigger(layer));
    try std.testing.expectEqual(@as(?*Node, null), stack.resolveTrackedNode(layer.anchor_target_handle, layer.anchor.?.target));
}

test "OverlayStack: commitExit tolerates synchronous dismiss disposal" {
    const allocator = std.testing.allocator;
    const owner = try core.SignalOwner.init(allocator);
    defer owner.deinit();
    const visible = try Signal(bool).create(owner, true);
    const content = try Node.create(allocator, 92_002, .box, .{});
    var content_alive = true;
    defer if (content_alive) content.destroy(allocator);

    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    const handle = try stack.push(.{
        .kind = .non_modal,
        .exit_transition = .none,
        .on_dismiss = visible,
    });
    stack.bindContentNode(allocator, handle, content);

    try @import("reactive.zig").createEffect(owner, .{
        .visible = visible,
        .stack = &stack,
        .handle = handle,
        .content = content,
        .content_alive = &content_alive,
        .allocator = allocator,
    }, struct {
        fn run(ctx: anytype) void {
            if (ctx.visible.get() or !ctx.content_alive.*) return;
            ctx.stack.removePermanently(ctx.handle);
            ctx.content.destroy(ctx.allocator);
            ctx.content_alive.* = false;
        }
    }.run);

    stack.commitExit(handle);
    try std.testing.expect(!content_alive);
    try std.testing.expectEqual(@as(u8, 0), stack.layer_count);
}

test "OverlayStack: exhausted z-index saturates and resets without trapping" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    stack.next_z = std.math.maxInt(i16) - 1;

    const high = try stack.push(.{ .kind = .non_modal });
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16) - 1), high.z_index);
    try std.testing.expectEqual(std.math.maxInt(i16), stack.next_z);
    stack.removePermanently(high);
    try std.testing.expectEqual(@as(i16, 100), stack.next_z);

    const explicit = try stack.push(.{ .kind = .modal, .z_index = std.math.maxInt(i16) });
    try std.testing.expectEqual(std.math.maxInt(i16), explicit.z_index);
    try std.testing.expectEqual(std.math.maxInt(i16), stack.next_z);
}

test "OverlayStack: bindFloatingContent updates layer and visual z-index" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);

    stack.bindFloatingContent(allocator, handle, content);

    const layer = stack.findLayer(handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(layer.content_node == content);
    try std.testing.expectEqual(handle.z_index, content.style.z_index());
    try std.testing.expect(content.frame_state.state_bits.flags.hit_test_visible);
}

test "OverlayStack: beginExit with no exit transition suspends layer" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const h1 = try stack.push(.{ .kind = .non_modal, .exit_transition = .none });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);

    stack.beginExit(h1);
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expect(layer.suspended);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "OverlayStack: handleEscape closes topmost" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    _ = try stack.push(.{ .kind = .modal, .dismiss = .{ .escape = true } });
    const h2 = try stack.push(.{ .kind = .non_modal, .dismiss = .{ .escape = true } });
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // escape close top only.
    const consumed = stack.handleEscape();
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // h2 enter exit-anim (default exit_transition = .scale_fade).
    if (stack.findLayer(h2)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "OverlayStack: handleEscape blocked by modal" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    _ = try stack.push(.{ .kind = .non_modal, .dismiss = .{ .escape = true } });
    _ = try stack.push(.{ .kind = .modal, .dismiss = .{ .escape = false } });
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);

    // modal escape=false but modal self-block propagate.
    const consumed = stack.handleEscape();
    try std.testing.expect(consumed); // modal block.
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count); // no layer closed.
}

test "OverlayStack: isTopmost" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const h1 = try stack.push(.{ .kind = .modal });
    try std.testing.expect(stack.isTopmost(h1));

    const h2 = try stack.push(.{ .kind = .non_modal });
    try std.testing.expect(!stack.isTopmost(h1));
    try std.testing.expect(stack.isTopmost(h2));
}

test "OverlayStack: mutual exclusion group" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const h1 = try stack.push(.{ .kind = .non_modal, .group = "menu" });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
    try std.testing.expect(stack.findLayer(h1) != null);

    // same-group non_modal mutex.
    const h2 = try stack.push(.{ .kind = .non_modal, .group = "menu" });
    _ = h2;
    // h1 enter exit-anim (default exit_transition = .scale_fade).
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u8, 2), stack.layer_count);
}

// TransitionController 5 unit-tests moved to overlay_transition.zig with impl (fade
// enter/exit / none instant / enter delay / seedFromProgress).

test "OverlayStack: beginExit with exit transition stays in exiting state" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var test_time: f64 = 0;

    const h1 = try stack.push(.{
        .kind = .non_modal,
        .exit_transition = .fade,
        .enter_transition = .none, // immediately visible.
    });
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);

    // beginExit doesn't immediate-remove (exit-anim).
    stack.beginExit(h1);
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count); // still on stack.
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
    } else {
        return error.TestUnexpectedResult;
    }

    // tick advance anim until done.
    var ticks: u32 = 0;
    while (stack.findLayer(h1) != null and ticks < 100) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = stack.tick(test_time, 0.016, 1920, 1080, std.testing.allocator); // ~60fps
    }
    // post-anim suspended.
    if (stack.findLayer(h1)) |layer| {
        try std.testing.expect(layer.suspended);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u8, 1), stack.layer_count);
}

test "OverlayStack: reactivate promotes reopened layer to topmost and updates z-order" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const h1 = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const h2 = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const n1 = try Node.create(allocator, 1, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const n2 = try Node.create(allocator, 2, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    defer n1.destroy(allocator);
    defer n2.destroy(allocator);

    stack.bindFloatingContent(allocator, h1, n1);
    stack.bindFloatingContent(allocator, h2, n2);
    try std.testing.expect(stack.isTopmost(h2));
    try std.testing.expect(n2.style.z_index() > n1.style.z_index());

    stack.commitExit(h1);
    try std.testing.expect(!n1.frame_state.state_bits.flags.hit_test_visible);
    stack.reactivate(h1);

    try std.testing.expect(stack.isTopmost(h1));
    try std.testing.expect(n1.style.z_index() > n2.style.z_index());
    try std.testing.expect(n1.frame_state.state_bits.flags.hit_test_visible);
}

test "OverlayStack: tooltip tier 恒在 dialog 之上（无关打开顺序）" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    // tooltip first, dialog later: pure sequence would rank dialog top, tier baseline must win.
    const tip = try stack.push(.{ .kind = .non_modal, .tier = .tooltip, .enter_transition = .none, .exit_transition = .none });
    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const tip_n = try Node.create(allocator, 701, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const dlg_n = try Node.create(allocator, 702, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } });
    defer tip_n.destroy(allocator);
    defer dlg_n.destroy(allocator);
    stack.bindFloatingContent(allocator, tip, tip_n);
    stack.bindFloatingContent(allocator, dlg, dlg_n);

    try std.testing.expect(tip_n.style.z_index() >= StackTier.tooltip.base());
    try std.testing.expect(dlg_n.style.z_index() >= StackTier.dialog.base());
    try std.testing.expect(tip_n.style.z_index() > dlg_n.style.z_index());
}

test "OverlayStack: 嵌套继承 —— dialog content 里的 trigger 开 popover 压过 dialog" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const dlg_content = try Node.create(allocator, 711, .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } });
    defer dlg_content.destroy(allocator);
    const trigger = try Node.create(allocator, 712, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    try dlg_content.appendChild(allocator, trigger);
    stack.bindFloatingContent(allocator, dlg, dlg_content);

    // popover tier (100) << dialog (1000), inherit must lift it above dialog.
    const pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none, .trigger_node = trigger });
    const pop_n = try Node.create(allocator, 713, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer pop_n.destroy(allocator);
    stack.bindFloatingContent(allocator, pop, pop_n);

    try std.testing.expect(pop_n.style.z_index() > dlg_content.style.z_index());

    // popover no trigger node usual overlay tier baseline nearby.
    const free_pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const free_n = try Node.create(allocator, 714, .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } });
    defer free_n.destroy(allocator);
    stack.bindFloatingContent(allocator, free_pop, free_n);
    try std.testing.expect(free_n.style.z_index() < StackTier.dialog.base());
}

test "OverlayStack: 后开的 dialog 压过此前活动的 popover（Top Layer FIFO），但压不过 tooltip" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    // Open tooltip and popover first, then modal without trigger_node (e.g. Modal from popover
    // content, Modal component doesn't pass trigger).
    const tip = try stack.push(.{ .kind = .non_modal, .tier = .tooltip, .enter_transition = .none, .exit_transition = .none });
    const pop = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const dlg = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none });
    const tip_n = try Node.create(allocator, 721, .box, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } });
    const pop_n = try Node.create(allocator, 722, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const dlg_n = try Node.create(allocator, 723, .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } });
    defer tip_n.destroy(allocator);
    defer pop_n.destroy(allocator);
    defer dlg_n.destroy(allocator);
    stack.bindFloatingContent(allocator, tip, tip_n);
    stack.bindFloatingContent(allocator, pop, pop_n);
    stack.bindFloatingContent(allocator, dlg, dlg_n);

    // FIFO: later-open dialog >= prior popover (even no-trigger nesting).
    try std.testing.expect(dlg_n.style.z_index() > pop_n.style.z_index());
    // tooltip forever-top: not buried later dialog.
    try std.testing.expect(tip_n.style.z_index() > dlg_n.style.z_index());
}

test "OverlayStack: reactivate preserves prewarmed descendant render caches" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 310, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const child = try Node.create(allocator, 311, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);
    try content.appendChild(allocator, child);
    stack.bindFloatingContent(allocator, handle, content);

    const cached = [_]core.DisplayItem{
        .{ .fill_rect = .{
            .header = .{ .transform_id = 0, .node_id = 0 },
            .x = 0,
            .y = 0,
            .w = 80,
            .h = 24,
            .color = Color.rgba(255, 255, 255, 255),
            .radius = .{ 0, 0, 0, 0 },
        } },
    };
    content.cacheRenderCommands(allocator, &cached, 0, 0);
    child.cacheRenderCommands(allocator, &cached, 0, 0);

    stack.commitExit(handle);
    try std.testing.expect(content.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(child.meta.per_frame.caches.commands.own != null);

    stack.reactivate(handle);
    try std.testing.expect(content.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(child.meta.per_frame.caches.commands.own != null);
}

test "OverlayStack: findLayerForNode matches overlay descendants" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 401, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const child = try Node.create(allocator, 402, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } });
    defer content.destroy(allocator);
    try content.appendChild(allocator, child);
    stack.bindFloatingContent(allocator, handle, content);

    const layer = stack.findLayerForNode(child) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(handle.id, layer.handle.id);
}

test "OverlayStack: bound content gains pointer role without losing inspect" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .none });
    const content = try Node.create(allocator, 411, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    // bindContentNode only add pointer. history: struct `.{ .pointer = true }`, silently
    // inspect true->false, dialog/panel select-miss devtools. per-role override, inspect must
    // keep true.
    const roles = core.interaction_semantics.nodeHitRoles(content);
    try std.testing.expect(roles.pointer);
    try std.testing.expect(roles.inspect);
}

test "OverlayStack: exiting overlay stops intercepting hits before commitExit" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var registry = core.NodeRegistry.init(allocator);
    defer registry.deinit();
    var runtime = core.InteractionIndex.init(allocator);
    defer runtime.deinit();

    const root = try Node.create(allocator, 200, .box, .{ .width = .{ .px = 220 }, .height = .{ .px = 180 } });
    defer root.destroy(allocator);
    const under = try Node.create(allocator, 201, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    under.behavior.interaction.focusable = true;
    try root.appendChild(allocator, under);

    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = .fade });
    const overlay_node = try Node.create(allocator, 202, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    const option = try Node.create(allocator, 203, .button, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } });
    option.behavior.interaction.focusable = true;
    try overlay_node.appendChild(allocator, option);
    try root.appendChild(allocator, overlay_node);
    stack.bindFloatingContent(allocator, handle, overlay_node);

    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 220, .h = 180 });
    under.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    overlay_node.setLayoutRect(.{ .x = 20, .y = 20, .w = 120, .h = 80 });
    option.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = 80 });

    try registry.rebuild(root);
    try runtime.rebuild(root, &registry);

    const before = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(before != null);
    try std.testing.expectEqual(@as(u32, 203), before.?.node_id);

    stack.beginExit(handle);
    try std.testing.expect(!overlay_node.frame_state.state_bits.flags.hit_test_visible);
    try runtime.rebuild(root, &registry);

    const after = runtime.hitTestQuery(.{ .kind = .pointer, .world_x = 60, .world_y = 50 }, &registry, null);
    try std.testing.expect(after != null);
    try std.testing.expectEqual(@as(u32, 201), after.?.node_id);
}

test "OverlayStack: entering state transitions to visible" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const h1 = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .fade, // 150ms
        .exit_transition = .none,
    });

    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
    }

    // tick until done.
    var ticks: u32 = 0;
    while (ticks < 100) : (ticks += 1) {
        test_time += 16.0;
        render_engine.current_frame_time_ms = test_time;
        _ = stack.tick(test_time, 0.016, 1920, 1080, std.testing.allocator);
        if (stack.findLayer(h1)) |layer| {
            if (layer.state == .visible) break;
        }
    }

    if (stack.findLayer(h1)) |layer| {
        try std.testing.expectEqual(LayerState.visible, layer.state);
    }
}

test "OverlayStack: enter transition pending first tick preserves initial frame" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const handle = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .fade,
        .exit_transition = .none,
    });
    const content = try Node.create(allocator, 301, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    // Tick 1: rect == 0 -> holdEnterUntilGeometryStable() forces progress to 0
    // and keeps the layer in `entering`.
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    render_engine.current_frame_dt_ms = 16.0;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
        try std.testing.expectApproxEqAbs(@as(f32, 0), layer.enter_ctrl.progress, 0.001);
    } else {
        return error.TestUnexpectedResult;
    }

    // Simulate layout completing: assign a non-zero rect and clear the dirty
    // bits that holdEnterUntilGeometryStable() treats as "still settling".
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
    content.frame_state.state_bits.dirty.core.layout = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;

    // Record the first laid-out rect without exposing changing geometry.
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.entering, layer.state);
        try std.testing.expectApproxEqAbs(@as(f32, 0), layer.enter_ctrl.progress, 0.001);
    } else {
        return error.TestUnexpectedResult;
    }

    // Next tick: hold released, progress advances.
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expect(layer.enter_ctrl.progress > 0.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() > 0.0);
}

/// Runs `layer`'s exit to its end (suspended), the way a close does.
fn finishExitForTest(stack: *OverlayStack, handle: LayerHandle, time: *f64, allocator: Allocator) !void {
    stack.beginExit(handle);
    var frames: usize = 0;
    while (frames < 200 and !stack.findLayer(handle).?.suspended) : (frames += 1) {
        time.* += 16.0;
        render_engine.current_frame_time_ms = time.*;
        _ = stack.tick(time.*, 0.016, 1920, 1080, allocator);
    }
    try std.testing.expect(stack.findLayer(handle).?.suspended);
}

test "OverlayStack: a layer reopened without an enter transition is shown, not left as the exit ended it" {
    // A sheet remounted while open (language switch) carries enter `.none`; after an animated
    // close it must reopen exactly at rest: opaque, unscaled, not slid out, no dropdown offset.
    const allocator = std.testing.allocator;
    const rest = [2]f32{ 12, 34 };
    for (std.enums.values(Transition)) |exit| {
        if (exit != .none) {
            var stack = OverlayStack{ .allocator = std.testing.allocator };
            defer stack.deinit();
            var time: f64 = 0;
            render_engine.current_frame_time_ms = 0;
            const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .none, .exit_transition = exit });
            const content = try Node.create(allocator, 303, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
            defer content.destroy(allocator);
            content.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
            stack.bindFloatingContent(allocator, handle, content);
            content.setOpacityRaw(1.0);
            // A host-positioned dropdown (Popover): rest translate plus the slide tracking opacity.
            const slides = exit == .slide_bottom or exit == .slide_right or exit == .slide_left or exit == .slide_top;
            if (!slides) {
                content.style.translate_x = rest[0];
                content.style.translate_y = rest[1];
            }
            stack.findLayer(handle).?.exit_ctrl.slide = .{ 0, -6 };

            try finishExitForTest(&stack, handle, &time, allocator);
            try std.testing.expect(content.getOpacity() < 0.01);

            stack.reactivateWith(handle, .{ .animate = false });
            try std.testing.expectEqual(LayerState.visible, stack.findLayer(handle).?.state);
            try std.testing.expectEqual(@as(f32, 1.0), content.getOpacity());
            try std.testing.expectEqual(@as(f32, 1.0), content.style.scale_x());
            try std.testing.expectEqual(@as(f32, 1.0), content.style.scale_y());
            const want = if (slides) [2]f32{ 0, 0 } else rest;
            try std.testing.expectApproxEqAbs(want[0], content.style.translate_x, 0.001);
            try std.testing.expectApproxEqAbs(want[1], content.style.translate_y, 0.001);
            if (content.style.ext) |ext| {
                try std.testing.expectEqual([2]f32{ 0, 0 }, ext.motion_offset);
            }
        }
    }
}

test "OverlayStack: an enter cut short by an instant close reopens shown" {
    // Enter `.scale_fade` interrupted by a `.none` exit (commits at once): no exit ran, so the
    // half-entered opacity and scale are what an instant reopen must undo.
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    render_engine.current_frame_time_ms = 0;
    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .scale_fade, .exit_transition = .none });
    const content = try Node.create(allocator, 304, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
    stack.bindFloatingContent(allocator, handle, content);
    var time: f64 = 0;
    for (0..4) |_| {
        time += 16.0;
        render_engine.current_frame_time_ms = time;
        _ = stack.tick(time, 0.016, 1920, 1080, allocator);
    }
    try std.testing.expect(content.style.scale_x() < 1.0);
    stack.beginExit(handle);
    try std.testing.expect(stack.findLayer(handle).?.suspended);

    stack.reactivateWith(handle, .{ .animate = false });
    try std.testing.expectEqual(@as(f32, 1.0), content.getOpacity());
    try std.testing.expectEqual(@as(f32, 1.0), content.style.scale_x());

    // A normal reopen still animates from the hidden state.
    stack.beginExit(handle);
    stack.reactivate(handle);
    try std.testing.expectEqual(LayerState.entering, stack.findLayer(handle).?.state);
    time += 16.0;
    render_engine.current_frame_time_ms = time;
    _ = stack.tick(time, 0.016, 1920, 1080, allocator);
    try std.testing.expect(content.getOpacity() < 1.0);
    try std.testing.expect(content.style.scale_x() < 1.0);
}

test "OverlayStack: exit transition holds visible frame before fading" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var test_time: f64 = 0;
    render_engine.current_frame_time_ms = 0;

    const handle = try stack.push(.{
        .kind = .non_modal,
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 302, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);
    content.setOpacityRaw(1.0);

    stack.beginExit(handle);
    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expectEqual(LayerState.exiting, layer.state);
        try std.testing.expect(layer.exit_ctrl.progress > 0.85 and layer.exit_ctrl.progress <= 1.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() > 0.85 and content.getOpacity() <= 1.0);

    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    if (stack.findLayer(handle)) |layer| {
        try std.testing.expect(layer.exit_ctrl.progress < 1.0);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(content.getOpacity() < 1.0);
}

test "OverlayStack: reactivated layer ignores opener outside-click for one frame" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    var test_time: f64 = 0;

    const handle = try stack.push(.{
        .kind = .modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .fade,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 501, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    const opener = try Node.create(allocator, 502, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 32 } });
    defer content.destroy(allocator);
    defer opener.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    stack.commitExit(handle);
    try std.testing.expect(stack.findLayer(handle).?.suspended);

    stack.reactivate(handle);
    try std.testing.expect(stack.findLayer(handle).?.skip_outside_click_frame);

    stack.handleOutsideClick(true, opener);
    try std.testing.expectEqual(LayerState.entering, stack.findLayer(handle).?.state);

    test_time += 16.0;
    render_engine.current_frame_time_ms = test_time;
    _ = stack.tick(test_time, 0.016, 1920, 1080, allocator);
    try std.testing.expect(!stack.findLayer(handle).?.skip_outside_click_frame);

    stack.handleOutsideClick(true, opener);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(handle).?.state);
}

test "OverlayStack: non-hit-test overlay content does not block outside-click dismissal below" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const modal_like = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const modal_content = try Node.create(allocator, 601, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer modal_content.destroy(allocator);
    stack.bindFloatingContent(allocator, modal_like, modal_content);

    const snapshot_like = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .none, .escape = false },
        .enter_transition = .none,
        .exit_transition = .none,
        .content_hit_test_visible = false,
    });
    const snapshot_content = try Node.create(allocator, 602, .box, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } });
    const outside_target = try Node.create(allocator, 603, .button, .{ .width = .{ .px = 80 }, .height = .{ .px = 32 } });
    defer snapshot_content.destroy(allocator);
    defer outside_target.destroy(allocator);
    stack.bindFloatingContent(allocator, snapshot_like, snapshot_content);

    stack.handleOutsideClick(true, outside_target);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(modal_like).?.state);
    try std.testing.expectEqual(LayerState.visible, stack.findLayer(snapshot_like).?.state);
}

test "OverlayStack: null hit target still counts as outside click" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    const handle = try stack.push(.{
        .kind = .non_modal,
        .dismiss = .{ .outside_click = .close, .escape = true },
        .enter_transition = .none,
        .exit_transition = .fade,
    });
    const content = try Node.create(allocator, 611, .box, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);

    stack.handleOutsideClick(true, null);
    try std.testing.expectEqual(LayerState.exiting, stack.findLayer(handle).?.state);
}

test "OverlayStack: clear" {
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();

    _ = try stack.push(.{ .kind = .modal });
    _ = try stack.push(.{ .kind = .non_modal });
    _ = try stack.push(.{ .kind = .toast });
    try std.testing.expectEqual(@as(u8, 3), stack.layer_count);

    stack.clear();
    try std.testing.expectEqual(@as(u8, 0), stack.layer_count);
}

// --- extracted-module test collection ---
// Warning: `pub const x = @import(...)` re-export **won't** collect that file's test
// blocks (see build.zig:556-570 text module note). Must register with a bare
// `_ = @import("...")` as a test source for the tests to run.
//
// overlay_transition.zig: TransitionController clock/curve table tests.
// overlay_layer_refs.zig: trigger/anchor dangling-ptr liveness tests.
test {
    _ = @import("overlay_transition.zig");
    _ = @import("overlay_layer_refs.zig");
}

test "OverlayStack: 对话框语义归 layer 所有，多次重绑不丢失、不错挂、不清节点固有语义" {
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    const dialog_semantics: A11yProps = .{ .role = .dialog, .label = "Settings", .modal = true };
    const handle = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .none, .a11y = dialog_semantics });

    const a = try Node.create(allocator, 11, .box, .{});
    defer a.destroy(allocator);
    const b = try Node.create(allocator, 12, .box, .{});
    defer b.destroy(allocator);
    const own = try Node.create(allocator, 13, .box, .{});
    defer own.destroy(allocator);
    own.behavior.interaction.a11y = .{ .role = .group, .label = "Own" };
    const d = try Node.create(allocator, 14, .box, .{});
    defer d.destroy(allocator);

    stack.bindContentNode(allocator, handle, a);
    try std.testing.expectEqual(core.A11yRole.dialog, a.behavior.interaction.a11y.?.role);

    // swap to b: a's layer-applied withdrawn, b gets dialog semantics.
    stack.bindContentNode(allocator, handle, b);
    try std.testing.expect(a.behavior.interaction.a11y == null);
    try std.testing.expectEqual(core.A11yRole.dialog, b.behavior.interaction.a11y.?.role);

    // swap to self-declared: theirs, b's withdrawn, own native semantics kept.
    stack.bindContentNode(allocator, handle, own);
    try std.testing.expect(b.behavior.interaction.a11y == null);
    try std.testing.expectEqualStrings("Own", own.behavior.interaction.a11y.?.label.?);

    // swap to blank: dialog semantics remain (old impl here lost entire), own native
    // untouched.
    stack.bindContentNode(allocator, handle, d);
    try std.testing.expectEqual(core.A11yRole.dialog, d.behavior.interaction.a11y.?.role);
    try std.testing.expectEqualStrings("Own", own.behavior.interaction.a11y.?.label.?);

    // component rewrote layer-applied then swap: rewrite trails semantics, old no phantom
    // modal (value-judge would leave rewritten copy = 'not layer's' wrongly).
    d.behavior.interaction.a11y.?.label = "Settings (edited)";
    stack.bindContentNode(allocator, handle, a);
    try std.testing.expect(d.behavior.interaction.a11y == null);
    try std.testing.expectEqualStrings("Settings (edited)", a.behavior.interaction.a11y.?.label.?);
    try std.testing.expect(a.behavior.interaction.a11y.?.modal);

    // through one yield (own self-declared) then swap blank: rewrite value continues, no
    // reset to initial.
    stack.bindContentNode(allocator, handle, own);
    try std.testing.expect(a.behavior.interaction.a11y == null);
    stack.bindContentNode(allocator, handle, b);
    try std.testing.expectEqualStrings("Settings (edited)", b.behavior.interaction.a11y.?.label.?);
}

test "OverlayStack: semantic actions respect modal and portaled trigger chains" {
    const a = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    const background = try Node.create(a, 500, .button, .{});
    defer background.destroy(a);
    const modal = try Node.create(a, 501, .box, .{});
    defer modal.destroy(a);
    const trigger = try Node.create(a, 502, .button, .{});
    try modal.appendChild(a, trigger);
    const popover = try Node.create(a, 503, .box, .{});
    defer popover.destroy(a);
    const nested = try Node.create(a, 504, .button, .{});
    defer nested.destroy(a);
    try std.testing.expect(stack.allowsSemanticAction(background));
    const m = try stack.push(.{ .kind = .modal, .enter_transition = .none, .exit_transition = .fade });
    stack.bindFloatingContent(a, m, modal);
    try std.testing.expect(!stack.allowsSemanticAction(background));
    try std.testing.expect(stack.allowsSemanticAction(trigger));
    const p = try stack.push(.{ .kind = .non_modal, .trigger_node = trigger });
    stack.bindFloatingContent(a, p, popover);
    const n = try stack.push(.{ .kind = .non_modal, .trigger_node = popover });
    stack.bindFloatingContent(a, n, nested);
    try std.testing.expect(stack.allowsSemanticAction(popover));
    try std.testing.expect(stack.allowsSemanticAction(nested));
    // An unrelated newer popup cannot punch through the modal boundary.
    stack.findLayer(p).?.trigger_node = background;
    try std.testing.expect(!stack.allowsSemanticAction(popover));
    try std.testing.expect(!stack.allowsSemanticAction(nested));
    stack.findLayer(p).?.trigger_node = trigger;
    const inner = try stack.push(.{ .kind = .modal, .enter_transition = .none });
    const inner_node = try Node.create(a, 505, .button, .{});
    defer inner_node.destroy(a);
    stack.bindFloatingContent(a, inner, inner_node);
    try std.testing.expect(!stack.allowsSemanticAction(trigger));
    try std.testing.expect(!stack.allowsSemanticAction(nested));
    try std.testing.expect(stack.allowsSemanticAction(inner_node));
    stack.commitExit(inner);
    try std.testing.expect(!stack.allowsSemanticAction(inner_node));
    try std.testing.expect(stack.allowsSemanticAction(nested));
    stack.beginExit(m);
    try std.testing.expect(!stack.allowsSemanticAction(trigger));
    try std.testing.expect(stack.allowsSemanticAction(background));
}

test "OverlayStack: slow clean geometry releases without extra GPU frame holds" {
    const previous_time = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = previous_time;
    const allocator = std.testing.allocator;
    var stack = OverlayStack{ .allocator = std.testing.allocator };
    defer stack.deinit();
    render_engine.current_frame_time_ms = 0;
    const handle = try stack.push(.{ .kind = .non_modal, .enter_transition = .fade, .exit_transition = .none });
    const content = try Node.create(allocator, 390, .box, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } });
    defer content.destroy(allocator);
    stack.bindFloatingContent(allocator, handle, content);
    const layer = stack.findLayer(handle).?;
    try std.testing.expect(holdEnterUntilGeometryStable(layer, allocator)); // no geometry
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 40 });
    content.frame_state.state_bits.dirty.core.layout = false;
    content.frame_state.state_bits.dirty.core.subtree_layout = false;
    try std.testing.expect(holdEnterUntilGeometryStable(layer, allocator)); // baseline
    render_engine.current_frame_time_ms = 250;
    try std.testing.expect(!holdEnterUntilGeometryStable(layer, allocator)); // equal, clean
    content.frame_state.state_bits.dirty.core.layout = true;
    try std.testing.expect(holdEnterUntilGeometryStable(layer, allocator)); // dirty must reset
    render_engine.current_frame_time_ms = 500;
    try std.testing.expect(holdEnterUntilGeometryStable(layer, allocator)); // still dirty
    content.frame_state.state_bits.dirty.core.layout = false;
    render_engine.current_frame_time_ms = 516;
    try std.testing.expect(!holdEnterUntilGeometryStable(layer, allocator)); // clean equal geometry, even at 16 ms
    content.setLayoutRect(.{ .x = 0, .y = 0, .w = 90, .h = 40 });
    try std.testing.expect(holdEnterUntilGeometryStable(layer, allocator)); // size changed
    render_engine.current_frame_time_ms = 550;
    try std.testing.expect(!holdEnterUntilGeometryStable(layer, allocator));
}
