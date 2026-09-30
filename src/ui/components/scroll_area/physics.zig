/// ScrollArea 滚动物理
///
/// 垂直/水平滚动应用 + overscroll + near-boundary resistance
const std = @import("std");
const state_mod = @import("state.zig");
const ScrollState = state_mod.ScrollState;
const debug = @import("debug.zig");
const logScroll = debug.logScroll;

/// 垂直滚动：正常范围 clamp，越界部分通过阻尼函数衰减后累积到 bonus
pub fn applyVerticalScroll(state: *ScrollState, dy: f32, speed: f32, is_momentum: bool) void {
    const raw_delta = -dy * speed;
    var delta = raw_delta;
    const max = state.maxScrollY();
    delta = applyVerticalNearBoundaryResistance(state, delta, max, is_momentum);
    logScroll(
        "apply v: raw_delta={d:.2} delta={d:.2} max={d:.2} scroll_y={d:.2} bonus_y={d:.2} momentum={}",
        .{ raw_delta, delta, max, state.scroll_y, state.bonus_y, is_momentum },
    );

    // 用户手动滚动时标记 user_scrolling（抑制弹簧回弹）
    if (!is_momentum) {
        state.user_scrolling = true;
    }
    // 惯性阶段且已越界：同向压缩放行（允许 outward momentum 继续加深越界），
    // 反向回拉让弹簧独占。小幅 outward 尾巴也拦截（防止弹簧回弹中被微弱 momentum 干扰）。
    if (is_momentum and !state.user_scrolling and state.bonus_y != 0) {
        const outward = (state.bonus_y > 0 and raw_delta > 0) or (state.bonus_y < 0 and raw_delta < 0);
        if (!outward or @abs(raw_delta) < ScrollState.scroll_tuning.momentum_bonus_tail_cutoff) return;
    }

    // 如果已经在越界区域，先用本次输入消耗 bonus（iOS 风格：回到边界前不移动内容）
    if (state.bonus_y != 0 and delta != 0) {
        const raw_bonus = state.rubber_band.unclamp(state.bonus_y, state.viewport_height);
        if ((raw_bonus > 0 and delta < 0) or (raw_bonus < 0 and delta > 0)) {
            const raw_sum = raw_bonus + delta;
            if (raw_sum == 0) {
                state.bonus_y = 0;
                logScroll("v consume bonus->0: delta={d:.2} raw_bonus={d:.2}", .{ delta, raw_bonus });
                return;
            }
            if ((raw_sum > 0 and raw_bonus < 0) or (raw_sum < 0 and raw_bonus > 0)) {
                // 反向跨过 0：剩余部分继续用于正常滚动
                delta = raw_sum;
                state.bonus_y = 0;
                logScroll("v consume bonus cross0: remain_delta={d:.2} prev_raw_bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                });
            } else {
                // 仍在越界区内
                state.bonus_y = state.rubber_band.clamp(raw_sum, state.viewport_height);
                logScroll("v consume bonus stay: delta={d:.2} raw_bonus={d:.2} bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                    state.bonus_y,
                });
                return;
            }
        }
    }

    if (max <= 0) {
        // 内容不够长，所有滚动都是越界 → 直接走 rubber band
        applyOverscrollY(state, delta);
        return;
    }

    const new_y = state.scroll_y + delta;

    if (new_y < 0) {
        state.scroll_y = 0;
        applyOverscrollY(state, new_y); // new_y 是负值
    } else if (new_y > max) {
        state.scroll_y = max;
        applyOverscrollY(state, new_y - max); // 正值
    } else {
        state.scroll_y = new_y;
    }
}

/// 水平滚动：正常范围 clamp，越界部分通过阻尼函数衰减后累积到 bonus_x
pub fn applyHorizontalScroll(state: *ScrollState, dx: f32, speed: f32, is_momentum: bool) void {
    const raw_delta = -dx * speed;
    var delta = raw_delta;
    const max = state.maxScrollX();
    delta = applyHorizontalNearBoundaryResistance(state, delta, max, is_momentum);
    logScroll(
        "apply h: raw_delta={d:.2} delta={d:.2} max={d:.2} scroll_x={d:.2} bonus_x={d:.2} momentum={}",
        .{ raw_delta, delta, max, state.scroll_x, state.bonus_x, is_momentum },
    );

    if (!is_momentum) {
        state.user_scrolling = true;
    }
    // 惯性阶段且已越界：同向压缩放行，反向回拉让弹簧独占，小幅尾巴也拦截
    if (is_momentum and !state.user_scrolling and state.bonus_x != 0) {
        const outward = (state.bonus_x > 0 and raw_delta > 0) or (state.bonus_x < 0 and raw_delta < 0);
        if (!outward or @abs(raw_delta) < ScrollState.scroll_tuning.momentum_bonus_tail_cutoff) return;
    }

    if (state.bonus_x != 0 and delta != 0) {
        const raw_bonus = state.rubber_band_x.unclamp(state.bonus_x, state.viewport_width);
        if ((raw_bonus > 0 and delta < 0) or (raw_bonus < 0 and delta > 0)) {
            const raw_sum = raw_bonus + delta;
            if (raw_sum == 0) {
                state.bonus_x = 0;
                logScroll("h consume bonus->0: delta={d:.2} raw_bonus={d:.2}", .{ delta, raw_bonus });
                return;
            }
            if ((raw_sum > 0 and raw_bonus < 0) or (raw_sum < 0 and raw_bonus > 0)) {
                delta = raw_sum;
                state.bonus_x = 0;
                logScroll("h consume bonus cross0: remain_delta={d:.2} prev_raw_bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                });
            } else {
                state.bonus_x = state.rubber_band_x.clamp(raw_sum, state.viewport_width);
                logScroll("h consume bonus stay: delta={d:.2} raw_bonus={d:.2} bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                    state.bonus_x,
                });
                return;
            }
        }
    }

    if (max <= 0) {
        applyOverscrollX(state, delta);
        return;
    }

    const new_x = state.scroll_x + delta;

    if (new_x < 0) {
        state.scroll_x = 0;
        applyOverscrollX(state, new_x);
    } else if (new_x > max) {
        state.scroll_x = max;
        applyOverscrollX(state, new_x - max);
    } else {
        state.scroll_x = new_x;
    }
}

