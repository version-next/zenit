/// GlassGroup / GlassShape: Liquid Glass container primitives (docs/LIQUID_GLASS_DESIGN.md Section
/// 3).
///
/// SwiftUI: `GlassEffectContainer(spacing:)` <-> GlassGroup; `.glassEffect` + `glassEffectID` +
/// `Glass.tint/.interactive` <-> GlassShape.
/// M2 (current): the container holds one absolute full-fill glass surface; members (GlassBox member
/// mode) write geometry/material to its shape table.
/// Render samples the background once per container rect and composites N shapes (shader takes
/// nearest shape, blur bank takes member 0). M3+: SDF smooth union (spacing = union radius).
/// Member drop shadows stay on the member root (drawn only outside the shape).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const glass_box = @import("../glass_box/mod.zig");
const types = @import("../../core/types.zig");

pub const GlassBoxShape = glass_box.GlassBoxShape;
pub const GlassEffectStyle = glass_box.GlassEffectStyle;
pub const ScrollEdgeBinding = glass_box.ScrollEdgeBinding;
pub const AdaptiveGlassBoxState = glass_box.AdaptiveGlassBoxState;

/// Container brightness family choice. `.automatic` = by appearance (large element) / by background
/// brightness flip (small element, M5).
pub const GlassScheme = enum { automatic, light, dark };

pub const GlassTransition = glass_box.GlassTransition;
pub const GlassMergeMode = glass_box.GlassMergeMode;

pub const max_shapes: usize = 8;

pub const GlassGroupProps = struct {
    /// `NSGlassEffectContainerView.spacing` / `GlassEffectContainer(spacing:)`: the proximity
    /// (logical px) at which member glass starts merging. Native default 0 (measured:
    /// `NSGlassEffectContainerView().spacing == 0`): members are batched but do not merge.
    spacing: f32 = 0,
    /// When merge takes effect: default only during transition (see GlassMergeMode).
    merge: GlassMergeMode = .transitions,
    scheme: GlassScheme = .automatic,
    /// Container-level scroll-edge: auto-applies to each member after mount.
    scroll_edge: ?ScrollEdgeBinding = null,
    width: ?f32 = null,
    height: ?f32 = null,
    direction: core.Direction = .row,
    gap: f32 = 12,
    padding: ?Padding = null,
};

pub const GlassShapeProps = struct {
    shape: GlassBoxShape = .capsule,
    /// `NSGlassEffectView.style` (see GlassBoxProps.glass_style).
    glass_style: GlassEffectStyle = .regular,
    /// Platform rendering profile; null = `Cx.glass_idiom` (see GlassBoxProps.idiom).
    idiom: ?glass_box.GlassIdiom = null,
    /// `NSGlassEffectView.tintColor`; alpha is the tint amount (see GlassBoxProps.tint_color).
    tint_color: ?Color = null,
    interactive: bool = false,
    press_feedback: glass_box.GlassPressFeedback = .none,
    /// glassEffectUnion(id:): same id members at rest composite into one shape (envelope).
    union_id: ?[]const u8 = null,
    enabled: bool = true,
    /// `glassEffectID`: same id shapes within container morph between layouts (M4).
    id: ?[]const u8 = null,
    transition: GlassTransition = .materialize,
    width: ?f32 = null,
    height: ?f32 = null,
    padding: ?Padding = null,
    body_gap: f32 = 12,
    title: reactive.Source([]const u8) = .{ .value = "" },
    subtitle: reactive.Source([]const u8) = .{ .value = "" },
};

pub const GlassShapeEntry = struct {
    node: *Node,
    body: *Node,
    state: *AdaptiveGlassBoxState,
    id: ?[]const u8,
    transition: GlassTransition,
};

pub const GlassGroupState = struct {
    allocator: Allocator,
    container: *Node,
    /// Container glass surface (absolute full-fill; holds member 0 material + shape table pointer)
    surface: *Node,
    /// Member shape table (address stable; render side reads via ext.glass.group pointer)
    table: types.GlassGroupShapes = .{},
    /// Independently allocated: member cleanup may outlive this state destruction (see
    /// GlassGroupLink.alive)
    link: *glass_box.GlassGroupLink,
    spacing: f32,
    scheme: GlassScheme,
    scroll_edge: ?ScrollEdgeBinding,
    shapes: [max_shapes]?GlassShapeEntry = @splat(null),
    shape_count: usize = 0,

    pub fn register(self: *GlassGroupState, entry: GlassShapeEntry) !void {
        if (self.shape_count >= max_shapes) return error.GlassGroupFull;
        self.shapes[self.shape_count] = entry;
        self.shape_count += 1;
    }

    pub fn find(self: *GlassGroupState, id: []const u8) ?*GlassShapeEntry {
        for (self.shapes[0..self.shape_count]) |*slot| {
            if (slot.*) |*entry| if (entry.id) |eid| if (std.mem.eql(u8, eid, id)) return entry;
        }
        return null;
    }
};

/// Member target geometry in one GlassGroup transaction (container-local {x, y, w, h}).
pub const GlassMove = struct { entry: GlassShapeEntry, rect: [4]f32 };

/// Corresponds to SwiftUI `withAnimation { state change }`: member movement + add/remove elements
/// with glassEffectID.
pub const GlassTransaction = struct {
    /// Retain member's new layout (.smooth spring morph)
    moves: []const GlassMove = &.{},
    /// Inserted member and its final rect (member must be mounted in container, hidden state)
    inserts: []const GlassMove = &.{},
    /// Removed member (hidden after wrap-up)
    removes: []const GlassShapeEntry = &.{},
    /// Default withAnimation measured equivalent to .smooth(duration: 0.5)
    duration_ms: f64 = 500,
};

fn rectGap(a: [4]f32, b: [4]f32) f32 {
    const dx = @max(@max(a[0] - (b[0] + b[2]), b[0] - (a[0] + a[2])), 0);
    const dy = @max(@max(a[1] - (b[1] + b[3]), b[1] - (a[1] + a[3])), 0);
    return @sqrt(dx * dx + dy * dy);
}

