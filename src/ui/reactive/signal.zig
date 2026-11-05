const std = @import("std");
const Allocator = std.mem.Allocator;

const SignalBase = @import("signal_base.zig").SignalBase;
const SignalOwner = @import("owner.zig").SignalOwner;
const Scope = @import("scope.zig").Scope;
const eqlValue = @import("eq.zig").eqlValue;
const graph_mod = @import("graph.zig");

const debug_checks = SignalOwner.debug_checks;
const alive_sentinel: u32 = 0x5161_A11E;
const dead_sentinel: u32 = 0x5161_DEAD;
const debug_writer_slots = 8;

/// Reactive type marker: `Signal` / `Memo` / `Derived` declare `pub const zenit_reactive`.
/// props normalize (`props.zig`) checks only this marker, no duck type.
pub const ReactiveKind = enum { signal, memo, derived };

/// Owned text signal storage (`scope.createText`). Double-buffer: write target non-current
/// chunk, safe for `set(transform(get()))`. Slice lifetime contract: see `Signal([]const u8)
/// .get` comment. Owned slice double-buffer (`scope.createText` / `scope.createList`): set
/// copy into non-current then switch, so prior slice valid after next write. Shallow copy elements.
pub fn SliceStore(comptime E: type) type {
    // String list owns bytes together: element slices point to this store's byte buffer (same
    // double-buffer as element array)
    const deep = E == []const u8;
    return struct {
        allocator: Allocator,
        bufs: [2][]E = .{ &.{}, &.{} },
        bytes: if (deep) [2][]u8 else void = if (deep) .{ &.{}, &.{} } else {},
        active: u1 = 0,

        const Self = @This();

        /// Copy `content` into non-current and switch. Two-phase: new ready before switch, fail
        /// returns false, current unchanged, no leak.
        pub fn store(self: *Self, content: []const E) bool {
            const target: u1 = self.active ^ 1;
            if (debug_checks and content.len > 0 and self.bufs[target].len > 0) {
                const buf = self.bufs[target];
                const lo = @intFromPtr(buf.ptr);
                const hi = lo + buf.len * @sizeOf(E);
                const p = @intFromPtr(content.ptr);
                std.debug.assert(p + content.len * @sizeOf(E) <= lo or p >= hi); // Contract: caller must not hold prior-prior slice
            }
            if (!self.fill(target, content)) return false;
            self.active = target;
            return true;
        }

        /// Write to `target` buffer (no switch). Fail returns false, target invalid.
        pub fn fill(self: *Self, target: u1, content: []const E) bool {
            if (deep) {
                var total: usize = 0;
                for (content) |str| {
                    total += str.len;
                    if (debug_checks and str.len > 0 and self.bytes[target].len > 0) {
                        // Contract same: strings can't point prior-prior byte buffer (expand frees
                        // it, no expand
                        // overlaps write target)
                        const lo = @intFromPtr(self.bytes[target].ptr);
                        const hi = lo + self.bytes[target].len;
                        const p = @intFromPtr(str.ptr);
                        std.debug.assert(p + str.len <= lo or p >= hi);
                    }
                }
                if (self.bytes[target].len < total) {
                    const cap = @max(total, self.bytes[target].len * 2, 64);
                    const fresh = self.allocator.alloc(u8, cap) catch return false;
                    self.allocator.free(self.bytes[target]);
                    self.bytes[target] = fresh;
                }
            }
            var buf = self.bufs[target];
            if (buf.len < content.len) {
                const cap = @max(content.len, buf.len * 2, 16);
                const fresh = self.allocator.alloc(E, cap) catch return false;
                self.allocator.free(buf);
                buf = fresh;
                self.bufs[target] = buf;
            }
            if (deep) {
                var off: usize = 0;
                for (content, 0..) |str, k| {
                    const dst = self.bytes[target][off .. off + str.len];
                    @memcpy(dst, str);
                    buf[k] = dst;
                    off += str.len;
                }
            } else {
                @memcpy(buf[0..content.len], content);
            }
            return true;
        }

        pub fn current(self: *const Self, len: usize) []const E {
            return self.bufs[self.active][0..len];
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bufs[0]);
            self.allocator.free(self.bufs[1]);
            if (deep) {
                self.allocator.free(self.bytes[0]);
                self.allocator.free(self.bytes[1]);
            }
        }
    };
}

