/// Metal CommandEncoder 实现
///
/// 提供高层命令编码 API，封装底层 Metal C API
/// 遵循 wgpu API 设计，实现状态机模式
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const resources = @import("resources.zig");
const bind_group_mod = @import("bind_group.zig");
const Queue = @import("queue.zig").Queue;

/// CommandEncoder - 命令编码器
///
/// 用于记录 GPU 命令，可以创建 RenderPass 和 ComputePass
pub const CommandEncoder = struct {
    raw: *mtl.MTLCommandBuffer,
    state: State = .initial,
    /// Monotonically increasing identity for the currently active child pass.
    ///
    /// Metal encoder objects are Objective-C objects whose addresses may be
    /// reused immediately after `endEncoding`.  A raw pointer in a copied
    /// RenderPass can therefore appear to become a *different encoder kind*.
    /// Every child pass carries this generation so stale/copied values are
    /// rejected in Zig before their raw pointer reaches Objective-C.
    next_pass_generation: u64 = 1,
    active_pass_generation: u64 = 0,
    /// 当前活跃 pass 的 +1 owned MTL*CommandEncoder。正常路径由 pass.end()
    /// endEncoding + release；错误路径（帧中途 try 失败）靠 deinit 兜底，
    /// 否则 encoder 泄漏且 command buffer 带着未 endEncoding 的 encoder 被释放。
    active_pass_raw: ?*anyopaque = null,

    const State = enum {
        initial, // 初始状态，可以开始编码
        render_pass, // 正在编码渲染通道
        compute_pass, // 正在编码计算通道
        blit, // 正在编码拷贝操作
        finished, // 已完成，不能再编码
    };

    fn activatePass(self: *CommandEncoder, state: State) u64 {
        std.debug.assert(self.state == .initial);
        const generation = self.next_pass_generation;
        self.next_pass_generation +%= 1;
        if (self.next_pass_generation == 0) self.next_pass_generation = 1;
        self.active_pass_generation = generation;
        self.state = state;
        return generation;
    }

    fn assertActivePass(self: *const CommandEncoder, state: State, generation: u64) void {
        if (self.state != state or self.active_pass_generation != generation) {
            @panic("stale or wrong-kind GPU pass used after its lifetime ended");
        }
    }

    fn passIsActive(self: *const CommandEncoder, state: State, generation: u64) bool {
        return self.state == state and self.active_pass_generation == generation;
    }

    fn closePass(self: *CommandEncoder, state: State, generation: u64) void {
        self.assertActivePass(state, generation);
        self.active_pass_raw = null;
        self.active_pass_generation = 0;
        self.state = .initial;
    }

    /// 从 Queue 创建 CommandEncoder
    pub fn init(queue: *Queue) !CommandEncoder {
        // ABI 合同：bridge 的 create/new/copy/nextDrawable 系列用 __bridge_retained
        // 返回 **+1 owned** 对象（metal_bridge.m:625），调用方直接接管所有权。
        // 这里**不能**再 retain —— 之前多 retain 一次而 deinit 只 release 一次，
        // 每帧净泄漏一个 MTLCommandBuffer。
        const cmd_buffer = mtl.metal_queue_command_buffer(queue.raw) orelse
            return error.CommandBufferCreationFailed;

        return CommandEncoder{
            .raw = cmd_buffer,
            .state = .initial,
        };
    }

    /// 开始渲染通道
    pub fn beginRenderPass(self: *CommandEncoder, desc: gpu.RenderPassDescriptor) !RenderPass {
        if (self.state != .initial) {
            return error.InvalidEncoderState;
        }

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 创建 Metal RenderPassDescriptor
        const pass_desc = mtl.metal_render_pass_descriptor_new();

        // 配置颜色附件
        for (desc.color_attachments, 0..) |attachment, i| {
            const color_attachment = mtl.metal_render_pass_get_color_attachment(pass_desc, @intCast(i));

            // 设置纹理
            mtl.metal_color_attachment_set_texture(color_attachment, attachment.view.raw);

            // 设置加载操作
            const load_action: mtl.MTLLoadAction = switch (attachment.load_op) {
                .load => .Load,
                .clear => .Clear,
                .dont_care => .DontCare,
            };
            mtl.metal_color_attachment_set_load_action(color_attachment, @intFromEnum(load_action));

            // 设置存储操作
            const store_action: mtl.MTLStoreAction = switch (attachment.store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_color_attachment_set_store_action(color_attachment, @intFromEnum(store_action));

            // 设置清除颜色
            if (attachment.load_op == .clear) {
                mtl.metal_color_attachment_set_clear_color(
                    color_attachment,
                    attachment.clear_value.r,
                    attachment.clear_value.g,
                    attachment.clear_value.b,
                    attachment.clear_value.a,
                );
            }

            // 设置 resolve target（MSAA）
            if (attachment.resolve_target) |resolve| {
                mtl.metal_color_attachment_set_resolve_texture(color_attachment, resolve.raw);
            }
        }

        // 配置深度/模板附件
        if (desc.depth_stencil_attachment) |ds_attachment| {
            const depth_attachment = mtl.metal_render_pass_get_depth_attachment(pass_desc);
            mtl.metal_depth_attachment_set_texture(depth_attachment, ds_attachment.view.raw);

            const depth_load: mtl.MTLLoadAction = switch (ds_attachment.depth_load_op) {
                .load => .Load,
                .clear => .Clear,
                .dont_care => .DontCare,
            };
            mtl.metal_depth_attachment_set_load_action(depth_attachment, @intFromEnum(depth_load));

            const depth_store: mtl.MTLStoreAction = switch (ds_attachment.depth_store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_depth_attachment_set_store_action(depth_attachment, @intFromEnum(depth_store));

            if (ds_attachment.depth_load_op == .clear) {
                mtl.metal_depth_attachment_set_clear_depth(depth_attachment, ds_attachment.depth_clear_value);
            }

            // Stencil
            const stencil_attachment = mtl.metal_render_pass_get_stencil_attachment(pass_desc);
            mtl.metal_stencil_attachment_set_texture(stencil_attachment, ds_attachment.view.raw);

            const stencil_load: mtl.MTLLoadAction = switch (ds_attachment.stencil_load_op) {
                .load => .Load,
                .clear => .Clear,
                .dont_care => .DontCare,
            };
            mtl.metal_stencil_attachment_set_load_action(stencil_attachment, @intFromEnum(stencil_load));

            const stencil_store: mtl.MTLStoreAction = switch (ds_attachment.stencil_store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_stencil_attachment_set_store_action(stencil_attachment, @intFromEnum(stencil_store));

            if (ds_attachment.stencil_load_op == .clear) {
                mtl.metal_stencil_attachment_set_clear_stencil(stencil_attachment, ds_attachment.stencil_clear_value);
            }
        }

        // 创建 Render Encoder。
        // ABI 合同：bridge 用 __bridge_retained 返回 +1 owned（metal_bridge.m:766），
        // 这里直接接管，**不再 retain** —— RenderPass.end() 只 release 一次，
        // 多retain 会让每个 render pass 泄漏一个 MTLRenderCommandEncoder。
        const encoder = mtl.metal_command_buffer_create_render_encoder(self.raw, pass_desc) orelse {
            mtl.release(pass_desc);
            return error.RenderEncoderCreationFailed;
        };

        // 释放 descriptor（encoder 已经持有引用）
        mtl.release(pass_desc);

        const generation = self.activatePass(.render_pass);
        self.active_pass_raw = @ptrCast(encoder);

        return RenderPass{
            .encoder = encoder,
            .command_encoder = self,
            .generation = generation,
        };
    }

    pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
        if (self.state != .initial) return error.InvalidEncoderState;
        const encoder = mtl.metal_command_buffer_create_blit_encoder(self.raw) orelse
            return error.BlitEncoderCreationFailed;
        const generation = self.activatePass(.blit);
        self.active_pass_raw = @ptrCast(encoder);
        return .{ .encoder = encoder, .command_encoder = self, .generation = generation };
    }

    /// 完成编码，返回 CommandBuffer
    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        if (self.state == .finished) return error.EncoderAlreadyFinished;
        if (self.state != .initial) return error.InvalidEncoderState;

        self.state = .finished;

        return CommandBuffer{
            .raw = self.raw,
        };
    }

    /// 销毁 CommandEncoder（如果未完成）
    pub fn deinit(self: *CommandEncoder) void {
        if (self.state == .finished) return;
        // 错误路径：仍有 pass 未 end（其 RenderPass/BlitPass 值被丢弃）。
        // 先 endEncoding + release 它，再释放 command buffer。
        if (self.active_pass_raw) |raw| {
            switch (self.state) {
                .render_pass => mtl.metal_render_encoder_end_encoding(@ptrCast(@alignCast(raw))),
                .blit => mtl.metal_blit_encoder_end_encoding(@ptrCast(@alignCast(raw))),
                .compute_pass => mtl.metal_compute_encoder_end_encoding(@ptrCast(@alignCast(raw))),
                .initial, .finished => {},
            }
            mtl.release(raw);
            self.active_pass_raw = null;
            self.active_pass_generation = 0;
            self.state = .initial;
        }
        mtl.release(self.raw);
    }
};

pub const BlitPass = struct {
    encoder: *mtl.MTLBlitCommandEncoder,
    command_encoder: *CommandEncoder,
    generation: u64,

    fn assertActive(self: *const BlitPass) void {
        self.command_encoder.assertActivePass(.blit, self.generation);
    }

    pub fn isActive(self: *const BlitPass) bool {
        return self.command_encoder.passIsActive(.blit, self.generation);
    }

    pub fn copyTextureRegion(
        self: *BlitPass,
        source: resources.TextureBinding,
        source_x: u32,
        source_y: u32,
        width: u32,
        height: u32,
        destination: resources.TextureBinding,
        destination_x: u32,
        destination_y: u32,
    ) !void {
        self.assertActive();
        if (width == 0 or height == 0 or
            source_x > source.width or width > source.width - source_x or
            source_y > source.height or height > source.height - source_y or
            destination_x > destination.width or width > destination.width - destination_x or
            destination_y > destination.height or height > destination.height - destination_y)
        {
            return error.InvalidTextureRegion;
        }
        mtl.metal_blit_encoder_copy_texture_region(
            self.encoder,
            source.raw,
            source_x,
            source_y,
            width,
            height,
            destination.raw,
            destination_x,
            destination_y,
        );
    }

    pub fn end(self: *BlitPass) void {
        self.assertActive();
        mtl.metal_blit_encoder_end_encoding(self.encoder);
        mtl.release(self.encoder);
        self.command_encoder.closePass(.blit, self.generation);
    }
};

/// RenderPass - 渲染通道
///
/// 用于记录渲染命令
pub const RenderPass = struct {
    encoder: *mtl.MTLRenderCommandEncoder,
    command_encoder: *CommandEncoder,
    generation: u64,

    fn assertActive(self: *const RenderPass) void {
        self.command_encoder.assertActivePass(.render_pass, self.generation);
    }

    pub fn isActive(self: *const RenderPass) bool {
        return self.command_encoder.passIsActive(.render_pass, self.generation);
    }

    /// 设置渲染管线
    pub fn setPipeline(self: *RenderPass, pipeline: *const RenderPipeline) void {
        self.assertActive();
        mtl.metal_render_encoder_set_render_pipeline_state(self.encoder, pipeline.raw);
    }

    /// 设置视口
    pub fn setViewport(
        self: *RenderPass,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        min_depth: f32,
        max_depth: f32,
    ) void {
        self.assertActive();
        mtl.metal_render_encoder_set_viewport(
            self.encoder,
            x,
            y,
            width,
            height,
            min_depth,
            max_depth,
        );
    }

    /// 设置裁剪矩形
    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, width: u32, height: u32) void {
        self.assertActive();
        mtl.metal_render_encoder_set_scissor_rect(self.encoder, x, y, width, height);
    }

    /// 设置顶点缓冲区
    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const resources.Buffer, offset: u64) void {
        self.assertActive();
        mtl.metal_render_encoder_set_vertex_buffer(self.encoder, buffer.raw, offset, slot);
    }

    /// 设置片段缓冲区
    pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const resources.Buffer, offset: u64) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_buffer(self.encoder, buffer.raw, offset, slot);
    }

    /// 设置片段纹理
    pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const resources.Texture) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture.raw, slot);
    }

    pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, texture: resources.TextureBinding) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture.raw, slot);
    }

    /// 设置片段纹理（原始 MTLTexture 指针）
    pub fn setFragmentTextureRaw(self: *RenderPass, slot: u32, texture: ?*mtl.MTLTexture) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture, slot);
    }

    /// 设置片段采样器（原始 MTLSamplerState 指针）
    pub fn setFragmentSamplerRaw(self: *RenderPass, slot: u32, sampler: ?*mtl.MTLSamplerState) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_sampler(self.encoder, sampler, slot);
    }

    /// Set a sampler through the backend-neutral resource wrapper.
    pub fn setFragmentSampler(self: *RenderPass, slot: u32, sampler: ?*const resources.Sampler) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_sampler(
            self.encoder,
            if (sampler) |value| value.raw else null,
            slot,
        );
    }

    /// 设置顶点字节数据（push constants）
    pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        mtl.metal_render_encoder_set_vertex_bytes(self.encoder, data.ptr, data.len, slot);
    }

    /// 设置片段字节数据（push constants）
    pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_bytes(self.encoder, data.ptr, data.len, slot);
    }

    /// 绘制基元
    pub fn draw(
        self: *RenderPass,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.assertActive();
        // 计数必须覆盖**两条** draw 路径。此前只有 drawIndexed 计数，
        // 而 UI 主路径（SDF/text/image/icon 实例化）走的正是这里的非索引
        // draw —— 于是 draw call 统计长期严重低估（审查报告 §4）。
        frame_draw_call_count += 1;
        if (instance_count == 1 and first_instance == 0) {
            mtl.metal_render_encoder_draw_primitives(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                first_vertex,
                vertex_count,
            );
        } else if (first_instance == 0) {
            mtl.metal_render_encoder_draw_primitives_instanced(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                first_vertex,
                vertex_count,
                instance_count,
            );
        } else {
            mtl.metal_render_encoder_draw_primitives_instanced_base_instance(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                first_vertex,
                vertex_count,
                instance_count,
                first_instance,
            );
        }
    }

    /// 全局 frame draw call 计数器（矩阵 #5 < 400）。
    /// FrameSync.beginFrame 处 reset；drawIndexed 调用时 +1（不分 instance count——
    /// 一次 drawIndexed* 调用 = 一次 draw call，与 instance 数无关）。
    pub var frame_draw_call_count: u32 = 0;

    /// 绘制索引基元
    pub fn drawIndexed(
        self: *RenderPass,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: i32,
        first_instance: u32,
        index_buffer: *const resources.Buffer,
        index_format: gpu.IndexFormat,
    ) void {
        self.assertActive();
        frame_draw_call_count += 1;
        const mtl_index_type: mtl.MTLIndexType = switch (index_format) {
            .uint16 => .UInt16,
            .uint32 => .UInt32,
        };

        const index_size: u64 = switch (index_format) {
            .uint16 => 2,
            .uint32 => 4,
        };

        const offset = first_index * index_size;

        if (instance_count == 1 and first_instance == 0 and base_vertex == 0) {
            mtl.metal_render_encoder_draw_indexed_primitives(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @intFromEnum(mtl_index_type),
                index_buffer.raw,
                offset,
            );
        } else if (first_instance == 0 and base_vertex == 0) {
            mtl.metal_render_encoder_draw_indexed_primitives_instanced(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @intFromEnum(mtl_index_type),
                index_buffer.raw,
                offset,
                instance_count,
            );
        } else {
            mtl.metal_render_encoder_draw_indexed_primitives_full(
                self.encoder,
                @intFromEnum(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @intFromEnum(mtl_index_type),
                index_buffer.raw,
                offset,
                instance_count,
                @intCast(@as(i64, base_vertex)),
                first_instance,
            );
        }
    }

    /// 设置 BindGroup
    ///
    /// 将 BindGroup 中的资源绑定到 Metal encoder。
    /// group_index 用于偏移 buffer slot，避免多个 BindGroup 冲突。
    pub fn setBindGroup(self: *RenderPass, group_index: u32, bind_group: *const bind_group_mod.BindGroup) void {
        self.assertActive();
        bind_group.applyToRenderEncoder(self.encoder, group_index);
    }

    /// 结束渲染通道
    pub fn end(self: *RenderPass) void {
        self.assertActive();
        mtl.metal_render_encoder_end_encoding(self.encoder);
        mtl.release(self.encoder);
        self.command_encoder.closePass(.render_pass, self.generation);
    }
};

