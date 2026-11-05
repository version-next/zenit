//! Preview-only template publication. Parsing and complete factory validation
//! precede any view allocation; all candidates precede the irreversible commit.
const std = @import("std");
const core = @import("core.zig");
const v = @import("view.zig");
const template = @import("template.zig");
/// Internal dev bridge, also used to exercise app-owned registrations.
pub const mount_effects = @import("preview_mount.zig");
const compiler = @import("zenit_environment").preview.yix;
const A = std.mem.Allocator;
const Op = compiler.PreviewOp;
pub const File = struct { path: []const u8, source: []const u8 };
pub const Entry = struct {
    module: []const u8,
    component: []const u8,
    source: []const u8,
    original: []const template.Instruction,
    active: ?[]const template.Instruction = null,
    current_ops: ?[]const Op = null,
    lower: *const fn (A, compiler.PreviewComponent, compiler.PreviewComponent) anyerror![]const template.Instruction,
    next: ?*Entry = null,
    registered: bool = false,
    region: bool = false,
};
var entries: ?*Entry = null;
var versions: ?*Preparation = null;
pub var generation: u64 = 0;
var publishing = false;
pub var commit_reentered = false;
pub var needs_remount = false;
pub var remount_reason: ?[]const u8 = null;
pub fn requestRemount(reason: []const u8) void {
    needs_remount = true;
    remount_reason = reason;
    std.log.warn("[preview] L3 required after template commit: {s}", .{reason});
}
pub fn rejectReentry() bool {
    if (!publishing) return false;
    commit_reentered = true;
    return true;
}
pub fn preparing() bool {
    return @import("preview_mount.zig").current != null;
}

pub fn lookup(comptime T: type, comptime meta: template.Metadata) !*Entry {
    const Holder = struct {
        var entry: Entry = .{
            .module = meta.module,
            .component = meta.path,
            .source = meta.source.?,
            .original = &template.Schema(T).instructions,
            .lower = struct {
                fn run(a: A, old: compiler.PreviewComponent, next: compiler.PreviewComponent) ![]const template.Instruction {
                    return lower(T, a, old, next);
                }
            }.run,
        };
    };
    const e = &Holder.entry;
    if (!e.registered) {
        if (preparing()) return error.TemplateCandidateSideEffects;
        var version = versions;
        version_loop: while (version) |p| : (version = p.next) {
            for (p.updates.items) |update| {
                if (!eq(update.entry.module, e.module) or !eq(update.entry.component, e.component)) continue;
                const a = p.arena.allocator();
                const before = (try compiler.compilePreview(a, e.module, e.source)).document;
                for (before.components) |component| if (eq(component.name, e.component)) {
                    e.active = if (opsEqual(component.ops, update.syntax)) e.original else try e.lower(a, component, .{ .name = e.component, .start = 0, .end = 0, .ops = update.syntax, .isolated = true });
                    e.current_ops = update.syntax;
                    break;
                };
                break :version_loop;
            }
        }
        e.next = entries;
        entries = e;
        e.registered = true;
        // Same module can have several concrete capture/receiver instantiations.
        // A new one requires L3 rather than borrowing another type's bindings.
    }
    return e;
}

pub fn lookupRegion(comptime T: type, comptime meta: template.Metadata, comptime region_name: []const u8) !*Entry {
    const Holder = struct {
        var entry: Entry = .{
            .module = meta.module,
            .component = region_name,
            .source = "",
            .region = true,
            .original = &template.Schema(T).instructions,
            .lower = struct {
                fn run(a: A, old: compiler.PreviewComponent, next: compiler.PreviewComponent) ![]const template.Instruction {
                    return lower(T, a, old, next);
                }
            }.run,
        };
    };
    const e = &Holder.entry;
    if (!e.registered) {
        if (preparing()) return error.TemplateUnregisteredRegion;
        e.source = findBaseline(meta.module) orelse return error.TemplateUnregisteredRegion;
        // A region first mounted after publication must use the same snapshot.
        if (versions) |latest| for (latest.files.items) |file| {
            if (!eq(file.path, meta.module)) continue;
            const a = latest.arena.allocator();
            const old = (try compiler.compilePreview(a, meta.module, e.source)).document;
            const next = (try compiler.compilePreview(a, meta.module, file.source)).document;
            for (old.regions) |before| if (eq(before.name, region_name)) {
                for (next.regions) |after| if (eq(after.name, region_name)) {
                    e.active = if (opsEqual(before.ops, after.ops)) e.original else try e.lower(a, before, after);
                    e.current_ops = after.ops;
                    break;
                };
                break;
            };
            break;
        };
        e.next = entries;
        entries = e;
        e.registered = true;
    }
    return e;
}

