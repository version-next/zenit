//! Cx 批量 quad 层：setBulkQuads*（带版本号的跳过重传）与挂靠节点、
//! 外部 clip rect 注入。存储与降级逻辑在 bulk_quad_layer.zig。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const BulkQuad = core.BulkQuad;
const Node = core.Node;
const bulk_quad_layer_mod = @import("bulk_quad_layer.zig");

/// 把 Cx 的六个只读输入打包成 BulkQuadLayer 要的 Host。
///
/// 析出到 core/bulk_quad_layer.zig 之后，那一层对 Cx 的全部依赖就是
/// 这六个（display_list / property_tree / scene_runtime / root /
/// frame_arena / allocator），不 import core.zig，也就没有反向依赖。
fn bulkQuadHost(self: *Cx) bulk_quad_layer_mod.Host {
    return .{
        .display_list = &self.display_list,
        .property_tree = &self.property_tree,
        .scene_runtime = &self.scene_runtime,
        .root = self.root,
        .frame_arena = self.frame_arena.allocator(),
        .allocator = self.allocator,
    };
}

/// 批量层的五个 Cx 字段（bulk_quads / _anchor / _overlay_z / _version /
/// _unchanged）按 BulkQuadLayer 的形状临时借视图。析出后 Cx 仍以
/// `bulk_quads_*` 之名持有这些状态（tests / devtools 直读），所以这里
/// 用指针重组而不是搬家。
pub fn bulkQuadLayer(self: *Cx) bulk_quad_layer_mod.BulkQuadLayer {
    return .{
        .quads = self.bulk_quads,
        .anchor = self.bulk_quads_anchor,
        .overlay_z = self.bulk_quads_overlay_z,
        .version = self.bulk_quads_version,
        .unchanged = self.bulk_quads_unchanged,
    };
}

/// 视图写回（append 不会改这五个状态，但 set* 路径要）。
pub fn storeBulkQuadLayer(self: *Cx, layer: bulk_quad_layer_mod.BulkQuadLayer) void {
    self.bulk_quads = layer.quads;
    self.bulk_quads_anchor = layer.anchor;
    self.bulk_quads_overlay_z = layer.overlay_z;
    self.bulk_quads_version = layer.version;
    self.bulk_quads_unchanged = layer.unchanged;
}

/// 把批量矩形层 lower 成 display item。与 Node 路径**同构**：
/// 背景走 `fill_rect`、描边走 `stroke_rect`，参数逐项对应，
/// 因此同样的几何/颜色/圆角/描边宽度产出逐位相同的像素。
///
/// 实现在 core/bulk_quad_layer.zig（三级插入点定位 / z 归并 / lower 的
/// 单元测试也在那边）；这里只是把 Host 打包后委托。
pub fn appendBulkQuads(self: *Cx) !void {
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    try layer.append(bulkQuadHost(self));
}

pub fn setBulkQuads(self: *Cx, anchor: ?*Node, quads: []const BulkQuad) !void {
    return self.setBulkQuadsEx(anchor, quads, null);
}

pub fn setBulkQuadsVersioned(
    self: *Cx,
    anchor: ?*Node,
    quads: []const BulkQuad,
    overlay_z_threshold: ?i16,
    version: ?u64,
) !void {
    // 版本号判定（unchanged / version 的三态语义）在 bulk_quad_layer.zig；
    // 这里借视图跑完再写回，Cx 字段名保持不变（tests / devtools 直读）。
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    return layer.setVersioned(bulkQuadHost(self), anchor, quads, overlay_z_threshold, version);
}

pub fn setBulkQuadsEx(
    self: *Cx,
    anchor: ?*Node,
    quads: []const BulkQuad,
    overlay_z_threshold: ?i16,
) !void {
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    return layer.set(bulkQuadHost(self), anchor, quads, overlay_z_threshold);
}

pub fn setNodeExternalClipRect(self: *Cx, node_id: u32, rect: ?[4]f32) void {
    if (rect) |r| {
        const gop = self.external_clip_rects.getOrPut(self.allocator, node_id) catch return;
        if (gop.found_existing and std.mem.eql(f32, &gop.value_ptr.*, &r)) return;
        gop.value_ptr.* = r;
    } else {
        if (!self.external_clip_rects.remove(node_id)) return;
    }
    self.requestRedraw();
}