/// ComputePass - 计算通道
///
/// 用于记录计算命令
pub const ComputePass = struct {
    encoder: *mtl.MTLComputeCommandEncoder,
    command_encoder: *CommandEncoder,

    /// 设置计算管线
    pub fn setPipeline(self: *ComputePass, pipeline: *const ComputePipeline) void {
        mtl.metal_compute_encoder_set_compute_pipeline_state(self.encoder, pipeline.raw);
    }

    /// 分发计算
    pub fn dispatch(
        self: *ComputePass,
        threadgroups: [3]u32,
        threads_per_group: [3]u32,
    ) void {
        mtl.metal_compute_encoder_dispatch_threadgroups(
            self.encoder,
            threadgroups[0],
            threadgroups[1],
            threadgroups[2],
            threads_per_group[0],
            threads_per_group[1],
            threads_per_group[2],
        );
    }

    /// 设置 BindGroup
    pub fn setBindGroup(self: *ComputePass, group_index: u32, bind_group: *const bind_group_mod.BindGroup) void {
        bind_group.applyToComputeEncoder(self.encoder, group_index);
    }

    /// 结束计算通道
    pub fn end(self: *ComputePass) void {
        mtl.metal_compute_encoder_end_encoding(self.encoder);
        mtl.release(self.encoder);
        self.command_encoder.state = .initial;
    }
};

