//! DirtyFlags — Phase 0 地基（待 Phase 3 接入 Node 拆分）
//!
//! 替代当前 Node 上分散的 13 个布尔 + 2 个 u32 version。
//!
//! 历史债避免（吸取 Chromium cc::Layer 18 布尔状态混乱教训）：
//! 严格分两组：
//! - **input flags**：上游写入端用（"什么属性变了"）
//! - **output flags**：下游读端用（"什么阶段需要重做"）
//!
//! 不让单个 set 同时翻多组 —— `markStyleChanged`、`markGeometryChanged` 等
//! 高层 API 决定输入到输出的映射，而不是让每个调用点自己 OR 一堆位。
//!
//! 子树传播位是单独的（`subtree_*`），由 `markSubtree` 系列 API 推进，
//! 永远不与"自身" flag 在同一调用里被 OR。
//!
//! 容量：u32 packed，足够当前所有阶段；不再用 u16 因为后续要加 layer 阶段。
//!
//! 关键不变量：
//! 1. `clear()` 后所有位归零（视作 fully clean）
//! 2. `union(other)` = 集合并
//! 3. `subtree_*` 永远 ⊇ `*`（局部脏 ⇒ 子树脏）由 promote() 强制
//! 4. 每个 flag 都有明确语义；不重复表达

const std = @import("std");
const testing = std.testing;

/// 输入域：组件/动画/事件等上游写入；下游不应直接读这些位决策。
pub const InputFlags = packed struct(u8) {
    /// 自身 style 属性变化（color、opacity、transform 等）。
    style_changed: bool = false,
    /// 自身几何相关 style 变化（width/height/padding/margin/flex/grid）。
    geometry_changed: bool = false,
    /// 文本内容/字体相关变化。
    text_changed: bool = false,
    /// 子节点拓扑变化（增/删/序）。
    structure_changed: bool = false,
    /// 交互意图（hit_test_visible / pointer-events / focus options）变化。
    interaction_changed: bool = false,
    /// 命中几何（rect/path/clip）变化（一般由 geometry_changed 派生，但允许显式置位）。
    hit_geometry_changed: bool = false,

    _reserved: u2 = 0,

    pub const NONE: InputFlags = .{};

    pub fn isEmpty(self: InputFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: InputFlags, other: InputFlags) InputFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// 输出域：渲染流水线读取以决定本帧需要做什么。
/// 所有位均 false = 此节点本帧零工作（fast skip）。
pub const OutputFlags = packed struct(u8) {
    /// 需要重新布局
    needs_layout: bool = false,
    /// 需要重新生成 paint chunks（display items）
    needs_paint: bool = false,
    /// 需要重新合成（layer transform/opacity 更新即可，paint 可能不变）
    needs_composite: bool = false,
    /// 需要重建命中代理
    needs_hit_rebuild: bool = false,
    /// 需要更新交互语义（focus tree / aria projection）
    needs_interaction_update: bool = false,
    /// runtime 索引（z-order/runtime_index）需要重排
    needs_order_update: bool = false,

    _reserved: u2 = 0,

    pub const NONE: OutputFlags = .{};
    pub const ALL: OutputFlags = .{
        .needs_layout = true,
        .needs_paint = true,
        .needs_composite = true,
        .needs_hit_rebuild = true,
        .needs_interaction_update = true,
        .needs_order_update = true,
    };

    pub fn isEmpty(self: OutputFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: OutputFlags, other: OutputFlags) OutputFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// 子树脏位：祖先方向的"我或我后代有脏"汇总，避免子树扫描。
pub const SubtreeFlags = packed struct(u8) {
    has_layout_dirty: bool = false,
    has_paint_dirty: bool = false,
    has_composite_dirty: bool = false,
    has_hit_rebuild: bool = false,
    has_interaction_update: bool = false,
    has_order_update: bool = false,

    _reserved: u2 = 0,

    pub const NONE: SubtreeFlags = .{};

    pub fn isEmpty(self: SubtreeFlags) bool {
        const v: u8 = @bitCast(self);
        return v == 0;
    }

    pub fn unionWith(self: SubtreeFlags, other: SubtreeFlags) SubtreeFlags {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }

    /// 把 OutputFlags 的位投影到 SubtreeFlags（用于将自身脏向上 propagate）。
    pub fn fromOutput(out: OutputFlags) SubtreeFlags {
        return .{
            .has_layout_dirty = out.needs_layout,
            .has_paint_dirty = out.needs_paint,
            .has_composite_dirty = out.needs_composite,
            .has_hit_rebuild = out.needs_hit_rebuild,
            .has_interaction_update = out.needs_interaction_update,
            .has_order_update = out.needs_order_update,
        };
    }
};

/// 完整脏标位汇集。32-bit packed = 内存友好；u64 对齐。
/// 暂不放在 Node 内部 —— Phase 3 拆 Node 时把这个推进 LayoutTable/PaintTable 旁。
pub const DirtyFlags = packed struct(u32) {
    input: InputFlags = .{},
    output: OutputFlags = .{},
    subtree: SubtreeFlags = .{},
    /// 8-bit padding 给未来扩展
    _reserved: u8 = 0,

    pub const NONE: DirtyFlags = .{};

    pub fn isClean(self: DirtyFlags) bool {
        return self.input.isEmpty() and self.output.isEmpty() and self.subtree.isEmpty();
    }

    pub fn clear(self: *DirtyFlags) void {
        self.* = NONE;
    }

    /// 仅清掉本节点的输出脏位（保留 subtree —— 那是子树状态）。
    /// 渲染流水线在某阶段消费完后调用。
    pub fn clearOutputs(self: *DirtyFlags) void {
        self.output = .{};
    }

    pub fn clearSubtree(self: *DirtyFlags) void {
        self.subtree = .{};
    }
};

/// InputFlags → OutputFlags 投影。决定哪些上游变更触发哪些下游阶段。
/// **唯一**的 input→output 映射点 —— 不允许其他地方手动 OR 输出位
/// （除调度器为合并子树脏汇总时）。
pub fn outputFromInput(in: InputFlags) OutputFlags {
    var out = OutputFlags.NONE;
    if (in.geometry_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
        out.needs_composite = true;
        out.needs_hit_rebuild = true;
    }
    if (in.text_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
    }
    if (in.style_changed) {
        // 纯样式（如颜色）只触发 paint；如果同时 geometry_changed 已置位则上面已覆盖
        out.needs_paint = true;
    }
    if (in.structure_changed) {
        out.needs_layout = true;
        out.needs_paint = true;
        out.needs_composite = true;
        out.needs_hit_rebuild = true;
        out.needs_order_update = true;
    }
    if (in.interaction_changed) {
        out.needs_interaction_update = true;
    }
    if (in.hit_geometry_changed) {
        out.needs_hit_rebuild = true;
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================

test "DirtyFlags is exactly 4 bytes (u32 packed)" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(DirtyFlags));
}

test "DirtyFlags NONE is fully clean" {
    const f = DirtyFlags.NONE;
    try testing.expect(f.isClean());
    try testing.expect(f.input.isEmpty());
    try testing.expect(f.output.isEmpty());
    try testing.expect(f.subtree.isEmpty());
}

test "InputFlags union" {
    const a: InputFlags = .{ .style_changed = true };
    const b: InputFlags = .{ .text_changed = true };
    const c = a.unionWith(b);
    try testing.expect(c.style_changed);
    try testing.expect(c.text_changed);
    try testing.expect(!c.geometry_changed);
}

test "outputFromInput: style_changed → paint only" {
    const out = outputFromInput(.{ .style_changed = true });
    try testing.expect(out.needs_paint);
    try testing.expect(!out.needs_layout);
    try testing.expect(!out.needs_composite);
    try testing.expect(!out.needs_hit_rebuild);
}

test "outputFromInput: geometry_changed → layout + paint + composite + hit" {
    const out = outputFromInput(.{ .geometry_changed = true });
    try testing.expect(out.needs_layout);
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_composite);
    try testing.expect(out.needs_hit_rebuild);
    try testing.expect(!out.needs_interaction_update);
    try testing.expect(!out.needs_order_update);
}

test "outputFromInput: structure_changed → all major + order" {
    const out = outputFromInput(.{ .structure_changed = true });
    try testing.expect(out.needs_layout);
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_composite);
    try testing.expect(out.needs_hit_rebuild);
    try testing.expect(out.needs_order_update);
}

