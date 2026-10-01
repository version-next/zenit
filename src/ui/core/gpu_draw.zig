//! GpuDraw IR, Phase 5 GPU encoder 输出格式
//!
//! 当前 zenit 渲染流水线：
//!   DisplayItem (paint pass 唯一 IR) -> GpuDraw -> GPU command buffer
//!
//! GpuDraw 是渲染流水线的最后 CPU IR：包含一个 GPU draw 所需的全部状态引用。
//! 故意做成 packed/紧凑结构以利于 batcher 合并相邻 draw。
//!
//! 设计参照：
//! - Skia DisplayList -> backend draw call
//! - Impeller Entity -> GPU command
//! - WebRender Primitives -> Renderer batches
//!
//! 历史债避免：
//! - **不**让 GpuDraw 持任何 owned 资源指针，所有 GPU 资源走 ResourcePool
//!   handle (u64)；GpuDraw 只引用 handle index
//! - **不**在 GpuDraw 内嵌 GPU API 状态对象（pipeline state object 等）；走
//!   小整型 id，由 backend table 解析
//! - **不**让 GpuDraw 跨帧持久，每帧重新生成 draw stream（layer_tree 跨帧
//!   持久但 GpuDraw stream 是 frame-transient）

const std = @import("std");
const testing = std.testing;

/// 渲染管线类型 id（pipeline state object 编号；后端通过 table 解析）。
/// 0 = 无效；1.. = 有效 pipeline。
pub const PipelineId = u16;

/// GPU 资源 handle（来自 ResourcePool；u32 截取 ResourceHandle 低位即可）。
/// MAX = 无引用。
pub const GpuRangeHandle = u32;

/// Buffer 范围引用（vbo / ibo / uniform）
pub const BufferRange = packed struct(u64) {
    /// 资源 handle（来自 ResourcePool；low u24）
    handle: u24,
    /// 起始 offset（in elements）
    offset: u20 = 0,
    /// 元素数量
    count: u20 = 0,

    pub const NONE: BufferRange = .{ .handle = 0xFFFFFF };

    pub fn isNone(self: BufferRange) bool {
        return self.handle == 0xFFFFFF;
    }
};

/// 混合模式（GPU pipeline 状态的一部分；分离出来便于 batcher 决定是否合并）
pub const BlendMode = enum(u8) {
    none,
    alpha,
    additive,
    multiply,
    screen,
    overlay,
    pre_alpha,
};

/// Scissor rect id（0 = 无 scissor；> 0 引用 frame scissor table）
pub const ScissorId = u16;

/// LayerId（与 layer_tree.LayerId 同概念，u32 packed；用 u32 raw 避免循环 import）
pub const LayerIdRaw = u32;

/// 单个 GPU draw 调用的完整状态。
/// **64 字节对齐** 让 batcher 顺序扫描时 cache-line 友好（一个 draw = 1 个 cache line）。
pub const GpuDraw = extern struct {
    /// 渲染管线（决定 shader + 顶点格式）
    pipeline: PipelineId = 0,
    /// scissor rect id
    scissor: ScissorId = 0,
    /// 混合模式
    blend: BlendMode = .none,
    /// 是否 instanced draw
    instanced: bool = false,
    _pad0: [2]u8 = .{ 0, 0 },
    /// 该 draw 所在的 layer
    layer_id_raw: LayerIdRaw = 0,
    /// 顶点 buffer 范围
    vbo: BufferRange = BufferRange.NONE,
    /// 索引 buffer 范围（NONE = non-indexed draw）
    ibo: BufferRange = BufferRange.NONE,
    /// uniform buffer 范围
    uniforms: BufferRange = BufferRange.NONE,
    /// 主 texture handle（NONE = 无）
    texture0: GpuRangeHandle = 0xFFFFFFFF,
    /// 副 texture handle（NONE = 无）
    texture1: GpuRangeHandle = 0xFFFFFFFF,
    /// instance count（instanced draw 用）
    instance_count: u32 = 1,

    /// 判断两个 draw 是否可以合并到同一 batch
    /// 条件：相同 pipeline + blend + scissor + 同 layer + 都未 instanced
    /// + 无 texture 或同 texture（简化条件）
    pub fn canBatchWith(a: GpuDraw, b: GpuDraw) bool {
        if (a.pipeline != b.pipeline) return false;
        if (a.blend != b.blend) return false;
        if (a.scissor != b.scissor) return false;
        if (a.layer_id_raw != b.layer_id_raw) return false;
        if (a.instanced or b.instanced) return false;
        if (a.texture0 != b.texture0) return false;
        if (a.texture1 != b.texture1) return false;
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BufferRange is exactly 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(BufferRange));
}

test "BufferRange NONE detection" {
    const none = BufferRange.NONE;
    try testing.expect(none.isNone());

    const real: BufferRange = .{ .handle = 5, .offset = 100, .count = 24 };
    try testing.expect(!real.isNone());
}

test "GpuDraw canBatchWith: same pipeline + same state → true" {
    const a = GpuDraw{ .pipeline = 1, .blend = .alpha, .scissor = 2, .layer_id_raw = 5 };
    const b = GpuDraw{ .pipeline = 1, .blend = .alpha, .scissor = 2, .layer_id_raw = 5 };
    try testing.expect(a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different pipeline → false" {
    const a = GpuDraw{ .pipeline = 1 };
    const b = GpuDraw{ .pipeline = 2 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different blend → false" {
    const a = GpuDraw{ .pipeline = 1, .blend = .alpha };
    const b = GpuDraw{ .pipeline = 1, .blend = .multiply };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different scissor → false" {
    const a = GpuDraw{ .pipeline = 1, .scissor = 2 };
    const b = GpuDraw{ .pipeline = 1, .scissor = 3 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different layer → false" {
    const a = GpuDraw{ .pipeline = 1, .layer_id_raw = 5 };
    const b = GpuDraw{ .pipeline = 1, .layer_id_raw = 6 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: different texture → false" {
    const a = GpuDraw{ .pipeline = 1, .texture0 = 100 };
    const b = GpuDraw{ .pipeline = 1, .texture0 = 200 };
    try testing.expect(!a.canBatchWith(b));
}

test "GpuDraw canBatchWith: instanced → false" {
    const a = GpuDraw{ .pipeline = 1, .instanced = true };
    const b = GpuDraw{ .pipeline = 1 };
    try testing.expect(!a.canBatchWith(b));
}
