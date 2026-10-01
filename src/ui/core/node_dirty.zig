//! node_dirty, v0.12 §N1 god-object split: 从 node.zig 抽出 dirty
//! 传播子域（15 方法：12 pub + 3 private helper）。
//!
//! 与 v0.9 paint_content_accessor.zig（pca）范式的本质差异：pca 是
//! SoA accessor，free function 收 element_id_raw + POD，Node-agnostic。
//! dirty 传播深度操作 self.parent 链 / frame_state.state_bits / meta，
//! 必须 *Node 类型 -> 本模块用 **Node-typed free function**，
//! @import("node.zig") 取 Node 类型（与 node.zig 循环 import；Zig
//! 惰性求值，多个 sibling 早已这样做，成立）。
//!
//! node.zig 保留全部 15 个 dirty 方法的 thin delegate（按原 pub/private
//! 可见性），方法体一行转发到本模块。node.zig 内 self.markX() caller
//! 极多且散落别的子域，保留本地 delegate -> 零改 caller。
//!
//! dirty-notify callback 单元（DirtyKind / DirtyNotifyFn / g_dirty_notify
//! / setDirtyNotifyCallback）一并搬入（markRenderDirty 用 g_dirty_notify
//! 推 dirty 到 World.dirty_set）；node.zig re-export 保持公开 API 不破。

const std = @import("std");
const world_mod = @import("world.zig");
const node_mod = @import("node.zig");
const redraw = @import("redraw.zig");
const debug_trace = @import("debug_trace.zig");

const Node = node_mod.Node;

// ─────────────────────────────────────────────────────────────────────
// dirty-notify callback 单元（自 node.zig 整体搬入）
// 同步通过 callback 把 dirty 推到 World.dirty_set。
// 不直接 import core.zig（避免循环）；core.zig 在 Cx.init 时设 callback。
// ─────────────────────────────────────────────────────────────────────

pub const DirtyKind = enum(u8) { layout, style, structure, interaction };
pub const DirtyNotifyFn = *const fn (element_id_raw: u32, kind: DirtyKind) void;
var g_dirty_notify: ?DirtyNotifyFn = null;

/// 把一次 dirty 标记推给节点所属 World 的 dirty_set。
///
/// P0-3 阶段 3：优先直连 `node.world_ref`；world_ref == null（cx-less mock）
/// 时退回旧的进程级回调。语义与原 core.zig:onNodeDirty 逐行一致。
fn markWorldDirty(node: anytype, kind: DirtyKind) void {
    if (node.element_id_raw == 0xFFFFFFFF) return;
    const flags: world_mod.DirtyFlags = switch (kind) {
        .layout => .{ .input = .{ .geometry_changed = true } },
        .style => .{ .input = .{ .style_changed = true } },
        .structure => .{ .input = .{ .structure_changed = true } },
        .interaction => .{ .input = .{ .interaction_changed = true } },
    };
    if (node.world_ref) |w| {
        // OOM 容错，dirty 丢一次，本帧仍走旧路径重建。
        w.markDirty(world_mod.ElementId.fromRaw(node.element_id_raw), flags) catch {};
        return;
    }
    if (g_dirty_notify) |notify| notify(node.element_id_raw, kind);
}

pub fn setDirtyNotifyCallback(notify: ?DirtyNotifyFn) void {
    g_dirty_notify = notify;
}

// ─────────────────────────────────────────────────────────────────────
// dirty 传播方法（Node-typed free function）
// ─────────────────────────────────────────────────────────────────────

/// loose interaction 位（pipeline.interaction / hit.geometry / hit.semantics）
/// 的翻转代数。这三个位不冒泡，历史上只能靠全树递归扫描
/// （subtreeHasLooseInteractionDirty，曾是帧结构采样最大单项）。所有
/// 置位/清位点都 bump 本代数,扫描按 (root, gen) 记忆,任何翻转自动失效,
/// 语义与逐次扫描精确等价。新增这三个位的写点时必须一并 bump（core.zig
/// 的 memo 注释同此约定）。
pub var g_loose_interaction_gen: u64 = 1;

pub inline fn bumpLooseInteractionGen() void {
    g_loose_interaction_gen +%= 1;
}