test "outputFromInput: interaction_changed → interaction only" {
    const out = outputFromInput(.{ .interaction_changed = true });
    try testing.expect(out.needs_interaction_update);
    try testing.expect(!out.needs_layout);
    try testing.expect(!out.needs_paint);
}

test "outputFromInput: combined inputs accumulate outputs" {
    const out = outputFromInput(.{ .style_changed = true, .interaction_changed = true });
    try testing.expect(out.needs_paint);
    try testing.expect(out.needs_interaction_update);
    try testing.expect(!out.needs_layout);
}

test "SubtreeFlags.fromOutput projection" {
    const out: OutputFlags = .{ .needs_paint = true, .needs_composite = true };
    const sub = SubtreeFlags.fromOutput(out);
    try testing.expect(sub.has_paint_dirty);
    try testing.expect(sub.has_composite_dirty);
    try testing.expect(!sub.has_layout_dirty);
}

test "DirtyFlags.clear / clearOutputs / clearSubtree" {
    var f: DirtyFlags = .{
        .input = .{ .style_changed = true },
        .output = .{ .needs_paint = true },
        .subtree = .{ .has_paint_dirty = true },
    };
    try testing.expect(!f.isClean());

    f.clearOutputs();
    try testing.expect(!f.output.needs_paint);
    try testing.expect(f.input.style_changed);
    try testing.expect(f.subtree.has_paint_dirty);

    f.clearSubtree();
    try testing.expect(!f.subtree.has_paint_dirty);

    f.clear();
    try testing.expect(f.isClean());
}

test "OutputFlags ALL has all six bits set" {
    const a = OutputFlags.ALL;
    try testing.expect(a.needs_layout);
    try testing.expect(a.needs_paint);
    try testing.expect(a.needs_composite);
    try testing.expect(a.needs_hit_rebuild);
    try testing.expect(a.needs_interaction_update);
    try testing.expect(a.needs_order_update);
}
