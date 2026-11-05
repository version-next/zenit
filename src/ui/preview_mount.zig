//! Dev-only mount transaction. The normal path runs the very same callback at
//! the same call site; only a candidate delays it until after root publication.
const std = @import("std");
const Scope = @import("reactive.zig").Scope;
const enabled = @import("zenit_environment").dev_preview;
pub const Kind = enum { mount, ref, portal, effect, cleanup, timer, subscription, registration };
pub var current: if (enabled) ?*Transaction else void = if (enabled) null else {};

pub var committing: if (enabled) ?*Transaction else void = if (enabled) null else {};
pub fn reportFailure(err: anyerror) bool {
    if (comptime !enabled) return false;
    const tx = current orelse committing orelse return false;
    tx.failure = err;
    return true;
}
pub const Transaction = struct {
    failure: ?anyerror = null,
    source_scope: ?*Scope = null,
    retain_children: bool = false,
    promotions: std.ArrayList(*@import("view.zig").ComponentInstance) = .empty,
    relocations: std.ArrayList(*@import("view.zig").TemplateChildMove) = .empty,
    attachment_replays: std.ArrayList(*@import("view.zig").AttachmentReplay) = .empty,
    arena: std.heap.ArenaAllocator,
    actions: std.ArrayList(*Action) = .empty,
    // Injection is exercised by the same commit loop as real callback errors.
    fail_at: ?usize = null,
    pub const Action = struct {
        scope: *Scope,
        active: bool = true,
        kind: Kind,
        context: *anyopaque,
        call: *const fn (*Action) anyerror!void,
        fn clear(self: *@This()) void {
            self.active = false;
        }
    };
    pub fn init(a: std.mem.Allocator) Transaction {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Transaction) void {
        // Markers must never survive their arena. Inactive scopes have already
        // removed them during disposal; active ones are still guarded by owner.
        for (self.actions.items) |action| if (action.active) {
            const cleanups = &action.scope.cleanups;
            for (cleanups.items, 0..) |cleanup, index| if (cleanup.ctx == @as(*anyopaque, @ptrCast(action))) {
                _ = cleanups.orderedRemove(index);
                break;
            };
        };
        self.arena.deinit();
    }
    pub fn run(self: *Transaction) !void {
        const previous = committing;
        std.debug.assert(previous == null or previous == self);
        committing = self;
        defer committing = previous;
        for (self.actions.items, 0..) |action, index| {
            if (!action.active) continue;
            if (action.scope.willBeDisposedAfterReactiveCallback()) return error.ViewMountCancelled;
            if (self.fail_at == index) return error.TemplateCommitInjectedFailure;
            const queued = action.scope.owner.deferred_disposals.tail;
            const errors = @import("on.zig").handler_error_count;
            const tracking = @import("reactive/graph.zig").reactive_tracking_failures;
            try action.call(action);
            if (self.failure) |err| return err;
            if (@import("on.zig").handler_error_count != errors) return error.TemplateCommitCallbackFailed;
            if (@import("reactive/graph.zig").reactive_tracking_failures != tracking) return error.OutOfMemory;
            if (!action.active or action.scope.willBeDisposedAfterReactiveCallback() or action.scope.owner.deferred_disposals.tail != queued) return error.ViewMountCancelled;
        }
    }
};

/// Returns true only when the operation was queued. The context is copied and
/// scope disposal cancels its action without invoking application callbacks.
pub fn deferAction(scope: *Scope, kind: Kind, context: anytype, comptime call: anytype) !bool {
    if (comptime !enabled) return false;
    const tx = current orelse return false;
    const a = tx.arena.allocator();
    const C = @TypeOf(context);
    const saved = try a.create(C);
    saved.* = context;
    const action = try a.create(Transaction.Action);
    action.* = .{ .scope = scope, .kind = kind, .context = @ptrCast(saved), .call = struct {
        fn run(entry: *Transaction.Action) anyerror!void {
            const ctx: *C = @ptrCast(@alignCast(entry.context));
            try call(ctx.*, entry.scope);
        }
    }.run };
    // Append before registering the marker: onCleanup failure leaves an inactive
    // entry, never an untracked pointer into an already freed scope.
    try tx.actions.append(a, action);
    action.active = false;
    try scope.onCleanup(Transaction.Action, action, Transaction.Action.clear);
    action.active = true;
    return true;
}
