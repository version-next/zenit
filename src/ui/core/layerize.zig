//! Layerization — Phase 4 把 PaintChunks 分组到 LayerTree
//!
//! 取代当前 compositor_plan.zig 每帧 O(N·M) 线性扫描的"合成摘要"。
//! 算法对标 Chromium PaintArtifactCompositor::LayerizeGroup：
//!
//! 1. 按 element 顺序遍历（与 paint order 一致）
//! 2. 对每个 element 检查是否需要"提升"为独立 layer：
//!    - transform 动画期间 → 提升
//!    - opacity 动画期间且 0 < α < 1 → 提升
//!    - overflow: scroll/auto → 提升（解锁 layer transform 滚动）
//!    - will-change: transform | opacity → 提升
//! 3. 不需提升 → 加入"当前 group"（继续合并到父 layer）
//! 4. group 形成新 layer 时检查：
//!    - 面积 < min_layer_area_px2：合并回父
//!    - layer 总数已达上限：合并回父
//!
//! 历史债避免：
//! - **不**让 layerization 跑在每帧——只在 element 拓扑/style/promotion-reason
//!   变化时跑一次；后续帧直接复用 layer tree（PropertyTree epoch 不变即可命中）
//! - **不**为每个 chunk 一 layer（cc 早期教训）
//! - **不**做 transform/opacity 静态提升（无动画时无收益）
//!
//! 输入：
//!   - World（含 ElementTable / PaintTable / PropertyTree）
//!   - PromotionHints（哪些 element 需要提升的 hint，由 reactive/animation 设置）
//! 输出：
//!   - LayerTree 写入

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const layer_tree_mod = @import("layer_tree.zig");
const paint_table_mod = @import("paint_table.zig");

pub const ElementId = element_id_mod.ElementId;
pub const LayerTree = layer_tree_mod.LayerTree;
pub const LayerId = layer_tree_mod.LayerId;
pub const PromotionReason = layer_tree_mod.PromotionReason;
pub const Bounds = paint_table_mod.Bounds;

/// 单个 element 的 promotion hint —— 由 reactive/animation/scroll 在 prepass 阶段设置。
pub const PromotionHint = packed struct(u8) {
    transform_animating: bool = false,
    opacity_animating: bool = false,
    is_scroll_container: bool = false,
    will_change: bool = false,
    has_filter: bool = false, // Phase 6+
    has_3d_transform: bool = false, // Phase 6+
    _reserved: u2 = 0,

    pub const NONE: PromotionHint = .{};

    pub fn shouldPromote(self: PromotionHint) bool {
        return self.transform_animating or
            self.opacity_animating or
            self.is_scroll_container or
            self.will_change;
    }

    pub fn primaryReason(self: PromotionHint) PromotionReason {
        if (self.transform_animating) return .transform_animating;
        if (self.opacity_animating) return .opacity_animating;
        if (self.is_scroll_container) return .scroll;
        if (self.will_change) return .will_change;
        if (self.has_filter) return .filter;
        if (self.has_3d_transform) return .transform_3d;
        return .root;
    }
};

/// 简化版 layerize：给定一组 (element_id, hint, bounds)，构建 LayerTree。
/// 真实集成时由渲染管线调用，把整个 World 的 paint chunks 喂进来。
pub fn layerize(
    tree: *LayerTree,
    items: []const LayerizeInput,
) !void {
    // 先建一个 root layer
    if (tree.root.isNull()) {
        const root_layer = try tree.createLayer(ElementId.NULL, .root, LayerId.NULL);
        tree.root = root_layer;
    }
    const root_id = tree.root;

    var current_group_layer: LayerId = root_id;
    // TODO Phase 4 后续：用 min_layer_area_px2 阈值决定何时合并小 group 到父；
    // 当前先做正确性，性能优化预留 hook。

    for (items) |item| {
        if (item.hint.shouldPromote()) {
            // 检查是否到达 layer 数上限
            if (tree.liveLayerCount() >= tree.config.max_layer_count) {
                // 降级：合到当前 group
                try tree.assignElement(current_group_layer, item.element);
                continue;
            }

            // 提升为新 layer，parent = root（Phase 4 暂不做嵌套层；后续优化）
            const reason = item.hint.primaryReason();
            const new_layer = try tree.createLayer(item.element, reason, root_id);
            try tree.assignElement(new_layer, item.element);

            // bounds 同步到 layer
            if (tree.getMut(new_layer)) |l| {
                l.world_bounds = item.world_bounds;
                l.property_state = item.property_state;
            }

            // 接下来的非提升 element 跟这个新 layer
            current_group_layer = new_layer;
        } else {
            // 不提升 → 合到当前 group layer
            try tree.assignElement(current_group_layer, item.element);
            if (tree.getMut(current_group_layer)) |l| {
                l.world_bounds = l.world_bounds.unionWith(item.world_bounds);
            }
        }
    }
}

