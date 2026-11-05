/// Retained control flow primitives.
///
/// Show: conditional render, condition true mount content, false unmount and destroy.
/// For: list render, increment-render list per data Signal (key-based diff).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const Node = core.Node;
const Cx = core.Cx;
const Scope = core.Scope;
const Signal = core.Signal;
const reactive = @import("reactive.zig");

// The next generated branch/row root is an independently replaceable view.
// Consumed by template.Site; restored across nested dev emit/reentry. Release
// keeps the original control-flow path without these descriptors or wrappers.
const preview_enabled = @import("zenit_environment").dev_preview;
pub var template_region_pending: if (preview_enabled) bool else void = if (preview_enabled) false else {};
pub const TemplateRegionIdentity = struct { controller: ?*anyopaque = null, key: ?u64 = null };
pub var template_region_identity: if (preview_enabled) TemplateRegionIdentity else void = if (preview_enabled) .{} else {};

/// Build subtree in untrack: component mount reads don't become control flow effect
/// dependencies (else any Signal child reads becomes Show/Match/For effect dep, Match may
/// rebuild subtree). Mirrors Solid: component function body untracked.
pub fn callUntracked(cx: *Cx, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const Args = @TypeOf(args);
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return cx.owner.untrack(struct {
        fn call(a: Args) R {
            return @call(.auto, f, a);
        }
    }.call, args);
}

/// Control flow drive source: *Signal(T) / *Memo(T) / derived value / Source(T) all
/// work (docs/SIGNAL_API_DESIGN.md section 4.9), e.g. ui.Show(scope, root, ui.eq(page,
/// .settings), ...).
fn sourceArg(comptime T: type, comptime who: []const u8, x: anytype) reactive.Source(T) {
    const X = @TypeOf(x);
    if (X == T) return .{ .value = x };
    const V = reactive.SourceValueOf(X);
    if (V != T) @compileError(who ++ ": expected a source of " ++ @typeName(T) ++ ", got " ++ @typeName(X) ++ " (value type " ++ @typeName(V) ++ ")");
    return reactive.toSource(x);
}

/// Control flow (Show/For/Match) internal error report.
///
/// These callbacks are driven by reactive effects and their signature can't return an error, so
/// OOM / build failures must not be silently swallowed (UI would silently miss a piece with no
/// logs or counts).
///
/// Without changing the callback signature: (1) log with source + original error; (2) count for
/// tests/diagnostic asserts. A true error boundary needs an effect-layer error sink (future work).
pub var control_flow_error_count: u64 = 0;

/// Test silent switch: Zig test runner treats std.log.err as test failure, but "error
/// reported" is exactly behavior we assert, so give tests silent bypass, count still increments.
pub var control_flow_suppress_error_log: bool = false;

fn reportControlFlowError(site: []const u8, err: anyerror) void {
    control_flow_error_count += 1;
    if (comptime @import("zenit_environment").dev_preview) if (@import("preview_mount.zig").reportFailure(err)) return;
    if (control_flow_suppress_error_log) return;
    std.log.scoped(.zenit_control_flow).err(
        "{s} failed: {s} (UI subtree omitted; see control_flow_error_count)",
        .{ site, @errorName(err) },
    );
}

/// Cleanup never pre-clears whole-tree scope pointers: when the transaction scope is disposed,
/// attached nodes (and descendants) are already unbound; still-non-null pointers come only from
/// external live scopes (Node child elements) and are handed to freeNode to dispose together,
/// else they leak until the caller scope is destroyed.
///
/// Mount failure cleans the unattached subtree in normal unmount order: unset hook state ->
/// dispose scope (cleanup still sees live nodes) -> clear node scope pointers -> destroyDetached
/// (free ElementTable slot, clear Cx refs). Don't use node.destroy: it skips the above and frees
/// nodes before scope dispose.
fn discardUnmountedSubtree(cx: *Cx, child_scope: *Scope, node: *Node) void {
    hooks.invalidateSubtreeHookState(node);
    if (!child_scope.disposed) child_scope.dispose();
    if (node.parent) |p| cx.detachChild(p, node);
    cx.destroyDetached(node);
}

// ============================================================================
// Area: control flow content's insertion point in the parent node
// ============================================================================
//
// Show / Match content created with `parent.appendChild` lands after all siblings when the
// condition turns true later; For positions by 'non-For sibling count before it', which drifts
// if earlier dynamic areas (Show open/close) change the count. Both only work when the parent
// holds a single control flow.
//
// Mirrors Solid's marker: each area owns an anchor pair [start, end) in the parent
// (ElementTag.anchor, display:none, no space/gap, no hit/a11y); content always inserts before
// end. Area content can be several nodes, including nested areas: clearing by position drops
// everything between start and end (nested anchors and content included), and nested areas'
// own scopes are disposed recursively by the outer child scope.

/// Node placement: insert before `before`, append to parent when `before == null`.
///
/// `parent == null` is capture mode (Sink.capture): a single root goes to the `root` slot,
/// not attached to the tree; the slot holder (view.render root or For loop) delivers/cleans up.
///
/// Rollback contract: a mount (one 'transaction') stops on first error, so at most one
/// 'built but failed-to-attach' node goes to the `stray` slot. The transaction owner cleans up
/// in unload order: hook invalidation -> dispose scope (cleanup can still see live
/// nodes) -> free attached content and stray. Child locations derive from `child()`,
/// sharing the same stray slot.
pub const Sink = struct {
    parent: ?*Node,
    before: ?*Node = null,
    stray: ?*?*Node = null,
    root: ?*?*Node = null,

    pub fn capture(root: *?*Node, stray: ?*?*Node) Sink {
        return .{ .parent = null, .root = root, .stray = stray };
    }

    /// Append child element location (same transaction).
    pub fn child(self: Sink, parent: *Node) Sink {
        return .{ .parent = parent, .stray = self.stray };
    }

    /// Mount a freshly-built detached node. On failure, node won't leak: either it goes to
    /// stray slot awaiting transaction rollback, or (without stray slot) it gets freed
    /// immediately.
    pub fn insert(self: Sink, cx: *Cx, node: *Node) !void {
        const parent = self.parent orelse {
            const slot = self.root.?;
            if (slot.* == null) {
                slot.* = node;
                return;
            }
            // Capture accepts only one root; extra nodes mean element implementation breach
            // (single-node element emitted multiple).
            self.park(cx, node);
            return error.ViewMultipleRoots;
        };
        parent.insertChildBefore(cx.allocator, node, self.before) catch |err| {
            self.park(cx, node);
            return err;
        };
    }

    fn park(self: Sink, cx: *Cx, node: *Node) void {
        if (self.stray) |slot| {
            if (slot.* == null) {
                slot.* = node;
                return;
            }
        }
        cx.freeDetachedNodeAfterScopeDispose(node);
    }
};

/// Cleanup after capture mount failure: hook invalidation -> dispose scope -> free
/// root and stray.
pub fn discardCaptured(cx: *Cx, scope: *Scope, root: ?*Node, stray: ?*Node) void {
    if (root) |n| hooks.invalidateSubtreeHookState(n);
    if (stray) |n| hooks.invalidateSubtreeHookState(n);
    if (!scope.disposed) scope.dispose();
    inline for (.{ root, stray }) |maybe| {
        if (maybe) |n| {
            if (n.parent) |p| cx.detachChild(p, n);
            cx.destroyDetached(n);
        }
    }
}

