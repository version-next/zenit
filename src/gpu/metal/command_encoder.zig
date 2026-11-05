/// Metal CommandEncoder implementation.
///
/// Provides high-level command encoding API, wraps Metal C API.
/// Follows wgpu API design, implements state machine pattern.
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const resources = @import("resources.zig");
const bind_group_mod = @import("bind_group.zig");
const Queue = @import("queue.zig").Queue;

/// CommandEncoder - command encoder.
///
/// Records GPU commands, can create RenderPass and ComputePass.
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
    /// Current active pass's +1 owned MTL*CommandEncoder. Normal path: pass.end()
    /// endEncoding + release; error path (try fails mid-frame): deinit catches, else encoder
    /// leaks and command buffer released with un-endEncoded encoder.
    active_pass_raw: ?*anyopaque = null,

    const State = enum {
        initial, // Initial state, can start encoding.
        render_pass, // Encoding render pass.
        compute_pass, // Encoding compute pass.
        blit, // Encoding blit operation.
        finished, // Finished, can't encode.
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

    /// Create CommandEncoder from Queue.
    pub fn init(queue: *Queue) !CommandEncoder {
        // ABI contract: bridge's create/new/copy/nextDrawable series use __bridge_retained to
        // return
        // **+1 owned** object (metal_bridge.m:625), caller takes ownership directly. **Can't**
        // retain
        // again here; extra retain once but deinit releases once leaks MTLCommandBuffer per frame.
        const cmd_buffer = mtl.metal_queue_command_buffer(queue.raw) orelse
            return error.CommandBufferCreationFailed;

        return CommandEncoder{
            .raw = cmd_buffer,
            .state = .initial,
        };
    }

    /// Begin render pass.
    pub fn beginRenderPass(self: *CommandEncoder, desc: gpu.RenderPassDescriptor) !RenderPass {
        if (self.state != .initial) {
            return error.InvalidEncoderState;
        }

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // Create Metal RenderPassDescriptor.
        const pass_desc = mtl.metal_render_pass_descriptor_new();

        // Configure color attachment.
        for (desc.color_attachments, 0..) |attachment, i| {
            const color_attachment = mtl.metal_render_pass_get_color_attachment(pass_desc, @intCast(i));

            // Set texture.
            mtl.metal_color_attachment_set_texture(color_attachment, attachment.view.raw);

            // Set load action.
            const load_action: mtl.MTLLoadAction = switch (attachment.load_op) {
                .load => .Load,
                .clear => .Clear,
                .dont_care => .DontCare,
            };
            mtl.metal_color_attachment_set_load_action(color_attachment, @backingInt(load_action));

            // Set store action.
            const store_action: mtl.MTLStoreAction = switch (attachment.store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_color_attachment_set_store_action(color_attachment, @backingInt(store_action));

            // Set clear color.
            if (attachment.load_op == .clear) {
                mtl.metal_color_attachment_set_clear_color(
                    color_attachment,
                    attachment.clear_value.r,
                    attachment.clear_value.g,
                    attachment.clear_value.b,
                    attachment.clear_value.a,
                );
            }

            // Set resolve target (MSAA).
            if (attachment.resolve_target) |resolve| {
                mtl.metal_color_attachment_set_resolve_texture(color_attachment, resolve.raw);
            }
        }

        // Configure depth/stencil attachment.
        if (desc.depth_stencil_attachment) |ds_attachment| {
            const depth_attachment = mtl.metal_render_pass_get_depth_attachment(pass_desc);
            mtl.metal_depth_attachment_set_texture(depth_attachment, ds_attachment.view.raw);

            const depth_load: mtl.MTLLoadAction = switch (ds_attachment.depth_load_op) {
                .load => .Load,
                .clear => .Clear,
                .dont_care => .DontCare,
            };
            mtl.metal_depth_attachment_set_load_action(depth_attachment, @backingInt(depth_load));

            const depth_store: mtl.MTLStoreAction = switch (ds_attachment.depth_store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_depth_attachment_set_store_action(depth_attachment, @backingInt(depth_store));

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
            mtl.metal_stencil_attachment_set_load_action(stencil_attachment, @backingInt(stencil_load));

            const stencil_store: mtl.MTLStoreAction = switch (ds_attachment.stencil_store_op) {
                .store => .Store,
                .discard => .DontCare,
            };
            mtl.metal_stencil_attachment_set_store_action(stencil_attachment, @backingInt(stencil_store));

            if (ds_attachment.stencil_load_op == .clear) {
                mtl.metal_stencil_attachment_set_clear_stencil(stencil_attachment, ds_attachment.stencil_clear_value);
            }
        }

        // Create Render Encoder. ABI contract: bridge uses __bridge_retained to return +1 owned
        // (metal_bridge.m:766), take ownership directly, **don't retain again**, RenderPass.end()
        // releases once; over-retaining leaks MTLRenderCommandEncoder per render pass.
        const encoder = mtl.metal_command_buffer_create_render_encoder(self.raw, pass_desc) orelse {
            mtl.release(pass_desc);
            return error.RenderEncoderCreationFailed;
        };

        // Release descriptor (encoder already holds reference).
        mtl.release(pass_desc);

        const generation = self.activatePass(.render_pass);
        self.active_pass_raw = @ptrCast(encoder);

        return RenderPass{
            .encoder = encoder,
            .command_encoder = self,
            .generation = generation,
        };
    }

    /// A render pass with no attachments over a width x height raster
    /// (Metal): draws write textures from their fragment functions, so one
    /// encoder can carry independent passes into different targets.
    pub fn beginAttachmentlessRenderPass(self: *CommandEncoder, width: u32, height: u32) !RenderPass {
        if (self.state != .initial) return error.InvalidEncoderState;
        if (width == 0 or height == 0) return error.InvalidTextureRegion;
        const encoder = mtl.metal_command_buffer_create_attachmentless_render_encoder(self.raw, width, height) orelse
            return error.RenderEncoderCreationFailed;
        const generation = self.activatePass(.render_pass);
        self.active_pass_raw = @ptrCast(encoder);
        return .{ .encoder = encoder, .command_encoder = self, .generation = generation };
    }

    pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
        if (self.state != .initial) return error.InvalidEncoderState;
        const encoder = mtl.metal_command_buffer_create_blit_encoder(self.raw) orelse
            return error.BlitEncoderCreationFailed;
        const generation = self.activatePass(.blit);
        self.active_pass_raw = @ptrCast(encoder);
        return .{ .encoder = encoder, .command_encoder = self, .generation = generation };
    }

    /// A whole render pass with integer source texel addressing. Reject aliasing:
    /// Metal may not sample its active color attachment (gutter uses shader clamp).
    pub fn copyTextureRegionRender(self: *CommandEncoder, source: resources.TextureBinding, sx: u32, sy: u32, width: u32, height: u32, destination: resources.TextureBinding, dx: u32, dy: u32, clear: bool) !void {
        if (self.state != .initial) return error.InvalidEncoderState;
        if (source.raw == destination.raw or width == 0 or height == 0 or
            sx > source.width or width > source.width - sx or sy > source.height or height > source.height - sy or
            dx > destination.width or width > destination.width - dx or dy > destination.height or height > destination.height - dy)
            return error.InvalidTextureRegion;
        if (mtl.metal_command_buffer_copy_texture_region_render(self.raw, source.raw, sx, sy, width, height, destination.raw, dx, dy, @intFromBool(clear)) == 0) return error.RenderCopyFailed;
    }

    /// Finish encoding, return CommandBuffer.
    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        if (self.state == .finished) return error.EncoderAlreadyFinished;
        if (self.state != .initial) return error.InvalidEncoderState;

        self.state = .finished;

        return CommandBuffer{
            .raw = self.raw,
        };
    }

    /// Destroy CommandEncoder (if not finished).
    pub fn deinit(self: *CommandEncoder) void {
        if (self.state == .finished) return;
        // Error path: pass still not ended (its RenderPass/BlitPass value discarded). First
        // endEncoding + release it, then release command buffer.
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

/// RenderPass - render pass.
///
/// Records render commands.
pub const RenderPass = struct {
    encoder: *mtl.MTLRenderCommandEncoder,
    command_encoder: *CommandEncoder,
    generation: u64,
    /// Root target is a cropped piece of the full scene. Preserve the scene's
    /// shader coordinates/NDC arithmetic and translate only rasterization.
    root_crop: ?[4]u32 = null,
    /// Where the crop lands in the attachment (atlas cells); zero for a
    /// target that is exactly the crop.
    root_offset: [2]u32 = .{ 0, 0 },

    fn assertActive(self: *const RenderPass) void {
        self.command_encoder.assertActivePass(.render_pass, self.generation);
    }

    pub fn isActive(self: *const RenderPass) bool {
        return self.command_encoder.passIsActive(.render_pass, self.generation);
    }

    /// Set render pipeline.
    pub fn setPipeline(self: *RenderPass, pipeline: *const RenderPipeline) void {
        self.assertActive();
        mtl.metal_render_encoder_set_render_pipeline_state(self.encoder, pipeline.raw);
    }

    /// Set viewport.
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
            x - if (self.root_crop) |r| @as(f32, @floatFromInt(r[0])) - @as(f32, @floatFromInt(self.root_offset[0])) else @as(f32, 0),
            y - if (self.root_crop) |r| @as(f32, @floatFromInt(r[1])) - @as(f32, @floatFromInt(self.root_offset[1])) else @as(f32, 0),
            width,
            height,
            min_depth,
            max_depth,
        );
    }

    /// Set scissor rectangle.
    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, width: u32, height: u32) void {
        self.assertActive();
        if (self.root_crop) |r| {
            const left = @min(@max(x, r[0]), r[0] + r[2]);
            const top = @min(@max(y, r[1]), r[1] + r[3]);
            const right = @max(left, @min(x +| width, r[0] + r[2]));
            const bottom = @max(top, @min(y +| height, r[1] + r[3]));
            mtl.metal_render_encoder_set_scissor_rect(self.encoder, left - r[0] + self.root_offset[0], top - r[1] + self.root_offset[1], right - left, bottom - top);
            return;
        }
        mtl.metal_render_encoder_set_scissor_rect(self.encoder, x, y, width, height);
    }

    /// Set vertex buffer.
    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const resources.Buffer, offset: u64) void {
        self.assertActive();
        mtl.metal_render_encoder_set_vertex_buffer(self.encoder, buffer.raw, offset, slot);
    }

    /// Set fragment buffer.
    pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const resources.Buffer, offset: u64) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_buffer(self.encoder, buffer.raw, offset, slot);
    }

    /// Set fragment texture.
    pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const resources.Texture) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture.raw, slot);
    }

    pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, texture: resources.TextureBinding) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture.raw, slot);
    }

    /// Set fragment texture (raw MTLTexture pointer).
    pub fn setFragmentTextureRaw(self: *RenderPass, slot: u32, texture: ?*mtl.MTLTexture) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_texture(self.encoder, texture, slot);
    }

    /// Set fragment sampler (raw MTLSamplerState pointer).
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

    /// Set vertex bytes (push constants).
    pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        mtl.metal_render_encoder_set_vertex_bytes(self.encoder, data.ptr, data.len, slot);
    }

    /// Set fragment bytes (push constants).
    pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        self.assertActive();
        mtl.metal_render_encoder_set_fragment_bytes(self.encoder, data.ptr, data.len, slot);
    }

    /// Draw primitives of the given primitive type (shared by draw/drawTriangleStrip).
    fn drawPrimitive(
        self: *RenderPass,
        primitive: mtl.MTLPrimitiveType,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.assertActive();
        // Count must cover **both** draw paths. Previously only drawIndexed counted, but UI main
        // path (SDF/text/image/icon instancing) uses non-indexed draw here, so draw call stats
        // long under-estimated (review report §4).
        frame_draw_call_count += 1;
        if (instance_count == 1 and first_instance == 0) {
            mtl.metal_render_encoder_draw_primitives(
                self.encoder,
                @backingInt(primitive),
                first_vertex,
                vertex_count,
            );
        } else if (first_instance == 0) {
            mtl.metal_render_encoder_draw_primitives_instanced(
                self.encoder,
                @backingInt(primitive),
                first_vertex,
                vertex_count,
                instance_count,
            );
        } else {
            mtl.metal_render_encoder_draw_primitives_instanced_base_instance(
                self.encoder,
                @backingInt(primitive),
                first_vertex,
                vertex_count,
                instance_count,
                first_instance,
            );
        }
    }

    /// Draw primitives (triangle list semantics unchanged).
    pub fn draw(
        self: *RenderPass,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.drawPrimitive(.Triangle, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draw primitives as a triangle strip.
    pub fn drawTriangleStrip(
        self: *RenderPass,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.drawPrimitive(.TriangleStrip, vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Global frame draw call counter (matrix #5 < 400). Reset at FrameSync.beginFrame; +1
    /// on drawIndexed call (ignores instance count; one drawIndexed* call = one draw call,
    /// independent of instance count).
    pub var frame_draw_call_count: u32 = 0;

    /// Draw indexed primitives.
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
                @backingInt(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @backingInt(mtl_index_type),
                index_buffer.raw,
                offset,
            );
        } else if (first_instance == 0 and base_vertex == 0) {
            mtl.metal_render_encoder_draw_indexed_primitives_instanced(
                self.encoder,
                @backingInt(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @backingInt(mtl_index_type),
                index_buffer.raw,
                offset,
                instance_count,
            );
        } else {
            mtl.metal_render_encoder_draw_indexed_primitives_full(
                self.encoder,
                @backingInt(mtl.MTLPrimitiveType.Triangle),
                index_count,
                @backingInt(mtl_index_type),
                index_buffer.raw,
                offset,
                instance_count,
                @intCast(@as(i64, base_vertex)),
                first_instance,
            );
        }
    }

    /// Set BindGroup.
    ///
    /// Bind resources from BindGroup to Metal encoder. group_index offsets buffer slot to
    /// avoid BindGroup conflicts.
    pub fn setBindGroup(self: *RenderPass, group_index: u32, bind_group: *const bind_group_mod.BindGroup) void {
        self.assertActive();
        bind_group.applyToRenderEncoder(self.encoder, group_index);
    }

    /// End render pass.
    pub fn end(self: *RenderPass) void {
        self.assertActive();
        mtl.metal_render_encoder_end_encoding(self.encoder);
        mtl.release(self.encoder);
        self.command_encoder.closePass(.render_pass, self.generation);
    }
};

/// ComputePass - compute pass.
///
/// Records compute commands.
pub const ComputePass = struct {
    encoder: *mtl.MTLComputeCommandEncoder,
    command_encoder: *CommandEncoder,

    /// Set compute pipeline.
    pub fn setPipeline(self: *ComputePass, pipeline: *const ComputePipeline) void {
        mtl.metal_compute_encoder_set_compute_pipeline_state(self.encoder, pipeline.raw);
    }

    /// Dispatch compute.
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

    /// Set BindGroup.
    pub fn setBindGroup(self: *ComputePass, group_index: u32, bind_group: *const bind_group_mod.BindGroup) void {
        bind_group.applyToComputeEncoder(self.encoder, group_index);
    }

    /// End compute pass.
    pub fn end(self: *ComputePass) void {
        mtl.metal_compute_encoder_end_encoding(self.encoder);
        mtl.release(self.encoder);
        self.command_encoder.state = .initial;
    }
};

/// CommandBuffer - encoded command buffer.
///
/// Can be submitted to Queue for execution.
pub const CommandBuffer = struct {
    raw: *mtl.MTLCommandBuffer,

    /// Process-level command buffer failure count (for diagnostics/soak assertions).
    pub var error_count: std.atomic.Value(u64) = .init(0);

    fn onCommandBufferError(context: ?*anyopaque, code: c_long, desc: [*:0]const u8) callconv(.c) void {
        _ = context;
        const n = CommandBuffer.error_count.fetchAdd(1, .monotonic);
        // First few times report fully, then sample. GPU fault, once occurs, usually repeats
        // frame-by-frame; can't spam but must never silent (old behavior: nobody watched status).
        if (n < 5 or n % 64 == 0) {
            std.log.err("[metal] command buffer failed (code={d}, total={d}): {s}", .{ code, n + 1, desc });
        }
    }

    /// Submit commands. Include error observation: GPU fault / hang / device removal no longer
    /// silent.
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

    /// Non-blocking query whether buffer reached terminal state. Lets caller do opportunistic
    /// reads of 'data only readable after completion', no main thread block.
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

    /// Present drawable.
    pub fn presentDrawable(self: *CommandBuffer, drawable: *mtl.CAMetalDrawable) void {
        mtl.metal_command_buffer_present_drawable(self.raw, drawable);
    }

    /// Destroy.
    pub fn deinit(self: *CommandBuffer) void {
        mtl.release(self.raw);
    }
};

// Use definitions from pipeline.zig.
const pipeline_mod = @import("pipeline.zig");
pub const RenderPipeline = pipeline_mod.RenderPipeline;

/// ComputePipeline - compute pipeline (placeholder, future implementation).
pub const ComputePipeline = struct {
    raw: *mtl.MTLComputePipelineState,

    pub fn deinit(self: *ComputePipeline) void {
        mtl.release(self.raw);
    }
};
