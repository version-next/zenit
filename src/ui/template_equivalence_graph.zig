//! Test-only ownership and subscription projection. Raw graph slot/generation
//! allocation is mapped to scope preorder + kind/order within its owning scope.
const std = @import("std");
const ui = @import("ui.zig");
const Graph = @import("reactive/graph.zig");
const t = std.testing;

const Entry = struct { raw: u32, scope: usize };
const Projection = struct { scopes: u64, subscriptions: u64 };

fn service(cx: *ui.Cx, raw: u32) ?u64 {
    if (cx.theme_signal) |s| if (s.base.graph_node_raw == raw) return std.math.maxInt(u64) - 1;
    if (cx.a11y_prefs_signal) |s| if (s.base.graph_node_raw == raw) return std.math.maxInt(u64) - 2;
    if (comptime @TypeOf(cx.style_signal) != void) if (cx.style_signal) |s| if (s.base.graph_node_raw == raw) return std.math.maxInt(u64) - 3;
    return null;
}

fn generation(cx: *ui.Cx, raw: u32) bool {
    if (comptime @TypeOf(cx.style_signal) != void) if (cx.style_signal) |s| return s.base.graph_node_raw == raw;
    return false;
}

// Only an explicitly tagged replacement for a release theme replay is
// infrastructure, and only while it reads exclusively theme/generation.
// A tagged effect capturing even one business signal fails; ordinary effects
// remain in the graph projection.
// Preference observers, empty effects and unknown dependencies never disappear.
fn styleObserver(cx: *ui.Cx, node: Graph.GraphNode) !bool {
    if (!node.test_preview_style_infrastructure) return false;
    if (node.kind != .effect or node.sources.items.len == 0) return error.ProjectionInvalidPreviewStyleObserver;
    var watches_generation = false;
    for (node.sources.items) |source| {
        const raw: u32 = @bitCast(source);
        if (generation(cx, raw)) {
            watches_generation = true;
            continue;
        }
        if (cx.theme_signal) |s| if (s.base.graph_node_raw == raw) continue;
        return error.ProjectionPreviewStyleCapturedBusinessSignal;
    }
    if (!watches_generation) return error.ProjectionInvalidPreviewStyleObserver;
    return true;
}

fn add(cx: *ui.Cx, entries: *std.ArrayList(Entry), raw: u32, scope: usize, kind: Graph.NodeKind) !bool {
    if (service(cx, raw) != null) return false;
    const node = cx.owner.graph.getNode(@bitCast(raw)) orelse return error.ProjectionDeadOwnedGraphNode;
    if (node.kind != kind) return error.ProjectionOwnedGraphKindMismatch;
    if (try styleObserver(cx, node.*)) return false;
    for (entries.items) |entry| if (entry.raw == raw) return error.ProjectionGraphNodeOwnedTwice;
    try entries.append(t.allocator, .{ .raw = raw, .scope = scope });
    return true;
}

fn validateScope(cx: *ui.Cx, scope: *ui.Scope) !void {
    if (scope.owner != cx.owner) return error.ProjectionForeignScopeOwner;
    for (scope.children.items) |child| if (child.parent != scope) return error.ProjectionScopeParentMismatch;
}

fn regionView(cx: *ui.Cx, scope: *ui.Scope) !void {
    if (scope.test_preview_boundary != .region_view) return error.ProjectionInvalidPreviewBoundary;
    const instance = ui.view.templateInstanceForScope(scope) orelse return error.ProjectionInvalidPreviewBoundary;
    if (!instance.template_region or instance.cx != cx or instance.setup != scope.parent or instance.parts.root == null)
        return error.ProjectionInvalidPreviewBoundary;
    const entry = instance.preview_template orelse return error.ProjectionInvalidPreviewBoundary;
    if (!entry.registered or !entry.region) return error.ProjectionInvalidPreviewBoundary;
    const slot = std.mem.indexOf(u8, entry.component, "/slot:") != null;
    const branch = std.mem.indexOf(u8, entry.component, "/keyword_") != null;
    if (instance.setup.test_preview_boundary == .slot_setup) {
        if (!slot) return error.ProjectionInvalidPreviewBoundary;
    } else if (!branch) return error.ProjectionInvalidPreviewBoundary;
}

// Exact creation provenance is required. In particular, an empty ordinary
// scope, or a scope with one child, never becomes transparent by inference.
fn transparent(cx: *ui.Cx, scope: *ui.Scope) !bool {
    try validateScope(cx, scope);
    if (scope.test_preview_boundary == .none) return false;
    if (comptime !@import("zenit_environment").dev_preview) return error.ProjectionReleasePreviewBoundary;
    switch (scope.test_preview_boundary) {
        .none => unreachable,
        .region_view => try regionView(cx, scope),
        .slot_setup => {
            if (scope.parent == null or scope.children.items.len != 1 or scope.signals.items.len != 0 or scope.effects.items.len != 0 or scope.context_count != 0)
                return error.ProjectionInvalidPreviewBoundary;
            for (scope.resources.items) |resource| if (resource.test_graph_node_raw != null) return error.ProjectionInvalidPreviewBoundary;
            const child = scope.children.items[0];
            try validateScope(cx, child);
            try regionView(cx, child);
        },
    }
    return true;
}