pub fn markLayoutDirty(self: *Node) void {
    if (self.frame_state.state_bits.dirty.core.layout) return;
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.core.layout = true;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;
    debug_trace.maybeRecordRender(self.id, .layout_triggered, "markLayoutDirty");

    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_layout and parent.frame_state.state_bits.dirty.core.subtree_render and parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
        parent.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

/// 标脏自身和父节点的布局。用于子节点 sizing 属性（width/height）被动态修改后，
/// 需要父容器重新跑 layoutChildren 来重新计算子节点尺寸的场景。
pub fn markSizingDirty(self: *Node) void {
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.core.layout = true;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;
    debug_trace.maybeRecordRender(self.id, .sizing_triggered, "markSizingDirty");

    if (self.parent) |parent_node| {
        parent_node.frame_state.state_bits.dirty.core.layout = true;
        parent_node.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent_node.frame_state.state_bits.dirty.core.render = true;
        parent_node.frame_state.state_bits.dirty.core.subtree_render = true;
        parent_node.frame_state.state_bits.dirty.pipeline.composite = true;
        parent_node.frame_state.state_bits.dirty.pipeline.subtree_composite = true;

        // 从 grandparent 开始冒泡 subtree_dirty
        // （parent 已经在上面处理过了，从 parent 开始会立即 break 导致 grandparent 不被标脏）
        if (!parent_node.style.layout_isolation) {
            var p = parent_node.parent;
            while (p) |ancestor| {
                if (ancestor.frame_state.state_bits.dirty.core.subtree_layout and ancestor.frame_state.state_bits.dirty.core.subtree_render and ancestor.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
                ancestor.frame_state.state_bits.dirty.core.subtree_layout = true;
                ancestor.frame_state.state_bits.dirty.core.subtree_render = true;
                ancestor.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
                if (ancestor.style.layout_isolation) break;
                p = ancestor.parent;
            }
        }
    }
}

/// 标脏运行时索引（registry/focus order/interaction entries），用于结构变化场景。
/// 与普通 layout dirty 分离，避免仅位置/尺寸变化时全树重建运行时索引。
pub fn markRuntimeIndexDirty(self: *Node) void {
    if (!self.frame_state.state_bits.dirty.runtime.dirty) {
        self.frame_state.state_bits.dirty.runtime.dirty = true;
    }
    bubbleChildRuntimeIndexDirty(self, false);
}

pub fn markRuntimeIndexFullRebuild(self: *Node) void {
    markRuntimeIndexDirty(self);
    if (!self.frame_state.state_bits.dirty.runtime.full_rebuild) {
        self.frame_state.state_bits.dirty.runtime.full_rebuild = true;
    }
    bubbleChildRuntimeIndexDirty(self, true);
}

pub fn markOrderDirty(self: *Node) void {
    if (!self.frame_state.state_bits.dirty.pipeline.order) {
        self.frame_state.state_bits.dirty.pipeline.order = true;
    }
    if (!self.frame_state.state_bits.dirty.pipeline.subtree_order) {
        self.frame_state.state_bits.dirty.pipeline.subtree_order = true;
    }

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_order;
        parent.frame_state.state_bits.dirty.pipeline.subtree_order = true;
        if (had_dirty) break;
        p = parent.parent;
    }
}

pub fn markInteractionDirty(self: *Node) void {
    bumpLooseInteractionGen();
    self.invalidateCustomClipGeometryCache();
    if (!self.frame_state.state_bits.dirty.pipeline.interaction) {
        self.frame_state.state_bits.dirty.pipeline.interaction = true;
    }
    self.frame_state.state_bits.dirty.hit.geometry = true;
    self.frame_state.state_bits.dirty.hit.semantics = true;
    if (!self.frame_state.state_bits.dirty.pipeline.subtree_interaction) {
        self.frame_state.state_bits.dirty.pipeline.subtree_interaction = true;
    }
    redraw.requested = true;

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_interaction;
        parent.frame_state.state_bits.dirty.pipeline.subtree_interaction = true;
        if (had_dirty) break;
        p = parent.parent;
    }
}

pub fn markHitSemanticsDirty(self: *Node) void {
    bumpLooseInteractionGen();
    self.frame_state.state_bits.dirty.hit.semantics = true;
    markInteractionDirty(self);
}

pub fn markHitStructureDirty(self: *Node) void {
    self.frame_state.state_bits.dirty.hit.structure = true;
    markRuntimeIndexDirty(self);
}

pub fn bubbleChildRuntimeIndexDirty(self: *Node, full_rebuild: bool) void {
    if (!self.frame_state.state_bits.dirty.runtime.subtree_dirty) {
        self.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
    }
    if (full_rebuild and !self.frame_state.state_bits.dirty.runtime.subtree_full_rebuild) {
        self.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;
    }

    var p = self.parent;
    while (p) |parent| {
        const had_dirty = parent.frame_state.state_bits.dirty.runtime.subtree_dirty;
        const had_full = parent.frame_state.state_bits.dirty.runtime.subtree_full_rebuild;
        parent.frame_state.state_bits.dirty.runtime.subtree_dirty = true;
        if (full_rebuild) parent.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;
        if (had_dirty and (!full_rebuild or had_full)) break;
        p = parent.parent;
    }
}

