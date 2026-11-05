//! Signal-first component API core types (docs/SIGNAL_API_DESIGN.md sec 4).
//!
//! - `Source(T)`: read-only prop, static value / signal / memo / zero-alloc derived.
//! - `Model(T)`: controlled value prop (single source, component only proposes
//!   write-back), `local` (component-owned) / `bound` (parent-owned) / `split`
//!   (parent-owned, decides each write).
//! - `Derived(T)` + combinators `not / eq / map / map2 / field / derive`:
//!   closure-free derivation.
//! - `Callback(T)`: callback with typed payload; `T == void` form is `HandlerRef` in
//!   ui layer.
//! - `Bound(T)`: runtime form `Model` is parsed to on component mount; `propose` is the
//!   unified write-back pipeline.
//! - borrow check: borrowed signal / memo must be in consumer scope's ancestor
//!   chain (sec 4.11).
const std = @import("std");

const SignalOwner = @import("owner.zig").SignalOwner;
const signal_mod = @import("signal.zig");
const Signal = signal_mod.Signal;
const ReactiveKind = signal_mod.ReactiveKind;
const Memo = @import("memo.zig").Memo;
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;
const eq_mod = @import("eq.zig");
const eqlValue = eq_mod.eqlValue;
const EqKey = eq_mod.EqKey;
const eqKey = eq_mod.eqKey;
const graph_mod = @import("graph.zig");

const debug_checks = SignalOwner.debug_checks;

/// `Derived` max inline source count. Exceed via `derive` pass ctx struct or
/// `scope.createMemo`.
pub const max_derived_sources = 3;

const Args = [max_derived_sources]?*anyopaque;

// Type discrimination

/// Return kind if `X` is one of `*Signal(T)` / `*Memo(T)` / `Derived(T)`. Marker
/// only.
pub fn reactiveKindOf(comptime X: type) ?ReactiveKind {
    const Target = switch (@typeInfo(X)) {
        // const pointer doesn't count: reading signal needs dependency registration,
        // requires *Self (caller gets directed error).
        .pointer => |p| if (p.size == .one and !p.attrs.@"const") p.child else return null,
        .@"struct" => X,
        else => return null,
    };
    if (!isContainer(Target)) return null;
    if (!@hasDecl(Target, "zenit_reactive")) return null;
    const kind: ReactiveKind = Target.zenit_reactive;
    // Derived passed by value; Signal / Memo passed by pointer.
    if ((kind == .derived) != (@typeInfo(X) == .@"struct")) return null;
    return kind;
}

/// Reactive source's value type (`*Signal(T)` -> T). Confirm
/// `reactiveKindOf(X) != null` before call.
pub fn ValueOf(comptime X: type) type {
    return switch (@typeInfo(X)) {
        .pointer => |p| p.child.Value,
        else => X.Value,
    };
}

fn isContainer(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn isConstPointerTo(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .pointer => |p| p.size == .one and p.attrs.@"const" and isContainer(p.child) and @hasDecl(p.child, "zenit_reactive"),
        else => false,
    };
}

// Borrow checking

/// Traverse derived dependency leaf signals / memos, report their owning scope
/// (Debug use).
pub const LeafVisitor = struct {
    ctx: *anyopaque,
    visit_fn: *const fn (ctx: *anyopaque, leaf_scope: ?*Scope) void,

    pub fn visit(self: LeafVisitor, leaf_scope: ?*Scope) void {
        self.visit_fn(self.ctx, leaf_scope);
    }
};

/// Borrow rule (sec 4.11): leaf's owning scope in {consumer's ancestor chain,
/// consumer itself, any root scope}, or leaf owns no scope (owner arena). Scope
/// release strictly children-before-parent; satisfying rule ensures borrowed lives
/// longer than consumer. Judged by logical scope chain, unrelated to node portal.
pub fn borrowAllowed(consumer: *Scope, leaf_scope: ?*Scope) bool {
    const leaf = leaf_scope orelse return true;
    if (leaf.parent == null) return true;
    var cur: ?*Scope = consumer;
    while (cur) |s| : (cur = s.parent) {
        if (s == leaf) return true;
    }
    return false;
}

/// Borrow-check all leaves of `src`; count + warn on violation, no abort (Debug
/// build).
pub fn checkBorrow(consumer: *Scope, src: anytype) void {
    if (debug_checks) checkBorrowDebug(consumer, src);
}

fn checkBorrowDebug(consumer: *Scope, src: anytype) void {
    if (comptime isContainer(@TypeOf(src)) and @hasDecl(@TypeOf(src), "zenit_assume_outlives")) return;
    const Ctx = struct {
        consumer: *Scope,
        fn visit(ctx: *anyopaque, leaf_scope: ?*Scope) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (borrowAllowed(self.consumer, leaf_scope)) return;
            self.consumer.owner.debug.borrow_warnings += 1;
            std.log.warn("[reactive] borrowed signal is owned by a scope outside the consumer's ancestor chain; it may be freed first (use ui.assumeOutlives if intended)", .{});
        }
    };
    var ctx = Ctx{ .consumer = consumer };
    visitLeaves(src, .{ .ctx = &ctx, .visit_fn = Ctx.visit });
}

fn visitLeaves(src: anytype, v: LeafVisitor) void {
    const X = @TypeOf(src);
    if (comptime reactiveKindOf(X)) |kind| switch (kind) {
        .signal, .memo => v.visit(src.debugScope()),
        .derived => src.visit(&src.args, v),
    } else if (comptime isContainer(X) and @hasDecl(X, "visitLeaves")) {
        src.visitLeaves(v);
    }
}

/// Explicitly declare 'this signal outlives consumer', skip borrow check (sec
/// 4.11 escape hatch).
pub fn AssumeOutlives(comptime P: type) type {
    return struct {
        ptr: P,
        pub const zenit_assume_outlives = true;
    };
}

pub fn assumeOutlives(ptr: anytype) AssumeOutlives(@TypeOf(ptr)) {
    return .{ .ptr = ptr };
}

// ---------------------------------------------------------------------------
// Derived
// ---------------------------------------------------------------------------