pub const Result = union(enum) {
    ready,
    fallback: struct { file: []const u8, reason: []const u8 },
    diagnostic: struct { file: []const u8, line: usize, message: []const u8 },
};
const Update = struct { entry: *Entry, ops: []const template.Instruction, syntax: []const Op, changed: bool };
const PublicationOwner = struct {
    cx: *core.Cx,
    lifetime: v.PreviewScopeWatch,
    root: v.PreviewRootSnapshot,
    retired: bool = false,
};
fn markCandidatesForRemount(candidates: []v.PreparedView) void {
    for (candidates) |*candidate| if (!candidate.lifetime.disposed) {
        candidate.instance.state = .needs_remount;
    };
}
/// Callback tails may dispose setup after commit returned. Resolve roots through
/// generation snapshots, never through an instance that may already be freed.
fn finishPublication(candidates: []v.PreparedView, owners: []PublicationOwner) bool {
    for (candidates) |*candidate| candidate.cancel();
    var cancelled = false;
    for (owners) |*owner| if (!owner.root.recordKnown(owner.cx.root)) {
        cancelled = true;
        markCandidatesForRemount(candidates);
        if (!needs_remount) requestRemount("ViewMountCancelled");
        if (owner.cx.root) |root| {
            owner.cx.root = null;
            owner.cx.content_root = null;
            owner.cx.popover_portal_root = null;
            v.discardPreviewRootWhileGuarded(owner.cx, root);
        }
        owner.retired = true;
    };
    // A callback may dispose an owned child scope without freeing its Node.
    // Every selected view in that owner must retire, while live setup survives.
    for (candidates) |candidate| if (candidate.scope_invalidated) {
        for (candidates) |*other| if (other.cx == candidate.cx) {
            other.scope_invalidated = true;
        };
    };
    // This boundary must drain deferred scope disposal BEFORE the fixed point:
    // its lifetime watches are updated by actual destruction, not a request.
    // Moving it below the loop would miss callback-tail owner/child disposal.
    // Contract: discard paths below MUST remain free of user callbacks (including
    // blur, unmount and detach). They can see already-disposed view contexts;
    // active-use protects Cx storage, not those contexts. Keep watches installed.
    for (owners) |owner| owner.cx.owner.endReactiveCallback();
    // Retiring one owner's tree can close another. Watches remain installed
    // through the fixed point; every owner/root is retired at most once.
    var progress = true;
    while (progress) {
        progress = false;
        for (owners) |*owner| {
            if (owner.retired) continue;
            var disposed = owner.lifetime.disposed;
            for (candidates) |candidate| if (candidate.cx == owner.cx and candidate.lifetime.disposed) {
                disposed = true;
            };
            const root_lost = owner.root.node != null and owner.root.resolve() == null;
            if (!disposed and !root_lost and owner.cx.root == owner.root.node) continue;
            owner.retired = true;
            progress = true;
            cancelled = true;
            markCandidatesForRemount(candidates);
            if (!needs_remount) requestRemount("ViewMountCancelled");
            owner.cx.content_root = null;
            owner.cx.popover_portal_root = null;
            owner.root.discard();
        }
        for (candidates) |*candidate| {
            if ((!candidate.lifetime.disposed and !candidate.scope_invalidated) or candidate.retired_disposed_roots) continue;
            candidate.retired_disposed_roots = true;
            cancelled = true;
            progress = true;
            candidate.abandonView();
        }
    }
    for (candidates) |*candidate| candidate.lifetime.release();
    for (owners) |*owner| owner.lifetime.release();
    for (owners) |owner| owner.cx.endActiveUse();
    return cancelled;
}

