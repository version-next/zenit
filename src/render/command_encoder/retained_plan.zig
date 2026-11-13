//! Backend-independent retained content fingerprints and conservative damage.
//! Shared by the GPU encoder and the Windows paint adapter. This planner owns
//! no textures and performs no rendering; cache decisions must be committed
//! only after the backend successfully updates its retained surface.
const std = @import("std");
const paint_fp = @import("paint_fingerprint.zig");

pub const DamageItem = struct {
    digest: u64,
    /// x/y/w/h (layer outer coordinate system, same space as begin token geom; includes
    /// shadow/stroke padding)
    bounds: [4]f32,
};

pub const DamageRange = struct {
    start: u32 = 0,
    len: u32 = 0,
    /// false = layer contains control token (nested layer/clip) or path commands, nested pass
    /// resets scissor, path renderer self-manages scissor, partial redraw unsafe, full layer
    /// redraw.
    safe: bool = false,
    /// Item count exceeds damage_scratch capacity, diff incomplete, give up partial redraw.
    overflow: bool = false,
    /// Whether this range was truly captured before (layers beyond index 64 are false).
    captured: bool = false,
};

pub const Plan = struct {
    pub const Layer = struct {
        stable_id: u32 = std.math.maxInt(u32),
        begin: usize = 0,
        end: ?usize = null,
    };
    scale: f32 = 1,
    retained_hashes: [64]u64 = @as([64]u64, @splat(0)),
    retained_hash_count: usize = 0,
    damage_scratch: [1024]DamageItem = undefined,
    damage_scratch_count: usize = 0,
    damage_ranges: [64]DamageRange = @as([64]DamageRange, @splat(.{})),
    layers: [64]Layer = @as([64]Layer, @splat(.{})),

    pub fn compute(self: *Plan, commands: anytype, scale: f32) void {
        self.scale = scale;
        scan(self, commands, null);
        self.layers = @as([64]Layer, @splat(.{}));
        var stack: [64]usize = undefined;
        var depth: usize = 0;
        var untracked: usize = 0;
        var seq: usize = 0;
        for (commands, 0..) |item, index| {
            if (item.kind != .control) continue;
            switch (item.control_kind) {
                .begin_opacity_layer => {
                    if (seq < self.layers.len) self.layers[seq] = .{ .stable_id = item.surface_stable_id, .begin = index };
                    if (depth < stack.len and untracked == 0) {
                        stack[depth] = seq;
                        depth += 1;
                    } else untracked += 1;
                    seq += 1;
                },
                .end_opacity_layer => {
                    if (untracked > 0) {
                        untracked -= 1;
                    } else if (depth > 0) {
                        depth -= 1;
                        const layer = stack[depth];
                        if (layer < self.layers.len) self.layers[layer].end = index;
                    }
                },
                else => {},
            }
        }
    }
};

