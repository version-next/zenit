/// ScrollArea 滚动事件处理
///
/// scrollEventHandler + 嵌套滚动链委托 + momentum 过滤 + 辅助判断函数
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
const render_engine = @import("../../core/render_engine/mod.zig");
const applyVerticalScroll = scroll_physics.applyVerticalScroll;
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
                "event in id={d} dir={s} dy={d:.2} dx={d:.2} momentum={} phase_end={} trackpad={} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{
                    container.id,
                    @tagName(ctx.direction),
                    scroll.dy,
                    scroll.dx,
                    scroll.is_momentum,
                    scroll.phase_ended,
                    scroll.is_trackpad,
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
            // 用户主动输入（非 momentum）到达时，清除所有残余抑制状态，
            // 确保新手势不被 guard/suppress 误拦截。
            if (!scroll.phase_ended and !scroll.is_momentum) {
                state.phase_end_guard_frames = 0;
                state.bounce_active_y = false;
                state.bounce_active_x = false;
                state.bounce_done_time_y = 0;
                state.bounce_done_time_x = 0;
                state.awaiting_trackpad_reengage = false;
            }
            if (!scroll.phase_ended and !scroll.is_momentum and shouldSuppressIdleResidualTail(state, ctx.direction, scroll.dx, scroll.dy, ctx.scroll_speed)) {
                logScroll("tail_filter suppress: dy={d:.2} dx={d:.2} tail_idle_frames={d}", .{
                    scroll.dy,
                    scroll.dx,
                    state.tail_idle_frames,
                });
                return .stop;
            }
            const outward = isOutwardAtBoundary(state, ctx.direction, scroll.dx, scroll.dy, ctx.scroll_speed);
            // phase-end 护栏仅在"当前无 active bonus"时生效，避免边界动量被硬切断。
            if (outward and state.phase_end_guard_frames > 0 and !hasActiveBonusForDirection(state, ctx.direction)) {
                logScroll("momentum_guard phase-end: dy={d:.2} dx={d:.2} guard={d}", .{
                    scroll.dy,
                    scroll.dx,
                    state.phase_end_guard_frames,
                });
                return .stop;
            }
            const primary = primaryAbsDelta(ctx.direction, scroll.dx, scroll.dy, ctx.scroll_speed);
            // 回弹动画进行中 → 拒绝 outward momentum
            const bounce_active = hasBounceActive(state, ctx.direction);
            if (outward and bounce_active) {
                logScroll("momentum_guard bounce-active: dy={d:.2} dx={d:.2} primary={d:.2}", .{
                    scroll.dy,
                    scroll.dx,
                    primary,
                });
                return .stop;
            }
            // 回弹完成后短窗口内拦截 outward momentum（绝对时间护栏，防止 momentum 尾巴重新越界）
            if (outward and scroll.is_momentum) {
                const now_ms = render_engine.current_frame_time_ms;
                const guard_ms: f64 = 500; // 护栏持续 500ms
                const y_guard = state.bounce_done_time_y > 0 and (now_ms - state.bounce_done_time_y) < guard_ms;
                const x_guard = state.bounce_done_time_x > 0 and (now_ms - state.bounce_done_time_x) < guard_ms;
                const in_guard = switch (ctx.direction) {
                    .vertical => y_guard,
                    .horizontal => x_guard,
                    .both => y_guard or x_guard,
                };
                if (in_guard) {
                    logScroll("momentum_guard post-bounce: dy={d:.2} dx={d:.2}", .{ scroll.dy, scroll.dx });
                    return .stop;
                }
            }
            // phase ended 后，过滤尾部残余小输入（尤其是边界向外抖动）
            if (!scroll.phase_ended and state.awaiting_trackpad_reengage) {
                const threshold = ScrollState.scroll_tuning.trackpad_reengage_delta_threshold;
                if (outward and primary <= threshold) {
                    logScroll("momentum_guard awaiting-reengage: dy={d:.2} dx={d:.2} primary={d:.2}", .{
                        scroll.dy,
                        scroll.dx,
                        primary,
                    });
                    return .stop;
                }
                state.awaiting_trackpad_reengage = false;
            }
            // phase_ended 优先处理：必须在 delegate 检查之前，
            // 因为 phase_ended 通常 dy=0，shouldDelegate 会返回 false，
            // 但如果本层没有活跃滚动，phase_ended 需要继续冒泡到真正在滚动的外层。
            if (scroll.phase_ended) {
                const was_active = state.user_scrolling or state.bonus_y != 0 or state.bonus_x != 0;
                state.user_scrolling = false;
                state.is_trackpad_session = false;
                // 触控板 phase_ended 是精确的"手势结束"信号，
                // 立即跳过 idle 保护窗口，避免子级 ScrollArea 被误判为
                // "外层活跃"而延迟接收新手势。
                state.scroll_event_idle_frames = ScrollState.scroll_tuning.wheel_release_frames + 1;

                if (!was_active) {
                    // 本层没有活跃滚动 → 不消费 phase_ended，让它冒泡到外层
                    logScroll("phase ended passthrough (inactive) id={d}: bonus_y={d:.2} bonus_x={d:.2}", .{ container.id, state.bonus_y, state.bonus_x });
                    return .ignored;
                }

                state.awaiting_trackpad_reengage = true;
                state.phase_end_guard_frames = ScrollState.scroll_tuning.phase_end_guard_frames;
                if (state.bonus_y != 0 or isAtVerticalBoundary(state)) {
                    state.suppress_outward_momentum_y = true;
                }
                if (state.bonus_x != 0 or isAtHorizontalBoundary(state)) {
                    state.suppress_outward_momentum_x = true;
                }
                logScroll("phase ended ACTIVE id={d}: bonus_y={d:.2} bonus_x={d:.2} user_scrolling_was={}", .{ container.id, state.bonus_y, state.bonus_x, was_active });
                // 如果同时也是 momentum 且已越界，不再处理 delta，直接让弹簧回弹
                if (state.bonus_y != 0 or state.bonus_x != 0) {
                    return .stop;
                }
                // phase ended 事件即使携带残余 delta，也不应重启拖拽/越界
                if (!scroll.is_momentum) {
                    return .stop;
                }
            }

            if (scrollDebugEnabled()) {
                if (container.meta.ownership.meta.component_name) |cn| {
                    if (std.mem.eql(u8, cn, "VirtualList") and ctx.direction == .both) {
                        const max_y = state.maxScrollY();
                        const max_x = state.maxScrollX();
                        logScroll("[ft-scroll] id={d} dy={d:.2} dx={d:.2} vh={d:.0} ch={d:.0} vw={d:.0} cw={d:.0} maxY={d:.0} maxX={d:.0} scroll_y={d:.1} ext_h={} ext_w={}", .{
                            container.id,
                            scroll.dy,
                            scroll.dx,
                            state.viewport_height,
                            state.content_height,
                            state.viewport_width,
                            state.content_width,
                            max_y,
                            max_x,
                            state.scroll_y,
                            state.external_content_height,
                            state.external_content_width,
                        });
                    }
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
                    skip_y = skip_y or shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, scroll.is_momentum);
                }
                if (can_h) {
                    skip_x = skip_x or shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, scroll.is_momentum);
                }
            } else {
                const single_axis_passthrough = switch (ctx.direction) {
                    .vertical => h_delta_abs > epsilon and h_delta_abs > v_delta_abs and !state.user_scrolling and !hasActiveBonusForDirection(state, .vertical),
                    .horizontal => v_delta_abs > epsilon and v_delta_abs > h_delta_abs and !state.user_scrolling and !hasActiveBonusForDirection(state, .horizontal),
                    .both => false,
                };
                if (single_axis_passthrough) {
                    logScroll("axis_passthrough cross-dominant: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    state.user_scrolling = false;
                    content.style.translate_y = state.contentTranslateY();
                    content.style.translate_x = state.contentTranslateX();
                    // 滚动逐帧平移（内容未变）：anim-frame 组合（interaction+composite）。
                    content.markCompositeAnimFrameDirty();
                    return .ignored;
                }

                // 单轴模式保持原逻辑
                const delegate_to_ancestor = switch (ctx.direction) {
                    .vertical => shouldDelegateVerticalToAncestor(state, ctx, scroll.dy, scroll.is_momentum),
                    .horizontal => shouldDelegateHorizontalToAncestor(state, ctx, scroll.dx, scroll.is_momentum),
                    .both => unreachable,
                };
                if (delegate_to_ancestor) {
                    logScroll("axis_delegate: id={d} dir={s} dy={d:.2} dx={d:.2}", .{
                        container.id,
                        @tagName(ctx.direction),
                        scroll.dy,
                        scroll.dx,
                    });
                    // 手势归属上抛 → 本层放弃 latch
                    if (!scroll.is_momentum) state.latched = false;
                    state.user_scrolling = false;
                    content.style.translate_y = state.contentTranslateY();
                    content.style.translate_x = state.contentTranslateX();
                    // 滚动逐帧平移（内容未变）：anim-frame 组合（interaction+composite）。
                    content.markCompositeAnimFrameDirty();
                    return .ignored;
                }
            }

            // momentum 事件不重置 scroll_event_idle_frames，
            // 因为 idle_frames 是给 hasActiveAncestorScrollAreaForAxis 判断"用户主动输入"的，
            // momentum 不是主动输入。如果 momentum 重置了 idle_frames，
            // 会导致 inner ScrollArea 误以为 outer 还在"活跃接收输入"，
            // 从而 delegate 新手势给 outer，inner 无法接管。
            // 注意：非 momentum 活动要在确认本层真的处理了某个轴后再记账，
            // 避免 .both 下"不可滚轴输入被忽略"也污染 activity/history。
            const pending_user_activity = !scroll.is_momentum;
            if (scroll.is_momentum) {
                // momentum 仍需要更新 scrollbar fade（视觉反馈）
                state.scrollbar_fade.onActivity();
            }

            // 新手势"接住"回弹（native hold 语义）：
            // 仅停掉弹簧动画并清速度，**保留当前 bonus**——内容停在手指按住的位置，
            // 后续输入经 consume-bonus / rubber-band 路径从当前位置继续（清零会导致内容跳变）。
            if (!scroll.is_momentum and !state.user_scrolling) {
                if (state.bounce_active_y or state.bonus_velocity != 0) {
                    logScroll("hold: catch bounce y bonus={d:.2} vel={d:.2}", .{ state.bonus_y, state.bonus_velocity });
                }
                state.bounce_active_y = false;
                state.bounce_active_x = false;
                state.bonus_velocity = 0;
                state.bonus_velocity_x = 0;
                state.suppress_outward_momentum_y = false;
                state.suppress_outward_momentum_x = false;
            }

            // 记录触摸板会话
            if (scroll.is_trackpad) state.is_trackpad_session = true;

            if (scroll.is_momentum) {
                var suppress = false;
                switch (ctx.direction) {
                    .vertical => {
                        const active_bonus_y = state.bonus_y != 0;
                        suppress = shouldSuppressOutwardMomentumY(state, scroll.dy, ctx.scroll_speed);
                        if (!suppress and state.suppress_outward_momentum_y and !active_bonus_y) {
                            state.suppress_outward_momentum_y = false;
                        }
                    },
                    .horizontal => {
                        const active_bonus_x = state.bonus_x != 0;
                        suppress = shouldSuppressOutwardMomentumX(state, scroll.dx, ctx.scroll_speed);
                        if (!suppress and state.suppress_outward_momentum_x and !active_bonus_x) {
                            state.suppress_outward_momentum_x = false;
                        }
                    },
                    .both => {
                        // .both 模式：按轴独立 suppress，被 suppress 的轴标记 skip，另一轴继续
                        const active_bonus_y = state.bonus_y != 0;
                        const active_bonus_x = state.bonus_x != 0;
                        const suppress_y = can_v and shouldSuppressOutwardMomentumY(state, scroll.dy, ctx.scroll_speed);
                        const suppress_x = can_h and shouldSuppressOutwardMomentumX(state, scroll.dx, ctx.scroll_speed);
                        if (suppress_y) skip_y = true;
                        if (suppress_x) skip_x = true;
                        suppress = suppress_y and suppress_x;
                        if (!suppress_y and state.suppress_outward_momentum_y and !active_bonus_y) {
                            state.suppress_outward_momentum_y = false;
                        }
                        if (!suppress_x and state.suppress_outward_momentum_x and !active_bonus_x) {
                            state.suppress_outward_momentum_x = false;
                        }
                    },
                }
                if (suppress) {
                    logScroll("momentum_guard outward-suppress: dy={d:.2} dx={d:.2} dir={s}", .{
                        scroll.dy,
                        scroll.dx,
                        @tagName(ctx.direction),
                    });
                    return .stop;
                }
            }

            // 已越界且仍有惯性事件：弹簧独占回弹。
            // 但允许足够大的 outward momentum 继续压缩越界（Apple 风格手感）。
            if (scroll.is_momentum) {
                const cutoff = ScrollState.scroll_tuning.momentum_bonus_tail_cutoff;
                switch (ctx.direction) {
                    .vertical => {
                        if (state.bonus_y != 0) {
                            const raw_dy = -scroll.dy * ctx.scroll_speed;
                            const outward_y = (state.bonus_y > 0 and raw_dy > 0) or (state.bonus_y < 0 and raw_dy < 0);
                            if (!outward_y or @abs(raw_dy) < cutoff) {
                                logScroll("momentum_guard bounce-owns y: dy={d:.2} bonus_y={d:.2}", .{ scroll.dy, state.bonus_y });
                                return .stop;
                            }
                        }
                    },
                    .horizontal => {
                        if (state.bonus_x != 0) {
                            const raw_dx = -scroll.dx * ctx.scroll_speed;
                            const outward_x = (state.bonus_x > 0 and raw_dx > 0) or (state.bonus_x < 0 and raw_dx < 0);
                            if (!outward_x or @abs(raw_dx) < cutoff) {
                                logScroll("momentum_guard bounce-owns x: dx={d:.2} bonus_x={d:.2}", .{ scroll.dx, state.bonus_x });
                                return .stop;
                            }
                        }
                    },
                    .both => {
                        const block_y = if (state.bonus_y != 0) blk: {
                            const raw_dy = -scroll.dy * ctx.scroll_speed;
                            const outward_y = (state.bonus_y > 0 and raw_dy > 0) or (state.bonus_y < 0 and raw_dy < 0);
                            break :blk !outward_y or @abs(raw_dy) < cutoff;
                        } else false;
                        const block_x = if (state.bonus_x != 0) blk: {
                            const raw_dx = -scroll.dx * ctx.scroll_speed;
                            const outward_x = (state.bonus_x > 0 and raw_dx > 0) or (state.bonus_x < 0 and raw_dx < 0);
                            break :blk !outward_x or @abs(raw_dx) < cutoff;
                        } else false;
                        if (block_y or block_x) {
                            if (block_y) skip_y = true;
                            if (block_x) skip_x = true;
                            logScroll("momentum_guard bounce-owns both: dy={d:.2} dx={d:.2} bonus_y={d:.2} bonus_x={d:.2} block_y={} block_x={}", .{
                                scroll.dy,
                                scroll.dx,
                                state.bonus_y,
                                state.bonus_x,
                                block_y,
                                block_x,
                            });
                            if ((block_y or !wants_v or !can_v) and (block_x or !wants_h or !can_h)) {
                                return .stop;
                            }
                        }
                    },
                }
            }

            // 惯性滚动开始 → 释放 user_scrolling，让弹簧可以回弹
            if (scroll.is_momentum and state.user_scrolling) {
                state.user_scrolling = false;
                state.is_trackpad_session = false;
                logScroll("momentum start: dy={d:.2} dx={d:.2} speed={d:.2}", .{
                    scroll.dy,
                    scroll.dx,
                    ctx.scroll_speed,
                });
            }

            var handled_axis = false;
            // 分轴跟踪 —— scrollbar fade 必须知道哪个轴被实际滚动，
            // 否则纯 Y 滚动也会让 X scrollbar 闪现（VSCode/Zed 行为：只显示活跃轴）。
            var applied_y = false;
            var applied_x = false;
            switch (ctx.direction) {
                .vertical => {
                    applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, scroll.is_momentum);
                    handled_axis = true;
                    applied_y = true;
                },
                .horizontal => {
                    applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, scroll.is_momentum);
                    handled_axis = true;
                    applied_x = true;
                },
                .both => {
                    if (!skip_y and can_v and wants_v) {
                        applyVerticalScroll(state, scroll.dy, ctx.scroll_speed, scroll.is_momentum);
                        handled_axis = true;
                        applied_y = true;
                    }
                    if (!skip_x and can_h and wants_h) {
                        applyHorizontalScroll(state, scroll.dx, ctx.scroll_speed, scroll.is_momentum);
                        handled_axis = true;
                        applied_x = true;
                    }
                },
            }
            if (ctx.direction == .both and !scroll.phase_ended and !handled_axis and (wants_v or wants_h)) {
                logScroll("axis_delegate: id={d} dir=both dy={d:.2} dx={d:.2} skip_y={} skip_x={} can_v={} can_h={}", .{
                    container.id,
                    scroll.dy,
                    scroll.dx,
                    skip_y,
                    skip_x,
                    can_v,
                    can_h,
                });
                if (!scroll.is_momentum) state.latched = false;
                state.user_scrolling = false;
                content.style.translate_y = state.contentTranslateY();
                content.style.translate_x = state.contentTranslateX();
                content.markCompositeAnimFrameDirty();
                return .ignored;
            }
            if (pending_user_activity) {
                state.onScrollActivityAxes(applied_y, applied_x);
                state.has_scroll_history = true;
                // 本层实际处理了这轮手势 → 持有 latch，momentum 跟随本层
                if (handled_axis) state.latched = true;
            } else if (handled_axis) {
                state.onMomentumActivityAxes(applied_y, applied_x);
            }
            logScroll(
                "event out id={d} scroll_y={d:.2} bonus_y={d:.2} scroll_x={d:.2} bonus_x={d:.2}",
                .{ container.id, state.scroll_y, state.bonus_y, state.scroll_x, state.bonus_x },
            );

            const new_ty = state.contentTranslateY();
            const new_tx = state.contentTranslateX();
            if (new_ty != content.style.translate_y or new_tx != content.style.translate_x) {
                content.style.translate_y = new_ty;
                content.style.translate_x = new_tx;
                content.markCompositeAnimFrameDirty();
            }
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

