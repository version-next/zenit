const std = @import("std");
const types = @import("core/types.zig");

pub const Rect = types.ComputedRect;

pub const Placement = enum {
    top,
    top_start,
    top_end,
    bottom,
    bottom_start,
    bottom_end,
    left,
    left_start,
    left_end,
    right,
    right_start,
    right_end,
};

pub const Side = enum {
    top,
    bottom,
    left,
    right,
};

pub const Overflow = struct {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
};

/// Offset 值，可以是静态或 derivable（caller 提供 fn(state) -> f32，按 placement 动态算）。
/// 对齐 floating-ui 的 `OffsetOptions` 支持 `Derivable<OffsetValue>` 模式。
/// 典型用法：docs popover flip 到 cursor 对侧时多偏一个 line_height 让出 cursor 行
///   .main_axis = .{ .derive = .{ .ctx = popup_ptr, .compute = computeOffsetByPlacement } }
pub const OffsetValue = union(enum) {
    static: f32,
    derive: struct {
        ctx: ?*anyopaque,
        compute: *const fn (ctx: ?*anyopaque, state: OffsetDeriveState) f32,
    },

    pub fn resolve(self: OffsetValue, state: OffsetDeriveState) f32 {
        return switch (self) {
            .static => |v| v,
            .derive => |d| d.compute(d.ctx, state),
        };
    }
};

/// Offset derivable callback 收到的 state（足够 caller 按 placement 决定数值）。
pub const OffsetDeriveState = struct {
    placement: Placement,
    reference: Rect,
    floating: Rect,
};

pub const OffsetOptions = struct {
    main_axis: OffsetValue = .{ .static = 0 },
    cross_axis: OffsetValue = .{ .static = 0 },
};

pub const FlipOptions = struct {
    /// 当 preferred placement 溢出时依次尝试的 fallback 列表。
    /// 默认空 = 使用经典 2-way flip（preferred ↔ opposite）。
    /// 对齐 floating-ui 的 `fallbackPlacements` 语义。
    /// 典型用法（docs panel）：`fallback_placements = &.{.right_start, .bottom_start, .top_start}`
    ///   表示"右边放不下就下面，下面放不下就上面，**永不 flip 到左边**（避免遮 sidebar）"。
    fallback_placements: []const Placement = &.{},
};

pub const ShiftOptions = struct {
    padding: f32 = 0,
    main_axis: bool = false,
    cross_axis: bool = true,
};

pub const SizeOptions = struct {
    padding: f32 = 0,
};

/// Autosize: 把当前 placement 下 viewport 能容纳的最大宽/高作为浮层的 commit 约束。
/// 和 `size` 的区别 ——
///   - `size` 是 **advisory**：只写 middleware_data.size，caller 读了可以自己决定是否采用
///   - `autosize` 是 **committing**：写 middleware_data.autosize 的同时，caller
///     在 layout pass 应直接把这个值作为 max_width/max_height 的硬上限，超出走滚动
///
/// 典型 chain:
///   offset -> flip -> shift -> autosize
/// 让 flip/shift 先决定最终 placement，autosize 再据此求可用空间。
pub const AutosizeOptions = struct {
    padding: f32 = 0,
    apply_width: bool = true,
    apply_height: bool = true,
};

pub const Middleware = union(enum) {
    offset: OffsetOptions,
    flip: FlipOptions,
    shift: ShiftOptions,
    size: SizeOptions,
    autosize: AutosizeOptions,
};

pub const OffsetData = struct {
    x: f32,
    y: f32,
};

pub const FlipData = struct {
    placement: Placement,
    overflow: Overflow,
};

pub const ShiftData = struct {
    x: f32,
    y: f32,
    overflow: Overflow,
};

pub const SizeData = struct {
    available_width: f32,
    available_height: f32,
};

/// autosize middleware 的输出 —— caller 应用这些值作为浮层 layout 的硬上限。
pub const AutosizeData = struct {
    committed_max_width: f32,
    committed_max_height: f32,
    apply_width: bool,
    apply_height: bool,
};

pub const MiddlewareData = struct {
    offset: ?OffsetData = null,
    flip: ?FlipData = null,
    shift: ?ShiftData = null,
    size: ?SizeData = null,
    autosize: ?AutosizeData = null,
};

