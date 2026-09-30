//! Backend-neutral RHI contracts plus a deterministic Null implementation.
//! The production Metal backend migrates to these value contracts phase by
//! phase; the Null backend validates state/lifetime, not pixels.

const std = @import("std");

pub const Error = error{
    InvalidDescriptor,
    InvalidHandle,
    InvalidPassState,
    PipelineNotBound,
    ResourceExhausted,
    SurfaceNotConfigured,
    SurfaceAlreadyAcquired,
    SurfaceOutdated,
    SurfaceLost,
    Timeout,
};

pub const TextureFormat = enum { r8_unorm, rgba8_unorm_srgb, bgra8_unorm_srgb };
pub const ResourceKind = enum(u2) { buffer, texture, pipeline };
pub const SurfaceState = enum { unconfigured, configured, acquired, submitted };

pub const Capabilities = struct {
    supports_timestamp_queries: bool = false,
    supports_memoryless_targets: bool = false,
    max_texture_dimension_2d: u32 = 16384,
};

pub const TextureDescriptor = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    render_target: bool = false,
    sampled: bool = false,

    pub fn validate(self: TextureDescriptor, caps: Capabilities) Error!void {
        if (self.width == 0 or self.height == 0) return Error.InvalidDescriptor;
        if (self.width > caps.max_texture_dimension_2d or self.height > caps.max_texture_dimension_2d)
            return Error.InvalidDescriptor;
        if (!self.render_target and !self.sampled) return Error.InvalidDescriptor;
    }
};

pub const BufferDescriptor = struct {
    size: usize,

    pub fn validate(self: BufferDescriptor) Error!void {
        if (self.size == 0) return Error.InvalidDescriptor;
    }
};

pub const Handle = packed struct(u32) {
    index: u16,
    generation: u14,
    kind: ResourceKind,
};

pub const CompletionToken = struct { epoch: u64 };

const Slot = struct {
    generation: u14 = 0,
    kind: ResourceKind = .buffer,
    live: bool = false,
    retired_after: ?u64 = null,
};

pub const PassKind = enum(u8) { none, render, blit, compute };
pub const PassToken = packed struct(u64) {
    generation: u56,
    kind: PassKind,
};

const CommandTag = enum(u8) {
    begin_render_pass,
    bind_pipeline,
    draw,
    end_render_pass,
    begin_blit_pass,
    blit_copy,
    end_blit_pass,
};
const Command = packed struct {
    tag: CommandTag,
    arg: u32,
};

