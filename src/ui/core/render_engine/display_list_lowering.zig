/// DisplayList lowering: transform the DisplayItem sequence from local space to world space.
///
/// Input and output are both DisplayItem (with apply transform + scale fields). Handles:
/// - appendDisplayItemsToRenderListInternal: core lowering loop (17 paint variants +
///   8 effect/clip control passthroughs)
/// - public API: appendAllDisplayItemsToRenderList / appendNodeDisplayPayloadToRenderList
/// - internal helpers: getNodeDisplayItems / getNodeTextBlobs / getNodeDisplayPayload
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const property_tree_mod = @import("../property_tree.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");
const scene_runtime_mod = @import("../scene_runtime.zig");
const render_context_mod = @import("render_context.zig");
const node_state = @import("node_state.zig");
const style_render = @import("node_style_render.zig");
const effect_bridge = @import("effect_bridge.zig");
const text_trace = @import("trace").text_flicker;
const bracket_debug = @import("bracket_debug.zig");
const paint_table_mod = @import("../paint_table.zig");
const gpu_draw_shadow = @import("gpu_draw_shadow.zig");

const ComputedRect = types.ComputedRect;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;
const RenderContext = render_context_mod.RenderContext;
const NodeExecutionState = node_state.NodeExecutionState;
const INVALID_ID = property_tree_mod.INVALID_ID;
const scaleLocalRadii = style_render.scaleLocalRadii;
const DisplayEffectBridgeScope = effect_bridge.DisplayEffectBridgeScope;
const ItemHeader = display_list_mod.ItemHeader;

pub const CONTROL_HEADER: ItemHeader = .{ .transform_id = INVALID_ID, .node_id = std.math.maxInt(u32) };

/// Only writes paint_table.DisplayItem (paint_table is the source; the union path is deprecated).
///
/// Control variants manage scopes. Literal controls are already lowered;
/// node_local push_clip also carries geometry that must follow its paint transform.
fn isControlItem(item: *const display_list_mod.DisplayItem) bool {
    // Single criterion: share DisplayItem.isControl with core.zig bulk quad ownership scan;
    // separate name lists on both sides will eventually get out of sync.
    return item.isControl();
}