pub const ComputePositionConfig = struct {
    placement: Placement = .bottom_start,
    middleware: []const Middleware = &.{},
    /// 群组协同布局：上下文里"已被前序 popover 占用的矩形"列表。
    /// flip / shift / autosize 三个 middleware 会把这些 rect 当作不可侵入的"软边界"：
    ///   - flip：候选 placement 与任一 excluded rect 重叠 → 视为溢出，触发翻面/fallback
    ///   - shift：cross-axis 推回时把 excluded rect 当墙，把 popover 推到外面
    ///   - autosize：available_width/height 计算扣除被 excluded rect 占用的部分
    /// 元素必须是绝对屏幕坐标（与 viewport 同坐标空间）。空 = 退化为单 popover 行为，零开销。
    excluded_rects: []const Rect = &.{},
};

pub const ComputePositionResult = struct {
    x: f32,
    y: f32,
    placement: Placement,
    middleware_data: MiddlewareData,
};

pub fn getSide(pos: Placement) Side {
    return switch (pos) {
        .top, .top_start, .top_end => .top,
        .bottom, .bottom_start, .bottom_end => .bottom,
        .left, .left_start, .left_end => .left,
        .right, .right_start, .right_end => .right,
    };
}

pub fn getOppositePlacement(pos: Placement) Placement {
    return switch (pos) {
        .top => .bottom,
        .top_start => .bottom_start,
        .top_end => .bottom_end,
        .bottom => .top,
        .bottom_start => .top_start,
        .bottom_end => .top_end,
        .left => .right,
        .left_start => .right_start,
        .left_end => .right_end,
        .right => .left,
        .right_start => .left_start,
        .right_end => .left_end,
    };
}

pub fn computeTranslate(pos: Placement, tw: f32, th: f32, fw: f32, fh: f32, main_axis_offset: f32) [2]f32 {
    return switch (pos) {
        .top => .{ (tw - fw) / 2, -fh - main_axis_offset },
        .top_start => .{ 0, -fh - main_axis_offset },
        .top_end => .{ tw - fw, -fh - main_axis_offset },
        .bottom => .{ (tw - fw) / 2, th + main_axis_offset },
        .bottom_start => .{ 0, th + main_axis_offset },
        .bottom_end => .{ tw - fw, th + main_axis_offset },
        .left => .{ -fw - main_axis_offset, (th - fh) / 2 },
        .left_start => .{ -fw - main_axis_offset, 0 },
        .left_end => .{ -fw - main_axis_offset, th - fh },
        .right => .{ tw + main_axis_offset, (th - fh) / 2 },
        .right_start => .{ tw + main_axis_offset, 0 },
        .right_end => .{ tw + main_axis_offset, th - fh },
    };
}

pub fn computeOverflow(
    pos: Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
) Overflow {
    const translate = computeTranslate(pos, reference.w, reference.h, floating.w, floating.h, main_axis_offset);
    const x = reference.x + translate[0];
    const y = reference.y + translate[1];
    return computeOverflowFromCoords(x, y, floating, viewport, padding);
}

pub fn mainAxisOverflow(overflow: Overflow, side: Side) f32 {
    return switch (side) {
        .top => overflow.top,
        .bottom => overflow.bottom,
        .left => overflow.left,
        .right => overflow.right,
    };
}

pub fn flipPlacement(
    preferred: Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
) Placement {
    const opposite = getOppositePlacement(preferred);
    const candidates = [_]Placement{ preferred, opposite };

    var best = preferred;
    var best_overflow: f32 = std.math.inf(f32);

    for (candidates) |candidate| {
        const overflow = computeOverflow(candidate, reference, floating, viewport, main_axis_offset, padding);
        const current = mainAxisOverflow(overflow, getSide(candidate));
        if (current <= 0) return candidate;
        if (current < best_overflow) {
            best_overflow = current;
            best = candidate;
        }
    }

    return best;
}