/// Dynamic region in parent, bounded by anchor pair [start, end).
pub const Region = struct {
    start: *Node,
    end: *Node,
    /// Failed-insertion nodes (see Sink.stray), freed by clear after scope dispose.
    stray: ?*Node = null,

    /// Place anchor pair at location. Region must fall in real parent (capture mode has
    /// no location).
    pub fn open(cx: *Cx, at: Sink) !Region {
        const parent = at.parent orelse return error.ViewRegionNeedsParent;
        const start = try core.anchorNode(cx);
        try (Sink{ .parent = parent, .before = at.before }).insert(cx, start);
        errdefer {
            cx.detachChild(parent, start);
            cx.freeNode(start);
        }
        const end = try core.anchorNode(cx);
        try (Sink{ .parent = parent, .before = at.before }).insert(cx, end);
        return .{ .start = start, .end = end };
    }

    /// Content location of region (before end).
    pub fn sink(self: *Region) Sink {
        return .{ .parent = self.end.parent.?, .before = self.end, .stray = &self.stray };
    }

    /// Content between anchors. Null if anchors no longer share a parent (parent was
    /// rewritten externally).
    fn contentRange(self: *const Region) ?struct { parent: *Node, lo: usize, hi: usize } {
        const parent = self.end.parent orelse return null;
        if (self.start.parent != parent) return null;
        const items = parent.children.items;
        const lo = std.mem.indexOfScalar(*Node, items, self.start) orelse return null;
        const hi = std.mem.indexOfScalar(*Node, items, self.end) orelse return null;
        if (hi <= lo) return null;
        return .{ .parent = parent, .lo = lo + 1, .hi = hi };
    }

    pub fn isEmpty(self: *const Region) bool {
        const r = self.contentRange() orelse return true;
        return r.lo == r.hi and self.stray == null;
    }

    /// Unload region content, same order as single-node unload: strip hook state ->
    /// dispose scope (cleanup sees live nodes) -> clear scope pointer -> strip tree/free.
    /// No allocation: take siblings after start until end sequentially.
    pub fn clear(self: *Region, cx: *Cx, content_scope: ?*Scope) void {
        if (self.contentRange()) |r| {
            for (r.parent.children.items[r.lo..r.hi]) |n| hooks.invalidateSubtreeHookState(n);
        }
        if (self.stray) |n| hooks.invalidateSubtreeHookState(n);
        if (content_scope) |cs| {
            if (!cs.disposed) cs.dispose();
        }
        if (self.contentRange()) |r| {
            const parent = r.parent;
            while (true) {
                const i = std.mem.indexOfScalar(*Node, parent.children.items, self.start) orelse break;
                if (i + 1 >= parent.children.items.len) break;
                const n = parent.children.items[i + 1];
                if (n == self.end) break;
                cx.detachChild(parent, n);
                cx.freeNode(n);
            }
            parent.markLayoutDirty();
        }
        if (self.stray) |n| {
            self.stray = null;
            cx.destroyDetached(n);
        }
        cx.needs_redraw = true;
    }

    /// Remove together with anchors (only for first-mount rollback; normal unload frees
    /// anchors via parent).
    pub fn close(self: *Region, cx: *Cx, content_scope: ?*Scope) void {
        self.clear(cx, content_scope);
        inline for (.{ self.end, self.start }) |a| {
            if (a.parent) |p| cx.detachChild(p, a);
            cx.freeNode(a);
        }
    }
};

/// Value-switch region: Show / Match / view DSL show/match share this core.
///
/// A `value` change (eqlValue) unloads old content and rebuilds under a new child scope by
/// calling `emit(ctx, child_scope, cx, sink, value)`. emit may place any number of nodes in
/// sink (including nested regions) or none (Show false branch). emit runs untracked: reads
/// during content mount don't become region dependencies.
pub fn SwitchRegion(comptime T: type, comptime Ctx: type, comptime emit: anytype) type {
    return struct {
        const Self = @This();

        region: Region,
        content_scope: ?*Scope = null,
        current: T,
        parent_scope: *Scope,
        cx: *Cx,
        ctx: Ctx,

        /// Static-value branch: emit directly to location, content belongs to caller scope,
        /// no anchors/effects.
        pub const emitOnce = emit;

        /// Mount region at `at` and build content once at current value. On first-mount
        /// failure, rollback with anchors; error propagates unchanged.
        pub fn mount(scope: *Scope, cx: *Cx, at: Sink, value: reactive.Source(T), ctx: Ctx) !*Self {
            reactive.checkBorrow(scope, value);
            const self = try scope.allocator.create(Self);
            self.* = .{
                .region = undefined,
                .current = value.peek(),
                .parent_scope = scope,
                .cx = cx,
                .ctx = ctx,
            };
            // adoptResource registration failure frees with destroy; can't destroy again here.
            try scope.adoptResource(@ptrCast(self), destroy);
            self.region = try Region.open(cx, at);
            self.build() catch |err| {
                self.region.close(cx, self.content_scope);
                self.content_scope = null;
                return err;
            };

            // Effect build failure leaves region unresponsive: rollback anchors and content
            // together, honoring 'first-mount failure leaves no remnants' contract.
            scope.createEffect(.{ .value = value, .self = self }, struct {
                fn update(c: anytype) void {
                    const v = c.value.get();
                    const s = c.self;
                    if (@import("reactive/eq.zig").eqlValue(T, v, s.current)) return;
                    s.current = v;
                    s.rebuild();
                }
            }.update) catch |err| {
                self.region.close(cx, self.content_scope);
                self.content_scope = null;
                return err;
            };
            return self;
        }

        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const s: *Self = @ptrCast(@alignCast(ptr));
            allocator.destroy(s);
        }

        /// Build content; caller decides rollback granularity (first: with anchors; later:
        /// content only).
        fn build(self: *Self) !void {
            const cs = try self.parent_scope.childScope();
            self.content_scope = cs;
            const pending = if (comptime preview_enabled) template_region_pending else {};
            const identity = if (comptime preview_enabled) template_region_identity else {};
            if (comptime preview_enabled) {
                template_region_pending = true;
                template_region_identity = .{ .controller = self };
            }
            defer if (comptime preview_enabled) {
                template_region_pending = pending;
                template_region_identity = identity;
            };
            try callUntracked(self.cx, emit, .{ self.ctx, cs, self.cx, self.region.sink(), self.current });
            self.region.end.parent.?.markLayoutDirty();
            self.cx.needs_redraw = true;
        }

        /// Unload current content and rebuild at current (shared by effect and
        /// MatchHandle.invalidate).
        pub fn rebuild(self: *Self) void {
            self.region.clear(self.cx, self.content_scope);
            self.content_scope = null;
            self.build() catch |err| {
                reportControlFlowError("Switch.rebuild", err);
                self.region.clear(self.cx, self.content_scope);
                self.content_scope = null;
            };
        }

        fn rebuildErased(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.rebuild();
        }

        pub fn handle(self: *Self) MatchHandle {
            return .{ .state = @ptrCast(self), .rebuild_fn = &rebuildErased };
        }
    };
}

/// Single-node build fn -> region emit adapter: build then mount.
fn emitOne(sink: Sink, cx: *Cx, node: *Node) !void {
    try sink.insert(cx, node);
}

/// Show, conditional render.
///
/// When the condition is true, call buildFn to create the subtree and mount it to parent;
/// when false, destroy the child scope and remove children from parent.
/// Content stays fixed at the Show call position (later appended siblings won't pass it).
///
/// Usage:
/// ```zig
/// try Show(scope, parent, is_visible, cx, struct {
///     fn build(child_scope: *Scope, c: *Cx) anyerror!*Node {
///         return try Button(.{ .label = "Hello" }).mount(child_scope, c);
///     }
/// }.build);
/// ```
pub fn Show(
    scope: *Scope,
    parent: *Node,
    condition_arg: anytype,
    cx: *Cx,
    comptime buildFn: fn (*Scope, *Cx) anyerror!*Node,
) !void {
    const condition = sourceArg(bool, "Show", condition_arg);
    const R = SwitchRegion(bool, void, struct {
        fn emit(_: void, child_scope: *Scope, c: *Cx, sink: Sink, visible: bool) anyerror!void {
            if (!visible) return;
            try emitOne(sink, c, try buildFn(child_scope, c));
        }
    }.emit);
    _ = try R.mount(scope, cx, .{ .parent = parent }, condition, {});
}

/// For control flow options (key_fn required, eq_props_fn optional).
///
/// Three functions with separate responsibilities:
/// - `key_fn`: item -> unique key (required). **Identity** check: which two items are
///   'the same'. Use `item.id` / `item.hash()`; not index (shifts on add/delete).
/// - `render_fn`: render function (required). child_scope holds reactive resources,
///   auto-disposed on cleanup.
/// - `eq_props_fn`: prev vs next **props equal** (optional). Default null ->
///   eqlValue smart compare ([]const u8 by content / NaN bytewise / nested struct
///   recursive). true = reuse old node (no rerender); false = destroy+create.
///   Fast path: compare only key fields, skipping cached_handle and internals,
///   or `fn(_, _) bool { return true; }` to always reuse (pair with a reactive signal
///   for dirty tracking).
pub fn ForOpts(comptime T: type) type {
    return struct {
        key_fn: fn (T) u64,
        render_fn: fn (*Scope, *Cx, T, usize) anyerror!*Node,
        eq_props_fn: ?fn (T, T) bool = null,
    };
}

/// For core options: row render gets context (view DSL needs: row reads values from
/// call site, Zig lacks closures), emit row root to capture slot not direct return --
/// row internal mount failure leaves half-built tree in slot, recoverable by 'scope
/// dispose then node free' cleanup order.
pub fn ForCtxOpts(comptime T: type, comptime Ctx: type) type {
    return struct {
        key_fn: fn (T) u64,
        /// Row render; usize is mount index for this row (unchanged after reorder).
        render_fn: ?fn (Ctx, *Scope, *Cx, Sink, T, usize) anyerror!void = null,
        /// Row render receiving own index signal: reused row after reorder gets new index
        /// (one of three options).
        render_index_fn: ?fn (Ctx, *Scope, *Cx, Sink, T, *reactive.Signal(usize)) anyerror!void = null,
        /// Row render receiving own data source and index signals (third option): same-key
        /// content unchanged doesn't rebuild, update this row's data source, row follows
        /// (in-place update).
        render_source_fn: ?fn (Ctx, *Scope, *Cx, Sink, *reactive.Signal(T), *reactive.Signal(usize)) anyerror!void = null,
        eq_props_fn: ?fn (T, T) bool = null,
    };
}

