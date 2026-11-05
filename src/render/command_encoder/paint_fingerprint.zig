//! command_encoder/paint_fingerprint.zig: pure-function toolkit for paint commands.
//!
//! Common trait: **zero encoder-instance state dependency**. All are `fn(anytype) -> value` pure
//! functions depending only on the passed paint command.
//!
//! Three responsibility groups:
//! 1. **damage bounds**: pixel range affected by one command, for damage-rect partial-redraw
//!    dirty-union. Contract: **prefer overestimate**: a missed pixel = stale content persists.
//! 2. **content fingerprint**: feed command fields affecting pixels into a hasher, for retained
//!    layer hit judgment. Contract: **prefer over-feed**: a missing feed = changed content but a
//!    hit = stale frame.
//! 3. **structural folding**: detect empty begin/end blocks, skip the whole span.
//!
//! WARNING: before changing any function here, read both contracts above: the failure mode is a
//! **stale frame**, not a crash; e2e may not catch it.

const std = @import("std");

// Structural token classification, pure function in same cluster as tryFindNoOpStructuralBlock.
pub const StructuralToken = enum {
    none,
    begin_clip,
    end_clip,
    begin_rounded_clip,
    end_rounded_clip,
    begin_blur_layer,
    end_blur_layer,
    begin_opacity_layer,
    end_opacity_layer,
};