fn inEntries(list: []const GlassShapeEntry, st: *AdaptiveGlassBoxState) bool {
    for (list) |e| if (e.state == st) return true;
    return false;
}
fn inMoves(list: []const GlassMove, st: *AdaptiveGlassBoxState) bool {
    for (list) |m| if (m.entry.state == st) return true;
    return false;
}

/// Apple expand/collapse semantics (measured natively per frame, see glass_box matched note):
/// - Inserted element whose final rect connects via spacing to a retained element's
///   **pre-animation** rect (chains through other inserted ones allowed) grows from that element's
///   matched geometry; else fades in (materialize).
/// - Removed element whose **current** rect connects via spacing to a retained element (chains
///   allowed) is sucked back into it; else fades out. Source element pulses along the measured
///   curve.
/// - Mid-reverse: a matched-inserted element then removed sucks back to its source (don't re-judge
///   by current gap: it just left the source, and a gap slightly over spacing would read as
///   fade-out); a sucked-back element inserted again springs from its current rect to target, not
///   re-growing from the anchor.
///   Native flashes (frame-disappear / full size) here (native_glass_scenarios.swift bar_rev15 /
///   toolbar_rev08); we keep the main motion continuous.
pub fn transact(group: GlassGroupMount, tx: GlassTransaction) void {
    const gs = group.state;
    const spacing = gs.spacing;
    const n = gs.shape_count;
    // Retained element: currently visible, not in this add/remove
    var pre: [max_shapes][4]f32 = undefined;
    var keep: [max_shapes]bool = @splat(false);
    for (gs.shapes[0..n], 0..) |slot, k| {
        const e = slot orelse continue;
        const st = e.state;
        if (!st.enabled or st.materialize_level < 0.5) continue;
        if (st.matched) |mm| if (mm.kind == .remove) continue;
        if (inEntries(tx.removes, st) or inMoves(tx.inserts, st)) continue;
        keep[k] = true;
        pre[k] = glass_box.memberGeometry(st);
    }
    // Removed: mid-insertion reversed, back to its source; rest chain-connect to retained element
    var rsrc: [max_shapes]?*AdaptiveGlassBoxState = @splat(null);
    for (tx.removes, 0..) |r, ri| {
        if (ri >= max_shapes) break;
        const mm = r.state.matched orelse continue;
        if (mm.kind == .insert) rsrc[ri] = keptMember(gs, &keep, mm.source_index);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (tx.removes, 0..) |r, ri| {
            if (ri >= max_shapes or rsrc[ri] != null) continue;
            const rr = glass_box.memberGeometry(r.state);
            for (gs.shapes[0..n], 0..) |slot, k| {
                if (!keep[k]) continue;
                if (rectGap(rr, pre[k]) <= spacing) {
                    rsrc[ri] = slot.?.state;
                    changed = true;
                    break;
                }
            }
            if (rsrc[ri] != null) continue;
            for (tx.removes, 0..) |o, oi| {
                if (oi >= max_shapes or oi == ri) continue;
                const src = rsrc[oi] orelse continue;
                if (rectGap(rr, glass_box.memberGeometry(o.state)) <= spacing) {
                    rsrc[ri] = src;
                    changed = true;
                    break;
                }
            }
        }
    }
    // Inserted: final rect chain-connects to retained element's pre-animation rect
    var isrc: [max_shapes]?*AdaptiveGlassBoxState = @splat(null);
    changed = true;
    while (changed) {
        changed = false;
        for (tx.inserts, 0..) |ins, ii| {
            if (ii >= max_shapes or isrc[ii] != null) continue;
            for (gs.shapes[0..n], 0..) |slot, k| {
                if (!keep[k]) continue;
                if (rectGap(ins.rect, pre[k]) <= spacing) {
                    isrc[ii] = slot.?.state;
                    changed = true;
                    break;
                }
            }
            if (isrc[ii] != null) continue;
            for (tx.inserts, 0..) |o, oi| {
                if (oi >= max_shapes or oi == ii) continue;
                const src = isrc[oi] orelse continue;
                if (rectGap(ins.rect, o.rect) <= spacing) {
                    isrc[ii] = src;
                    changed = true;
                    break;
                }
            }
        }
    }
    // Inserted / removed members enter or leave the hierarchy: their content goes with the glass.
    for (tx.inserts) |ins| ins.entry.state.content_follows_presence = true;
    for (tx.removes) |r| r.state.content_follows_presence = true;
    for (tx.moves) |m| glass_box.glassMorphTo(m.entry.state, .{ .x = m.rect[0], .y = m.rect[1], .w = m.rect[2], .h = m.rect[3], .duration_ms = tx.duration_ms, .easing = .spring_smooth, .liquid = .none });
    for (tx.removes, 0..) |r, ri| {
        if (ri < max_shapes) if (rsrc[ri]) |src| {
            glass_box.startMatchedRemove(r.state, src, tx.duration_ms);
            continue;
        };
        glass_box.glassSetEnabled(r.state, false);
    }
    for (tx.inserts, 0..) |ins, ii| {
        // Fade-out in progress then re-inserted (removed beyond spacing does materialize fade-out):
        // member still visible,
        // in-place reverse fade-out, morph to target; treating as new insert would put geometry
        // back to source cap re-grow (frame jump)
        if (ins.entry.state.materialize) |m| if (m.to == 0 and ins.entry.state.materialize_level > 0) {
            const st = ins.entry.state;
            glass_box.glassMorphTo(st, .{ .x = ins.rect[0], .y = ins.rect[1], .w = ins.rect[2], .h = ins.rect[3], .duration_ms = tx.duration_ms, .easing = .spring_smooth, .liquid = .none, .from = glass_box.memberGeometry(st) });
            glass_box.glassSetEnabled(st, true);
            continue;
        };
        if (ins.entry.state.matched) |mm| if (mm.kind == .remove) {
            glass_box.reverseMatchedRemove(ins.entry.state, keptMember(gs, &keep, mm.source_index), ins.rect, tx.duration_ms);
            continue;
        };
        if (ii < max_shapes) if (isrc[ii]) |src| {
            glass_box.startMatchedInsert(ins.entry.state, src, ins.rect, tx.duration_ms);
            continue;
        };
        glass_box.glassPlace(ins.entry.state, ins.rect);
        glass_box.glassSetEnabled(ins.entry.state, true);
    }
}