/// CommandBuffer - 已编码的命令缓冲区
///
/// 可以提交到 Queue 执行
pub const CommandBuffer = struct {
    raw: *mtl.MTLCommandBuffer,

    /// 进程级 command buffer 失败计数（诊断/soak 断言用）。
    pub var error_count: std.atomic.Value(u64) = .init(0);

    fn onCommandBufferError(context: ?*anyopaque, code: c_long, desc: [*:0]const u8) callconv(.c) void {
        _ = context;
        const n = CommandBuffer.error_count.fetchAdd(1, .monotonic);
        // 前几次全量报告，之后抽样 —— GPU fault 一旦发生往往逐帧复现，
        // 不能刷屏，但也绝不能静默（此前的行为：完全没人看 status）。
        if (n < 5 or n % 64 == 0) {
            std.log.err("[metal] command buffer failed (code={d}, total={d}): {s}", .{ code, n + 1, desc });
        }
    }

    /// 提交命令。附带错误观测：GPU fault / hang / 设备移除不再静默。
    pub fn submit(self: *CommandBuffer) void {
        mtl.metal_command_buffer_notify_error(self.raw, null, &onCommandBufferError);
        mtl.metal_command_buffer_commit(self.raw);
    }

    /// Retained copy for cross-frame completion/timestamp observation.
    pub fn retained(self: *const CommandBuffer) CommandBuffer {
        return .{ .raw = mtl.retain(self.raw) };
    }

    pub fn waitUntilCompleted(self: *const CommandBuffer) void {
        mtl.metal_command_buffer_wait_until_completed(self.raw);
    }

    /// 非阻塞查询本 buffer 是否已到终态。让调用方可以把"完成后才能读的
    /// 数据"做成机会式读取，而不必阻塞主线程。
    pub fn isCompleted(self: *const CommandBuffer) bool {
        return mtl.metal_command_buffer_is_completed(self.raw);
    }

    /// Available after completion. Null means the backend did not publish a
    /// valid timestamp interval for this submission.
    pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
        const start = mtl.metal_command_buffer_gpu_start_time(self.raw);
        const end = mtl.metal_command_buffer_gpu_end_time(self.raw);
        if (end <= start) return null;
        return @intFromFloat((end - start) * std.time.us_per_s);
    }

    /// 呈现 drawable
    pub fn presentDrawable(self: *CommandBuffer, drawable: *mtl.CAMetalDrawable) void {
        mtl.metal_command_buffer_present_drawable(self.raw, drawable);
    }

    /// 销毁
    pub fn deinit(self: *CommandBuffer) void {
        mtl.release(self.raw);
    }
};

// 使用 pipeline.zig 中的定义
const pipeline_mod = @import("pipeline.zig");
pub const RenderPipeline = pipeline_mod.RenderPipeline;

/// ComputePipeline - 计算管线（占位，后续实现）
pub const ComputePipeline = struct {
    raw: *mtl.MTLComputePipelineState,

    pub fn deinit(self: *ComputePipeline) void {
        mtl.release(self.raw);
    }
};
