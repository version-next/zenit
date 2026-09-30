/// Metal Surface 实现
///
/// 封装 CAMetalLayer，提供跨帧的纹理获取和呈现
/// 参考: wgpu-hal/src/metal/surface.rs
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const resources = @import("resources.zig");

/// Surface - 窗口表面（纯数据）
pub const Surface = struct {
    layer: *mtl.CAMetalLayer,
    format: ?gpu.TextureFormat = null,
    extent: gpu.Extent3D = .{ .width = 0, .height = 0, .depth = 1 },

    /// 从平台原生 surface 句柄创建 Surface。
    ///
    /// 参数刻意是 `*anyopaque` 而非 `*mtl.CAMetalLayer`：调用方
    /// （`zenit_app/runtime.zig`）拿到的本来就是平台层返回的不透明指针
    /// （`window.getNativeSurfaceHandle()` 的返回类型就是 `*anyopaque`），旧签名逼着
    /// 它 `@import` metal_bindings 再 `@ptrCast` 一把——这是 backend 抽象上
    /// **唯一**会让第二个后端编译不过的硬泄漏（C1 评估记录在
    /// docs/internal/RHI_SECOND_BACKEND_ASSESSMENT.md）。
    ///
    /// 具体后端各自解释这个句柄：Metal 当它是 CAMetalLayer，Null 后端忽略它。
    pub fn init(layer: *anyopaque) Surface {
        const metal_layer: *mtl.CAMetalLayer = @ptrCast(@alignCast(layer));
        return Surface{
            .layer = mtl.retain(metal_layer),
            .format = null,
            .extent = .{ .width = 0, .height = 0, .depth = 1 },
        };
    }

    /// 配置 Surface
    /// 参考: wgpu-hal surface.rs configure() (61-110)
    pub fn configure(
        self: *Surface,
        allocator: std.mem.Allocator,
        device: *Device,
        config: SurfaceConfiguration,
    ) !void {
        _ = allocator;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 保存配置
        self.format = config.format;
        self.extent = .{
            .width = config.width,
            .height = config.height,
            .depth = 1,
        };

        // 配置 layer
        mtl.metal_layer_set_device(self.layer, device.raw_device);
        mtl.metal_layer_set_pixel_format(
            self.layer,
            @intFromEnum(conv.toMetalPixelFormat(config.format)),
        );

        // 性能优化
        const framebuffer_only: c_int = if (config.usage == .color_target_only) 1 else 0;
        mtl.metal_layer_set_framebuffer_only(self.layer, framebuffer_only);

        // 帧缓冲控制
        mtl.metal_layer_set_maximum_drawable_count(
            self.layer,
            config.maximum_frame_latency + 1,
        );

        // VSync
        const display_sync: c_int = if (config.present_mode == .fifo) 1 else 0;
        mtl.metal_layer_set_display_sync_enabled(self.layer, display_sync);

        // 超时控制（关键！）：**禁用** nextDrawable 超时。
        //
        // ⚠️ 别"改进"成有界等待。2026-08-07 按 GPU 评审 §D3 的建议试过设为 1
        // （允许超时 → acquireTexture 报 error.SurfaceTimeout → 跳帧计数），
        // storybook e2e 立刻从 87/87 掉到 78/87：glasslab 这类重 blur 场景
        // 反复吃 ~1s 超时，跳帧意味着**什么都没画出来**，表现为画面不刷新。
        //
        // 评审担心的"GPU 卡顿时无界阻塞冻死 UI"在本仓不成立：drawable 池
        // 耗尽的真实成因是泄漏（见 acquireTexture 里的 ABI 合同注释），那已
        // 根治；正常负载下 nextDrawable 的等待就是 vsync 背压，本来就该等。
        // 有界超时把"等一会儿"变成了"这帧丢了"，对重 GPU 场景是净损失。
        mtl.metal_layer_set_allows_next_drawable_timeout(self.layer, 0);

        // Alpha 模式
        const is_opaque_val: c_int = if (config.alpha_mode == AlphaMode.fully_opaque) 1 else 0;
        mtl.metal_layer_set_opaque(self.layer, is_opaque_val);

        // HDR 支持
        const wants_hdr: c_int = if (config.format == .rgba16_float) 1 else 0;
        mtl.metal_layer_set_wants_edr(self.layer, wants_hdr);

        // 设置尺寸
        mtl.metal_layer_set_drawable_size(self.layer, config.width, config.height);
    }

    /// 获取当前 drawable 纹理
    /// 参考: wgpu-hal surface.rs acquire_texture() (116-154)
    pub fn acquireTexture(
        self: *Surface,
        allocator: std.mem.Allocator,
    ) !SurfaceTexture {
        _ = allocator;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 获取 drawable (关键：在 autorelease pool 中)。
        // ABI 合同：metal_layer_next_drawable 用 __bridge_retained 返回 +1 owned
        // （metal_bridge.m:566），这里直接接管，**不再 retain**。
        // 之前多 retain 一次而 SurfaceTexture.deinit 只 release 一次，每帧净漏一个
        // CAMetalDrawable —— drawable 池只有 2-3 个，几秒内就会把池耗尽，
        // 表现为 nextDrawable 永久阻塞、画面冻死。
        const drawable = mtl.metal_layer_next_drawable(self.layer) orelse
            return error.SurfaceTimeout;
        errdefer mtl.release(drawable);

        // ⚠️ ABI 例外：metal_drawable_get_texture 定义在 window_bridge.m:2966，
        // 用的是 __bridge（**+0 借用**），与本文件其余 getter 的 __bridge_retained
        // 约定相反。因此这里的 retain 是**必需的**，不能跟着上面一起删。
        const texture_raw = mtl.metal_drawable_get_texture(drawable);
        _ = mtl.retain(texture_raw);
        errdefer mtl.release(texture_raw);

        // 构造 Texture（如果 format 未配置，errdefer 会释放上面 retain 的资源）
        const texture = resources.Texture{
            .raw = texture_raw,
            .format = self.format orelse return error.SurfaceNotConfigured,
            .size = self.extent,
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .device_local,
        };

        return SurfaceTexture{
            .texture = texture,
            .drawable = drawable,
            .present_with_transaction = mtl.metal_layer_presents_with_transaction(self.layer) != 0,
        };
    }

    /// 销毁 Surface
    pub fn deinit(self: *Surface) void {
        mtl.release(self.layer);
    }
};