/// inline payload (polygon / glass / icon_rep / path geometry) spill to frame_arena for stable
/// addresses; cannot use main_paint internal address since later append may realloc.
pub fn appendLoweredBoth(cx: *RenderContext, item: display_list_mod.DisplayItem) !void {
    if (!cx.paint_pass_lowering) return;
    if (cx.capture_lowered) |sink| {
        var frozen = item;
        frozen.headerPtr().* = .{ .already_lowered = true, .transform_id = INVALID_ID, .node_id = INVALID_ID };
        // Referenced payloads may be the caller's temporaries: the sink outlives them.
        switch (frozen) {
            .push_clip => |*clip| if (clip.polygon) |p| {
                const own = try cx.frame_allocator.create(display_list_mod.ClipPolygon);
                own.* = p.*;
                clip.polygon = own;
            },
            .begin_blur_layer => |*blur| {
                const own = try cx.frame_allocator.create(@TypeOf(blur.glass.*));
                own.* = blur.glass.*;
                blur.glass = own;
            },
            else => {},
        }
        try sink.append(cx.allocator, frozen);
    }
    var paint_item = gpu_draw_shadow.lowerDisplayItem(item);
    paint_item.paint_digest = loweredDigest(cx, &item);
    // Payloads by pointer: a capture by value copies the whole variant (a push_clip carries a
    // 32-point polygon).
    switch (item) {
        .push_clip => |*it| {
            if (it.shape_kind == .polygon) {
                const dup = try cx.frame_allocator.create(display_list_mod.ClipPolygon);
                dup.* = display_list_mod.ClipPolygon.of(it.polygon);
                paint_item.clip_polygon_ptr = dup;
            }
        },
        .begin_blur_layer => |*it| {
            const dup = try cx.frame_allocator.create(@TypeOf(it.glass.*));
            dup.* = it.glass.*;
            paint_item.glass_ptr = dup;
        },
        .icon_rep => |*it| {
            const dup = try cx.frame_allocator.create(@TypeOf(it.rep));
            dup.* = it.rep;
            paint_item.icon_rep_ptr = dup;
        },
        .fill_path => |it| {
            const dup = try cx.frame_allocator.create(types.PathGeometry);
            dup.* = it.geometry.*;
            dup.commands = try cx.frame_allocator.dupe(types.PathCommand, it.geometry.commands);
            dup.owned = false;
            paint_item.path_geometry_ptr = dup;
        },
        .stroke_path => |it| {
            const dup = try cx.frame_allocator.create(types.PathGeometry);
            dup.* = it.geometry.*;
            dup.commands = try cx.frame_allocator.dupe(types.PathCommand, it.geometry.commands);
            dup.owned = false;
            paint_item.path_geometry_ptr = dup;
        },
        else => {},
    }
    try cx.lowering_buffer_paint.append(cx.allocator, paint_item);
    if (cx.sprite_probe) |probe| probe.noteLowered(item.header().node_id, cx.lowering_buffer_paint.items.len - 1, isControlItem(&item));
}
/// paint_table.DisplayItem.paint_digest of a lowered item: its recorded
/// content fingerprint, the transform it was lowered through, its place among
/// the items lowered from the same recorded one, and the text it resolved
/// (text runs read this frame's blob store). 0 (unknown) outside a recorded
/// item's lowering scope or without a fingerprint. Clip pops and group ends
/// carry nothing but their kind and lower to a constant item: their digest is
/// their kind's, wherever they are lowered.
fn loweredDigest(cx: *RenderContext, item: *const display_list_mod.DisplayItem) u64 {
    switch (item.*) {
        .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip => {
            // A field added to one of them would make this digest lie.
            comptime for ([_][]const u8{ "pop_clip", "end_opacity_layer", "end_blur_layer", "end_rounded_clip" }) |name| {
                if (@typeInfo(@FieldType(display_list_mod.DisplayItem, name)).@"struct".field_names.len != 1) @compileError(name ++ " carries content: digest it");
            };
            const tag: u32 = @backingInt(std.meta.activeTag(item.*));
            return std.hash.Wyhash.hash(0x6d61726b6572, std.mem.asBytes(&tag)) | 1;
        },
        else => {},
    }
    const transform = cx.lowering_fp_transform orelse return 0;
    const header = item.header();
    if (header.local_fp == 0 or header.already_lowered) return 0;
    // One-shot hashes of packed words: this runs for every paint item of every frame.
    const Packed = extern struct { t: [6]f32, seq: u32, kind: u32 };
    const words: Packed = .{
        // + 0 folds -0 into 0: transforms composed along different paths
        // (replay vs fresh) may differ only in a zero's sign.
        .t = .{ transform.a + 0, transform.b + 0, transform.c + 0, transform.d + 0, transform.tx + 0, transform.ty + 0 },
        .seq = cx.lowering_fp_seq,
        .kind = @backingInt(std.meta.activeTag(item.*)),
    };
    cx.lowering_fp_seq += 1;
    var digest = std.hash.Wyhash.hash(header.local_fp, std.mem.asBytes(&words));
    if (item.* == .text_run) digest = std.hash.Wyhash.hash(digest, item.text_run.content);
    return if (digest == 0) 1 else digest;
}

/// Lower a node clip through exactly the same content/replay transform as its paint.
/// The encoder subsequently applies the surface source-origin offset to both.
/// A scaled polygon is written to `allocator` (the frame allocator).
pub fn lowerNodeClip(allocator: std.mem.Allocator, item: display_list_mod.DisplayItem, transform: Transform2D) !display_list_mod.DisplayItem {
    var clip = item.push_clip;
    const rect = transform.transformRect(ComputedRect.init(clip.x, clip.y, clip.w, clip.h));
    const scale = transform.extractApproxScale();
    clip.x = rect.x;
    clip.y = rect.y;
    clip.w = rect.w;
    clip.h = rect.h;
    for (&clip.radii) |*radius| radius.* *= scale;
    // Node-local corners land on the target-frame corners the transform maps them to (a mirrored
    // or quarter-turned owner keeps each radius on its own corner).
    clip.radii = transform.orientCornerRadii(clip.radii);
    if (clip.polygon) |source| {
        const scaled = try allocator.create(display_list_mod.ClipPolygon);
        scaled.* = source.*;
        for (scaled.points[0..scaled.point_count]) |*point| {
            point[0] *= scale;
            point[1] *= scale;
        }
        clip.polygon = scaled;
    }
    clip.node_local = false;
    return .{ .push_clip = clip };
}

// PT-BRACKET text debug subsystem split to bracket_debug.zig (v0.5 S5 GpuDraw epic B-3
// sub-task); this file focuses core lowering.

// Public types

// Node display payload read-only access (type + three accessors) extracted to
// node_display_payload.zig: zero side effects there, read-only scene_runtime indices;
// this file keeps main lowering path (write buffer). Following re-exports ensure
// public API unchanged from existing call sites.
const node_display_payload = @import("node_display_payload.zig");

pub const DisplayPayloadScope = node_display_payload.DisplayPayloadScope;
pub const TextBlobPayloadScope = node_display_payload.TextBlobPayloadScope;
pub const NodeDisplayPayloadView = node_display_payload.NodeDisplayPayloadView;

