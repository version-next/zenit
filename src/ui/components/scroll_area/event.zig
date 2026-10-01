/// ScrollArea 滚动事件处理
///
/// scrollEventHandler + 嵌套滚动链委托 + 惯性归属 + 辅助判断函数
const std = @import("std");
const core = @import("../../core.zig");
const Node = core.Node;
const Event = core.Event;
const EventResult = core.EventResult;

const state_mod = @import("state.zig");
const ScrollState = state_mod.ScrollState;
const ScrollDirection = state_mod.ScrollDirection;
const ScrollEventCtx = state_mod.ScrollEventCtx;

const scroll_physics = @import("physics.zig");
const applyVerticalScroll = scroll_physics.applyVerticalScroll;
const InputKind = scroll_physics.InputKind;
const applyHorizontalScroll = scroll_physics.applyHorizontalScroll;

const debug = @import("debug.zig");
const logScroll = debug.logScroll;
const scrollDebugEnabled = debug.scrollDebugEnabled;

pub fn scrollEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *const ScrollEventCtx = @ptrCast(@alignCast(context.?));
    const state = ctx.state;
    const content = ctx.content orelse return .ignored;
    const container = ctx.container orelse return .ignored;

    switch (event) {
        .scroll => |scroll| {
            logScroll(
                "event in id={d} dir={s} dy={d:.2} dx={d:.2} phase={s} momentum={s} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{
                    container.id,
                    @tagName(ctx.direction),
                    scroll.dy,
                    scroll.dx,
                    @tagName(scroll.phase),
                    @tagName(scroll.momentum),
                    state.scroll_y,
                    state.bonus_y,
                    state.scroll_x,
                    state.bonus_x,
                },
            );
            if (content.parent) |parent| {
                const pr = parent.rectFromWorldOrFallback();
                state.viewport_height = pr.h - parent.style.padding.vertical();
                state.viewport_width = pr.w - parent.style.padding.horizontal();
            }
            const cr = content.rectFromWorldOrFallback();
            if (!state.external_content_height and cr.h > 0) state.content_height = cr.h;
            if (!state.external_content_width and cr.w > 0) state.content_width = cr.w;

            // viewport 还没初始化（未经过任何 layout），暂不处理
            if (state.viewport_height <= 0 and state.viewport_width <= 0) {
                return .ignored;
            }

            const kind: InputKind = if (scroll.isMomentum())
                .momentum
            else if (scroll.phase == .none)
                .wheel
            else
                .gesture;

            // 开始信号只由手指下的这一层处理（owner），不冒泡：外层若在回弹，
            // 冒泡会让它"接住回弹"而被当成持有手势，把内层的手势抢走。外层上的
            // 旧惯性由调度器补发的惯性 ended 结束；手势委托给外层时，外层在第一次
            // 实际滚动时 beginTouch。
            // 结束信号则继续冒泡：手势可能中途委托给了外层，必须到达真正持有它的那层。
            switch (scroll.phase) {
                .may_begin, .began => {
                    state.momentum_active = false;
                    state.momentum_spent_y = false;
                    state.momentum_spent_x = false;
                    state.latched = false;
                    // 手指放下接住本层进行中的回弹
                    if (state.bonus_y != 0 or state.bonus_x != 0 or state.bounce_active_y or state.bounce_active_x) {
                        state.beginTouch();
                    }
                    if (scroll.dx == 0 and scroll.dy == 0) return .stop;
                },
                .ended, .cancelled => {
                    if (state.touching) {
                        state.touching = false;
                        // 松手时已越界：这一轴随后朝外的惯性交给弹簧
                        if (state.bonus_y != 0) state.momentum_spent_y = true;
                        if (state.bonus_x != 0) state.momentum_spent_x = true;
                        logScroll("touch end id={d} phase={s} bonus_y={d:.2} bonus_x={d:.2}", .{ container.id, @tagName(scroll.phase), state.bonus_y, state.bonus_x });
                    }
                    // cancelled 之后没有惯性，手势归属到此为止
                    if (scroll.phase == .cancelled) state.latched = false;
                    return .ignored;
                },
                .none, .changed => {},
            }
            if (kind == .momentum) {
                // 有惯性说明手指已经离开
                state.touching = false;
                if (scroll.momentum == .ended) {
                    state.momentum_active = false;
                    state.latched = false;
                    return .ignored;
                }
            }

            // 嵌套滚动链：边界向外滚时，让外层 ScrollArea 处理（更接近 iOS/macOS 原生手感）
            // .both 模式：两轴独立 delegate，一个轴 delegate 不影响另一轴正常滚动
            var skip_y = false;
            var skip_x = false;
            const wants_v = scroll.dy != 0;
            const wants_h = scroll.dx != 0;
            const can_v = canScrollVerticalAxis(state);
            const can_h = canScrollHorizontalAxis(state);
            const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
            const v_delta_abs = @abs(-scroll.dy * ctx.scroll_speed);
            const h_delta_abs = @abs(-scroll.dx * ctx.scroll_speed);
            const is_momentum = kind == .momentum;

            if (ctx.direction == .both) {
                if (wants_v and !can_v) {
                    skip_y = true;
                    logScroll("axis_skip y: reason=no-scroll-space dy={d:.2} max_y={d:.2} bonus_y={d:.2}", .{
                        scroll.dy,
                        state.maxScrollY(),
                        state.bonus_y,
                    });
                }
                if (wants_h and !can_h) {
                    skip_x = true;
                    logScroll("axis_skip x: reason=no-scroll-space dx={d:.2} max_x={d:.2} bonus_x={d:.2}", .{
                        scroll.dx,
                        state.maxScrollX(),
                        state.bonus_x,
                    });
                }
                if (can_v) {
                    skip_y = skip_y or shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, is_momentum);
                }
                if (can_h) {
                    skip_x = skip_x or shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, is_momentum);
                }
                // 一个轴要交给外层、另一个轴本层能滚：按主导轴决定整个事件的归属（与单轴
                // 的 cross-dominant passthrough 同一规则），否则本层吃掉一轴、另一轴凭空
                // 消失。本层已持有手势（或它的惯性）时不换手，次要轴随之留在本层。
                const y_leaves = wants_v and skip_y;
                const x_leaves = wants_h and skip_x;
                const holds_stream = state.touching or (is_momentum and state.latched);
                if (!holds_stream and y_leaves != x_leaves) {
                    const leaving_dominant = if (y_leaves) v_delta_abs > h_delta_abs else h_delta_abs > v_delta_abs;
                    if (leaving_dominant) {
                        logScroll("axis_passthrough both dominant-leaves: id={d} dy={d:.2} dx={d:.2}", .{ container.id, scroll.dy, scroll.dx });
                        if (kind == .gesture) state.latched = false;
                        return .ignored;
                    }
                }
            } else {
                const single_axis_passthrough = switch (ctx.direction) {
                    .vertical => h_delta_abs > epsilon and h_delta_abs > v_delta_abs and !state.touching and !hasActiveBonusForDirection(state, .vertical),
                    .horizontal => v_delta_abs > epsilon and v_delta_abs > h_delta_abs and !state.touching and !hasActiveBonusForDirection(state, .horizontal),
                    .both => false,
                };
                if (single_axis_passthrough) {
                    logScroll("axis_passthrough cross-dominant: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    return .ignored;
                }

                const delegate_to_ancestor = switch (ctx.direction) {
                    .vertical => shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, is_momentum),
                    .horizontal => shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, is_momentum),
                    .both => unreachable,
                };
                if (delegate_to_ancestor) {
                    logScroll("axis_delegate: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    // 手势归属上抛 -> 本层放弃 latch
                    if (kind == .gesture) {
                        state.latched = false;
                        state.touching = false;
                    }
                    syncContentTranslate(state, content);
                    return .ignored;
                }
            }

            // 惯性：越界部分归弹簧；本段惯性已撞过边界的轴不再朝外推。
            if (kind == .momentum) {
                state.momentum_active = true;
                const block_y = momentumBlockedY(state, scroll.dy, ctx.scroll_speed);
                const block_x = momentumBlockedX(state, scroll.dx, ctx.scroll_speed);
                switch (ctx.direction) {
                    .vertical => if (block_y) {
                        logScroll("momentum blocked y: dy={d:.2} bonus_y={d:.2} spent={}", .{ scroll.dy, state.bonus_y, state.momentum_spent_y });
                        return .stop;
                    },
                    .horizontal => if (block_x) {
                        logScroll("momentum blocked x: dx={d:.2} bonus_x={d:.2} spent={}", .{ scroll.dx, state.bonus_x, state.momentum_spent_x });
                        return .stop;
                    },
                    .both => {
                        if (block_y) skip_y = true;
                        if (block_x) skip_x = true;
                        if ((block_y or !wants_v or !can_v) and (block_x or !wants_h or !can_h) and (block_y or block_x)) {
                            logScroll("momentum blocked both: dy={d:.2} dx={d:.2} block_y={} block_x={}", .{ scroll.dy, scroll.dx, block_y, block_x });
                            return .stop;
                        }
                    },
                }
            }

            if (kind == .gesture) state.beginTouch();

            var handled_axis = false;
            // 分轴跟踪，scrollbar fade 必须知道哪个轴被实际滚动，
            // 否则纯 Y 滚动也会让 X scrollbar 闪现（VSCode/Zed 行为：只显示活跃轴）。
            var applied_y = false;
            var applied_x = false;
            switch (ctx.direction) {
                .vertical => {
                    applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, kind);
                    handled_axis = true;
                    applied_y = true;
                },
                .horizontal => {
                    applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, kind);
                    handled_axis = true;
                    applied_x = true;
                },
                .both => {
                    if (!skip_y and can_v and wants_v) {
                        applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, kind);
                        handled_axis = true;
                        applied_y = true;
                    }
                    if (!skip_x and can_h and wants_h) {
                        applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, kind);
                        handled_axis = true;
                        applied_x = true;
                    }
                },
            }
            if (ctx.direction == .both and !handled_axis and (wants_v or wants_h)) {
                logScroll("axis_delegate: id={d} dir=both dy={d:.2} dx={d:.2} skip_y={} skip_x={} can_v={} can_h={}", .{
                    container.id,
                    scroll.dy,
                    scroll.dx,
                    skip_y,
                    skip_x,
                    can_v,
                    can_h,
                });
                if (kind == .gesture) {
                    state.latched = false;
                    state.touching = false;
                }
                syncContentTranslate(state, content);
                return .ignored;
            }
            if (handled_axis) {
                state.input_serial +%= 1;
                state.onScrollActivityAxes(applied_y, applied_x);
                switch (kind) {
                    // 本层实际处理了这轮手势 -> 持有 latch，momentum 跟随本层
                    .gesture => state.latched = true,
                    .momentum => {
                        if (applied_y and state.bonus_y != 0) state.momentum_spent_y = true;
                        if (applied_x and state.bonus_x != 0) state.momentum_spent_x = true;
                    },
                    .wheel => {},
                }
            }
            logScroll(
                "event out id={d} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{ container.id, state.scroll_y, state.bonus_y, state.scroll_x, state.bonus_x },
            );
            syncContentTranslate(state, content);
            return .stop;
        },
        .mouse_move => |move| {
            // 垂直条 hover 检测：视觉更细，但保留更宽的交互热区。
            const sb = ctx.scrollbar orelse return .ignored;
            const was_hovered = state.scrollbar_hovered;
            state.scrollbar_hovered = state.needsScrollbar() and sb.rectFromWorldOrFallback().w > 0 and
                move.x >= sb.rectFromWorldOrFallback().x - state_mod.ScrollbarVisual.hover_slop and move.x <= sb.rectFromWorldOrFallback().x + sb.rectFromWorldOrFallback().w + state_mod.ScrollbarVisual.hover_slop;
            if (state.scrollbar_hovered and !was_hovered) state.onScrollActivity();
            // 水平条 hover 检测：同样使用热区放大，避免细条难命中。
            const sb_h = ctx.scrollbar_h orelse return .ignored;
            const was_hovered_h = state.scrollbar_hovered_h;
            state.scrollbar_hovered_h = state.needsHScrollbar() and sb_h.rectFromWorldOrFallback().h > 0 and
                move.y >= sb_h.rectFromWorldOrFallback().y - state_mod.ScrollbarVisual.hover_slop and move.y <= sb_h.rectFromWorldOrFallback().y + sb_h.rectFromWorldOrFallback().h + state_mod.ScrollbarVisual.hover_slop;
            if (state.scrollbar_hovered_h and !was_hovered_h) state.onScrollActivity();
            return .ignored;
        },
        .mouse_down => {
            // container 不处理 mouse_down，scrollbar 的 hitTest 会处理
            return .ignored;
        },
        else => return .ignored,
    }
}

