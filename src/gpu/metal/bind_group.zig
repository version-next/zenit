/// Metal BindGroup 实现
///
/// Metal 没有原生 BindGroup 概念。本模块通过逻辑绑定表实现 wgpu 风格的
/// BindGroup/BindGroupLayout/PipelineLayout API。
///
/// 在 RenderPass/ComputePass 中 setBindGroup 时，展开为对应的
/// setVertexBuffer / setFragmentBuffer / setFragmentTexture 等 Metal 调用。
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");

/// BindGroupLayout — 描述一组绑定的布局
///
/// 存储每个 binding slot 的类型和可见性信息，用于验证和 pipeline 创建。
pub const BindGroupLayout = struct {
    entries: []const gpu.BindGroupLayoutEntry,
    label: ?[]const u8 = null,

    /// 从描述符创建 BindGroupLayout
    pub fn init(allocator: std.mem.Allocator, desc: gpu.BindGroupLayoutDescriptor) !BindGroupLayout {
        const entries = try allocator.dupe(gpu.BindGroupLayoutEntry, desc.entries);
        return .{
            .entries = entries,
            .label = desc.label,
        };
    }

    pub fn deinit(self: *BindGroupLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

/// PipelineLayout — 组合多个 BindGroupLayout
pub const PipelineLayout = struct {
    bind_group_layouts: []const BindGroupLayout,
    label: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, desc: gpu.PipelineLayoutDescriptor) !PipelineLayout {
        const layouts = try allocator.dupe(BindGroupLayout, desc.bind_group_layouts);
        return .{
            .bind_group_layouts = layouts,
            .label = desc.label,
        };
    }

    pub fn deinit(self: *PipelineLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.bind_group_layouts);
    }
};

/// 绑定资源的具体引用 (运行时数据)
pub const BoundResource = union(enum) {
    buffer: struct {
        raw: *mtl.MTLBuffer,
        offset: u64,
        size: ?u64,
    },
    texture: struct {
        raw: *mtl.MTLTexture,
    },
    sampler: struct {
        raw: *mtl.MTLSamplerState,
    },
};

