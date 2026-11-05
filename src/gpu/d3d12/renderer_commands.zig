//! Renderer command API adapter. Move-only encoder; retained command buffers
//! share one submission state. All access is confined to the render thread.
const std = @import("std");
const gpu = @import("../gpu.zig");
const d12 = @import("resources.zig");
const resources = @import("renderer_resources.zig");
pub const Queue = struct {
    context: *resources.Context,
    /// Borrow the Context's ordered queue; Context owns its native lifetime.
    pub fn init(context: *resources.Context) Queue {
        return .{ .context = context };
    }
    pub fn deinit(self: *Queue) void {
        self.* = undefined;
    }
};
pub const CommandEncoder = struct {
    inner: d12.CommandEncoder,
    context: *resources.Context,
    generation: u64 = 0,
    active_generation: u64 = 0,
    owns_context: bool = true,
    finished: bool = false,
    active_render: ?RenderState = null,
    /// Upload page currently sub-allocated by this encoder, and every page it
    /// used (handed to the command on finish).
    upload_page: ?usize = null,
    upload_cursor: u64 = 0,
    upload_used: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(queue: *Queue) !CommandEncoder {
        var inner = try queue.context.device.createCommandEncoder();
        // Timing is optional; allocation/support failure cannot reject a frame.
        inner.enableTimestamps() catch {};
        queue.context.resources += 1;
        return .{ .inner = inner, .context = queue.context };
    }
    /// Per-frame pass counters (render thread); the app renderer reads and
    /// resets them into FrameStats. native_ns covers the native begin/end calls.
    pub var perf_counters: PerfCounters = .{};
    /// Encode-cost attribution (render thread). draw_ns spans drawChecked;
    /// bind_ns its binding-table assembly (views, uniform snapshots, bind
    /// groups); native_draw_ns the native record call.
    pub const PerfCounters = struct {
        render_passes: u32 = 0,
        blit_passes: u32 = 0,
        native_ns: u64 = 0,
        draws: u32 = 0,
        draw_ns: u64 = 0,
        bind_ns: u64 = 0,
        native_draw_ns: u64 = 0,
        uniform_snapshots: u32 = 0,
        texture_views: u32 = 0,
        bind_groups: u32 = 0,
    };
    pub fn beginRenderPass(self: *CommandEncoder, desc: RenderPassDescriptor) !RenderPass {
        if (self.finished) return error.EncoderAlreadyFinished;
        if (self.active_generation != 0) return error.InvalidEncoderState;
        if (desc.color_attachments.len > 8) return error.InvalidRenderPass;
        var colors: [8]d12.ColorAttachment = undefined;
        for (desc.color_attachments, 0..) |*color, i| {
            if (color.view.context != self.context) return error.InvalidRenderPass;
            if (color.resolve_target) |resolve| if (resolve.context != self.context) return error.InvalidRenderPass;
            colors[i] = .{ .texture = &color.view.inner, .load_op = color.load_op, .store_op = color.store_op, .clear_value = .{ color.clear_value.r, color.clear_value.g, color.clear_value.b, color.clear_value.a }, .resolve_target = if (color.resolve_target) |*resolve| .{ .texture = &resolve.inner } else null };
        }
        var depth: ?d12.DepthStencilAttachment = null;
        if (desc.depth_stencil_attachment) |*ds| {
            if (ds.view.context != self.context) return error.InvalidRenderPass;
            depth = .{ .texture = &ds.view.inner, .depth_load_op = ds.depth_load_op, .depth_store_op = ds.depth_store_op, .depth_clear_value = ds.depth_clear_value, .depth_read_only = ds.depth_read_only, .stencil_load_op = ds.stencil_load_op, .stencil_store_op = ds.stencil_store_op, .stencil_clear_value = ds.stencil_clear_value, .stencil_read_only = ds.stencil_read_only };
        }
        const begin_t0 = @import("clock.zig").nowNanoseconds();
        const native = try self.inner.beginRenderPass(.{ .color_attachments = colors[0..desc.color_attachments.len], .depth_stencil_attachment = depth });
        perf_counters.render_passes += 1;
        if (begin_t0) |t0| if (@import("clock.zig").nowNanoseconds()) |t1| {
            perf_counters.native_ns += t1 -| t0;
        };
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.active_generation = self.generation;
        self.active_render = .{
            .inner = native,
            .target_size = if (desc.color_attachments.len > 0)
                .{ @floatFromInt(desc.color_attachments[0].view.inner.size.width), @floatFromInt(desc.color_attachments[0].view.inner.size.height) }
            else if (desc.depth_stencil_attachment) |ds|
                .{ @floatFromInt(ds.view.inner.size.width), @floatFromInt(ds.view.inner.size.height) }
            else
                .{ 0, 0 },
        };
        return .{ .command_encoder = self, .generation = self.generation };
    }
    pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
        if (self.finished) return error.EncoderAlreadyFinished;
        perf_counters.blit_passes += 1;
        if (self.active_generation != 0) return error.InvalidEncoderState;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.active_generation = self.generation;
        return .{ .command_encoder = self, .generation = self.generation };
    }
    pub fn finish(self: *CommandEncoder) !CommandBuffer {
        if (self.finished) return error.EncoderAlreadyFinished;
        if (self.active_generation != 0) return error.InvalidEncoderState;
        const shared = try self.context.allocator.create(SharedCommand);
        errdefer self.context.allocator.destroy(shared);
        shared.* = .{ .inner = try self.inner.finish(), .context = self.context, .upload_pages = self.upload_used };
        self.upload_used = .empty;
        self.upload_page = null;
        self.finished = true;
        self.owns_context = false; // Transfer the one live-owner count to SharedCommand.
        return .{ .shared = shared };
    }
    pub fn deinit(self: *CommandEncoder) void {
        if (self.active_render) |*render| render.deinit();
        self.active_render = null;
        // Pages of an encoder that never produced a command were never read.
        self.context.releaseUploadPages(self.upload_used.items, null);
        self.upload_used.deinit(self.context.allocator);
        self.upload_page = null;
        self.inner.deinit();
        self.finished = true;
        self.active_generation = 0;
        if (self.owns_context) {
            self.context.resources -= 1;
            self.owns_context = false;
        }
    }
};
// Use public descriptors so shared offscreen/opacity passes have the same API.
pub const ColorAttachment = gpu.RenderPassColorAttachment;
pub const DepthStencilAttachment = gpu.RenderPassDepthStencilAttachment;
pub const RenderPassDescriptor = gpu.RenderPassDescriptor;
const StoredUniform = struct { buffer: d12.Buffer, offset: u64 = 0, size: u64 };
const StoredVertex = struct { buffer: d12.Buffer, offset: u64, size: ?u64 = null };
fn bufferRangeSize(capacity: u64, offset: u64, size: ?u64) !u64 {
    if (offset > capacity) return error.InvalidBufferRange;
    const available = capacity - offset;
    const bound = size orelse available;
    if (bound == 0 or bound > available) return error.InvalidBufferRange;
    return bound;
}

