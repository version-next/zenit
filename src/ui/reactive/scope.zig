const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const EffectBase = @import("effect_base.zig").EffectBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Signal = @import("signal.zig").Signal;
const effect_mod = @import("effect.zig");
const Memo = @import("memo.zig").Memo;
const memo_mod = @import("memo.zig");

/// Scope: lifecycle container for reactive resources.
///
/// Retained mode: each component creates one Scope on mount; dispose recursively cleans it.
/// Design points:
/// - no Arena; resources allocated individually (must support independent destruction)
/// - SignalOwner stays the shared tracking context (current_effect, is_tracking, batch_ctx)
/// - dispose() order: child Scopes -> cleanups -> Effects unsubscribed -> free memory
const context_mod = @import("context.zig");

pub const ALIVE_SENTINEL: u32 = 0x5C0E_A11E;
pub const DEAD_SENTINEL: u32 = 0x5C0E_DEAD;

pub const Scope = struct {
    /// Only the template oracle uses this provenance. Ordinary scopes are never
    /// inferred to be transparent from their shape or their resource counts.
    pub const TestPreviewBoundary = enum { none, region_view, slot_setup };
    test_preview_boundary: if (@import("builtin").is_test) TestPreviewBoundary else void = if (@import("builtin").is_test) .none else {},
    allocator: Allocator,
    parent: ?*Scope,
    children: std.ArrayList(*Scope),
    signals: std.ArrayList(*SignalBase),
    effects: std.ArrayList(*EffectBase),
    // Append-only while alive; synchronous component rebuild tickets may remove
    // their own tail-era entry after callbacks settle. No compaction/reordering
    // or removal by other code is allowed before disposal consumes the list.
    cleanups: std.ArrayList(CleanupEntry),
    resources: std.ArrayList(ResourceEntry),
    owner: *SignalOwner,
    disposed: bool = false,
    dispose_pending: bool = false,
    /// alive sentinel, semantics match Node.alive_sentinel:
    /// disposeNow end calls allocator.destroy(self), double dispose reads `disposed`
    /// may be 0xaa overwrite value (non-zero => true), double dispose degrades to silent
    /// early-return.
    alive_sentinel: u32 = ALIVE_SENTINEL,
    deferred_disposal: SignalOwner.DeferredDisposal = .{},

    /// Context API: zero-allocation slot array (up to 8 context per scope)
    context_entries: [context_mod.max_context_slots]context_mod.ContextSlot = @as([context_mod.max_context_slots]context_mod.ContextSlot, @splat(.{})),
    context_count: u5 = 0,

    pub const CleanupFn = *const fn (*anyopaque) void;

    pub const CleanupEntry = struct {
        func: CleanupFn,
        ctx: *anyopaque,
    };

    /// generic resource entry: freed by destroyFn on dispose
    pub const ResourceDestroyFn = *const fn (*anyopaque, Allocator) void;
    pub const ResourceEntry = struct {
        ptr: *anyopaque,
        destroyFn: ResourceDestroyFn,
        // Complete memo ownership provenance for the test graph oracle, erased
        // from non-test layouts; no UI/template dependency in reactive modules.
        test_graph_node_raw: if (@import("builtin").is_test) ?u32 else void = if (@import("builtin").is_test) null else {},
    };

    /// create Scope
    pub fn init(allocator: Allocator, parent: ?*Scope, owner: *SignalOwner) !*Scope {
        const scope = try allocator.create(Scope);
        // Scope uses caller's allocator (not owner arena), parent registration failure is a true
        // leak
        // (measured 416B per occurrence)
        errdefer allocator.destroy(scope);
        scope.* = .{
            .allocator = allocator,
            .parent = parent,
            .children = .empty,
            .signals = .empty,
            .effects = .empty,
            .cleanups = .empty,
            .resources = .empty,
            .owner = owner,
        };

        // register to parent Scope
        if (parent) |p| {
            try p.children.append(allocator, scope);
        }

        return scope;
    }

    /// Recursively destroy the Scope and all its resources.
    ///
    /// Order:
    /// 1. recursively destroy child Scopes
    /// 2. run cleanup callbacks (reverse order)
    /// 3. clean Effects (remove from Signal subscribers + free)
    /// 4. clean Signals (free subscribers list + free)
    /// 5. free self
    pub fn dispose(self: *Scope) void {
        if (self.disposed) return;
        if (self.owner.reactive_callback_depth > 0) {
            if (self.dispose_pending) return;
            self.queueDeferredDispose();
            return;
        }
        self.disposeNow();
    }

    fn queueDeferredDispose(self: *Scope) void {
        // A queued ancestor already owns this subtree. Otherwise preserve
        // FIFO order; disposeNow cancels descendant entries before freeing.
        var parent = self.parent;
        while (parent) |scope| : (parent = scope.parent) {
            if (scope.disposed or scope.dispose_pending) return;
        }
        self.dispose_pending = true;
        self.owner.deferDisposal(&self.deferred_disposal, @ptrCast(self), &finishDeferredDispose);
    }

    fn finishDeferredDispose(ptr: *anyopaque) void {
        const scope: *Scope = @ptrCast(@alignCast(ptr));
        scope.disposeNow();
    }

    pub fn willBeDisposedAfterReactiveCallback(self: *Scope) bool {
        var current: ?*Scope = self;
        while (current) |scope| : (current = scope.parent) {
            if (scope.disposed or scope.dispose_pending) return true;
        }
        return false;
    }

    fn disposeNow(self: *Scope) void {
        // Alive sentinel: the check must dominate all other field accesses on the same pointer.
        // Done in disposeNow, not dispose, because disposeNow is the common entry for both paths
        // (sync / deferred) and calls allocator.destroy(self) at the end. Without the check, a
        // double entry reads `disposed`, which may be a 0xaa overwrite (non-zero => true); with it,
        // double dispose degrades to a silent early return, same as Node.
        if (self.alive_sentinel != ALIVE_SENTINEL) {
            @panic("Scope.disposeNow: scope 已被释放（double dispose）或内存已损坏");
        }
        if (self.disposed) return;
        const lifetime_owner = self.owner;
        lifetime_owner.scope_disposal_depth += 1;
        defer lifetime_owner.scope_disposal_depth -= 1;
        self.disposed = true;
        self.dispose_pending = false;
        self.deferred_disposal.cancel();
        // Detach before callbacks: a child cleanup can dispose its former
        // parent, so no later cleanup may dereference that parent pointer.
        if (self.parent) |parent| {
            for (parent.children.items, 0..) |child, index| {
                if (child == self) {
                    _ = parent.children.orderedRemove(index);
                    break;
                }
            }
            self.parent = null;
        }

        // 1. Destroy children in creation order. Each child detaches first;
        // its cleanup may also dispose a sibling, so reread the live list.
        while (self.children.items.len != 0) {
            self.children.items[0].disposeNow();
        }
        self.children.deinit(self.allocator);

        // 2. run cleanup callbacks (reverse order)
        var i = self.cleanups.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.cleanups.items[i];
            entry.func(entry.ctx);
        }
        self.cleanups.deinit(self.allocator);

        // 3. clean Effects: unregister graph node (auto-disconnect source/observer edges) + free;
        // single cleanup path, graph.destroyNode handles all cleanup;
        // no longer traverse effect.dependencies / signal.subscribers lists.
        for (self.effects.items) |effect| {
            if (effect.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(effect.graph_node_raw);
                self.owner.graph.destroyNode(gid);
                effect.graph_node_raw = 0xFFFFFFFF;
            }
            effect.destroy(self.allocator);
        }
        self.effects.deinit(self.allocator);

        // 4. clean Signals: same single path via graph
        for (self.signals.items) |signal| {
            if (signal.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(signal.graph_node_raw);
                self.owner.graph.destroyNode(gid);
                signal.graph_node_raw = 0xFFFFFFFF;
            }
            signal.destroy(self.allocator);
        }
        self.signals.deinit(self.allocator);

        // 5. free generic resources (reverse order),
        // consistent with cleanup, avoid early resource freeing node/context
        // that later-registered resources depend on reading dangling pointers during dispose.
        i = self.resources.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.resources.items[i];
            entry.destroyFn(entry.ptr, self.allocator);
        }
        self.resources.deinit(self.allocator);

        // 7. free self;
        // poisoned: using as live scope after free causes panic at dispose entry sentinel.
        self.alive_sentinel = DEAD_SENTINEL;
        self.allocator.destroy(self);
    }

    /// create child Scope
    pub fn childScope(self: *Scope) !*Scope {
        return Scope.init(self.allocator, self, self.owner);
    }

    /// Framework safe-point teardown of an owned child. The surrounding callback
    /// guard pins the owner while child cleanups run; requests to destroy the
    /// owner are deferred until the caller has stopped using it. Unlike dispose,
    /// this retires the child before a replacement view starts binding refs.
    pub fn disposeChildAtSafePoint(self: *Scope, child: *Scope) void {
        std.debug.assert(child.parent == self);
        std.debug.assert(self.owner.reactive_callback_depth > 0);
        std.debug.assert(!self.owner.inReactiveComputation());
        child.disposeNow();
    }

    /// create Signal in this Scope
    pub fn createSignal(self: *Scope, comptime T: type, initial: T) !*Signal(T) {
        const signal = try Signal(T).createInScope(self, initial);
        return signal;
    }

    pub const TextOptions = struct {
        /// initial buffer capacity; doubled when insufficient.
        capacity: usize = 0,
    };

    /// allocate state released with this scope (address stable `*T`), shared by multiple event
    /// handlers
    /// (`ui.on.call(state, T.method)`). differs from `cx.bindState`: latter lives until Cx
    /// destroyed,
    /// repeated component/page mounts accumulate; here reclaimed with mounting scope. does not call
    /// `T.deinit`,
    /// call `onCleanup` if needed.
    pub fn createState(self: *Scope, comptime T: type, initial: T) !*T {
        const p = try self.allocator.create(T);
        p.* = initial;
        try self.adoptResource(@ptrCast(p), struct {
            fn destroy(raw: *anyopaque, allocator: Allocator) void {
                allocator.destroy(@as(*T, @ptrCast(@alignCast(raw))));
            }
        }.destroy);
        return p;
    }

    /// owning-type text signal (docs/SIGNAL_API_DESIGN.md §4.8): `set` copies content into signal's
    /// own buffer (double-buffered + doubled), allocation failure leaves value unchanged. `get`
    /// slice valid only
    /// within current sync call and while signal not written again (see `Signal.get`), use `dupe` /
    /// `getInto` to hold across calls. text input components' `value` requires this.
    pub fn createText(self: *Scope, initial: []const u8, opts: TextOptions) !*Signal([]const u8) {
        return self.createOwnedSlice(u8, initial, opts.capacity);
    }

    /// Owning list signal `Signal([]const E)`: `set` copies elements into the signal's
    /// double-buffer,
    /// so the caller may pass a temporary buffer (row keys, expanded node ids, file paths).
    /// `E == []const u8` also copies string bytes; other elements are shallow-copied, so borrowed
    /// fields inside them stay the caller's and must remain valid while current.
    /// As with `createText`, a read slice is valid only in the current sync call and until the next
    /// write.
    pub fn createList(self: *Scope, comptime E: type, initial: []const E) !*Signal([]const E) {
        return self.createOwnedSlice(E, initial, 0);
    }

    /// select signal storage by value type (Yix's `var x: T = signal(v)` uses): `[]const u8`
    /// creates owning-type text (same createText),
    /// other `[]const E` creates owning-type list (same createList), other types same createSignal.
    /// selects by type itself, aliases work same.
    pub fn createSignalFor(self: *Scope, comptime T: type, initial: T) !*Signal(T) {
        comptime rejectMutableSlice(T);
        if (T == []const u8) return self.createText(initial, .{});
        if (comptime constSliceChild(T)) |E| return self.createList(E, initial);
        return self.createSignal(T, initial);
    }

    fn createOwnedSlice(self: *Scope, comptime E: type, initial: []const E, capacity: usize) !*Signal([]const E) {
        const Store = @import("signal.zig").SliceStore(E);
        const ts = try self.allocator.create(Store);
        errdefer self.allocator.destroy(ts);
        ts.* = .{ .allocator = self.allocator };
        const cap = @max(initial.len, capacity);
        if (cap > 0) ts.bufs[0] = try self.allocator.alloc(E, cap);
        errdefer ts.deinit();
        if (!ts.fill(0, initial)) return error.OutOfMemory;
        const signal = try Signal([]const E).createInScope(self, ts.current(initial.len));
        signal.slice_store = ts;
        return signal;
    }

    /// explicit dependency watch: calls `f` with `(ctx, new, old)` when `src` changes (values not
    /// equal), function body not tracked.
    /// not called at creation (matches Vue `watch`). `src` accepts `*Signal` / `*Memo` / derived /
    /// `Source`.
    /// `old` of owning-type text valid only in this call and when single write between two
    /// triggers.
    pub fn watch(self: *Scope, src: anytype, ctx: anytype, comptime f: anytype) !void {
        const source_mod = @import("source.zig");
        const S = @TypeOf(source_mod.toSource(src));
        const T = S.Value;
        const Ctx = @TypeOf(ctx);
        // text source: `old` saved as watch's own copy. owning-type text is double-buffered, two
        // writes
        // (or resize) in one batch overwrites/frees previous buffer, direct slice save becomes
        // dangling.
        const is_text = T == []const u8;
        const Buf = std.ArrayListUnmanaged(u8);
        const State = struct {
            src: S,
            ctx: Ctx,
            allocator: Allocator,
            old: if (is_text) Buf else T = if (is_text) .empty else undefined,
            next: if (is_text) Buf else void = if (is_text) .empty else {},
            primed: bool = false,

            const Self = @This();

            fn oldValue(st: *const Self) T {
                return if (is_text) st.old.items else st.old;
            }

            fn run(st: *Self) void {
                const v = st.src.get();
                if (!st.primed) {
                    if (is_text) {
                        st.old.clearRetainingCapacity();
                        st.old.appendSlice(st.allocator, v) catch return; // left unprimed; retry next time
                    } else st.old = v;
                    st.primed = true;
                    return;
                }
                if (@import("eq.zig").eqlValue(T, st.oldValue(), v)) return;
                if (is_text) {
                    st.next.clearRetainingCapacity();
                    st.next.appendSlice(st.allocator, v) catch {
                        // could not copy new value: notify normally, but `old` next time not
                        // reliable, reprime.
                        std.log.warn("[reactive.watch] could not copy the new text value; old will be re-primed", .{});
                        st.primed = false;
                        callUntracked(st, v, st.old.items);
                        return;
                    };
                    callUntracked(st, v, st.old.items);
                    std.mem.swap(Buf, &st.old, &st.next);
                } else {
                    const old = st.old;
                    st.old = v;
                    callUntracked(st, v, old);
                }
            }

            fn callUntracked(st: *Self, v: T, old: T) void {
                ownerOf(st.src).untrack(struct {
                    fn call(args: struct { *Self, T, T }) void {
                        f(args[0].ctx, args[1], args[2]);
                    }
                }.call, .{ st, v, old });
            }

            fn destroy(ptr: *anyopaque, allocator: Allocator) void {
                const st: *Self = @ptrCast(@alignCast(ptr));
                if (is_text) {
                    st.old.deinit(allocator);
                    st.next.deinit(allocator);
                }
                allocator.destroy(st);
            }
        };
        source_mod.checkBorrow(self, src);
        const st = try self.allocator.create(State);
        st.* = .{ .src = source_mod.toSource(src), .ctx = ctx, .allocator = self.allocator };
        try self.adoptResource(st, State.destroy);
        try self.createEffect(st, State.run);
    }

    /// writable derived (matches Angular `linkedSignal`): returns local writable signal, initial
    /// value from `src`;
    /// when `src` changes resets to `reset(new_src, current)` (`reset == null` takes `new_src`
    /// directly).
    /// use instead of "write signal in effect to sync state".
    pub fn linked(self: *Scope, comptime T: type, src: anytype, comptime reset: ?fn (T, T) T) !*Signal(T) {
        const source_mod = @import("source.zig");
        const S = @TypeOf(source_mod.toSource(src));
        if (S.Value != T) @compileError("scope.linked: source value type is " ++ @typeName(S.Value) ++ ", expected " ++ @typeName(T));
        source_mod.checkBorrow(self, src);
        // text: local value must be owning-type, else initial value directly borrows source
        // signal's buffer (source resize becomes dangling).
        const sig = if (T == []const u8)
            try self.createText(source_mod.toSource(src).peek(), .{})
        else
            try self.createSignal(T, source_mod.toSource(src).peek());
        const State = struct {
            src: S,
            sig: *Signal(T),
            primed: bool = false,

            fn run(st: *@This()) void {
                const v = st.src.get();
                if (!st.primed) {
                    st.primed = true;
                    return;
                }
                const next = if (reset) |r| r(v, st.sig.peek()) else v;
                st.sig.set(next);
            }

            fn destroy(ptr: *anyopaque, allocator: Allocator) void {
                allocator.destroy(@as(*@This(), @ptrCast(@alignCast(ptr))));
            }
        };
        const st = try self.allocator.create(State);
        st.* = .{ .src = source_mod.toSource(src), .sig = sig };
        try self.adoptResource(st, State.destroy);
        try self.createEffect(st, State.run);
        return sig;
    }

    fn ownerOf(src: anytype) *SignalOwner {
        return switch (src) {
            .value => unreachable,
            .signal => |s| s.owner,
            .memo => |m| m.owner,
            .derived => |d| d.owner,
        };
    }

    /// create Effect in this Scope
    pub fn createEffect(
        self: *Scope,
        context: anytype,
        comptime effectFn: anytype,
    ) !void {
        const Context = @TypeOf(context);
        const EffectType = effect_mod.Effect(Context, effectFn);
        _ = try EffectType.createInScope(self, context);
    }

    /// create Memo in this Scope
    pub fn createMemo(
        self: *Scope,
        comptime T: type,
        context: anytype,
        comptime computeFn: anytype,
    ) !*Memo(T) {
        return memo_mod.createMemoInScope(self, T, context, computeFn);
    }

    /// derived value, static hoisting at runtime: create memo compute once, if no dependencies
    /// recorded shrinks to static value (not in dependency graph), else keeps memo.
    /// Yix's computed / property expressions generated by it, see `memo.deriveInScope`.
    pub fn derive(
        self: *Scope,
        comptime T: type,
        context: anytype,
        comptime computeFn: anytype,
    ) !@import("source.zig").Source(T) {
        return switch (try memo_mod.deriveInScope(self, T, context, computeFn)) {
            .value => |v| @import("source.zig").Source(T).of(v),
            .memo => |m| .{ .memo = m },
        };
    }

    /// register cleanup callback (runs on Scope dispose)
    pub fn onCleanup(self: *Scope, comptime T: type, ctx: *T, comptime cleanupFn: fn (*T) void) !void {
        const wrapper = struct {
            fn invoke(ptr: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                cleanupFn(typed);
            }
        };
        try self.cleanups.append(self.allocator, .{
            .func = wrapper.invoke,
            .ctx = @ptrCast(ctx),
        });
    }

    /// register Signal to this Scope
    pub fn registerSignal(self: *Scope, signal: *SignalBase) !void {
        try self.signals.append(self.allocator, signal);
    }

    /// register Effect to this Scope
    pub fn registerEffect(self: *Scope, effect: *EffectBase) !void {
        try self.effects.append(self.allocator, effect);
    }

    /// Register a generic resource (freed by destroyFn(ptr, allocator) on dispose).
    ///
    /// WARNING: registration can fail (resources resize); ptr stays the caller's, so the usual
    /// "create -> init -> registerResource" leaks on failure. Use adoptResource unless you add
    /// your own errdefer.
    pub fn registerResource(self: *Scope, ptr: *anyopaque, destroyFn: ResourceDestroyFn) !void {
        try self.resources.append(self.allocator, .{ .ptr = ptr, .destroyFn = destroyFn });
    }

    /// register resource, **free it immediately with same destroyFn if registration fails**, then
    /// throw error back.
    /// semantics: call succeeds => resource owned by scope; call fails => resource already freed,
    /// caller must not touch ptr.
    /// precondition: at call time ptr points to object initialized to safe degree for destroyFn
    /// (destroyFn will read its fields to free), do not register before `state.* = .{…}`.
    pub fn adoptResource(self: *Scope, ptr: *anyopaque, destroyFn: ResourceDestroyFn) !void {
        self.resources.append(self.allocator, .{ .ptr = ptr, .destroyFn = destroyFn }) catch |err| {
            destroyFn(ptr, self.allocator);
            return err;
        };
    }

    /// register a context value in current scope
    pub fn setContext(self: *Scope, type_id: usize, ptr: *anyopaque) !void {
        // search for existing slot
        for (self.context_entries[0..self.context_count]) |*slot| {
            if (slot.type_id == type_id) {
                slot.ptr = ptr;
                return;
            }
        }
        // allocate new slot
        if (self.context_count < context_mod.max_context_slots) {
            self.context_entries[self.context_count] = .{ .type_id = type_id, .ptr = ptr };
            self.context_count += 1;
            return;
        } else {
            return error.ContextsFull;
        }
    }

    /// find context value walking up parent chain
    pub fn getContext(self: *Scope, type_id: usize) ?*anyopaque {
        // search self first
        for (self.context_entries[0..self.context_count]) |slot| {
            if (slot.type_id == type_id) return slot.ptr;
        }
        // recurse parent scope
        if (self.parent) |p| {
            return p.getContext(type_id);
        }
        return null;
    }
};