/// Zero-alloc derivation: inline up to 3 source pointers + comptime-generated
/// thunk. Not cached (sec 4.2).
pub fn Derived(comptime T: type) type {
    return struct {
        args: Args,
        owner: *SignalOwner,
        compute: *const fn (args: *const Args) T,
        /// Debug: traverse leaves for borrow check; void in Release.
        visit: VisitFn,

        const Self = @This();
        pub const Value = T;
        pub const zenit_reactive: ReactiveKind = .derived;
        pub const VisitFn = if (debug_checks) *const fn (args: *const Args, v: LeafVisitor) void else void;

        /// Evaluate; register dependency if called inside effect / memo.
        pub fn get(self: Self) T {
            return self.compute(&self.args);
        }

        /// Evaluate without registering dependency.
        pub fn peek(self: Self) T {
            if (debug_checks) self.owner.debug.snapshot_depth += 1;
            defer if (debug_checks) {
                self.owner.debug.snapshot_depth -= 1;
            };
            return self.owner.untrack(struct {
                fn run(d: Self) T {
                    return d.compute(&d.args);
                }
            }.run, self);
        }
    };
}

/// Generic derive: `sources` is a 1-3 stable-pointer tuple (`*Signal` / `*Memo` / any ctx pointer,
/// at least one Signal or Memo), `f` receives same-shaped tuple returning `T`.
///
/// ```zig
/// const total = ui.derive(f32, .{ price, qty }, struct {
///     fn f(s: anytype) f32 { return s[0].get() * @as(f32, @floatFromInt(s[1].get())); }
/// }.f);
/// ```
pub fn derive(comptime T: type, sources: anytype, comptime f: anytype) Derived(T) {
    const S = @TypeOf(sources);
    const fields = @import("zenit_reflection").fields(S);
    if (fields.len == 0 or fields.len > max_derived_sources) {
        @compileError(std.fmt.comptimePrint("ui.derive takes 1..{d} sources; use scope.createMemo for more", .{max_derived_sources}));
    }
    const owner_name = comptime blk: {
        var owner_field: ?[]const u8 = null;
        for (fields) |fld| {
            if (@typeInfo(fld.type) != .pointer or @typeInfo(fld.type).pointer.size != .one) {
                @compileError("ui.derive: source '" ++ fld.name ++ "' must be a single-item pointer, got " ++ @typeName(fld.type));
            }
            if (owner_field == null) {
                if (reactiveKindOf(fld.type)) |kind| {
                    if (kind != .derived) owner_field = fld.name;
                }
            }
        }
        break :blk owner_field orelse @compileError("ui.derive needs at least one *Signal or *Memo source");
    };

    const Thunks = struct {
        fn unpack(args: *const Args) S {
            var t: S = undefined;
            inline for (fields, 0..) |fld, i| {
                @field(t, fld.name) = @ptrCast(@alignCast(args[i].?));
            }
            return t;
        }
        fn compute(args: *const Args) T {
            return f(unpack(args));
        }
        fn visit(args: *const Args, v: LeafVisitor) void {
            const t = unpack(args);
            inline for (fields) |fld| {
                if (comptime reactiveKindOf(fld.type) != null) visitLeaves(@field(t, fld.name), v);
            }
        }
    };

    var d: Derived(T) = .{
        .args = .{ null, null, null },
        .owner = @field(sources, owner_name).owner,
        .compute = Thunks.compute,
        .visit = if (debug_checks) Thunks.visit else {},
    };
    inline for (fields, 0..) |fld, i| {
        d.args[i] = @ptrCast(@constCast(@field(sources, fld.name)));
    }
    return d;
}

/// `!src`
pub fn not(src: anytype) Derived(bool) {
    requireSourcePtr(@TypeOf(src), bool, "ui.not");
    return derive(bool, .{src}, struct {
        fn f(s: anytype) bool {
            return !s[0].get();
        }
    }.f);
}

/// `src == value`, `value` must be comptime constant (e.g., enum literal). Runtime
/// value comparison uses `derive`.
pub fn eq(src: anytype, comptime value: anytype) Derived(bool) {
    const V = SourcePtrValue(@TypeOf(src), "ui.eq");
    const target: V = value;
    return derive(bool, .{src}, struct {
        fn f(s: anytype) bool {
            return eqlValue(V, s[0].get(), target);
        }
    }.f);
}

/// `f(src)`
pub fn map(src: anytype, comptime f: anytype) Derived(ReturnOf(f)) {
    const V = SourcePtrValue(@TypeOf(src), "ui.map");
    _ = V;
    return derive(ReturnOf(f), .{src}, struct {
        fn g(s: anytype) ReturnOf(f) {
            return f(s[0].get());
        }
    }.g);
}

/// `f(a, b)`
pub fn map2(a: anytype, b: anytype, comptime f: anytype) Derived(ReturnOf(f)) {
    _ = SourcePtrValue(@TypeOf(a), "ui.map2");
    _ = SourcePtrValue(@TypeOf(b), "ui.map2");
    return derive(ReturnOf(f), .{ a, b }, struct {
        fn g(s: anytype) ReturnOf(f) {
            return f(s[0].get(), s[1].get());
        }
    }.g);
}

