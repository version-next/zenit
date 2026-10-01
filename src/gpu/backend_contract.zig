//! 后端接口契约：编译期校验一个候选后端是否实现了渲染器所依赖的全部符号。
//!
//! ## 为什么需要它
//!
//! `gpu.Backend` 长期是 `@import("metal/backend.zig")` 这样的**编译期 type
//! alias**。alias 的问题不是"迁移贵", `check_renderer_metal_boundary.sh` 早已
//! 把渲染核心的直接 Metal 引用压到 0/0，而是**抽象从未被证伪**：只有一个实现
//! 时，无法知道 `gpu.Backend.*` 的签名到底是 backend-neutral 的，还是无意中把
//! Metal 语义焊死在了里面。
//!
//! 本模块把"后端必须提供什么"从口头约定变成**编译期断言**：任何后端只要漏掉
//! 一个符号、或把某个符号写成不同的种类（类型 vs 函数），`zig build` 当场失败，
//! 而不是等到某个 `@import` 路径被真正实例化时才炸。
//!
//! ## 契约面为什么是这些符号
//!
//! 清单来自实测而非设计愿望：统计 `src/render`、`src/ui`、`src/zenit_app`
//! 里所有 `gpu.Backend.<Symbol>` 的引用点得到。`metal/backend.zig` 共导出 32 个
//! 符号，渲染层实际只用到其中一个子集，契约只锁**被真正依赖的那部分**，
//! 多导出不算违约（后端可以有自己的扩展），少导出才算。
const std = @import("std");

/// 渲染层实际依赖的类型符号。
///
/// 顺序按实测引用频次排列（Buffer 最高），纯粹为了让人读到时先看见热点。
pub const required_types = [_][]const u8{
    "Instance",
    "Adapter",
    "Device",
    "Queue",
    "Buffer",
    "Texture",
    "TextureBinding",
    "TextureView",
    "Sampler",
    "Surface",
    "SurfaceTexture",
    "SurfaceConfiguration",
    "CommandEncoder",
    "CommandBuffer",
    "RenderPass",
    "ShaderModule",
    "ShaderFunction",
    "RenderPipeline",
    "RenderPipelineDescriptor",
    "VertexBufferLayoutDescriptor",
    "VertexAttributeDescriptor",
    "BlendState",
    "FrameSync",
};

/// 渲染层实际依赖的自由函数符号。
pub const required_functions = [_][]const u8{
    "createRenderPipeline",
    "writePngRgba",
};

/// 编译期校验：`BackendType` 是否满足契约。
///
/// 在 `gpu.zig` 顶层对被选中的后端调用一次。校验失败会给出**具体缺了哪个符号**
/// 的编译错误，比"某处 undefined"这种间接报错好定位得多。
pub fn verify(comptime BackendType: type, comptime backend_name: []const u8) void {
    comptime {
        for (required_types) |name| {
            if (!@hasDecl(BackendType, name)) {
                @compileError("GPU backend '" ++ backend_name ++
                    "' is missing required type '" ++ name ++
                    "' (see src/gpu/backend_contract.zig)");
            }
            const decl = @field(BackendType, name);
            if (@TypeOf(decl) != type) {
                @compileError("GPU backend '" ++ backend_name ++ "' declares '" ++ name ++
                    "' but it is not a type (see src/gpu/backend_contract.zig)");
            }
        }
        for (required_functions) |name| {
            if (!@hasDecl(BackendType, name)) {
                @compileError("GPU backend '" ++ backend_name ++
                    "' is missing required function '" ++ name ++
                    "' (see src/gpu/backend_contract.zig)");
            }
            const info = @typeInfo(@TypeOf(@field(BackendType, name)));
            if (info != .@"fn") {
                @compileError("GPU backend '" ++ backend_name ++ "' declares '" ++ name ++
                    "' but it is not a function (see src/gpu/backend_contract.zig)");
            }
        }
    }
}

test "contract accepts a backend that declares every required symbol" {
    // 一个最小的合格后端：只需要符号**存在且种类正确**，不需要能真跑。
    const Ok = struct {
        pub const Instance = struct {};
        pub const Adapter = struct {};
        pub const Device = struct {};
        pub const Queue = struct {};
        pub const Buffer = struct {};
        pub const Texture = struct {};
        pub const TextureBinding = struct {};
        pub const TextureView = struct {};
        pub const Sampler = struct {};
        pub const Surface = struct {};
        pub const SurfaceTexture = struct {};
        pub const SurfaceConfiguration = struct {};
        pub const CommandEncoder = struct {};
        pub const CommandBuffer = struct {};
        pub const RenderPass = struct {};
        pub const ShaderModule = struct {};
        pub const ShaderFunction = struct {};
        pub const RenderPipeline = struct {};
        pub const RenderPipelineDescriptor = struct {};
        pub const VertexBufferLayoutDescriptor = struct {};
        pub const VertexAttributeDescriptor = struct {};
        pub const BlendState = struct {};
        pub const FrameSync = struct {};
        pub fn createRenderPipeline() void {}
        pub fn writePngRgba() void {}
    };
    verify(Ok, "test-ok");
}

test "contract lists stay in sync with themselves" {
    // 防手滑：两张清单都不能为空，且不能出现重复项（重复会让"缺符号"的
    // 编译错误报两遍，且暗示编辑时复制粘贴出过错）。
    try std.testing.expect(required_types.len > 0);
    try std.testing.expect(required_functions.len > 0);
    for (required_types, 0..) |a, i| {
        for (required_types[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
    for (required_functions, 0..) |a, i| {
        for (required_functions[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}