/// For: incremental list rendering.
///
/// Renders a list incrementally from an items slice Signal.
/// opts.key_fn extracts a unique key per item for identity matching; opts.eq_props_fn decides
/// props equivalence (reuse vs rebuild).
/// Parent ownership is not exclusive: For items stay at the position where For is called
/// (between anchor points); sibling additions/removals before/after (including other control flow
/// areas) don't affect them.
///
/// Usage:
/// ```zig
/// try For([]const u8, scope, parent, items_signal, cx, .{
///     .key_fn = struct { fn k(item: []const u8) u64 { return std.hash.Wyhash.hash(0, item); } }.k,
///     .render_fn = struct { fn r(child_scope: *Scope, c: *Cx, item: []const u8, idx: usize)
///     anyerror!*Node {
///         _ = idx;
///         return try ui.text(c, item, .{});
///     }}.r,
///     // .eq_props_fn = null,  // default uses eqlValue
/// });
/// ```
pub fn For(
    comptime T: type,
    scope: *Scope,
    parent: *Node,
    data_arg: anytype,
    cx: *Cx,
    comptime opts: ForOpts(T),
) !void {
    const data = sourceArg([]const T, "For", data_arg);
    _ = try ForRegion(T, void, .{
        .key_fn = opts.key_fn,
        .render_fn = struct {
            fn r(_: void, s: *Scope, c: *Cx, sink: Sink, item: T, idx: usize) anyerror!void {
                try emitOne(sink, c, try opts.render_fn(s, c, item, idx));
            }
        }.r,
        .eq_props_fn = opts.eq_props_fn,
    }).mount(scope, cx, .{ .parent = parent }, data, {});
}