// Core playback loop

/// Item's actual destination clip: under CSS overflow semantics a node's own overflow clip only
/// clips descendants, not its own shadow/background/border (`owner_content_exempt`).
/// header.clip_id, per the invariant "each item id == its node value in scene_runtime"
/// (appendCachedCommands rewrites per node_id), is always the node's **own** clip, so the owner's
/// self-content falls back to the parent clip here; descendants (different node_id) use it
/// normally.
/// Without this, an overflow_hidden node's shadow is clipped to its border-box rect (the static
/// card shadow ring vanishes; rounded corners expose a rectangular gray shadow block).
pub fn paintClipIdForItem(cx: *RenderContext, header: display_list_mod.ItemHeader) u32 {
    const clips = cx.property_tree.clips.items;
    if (header.clip_id == INVALID_ID or header.clip_id >= clips.len) return header.clip_id;
    const clip = clips[header.clip_id];
    if (clip.owner_content_exempt and clip.node_id == header.node_id) return clip.parent;
    return header.clip_id;
}

fn appendDisplayItemsToRenderListInternal(
    cx: *RenderContext,
    start: usize,
    end: usize,
    include_structure: bool,
    active_parent_effect_id: u32,
    replay_node: ?*Node,
    replay_exec_state: ?*const NodeExecutionState,
) !void {
    const slice = cx.display_list.items.items[start..@min(end, cx.display_list.items.items.len)];
    // This switch is invariant during a synchronous lowering pass. Resolve it
    // only if an effect group needs it, rather than locking the process
    // environment for every item group (including passes without structure).
    var emit_in_effect: ?bool = null;
    const replay_base_inverse = if (replay_exec_state) |exec_state|
        exec_state.world_transform.invert()
    else
        Transform2D.identity();

    // Effect scope prefix is preserved: adjacent groups sharing the same effect chain prefix keep
    // the scope open **across groups**, only the open/close difference is emitted. Closing and
    // reopening the full chain per group is wrong: begin_blur_layer in the encoder immediately
    // composites the glass backdrop, so one blur island split by clip_id into N groups repaints the
    // backdrop N times, each obscuring the previous group (only the last group is visible), and
    // every reopen reruns the full blur capture + kawase chain.
    // open_scopes/open_ids store the current open chain **outermost-first**.
    var open_scopes: [8]DisplayEffectBridgeScope = undefined;
    var open_ids: [8]u32 = undefined;
    var open_count: usize = 0;
    // Not downgradeable: Begin already in stream, no End = unclosed scope. defer can't propagate
    // error -> panic (same strategy as old).
    defer if (include_structure and open_count > 0) {
        effect_bridge.appendDisplayEffectBridgeEnd(cx, open_scopes[0..open_count]) catch @panic("OOM: display effect bridge end (unbalanced scope)");
    };

    // Clip prefix preserved across groups (same structure as the effect scope above).
    // Main loop groups by (effect_id, clip_id); a virtual list has one clip_id per row. Resending
    // the full ancestor chain per group pushes/pops the shared outermost clip (island corner) 150k
    // times per scroll; each triggers flushAllPending (consumes an SDF uniform slot), 256 slots run
    // out
    // mid-frame, later commands are lost and encode jumps to 10-17ms. Only differences close/open.
    var open_clip_ids: [8]u32 = undefined;
    var open_clip_count: usize = 0;
    defer if (include_structure and open_clip_count > 0) {
        effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count) catch @panic("OOM: display clip bridge end (unbalanced scope)");
    };

    var i: usize = 0;
    while (i < slice.len) {
        const header = slice[i].header();
        const group_clip_id = paintClipIdForItem(cx, header);

        var group_end = i + 1;
        while (group_end < slice.len) {
            const next_header = slice[group_end].header();
            if (next_header.effect_id != header.effect_id or paintClipIdForItem(cx, next_header) != group_clip_id) break;
            group_end += 1;
        }

        var chain_len: usize = 0;
        // Clip coordinate projection depends on current innermost effect; effect scope change means
        // already-open clip prefix no longer usable
        // (see clip prefix preservation note below).
        var effect_scope_changed = false;
        if (include_structure) {
            var chain: [8]node_state.EffectBridgeEntry = undefined;
            const count = effect_bridge.collectEffectBridgeChain(cx, active_parent_effect_id, header.effect_id, &chain);
            chain_len = count;
            // chain is innermost-first; compute outermost-first common prefix
            var common: usize = 0;
            while (common < open_count and common < count and
                open_ids[common] == chain[count - 1 - common].effect_id) common += 1;
            // Clip prefix must close before any Begin/End of effect scope: encoder either skips
            // full begin..end range (GPU retained hit), or
            // restores clip stack snapshot at begin time, both paths assume self-consistent clip.
            // If cross-group-preserved prefix ends in new-opened
            // scope (or left after old scope close), those clip layers permanently leak: tab clip
            // lingering on stack causes all subsequent frame
            // content clipped into tab (edit/hover frame full screen flash white root cause).
            if ((open_count > common or open_count < count) and open_clip_count > 0) {
                try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
                open_clip_count = 0;
            }
            // Close no-longer-needed inner (innermost-first)
            if (open_count > common) {
                effect_scope_changed = true;
                try effect_bridge.appendDisplayEffectBridgeEnd(cx, open_scopes[common..open_count]);
                open_count = common;
            }
            // Open missing (outermost -> innermost)
            while (open_count < count) {
                effect_scope_changed = true;
                const entry = chain[count - 1 - open_count];
                open_scopes[open_count] = try effect_bridge.appendDisplayEffectBridgeBeginEntry(cx, entry, replay_node, replay_exec_state);
                open_ids[open_count] = entry.effect_id;
                open_count += 1;
            }
        }
        // WARNING: with a non-empty effect chain (blur island interior) the clip chain is **not
        // emitted** by
        // default. Emitting it (scroll container clip) targets the "island interior container not
        // clipped"
        // gap, but the projection frame is unresolved: the scrollbar thumb (container absolute
        // child) is
        // clipped invisible while row content is fine, i.e. clip projection and an item coordinate
        // frame
        // mismatch. Row overflow clip is handled by emitScrollClipBegin/End (children envelope,
        // mod.zig).
        // Set ZENIT_ENABLE_EFFECT_CLIP_BRIDGE=1 explicitly to continue investigation.
        const innermost_effect_for_clip: u32 =
            if (open_count > 0) open_ids[open_count - 1] else active_parent_effect_id;
        const want_clip = include_structure and (chain_len == 0 or blk: {
            if (emit_in_effect == null) emit_in_effect = @import("zenit_environment").flag("ZENIT_ENABLE_EFFECT_CLIP_BRIDGE");
            break :blk emit_in_effect.?;
        });

        // On effect scope change clip must fully reopen: clip coordinates relative to
        // `innermost_effect_for_clip` projection (see
        // appendDisplayClipBridgeBeginSuffix active_parent_inverse), changing effect frame can't
        // reuse old push.
        if (effect_scope_changed and open_clip_count > 0) {
            try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
            open_clip_count = 0;
        }

        if (want_clip) {
            var clip_chain: [8]u32 = undefined;
            const clip_len = effect_bridge.collectDisplayClipChainPublic(cx, group_clip_id, &clip_chain);
            // chain is innermost-first; compute outermost-first common prefix.
            var common: usize = 0;
            while (common < open_clip_count and common < clip_len and
                open_clip_ids[common] == clip_chain[clip_len - 1 - common]) common += 1;
            if (open_clip_count > common) {
                try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count - common);
                open_clip_count = common;
            }
            if (clip_len > common) {
                const emitted = try effect_bridge.appendDisplayClipBridgeBeginSuffix(
                    cx,
                    group_clip_id,
                    innermost_effect_for_clip,
                    chain_len != 0,
                    common,
                );
                // only_scroll filter may emit fewer than chain length; account by actual emit
                // count, else End count won't match Begin.
                var k: usize = 0;
                while (k < emitted and open_clip_count < open_clip_ids.len) : (k += 1) {
                    open_clip_ids[open_clip_count] = clip_chain[clip_len - 1 - common - k];
                    open_clip_count += 1;
                }
            }
        } else if (open_clip_count > 0) {
            try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
            open_clip_count = 0;
        }

        // By pointer: a by-value capture copies every item of the frame (a few hundred bytes each).
        for (slice[i..group_end]) |*item_ref| {
            const item = item_ref;
            const item_header = item.header();
            cx.lowering_fp_transform = null;

            // Literal controls are already lowered, may have INVALID transform IDs. Node-local
            // clips must reach
            // the same transform path as paint items. Control-header items (e.g.
            // begin/end_opacity_layer from
            // custom_draw, Snapshot.appendTo wrapping for anchor/scale/opacity) must not be
            // silently discarded
            // here, else the wrapping is lost and the snapshot paints at local (0,0), not its
            // anchor. The
            // effect_bridge path is unaffected: it uses appendLoweredBoth and writes the paint list
            // directly.
            if (item_header.already_lowered or (isControlItem(item) and !(item.* == .push_clip and item.push_clip.node_local))) {
                // Clip prefix bridge can't cross layer boundary token: encoder either skips full
                // begin..end range (GPU retained hit), or restores clip
                // stack snapshot at begin, both paths assume self-consistent clip. If
                // cross-group-preserved prefix ends in range (pop closes range-external
                // push), those clip layers permanently leak: tab clip lingering on stack causes all
                // subsequent frame content clipped into tab
                // (edit/hover frame full screen flash white root cause). Hit boundary, close first,
                // defer after current group reopen.
                const is_layer_boundary = switch (item.*) {
                    .begin_opacity_layer,
                    .end_opacity_layer,
                    .begin_blur_layer,
                    .end_blur_layer,
                    .begin_rounded_clip,
                    .end_rounded_clip,
                    => true,
                    else => false,
                };
                if (is_layer_boundary and open_clip_count > 0) {
                    try effect_bridge.appendDisplayClipBridgeEnd(cx, open_clip_count);
                    open_clip_count = 0;
                }
                try appendLoweredBoth(cx, item.*);
                if (is_layer_boundary and want_clip) {
                    var boundary_chain: [8]u32 = undefined;
                    const boundary_len = effect_bridge.collectDisplayClipChainPublic(cx, group_clip_id, &boundary_chain);
                    if (boundary_len > 0) {
                        const emitted = try effect_bridge.appendDisplayClipBridgeBeginSuffix(
                            cx,
                            group_clip_id,
                            innermost_effect_for_clip,
                            chain_len != 0,
                            0,
                        );
                        var k: usize = 0;
                        while (k < emitted and open_clip_count < open_clip_ids.len) : (k += 1) {
                            open_clip_ids[open_clip_count] = boundary_chain[boundary_len - 1 - k];
                            open_clip_count += 1;
                        }
                    }
                }
                continue;
            }

            if (item_header.transform_id >= cx.property_tree.transforms.items.len) continue;
            // Stage B S5.2: when replay_exec_state != null (subtree replay), use
            // inverse_replay_base
            // world + paint main path; replay_exec_state == null (derive path) uses
            // transform.content (includes surface_inverse * world), equivalent to subtree replay's
            // inverse.
            // Note: after P6.3 all overlays (modal + non_modal) use unified composited_group
            // surface.
            const world = cx.property_tree.transforms.items[item_header.transform_id].world;
            const content = cx.property_tree.transforms.items[item_header.transform_id].content;
            const item_transform = if (replay_exec_state != null)
                replay_base_inverse.mul(world)
            else
                content;
            const scale = item_transform.extractApproxScale();

            // lowering writes DisplayItem (lower-ed fields). header reuses item.header (includes
            // transform_id/clip_id/effect_id), but paint variant's x/y/w/h already lower-ed to
            // world coord, encoder no longer transforms twice.
            const lowered_header = item_header;
            // Everything below is a function of the recorded item and this transform
            // (plus the text it resolves, hashed in appendLoweredBoth).
            cx.lowering_fp_transform = item_transform;
            cx.lowering_fp_seq = 0;
            defer cx.lowering_fp_transform = null;
            switch (item.*) {
                .fill_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .fill_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .radius = scaleLocalRadii(it.radius, scale),
                            // WARNING: field-by-field reconstruction lowering: **new fields must be
                            // manually added**,
                            // missing field silently loses value (ellipse reverts to rounded rect).
                            .shape = it.shape,
                        },
                    });
                },
                .stroke_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .stroke_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                            .shape = it.shape,
                        },
                    });
                },
                .border_side => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    const clip_rect = item_transform.transformRect(ComputedRect.init(it.clip_x, it.clip_y, it.clip_w, it.clip_h));
                    try appendLoweredBoth(cx, .{
                        .push_clip = .{
                            .header = CONTROL_HEADER,
                            .x = clip_rect.x,
                            .y = clip_rect.y,
                            .w = clip_rect.w,
                            .h = clip_rect.h,
                            .radii = scaleLocalRadii(it.clip_radii, scale),
                            .shape_kind = it.clip_shape_kind,
                            .polygon = it.clip_polygon,
                        },
                    });
                    try appendLoweredBoth(cx, .{
                        .stroke_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                    try appendLoweredBoth(cx, .{ .pop_clip = .{ .header = CONTROL_HEADER } });
                },
                .border_per_side => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .border_per_side = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .widths = .{ it.widths[0] * scale, it.widths[1] * scale, it.widths[2] * scale, it.widths[3] * scale },
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .gradient_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .gradient_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .from = it.from,
                            .to = it.to,
                            .direction = it.direction,
                            .radius = scaleLocalRadii(it.radius, scale),
                            // Like multi_gradient_rect: field-by-field reconstruction, miss one
                            // silently loses.
                            .radial_center_x = it.radial_center_x,
                            .radial_center_y = it.radial_center_y,
                            .conic_start_angle = it.conic_start_angle,
                            .extend_mode = it.extend_mode,
                            .shape = it.shape,
                        },
                    });
                },
                .shadow_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .shadow_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .blur = it.blur * scale,
                            .offset_x = it.offset_x * scale,
                            .offset_y = it.offset_y * scale,
                            .spread = it.spread * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .outline_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .outline_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .color = it.color,
                            .width = it.width * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .text_run => |*it| {
                    const origin = item_transform.applyPoint(it.x, it.y);
                    const resolved_content = display_list_mod.resolveTextRunContent(cx.text_blob_store, it.*);
                    if (bracket_debug.bracketRenderDebugEnabled() and resolved_content.len == 1 and
                        (bracket_debug.bracketDebugNodeFilter() == null or item_header.node_id == bracket_debug.bracketDebugNodeFilter().?) and
                        bracket_debug.shouldLogBracketReplay(cx.scene_runtime.frame_epoch, item_header.node_id, it.blob_byte_start, it.blob_byte_end))
                    {
                        std.debug.print(
                            "[PT-BRACKET] frame={d} replay node={d} origin=({d:.1},{d:.1}) range=[{d},{d}) text=\"{s}\" clip={d} effect={d}\n",
                            .{
                                cx.scene_runtime.frame_epoch,
                                item_header.node_id,
                                origin.x,
                                origin.y,
                                it.blob_byte_start,
                                it.blob_byte_end,
                                resolved_content,
                                item_header.clip_id,
                                item_header.effect_id,
                            },
                        );
                    }
                    if (resolved_content.len == 0 and (it.content.len > 0 or it.blob_byte_end > it.blob_byte_start)) {
                        const blob_exists = it.blob_id != INVALID_ID and cx.text_blob_store.get(it.blob_id) != null;
                        text_trace.log(
                            cx.scene_runtime.frame_epoch,
                            "replay-empty-text node={d} blob={d} blob_exists={} raw_len={d} range=[{d}..{d}) scale={d:.2} clip={d} effect={d}",
                            .{
                                item_header.node_id,
                                it.blob_id,
                                blob_exists,
                                it.content.len,
                                it.blob_byte_start,
                                it.blob_byte_end,
                                scale,
                                item_header.clip_id,
                                item_header.effect_id,
                            },
                        );
                    }
                    try appendLoweredBoth(cx, .{
                        .text_run = .{
                            .header = lowered_header,
                            .x = origin.x,
                            .y = origin.y,
                            .content = resolved_content,
                            .blob_byte_start = it.blob_byte_start,
                            .blob_byte_end = it.blob_byte_end,
                            .color = it.color,
                            .font_size = it.font_size * scale,
                            .font_weight = it.font_weight,
                            .font_family = it.font_family,
                            .use_symbols_font = it.use_symbols_font,
                            .use_monospace_font = it.use_monospace_font,
                            .monospace_char_width = it.monospace_char_width * scale,
                            .use_italic_font = it.use_italic_font,
                            .font_smoothing = it.font_smoothing,
                            .spans = it.spans,
                            .blob_id = it.blob_id,
                            .blob_content_hash = it.blob_content_hash,
                            // blob_id must be transmitted together with its content_hash. blob_id
                            // is a frame-local sequence
                            // number (store clears and reallocates each frame);
                            // resolveTextRunContent uses blob_content_hash
                            // to detect "this sequence number changed owner". If it's never
                            // transmitted it stays 0, the identity
                            // check short-circuits to an always-true `run.blob_content_hash == 0`,
                            // and a re-lowered item takes the
                            // old sequence number and slices **another blob** in this frame's
                            // bytes.
                            .raster_policy = it.raster_policy,
                            .fade_dx0 = it.fade_dx0 * scale,
                            .fade_dx1 = it.fade_dx1 * scale,
                        },
                    });
                },
                .image_quad => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .image_quad = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .texture_id = it.texture_id,
                            .tint = it.tint,
                            .corner_radius = it.corner_radius * scale,
                            .opacity = it.opacity,
                        },
                    });
                },
                .icon_rep => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .icon_rep = .{
                            .header = lowered_header,
                            .icon_id = it.icon_id,
                            .rep_size = it.rep_size,
                            .rep = it.rep,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .tint = it.tint,
                            .corner_clip_radius = it.corner_clip_radius * scale,
                            .opacity = it.opacity,
                            .snap = it.snap,
                        },
                    });
                },
                .arc => |*it| {
                    const center = item_transform.applyPoint(it.cx, it.cy);
                    try appendLoweredBoth(cx, .{
                        .arc = .{
                            .header = lowered_header,
                            .cx = center.x,
                            .cy = center.y,
                            .outer_radius = it.outer_radius * scale,
                            .stroke_width = it.stroke_width * scale,
                            .start_angle = it.start_angle,
                            .end_angle = it.end_angle,
                            .color = it.color,
                        },
                    });
                },
                .multi_gradient_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .multi_gradient_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .direction = it.direction,
                            .radius = scaleLocalRadii(it.radius, scale),
                            .stop_colors = it.stop_colors,
                            .stop_positions = it.stop_positions,
                            .stop_count = it.stop_count,
                            // WARNING: field-by-field reconstruction: miss one field silently
                            // loses. The next four originally
                            // **all missed**: shape missed made ellipse gradient fill bounding box;
                            // radial/conic center and
                            // start angle, extend_mode missed made radial/conic gradient fall back
                            // to default params.
                            .radial_center_x = it.radial_center_x,
                            .radial_center_y = it.radial_center_y,
                            .radial_radius_x = it.radial_radius_x,
                            .radial_radius_y = it.radial_radius_y,
                            .conic_start_angle = it.conic_start_angle,
                            .extend_mode = it.extend_mode,
                            .shape = it.shape,
                        },
                    });
                },
                .noise_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .noise_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .mode = it.mode,
                            .scale = it.scale,
                            .intensity = it.intensity,
                            .seed = it.seed,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .inset_shadow_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .inset_shadow_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .shadow_color = it.shadow_color,
                            .blur = it.blur * scale,
                            .offset_x = it.offset_x * scale,
                            .offset_y = it.offset_y * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .shadow_dual_rect => |*it| {
                    const rect = item_transform.transformRect(ComputedRect.init(it.x, it.y, it.w, it.h));
                    try appendLoweredBoth(cx, .{
                        .shadow_dual_rect = .{
                            .header = lowered_header,
                            .x = rect.x,
                            .y = rect.y,
                            .w = rect.w,
                            .h = rect.h,
                            .fill = it.fill,
                            .shadow1_color = it.shadow1_color,
                            .shadow1_blur = it.shadow1_blur * scale,
                            .shadow1_offset_x = it.shadow1_offset_x * scale,
                            .shadow1_offset_y = it.shadow1_offset_y * scale,
                            .shadow2_color = it.shadow2_color,
                            .shadow2_blur = it.shadow2_blur * scale,
                            .shadow2_offset_x = it.shadow2_offset_x * scale,
                            .shadow2_offset_y = it.shadow2_offset_y * scale,
                            .radius = scaleLocalRadii(it.radius, scale),
                        },
                    });
                },
                .fill_path => |*it| {
                    const origin = item_transform.applyPoint(it.offset_x, it.offset_y);
                    try appendLoweredBoth(cx, .{
                        .fill_path = .{
                            .header = lowered_header,
                            .geometry = it.geometry,
                            .color = it.color,
                            .offset_x = origin.x,
                            .offset_y = origin.y,
                            .opacity = it.opacity,
                            // WARNING: field-by-field reconstruction: gradient missing makes
                            // polygon fill revert to solid.
                            .gradient_direction = it.gradient_direction,
                            .gradient_stop_colors = it.gradient_stop_colors,
                            .gradient_stop_positions = it.gradient_stop_positions,
                            .gradient_stop_count = it.gradient_stop_count,
                            .gradient_center_x = it.gradient_center_x,
                            .gradient_center_y = it.gradient_center_y,
                            .gradient_start_angle = it.gradient_start_angle,
                        },
                    });
                },
                .stroke_path => |*it| {
                    const origin = item_transform.applyPoint(it.offset_x, it.offset_y);
                    try appendLoweredBoth(cx, .{
                        .stroke_path = .{
                            .header = lowered_header,
                            .geometry = it.geometry,
                            .color = it.color,
                            .width = it.width * scale,
                            .line_join = it.line_join,
                            .offset_x = origin.x,
                            .offset_y = origin.y,
                            .opacity = it.opacity,
                        },
                    });
                },
                // Stage B R3f: effect/clip literal tokens 1:1 passthrough (fields already lower-ed)
                .push_clip => try appendLoweredBoth(cx, try lowerNodeClip(cx.frame_allocator, item.*, item_transform)),
                .pop_clip => |*it| try appendLoweredBoth(cx, .{ .pop_clip = it.* }),
                .begin_opacity_layer => |*it| try appendLoweredBoth(cx, .{ .begin_opacity_layer = it.* }),
                .end_opacity_layer => |*it| try appendLoweredBoth(cx, .{ .end_opacity_layer = it.* }),
                .begin_blur_layer => |*it| try appendLoweredBoth(cx, .{ .begin_blur_layer = it.* }),
                .end_blur_layer => |*it| try appendLoweredBoth(cx, .{ .end_blur_layer = it.* }),
                .begin_rounded_clip => |*it| try appendLoweredBoth(cx, .{ .begin_rounded_clip = it.* }),
                .end_rounded_clip => |*it| try appendLoweredBoth(cx, .{ .end_rounded_clip = it.* }),
            }
        }
        i = group_end;
    }
}