pub const NullRhi = struct {
    pub const max_resources = 256;
    pub const max_commands = 1024;

    capabilities: Capabilities = .{},
    slots: [max_resources]Slot = [_]Slot{.{}} ** max_resources,
    commands: [max_commands]Command = undefined,
    command_count: usize = 0,
    active_pass: PassKind = .none,
    next_pass_generation: u56 = 1,
    active_pass_generation: u56 = 0,
    pipeline_bound: bool = false,
    submitted_epoch: u64 = 0,
    completed_epoch: u64 = 0,
    last_fingerprint: u64 = 0,
    surface_state: SurfaceState = .unconfigured,
    injected_acquire_error: ?Error = null,

    pub fn createTexture(self: *NullRhi, desc: TextureDescriptor) Error!Handle {
        try desc.validate(self.capabilities);
        return self.allocate(.texture);
    }

    pub fn createBuffer(self: *NullRhi, desc: BufferDescriptor) Error!Handle {
        try desc.validate();
        return self.allocate(.buffer);
    }

    pub fn createPipeline(self: *NullRhi) Error!Handle {
        return self.allocate(.pipeline);
    }

    fn allocate(self: *NullRhi, kind: ResourceKind) Error!Handle {
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.live and slot.retired_after == null) {
                slot.live = true;
                slot.kind = kind;
                return .{ .index = @intCast(i), .generation = slot.generation, .kind = kind };
            }
        }
        return Error.ResourceExhausted;
    }

    fn resolve(self: *NullRhi, handle: Handle, kind: ResourceKind) Error!*Slot {
        if (handle.index >= self.slots.len or handle.kind != kind) return Error.InvalidHandle;
        const slot = &self.slots[handle.index];
        if (!slot.live or slot.generation != handle.generation or slot.kind != kind) return Error.InvalidHandle;
        return slot;
    }

    pub fn destroyAfter(self: *NullRhi, handle: Handle, token: CompletionToken) Error!void {
        const slot = try self.resolve(handle, handle.kind);
        if (token.epoch > self.submitted_epoch) return Error.InvalidHandle;
        slot.live = false;
        slot.retired_after = token.epoch;
    }

    pub fn complete(self: *NullRhi, token: CompletionToken) void {
        self.completed_epoch = @max(self.completed_epoch, token.epoch);
        for (&self.slots) |*slot| {
            if (slot.retired_after) |epoch| {
                if (epoch <= self.completed_epoch) {
                    slot.retired_after = null;
                    slot.generation +%= 1;
                }
            }
        }
    }

    pub fn beginFrame(self: *NullRhi) Error!void {
        if (self.active_pass != .none) return Error.InvalidPassState;
        self.command_count = 0;
        self.pipeline_bound = false;
    }

    pub fn beginRenderPass(self: *NullRhi, target: Handle) Error!void {
        if (self.active_pass != .none) return Error.InvalidPassState;
        _ = try self.resolve(target, .texture);
        self.activatePass(.render);
        self.pipeline_bound = false;
        try self.push(.begin_render_pass, @bitCast(target));
    }

    pub fn bindPipeline(self: *NullRhi, pipeline: Handle) Error!void {
        if (self.active_pass != .render) return Error.InvalidPassState;
        _ = try self.resolve(pipeline, .pipeline);
        self.pipeline_bound = true;
        try self.push(.bind_pipeline, @bitCast(pipeline));
    }

    pub fn draw(self: *NullRhi, vertex_count: u32) Error!void {
        if (self.active_pass != .render) return Error.InvalidPassState;
        if (!self.pipeline_bound) return Error.PipelineNotBound;
        if (vertex_count == 0) return Error.InvalidDescriptor;
        try self.push(.draw, vertex_count);
    }

    pub fn endRenderPass(self: *NullRhi) Error!void {
        if (self.active_pass != .render) return Error.InvalidPassState;
        try self.push(.end_render_pass, 0);
        self.closePass();
        self.pipeline_bound = false;
    }

    pub fn beginBlitPass(self: *NullRhi) Error!void {
        if (self.active_pass != .none) return Error.InvalidPassState;
        self.activatePass(.blit);
        try self.push(.begin_blit_pass, 0);
    }

    pub fn copyTexture(self: *NullRhi, source: Handle, destination: Handle) Error!void {
        if (self.active_pass != .blit) return Error.InvalidPassState;
        _ = try self.resolve(source, .texture);
        _ = try self.resolve(destination, .texture);
        try self.push(.blit_copy, (@as(u32, source.index) << 16) | destination.index);
    }

    pub fn endBlitPass(self: *NullRhi) Error!void {
        if (self.active_pass != .blit) return Error.InvalidPassState;
        try self.push(.end_blit_pass, 0);
        self.closePass();
    }

    pub fn activePassToken(self: *const NullRhi) Error!PassToken {
        if (self.active_pass == .none) return Error.InvalidPassState;
        return .{ .generation = self.active_pass_generation, .kind = self.active_pass };
    }

    pub fn validatePassToken(self: *const NullRhi, token: PassToken, expected: PassKind) Error!void {
        if (expected == .none or self.active_pass != expected or token.kind != expected or
            token.generation != self.active_pass_generation)
            return Error.InvalidPassState;
    }

    fn activatePass(self: *NullRhi, kind: PassKind) void {
        std.debug.assert(kind != .none and self.active_pass == .none);
        self.active_pass = kind;
        self.active_pass_generation = self.next_pass_generation;
        self.next_pass_generation +%= 1;
        if (self.next_pass_generation == 0) self.next_pass_generation = 1;
    }

    fn closePass(self: *NullRhi) void {
        self.active_pass = .none;
        self.active_pass_generation = 0;
    }

    fn push(self: *NullRhi, tag: CommandTag, arg: u32) Error!void {
        if (self.command_count >= self.commands.len) return Error.ResourceExhausted;
        self.commands[self.command_count] = .{ .tag = tag, .arg = arg };
        self.command_count += 1;
    }

    pub fn submit(self: *NullRhi) Error!CompletionToken {
        if (self.active_pass != .none) return Error.InvalidPassState;
        self.submitted_epoch += 1;
        self.last_fingerprint = std.hash.Wyhash.hash(
            0,
            std.mem.sliceAsBytes(self.commands[0..self.command_count]),
        );
        return .{ .epoch = self.submitted_epoch };
    }

    pub fn commandFingerprint(self: *const NullRhi) u64 {
        return self.last_fingerprint;
    }

    pub fn configureSurface(self: *NullRhi) void {
        self.surface_state = .configured;
    }

    pub fn injectNextAcquireError(self: *NullRhi, err: Error) void {
        self.injected_acquire_error = err;
    }

    pub fn acquireSurface(self: *NullRhi) Error!void {
        if (self.surface_state == .unconfigured) return Error.SurfaceNotConfigured;
        if (self.surface_state != .configured) return Error.SurfaceAlreadyAcquired;
        if (self.injected_acquire_error) |err| {
            self.injected_acquire_error = null;
            return err;
        }
        self.surface_state = .acquired;
    }

    pub fn markSurfaceSubmitted(self: *NullRhi) Error!void {
        if (self.surface_state != .acquired) return Error.InvalidPassState;
        self.surface_state = .submitted;
    }

    pub fn presentSurface(self: *NullRhi) Error!void {
        if (self.surface_state != .submitted) return Error.InvalidPassState;
        self.surface_state = .configured;
    }
};

