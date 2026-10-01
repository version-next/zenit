//! Cx 帧管线：render()（before-render tick -> layout -> after-layout hooks ->
//! 运行时索引 -> layerize -> display list）、编码器 paint table 降级、
//! redraw 调度，以及命中测试前的场景保鲜（ensureHitTestSceneFresh）。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_frame = @import("cx_frame.zig");
const cx_bulk_quads = @import("cx_bulk_quads.zig");
const PartialInteractionRoots = cx_runtime_index.PartialInteractionRoots;
const AfterLayoutOutcome = struct { ran_layout: bool = false, interaction_dirty: bool = false };
const text_core_module = @import("text_core");
const AfterLayoutFn = core.AfterLayoutFn;
const ComputedRect = core.ComputedRect;
const LayoutContext = layout_engine.LayoutContext;
const LayoutTable = core.LayoutTable;
const Node = core.Node;
const cx_cursor = @import("cx_cursor.zig");
const cx_node_lifetime = @import("cx_node_lifetime.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const display_list = core.display_list;
const display_list_mod = @import("display_list.zig");
const hitSceneDebugEnabled = debug_env.hitSceneDebugEnabled;
const layoutIntegrityEveryFrameEnabled = debug_env.layoutIntegrityEveryFrameEnabled;
const layout_engine = core.layout_engine;
const max_after_layout_rounds = core.max_after_layout_rounds;
const paint_table = core.paint_table;
const renderDirtyDebugEnabled = debug_env.renderDirtyDebugEnabled;
const render_engine = core.render_engine;
const text = core.text;

pub fn render(self: *Cx) []const display_list_mod.DisplayItem {
    // 计时器回调先跑：它们标脏的节点要赶上本帧（不能被零脏帧路径跳过）。
    self.fireDueTimers();
    // overlay 退场完成后把焦点还给触发它的控件。
    // ⚠ 必须在**零脏帧 fast-path 之前**：关闭 overlay 后常常正好是零脏帧，
    // 放在后面会被 early-return 跳过，焦点永远恢复不了。
    cx_node_lifetime.drainOverlayFocusRestore(self);

    // 零脏帧快速路径，根 fully-clean 且上一帧 cache 有效时直接返回缓存。
    // 矩阵 #1：10k 节点零脏帧 < 0.5ms 的关键 skip。
    // 安全条件：根节点 layout/render/composite/subtree_* 全 clean + overlay_stack 无动画
    // + inspector 关闭。markDirty 路径会冒泡到根，所以 root 全 clean 蕴含整树 clean。
    if (self.root) |r| {
        const time_unchanged = self.frame_time_ms == self.last_render_frame_time_ms;
        if (self.last_render_valid and
            time_unchanged and
            // 批量矩形层每帧由宿主重新提交，zenit 不做跨帧 diff，
            // 无从判断内容是否变化 ⇒ 默认保守重画（见 setBulkQuads）。
            // 但宿主可以用 setBulkQuadsVersioned 自证"这批和上一帧一样"，
            // 那样静止画面就能回到零脏帧，两万 quad 的画布上这条决定了
            // 每帧是 21.6ms 还是 ~0。
            (self.bulk_quads.items.len == 0 or self.bulk_quads_unchanged) and
            isTreeFullyClean(r) and
            !self.overlay_stack.hasActiveAnimations() and
            // 自动化虚拟指针是**画在真实呈现目标里**的（截图/录屏要看得见），
            // 但它不进 Node 树 ⇒ 移动指针时整棵树仍然 fully-clean。少了这
            // 一条，纯 mouse_move（不改任何节点）会走零脏帧 early-return，
            // overlay 那段代码根本执行不到，表现为"harness 里虚拟鼠标
            // 永远画不出来"。可见即参与判据；不可见时该路径零成本。
            !self.virtual_cursor.visible and
            !self.inspector.enabled and
            !self.inspector.debug_paint.anyActive())
        {
            self.perf.resetFrame();
            return self.display_list.items.items;
        }
    }
    // 重置帧 arena，释放上一帧的所有临时分配
    _ = self.frame_arena.reset(.retain_capacity);
    self.perf.resetFrame();
    // gesture_arena tick, long_press 等时间相关识别器靠这个推进。
    // 必须在 render pass 前调；否则 long_press began 在本帧 emit 后才 dispatch
    // 渲染（多 1 帧延迟，用户感觉滞后）。
    self.gesture_arena.tick(std.time.nanoTimestamp());
    // 推进 ShapingCache epoch；上一帧未触达的 entry 在配置阈值
    // 帧后被驱逐。GlyphRun pipeline 接管旧 measure 路径后是 text 测量
    // 唯一缓存层。
    self.text.beginFrame();
    self.lowering.main_paint.clearRetainingCapacity();
    if (self.root) |r| {
        // OverlayStack: 统一 outside-click 处理（在 has_new_mouse_down 被清除前）
        // mouseDown 与 render 之间，虚拟列表/条件渲染可能已释放命中节点。
        // 裸指针只保留作同步事件期兼容；跨帧消费必须重新解析带代次的
        // handle，避免 OverlayStack.isDescendantOf 沿悬空 parent 链读取。
        const outside_click_target = self.node_registry.resolve(self.last_mouse_down_handle, &self.perf);
        self.last_mouse_down_target = outside_click_target;
        if (outside_click_target == null) self.last_mouse_down_handle = null;
        self.overlay_stack.handleOutsideClickOwned(self.has_new_mouse_down, outside_click_target, self.press_overlay_owner);

        const tick_mod = @import("render_engine/tick.zig");
        tick_mod.g_tick_node_count = 0;
        tick_mod.g_tick_hook_count = 0;
        tick_mod.g_slow_hook_us = 0;
        tick_mod.g_slow_hook_name_len = 0;
        tick_mod.g_debug_frame = self.frame_count;
        tick_mod.g_debug_dirty_hooks = 0;
        var bt = std.time.Timer.start() catch undefined;
        ensureBeforeRenderTicked(self);
        self.perf.before_render_us = bt.read() / 1000;
        self.perf.tick_nodes = tick_mod.g_tick_node_count;
        self.perf.tick_hooks = tick_mod.g_tick_hook_count;
        self.perf.slow_hook_us = tick_mod.g_slow_hook_us;
        const sn_len = tick_mod.g_slow_hook_name_len;
        const sn_max = @min(sn_len, self.perf.slow_hook_name.len);
        @memcpy(self.perf.slow_hook_name[0..sn_max], tick_mod.g_slow_hook_name[0..sn_max]);
        self.perf.slow_hook_name_len = sn_max;
        // DEBUG: 每 300 帧打印 render_dirty 节点
        if (renderDirtyDebugEnabled() and self.frame_count % 300 == 1) {
            cx_frame.debugPrintRenderDirtyNodes(self, r);
        }
        // on_before_render 已消费 has_new_mouse_down，清除
        self.has_new_mouse_down = false;

        // OverlayStack: 先更新锚点几何，再在布局完成后推进动画时间。
        self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);

        // Pass 1.5: 增量布局
        var inner_timer = std.time.Timer.start() catch undefined;
        if (r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.inner_layout_us = inner_timer.lap() / 1000;

        const animations_active = self.overlay_stack.tickAnimations(self.frame_time_ms, self.frame_dt_seconds, self.allocator);
        if (animations_active) {
            self.needs_redraw = true;
        }

        // Pass 2: 渲染命令生成
        var render_ctx = render_engine.RenderContext{
            .lowering_buffer = &self.lowering._dead_main,
            .lowering_buffer_paint = &self.lowering.main_paint,
            .display_list = &self.display_list,
            .text_blob_store = &self.text_blob_store,
            .scene_runtime = &self.scene_runtime,
            .property_tree = &self.property_tree,
            .layer_tree = &self.layer_tree,
            .world = &self.world,
            .allocator = self.allocator,
            .frame_allocator = self.frame_arena.allocator(),
            .viewport = self.viewport,
            .perf = &self.perf,
            .external_clip_rects = &self.external_clip_rects,
            // 把 GlyphRun pipeline 资源传到 render engine
            .shaping_cache = &self.text.shaping_cache,
            .font_system = self.text.font_system,
            .visual_line_context = self,
            .visual_line_fn = &renderVisualLine,
        };
        const render_node_start = inner_timer.read();
        render_engine.renderNode(&render_ctx, r) catch |err| {
            std.debug.print("[ui] renderNode error: {}\n", .{err});
        };
        self.perf.render_node_us = (inner_timer.read() - render_node_start) / 1000;

        // 批量矩形层：绝对视口坐标 ⇒ 用 identity transform（id 0）。
        // 层级/裁剪取决于宿主指定的 anchor（见 setBulkQuads）：挂靠时
        // 插入到 anchor 子树区间末尾并带上它的 clip_id。
        cx_bulk_quads.appendBulkQuads(self) catch |err| {
            std.debug.print("[ui] bulk quad append error: {}\n", .{err});
        };

        // Stage B R3f: derive + inspector overlay 仍在 cx.render() 末尾跑 (兼容
        // 测试期望 cx.lowering.main 在 cx.render() 后立即可读)。lowerForEncoder
        // 提供给 encoder 调，**幂等**，已填好就直接 return，不重复 derive。
        self.lowering._dead_main.clearRetainingCapacity();
        self.lowering.main_paint.clearRetainingCapacity();
        const lowering_mod = @import("render_engine/display_list_lowering.zig");
        // 正确性路径：main_paint 刚被 clearRetainingCapacity，这里是把整帧的
        // display item 重新 lower 进去。中途 OOM 会留下**截断的** paint 列表
        // （begin/end 层不配对、后半棵树整个不画），而 render() 返回的就是它
        // 画面静默错乱而非干净失败。
        if (std.posix.getenv("ZENIT_DEBUG_DLIST") != null) {
            std.debug.print("[dlist] ── frame {d} items={d} ──\n", .{ self.scene_runtime.frame_epoch, self.display_list.items.items.len });
            for (self.display_list.items.items, 0..) |it, di| {
                const h = it.header();
                switch (it) {
                    .text_run => |t| std.debug.print("[dlist] {d}: text node={d} eff={d} clip={d} \"{s}\"\n", .{ di, h.node_id, h.effect_id, h.clip_id, t.content[0..@min(t.content.len, 12)] }),
                    .fill_rect => |fr| std.debug.print("[dlist] {d}: rect node={d} eff={d} clip={d} ({d:.0},{d:.0},{d:.0}x{d:.0}) r={d:.3} a={d}\n", .{ di, h.node_id, h.effect_id, h.clip_id, fr.x, fr.y, fr.w, fr.h, fr.radius[0], fr.color.a }),
                    // 描边宽度/圆角是"内容属性等比缩放"回归验证的观测点
                    // （下游应用：描边与圆角必须 == 世界值 × scale）。
                    .stroke_rect => |sr| std.debug.print("[dlist] {d}: stroke node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, sr.x, sr.y, sr.w, sr.h, sr.width, sr.radius[0] }),
                    .border_side => |bs| std.debug.print("[dlist] {d}: border node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, bs.x, bs.y, bs.w, bs.h, bs.width, bs.radius[0] }),
                    else => std.debug.print("[dlist] {d}: {s} node={d} eff={d} clip={d}\n", .{ di, @tagName(it), h.node_id, h.effect_id, h.clip_id }),
                }
            }
        }
        // Timed as `phase_prebuild_us`: lowering walks the whole display
        // list every frame and was the largest untimed region inside
        // render(), so a slow frame here looked like unattributed
        // `render_us`.
        const lower_start = inner_timer.read();
        lowering_mod.appendAllDisplayItemsToRenderList(&render_ctx) catch @panic("OOM: lower display list into main render list");
        self.perf.phase_prebuild_us = (inner_timer.read() - lower_start) / 1000;
        if (std.posix.getenv("ZENIT_DEBUG_SURFDUMP") != null) {
            var in_surf: bool = false;
            var counts: [64]u32 = @splat(0);
            for (self.lowering.main_paint.items) |it| {
                const k = @intFromEnum(it.kind);
                if (it.kind == .control and it.control_kind == .begin_opacity_layer) {
                    in_surf = true;
                    std.debug.print("[surfdump] f={d} BEGIN op={d:.2}\n", .{ self.scene_runtime.frame_epoch, it.opacity });
                } else if (in_surf and it.kind == .control and it.control_kind == .end_opacity_layer) {
                    in_surf = false;
                    std.debug.print("[surfdump] f={d} END counts:", .{self.scene_runtime.frame_epoch});
                    for (counts, 0..) |c, ki| {
                        if (c > 0) std.debug.print(" {s}={d}", .{ @tagName(@as(@TypeOf(it.kind), @enumFromInt(ki))), c });
                    }
                    std.debug.print("\n", .{});
                    counts = @splat(0);
                } else if (in_surf) {
                    if (k < counts.len) counts[k] += 1;
                    std.debug.print("[surfitem] {s} x={d:.1} y={d:.1} w={d:.1} h={d:.1} a={d:.2}\n", .{
                        @tagName(it.kind),                           it.geom.x, it.geom.y, it.geom.w, it.geom.h,
                        @as(f32, @floatFromInt(it.color.a)) / 255.0,
                    });
                }
            }
        }
        // v0.5-P3 Stage 4-1+: render 末尾再做一次 layout sync，捕获 before_render 钩子
        // 内（如 ScrollArea scrollbar）直接改写 node.rect 的散装路径。这是补丁式修复,
        // 真正解法是给 scrollbar/modal 等改 rect 的位置直接调 cx.syncNodeRect(node)。
        // Timed together as `phase_sync_us`: these four shadow-sync passes
        // each walk the node tree at the end of every frame. They were
        // untimed, so their cost showed up only as the gap between
        // render_node_us and render_us.
        const sync_start = inner_timer.read();
        self.syncLayoutToTable(r);
        // shadow-sync paint props 到 PaintTable
        self.syncPaintToTable(r);
        // shadow-sync interaction 到 InteractionTable
        self.syncInteractionToTable(r);
        // 把 Node 树 a11y 元数据投影到 AccessibilityTree。下一步
        // (§2.1 ObjC bridge) cx.render() 末尾 a11y_router.flushToBridge 把
        // dirty 队列推到 macOS NSAccessibility。
        self.syncA11yTreeFromInteractions(r);
        self.perf.phase_sync_us = (inner_timer.read() - sync_start) / 1000;
        // 整树 invariant 在 debug build 校验。
        // 降频为每 64 帧一次采样：这是纯诊断走树（自身注释即承认是 debug
        // 膨胀源），每帧跑把 Debug 帧税抬高 ~5ms 而 shadow-sync 类回归
        // 是持续性的，采样 64 帧内必然命中。ZENIT_LAYOUT_INTEGRITY=1
        // 恢复逐帧校验（排查 sync 时序类问题时用）。
        const integrity_start = inner_timer.read();
        if (std.debug.runtime_safety) {
            const every_frame = layoutIntegrityEveryFrameEnabled();
            if (every_frame or self.frame_count % 64 == 1) {
                if (!self.assertLayoutSyncIntegrity(r)) {
                    std.debug.panic("LayoutTable shadow-sync integrity check failed\n", .{});
                }
            }
        }
        // `phase_retained_us` reports the debug-only integrity walk. It is
        // a full-tree traversal that exists only under runtime_safety, so
        // it inflates render() in debug builds and vanishes in release,
        // worth seeing separately rather than blaming the paint pass.
        self.perf.phase_retained_us = (inner_timer.read() - integrity_start) / 1000;
    }
    self.inspector.renderOverlay(self);
    // 最后一层：自动化 cursor 必须进入真实呈现目标，截图/录屏才看得见。
    // 它在 inspector 后绘制，且完全不进入 Node / hit-test 树。
    if (self.virtual_cursor.renderOverlay(self, self.frame_time_ms)) {
        self.needs_redraw = true;
    }

    // 零脏 skip 路径直接返回 self.display_list.items.items。
    // display_list 是真源、跨帧稳定（仅在 paint pass 入口被 clear），无需快照。
    self.last_render_valid = true;
    self.last_render_frame_time_ms = self.frame_time_ms;
    return self.display_list.items.items;
}

pub fn lowerForEncoderPaintTable(self: *Cx) []const paint_table.DisplayItem {
    return self.lowering.main_paint.items;
}

/// 检查整棵树是否 fully clean。markDirty 路径冒泡到根，所以
/// root 的 layout/render/composite/subtree_* 全 clean 蕴含整树 clean。
/// 这是 O(1) 检查。
pub fn isTreeFullyClean(root: *Node) bool {
    return !root.frame_state.state_bits.dirty.core.layout and
        !root.frame_state.state_bits.dirty.core.subtree_layout and
        !root.frame_state.state_bits.dirty.core.render and
        !root.frame_state.state_bits.dirty.core.subtree_render and
        !root.frame_state.state_bits.dirty.pipeline.composite and
        !root.frame_state.state_bits.dirty.pipeline.subtree_composite;
}

pub fn scheduleRedrawAfterNs(self: *Cx, delay_ns: u64) void {
    const now = std.time.Instant.now() catch return;
    if (self.next_redraw_scheduled_at) |scheduled_at| {
        if (self.next_redraw_delay_ns) |current_delay| {
            const elapsed = now.since(scheduled_at);
            const remaining = current_delay -| elapsed;
            if (delay_ns >= remaining) return;
        }
    }
    self.next_redraw_scheduled_at = now;
    self.next_redraw_delay_ns = delay_ns;
}

pub fn processScheduledRedraw(self: *Cx) bool {
    const scheduled_at = self.next_redraw_scheduled_at orelse return false;
    const delay_ns = self.next_redraw_delay_ns orelse return false;
    const now = std.time.Instant.now() catch return false;
    if (now.since(scheduled_at) < delay_ns) return false;
    self.next_redraw_scheduled_at = null;
    self.next_redraw_delay_ns = null;
    self.needs_redraw = true;
    return true;
}

/// 事件处理前强制更新 interaction index。
/// 不受 before_render_frame 缓存限制（空闲帧 frame_count 不递增时也能执行）。
pub fn ensureHitTestSceneFresh(self: *Cx) void {
    if (self.tick_depth > 0 or self.draining_deferred_frees) return;
    _ = self.processScheduledRedraw();
    if (!self.hasPendingSceneWork()) return;
    forceTickAndRebuildForHitTest(self);
}

pub fn forceTickAndRebuildForHitTest(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    const r = self.root orelse return;
    const root_handle = self.node_registry.handleFor(r);
    const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
    const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
    const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(r);
    var partial_interaction_roots = PartialInteractionRoots{};
    if ((had_initial_layout_dirty or had_initial_interaction_dirty) and !r.frame_state.state_bits.dirty.runtime.subtree_dirty and !r.frame_state.state_bits.dirty.pipeline.subtree_order) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
    }
    if (had_initial_layout_dirty) {
        layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(r);
    }
    // Hit-test freshness must not consume animation time. This path can run
    // multiple times within one visual frame during mouse down/up/move, and
    // advancing dt here causes popovers/selects/pickers to skip opening
    // frames before the next actual render.
    // 绝对时间戳需要和当前逻辑帧同步，否则"动画已经推进、但还没 render"的 hitTest
    // 会继续使用上一帧时间，导致命中区域滞后于可见位置。
    render_engine.setFrameClock(.{
        .time_ms = self.frame_time_ms,
        .dt_ms = 0,
        .dt_seconds = 0,
    });
    // 同 render 路径：遍历期间 freeNode 延后（见 freeNode 注释）。
    self.tick_depth += 1;
    self.last_tick_animations_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, 0);
    self.tick_depth -= 1;
    // Handles make the collection itself memory-safe. Resetting after a
    // structural mutation also prevents pre-hook ancestry decisions from
    // being merged with the post-hook tree; the fresh collection below is
    // authoritative for the new topology.
    if (self.deferred_free_nodes.len > 0) partial_interaction_roots = .{};
    cx_node_lifetime.drainDeferredFrees(self);
    const current_root = self.root orelse return;
    if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
        cx_runtime_index.fullRebuildRuntimeIndexes(self, current_root) catch @panic("OOM: root changed during hit-test tick");
        return;
    }
    self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);
    const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
    const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(current_root);
    if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty) and !current_root.frame_state.state_bits.dirty.runtime.subtree_dirty and !current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
    }
    if (had_post_tick_layout_dirty) {
        layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(current_root);
    }
    const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty;
    const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty;
    // OOM 不吞：见 rebuildRuntimeIndexesIfCurrentRootDirty 的说明。
    if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=runtime\n", .{});
        cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (hit-test scene refresh)");
    } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=order\n", .{});
        cx_runtime_index.rebuildOrderIndexes(self) catch @panic("OOM: rebuildOrderIndexes (hit-test scene refresh)");
    } else if (has_layout_dirty or has_interaction_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=partial roots={d} overflow={}\n", .{ partial_interaction_roots.len, partial_interaction_roots.overflow });
        cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (hit-test scene refresh)");
    }
}