// ===== tests =====

test "Scope: init/dispose" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    scope.dispose();
}

test "Scope: reactive callbacks defer disposal until their facade returns" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    // Initial effect execution may dispose its own scope. Creation reports the
    // disposal instead of returning a dangling Effect pointer.
    const initial_scope = try Scope.init(allocator, null, owner);
    try std.testing.expectError(error.ScopeDisposed, initial_scope.createEffect(.{ .scope = initial_scope }, struct {
        fn run(ctx: anytype) void {
            ctx.scope.dispose();
        }
    }.run));

    // The same operation during a later signal-driven run must let the effect
    // and graph unwind before freeing the effect, signal, and scope.
    const effect_scope = try Scope.init(allocator, null, owner);
    const signal = try effect_scope.createSignal(u32, 0);
    var dispose_on_run = false;
    var runs: usize = 0;
    try effect_scope.createEffect(.{
        .scope = effect_scope,
        .signal = signal,
        .dispose_on_run = &dispose_on_run,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.signal.get();
            ctx.runs.* += 1;
            if (ctx.dispose_on_run.*) ctx.scope.dispose();
        }
    }.run);
    dispose_on_run = true;
    signal.set(1);
    try std.testing.expectEqual(@as(usize, 2), runs);

    // Memo.get still needs to copy the computed cache after graph recompute;
    // disposal therefore waits until the complete get() facade exits.
    const memo_scope = try Scope.init(allocator, null, owner);
    const memo = try memo_scope.createMemo(u32, .{ .scope = memo_scope }, struct {
        fn compute(ctx: anytype) u32 {
            ctx.scope.dispose();
            return 42;
        }
    }.compute);
    try std.testing.expectEqual(@as(u32, 42), memo.get());
}