/// For core: entries are continuous nodes [start, end) in parent region, one per row.
pub fn ForRegion(comptime T: type, comptime Ctx: type, comptime opts: ForCtxOpts(T, Ctx)) type {
    const keyFn = opts.key_fn;
    if (@as(u8, @intFromBool(opts.render_fn != null)) + @intFromBool(opts.render_index_fn != null) + @intFromBool(opts.render_source_fn != null) != 1)
        @compileError("ForRegion: give exactly one of render_fn / render_index_fn / render_source_fn");
    const eqProps = opts.eq_props_fn;
    return struct {
        const Self = @This();
        const ItemEntry = struct {
            key: u64,
            item: T,
            scope: *Scope,
            node: *Node,
            lease: ?*@import("view.zig").RootLease = null,

            /// render_index_fn / render_source_fn row index signal (belongs to row scope).
            index: ?*reactive.Signal(usize) = null,
            /// render_source_fn row data source (belongs to row scope).
            source: ?*reactive.Signal(T) = null,

            fn currentNode(entry: ItemEntry) ?*Node {
                return if (entry.lease) |lease| lease.resolve() else entry.node;
            }

            fn cleanupNode(entry: ItemEntry) ?*Node {
                return if (entry.lease) |lease| lease.retainedNode() else entry.node;
            }
        };
        const Rendered = struct { node: *Node, lease: ?*@import("view.zig").RootLease, index: ?*reactive.Signal(usize), source: ?*reactive.Signal(T) = null };

        entries: std.ArrayList(ItemEntry),
        region: Region,
        parent_scope: *Scope,
        cx_ptr: *Cx,
        alloc: Allocator,
        ctx: Ctx,
        /// Last placeEntries failed: entries may have detached (not-on-tree) row nodes.
        has_unplaced: bool = false,

        pub fn mount(scope: *Scope, cx: *Cx, at: Sink, data: reactive.Source([]const T), ctx: Ctx) !*Self {
            reactive.checkBorrow(scope, data);
            const state = try scope.allocator.create(Self);
            state.* = .{
                .entries = .empty,
                .region = undefined,
                .parent_scope = scope,
                .cx_ptr = cx,
                .alloc = scope.allocator,
                .ctx = ctx,
            };
            // adoptResource registration failure frees with destroy; can't destroy again here.
            try scope.adoptResource(@ptrCast(state), destroy);
            state.region = try Region.open(cx, at);
            state.mountInitial(data.peek()) catch |err| {
                state.region.close(cx, null);
                return err;
            };

            // Effect: respond to data changes, key-based diff incremental update. Fails to build ->
            // rollback whole region. First run reconciles normally: can't skip by slice identity
            // ('data unchanged') -- in-place-modified arrays / data sources synced back during
            // render
            // both miss; diff all when content equal to only pay reconcile cost.
            scope.createEffect(.{ .data = data, .state = state }, struct {
                fn update(c: anytype) void {
                    c.state.reconcile(c.data.get());
                }
            }.update) catch |err| {
                for (state.entries.items) |entry| if (entry.currentNode()) |node| hooks.invalidateSubtreeHookState(node);
                for (state.entries.items) |entry| {
                    if (!entry.scope.disposed) entry.scope.dispose();
                }
                for (state.entries.items) |entry| if (entry.lease) |lease| lease.release();
                state.entries.clearRetainingCapacity();
                state.region.close(cx, null);
                return err;
            };
            return state;
        }

        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            const s: *Self = @ptrCast(@alignCast(ptr));
            // After placeEntries fails, newly-built rows remain detached outside tree, only entries
            // track them; scope cleanup can't release via parent. Entry scope is parent_scope
            // child,
            // already disposed. Only read node.parent when actually orphaned: normal path entries
            // stay
            // on tree, freed via parent.
            if (s.has_unplaced) {
                for (s.entries.items) |entry| {
                    const node = entry.cleanupNode() orelse continue;
                    if (node.parent != null) continue;
                    hooks.invalidateSubtreeHookState(node);
                    s.cx_ptr.destroyDetached(node);
                }
            }
            for (s.entries.items) |entry| if (entry.lease) |lease| lease.release();
            s.entries.deinit(allocator);
            allocator.destroy(s);
        }

        /// Render one row. On failure, self-cleanup (scope before node); caller must NOT
        /// dispose child_scope further.
        fn render(self: *Self, child_scope: *Scope, item: T, idx: usize) !Rendered {
            const pending = if (comptime preview_enabled) template_region_pending else {};
            const identity = if (comptime preview_enabled) template_region_identity else {};
            if (comptime preview_enabled) {
                template_region_pending = true;
                template_region_identity = .{ .controller = self, .key = keyFn(item) };
            }
            defer if (comptime preview_enabled) {
                template_region_pending = pending;
                template_region_identity = identity;
            };
            var root: ?*Node = null;
            var stray: ?*Node = null;
            var index: ?*reactive.Signal(usize) = null;
            var source: ?*reactive.Signal(T) = null;
            if (opts.render_source_fn) |f| {
                const sig = child_scope.createSignal(usize, idx) catch |err| {
                    child_scope.dispose();
                    return err;
                };
                const src = child_scope.createSignal(T, item) catch |err| {
                    child_scope.dispose();
                    return err;
                };
                index = sig;
                source = src;
                callUntracked(self.cx_ptr, f, .{ self.ctx, child_scope, self.cx_ptr, Sink.capture(&root, &stray), src, sig }) catch |err| {
                    discardCaptured(self.cx_ptr, child_scope, root, stray);
                    return err;
                };
            } else if (opts.render_index_fn) |f| {
                const sig = child_scope.createSignal(usize, idx) catch |err| {
                    child_scope.dispose();
                    return err;
                };
                index = sig;
                callUntracked(self.cx_ptr, f, .{ self.ctx, child_scope, self.cx_ptr, Sink.capture(&root, &stray), item, sig }) catch |err| {
                    discardCaptured(self.cx_ptr, child_scope, root, stray);
                    return err;
                };
            } else {
                callUntracked(self.cx_ptr, opts.render_fn.?, .{ self.ctx, child_scope, self.cx_ptr, Sink.capture(&root, &stray), item, idx }) catch |err| {
                    discardCaptured(self.cx_ptr, child_scope, root, stray);
                    return err;
                };
            }
            const node = root orelse {
                discardCaptured(self.cx_ptr, child_scope, null, stray);
                return error.ForRowEmpty;
            };
            const lease = @import("view.zig").RootLease.acquire(self.alloc, node) catch |err| {
                discardCaptured(self.cx_ptr, child_scope, root, stray);
                return err;
            };
            return .{ .node = node, .lease = lease, .index = index, .source = source };
        }

        /// First render. On failure, entries on-tree freed by region.close (scopes are
        /// parent_scope children, dispose before detach nodes).
        fn mountInitial(self: *Self, initial_items: []const T) !void {
            errdefer {
                for (self.entries.items) |entry| if (entry.currentNode()) |node| hooks.invalidateSubtreeHookState(node);
                for (self.entries.items) |entry| {
                    if (!entry.scope.disposed) entry.scope.dispose();
                }
                for (self.entries.items) |entry| if (entry.lease) |lease| lease.release();
                self.entries.clearRetainingCapacity();
            }
            for (initial_items, 0..) |item, idx| {
                const key = keyFn(item);
                const child_scope = try self.parent_scope.childScope();
                const rendered = try self.render(child_scope, item, idx);
                const node = rendered.node;
                errdefer if (rendered.lease) |lease| lease.release();
                // Pre-reserve entries capacity before attach-to-tree: can't fail between steps or
                // node on-tree but missing entries (diff never removes it).
                self.entries.ensureUnusedCapacity(self.alloc, 1) catch |err| {
                    discardUnmountedSubtree(self.cx_ptr, child_scope, node);
                    return err;
                };
                self.region.sink().insert(self.cx_ptr, node) catch |err| {
                    // Failed-insertion nodes in region.stray; clean up in unload order.
                    self.region.stray = null;
                    discardUnmountedSubtree(self.cx_ptr, child_scope, node);
                    return err;
                };
                self.entries.appendAssumeCapacity(.{
                    .key = key,
                    .item = item,
                    .scope = child_scope,
                    .node = node,
                    .lease = rendered.lease,
                    .index = rendered.index,
                    .source = rendered.source,
                });
            }
        }

        /// Key-based diff: keep same-key entries, only destroy/create changes.
        ///
        /// Allocate-then-mutate: bookkeeping tables (old key map, reuse flags, new entries)
        /// pre-allocate
        /// capacity before any entry is mutated, so later inserts never fail. A missing reuse flag
        /// would
        /// destroy in-use nodes (dangling/double free). A pre-alloc failure changes nothing: log
        /// the
        /// error and keep the original rows.
        fn reconcile(s: *Self, items: []const T) void {
            var old_map = std.AutoHashMap(u64, usize).init(s.alloc);
            defer old_map.deinit();
            var reused = std.AutoHashMap(usize, void).init(s.alloc); // mark reused old indices
            defer reused.deinit();
            var new_entries: std.ArrayList(ItemEntry) = .empty;
            const reserved = blk: {
                old_map.ensureTotalCapacity(@intCast(s.entries.items.len)) catch |err| break :blk err;
                reused.ensureTotalCapacity(@intCast(s.entries.items.len)) catch |err| break :blk err;
                new_entries.ensureTotalCapacity(s.alloc, items.len) catch |err| break :blk err;
                break :blk {};
            };
            reserved catch |err| {
                new_entries.deinit(s.alloc);
                reportControlFlowError("For.update/reserve", err);
                return;
            };

            // 1. old entries -> HashMap<key, index>
            for (s.entries.items, 0..) |entry, i| old_map.putAssumeCapacity(entry.key, i);

            // 2. iterate new items, reuse matches, create misses

            for (items, 0..) |item, idx| {
                const key = keyFn(item);
                if (old_map.get(key)) |old_idx| {
                    // A key may occur more than once even though keyed lists
                    // conventionally require uniqueness. Reusing the same old
                    // entry twice aliases its node/scope and later cleanup turns
                    // that alias into UAF/double-free. Only the first occurrence
                    // may consume an old entry; render later duplicates afresh.
                    if (reused.contains(old_idx)) {
                        s.appendEntry(&new_entries, key, item, idx) catch {};
                        continue;
                    }
                    var old_entry = s.entries.items[old_idx];
                    if (old_entry.currentNode() == null) {
                        s.discardEntry(old_entry);
                        reused.putAssumeCapacity(old_idx, {});
                        s.appendEntry(&new_entries, key, item, idx) catch {};
                        continue;
                    }
                    // row receives data source: same key reuses, content changed updates this row's
                    // source
                    // (in-place, preserves focus/hover/local state).
                    if (old_entry.source) |src| {
                        // same content also swaps to new value (no notification): borrowed strings
                        // point to new
                        // array; caller may free old soon after.
                        if (@import("reactive/eq.zig").eqlValue(T, item, old_entry.item)) src.replaceSameContent(item) else src.set(item);
                        old_entry.item = item;
                        if (old_entry.index) |sig| if (sig.peek() != idx) sig.set(idx);
                        new_entries.appendAssumeCapacity(old_entry);
                        reused.putAssumeCapacity(old_idx, {});
                        continue;
                    }
                    // caller can register eq_props_fn for custom reuse; defaults to eqlValue
                    // (reactive/eq.zig
                    // type-dispatch content compare, handles []const u8 / NaN / nested struct). key
                    // match
                    // but props unequal still rebuilds.
                    const can_reuse = if (eqProps) |f|
                        f(item, old_entry.item)
                    else
                        @import("reactive/eq.zig").eqlValue(T, item, old_entry.item);
                    if (can_reuse) {
                        // index signal = this item's position in items (data index, same coordinate
                        // system as
                        // new row mount; skipped failed rows don't shift).
                        if (old_entry.index) |sig| if (sig.peek() != idx) sig.set(idx);
                        // comparison baseline swaps to this batch's elements: old left behind, next
                        // batch's
                        // eqlValue reads already-swapped (possibly freed) old array.
                        old_entry.item = item;
                        new_entries.appendAssumeCapacity(old_entry);
                        // reuse flag must record: miss -> step 3 destroys node still in
                        // new_entries.
                        reused.putAssumeCapacity(old_idx, {});
                        continue;
                    }

                    s.discardEntry(old_entry);
                    // here old_entry.node already freeNode; flag miss = step 3 dispose/free same
                    // node
                    // again.
                    reused.putAssumeCapacity(old_idx, {});

                    s.appendEntry(&new_entries, key, item, idx) catch {};
                } else {
                    // new: key not in old list.
                    s.appendEntry(&new_entries, key, item, idx) catch {};
                }
            }

            // 3. destroy old map entries not reused.
            for (s.entries.items, 0..) |entry, i| {
                if (reused.contains(i)) continue;
                s.discardEntry(entry);
            }

            // 4. replace entries, must be unconditional and precede any fail-point: steps 2/3
            //    freed old nodes; catch return before this leaves dangling in s.entries (next diff
            //    double free), new_entries leak entire batch.
            s.entries.deinit(s.alloc);
            s.entries = new_entries;
            s.cx_ptr.needs_redraw = true;

            // 5. place entries in new order between anchors; out-of-anchor siblings stay put.
            //    fail = new nodes not yet on-tree but owned by s.entries; next diff mounts them.
            s.placeEntries() catch |err| {
                s.has_unplaced = true;
                reportControlFlowError("For.update/reorder", err);
                return;
            };
            s.has_unplaced = false;
        }

        fn discardEntry(s: *Self, entry: ItemEntry) void {
            const node = entry.cleanupNode();
            if (entry.lease) |lease| lease.release();
            if (node) |n| hooks.invalidateSubtreeHookState(n);
            if (!entry.scope.disposed) entry.scope.dispose();
            if (node) |n| {
                if (n.parent) |p| s.cx_ptr.detachChild(p, n);
                s.cx_ptr.freeNode(n);
            }
        }

        /// For 'create new entry' common path: childScope -> render -> bookkeeping; any step
        /// failure
        /// cascades rollback (a bare `catch return` per line would leak prior scope/node). The new
        /// node
        /// is detached here and placed by placeEntries. reconcile downgrades failed entries to skip
        /// (one
        /// fewer row this run; the next diff rebuilds it by key), no panic: DSL rows are user
        /// components
        /// and a mount error shouldn't crash.
        fn appendEntry(s: *Self, new_entries: *std.ArrayList(ItemEntry), key: u64, item: T, idx: usize) !void {
            const child_scope = s.parent_scope.childScope() catch |err| {
                reportControlFlowError("For.create/childScope", err);
                return err;
            };
            const rendered = s.render(child_scope, item, idx) catch |err| {
                reportControlFlowError("For.create/render", err);
                return err;
            };
            // capacity pre-reserved in reconcile head per items.len.
            new_entries.appendAssumeCapacity(.{
                .key = key,
                .item = item,
                .scope = child_scope,
                .node = rendered.node,
                .lease = rendered.lease,
                .index = rendered.index,
                .source = rendered.source,
            });
        }

        /// region content := entries (in order). siblings before start and after end untouched.
        fn placeEntries(s: *Self) !void {
            const parent = s.region.end.parent orelse return error.InvalidAnchor;
            const items = parent.children.items;
            const lo = std.mem.indexOfScalar(*Node, items, s.region.start) orelse return error.InvalidAnchor;
            const hi = std.mem.indexOfScalar(*Node, items, s.region.end) orelse return error.InvalidAnchor;
            if (hi <= lo) return error.InvalidAnchor;

            var order: std.ArrayList(*Node) = .empty;
            defer order.deinit(s.alloc);
            try order.ensureTotalCapacity(s.alloc, (lo + 1) + s.entries.items.len + (items.len - hi));
            order.appendSliceAssumeCapacity(items[0 .. lo + 1]);
            for (s.entries.items) |entry| if (entry.currentNode()) |node| {
                order.appendAssumeCapacity(node);
            };
            order.appendSliceAssumeCapacity(items[hi..]);
            try parent.replaceChildOrder(s.alloc, order.items);
        }
    };
}