fn rankNodes(node: *core.Node, ranks: *std.AutoHashMap(*core.Node, usize)) !void {
    const ordinal = ranks.count();
    try ranks.put(node, ordinal);
    for (node.children.items) |child| try rankNodes(child, ranks);
}
fn scopeDepth(scope: *core.Scope) usize {
    var depth: usize = 0;
    var cursor = scope.parent;
    while (cursor) |parent| : (cursor = parent.parent) depth += 1;
    return depth;
}

pub const Preparation = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    result: Result = .ready,
    updates: std.ArrayList(Update) = .empty,
    committed: bool = false,
    base_generation: u64,
    files: std.ArrayList(File) = .empty,
    fail_after: ?usize = null,
    deadline: ?i96 = null,
    fail_commit_at: ?usize = null,
    next: ?*Preparation = null,

    pub fn deinit(self: *Preparation) void {
        std.debug.assert(!self.committed);
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }

    /// Owners are visited serially by the UI safe-point controller. No candidate
    /// escapes on error and no generation is consumed until every view commits.
    /// Success transfers ownership to the registry. Do not retain/dereference
    /// this Preparation across later publications: only two snapshots survive.
    pub fn apply(self: *Preparation, owners: []const *core.Cx) !usize {
        if (publishing) {
            commit_reentered = true;
            return error.TemplateReloadReentry;
        }
        if (needs_remount) return error.TemplateNeedsRemount;
        commit_reentered = false;
        if (self.result != .ready or self.committed) return error.TemplateReloadUnavailable;
        if (self.base_generation != generation) return error.TemplateStalePreparation;
        publishing = true;
        defer publishing = false;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var instances: std.ArrayList(*v.ComponentInstance) = .empty;
        for (owners, 0..) |cx, ci| {
            for (owners[0..ci]) |previous| if (previous == cx) return error.TemplateDuplicateOwner;
            const owner = cx.owner;
            owner.assertThread();
            if (cx.root_scope) |scope| if (scope.owner != owner) return error.TemplateOwnerMismatch;
            if (owner.graph.flushing or owner.reactive_callback_depth != 0 or cx.tick_depth != 0 or owner.scope_disposal_depth != 0 or owner.inReactiveComputation() or owner.draining_disposals or owner.draining_settled_tasks or cx.draining_deferred_frees) return error.ViewRebuildNeedsSafePoint;
            const first = instances.items.len;
            if (cx.root_scope) |scope| try v.collectTemplateInstances(scope, a, &instances);
            // Keyed reordering changes mount order without reordering the scope
            // ownership list. Commit by live tree preorder, with outer owners
            // first for promoted roots, rather than by scope creation order.
            var ranks = std.AutoHashMap(*core.Node, usize).init(a);
            if (cx.root) |root| try rankNodes(root, &ranks);
            for (instances.items[first..]) |instance| {
                const entry = instance.preview_template orelse continue;
                for (self.updates.items) |update| if (update.changed and update.entry == entry) {
                    const root = instance.parts.root orelse return error.TemplateDetachedInstance;
                    if (!ranks.contains(root)) return error.TemplateDetachedInstance;
                };
            }
            std.mem.sort(*v.ComponentInstance, instances.items[first..], &ranks, struct {
                fn less(map: *std.AutoHashMap(*core.Node, usize), x: *v.ComponentInstance, y: *v.ComponentInstance) bool {
                    const xr = if (x.parts.root) |root| map.get(root) orelse std.math.maxInt(usize) else std.math.maxInt(usize);
                    const yr = if (y.parts.root) |root| map.get(root) orelse std.math.maxInt(usize) else std.math.maxInt(usize);
                    if (xr != yr) return xr < yr;
                    return scopeDepth(x.setup) < scopeDepth(y.setup);
                }
            }.less);
        }
        for (instances.items, 0..) |instance, ii| {
            const identity = instance.preview_region_identity;
            if (identity.controller == null or identity.key == null) continue;
            for (instances.items[0..ii]) |previous| {
                const other = previous.preview_region_identity;
                if (instance.preview_template == previous.preview_template and identity.controller == other.controller and identity.key == other.key) return error.TemplateAmbiguousKey;
            }
        }
        const publications = try a.alloc(PublicationOwner, owners.len);
        for (publications, owners) |*publication, cx| publication.* = .{
            .cx = cx,
            .lifetime = .{ .scope = cx.root_scope },
            .root = try v.PreviewRootSnapshot.capture(cx, cx.root),
        };
        var candidates: std.ArrayList(v.PreparedView) = .empty;
        defer for (candidates.items) |*candidate| candidate.cancel();
        // Reserve before touching active descriptors or evaluating factories.
        try candidates.ensureTotalCapacity(a, instances.items.len);
        // Every selected ancestor must build its descendants against this same
        // batch, including a child module edited alongside its parent.
        const old_descriptors = try a.alloc(?[]const template.Instruction, self.updates.items.len);
        for (self.updates.items, old_descriptors) |update, *old| {
            old.* = update.entry.active;
            update.entry.active = update.ops;
        }
        defer if (!self.committed) {
            for (self.updates.items, old_descriptors) |update, old| update.entry.active = old;
        };
        instance_loop: for (instances.items) |instance| {
            // Parent-first collection: a selected ancestor owns this instance's
            // retirement. Never keep a second candidate pointing into that view.
            for (candidates.items) |candidate| {
                var ancestor: ?*core.Scope = instance.setup;
                while (ancestor) |scope| : (ancestor = scope.parent) if (scope == candidate.instance.view_scope and !candidate.retains(instance.setup)) continue :instance_loop;
            }
            const e = instance.preview_template orelse continue;
            for (self.updates.items) |update| if (update.entry == e and update.changed) {
                const candidate = try instance.prepareView();
                candidates.appendAssumeCapacity(candidate);
                break;
            };
        }
        if (self.fail_after) |n| if (candidates.items.len >= n) return error.TemplateInjectedFailure;
        if (self.deadline) |deadline| {
            if (owners.len == 0 or std.Io.Clock.awake.now(owners[0].io).nanoseconds >= deadline) return error.Timeout;
        }
        defer {
            for (candidates.items) |*candidate| candidate.lifetime.release();
            for (publications) |*publication| publication.lifetime.release();
        }
        for (candidates.items) |*candidate| try candidate.lifetime.install();
        for (publications) |*publication| try publication.lifetime.install();
        // All owners remain pinned through callbacks, including callbacks which
        // close another owner or reenter publication. Cancel before unpinning.
        for (owners) |cx| {
            cx.beginActiveUse();
            cx.owner.beginReactiveCallback();
        }
        var guarded = true;
        defer if (guarded) {
            _ = finishPublication(candidates.items, publications);
        };
        // From here on rollback is impossible. Retain descriptor storage even if
        // a callback fails; the launcher will snapshot persist state and use L3.
        self.committed = true;
        self.next = versions;
        versions = self;
        defer {
            // Every generation is a complete descriptor snapshot. Live views own
            // their borrowed literal data, so no reader can reference the retired
            // arenas after this UI safe-point commit.
            if (self.next) |previous| {
                var retired = previous.next;
                previous.next = null;
                while (retired) |p| {
                    retired = p.next;
                    p.committed = false;
                    p.deinit();
                }
            }
        }

        var commit_error: []const u8 = "TemplateCommitFailed";
        errdefer {
            markCandidatesForRemount(candidates.items);
            requestRemount(commit_error);
        }
        for (self.updates.items) |update| {
            update.entry.active = update.ops;
            update.entry.current_ops = update.syntax;
        }
        for (candidates.items) |*candidate| {
            candidate.transaction.fail_at = self.fail_commit_at;
            candidate.commit() catch |err| {
                commit_error = @errorName(err);
                return err;
            };
        }
        const cancelled = finishPublication(candidates.items, publications);
        guarded = false;
        if (cancelled or commit_reentered) {
            const err = if (commit_reentered) error.TemplateReloadReentry else error.ViewMountCancelled;
            commit_error = @errorName(err);
            return err;
        }
        generation += 1;
        return candidates.items.len;
    }
};