/// `src.<name>` (`name` is enum literal, e.g., `.email`).
pub fn field(src: anytype, comptime name: @TypeOf(.enum_literal)) Derived(@FieldType(SourcePtrValue(@TypeOf(src), "ui.field"), @tagName(name))) {
    const V = SourcePtrValue(@TypeOf(src), "ui.field");
    const F = @FieldType(V, @tagName(name));
    return derive(F, .{src}, struct {
        fn f(s: anytype) F {
            return @field(s[0].get(), @tagName(name));
        }
    }.f);
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn SourcePtrValue(comptime X: type, comptime who: []const u8) type {
    const kind = reactiveKindOf(X) orelse @compileError(who ++ ": expected *Signal(T) or *Memo(T), got " ++ @typeName(X));
    if (kind == .derived) @compileError(who ++ ": pass a *Signal or *Memo; compose derived values with ui.derive");
    return ValueOf(X);
}

fn requireSourcePtr(comptime X: type, comptime V: type, comptime who: []const u8) void {
    const got = SourcePtrValue(X, who);
    if (got != V) @compileError(who ++ ": expected a source of " ++ @typeName(V) ++ ", got " ++ @typeName(X));
}

// ---------------------------------------------------------------------------
// Callback
// ---------------------------------------------------------------------------

/// Callback with typed payload. Component props events use it uniformly (ui layer
/// `Handler(T)`).
pub fn Callback(comptime T: type) type {
    return struct {
        ctx: *anyopaque,
        call_fn: *const fn (ctx: *anyopaque, value: T) void,

        const Self = @This();
        pub const Value = T;
        /// event callback type marker (Yix distinguishes events from data by receiver param
        /// type, see ui.view.isEventProp).
        pub const zenit_handler = true;

        pub fn call(self: Self, value: T) void {
            self.call_fn(self.ctx, value);
        }

        /// Construct from `method: fn(*S, T) void` (or function pointer to it).
        pub fn from(comptime S: type, state: *S, comptime method: anytype) Self {
            return .{
                .ctx = @ptrCast(state),
                .call_fn = struct {
                    fn invoke(ctx: *anyopaque, value: T) void {
                        method(@ptrCast(@alignCast(ctx)), value);
                    }
                }.invoke,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Source
// ---------------------------------------------------------------------------

/// Read-only prop. Static value zero-cost: no alloc, no effect, no dependency
/// graph (sec 4.1).
pub fn Source(comptime T: type) type {
    return union(enum) {
        value: T,
        signal: *Signal(T),
        memo: *Memo(T),
        derived: Derived(T),

        const Self = @This();
        pub const Value = T;
        pub const zenit_source = true;

        /// decl literal: `.label = .of("Save")` (when passing canonical Props struct
        /// directly).
        pub fn of(v: T) Self {
            return .{ .value = v };
        }

        /// Register dependency if called inside effect / memo.
        pub fn get(self: Self) T {
            return switch (self) {
                .value => |v| v,
                .signal => |s| s.get(),
                .memo => |m| m.get(),
                .derived => |d| d.get(),
            };
        }

        /// Don't register dependency.
        pub fn peek(self: Self) T {
            return switch (self) {
                .value => |v| v,
                .signal => |s| s.peek(),
                .memo => |m| m.peek(),
                .derived => |d| d.peek(),
            };
        }

        pub fn isStatic(self: Self) bool {
            return self == .value;
        }

        /// Unified read for component view function: `read(false)` snapshot at mount
        /// (error direct return), `read(true)` register dependency in effect. Reuse one
        /// view function both places.
        pub fn read(self: Self, comptime tracked: bool) T {
            return if (tracked) self.get() else self.peek();
        }

        pub fn visitLeaves(self: Self, v: LeafVisitor) void {
            switch (self) {
                .value => {},
                .signal => |s| v.visit(s.debugScope()),
                .memo => |m| v.visit(m.debugScope()),
                .derived => |d| if (debug_checks) d.visit(&d.args, v),
            }
        }
    };
}

/// Reactive source (`*Signal(T)` / `*Memo(T)` / `Derived(T)` / `Source(T)`) value
/// type.
pub fn SourceValueOf(comptime X: type) type {
    if (comptime isContainer(X) and @hasDecl(X, "zenit_source")) return X.Value;
    if (comptime reactiveKindOf(X) != null) return ValueOf(X);
    if (comptime isConstPointerTo(X)) @compileError("pass a mutable pointer (*Signal / *Memo), got " ++ @typeName(X));
    @compileError("expected *Signal(T), *Memo(T), a derived value or Source(T), got " ++ @typeName(X));
}

/// Unify reactive source into `Source(T)` (internal use: `watch` / `linked` /
/// `bind` etc).
pub fn toSource(src: anytype) Source(SourceValueOf(@TypeOf(src))) {
    const X = @TypeOf(src);
    const T = SourceValueOf(X);
    if (X == Source(T)) return src;
    return switch (comptime reactiveKindOf(X).?) {
        .signal => .{ .signal = src },
        .memo => .{ .memo = src },
        .derived => .{ .derived = src },
    };
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// `split` form: read `read`, proposal to `write`, parent decides whether/how to
/// land. Contract: `write` must land synchronously in current call stack (sec 4.4).
pub fn Split(comptime T: type) type {
    return struct {
        read: Source(T),
        write: Callback(T),

        pub const Value = T;
        pub const zenit_split = true;
    };
}

/// `ui.split(read, write)`: `read` can be `*Signal(T)` / `*Memo(T)` / `Derived(T)`,
/// `write` is `Handler(T)` (`cx.on(S, s, S.method)`, method is `fn(*S, T) void`).
pub fn split(read: anytype, write: anytype) Split(SplitValue(@TypeOf(read))) {
    const R = @TypeOf(read);
    const kind = comptime reactiveKindOf(R).?;
    const T = SplitValue(R);
    const W = @TypeOf(write);
    if (W != Callback(T)) @compileError("ui.split: `write` must be a Handler(" ++ @typeName(T) ++ ") (cx.on with a fn(*S, " ++ @typeName(T) ++ ") void method), got " ++ @typeName(W));
    const src: Source(T) = switch (kind) {
        .signal => .{ .signal = read },
        .memo => .{ .memo = read },
        .derived => .{ .derived = read },
    };
    return .{ .read = src, .write = write };
}

fn SplitValue(comptime R: type) type {
    if (reactiveKindOf(R) == null) {
        @compileError("ui.split: `read` must be a *Signal(T), *Memo(T) or a derived value; a static value would never change (got " ++ @typeName(R) ++ ")");
    }
    return ValueOf(R);
}

/// Controlled value prop (sec 4.3): component both displays it and wants to change
/// on user interaction (checked / value / open / selected ...). Data flow is
/// unidirectional, not 'bidirectional sync':
///
/// - **Single data source**. Tag is ownership: `local` component's own signal,
///   `bound` / `split` parent-owned.
/// - **View follows source only**. Component reads source in effect to drive view,
///   never keeps 'what it thinks'; parent `set` anytime, view follows.
/// - **Interaction is proposal only**. Event entry passes new value via
///   `Bound.propose` / `commit` to source: `local` / `bound` write directly; `split`
///   to parent callback, it accepts, rewrites or rejects (parent may not write).
/// - **`on_change` reports landed value only**. After proposal, read source back; if
///   truly changed, callback with landed value (possibly parent-rewritten); if
///   rejected, no callback, view stays at source's current value.
/// - component-internal drafts (edited text, half-selected range, search term) are not
///   source; must discard on leaving edit mode, return to source value.
pub fn Model(comptime T: type) type {
    return union(enum) {
        /// Uncontrolled: component creates signal in own scope, uses as initial value.
        local: T,
        /// Controlled: parent owns the signal; component reads it and writes it directly when
        /// proposing.
        bound: *Signal(T),
        /// Controlled + intercepting.
        split: Split(T),
        /// Controlled (read-only): values from parent's read-only source (derived values, list row
        /// fields, props); component does not write.
        /// User actions invoke component's onChange with the proposed value; parent decides whether
        /// to update data (React-style controlled).
        /// Display follows the read-only source when parent doesn't change it.
        controlled: Source(T),

        const Self = @This();
        pub const Value = T;
        pub const zenit_model = true;

        /// Decl literal (pass spec Props struct directly): `.checked = .of(true)`.
        pub fn of(v: T) Self {
            return .{ .local = v };
        }

        /// Decl literal: `.checked = .bindTo(agree)`.
        pub fn bindTo(sig: *Signal(T)) Self {
            return .{ .bound = sig };
        }

        pub fn visitLeaves(self: Self, v: LeafVisitor) void {
            switch (self) {
                .local => {},
                .bound => |s| v.visit(s.debugScope()),
                .split => |sp| sp.read.visitLeaves(v),
                .controlled => |src| src.visitLeaves(v),
            }
        }
    };
}

/// Runtime form parsed from `Model(T)` when component mounts.
pub fn Bound(comptime T: type) type {
    return struct {
        read: Source(T),
        /// local / bound: write directly; split / controlled: null.
        signal: ?*Signal(T),
        /// split: parent's write callback; others null. If both signal and write are null, it's
        /// controlled (does not write data source).
        write: ?Callback(T),
        owner: *SignalOwner,

        const Self = @This();

        /// Write pipeline (§4.4). `v` should be sanitized by component already.
        /// Called only at event entry (Debug asserts not in effect/memo computation).
        /// When data source actually changes, call `on_change` with settled value
        /// (parent-transformed value, not proposal).
        pub fn propose(self: Self, v: T, on_change: anytype) void {
            const landed = self.commit(v) orelse return;
            const C = @TypeOf(on_change);
            if (C == @TypeOf(null)) return;
            const cb = (if (@typeInfo(C) == .optional) on_change else @as(?C, on_change)) orelse return;
            const Cb = @TypeOf(cb);
            if (Cb.Value == T) return cb.call(landed);
            // Value is ?U, callback is Handler(U) (e.g., RadioGroup: selected value can be null,
            // callback only reports selected): don't call when settled to null
            if (@typeInfo(T) == .optional and @typeInfo(T).optional.child == Cb.Value) {
                if (landed) |x| cb.call(x);
                return;
            }
            @compileError("Model(" ++ @typeName(T) ++ ").propose: on_change must be a Handler(" ++ @typeName(T) ++ ") or, for an optional value, a Handler of its child type");
        }

        /// Write pipeline body: propose `v`; return settled value if data source changes, else
        /// null.
        /// For components whose callback type differs from `T` (e.g., `?[]const u8` value +
        /// `[]const u8` callback), use this directly.
        pub fn commit(self: Self, v: T) ?T {
            if (debug_checks and self.owner.inReactiveComputation()) {
                // Event handlers that a computation sets off synchronously (blur from an effect
                // revoking focus) defer their proposal with `SignalOwner.runOutsideComputation`.
                std.debug.panic("Model.propose called inside an effect/memo; proposals must come from event handlers", .{});
            }
            // Compare keys, not save old slice: split's parent callback may write text source
            // twice, or drain another write synchronously outside batch; the double-buffer holding
            // the old slice will be overwritten/freed.
            const before = eqKey(T, self.read.peek());
            if (self.signal) |s| {
                s.set(v);
            } else if (self.write == null) {
                // Controlled: does not write data source; proposal itself is the value passed to
                // parent (same as current value means no change).
                if (eqlValue(EqKey(T), before, eqKey(T, v))) return null;
                return v;
            } else {
                const version_before = if (debug_checks) self.readVersion() else {};
                self.write.?.call(v);
                if (debug_checks) {
                    if (self.readVersion()) |after| {
                        if (after == version_before.?) {
                            self.owner.debug.split_unlanded_hints += 1;
                            std.log.debug("[reactive] split write did not change the read signal synchronously; on_change will not fire", .{});
                        }
                    }
                }
            }
            const landed = self.read.peek();
            if (eqlValue(EqKey(T), before, eqKey(T, landed))) return null;
            return landed;
        }

        /// For signal read source in split, return its graph version (for Debug settled check);
        /// memo/derived cannot be checked precisely, return null (no hint).
        fn readVersion(self: Self) ?u64 {
            const sig = switch (self.read) {
                .signal => |sg| sg,
                else => return null,
            };
            if (sig.base.graph_node_raw == 0xFFFFFFFF) return null;
            const gid: graph_mod.NodeId = @bitCast(sig.base.graph_node_raw);
            const node = self.owner.graph.getNodeConst(gid) orelse return null;
            return node.version;
        }

        /// Current value; registers dependency when called in effect.
        pub fn get(self: Self) T {
            return self.read.get();
        }

        /// Same as `Source.read`: pass false in mount snapshot, true in effect.
        pub fn readAs(self: Self, comptime tracked: bool) T {
            return self.read.read(tracked);
        }

        pub fn peek(self: Self) T {
            return self.read.peek();
        }

        /// Convert directly to `Model(T)`, pass to child components sharing the same data source
        /// (e.g., Select passes toggle to Popover).
        pub fn toModel(self: Self) Model(T) {
            if (self.signal) |sig| return .{ .bound = sig };
            if (self.write) |w| return .{ .split = .{ .read = self.read, .write = w } };
            return .{ .controlled = self.read };
        }

        /// For local/bound, return underlying signal (component exposes to caller via mount
        /// result).
        pub fn asSignal(self: Self) ?*Signal(T) {
            return self.signal;
        }
    };
}

/// Parse `Model(T)` to `Bound(T)`. For `local`, create signal in `scope` (component owns). For
/// `bound`/`split`, do borrow checking.
pub fn resolveModel(comptime T: type, scope: *Scope, model: Model(T)) !Bound(T) {
    switch (model) {
        .local => |v| {
            const sig = try scope.createSignal(T, v);
            return .{ .read = .{ .signal = sig }, .signal = sig, .write = null, .owner = scope.owner };
        },
        .bound => |sig| {
            checkBorrow(scope, sig);
            return .{ .read = .{ .signal = sig }, .signal = sig, .write = null, .owner = scope.owner };
        },
        .split => |sp| {
            checkBorrow(scope, sp.read);
            return .{ .read = sp.read, .signal = null, .write = sp.write, .owner = scope.owner };
        },
        .controlled => |src| {
            checkBorrow(scope, src);
            return .{ .read = src, .signal = null, .write = null, .owner = scope.owner };
        },
    }
}

/// Model parsing for owned text signal: for `local`, create owned text signal; for `bound`,
/// require it to be owned (`scope.createText`), else return `error.TextModelNotOwned` (§4.8).
pub fn resolveTextModel(scope: *Scope, model: Model([]const u8)) !Bound([]const u8) {
    switch (model) {
        .local => |v| {
            const sig = try scope.createText(v, .{});
            return .{ .read = .{ .signal = sig }, .signal = sig, .write = null, .owner = scope.owner };
        },
        .bound => |sig| {
            // All build modes check: non-owned text signal holds only borrowed slice; component
            // consuming as "owned" will dangle.
            if (sig.slice_store == null) return error.TextModelNotOwned;
            return resolveModel([]const u8, scope, model);
        },
        .split, .controlled => return resolveModel([]const u8, scope, model),
    }
}

/// Model parsing for owned list signal (set models: checked row keys, expanded node ids...).
/// New sets written by component are usually in temp buffers; data source must copy: for `local`,
/// create owned list
/// signal; for `bound`, require it from `scope.createList`, else `error.ListModelNotOwned`; for
/// `split`, write callback's
/// slice is valid only for this call; parent must copy.
pub fn resolveListModel(comptime E: type, scope: *Scope, model: Model([]const E)) !Bound([]const E) {
    switch (model) {
        .local => |v| {
            const sig = try scope.createList(E, v);
            return .{ .read = .{ .signal = sig }, .signal = sig, .write = null, .owner = scope.owner };
        },
        .bound => |sig| {
            if (sig.slice_store == null) return error.ListModelNotOwned;
            return resolveModel([]const E, scope, model);
        },
        .split, .controlled => return resolveModel([]const E, scope, model),
    }
}

/// Choose Model parsing by value type (Yix `Model(T)` param): `[]const u8` is owned text, other
/// `[]const E` is owned list, other types use `resolveModel`. Judge by type itself, not how it's
/// written (aliases work too).
pub fn resolveModelFor(comptime T: type, scope: *Scope, model: Model(T)) !Bound(T) {
    comptime scope_mod.rejectMutableSlice(T);
    if (T == []const u8) return resolveTextModel(scope, model);
    if (comptime scope_mod.constSliceChild(T)) |E| return resolveListModel(E, scope, model);
    return resolveModel(T, scope, model);
}

// Tests

const testing = std.testing;

test "createList: owned list signal copies the elements; the old slice survives one more write" {
    var owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    var tmp = [_]u32{ 1, 2, 3 };
    const sel = try scope.createList(u32, &tmp);
    tmp[0] = 99; // Caller changing temp buffer doesn't affect signal
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, sel.peek());
    const prev = sel.peek();
    var next = [_]u32{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    sel.set(&next);
    next[0] = 0;
    try testing.expectEqual(@as(u32, 4), sel.peek()[0]);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, prev); // Double-buffer: previous version still valid

    // String list owns bytes together: caller changing/freeing temp buffer doesn't affect signal
    var name_buf = "alpha".*;
    const names = try scope.createList([]const u8, &.{ name_buf[0..], "beta" });
    name_buf[0] = 'X';
    try testing.expectEqualStrings("alpha", names.peek()[0]);
    var tmp_a = "first".*;
    var tmp_b = ((@as([("y").len * (100)]u8, @bitCast(@as([100][("y").len]u8, @splat(("y").*)))) ++ "")).*; // Exceeds initial byte capacity, triggers reallocation
    names.set(&.{ tmp_a[0..], tmp_b[0..] });
    tmp_a[0] = 'Z';
    tmp_b[0] = 'Z';
    try testing.expectEqualStrings("first", names.peek()[0]);
    try testing.expectEqualStrings((@as([("y").len * (100)]u8, @bitCast(@as([100][("y").len]u8, @splat(("y").*)))) ++ ""), names.peek()[1]);

    const borrowed = try scope.createSignal([]const u32, &.{});
    try testing.expectError(error.ListModelNotOwned, resolveListModel(u32, scope, .{ .bound = borrowed }));
    const b = try resolveListModel(u32, scope, .{ .local = &.{ 7, 8 } });
    try testing.expect(b.signal.?.slice_store != null);
}

test "Source: static value is zero-cost and returns the value" {
    const s = Source(u32).of(7);
    try testing.expect(s.isStatic());
    try testing.expectEqual(@as(u32, 7), s.get());
    try testing.expectEqual(@as(u32, 7), s.peek());
}

test "derive combinators follow their sources" {
    const scope = try Scope.init(testing.allocator, null, try SignalOwner.init(testing.allocator));
    const owner = scope.owner;
    defer owner.deinit();
    defer scope.dispose();

    const loading = try scope.createSignal(bool, false);
    const Page = enum { home, settings };
    const page = try scope.createSignal(Page, .home);
    const count = try scope.createSignal(u32, 2);
    const other = try scope.createSignal(u32, 3);
    const User = struct { age: u8, id: u32 };
    const user = try scope.createSignal(User, .{ .age = 30, .id = 1 });

    const disabled = not(loading);
    const on_settings = eq(page, .settings);
    const doubled = map(count, struct {
        fn f(v: u32) u64 {
            return v * 2;
        }
    }.f);
    const sum = map2(count, other, struct {
        fn f(a: u32, b: u32) u32 {
            return a + b;
        }
    }.f);
    const age = field(user, .age);

    try testing.expect(disabled.get());
    try testing.expect(!on_settings.get());
    try testing.expectEqual(@as(u64, 4), doubled.get());
    try testing.expectEqual(@as(u32, 5), sum.get());
    try testing.expectEqual(@as(u8, 30), age.get());

    loading.set(true);
    page.set(.settings);
    count.set(10);
    user.set(.{ .age = 31, .id = 1 });
    try testing.expect(!disabled.get());
    try testing.expect(on_settings.peek());
    try testing.expectEqual(@as(u64, 20), doubled.get());
    try testing.expectEqual(@as(u32, 13), sum.get());
    try testing.expectEqual(@as(u8, 31), age.get());
}

test "derived value is tracked inside an effect" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const loading = try scope.createSignal(bool, false);
    const src: Source(bool) = .{ .derived = not(loading) };
    var seen: [4]bool = undefined;
    var n: usize = 0;
    try scope.createEffect(.{ .src = src, .seen = &seen, .n = &n }, struct {
        fn run(c: anytype) void {
            c.seen[c.n.*] = c.src.get();
            c.n.* += 1;
        }
    }.run);
    loading.set(true);
    loading.set(false);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, seen[0..3]);
}

test "Bound.propose: controlled 不写只读源，提议直接交给 on_change（同值不回调）；toModel 原样保留形态" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();
    const Probe = struct {
        last: ?bool = null,
        calls: u32 = 0,
        fn changed(self: *@This(), v: bool) void {
            self.last = v;
            self.calls += 1;
        }
    };
    var probe = Probe{};
    const cb = Callback(bool).from(Probe, &probe, Probe.changed);
    const src = try scope.createSignal(bool, false);
    const m = try scope.createMemo(bool, .{ .s = src }, struct {
        fn f(c: anytype) bool {
            return c.s.get();
        }
    }.f);
    const ctl = try resolveModel(bool, scope, .{ .controlled = .{ .memo = m } });
    ctl.propose(true, cb);
    try testing.expectEqual(@as(?bool, true), probe.last);
    try testing.expect(!ctl.peek()); // Read-only source was not written
    ctl.propose(false, cb); // Same as current value: don't call callback
    try testing.expectEqual(@as(u32, 1), probe.calls);
    src.set(true); // Parent changes data: display follows
    try testing.expect(ctl.peek());
    try testing.expect(ctl.toModel() == .controlled);
    const bound = try resolveModel(bool, scope, .{ .bound = src });
    try testing.expect(bound.toModel() == .bound);
}

test "Bound.propose: local/bound write directly, on_change gets the landed value" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const Probe = struct {
        last: ?bool = null,
        calls: u32 = 0,
        fn changed(self: *@This(), v: bool) void {
            self.last = v;
            self.calls += 1;
        }
    };
    var probe = Probe{};
    const cb = Callback(bool).from(Probe, &probe, Probe.changed);

    const local = try resolveModel(bool, scope, .{ .local = false });
    local.propose(true, cb);
    try testing.expect(local.peek());
    try testing.expectEqual(@as(?bool, true), probe.last);
    local.propose(true, cb); // Same value: doesn't trigger
    try testing.expectEqual(@as(u32, 1), probe.calls);

    const agree = try scope.createSignal(bool, false);
    const bound = try resolveModel(bool, scope, .{ .bound = agree });
    bound.propose(true, cb);
    try testing.expect(agree.peek());
    try testing.expectEqual(@as(u32, 2), probe.calls);
}

test "Bound.propose: split lets the parent transform or reject" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const vol = try scope.createSignal(f32, 30);
    const Parent = struct {
        vol: *Signal(f32),
        fn propose(self: *@This(), v: f32) void {
            if (v > 80) return; // Reject
            self.vol.set(@round(v / 10) * 10); // Transform
        }
    };
    var parent = Parent{ .vol = vol };
    const Probe = struct {
        last: ?f32 = null,
        fn changed(self: *@This(), v: f32) void {
            self.last = v;
        }
    };
    var probe = Probe{};

    const m = try resolveModel(f32, scope, .{ .split = split(vol, Callback(f32).from(Parent, &parent, Parent.propose)) });
    m.propose(47, Callback(f32).from(Probe, &probe, Probe.changed));
    try testing.expectEqual(@as(f32, 50), vol.peek());
    try testing.expectEqual(@as(?f32, 50), probe.last); // Settled value, not proposal

    probe.last = null;
    m.propose(95, Callback(f32).from(Probe, &probe, Probe.changed));
    try testing.expectEqual(@as(f32, 50), vol.peek()); // Rejected: data source unchanged
    try testing.expectEqual(@as(?f32, null), probe.last); // Doesn't trigger
    if (debug_checks) try testing.expectEqual(@as(u32, 1), owner.debug.split_unlanded_hints);
}