/// Mount-time presence of a member that later transactions insert / remove: absent hides its glass
/// and its content until a transaction inserts it.
pub fn setMemberPresent(entry: GlassShapeEntry, present: bool) void {
    glass_box.glassSetPresentImmediate(entry.state, present);
}

/// Retained element with group_index == index (matched source reverse-lookup).
fn keptMember(gs: *GlassGroupState, keep: *const [max_shapes]bool, index: u8) ?*AdaptiveGlassBoxState {
    for (gs.shapes[0..gs.shape_count], 0..) |slot, k| {
        const e = slot orelse continue;
        if (keep[k] and e.state.group_index == index) return e.state;
    }
    return null;
}

pub const GlassGroupMount = struct {
    container: *Node,
    state: *GlassGroupState,
};

pub fn GlassGroup(props: anytype) GlassGroupBuilder {
    return .{ .props = reactive.props.coerce(GlassGroupProps, props) };
}

pub const GlassGroupBuilder = struct {
    props: GlassGroupProps,

    pub fn mount(self: GlassGroupBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountWithState(scope, cx)).container;
    }

    pub fn mountWithState(self: GlassGroupBuilder, scope: *Scope, cx: *Cx) !GlassGroupMount {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const p = self.props;
        const container = try box(cx, .{
            .width = if (p.width) |v| .{ .px = v } else .{ .fit = .{} },
            .height = if (p.height) |v| .{ .px = v } else .{ .fit = .{} },
            .direction = p.direction,
            .gap = p.gap,
            .padding = p.padding orelse Padding.all(0),
            .position = .relative,
        }, .{});
        container.meta.ownership.meta.component_name = "GlassGroup";
        errdefer cx.freeNode(container);
        try core.bindScopeToNode(my_scope, container);

        // Container glass surface: absolute full-fill, no background/stroke; glass pixels
        // determined by shape table, no paint when
        // table empty (container has no members).
        const surface = try core.adoptChild(cx, allocator, container, try box(cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{}));
        surface.meta.ownership.meta.component_name = "GlassGroupSurface";

        const state = try allocator.create(GlassGroupState);
        errdefer allocator.destroy(state);
        const link = try allocator.create(glass_box.GlassGroupLink);
        errdefer allocator.destroy(link);
        state.* = .{
            .allocator = allocator,
            .container = container,
            .surface = surface,
            .link = link,
            .spacing = @max(p.spacing, 0),
            .scheme = p.scheme,
            .scroll_edge = p.scroll_edge,
        };
        link.* = .{ .allocator = allocator, .container = container, .surface = surface, .table = &state.table, .merge_mode = p.merge, .base_spacing = state.spacing, .merge_strength = if (p.merge == .always) 1.0 else 0.0 };
        state.table.spacing = state.spacing * link.merge_strength;
        state.table.blend = link.merge_strength;
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *GlassGroupState = @ptrCast(@alignCast(ptr));
                s.link.releaseFromGroup();
                alloc.destroy(s);
            }
        }.cleanup);
        (try surface.style.ensureExtFallible(allocator)).glass = .{ .backdrop_blur = 1, .glass_intensity = 0, .group = &state.table };
        container.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
        return .{ .container = container, .state = state };
    }
};

pub fn GlassShape(props: anytype) GlassShapeBuilder {
    return .{ .props = reactive.props.coerce(GlassShapeProps, props) };
}

pub const GlassShapeBuilder = struct {
    props: GlassShapeProps,

    /// Mount one member in container; return its node, content body, and material state handle.
    pub fn mountIn(self: GlassShapeBuilder, group: GlassGroupMount, scope: *Scope, cx: *Cx) !GlassShapeEntry {
        const p = self.props;
        // Capacity check before any mount: mounting then error lets errdefer free already-in-tree
        // child.
        if (group.state.shape_count >= max_shapes) return error.GlassGroupFull;
        const mounted = try glass_box.GlassBox(.{
            .title = p.title,
            .subtitle = p.subtitle,
            .width = p.width,
            .height = p.height,
            .padding = p.padding,
            .body_gap = p.body_gap,
            .shape = p.shape,
            .glass_style = p.glass_style,
            .idiom = p.idiom,
            .tint_color = p.tint_color,
            .interactive = p.interactive,
            .press_feedback = p.press_feedback,
            .union_id = p.union_id,
            .enabled = p.enabled,
            .transition = p.transition,
            // Container-level scroll-edge trickle to member (M2 onwards becomes container-level
            // gradient)
            .scroll_edge = group.state.scroll_edge,
        }).mountWithState(scope, cx);
        errdefer cx.freeNode(mounted.box);
        try group.container.appendChild(cx.allocator, mounted.box);
        glass_box.enterGroupMode(mounted.state, group.state.link, @intCast(group.state.shape_count));
        const entry: GlassShapeEntry = .{
            .node = mounted.box,
            .body = mounted.body,
            .state = mounted.state,
            .id = p.id,
            .transition = p.transition,
        };
        try group.state.register(entry);
        return entry;
    }
};