/// Match: enum/integer conditional switching.
///
/// Like SolidJS <Switch>/<Match>: switches subtrees based on an enum or integer Signal.
/// On value change, destroys the old subtree and calls buildFn to create the new one.
///
/// Usage:
/// ```zig
/// try Match(Category, scope, parent, category_signal, cx,
///     struct {
///         fn build(child_scope: *Scope, c: *Cx, cat: Category) anyerror!*Node {
///             return switch (cat) {
///                 .buttons => try buildButtonsPage(child_scope, c),
///                 .inputs  => try buildInputsPage(child_scope, c),
///             };
///         }
///     }.build,
/// );
/// ```
/// Match handle for externally forcing rebuild
pub const MatchHandle = struct {
    state: *anyopaque,
    rebuild_fn: *const fn (*anyopaque) void,

    /// Force rebuild current subtree (theme switches etc).
    pub fn invalidate(self: MatchHandle) void {
        self.rebuild_fn(self.state);
    }
};

pub fn Match(
    comptime T: type,
    scope: *Scope,
    parent: *Node,
    value_arg: anytype,
    cx: *Cx,
    comptime buildFn: fn (*Scope, *Cx, T) anyerror!*Node,
) !MatchHandle {
    const value = sourceArg(T, "Match", value_arg);
    const R = SwitchRegion(T, void, struct {
        fn emit(_: void, child_scope: *Scope, c: *Cx, sink: Sink, v: T) anyerror!void {
            try emitOne(sink, c, try buildFn(child_scope, c, v));
        }
    }.emit);
    const state = try R.mount(scope, cx, .{ .parent = parent }, value, {});
    return state.handle();
}

// ===== test helpers =====

/// helper: content child count in parent. Control flow region anchors are position
/// bookkeeping, don't count as content.
fn contentCount(parent: *Node) usize {
    var n: usize = 0;
    for (parent.children.items) |c| {
        if (c.tag != .anchor) n += 1;
    }
    return n;
}

/// helper: i-th content child (skip anchors).
fn contentAt(parent: *Node, i: usize) *Node {
    var k: usize = 0;
    for (parent.children.items) |c| {
        if (c.tag == .anchor) continue;
        if (k == i) return c;
        k += 1;
    }
    @panic("contentAt: index out of range");
}

test "Show: basic toggle" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, false);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            const n = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 50 },
            });
            c.linkNodeToWorld(n);
            n.setBackgroundRaw(core.Color.hex(0xff0000));
            return n;
        }
    }.build);

    // initial: invisible, no children.
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));

    // set visible.
    visible.set(true);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // set invisible.
    visible.set(false);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));

    // visible again.
    visible.set(true);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));
}

test "Show: initial true" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, true);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            return try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 50 },
                .height = .{ .px = 50 },
            });
        }
    }.build);

    // initially visible.
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // hide.
    visible.set(false);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
}

test "Show: reactive teardown runs scope cleanups before freeing its node" {
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const visible = try root_scope.createSignal(bool, true);

    const TeardownOrder = struct {
        node_freed: bool = false,
        cleanup_ran: bool = false,
        cleanup_saw_live_node: bool = false,
    };
    var order = TeardownOrder{};

    const Harness = struct {
        var marker: ?*TeardownOrder = null;

        fn build(child_scope: *Scope, c: *Cx) anyerror!*Node {
            const order_marker = marker.?;
            const node = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 10 },
                .height = .{ .px = 10 },
            });
            c.linkNodeToWorld(node);
            node.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
                fn freed(raw: *anyopaque) void {
                    const teardown: *TeardownOrder = @ptrCast(@alignCast(raw));
                    teardown.node_freed = true;
                }
            }.freed, @ptrCast(order_marker));
            try child_scope.onCleanup(TeardownOrder, order_marker, struct {
                fn cleanup(teardown: *TeardownOrder) void {
                    teardown.cleanup_ran = true;
                    teardown.cleanup_saw_live_node = !teardown.node_freed;
                }
            }.cleanup);
            return node;
        }
    };
    Harness.marker = &order;
    defer Harness.marker = null;

    try Show(root_scope, parent, visible, ctx, Harness.build);

    visible.set(false);
    try std.testing.expect(order.cleanup_ran);
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
}

test "For: basic list" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, value: i32 };
    const items_storage = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };

    const items = try root_scope.createSignal([]const Item, &items_storage);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(item: Item) u64 {
                return item.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
            }
        }.render,
    });

    // initial 3 entries.
    try std.testing.expectEqual(@as(usize, 3), contentCount(parent));

    // update to 2 entries.
    const items_2 = [_]Item{
        .{ .id = 1, .value = 100 },
        .{ .id = 4, .value = 40 },
    };
    items.set(&items_2);
    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));

    // clear to empty.
    const items_empty: []const Item = &.{};
    items.set(items_empty);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
}

test "For: key-based diff rebuilds nodes when item payload changes" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, value: i32 };
    const items_v1 = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };

    const items = try root_scope.createSignal([]const Item, &items_v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(item: Item) u64 {
                return item.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
            }
        }.render,
    });

    // save initial node pointers.
    const node_1 = contentAt(parent, 0);
    const node_2 = contentAt(parent, 1);
    const node_3 = contentAt(parent, 2);

    // update: remove id=2, id=1/id=3 payload changes, add id=4.
    const items_v2 = [_]Item{
        .{ .id = 1, .value = 100 },
        .{ .id = 3, .value = 300 },
        .{ .id = 4, .value = 40 },
    };
    items.set(&items_v2);

    try std.testing.expectEqual(@as(usize, 3), contentCount(parent));
    // id=1 / id=3 payload changed should rebuild, avoid reusing stale node.
    try std.testing.expect(contentAt(parent, 0) != node_1);
    try std.testing.expect(contentAt(parent, 1) != node_3);
    // id=4 is new node.
    try std.testing.expect(contentAt(parent, 2) != node_2);

    // reverse: keep id=4, remove id=1 and id=3.
    const node_4 = contentAt(parent, 2);
    const items_v3 = [_]Item{
        .{ .id = 4, .value = 400 },
    };
    items.set(&items_v3);

    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));
    // id=4 payload 40 -> 400, current policy rebuilds.
    try std.testing.expect(contentAt(parent, 0) != node_4);
}

test "Match: enum switch" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Mode = enum(u8) { alpha = 0, beta, gamma };
    const mode = try root_scope.createSignal(Mode, .alpha);

    _ = try Match(Mode, root_scope, parent, mode, ctx, struct {
        fn build(_: *Scope, c: *Cx, val: Mode) anyerror!*Node {
            const h: f32 = switch (val) {
                .alpha => 10,
                .beta => 20,
                .gamma => 30,
            };
            return try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = h },
            });
        }
    }.build);

    // initial: alpha -> 1 child.
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // switch to beta.
    mode.set(.beta);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // switch to gamma.
    mode.set(.gamma);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // switch back to alpha.
    mode.set(.alpha);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    // set same value shouldn't trigger rebuild (verify no crash).
    mode.set(.alpha);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));
}

// ========================================================================
// v0.7 §2.4, For control flow key-only + eq_props_fn tests
// ========================================================================

test "For eq_props_fn=true 强制复用，key 命中即不重建" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{ .{ .id = 1, .payload = 10 }, .{ .id = 2, .payload = 20 } };
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // force always reuse even when payload changed (caller self-manages dirty via
        // reactive signal).
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return true;
            }
        }.eq,
    });

    const node_1 = contentAt(parent, 0);
    const node_2 = contentAt(parent, 1);

    // payload changed, eq_props_fn=true forces reuse.
    const v2 = [_]Item{ .{ .id = 1, .payload = 999 }, .{ .id = 2, .payload = 888 } };
    items.set(&v2);

    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));
    try std.testing.expectEqual(node_1, contentAt(parent, 0)); // same ptr, no rebuild.
    try std.testing.expectEqual(node_2, contentAt(parent, 1));
}

test "For eq_props_fn=false 强制重建，每次 update 都换 node" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{.{ .id = 1, .payload = 10 }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // force always rebuild.
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return false;
            }
        }.eq,
    });

    const node_1 = contentAt(parent, 0);

    // Change the payload so signal.set sees an unequal value. The key stays 1; default eqlValue
    // would rebuild (payload changed); eq_props_fn=false here verifies the caller override is
    // explicit even if eq_props_fn is always false. The reverse case 'payload unchanged +
    // eq_props_fn=false' can't be tested standalone: the signal short-circuits on equality and the
    // effect never runs. So use payload change + forced false to verify eq_props_fn is truly
    // called.
    const v2 = [_]Item{.{ .id = 1, .payload = 999 }};
    items.set(&v2);
    try std.testing.expect(contentAt(parent, 0) != node_1);
}