pub const LayerizeInput = struct {
    element: ElementId,
    hint: PromotionHint = .NONE,
    world_bounds: Bounds = .ZERO,
    property_state: paint_table_mod.PropertyStateRef = .NONE,
};

// ============================================================================
// Tests
// ============================================================================

test "PromotionHint: shouldPromote" {
    try testing.expect(!PromotionHint.NONE.shouldPromote());

    var h: PromotionHint = .{};
    h.transform_animating = true;
    try testing.expect(h.shouldPromote());
    try testing.expectEqual(PromotionReason.transform_animating, h.primaryReason());

    h = .{ .is_scroll_container = true };
    try testing.expect(h.shouldPromote());
    try testing.expectEqual(PromotionReason.scroll, h.primaryReason());
}

test "layerize: empty input creates only root layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();
    try layerize(&t, &.{});
    try testing.expectEqual(@as(u32, 1), t.liveLayerCount());
    try testing.expect(!t.root.isNull());
}

test "layerize: non-promoted elements all join root" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    const e3: ElementId = .{ .index = 3, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = e1, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e2, .world_bounds = .{ .min_x = 100, .min_y = 0, .max_x = 200, .max_y = 100 } },
        .{ .element = e3, .world_bounds = .{ .min_x = 0, .min_y = 100, .max_x = 200, .max_y = 200 } },
    });

    try testing.expectEqual(@as(u32, 1), t.liveLayerCount());
    try testing.expect(t.layerOf(e1).?.eql(t.root));
    try testing.expect(t.layerOf(e2).?.eql(t.root));
    try testing.expect(t.layerOf(e3).?.eql(t.root));
}

test "layerize: scroll container is promoted to its own layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const root_elem: ElementId = .{ .index = 1, .generation = 0 };
    const scroll_elem: ElementId = .{ .index = 2, .generation = 0 };
    const child_in_scroll: ElementId = .{ .index = 3, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = root_elem, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 800, .max_y = 600 } },
        .{
            .element = scroll_elem,
            .hint = .{ .is_scroll_container = true },
            .world_bounds = .{ .min_x = 100, .min_y = 100, .max_x = 700, .max_y = 500 },
        },
        .{ .element = child_in_scroll, .world_bounds = .{ .min_x = 100, .min_y = 100, .max_x = 200, .max_y = 200 } },
    });

    // 1 root layer + 1 scroll layer
    try testing.expectEqual(@as(u32, 2), t.liveLayerCount());

    const scroll_layer = t.layerOf(scroll_elem).?;
    try testing.expect(!scroll_layer.eql(t.root));
    try testing.expectEqual(PromotionReason.scroll, t.get(scroll_layer).?.reason);

    // child_in_scroll 跟随 scroll layer
    try testing.expect(t.layerOf(child_in_scroll).?.eql(scroll_layer));
}

test "layerize: transform-animating element gets its own layer" {
    var t = LayerTree.init(testing.allocator, .{});
    defer t.deinit();

    const animating: ElementId = .{ .index = 5, .generation = 0 };
    try layerize(&t, &.{
        .{
            .element = animating,
            .hint = .{ .transform_animating = true },
            .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 },
        },
    });

    const layer = t.layerOf(animating).?;
    try testing.expect(!layer.eql(t.root));
    try testing.expectEqual(PromotionReason.transform_animating, t.get(layer).?.reason);
}

test "layerize: max_layer_count cap downgrades extra promotions to current group" {
    var t = LayerTree.init(testing.allocator, .{ .max_layer_count = 3 }); // 1 root + 至多 2 提升
    defer t.deinit();

    const e1: ElementId = .{ .index = 1, .generation = 0 };
    const e2: ElementId = .{ .index = 2, .generation = 0 };
    const e3: ElementId = .{ .index = 3, .generation = 0 };
    const e4: ElementId = .{ .index = 4, .generation = 0 };

    try layerize(&t, &.{
        .{ .element = e1, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e2, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e3, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
        .{ .element = e4, .hint = .{ .transform_animating = true }, .world_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 100, .max_y = 100 } },
    });

    // 总 layer 数不超 3（root + e1 + e2，e3/e4 降级到 e2 group）
    try testing.expect(t.liveLayerCount() <= 3);
    try testing.expect(t.layerOf(e1) != null);
    try testing.expect(t.layerOf(e3) != null);
}