test "GlassGroup: shapes register with shared spacing and scroll-edge" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const group = try GlassGroup(.{ .spacing = 16 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const a = try GlassShape(.{ .width = 120, .height = 44, .id = "a" }).mountIn(group, scope, ctx);
    const b = try GlassShape(.{ .width = 44, .height = 44, .shape = .circle, .glass_style = .clear, .id = "b" }).mountIn(group, scope, ctx);
    ctx.layout();
    glass_box.runBeforeRenderHooks(a.node);
    glass_box.runBeforeRenderHooks(b.node);

    try std.testing.expectEqual(@as(usize, 2), group.state.shape_count);
    try std.testing.expectEqual(@as(f32, 16), group.state.spacing);
    try std.testing.expect(group.state.find("b").?.node == b.node);
    try std.testing.expect(group.state.find("zzz") == null);
    try std.testing.expectEqualStrings("GlassGroup", group.container.meta.ownership.meta.component_name.?);
    // M2: member doesn't paint glass itself, geometry/material goes to container shape table;
    // container surface holds table pointer.
    try std.testing.expect(a.node.children.items[0].style.glass_params() == null);
    try std.testing.expect(b.node.children.items[0].style.glass_params() == null);
    const gp = group.state.surface.style.glass_params().?;
    try std.testing.expect(gp.group.? == &group.state.table);
    try std.testing.expect(gp.backdrop_blur > 0.5);
    try std.testing.expectEqual(@as(u8, 2), group.state.table.count);
    try std.testing.expectEqual(@as(f32, 22), group.state.table.shapes[0].radius); // capsule = h/2
    try std.testing.expectEqual(@as(f32, 0), group.state.table.shapes[0].x);
    try std.testing.expectEqual(@as(f32, 132), group.state.table.shapes[1].x); // 120 + gap 12
    try std.testing.expectEqual(@as(f32, 44), group.state.table.shapes[1].w);
    try std.testing.expectEqual(b.state.surface.id, group.state.table.shapes[1].node_id);
    try std.testing.expect(group.state.table.shapes[1].material.lens_bezel_px > 0);
    // Project shadow into table (regular members have, clear don't), member node's own shadow off
    // Member registered shadow (measured alpha under blending: bright family 0.095 / dark family
    // 0.039)
    try std.testing.expect(group.state.table.shapes[0].shadow_alpha > 0.02);
    try std.testing.expectEqual(@as(f32, 37), group.state.table.shapes[0].shadow_blur);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.shapes[1].shadow_alpha);
    try std.testing.expectEqual(@as(u8, 0), (a.node.style.shadow() orelse unreachable).color.a);
    try std.testing.expect(b.state.variant == .clear);
    // Member move (layout change) must refresh table: after container gap change reflow
    const v0 = group.state.table.version;
    group.container.style.gap = 40;
    group.container.markLayoutDirty();
    ctx.layout();
    glass_box.runBeforeRenderHooks(b.node);
    try std.testing.expectEqual(@as(f32, 160), group.state.table.shapes[1].x);
    try std.testing.expect(group.state.table.version != v0);
    // Member unmount alone: slot clear, count shrink, version change, link still held by container
    const v1 = group.state.table.version;
    group.container.removeChild(b.node);
    ctx.freeNode(b.node);
    try std.testing.expectEqual(@as(u8, 1), group.state.table.count);
    try std.testing.expectEqual(std.math.maxInt(u32), group.state.table.shapes[1].node_id);
    try std.testing.expect(group.state.table.version != v1);
    try std.testing.expectEqual(@as(u8, 1), group.state.link.attached);
    try std.testing.expect(group.state.link.alive);
}

test "GlassGroup: full container rejects the ninth shape before mounting it" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{}).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    for (0..max_shapes) |_| _ = try GlassShape(.{ .width = 20, .height = 20 }).mountIn(group, scope, ctx);
    const before = group.container.children.items.len;
    try std.testing.expectError(error.GlassGroupFull, GlassShape(.{ .width = 20, .height = 20 }).mountIn(group, scope, ctx));
    try std.testing.expectEqual(before, group.container.children.items.len);
}

test "GlassGroup: container teardown before member cleanup leaves no dangling link" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{}).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    _ = try GlassShape(.{ .width = 40, .height = 40 }).mountIn(group, scope, ctx);
    _ = try GlassShape(.{ .width = 40, .height = 40 }).mountIn(group, scope, ctx);
    ctx.layout();
    // freeNodeNow: dispose container scope first (state destroyed, link alive=false), then free
    // member;
    // member cleanup just releases link, last one frees it (testing allocator catches leak/UAF).
    root.removeChild(group.container);
    ctx.freeNode(group.container);
}