// Public API

pub const getNodeDisplayItems = node_display_payload.getNodeDisplayItems;
pub const getNodeTextBlobs = node_display_payload.getNodeTextBlobs;
pub const getNodeDisplayPayload = node_display_payload.getNodeDisplayPayload;

/// Stage B R3f: lower entire cx.display_list to cx.lowering.main (world coordinate +
/// lower-ed field DisplayItem stream) for encoder consumption. Currently only translation
/// entry at end of cx.render().
/// Freeze a displayed subtree without opening its ancestor effect scopes.
pub fn appendSnapshotDisplayItems(cx: *RenderContext, start: usize, end: usize, parent_effect_id: u32) !void {
    try appendDisplayItemsToRenderListInternal(cx, start, end, true, parent_effect_id, null, null);
}

pub fn appendAllDisplayItemsToRenderList(cx: *RenderContext) !void {
    const len = cx.display_list.items.items.len;
    if (len == 0) return;
    try appendDisplayItemsToRenderListInternal(cx, 0, len, true, INVALID_ID, null, null);
}

pub fn appendNodeDisplayPayloadToRenderList(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) !bool {
    const payload = getNodeDisplayPayload(cx, node_id, scope) orelse return false;
    if (payload.items.len == 0) return false;

    const runtime = cx.scene_runtime.getPtr(node_id) orelse return false;
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    try appendDisplayItemsToRenderListInternal(cx, start, start + payload.items.len, true, INVALID_ID, null, null);
    return true;
}