fn primaryAbsDelta(direction: ScrollDirection, dx: f32, dy: f32, speed: f32) f32 {
    const v = @abs(-dy * speed);
    const h = @abs(-dx * speed);
    return switch (direction) {
        .vertical => v,
        .horizontal => h,
        .both => @max(v, h),
    };
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

fn shouldSuppressIdleResidualTail(state: *const ScrollState, direction: ScrollDirection, dx: f32, dy: f32, speed: f32) bool {
    if (!state.has_scroll_history) return false;
    if (state.user_scrolling) return false;
    if (state.tail_idle_frames <= ScrollState.scroll_tuning.wheel_release_frames) return false;
    const primary = primaryAbsDelta(direction, dx, dy, speed);
    if (primary > ScrollState.scroll_tuning.idle_residual_delta_threshold) return false;
    return isOutwardAtBoundary(state, direction, dx, dy, speed);
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
                    // 判定祖先是否"正在接收输入"：
                    // - user_scrolling: 手指/滚轮正在输入（精确信号）
                    // - scroll_event_idle_frames: 鼠标滚轮的猜测性保护窗口
                    //   （鼠标滚轮无 phase 信号，用短超时代替）
                    const active = s.user_scrolling or
                        s.scroll_event_idle_frames <= ScrollState.scroll_tuning.wheel_release_frames;
                    if (active) {
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
    if (state.user_scrolling) return false;

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
    if (state.user_scrolling) return false;

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

fn shouldSuppressOutwardMomentumY(state: *const ScrollState, dy: f32, speed: f32) bool {
    if (!state.suppress_outward_momentum_y) return false;
    // 保留"越界时 outward momentum 继续压缩 bonus"的手感：
    // 仅在 bonus 已回零后才启用 outward suppress。
    if (state.bonus_y != 0) return false;
    const max = state.maxScrollY();
    if (max <= 0) return true;

    const delta = -dy * speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return true;

    const at_top = state.scroll_y <= epsilon;
    const at_bottom = state.scroll_y >= max - epsilon;
    const outw = (at_top and delta < 0) or (at_bottom and delta > 0);
    if (!outw) return false;
    // suppress 只拦截小尾巴，避免大动量被硬切断造成"闸刀感"。
    return @abs(delta) <= state.tuning().idle_residual_delta_threshold;
}

fn shouldSuppressOutwardMomentumX(state: *const ScrollState, dx: f32, speed: f32) bool {
    if (!state.suppress_outward_momentum_x) return false;
    // 同 Y 轴：active bonus 阶段允许 outward momentum 继续塑形。
    if (state.bonus_x != 0) return false;
    const max = state.maxScrollX();
    if (max <= 0) return true;

    const delta = -dx * speed;
    const epsilon = ScrollState.scroll_tuning.jitter_snap_epsilon;
    if (@abs(delta) <= epsilon) return true;

    const at_left = state.scroll_x <= epsilon;
    const at_right = state.scroll_x >= max - epsilon;
    const outw = (at_left and delta < 0) or (at_right and delta > 0);
    if (!outw) return false;
    return @abs(delta) <= state.tuning().idle_residual_delta_threshold;
}