fn reflectedUniformSize(available: u64, reflected: u64) !u64 {
    if (reflected > 65536) return error.InvalidUniformData;
    const capped = @min(available, @as(u64, 65536));
    return if (reflected == 0) capped else @min(capped, std.mem.alignForward(u64, reflected, 16));
}

test "uniform bindings exclude allocation tails and preserve register padding" {
    try std.testing.expectEqual(@as(u64, 352), try reflectedUniformSize(4 * 1024 * 1024, 340));
    try std.testing.expectEqual(@as(u64, 352), try reflectedUniformSize(352, 340));
    // A short source stays short: the caller must reject it or explicitly
    // snapshot/zero-pad it, rather than exposing bytes past the source range.
    try std.testing.expectEqual(@as(u64, 340), try reflectedUniformSize(340, 352));
    try std.testing.expectEqual(@as(u64, 65536), try reflectedUniformSize(131072, 0));
    try std.testing.expectEqual(@as(u64, 65536), try reflectedUniformSize(65536, 65536));
    try std.testing.expectError(error.InvalidUniformData, reflectedUniformSize(131072, 65537));
}

test "explicit buffer ranges retain payload bounds within large allocations" {
    try std.testing.expectEqual(@as(u64, 512), try bufferRangeSize(10 * 1024 * 1024, 256, 512));
    try std.testing.expectEqual(@as(u64, 768), try bufferRangeSize(1024, 256, null));
    try std.testing.expectError(error.InvalidBufferRange, bufferRangeSize(1024, 1025, 1));
    try std.testing.expectError(error.InvalidBufferRange, bufferRangeSize(1024, 1024, null));
    try std.testing.expectError(error.InvalidBufferRange, bufferRangeSize(1024, 256, 769));
    try std.testing.expectError(error.InvalidBufferRange, bufferRangeSize(1024, 0, 0));
}
const RenderState = struct {
    inner: d12.RenderPass,
    target_size: [2]f32,
    pipeline: ?d12.RenderPipeline = null,
    vertices: [32]?StoredVertex = @splat(null),
    fragment_buffers: [32]?StoredVertex = @splat(null),
    vertex_bytes: [32]?StoredUniform = @splat(null),
    fragment_bytes: [32]?StoredUniform = @splat(null),
    textures: [32]?resources.TextureView = @splat(null),
    samplers: [32]?d12.Sampler = @splat(null),
    viewport: ?d12.Viewport = null,
    scissor: ?d12.Scissor = null,
    fn deinit(self: *RenderState) void {
        self.inner.deinit();
        if (self.pipeline) |*pipeline| pipeline.deinit();
        for (&self.vertices) |*vertex| if (vertex.*) |*v| v.buffer.destroy();
        for (&self.fragment_buffers) |*buffer| if (buffer.*) |*v| v.buffer.destroy();
        for (&self.vertex_bytes) |*uniform| if (uniform.*) |*v| v.buffer.destroy();
        for (&self.fragment_bytes) |*uniform| if (uniform.*) |*v| v.buffer.destroy();
        for (&self.textures) |*texture| if (texture.*) |*view| view.destroy();
        for (&self.samplers) |*sampler| if (sampler.*) |*s| s.destroy();
    }
};
/// Bind group entries of one draw, assembled on the stack. Texture views and
/// uniform snapshots it creates are released after the draw is recorded (the
/// command retains what it uses).
const GroupEntries = struct {
    const max_entries = 128;
    current: *RenderState,
    pipeline: *d12.RenderPipeline,
    context: *resources.Context,
    entries: [max_entries]d12.NativeBindingEntry = undefined,
    group_counts: [4]u32 = @splat(0),
    entry_total: usize = 0,
    views: [max_entries]d12.TextureView = undefined,
    view_count: usize = 0,
    uniform_snapshots: [max_entries]d12.Buffer = undefined,
    snapshot_count: usize = 0,
    fn deinit(b: *GroupEntries) void {
        for (b.views[0..b.view_count]) |*view| view.destroy();
        for (b.uniform_snapshots[0..b.snapshot_count]) |*buffer| buffer.destroy();
    }
    /// Whether a bind group made of this group's assembled entries would be
    /// created (error path only).
    fn groupValid(b: *GroupEntries, info: anytype, group_index: usize) bool {
        var at: usize = 0;
        for (b.group_counts[0..group_index]) |count| at += count;
        _ = info;
        return d12.validateBindGroupEntries(&b.pipeline.bindingLayout(), @intCast(group_index), b.entries[at..][0..b.group_counts[group_index]]);
    }
    fn add(b: *GroupEntries, info: anytype, group_index: usize) !void {
        for (info.bindings) |binding| {
            if (binding.group != group_index) continue;
            if (b.entry_total == GroupEntries.max_entries) return error.UnsupportedRendererBinding;
            if (binding.count != 1 or binding.binding >= 32 or binding.visibility == 0 or binding.visibility & ~@as(u32, 3) != 0) return error.UnsupportedRendererBinding;
            var entry: d12.BindGroupEntry = undefined;
            switch (binding.kind) {
                0 => {
                    entry = try RenderPass.uniformEntry(b.current, binding.visibility & 1 != 0, binding.binding);
                    if (binding.visibility == 3) {
                        const fragment = try RenderPass.uniformEntry(b.current, false, binding.binding);
                        if (entry.buffer.?.raw != fragment.buffer.?.raw or entry.offset != fragment.offset or entry.size != fragment.size) {
                            if (entry.size != fragment.size) return error.SharedUniformMismatch;
                            var vs = entry.buffer.?.*;
                            var ps = fragment.buffer.?.*;
                            const left = vs.getMappedRange(entry.offset, entry.size.?) catch return error.SharedUniformMismatch;
                            const right = ps.getMappedRange(fragment.offset, fragment.size.?) catch return error.SharedUniformMismatch;
                            if (!std.mem.eql(u8, left, right)) return error.SharedUniformMismatch;
                        }
                    }
                    // HLSL cbuffers round the last register to 16 bytes.
                    // Inline snapshots already own zeroed native padding.
                    const inline_bytes = if (binding.visibility & 1 != 0) &b.current.vertex_bytes else &b.current.fragment_bytes;
                    if (inline_bytes[binding.binding] != null) entry.size = std.mem.alignForward(u64, entry.size.?, 16);
                    // Bind only the shader's declared registers. Using the
                    // remainder of a large upload allocation copies up to
                    // 64 KiB per tiny uniform and includes unrelated slots.
                    entry.size = try reflectedUniformSize(entry.size.?, binding.min_size);
                    // Shared renderers append CPU-sized uniforms (e.g.340
                    // bytes), whereas native CBV addresses align to256.
                    // Snapshot an unaligned host-visible range per draw;
                    // the command retains it through GPU use.
                    if (entry.offset % 256 != 0) {
                        const size = std.mem.alignForward(u64, binding.min_size, 16);
                        if (size == 0 or size > 65536 or std.mem.alignForward(u64, entry.size.?, 16) < size) return error.InvalidUniformData;
                        const payload = @min(entry.size.?, size);
                        var source = entry.buffer.?.*;
                        const bytes = source.getMappedRange(entry.offset, payload) catch return error.UniformBufferNotHostVisible;
                        CommandEncoder.perf_counters.uniform_snapshots += 1;
                        b.uniform_snapshots[b.snapshot_count] = try b.context.createBuffer(b.context.allocator, .{ .size = size, .usage = .{ .uniform = true, .map_write = true } });
                        const snapshot = &b.uniform_snapshots[b.snapshot_count];
                        b.snapshot_count += 1;
                        const mapped = try snapshot.getMappedRange(0, size);
                        @memset(mapped, 0);
                        @memcpy(mapped[0..@intCast(payload)], bytes);
                        entry.buffer = snapshot;
                        entry.offset = 0;
                        entry.size = size;
                    }
                    if (entry.size.? < binding.min_size) return error.InvalidUniformData;
                    entry.binding = binding.binding;
                },
                2 => {
                    // Explicit renderer spans expose only the uploaded
                    // batch; ordinary bindings retain their full range.
                    entry = try RenderPass.bufferEntry(b.current, binding.visibility & 1 != 0, binding.binding);
                    entry.stride = try b.pipeline.bufferStride(binding.group, binding.binding);
                    // Capacity allocations may end in a partial element
                    // (Path's byte-sized growth with28-byte vertices).
                    // Expose only complete structured elements, preserving
                    // raw ByteAddressBuffer ranges and native offset guards.
                    if (entry.stride != 0) {
                        entry.size = entry.size.? - entry.size.? % entry.stride;
                        if (entry.size.? == 0) return error.InvalidStorageData;
                    }
                    if (binding.visibility == 3) {
                        var other = try RenderPass.bufferEntry(b.current, false, binding.binding);
                        if (entry.stride != 0) other.size = other.size.? - other.size.? % entry.stride;
                        if (entry.buffer.?.raw != other.buffer.?.raw or entry.offset != other.offset or entry.size != other.size) return error.SharedStorageMismatch;
                    }
                },
                1 => {
                    if (binding.visibility != 2) return error.UnsupportedRendererBinding;
                    const texture = if (b.current.textures[binding.binding]) |*t| t else return error.TextureNotSet;
                    const dimension: gpu.TextureViewDimension = switch (binding.view_dimension) {
                        1 => .@"1d",
                        2 => .@"2d",
                        3 => .@"2d_array",
                        4 => .cube,
                        5 => .cube_array,
                        6 => .@"3d",
                        else => return error.UnsupportedRendererBinding,
                    };
                    // Full-range views are cached by the texture natively.
                    CommandEncoder.perf_counters.texture_views += 1;
                    b.views[b.view_count] = try texture.inner.createView(.{ .dimension = dimension });
                    entry = .{ .binding = binding.binding, .texture_view = &b.views[b.view_count] };
                    b.view_count += 1;
                },
                4 => {
                    if (binding.visibility != 2) return error.UnsupportedRendererBinding;
                    const sampler = if (b.current.samplers[binding.binding]) |*smp| smp else return error.SamplerNotSet;
                    entry = .{ .binding = binding.binding, .sampler = sampler };
                },
                else => return error.UnsupportedRendererBinding,
            }
            b.entries[b.entry_total] = try d12.nativeBindingEntry(entry);
            b.entry_total += 1;
            b.group_counts[group_index] += 1;
        }
    }
};
pub const RenderPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,
    /// The pass renders part of a larger scene at its own coordinates (a
    /// compositor sprite's cell in a target that ends at the cell): scissors
    /// past the target are clamped to it instead of rejecting the draw.
    clamp_scissor: bool = false,
    pub var frame_draw_call_count: u32 = 0;
    /// What the latest counted (not returned) pass error was (diagnostics).
    pub var last_error: []const u8 = "";
    pub fn isActive(self: *const RenderPass) bool {
        return !self.command_encoder.finished and self.command_encoder.active_render != null and self.command_encoder.active_generation == self.generation;
    }
    fn state(self: *RenderPass) *RenderState {
        if (!self.isActive()) @panic("stale or wrong-kind GPU pass used after its lifetime ended");
        return &self.command_encoder.active_render.?;
    }
    pub fn setPipeline(self: *RenderPass, pipeline: *const d12.RenderPipeline) void {
        const current = self.state();
        const owned = pipeline.retained();
        if (current.pipeline) |*old| old.deinit();
        current.pipeline = owned;
    }
    pub fn setViewport(self: *RenderPass, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        self.state().viewport = .{ .x = x, .y = y, .width = width, .height = height, .min_depth = min_depth, .max_depth = max_depth };
    }
    pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, width: u32, height: u32) void {
        const current = self.state();
        if (self.clamp_scissor) {
            const tw: u32 = @intFromFloat(current.target_size[0]);
            const th: u32 = @intFromFloat(current.target_size[1]);
            const left = @min(x, tw);
            const top = @min(y, th);
            current.scissor = .{ .x = left, .y = top, .width = @min(x +| width, tw) - left, .height = @min(y +| height, th) - top };
            return;
        }
        current.scissor = .{ .x = x, .y = y, .width = width, .height = height };
    }
    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const d12.Buffer, offset: u64) void {
        const current = self.state();
        if (slot >= 32) @panic("vertex buffer slot out of range");
        const owned = buffer.retained();
        if (current.vertices[slot]) |*old| old.buffer.destroy();
        current.vertices[slot] = .{ .buffer = owned, .offset = offset };
        if (current.vertex_bytes[slot]) |*old| old.buffer.destroy();
        current.vertex_bytes[slot] = null;
    }
    pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const d12.Buffer, offset: u64) void {
        const current = self.state();
        if (slot >= 32) @panic("fragment buffer slot out of range");
        const owned = buffer.retained();
        if (current.fragment_buffers[slot]) |*old| old.buffer.destroy();
        current.fragment_buffers[slot] = .{ .buffer = owned, .offset = offset };
        if (current.fragment_bytes[slot]) |*old| old.buffer.destroy();
        current.fragment_bytes[slot] = null;
    }
    pub fn setVertexBufferRange(self: *RenderPass, slot: u32, buffer: *const d12.Buffer, offset: u64, size: u64) void {
        self.setVertexBuffer(slot, buffer, offset);
        self.state().vertices[slot].?.size = size;
    }
    pub fn setFragmentBufferRange(self: *RenderPass, slot: u32, buffer: *const d12.Buffer, offset: u64, size: u64) void {
        self.setFragmentBuffer(slot, buffer, offset);
        self.state().fragment_buffers[slot].?.size = size;
    }
    pub fn setFragmentTextureBindingChecked(self: *RenderPass, slot: u32, texture: resources.TextureBinding) !void {
        if (!self.isActive()) return error.InvalidEncoderState;
        if (slot >= 32) return error.InvalidTextureBinding;
        if (texture.context != self.command_encoder.context) return error.InvalidTextureBinding;
        const owned = texture.createView();
        const current = self.state();
        if (current.textures[slot]) |*old| old.destroy();
        current.textures[slot] = owned;
    }
    pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, texture: resources.TextureBinding) void {
        _ = self.state();
        self.setFragmentTextureBindingChecked(slot, texture) catch |err| {
            last_error = @errorName(err);
            _ = CommandBuffer.error_count.fetchAdd(1, .monotonic);
        };
    }
    pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const resources.Texture) void {
        self.setFragmentTextureBinding(slot, texture.binding());
    }
    pub fn setFragmentSampler(self: *RenderPass, slot: u32, sampler: ?*const d12.Sampler) void {
        const current = self.state();
        if (slot >= 32) @panic("fragment sampler slot out of range");
        const owned = if (sampler) |s| s.retained() else null;
        if (current.samplers[slot]) |*old| old.destroy();
        current.samplers[slot] = owned;
    }
    fn setBytesChecked(self: *RenderPass, vertex: bool, slot: u32, data: []const u8) !void {
        if (!self.isActive()) return error.InvalidEncoderState;
        if (slot >= 32 or data.len == 0 or data.len > 4096) return error.InvalidUniformData;
        const encoder = self.command_encoder;
        const context = encoder.context;
        // CBV addresses must be 256-byte aligned; pages are, and so is every slice.
        const size = std.mem.alignForward(u64, data.len, 256);
        if (encoder.upload_page == null or encoder.upload_cursor + size > resources.Context.upload_page_size) {
            const page = try context.acquireUploadPage();
            encoder.upload_used.append(context.allocator, page) catch |err| {
                context.releaseUploadPages(&.{page}, null);
                return err;
            };
            encoder.upload_page = page;
            encoder.upload_cursor = 0;
        }
        const page = &context.upload_pages.items[encoder.upload_page.?];
        const offset = encoder.upload_cursor;
        const bytes = try page.buffer.getMappedRange(offset, size);
        @memset(bytes, 0);
        @memcpy(bytes[0..data.len], data);
        encoder.upload_cursor += size;
        const current = self.state();
        const uniforms = if (vertex) &current.vertex_bytes else &current.fragment_bytes;
        const buffers = if (vertex) &current.vertices else &current.fragment_buffers;
        if (uniforms[slot]) |*old| old.buffer.destroy();
        if (buffers[slot]) |*old| old.buffer.destroy();
        buffers[slot] = null;
        uniforms[slot] = .{ .buffer = page.buffer.retained(), .offset = offset, .size = data.len };
    }
    pub fn setVertexBytesChecked(self: *RenderPass, slot: u32, data: []const u8) !void {
        try self.setBytesChecked(true, slot, data);
    }
    pub fn setFragmentBytesChecked(self: *RenderPass, slot: u32, data: []const u8) !void {
        try self.setBytesChecked(false, slot, data);
    }
    pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        _ = self.state();
        self.setVertexBytesChecked(slot, data) catch |err| {
            last_error = @errorName(err);
            _ = CommandBuffer.error_count.fetchAdd(1, .monotonic);
        };
    }
    pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
        _ = self.state();
        self.setFragmentBytesChecked(slot, data) catch |err| {
            last_error = @errorName(err);
            _ = CommandBuffer.error_count.fetchAdd(1, .monotonic);
        };
    }
    fn bufferEntry(current: *RenderState, vertex: bool, slot: u32) !d12.BindGroupEntry {
        const uniforms = if (vertex) &current.vertex_bytes else &current.fragment_bytes;
        const buffers = if (vertex) &current.vertices else &current.fragment_buffers;
        if (uniforms[slot]) |*u| return .{ .binding = slot, .buffer = &u.buffer, .offset = u.offset, .size = u.size };
        if (buffers[slot]) |*b| {
            return .{ .binding = slot, .buffer = &b.buffer, .offset = b.offset, .size = try bufferRangeSize(b.buffer.size, b.offset, b.size) };
        }
        return error.UniformNotSet;
    }
    fn uniformEntry(current: *RenderState, vertex: bool, slot: u32) !d12.BindGroupEntry {
        var entry = try bufferEntry(current, vertex, slot);
        entry.size = @min(@as(u64, 65536), entry.size.?);
        return entry;
    }
    pub fn drawChecked(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        if (!self.isActive()) return error.InvalidEncoderState;
        const clock = @import("clock.zig");
        const draw_t0 = clock.nowNanoseconds();
        defer if (draw_t0) |t0| if (clock.nowNanoseconds()) |t1| {
            CommandEncoder.perf_counters.draw_ns += t1 -| t0;
        };
        CommandEncoder.perf_counters.draws += 1;
        const current = self.state();
        const pipeline = if (current.pipeline) |*p| p else return error.PipelineNotSet;
        var bindings: [32]d12.VertexBinding = undefined;
        var count: usize = 0;
        for (&current.vertices, 0..) |*vertex, slot| {
            if (pipeline.vertex_slots & (@as(u32, 1) << @intCast(slot)) == 0) continue;
            if (current.vertex_bytes[slot]) |*u| {
                bindings[count] = .{ .buffer = &u.buffer, .slot = @intCast(slot), .offset = u.offset, .size = u.size };
            } else {
                const value = if (vertex.*) |*v| v else return error.VertexBufferNotSet;
                bindings[count] = .{ .buffer = &value.buffer, .slot = @intCast(slot), .offset = value.offset, .size = value.size };
            }
            count += 1;
        }
        const layout = pipeline.bindingLayout();
        const info = layout.describe();
        if (info.groups > 4) return error.UnsupportedRendererBinding;
        // Entries of every group, concatenated in group order; the native
        // draw validates them as bind groups and writes their descriptors
        // directly (no per-draw bind group objects or heap allocations).
        // Entries of every group, concatenated in group order; the native
        // draw validates them as bind groups and writes their descriptors
        // directly (no per-draw bind group objects or heap allocations).
        var b: GroupEntries = .{ .current = current, .pipeline = pipeline, .context = self.command_encoder.context };
        defer b.deinit();
        const bind_t0 = clock.nowNanoseconds();
        for (0..info.groups) |group_index| {
            b.add(info, group_index) catch |err| {
                // As when each group's bind group was created before the next
                // was assembled: an earlier group creation would reject wins.
                if (err != error.InvalidBindGroup) for (0..group_index) |g| {
                    if (!b.groupValid(info, g)) return error.InvalidBindGroup;
                };
                return err;
            };
            CommandEncoder.perf_counters.bind_groups += 1;
        }
        const entries = b.entries[0..b.entry_total];
        const group_counts = b.group_counts[0..info.groups];
        const native_t0 = clock.nowNanoseconds();
        if (bind_t0) |t0| if (native_t0) |t1| {
            CommandEncoder.perf_counters.bind_ns += t1 -| t0;
        };
        defer if (native_t0) |t0| if (clock.nowNanoseconds()) |t1| {
            CommandEncoder.perf_counters.native_draw_ns += t1 -| t0;
        };
        try current.inner.drawEntries(.{ .pipeline = pipeline, .vertex_buffers = bindings[0..count], .vertex_count = vertex_count, .instance_count = instance_count, .first_vertex = first_vertex, .first_instance = first_instance, .viewport = current.viewport, .scissor = current.scissor }, entries, group_counts);
        if (vertex_count != 0 and instance_count != 0) frame_draw_call_count += 1;
    }
    pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        _ = self.state();
        self.drawChecked(vertex_count, instance_count, first_vertex, first_instance) catch |err| {
            last_error = @errorName(err);
            _ = CommandBuffer.error_count.fetchAdd(1, .monotonic);
            std.log.err("D3D12 draw rejected: {s} (vertices={d}, instances={d}, first_vertex={d}, first_instance={d})", .{ @errorName(err), vertex_count, instance_count, first_vertex, first_instance });
        };
    }

    pub fn clearOpaque(self: *RenderPass, color: [4]f32, bounds: [4]u32) bool {
        const current = self.state();
        var clipped = bounds;
        if (current.scissor) |clip| {
            const right = @min(@as(u64, bounds[0]) + bounds[2], @as(u64, clip.x) + clip.width);
            const bottom = @min(@as(u64, bounds[1]) + bounds[3], @as(u64, clip.y) + clip.height);
            clipped[0] = @max(bounds[0], clip.x);
            clipped[1] = @max(bounds[1], clip.y);
            clipped[2] = @intCast(right -| clipped[0]);
            clipped[3] = @intCast(bottom -| clipped[1]);
        }
        current.inner.clearOpaque(color, clipped) catch return false;
        return true;
    }

    pub fn matchesViewport(self: *RenderPass, size: [2]f32) bool {
        const current = self.state();
        const viewport = current.viewport orelse return current.target_size[0] == size[0] and current.target_size[1] == size[1];
        return viewport.x == 0 and viewport.y == 0 and viewport.width == size[0] and viewport.height == size[1];
    }

    /// Caller has already validated that its coordinates match this target.
    /// Requires the region-index vertex shader: four original quads, each
    /// selecting its matching viewport/scissor. Native draw state intersects
    /// every region with the caller scissor; later draws return to one viewport.
    pub fn drawFourRegions(self: *RenderPass, regions: *const [4][4]u32) bool {
        const current = self.state();
        current.inner.setDrawRegions(regions) catch return false;
        defer current.inner.setDrawRegions(&.{}) catch unreachable;
        self.draw(24, 1, 0, 0);
        return true;
    }

    /// Keep vertices unchanged, and restore the original scissor after drawing.
    pub fn drawRegion(self: *RenderPass, bounds: [4]u32, vertex_count: u32, instance_count: u32) void {
        const current = self.state();
        const previous = current.scissor;
        defer current.scissor = previous;
        var left = bounds[0];
        var top = bounds[1];
        var right = @as(u64, left) + bounds[2];
        var bottom = @as(u64, top) + bounds[3];
        if (previous) |clip| {
            left = @max(left, clip.x);
            top = @max(top, clip.y);
            right = @min(right, @as(u64, clip.x) + clip.width);
            bottom = @min(bottom, @as(u64, clip.y) + clip.height);
        }
        // Nothing of the region is inside the scissor (it may even start past
        // the target, which a draw would be rejected for).
        if (right <= left or bottom <= top) return;
        current.scissor = .{ .x = left, .y = top, .width = @intCast(right -| left), .height = @intCast(bottom -| top) };
        self.draw(vertex_count, instance_count, 0, 0);
    }

    /// Additional conservative pixel bounds for one draw. Only use them when
    /// the caller's coordinate space exactly matches an explicit viewport.
    /// Preserve the caller's scissor, including on a rejected draw.
    pub fn drawClipped(self: *RenderPass, bounds: [4]u32, viewport_size: [2]f32, vertex_count: u32, instance_count: u32) void {
        const current = self.state();
        const previous = current.scissor;
        defer current.scissor = previous;
        if (current.viewport) |viewport| {
            if (viewport.x == 0 and viewport.y == 0 and viewport.width == viewport_size[0] and viewport.height == viewport_size[1]) {
                var left = bounds[0];
                var top = bounds[1];
                var right = @as(u64, left) + bounds[2];
                var bottom = @as(u64, top) + bounds[3];
                if (previous) |clip| {
                    left = @max(left, clip.x);
                    top = @max(top, clip.y);
                    right = @min(right, @as(u64, clip.x) + clip.width);
                    bottom = @min(bottom, @as(u64, clip.y) + clip.height);
                }
                if (right <= left or bottom <= top) return;
                current.scissor = .{ .x = left, .y = top, .width = @intCast(right -| left), .height = @intCast(bottom -| top) };
            }
        }
        self.draw(vertex_count, instance_count, 0, 0);
    }
    pub fn end(self: *RenderPass) void {
        const end_t0 = @import("clock.zig").nowNanoseconds();
        self.state().deinit();
        if (end_t0) |t0| if (@import("clock.zig").nowNanoseconds()) |t1| {
            CommandEncoder.perf_counters.native_ns += t1 -| t0;
        };
        self.command_encoder.active_render = null;
        self.command_encoder.active_generation = 0;
    }
};
pub const BlitPass = struct {
    command_encoder: *CommandEncoder,
    generation: u64,
    pub fn isActive(self: *const BlitPass) bool {
        return !self.command_encoder.finished and self.command_encoder.active_render == null and self.command_encoder.active_generation == self.generation;
    }
    pub fn copyTextureRegion(self: *BlitPass, source: resources.TextureBinding, source_x: u32, source_y: u32, width: u32, height: u32, destination: resources.TextureBinding, destination_x: u32, destination_y: u32) !void {
        if (!self.isActive()) return error.InvalidEncoderState;
        if (source.context != self.command_encoder.context or destination.context != self.command_encoder.context) return error.InvalidTextureCopy;
        if (source.inner.dimension != .@"2d" or destination.inner.dimension != .@"2d") return error.InvalidTextureRegion;
        try self.command_encoder.inner.copyTextureToTexture(&source.inner, .{ .x = source_x, .y = source_y, .width = width, .height = height }, &destination.inner, .{ .x = destination_x, .y = destination_y, .width = width, .height = height });
    }
    pub fn end(self: *BlitPass) void {
        if (!self.isActive()) @panic("stale or wrong-kind GPU pass used after its lifetime ended");
        self.command_encoder.active_generation = 0;
    }
};
const SharedCommand = struct {
    inner: d12.CommandBuffer,
    context: *resources.Context,
    refs: usize = 1,
    serial: ?u64 = null,
    /// Upload pages this command reads; retired behind `serial` on submit.
    upload_pages: std.ArrayListUnmanaged(usize) = .empty,
    upload_released: bool = false,
    fn releaseUpload(self: *SharedCommand) void {
        if (self.upload_released) return;
        self.upload_released = true;
        self.context.releaseUploadPages(self.upload_pages.items, self.serial);
    }
};
pub const CommandBuffer = struct {
    shared: *SharedCommand,
    pub var error_count: std.atomic.Value(usize) = .init(0);
    pub fn submitChecked(self: *CommandBuffer) !void {
        if (self.shared.serial != null) return error.CommandAlreadySubmitted;
        const context = self.shared.context;
        // Texture writes recorded during this frame execute before its draws.
        // A failed flush leaves the frame unsubmitted.
        try context.flushUploads();
        const queue = &context.queue;
        const before = queue.last_serial;
        const serial = queue.submit(&.{self.shared.inner}) catch |err| {
            // Signal failure can follow real execution. Keep its serial and
            // forbid re-execution while permitting fence recovery via wait.
            if (queue.last_serial != before) {
                self.shared.serial = queue.last_serial;
                self.shared.releaseUpload();
            }
            return err;
        };
        self.shared.serial = serial;
        self.shared.releaseUpload();
    }
    pub fn submit(self: *CommandBuffer) void {
        self.submitChecked() catch {
            _ = error_count.fetchAdd(1, .monotonic);
        };
    }
    pub fn retained(self: *const CommandBuffer) CommandBuffer {
        self.shared.refs += 1;
        return .{ .shared = self.shared };
    }
    pub fn waitChecked(self: *const CommandBuffer, timeout_ms: u32) !void {
        const serial = self.shared.serial orelse return error.CommandNotSubmitted;
        try self.shared.context.queue.wait(serial, timeout_ms);
    }
    pub fn waitUntilCompleted(self: *const CommandBuffer) void {
        self.waitChecked(self.shared.context.timeout_ms) catch {
            _ = error_count.fetchAdd(1, .monotonic);
        };
    }
    pub fn isCompleted(self: *const CommandBuffer) bool {
        self.waitChecked(0) catch return false;
        return true;
    }
    pub fn gpuTimingResult(self: *const CommandBuffer) d12.GpuTimingResult {
        return self.shared.inner.gpuTimingResult();
    }
    pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
        return self.shared.inner.gpuElapsedMicros();
    }
    pub fn deinit(self: *CommandBuffer) void {
        const shared = self.shared;
        shared.refs -= 1;
        if (shared.refs == 0) {
            // Never submitted (serial null): the GPU never read its pages.
            shared.releaseUpload();
            shared.upload_pages.deinit(shared.context.allocator);
            shared.inner.deinit();
            shared.context.resources -= 1;
            shared.context.allocator.destroy(shared);
        }
        self.* = undefined;
    }
};