pub fn deinit() void {
    // Entries are static registrations and can be detached during a callback.
    // Publication still borrows Preparation arenas (including the apply receiver),
    // so retain those until a non-publishing deinit. Repeated calls may clear
    // registrations again, but must preserve the reentry signal for apply.
    if (publishing) commit_reentered = true;
    var cursor = entries;
    while (cursor) |entry| {
        cursor = entry.next;
        entry.active = null;
        entry.current_ops = null;
        entry.next = null;
        entry.registered = false;
    }
    entries = null;
    generation = 0;
    needs_remount = false;
    remount_reason = null;
    if (publishing) return;
    while (versions) |p| {
        versions = p.next;
        p.committed = false;
        p.deinit();
    }
    commit_reentered = false;
}

pub fn retainedVersionCount() usize {
    var n: usize = 0;
    var p = versions;
    while (p) |version| : (p = version.next) n += 1;
    return n;
}
pub fn retainedBytes() usize {
    var n: usize = 0;
    var p = versions;
    while (p) |version| : (p = version.next) n += version.arena.queryCapacity() + @sizeOf(Preparation);
    return n;
}

pub fn prepare(allocator: A, files: []const File) !*Preparation {
    const p = try allocator.create(Preparation);
    p.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .base_generation = generation };
    errdefer p.deinit();
    const a = p.arena.allocator();
    // Carry unchanged modules forward too. A latest snapshot must never borrow
    // descriptors or syntax from an arena more than one generation old.
    try p.files.appendSlice(a, files);
    if (versions) |latest| for (latest.files.items) |file| {
        var present = false;
        for (files) |input| if (eq(input.path, file.path)) {
            present = true;
        };
        if (!present) try p.files.append(a, file);
    };
    for (p.files.items, 0..) |*file, fi| {
        const path = try a.dupe(u8, file.path);
        for (p.files.items[0..fi]) |previous| if (eq(previous.path, path)) {
            p.result = .{ .fallback = .{ .file = path, .reason = "duplicate_file" } };
            return p;
        };
        const source = try a.dupe(u8, file.source);
        file.* = .{ .path = path, .source = source };
        const next = switch (try compiler.compilePreview(a, path, source)) {
            .diagnostic => |d| {
                var line: usize = 1;
                for (source[0..@min(d.offset, source.len)]) |c| if (c == '\n') {
                    line += 1;
                };
                p.result = .{ .diagnostic = .{ .file = path, .line = line, .message = d.message } };
                return p;
            },
            .document => |d| d,
        };
        for (next.regions, 0..) |region, ri| for (next.regions[0..ri]) |previous| if (eq(region.name, previous.name)) {
            p.result = .{ .fallback = .{ .file = path, .reason = "TemplateAmbiguousRegion" } };
            return p;
        };
        var registered = false;
        var cursor = entries;
        while (cursor) |entry| : (cursor = entry.next) {
            if (!eq(path, entry.module)) continue;
            registered = true;
            const old = switch (try compiler.compilePreview(a, path, entry.source)) {
                .document => |d| d,
                .diagnostic => return error.TemplateCompiledSourceInvalid,
            };
            // Authored embedded bytes can change capture types without changing
            // the initializer's tokens (including a self-embedded Yix file).
            if (std.mem.indexOf(u8, old.envelope, "@embedFile ") != null) {
                p.result = .{ .fallback = .{ .file = path, .reason = "template_embedded_dependency" } };
                return p;
            }
            if (!eq(old.envelope, next.envelope) or old.components.len != next.components.len) {
                p.result = .{ .fallback = .{ .file = path, .reason = "non_template_code" } };
                return p;
            }
            var found = false;
            const before_components = if (entry.region) old.regions else old.components;
            const after_components = if (entry.region) next.regions else next.components;
            if (before_components.len != after_components.len) {
                p.result = .{ .fallback = .{ .file = path, .reason = "TemplateRegionSetChanged" } };
                return p;
            }
            for (before_components, after_components) |before, after| {
                if (!eq(before.name, after.name)) {
                    p.result = .{ .fallback = .{ .file = path, .reason = "component_identity" } };
                    return p;
                }
                if (!eq(before.name, entry.component)) continue;
                found = true;
                const changed_ops = !opsEqual(entry.current_ops orelse before.ops, after.ops);
                const ops = (if (opsEqual(before.ops, after.ops)) entry.original else entry.lower(a, before, after)) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    p.result = .{ .fallback = .{ .file = path, .reason = @errorName(err) } };
                    return p;
                };
                try p.updates.append(a, .{ .entry = entry, .ops = ops, .syntax = after.ops, .changed = changed_ops });
            }
            if (!found) {
                p.result = .{ .fallback = .{ .file = path, .reason = "missing_component" } };
                return p;
            }
        }
        if (!registered) {
            p.result = .{ .fallback = .{ .file = path, .reason = "unregistered_file" } };
            return p;
        }
        // Every changed component needs a compiled descriptor, including components
        // not currently mounted. Otherwise a later mount could silently show A.
        const baseline = findBaseline(path).?;
        const old = (try compiler.compilePreview(a, path, baseline)).document;
        for (old.components, next.components) |before, after| {
            if (opsEqual(before.ops, after.ops)) continue;
            var covered = false;
            var e = entries;
            while (e) |entry| : (e = entry.next) if (!entry.region and eq(entry.module, path) and eq(entry.component, before.name)) {
                covered = true;
            };
            if (!covered) {
                p.result = .{ .fallback = .{ .file = path, .reason = try std.fmt.allocPrint(a, "unregistered_component:{s}", .{before.name}) } };
                return p;
            }
        }
        if (old.regions.len != next.regions.len) {
            p.result = .{ .fallback = .{ .file = path, .reason = "TemplateRegionSetChanged" } };
            return p;
        }
        for (old.regions, next.regions) |before, after| {
            if (!eq(before.name, after.name) or !eq(before.key_tokens, after.key_tokens)) {
                p.result = .{ .fallback = .{ .file = path, .reason = "TemplateRegionIdentityChanged" } };
                return p;
            }
            if (opsEqual(before.ops, after.ops)) continue;
            var covered = false;
            var e = entries;
            while (e) |entry| : (e = entry.next) if (entry.region and eq(entry.module, path) and eq(entry.component, before.name)) {
                covered = true;
            };
            if (!covered) {
                p.result = .{ .fallback = .{ .file = path, .reason = "TemplateUnregisteredRegion" } };
                return p;
            }
        }
    }
    return p;
}
fn findBaseline(path: []const u8) ?[]const u8 {
    var e = entries;
    while (e) |entry| : (e = entry.next) if (eq(entry.module, path)) return entry.source;
    return null;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    return if (a) |x| eq(x, b.?) else true;
}
fn opEqual(a: Op, b: Op) bool {
    if (a.kind != b.kind or !eq(a.path, b.path) or !eq(a.receiver, b.receiver) or !eq(a.identity_tokens orelse a.tokens, b.identity_tokens orelse b.tokens) or !optionalEqual(a.literal, b.literal) or a.attributes.len != b.attributes.len or !capturesEqual(a.fragments, b.fragments) or !capturesEqual(a.captures, b.captures)) return false;
    for (a.attributes, b.attributes) |x, y| if (!eq(x.name, y.name) or x.slot != y.slot or (!x.slot and (!eq(x.value, y.value) or x.literal != y.literal))) return false;
    return true;
}
fn opsEqual(a: []const Op, b: []const Op) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!opEqual(x, y)) return false;
    return true;
}
fn capturesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eq(x, y)) return false;
    return true;
}
fn syntaxIdentity(a: Op, b: Op) bool {
    return a.kind == b.kind and eq(a.path, b.path) and eq(a.receiver, b.receiver) and eq(a.identity_tokens orelse a.tokens, b.identity_tokens orelse b.tokens) and capturesEqual(a.captures, b.captures);
}
fn decodeText(a: A, value: []const u8) ![]const u8 {
    return std.zig.string_literal.parseAlloc(a, std.mem.trim(u8, value, " \t\r\n")) catch return error.TemplateLiteralUnsupported;
}
fn literal(comptime T: type, op: Op) !bool {
    if (op.kind == .close) return true;
    if ((op.kind == .text or eq(op.receiver, "text")) and op.literal != null and op.attributes.len == 0) return true;
    if (op.kind != .element) return false;
    for (op.attributes) |attribute| {
        const name = attribute.name;
        const value = std.mem.trim(u8, attribute.value, " \t\r\n");
        if (eq(name, "style")) {
            if (catalogSlot(T, attribute.value) == null and styleSlot(T, attribute.value) == null and template.literalStyle(attribute.value) == null) return false;
        } else if (eq(name, "test_id")) {
            if (value.len < 2 or value[0] != '"') return false;
        } else if (eq(name, "visible") or eq(name, "focusable") or eq(name, "hit_test")) {
            if (!eq(value, "true") and !eq(value, "false")) return false;
        } else return false;
    }
    return true;
}
fn catalogSlot(comptime T: type, tokens: []const u8) ?u32 {
    inline for (comptime template.catalogStyles(T), 0..) |style, index| if (eq(std.mem.trim(u8, tokens, " "), std.mem.trim(u8, style.tokens, " "))) return @intCast(index);
    return null;
}
fn styleSlot(comptime T: type, tokens: []const u8) ?u32 {
    for (template.Schema(T).entries, 0..) |entry, index| if (entry.style_factory) |style| {
        if (eq(tokens, style.tokens)) return @intCast(index);
    };
    return null;
}
const OpaquePosition = struct { slots: [template.max_depth + 1]usize = @splat(0), depth: usize = 0 };
fn opaquePosition(ops: []const Op, target: usize) OpaquePosition {
    var out: OpaquePosition = .{};
    for (ops, 0..) |op, index| {
        if (op.kind == .close) {
            out.depth -= 1;
            continue;
        }
        out.slots[out.depth] += 1;
        if (index == target) return out;
        if (op.kind == .element) {
            out.depth += 1;
            out.slots[out.depth] = 0;
        }
    }
    unreachable;
}
fn sameOpaquePosition(before: []const Op, bi: usize, after: []const Op, ai: usize) bool {
    const x = opaquePosition(before, bi);
    const y = opaquePosition(after, ai);
    return x.depth == y.depth and std.mem.eql(usize, x.slots[0 .. x.depth + 1], y.slots[0 .. y.depth + 1]);
}