test "borrow check: ancestor and root scopes are allowed, a sibling scope is not" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const root = try Scope.init(testing.allocator, null, owner);
    defer root.dispose();
    const parent = try root.childScope();
    const child = try parent.childScope();
    const sibling = try root.childScope();

    try testing.expect(borrowAllowed(child, parent));
    try testing.expect(borrowAllowed(child, child));
    try testing.expect(borrowAllowed(child, root));
    try testing.expect(borrowAllowed(child, null));
    try testing.expect(!borrowAllowed(child, sibling));
    try testing.expect(!borrowAllowed(parent, child));

    if (!debug_checks) return;
    const from_sibling = try sibling.createSignal(bool, false);
    const from_parent = try parent.createSignal(bool, false);
    checkBorrow(child, from_parent);
    try testing.expectEqual(@as(u32, 0), owner.debug.borrow_warnings);
    checkBorrow(child, from_sibling);
    try testing.expectEqual(@as(u32, 1), owner.debug.borrow_warnings);
    // Derived recursively checks to leaves
    checkBorrow(child, not(from_sibling));
    try testing.expectEqual(@as(u32, 2), owner.debug.borrow_warnings);
    const src: Source(bool) = .{ .derived = map2(from_parent, from_sibling, struct {
        fn f(a: bool, b: bool) bool {
            return a and b;
        }
    }.f) };
    checkBorrow(child, src);
    try testing.expectEqual(@as(u32, 3), owner.debug.borrow_warnings);
}