const SettledProbe = struct {
    owner: *SignalOwner,
    entry: SignalOwner.SettledTask = .{},
    runs: usize = 0,
    ran_inside_computation: bool = false,

    fn request(self: *SettledProbe) void {
        self.owner.runOutsideComputation(&self.entry, @ptrCast(self), run);
    }

    fn run(ptr: *anyopaque) void {
        const self: *SettledProbe = @ptrCast(@alignCast(ptr));
        self.runs += 1;
        if (self.owner.inReactiveComputation()) self.ran_inside_computation = true;
    }
};

test "SignalOwner.runOutsideComputation: 计算内的请求在写入的 effect drain 结束后运行，计算外立即运行" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();
    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    var probe = SettledProbe{ .owner = owner };
    probe.request(); // no computation on the stack: runs now
    try std.testing.expectEqual(@as(usize, 1), probe.runs);

    const trigger = try scope.createSignal(u32, 0);
    const chained = try scope.createSignal(u32, 0);
    var seen_in_effect: usize = 0;
    // first effect requests twice (coalesced) and writes a signal that runs a second effect
    try scope.createEffect(.{ .trigger = trigger, .chained = chained, .probe = &probe }, struct {
        fn run(c: anytype) void {
            const v = c.trigger.get();
            if (v == 0) return;
            c.probe.request();
            c.probe.request();
            c.chained.set(v);
        }
    }.run);
    // second effect checks the task has not run while effects are still draining
    try scope.createEffect(.{ .chained = chained, .probe = &probe, .seen = &seen_in_effect }, struct {
        fn run(c: anytype) void {
            if (c.chained.get() != 0) c.seen.* = c.probe.runs;
        }
    }.run);

    trigger.set(1);
    try std.testing.expectEqual(@as(usize, 1), seen_in_effect);
    try std.testing.expectEqual(@as(usize, 2), probe.runs);
    try std.testing.expect(!probe.ran_inside_computation);

    // batch: effects drain at endBatch, the task right after
    owner.beginBatch();
    trigger.set(2);
    try std.testing.expectEqual(@as(usize, 2), probe.runs);
    owner.endBatch();
    try std.testing.expectEqual(@as(usize, 3), probe.runs);
    try std.testing.expect(!probe.ran_inside_computation);
}