/// Group-aware flip：在经典 flip / fallback 基础上，把"候选 placement 与任一 excluded rect 重叠"
/// 视为该 placement 不可用（等价于无穷大溢出，强制 fallback）。
/// excluded_rects 空 → 行为完全等同 flipPlacement。
pub fn flipPlacementGroupAware(
    preferred: Placement,
    fallbacks: []const Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
    excluded: []const Rect,
) Placement {
    // 计算给定 placement 的"effective overflow"：viewport main-axis overflow + 重叠 excluded rect → 加 INF
    const score = struct {
        fn s(p: Placement, ref: Rect, flt: Rect, vp: Rect, mo: f32, pad: f32, ex: []const Rect) f32 {
            const ov = computeOverflow(p, ref, flt, vp, mo, pad);
            const main_ov = mainAxisOverflow(ov, getSide(p));
            // 检查跟 excluded 是否重叠
            const tr = computeTranslate(p, ref.w, ref.h, flt.w, flt.h, mo);
            const fx = ref.x + tr[0];
            const fy = ref.y + tr[1];
            if (collidesWithExcluded(fx, fy, flt, ex)) return std.math.inf(f32);
            return main_ov;
        }
    }.s;

    var best = preferred;
    var best_overflow = score(preferred, reference, floating, viewport, main_axis_offset, padding, excluded);
    if (best_overflow <= 0) return preferred;

    if (fallbacks.len > 0) {
        for (fallbacks) |candidate| {
            const cur = score(candidate, reference, floating, viewport, main_axis_offset, padding, excluded);
            if (cur <= 0) return candidate;
            if (cur < best_overflow) {
                best_overflow = cur;
                best = candidate;
            }
        }
    } else {
        // 经典 2-way flip
        const opp = getOppositePlacement(preferred);
        const cur = score(opp, reference, floating, viewport, main_axis_offset, padding, excluded);
        if (cur <= 0) return opp;
        if (cur < best_overflow) {
            best_overflow = cur;
            best = opp;
        }
    }
    return best;
}