/// BindGroup — 一组已绑定的资源
///
/// 在 Metal 中，setBindGroup 会被展开为一系列 setVertexBuffer/setFragmentTexture 调用。
/// binding 号直接映射到 Metal 的 buffer/texture/sampler index。
pub const BindGroup = struct {
    layout: BindGroupLayout,
    bindings: []const Binding,

    pub const Binding = struct {
        slot: u32,
        visibility: gpu.ShaderStages,
        resource: BoundResource,
    };

    /// 从描述符创建 BindGroup
    pub fn init(allocator: std.mem.Allocator, desc: gpu.BindGroupDescriptor) !BindGroup {
        const layout = desc.layout;

        // Validate every buffer range before retaining anything, keeping the
        // failure path allocation- and ownership-neutral.
        for (desc.entries) |entry| switch (entry.resource) {
            .buffer => |buf| {
                if (buf.offset > buf.buffer.size) return error.InvalidBufferBinding;
                if (buf.size) |size| {
                    if (size == 0 or size > buf.buffer.size - buf.offset) {
                        return error.InvalidBufferBinding;
                    }
                }
            },
            else => {},
        };

        const bindings = try allocator.alloc(Binding, desc.entries.len);
        errdefer allocator.free(bindings);

        for (desc.entries, 0..) |entry, i| {
            // 从 layout 中查找 visibility
            const visibility = findVisibility(layout, entry.binding);

            bindings[i] = .{
                .slot = entry.binding,
                .visibility = visibility,
                .resource = switch (entry.resource) {
                    .buffer => |buf| .{
                        .buffer = .{
                            // A BindGroup owns references independently of the
                            // descriptor wrappers supplied by its caller.
                            .raw = mtl.retain(buf.buffer.raw),
                            .offset = buf.offset,
                            .size = buf.size,
                        },
                    },
                    .texture_view => |tv| .{ .texture = .{
                        .raw = mtl.retain(tv.raw),
                    } },
                    .sampler => |s| .{ .sampler = .{
                        .raw = mtl.retain(s.raw),
                    } },
                },
            };
        }

        return .{
            .layout = layout,
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *BindGroup, allocator: std.mem.Allocator) void {
        for (self.bindings) |binding| switch (binding.resource) {
            .buffer => |buf| mtl.release(buf.raw),
            .texture => |texture| mtl.release(texture.raw),
            .sampler => |sampler| mtl.release(sampler.raw),
        };
        allocator.free(self.bindings);
    }

    /// 将 BindGroup 应用到 Metal RenderEncoder
    ///
    /// group_index: BindGroup 在 PipelineLayout 中的序号，用于偏移 buffer slot
    /// 避免与其他 BindGroup 冲突。
    ///
    /// 偏移策略:
    ///   - buffer slot = group_index * MAX_BINDINGS_PER_GROUP + binding
    ///   - texture slot = binding (无偏移，Metal texture slots 独立于 buffer)
    ///   - sampler slot = binding (同上)
    pub fn applyToRenderEncoder(
        self: *const BindGroup,
        encoder: *mtl.MTLRenderCommandEncoder,
        group_index: u32,
    ) void {
        const buffer_offset = group_index * MAX_BINDINGS_PER_GROUP;

        for (self.bindings) |binding| {
            switch (binding.resource) {
                .buffer => |buf| {
                    const slot = buffer_offset + binding.slot;
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_buffer(
                            encoder,
                            buf.raw,
                            buf.offset,
                            slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_buffer(
                            encoder,
                            buf.raw,
                            buf.offset,
                            slot,
                        );
                    }
                },
                .texture => |tex| {
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_texture(
                            encoder,
                            tex.raw,
                            binding.slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_texture(
                            encoder,
                            tex.raw,
                            binding.slot,
                        );
                    }
                },
                .sampler => |smp| {
                    if (binding.visibility.vertex) {
                        mtl.metal_render_encoder_set_vertex_sampler(
                            encoder,
                            smp.raw,
                            binding.slot,
                        );
                    }
                    if (binding.visibility.fragment) {
                        mtl.metal_render_encoder_set_fragment_sampler(
                            encoder,
                            smp.raw,
                            binding.slot,
                        );
                    }
                },
            }
        }
    }

    /// 将 BindGroup 应用到 Metal ComputeEncoder
    pub fn applyToComputeEncoder(
        self: *const BindGroup,
        encoder: *mtl.MTLComputeCommandEncoder,
        group_index: u32,
    ) void {
        const buffer_offset = group_index * MAX_BINDINGS_PER_GROUP;

        for (self.bindings) |binding| {
            switch (binding.resource) {
                .buffer => |buf| {
                    mtl.metal_compute_encoder_set_buffer(
                        encoder,
                        buf.raw,
                        buf.offset,
                        buffer_offset + binding.slot,
                    );
                },
                .texture => |tex| {
                    mtl.metal_compute_encoder_set_texture(
                        encoder,
                        tex.raw,
                        binding.slot,
                    );
                },
                .sampler => {
                    // Metal compute encoder 没有 setSampler，
                    // sampler 通常通过 argument buffer 传入
                },
            }
        }
    }
};

/// 每个 BindGroup 的最大 binding 数（用于 buffer slot 偏移）
const MAX_BINDINGS_PER_GROUP: u32 = 16;

/// 在 layout 中查找指定 binding 的 visibility
fn findVisibility(layout: BindGroupLayout, binding: u32) gpu.ShaderStages {
    for (layout.entries) |entry| {
        if (entry.binding == binding) return entry.visibility;
    }
    // 默认: vertex + fragment
    return .{ .vertex = true, .fragment = true };
}

// ============================================================================
// 测试
// ============================================================================

test "BindGroupLayout: init and deinit" {
    const allocator = std.testing.allocator;

    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .ty = .{ .buffer = .{ .ty = .uniform } },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .ty = .{ .texture = .{} },
        },
    };

    var layout = try BindGroupLayout.init(allocator, .{
        .entries = &entries,
    });
    defer layout.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), layout.entries.len);
    try std.testing.expectEqual(@as(u32, 0), layout.entries[0].binding);
    try std.testing.expectEqual(@as(u32, 1), layout.entries[1].binding);
}

test "PipelineLayout: init and deinit" {
    const allocator = std.testing.allocator;

    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .ty = .{ .buffer = .{} },
        },
    };

    var bg_layout = try BindGroupLayout.init(allocator, .{
        .entries = &entries,
    });
    defer bg_layout.deinit(allocator);

    const layouts = [_]BindGroupLayout{bg_layout};
    var pipeline_layout = try PipelineLayout.init(allocator, .{
        .bind_group_layouts = &layouts,
    });
    defer pipeline_layout.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), pipeline_layout.bind_group_layouts.len);
}

test "findVisibility: returns correct stages" {
    const entries = [_]gpu.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .ty = .{ .buffer = .{} },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .ty = .{ .texture = .{} },
        },
    };

    const layout = BindGroupLayout{
        .entries = &entries,
    };

    const vis0 = findVisibility(layout, 0);
    try std.testing.expect(vis0.vertex);
    try std.testing.expect(!vis0.fragment);

    const vis1 = findVisibility(layout, 1);
    try std.testing.expect(!vis1.vertex);
    try std.testing.expect(vis1.fragment);

    // 不存在的 binding 返回默认
    const vis_default = findVisibility(layout, 99);
    try std.testing.expect(vis_default.vertex);
    try std.testing.expect(vis_default.fragment);
}