test "SignalOwner.runOutsideComputation: effect 首跑与 untrack 内的请求；取消后不运行" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();
    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    var probe = SettledProbe{ .owner = owner };
    // initial run of a new effect: settles when createEffect returns; untrack does not hide the
    // computation below its sentinel
    try scope.createEffect(&probe, struct {
        fn run(p: *SettledProbe) void {
            p.owner.untrack(SettledProbe.request, p);
            if (p.runs != 0) p.ran_inside_computation = true;
        }
    }.run);
    try std.testing.expectEqual(@as(usize, 1), probe.runs);
    try std.testing.expect(!probe.ran_inside_computation);

    // a cancelled request (its owner went away) never runs
    var gone = SettledProbe{ .owner = owner };
    const trigger = try scope.createSignal(u32, 0);
    try scope.createEffect(.{ .trigger = trigger, .gone = &gone }, struct {
        fn run(c: anytype) void {
            if (c.trigger.get() == 0) return;
            c.gone.request();
            c.gone.entry.cancel();
        }
    }.run);
    trigger.set(1);
    try std.testing.expectEqual(@as(usize, 0), gone.runs);
    try std.testing.expect(owner.settled_tasks.head == null);
}

test "Scope: nested scopes dispose correctly" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const parent_scope = try Scope.init(allocator, null, owner);
    _ = try parent_scope.childScope();
    _ = try parent_scope.childScope();

    // destroying parent Scope should recursively destroy child Scopes
    parent_scope.dispose();
}