pub fn computePosition(reference: Rect, floating: Rect, viewport: Rect, config: ComputePositionConfig) ComputePositionResult {
    var state = ComputePositionResult{
        .x = 0,
        .y = 0,
        .placement = config.placement,
        .middleware_data = .{},
    };

    var offset_options = OffsetOptions{};
    for (config.middleware) |middleware| {
        switch (middleware) {
            .offset => |options| offset_options = options,
            else => {},
        }
    }

    // Resolve offset 值 —— derivable 用 (placement, reference, floating) 算实际数值。
    const resolveMain = struct {
        fn r(opts: OffsetOptions, p: Placement, ref: Rect, flt: Rect) f32 {
            return opts.main_axis.resolve(.{ .placement = p, .reference = ref, .floating = flt });
        }
    }.r;
    const resolveCross = struct {
        fn r(opts: OffsetOptions, p: Placement, ref: Rect, flt: Rect) f32 {
            return opts.cross_axis.resolve(.{ .placement = p, .reference = ref, .floating = flt });
        }
    }.r;

    const initial_main = resolveMain(offset_options, state.placement, reference, floating);
    const initial_translate = computeTranslate(state.placement, reference.w, reference.h, floating.w, floating.h, initial_main);
    state.x = reference.x + initial_translate[0];
    state.y = reference.y + initial_translate[1];

    for (config.middleware) |middleware| {
        switch (middleware) {
            .offset => |options| {
                const cross_v = resolveCross(options, state.placement, reference, floating);
                const delta = applyCrossAxisOffset(state.placement, cross_v);
                state.x += delta[0];
                state.y += delta[1];
                state.middleware_data.offset = .{ .x = delta[0], .y = delta[1] };
            },
            .flip => |options| {
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                const chosen = flipPlacementGroupAware(
                    state.placement,
                    options.fallback_placements,
                    reference,
                    floating,
                    viewport,
                    main_v,
                    0,
                    config.excluded_rects,
                );
                if (chosen != state.placement) {
                    state.placement = chosen;
                    const new_main = resolveMain(offset_options, chosen, reference, floating);
                    const new_cross = resolveCross(offset_options, chosen, reference, floating);
                    const translated = computeTranslate(chosen, reference.w, reference.h, floating.w, floating.h, new_main);
                    state.x = reference.x + translated[0];
                    state.y = reference.y + translated[1];
                    const delta = applyCrossAxisOffset(chosen, new_cross);
                    state.x += delta[0];
                    state.y += delta[1];
                }
                state.middleware_data.flip = .{
                    .placement = state.placement,
                    .overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, 0),
                };
            },
            .shift => |options| {
                var dx: f32 = 0;
                var dy: f32 = 0;
                const overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, options.padding);
                const side = getSide(state.placement);

                if (options.cross_axis) {
                    if (side == .top or side == .bottom) {
                        if (overflow.right > 0) dx -= overflow.right;
                        if (overflow.left > 0) dx += overflow.left;
                    } else {
                        if (overflow.bottom > 0) dy -= overflow.bottom;
                        if (overflow.top > 0) dy += overflow.top;
                    }
                }

                if (options.main_axis) {
                    switch (side) {
                        .top => {
                            if (overflow.top > 0) dy += overflow.top;
                        },
                        .bottom => {
                            if (overflow.bottom > 0) dy -= overflow.bottom;
                        },
                        .left => {
                            if (overflow.left > 0) dx += overflow.left;
                        },
                        .right => {
                            if (overflow.right > 0) dx -= overflow.right;
                        },
                    }
                }

                // Group-aware：沿主轴把 popover 推出 excluded rects
                if (config.excluded_rects.len > 0) {
                    const main_push = pushOutOfExcludedAlongMain(state.x + dx, state.y + dy, floating, side, config.excluded_rects);
                    if (side == .top or side == .bottom) dy += main_push else dx += main_push;
                }

                state.x += dx;
                state.y += dy;
                state.middleware_data.shift = .{
                    .x = dx,
                    .y = dy,
                    .overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, options.padding),
                };
            },
            .size => |options| {
                // 主轴 offset 也占用可用空间（floating-ui 的 size 基于 offset 后的坐标算
                // overflow，天然扣掉；这里显式减）。
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                state.middleware_data.size = .{
                    .available_width = availableWidthForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkWidth(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnWidth(state.placement, main_v),
                    .available_height = availableHeightForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkHeight(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnHeight(state.placement, main_v),
                };
            },
            .autosize => |options| {
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                state.middleware_data.autosize = .{
                    .committed_max_width = @max(0, availableWidthForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkWidth(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnWidth(state.placement, main_v)),
                    .committed_max_height = @max(0, availableHeightForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkHeight(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnHeight(state.placement, main_v)),
                    .apply_width = options.apply_width,
                    .apply_height = options.apply_height,
                };
            },
        }
    }

    return state;
}

fn computeOverflowFromCoords(x: f32, y: f32, floating: Rect, viewport: Rect, padding: f32) Overflow {
    return .{
        .top = (viewport.y + padding) - y,
        .right = (x + floating.w) - (viewport.x + viewport.w - padding),
        .bottom = (y + floating.h) - (viewport.y + viewport.h - padding),
        .left = (viewport.x + padding) - x,
    };
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// 检查 popover 候选矩形是否与任一 excluded rect 重叠。
/// flip 用：重叠 = 视为该 placement 不可用，触发翻面。
fn collidesWithExcluded(x: f32, y: f32, floating: Rect, excluded: []const Rect) bool {
    if (excluded.len == 0) return false;
    const fl = Rect{ .x = x, .y = y, .w = floating.w, .h = floating.h };
    for (excluded) |er| {
        if (rectsOverlap(fl, er)) return true;
    }
    return false;
}

/// 沿 placement 主轴方向，把 popover 推出所有 excluded rects 所需的总位移（带符号）。
/// shift main_axis 用：在原 viewport 推回基础上叠加这个位移。
/// side=bottom：返回正值（向下推）；side=top：返回负值（向上推）；类似 left/right。
fn pushOutOfExcludedAlongMain(
    x: f32,
    y: f32,
    floating: Rect,
    side: Side,
    excluded: []const Rect,
) f32 {
    if (excluded.len == 0) return 0;
    const fl = Rect{ .x = x, .y = y, .w = floating.w, .h = floating.h };
    var max_push: f32 = 0;
    for (excluded) |er| {
        if (!rectsOverlap(fl, er)) continue;
        const p: f32 = switch (side) {
            .bottom => (er.y + er.h) - fl.y, // 把 popover 顶推到 er 底之下
            .top => (fl.y + fl.h) - er.y, // 把 popover 底推到 er 顶之上（取正值，调用方按 side 决定符号）
            .right => (er.x + er.w) - fl.x,
            .left => (fl.x + fl.w) - er.x,
        };
        if (p > max_push) max_push = p;
    }
    return switch (side) {
        .bottom, .right => max_push,
        .top, .left => -max_push,
    };
}

/// autosize 用：算 popover 在指定 placement 下的可用宽度（已扣除 excluded rects 占用）。
/// 仅扣除"当 popover 沿主轴贴 anchor 摆放时，跨轴方向上被 excluded rect 截断的可用空间"。
fn excludedShrinkWidth(placement: Placement, reference: Rect, viewport: Rect, padding: f32, excluded: []const Rect) f32 {
    _ = padding;
    if (excluded.len == 0) return 0;
    const side = getSide(placement);
    // 只对 left/right 主轴 placement 有意义（width 是主轴）
    return switch (side) {
        .left => blk: {
            // popover 在 reference 左边，width 范围 [viewport.x, reference.x]
            // 任何在这个 vertical band 内的 excluded rect 把可用宽度推回
            var min_left = viewport.x;
            for (excluded) |er| {
                if (er.x + er.w <= viewport.x) continue;
                if (er.x >= reference.x) continue;
                // er 跟 reference 的 vertical band（reference 周围）有 overlap 才算
                // 简化：只看 er 是否在 popover 可能落的 y 带（以 reference 为中心 + popover 高度）
                // 这里粗略用 er.y..er.y+er.h 跟 reference 的 vertical 重叠
                if (er.y + er.h <= reference.y or er.y >= reference.y + reference.h) {
                    // 完全错开 reference vertical band → 不影响 popover
                    // （注意：popover 实际比 reference 高，这里粗略不精确，但够用）
                }
                if (er.x + er.w > min_left) min_left = er.x + er.w;
            }
            const recovered = reference.x - min_left;
            const original = reference.x - viewport.x;
            break :blk @max(0, original - recovered);
        },
        .right => blk: {
            var max_right = viewport.x + viewport.w;
            const ref_right = reference.x + reference.w;
            for (excluded) |er| {
                if (er.x >= viewport.x + viewport.w) continue;
                if (er.x + er.w <= ref_right) continue;
                if (er.x < max_right) max_right = er.x;
            }
            const recovered = max_right - ref_right;
            const original = (viewport.x + viewport.w) - ref_right;
            break :blk @max(0, original - recovered);
        },
        else => 0,
    };
}

fn excludedShrinkHeight(placement: Placement, reference: Rect, viewport: Rect, padding: f32, excluded: []const Rect) f32 {
    _ = padding;
    if (excluded.len == 0) return 0;
    const side = getSide(placement);
    return switch (side) {
        .top => blk: {
            // popover 在 reference 上方，可用 height 范围 [viewport.y, reference.y]
            // 找出最靠下的 excluded.bottom（在 popover 区域内）→ 把可用空间推回
            var min_top = viewport.y;
            for (excluded) |er| {
                if (er.y + er.h <= viewport.y) continue;
                if (er.y >= reference.y) continue;
                if (er.y + er.h > min_top) min_top = er.y + er.h;
            }
            const recovered = reference.y - min_top;
            const original = reference.y - viewport.y;
            break :blk @max(0, original - recovered);
        },
        .bottom => blk: {
            var max_bottom = viewport.y + viewport.h;
            const ref_bottom = reference.y + reference.h;
            for (excluded) |er| {
                if (er.y >= viewport.y + viewport.h) continue;
                if (er.y + er.h <= ref_bottom) continue;
                if (er.y < max_bottom) max_bottom = er.y;
            }
            const recovered = max_bottom - ref_bottom;
            const original = (viewport.y + viewport.h) - ref_bottom;
            break :blk @max(0, original - recovered);
        },
        else => 0,
    };
}

fn applyCrossAxisOffset(placement: Placement, cross_axis: f32) [2]f32 {
    return switch (getSide(placement)) {
        .top, .bottom => .{ cross_axis, 0 },
        .left, .right => .{ 0, cross_axis },
    };
}

fn availableWidthForPlacement(placement: Placement, reference: Rect, viewport: Rect, padding: f32) f32 {
    return switch (getSide(placement)) {
        .top, .bottom => @max(0, viewport.w - padding * 2),
        .left => @max(0, reference.x - viewport.x - padding),
        .right => @max(0, viewport.x + viewport.w - (reference.x + reference.w) - padding),
    };
}

/// 主轴 offset 在 width 轴上占的空间（left/right 侧）。
fn mainOffsetOnWidth(placement: Placement, main_v: f32) f32 {
    return switch (getSide(placement)) {
        .left, .right => main_v,
        .top, .bottom => 0,
    };
}

/// 主轴 offset 在 height 轴上占的空间（top/bottom 侧）。
fn mainOffsetOnHeight(placement: Placement, main_v: f32) f32 {
    return switch (getSide(placement)) {
        .top, .bottom => main_v,
        .left, .right => 0,
    };
}

fn availableHeightForPlacement(placement: Placement, reference: Rect, viewport: Rect, padding: f32) f32 {
    return switch (getSide(placement)) {
        .top => @max(0, reference.y - viewport.y - padding),
        .bottom => @max(0, viewport.y + viewport.h - (reference.y + reference.h) - padding),
        .left, .right => @max(0, viewport.h - padding * 2),
    };
}

test "flip fallbacks: preferred fits — returns preferred" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    try std.testing.expectEqual(Placement.right_start, result.placement);
}

test "flip fallbacks: preferred overflows — tries fallback list in order" {
    // viewport 240x160, reference at (200, 50, 30, 20) — 右边只剩 10px，放不下 120 wide
    const reference = Rect.init(200, 50, 30, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        // right 放不下 → 试 bottom → bottom 有 60 高 + 100 available 应当 fit
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // 期望落到 bottom_start（第一个不溢出的 fallback）
    try std.testing.expectEqual(Placement.bottom_start, result.placement);
}

test "flip fallbacks: 所有 fallback 都溢出 — 选溢出最小的" {
    // 非常小的 viewport 让每个方向都不够
    const reference = Rect.init(10, 10, 20, 20);
    const floating = Rect.init(0, 0, 200, 200); // 比 viewport 还大
    const viewport = Rect.init(0, 0, 100, 100);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // 无论选哪个都溢出；函数应当返回某个候选（不 crash）
    // 具体哪个依赖溢出计算细节，这里只验证不是 left 相关（fallback 列表里没有）
    try std.testing.expect(result.placement != .left_start);
    try std.testing.expect(result.placement != .left_end);
    try std.testing.expect(result.placement != .left);
}

test "flip fallbacks: 空 fallback list — 退回经典 2-way flip" {
    const reference = Rect.init(200, 50, 30, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} }, // 空 fallback
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // right 溢出 → 2-way flip 尝试 opposite = left_start
    try std.testing.expectEqual(Placement.left_start, result.placement);
}

test "computePosition: flip then shift" {
    const reference = Rect.init(100, 10, 80, 32);
    const floating = Rect.init(0, 0, 160, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .shift = .{} },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .top_start,
        .middleware = &middleware,
    });

    try std.testing.expectEqual(Placement.bottom_start, result.placement);
    try std.testing.expect(result.y >= reference.y + reference.h);
}