/// 统一越界处理: overflow 直接走 rubber band 公式（手动和惯性一致）
pub fn applyOverscrollY(state: *ScrollState, overflow: f32) void {
    if (!state.rubber_band_y_enabled) return;
    const prev_bonus = state.bonus_y;
    state.bonus_y = state.rubber_band.applyDelta(state.bonus_y, overflow, state.viewport_height);
    // 逐事件估计视觉速度（px/s），弹簧启动时作为 v0 携带 → 与 rubber-band 阶段速度连续
    state.bonus_velocity = (state.bonus_y - prev_bonus) / ScrollState.default_dt;
    if (@abs(state.bonus_y) < ScrollState.scroll_tuning.jitter_snap_epsilon and @abs(overflow) < ScrollState.scroll_tuning.jitter_snap_epsilon) {
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return;
    }
    if (prev_bonus == 0 and state.bonus_y != 0) {
        logScroll("!! BOUNCE RETRIGGER Y: overflow={d:.2} bonus 0->{d:.2} bounce_active={} scroll_y={d:.1}", .{
            overflow, state.bonus_y, state.bounce_active_y, state.scroll_y,
        });
    } else {
        logScroll("v overscroll: overflow={d:.2} bonus {d:.2}->{d:.2}", .{
            overflow, prev_bonus, state.bonus_y,
        });
    }
}

/// 统一水平越界处理
pub fn applyOverscrollX(state: *ScrollState, overflow: f32) void {
    if (!state.rubber_band_x_enabled) return;
    const prev_bonus = state.bonus_x;
    state.bonus_x = state.rubber_band_x.applyDelta(state.bonus_x, overflow, state.viewport_width);
    state.bonus_velocity_x = (state.bonus_x - prev_bonus) / ScrollState.default_dt;
    if (@abs(state.bonus_x) < ScrollState.scroll_tuning.jitter_snap_epsilon and @abs(overflow) < ScrollState.scroll_tuning.jitter_snap_epsilon) {
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return;
    }
    logScroll("h overscroll: overflow={d:.2} bonus {d:.2}->{d:.2}", .{
        overflow, prev_bonus, state.bonus_x,
    });
}

pub fn applyNearBoundaryResistance(distance_to_boundary: f32, delta: f32, is_momentum: bool) f32 {
    const t = ScrollState.scroll_tuning;
    const zone = @max(t.edge_resistance_zone_px, 1.0);
    if (distance_to_boundary >= zone) return delta;
    const ratio = std.math.clamp(distance_to_boundary / zone, 0.0, 1.0);
    const eased = ratio * ratio;
    const min_factor = if (is_momentum)
        t.momentum_edge_resistance_min_factor
    else
        t.edge_resistance_min_factor;
    const factor = std.math.clamp(min_factor + (1.0 - min_factor) * eased, min_factor, 1.0);
    if (factor < 0.999) {
        logScroll(
            "edge resistance: dist={d:.2} delta={d:.2} factor={d:.3} momentum={}",
            .{ distance_to_boundary, delta, factor, is_momentum },
        );
    }
    return delta * factor;
}

pub fn applyVerticalNearBoundaryResistance(state: *const ScrollState, delta: f32, max: f32, is_momentum: bool) f32 {
    if (delta == 0 or max <= 0) return delta;
    if (delta < 0) {
        // 向顶部边界外推
        return applyNearBoundaryResistance(@max(state.scroll_y, 0), delta, is_momentum);
    }
    // 向底部边界外推
    return applyNearBoundaryResistance(@max(max - state.scroll_y, 0), delta, is_momentum);
}

pub fn applyHorizontalNearBoundaryResistance(state: *const ScrollState, delta: f32, max: f32, is_momentum: bool) f32 {
    if (delta == 0 or max <= 0) return delta;
    if (delta < 0) {
        return applyNearBoundaryResistance(@max(state.scroll_x, 0), delta, is_momentum);
    }
    return applyNearBoundaryResistance(@max(max - state.scroll_x, 0), delta, is_momentum);
}