test "For eq_props_fn 选择性比较字段（忽略 cached_handle）" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct {
        id: u64,
        label: i32,
        cached_handle: u64, // caller internal cache changes every update, doesn't affect render.
    };
    const v1 = [_]Item{.{ .id = 1, .label = 10, .cached_handle = 0xABCD }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // compare only label, ignore cached_handle.
        .eq_props_fn = struct {
            fn eq(a: Item, b: Item) bool {
                return a.label == b.label;
            }
        }.eq,
    });

    const node_1 = contentAt(parent, 0);

    // cached_handle changed, label unchanged -> reuse.
    const v2 = [_]Item{.{ .id = 1, .label = 10, .cached_handle = 0xDEAD }};
    items.set(&v2);
    try std.testing.expectEqual(node_1, contentAt(parent, 0));

    // label truly changed -> rebuild.
    const v3 = [_]Item{.{ .id = 1, .label = 20, .cached_handle = 0xDEAD }};
    items.set(&v3);
    try std.testing.expect(contentAt(parent, 0) != node_1);
}

test "For 默认 eq_props_fn=null 走 eqlValue (与历史行为一致)" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, name: []const u8 };
    const v1 = [_]Item{.{ .id = 1, .name = "alpha" }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
            }
        }.r,
        // eq_props_fn = null -> default eqlValue (content compare).
    });

    const node_1 = contentAt(parent, 0);

    // different ptr but same []const u8 content; std.meta.eql mismatch -> rebuild;
    // eqlValue compares content -> equal -> reuse.
    var name_buf: [16]u8 = undefined;
    @memcpy(name_buf[0..5], "alpha");
    const v2 = [_]Item{.{ .id = 1, .name = name_buf[0..5] }};
    items.set(&v2);
    try std.testing.expectEqual(node_1, contentAt(parent, 0));

    // truly renamed -> rebuild.
    const v3 = [_]Item{.{ .id = 1, .name = "beta" }};
    items.set(&v3);
    try std.testing.expect(contentAt(parent, 0) != node_1);
}

// ========================================================================
// For focus restoration e2e
// ========================================================================
//
// 1. Mount For with eq_props_fn=true (force reuse)
// 2. setFocus to the second node
// 3. items signal.set a new array (same key, different payload)
// 4. Assert: (a) Node ptr unchanged (eq_props_fn truly effective); (b) cx.isFocused still true
//
// If For doesn't reuse the same Node ptr, focus_manager's focused_node points to a freed Node ->
// isFocused = false or segfault; this validates that key + eq_props_fn reuse is the
// infrastructure for reactive focus restoration.
// ========================================================================

test "For eq_props_fn=true 时 reactive rerender 保持焦点" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{
        .{ .id = 1, .payload = 10 },
        .{ .id = 2, .payload = 20 },
        .{ .id = 3, .payload = 30 },
    };
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .px = 10 },
                    .height = .{ .px = 10 },
                });
                n.behavior.interaction.focusable = true;
                c.linkNodeToWorld(n);
                return n;
            }
        }.r,
        // force reuse, caller self-manages dirty via reactive signal, eq_props_fn=true key
        // match skips rebuild.
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return true;
            }
        }.eq,
    });

    try std.testing.expectEqual(@as(usize, 3), contentCount(parent));
    const node_2_before = contentAt(parent, 1);

    // focus on second node.
    ctx.setFocus(node_2_before);
    try std.testing.expect(ctx.isFocused(node_2_before));

    // change payload, signal detects unequal triggers effect, For uses reuse branch.
    const v2 = [_]Item{
        .{ .id = 1, .payload = 999 },
        .{ .id = 2, .payload = 888 },
        .{ .id = 3, .payload = 777 },
    };
    items.set(&v2);

    // (a) Node ptr unchanged.
    const node_2_after = contentAt(parent, 1);
    try std.testing.expectEqual(node_2_before, node_2_after);

    // (b) focus still clings to original Node, focus_manager.focused_node didn't
    // invalidate.
    try std.testing.expect(ctx.isFocused(node_2_after));
}

test "反向 case — eq_props_fn=false 时 Node 被销毁，焦点丢失" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Item = struct { id: u64, payload: i32 };
    const v1 = [_]Item{.{ .id = 1, .payload = 10 }};
    const items = try root_scope.createSignal([]const Item, &v1);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(i: Item) u64 {
                return i.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                n.behavior.interaction.focusable = true;
                c.linkNodeToWorld(n);
                return n;
            }
        }.r,
        .eq_props_fn = struct {
            fn eq(_: Item, _: Item) bool {
                return false; // force rebuild.
            }
        }.eq,
    });

    const node_1_before = contentAt(parent, 0);
    ctx.setFocus(node_1_before);
    try std.testing.expect(ctx.isFocused(node_1_before));

    // change payload, eq_props_fn=false triggers rebuild.
    const v2 = [_]Item{.{ .id = 1, .payload = 999 }};
    items.set(&v2);

    const node_1_after = contentAt(parent, 0);
    try std.testing.expect(node_1_after != node_1_before);
    // old node destroyed; focus_manager.focused_node no longer points to current child.
    try std.testing.expect(!ctx.isFocused(node_1_after));
}

test "control flow: build failure is reported, not silently swallowed" {
    // review @3: Show/For/Match effect callbacks historically all `catch return`,
    // OOM/build failure silently swallowed; no logging/counting. Now at least counts +
    // logs (true error boundary needs effect-layer error sink, future work). This test
    // locks 'no longer silent'.
    const ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try core.box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    ctx.root = parent;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const visible = try scope.createSignal(bool, false);

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const before = control_flow_error_count;
    try Show(scope, parent, visible, ctx, struct {
        fn build(_: *Scope, _: *Cx) anyerror!*Node {
            return error.OutOfMemory; // simulate build failure.
        }
    }.build);

    // open condition -> effect fires build -> must fail.
    visible.set(true);

    // key assert: failure logged (not silent return).
    try std.testing.expect(control_flow_error_count > before);
    // and no half-built subtree attached.
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
}

// Regression: Show/For/Switch subtree destruction must call cx.freeNode, not node.destroy.
// node.destroy frees only the Node itself and doesn't reclaim the ElementTable slot;
// world.destroyElement is called only from Cx.freeNode. Otherwise every Show switch leaks an
// element slot (plus 5 mirror-table remnants: interaction / dirty_set / content / paint_state /
// layout_output). ElementTable index is u24; long-running list apps eventually hit
// error.ElementTableFull.
test "regression: Show 反复切换不泄漏 ElementTable slot" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const visible = try root_scope.createSignal(bool, false);

    try Show(root_scope, parent, visible, ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            const n = try Node.create(c.allocator, c.nextId(), .box, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 50 },
            });
            c.linkNodeToWorld(n);
            return n;
        }
    }.build);

    // flip once to stabilize element count (first mount creates slots).
    visible.set(true);
    visible.set(false);
    const baseline = ctx.world.elements.count();

    // flip 50 times: slot unreclaimed -> count grows 50.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        visible.set(true);
        visible.set(false);
    }

    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

// ----- OOM invariant: For keyed reconcile -----
//
// A missing reuse flag destroys in-use nodes (dangling/double free), so reconcile bookkeeping
// inserts must never fail. Allocate-then-mutate: old key map, reuse flags and new entries
// capacity are reserved before mutating any entry; all inserts use AssumeCapacity; a pre-alloc
// failure changes nothing, logs the error and keeps the old rows. The effect's first run still
// reconciles (no skip by slice identity; see mount note), and a pre-alloc failure there also
// keeps old rows. Every alloc failure point is swept via RadioGroup (options from a signal).
// With ample memory, a mixed diff (reuse/rebuild/create/delete together) must leave parent
// children matching items 1:1.
test "For keyed reconcile: 复用/重建/新建/删除混合后子节点与 items 一一对应" {
    const Item = struct { id: u64, value: i32 };
    const allocator = std.testing.allocator;

    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 400 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const initial = [_]Item{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
        .{ .id = 3, .value = 30 },
    };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(it: Item) u64 {
                return it.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
                c.linkNodeToWorld(n);
                return n;
            }
        }.render,
    });
    try std.testing.expectEqual(initial.len, contentCount(parent));

    // save id=1 node ptr: must be reused as-is (not destroy-rebuild).
    const reused_node_before = contentAt(parent, 0);

    // mixed four: reuse id=1 / key match props changed rebuild id=3 / new key create
    // id=4 / id=2 gone deleted. one update hits both reused.put branches + both
    // appendForEntry branches.
    const updated = [_]Item{
        .{ .id = 1, .value = 10 }, // identical -> reuse.
        .{ .id = 3, .value = 999 }, // key match props change -> destroy rebuild.
        .{ .id = 4, .value = 40 }, // new key -> create.
    };
    items.set(&updated);

    // < 3 = missed reuse flag destroyed in-use node; > 3 = duplicate create same key.
    try std.testing.expectEqual(updated.len, contentCount(parent));
    // id=1 must be same Node object (true reuse, not destroy-rebuild new).
    try std.testing.expectEqual(reused_node_before, contentAt(parent, 0));

    // remove down to one, confirm delete path exact.
    const shrunk = [_]Item{.{ .id = 4, .value = 40 }};
    items.set(&shrunk);
    try std.testing.expectEqual(shrunk.len, contentCount(parent));

    // clear all: all nodes must leak-free (GPA reports at ctx.deinit).
    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
}