pub inline fn structuralToken(it: anytype) StructuralToken {
    if (it.kind != .control) return .none;
    return switch (it.control_kind) {
        .push_clip => .begin_clip,
        .pop_clip => .end_clip,
        .begin_rounded_clip => .begin_rounded_clip,
        .end_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .begin_blur_layer,
        .end_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .begin_opacity_layer,
        .end_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

pub inline fn isBeginStructuralToken(tok: StructuralToken) bool {
    return switch (tok) {
        .begin_clip, .begin_rounded_clip, .begin_blur_layer, .begin_opacity_layer => true,
        else => false,
    };
}

pub inline fn matchingEndStructuralToken(begin_tok: StructuralToken) StructuralToken {
    return switch (begin_tok) {
        .begin_clip => .end_clip,
        .begin_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

/// Window-space bounds of an effect/clip group's begin token. A group with a
/// surface transform carries its surface-local source rect in `geom` and its
/// window-space draw rect in `draw_*`; the group writes pixels only there.
pub fn groupWorldBounds(it: anytype) [4]f32 {
    const pad: f32 = 2;
    if (it.use_draw_transform) return .{ it.draw_x - pad, it.draw_y - pad, it.draw_w + 2 * pad, it.draw_h + 2 * pad };
    return damageItemBounds(it);
}

const unbounded_rect: [4]f32 = .{ -1e7, -1e7, 2e7, 2e7 };

/// Window-space rect containing every pixel an item can change; for a group
/// begin token, every pixel its whole group can change. Items drawn through a
/// draw transform have surface-local geometry and are unbounded here.
pub fn inkWorldBounds(it: anytype) [4]f32 {
    if (it.kind == .control) return switch (it.control_kind) {
        .begin_blur_layer => glassInkBounds(it),
        .begin_opacity_layer, .begin_rounded_clip => groupWorldBounds(it),
        .push_clip => damageItemBounds(it),
        else => .{ 0, 0, 0, 0 },
    };
    if (it.use_draw_transform) return unbounded_rect;
    if (it.kind == .path) {
        const b = pathItemBounds(it);
        const pad = @max(it.stroke_width, 0) + 2;
        return .{ b[0] - pad, b[1] - pad, b[2] + 2 * pad, b[3] + 2 * pad };
    }
    return damageItemBounds(it);
}

fn glassNodeRect(it: anytype) [4]f32 {
    const nan_draw = std.math.isNan(it.draw_x) or std.math.isNan(it.draw_y) or std.math.isNan(it.draw_w) or std.math.isNan(it.draw_h);
    return if (nan_draw) .{ it.geom.x, it.geom.y, it.geom.w, it.geom.h } else .{ it.draw_x, it.draw_y, it.draw_w, it.draw_h };
}

/// Pixels a glass composite writes, window space: the node and GlassGroup
/// member shapes with their shadows, plus a 4 px fringe margin.
pub fn glassWrittenBounds(it: anytype) [4]f32 {
    const r = glassNodeRect(it);
    const margin: f32 = 4;
    var lo: [2]f32 = .{ r[0] - margin, r[1] - margin };
    var hi: [2]f32 = .{ r[0] + r[2] + margin, r[1] + r[3] + margin };
    if (it.glass_ptr) |gp| {
        const g = gp.*;
        if (comptime @typeInfo(@TypeOf(g)) == .@"struct" and @hasField(@TypeOf(g), "group")) if (g.group) |grp| {
            // Member shapes are container-local (scaled by the draw/local ratio).
            const sx: f32 = if (it.geom.w > 0) r[2] / it.geom.w else 1;
            const sy: f32 = if (it.geom.h > 0) r[3] / it.geom.h else 1;
            for (grp.shapes[0..@min(grp.count, grp.shapes.len)]) |sh| {
                if (sh.w <= 0.5 or sh.h <= 0.5) continue;
                const ext = (if (sh.shadow_alpha > 0.001) sh.shadow_blur + @max(@abs(sh.shadow_offset_x), @abs(sh.shadow_offset_y)) else 0) * @max(sx, sy) + margin;
                lo = .{ @min(lo[0], r[0] + sh.x * sx - ext), @min(lo[1], r[1] + sh.y * sy - ext) };
                hi = .{ @max(hi[0], r[0] + (sh.x + sh.w) * sx + ext), @max(hi[1], r[1] + (sh.y + sh.h) * sy + ext) };
            }
        };
    }
    return .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] };
}

/// Everything a glass composite reads or writes, window space: its written
/// area and the backdrop it samples (glassReadBounds).
fn glassInkBounds(it: anytype) [4]f32 {
    const written = glassWrittenBounds(it);
    const read = glassReadBounds(it);
    const x0 = @min(read[0], written[0]);
    const y0 = @min(read[1], written[1]);
    const x1 = @max(read[0] + read[2], written[0] + written[2]);
    const y1 = @max(read[1] + read[3], written[1] + written[3]);
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

/// Window-space rect containing the backdrop a glass composite samples
/// (backdrop_blur.tryBackdropBlur's capture rect, before clipping): the node
/// padded by max(geometry pad, blur reach, member shadow reach), or, for the
/// native material, by the CABackdropLayer margin of its backdrop bounds plus
/// how far those bounds overflow the node; snapped outward to the window's
/// 4 px grid. Overestimates: the margin is taken from the written area (which
/// holds the member bounding box) and the grid slack in logical px. No pad
/// with capture_clamp is still covered by the larger pads.
pub fn glassReadBounds(it: anytype) [4]f32 {
    const r = glassNodeRect(it);
    const written = glassWrittenBounds(it);
    var pad: f32 = 130;
    if (it.glass_ptr) |gp| {
        const g = gp.*;
        if (comptime @typeInfo(@TypeOf(g)) == .@"struct" and @hasField(@TypeOf(g), "backdrop_blur")) {
            const overflow = @max(@max(@max(r[0] - written[0], r[1] - written[1]), @max(written[0] + written[2] - (r[0] + r[2]), written[1] + written[3] - (r[1] + r[3]))), 0);
            const base = @max(@max(std.math.clamp(0.35 * @min(r[2], r[3]) + 8, 12, 80), @min(g.backdrop_blur, 96)), overflow + 2);
            const native = @import("../backdrop_blur.zig").nativeBackdropMargin(@min(written[2], written[3])) + overflow;
            pad = @max(base, native);
        }
    }
    // Grid snap (up to 4 device px, at most 4 logical px) and two device
    // pixels of rounding.
    const m: f32 = 6;
    return .{ r[0] - pad - m, r[1] - pad - m, r[2] + 2 * (pad + m), r[3] + 2 * (pad + m) };
}

/// damage-rect: conservative over-expanded bounds for one command. Prefer overestimate; miss one
/// dirty pixel = stale pixel persists.
pub fn damageItemBounds(it: anytype) [4]f32 {
    const sh1 = it.shadow_blur * 2 + @max(@abs(it.shadow_offset_x), @abs(it.shadow_offset_y)) + @max(0, it.shadow_spread);
    const sh2 = it.shadow2_blur * 2 + @max(@abs(it.shadow2_offset_x), @abs(it.shadow2_offset_y));
    var pad: f32 = 2 + it.stroke_width + @max(sh1, sh2);
    // Text glyphs may overflow measurement box (italic overhang / descenders), extra margin.
    if (it.kind == .text) pad += 8;
    var y = it.geom.y;
    var w = it.geom.w;
    var h = it.geom.h;
    if (it.kind == .text) {
        // WARNING: a text command's geom.w/h is **always 0** (lowering only fills the draw origin;
        // see the
        // .text_run branch in render_engine/gpu_draw_shadow.zig). Computing bounds directly yields
        // a tiny
        // ~20px pad*2 region around the origin; only the first one or two chars per line enter the
        // dirty
        // area and the rest keep previous-frame pixels (e.g. '3 x 4' -> '3 x 5': dirty x in
        // [331,351]
        // covers only the lead glyph, trailing '5' at x=368 stays stale).
        //
        // So use a conservative upper bound from content length: max 1 em (font_size) per byte; for
        // monospace, use the explicit cell width. Contract: prefer overestimate; overestimating
        // redraws a
        // few pixels, underestimating leaves stale pixels.
        const per_byte = if (it.text_monospace_char_width > 0)
            it.text_monospace_char_width
        else
            it.text_font_size;
        const n: f32 = @floatFromInt(it.text_content.len);
        w = @max(w, n * per_byte);
        // WARNING: text's geom.y is the **baseline** (text_item_render fills baseline_y in all
        // .text_run
        // branches); glyphs draw **above** it (glyph_y = cursor_y - bearing_y). A [y, y+2fs] range
        // misses
        // ascenders entirely: at fs>=14 the retained layer keeps stale pixels at the text top / new
        // glyphs
        // get clipped. Use 1.3em above (covers CJK/emoji/accented capitals ascent), 0.6em below
        // (descenders + inline decoration).
        const fs = @max(it.text_font_size, 0);
        y -= fs * 1.3;
        h = @max(h, fs * 1.9);
    }
    // Rotation (image/icon rotates around center, see rotate param in addImage/addIcon):
    // axis-aligned
    // geom doesn't cover rotated corners, rotation animation leaves trails at corners. Use
    // circumscribed circle like local_sort.localSortImageLikeBounds.
    if (it.kind != .text and @abs(it.rotate) > 0.0001) {
        const cx = it.geom.x + w * 0.5;
        const cy = it.geom.y + h * 0.5;
        const r = 0.5 * @sqrt(w * w + h * h) + pad;
        return .{ cx - r, cy - r, r * 2, r * 2 };
    }
    return .{
        it.geom.x - pad,
        y - pad,
        w + pad * 2,
        h + pad * 2,
    };
}

/// damage-rect: conservative bounds for path command. path's geom.w/h always 0 (lowering only fills
/// offset); bounds must compute from points. Quad/cubic control points upper-bound curve's convex
/// hull, include directly (over-inclusive but safe).
pub fn pathItemBounds(it: anytype) [4]f32 {
    // arc (spinner/progress ring) reuses the `.path` kind but has **no** path_geometry_ptr; geom is
    // the
    // center, w/h always 0. Without special handling the dirty region is only the center point, and
    // a
    // Spinner in a retained layer (Modal/Sheet/Popover) with partial redraw gets its ring
    // scissor-clipped and freezes on screen. Criteria match isArcCommand / localSortArcBounds (only
    // checks arc_outer_radius); over-expand by stroke_width + 2px AA margin (prefer overestimate).
    if (it.arc_outer_radius > 0) {
        const r = it.arc_outer_radius + @max(it.stroke_width, 0) + 2;
        return .{ it.geom.x - r, it.geom.y - r, r * 2, r * 2 };
    }
    const pg = it.path_geometry_ptr orelse
        return .{ it.geom.x, it.geom.y, 0, 0 };
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var any = false;
    for (pg.commands) |cmd| {
        switch (cmd) {
            .move_to, .line_to => |pt| {
                min_x = @min(min_x, pt.x);
                min_y = @min(min_y, pt.y);
                max_x = @max(max_x, pt.x);
                max_y = @max(max_y, pt.y);
                any = true;
            },
            .quad_to => |q| {
                min_x = @min(min_x, @min(q.ctrl.x, q.end.x));
                min_y = @min(min_y, @min(q.ctrl.y, q.end.y));
                max_x = @max(max_x, @max(q.ctrl.x, q.end.x));
                max_y = @max(max_y, @max(q.ctrl.y, q.end.y));
                any = true;
            },
            .cubic_to => |c| {
                min_x = @min(min_x, @min(c.ctrl1.x, @min(c.ctrl2.x, c.end.x)));
                min_y = @min(min_y, @min(c.ctrl1.y, @min(c.ctrl2.y, c.end.y)));
                max_x = @max(max_x, @max(c.ctrl1.x, @max(c.ctrl2.x, c.end.x)));
                max_y = @max(max_y, @max(c.ctrl1.y, @max(c.ctrl2.y, c.end.y)));
                any = true;
            },
            .close => {},
        }
    }
    if (!any) return .{ it.geom.x, it.geom.y, 0, 0 };
    // stroke expands half width outward, join/cap adds 1x more; +2 base pad.
    const pad: f32 = 2 + it.stroke_width * 1.5;
    return .{
        it.geom.x + min_x - pad,
        it.geom.y + min_y - pad,
        (max_x - min_x) + pad * 2,
        (max_y - min_y) + pad * 2,
    };
}

/// damage-rect: composite rect of nested opacity sublayer (geom union draw rect union axis-aligned
/// transform rect, over-expand 4px to tolerate composite bilinear/rounded edges). Rotation /
/// non-axis-aligned transform returns null -> that top-level layer judges unsafe.
pub fn nestedCompositeBounds(it: anytype) ?[4]f32 {
    if (it.rotate != 0) return null;
    var min_x = it.geom.x;
    var min_y = it.geom.y;
    var max_x = it.geom.x + it.geom.w;
    var max_y = it.geom.y + it.geom.h;
    if (it.use_draw_transform) {
        const t = it.draw_transform;
        if (t[1] != 0 or t[2] != 0 or t[0] <= 0 or t[3] <= 0) return null;
        // dt composite: geom.xy is nested-local content envelope origin, independent of parent
        // coords;
        // composite rect depends only on transform (t4,t5,a·w,d·h).
        min_x = t[4];
        min_y = t[5];
        max_x = t[4] + t[0] * it.geom.w;
        max_y = t[5] + t[3] * it.geom.h;
    } else if (!std.math.isNan(it.draw_x) and it.draw_w > 0 and it.draw_h > 0) {
        min_x = @min(min_x, it.draw_x);
        min_y = @min(min_y, it.draw_y);
        max_x = @max(max_x, it.draw_x + it.draw_w);
        max_y = @max(max_y, it.draw_y + it.draw_h);
    }
    const pad: f32 = 4;
    return .{ min_x - pad, min_y - pad, (max_x - min_x) + pad * 2, (max_y - min_y) + pad * 2 };
}

/// Strictly increasing across every encoded frame of every window (not a
/// per-window frame index: two windows' indices can coincide, and a frame's
/// damage pass hashes before its own encoder begins). Items whose pixels are
/// reseeded every frame mix it into their fingerprint so neither the damage
/// tracker nor a retained surface treats them as unchanged. Rendering is
/// serial on the main thread.
pub var frame_salt: u64 = 0;
pub fn nextFrameSalt() void {
    frame_salt +%= 1;
}

pub fn hashPaintItemInto(hasher: *std.hash.Wyhash, it: anytype) void {
    hashPaintItem(hasher, it, true, null);
}

/// Synchronous caret preparation compares separate lowered frames. Glass
/// and icon payloads are arena copies, so their addresses are not content.
/// Retained encoding keeps its existing within-frame identity contract above.
/// Content fingerprint of one paint item: the digest the UI computed when it
/// lowered the item (paint_table.DisplayItem.paint_digest, see
/// display_list_lowering.loweredDigest), or this module's own hash when it
/// left none. Never 0.
pub fn itemDigest(it: anytype) u64 {
    const Item = switch (@typeInfo(@TypeOf(it))) {
        .pointer => |p| p.child,
        else => @TypeOf(it),
    };
    if (comptime @hasField(Item, "paint_digest")) {
        if (it.paint_digest != 0) return it.paint_digest;
    }
    return fullItemDigest(it);
}

/// hashCaretPaintItemInto of the item alone (never 0): what itemDigest falls
/// back to, and what ZENIT_VERIFY_PAINT_DIGEST checks the UI digest against.
pub fn fullItemDigest(it: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    hashCaretPaintItemInto(&h, it);
    const d = h.final();
    return if (d == 0) 1 else d;
}

pub fn hashCaretPaintItemInto(hasher: *std.hash.Wyhash, it: anytype) void {
    hashPaintItem(hasher, it, false, null);
}

/// hashCaretPaintItemInto of `it` with its geometry replaced by `geom`
/// (equal to hashing a copy whose geom was set), without copying the item.
/// `it` may be a pointer to the item.
pub fn hashCaretPaintItemWithGeomInto(hasher: *std.hash.Wyhash, it: anytype, geom: anytype) void {
    hashPaintItem(hasher, it, false, geom);
}

fn hashPaintItem(hasher: *std.hash.Wyhash, it: anytype, comptime glass_address: bool, geom: ?@TypeOf(it.geom)) void {
    // Fields are packed and fed in large chunks: Wyhash streaming is chunking-invariant (same
    // value as one update per field), and ~70 tiny updates per item dominated whole-list scans.
    var p: Packer = .{ .hasher = hasher };
    defer p.flush();
    p.add(std.mem.asBytes(&it.kind));
    p.add(std.mem.asBytes(&it.control_kind));
    if (geom) |g| p.add(std.mem.asBytes(&g)) else p.add(std.mem.asBytes(&it.geom));
    if (!glass_address) {
        // A group's or glass's window draw rect, a group's composite warp and an
        // icon's pixel snapping all change pixels without touching the fields
        // below. (The retained-surface fold keeps its own contract: a surface
        // re-composited at a new place is reused.)
        p.add(std.mem.asBytes(&it.draw_x));
        p.add(std.mem.asBytes(&it.draw_y));
        p.add(std.mem.asBytes(&it.draw_w));
        p.add(std.mem.asBytes(&it.draw_h));
        p.add(std.mem.asBytes(&it.warp));
        p.add(std.mem.asBytes(&it.icon_snap));
    }
    p.add(std.mem.asBytes(&it.color));
    p.add(std.mem.asBytes(&it.radii));
    p.add(std.mem.asBytes(&it.opacity));
    p.add(std.mem.asBytes(&it.rotate));
    p.add(std.mem.asBytes(&it.blend_mode));
    p.add(std.mem.asBytes(&it.use_draw_transform));
    p.add(std.mem.asBytes(&it.draw_transform));
    p.add(std.mem.asBytes(&it.stroke_width));
    p.add(std.mem.asBytes(&it.clip_shape_kind));
    // Drawing shape (rounded_rect / ellipse) changes distance field itself; same geom changes
    // pixels.
    p.add(std.mem.asBytes(&it.shape_kind));
    // Text horizontal fade (marquee / truncation fade): fade range animation doesn't change content
    // bytes.
    p.add(std.mem.asBytes(&it.text_fade_dx0));
    p.add(std.mem.asBytes(&it.text_fade_dx1));
    // Full shadow parameters (all influencing pixels).
    p.add(std.mem.asBytes(&it.shadow_blur));
    p.add(std.mem.asBytes(&it.shadow_offset_x));
    p.add(std.mem.asBytes(&it.shadow_offset_y));
    p.add(std.mem.asBytes(&it.shadow_spread));
    p.add(std.mem.asBytes(&it.shadow_secondary_color));
    p.add(std.mem.asBytes(&it.shadow2_blur));
    p.add(std.mem.asBytes(&it.shadow2_offset_x));
    p.add(std.mem.asBytes(&it.shadow2_offset_y));
    // Full gradient (end colors / direction / radial center / conic angle + multi-stop).
    p.add(std.mem.asBytes(&it.gradient_to_color));
    p.add(std.mem.asBytes(&it.gradient_direction));
    p.add(std.mem.asBytes(&it.gradient_extend_mode));
    p.add(std.mem.asBytes(&it.gradient_radial_center_x));
    p.add(std.mem.asBytes(&it.gradient_radial_center_y));
    p.add(std.mem.asBytes(&it.gradient_radial_radius_x));
    p.add(std.mem.asBytes(&it.gradient_radial_radius_y));
    p.add(std.mem.asBytes(&it.gradient_conic_start_angle));
    p.add(std.mem.asBytes(&it.mg_stop_count));
    if (it.mg_stop_count > 0) {
        const n = @min(@as(usize, it.mg_stop_count), it.mg_stop_colors.len);
        p.add(std.mem.sliceAsBytes(it.mg_stop_colors[0..n]));
        p.add(std.mem.sliceAsBytes(it.mg_stop_positions[0..n]));
    }
    // glass parameters (begin_blur_layer): only pointer, content must feed field-by-field; if
    // per-frame changes like scroll_edge_strength / interactive boost don't enter fingerprint,
    // retained
    // layer gets stale hit (existing gap, added 2026-07-30).
    if (it.glass_ptr) |gp| {
        const g = gp.*;
        if (@typeInfo(@TypeOf(g)) == .@"struct") {
            inline for (@import("zenit_reflection").fields(@TypeOf(g))) |f| {
                p.add(std.mem.asBytes(&@field(g, f.name)));
            }
            if (!glass_address and @hasField(@TypeOf(g), "group")) {
                // The group itself has scope lifetime and stable identity, but
                // its table can mutate in place between the two snapshots.
                if (g.group) |group| p.add(std.mem.asBytes(&group.version));
            }
        }
    }
    // arc: spinner/progress ring angle changes per-frame while geom (center) stays; not feeding
    // ensures stale.
    p.add(std.mem.asBytes(&it.arc_start_angle));
    p.add(std.mem.asBytes(&it.arc_end_angle));
    p.add(std.mem.asBytes(&it.arc_outer_radius));
    // Border / noise.
    p.add(std.mem.asBytes(&it.border_widths));
    p.add(std.mem.asBytes(&it.noise_mode));
    p.add(std.mem.asBytes(&it.noise_scale));
    p.add(std.mem.asBytes(&it.noise_intensity));
    p.add(std.mem.asBytes(&it.noise_seed));
    // Film grain (noise mode 2) is reseeded from the frame index in the shader:
    // a retained surface holding it froze the grain (the legacy painter never
    // retained such groups), and the damage tracker saw no change.
    if (it.noise_mode == 2 and it.noise_intensity > 0) p.add(std.mem.asBytes(&frame_salt));
    p.add(std.mem.asBytes(&it.path_line_join));
    // text: content + font-size / font-weight / font flags all affect pixels.
    p.add(it.text_content);
    p.add(std.mem.asBytes(&it.text_font_size));
    p.add(std.mem.asBytes(&it.text_font_weight));
    // Font family must enter fingerprint: changing font with same size/weight, missing fingerprint
    // skips redraw.
    p.add(std.mem.asBytes(&it.text_font_family));
    p.add(std.mem.asBytes(&it.text_font_flags));
    p.add(std.mem.asBytes(&it.text_raster_policy));
    // Image/icon identity. text's resource_handle is blob_id (shaping cache handle); pixels
    // determined
    // entirely by content + font params; blob identity **doesn't enter fingerprint**: overlay
    // subtree
    // rebuild re-allocates blob for identical-content text, feeding kills retained hit and ruins
    // per-item
    // diff (100% dirty).
    if (it.kind != .text) p.add(std.mem.asBytes(&it.resource_handle));
    p.add(std.mem.asBytes(&it.text_monospace_char_width));
    p.add(std.mem.asBytes(&it.image_opacity));
    p.add(std.mem.asBytes(&it.image_tint));
    p.add(std.mem.asBytes(&it.image_corner_radius));
    p.add(std.mem.asBytes(&it.icon_tint));
    p.add(std.mem.asBytes(&it.icon_rep_size));
    p.add(std.mem.asBytes(&it.icon_corner_clip_radius));
    // Shadow / gradient also affect pixels.
    p.add(std.mem.asBytes(&it.shadow2_color));
    // text_spans: span coloring/weight changes (selection highlight, syntax color) don't modify
    // text
    // bytes; feed field-by-field (struct bytewise hash reads padding, unstable).
    if (it.text_spans) |spans| {
        var span_len: usize = spans.len;
        p.add(std.mem.asBytes(&span_len));
        for (spans) |sp| {
            p.add(std.mem.asBytes(&sp.start));
            p.add(std.mem.asBytes(&sp.end));
            p.optionalColor(sp.color);
            if (sp.font_weight) |fw| p.add(std.mem.asBytes(&fw)) else p.add("n");
            const flags = [_]bool{ sp.use_italic_font, sp.use_monospace_font, sp.strikethrough };
            p.add(std.mem.asBytes(&flags));
            p.optionalColor(sp.bg_color);
        }
    }
    // path geometry: **must feed vertex content**. Feeding only pointer value: after frame_arena
    // reset
    // each frame, same allocation order reuses address; same pointer, new content = stale path
    // false hit
    // (P0). PathCommand is union; bytewise hash reads padding; feed per-tag payload.
    if (it.path_geometry_ptr) |pg| {
        p.add(std.mem.asBytes(&pg.fill_rule));
        var cmd_len: usize = pg.commands.len;
        p.add(std.mem.asBytes(&cmd_len));
        for (pg.commands) |cmd| {
            const tag: u8 = @backingInt(cmd);
            p.add(std.mem.asBytes(&tag));
            switch (cmd) {
                .move_to, .line_to => |pt| p.add(std.mem.asBytes(&pt)),
                .quad_to => |q| p.add(std.mem.asBytes(&q)),
                .cubic_to => |c| p.add(std.mem.asBytes(&c)),
                .close => {},
            }
        }
    }
    // polygon clip: points live in frame_arena, same address after reset each frame; feeding only
    // pointer = same pointer, new content false hit (same class as path geometry P0). Feed
    // field-by-field by content (whole asBytes reads padding); points outside valid range don't
    // affect
    // pixels, don't feed.
    if (it.clip_polygon_ptr) |cp| {
        const pc: usize = @min(@as(usize, cp.point_count), cp.points.len);
        const cc: usize = @min(@as(usize, cp.contour_count), cp.contour_end_points.len);
        p.add(std.mem.asBytes(&cp.point_count));
        p.add(std.mem.asBytes(&cp.contour_count));
        const fr: u8 = @backingInt(cp.fill_rule);
        p.add(std.mem.asBytes(&fr));
        p.add(std.mem.sliceAsBytes(cp.contour_end_points[0..cc]));
        p.add(std.mem.sliceAsBytes(cp.points[0..pc]));
    } else {
        p.add("np");
    }
    // Remaining pointer payload (glass/icon_rep): feed the pointer value. glass content is already
    // fed
    // field by field above; icon_rep is generated statically from icon_id and never mutated in
    // place;
    // the pointer value distinguishes within a frame only. WARNING: implicit contract:
    // resource_handle's
    // GPU texture content must be immutable (an animated/video in-place texture-update path would
    // need
    // a version number fed into the fingerprint).
    if (glass_address) p.add(std.mem.asBytes(&@intFromPtr(it.glass_ptr)));
    if (glass_address) {
        p.add(std.mem.asBytes(&@intFromPtr(it.icon_rep_ptr)));
    } else if (it.icon_rep_ptr) |rep| {
        p.add("icon");
        p.add(std.mem.asBytes(&rep.size));
        p.add(std.mem.asBytes(&rep.view_min_x));
        p.add(std.mem.asBytes(&rep.view_min_y));
        p.add(std.mem.asBytes(&rep.view_width));
        p.add(std.mem.asBytes(&rep.view_height));
        p.add(std.mem.asBytes(&rep.shapes.len));
        for (rep.shapes) |shape| {
            p.add(std.mem.asBytes(&shape.fill));
            p.add(std.mem.asBytes(&shape.stroke_width));
            p.add(std.mem.asBytes(&shape.fill_rule));
            p.add(std.mem.asBytes(&shape.contours.len));
            for (shape.contours) |contour| {
                p.add(std.mem.asBytes(&contour.closed));
                p.add(std.mem.asBytes(&contour.points.len));
                for (contour.points) |point| {
                    p.add(std.mem.asBytes(&point.x));
                    p.add(std.mem.asBytes(&point.y));
                }
            }
        }
    } else p.add("no-icon");
}

/// Buffers small hasher updates into one (see hashPaintItem).
const Packer = struct {
    hasher: *std.hash.Wyhash,
    buf: [512]u8 = undefined,
    len: usize = 0,

    inline fn add(self: *Packer, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) {
            self.flush();
            if (bytes.len > self.buf.len) return self.hasher.update(bytes);
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *Packer) void {
        if (self.len == 0) return;
        self.hasher.update(self.buf[0..self.len]);
        self.len = 0;
    }

    fn optionalColor(self: *Packer, c: anytype) void {
        if (c) |v| {
            self.add("c");
            self.add(std.mem.asBytes(&v));
        } else {
            self.add("n");
        }
    }
};

pub fn hashOptionalColor(hasher: *std.hash.Wyhash, c: anytype) void {
    if (c) |v| {
        hasher.update("c");
        hasher.update(std.mem.asBytes(&v));
    } else {
        hasher.update("n");
    }
}

pub const NoOpStructuralBlock = struct {
    end_index: usize,
    pair_count: u32,
};

pub fn tryFindNoOpStructuralBlock(commands: anytype, start: usize) ?NoOpStructuralBlock {
    if (start >= commands.len) return null;
    const begin_tok = structuralToken(commands[start]);
    if (!isBeginStructuralToken(begin_tok)) return null;
    const expected_end = matchingEndStructuralToken(begin_tok);
    if (expected_end == .none) return null;

    var pair_count: u32 = 1;
    var i = start + 1;
    while (i < commands.len) {
        const tok = structuralToken(commands[i]);
        if (tok == .none) return null; // encounter real paint command, non-empty struct block.
        if (tok == expected_end) {
            return .{
                .end_index = i,
                .pair_count = pair_count,
            };
        }
        if (isBeginStructuralToken(tok)) {
            const nested = tryFindNoOpStructuralBlock(commands, i) orelse return null;
            pair_count +|= nested.pair_count;
            i = nested.end_index + 1;
            continue;
        }
        // unexpected end token (unbalanced struct) or other struct noise, don't fold.
        return null;
    }
    return null; // no matching end found.
}

test "packed item hashing feeds the same bytes as one update per field" {
    var prng = std.Random.DefaultPrng.init(0x9ac4);
    const random = prng.random();
    var data: [3000]u8 = undefined;
    random.bytes(&data);
    for (0..200) |_| {
        var packed_hash = std.hash.Wyhash.init(3);
        var direct = std.hash.Wyhash.init(3);
        var p: Packer = .{ .hasher = &packed_hash };
        var i: usize = 0;
        while (i < data.len) {
            // Mostly field-sized pieces, sometimes longer than the buffer (text content).
            const n = @min(data.len - i, if (random.uintLessThan(u8, 10) == 0) random.uintLessThan(usize, 900) else random.uintLessThan(usize, 24));
            p.add(data[i .. i + n]);
            direct.update(data[i .. i + n]);
            i += n;
        }
        p.flush();
        try std.testing.expectEqual(direct.final(), packed_hash.final());
    }
}