test "Null RHI validates descriptors and pass nesting" {
    const testing = std.testing;
    var rhi = NullRhi{};
    try testing.expectError(Error.InvalidDescriptor, rhi.createTexture(.{ .width = 0, .height = 10, .format = .r8_unorm, .sampled = true }));
    const target = try rhi.createTexture(.{ .width = 64, .height = 64, .format = .bgra8_unorm_srgb, .render_target = true });
    const pipeline = try rhi.createPipeline();
    try rhi.beginFrame();
    try rhi.beginRenderPass(target);
    try testing.expectError(Error.InvalidPassState, rhi.beginRenderPass(target));
    try testing.expectError(Error.PipelineNotBound, rhi.draw(3));
    try rhi.bindPipeline(pipeline);
    try rhi.draw(3);
    try rhi.endRenderPass();
    _ = try rhi.submit();
    try testing.expect(rhi.commandFingerprint() != 0);
}

test "Null RHI enforces typed render to blit transitions and stale generations" {
    const testing = std.testing;
    var rhi = NullRhi{};
    const source = try rhi.createTexture(.{ .width = 8, .height = 8, .format = .rgba8_unorm_srgb, .render_target = true });
    const destination = try rhi.createTexture(.{ .width = 8, .height = 8, .format = .rgba8_unorm_srgb, .render_target = true });
    const pipeline = try rhi.createPipeline();

    try rhi.beginFrame();
    try rhi.beginRenderPass(source);
    const render_token = try rhi.activePassToken();
    try rhi.validatePassToken(render_token, .render);
    try testing.expectError(Error.InvalidPassState, rhi.beginBlitPass());
    try testing.expectError(Error.InvalidPassState, rhi.copyTexture(source, destination));
    try testing.expectError(Error.InvalidPassState, rhi.endBlitPass());
    try rhi.bindPipeline(pipeline);
    try rhi.draw(3);
    try rhi.endRenderPass();

    try rhi.beginBlitPass();
    const blit_token = try rhi.activePassToken();
    try rhi.validatePassToken(blit_token, .blit);
    try testing.expectError(Error.InvalidPassState, rhi.validatePassToken(render_token, .render));
    try testing.expectError(Error.InvalidPassState, rhi.beginRenderPass(destination));
    try testing.expectError(Error.InvalidPassState, rhi.bindPipeline(pipeline));
    try testing.expectError(Error.InvalidPassState, rhi.draw(3));
    try testing.expectError(Error.InvalidPassState, rhi.endRenderPass());
    try rhi.copyTexture(source, destination);
    try rhi.endBlitPass();
    try testing.expectError(Error.InvalidPassState, rhi.validatePassToken(blit_token, .blit));

    try rhi.beginRenderPass(destination);
    const second_render_token = try rhi.activePassToken();
    try testing.expect(second_render_token.generation != render_token.generation);
    try rhi.endRenderPass();
    _ = try rhi.submit();
}