// ========== 辅助判断函数 ==========

pub fn isAtVerticalBoundary(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollY();
    if (max <= epsilon) return true;
    return state.scroll_y <= epsilon or state.scroll_y >= max - epsilon;
}

pub fn canScrollVerticalAxis(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    return state.maxScrollY() > epsilon or state.bonus_y != 0;
}

pub fn canScrollHorizontalAxis(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    return state.maxScrollX() > epsilon or state.bonus_x != 0;
}

fn isOutwardAtBoundaryY(state: *const ScrollState, delta: f32) bool {
    if (delta == 0) return false;
    if (state.bonus_y < 0) return delta < 0;
    if (state.bonus_y > 0) return delta > 0;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollY();
    if (max <= epsilon) return true;
    const at_top = state.scroll_y <= epsilon;
    const at_bottom = state.scroll_y >= max - epsilon;
    return (at_top and delta < 0) or (at_bottom and delta > 0);
}

fn isOutwardAtBoundaryX(state: *const ScrollState, delta: f32) bool {
    if (delta == 0) return false;
    if (state.bonus_x < 0) return delta < 0;
    if (state.bonus_x > 0) return delta > 0;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollX();
    if (max <= epsilon) return true;
    const at_left = state.scroll_x <= epsilon;
    const at_right = state.scroll_x >= max - epsilon;
    return (at_left and delta < 0) or (at_right and delta > 0);
}