fn lower(comptime T: type, a: A, old: compiler.PreviewComponent, next: compiler.PreviewComponent) ![]const template.Instruction {
    if (!old.isolated or !next.isolated) return error.TemplateSlotOrViewHook;
    const original = template.Schema(T).instructions;
    if (old.region) for (original) |instruction| {
        // Updating an outer body must not silently recreate a nested controller
        // and lose its keyed rows. Its own independently registered body can
        // still update without rebuilding this region.
        if (eq(instruction.element, "control")) return error.TemplateNestedController;
    };
    if (old.ops.len != original.len) return error.TemplateSchemaDrift;
    var used = try a.alloc(bool, original.len);
    @memset(used, false);
    var out: std.ArrayList(template.Instruction) = .empty;
    var routed: std.ArrayList(template.Hole) = .empty;
    for (next.ops, 0..) |op, syntax_index| {
        if (try literal(T, op)) {
            if (op.kind == .close) {
                try out.append(a, .{ .kind = .close });
            } else if (op.literal) |text| {
                try out.append(a, .{ .kind = .literal_emit, .element = "text", .literal_text = try decodeText(a, text) });
            } else {
                var catalog_style: ?u32 = null;
                var container: template.LiteralContainer = .{ .layout = std.meta.stringToEnum(@FieldType(template.LiteralContainer, "layout"), op.receiver) orelse return error.TemplateContainerUnsupported };
                for (op.attributes) |attribute| {
                    const value = std.mem.trim(u8, attribute.value, " \t\r\n");
                    if (eq(attribute.name, "style")) {
                        catalog_style = catalogSlot(T, attribute.value);
                        container.style_slot = if (catalog_style == null) styleSlot(T, attribute.value) else null;
                        if (container.style_slot == null and catalog_style == null) container.style = template.literalStyle(attribute.value) orelse return error.TemplateLiteralUnsupported;
                    } else if (eq(attribute.name, "test_id")) container.test_id = try decodeText(a, value) else if (eq(attribute.name, "visible")) container.visible = eq(value, "true") else if (eq(attribute.name, "focusable")) container.focusable = eq(value, "true") else if (eq(attribute.name, "hit_test")) container.hit_test = eq(value, "true");
                }
                try out.append(a, .{ .kind = .literal_open, .element = op.receiver, .container = container, .catalog_style = catalog_style });
            }
            continue;
        }
        // Host expression calls remain conservative. Component/control factories
        // carry compiled proofs and runtime guards before entering user setup.
        if ((eq(op.receiver, "box") or eq(op.receiver, "row") or eq(op.receiver, "col") or eq(op.receiver, "text")) and std.mem.indexOfScalar(u8, op.tokens, '(') != null) return error.TemplateCandidateSideEffects;
        var match: ?usize = null;
        for (old.ops, original, 0..) |before, compiled, index| {
            if (!syntaxIdentity(before, op) or compiled.kind == .literal_open or compiled.kind == .literal_emit or compiled.kind == .close) continue;
            if (used[index]) continue;
            if (match != null) return error.TemplateAmbiguousHole;
            match = index;
        }
        const index = match orelse return error.TemplateHoleChanged;
        const compiled = original[index];
        const is_opaque = !eq(op.receiver, "box") and !eq(op.receiver, "row") and !eq(op.receiver, "col") and !eq(op.receiver, "text");
        const moved = is_opaque and !sameOpaquePosition(old.ops, index, next.ops, syntax_index);
        if (moved and !template.relocatableHole(template.Schema(T).entries[index].factory.?.hole, compiled.attributes)) return error.TemplateChildRelocation;
        if (!template.Schema(T).entries[index].preview_isolated) return error.TemplateCandidateSideEffects;
        const hole = template.Schema(T).entries[index].factory.?.hole;
        // Full descriptor identity remains compiled. Syntax, module and envelope
        // equality prove its captures/types/edges cannot have changed in this edit.
        if (!eq(hole.path, op.path) or !eq(hole.receiver.name, op.receiver) or !eq(hole.tokens, old.ops[index].tokens) or compiled.abi != template.fingerprint(hole)) return error.TemplateHoleChanged;
        try routed.append(a, hole);
        used[index] = true;
        var instruction = compiled;
        instruction.relocate = moved;
        if (op.literal) |text| instruction.literal_text = try decodeText(a, text);
        instruction.fragments = op.fragments;
        if (!eq(op.receiver, "box") and !eq(op.receiver, "row") and !eq(op.receiver, "col") and !eq(op.receiver, "text")) {
            try out.append(a, instruction);
            continue;
        }
        const attributes = try a.dupe(template.Attribute, compiled.attributes);
        if (attributes.len != op.attributes.len) return error.TemplateHoleChanged;
        for (attributes, op.attributes) |*attribute, syntax| {
            if (!eq(attribute.name, syntax.name)) return error.TemplateHoleChanged;
            if (eq(attribute.name, "style")) {
                instruction.catalog_style = catalogSlot(T, syntax.value);
                if (instruction.catalog_style == null) {
                    if (eq(op.receiver, "text")) return error.TemplateTextInlineStyleUnsupported;
                    instruction.inline_style = template.literalStyle(syntax.value) orelse return error.TemplateStyleNotInCatalog;
                }
                attribute.tokens = syntax.value;
            } else if (syntax.literal and attribute.literal != null) {
                attribute.tokens = syntax.value;
                attribute.literal = switch (attribute.literal.?) {
                    .text => .{ .text = try decodeText(a, syntax.value) },
                    .boolean => if (eq(std.mem.trim(u8, syntax.value, " "), "true")) .{ .boolean = true } else if (eq(std.mem.trim(u8, syntax.value, " "), "false")) .{ .boolean = false } else return error.TemplateLiteralUnsupported,
                    else => return error.TemplateLiteralUnsupported,
                };
            } else if (!eq(attribute.tokens, syntax.value) or syntax.literal != (attribute.literal != null)) return error.TemplateHoleChanged;
        }
        instruction.attributes = attributes;
        try out.append(a, instruction);
    }
    for (original, used) |op, seen| if ((op.kind == .open or op.kind == .emit) and !seen) return error.TemplateHoleChanged;
    // Only validate a unique multiset bijection here. Emission already uses
    // routed holes; no positional mapping is needed after this check.
    const mapping = try template.matchHoles(a, &template.Schema(T).holes, routed.items);
    a.free(mapping);
    try template.validate(T, out.items);
    return out.items;
}
