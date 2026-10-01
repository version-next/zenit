/// 帧前 tick：声明式 Transition 推进、命令式动画 tick、on_before_render 钩子、视口裁剪遍历
const std = @import("std");
const tick_node_dirty = @import("../node_dirty.zig");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const geometry = @import("geometry.zig");
// 帧时间全局变量由 mod.zig 定义，tick 函数通过参数接收 now_ms，
// tickBeforeRender 调用方（mod.zig）传入 current_frame_time_ms

const Allocator = std.mem.Allocator;
const ComputedRect = types.ComputedRect;
const Node = node_mod.Node;

fn transitionPropAffectsOpacity(prop: types.TransitionProp) bool {
    return prop == .opacity;
}

fn transitionPropAffectsTransform(prop: types.TransitionProp) bool {
    return switch (prop) {
        .translate_x, .translate_y, .scale_x, .scale_y, .rotate => true,
        else => false,
    };
}

/// 声明式 Transition tick：推进所有活跃过渡的进度，更新 style 值
/// 返回 true 表示仍有活跃过渡（需要继续重绘）
pub fn tickTransitions(node: *Node, slots: *types.TransitionSlots, allocator: Allocator, now_ms: f64) bool {
    var still_active = false;
    var interaction_changed = false;
    var composite_changed = false;
    var render_changed = false;
    var requested_linger = false;

    // 收集完成回调（延迟到循环结束后触发，避免回调中销毁节点导致 use-after-free）
    var pending_callbacks: [12]struct { cb: *const fn (*anyopaque) void, ctx: *anyopaque } = undefined;
    var pending_count: u5 = 0;

    for (slots.slots[0..slots.count]) |*slot| {
        if (!slot.active) continue;

        // 绝对时间戳驱动：progress = (now - start) / duration，零累积误差
        const elapsed = @as(f32, @floatCast(now_ms - slot.start_time_ms));
        const progress = if (slot.spec.duration_ms > 0)
            std.math.clamp(elapsed / slot.spec.duration_ms, 0, 1)
        else
            @as(f32, 1.0);

        const is_complete = progress >= 1.0;

        if (is_complete) {
            slot.active = false;
            const affects_opacity = transitionPropAffectsOpacity(slot.prop);
            const affects_transform = transitionPropAffectsTransform(slot.prop);
            if (affects_opacity or affects_transform) {
                node.requestCompositeAnimationLinger(affects_opacity, affects_transform);
                requested_linger = true;
            }
            // 收集完成回调（不立即触发）
            if (slot.on_complete) |cb| {
                if (slot.on_complete_ctx) |ctx| {
                    if (pending_count < 12) {
                        pending_callbacks[pending_count] = .{ .cb = cb, .ctx = ctx };
                        pending_count += 1;
                    }
                }
                slot.on_complete = null;
                slot.on_complete_ctx = null;
            }
        } else {
            still_active = true;
        }

        const t = slot.spec.easing.apply(progress);

        // 完成时精确赋终值，避免 from + (to - from) * 1.0 的浮点舍入误差
        const lerped = if (is_complete) slot.to_value else slot.from_value + (slot.to_value - slot.from_value) * t;

        // 应用插值到 style
        switch (slot.prop) {
            .background => {
                node.setBackgroundRaw(if (is_complete) slot.to_color else types.Color.lerp(slot.from_color, slot.to_color, t));
                render_changed = true;
            },
            .border_color => {
                node.style.border.color = if (is_complete) slot.to_color else types.Color.lerp(slot.from_color, slot.to_color, t);
                render_changed = true;
            },
            .opacity => {
                node.setOpacityRaw(lerped);
                interaction_changed = true;
                composite_changed = true;
            },
            .translate_x => {
                node.style.translate_x = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .translate_y => {
                node.style.translate_y = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .scale_x => {
                node.style.ensureExtPanic(allocator).scale_x = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .scale_y => {
                node.style.ensureExtPanic(allocator).scale_y = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .rotate => {
                node.style.ensureExtPanic(allocator).rotate = lerped;
                interaction_changed = true;
                composite_changed = true;
            },
            .corner_radius => {
                node.style.ensureExtPanic(allocator).corner_radius = .{ .all = @max(0, lerped) };
                interaction_changed = true;
                render_changed = true;
            },
            .border_width => {
                node.style.border.setUniformWidth(lerped);
                interaction_changed = true;
                render_changed = true;
            },
            .width => {
                node.style.width = .{ .px = @max(0, lerped) };
                node.markLayoutDirty();
            },
        }
    }

    slots.any_active = still_active;
    // composite 类属性统一走权威失效组合（markCompositePropDirty = interaction +
    // composite + invalidateRenderCache），与 node_animator / hooks / setter 一致。
    if (composite_changed) {
        node.markCompositePropDirty();
    } else {
        if (interaction_changed) node.markInteractionDirty();
        if (render_changed) node.markRenderDirty();
    }

    // 循环结束后触发延迟回调（此时 node 访问已完成，回调可安全销毁节点）
    for (pending_callbacks[0..pending_count]) |entry| {
        entry.cb(entry.ctx);
    }

    return still_active or requested_linger;
}

/// DEBUG: 全局帧计数（用于限频 log）
pub var g_debug_frame: u64 = 0;
/// DEBUG: 当前帧内触发 markRenderDirty 的 hook 计数
pub var g_debug_dirty_hooks: u32 = 0;

var dirty_hook_debug_cache: ?bool = null;

fn dirtyHookDebugEnabled() bool {
    return dirty_hook_debug_cache orelse blk: {
        const enabled = std.posix.getenv("ZENIT_RENDER_DIRTY_DEBUG") != null;
        dirty_hook_debug_cache = enabled;
        break :blk enabled;
    };
}

/// self-only 担保的运行期稽核（仅 Debug/ReleaseSafe）。
///
/// 背景：before_render_hook_affects_self_only 是**调用方担保**，而框架里存在
/// 一批"无副作用写入口"（setBackgroundRaw / setOpacityRaw，生产代码 151 处），
/// 它们不标脏、不 bump content_version。担保一旦说谎，跨帧缓存会复用陈旧
/// DisplayItem, transform 类写入有 property_tree 每帧重算兜底，但**颜色/
/// 不透明度这类烘焙进 item 的值没有兜底，画面会静默错到下一次真脏**。
///
/// 稽核的判据必须**恰好等于威胁模型**，否则就会惩罚合法用法（两次交叉审查
/// 各抓到一次，都已用探针复现）：
///   - 只看"值变了"-> hook 自己 mount 一个新后代也会被判违约（新节点不存在
///     陈旧复用问题）。首个真实采纳者（编辑器 hook 每帧驱动 VirtualList
///     挂载/回收）会每帧崩。
///   - 只看"值变了"-> 连 panic 文案推荐的修法（改走 setBackground，会标脏、
///     缓存语义安全）也照样触发 panic，自相矛盾。
/// 所以这里比对的是 **(节点身份, 绘制值, content_version) 三元组**，且只针对
/// **跑 hook 之前就已存在**的节点：
///   - 新增节点：不参与（本帧全新构建，无陈旧可复用）；
///   - 消失节点：不参与（不会被复用）；
///   - 既存节点值变了**且 content_version 也变了**：合法（标脏写，缓存会失效）；
///   - 既存节点值变了**而 content_version 没变**：**这才是违约**，未标脏的
///     写入，跨帧缓存会复用陈旧值。
const SelfScopeAuditEntry = struct {
    node: *Node,
    paint_hash: u64,
    content_version: u32,
};

/// 稽核样本上限。超出则跳过稽核（宁可不查，也不为诊断设施分配/失败）。
const self_scope_audit_max: usize = 4096;

/// 指纹覆盖面 = "烘焙进 DisplayItem 且**没有**每帧重算兜底"的那些值。
///
/// 收进来：background rgba、opacity、border（宽/色/半径），它们都是被直接
/// 写进 fill_rect/stroke_rect 的常量（display_list.zig:66-90 的 color/radius/
/// shape 字段），缓存复用时原样replay，错了就一直错到下次真脏。
///
/// **故意不收 transform/translate**：缓存 item 存的是 local 坐标 + transform_id，
/// lower 时读当帧 property_tree 矩阵（每帧 clear 重建），平移天然自愈。
/// 已实测：谎报的 hook 逐帧改后代 translate（7->56），drawn_x 每帧都跟得上、
/// 零陈旧。把它收进指纹只会制造误报，不会提高安全性。
fn paintHashOf(node: *Node) u64 {
    var h: u64 = 1469598103934665603;
    const bg = node.getBackground();
    inline for (.{ bg.r, bg.g, bg.b, bg.a }) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    h = (h ^ @as(u64, @bitCast(@as(f64, node.getOpacity())))) *% 1099511628211;
    // border 三项同样烘焙进 item 且无兜底（交叉审查指出的覆盖面缺口）
    const b = node.style.border;
    h = (h ^ @as(u64, @bitCast(@as(f64, b.width)))) *% 1099511628211;
    h = (h ^ @as(u64, @bitCast(@as(f64, b.radius)))) *% 1099511628211;
    inline for (.{ b.color.r, b.color.g, b.color.b, b.color.a }) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    return h;
}

var self_scope_audit_every_frame_cache: ?bool = null;
/// ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME=1：恢复逐帧稽核（默认每 64 帧采样一次）。
fn selfScopeAuditEveryFrameEnabled() bool {
    return self_scope_audit_every_frame_cache orelse blk: {
        const v = std.posix.getenv("ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME") != null;
        self_scope_audit_every_frame_cache = v;
        break :blk v;
    };
}

fn collectSelfScopeAudit(
    node: *Node,
    exclude: *Node,
    buf: []SelfScopeAuditEntry,
    count: *usize,
) void {
    if (node != exclude) {
        if (count.* >= buf.len) return; // 容量不足：调用方据此放弃本次稽核
        buf[count.*] = .{
            .node = node,
            .paint_hash = paintHashOf(node),
            .content_version = node.meta.per_frame.caches.versions.content,
        };
        count.* += 1;
    }
    for (node.children.items) |child| {
        collectSelfScopeAudit(child, exclude, buf, count);
    }
}

/// 从 node 向上找到渲染根（没有 parent 的那个）。
fn renderRootOf(node: *Node) *Node {
    var cur = node;
    while (cur.parent) |p| cur = p;
    return cur;
}

pub fn runBeforeRenderHook(node: *Node, hook: *const fn (*Node) void) bool {
    const was_dirty = node.frame_state.state_bits.dirty.core.render;
    node.frame_state.state_bits.dirty.core.render = false;

    // 只在安全构建里稽核，且只对真正声明了 self-only 的节点付这份遍历成本。
    //
    // ⚠️ 降频采样（2026-09-18）：这份稽核对**每个** self-only hook 都从渲染根
    // 遍历整棵树并对每个节点算 paint hash，跑 hook 前后各一遍。实测一屏
    // 代码块文档里每帧 38 次稽核、**遍历 143,564 个节点**，而 tick 本身只需
    // 走 583 个，放大 246 倍，br_tick 2.6ms -> 19.2ms，Debug 下滚动直接掉帧。
    //
    // 与同文件 assertLayoutSyncIntegrity 的处理一致：它也是纯诊断走树，
    // 早已降频为每 64 帧一次并在注释里写明理由（"每帧跑把 Debug 帧税抬高
    // ~5ms，而这类回归是持续性的，采样 64 帧内必然命中"）。
    // 担保被违反同样是持续性的（每帧都会重复那次未标脏写入），采样必然命中。
    // ZENIT_SELF_SCOPE_AUDIT_EVERY_FRAME=1 恢复逐帧稽核（排查具体违约时用）。
    const audit_sampled = selfScopeAuditEveryFrameEnabled() or (g_debug_frame % 64 == 1);
    const audit = (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) and
        node.frame_state.state_bits.flags.before_render_hook_affects_self_only and
        audit_sampled;
    var audit_buf: [self_scope_audit_max]SelfScopeAuditEntry = undefined;
    var audit_count: usize = 0;
    var audit_overflow = false;
    if (audit) {
        collectSelfScopeAudit(renderRootOf(node), node, &audit_buf, &audit_count);
        // 采样到上限说明树比缓冲大，样本不完整 -> 放弃本次稽核而不是误判。
        audit_overflow = audit_count >= self_scope_audit_max;
    }

    hook(node);

    if (audit and !audit_overflow) {
        for (audit_buf[0..audit_count]) |entry| {
            // 只看 hook 之前就存在的节点。节点若已被 freeNode 排队，帧内指针
            // 仍可解引用（延迟销毁），读到的值也仍是它自己的，不影响判定。
            const now_hash = paintHashOf(entry.node);
            if (now_hash == entry.paint_hash) continue;
            // 值变了但 content_version 也变了 = 走了标脏入口 = 缓存会失效 = 合法。
            if (entry.node.meta.per_frame.caches.versions.content != entry.content_version) continue;
            std.debug.panic(
                "before_render_hook_affects_self_only 担保被违反：hook 所在 node_id={d} " ++
                    "component={s} test_id={s}；它改了 node_id={d} 的绘制态（背景/不透明度）" ++
                    "**且没有标脏**（content_version 未变）。未标脏的写入会让跨帧 payload 缓存" ++
                    "复用陈旧颜色（transform 有 property_tree 每帧重算兜底，颜色没有）。\n" ++
                    "修法二选一：(a) 摘掉该节点的 before_render_hook_affects_self_only；" ++
                    "(b) 改走 setBackground/setOpacity 等会标脏的入口，不要用 setBackgroundRaw/setOpacityRaw。",
                .{
                    node.id,
                    node.meta.ownership.meta.component_name orelse "(nil)",
                    node.meta.ownership.meta.test_id orelse "(nil)",
                    entry.node.id,
                },
            );
        }
    }
    if (node.frame_state.state_bits.dirty.core.render) {
        // DEBUG: hook 自身调了 markRenderDirty
        g_debug_dirty_hooks += 1;
        if (dirtyHookDebugEnabled() and g_debug_frame % 300 == 1 and g_debug_dirty_hooks <= 8) {
            std.debug.print("[hook-dirty] frame={d} hook_set_dirty node_id={d} component={s} test_id={s}\n", .{
                g_debug_frame,
                node.id,
                node.meta.ownership.meta.component_name orelse "(nil)",
                node.meta.ownership.meta.test_id orelse "(nil)",
            });
        }
        return true;
    }
    if (was_dirty) {
        node.frame_state.state_bits.dirty.core.render = true;
        // DEBUG: was_dirty 恢复
        g_debug_dirty_hooks += 1;
        if (dirtyHookDebugEnabled() and g_debug_frame % 300 == 1 and g_debug_dirty_hooks <= 8) {
            std.debug.print("[hook-dirty] frame={d} was_dirty_restored node_id={d} component={s} test_id={s}\n", .{
                g_debug_frame,
                node.id,
                node.meta.ownership.meta.component_name orelse "(nil)",
                node.meta.ownership.meta.test_id orelse "(nil)",
            });
        }
    }
    return false;
}

/// 返回 true 表示有 on_before_render 钩子请求了重绘（活跃动画）
/// now_ms: 由调用方（mod.zig）传入 current_frame_time_ms
pub var g_tick_node_count: u32 = 0;
pub var g_tick_hook_count: u32 = 0;
pub var g_slow_hook_us: u64 = 0;
pub var g_slow_hook_name: [64]u8 = [_]u8{0} ** 64;
pub var g_slow_hook_name_len: u8 = 0;
/// devtools performance 面板打开时置 true；关闭时每个 hook 免掉两次时钟读取。
pub var g_profile_hooks: bool = false;

var hook_trace_cache: ?bool = null;
/// ZENIT_HOOK_TRACE=1：强制开启逐 hook 计时,并把 >5ms 的 hook 逐条打日志。
/// 用途：帧级 SLOW 日志显示 before_render 巨大但 slow_hook 归因为空时
/// （g_profile_hooks 默认关,只有 devtools perf 面板开）,用它抓真凶。
fn hookTraceEnabled() bool {
    return hook_trace_cache orelse blk: {
        const v = std.posix.getenv("ZENIT_HOOK_TRACE") != null;
        hook_trace_cache = v;
        break :blk v;
    };
}

fn runHookTimed(node: *Node, hook: *const fn (*Node) void) bool {
    const trace = hookTraceEnabled();
    if (!g_profile_hooks and !trace) return runBeforeRenderHook(node, hook);
    var ht = std.time.Timer.start() catch undefined;
    const requested = runBeforeRenderHook(node, hook);
    const elapsed = ht.read() / 1000;
    if (elapsed > g_slow_hook_us) {
        g_slow_hook_us = elapsed;
        const name = node.meta.ownership.meta.component_name orelse node.meta.ownership.meta.test_id orelse "(unnamed)";
        const n = @min(name.len, g_slow_hook_name.len);
        @memcpy(g_slow_hook_name[0..n], name[0..n]);
        g_slow_hook_name_len = @intCast(n);
    }
    if (trace and elapsed > 1000) {
        std.debug.print("[hook-trace] {d}us node_id={d} component={s} test_id={s}\n", .{
            elapsed,
            node.id,
            node.meta.ownership.meta.component_name orelse "(nil)",
            node.meta.ownership.meta.test_id orelse "(nil)",
        });
    }
    return requested;
}

// A callback may retire an ancestor while this subtree is still on the
// traversal stack. Its allocations survive until Cx drains, but callbacks
// must stop: their Scope-owned state may already have been disposed.
fn isRetiring(node: *Node) bool {
    var current: ?*Node = node;
    while (current) |ancestor| : (current = ancestor.parent) {
        if (ancestor.pending_free_cx != null or ancestor.freeing) return true;
    }
    return false;
}

pub fn tickBeforeRender(node: *Node, offset_x: f32, offset_y: f32, clip_opt: ?ComputedRect, allocator: Allocator, dt_ms: f32, now_ms: f64) bool {
    if (isRetiring(node)) return false;
    var redraw_requested = false;
    g_tick_node_count += 1;

    // 子树 hook 标志自愈折叠：组件层大量 `before_render.main =` 直赋值不经过
    // addBeforeRender（40+ 处），靠这里在 hook 真执行时置位 + 沿祖先冒泡，
    // 消化"绕过 setter 的写路径"（下一帧 render 的 hasBeforeRenderHookSubtree
    // 一定看得到）。tick 在 render 之前全树执行，标志只增不减 -> 语义是旧递归
    // 实现的保守超集。旧实现对"已卸载 hook"会少算 true，本实现保持 true,
    // 消费方（缓存资格判定）只会因此更保守，方向安全。
    if (node.hasBeforeRenderHooks()) node.markSubtreeBeforeRenderHook();

    // 从全局 World hook 读 rect。
    const local_rect = node.rectFromWorldOrFallback();

    if (node.consumeCompositeAnimationLingerFrame()) {
        redraw_requested = true;
    }

    // -1. 更新 out_of_viewport 标记，供 on_before_render hook 使用（如 Skeleton shimmer、Spinner）
    if (clip_opt) |clip| {
        const nx = local_rect.x + node.style.translate_x + node.frame_state.frame_local.runtime.sticky.x + offset_x;
        const ny = local_rect.y + node.style.translate_y + node.frame_state.frame_local.runtime.sticky.y + offset_y;
        const margin: f32 = 48;
        node.frame_state.state_bits.flags.out_of_viewport = (local_rect.w > 0 and local_rect.h > 0) and
            (nx + local_rect.w < clip.x - margin or nx > clip.x + clip.w + margin or
                ny + local_rect.h < clip.y - margin or ny > clip.y + clip.h + margin);
    } else {
        node.frame_state.state_bits.flags.out_of_viewport = true;
    }

    // 0. 声明式 Transition tick（绝对时间戳驱动）
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) {
            if (tickTransitions(node, slots, allocator, now_ms)) {
                redraw_requested = true;
            }
            if (isRetiring(node)) return true;
        }
    }

    // 0.5 命令式节点动画 tick（绝对时间戳驱动）
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (anims.count > 0) {
            if (anims.tick(node, allocator, now_ms)) {
                redraw_requested = true;
            }
            if (isRetiring(node)) return true;
        }
        if (anims.count == 0) {
            anims.deinit();
            allocator.destroy(anims);
            node.frame_state.frame_local.runtime.commands = null;
        }
    }

    // 1. 有钩子的节点无条件执行（确保 ScrollArea 弹簧回弹、动画 tick 等继续运行）
    if (node.meta.per_frame.hooks.before_render.main) |hook| {
        g_tick_hook_count += 1;
        if (runHookTimed(node, hook)) redraw_requested = true;
        if (isRetiring(node)) return true;
    }
    for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |hook_opt| {
        if (hook_opt) |hook| {
            g_tick_hook_count += 1;
            if (runHookTimed(node, hook)) redraw_requested = true;
            if (isRetiring(node)) return true;
        }
    }

    if (node.style.overflow_hidden and
        (local_rect.w <= 0.1 or local_rect.h <= 0.1) and
        !subtreeHasActiveAnimation(node))
    {
        clearHiddenSubtreeSceneDirty(node);
        return redraw_requested;
    }

    // 1.5 overflow_hidden 收紧 clip 区域
    const tbr_tx = node.style.translate_x;
    const tbr_ty = node.style.translate_y;
    var effective_clip = clip_opt;
    if (node.style.overflow_hidden) {
        const node_clip = ComputedRect.init(
            local_rect.x + tbr_tx + node.frame_state.frame_local.runtime.sticky.x + offset_x,
            local_rect.y + tbr_ty + node.frame_state.frame_local.runtime.sticky.y + offset_y,
            local_rect.w,
            local_rect.h,
        );
        effective_clip = if (effective_clip) |clip|
            geometry.intersectRect(clip, node_clip)
        else
            node_clip;
    }

    // 1.6 sticky offset 计算（需要在 effective_clip 确定后、child_offset 之前）
    // 吸附区域用祖先的 clip_opt（不含自身的 overflow_hidden）；为 null（交集为空）时也要调用，
    // 由 computeStickyOffset 清零偏移与状态并标脏，不能保留陈旧值。
    if (node.style.position == .sticky) {
        geometry.computeStickyOffset(node, offset_x, offset_y, clip_opt);
    }

    // 2. 计算子节点的累积偏移（rect + translate + sticky_offset 传递）
    // 相对坐标系：child_offset 包含父节点的 rect 位置
    const child_offset_x = offset_x + local_rect.x + tbr_tx + node.frame_state.frame_local.runtime.sticky.x;
    const child_offset_y = offset_y + local_rect.y + tbr_ty + node.frame_state.frame_local.runtime.sticky.y;

    // 3. 递归子节点，带视口裁剪
    //
    // ⚠️ 迭代期 mutation 安全（2026-07-29 修，原为 segfault / UAF）：
    // 上面第 1 步跑的 before_render hook、以及第 0.5 步动画 tick 的**完成
    // 回调**，都可以在本帧内销毁节点，典型路径是
    // `animateOpacity(..., done)` 的 done 回调里 dispose 组件 scope，
    // scope cleanup 走 detachChild + freeNode（见 snapshot_layer.zig:136-144）。
    // detachChild -> removeChildIncremental 会**就地修改 node.children**，
    // 于是原来的 `for (node.children.items)` 会：
    //   - 迭代到已被 free 的 *Node（读到 0xaaaa… 毒值 -> segfault），或
    //   - 因数组左移而漏掉/重复访问兄弟节点。
    // 用**下标 + 每轮重读 items** 的方式迭代，并在每轮校验当前槽位仍是
    // 我们预期的那个子节点；若本轮发生了删除（长度变短或槽位换人），
    // 就地重新对齐而不前进，保证既不越界也不漏项。
    var child_idx: usize = 0;
    while (child_idx < node.children.items.len) {
        const child = node.children.items[child_idx];
        defer {
            // Deleting a later sibling shrinks the array without moving this
            // child. Advance by identity, not by comparing list lengths.
            if (child_idx < node.children.items.len and node.children.items[child_idx] == child) child_idx += 1;
        }
        // 全局 hook 读 rect。
        const child_rect = child.rectFromWorldOrFallback();
        if (child.style.overflow_hidden and
            (child_rect.w <= 0.1 or child_rect.h <= 0.1) and
            !child.hasBeforeRenderHooks() and
            !subtreeHasActiveAnimation(child))
        {
            clearHiddenSubtreeDirty(child);
            continue;
        }

        // opacity == 0 且无钩子且自身无活跃 transition/animation -> 完全不可见，跳过子树渲染递归。
        // 但仍要补 tick 子树深处的活跃 transition/animation：否则 hidden subtree 里的 active slot
        // 永远不会被推进到 complete，slots.any_active 永驻 true，让 hasPendingSceneWork() 每帧
        // 返回 true，整个 app 卡在 60fps 持续 redraw（quick-open 等隐藏面板的 Input border_color
        // transition 是典型案例）。
        if (child.isPaintSkipped() and !child.hasBeforeRenderHooks() and
            (child.frame_state.frame_local.runtime.transitions == null or !child.frame_state.frame_local.runtime.transitions.?.any_active) and
            (child.frame_state.frame_local.runtime.commands == null or child.frame_state.frame_local.runtime.commands.?.count == 0))
        {
            if (subtreeHasActiveAnimation(child)) {
                tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
                if (isRetiring(node)) return true;
            }
            continue;
        }

        const child_tx = child.style.translate_x;
        const child_ty = child.style.translate_y;
        const child_x = child_rect.x + child_tx + child.frame_state.frame_local.runtime.sticky.x + child_offset_x;
        const child_y = child_rect.y + child_ty + child.frame_state.frame_local.runtime.sticky.y + child_offset_y;
        const child_w = child_rect.w;
        const child_h = child_rect.h;

        // 如果子节点有尺寸、没有钩子、非 sticky、无 translate 偏移、且完全在视口外 -> 跳过整棵子树
        // sticky 节点不能被跳过：其 sticky_offset 需要每帧重新计算
        // translate 节点不能被跳过：translate 用于滚动，AABB 不反映实际可见区域
        const child_has_translate = child_tx != 0 or child_ty != 0;
        if (child_w > 0 and child_h > 0 and !child.hasBeforeRenderHooks() and child.style.position != .sticky and !child_has_translate) {
            const margin: f32 = 48;
            var out_of_clip = false;
            if (effective_clip) |clip| {
                const clip_x2 = clip.x + clip.w;
                const clip_y2 = clip.y + clip.h;
                if (child_x + child_w < clip.x - margin or child_x > clip_x2 + margin or
                    child_y + child_h < clip.y - margin or child_y > clip_y2 + margin)
                {
                    out_of_clip = true;
                }
            } else {
                out_of_clip = true;
            }
            if (out_of_clip) {
                // 视口外：仍需推进整个子树内所有活跃 transition，防止 any_active 永久不清零
                tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
                if (isRetiring(node)) return true;
                continue; // 跳过子树渲染递归
            }
        }

        if (tickBeforeRender(child, child_offset_x, child_offset_y, effective_clip, allocator, dt_ms, now_ms)) {
            redraw_requested = true;
        }
        if (isRetiring(node)) return true;
    }
    return redraw_requested;
}

fn clearHiddenSubtreeDirty(node: *Node) void {
    node.frame_state.state_bits.dirty.core.layout = false;
    node.frame_state.state_bits.dirty.core.subtree_layout = false;
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    tick_node_dirty.bumpLooseInteractionGen();

    for (node.children.items) |child| {
        clearHiddenSubtreeDirty(child);
    }
}

fn clearHiddenSubtreeSceneDirty(node: *Node) void {
    node.frame_state.state_bits.dirty.core.render = false;
    node.frame_state.state_bits.dirty.core.subtree_render = false;
    node.frame_state.state_bits.dirty.pipeline.composite = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_composite = false;
    node.frame_state.state_bits.dirty.pipeline.interaction = false;
    node.frame_state.state_bits.dirty.pipeline.subtree_interaction = false;
    tick_node_dirty.bumpLooseInteractionGen();

    for (node.children.items) |child| {
        clearHiddenSubtreeSceneDirty(child);
    }
}

/// 递归推进视口外子树中的活跃动画，防止它们停在 active 状态导致 idle-skip 失效。
fn tickOffscreenAnimationsInSubtree(node: *Node, allocator: Allocator, now_ms: f64) void {
    if (isRetiring(node)) return;
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) {
            _ = tickTransitions(node, slots, allocator, now_ms);
            if (isRetiring(node)) return;
        }
    }
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (nodeAnimationsActive(anims)) {
            _ = anims.tick(node, allocator, now_ms);
            if (isRetiring(node)) return;
        }
        if (anims.count == 0) {
            anims.deinit();
            allocator.destroy(anims);
            node.frame_state.frame_local.runtime.commands = null;
        }
    }
    var child_idx: usize = 0;
    while (child_idx < node.children.items.len) {
        const child = node.children.items[child_idx];
        defer {
            if (child_idx < node.children.items.len and node.children.items[child_idx] == child) child_idx += 1;
        }
        if (!subtreeHasActiveAnimation(child)) continue;
        tickOffscreenAnimationsInSubtree(child, allocator, now_ms);
        if (isRetiring(node)) return;
    }
}

fn nodeAnimationsActive(anims: *const @import("../../animation/node_animator.zig").NodeAnimations) bool {
    for (anims.entries[0..anims.count]) |entry| {
        if (entry.controller.isActive()) return true;
    }
    return false;
}

/// 快速检查子树是否有活跃动画（避免无效递归）。
fn subtreeHasActiveAnimation(node: *Node) bool {
    if (node.frame_state.frame_local.runtime.transitions) |slots| {
        if (slots.any_active) return true;
    }
    if (node.frame_state.frame_local.runtime.commands) |anims| {
        if (nodeAnimationsActive(anims)) return true;
    }
    for (node.children.items) |child| {
        if (subtreeHasActiveAnimation(child)) return true;
    }
    return false;
}