pub fn addAfterLayoutHook(self: *Cx, ctx: *anyopaque, run: AfterLayoutFn) !void {
    for (self.after_layout_hooks.items) |h| {
        if (h.ctx == ctx) return;
    }
    try self.after_layout_hooks.append(self.allocator, .{ .ctx = ctx, .run = run });
}

pub fn removeAfterLayoutHook(self: *Cx, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < self.after_layout_hooks.items.len) {
        if (self.after_layout_hooks.items[i].ctx == ctx) {
            _ = self.after_layout_hooks.orderedRemove(i);
            if (self.after_layout_cursor) |*next| {
                if (i < next.*) next.* -= 1;
            }
        } else i += 1;
    }
}

/// 回调 -> （脏则）布局，循环到没有回调请求再布局或达到轮数上限。
fn runAfterLayoutHooks(self: *Cx, partial: *PartialInteractionRoots) AfterLayoutOutcome {
    var out = AfterLayoutOutcome{};
    if (self.after_layout_hooks.items.len == 0) return out;
    var round: u8 = 0;
    while (round < max_after_layout_rounds) : (round += 1) {
        const last_round = round + 1 == max_after_layout_rounds;
        var again = false;
        // 与 before_render 同一套门控：回调里的 freeNode 延后到本轮结束。
        self.tick_depth += 1;
        const saved_cursor = self.after_layout_cursor;
        self.after_layout_cursor = 0;
        while (self.after_layout_cursor.? < self.after_layout_hooks.items.len) {
            const h = self.after_layout_hooks.items[self.after_layout_cursor.?];
            self.after_layout_cursor.? += 1;
            if (h.run(h.ctx, round, last_round) == .needs_layout) again = true;
        }
        self.after_layout_cursor = saved_cursor;
        self.tick_depth -= 1;
        if (self.deferred_free_nodes.len > 0) partial.* = .{};
        cx_node_lifetime.drainDeferredFrees(self);
        const root = self.root orelse return out;
        const layout_dirty = root.frame_state.state_bits.dirty.core.layout or root.frame_state.state_bits.dirty.core.subtree_layout;
        const interaction_dirty = root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(root);
        if (interaction_dirty) out.interaction_dirty = true;
        if (layout_dirty) {
            if (!root.frame_state.state_bits.dirty.runtime.subtree_dirty and !root.frame_state.state_bits.dirty.pipeline.subtree_order) {
                cx_runtime_index.collectPartialInteractionRootsWithFallback(self, root, partial);
            }
            layout_engine.layoutNode(root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(root);
            out.ran_layout = true;
        }
        if (!again) break;
    }
    return out;
}

fn ensureBeforeRenderTicked(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    if (self.before_render_frame == self.frame_count and
        std.math.approxEqAbs(f64, self.before_render_time_ms, self.frame_time_ms, 0.0001))
    {
        return;
    }
    if (self.root) |r| {
        const root_handle = self.node_registry.handleFor(r);
        self.perf.tick_before_render_count += 1;
        std.debug.assert(self.perf.tick_before_render_count <= 1);
        // 先做一轮 layout，让 on_before_render / overlay enter tick 读取到当前帧真实 rect。
        // 这对依赖内容尺寸定位的浮层很关键，否则打开首帧只能看到上一拍的 0x0 / 旧几何。
        const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
        const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(r);
        var partial_interaction_roots = PartialInteractionRoots{};
        if ((had_initial_layout_dirty or had_initial_interaction_dirty) and !r.frame_state.state_bits.dirty.runtime.subtree_dirty and !r.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
        }
        // 这四个归因点曾被删成"写但 0 read"，于是 before_render 整段成了黑盒：
        // 实测它每帧恒定 4.7ms（571 节点），不拆开就只能靠猜。恢复写入。
        var br_timer = std.time.Timer.start() catch undefined;
        if (had_initial_layout_dirty) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.br_initial_layout_us = br_timer.lap() / 1000;
        const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
        // 设置全局帧时间供 on_before_render hooks 和动画系统读取（单线程安全，此处是唯一入口）
        render_engine.setFrameClock(.{
            .time_ms = self.frame_time_ms,
            .dt_ms = self.frame_dt_ms,
            .dt_seconds = self.frame_dt_seconds,
        });
        // tick_depth 门控：遍历期间 freeNode 一律延后（见 freeNode 注释）。
        self.tick_depth += 1;
        const tick_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, self.frame_dt_seconds * 1000.0);
        self.tick_depth -= 1;
        self.perf.br_tick_us = br_timer.lap() / 1000;
        // See forceTickAndRebuildForHitTest: discard pre-hook ancestry
        // decisions after structural mutation and recollect from handles.
        if (self.deferred_free_nodes.len > 0) partial_interaction_roots = .{};
        cx_node_lifetime.drainDeferredFrees(self);
        const current_root = self.root orelse return;
        if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
            if (current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout) {
                layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
                self.syncLayoutToTable(current_root);
            }
            // 索引随后整体重建，不需要局部命中根。
            var ignored_partial = PartialInteractionRoots{};
            _ = runAfterLayoutHooks(self, &ignored_partial);
            cx_runtime_index.fullRebuildRuntimeIndexes(self, self.root orelse current_root) catch @panic("OOM: root changed during before-render tick");
            self.before_render_frame = self.frame_count;
            self.before_render_time_ms = self.frame_time_ms;
            return;
        }
        self.last_tick_animations_active = tick_active;
        if (tick_active) {
            self.needs_redraw = true;
        }
        // on_before_render hooks 可能标脏 layout（修改 translate/rect）和 interaction。
        // 必须先完成 layout 再重建 interaction index，否则 hitTest 的 world position 基于旧 rect。
        // 注意：has_layout_dirty 必须在 layout 之前读取，因为 layout 会清除 dirty 标记。
        // 如果这帧做了 layout，interaction index 也必须更新（子节点的绝对位置变了）。
        const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
        const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(current_root);
        if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty) and !current_root.frame_state.state_bits.dirty.runtime.subtree_dirty and !current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
        }
        if (had_post_tick_layout_dirty) {
            layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(current_root);
        }
        self.perf.br_post_layout_us = br_timer.lap() / 1000;
        const after_layout = runAfterLayoutHooks(self, &partial_interaction_roots);
        const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty or after_layout.ran_layout;
        const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty or after_layout.interaction_dirty;
        // OOM 不吞：见 rebuildRuntimeIndexesIfCurrentRootDirty 的说明。
        if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
            cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (before-render tick)");
        } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.rebuildOrderIndexes(self) catch @panic("OOM: rebuildOrderIndexes (before-render tick)");
        } else if (has_layout_dirty or has_interaction_dirty) {
            cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (before-render tick)");
        }
        self.perf.br_index_us = br_timer.lap() / 1000;
    }
    self.before_render_frame = self.frame_count;
    self.before_render_time_ms = self.frame_time_ms;
}

fn renderVisualLine(context: *anyopaque, content: []const u8, font_size: f32, font_weight: u16, italic: bool) ?text_core_module.VisualLine {
    const self: *Cx = @ptrCast(@alignCast(context));
    return self.text.visualLine(.{
        .text = content,
        .font_family = "system",
        .font_size = font_size,
        .font_weight = font_weight,
        .use_italic = italic,
    }) catch null;
}
