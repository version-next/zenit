//! 可继承文本属性的 resolve —— 从 node.zig 析出（2026-08-05），
//! 延续 v0.12 god-object split 的 node_* sibling 约定。
//!
//! 这一簇是 node.zig 里唯一沿 **parent 链向上遍历** 的读路径，语义对标
//! CSS inherited properties：每个属性取祖先链上最近的一个非 null 值
//! （就近覆盖），节点自己的值优先级最高。与 node.zig 其余方法的区别很干净：
//! 那些要么只读写 self、要么向**下**改子树（mark*Dirty 传播），
//! 只有这里是向上读且完全无副作用 —— 不分配、不标脏、`*const Node` 入参。
//!
//! 一次遍历同时解三个属性（而不是三次独立遍历）是刻意的：文本节点每帧
//! resolve，深树下三趟 parent 链是纯浪费；isComplete 提前退出让常见的
//! “父节点就定义了全部三项”只走一层。
//!
//! 与 node.zig 循环 import 取 Node 类型 —— Zig 惰性求值，node_dirty.zig 等
//! 多个 sibling 早已这样做，成立。

const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;

/// 可继承文本属性快照
pub const InheritedTextStyle = struct {
    color: ?types.Color = null,
    font_size: ?f32 = null,
    font_weight: ?u16 = null,

    /// 是否所有字段都已找到（可提前退出遍历）
    pub fn isComplete(self: InheritedTextStyle) bool {
        return self.color != null and self.font_size != null and self.font_weight != null;
    }
};

/// 一次遍历 parent 链，同时查找 text_color / text_font_size / text_font_weight。
/// 每个属性取最近的非 null 值（就近覆盖，类似 CSS inherited properties）。
pub fn resolveInheritedTextStyle(self: *const Node) InheritedTextStyle {
    var result = InheritedTextStyle{};
    var cur: ?*const Node = self;
    while (cur) |n| {
        if (n.style.ext) |ext| {
            if (result.color == null and ext.text_color != null) result.color = ext.text_color;
            if (result.font_size == null and ext.text_font_size != null) result.font_size = ext.text_font_size;
            if (result.font_weight == null and ext.text_font_weight != null) result.font_weight = ext.text_font_weight;
            if (result.isComplete()) break;
        }
        cur = n.parent;
    }
    return result;
}

/// 向上查找最近的非 null text_color（便利方法）
pub fn resolveTextColor(self: *const Node) ?types.Color {
    return resolveInheritedTextStyle(self).color;
}

/// 向上查找最近的非 null text_font_size（便利方法）
pub fn resolveTextFontSize(self: *const Node) ?f32 {
    return resolveInheritedTextStyle(self).font_size;
}

/// 向上查找最近的非 null text_font_weight（便利方法）
pub fn resolveTextFontWeight(self: *const Node) ?u16 {
    return resolveInheritedTextStyle(self).font_weight;
}