pub fn appendNodeDisplayPayloadToRenderListForReplay(
    cx: *RenderContext,
    node: *Node,
    exec_state: *const NodeExecutionState,
    strategy: scene_runtime_mod.DisplayPayloadSubtreeStrategy,
    scope: DisplayPayloadScope,
    active_parent_effect_id: u32,
) !bool {
    const payload = getNodeDisplayPayload(cx, node.id, scope) orelse return false;
    if (payload.items.len == 0) return false;
    const runtime = cx.scene_runtime.getPtr(node.id) orelse return false;

    if (text_trace.enabled()) {
        var text_item_count: usize = 0;
        var blob_backed_text_item_count: usize = 0;
        var min_blob_id: u32 = std.math.maxInt(u32);
        var max_blob_id: u32 = 0;
        for (payload.items) |item| {
            switch (item) {
                .text_run => |run| {
                    text_item_count += 1;
                    if (run.blob_id != INVALID_ID and run.blob_byte_end > run.blob_byte_start) {
                        blob_backed_text_item_count += 1;
                        min_blob_id = @min(min_blob_id, run.blob_id);
                        max_blob_id = @max(max_blob_id, run.blob_id);
                    }
                },
                else => {},
            }
        }
        if (text_item_count > 0 and blob_backed_text_item_count > 0 and payload.blobs.len < blob_backed_text_item_count) {
            const runtime_blob_start: u32 = switch (scope) {
                .own => runtime.text_blob_start,
                .subtree => runtime.subtree_text_blob_start,
            };
            const runtime_blob_count: u32 = switch (scope) {
                .own => runtime.text_blob_count,
                .subtree => runtime.subtree_text_blob_count,
            };
            text_trace.log(
                cx.scene_runtime.frame_epoch,
                "payload-replay-shared-blob-ref node={d} scope={s} strategy={s} items={d} text_items={d} blob_text_items={d} runtime_blob_range=[{d}..{d}) payload_blobs={d} run_blob_range=[{d}..{d}]",
                .{
                    node.id,
                    @tagName(scope),
                    @tagName(strategy),
                    payload.items.len,
                    text_item_count,
                    blob_backed_text_item_count,
                    runtime_blob_start,
                    runtime_blob_start + runtime_blob_count,
                    payload.blobs.len,
                    if (min_blob_id == std.math.maxInt(u32)) 0 else min_blob_id,
                    max_blob_id,
                },
            );
        }
    }
    // The replay's items are already in the display list; only the paint-pass lowering copy
    // remains, which the caller does not want (see RenderContext.paint_pass_lowering).
    if (!cx.paint_pass_lowering) return true;
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    const uses_self_effect_space = scene_runtime_mod.displayPayloadSubtreeStrategyUsesSelfEffectSpace(strategy);
    try appendDisplayItemsToRenderListInternal(
        cx,
        start,
        start + payload.items.len,
        true,
        active_parent_effect_id,
        if (uses_self_effect_space) node else null,
        if (uses_self_effect_space) exec_state else null,
    );
    return true;
}
