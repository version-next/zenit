//! Cx → World 表同步：节点挂接 World（ElementTag 映射）、layerize、
//! layout / paint / interaction 三张表的逐帧同步，以及 layout shadow-sync 完整性校验。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const ComputedRect = core.ComputedRect;
const ElementTag = core.ElementTag;
const Node = core.Node;
const interaction_table = core.interaction_table;
const layerize_mod = core.layerize_mod;
const paint_table = core.paint_table;
const render_engine = core.render_engine;
const world = core.world;

/// Node.tag (UI 端) → ElementTable.ElementTag (SoA 端) 映射。
/// 两套 enum 不耦合：UI 端是组件级别（box/button/scroll/list/...），
/// SoA 端是渲染端类别（container/text/image/input/component/...）。
pub fn nodeTagToWorldTag(t: ElementTag) world.ElementTag {
    return switch (t) {
        .box, .scroll, .list, .spacer => .container,
        .text => .text,
        .image => .image,
        .input, .button => .input,
        .custom => .component,
    };
}

pub fn linkNodeToWorld(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) return; // 已注册，幂等
    const eid = self.world.createElement(.{
        .tag = nodeTagToWorldTag(node.tag),
        .key = node.id,
    }) catch return;
    node.element_id_raw = eid.raw();
}

/// 帧开始 layerize—— 把 World.elements 分组到 LayerTree。
/// 返回 layer 数量（含 root）。
///
/// 从 World.interaction 自动收集 PromotionHint —— scroll containers
/// 自动提为独立 layer。无需 caller 传 hints。
/// PaintTable.bounds 为主 + LayoutTable.rect fallback。
fn paintChunkBoundsOrLayoutFallback(w: *world.World, eid: world.ElementId) paint_table.Bounds {
    if (w.paint.get(eid)) |chunk| {
        if (!chunk.bounds.isEmpty()) return chunk.bounds;
    }
    if (w.layout.rect(eid)) |r| {
        return paint_table.Bounds{
            .min_x = r.x,
            .min_y = r.y,
            .max_x = r.x + r.width,
            .max_y = r.y + r.height,
        };
    }
    return paint_table.Bounds{};
}

pub fn layerizeFrame(self: *Cx, extra_hints: []const layerize_mod.LayerizeInput) u32 {
    // 帧开始：清 layer damage 状态
    self.layer_tree.beginFrame();

    // 自动从 InteractionTable 收集 promotion hints（scroll containers 等）
    var collected = std.ArrayList(layerize_mod.LayerizeInput){};
    defer collected.deinit(self.allocator);

    var iter = self.world.interaction.data.iterator();
    while (iter.next()) |entry| {
        const eid = world.ElementId.fromRaw(entry.key_ptr.*);
        const data = entry.value_ptr.*;
        // scroll_id 有效 → promotion hint = scroll container
        if (data.scroll_id != std.math.maxInt(u32)) {
            // 从 PaintTable 取 chunk bounds（shadow-sync 已就绪）。
            const bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid);
            collected.append(self.allocator, .{
                .element = eid,
                .hint = .{ .is_scroll_container = true },
                .world_bounds = bounds,
            }) catch continue;
        }
    }

    // v0.5-P3 Stage 3-3 Phase 4 (session 38): 也根据 PaintChunk.property_state.effect_id
    // 提升带有非 root effect 的元素（opacity layer / backdrop_blur 等）。
    // 这是 Stage 5 删 deferred 文件的关键依赖：layerize 不再只听 InteractionTable，
    // 而是真消费 PaintTable 4 表 SoT。
    for (self.world.paint.chunks.items, 0..) |chunk, idx| {
        const effect_id = chunk.property_state.effect_id;
        if (effect_id == std.math.maxInt(u32)) continue;
        if (effect_id >= self.property_tree.effects.items.len) continue;
        const effect = self.property_tree.effects.items[effect_id];
        // 只提升真需要离屏的 effect（opacity layer / backdrop blur）
        if (!effect.requires_offscreen) continue;

        const eid_idx: u24 = @intCast(idx);
        const eid: world.ElementId = .{
            .index = eid_idx,
            .generation = self.world.elements.generations.items[eid_idx],
        };
        // 跳过已经因 scroll_id 添加的元素，避免重复
        var already_collected = false;
        for (collected.items) |c| {
            if (c.element.eql(eid)) {
                already_collected = true;
                break;
            }
        }
        if (already_collected) continue;

        const hint: layerize_mod.PromotionHint = switch (effect.kind) {
            .opacity, .composited_group => .{ .opacity_animating = true },
            .backdrop_blur => .{ .has_filter = true },
            else => layerize_mod.PromotionHint.NONE,
        };
        if (!hint.shouldPromote() and !hint.has_filter) continue;

        collected.append(self.allocator, .{
            .element = eid,
            .hint = hint,
            .world_bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid),
        }) catch break;
    }
    // 追加 caller 显式传的 hints
    for (extra_hints) |h| collected.append(self.allocator, h) catch break;

    layerize_mod.layerize(&self.layer_tree, collected.items) catch return 0;
    return self.layer_tree.liveLayerCount();
}