test "createText: set copies, transform-of-get is safe, buffers grow" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const name = try scope.createText("ab", .{});
    var buf = [_]u8{ 'x', 'y', 'z' };
    name.set(&buf);
    buf[0] = 'Q'; // Caller changing own buffer doesn't affect signal
    try testing.expectEqualStrings("xyz", name.peek());

    // set(transform(get())): write target is non-current buffer
    name.set(name.peek()[1..]);
    try testing.expectEqualStrings("yz", name.peek());

    const long = "a fairly long string that forces the buffer to grow";
    name.set(long);
    try testing.expectEqualStrings(long, name.peek());

    const copy = try name.dupe(testing.allocator);
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings(long, copy);
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("a fair", name.getInto(&small));
}

test "createText: allocation failure keeps the old value (two-phase commit)" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(failing.allocator(), null, owner);
    defer scope.dispose();

    const t = try scope.createText("hello", .{});
    failing.fail_index = failing.alloc_index; // Next allocation fails
    t.set("this needs a much larger buffer than before");
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqualStrings("hello", t.peek());
    if (debug_checks) try testing.expectEqual(@as(u32, 1), owner.debug.text_store_failures);
    t.set("ok now");
    try testing.expectEqualStrings("ok now", t.peek());
}

test "scope.watch: lazy, gets (new, old), body is untracked" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const count = try scope.createSignal(u32, 1);
    const other = try scope.createSignal(u32, 100);
    const Log = struct {
        calls: u32 = 0,
        new: u32 = 0,
        old: u32 = 0,
        other: *Signal(u32),
    };
    var log = Log{ .other = other };
    try scope.watch(count, &log, struct {
        fn f(l: *Log, new: u32, old: u32) void {
            l.calls += 1;
            l.new = new;
            l.old = old;
            _ = l.other.get(); // Should not be tracked
        }
    }.f);
    try testing.expectEqual(@as(u32, 0), log.calls);
    count.set(2);
    try testing.expectEqual(@as(u32, 1), log.calls);
    try testing.expectEqual(@as(u32, 2), log.new);
    try testing.expectEqual(@as(u32, 1), log.old);
    other.set(200);
    try testing.expectEqual(@as(u32, 1), log.calls);
}

