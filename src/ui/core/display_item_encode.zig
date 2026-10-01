//! DisplayItem -> GpuDraw direct encoder
//!
//! DisplayItem -> GpuDraw 直译路径。
//! encodeDisplayItem 把单个 DisplayItem 直接产出 GpuDraw（一对一或一对多）。
//!
//! Batcher：encodeStream 顺序处理 DisplayItem 序列，输出 GpuDraw 序列；
//! 相邻可合并的 draw（同 pipeline + 同 scissor + 同 blend + 同 layer + 兼容
//! texture）合并为单个 batch（vbo 范围扩展，instance count++）。
//!
//! 当前实现：纯 CPU IR 转换，不真分配 GPU buffer（那是 backend 职责）。
//! 输出 GpuDraw 的 vbo/ibo/uniforms 字段填 placeholder NONE；调用方在
//! 真 backend encode 时填充真 buffer range。

const std = @import("std");
const testing = std.testing;
const paint_table_mod = @import("paint_table.zig");
const gpu_draw_mod = @import("gpu_draw.zig");

pub const DisplayItem = paint_table_mod.DisplayItem;
pub const DisplayItemKind = paint_table_mod.DisplayItemKind;
pub const GpuDraw = gpu_draw_mod.GpuDraw;
pub const PipelineId = gpu_draw_mod.PipelineId;
pub const BlendMode = gpu_draw_mod.BlendMode;

/// DisplayItemKind -> PipelineId 映射。每种 kind 对应一个固定 pipeline；
/// backend 在初始化时注册这些 pipeline 进 table，PipelineId 是 1-based。
pub fn pipelineForKind(kind: DisplayItemKind) PipelineId {
    return switch (kind) {
        .none => 0,
        .rect => 1,
        .text => 2,
        .image => 3,
        .path => 4,
        .shadow => 5,
        .gradient => 6,
        .control => 0, // effect/clip token 不走 GPU pipeline
    };
}

/// 单个 DisplayItem 直译成一个 GpuDraw（不做合并；合并由 encodeStream 负责）
pub fn encodeOne(item: DisplayItem, layer_id_raw: u32) GpuDraw {
    return GpuDraw{
        .pipeline = pipelineForKind(item.kind),
        .scissor = 0,
        .blend = if (item.kind == .text or item.kind == .image) .alpha else .none,
        .instanced = false,
        .layer_id_raw = layer_id_raw,
        .vbo = .NONE,
        .ibo = .NONE,
        .uniforms = .NONE,
        .texture0 = if (item.kind == .image or item.kind == .text)
            @truncate(item.resource_handle)
        else
            0xFFFFFFFF,
        .texture1 = 0xFFFFFFFF,
        .instance_count = 1,
    };
}

/// 批量编码：DisplayItem 序列 -> GpuDraw 序列，相邻可合并的合到 instance_count++。
/// 返回写入 out 的 GpuDraw 数量。out 长度需 >= items.len。
pub fn encodeStream(
    items: []const DisplayItem,
    layer_id_raw: u32,
    out: []GpuDraw,
) usize {
    if (items.len == 0) return 0;
    std.debug.assert(out.len >= items.len);

    var write: usize = 0;
    var current = encodeOne(items[0], layer_id_raw);

    for (items[1..]) |item| {
        const candidate = encodeOne(item, layer_id_raw);
        if (current.canBatchWith(candidate)) {
            // 合并：instance_count++（真实 vbo 合并由 backend encode 处理）
            current.instance_count += 1;
        } else {
            out[write] = current;
            write += 1;
            current = candidate;
        }
    }
    out[write] = current;
    write += 1;
    return write;
}

/// 统计：相邻可合并的连续 run 长度（用于 batcher 效果度量）。
pub fn maxBatchableRun(items: []const DisplayItem, layer_id_raw: u32) u32 {
    if (items.len == 0) return 0;
    var max_run: u32 = 1;
    var cur_run: u32 = 1;
    var prev = encodeOne(items[0], layer_id_raw);
    for (items[1..]) |item| {
        const cand = encodeOne(item, layer_id_raw);
        if (prev.canBatchWith(cand)) {
            cur_run += 1;
            if (cur_run > max_run) max_run = cur_run;
        } else {
            cur_run = 1;
            prev = cand;
        }
    }
    return max_run;
}

// ============================================================================
// Tests
// ============================================================================

test "pipelineForKind: stable ids" {
    try testing.expectEqual(@as(PipelineId, 0), pipelineForKind(.none));
    try testing.expectEqual(@as(PipelineId, 1), pipelineForKind(.rect));
    try testing.expectEqual(@as(PipelineId, 2), pipelineForKind(.text));
}

test "encodeOne: rect → no-blend, no-texture" {
    const item: DisplayItem = .{ .kind = .rect };
    const draw = encodeOne(item, 0);
    try testing.expectEqual(@as(PipelineId, 1), draw.pipeline);
    try testing.expectEqual(BlendMode.none, draw.blend);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), draw.texture0);
}

test "encodeOne: text → alpha blend, texture0 from resource_handle" {
    const item: DisplayItem = .{ .kind = .text, .resource_handle = 0xCAFE };
    const draw = encodeOne(item, 0);
    try testing.expectEqual(@as(PipelineId, 2), draw.pipeline);
    try testing.expectEqual(BlendMode.alpha, draw.blend);
    try testing.expectEqual(@as(u32, 0xCAFE), draw.texture0);
}

test "encodeStream: 3 同质 rect → 1 batched draw with instance_count=3" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    var out: [3]GpuDraw = undefined;
    const written = encodeStream(&items, 7, &out);
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u32, 3), out[0].instance_count);
    try testing.expectEqual(@as(u32, 7), out[0].layer_id_raw);
}

test "encodeStream: rect + text + rect → 3 separate draws (different pipeline)" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .text },
        .{ .kind = .rect },
    };
    var out: [3]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 3), written);
}

test "encodeStream: 5 rects + 3 texts + 2 rects → 3 batches (5,3,2)" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .text, .resource_handle = 1 },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    var out: [10]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(@as(u32, 5), out[0].instance_count);
    try testing.expectEqual(@as(u32, 3), out[1].instance_count);
    try testing.expectEqual(@as(u32, 2), out[2].instance_count);
}

test "encodeStream: text with different resource_handle → 不合并" {
    const items = [_]DisplayItem{
        .{ .kind = .text, .resource_handle = 100 },
        .{ .kind = .text, .resource_handle = 200 },
    };
    var out: [2]GpuDraw = undefined;
    const written = encodeStream(&items, 0, &out);
    try testing.expectEqual(@as(usize, 2), written);
}

test "maxBatchableRun: 5 同质 rect → 5" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
        .{ .kind = .rect },
    };
    try testing.expectEqual(@as(u32, 5), maxBatchableRun(&items, 0));
}

test "maxBatchableRun: 交替 rect/text → 1" {
    const items = [_]DisplayItem{
        .{ .kind = .rect },
        .{ .kind = .text },
        .{ .kind = .rect },
        .{ .kind = .text },
    };
    try testing.expectEqual(@as(u32, 1), maxBatchableRun(&items, 0));
}

test "encodeStream: empty input → 0 output" {
    const items: []const DisplayItem = &.{};
    var out: [1]GpuDraw = undefined;
    const written = encodeStream(items, 0, &out);
    try testing.expectEqual(@as(usize, 0), written);
}