test "GlassGroup: a member dissolves to identity and materializes back (container surface regains its blur)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 0 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const m = try GlassShape(.{ .width = 200, .height = 56, .shape = .capsule }).mountIn(group, scope, ctx);
    ctx.layout();
    ctx.frame_time_ms = 5000;
    glass_box.runBeforeRenderHooks(m.node);
    const gp0 = group.state.surface.style.glass_params().?;
    try std.testing.expect(gp0.backdrop_blur > 0.5);
    try std.testing.expectEqual(@as(f32, 1), group.state.table.shapes[0].level);

    glass_box.glassSetEnabled(m.state, false);
    ctx.frame_presentation_sample = .{ .tick = 36, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    glass_box.runBeforeRenderHooks(m.node);
    ctx.frame_time_ms += 400;
    ctx.frame_presentation_sample = .{ .tick = 60, .target_time_ms = 90035 + 23 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    glass_box.runBeforeRenderHooks(m.node);
    try std.testing.expect(!m.state.enabled);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.shapes[0].level);
    // identity member skips composite: zero-size entry
    try std.testing.expectEqual(@as(f32, 0), group.state.table.shapes[0].w);

    glass_box.glassSetEnabled(m.state, true);
    try std.testing.expect(m.state.enabled);
    ctx.frame_presentation_sample = .{ .tick = 70, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    glass_box.runBeforeRenderHooks(m.node);
    // First frame appear: container surface must have already restored backdrop pass (else full
    // appear invisible)
    try std.testing.expect(group.state.surface.style.glass_params().?.backdrop_blur > 0.5);
    ctx.frame_time_ms += 600;
    ctx.frame_presentation_sample = .{ .tick = 110, .target_time_ms = 90035 + 63 * (1000.0 / 60.0), .period_ms = 1000.0 / 60.0 };
    glass_box.runBeforeRenderHooks(m.node);
    try std.testing.expect(m.state.materialize == null);
    try std.testing.expectEqual(@as(f32, 1), group.state.table.shapes[0].level);
    try std.testing.expectEqual(@as(f32, 200), group.state.table.shapes[0].w);
    try std.testing.expect(group.state.table.shapes[0].material.backdrop_blur > 0.5);
    try std.testing.expect(group.state.surface.style.glass_params().?.backdrop_blur > 0.5);
}

test "GlassGroup: merge .transitions enables spacing only while a member moves, then decays" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 40, .width = 600, .height = 80 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const a = try GlassShape(.{ .width = 150, .height = 44 }).mountIn(group, scope, ctx);
    a.node.style.position = .absolute;
    (try a.node.style.ensureExtFallible(std.testing.allocator)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 8 } };
    ctx.layout();
    ctx.frame_time_ms = 1000;
    ctx.frame_dt_ms = 16;
    glass_box.runBeforeRenderHooks(a.node);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.spacing); // Idle: no adhesion
    try std.testing.expectEqual(@as(f32, 0), group.state.table.blend); // Idle: hard union
    // Morph start: spacing ramps to 40 during transition
    glass_box.glassMorphTo(a.state, .{ .x = 200, .y = 8, .w = 150, .h = 44, .frames = 30 });
    ctx.frame_presentation_sample = .{ .tick = 10, .target_time_ms = null, .period_ms = 1000.0 / 60.0 };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        ctx.frame_time_ms += 16;
        ctx.frame_presentation_sample = .{ .tick = 11 + @as(u64, @intCast(i)), .target_time_ms = 50000 + @as(f64, @floatFromInt(i)) * 16.67, .period_ms = 1000.0 / 60.0 };
        glass_box.runBeforeRenderHooks(a.node);
    }
    try std.testing.expect(a.state.morph != null);
    try std.testing.expectApproxEqAbs(@as(f32, 40), group.state.table.spacing, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), group.state.table.blend, 0.01);
    // During transition: merge radius k/S = morph_transition_k*sqrt(1-s), s is that member's
    // current morph progress
    const m = a.state.morph.?;
    const s_now = m.t * m.t * (3.0 - 2.0 * m.t);
    try std.testing.expect(m.t > 0.05 and m.t < 0.95);
    try std.testing.expectApproxEqAbs(glass_box.morph_transition_k * @sqrt(1.0 - s_now), group.state.table.motion, 1e-4);
    // After morph ends stay >150ms: decay to 0
    ctx.frame_time_ms += 600;
    ctx.frame_presentation_sample = .{ .tick = 60, .target_time_ms = 50000 + 49 * 16.67, .period_ms = 1000.0 / 60.0 };
    glass_box.runBeforeRenderHooks(a.node);
    try std.testing.expect(a.state.morph == null);
    // Morph-driven adhesion winds down with progress: end has no adhesion, no "maintain + decay"
    // tail (else end cusp freezes then
    // suddenly shrinks)
    ctx.frame_time_ms += 16;
    glass_box.runBeforeRenderHooks(a.node);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.spacing);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.blend);
    // Non-morph position change (drag) takes time envelope: motion frame ramps to 1, must keep
    // requesting frame during hold, else
    // idle stops frame then decay can't advance
    (try a.node.style.ensureExtFallible(std.testing.allocator)).inset = .{ .left = .{ .px = 260 }, .top = .{ .px = 8 } };
    a.node.markLayoutDirty();
    ctx.layout();
    i = 0;
    while (i < 6) : (i += 1) {
        ctx.frame_time_ms += 16;
        glass_box.runBeforeRenderHooks(a.node);
    }
    try std.testing.expect(group.state.table.spacing > 0);
    ctx.needs_redraw = false;
    ctx.frame_time_ms += 16;
    glass_box.runBeforeRenderHooks(a.node);
    try std.testing.expect(ctx.needs_redraw);
    i = 0;
    while (i < 40) : (i += 1) {
        ctx.frame_time_ms += 16;
        glass_box.runBeforeRenderHooks(a.node);
    }
    try std.testing.expectEqual(@as(f32, 0), group.state.table.spacing);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.motion);
    // .always: constant spacing
    const always = try GlassGroup(.{ .spacing = 40, .merge = .always }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, always.container);
    try std.testing.expectApproxEqAbs(@as(f32, 40), always.state.table.spacing, 0.01);
}