pub fn scan(self: anytype, commands: anytype, images: ?*@import("../image_renderer.zig").ImageRenderer) void {
    self.retained_hash_count = 0;
    self.damage_scratch_count = 0;
    self.damage_ranges = @as([64]DamageRange, @splat(.{}));
    // backdrop: child tree has background blur (glass). Glass pixels depend on image **behind**
    // layer,
    // when behind changes cache expires, layer content fingerprint doesn't see behind, such layers
    // (and all outer layers, outer-layer texture bakes inner glass) never reuse cache texture.
    var stack: [64]struct { idx: usize, hasher: std.hash.Wyhash, backdrop: bool = false } = undefined;
    var depth: usize = 0;
    var untracked_depth: usize = 0;
    // Non-flat layer capture state:
    //   fold_*: a nested opacity subtree folds into a single item (digest cumulative over all
    //   subtree
    //           commands + self composite params; bounds = composite rect padded). Runtime safety:
    //           the sublayer content pass draws to its own texture, and the parent pass's damage
    //           scissor is restored at the end by applyOffscreenTargetViewport recalc intersection.
    //   clip_rects: push_clip rectangular stack; pop_clip as an item takes the paired push's
    //           rectangle (a clip param change via index-diff puts both new and old rects in dirty,
    //           covering visible-change clipping). Clips all use shader uniforms, don't touch GPU
    //           scissor, so runtime needs no extra handling.
    //   nest_offsets: **translation-only** nested opacity subtrees (no transform/rotate) don't
    //   fold;
    //           they recurse per-item, with bounds offset by the nested layer offset in parent
    //           coords.
    //           This gives overlays (Modal/Popover content in a nested surface) fine-grained dirty:
    //           fold granularity = whole popup rect, always > 60% threshold. Subtrees with a
    //           transform fall back to fold (composite rect can't map per item).
    var fold_depth: usize = 0;
    var fold_hasher = std.hash.Wyhash.init(0);
    var fold_bounds: [4]f32 = .{ 0, 0, 0, 0 };
    var clip_rects: [16][4]f32 = undefined;
    var clip_count: usize = 0;
    var nest_offsets: [6][2]f32 = undefined;
    var nest_rects: [6][4]f32 = undefined;
    var capture_depth: usize = 0; // Nested translation-only layers entered count.

    for (commands) |it| {
        const revision: u64 = if (it.kind == .image and it.icon_rep_ptr == null)
            if (images) |renderer| renderer.textureContentRevision(@intCast(it.resource_handle)) else 0
        else
            0;
        // damage-rect capture: top-level layer (depth==1 = only stack[0] open) content commands
        // record {single fingerprint, padded bounds} per item. Own end token doesn't count as
        // content.
        // path (bounds from point set), push/pop_clip (rect/rounded/ellipse) and nested opacity
        // subtrees
        // (folded) are all captured; blur/rounded_clip subtrees, polygon clip and non-axis-aligned
        // transform nested layers stay unsafe -> full layer redraw.
        if (fold_depth > 0) {
            paint_fp.hashPaintItemInto(&fold_hasher, it);
            if (revision != 0) fold_hasher.update(std.mem.asBytes(&revision));
            if (it.kind == .control) switch (it.control_kind) {
                .begin_opacity_layer => fold_depth += 1,
                .end_opacity_layer => {
                    fold_depth -= 1;
                    if (fold_depth == 0 and stack[0].idx < self.damage_ranges.len) {
                        const range = &self.damage_ranges[stack[0].idx];
                        if (range.captured and range.safe and !range.overflow) {
                            if (self.damage_scratch_count < self.damage_scratch.len) {
                                self.damage_scratch[self.damage_scratch_count] = .{
                                    .digest = fold_hasher.final(),
                                    .bounds = fold_bounds,
                                };
                                self.damage_scratch_count += 1;
                                range.len += 1;
                            } else {
                                range.overflow = true;
                            }
                        }
                    }
                },
                else => {},
            };
        } else if (depth >= 1 and depth == capture_depth + 1 and stack[0].idx < self.damage_ranges.len) {
            const is_own_end = it.kind == .control and it.control_kind == .end_opacity_layer and depth == 1;
            if (!is_own_end) {
                const range = &self.damage_ranges[stack[0].idx];
                if (range.captured and range.safe and !range.overflow) capture: {
                    // Current accumulated offset (translation-only nested chain origin in top-level
                    // surface coords).
                    var off_x: f32 = 0;
                    var off_y: f32 = 0;
                    for (nest_offsets[0..capture_depth]) |o| {
                        off_x += o[0];
                        off_y += o[1];
                    }
                    var bounds: [4]f32 = undefined;
                    if (it.kind == .control) {
                        switch (it.control_kind) {
                            .push_clip => {
                                // polygon clip point set only has pointer, not in fingerprint ->
                                // conservative unsafe.
                                if (it.clip_shape_kind == 3 or clip_count >= clip_rects.len) {
                                    range.safe = false;
                                    break :capture;
                                }
                                bounds = .{ it.geom.x + off_x - 2, it.geom.y + off_y - 2, it.geom.w + 4, it.geom.h + 4 };
                                clip_rects[clip_count] = bounds;
                                clip_count += 1;
                            },
                            .pop_clip => {
                                // Popped clip not this layer's push (unpaired) -> unsafe.
                                if (clip_count == 0) {
                                    range.safe = false;
                                    break :capture;
                                }
                                clip_count -= 1;
                                bounds = clip_rects[clip_count];
                            },
                            .begin_opacity_layer => {
                                // Coordinate contract (from the composite formula, see
                                // endOpacityLayer steps 6.5/7):
                                // nested texture (0,0) maps to nested-local point (geom.x, geom.y);
                                // composite lands at the
                                // parent-raw draw origin, so nested-local q maps to parent-raw =
                                // q + (draw_origin - geom.xy). Plain (no dt) draw==geom -> offset 0
                                // (in-flow sublayer content coords already match the parent).
                                const translate_only = it.use_draw_transform and it.rotate == 0 and
                                    it.draw_transform[0] == 1 and it.draw_transform[1] == 0 and
                                    it.draw_transform[2] == 0 and it.draw_transform[3] == 1;
                                const plain = !it.use_draw_transform and it.rotate == 0;
                                if ((plain or translate_only) and capture_depth < nest_offsets.len) {
                                    const pad: f32 = 4;
                                    var org_x: f32 = 0;
                                    var org_y: f32 = 0;
                                    var bx = it.geom.x;
                                    var by = it.geom.y;
                                    if (translate_only) {
                                        org_x = it.draw_transform[4] - it.geom.x;
                                        org_y = it.draw_transform[5] - it.geom.y;
                                        bx = it.draw_transform[4];
                                        by = it.draw_transform[5];
                                    } else if (!std.math.isNan(it.draw_x) and it.draw_w > 0 and it.draw_h > 0) {
                                        org_x = it.draw_x - it.geom.x;
                                        org_y = it.draw_y - it.geom.y;
                                        bx = it.draw_x;
                                        by = it.draw_y;
                                    }
                                    bounds = .{ bx + off_x - pad, by + off_y - pad, it.geom.w + pad * 2, it.geom.h + pad * 2 };
                                    nest_offsets[capture_depth] = .{ org_x + off_x, org_y + off_y };
                                    nest_rects[capture_depth] = bounds;
                                    capture_depth += 1;
                                } else if (paint_fp.nestedCompositeBounds(it)) |b| {
                                    // Axis-aligned transform: whole subtree folds to single item.
                                    fold_hasher = std.hash.Wyhash.init(0);
                                    paint_fp.hashPaintItemInto(&fold_hasher, it);
                                    fold_bounds = .{ b[0] + off_x, b[1] + off_y, b[2], b[3] };
                                    fold_depth = 1;
                                    break :capture; // Fold item deferred to subtree end persist.
                                } else {
                                    // Rotate/non-axis-aligned transform: composite range can't be
                                    // cheaply bounded.
                                    range.safe = false;
                                    break :capture;
                                }
                            },
                            .end_opacity_layer => {
                                // Translation-only nested layer finish: end as item (digest
                                // constant,
                                // only for index align; bounds = layer composite rect,
                                // conservative).
                                capture_depth -= 1;
                                bounds = nest_rects[capture_depth];
                            },
                            else => {
                                // blur/rounded_clip will cut pass / reset scissor.
                                range.safe = false;
                                break :capture;
                            },
                        }
                    } else {
                        bounds = if (it.kind == .path) paint_fp.pathItemBounds(it) else paint_fp.damageItemBounds(it);
                        bounds[0] += off_x;
                        bounds[1] += off_y;
                    }
                    if (self.damage_scratch_count < self.damage_scratch.len) {
                        var ih = std.hash.Wyhash.init(0);
                        paint_fp.hashPaintItemInto(&ih, it);
                        if (revision != 0) ih.update(std.mem.asBytes(&revision));
                        self.damage_scratch[self.damage_scratch_count] = .{
                            .digest = ih.final(),
                            .bounds = bounds,
                        };
                        self.damage_scratch_count += 1;
                        range.len += 1;
                    } else {
                        range.overflow = true;
                    }
                }
            }
        }
        // Feed this command to all still-open layers first (nested layers share inner content).
        //
        // Warning: **begin_opacity_layer must also feed to outer layers**: nested sublayer
        // composite
        // happens **inside the parent cache texture**, and a parent layer hit skips the whole
        // sublayer
        // composite (pixels are baked into the parent texture). If sublayer transform/opacity
        // changes
        // frame by frame (Sheet slide-in, Popover scale) and the parent fingerprint can't see it,
        // the hit
        // is stale every frame and the whole window freezes until the animation ends, then jumps.
        // 'Composite params not in fingerprint' applies only to the **self begin token** (its
        // composite is
        // outside cached content), so feed outer layers (stack[0..depth], not the self about to be
        // pushed).
        var di: usize = 0;
        while (di < depth) : (di += 1) {
            paint_fp.hashPaintItemInto(&stack[di].hasher, it);
            if (revision != 0) stack[di].hasher.update(std.mem.asBytes(&revision));
        }

        if (it.kind != .control) continue;
        switch (it.control_kind) {
            .begin_blur_layer => {
                var bi: usize = 0;
                while (bi < depth) : (bi += 1) stack[bi].backdrop = true;
            },
            .begin_opacity_layer => {
                if (untracked_depth == 0 and depth < stack.len) {
                    var hasher = std.hash.Wyhash.init(0);
                    // Geometry size in fingerprint: size change means texture content must redraw.
                    hasher.update(std.mem.asBytes(&it.geom.w));
                    hasher.update(std.mem.asBytes(&it.geom.h));
                    // scale also must be in fingerprint (2026-07-30 review add): pool size key is
                    // 64px bucket-quantized alloc size, across monitor/fractional scale change
                    // old/new
                    // physical size may land same bucket, no scale feed hits quantized pixel
                    // (blur/stretch
                    // + UV misses old used area).
                    hasher.update(std.mem.asBytes(&self.scale));
                    stack[depth] = .{ .idx = self.retained_hash_count, .hasher = hasher };
                    // damage-rect: top-level layer begin capture start (layers beyond index 64
                    // don't capture).
                    // Capture state per-layer zeroed (previous layer unbalanced clip/fold can't
                    // cross layers).
                    if (depth == 0) {
                        clip_count = 0;
                        fold_depth = 0;
                        capture_depth = 0;
                    }
                    if (depth == 0 and self.retained_hash_count < self.damage_ranges.len) {
                        self.damage_ranges[self.retained_hash_count] = .{
                            .start = @intCast(self.damage_scratch_count),
                            .len = 0,
                            .safe = true,
                            .overflow = false,
                            .captured = true,
                        };
                    }
                    depth += 1;
                } else {
                    // Hash slots beyond the bounded stack stay zero (forced
                    // cache miss), but their ends must not pop a tracked
                    // outer frame early.
                    untracked_depth += 1;
                }
                // Each begin must take one slot (even if stack full still takes, else begin and
                // consumer sequence mismatch, sequence error = wrong fingerprint).
                if (self.retained_hash_count < self.retained_hashes.len) {
                    self.retained_hashes[self.retained_hash_count] = 0;
                }
                self.retained_hash_count += 1;
            },
            .end_opacity_layer => {
                if (untracked_depth > 0) {
                    untracked_depth -= 1;
                } else if (depth > 0) {
                    // Note: end already fed to **all open layers including self** above, so this
                    // layer
                    // fingerprint has end marker, naturally distinguish 'content ends at end' from
                    // 'content not yet done'.
                    depth -= 1;
                    const fr = &stack[depth];
                    if (fr.idx < self.retained_hashes.len) {
                        // 0 is 'invalid fingerprint' sentinel, when truly compute 0 shift one bit
                        // to avoid
                        // misidentify. Layers with glass always 0: force redraw every frame
                        // (background sample
                        // must be current frame).
                        const h = fr.hasher.final();
                        // Layers with glass always 0 (invalid fingerprint -> never retained hit):
                        // Background sample must be current frame.
                        self.retained_hashes[fr.idx] = if (fr.backdrop) 0 else if (h == 0) 1 else h;
                    }
                }
            },
            else => {},
        }
    }
}