// A logical scope consists of its original physical scope and only the
// explicitly authorized dev wrappers. Graph nodes are retained, not erased;
// their owner is the nearest ordinary scope. Normal children retain preorder.
fn expand(cx: *ui.Cx, scope: *ui.Scope, members: *std.ArrayList(*ui.Scope), children: *std.ArrayList(*ui.Scope)) !void {
    try members.append(t.allocator, scope);
    for (scope.children.items) |child| {
        if (try transparent(cx, child)) {
            try expand(cx, child, members, children);
        } else try children.append(t.allocator, child);
    }
}

fn walk(comptime Hash: type, cx: *ui.Cx, scope: *ui.Scope, entries: *std.ArrayList(Entry), hash: *Hash, ordinal: *usize) !void {
    if (try transparent(cx, scope)) return error.ProjectionInvalidPreviewBoundary;
    var members: std.ArrayList(*ui.Scope) = .empty;
    defer members.deinit(t.allocator);
    var children: std.ArrayList(*ui.Scope) = .empty;
    defer children.deinit(t.allocator);
    try expand(cx, scope, &members, &children);
    const id = ordinal.*;
    ordinal.* += 1;
    hash.feed("scope-open");
    hash.feed(children.items.len);
    var signals: usize = 0;
    var memos: usize = 0;
    var effects: usize = 0;
    // Group by kind across all members before assigning logical graph IDs,
    // matching the original single scope's signal/memo/effect inventory order.
    for (members.items) |member| for (member.signals.items) |s| {
        signals += @intFromBool(try add(cx, entries, s.graph_node_raw, id, .signal));
    };
    for (members.items) |member| for (member.resources.items) |r| {
        if (r.test_graph_node_raw) |raw| memos += @intFromBool(try add(cx, entries, raw, id, .memo));
    };
    for (members.items) |member| for (member.effects.items) |e| {
        effects += @intFromBool(try add(cx, entries, e.graph_node_raw, id, .effect));
    };
    hash.feed(signals);
    hash.feed(memos);
    hash.feed(effects);
    for (children.items) |child| try walk(Hash, cx, child, entries, hash, ordinal);
    hash.feed("scope-close");
}

fn logical(cx: *ui.Cx, entries: []const Entry, raw: u32) !u64 {
    if (service(cx, raw)) |id| return id;
    for (entries, 0..) |entry, index| if (entry.raw == raw) return @intCast(index);
    return error.ProjectionUnownedGraphNode;
}

fn edges(comptime Hash: type, cx: *ui.Cx, entries: []const Entry, ids: []const Graph.NodeId, hash: *Hash) !void {
    var mapped: std.ArrayList(u64) = .empty;
    defer mapped.deinit(t.allocator);
    for (ids) |id| {
        const raw: u32 = @bitCast(id);
        if (generation(cx, raw)) continue;
        const node = cx.owner.graph.getNode(id) orelse return error.ProjectionDeadGraphEdge;
        if (try styleObserver(cx, node.*)) continue;
        try mapped.append(t.allocator, try logical(cx, entries, raw));
    }
    std.mem.sort(u64, mapped.items, {}, std.sort.asc(u64));
    hash.feed(mapped.items);
}

pub fn snapshot(comptime Hash: type, cx: *ui.Cx, scope: *ui.Scope) !Projection {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(t.allocator);
    var scopes = Hash{};
    var subscriptions = Hash{};
    var ordinal: usize = 0;
    try walk(Hash, cx, scope, &entries, &scopes, &ordinal);
    // Inventory is exhaustive, including disconnected graph nodes. A leaked or
    // incorrectly owned node must not vanish just because it has no observers.
    for (cx.owner.graph.nodes.items, 0..) |node, i| {
        if (!node.alive or try styleObserver(cx, node)) continue;
        const raw: u32 = @bitCast(Graph.NodeId{ .index = @intCast(i), .generation = cx.owner.graph.generations.items[i] });
        _ = try logical(cx, entries.items, raw);
    }
    for (entries.items) |entry| {
        const node = cx.owner.graph.getNode(@bitCast(entry.raw)).?;
        subscriptions.feed(entry.scope);
        subscriptions.feed(node.kind);
        try edges(Hash, cx, entries.items, node.sources.items, &subscriptions);
        try edges(Hash, cx, entries.items, node.observers.items, &subscriptions);
    }
    return .{ .scopes = scopes.finish(), .subscriptions = subscriptions.finish() };
}