test "GlassGroup.transact: reversing mid-split retraces into the source without dropping the bulge or blend" {
    // Native toolbar mid-reverse (native_glass_scenarios.swift tb24_rev150/250): always one
    // connected blob, bulge continuous,
    // new elements suck back to source element. Old impl mid-reverse frame bulge zeros, k 0.75->0.5
    // jump, member slightly far from
    // source fade-out in place.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 24, .width = 600, .height = 80 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const a = try GlassShape(.{ .width = 450, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const b = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const c = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    // Next-row static neighbor d: at reverse moment c within spacing of it, far from source a,
    // re-judge by current gap would suck into d
    const d = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const all = [_]GlassShapeEntry{ a, b, c, d };
    for (all) |e| e.node.style.position = .absolute;
    glass_box.glassPlace(a.state, .{ 0, 8, 450, 44 });
    glass_box.glassPlace(d.state, .{ 300, 64, 150, 44 });
    glass_box.glassSetEnabledImmediate(b.state, false);
    glass_box.glassSetEnabledImmediate(c.state, false);
    ctx.layout();
    ctx.frame_time_ms = 1000;
    ctx.frame_dt_ms = 16;
    for (all) |e| glass_box.runBeforeRenderHooks(e.node);
    const step = struct {
        fn run(cx: *Cx, es: []const GlassShapeEntry, n: usize) void {
            for (0..n) |_| {
                cx.frame_time_ms += 16;
                for (es) |e| glass_box.runBeforeRenderHooks(e.node);
                cx.layout();
            }
        }
    }.run;
    transact(group, .{
        .moves = &.{.{ .entry = a, .rect = .{ -24, 8, 150, 44 } }},
        .inserts = &.{ .{ .entry = b, .rect = .{ 150, 8, 150, 44 } }, .{ .entry = c, .rect = .{ 324, 8, 150, 44 } } },
    });
    // Anchor at source element's **final** end cap (a gets -24..126 -> end cap center 104), not
    // current shrinking end cap (428):
    // else new element protrudes out shrinking a, exterior rebounds once more (recording
    // 919->930->900)
    ctx.layout();
    const c0 = c.node.rectFromWorldOrFallback();
    try std.testing.expectApproxEqAbs(@as(f32, 104), c0.x + c0.w / 2, 1);
    step(ctx, &all, 16);
    try std.testing.expectEqual(a.state.group_index, c.state.matched.?.source_index);
    try std.testing.expect(rectGap(glass_box.memberRect(c.state), glass_box.memberRect(d.state)) <= 24);
    const dilate_before = a.state.group_dilate;
    const motion_before = group.state.table.motion;
    // Mid-reverse
    transact(group, .{
        .moves = &.{.{ .entry = a, .rect = .{ 0, 8, 450, 44 } }},
        .removes = &.{ b, c },
    });
    for ([_]GlassShapeEntry{ b, c }) |e| {
        const mm = e.state.matched orelse return error.TestExpectedMatchedRemove;
        try std.testing.expectEqual(glass_box.MatchedKind.remove, mm.kind);
        try std.testing.expectEqual(a.state.group_index, mm.source_index);
        try std.testing.expect(e.state.materialize == null);
    }
    step(ctx, &all, 1);
    const w_first = c.node.rectFromWorldOrFallback().w;
    // Bulge doesn't zero (old impl frame 4.2 -> 0): at least old pulse alone another frame's value,
    // blend coefficient no jump
    const old_alone = (glass_box.matchedPulse(16.0 * 17.0 / 1000.0) - 1) * 44.0 / 2.0;
    try std.testing.expect(dilate_before > 2);
    try std.testing.expect(a.state.group_dilate >= old_alone - 0.01);
    try std.testing.expectApproxEqAbs(motion_before, group.state.table.motion, 0.02);
    // Reverse immediately, no 0.05s startup delay (else first 3 frames after reverse frozen in
    // place, width frame-identical)
    step(ctx, &all, 1);
    try std.testing.expect(c.node.rectFromWorldOrFallback().w < w_first - 1);
    // Reverse mid-suck (rapid re-click): spring from current rect to target, doesn't back to cap
    // re-grow
    step(ctx, &all, 3);
    // Screen geometry is layout rect (memberRect written last frame, one frame late)
    const before = c.node.rectFromWorldOrFallback();
    transact(group, .{
        .moves = &.{.{ .entry = a, .rect = .{ -24, 8, 150, 44 } }},
        .inserts = &.{ .{ .entry = b, .rect = .{ 150, 8, 150, 44 } }, .{ .entry = c, .rect = .{ 324, 8, 150, 44 } } },
    });
    try std.testing.expect(c.state.matched == null and c.state.enabled and c.state.morph != null);
    step(ctx, &all, 1);
    const after = c.node.rectFromWorldOrFallback();
    // Spring first step ~1px; back to cap re-grow would be tens of px
    try std.testing.expect(@abs(after.x - before.x) < 4 and @abs(after.w - before.w) < 4 and @abs(after.h - before.h) < 4);
    step(ctx, &all, 60);
    const r = glass_box.memberRect(c.state);
    try std.testing.expectApproxEqAbs(@as(f32, 324), r[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 150), r[2], 0.5);
}