test "scope.linked: follows the source, can be edited locally, resets on change" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const options_len = try scope.createSignal(u32, 5);
    const selected = try scope.linked(u32, options_len, struct {
        fn reset(new_len: u32, current: u32) u32 {
            return if (current < new_len) current else new_len - 1;
        }
    }.reset);
    try testing.expectEqual(@as(u32, 5), selected.peek());
    selected.set(3); // Local edit
    try testing.expectEqual(@as(u32, 3), selected.peek());
    options_len.set(10); // Upstream change: current still valid, keep
    try testing.expectEqual(@as(u32, 3), selected.peek());
    options_len.set(2); // Out of bounds: reset
    try testing.expectEqual(@as(u32, 1), selected.peek());
    if (debug_checks) try testing.expectEqual(@as(u32, 0), owner.debug.self_write_warnings);
}

test "debug: an effect writing a signal it read is reported" {
    if (!debug_checks) return;
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const a = try scope.createSignal(u32, 0);
    try scope.createEffect(.{ .a = a }, struct {
        fn run(c: anytype) void {
            if (c.a.get() < 1) c.a.set(1);
        }
    }.run);
    try testing.expect(owner.debug.self_write_warnings >= 1);
    try testing.expectEqual(@as(u32, 1), a.peek());
}

test "debug: recent writers are recorded" {
    if (!debug_checks) return;
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();
    const a = try scope.createSignal(u32, 0);
    a.set(1);
    a.set(2);
    const w = a.debugRecentWriters();
    try testing.expect(w[0] != 0 and w[1] != 0 and w[2] == 0);
}