/// See `Cx.syncLayoutToTable`. Flip to true to restore the old defensive walk.
const walk_layout_tree_each_frame = false;

pub fn syncLayoutToTable(self: *Cx, root: *Node) void {
    if (comptime walk_layout_tree_each_frame) syncLayoutNodeRecursive(self, root);
}

pub fn syncNodeRect(self: *Cx, node: *Node) void {
    if (node.element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    self.world.layout.ensureSlot(eid) catch return;
}

fn syncLayoutNodeRecursive(self: *Cx, node: *Node) void {
    self.syncNodeRect(node);
    for (node.children.items) |child| syncLayoutNodeRecursive(self, child);
}

pub fn syncPaintToTable(self: *Cx, root: *Node) void {
    self.perf.synced_node_count = 0;
    syncPaintNodeRecursive(self, root);
}

fn syncPaintNodeRecursive(self: *Cx, node: *Node) void {
    self.perf.synced_node_count +|= 1;
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        // rect 读一次复用：这是每帧每节点路径，rectFromWorldOrFallback
        // 一次 ≈ 6-8 层调用（Debug 不 CSE，写四遍就是四次全链）。
        const rect = node.rectFromWorldOrFallback();
        const hash = paintContentHash(node, rect);
        const bounds: paint_table.Bounds = .{
            .min_x = rect.x,
            .min_y = rect.y,
            .max_x = rect.x + rect.w,
            .max_y = rect.y + rect.h,
        };
        // beginRecord 返回 true = 需要重录（hash mismatch / 首次）；false = cache hit。
        const need_record = self.world.paint.beginRecord(eid, hash) catch return;
        // v0.5-P3 Stage 3-3 Phase 3 (session 37): 从 SceneRuntime 取 property tree refs
        // (transform_id / clip_id / effect_id)，从 InteractionTable 取 scroll_id，写到 chunk.property_state。
        const runtime = self.scene_runtime.get(node.id);
        const interaction_data = self.world.interaction.get(eid);
        const property_state = paint_table.PropertyStateRef{
            .transform_id = if (runtime) |rt| rt.transform_id else std.math.maxInt(u32),
            .clip_id = if (runtime) |rt| rt.clip_id else std.math.maxInt(u32),
            .effect_id = if (runtime) |rt| rt.effect_id else std.math.maxInt(u32),
            .scroll_id = if (interaction_data) |d| d.scroll_id else std.math.maxInt(u32),
        };
        if (need_record) {
            // 真 mirror 该节点的 own DisplayItem 范围。
            if (runtime) |rt| {
                const start: usize = rt.display_item_start;
                const count: usize = rt.display_item_count;
                if (count > 0 and start + count <= self.display_list.items.items.len) {
                    const gpu_draw_shadow = @import("render_engine/gpu_draw_shadow.zig");
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const di = self.display_list.items.items[start + i];
                        // 唯一的 display_list → paint_table
                        // 映射点 (从 cx 内 mapDisplayItem 合并到 shadow 路径的
                        // lowerDisplayItem)。两个路径产 identical paint_table.DisplayItem。
                        const mapped = gpu_draw_shadow.lowerDisplayItem(di);
                        // 失败会让本节点的 paint chunk **少掉若干 item** →
                        // 画面局部缺失且无任何信号。计数以便诊断
                        // （审查报告 §3 的静默吞错家族）。
                        self.world.paint.pushItem(eid, mapped) catch {
                            core.paint_push_failures += 1;
                        };
                    }
                }
            }
            self.world.paint.endRecord(eid, property_state);
        }
        // 单次 get 合并两笔写：cache hit 也要更新 property_state
        // （transform_id / scroll_id 会变）；chunk.bounds 是 world-space
        // element rect —— pushItem 内部 unionWith 累积的 local_bounds
        // （item-local 坐标）与 world bounds 语义不符，这里覆盖。下游
        // （LayerTree.layerizeFrame）要的是 world bounds。
        if (self.world.paint.get(eid)) |chunk| {
            if (!need_record) chunk.property_state = property_state;
            chunk.bounds = bounds;
        }
    }
    for (node.children.items) |child| syncPaintNodeRecursive(self, child);
}

/// 轻量 content hash —— Stage 3-3 Phase 1+ 用于 cache invalidation。
/// 取 background + border + opacity + width/height + text + image/icon refs。
/// session 43: 扩展从 background-only 到 8 个常见可视属性 — 让 PaintTable cache
/// invalidation 覆盖更多真实修改场景。
fn paintContentHash(node: *const Node, rect: ComputedRect) u64 {
    var h = std.hash.Wyhash.init(0);
    const bg = node.getBackground();
    h.update(std.mem.asBytes(&bg));
    h.update(std.mem.asBytes(&node.style.border.color));
    h.update(std.mem.asBytes(&node.style.border.width));
    h.update(std.mem.asBytes(&node.getOpacity()));
    const w = rect.w;
    const ht = rect.h;
    h.update(std.mem.asBytes(&w));
    h.update(std.mem.asBytes(&ht));
    if (node.getText()) |t| {
        h.update(t.content);
        h.update(std.mem.asBytes(&t.font_size));
        h.update(std.mem.asBytes(&t.color));
    }
    if (node.getImage()) |im| {
        h.update(std.mem.asBytes(&im.texture_id));
        h.update(std.mem.asBytes(&im.tint));
    }
    if (node.getIcon()) |ic| {
        h.update(std.mem.asBytes(&ic.icon_id));
        h.update(std.mem.asBytes(&ic.tint));
    }
    return h.final();
}