test "For keyed reconcile: duplicate keys never alias node or scope ownership" {
    const Item = struct { id: u64, value: i32 };
    const allocator = std.testing.allocator;

    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
    });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const duplicate = [_]Item{
        .{ .id = 7, .value = 70 },
        .{ .id = 7, .value = 70 },
    };
    const items = try root_scope.createSignal([]const Item, &duplicate);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn key(it: Item) u64 {
                return it.id;
            }
        }.key,
        .render_fn = struct {
            fn render(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{
                    .width = .{ .grow = .{} },
                    .height = .{ .px = 30 },
                });
                c.linkNodeToWorld(n);
                return n;
            }
        }.render,
    });

    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));
    try std.testing.expect(contentAt(parent, 0) != contentAt(parent, 1));

    // Exercise duplicate -> duplicate -> single -> empty. The old algorithm
    // first inserted one node twice, then freed it through the other entry.
    const duplicate_changed = [_]Item{
        .{ .id = 7, .value = 71 },
        .{ .id = 7, .value = 71 },
    };
    items.set(&duplicate_changed);
    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));
    try std.testing.expect(contentAt(parent, 0) != contentAt(parent, 1));

    const single = [_]Item{.{ .id = 7, .value = 70 }};
    items.set(&single);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));

    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
}

// ----- mount failure path: cleanup in proper unload order -----
//
// Failure rollback must not be two defers (node.destroy first, child_scope.dispose second):
// (1) scope cleanup would see a freed node; (2) Node.destroy doesn't reclaim the ElementTable
// slot (destroyElement only in Cx.freeNode). FailingAllocator fail_index is runtime-writable:
// set to alloc_index at the build tail so the next appendChild/entries expansion fails, then
// revert.
const MountFailureHarness = struct {
    var failing: ?*std.testing.FailingAllocator = null;
    var order: ?*Order = null;

    const Order = struct {
        node_freed: bool = false,
        cleanup_ran: bool = false,
        cleanup_saw_live_node: bool = false,
    };

    fn armNextAllocFailure() void {
        const fa = failing.?;
        fa.fail_index = fa.alloc_index;
        fa.resize_fail_index = fa.resize_index;
    }

    fn disarm() void {
        failing.?.fail_index = std.math.maxInt(usize);
        failing.?.resize_fail_index = std.math.maxInt(usize);
    }

    fn buildTracked(child_scope: *Scope, c: *Cx) anyerror!*Node {
        const marker = order.?;
        const node = try Node.create(c.allocator, c.nextId(), .box, .{
            .width = .{ .px = 10 },
            .height = .{ .px = 10 },
        });
        c.linkNodeToWorld(node);
        node.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
            fn freed(raw: *anyopaque) void {
                const o: *Order = @ptrCast(@alignCast(raw));
                o.node_freed = true;
            }
        }.freed, @ptrCast(marker));
        try child_scope.onCleanup(Order, marker, struct {
            fn cleanup(o: *Order) void {
                o.cleanup_ran = true;
                o.cleanup_saw_live_node = !o.node_freed;
            }
        }.cleanup);
        armNextAllocFailure();
        return node;
    }
};

test "Show: appendChild 失败时按卸载顺序回收（scope 先于节点、回收 element slot）" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const visible = try root_scope.createSignal(bool, false);

    var order = MountFailureHarness.Order{};
    MountFailureHarness.failing = &fa;
    MountFailureHarness.order = &order;
    defer MountFailureHarness.failing = null;
    defer MountFailureHarness.order = null;

    try Show(root_scope, parent, visible, ctx, MountFailureHarness.buildTracked);
    const baseline = ctx.world.elements.count();
    // place anchors already expanded children; tighten to exact fit so post-build insert
    // must allocate, truly hit 'built but failed-attach' rollback (else test empty-runs).
    parent.children.shrinkAndFree(allocator, parent.children.items.len);

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const errors_before = control_flow_error_count;
    visible.set(true);
    MountFailureHarness.disarm();

    try std.testing.expect(control_flow_error_count > errors_before);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
    try std.testing.expect(order.cleanup_ran);
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

test "For: 首次挂载 entries/appendChild 失败不泄漏节点、不留半截子树" {
    const Item = struct { id: u64 };
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const items_storage = [_]Item{ .{ .id = 1 }, .{ .id = 2 } };
    const items = try root_scope.createSignal([]const Item, &items_storage);

    var order = MountFailureHarness.Order{};
    MountFailureHarness.failing = &fa;
    MountFailureHarness.order = &order;
    defer MountFailureHarness.failing = null;
    defer MountFailureHarness.order = null;
    const baseline = ctx.world.elements.count();

    const result = For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(child_scope: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                return MountFailureHarness.buildTracked(child_scope, c);
            }
        }.r,
    });
    MountFailureHarness.disarm();

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
    try std.testing.expect(order.cleanup_saw_live_node);
    try std.testing.expect(order.node_freed);
    try std.testing.expectEqual(baseline, ctx.world.elements.count());
}

// ----- For and same-parent siblings coexist -----
//
// For effect every time (first too) replaceChildOrder(parent, For entries only),
// replaceChildOrder detaches all missing; same-parent title/Show nodes silent detach
// orphaned (no render + never freed).
test "For: 与同 parent 的前后兄弟共存，增删重排都不摘兄弟" {
    const Item = struct { id: u64 };
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 300 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const header = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    ctx.linkNodeToWorld(header);
    try parent.appendChild(allocator, header);

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const initial = [_]Item{ .{ .id = 1 }, .{ .id = 2 } };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, item: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                c.linkNodeToWorld(n);
                n.meta.ownership.meta.component_name = switch (item.id) {
                    1 => "i1",
                    2 => "i2",
                    3 => "i3",
                    else => "i?",
                };
                return n;
            }
        }.r,
    });

    try std.testing.expectEqual(@as(usize, 3), contentCount(parent));
    try std.testing.expectEqual(header, contentAt(parent, 0));
    try std.testing.expectEqual(parent, header.parent.?);

    // attach sibling after For.
    const footer = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    ctx.linkNodeToWorld(footer);
    try parent.appendChild(allocator, footer);

    const Expect = struct {
        fn names(p: *Node, h: *Node, f: *Node, comptime want: []const []const u8) !void {
            try std.testing.expectEqual(want.len + 2, contentCount(p));
            try std.testing.expectEqual(h, contentAt(p, 0));
            try std.testing.expectEqual(f, contentAt(p, contentCount(p) - 1));
            inline for (want, 0..) |w, i| {
                try std.testing.expectEqualStrings(w, contentAt(p, i + 1).meta.ownership.meta.component_name.?);
            }
        }
    };

    // insert.
    const inserted = [_]Item{ .{ .id = 1 }, .{ .id = 3 }, .{ .id = 2 } };
    items.set(&inserted);
    try Expect.names(parent, header, footer, &.{ "i1", "i3", "i2" });
    // reorder.
    const reordered = [_]Item{ .{ .id = 2 }, .{ .id = 1 }, .{ .id = 3 } };
    items.set(&reordered);
    try Expect.names(parent, header, footer, &.{ "i2", "i1", "i3" });
    // delete.
    const removed = [_]Item{.{ .id = 3 }};
    items.set(&removed);
    try Expect.names(parent, header, footer, &.{"i3"});
    // clear then restore: segment position must remember (no For node to reference when
    // list empty).
    const empty: []const Item = &.{};
    items.set(empty);
    try Expect.names(parent, header, footer, &.{});
    items.set(&initial);
    try Expect.names(parent, header, footer, &.{ "i1", "i2" });
}

// after steps 2/3 freed old nodes, reorder OOM, old impl `catch return` skipped entries
// replace: s.entries left stale (next diff free = double free), new_entries + rebuilt
// nodes leak. trigger: same key props change -> step 2 free old + render rebuild;
// render tail arm FailingAllocator, next reorder alloc fails. (deleted entry scope/node
// cleanup deferred in reactive callback, post-effect, can't arm.) new_entries initial
// capacity >= 2 (cache_line / @sizeOf(ItemEntry)), rebuild append won't allocate, fail
// lands on reorder, assert count confirms hit.
test "For: 旧节点已释放后重排 OOM 不留悬垂 entries、不泄漏" {
    const Item = struct { id: u64, v: u32 };
    const H = struct {
        var failing: ?*std.testing.FailingAllocator = null;
        var arm_on_render = false;
    };
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = fa.allocator();
    H.failing = &fa;
    defer H.failing = null;
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;

    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();
    const initial = [_]Item{ .{ .id = 1, .v = 0 }, .{ .id = 2, .v = 0 } };
    const items = try root_scope.createSignal([]const Item, &initial);

    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(item: Item) u64 {
                return item.id;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: Item, _: usize) anyerror!*Node {
                const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
                c.linkNodeToWorld(n);
                if (H.arm_on_render) {
                    const f = H.failing.?;
                    f.fail_index = f.alloc_index;
                }
                return n;
            }
        }.r,
    });
    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));

    control_flow_suppress_error_log = true;
    defer control_flow_suppress_error_log = false;
    const errors_before = control_flow_error_count;
    H.arm_on_render = true;
    const changed = [_]Item{ .{ .id = 1, .v = 0 }, .{ .id = 2, .v = 1 } };
    items.set(&changed);
    H.arm_on_render = false;
    fa.fail_index = std.math.maxInt(usize);
    // confirm truly hit reorder fail branch (else test fake-green).
    try std.testing.expect(control_flow_error_count > errors_before);

    // run diff a few more times: stale freed nodes in entries -> double free/UAF;
    // unmounted new owned by entries, next diff must remount.
    const empty: []const Item = &.{};
    items.set(empty);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
    items.set(&initial);
    try std.testing.expectEqual(@as(usize, 2), contentCount(parent));
}

