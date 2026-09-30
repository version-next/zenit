//! 同级绘制带（paint band）—— 渲染与命中测试共用的唯一事实来源。
//!
//! `z_index` 只表达"同一父节点下兄弟之间的绘制与命中顺序"（每个节点都是
//! 自己子节点的 stacking context），**不影响裁剪**：裁剪永远由祖先
//! `overflow_hidden` 链决定。要画到所有容器外只有结构性 portal 一条路
//! （`cx.ensurePopoverPortalRoot()` / OverlayStack）。
//!
//! 兄弟顺序 = 先按 `siblingZ`（负 z 钳到 0）稳定排序，再按
//! `regular → sticky → positive_z` 三个带依次遍历。等价于按
//! `siblingOrderKey` 的 (band, z) 字典序稳定排序。
//! render_engine（`sortSubtreeChildrenByZ` + `childPasses`）与 hit_runtime
//! （`paintOrderedChildren` + 三带遍历）都必须经由这里，否则 paint_order
//! 与像素会错位（方案 sticky-zindex-clip-decoupling-plan.md §5.2）。
//!
//! 与 node.zig 循环 import 取 Node 类型 —— 同 node_inherit.zig 等 sibling。

const node_mod = @import("node.zig");

const Node = node_mod.Node;

pub const PaintBand = enum(u2) {
    /// 普通流内兄弟（非 sticky、z<=0），按插入序。
    regular,
    /// z<=0 的 sticky 兄弟：画在同级 regular 之后，按插入序。
    sticky,
    /// z>0 的兄弟（含 z>0 的 sticky）：最后画，按 z 稳定升序。
    positive_z,
};

/// 三个带的遍历顺序。
pub const bands = [_]PaintBand{ .regular, .sticky, .positive_z };

pub fn paintBand(child: *const Node) PaintBand {
    if (child.style.z_index() > 0) return .positive_z;
    return if (child.style.position == .sticky) .sticky else .regular;
}

/// 同级排序用的 z：负值钳到 0（负 z 目前不起作用，保持插入序）。
pub fn siblingZ(node: *const Node) i16 {
    return @max(node.style.z_index(), 0);
}

pub const SiblingOrderKey = struct {
    band: PaintBand,
    z: i16,

    pub fn lessThan(lhs: SiblingOrderKey, rhs: SiblingOrderKey) bool {
        if (lhs.band != rhs.band) return @intFromEnum(lhs.band) < @intFromEnum(rhs.band);
        return lhs.z < rhs.z;
    }
};

/// 兄弟顺序键：(band, z) 字典序 + 稳定排序（同键保持插入序）。
pub fn siblingOrderKey(child: *const Node) SiblingOrderKey {
    return .{ .band = paintBand(child), .z = siblingZ(child) };
}