/// 回弹动画是否活跃（duration 内 outward momentum 被拒绝）
pub fn hasBounceActive(state: *const ScrollState, direction: ScrollDirection) bool {
    return switch (direction) {
        .vertical => state.bounce_active_y,
        .horizontal => state.bounce_active_x,
        .both => state.bounce_active_y or state.bounce_active_x,
    };
}

fn hasActiveBonusForDirection(state: *const ScrollState, direction: ScrollDirection) bool {
    return switch (direction) {
        .vertical => state.bonus_y != 0,
        .horizontal => state.bonus_x != 0,
        .both => state.bonus_y != 0 or state.bonus_x != 0,
    };
}

pub fn isOutwardAtBoundary(state: *const ScrollState, direction: ScrollDirection, dx: f32, dy: f32, speed: f32) bool {
    const v_delta = -dy * speed;
    const h_delta = -dx * speed;
    return switch (direction) {
        .vertical => isOutwardAtBoundaryY(state, v_delta),
        .horizontal => isOutwardAtBoundaryX(state, h_delta),
        // .both: delta=0 的轴视为中性（不参与判断），
        // 只对有非零 delta 的轴做 outward 检查
        .both => blk: {
            const has_v = canScrollVerticalAxis(state);
            const has_h = canScrollHorizontalAxis(state);
            const v_active = has_v and v_delta != 0;
            const h_active = has_h and h_delta != 0;
            if (v_active and h_active) {
                break :blk isOutwardAtBoundaryY(state, v_delta) and isOutwardAtBoundaryX(state, h_delta);
            }
            if (v_active) break :blk isOutwardAtBoundaryY(state, v_delta);
            if (h_active) break :blk isOutwardAtBoundaryX(state, h_delta);
            break :blk false; // 两个轴都没活跃 delta
        },
    };
}