test "GlassGroup.transact: rapid triple toggle keeps the earliest pulse running (bulge is the max of all pulses)" {
    // 48ms apart three clicks (insert -> remove -> insert): earliest pulse nearing peak, highest of
    // three.
    // Single slot save would let second overwrite it, bulge deflates; native takes max of all
    // pulsing. Two members (same toolbar):
    // each transaction calls startPulse on source twice, second in transaction (progress 0) must
    // not occupy slot, else third overwrites earliest.
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 24, .width = 600, .height = 80 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const a = try GlassShape(.{ .width = 450, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const b = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const c = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const all = [_]GlassShapeEntry{ a, b, c };
    for (all) |e| e.node.style.position = .absolute;
    glass_box.glassPlace(a.state, .{ 0, 8, 450, 44 });
    glass_box.glassSetEnabledImmediate(b.state, false);
    glass_box.glassSetEnabledImmediate(c.state, false);
    ctx.layout();
    ctx.frame_time_ms = 1000;
    ctx.frame_dt_ms = 16;
    for (all) |e| glass_box.runBeforeRenderHooks(e.node);
    const step = struct {
        fn run(cx: *Cx, es: []const GlassShapeEntry, n: usize) void {
            for (0..n) |_| {
                cx.frame_time_ms += 16;
                for (es) |e| glass_box.runBeforeRenderHooks(e.node);
                cx.layout();
            }
        }
    }.run;
    const split = GlassTransaction{
        .moves = &.{.{ .entry = a, .rect = .{ -24, 8, 150, 44 } }},
        .inserts = &.{ .{ .entry = b, .rect = .{ 150, 8, 150, 44 } }, .{ .entry = c, .rect = .{ 324, 8, 150, 44 } } },
    };
    const merge = GlassTransaction{ .moves = &.{.{ .entry = a, .rect = .{ 0, 8, 450, 44 } }}, .removes = &.{ b, c } };
    transact(group, split);
    step(ctx, &all, 3);
    transact(group, merge);
    step(ctx, &all, 3);
    transact(group, split);
    step(ctx, &all, 3);
    // Earliest pulse this point 9 frames in (144ms), near peak 1.2144; latter two only 6 / 3 frames
    const h: f32 = 44;
    const first_alone = (glass_box.matchedPulse(9.0 * 16.0 / 1000.0) - 1) * h / 2;
    try std.testing.expect(first_alone > 3.5);
    try std.testing.expect(a.state.group_dilate >= first_alone - 0.05);
}

test "GlassGroup.transact: matched insert grows from the source end cap, settles exactly; source pulses" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 24, .width = 600, .height = 80 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    const a = try GlassShape(.{ .width = 450, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const b = try GlassShape(.{ .width = 150, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    const far = try GlassShape(.{ .width = 60, .height = 44, .shape = .capsule }).mountIn(group, scope, ctx);
    for ([_]GlassShapeEntry{ a, b, far }) |e| e.node.style.position = .absolute;
    glass_box.glassPlace(a.state, .{ 0, 8, 450, 44 });
    glass_box.glassPlace(b.state, .{ 150, 8, 150, 44 });
    glass_box.glassPlace(far.state, .{ 520, 8, 60, 44 });
    glass_box.glassSetEnabledImmediate(b.state, false);
    ctx.layout();
    ctx.frame_time_ms = 1000;
    ctx.frame_dt_ms = 16;
    for ([_]GlassShapeEntry{ a, b, far }) |e| glass_box.runBeforeRenderHooks(e.node);
    // b in a's pre-animation rect (gap 0 <= 24) -> matched, grows from a; far distance to a's
    // post-shrink rect >24 no matter:
    // criterion uses pre-animation rect.
    transact(group, .{
        .moves = &.{.{ .entry = a, .rect = .{ -24, 8, 150, 44 } }},
        .inserts = &.{.{ .entry = b, .rect = .{ 150, 8, 150, 44 } }},
    });
    try std.testing.expect(b.state.matched != null);
    try std.testing.expectEqual(a.state.group_index, b.state.matched.?.source_index);
    try std.testing.expect(a.state.pulse_start_ms >= 0);
    var peak_dilate: f32 = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        ctx.frame_time_ms += 16;
        for ([_]GlassShapeEntry{ a, b, far }) |e| glass_box.runBeforeRenderHooks(e.node);
        ctx.layout();
        peak_dilate = @max(peak_dilate, a.state.group_dilate);
        if (i == 5) try std.testing.expect(group.state.table.motion > 0.7); // Transition merge radius 0.75*S
    }
    try std.testing.expect(b.state.matched == null);
    const r = glass_box.memberRect(b.state);
    try std.testing.expectApproxEqAbs(@as(f32, 150), r[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), r[2], 0.01);
    // Source pulse: peak ~= (1.2227 - 1)*44/2 ~= 4.9px (sampled frame slightly lower), zero after
    try std.testing.expect(peak_dilate > 3.5 and peak_dilate < 5.2);
    try std.testing.expectEqual(@as(f32, 0), a.state.group_dilate);
    try std.testing.expectEqual(@as(f32, 0), group.state.table.motion);
    // Far remove: far distance to a (post-shrink -24..126) > spacing -> materialize fade-out, not
    // matched
    transact(group, .{ .removes = &.{far} });
    try std.testing.expect(far.state.matched == null);
    try std.testing.expect(far.state.materialize != null);
    // Near remove: b distance to a 24 <= spacing -> matched suck back, hidden after
    transact(group, .{ .moves = &.{.{ .entry = a, .rect = .{ 0, 8, 450, 44 } }}, .removes = &.{b} });
    try std.testing.expect(b.state.matched != null and b.state.matched.?.kind == .remove);
    i = 0;
    while (i < 60) : (i += 1) {
        ctx.frame_time_ms += 16;
        for ([_]GlassShapeEntry{ a, b, far }) |e| glass_box.runBeforeRenderHooks(e.node);
        ctx.layout();
    }
    try std.testing.expect(b.state.matched == null and !b.state.enabled);
}

test "GlassGroup matchedRect: insert starts as a point on the source end cap, remove ends there" {
    const src = [4]f32{ 0, 0, 450, 44 };
    // Target center 494 outside source skeleton [22, 428] -> clamp anchor to end cap center 428
    const fin = [4]f32{ 419, 0, 150, 44 };
    const r0 = glass_box.matchedRect(.insert, fin, src, 22, 0);
    try std.testing.expectEqual(@as(f32, 0), r0[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 428), r0[0], 0.01);
    // Target center in skeleton -> anchor is target center projected onto skeleton
    const inner = glass_box.matchedRect(.insert, .{ 324, 0, 150, 44 }, src, 22, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 399), inner[0], 0.01);
    const r1 = glass_box.matchedRect(.insert, fin, src, 22, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 419), r1[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), r1[2], 0.01);
    const e = glass_box.matchedRect(.remove, fin, src, 22, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), e[2], 0.01);
    // rounded card: skeleton = rect inset by corner radius 16, child bar right-side pull out along
    // own row horizontal
    const card = [4]f32{ 90, 10, 300, 146 };
    const anc = glass_box.matchedAnchor(card, 16, 405, 30);
    try std.testing.expectApproxEqAbs(@as(f32, 374), anc[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), anc[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2227), glass_box.matchedPulse(0.2), 1e-4);
    try std.testing.expectEqual(@as(f32, 1), glass_box.matchedPulse(2));
}

const ToggleFuzz = struct {
    spacing: f32,
    collapsed: [4]f32,
    split: [3][4]f32,
    shape: glass_box.GlassBoxShape,
    /// max any member height (include pulsation)
    max_h: f32,
    /// max adjacent-frame w/h change
    max_dw: f32,
    max_dh: f32,
};

/// random-interval clicks expand/collapse several times (don't await animation end), final slow
/// ×16; frame-by-frame check layout rect not exceed-bounds, adjacent frame no jump.
fn toggleFuzz(cfg: ToggleFuzz) !void {
    var seed: u64 = 1;
    while (seed <= 60) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        var ctx = try Cx.init(std.testing.allocator, std.testing.io);
        defer ctx.deinit();
        const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
        defer scope.dispose();
        const group = try GlassGroup(.{ .spacing = cfg.spacing, .width = 600, .height = 200 }).mountWithState(scope, ctx);
        try root.appendChild(std.testing.allocator, group.container);
        const a = try GlassShape(.{ .width = cfg.collapsed[2], .height = cfg.collapsed[3], .shape = cfg.shape }).mountIn(group, scope, ctx);
        const b = try GlassShape(.{ .width = cfg.split[1][2], .height = cfg.split[1][3], .shape = cfg.shape }).mountIn(group, scope, ctx);
        const c = try GlassShape(.{ .width = cfg.split[2][2], .height = cfg.split[2][3], .shape = cfg.shape }).mountIn(group, scope, ctx);
        const all = [_]GlassShapeEntry{ a, b, c };
        for (all) |e| e.node.style.position = .absolute;
        glass_box.glassPlace(a.state, cfg.collapsed);
        glass_box.glassSetEnabledImmediate(b.state, false);
        glass_box.glassSetEnabledImmediate(c.state, false);
        ctx.layout();
        ctx.frame_time_ms = 1000;
        ctx.frame_dt_ms = 16;
        for (all) |e| glass_box.runBeforeRenderHooks(e.node);
        var prev: [3]?[4]f32 = .{ null, null, null };
        var split = false;
        const clicks = 2 + rnd.uintLessThan(usize, 6);
        for (0..clicks + 1) |ci| {
            split = !split;
            const ms: f64 = if (ci == clicks) 8000 else 500;
            if (split) transact(group, .{
                .moves = &.{.{ .entry = a, .rect = cfg.split[0] }},
                .inserts = &.{ .{ .entry = b, .rect = cfg.split[1] }, .{ .entry = c, .rect = cfg.split[2] } },
                .duration_ms = ms,
            }) else transact(group, .{ .moves = &.{.{ .entry = a, .rect = cfg.collapsed }}, .removes = &.{ b, c }, .duration_ms = ms });
            const frames: usize = if (ci == clicks) 300 else 1 + rnd.uintLessThan(usize, 25);
            for (0..frames) |_| {
                ctx.frame_time_ms += 16;
                for (all) |e| glass_box.runBeforeRenderHooks(e.node);
                ctx.layout();
                for (all, 0..) |e, k| {
                    if (!e.state.enabled) {
                        prev[k] = null;
                        continue;
                    }
                    // layout rect (memberRect lag one frame: insert first frame still pre-hidden
                    // old geometry)
                    const lr = e.node.rectFromWorldOrFallback();
                    const r = [4]f32{ lr.x, lr.y, lr.w, lr.h };
                    try std.testing.expect(r[3] + 2 * e.state.group_dilate <= cfg.max_h);
                    if (prev[k]) |p| {
                        try std.testing.expect(@abs(r[2] - p[2]) < cfg.max_dw);
                        try std.testing.expect(@abs(r[3] - p[3]) < cfg.max_dh);
                    }
                    prev[k] = r;
                }
            }
        }
    }
}