test "Scope: createSignal" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const count = try scope.createSignal(i32, 42);
    try std.testing.expectEqual(@as(i32, 42), count.get());

    count.set(100);
    try std.testing.expectEqual(@as(i32, 100), count.get());
}

test "Scope: createEffect with auto-tracking" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);
    defer scope.dispose();

    const count = try scope.createSignal(i32, 0);
    var effect_run_count: i32 = 0;

    try scope.createEffect(.{
        .count = count,
        .counter = &effect_run_count,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.counter.* += 1;
        }
    }.run);

    // Effect executes once on creation
    try std.testing.expectEqual(@as(i32, 1), effect_run_count);

    // Signal change triggers Effect
    count.set(1);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count);

    count.set(2);
    try std.testing.expectEqual(@as(i32, 3), effect_run_count);
}

test "Scope: dispose stops effects" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    // create Signal on owner's Arena (survives across Scopes)
    const count = try Signal(i32).create(owner, 0);

    var effect_run_count: i32 = 0;

    {
        const scope = try Scope.init(allocator, null, owner);

        try scope.createEffect(.{
            .count = count,
            .counter = &effect_run_count,
        }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.count.get();
                ctx.counter.* += 1;
            }
        }.run);

        try std.testing.expectEqual(@as(i32, 1), effect_run_count);

        count.set(1);
        try std.testing.expectEqual(@as(i32, 2), effect_run_count);

        // Scope destruction -> Effect cleanup
        scope.dispose();
    }

    // after Scope destroyed, Signal change no longer triggers Effect
    count.set(2);
    try std.testing.expectEqual(@as(i32, 2), effect_run_count);
}