test "Null RHI fingerprints are deterministic and stale generations fail" {
    const testing = std.testing;
    var first = NullRhi{};
    var second = NullRhi{};
    const t1 = try first.createTexture(.{ .width = 8, .height = 8, .format = .r8_unorm, .render_target = true });
    const p1 = try first.createPipeline();
    const t2 = try second.createTexture(.{ .width = 8, .height = 8, .format = .r8_unorm, .render_target = true });
    const p2 = try second.createPipeline();
    inline for (.{ .{ &first, t1, p1 }, .{ &second, t2, p2 } }) |entry| {
        try entry[0].beginFrame();
        try entry[0].beginRenderPass(entry[1]);
        try entry[0].bindPipeline(entry[2]);
        try entry[0].draw(6);
        try entry[0].endRenderPass();
        _ = try entry[0].submit();
    }
    try testing.expectEqual(first.commandFingerprint(), second.commandFingerprint());

    const token = CompletionToken{ .epoch = first.submitted_epoch };
    try first.destroyAfter(t1, token);
    first.complete(token);
    try testing.expectError(Error.InvalidHandle, first.beginRenderPass(t1));
    const replacement = try first.createTexture(.{ .width = 8, .height = 8, .format = .r8_unorm, .render_target = true });
    try testing.expectEqual(t1.index, replacement.index);
    try testing.expect(t1.generation != replacement.generation);
}

test "Null RHI models surface recovery states" {
    const testing = std.testing;
    var rhi = NullRhi{};
    try testing.expectError(Error.SurfaceNotConfigured, rhi.acquireSurface());
    rhi.configureSurface();
    rhi.injectNextAcquireError(Error.SurfaceOutdated);
    try testing.expectError(Error.SurfaceOutdated, rhi.acquireSurface());
    try testing.expectEqual(SurfaceState.configured, rhi.surface_state);
    try rhi.acquireSurface();
    try rhi.markSurfaceSubmitted();
    try rhi.presentSurface();
    try testing.expectEqual(SurfaceState.configured, rhi.surface_state);
}

test "Null RHI resource exhaustion does not partially publish a resource" {
    const testing = std.testing;
    var rhi = NullRhi{};
    var handles: [NullRhi.max_resources]Handle = undefined;
    for (&handles) |*handle| handle.* = try rhi.createPipeline();
    try testing.expectError(Error.ResourceExhausted, rhi.createPipeline());

    var live_count: usize = 0;
    for (rhi.slots) |slot| if (slot.live) {
        live_count += 1;
    };
    try testing.expectEqual(NullRhi.max_resources, live_count);
    for (handles) |handle| _ = try rhi.resolve(handle, .pipeline);
}