test "OOM sweep: createText / watch / linked fail cleanly at every allocation" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const owner = try SignalOwner.init(testing.allocator);
        defer owner.deinit();
        const scope = Scope.init(failing.allocator(), null, owner) catch continue;
        const ok = blk: {
            const src = scope.createSignal(u32, 1) catch break :blk false;
            const text = scope.createText("hello", .{ .capacity = 8 }) catch break :blk false;
            text.set("a longer string than the initial capacity");
            var hits: u32 = 0;
            scope.watch(src, &hits, struct {
                fn f(h: *u32, _: u32, _: u32) void {
                    h.* += 1;
                }
            }.f) catch break :blk false;
            const l = scope.linked(u32, src, null) catch break :blk false;
            src.set(2);
            try testing.expectEqual(@as(u32, 2), l.peek());
            try testing.expectEqual(@as(u32, 1), hits);
            break :blk true;
        };
        scope.dispose();
        if (ok and !failing.has_induced_failure) break;
    }
    try testing.expect(fail_index > 4);
}

test "owner.untrack hides memo reads too, but nested effects still track" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const a = try scope.createSignal(u32, 1);
    const doubled = try scope.createMemo(u32, .{ .a = a }, struct {
        fn f(c: anytype) u32 {
            return c.a.get() * 2;
        }
    }.f);
    const inner_src = try scope.createSignal(u32, 0);
    const Counts = struct { outer: u32 = 0, inner: u32 = 0 };
    var counts = Counts{};
    const child = try scope.childScope();
    const Ctx = struct { doubled: *Memo(u32), inner_src: *Signal(u32), counts: *Counts, child: *Scope, owner: *SignalOwner };
    try scope.createEffect(Ctx{ .doubled = doubled, .inner_src = inner_src, .counts = &counts, .child = child, .owner = owner }, struct {
        fn run(c: Ctx) void {
            c.counts.outer += 1;
            c.owner.untrack(struct {
                fn body(cc: Ctx) void {
                    _ = cc.doubled.get(); // Should not become outer effect's dependency
                    if (cc.counts.outer == 1) {
                        // Effect created inside untrack must track normally
                        cc.child.createEffect(cc, struct {
                            fn inner(x: Ctx) void {
                                _ = x.inner_src.get();
                                x.counts.inner += 1;
                            }
                        }.inner) catch unreachable;
                    }
                }
            }.body, c);
        }
    }.run);
    try testing.expectEqual(@as(u32, 1), counts.outer);
    try testing.expectEqual(@as(u32, 1), counts.inner);
    a.set(5); // Memo changes: outer shouldn't rerun
    try testing.expectEqual(@as(u32, 1), counts.outer);
    // Memo computed first inside untrack; its dependency on `a` must still hold
    try testing.expectEqual(@as(u32, 10), doubled.peek());
    inner_src.set(1); // Inner effect dependencies still valid
    try testing.expectEqual(@as(u32, 2), counts.inner);
}