test "Scope: disposing one sibling scope keeps the other active" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    const scope_a = try Scope.init(allocator, null, owner);
    const scope_b = try Scope.init(allocator, null, owner);
    defer scope_b.dispose();

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;

    try scope_a.createEffect(.{
        .count = count,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try scope_b.createEffect(.{
        .count = count,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);

    count.set(1);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);

    // destroying only scope_a should not affect scope_b
    scope_a.dispose();

    count.set(2);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 3), b_runs);
}

test "Scope: disposed sibling is not queued during owner batch" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);
    const scope_a = try Scope.init(allocator, null, owner);
    const scope_b = try Scope.init(allocator, null, owner);
    defer scope_b.dispose();

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;

    try scope_a.createEffect(.{
        .count = count,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try scope_b.createEffect(.{
        .count = count,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.count.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);

    scope_a.dispose();

    // two sets in batch: scope_b's effect should queue and run once only, scope_a not queued by
    // mistake
    try owner.batch(struct {
        fn update(ctx: anytype) void {
            ctx.count.set(1);
            ctx.count.set(2);
        }
    }.update, .{ .count = count });

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
}

test "Scope: dispose after batch+untrack+nested chain stops all effects" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const trigger = try Signal(bool).create(owner, false);
    const source = try Signal(i32).create(owner, 0);
    const mirror = try Signal(i32).create(owner, 0);

    var a_runs: i32 = 0;
    var b_runs: i32 = 0;
    var c_runs: i32 = 0;
    var leaf_value: i32 = -1;

    const scope = try Scope.init(allocator, null, owner);

    // B: source -> mirror
    try scope.createEffect(.{
        .source = source,
        .mirror = mirror,
        .runs = &b_runs,
    }, struct {
        fn run(ctx: anytype) void {
            const s = ctx.source.get();
            ctx.runs.* += 1;
            ctx.mirror.set(s * 2);
        }
    }.run);

    // C: mirror -> leaf
    try scope.createEffect(.{
        .mirror = mirror,
        .runs = &c_runs,
        .leaf = &leaf_value,
    }, struct {
        fn run(ctx: anytype) void {
            ctx.runs.* += 1;
            ctx.leaf.* = ctx.mirror.get();
        }
    }.run);

    // A: when trigger true, batch update source in untrack
    try scope.createEffect(.{
        .owner = owner,
        .trigger = trigger,
        .source = source,
        .runs = &a_runs,
    }, struct {
        fn run(ctx: anytype) void {
            const enabled = ctx.trigger.get();
            ctx.runs.* += 1;
            if (!enabled) return;

            _ = ctx.owner.untrack(struct {
                fn op(args: anytype) void {
                    args.owner.batch(struct {
                        fn update(inner: anytype) void {
                            inner.source.set(1);
                            inner.source.set(2);
                        }
                    }.update, .{ .source = args.source }) catch unreachable;
                }
            }.op, .{
                .owner = ctx.owner,
                .source = ctx.source,
            });
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), a_runs);
    try std.testing.expectEqual(@as(i32, 1), b_runs);
    try std.testing.expectEqual(@as(i32, 1), c_runs);
    try std.testing.expectEqual(@as(i32, 0), leaf_value);

    trigger.set(true);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);

    // after dispose, all three effects should not be triggered by source/mirror/trigger changes
    scope.dispose();

    source.set(3);
    mirror.set(7);
    trigger.set(false);
    try std.testing.expectEqual(@as(i32, 2), a_runs);
    try std.testing.expectEqual(@as(i32, 2), b_runs);
    try std.testing.expectEqual(@as(i32, 2), c_runs);
    try std.testing.expectEqual(@as(i32, 4), leaf_value);
}

test "Scope: cleanup callbacks" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    var cleanup_count: i32 = 0;

    const scope = try Scope.init(allocator, null, owner);

    try scope.onCleanup(i32, &cleanup_count, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    try std.testing.expectEqual(@as(i32, 0), cleanup_count);

    scope.dispose();

    try std.testing.expectEqual(@as(i32, 1), cleanup_count);
}

test "Scope: child scope disposed with parent" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    var parent_cleanup: i32 = 0;
    var child_cleanup: i32 = 0;

    const parent_scope = try Scope.init(allocator, null, owner);
    const child_scope = try parent_scope.childScope();

    try parent_scope.onCleanup(i32, &parent_cleanup, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    try child_scope.onCleanup(i32, &child_cleanup, struct {
        fn cleanup(ptr: *i32) void {
            ptr.* += 1;
        }
    }.cleanup);

    // destroy parent Scope
    parent_scope.dispose();

    // both cleanups should execute
    try std.testing.expectEqual(@as(i32, 1), parent_cleanup);
    try std.testing.expectEqual(@as(i32, 1), child_cleanup);
}

test "Scope: resources dispose in reverse registration order" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const scope = try Scope.init(allocator, null, owner);

    const Marker = struct {
        freed: bool = false,
        order: [2]u8 = undefined,
        len: usize = 0,
    };
    var marker = Marker{};

    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            _ = alloc;
            const m: *Marker = @ptrCast(@alignCast(ptr));
            m.order[m.len] = 'a';
            m.len += 1;
            m.freed = true;
        }
    }.destroy);

    try scope.registerResource(@ptrCast(&marker), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            _ = alloc;
            const m: *Marker = @ptrCast(@alignCast(ptr));
            std.debug.assert(!m.freed);
            m.order[m.len] = 'b';
            m.len += 1;
        }
    }.destroy);

    scope.dispose();

    try std.testing.expect(marker.freed);
    try std.testing.expectEqual(@as(usize, 2), marker.len);
    try std.testing.expectEqualStrings("ba", marker.order[0..marker.len]);
}