/// Owned text storage
pub const TextStore = SliceStore(u8);

/// `T` = `[]const E` -> `E`, else void (no owned storage)
pub fn SliceElem(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice and info.pointer.attrs.@"const" and info.pointer.sentinel_ptr == null) return info.pointer.child;
    return void;
}

/// Signal(T): generic reactive data source
///
/// Usage:
/// ```zig
/// var owner = try SignalOwner.init(allocator);
/// defer owner.deinit();
///
/// const count = try owner.createSignal(i32, 0);
/// count.set(42);        // notify subscribers
/// const val = count.get(); // auto-register dependency
/// ```
pub fn Signal(comptime T: type) type {
    return struct {
        base: SignalBase,
        value: T,
        owner: *SignalOwner,
        /// Only `scope.createText` / `scope.createList` slices non-empty: value in signal's own
        /// double-buffer (owned).
        slice_store: if (has_store) ?*SliceStore(SliceElem(T)) else void = if (has_store) null else {},
        debug: Debug = .{},

        const Self = @This();
        pub const Value = T;
        pub const zenit_reactive: ReactiveKind = .signal;
        const has_store = SliceElem(T) != void;

        /// Debug diagnostic state (docs/SIGNAL_API_DESIGN.md section 4.11); Release empty struct.
        pub const Debug = if (debug_checks) struct {
            alive: u32 = alive_sentinel,
            /// Owning scope (owner arena path = null); borrow check use.
            scope: ?*Scope = null,
            writers: [debug_writer_slots]usize = @as([debug_writer_slots]usize, @splat(0)),
            writer_next: u8 = 0,
        } else struct {};

        inline fn checkAlive(self: *const Self) void {
            if (debug_checks) {
                if (self.debug.alive != alive_sentinel) {
                    std.debug.panic("Signal({s}) used after its scope was disposed", .{@typeName(T)});
                }
            }
        }

        /// Owning scope; owner arena path or Release build = null.
        pub fn debugScope(self: *const Self) ?*Scope {
            return if (debug_checks) self.debug.scope else null;
        }

        /// Most recent writer return address (new to old, 0 = empty slot). Release empty.
        pub fn debugRecentWriters(self: *const Self) [debug_writer_slots]usize {
            if (!debug_checks) return @as([debug_writer_slots]usize, @splat(0));
            var out: [debug_writer_slots]usize = undefined;
            for (0..debug_writer_slots) |i| {
                const idx = (@as(usize, self.debug.writer_next) + debug_writer_slots - 1 - i) % debug_writer_slots;
                out[i] = self.debug.writers[idx];
            }
            return out;
        }

        /// owner path low-level: allocate in owner arena, freed with owner, no manual free.
        /// App/component code uses `scope.createSignal` (freed with scope).
        pub fn create(owner: *SignalOwner, initial: T) !*Self {
            owner.assertThread();
            const signal = try owner.allocator().create(Self);
            signal.* = .{
                .base = SignalBase.init(owner.allocator(), &vtable),
                .value = initial,
                .owner = owner,
            };

            // Register to owner
            try owner.registerSignal(&signal.base);

            // Sync register NodeId to graph
            const gid = try owner.graph.createSignal();
            signal.base.graph_node_raw = @bitCast(gid);

            return signal;
        }

        /// Create Signal in Scope (retain mode path)
        ///
        /// Use scope.allocator, register to scope (not Arena)
        pub fn createInScope(scope: *Scope, initial: T) !*Self {
            scope.owner.assertThread();
            const signal = try scope.allocator.create(Self);
            errdefer scope.allocator.destroy(signal);
            signal.* = .{
                .base = SignalBase.init(scope.allocator, &scope_vtable),
                .value = initial,
                .owner = scope.owner,
            };
            if (debug_checks) signal.debug.scope = scope;
            // Scope path: subscribers list also scope.allocator
            signal.base.scope_allocator = scope.allocator;

            const gid = try scope.owner.graph.createSignal();
            errdefer scope.owner.graph.destroyNode(gid);
            // Publish in the scope only after graph allocation succeeds.
            try scope.registerSignal(&signal.base);
            signal.base.graph_node_raw = @bitCast(gid);

            return signal;
        }

        /// Vtable (owner arena path, freed with owner)
        const vtable = SignalBase.VTable{
            .cleanup = cleanupImpl,
        };

        /// Vtable (Scope path, single free support)
        const scope_vtable = SignalBase.VTable{
            .cleanup = cleanupImpl,
            .destroy = destroyImpl,
        };

        fn cleanupImpl(base: *SignalBase) void {
            // Arena allocator auto-frees all
            _ = base;
        }

        fn destroyImpl(base: *SignalBase, allocator: Allocator) void {
            const self: *Self = @alignCast(@fieldParentPtr("base", base));
            // subscribers field deleted; graph.destroyNode handles edges
            if (has_store) {
                if (self.slice_store) |ts| {
                    ts.deinit();
                    allocator.destroy(ts);
                }
            }
            if (debug_checks) self.debug.alive = dead_sentinel;
            allocator.destroy(self);
        }

        /// Read value + auto-register dependency
        ///
        /// Single-track tracking: graph.tracking_stack is the only dependency source.
        /// `owner.untrack`
        /// inside (null sentinel reader on stack top) doesn't log a dependency.
        ///
        /// Owned slice (`scope.createText` / `createList`): the returned slice is valid only for
        /// the
        /// current sync call (handler/effect/memo compute until return) and while no signal
        /// re-write
        /// happens. After a write don't reuse it: double-buffering makes `set(transform(get()))`
        /// safe, but a
        /// second write makes the prior slice alias new content (silent wrong value). To keep
        /// across
        /// calls, use dupe/getInto.
        pub fn get(self: *Self) T {
            self.checkAlive();
            self.owner.assertThread();
            if (debug_checks) self.owner.noteTrackedRead("Signal");

            if (self.base.graph_node_raw != 0xFFFFFFFF) {
                const gid: graph_mod.NodeId = @bitCast(self.base.graph_node_raw);
                self.owner.graph.trackRead(gid) catch |err| {
                    std.log.warn("[reactive.Signal] graph.trackRead failed: {}", .{err});
                };
            }

            return self.value;
        }

        /// Read value no-depend
        pub fn peek(self: *const Self) T {
            self.checkAlive();
            self.owner.assertThread();
            return self.value;
        }

        /// Copy current text (cross-call keep). `Signal([]const u8)` only.
        pub fn dupe(self: *const Self, allocator: Allocator) ![]u8 {
            comptime if (T != []const u8) @compileError("dupe is only available on Signal([]const u8)");
            return allocator.dupe(u8, self.peek());
        }

        /// Copy current text into caller buffer; buffer short = truncate. Return written slice.
        pub fn getInto(self: *Self, buf: []u8) []u8 {
            comptime if (T != []const u8) @compileError("getInto is only available on Signal([]const u8)");
            const v = self.get();
            const n = @min(v.len, buf.len);
            @memcpy(buf[0..n], v[0..n]);
            return buf[0..n];
        }

        /// Set new value + notify all subscribers
        pub fn set(self: *Self, new_value: T) void {
            self.checkAlive();
            self.owner.assertThread();
            // Skip unchanged. eqlValue replaces std.meta.eql fixes three bugs: []const u8
            // compares content not (ptr, len), NaN bytewise same = no forever dirty, struct with
            // slice
            // fields recurse correctly.
            if (eqlValue(T, self.value, new_value)) return;

            if (has_store) {
                if (self.slice_store) |ts| {
                    if (!ts.store(new_value)) {
                        // Two-phase commit: fail = value unchanged (design section 4.8).
                        if (debug_checks) self.owner.debug.text_store_failures += 1;
                        std.log.warn("[reactive.Signal] owned slice store allocation failed; value unchanged", .{});
                        return;
                    }
                    self.value = ts.current(new_value.len);
                } else {
                    self.value = new_value;
                }
            } else {
                self.value = new_value;
            }

            if (comptime @import("builtin").is_test) {
                if (self.owner.test_write_trace) |trace| trace.write(trace.context, &self.base);
            }
            if (debug_checks) self.recordWrite(@returnAddress());

            // Writes go through the graph. graph.markSignalWritten internally:
            //   1. signal.version++
            //   2. observers mark dirty (effect -> pending_effects)
            //   3. batch_depth == 0 runs drainPendingEffects (topo-sort run)
            //   4. drain calls effect graphRecomputeCb -> EffectBase.runWithTracking
            //
            // The graph path covers all dispatch in topo order, with no 16 limit and diamond-glitch
            // freedom.
            if (self.base.graph_node_raw != 0xFFFFFFFF) {
                const gid: @import("graph.zig").NodeId = @bitCast(self.base.graph_node_raw);
                // The drain may run an effect that disposes this signal's scope: only the owner
                // (which outlives it) is used afterwards.
                const owner = self.owner;
                owner.graph.markSignalWritten(gid) catch |err| {
                    std.log.err("[reactive.Signal] graph.markSignalWritten failed: {}", .{err});
                };
                // the write's effect drain (if any) has finished: settle point
                owner.drainSettledTasks();
            }
        }

        /// Swap to content-equal but bottom memory different, don't notify (read unchanged).
        /// Borrow slice data source: caller swapped new array, old freed later, signal can't keep
        /// pointing old (list line in-place update). Owned (write copies) owns copy, noop.
        pub fn replaceSameContent(self: *Self, new_value: T) void {
            self.checkAlive();
            self.owner.assertThread();
            std.debug.assert(eqlValue(T, self.value, new_value));
            if (has_store) {
                if (self.slice_store != null) return;
            }
            self.value = new_value;
        }

        fn recordWrite(self: *Self, ret_addr: usize) void {
            self.owner.debug.signal_writes += 1;
            self.debug.writers[self.debug.writer_next] = ret_addr;
            self.debug.writer_next = @intCast((@as(usize, self.debug.writer_next) + 1) % debug_writer_slots);
            if (self.base.graph_node_raw != 0xFFFFFFFF) {
                const gid: graph_mod.NodeId = @bitCast(self.base.graph_node_raw);
                if (self.owner.graph.currentReaderReads(gid)) {
                    // Pain point 4: effect state sync. Switch to memo/scope.linked.
                    self.owner.debug.self_write_warnings += 1;
                    std.log.warn("[reactive] an effect/memo wrote Signal({s}) that it also read; use a memo or scope.linked instead", .{@typeName(T)});
                }
            }
        }

        /// Update value via function
        pub fn update(self: *Self, comptime updateFn: fn (T) T) void {
            self.set(updateFn(self.value));
        }

        /// Update with context: `sig.updateWith(ctx, comptime f)`, `f(ctx, old) T`.
        pub fn updateWith(self: *Self, ctx: anytype, comptime updateFn: anytype) void {
            self.set(updateFn(ctx, self.peek()));
        }
    };
}