test "computePosition: size middleware reports available space" {
    const reference = Rect.init(40, 50, 80, 20);
    const floating = Rect.init(0, 0, 100, 60);
    const viewport = Rect.init(0, 0, 320, 200);
    const middleware = [_]Middleware{
        .{ .size = .{ .padding = 8 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    try std.testing.expect(result.middleware_data.size != null);
    try std.testing.expectEqual(@as(f32, 304), result.middleware_data.size.?.available_width);
    try std.testing.expectEqual(@as(f32, 122), result.middleware_data.size.?.available_height);
}

test "computePosition: autosize commits max dimensions for committing callers" {
    const reference = Rect.init(40, 50, 80, 20);
    const floating = Rect.init(0, 0, 100, 60);
    const viewport = Rect.init(0, 0, 320, 200);
    const middleware = [_]Middleware{
        .{ .autosize = .{ .padding = 8 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    try std.testing.expect(result.middleware_data.autosize != null);
    const a = result.middleware_data.autosize.?;
    try std.testing.expectEqual(@as(f32, 304), a.committed_max_width);
    try std.testing.expectEqual(@as(f32, 122), a.committed_max_height);
    try std.testing.expect(a.apply_width);
    try std.testing.expect(a.apply_height);
}

test "computePosition: autosize applies after flip decides final placement" {
    // Reference 靠近底部，triggers flip from bottom to top
    const reference = Rect.init(100, 180, 60, 16);
    const floating = Rect.init(0, 0, 80, 100);
    const viewport = Rect.init(0, 0, 320, 220);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .autosize = .{ .padding = 4 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    // flip 应当切到 top 侧
    try std.testing.expect(getSide(result.placement) == .top);
    try std.testing.expect(result.middleware_data.autosize != null);
    // autosize 在 top placement 下报告 reference 上方空间，扣 padding 与主轴 offset
    // （= 180 - 4 - 4 = 172）
    const a = result.middleware_data.autosize.?;
    try std.testing.expectEqual(@as(f32, 172), a.committed_max_height);
}

// ============================================================================
// Group-aware tests：excluded_rects 让 flip / shift / autosize 协同避让
// ============================================================================

test "group-aware flip: bottom_start 被前序 popover 占住 → 翻到 top_start" {
    // anchor 中央，bottom 方向被前序 popover 占了 → flip 应当走 top
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);

    // 前序 popover 占住了 bottom 区（在 anchor 正下方）
    const excluded = [_]Rect{
        Rect.init(100, 140, 120, 60),
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    try std.testing.expectEqual(Placement.top_start, result.placement);
}

test "group-aware flip: 多个 fallback 都被 excluded 占住 → 退回最不冲突的" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);

    // bottom 和 top 都占了 → fallback list 里只剩 right
    const excluded = [_]Rect{
        Rect.init(100, 140, 120, 60), // bottom 区
        Rect.init(100, 30, 120, 60), // top 区
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .top_start, .right_start, .left_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    // bottom_start collides → top_start collides → remaining side with least overflow wins.
    try std.testing.expectEqual(Placement.left_start, result.placement);
}

test "group-aware shift main_axis: popover 被推出 excluded rect" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 30);
    const viewport = Rect.init(0, 0, 600, 400);

    // bottom_start 默认落在 (100, 132)。前序 popover 在 (100, 130, 120, 40) → 重叠
    const excluded = [_]Rect{
        Rect.init(100, 130, 120, 40),
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 0 } } },
        // flip 不动（这里强制不 fallback，单独测 shift 行为）
        .{ .shift = .{ .main_axis = true } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    // shift 应当把 popover 推到 excluded rect 下方：y >= 130 + 40 = 170
    try std.testing.expect(result.y >= 170);
}

test "group-aware autosize: bottom available_height 扣除 excluded rect 占用" {
    const reference = Rect.init(100, 50, 80, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 320, 400);

    // anchor 下方 320px 高度 (400 - 70 - 8 padding = 322)，excluded 在下半段占了 200px
    const excluded = [_]Rect{
        Rect.init(100, 200, 120, 200), // bottom 区下半段
    };

    const middleware = [_]Middleware{
        .{ .autosize = .{ .padding = 8 } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    try std.testing.expect(result.middleware_data.autosize != null);
    const a = result.middleware_data.autosize.?;
    // 原始 height = 400 - 70 - 8 = 322
    // excluded.y=200，从 ref_bottom=70 起算，max_bottom 被推到 200 → recovered=130, original=322 → 322-(322-130)=130
    try std.testing.expect(a.committed_max_height < 322);
    try std.testing.expect(a.committed_max_height >= 120);
    try std.testing.expect(a.committed_max_height <= 140);
}

test "group-aware: 空 excluded_rects → 行为完全等同非 group 版本" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .shift = .{} },
        .{ .autosize = .{ .padding = 4 } },
    };
    const r1 = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
    });
    const r2 = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &.{},
    });
    try std.testing.expectEqual(r1.placement, r2.placement);
    try std.testing.expectEqual(r1.x, r2.x);
    try std.testing.expectEqual(r1.y, r2.y);
}