test "Scope: parent dispose handles cross-scope signal dependencies" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();

    const parent_scope = try Scope.init(allocator, null, owner);
    const producer_scope = try parent_scope.childScope();
    const consumer_scope = try parent_scope.childScope();

    const shared = try producer_scope.createSignal(i32, 1);
    var runs: i32 = 0;

    try consumer_scope.createEffect(.{
        .shared = shared,
        .runs = &runs,
    }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.shared.get();
            ctx.runs.* += 1;
        }
    }.run);

    try std.testing.expectEqual(@as(i32, 1), runs);

    // previously this would access producer_scope's freed Signal in consumer_scope.dispose().
    parent_scope.dispose();
}

test "allocation campaign: Scope/Memo/Effect 构造路径 OOM 不泄漏不半注册" {
    // scan three construction paths per fail-index. testing.allocator auto-checks leaks at test
    // end,
    // FailingAllocator permanently fails after first hit, so each round independently builds
    // owner/scope.
    // invariants locked: construction failure => (a) caller-allocator frees all (Scope path once
    // measured 416B leak); (b) registry has no half-register state (graph_node_raw still 0xFFFFFFFF
    // EffectBase); (c) built graph nodes rolled back.
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();

        var owner = SignalOwner.init(alloc) catch continue;
        defer owner.deinit();

        // pushTracking panics on OOM per policy (tracking stack skew unrecoverable),
        // not part of invariants this test locks, preheat capacity to prevent allocation here
        owner.graph.tracking_stack.ensureTotalCapacity(alloc, 8) catch continue;

        const scope = Scope.init(alloc, null, owner) catch continue;
        defer scope.dispose();

        // child scope (covers parent registration failure branch)
        _ = scope.childScope() catch {};

        // effect (covers createNodeRaw failure after registerEffect branch)
        var effect_runs: u32 = 0;
        scope.createEffect(.{ .runs = &effect_runs }, struct {
            fn run(ctx: anytype) void {
                ctx.runs.* += 1;
            }
        }.run) catch {};

        // memo (covers two allocations + graph register + registerResource failure points)
        const m = scope.createMemo(i32, .{}, struct {
            fn compute(_: anytype) i32 {
                return 7;
            }
        }.compute) catch continue;
        try std.testing.expectEqual(@as(i32, 7), m.get());

        // half-register check: effects reaching here either complete (graph node valid),
        // or not in registry at all
        for (scope.effects.items) |eb| {
            try std.testing.expect(eb.graph_node_raw != 0xFFFFFFFF);
        }
    }
}