const ScrollAxis = enum {
    vertical,
    horizontal,
};

fn supportsAxis(direction: ScrollDirection, axis: ScrollAxis) bool {
    return switch (direction) {
        .vertical => axis == .vertical,
        .horizontal => axis == .horizontal,
        .both => true,
    };
}

/// 单次遍历祖先链，同时检查是否存在支持该轴的祖先 ScrollArea 及其是否活跃
const AncestorCheckResult = struct {
    exists: bool,
    is_active: bool,
    /// 是否有祖先持有当前手势的 latch（momentum 归属判断用）
    has_latch: bool,
};

fn checkAncestorScrollArea(container: *Node, axis: ScrollAxis) AncestorCheckResult {
    var result = AncestorCheckResult{ .exists = false, .is_active = false, .has_latch = false };
    var node = container.parent;
    while (node) |n| : (node = n.parent) {
        if (n.behavior.events.on_event) |handler| {
            if (handler == scrollEventHandler) {
                if (n.behavior.events.event_context) |raw_ctx| {
                    const ancestor_ctx: *const ScrollEventCtx = @ptrCast(@alignCast(raw_ctx));
                    if (!supportsAxis(ancestor_ctx.direction, axis)) continue;
                    result.exists = true;
                    const s = ancestor_ctx.state;
                    if (s.latched) result.has_latch = true;
                    // 祖先正持有当前触控板手势（手指在板上）
                    if (s.touching) {
                        result.is_active = true;
                        break; // 找到活跃祖先，无需继续
                    }
                }
            }
        }
    }
    return result;
}