fn testLeaf(c: *Cx) anyerror!*Node {
    const n = try Node.create(c.allocator, c.nextId(), .box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    c.linkNodeToWorld(n);
    return n;
}

test "Show / Match / For accept memos and derived values" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;
    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    // Show driven by derived signal: one enum vs N bool signals.
    const Page = enum { home, settings, about };
    const page = try root_scope.createSignal(Page, .home);
    try Show(root_scope, parent, reactive.eq(page, .settings), ctx, struct {
        fn build(_: *Scope, c: *Cx) anyerror!*Node {
            return testLeaf(c);
        }
    }.build);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));
    page.set(.settings);
    try std.testing.expectEqual(@as(usize, 1), contentCount(parent));
    page.set(.about);
    try std.testing.expectEqual(@as(usize, 0), contentCount(parent));

    // Match driven by memo.
    const n = try root_scope.createSignal(u32, 3);
    const parity = try root_scope.createMemo(bool, .{ .n = n }, struct {
        fn f(c: anytype) bool {
            return c.n.get() % 2 == 0;
        }
    }.f);
    const Seen = struct {
        var builds: u32 = 0;
    };
    Seen.builds = 0;
    _ = try Match(bool, root_scope, parent, parity, ctx, struct {
        fn build(_: *Scope, c: *Cx, _: bool) anyerror!*Node {
            Seen.builds += 1;
            return testLeaf(c);
        }
    }.build);
    try std.testing.expectEqual(@as(u32, 1), Seen.builds);
    n.set(5); // odd/even unchanged: memo equal, no rebuild.
    try std.testing.expectEqual(@as(u32, 1), Seen.builds);
    n.set(6);
    try std.testing.expectEqual(@as(u32, 2), Seen.builds);

    // For driven by memo (filtered list).
    const all = [_]u32{ 1, 2, 3, 4 };
    const only_even = try root_scope.createSignal(bool, false);
    const visible_items = try root_scope.createMemo([]const u32, .{ .only_even = only_even }, struct {
        fn f(c: anytype) []const u32 {
            return if (c.only_even.get()) all[1..2] else all[0..];
        }
    }.f);
    const list = try Node.create(allocator, ctx.nextId(), .box, .{});
    ctx.linkNodeToWorld(list);
    try parent.appendChild(allocator, list);
    try For(u32, root_scope, list, visible_items, ctx, .{
        .key_fn = struct {
            fn k(v: u32) u64 {
                return v;
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, _: u32, _: usize) anyerror!*Node {
                return testLeaf(c);
            }
        }.r,
    });
    try std.testing.expectEqual(@as(usize, 4), contentCount(list));
    only_even.set(true);
    try std.testing.expectEqual(@as(usize, 1), contentCount(list));
}

test "control flow builds children untracked: reads during mount do not subscribe the control-flow effect" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } });
    ctx.root = parent;
    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const Env = struct {
        var unrelated: *Signal(u32) = undefined;
        var builds: u32 = 0;
    };
    Env.unrelated = try root_scope.createSignal(u32, 0);
    Env.builds = 0;
    const which = try root_scope.createSignal(u8, 1);
    _ = try Match(u8, root_scope, parent, which, ctx, struct {
        fn build(_: *Scope, c: *Cx, _: u8) anyerror!*Node {
            Env.builds += 1;
            _ = Env.unrelated.get(); // mount-time read.
            return testLeaf(c);
        }
    }.build);
    try std.testing.expectEqual(@as(u32, 1), Env.builds);
    Env.unrelated.set(1); // shouldn't trigger Match rebuild.
    try std.testing.expectEqual(@as(u32, 1), Env.builds);
    which.set(2); // effect rebuilds: read inside build if tracked, unrelated gains observer.
    try std.testing.expectEqual(@as(u32, 2), Env.builds);
    const gid: @import("reactive/graph.zig").NodeId = @bitCast(Env.unrelated.base.graph_node_raw);
    try std.testing.expectEqual(@as(usize, 0), ctx.owner.graph.getNode(gid).?.observers.items.len);
}

// ----- region positioning: content fixed at call site -----
//
// Show/Match content built with plain appendChild lands after all siblings once the condition
// turns true; For locating by 'non-For sibling count before it' drifts when an upstream Show
// opens/closes. Instead each region has an anchor pair and content inserts at its own end anchor.
fn testTagged(c: *Cx, name: []const u8) !*Node {
    const n = try testLeaf(c);
    n.meta.ownership.meta.component_name = name;
    return n;
}

fn expectContentNames(parent: *Node, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, contentCount(parent));
    for (want, 0..) |w, i| {
        try std.testing.expectEqualStrings(w, contentAt(parent, i).meta.ownership.meta.component_name.?);
    }
}

test "Show / Match / For: 后开合的区域与后追加的兄弟都不让内容漂移" {
    const Item = struct { name: []const u8 };
    const Page = enum { a, b };
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const parent = try Node.create(allocator, ctx.nextId(), .box, .{ .width = .{ .px = 100 }, .height = .{ .px = 300 } });
    ctx.linkNodeToWorld(parent);
    ctx.root = parent;
    const root_scope = try Scope.init(allocator, null, ctx.owner);
    defer root_scope.dispose();

    const show = try root_scope.createSignal(bool, false);
    const page = try root_scope.createSignal(Page, .a);
    const one = [_]Item{.{ .name = "i1" }};
    const two = [_]Item{ .{ .name = "i1" }, .{ .name = "i2" } };
    const items = try root_scope.createSignal([]const Item, &one);

    try parent.appendChild(allocator, try testTagged(ctx, "head"));
    try Show(root_scope, parent, show, ctx, struct {
        fn b(_: *Scope, c: *Cx) anyerror!*Node {
            return testTagged(c, "show");
        }
    }.b);
    _ = try Match(Page, root_scope, parent, page, ctx, struct {
        fn b(_: *Scope, c: *Cx, p: Page) anyerror!*Node {
            return testTagged(c, @tagName(p));
        }
    }.b);
    try For(Item, root_scope, parent, items, ctx, .{
        .key_fn = struct {
            fn k(it: Item) u64 {
                return std.hash.Wyhash.hash(0, it.name);
            }
        }.k,
        .render_fn = struct {
            fn r(_: *Scope, c: *Cx, it: Item, _: usize) anyerror!*Node {
                return testTagged(c, it.name);
            }
        }.r,
    });
    try parent.appendChild(allocator, try testTagged(ctx, "tail"));
    try expectContentNames(parent, &.{ "head", "a", "i1", "tail" });

    show.set(true);
    try expectContentNames(parent, &.{ "head", "show", "a", "i1", "tail" });
    items.set(&two);
    try expectContentNames(parent, &.{ "head", "show", "a", "i1", "i2", "tail" });
    page.set(.b);
    try expectContentNames(parent, &.{ "head", "show", "b", "i1", "i2", "tail" });
    show.set(false);
    try expectContentNames(parent, &.{ "head", "b", "i1", "i2", "tail" });
    items.set(&one);
    show.set(true);
    try expectContentNames(parent, &.{ "head", "show", "b", "i1", "tail" });

    // World table sibling chain matches Node.children (insertChildBefore linked path).
    const ElementId = @import("core/element_id.zig").ElementId;
    var iter = ctx.world.elements.children(ElementId.fromRaw(parent.element_id_raw));
    var k: usize = 0;
    while (iter.next()) |eid| : (k += 1) {
        try std.testing.expectEqual(parent.children.items[k].element_id_raw, eid.raw());
    }
    try std.testing.expectEqual(parent.children.items.len, k);
}

test "Node.insertChildBefore: 锚点不是该父节点的子节点时报错且不挂树" {
    const allocator = std.testing.allocator;
    const ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const parent = try testLeaf(ctx);
    defer ctx.freeNode(parent);
    const other = try testLeaf(ctx);
    defer ctx.freeNode(other);
    const stranger = try testLeaf(ctx);
    try other.appendChild(allocator, stranger);
    const child = try testLeaf(ctx);
    defer ctx.freeNode(child);

    try std.testing.expectError(error.InvalidAnchor, parent.insertChildBefore(allocator, child, stranger));
    try std.testing.expect(child.parent == null);
    try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
}