pub fn syncInteractionToTable(self: *Cx, root: *Node) void {
    syncInteractionNodeRecursive(self, root);
}

fn syncInteractionNodeRecursive(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const has_a11y = node.behavior.interaction.a11y != null;
        const has_event = nodeHasAnyEvent(node);
        // v0.5-P3 Stage 3-4 fix (session 34): 保留已有 scroll_id（ScrollArea.mount 注入），
        // 不被每帧 render 后的 syncInteractionToTable 擦回 sentinel。
        const existing_scroll_id: u32 = if (self.world.interaction.get(eid)) |existing|
            existing.scroll_id
        else
            std.math.maxInt(u32);
        const has_scroll = existing_scroll_id != std.math.maxInt(u32);
        if (node.behavior.interaction.focusable or has_a11y or has_event or has_scroll) {
            const focused = if (self.focus_manager.current_focus) |fn_node| (fn_node == node) else false;
            const ti: i16 = if (node.behavior.interaction.tab_index) |t|
                @as(i16, @intCast(@max(@min(t, std.math.maxInt(i16)), std.math.minInt(i16))))
            else
                0;
            const role: u16 = if (node.behavior.interaction.a11y) |a| @intFromEnum(a.role) else 0;
            const data: interaction_table.InteractionData = .{
                .focus = .{
                    .focusable = node.behavior.interaction.focusable,
                    .tabbable = node.behavior.interaction.tab_index != null,
                    .focused = focused,
                },
                .tab_index = ti,
                .event_mask = if (has_event) 0xFFFF_FFFF else 0,
                .a11y_role = role,
                .scroll_id = existing_scroll_id,
            };
            // 失败 → 该节点这一帧**不可命中**（点击/hover 全失效），
            // 且完全无信号。与 core.paint_push_failures 同属"静默劣化"家族。
            self.world.interaction.put(eid, data) catch {
                core.interaction_put_failures += 1;
            };
        } else {
            _ = self.world.interaction.remove(eid);
        }
    }
    for (node.children.items) |child| syncInteractionNodeRecursive(self, child);
}

fn nodeHasAnyEvent(node: *const Node) bool {
    const e = node.behavior.events;
    return e.on_click != null or e.on_hover != null or e.on_leave != null or
        e.on_focus != null or e.on_blur != null or
        e.on_key_down != null or e.on_key_up != null or
        e.on_event != null or e.on_event_capture != null or e.on_action != null;
}

pub fn assertLayoutSyncIntegrity(self: *Cx, root: *Node) bool {
    return assertLayoutSyncIntegrityRecursive(self, root);
}

fn assertLayoutSyncIntegrityRecursive(self: *Cx, node: *Node) bool {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const lr = self.rectOf(eid) orelse return false;
        const eps: f32 = 0.001;
        // v0.5-P3 N-2 (2026-05-03 字段已删): frame_state.rect 已删，
        // World.LayoutTable 是唯一 source-of-truth。原 frame_state vs
        // LayoutTable 的 divergence 检测自动失效（divergence 不可能发生）。
        // PaintTable.bounds vs LayoutTable.rect 的 invariant 仍在下面 enforce。
        // v0.5-P3 Stage 3-3 Phase 5 (session 40): PaintTable.bounds 应等于 LayoutTable.rect
        // （shadow-sync 由 syncPaintToTable 保证）。任何 PaintTable shadow 漏写都被此处 catch。
        if (self.world.paint.get(eid)) |chunk| {
            if (!chunk.bounds.isEmpty()) {
                if (@abs(chunk.bounds.min_x - lr.x) > eps) return false;
                if (@abs(chunk.bounds.min_y - lr.y) > eps) return false;
                if (@abs(chunk.bounds.max_x - (lr.x + lr.width)) > eps) return false;
                if (@abs(chunk.bounds.max_y - (lr.y + lr.height)) > eps) return false;
            }
        }
        // v0.5-P3 Stage 3-2 Phase 2 attempt (session 41 — REVERTED):
        // 试图加 ElementTable 父子链结构一致性 invariant，但 Input/某些组件路径下
        // Node.parent 与 World.elements parent 在 layout pass 中间会有 stale 状态
        // （Input 组件内部 reparent 时序复杂）。撞墙 panic，已 revert。
        // 真正的 ElementTable invariant gate 需要先精细化"何时同步" hook。
    }
    for (node.children.items) |child| {
        if (!assertLayoutSyncIntegrityRecursive(self, child)) return false;
    }
    return true;
}