test "scope.watch on owned text: old stays valid across two writes in one batch and buffer growth" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const t = try scope.createText("a", .{});
    const Log = struct {
        old: [64]u8 = undefined,
        old_len: usize = 0,
        new: [64]u8 = undefined,
        new_len: usize = 0,
    };
    var log = Log{};
    try scope.watch(t, &log, struct {
        fn f(l: *Log, new: []const u8, old: []const u8) void {
            @memcpy(l.old[0..old.len], old);
            l.old_len = old.len;
            @memcpy(l.new[0..new.len], new);
            l.new_len = new.len;
        }
    }.f);
    owner.beginBatch();
    t.set("bb");
    t.set("a value long enough to force both text buffers to grow");
    owner.endBatch();
    try testing.expectEqualStrings("a", log.old[0..log.old_len]);
    try testing.expectEqualStrings("a value long enough to force both text buffers to grow", log.new[0..log.new_len]);
}

test "scope.linked on owned text keeps its own copy" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const src = try scope.createText("draft", .{});
    const local = try scope.linked([]const u8, src, null);
    try testing.expect(local.slice_store != null);
    local.set("edited");
    owner.beginBatch();
    src.set("x");
    src.set("a long upstream value that reallocates the source buffers");
    owner.endBatch();
    try testing.expectEqualStrings("a long upstream value that reallocates the source buffers", local.peek());
}

test "propose on owned text: split parent writing twice does not leave a dangling before-value" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const name = try scope.createText("ab", .{});
    const Parent = struct {
        name: *Signal([]const u8),
        fn write(self: *@This(), v: []const u8) void {
            self.name.set("x"); // First write
            self.name.set(v); // Second write: buffer holding `before` is overwritten/reallocated/freed
        }
    };
    var parent = Parent{ .name = name };
    const Probe = struct {
        calls: u32 = 0,
        fn changed(self: *@This(), _: []const u8) void {
            self.calls += 1;
        }
    };
    var probe = Probe{};
    const m = try resolveTextModel(scope, .{ .split = split(name, Callback([]const u8).from(Parent, &parent, Parent.write)) });
    m.propose("a value long enough to force both text buffers to reallocate", Callback([]const u8).from(Probe, &probe, Probe.changed));
    try testing.expectEqual(@as(u32, 1), probe.calls);
    m.propose("a value long enough to force both text buffers to reallocate", Callback([]const u8).from(Probe, &probe, Probe.changed));
    try testing.expectEqual(@as(u32, 1), probe.calls); // Settled value unchanged: doesn't trigger
}

test "memo returning a slice borrowed from owned text survives source buffer growth" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const t = try scope.createText("hello", .{});
    const first_word = try scope.createMemo([]const u8, .{ .t = t }, struct {
        fn f(c: anytype) []const u8 {
            const v = c.t.get();
            const end = std.mem.indexOfScalar(u8, v, ' ') orelse v.len;
            return v[0..end];
        }
    }.f);
    var runs: u32 = 0;
    try scope.createEffect(.{ .m = first_word, .runs = &runs }, struct {
        fn run(c: anytype) void {
            _ = c.m.get();
            c.runs.* += 1;
        }
    }.run);
    owner.beginBatch();
    t.set("x");
    t.set("hello there, this string forces both buffers to reallocate");
    owner.endBatch();
    // First word still "hello": memo value unchanged, downstream doesn't rerun; comparison must not
    // read freed old buffer
    try testing.expectEqualStrings("hello", first_word.peek());
    try testing.expectEqual(@as(u32, 1), runs);
}

test "resolveTextModel rejects a non-owning text signal in every build mode" {
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();
    const plain = try scope.createSignal([]const u8, "borrowed");
    try testing.expectError(error.TextModelNotOwned, resolveTextModel(scope, .{ .bound = plain }));
}

test "debug: split writing an unrelated signal is still reported as not landed" {
    if (!debug_checks) return;
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();

    const value = try scope.createSignal(u32, 1);
    const unrelated = try scope.createSignal(u32, 0);
    const Parent = struct {
        unrelated: *Signal(u32),
        fn write(self: *@This(), v: u32) void {
            self.unrelated.set(v); // Wrote different signal, doesn't land on `read`
        }
    };
    var parent = Parent{ .unrelated = unrelated };
    const m = try resolveModel(u32, scope, .{ .split = split(value, Callback(u32).from(Parent, &parent, Parent.write)) });
    m.propose(5, null);
    try testing.expectEqual(@as(u32, 1), owner.debug.split_unlanded_hints);
}

test "debug: a tracked read during mount outside an effect is reported, peek and effects are not" {
    if (!debug_checks) return;
    const owner = try SignalOwner.init(testing.allocator);
    defer owner.deinit();
    const scope = try Scope.init(testing.allocator, null, owner);
    defer scope.dispose();
    const a = try scope.createSignal(u32, 1);

    _ = a.get(); // Not in mount: no warning (reads in event handlers are legal)
    try testing.expectEqual(@as(u32, 0), owner.debug.mount_tracked_reads);

    owner.enterMount();
    defer owner.exitMount();
    _ = a.peek(); // Explicit snapshot
    try scope.createEffect(.{ .a = a }, struct {
        fn run(c: anytype) void {
            _ = c.a.get(); // In effect: tracks normally
        }
    }.run);
    try testing.expectEqual(@as(u32, 0), owner.debug.mount_tracked_reads);
    _ = a.get(); // Bare read in mount: value won't update
    try testing.expectEqual(@as(u32, 1), owner.debug.mount_tracked_reads);
}