test "Scope: adoptResource 登记失败时当场跑 destroyFn，不留孤儿也不双重释放" {
    const Probe = struct {
        var destroyed: usize = 0;
        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            destroyed += 1;
            allocator.destroy(@as(*u64, @ptrCast(@alignCast(ptr))));
        }
    };
    Probe.destroyed = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const owner = try SignalOwner.init(a);
    defer owner.deinit();
    const scope = try Scope.init(a, null, owner);
    defer scope.dispose();

    // first: resources first resize failed -> object must be claimed by destroyFn, error thrown
    // back.
    const first = try a.create(u64);
    first.* = 1;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, scope.adoptResource(@ptrCast(first), Probe.destroy));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), Probe.destroyed);
    try std.testing.expectEqual(@as(usize, 0), scope.resources.items.len);

    // second: success -> owned by scope, disposed exactly once.
    const second = try a.create(u64);
    second.* = 2;
    try scope.adoptResource(@ptrCast(second), Probe.destroy);
    try std.testing.expectEqual(@as(usize, 1), scope.resources.items.len);
    scope.dispose();
    try std.testing.expectEqual(@as(usize, 2), Probe.destroyed);
}

/// `E` of `[]const E`; null for other types (`Scope.createSignalFor` / `resolveModelFor` use it to
/// pick owning-type list)
pub fn constSliceChild(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice and ptr.attrs.@"const" and ptr.sentinel() == null) ptr.child else null,
        else => null,
    };
}

/// mutable slice of `[]E` as signal / Model value: unclear if write is borrow or copy, compile
/// error directly, require `[]const E`
pub fn rejectMutableSlice(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice and !ptr.attrs.@"const")
            @compileError("a signal / Model of a mutable slice " ++ @typeName(T) ++ " is not supported; use []const " ++ @typeName(ptr.child) ++ " (the signal keeps its own copy)"),
        else => {},
    }
}

test "Scope: child cleanup disposing sibling during parent teardown runs once" {
    const allocator = std.testing.allocator;
    var owner = try SignalOwner.init(allocator);
    defer owner.deinit();
    const parent = try Scope.init(allocator, null, owner);
    const first = try parent.childScope();
    const second = try parent.childScope();
    const third = try parent.childScope();
    const Probe = struct {
        sibling: *Scope,
        calls: [4]u32 = @splat(0),
        fn firstCleanup(self: *@This()) void {
            self.calls[0] += 1;
            self.sibling.dispose();
        }
        fn secondCleanup(self: *@This()) void {
            self.calls[1] += 1;
        }
        fn thirdCleanup(self: *@This()) void {
            self.calls[2] += 1;
        }
        fn parentCleanup(self: *@This()) void {
            std.debug.assert(self.calls[0] == 1 and self.calls[1] == 1 and self.calls[2] == 1);
            self.calls[3] += 1;
        }
    };
    var probe: Probe = .{ .sibling = second };
    try first.onCleanup(Probe, &probe, Probe.firstCleanup);
    try second.onCleanup(Probe, &probe, Probe.secondCleanup);
    try third.onCleanup(Probe, &probe, Probe.thirdCleanup);
    try parent.onCleanup(Probe, &probe, Probe.parentCleanup);
    parent.dispose();
    try std.testing.expectEqual(@as([4]u32, @splat(1)), probe.calls);
}