test "GlassGroup.transact: re-inserting a member absorbed down to the end cap grows from there (no 220x140 fallback)" {
    // regress (storybook Glass Split real shot): multi-click then slow ×16 expand, child bar
    // suddenly ~72pt tall capsule.
    // member pulled-back to source endcap width/height degrade near-0 (tested 11.5x0.3), reverse
    // glassMorphTo start layout rect,
    // "w/h <= 0.5 = unlaid-out" fallback 220x140, spring back target. random click interval + final
    // slow, frame-by-frame check height
    // no-exceed source pulsation peak (native 55), adjacent frame geometry no jump.
    try toggleFuzz(.{
        .spacing = 24,
        .collapsed = .{ 0, 0, 450, 44 },
        .split = .{ .{ -24, 0, 150, 44 }, .{ 150, 0, 150, 44 }, .{ 324, 0, 150, 44 } },
        .shape = .capsule,
        .max_h = 56,
        .max_dw = 40,
        .max_dh = 12,
    });
}

test "GlassGroup.transact: card expand / collapse reverses mid-way from the current geometry (fade-out members fade back)" {
    // storybook Glass Split card: 300x146 <-> three 150x40, spacing 40. collapse far two bar exceed
    // spacing fade, fade-mid-reverse must in-place reverse (no jump source endcap); first element
    // morph back-forth no jump, no exceed 146 + pulsation.
    try toggleFuzz(.{
        .spacing = 40,
        .collapsed = .{ 90, 10, 300, 146 },
        .split = .{ .{ 0, 10, 150, 40 }, .{ 330, 10, 150, 40 }, .{ 165, 120, 150, 40 } },
        .shape = .{ .rounded = 16 },
        .max_h = 146 * 1.2144 + 1, // pulsation scale by height: single-pulse peak 1.2144
        .max_dw = 40,
        .max_dh = 25,
    });
}

test "GlassGroup: absent / inserted / removed members take their content with them; isEnabled keeps it" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const group = try GlassGroup(.{ .spacing = 12, .width = 600, .height = 44 }).mountWithState(scope, ctx);
    try root.appendChild(std.testing.allocator, group.container);
    var es: [4]GlassShapeEntry = undefined;
    for (&es) |*e| {
        e.* = try GlassShape(.{ .width = 44, .height = 44, .shape = .circle, .padding = Padding.all(0) }).mountIn(group, scope, ctx);
        e.node.style.position = .absolute;
        try e.body.appendChild(std.testing.allocator, try box(ctx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{}));
    }
    const a = es[0];
    const near = es[1]; // within spacing of a: grows out of it (matched)
    const far = es[2]; // beyond spacing: materializes in place
    const off = es[3]; // glassEffect(isEnabled: false): glass off, content stays
    glass_box.glassPlace(a.state, .{ 500, 0, 44, 44 });
    setMemberPresent(near, false);
    setMemberPresent(far, false);
    glass_box.glassSetEnabledImmediate(off.state, false);
    ctx.layout();
    ctx.frame_time_ms = 1000;
    ctx.frame_dt_ms = 16;
    const step = struct {
        fn run(cx: *Cx, list: []const GlassShapeEntry, n: usize) void {
            for (0..n) |_| {
                cx.frame_time_ms += 16;
                for (list) |e| glass_box.runBeforeRenderHooks(e.node);
                cx.layout();
            }
        }
    }.run;
    step(ctx, &es, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), near.state.content.getOpacity(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), far.state.content.getOpacity(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), off.state.content.getOpacity(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.state.content.getOpacity(), 1e-3);

    transact(group, .{ .inserts = &.{ .{ .entry = near, .rect = .{ 444, 0, 44, 44 } }, .{ .entry = far, .rect = .{ 0, 0, 44, 44 } } } });
    step(ctx, &es, 1);
    // matched: the member is whole from the first frame (its geometry grows out of the source)
    try std.testing.expectApproxEqAbs(@as(f32, 1), near.state.content.getOpacity(), 1e-3);
    const mid = far.state.content.getOpacity();
    try std.testing.expect(mid > 0 and mid < 1);
    step(ctx, &es, 60);
    try std.testing.expectApproxEqAbs(@as(f32, 1), far.state.content.getOpacity(), 1e-3);

    transact(group, .{ .removes = &.{ near, far } });
    step(ctx, &es, 60);
    try std.testing.expectApproxEqAbs(@as(f32, 0), near.state.content.getOpacity(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), far.state.content.getOpacity(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.state.content.getOpacity(), 1e-3);
}