/// SurfaceTexture - 可呈现的纹理
pub const SurfaceTexture = struct {
    texture: resources.Texture,
    drawable: *mtl.CAMetalDrawable,
    present_with_transaction: bool,

    /// 在提交前准备 present。
    /// transaction 模式下不能在这里等待 scheduled，因为 command buffer 尚未 commit。
    pub fn preparePresent(self: *SurfaceTexture, command_buffer: *gpu.Backend.CommandBuffer) void {
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        if (!self.present_with_transaction) {
            command_buffer.presentDrawable(self.drawable);
        }
    }

    /// 提交后完成 present。
    /// live resize 期间 `presentsWithTransaction=YES`，必须等到 command buffer 已经 commit
    /// 且进入 scheduled 状态后再直接 present drawable，否则会把主线程卡死在未提交的 buffer 上。
    pub fn presentAfterSubmit(self: *SurfaceTexture, command_buffer: *gpu.Backend.CommandBuffer) void {
        if (!self.present_with_transaction) return;

        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        mtl.metal_command_buffer_wait_until_scheduled(command_buffer.raw);
        mtl.metal_drawable_present(self.drawable);
    }

    /// 销毁（释放 drawable 和 texture）
    pub fn deinit(self: *SurfaceTexture) void {
        mtl.release(self.texture.raw);
        mtl.release(self.drawable);
    }
};

/// Surface 配置
pub const SurfaceConfiguration = struct {
    format: gpu.TextureFormat,
    width: u32,
    height: u32,
    usage: SurfaceUsage = .color_target_only,
    present_mode: PresentMode = .fifo,
    alpha_mode: AlphaMode = .fully_opaque,
    maximum_frame_latency: u32 = 2,
};

/// Surface 用途
pub const SurfaceUsage = enum {
    color_target_only,
    color_target_and_read,
};

/// 呈现模式
pub const PresentMode = enum {
    fifo, // VSync
    immediate, // 不等待 VSync
    mailbox, // 三重缓冲
};

/// Alpha 混合模式
pub const AlphaMode = enum {
    fully_opaque,
    premultiplied,
    postmultiplied,
};