fn shouldDelegateVerticalToAncestor(state: *ScrollState, ctx: *const ScrollEventCtx, dy: f32, is_momentum: bool) bool {
    if (dy == 0) return false;
    const container = ctx.container orelse return false;
    const ancestor = checkAncestorScrollArea(container, .vertical);
    if (!ancestor.exists) return false;

    const delta = -dy * ctx.scroll_speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return false;
    // macOS 手势 latching：momentum 归 latch 持有者；本层 latch 则永不上抛，
    // 否则若有活跃/latch 的祖先则冒泡（惯性跟随发起手势的那一层）。
    if (is_momentum) {
        if (state.latched) return false;
        return ancestor.is_active or ancestor.has_latch;
    }
    if (ancestor.is_active) return true;
    // 手势中段不换手（NSScrollView 10.9+ latch 语义）：
    // 本层已开始处理这轮手势后，即使滚到边界也留在本层 rubber-band，不上抛。
    if (state.touching) return false;

    const max = state.maxScrollY();
    if (max <= epsilon) return true;

    const projected = state.scroll_y + delta;
    if (projected < -epsilon) {
        if (state.scroll_y > 0) state.scroll_y = 0;
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return true;
    }
    if (projected > max + epsilon) {
        if (state.scroll_y < max) state.scroll_y = max;
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return true;
    }
    return false;
}

fn shouldDelegateHorizontalToAncestor(state: *ScrollState, ctx: *const ScrollEventCtx, dx: f32, is_momentum: bool) bool {
    if (dx == 0) return false;
    const container = ctx.container orelse return false;
    const ancestor = checkAncestorScrollArea(container, .horizontal);
    if (!ancestor.exists) return false;

    const delta = -dx * ctx.scroll_speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return false;
    if (is_momentum) {
        if (state.latched) return false;
        return ancestor.is_active or ancestor.has_latch;
    }
    if (ancestor.is_active) return true;
    // 手势中段不换手（latch 语义），到边界后本层 rubber-band
    if (state.touching) return false;

    const max = state.maxScrollX();
    if (max <= epsilon) return true;

    const projected = state.scroll_x + delta;
    if (projected < -epsilon) {
        if (state.scroll_x > 0) state.scroll_x = 0;
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return true;
    }
    if (projected > max + epsilon) {
        if (state.scroll_x < max) state.scroll_x = max;
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return true;
    }
    return false;
}

pub fn isAtHorizontalBoundary(state: *const ScrollState) bool {
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    const max = state.maxScrollX();
    if (max <= epsilon) return true;
    return state.scroll_x <= epsilon or state.scroll_x >= max - epsilon;
}

fn syncContentTranslate(state: *const ScrollState, content: *Node) void {
    const new_ty = state.contentTranslateY();
    const new_tx = state.contentTranslateX();
    if (new_ty != content.style.translate_y or new_tx != content.style.translate_x) {
        content.style.translate_y = new_ty;
        content.style.translate_x = new_tx;
        // 滚动逐帧平移（内容未变）：anim-frame 组合（interaction+composite）。
        content.markCompositeAnimFrameDirty();
    }
}

/// 惯性在 Y 轴是否不再作用于内容：越界量由弹簧独占；或本段惯性已撞过边界且仍朝外。
fn momentumBlockedY(state: *const ScrollState, dy: f32, speed: f32) bool {
    if (dy == 0) return false;
    if (state.bonus_y != 0) return true;
    return state.momentum_spent_y and isOutwardAtBoundaryY(state, -dy * speed);
}

fn momentumBlockedX(state: *const ScrollState, dx: f32, speed: f32) bool {
    if (dx == 0) return false;
    if (state.bonus_x != 0) return true;
    return state.momentum_spent_x and isOutwardAtBoundaryX(state, -dx * speed);
}