// ===== Tests =====

test "Signal: basic get/set" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 42);

    try std.testing.expectEqual(@as(i32, 42), count.get());

    count.set(100);
    try std.testing.expectEqual(@as(i32, 100), count.get());
}

test "Signal: peek doesn't track" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    // peek shouldn't trigger dependency tracking
    _ = count.peek();

    try std.testing.expectEqual(@as(i32, 0), count.peek());
}

test "Signal: update function" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 0);

    count.update(struct {
        fn inc(val: i32) i32 {
            return val + 1;
        }
    }.inc);

    try std.testing.expectEqual(@as(i32, 1), count.get());
}

test "Signal: skip notification if value unchanged" {
    var owner = try SignalOwner.init(std.testing.allocator);
    defer owner.deinit();

    const count = try Signal(i32).create(owner, 42);

    var notify_count: u32 = 0;

    // Simulate subscription
    const MockEffect = struct {
        var counter: *u32 = undefined;

        fn run(_: *anyopaque) void {
            counter.* += 1;
        }
    };

    MockEffect.counter = &notify_count;

    // Set same value shouldn't notify
    count.set(42);
    try std.testing.expectEqual(@as(u32, 0), notify_count);

    // Set different value should notify
    count.set(100);
    // Note: doesn't actually notify here (no real subscriber)
}
