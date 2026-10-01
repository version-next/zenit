//! node_layout_output, v0.10 §L: NodeLayoutOutput 及子 struct 的独立定义。
//!
//! 从 node.zig 抽出，让 node.zig 与 layout_output_table.zig 都能引用而不
//! 形成 import 环（types.zig 不可承载 LayoutArtifacts，因 text_layout.zig
//! 已 import types.zig，反向会成环）。本模块只依赖 types.zig + text_layout.zig，
//! 两者均不 import 本模块，无环。

const types = @import("types.zig");
const text_layout_mod = @import("text_layout.zig");

const PathGeometry = types.PathGeometry;
const ComputedRect = types.ComputedRect;
const Color = types.Color;

/// 填充/clip 用的 path geometries（path + custom_clip）。
/// ⚠ path / custom_clip 持 clonePathGeometry 堆分配，owner 负责 freePathGeometry。
pub const NodeGeometries = struct {
    /// 用于 SVG <path> 渲染等矢量路径
    path: ?PathGeometry = null,
    /// 用户提供的自定义 clip mask（与 style.clip_shape 独立）
    custom_clip: ?PathGeometry = null,
};

/// 矢量描边（与 fill.path 独立，可同时存在）。geometry 持堆分配。
pub const NodeStroke = struct {
    geometry: ?PathGeometry = null,
    color: Color = Color.rgba(0, 0, 0, 255),
    width: f32 = 1.0,
    line_join: types.LineJoin = .miter,
};

pub const NodeVector = struct {
    /// 填充/clip 用的 path geometries（path + custom_clip）
    fill: NodeGeometries = .{},
    /// 矢量描边（与 fill.path 独立，可同时存在）
    stroke: NodeStroke = .{},
};

pub const LayoutArtifacts = struct {
    /// 子节点包围盒（相对于自身 rect，hitTest 剪枝用）
    /// layout 完成后计算，为 null 表示未计算或无子节点
    children_bbox: ?ComputedRect = null,
    /// 文本折行缓存 (wrap != .none 时由布局阶段填充)
    text_layout: ?text_layout_mod.TextLayout = null,
};

pub const NodeLayoutOutput = struct {
    vector: NodeVector = .{},
    artifacts: LayoutArtifacts = .{},
};