/// 标脏子树但不标脏自身布局。向上冒泡 subtree_dirty。
/// 用于"只有子节点需要重新布局，而当前节点本身的布局不需要重算"的场景。
/// 例如：VirtualList 的 content_node，其所有子节点都是 absolute 定位，
/// rebind 后只需递归布局 dirty 的子节点，不需要重跑 content_node 自身的 layoutChildren。
pub fn markSubtreeDirty(self: *Node) void {
    if (self.frame_state.state_bits.dirty.core.subtree_layout and self.frame_state.state_bits.dirty.core.subtree_render) return;
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.core.subtree_layout = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    redraw.requested = true;

    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_layout and parent.frame_state.state_bits.dirty.core.subtree_render and parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
        parent.frame_state.state_bits.dirty.core.subtree_layout = true;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

pub fn markCompositeDirty(self: *Node) void {
    const self_out_of_band = isOutOfBandRenderUnit(self);
    const self_needs_render_dirty = self.meta.per_frame.caches.commands.promoted == null and !self_out_of_band;
    var bubble_render_dirty = true;
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.composite +%= 1;
    self.frame_state.state_bits.dirty.pipeline.composite = true;
    self.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
    if (self_needs_render_dirty) {
        self.frame_state.state_bits.dirty.core.render = true;
        self.frame_state.state_bits.dirty.core.subtree_render = true;
    }
    redraw.requested = true;

    // subtree_render 逐跳冒泡：带外跳（child 对 parent 是带外单元）不标 parent，但**继续
    // 往上走**，更上层的缓存祖先里仍含 child 的旧命令（方案 §5.4 C3）。旧实现在第一个
    // 带外跳处整体停止冒泡，promoted / legacy 祖先因此永久替放旧画面（V2）。
    var child: *Node = self;
    var p = self.parent;
    while (p) |parent| {
        const had_composite_dirty = parent.frame_state.state_bits.dirty.pipeline.subtree_composite;
        const had_render_dirty = parent.frame_state.state_bits.dirty.core.subtree_render;
        parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
        if (bubble_render_dirty) {
            if (!isOutOfBandRenderUnit(child)) {
                parent.frame_state.state_bits.dirty.core.subtree_render = true;
            }
            // layout_isolation 作为 render dirty 边界（与 markLayoutDirty 一致）
            if (parent.style.layout_isolation) {
                bubble_render_dirty = false;
            }
        }
        if (had_composite_dirty and (!bubble_render_dirty or had_render_dirty)) break;
        child = parent;
        p = parent.parent;
    }
}

/// composite 类属性（opacity/translate/scale/rotate）动画写入后的**唯一权威**失效组合：
/// interaction（hit-test 几何）+ composite（layer 属性/重合成）+ invalidateRenderCache
/// （content 版本，防 promoted/payload 缓存 stale）。所有动画驱动器（transition tick、
/// node_animator、hooks before_render）与 Node setter 必须统一走这里，历史上四条写入
/// 路径各标各的 dirty（有的漏 composite、有的漏 cache 失效）是动画期偶发视觉 bug 的
/// 结构性来源。
pub fn markCompositePropDirty(self: *Node) void {
    markInteractionDirty(self);
    markCompositeDirty(self);
    @import("node_render_cache.zig").invalidateRenderCache(self);
}

/// composite 属性**逐帧动画驱动**专用组合：interaction + composite，**不** bump
/// content 版本。动画帧内容未变、只有 layer 属性变，bump content 版本会让
/// canReusePromotedSurface 每帧失效、打死动画期 surface 复用（文本 shimmer +
/// 全量重建）。一次性写入（定位、setter、状态切换）用 markCompositePropDirty；
/// 每帧插值写入用本函数。除这两个具名组合外，禁止手写 dirty 组合。
pub fn markCompositeAnimFrameDirty(self: *Node) void {
    markInteractionDirty(self);
    markCompositeDirty(self);
}

/// 带外渲染单元（原名 escapesAncestorRenderPass；方案 §5.4 C3）：`self` 对它的**直接父节点**
/// 而言，是不是"父节点的缓存替放时会被剔除、再 fresh 补渲染"的单元。是 -> self 的 render
/// dirty 不必让父节点失效（防止 overlay 闪烁拖着父节点的 legacy overflow 快照每帧重建）。
///
/// 判据必须与渲染侧逐条对上：
///   - legacy overflow 替放（tryReplayLegacyOverflowCacheHit）剔除父节点的全部 z>0 直接
///     子节点子树（appendLegacyCachedCommandsWithoutEscapedOverlays），再由
///     renderOverlayChildrenAfterCacheHit 按 `!use_opacity_layer` fresh 补渲染；legacy
///     缓存只在父节点没有 effect（-> 不开 opacity layer）时才会写/读，两者恒一致。
///   - promoted 替放（tryReplayPromotedCacheHit）整段替放、**不**剔除也不补渲染 z>0 子节点
///     （promoted 节点开 surface -> use_opacity_layer）。所以父节点持有 promoted 缓存时，
///     self 不是带外单元，必须让父节点失效。这里读的是父节点**实际持有**的缓存，而不是
///     "父节点会不会开 layer"的近似判据，旧判据只看 opacity，composited_group /
///     will_change 等 opacity=1 的 promoted 父节点被误判为带外（V2 第一种形态）。
///   - opacity < 0.999 的父节点保持旧行为（照常冒泡）：它开 opacity layer，本来就没有
///     legacy 缓存，冒泡只是保守。
///
/// 这只是**一跳**的判定。带外不等于"整条祖先链都不用失效"：父节点之上的缓存祖先
/// （promoted 整段、legacy 快照）照样含 self 的旧命令，冒泡必须越过这一跳继续往上
/// （markRenderDirty / markCompositeDirty 的逐跳循环）。
pub fn isOutOfBandRenderUnit(self: *const Node) bool {
    const parent = self.parent orelse return false;
    if (self.style.z_index() <= 0) return false;
    if (std.math.clamp(parent.getOpacity(), 0.0, 1.0) < 0.999) return false;
    if (parent.meta.per_frame.caches.commands.promoted != null) return false;
    return true;
}

/// 带外单元自身 render dirty 时的 subtree_render 冒泡：逐跳判定，带外跳不标 parent 但
/// 继续向上；非带外跳照常标记，遇到已脏的祖先停（它之上已按同一规则冒泡过，逐跳判定
/// 只取决于 (child, parent) 这一对，与从哪条路径来无关）；layout_isolation 为边界。
/// 代价 O(祖先深度)，与 subtree_composite 冒泡同阶；空闲帧不走这里。
fn bubbleSubtreeRenderAcrossOutOfBandHops(self: *Node) void {
    var child: *Node = self;
    var p = self.parent;
    while (p) |parent| {
        if (!isOutOfBandRenderUnit(child)) {
            if (parent.frame_state.state_bits.dirty.core.subtree_render) break;
            parent.frame_state.state_bits.dirty.core.subtree_render = true;
        }
        if (parent.style.layout_isolation) break;
        child = parent;
        p = parent.parent;
    }
}

pub fn markRenderDirty(self: *Node) void {
    self.invalidateCustomClipGeometryCache();
    self.meta.per_frame.caches.versions.content +%= 1;
    self.frame_state.state_bits.dirty.core.render = true;
    self.frame_state.state_bits.dirty.core.subtree_render = true;
    redraw.requested = true;

    // P0-3 阶段 3：直连 owner World 推 dirty，不再经过进程级 g_dirty_notify。
    markWorldDirty(self, .style);

    // 带外渲染单元（isOutOfBandRenderUnit）：父节点的缓存替放会剔除它再 fresh 补渲染，
    // 所以不标父节点的 subtree_render（防止 overlay 闪烁拖着父节点快照重建）；但更上层
    // 的缓存祖先含它的旧命令，subtree_render 必须越过带外跳继续冒泡（方案 §5.4 C3）。
    if (isOutOfBandRenderUnit(self)) {
        var p = self.parent;
        while (p) |parent| {
            if (parent.frame_state.state_bits.dirty.pipeline.subtree_composite) break;
            parent.frame_state.state_bits.dirty.pipeline.subtree_composite = true;
            if (parent.style.layout_isolation) break;
            p = parent.parent;
        }
        bubbleSubtreeRenderAcrossOutOfBandHops(self);
        return;
    }

    // 普通节点：向上冒泡 subtree_render_dirty
    // 遇到 layout_isolation=true 的祖先时停止（与 markLayoutDirty/markSizingDirty 一致）：
    // isolation 节点作为 dirty 边界，让 render_engine 的 fast-skip 能在 isolation 外生效。
    var p = self.parent;
    while (p) |parent| {
        if (parent.frame_state.state_bits.dirty.core.subtree_render) break;
        parent.frame_state.state_bits.dirty.core.subtree_render = true;
        if (parent.style.layout_isolation) break;
        p = parent.parent;
    }
}

/// markRenderDirty + 追踪渲染原因（DevTools trace）
pub fn markRenderDirtyTracked(self: *Node, reason: debug_trace.RenderReason, comptime source: []const u8) void {
    markRenderDirty(self);
    debug_trace.maybeRecordRender(self.id, reason, source);
}
