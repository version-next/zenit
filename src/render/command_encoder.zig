/// RenderCommandEncoder - UI DisplayItem → GPU 调用的统一编码器
///
/// 将 UI 框架生成的 lowered DisplayItem 切片高效编码为 SdfRenderer 和
/// TextRenderer 的批量调用。
///
/// 用法:
/// ```
/// var encoder = RenderCommandEncoder.init(&sdf_renderer, &text_renderer);
/// encoder.beginFrame(width, height, scale);
/// _ = cx.render();
/// try encoder.encodeDisplay(cx);
/// try encoder.flush(&render_pass);
/// ```
const std = @import("std");

/// 纹理已被释放（陈旧句柄）时只丢这一张图：向上抛会中止整帧编码，这条命令之后的内容全不画。
pub fn addImageOrSkip(ir: *ImageRenderer, handle: u64, x: f32, y: f32, w: f32, h: f32, tint: [4]f32, corner_radius: f32, opacity: f32, rotate: f32) !void {
    ir.addImageUV(@intCast(handle), x, y, w, h, .{ 0, 0, 1, 1 }, tint, corner_radius, opacity, rotate) catch |err| switch (err) {
        error.UnknownTexture => logUnknownTextureOnce(handle),
        else => return err,
    };
}

/// 同一个陈旧纹理句柄每帧都会遇到：只在句柄变化时记一次，别刷屏，也别静默。
var last_unknown_texture: u64 = 0;
fn logUnknownTextureOnce(handle: anytype) void {
    const h: u64 = @intCast(handle);
    if (h == last_unknown_texture) return;
    last_unknown_texture = h;
    std.log.scoped(.command_encoder).warn("image skipped: unknown texture handle {d}", .{h});
}
const gpu = @import("gpu");
// 纯函数簇（damage bounds / 内容指纹 / 结构折叠）已析出，见该文件头部合同说明。
const paint_fp = @import("command_encoder/paint_fingerprint.zig");
const lsort = @import("command_encoder/local_sort.zig");
const wire_types = @import("command_encoder/wire_types.zig");
const script_detect = @import("command_encoder/script_detect.zig");
const clip_geometry = @import("command_encoder/clip_geometry.zig");
// local-sort 簇状态机（2026-08-05 析出）：encoder 内联的嵌套 struct 改为
// 借用同目录模块，容量常量随之搬走。
const cluster_mod = @import("command_encoder/local_sort_cluster.zig");
const LocalSortCluster = cluster_mod.LocalSortCluster;
const LocalSortRejectReason = cluster_mod.RejectReason;
// 像素域转换（finitePixelCoordinate / physicalPixelExtent /
// max_safe_pixel_coordinate，2026-08-05 析出）：与 backdrop_capture.zig
// 共享同一份 2^24 钳制语义，独立成零依赖小模块，双方都从这里 import。
const pixel_domain = @import("command_encoder/pixel_domain.zig");
pub const finitePixelCoordinate = pixel_domain.finitePixelCoordinate;
pub const physicalPixelExtent = pixel_domain.physicalPixelExtent;
pub const max_safe_pixel_coordinate = pixel_domain.max_safe_pixel_coordinate;
// backdrop 采样区域解析（2026-08-05 析出）：computeBackdropCaptureRegion 原本
// 就是 encoder 上的静态函数（无 self），此处 re-export 保持 backdrop_blur 的
// 反射调用点（`@TypeOf(encoder.*).computeBackdropCaptureRegion`）零改动。
const backdrop_capture = @import("command_encoder/backdrop_capture.zig");
pub const BackdropCaptureRegion = backdrop_capture.BackdropCaptureRegion;
// 跨帧 GPU 资源缓存的簿记（2026-08-05 析出）：字段 + beginFrame/deinit。
// pipeline 的创建在 backdrop_blur / opacity_layer / blend_composite，
// uniform 槽分配已在 backdrop_blur —— 均不随迁。
const persistent_gpu_cache = @import("command_encoder/persistent_gpu_cache.zig");
pub const PersistentGpuCache = persistent_gpu_cache.PersistentGpuCache;
pub const LuminanceSlot = persistent_gpu_cache.LuminanceSlot;
pub const BlurLevelSlot = persistent_gpu_cache.BlurLevelSlot;
pub const LUMINANCE_SLOT_COUNT = persistent_gpu_cache.LUMINANCE_SLOT_COUNT;
pub const BLUR_LEVEL_SLOT_COUNT = persistent_gpu_cache.BLUR_LEVEL_SLOT_COUNT;
const color_conversion = @import("color_conversion.zig");
// 析出模块的 test 块必须显式引用才会被收集（本仓库里 `pub const x = @import`
// 这种再导出**不会**让 test 进 runner，见 render.zig 尾部 test 块的注释）。
test {
    _ = @import("command_encoder/local_sort_cluster.zig");
    _ = @import("command_encoder/backdrop_capture.zig");
    _ = @import("command_encoder/persistent_gpu_cache.zig");
    _ = @import("command_encoder/pixel_domain.zig");
}
pub const colorToFloat4 = color_conversion.toFloat4;
const colorToRenderColor = color_conversion.toRenderColor;
const srgbByteToLinear = color_conversion.srgbByteToLinear;
// FontSelector 与 encoder 零耦合，已析出；此处 re-export 保持 render.zig 的公开面不变。
pub const FontSelector = @import("command_encoder/font_selector.zig").FontSelector;
pub const TextFontProps = @import("command_encoder/font_selector.zig").TextFontProps;
const icon_ir = @import("icon_ir");
const sdf = @import("sdf_renderer.zig");
const SdfRenderer = sdf.SdfRenderer;
const GradientDir = sdf.GradientDir;
const GradientExtendMode = sdf.GradientExtendMode;
const img = @import("image_renderer.zig");
const ImageRenderer = img.ImageRenderer;
const IconRenderer = @import("icon_renderer.zig").IconRenderer;
const TextRenderer = @import("text_renderer.zig").TextRenderer;
const text_module = @import("text");
const Font = text_module.Font;

const path_tess_mod = @import("path_tessellator.zig");
const PathRenderer = @import("path_renderer.zig").PathRenderer;
const PathRendererMod = @import("path_renderer.zig");

/// PathRenderer 的顶点与 stroke width 都使用逻辑像素。device scale 只用于
/// viewport、曲线细分精度与 AA fringe，不能再次作用于线宽。
pub inline fn pathStrokeWidthForTessellation(logical_width: f32, device_scale: f32) f32 {
    _ = device_scale;
    return logical_width;
}

const backdrop_blur = @import("backdrop_blur.zig");
const KawaseUniforms = backdrop_blur.KawaseUniforms;
const GlassUniforms = backdrop_blur.GlassUniforms;
const offscreen_texture = @import("offscreen_texture.zig");
const OffscreenTexturePool = offscreen_texture.OffscreenTexturePool;
const TextureLease = offscreen_texture.TextureLease;
const OffscreenTextureSize = offscreen_texture.OffscreenTextureSize;
const computeOffscreenTextureSize = offscreen_texture.computeOffscreenTextureSize;
const opacity_layer = @import("opacity_layer.zig");

pub const ClipShapeKind = enum(u8) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    polygon = 3,
};

pub const PathFillRule = enum(u8) {
    evenodd = 0,
    nonzero = 1,
};

pub const max_clip_polygon_points: usize = 32;
pub const max_clip_polygon_contours: usize = 8;
pub const ClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: PathFillRule = .evenodd,
    contour_end_points: [max_clip_polygon_contours]u8 = [_]u8{0} ** max_clip_polygon_contours,
    points: [max_clip_polygon_points][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_clip_polygon_points,

    pub fn empty() ClipPolygon {
        return .{};
    }

    pub fn isEmpty(self: ClipPolygon) bool {
        return self.point_count == 0 or self.contour_count == 0;
    }
};

const RoundedClipMode = enum(u8) { shader, layer, noop };
const OpacityLayerMode = enum(u8) { layer, noop };

const RoundedClipState = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    shape_kind: ClipShapeKind,
    polygon: ClipPolygon = ClipPolygon.empty(),
};

/// SVG/CSS 混合模式 — 镜像 src/ui/core/types.zig 的 BlendMode
/// render 模块不依赖 ui 模块，需在此独立定义（枚举值必须同步）
pub const BlendMode = enum(u8) {
    normal = 0,
    multiply = 1,
    screen = 2,
    overlay = 3,
    darken = 4,
    lighten = 5,
    color_dodge = 6,
    color_burn = 7,
    hard_light = 8,
    soft_light = 9,
    difference = 10,
    exclusion = 11,
};

pub const GradientDirection = enum {
    horizontal,
    vertical,
    diagonal,
    radial,
    conic,
};

/// Monospace ASCII advance cache 槽位（详见 FontSelector.ascii_advance_cache 注释）。
/// Scissor 矩形 (物理像素)
pub const ScissorRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// GPU retained 命中时挂起的合成信息。内容 pass 被完全跳过，end 处用这些字段
/// 把缓存好的纹理合成回父目标 —— 等价于普通路径 endOpacityLayer 的第 7 步。
const RetainedPending = struct {
    texture: TextureLease,
    /// 该 layer 在父 surface 内的 outer-local 坐标（与 OffscreenLayer.x/y 同语义）。
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opacity: f32,
    rotate: f32,
    use_draw_transform: bool,
    draw_transform: [6]f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    corner_radius: f32,
    used_tex_w: u32,
    used_tex_h: u32,
    alloc_tex_w: u32,
    alloc_tex_h: u32,
};

/// 离屏 Opacity 图层状态
/// damage-rect：某顶层 opacity layer 的 per-item 捕获区间（damage_scratch 内）。
pub const DamageRange = struct {
    start: u32 = 0,
    len: u32 = 0,
    /// false = 层内含 control token（嵌套层/clip）或 path 类命令 —— 嵌套 pass
    /// 会重置 scissor、path renderer 自管 scissor，部分重绘不安全，整层重画。
    safe: bool = false,
    /// item 数超 damage_scratch 容量 —— diff 不完整，放弃部分重绘。
    overflow: bool = false,
    /// 该 range 是否真的被捕获过（序号超 64 的层为 false）
    captured: bool = false,
};

// pub：单测已析出到 command_encoder_test.zig，需要构造该类型。
pub const OffscreenLayer = struct {
    /// Pool-owned offscreen texture lease.
    texture: TextureLease,
    /// 离屏 render pass（存在栈上，encoder 通过指针引用）
    render_pass: gpu.Backend.RenderPass,
    /// end 离屏后要恢复到的目标纹理（嵌套时为父离屏纹理，否则为主 RT）
    restore_target: gpu.Backend.TextureBinding,
    /// 保存的 clip stack 深度
    saved_clip_depth: usize,
    /// 保存的 clip 溢出计数（离屏 pass 内从 0 开始计，返回时恢复）。
    saved_clip_overflow_depth: u32 = 0,
    /// 保存的逻辑 clip 栈内容。离屏 pass 会把 clip_depth 归零后复用同一块栈空间，
    /// 不备份会在返回主 pass 时把父级 clip/scissor 状态污染掉。
    saved_logical_clip_stack: [64]RoundedClipState = undefined,
    saved_effective_rect_clip_stack: [64][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** 64,
    /// 保存的 viewport
    saved_viewport_width: f32,
    saved_viewport_height: f32,
    /// 图层在恢复目标中的屏幕位置（逻辑像素）
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// 合成 opacity
    opacity: f32,
    /// 进层前的光栅倍率（endOpacityLayer 恢复用）。层内 encoder.scale = 该层的
    /// 有效光栅倍率（父倍率 × 合成变换的放大系数），见 opacity_layer.layerMagnification。
    saved_scale: f32 = 1,
    /// 以图层中心为 origin 的顺时针旋转（弧度）
    rotate: f32 = 0,
    /// 是否以完整 2D affine 变换回贴离屏图层
    use_draw_transform: bool = false,
    draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    /// 合成回恢复目标的矩形；默认与 source 相同
    draw_x: f32 = 0,
    draw_y: f32 = 0,
    draw_w: f32 = 0,
    draw_h: f32 = 0,
    /// 在 image_renderer 中注册的纹理 ID
    texture_id: u32,
    /// 圆角裁剪半径（0 = 普通 opacity layer）
    corner_radius: f32 = 0,
    /// SVG/CSS 混合模式（normal = 标准 SrcOver）
    blend_mode: BlendMode = .normal,
    /// GPU retained：本层画进的是某个 layer 的专属纹理时，记下它的 stable_id。
    /// endOpacityLayer 据此决定是"标记内容已就绪"（retained）还是"还回池"
    /// （普通临时纹理）—— 两者绝不能搞混：把 retained 纹理还回池会让别人覆写
    /// 它，把临时纹理标记 primed 则毫无意义。
    retained_id: u32 = opacity_layer.INVALID_SURFACE_ID,
    /// retained：本层 begin 在预扫描里的序号（damage-rect 基线写回用）。
    retained_seq: usize = std.math.maxInt(usize),
    /// 内容实际占用的物理像素（纹理按 64px 桶向上分配，见 bucketDimension，
    /// scale 动画期逐帧 ±1px 的尺寸抖动才能命中池复用）。合成时按
    /// used/alloc 裁 UV；重开 render pass 时 viewport/scissor 必须限到
    /// used 区域（NDC 默认铺满整个 alloc 纹理会把内容拉伸）。
    used_tex_w: u32 = 0,
    used_tex_h: u32 = 0,
    /// 纹理分配的物理像素（桶尺寸）
    alloc_tex_w: u32 = 0,
    alloc_tex_h: u32 = 0,
    /// damage-rect 部分重绘：本层内容 pass 的脏区 scissor（texture-local 物理
    /// 像素）。嵌套 pass end 恢复本层时必须重新取交（scissor 是 per-pass 状态，
    /// re-begin 会重置）—— 见 applyOffscreenTargetViewport。null = 整层重画。
    damage_scissor: ?opacity_layer.PartialRepaint = null,
};

/// RenderCommandEncoder — 将 lowered DisplayItem 切片编码为 GPU 调用。
/// 跨帧持久的 PersistentGpuCache 曾住在这里，已析出到
/// command_encoder/persistent_gpu_cache.zig（见该文件头部「不搬什么」）。
/// 一条命令是不是 arc。
///
/// arc 复用 `.path` kind，靠 `arc_outer_radius > 0` 区分 —— 且**只**靠它：
/// 描边宽度、颜色 alpha 是「画不画得出来」的问题，不是「是不是 arc」的问题。
/// 把可见性条件混进类型判据，就会出现「它不算 arc，于是按 fill_path 处理」
/// 这种既非 arc 也非 path 的空隙 —— 而 arc 命令从不带 path_geometry_ptr，
/// 掉进 fill_path 分支的结果是被 `orelse return` 静默吞掉。
pub fn isArcCommand(it: anytype) bool {
    return it.kind == .path and it.arc_outer_radius > 0;
}

pub const RenderCommandEncoder = struct {
    const local_sort_cluster_capacity: usize = cluster_mod.capacity;
    const max_kawase_uniform_updates: u32 = backdrop_blur.max_kawase_uniform_updates;
    const max_glass_uniform_updates: u32 = backdrop_blur.max_glass_uniform_updates;

    // local-sort 簇状态机已析出到 command_encoder/local_sort_cluster.zig
    //（refs+len 与四个方法只互相引用，encoder 只在 encodeCommands /
    // flushLocalSortCluster 两个触点使用）。reject reason 随迁 re-export，
    // switch 分支名不变。
    const LocalSortRejectReason = cluster_mod.RejectReason;

    sdf_renderer: *SdfRenderer,
    text_renderer: *TextRenderer,
    image_renderer: ?*ImageRenderer = null,
    icon_renderer: ?*IconRenderer = null,
    fonts: ?*FontSelector = null,

    // Clip stack — logical clip state remains stack-based, but axis-aligned
    // rect clip is now captured per instance to avoid flushes on common
    // overflow_hidden transitions.
    clip_stack: [64]ScissorRect = undefined,
    logical_clip_stack: [64]RoundedClipState = undefined,
    /// syncRendererClipMask 的 memo：clip 未变时跳过对全部 renderer 的
    /// 状态拷贝（每次同步是 4-5 个 renderer × ~300B 值拷贝，push/pop clip
    /// 和 begin/end layer 都会触发）。encoder 每帧重建，默认未同步。
    last_synced_clip_mask: ?RoundedClipState = null,
    clip_mask_synced: bool = false,
    /// begin_rounded_clip 的实现路径栈：end_rounded_clip 必须知道对应的
    /// begin 走了 shader clip 还是离屏 layer。shader 路径省掉 2 个 render
    /// pass + 全 RT load/store（tile GPU 上 rounded-clip 免离屏的核心收益）。
    rounded_clip_mode_stack: [32]RoundedClipMode = undefined,
    rounded_clip_mode_depth: u32 = 0,
    rounded_clip_overflow_depth: u32 = 0,
    /// 逃生阀：ZENIT_ROUNDED_CLIP_LAYER=1 强制全部走旧的离屏路径（进程级缓存）。
    force_rounded_clip_layer: ?bool = null,
    effective_rect_clip_stack: [64][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** 64,
    clip_depth: usize = 0,
    /// 栈满后被忽略的 push_clip 个数。配对的 pop_clip 必须先抵消这些，
    /// 否则会弹掉父级真实 clip（push 静默忽略 / pop 无条件弹 = 错配）。
    clip_overflow_depth: u32 = 0,
    render_pass: ?*gpu.Backend.RenderPass = null,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    scale: f32 = 1,
    frame_index: u64 = 0,
    /// v0.9-§D stage 1 audit (2026-05-13): 每帧 beginRenderPass 调用数。
    /// 主 pass + offscreen opacity_layer + backdrop_blur + clearTexture 等共享计数。
    /// `beginFrame` 重置；caller (encoder.beginFrame caller) 通过 `pass_count`
    /// 读上一帧值做 perf 监控。后续 stage 目标：通过合并 single-pass + stencil/blend
    /// 替代 offscreen 减少 pass count，复杂场景 (多个 opacity layer 嵌套) 收益最大。
    pass_count: u32 = 0,
    /// 诊断（ZENIT_DEBUG_PASSCOUNT）：按调用点归类的 pass 计数，用来回答
    /// "这一帧的 N 个 pass 分别是什么"。索引见 PassSite。
    pass_sites: [8]u32 = .{0} ** 8,
    /// 每个普通 opacity begin 的实际开层结果。必须逐层记录，单纯用 noop
    /// 深度计数无法表示「noop 外层里有真实内层」这类合法嵌套。
    /// 当 opacity ≈ 1.0 且 blend_mode = normal 且无 transform/rotate 时，
    /// 跳过 beginOpacityLayer 的离屏 pass + image 回贴，等价于不开 layer。
    opacity_mode_stack: [64]OpacityLayerMode = undefined,
    opacity_mode_depth: usize = 0,
    opacity_mode_overflow_depth: u32 = 0,
    /// GPU retained：命中缓存时，begin..end 之间的**内容命令全部跳过**（纹理里
    /// 已经有画好的像素），只在 end 处做一次合成 draw。此计数器跟踪被跳过的
    /// 嵌套深度，>0 期间 dispatchCommand 直接 return。
    ///
    /// 用深度计数而非布尔：被跳过的子树内部可能还有自己的 begin/end opacity
    /// layer，必须配对计数才能找回正确的 end。
    retained_skip_depth: u32 = 0,
    /// retained 命中时挂起的合成信息 —— 内容 pass 被跳过，但仍要在 end 处把
    /// 缓存纹理合成回父目标。
    retained_pending: [8]RetainedPending = undefined,
    retained_pending_depth: usize = 0,
    /// 本帧 retained 命中/未命中次数（诊断用；命中一次 = 省掉一整个离屏
    /// clear+内容 pass 的重光栅化）。
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    /// miss 中走了 damage-rect 部分重绘的次数（诊断）
    retained_partial_repaints: u32 = 0,
    /// 每个 begin_opacity_layer 的内容指纹（按出现顺序）。见
    /// `computeRetainedContentHashes` —— 这是 retained 的真正缓存键。
    retained_hashes: [64]u64 = [_]u64{0} ** 64,
    retained_hash_count: usize = 0,
    /// 本帧已合成过玻璃背板的 owner node id 集合。同一 blur effect 实例的
    /// begin token 可能在一帧内多次出现（display_list 多 pass 组装会把同
    /// 子树的零星 item 排到存储尾部 → effect 链重开）；背板重合成会把
    /// 先画的内容捕获+模糊+盖掉（下游应用侧栏"玻璃把内容糊掉"实拍）。
    /// 语义合同：一个 owner 每帧至多一张背板，重复 begin 跳过。
    blur_applied_owners: [64]u32 = undefined,
    blur_applied_count: usize = 0,
    /// dispatch 时走到第几个 begin_opacity_layer（与预扫描的序号对齐）。
    retained_begin_seq: usize = 0,
    /// damage-rect：本帧每个**顶层** opacity layer 的 per-item {单条指纹, 外扩
    /// bounds}，与 retained_hashes 同序号对齐。miss 时与 pool 里存的上一帧基线
    /// diff 出脏区，只重画脏区。
    damage_scratch: [1024]offscreen_texture.DamageItem = undefined,
    damage_scratch_count: usize = 0,
    /// layer_tree damage 通路合流（2026-07-30 晚）：
    /// 读方向 —— encodeDisplay 每帧从 LayerTree 快照 {stable_id, local-space
    /// damage bounds}（addDamage 生产端申报），computePartialDamage 并入 diff
    /// 出的脏区（安全方向：只放大，不缩小）。
    /// 写方向 —— retained 层的实际决策（hit/整层/部分重绘）经
    /// writebackLayerOutcomes 写回 LayerTree.needs_repaint/damage_rect，
    /// 两条通路从此共享一份状态（观测/测试单一事实源）。
    layer_damage_ids: [32]u32 = undefined,
    layer_damage_rects: [32][4]f32 = undefined, // local space {min_x,min_y,max_x,max_y}
    layer_damage_count: usize = 0,
    layer_outcome_ids: [64]u32 = undefined,
    layer_outcome_kinds: [64]u8 = undefined, // 0=hit 1=整层重画 2=部分重绘
    layer_outcome_rects: [64][4]f32 = undefined, // local space {min_x,min_y,max_x,max_y}
    layer_outcome_count: usize = 0,
    damage_ranges: [64]DamageRange = [_]DamageRange{.{}} ** 64,
    // Phase C2/C3: 离屏 opacity 图层
    /// GPU command encoder（用于在同一 command buffer 中创建多个 render pass）
    gpu_command_encoder: ?*gpu.Backend.CommandEncoder = null,
    /// 主 render target 纹理（用于 end 离屏后重新 beginRenderPass 回到主目标）
    main_render_target: ?gpu.Backend.TextureBinding = null,
    /// 离屏层栈（支持嵌套）
    offscreen_stack: [8]OffscreenLayer = undefined,
    offscreen_depth: usize = 0,
    /// 离屏纹理池 — 指向 **owner（AppRenderer）持有的持久池**。encoder 本身是
    /// 逐帧局部值；池若内嵌在 encoder 里会随 deinit 整池释放，跨帧复用（池存在
    /// 的唯一目的）从未发生，每个含离屏效果的帧都在 create/release 纹理。
    /// owner 负责 pool.deinit()（须在 GPU drain 之后）。
    offscreen_pool: *OffscreenTexturePool,

    /// **跨帧持久**的 GPU 资源缓存（借用，不拥有）——— 与 offscreen_pool 同理。
    ///
    /// 历史问题（审查报告 P1）：path renderer / tessellator / blur & glass
    /// pipeline / buffer / sampler 全部内嵌在**逐帧新建**的 encoder 里，
    /// deinit 即帧末销毁；下一帧遇到 path 或 blur 就要重新 runtime 编译 MSL、
    /// 创建多个 PSO、重建 buffer/sampler。任何连续的 SVG/path/GlassBox 动画
    /// 都会因此每帧付一次编译开销，产生主线程与驱动抖动。
    ///
    /// 现在把它们提升到 AppRenderer 持有的 PersistentGpuCache，encoder 只借用。
    /// 字段访问路径保持不变（下面的 accessor），故调用点无需改动。
    persistent: *PersistentGpuCache,

    /// 初始化编码器
    pub fn init(
        sdf_renderer: *SdfRenderer,
        text_renderer: *TextRenderer,
        offscreen_pool: *OffscreenTexturePool,
        persistent: *PersistentGpuCache,
    ) RenderCommandEncoder {
        return .{
            .sdf_renderer = sdf_renderer,
            .text_renderer = text_renderer,
            .offscreen_pool = offscreen_pool,
            .persistent = persistent,
        };
    }

    pub fn initWithImageAndIcon(
        sdf_renderer: *SdfRenderer,
        text_renderer: *TextRenderer,
        image_renderer: *ImageRenderer,
        icon_renderer: *IconRenderer,
        offscreen_pool: *OffscreenTexturePool,
        persistent: *PersistentGpuCache,
    ) RenderCommandEncoder {
        return .{
            .sdf_renderer = sdf_renderer,
            .text_renderer = text_renderer,
            .image_renderer = image_renderer,
            .icon_renderer = icon_renderer,
            .offscreen_pool = offscreen_pool,
            .persistent = persistent,
        };
    }

    /// 释放 encoder 懒加载创建的临时 GPU/路径资源。
    ///
    /// RenderCommandEncoder 常作为逐帧局部值使用；若某帧触发了 path/blur/glass
    /// 路径而不显式清理，这些资源会在 encoder 离开作用域后泄漏。
    pub fn deinit(self: *RenderCommandEncoder) void {
        // encoder 是逐帧局部值（AppRenderer.getEncoder 每帧新建），deinit 即帧末，
        // 此处 pass_count 是全帧终值。
        if (std.posix.getenv("ZENIT_DEBUG_PASSCOUNT") != null) {
            std.debug.print("[passcount] passes={d} retained_hit={d} retained_miss={d} | op_restore={d} op_begin={d} op_composite={d} clear_tex={d} blur={d}/{d}/{d}\n", .{
                self.pass_count,    self.retained_hits, self.retained_misses,
                self.pass_sites[0], self.pass_sites[1], self.pass_sites[2],
                self.pass_sites[4], self.pass_sites[5], self.pass_sites[6],
                self.pass_sites[7],
            });
            if (self.persistent.path_renderer) |*pr| {
                if (pr.frame_call_count > 0) {
                    std.debug.print("[pathbatch] calls={d} draws={d}\n", .{ pr.frame_call_count, pr.frame_draw_count });
                }
            }
        }

        // 帧中途出错（encodeDisplay/flush 的 try 提前返回）时 offscreen 栈里
        // 还有未 end 的层：它们借用的 external 纹理槽位必须在这里归还。
        // external 槽位只有 EXTERNAL_SLOT_COUNT 个且句柄不跨帧，漏还即永久丢一个槽。
        self.releaseAbandonedOffscreenBindings();

        // ⚠️ path/blur/glass 的 pipeline、buffer、sampler、tessellator **不再**
        // 在这里释放 —— 它们已提升到 AppRenderer 持有的 PersistentGpuCache，
        // 跨帧复用（此前每帧 create+destroy 一轮，连续 path/blur 动画每帧都要
        // 重新 runtime 编译 MSL，见审查报告 P1）。
        // encoder 只借用，帧末什么都不用做；缓存由 AppRenderer.deinit 统一释放。
    }

    fn releaseAbandonedOffscreenBindings(self: *RenderCommandEncoder) void {
        const ir = self.image_renderer orelse {
            self.offscreen_depth = 0;
            return;
        };
        for (self.offscreen_stack[0..self.offscreen_depth]) |layer| {
            ir.unregisterTextureBinding(layer.texture_id);
        }
        self.offscreen_depth = 0;
    }

    /// 设置字体选择器。
    ///
    /// ⚠️ **不要在这里给 selector 装 drawn-width 回调**。RenderCommandEncoder 是
    /// **逐帧按值新建**的栈上临时量（AppRenderer.getEncoder 每帧 return 一个），
    /// 把 `self` 存进生命周期跨帧的 FontSelector 里，帧一结束就是悬垂指针 ——
    /// 下一次布局测量即踩，表现为 e2e 里"RPC 超时"而非崩溃堆栈，极难归因。
    /// 该回调必须绑到生命周期稳定的 TextRenderer 上，由宿主在建窗时装、
    /// 拆窗时摘（由宿主的字体加载代码负责）。
    pub fn setFonts(self: *RenderCommandEncoder, fonts: *FontSelector) void {
        self.fonts = fonts;
    }

    /// 初始化 renderer 内部 FontSelector 的 lazy derived font cache
    /// 必须在 setFonts 之后调用（setFonts 为借用指针，不发生拷贝）
    pub fn initFontDerivedCache(self: *RenderCommandEncoder, allocator: std.mem.Allocator) void {
        if (self.fonts) |fs| {
            fs.initDerivedCache(allocator);
        }
    }

    /// 释放 renderer 内部 FontSelector 的 lazy derived font cache
    pub fn deinitFontDerivedCache(self: *RenderCommandEncoder) void {
        if (self.fonts) |fs| {
            fs.deinitDerivedCache();
        }
    }

    /// 开始新帧
    /// width/height: 逻辑像素; scale: DPI 缩放因子 (Retina=2.0)
    pub fn beginFrame(self: *RenderCommandEncoder, width: f32, height: f32, scale: f32) void {
        self.frame_index += 1;
        // reset 全局 draw call 计数器
        gpu.Backend.RenderPass.frame_draw_call_count = 0;
        // reset per-frame pass count audit counter
        self.pass_count = 0;
        self.pass_sites = .{0} ** 8;
        self.opacity_mode_depth = 0;
        self.opacity_mode_overflow_depth = 0;
        self.retained_skip_depth = 0;
        self.retained_pending_depth = 0;
        self.retained_begin_seq = 0;
        self.retained_hash_count = 0;
        self.rounded_clip_mode_depth = 0;
        self.rounded_clip_overflow_depth = 0;
        self.sdf_renderer.beginFrame(width, height, scale, @truncate(self.frame_index));
        self.text_renderer.beginFrame(width, height, scale);
        if (self.image_renderer) |ir| ir.beginFrame(width, height, scale);
        if (self.icon_renderer) |ir| ir.beginFrame(width, height, scale);
        if (self.persistent.path_renderer) |*pr| pr.beginFrame(width, height, scale);
        self.clip_depth = 0;
        self.clip_overflow_depth = 0;
        self.offscreen_depth = 0;
        self.offscreen_pool.resetFrame();
        // 回收长期没被认领的 retained 纹理（layer 消失后不该一直钉着显存）。
        self.offscreen_pool.sweepRetained(self.frame_index);
        self.offscreen_pool.sweepIdle(self.frame_index);
        backdrop_blur.resetDynamicUniformOffsets(self);
        self.viewport_width = width;
        self.viewport_height = height;
        self.scale = scale;
        self.syncRectClipState();
        self.syncTextClipX();
        self.syncRendererClipMask();
    }

    /// 编码 cx 的 lowered DisplayItem 切片到 sdf/image/text renderer，flush() 后
    /// 一次性提交 GPU。调用方不直接持有 IR 切片 — encoder 自己调
    /// cx.lowerForEncoderPaintTable() (B-7 主路径切换)。
    pub fn encodeDisplay(self: *RenderCommandEncoder, cx: anytype) !void {
        self.layer_outcome_count = 0;
        self.captureLayerTreeDamage(&cx.layer_tree);
        try self.encodeCommands(cx.lowerForEncoderPaintTable());
        self.writebackLayerOutcomes(&cx.layer_tree);
    }

    /// layer_tree → encoder：快照生产端（addDamage）申报的 per-layer 脏区。
    /// consume-clear：取走即清 —— 生产环境不保证每帧调 LayerTree.beginFrame，
    /// 不清会让一次申报永久生效（并回脏区的反馈环 = partial 永远 100%）。
    fn captureLayerTreeDamage(self: *RenderCommandEncoder, lt: anytype) void {
        self.layer_damage_count = 0;
        for (lt.layers.items) |*l| {
            if (!l.alive or !l.needs_repaint) continue;
            const comp = l.composited orelse continue;
            const d = l.damage_rect;
            l.needs_repaint = false;
            l.damage_rect = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
            if (d.max_x <= d.min_x or d.max_y <= d.min_y) continue;
            if (self.layer_damage_count >= self.layer_damage_ids.len) continue;
            self.layer_damage_ids[self.layer_damage_count] = comp.stable_id;
            self.layer_damage_rects[self.layer_damage_count] = .{ d.min_x, d.min_y, d.max_x, d.max_y };
            self.layer_damage_count += 1;
        }
    }

    /// encoder → layer_tree：写回 retained 层本帧实际重绘决策。
    fn writebackLayerOutcomes(self: *RenderCommandEncoder, lt: anytype) void {
        var i: usize = 0;
        while (i < self.layer_outcome_count) : (i += 1) {
            lt.noteEncoderOutcome(
                self.layer_outcome_ids[i],
                self.layer_outcome_kinds[i],
                self.layer_outcome_rects[i],
            );
        }
    }

    /// opacity_layer 在 retained begin 决策点调用（hit/opened_for_repaint）。
    pub fn recordLayerOutcome(self: *RenderCommandEncoder, stable_id: u32, kind: u8, rect: [4]f32) void {
        if (self.layer_outcome_count >= self.layer_outcome_ids.len) return;
        self.layer_outcome_ids[self.layer_outcome_count] = stable_id;
        self.layer_outcome_kinds[self.layer_outcome_count] = kind;
        self.layer_outcome_rects[self.layer_outcome_count] = rect;
        self.layer_outcome_count += 1;
    }

    /// Prewarm text atlas — 在 GPU wait 前预生成 glyph，避免渲染时 stall。
    pub fn prewarmDisplay(self: *RenderCommandEncoder, cx: anytype) !void {
        try self.prewarmTextCommands(cx.lowerForEncoderPaintTable());
    }

    /// prewarm 的输入指纹：只覆盖「决定需要哪些字形」的字段。
    ///
    /// 位置 / 颜色 / clip 一律**不进**签名 —— 滚动时它们每帧都变，但字形集合
    /// 完全不变，把它们算进去等于让签名永不命中，优化直接失效。
    /// 反过来，凡是能改变字形集合的都必须进：文本字节、字号、字重、
    /// font_flags（italic/mono/symbol 选不同字体）、monospace cell 宽
    /// （fixed_advance 影响 ligature 切分）、raster policy（影响 subpixel 分箱键）。
    fn prewarmSignature(commands: anytype) u64 {
        var h = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        for (commands) |it| {
            if (it.kind != .text) continue;
            if (it.text_content.len == 0 or it.text_font_size <= 0) continue;
            h.update(it.text_content);
            h.update(std.mem.asBytes(&it.text_font_size));
            h.update(std.mem.asBytes(&it.text_font_weight));
            h.update(std.mem.asBytes(&it.text_font_flags));
            h.update(std.mem.asBytes(&it.text_monospace_char_width));
            h.update(std.mem.asBytes(&it.text_raster_policy));
        }
        return h.final();
    }

    fn prewarmTextCommands(self: *RenderCommandEncoder, commands: anytype) !void {
        // 帧间跳过：文本负载与上帧完全一致且 atlas 没驱逐过页 → 字形必然全在，
        // 整趟 prewarm 无产出。详见 TextRenderer.prewarm_signature。
        const signature = prewarmSignature(commands);
        const gc_gen = self.text_renderer.atlas.gc_generation;
        if (self.text_renderer.prewarm_signature_valid and
            self.text_renderer.prewarm_signature == signature and
            self.text_renderer.prewarm_gc_generation == gc_gen)
        {
            return;
        }

        // 只为把缺失字形提前塞进 atlas —— 关掉实例产出，避免"文本编码两遍"
        // （审查报告 P1）。base_* 仍保留做兜底断言：理论上 glyph_only 下
        // 实例数不该变，若变了说明有路径绕过了这个开关。
        const base_nearest = self.text_renderer.instances_nearest.items.len;
        const base_linear = self.text_renderer.instances_linear.items.len;
        self.text_renderer.glyph_only = true;
        defer self.text_renderer.glyph_only = false;
        var offscreen_x: [8]f32 = [_]f32{0} ** 8;
        var offscreen_y: [8]f32 = [_]f32{0} ** 8;
        var offscreen_depth: usize = 0;

        for (commands) |it| {
            switch (it.kind) {
                .text => {
                    if (it.text_content.len == 0 or it.text_font_size <= 0) continue;
                    var ox: f32 = 0;
                    var oy: f32 = 0;
                    for (0..offscreen_depth) |idx| {
                        ox -= offscreen_x[idx];
                        oy -= offscreen_y[idx];
                    }
                    const use_italic = (it.text_font_flags & 1) != 0;
                    const use_mono = (it.text_font_flags & 2) != 0;
                    const use_sym = (it.text_font_flags & 4) != 0;
                    const raster = wire_types.textRasterControls(it.text_raster_policy);
                    if (it.text_spans) |s| {
                        try self.encodeTextWithSpans(
                            it.geom.x + ox,
                            it.geom.y + oy,
                            it.text_content,
                            it.color,
                            it.text_font_size,
                            it.text_font_weight,
                            it.text_font_family,
                            use_sym,
                            use_mono,
                            it.text_monospace_char_width,
                            use_italic,
                            raster.force_linear,
                            raster.shader_snap,
                            s,
                        );
                    } else {
                        try self.encodeText(
                            it.geom.x + ox,
                            it.geom.y + oy,
                            it.text_content,
                            it.color,
                            it.text_font_size,
                            it.text_font_weight,
                            it.text_font_family,
                            use_sym,
                            use_mono,
                            it.text_monospace_char_width,
                            use_italic,
                            raster.force_linear,
                            raster.shader_snap,
                        );
                    }
                },
                .control => switch (it.control_kind) {
                    .begin_opacity_layer, .begin_rounded_clip => {
                        if (offscreen_depth < offscreen_x.len) {
                            offscreen_x[offscreen_depth] = it.geom.x;
                            offscreen_y[offscreen_depth] = it.geom.y;
                            offscreen_depth += 1;
                        }
                    },
                    .end_opacity_layer, .end_rounded_clip => {
                        if (offscreen_depth > 0) offscreen_depth -= 1;
                    },
                    else => {},
                },
                else => {},
            }
        }

        // glyph_only 下不该有新实例产生；万一某条路径绕过了开关，这里仍然兜底
        // 截断，保持与旧行为一致（宁可多一次 shrink，也不要把 prewarm 的实例
        // 泄漏进正式 pass 导致文字画两遍）。
        self.text_renderer.instances_nearest.shrinkRetainingCapacity(base_nearest);
        self.text_renderer.instances_linear.shrinkRetainingCapacity(base_linear);

        // 只有真正跑完整趟 prewarm 才记签名 —— 此刻 atlas 对这份文本必然完备。
        // 注意读的是**跑完之后**的 gc_generation：本帧插入过程中若触发
        // forceEvictOldestPage，代号会变，那就不能拿旧值当基线。
        self.text_renderer.prewarm_signature = signature;
        self.text_renderer.prewarm_gc_generation = self.text_renderer.atlas.gc_generation;
        self.text_renderer.prewarm_signature_valid = true;
    }

    /// 统一编码循环：
    /// 1. 跳过空结构块（支持嵌套）
    /// 2. 在结构边界之间构建局部可排序 cluster
    /// 3. 其余命令走常规 dispatch
    pub fn encodeCommands(self: *RenderCommandEncoder, commands: anytype) !void {
        self.blur_applied_count = 0;
        if (std.posix.getenv("ZENIT_DEBUG_CMDSTREAM") != null) {
            std.debug.print("[cmdstream] ── frame {d} commands={d} ──\n", .{ self.frame_index, commands.len });
            for (commands, 0..) |it, ci| {
                if (it.kind == .control) {
                    std.debug.print("[cmdstream] {d}: ctl {s} geom=({d:.0},{d:.0},{d:.0}x{d:.0}) draw=({d:.0},{d:.0}) dt=({d:.0},{d:.0}) udt={}\n", .{
                        ci, @tagName(it.control_kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.draw_x, it.draw_y, it.draw_transform[4], it.draw_transform[5], it.use_draw_transform,
                    });
                } else {
                    std.debug.print("[cmdstream] {d}: {s} geom=({d:.0},{d:.0},{d:.0}x{d:.0}) a={d} txt=\"{s}\"\n", .{
                        ci, @tagName(it.kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.color.a, if (it.kind == .text) it.text_content[0..@min(it.text_content.len, 16)] else "",
                    });
                }
            }
        }
        self.computeRetainedContentHashes(commands);
        var cluster = LocalSortCluster{};
        var i: usize = 0;
        while (i < commands.len) {
            const tok = paint_fp.structuralToken(commands[i]);
            if (paint_fp.isBeginStructuralToken(tok)) {
                if (paint_fp.tryFindNoOpStructuralBlock(commands, i)) |block| {
                    // GPU retained（2026-07-30 审查修正）：被整块跳过的空结构块
                    // 里可能含 begin_opacity_layer —— 预扫描已经给它们编了号，
                    // 这里不补推 retained_begin_seq 的话，**后续所有层都会拿到
                    // 前移一位的错误指纹**，跨帧稳定的错误指纹 = 内容变了却判
                    // 命中 = 画面停在陈旧内容。
                    for (commands[i .. block.end_index + 1]) |sk| {
                        if (sk.kind == .control and sk.control_kind == .begin_opacity_layer) {
                            self.retained_begin_seq += 1;
                        }
                    }
                    i = block.end_index + 1;
                    continue;
                }
            }
            if (tok != .none) {
                try self.flushLocalSortCluster(commands, &cluster);
                try self.dispatchCommand(commands[i]);
                i += 1;
                continue;
            }

            switch (cluster.tryAppend(commands, i)) {
                .none => {},
                .overlap => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    const retry = cluster.tryAppend(commands, i);
                    if (retry != .none) {
                        try self.dispatchCommand(commands[i]);
                    }
                },
                .capacity => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    const retry = cluster.tryAppend(commands, i);
                    if (retry != .none) {
                        try self.dispatchCommand(commands[i]);
                    }
                },
                .unsortable => {
                    try self.flushLocalSortCluster(commands, &cluster);
                    try self.dispatchCommand(commands[i]);
                },
            }
            i += 1;
        }
        try self.flushLocalSortCluster(commands, &cluster);
    }

    /// GPU retained 的**内容指纹**预扫描。
    ///
    /// 为什么不能直接用 display item 上带来的 `surface_content_version`：
    /// 那是 layer **根节点自己**的 content version（node_dirty 里 markLayoutDirty
    /// 等处 +1），descendant 内容变化并不会让它变。CPU 侧的缓存路径之所以安全，
    /// 是因为它另外查了 `subtree_render` 脏位；encoder 拿不到那个信息。
    /// 曾经直接用它做 key —— 结果 Modal 打开时命中了上一帧的空纹理，
    /// 整个对话框画不出来（e2e 逮到）。
    ///
    /// 现在改成对 begin..end 之间**实际要编码的命令**取哈希：内容变了指纹必变，
    /// 内容没变指纹必同，与 descendant 深度无关 —— 这是自洽的判据，不依赖上游
    /// 脏标记的语义。代价是每帧一次线性扫描（无分配，纯算术）。
    ///
    /// 指纹只覆盖会影响**离屏纹理像素**的字段。合成参数（opacity/transform/
    /// draw_*）故意**不计入** —— 它们只影响回贴，正是 retained 想省下的
    /// "内容不变、只改 transform/opacity" 的场景。
    pub fn computeRetainedContentHashes(self: *RenderCommandEncoder, commands: anytype) void {
        self.retained_hash_count = 0;
        self.damage_scratch_count = 0;
        self.damage_ranges = [_]DamageRange{.{}} ** 64;
        // backdrop：子树里有背景模糊（玻璃）。玻璃像素取决于层**身后**的画面，
        // 身后一变缓存就过期，而层内容指纹看不见身后 —— 这种层（及其所有
        // 外层，外层纹理里烘着内层玻璃）永不复用缓存纹理。
        var stack: [64]struct { idx: usize, hasher: std.hash.Wyhash, backdrop: bool = false } = undefined;
        var depth: usize = 0;
        var untracked_depth: usize = 0;
        // 非平坦层捕获状态（2026-07-30 晚扩展）：
        //   fold_*：嵌套 opacity 子树折叠成单个 item（digest 累计子树全部命令 +
        //           begin 自身合成参数；bounds = 合成矩形外扩）。运行时安全性：
        //           子层内容 pass 画进自己的纹理，父 pass 的 damage scissor 在
        //           end 恢复时由 applyOffscreenTargetViewport 重新取交生效。
        //   clip_rects：push_clip 的矩形栈 —— pop_clip 作为 item 时 bounds 取
        //           配对 push 的矩形（clip 参数变化经 index-diff 会把新旧矩形都
        //           并入脏区，覆盖裁剪可见性变化）。clip 全走 shader uniform，
        //           不碰 GPU scissor，运行时无需额外处理。
        //   nest_offsets：**平移-only** 嵌套 opacity 子树（无 transform/rotate）
        //           不折叠 —— 逐条递归捕获，bounds 加上嵌套层在父坐标系的偏移。
        //           这是 overlay（Modal/Popover 内容都包在嵌套 surface 里）能拿到
        //           细粒度脏区的关键：折叠粒度 = 整个弹层矩形，永远超 60% 阈值。
        //           带 transform 的子树才回退折叠（合成矩形无法逐条映射）。
        var fold_depth: usize = 0;
        var fold_hasher = std.hash.Wyhash.init(0);
        var fold_bounds: [4]f32 = .{ 0, 0, 0, 0 };
        var clip_rects: [16][4]f32 = undefined;
        var clip_count: usize = 0;
        var nest_offsets: [6][2]f32 = undefined;
        var nest_rects: [6][4]f32 = undefined;
        var capture_depth: usize = 0; // 已进入的平移-only 嵌套层数

        for (commands) |it| {
            // damage-rect 捕获：顶层 layer（depth==1 = 只有 stack[0] 开着）的内容
            // 命令逐条记 {单条指纹, 外扩 bounds}。层自己的 end token 不算内容。
            // path（bounds 从点集算）、push/pop_clip（矩形/圆角/椭圆）、嵌套
            // opacity 子树（折叠）都可捕获；blur/rounded_clip 子树、polygon clip、
            // 非轴对齐 transform 的嵌套层保持 unsafe → 整层重画。
            if (fold_depth > 0) {
                paint_fp.hashPaintItemInto(&fold_hasher, it);
                if (it.kind == .control) switch (it.control_kind) {
                    .begin_opacity_layer => fold_depth += 1,
                    .end_opacity_layer => {
                        fold_depth -= 1;
                        if (fold_depth == 0 and stack[0].idx < self.damage_ranges.len) {
                            const range = &self.damage_ranges[stack[0].idx];
                            if (range.captured and range.safe and !range.overflow) {
                                if (self.damage_scratch_count < self.damage_scratch.len) {
                                    self.damage_scratch[self.damage_scratch_count] = .{
                                        .digest = fold_hasher.final(),
                                        .bounds = fold_bounds,
                                    };
                                    self.damage_scratch_count += 1;
                                    range.len += 1;
                                } else {
                                    range.overflow = true;
                                }
                            }
                        }
                    },
                    else => {},
                };
            } else if (depth >= 1 and depth == capture_depth + 1 and stack[0].idx < self.damage_ranges.len) {
                const is_own_end = it.kind == .control and it.control_kind == .end_opacity_layer and depth == 1;
                if (!is_own_end) {
                    const range = &self.damage_ranges[stack[0].idx];
                    if (range.captured and range.safe and !range.overflow) capture: {
                        // 当前累计偏移（平移-only 嵌套链在顶层 surface 坐标系的原点）
                        var off_x: f32 = 0;
                        var off_y: f32 = 0;
                        for (nest_offsets[0..capture_depth]) |o| {
                            off_x += o[0];
                            off_y += o[1];
                        }
                        var bounds: [4]f32 = undefined;
                        if (it.kind == .control) {
                            switch (it.control_kind) {
                                .push_clip => {
                                    // polygon clip 的点集只有指针、不进指纹 → 保守 unsafe
                                    if (it.clip_shape_kind == 3 or clip_count >= clip_rects.len) {
                                        range.safe = false;
                                        break :capture;
                                    }
                                    bounds = .{ it.geom.x + off_x - 2, it.geom.y + off_y - 2, it.geom.w + 4, it.geom.h + 4 };
                                    clip_rects[clip_count] = bounds;
                                    clip_count += 1;
                                },
                                .pop_clip => {
                                    // 弹出的 clip 不是本层压的（不配对）→ unsafe
                                    if (clip_count == 0) {
                                        range.safe = false;
                                        break :capture;
                                    }
                                    clip_count -= 1;
                                    bounds = clip_rects[clip_count];
                                },
                                .begin_opacity_layer => {
                                    // 坐标合同（由合成公式推导，见 endOpacityLayer 第 6.5/7 步）：
                                    // 嵌套纹理 (0,0) 对应嵌套-local 点 (geom.x, geom.y)，合成落在
                                    // parent-raw 的 draw 原点 → 嵌套-local q 映射到 parent-raw =
                                    // q + (draw_origin - geom.xy)。plain（无 dt）时 draw==geom →
                                    // 偏移 0（in-flow 子层内容坐标本来就与父同系）。
                                    const translate_only = it.use_draw_transform and it.rotate == 0 and
                                        it.draw_transform[0] == 1 and it.draw_transform[1] == 0 and
                                        it.draw_transform[2] == 0 and it.draw_transform[3] == 1;
                                    const plain = !it.use_draw_transform and it.rotate == 0;
                                    if ((plain or translate_only) and capture_depth < nest_offsets.len) {
                                        const pad: f32 = 4;
                                        var org_x: f32 = 0;
                                        var org_y: f32 = 0;
                                        var bx = it.geom.x;
                                        var by = it.geom.y;
                                        if (translate_only) {
                                            org_x = it.draw_transform[4] - it.geom.x;
                                            org_y = it.draw_transform[5] - it.geom.y;
                                            bx = it.draw_transform[4];
                                            by = it.draw_transform[5];
                                        } else if (!std.math.isNan(it.draw_x) and it.draw_w > 0 and it.draw_h > 0) {
                                            org_x = it.draw_x - it.geom.x;
                                            org_y = it.draw_y - it.geom.y;
                                            bx = it.draw_x;
                                            by = it.draw_y;
                                        }
                                        bounds = .{ bx + off_x - pad, by + off_y - pad, it.geom.w + pad * 2, it.geom.h + pad * 2 };
                                        nest_offsets[capture_depth] = .{ org_x + off_x, org_y + off_y };
                                        nest_rects[capture_depth] = bounds;
                                        capture_depth += 1;
                                    } else if (paint_fp.nestedCompositeBounds(it)) |b| {
                                        // 轴对齐 transform：整棵子树折叠成单个 item
                                        fold_hasher = std.hash.Wyhash.init(0);
                                        paint_fp.hashPaintItemInto(&fold_hasher, it);
                                        fold_bounds = .{ b[0] + off_x, b[1] + off_y, b[2], b[3] };
                                        fold_depth = 1;
                                        break :capture; // 折叠 item 推迟到子树 end 落盘
                                    } else {
                                        // 旋转/非轴对齐 transform：合成范围无法便宜地界定
                                        range.safe = false;
                                        break :capture;
                                    }
                                },
                                .end_opacity_layer => {
                                    // 平移-only 嵌套层收尾：end 作为 item（digest 恒定，
                                    // 只用于 index 对齐；bounds = 该层合成矩形，保守）
                                    capture_depth -= 1;
                                    bounds = nest_rects[capture_depth];
                                },
                                else => {
                                    // blur/rounded_clip 会切 pass / 重置 scissor
                                    range.safe = false;
                                    break :capture;
                                },
                            }
                        } else {
                            bounds = if (it.kind == .path) paint_fp.pathItemBounds(it) else paint_fp.damageItemBounds(it);
                            bounds[0] += off_x;
                            bounds[1] += off_y;
                        }
                        if (self.damage_scratch_count < self.damage_scratch.len) {
                            var ih = std.hash.Wyhash.init(0);
                            paint_fp.hashPaintItemInto(&ih, it);
                            self.damage_scratch[self.damage_scratch_count] = .{
                                .digest = ih.final(),
                                .bounds = bounds,
                            };
                            self.damage_scratch_count += 1;
                            range.len += 1;
                        } else {
                            range.overflow = true;
                        }
                    }
                }
            }
            // 先把本条命令喂给所有还开着的层（嵌套层共享内层内容）。
            //
            // ⚠️ **begin_opacity_layer 也必须喂给外层**（2026-07-30 Sheet 冻结
            // 回归的根因）：嵌套子层的合成发生在**父层缓存纹理内部** —— 父层
            // hit 时子层合成整个被跳过，像素烤在父纹理里。子层的 transform/
            // opacity 每帧在变（Sheet 滑入、Popover 缩放），父层指纹看不见的话
            // 就会帧帧 stale hit，整窗画面冻结到动画结束才跳变。
            // "合成参数不计入指纹"只对**本层自己的** begin token 成立（它的
            // 合成在缓存内容之外）—— 所以喂外层（stack[0..depth]，不含刚要
            // 压栈的自己）。
            var di: usize = 0;
            while (di < depth) : (di += 1) paint_fp.hashPaintItemInto(&stack[di].hasher, it);

            if (it.kind != .control) continue;
            switch (it.control_kind) {
                .begin_blur_layer => {
                    var bi: usize = 0;
                    while (bi < depth) : (bi += 1) stack[bi].backdrop = true;
                },
                .begin_opacity_layer => {
                    if (untracked_depth == 0 and depth < stack.len) {
                        var hasher = std.hash.Wyhash.init(0);
                        // 几何尺寸进指纹：尺寸变了纹理内容必然要重画。
                        hasher.update(std.mem.asBytes(&it.geom.w));
                        hasher.update(std.mem.asBytes(&it.geom.h));
                        // scale 也必须进指纹（2026-07-30 审查补）：池的尺寸键是
                        // 64px 桶化后的 alloc 尺寸，跨显示器/分数缩放切换时新旧
                        // 物理尺寸可能落同一桶 —— 不喂 scale 会命中按旧 scale
                        // 光栅化的像素（模糊/拉伸 + UV 对不上旧 used 区域）。
                        hasher.update(std.mem.asBytes(&self.scale));
                        stack[depth] = .{ .idx = self.retained_hash_count, .hasher = hasher };
                        // damage-rect：顶层 layer 开始捕获（序号超 64 的层不捕获）。
                        // 捕获状态按层归零（上一层未配平的 clip/fold 不能串层）。
                        if (depth == 0) {
                            clip_count = 0;
                            fold_depth = 0;
                            capture_depth = 0;
                        }
                        if (depth == 0 and self.retained_hash_count < self.damage_ranges.len) {
                            self.damage_ranges[self.retained_hash_count] = .{
                                .start = @intCast(self.damage_scratch_count),
                                .len = 0,
                                .safe = true,
                                .overflow = false,
                                .captured = true,
                            };
                        }
                        depth += 1;
                    } else {
                        // Hash slots beyond the bounded stack stay zero (forced
                        // cache miss), but their ends must not pop a tracked
                        // outer frame early.
                        untracked_depth += 1;
                    }
                    // 每个 begin 都要占一个槽（即使栈满也要占，否则 begin 与
                    // 消费端的序号对不上 —— 序号错位 = 拿错别人的指纹）。
                    if (self.retained_hash_count < self.retained_hashes.len) {
                        self.retained_hashes[self.retained_hash_count] = 0;
                    }
                    self.retained_hash_count += 1;
                },
                .end_opacity_layer => {
                    if (untracked_depth > 0) {
                        untracked_depth -= 1;
                    } else if (depth > 0) {
                        // 注意：end 自身已经在上面喂给了**包括本层在内**的所有
                        // 开着的层，所以本层指纹含一个 end 标记，天然区分
                        // "内容以 end 结束" 与 "内容还没结束"。
                        depth -= 1;
                        const fr = &stack[depth];
                        if (fr.idx < self.retained_hashes.len) {
                            // 0 是"无效指纹"哨兵，真算出 0 时挪一位避免误判。
                            // 含玻璃的层恒为 0：强制每帧重画（背景采样必须是当前帧的）。
                            const h = fr.hasher.final();
                            // 含玻璃的层恒为 0（无效指纹 → 永不 retained 命中）：
                            // 背景采样必须是当前帧的。
                            self.retained_hashes[fr.idx] = if (fr.backdrop) 0 else if (h == 0) 1 else h;
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// 把一条 paint 命令里**影响像素**的字段喂进指纹。
    /// 宁可多喂（多算一次重画）也不能漏喂（漏喂 = 内容变了却判命中 = 画面陈旧）。
    fn flushLocalSortCluster(self: *RenderCommandEncoder, commands: anytype, cluster: *LocalSortCluster) !void {
        if (cluster.isEmpty()) return;

        var dispatch_order_buf: [local_sort_cluster_capacity]usize = undefined;
        const dispatch_order = cluster.buildDispatchOrder(&dispatch_order_buf);

        for (dispatch_order) |index| {
            try self.dispatchCommand(commands[index]);
        }
        cluster.clear();
    }

    /// 统一命令分发 — 通过 anytype 接 DisplayItem union（render 模块不直接依赖 ui 模块）
    ///
    /// Z-order barrier: SDF (rect/border/shadow) 和 text 分属不同 GPU pipeline，
    /// 各自积累 instances 后批量 flush。默认 flush 顺序 SDF→Image→Text 意味着
    /// 背景总在文字下方——但节点树的 z-order 可能要求"后来的背景遮住先前的文字"
    /// (如 sticky gutter 覆盖滚动文本、z-index overlay 等)。
    /// 解决: 当即将分派 SDF 命令时，若 text pipeline 已有 pending instances，
    /// 说明这个 SDF 图元需要画在已有文字上方——必须先 flush 清空所有 pipeline，
    /// 再开始新的一批，从而保证正确的 z-order 绘制顺序。
    /// 获取当前离屏层的坐标偏移（将屏幕坐标转换为离屏局部坐标）
    /// 在主 pass 中返回 (0, 0)；在离屏层中返回 (-layer.x, -layer.y)
    pub inline fn offscreenOffset(self: *const RenderCommandEncoder) [2]f32 {
        if (self.offscreen_depth == 0) return .{ 0, 0 };
        // 累积所有嵌套层的偏移
        // 注：每层 offscreen_stack[i].x/y 是**该层在父 surface 内的 outer-local 坐标**（不是 world）。
        // beginOpacityLayer 入栈前已减去外层累积偏移（见 beginOpacityLayer 内的 outer-local 转换）。
        // 因此 child paint 的 world coord 减去累积值 = inner-surface-local。
        var dx: f32 = 0;
        var dy: f32 = 0;
        for (self.offscreen_stack[0..self.offscreen_depth]) |layer| {
            dx -= layer.x;
            dy -= layer.y;
        }
        return .{ dx, dy };
    }

    pub inline fn localizeDrawTransformForCurrentTarget(self: *const RenderCommandEncoder, draw_transform: [6]f32) [6]f32 {
        var localized = draw_transform;
        const off = self.offscreenOffset();
        localized[4] += off[0];
        localized[5] += off[1];
        return localized;
    }

    // Clip 几何代数纯函数簇已析出到 command_encoder/clip_geometry.zig
    // （比较/求交/归一），encoder 这边只留 clip **栈**的推进与回退。
    const roundedClipEqual = clip_geometry.roundedClipEqual;
    const clipPolygonEqual = clip_geometry.clipPolygonEqual;

    pub fn activeRoundedClip(self: *const RenderCommandEncoder) ?RoundedClipState {
        var i = self.clip_depth;
        while (i > 0) {
            i -= 1;
            const clip = self.logical_clip_stack[i];
            if (clip.shape_kind != .rect) return clip;
        }
        return null;
    }

    pub fn currentRectClip(self: *const RenderCommandEncoder) ?[4]f32 {
        if (self.clip_depth == 0) return null;
        return self.effective_rect_clip_stack[self.clip_depth - 1];
    }

    /// 重开/恢复 render pass 后统一设置 viewport+scissor：
    /// 当前目标是离屏纹理时限到该层的 used 区域（纹理按桶分配比内容大，
    /// NDC 默认铺满 alloc 会拉伸内容）；主目标时 scissor 全 drawable。
    pub fn applyOffscreenTargetViewport(self: *RenderCommandEncoder) void {
        const rp = self.render_pass orelse return;
        if (self.offscreen_depth > 0) {
            const layer = self.offscreen_stack[self.offscreen_depth - 1];
            if (layer.used_tex_w == 0 or layer.used_tex_h == 0) return;
            rp.setViewport(0, 0, @floatFromInt(layer.used_tex_w), @floatFromInt(layer.used_tex_h), 0, 1);
            // damage-rect：部分重绘层的 scissor 必须在每次 pass 恢复后重新取交
            //（嵌套 pass 的 re-begin 会把 scissor 重置成整纹理）。
            if (layer.damage_scissor) |d| {
                const x1 = @min(d.x + d.w, layer.used_tex_w);
                const y1 = @min(d.y + d.h, layer.used_tex_h);
                rp.setScissorRect(d.x, d.y, x1 -| d.x, y1 -| d.y);
                if (self.persistent.path_renderer) |*pr| pr.damage_scissor = .{ d.x, d.y, x1 -| d.x, y1 -| d.y };
            } else {
                rp.setScissorRect(0, 0, layer.used_tex_w, layer.used_tex_h);
                if (self.persistent.path_renderer) |*pr| pr.damage_scissor = null;
            }
        } else {
            const vw = physicalPixelExtent(self.viewport_width, self.scale);
            const vh = physicalPixelExtent(self.viewport_height, self.scale);
            rp.setScissorRect(0, 0, vw, vh);
            if (self.persistent.path_renderer) |*pr| pr.damage_scissor = null;
        }
    }

    pub fn syncRectClipState(self: *RenderCommandEncoder) void {
        const rect = self.currentRectClip();
        self.sdf_renderer.setRectClip(rect);
        self.text_renderer.setRectClip(rect);
        if (self.image_renderer) |ir| ir.setRectClip(rect);
        if (self.icon_renderer) |ir| ir.setRectClip(rect);
        if (self.persistent.path_renderer) |*pr| pr.setRectClip(rect);
    }

    pub const intersectClipRects = clip_geometry.intersectClipRects;

    // backdrop 采样区域解析（静态函数，无 self）已析出到
    // command_encoder/backdrop_capture.zig。backdrop_blur.zig 的调用点是
    // `@TypeOf(encoder.*).computeBackdropCaptureRegion(...)` 反射式，这里
    // 保留同名 decl 即零改动；类型一并 re-export。像素域转换原语见文件
    // 头部（pixel_domain.zig），不再从这里二次转发以免歧义。
    pub const BackdropCaptureRegion = backdrop_capture.BackdropCaptureRegion;
    pub const computeBackdropCaptureRegion = backdrop_capture.computeBackdropCaptureRegion;

    pub fn clearTextureToTransparent(self: *RenderCommandEncoder, texture: gpu.Backend.TextureBinding) bool {
        var view = texture.createView();
        const pass = self.gpu_command_encoder.?.beginRenderPass(.{
            .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            }},
        }) catch {
            view.destroy();
            return false;
        };
        self.pass_count += 1; // v0.9-§D audit
        self.pass_sites[4] += 1; // clear_texture
        view.destroy();
        var mutable_pass = pass;
        mutable_pass.end();
        return true;
    }

    /// 落盘全部 pending 批次。
    ///
    /// ⚠️ 单个 renderer 的资源上限**不能**中止整帧编码。
    ///
    /// 这里曾经是一路 `try`：任一 renderer 返回 `UniformSlotsExhausted`
    /// （每帧 uniform 槽 256 个，一次 rounded-clip 变化吃一个），错误就沿
    /// `flushAllPending → dispatchCommand → encodeCommands` 抛到最外层，
    /// 调用方 `enc.encodeDisplay(...) catch {}` 又把它吞掉 —— 于是这一批
    /// 之后的**所有**命令静默不发射，且没有任何报错。
    ///
    /// 实测：git diff 滚动时 52 行 diff 每行一次 clip 变化，256 槽在一帧内
    /// 耗尽，排在行区后面的动作栏（Discard/Stage）整条从画面消失，而布局
    /// rect、display list、命令流全部正常 —— 只看节点树永远查不出来。
    ///
    /// 现在每个 renderer 各自 catch：一个失败只损失它自己那一批，后续
    /// renderer 与后续命令照常编码。错误计数仍留在各 renderer 里供诊断。
    fn flushAllPending(self: *RenderCommandEncoder) !void {
        const rp = self.render_pass orelse return;
        if (self.sdf_renderer.instances.items.len > 0) {
            self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
        }
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
        }
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
        }
        if (self.persistent.path_renderer) |*pr| {
            if (pr.vertices.items.len > 0) pr.flush(rp) catch |err| self.noteFlushDropped("path", err);
        }
        if (self.text_renderer.getPendingInstanceCount() > 0) {
            self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn noteFlushDropped(self: *RenderCommandEncoder, comptime which: []const u8, err: anyerror) void {
        _ = self;
        std.log.warn("[encoder] " ++ which ++ " flush dropped a batch: {s} (frame continues)", .{@errorName(err)});
    }

    /// path 命令编码前调用：落盘除 path 外的全部 pending（保证 path 画在其上），
    /// path 自身留在 path_renderer 里跨命令合批。
    fn flushNonPathPending(self: *RenderCommandEncoder) !void {
        const rp = self.render_pass orelse return;
        if (self.sdf_renderer.instances.items.len > 0) self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
        }
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
        }
        if (self.text_renderer.getPendingInstanceCount() > 0) {
            self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn flushPathPending(self: *RenderCommandEncoder) !void {
        if (self.persistent.path_renderer) |*pr| {
            if (pr.draw_calls.items.len > 0) {
                if (self.render_pass) |rp| pr.flush(rp) catch |err| self.noteFlushDropped("path", err);
            }
        }
    }

    fn syncClipStateAfterMutation(self: *RenderCommandEncoder, prev_shape_clip: ?RoundedClipState) !void {
        const next_shape_clip = self.activeRoundedClip();
        if (!roundedClipEqual(prev_shape_clip, next_shape_clip)) {
            try self.flushAllPending();
        }
        self.syncRectClipState();
        self.syncRendererClipMask();
        self.syncTextClipX();
    }

    fn forceRoundedClipLayer(self: *RenderCommandEncoder) bool {
        return self.force_rounded_clip_layer orelse blk: {
            const forced = std.posix.getenv("ZENIT_ROUNDED_CLIP_LAYER") != null;
            self.force_rounded_clip_layer = forced;
            break :blk forced;
        };
    }

    pub fn syncRendererClipMask(self: *RenderCommandEncoder) void {
        const active = self.activeRoundedClip();
        if (self.clip_mask_synced and roundedClipEqual(self.last_synced_clip_mask, active)) return;
        self.clip_mask_synced = true;
        self.last_synced_clip_mask = active;
        if (active) |clip| {
            const rect = [4]f32{ clip.x, clip.y, clip.w, clip.h };
            const fill_rule: u32 = @intFromEnum(clip.polygon.fill_rule);
            const point_count: u32 = clip.polygon.point_count;
            const contour_count: u32 = clip.polygon.contour_count;
            self.sdf_renderer.setClipMask(@intFromEnum(clip.shape_kind), rect, clip.radius, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            self.text_renderer.setClipMask(@intFromEnum(clip.shape_kind), rect, clip.radius, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.image_renderer) |ir| ir.setClipMask(@intFromEnum(clip.shape_kind), rect, clip.radius, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.icon_renderer) |ir| ir.setClipMask(@intFromEnum(clip.shape_kind), rect, clip.radius, fill_rule, point_count, contour_count, clip.polygon.contour_end_points, clip.polygon.points);
            if (self.persistent.path_renderer) |*pr| pr.setClipMask(@intFromEnum(clip.shape_kind), rect, clip.radius);
        } else {
            const empty_points = [_][2]f32{.{ 0, 0 }} ** max_clip_polygon_points;
            const empty_contours = [_]u8{0} ** max_clip_polygon_contours;
            self.sdf_renderer.setClipMask(0, null, 0, 0, 0, 0, empty_contours, empty_points);
            self.text_renderer.setClipMask(0, null, 0, 0, 0, 0, empty_contours, empty_points);
            if (self.image_renderer) |ir| ir.setClipMask(0, null, 0, 0, 0, 0, empty_contours, empty_points);
            if (self.icon_renderer) |ir| ir.setClipMask(0, null, 0, 0, 0, 0, empty_contours, empty_points);
            if (self.persistent.path_renderer) |*pr| pr.setClipMask(0, null, 0);
        }
    }

    inline fn coerceClipShapeKind(shape_kind: anytype) ClipShapeKind {
        return @enumFromInt(@intFromEnum(shape_kind));
    }

    inline fn coercePathFillRule(fill_rule: anytype) PathFillRule {
        return @enumFromInt(@intFromEnum(fill_rule));
    }

    fn coerceClipPolygon(polygon: anytype) ClipPolygon {
        return clip_geometry.coerceClipPolygon(ClipPolygon, polygon, coercePathFillRule);
    }

    /// dispatchCommand 主路径吃 paint_table.DisplayItem。
    ///
    /// it: paint_table.DisplayItem (anytype) — encoder 不引 ui-side type，duck typing
    /// .kind/.control_kind/.geom/.color/.radii 等字段访问。
    ///
    /// kind 与 source variant 的映射 (lowerDisplayItem 写入)：
    ///   .rect: fill_rect (stroke_width=0, noise_intensity=0, border_widths=0) /
    ///          stroke_rect (stroke_width>0) / outline_rect (stroke_width>0) /
    ///          border_per_side (border_widths!=0) / noise_rect (noise_intensity>0)
    ///   .text: text_run
    ///   .image: image_quad (icon_rep_ptr=null) / icon_rep (icon_rep_ptr!=null)
    ///   .shadow: shadow_rect (shadow_secondary.a=0 shadow2_color.a=0) /
    ///            inset_shadow_rect (shadow_secondary.a>0 shadow2_color.a=0) /
    ///            shadow_dual_rect (shadow2_color.a>0)
    ///   .gradient: gradient_rect (mg_stop_count=0) / multi_gradient_rect (mg_stop_count>0)
    ///   .path: arc (arc_outer_radius>0) / fill_path (path_geometry_ptr stroke_width=0) /
    ///          stroke_path (path_geometry_ptr stroke_width>0)
    ///   .control: 8 control kinds via control_kind enum
    fn dispatchCommand(self: *RenderCommandEncoder, it: anytype) !void {
        // GPU retained 命中：begin..end 之间的内容已经在缓存纹理里了，全部跳过。
        // 只需数出配对的 begin/end 找回本层的结束位置。
        if (self.retained_skip_depth > 0) {
            if (it.kind == .control) {
                switch (it.control_kind) {
                    .begin_opacity_layer => {
                        // 被跳过的内层 begin 也占一个预扫描槽位，序号必须同步推进，
                        // 否则后续层会读到错位的指纹。
                        self.retained_begin_seq += 1;
                        self.retained_skip_depth += 1;
                    },
                    .begin_blur_layer, .begin_rounded_clip => {
                        self.retained_skip_depth += 1;
                    },
                    .end_opacity_layer, .end_blur_layer, .end_rounded_clip => {
                        self.retained_skip_depth -= 1;
                        if (self.retained_skip_depth == 0) try self.compositeRetainedLayer();
                    },
                    else => {},
                }
            }
            return;
        }

        const off = self.offscreenOffset();
        const ox = off[0];
        const oy = off[1];

        // path 合批的顺序 fence：path pending 存在时，任何非 path-pipeline 命令
        // （含 arc——它走 sdf）编码前必须先把 path 落盘，否则 path 晚 flush 会
        // 盖到后画的内容之上。path 命令自身在 .path 分支做反向 flushNonPathPending。
        // ⚠ 「是不是 arc」只能有一份判据。此前这里用 arc_outer_radius <= 0，
        // 而下面 .path 分支用 (radius>0 and stroke>0 and alpha>0)，两者的
        // 差值（零宽或全透明的 arc）会掉进 fill_path 分支，而 arc 命令从不设
        // path_geometry_ptr ⇒ `orelse return` 静默吞掉整条命令。
        const is_arc = isArcCommand(it);
        const is_batched_path = it.kind == .path and !is_arc;
        if (!is_batched_path) try self.flushPathPending();

        switch (it.kind) {
            .none => return,
            .rect => {
                // 形状上下文：非矩形（椭圆）时，本条命令产出的所有实例
                // （填充/描边/渐变/噪声/阴影）都用该形状的 SDF。
                // defer 复位是**必须**的 —— 残留会让后面无关的矩形变椭圆。
                self.sdf_renderer.current_shape =
                    if (it.shape_kind == 1) .ellipse else .rect;
                defer self.sdf_renderer.current_shape = .rect;
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPending();
                const radii = it.radii.toArray();
                // noise_rect: noise_intensity > 0 是判别条件 (即使 fill.a == 0 也要画)
                if (it.noise_intensity > 0) {
                    try self.sdf_renderer.addNoiseRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        @enumFromInt(it.noise_mode),
                        it.noise_scale,
                        it.noise_intensity,
                        it.noise_seed,
                        radii,
                    );
                    return;
                }
                if (it.color.a == 0) return;
                // border_per_side: any width > 0
                const any_border_width = it.border_widths[0] > 0 or it.border_widths[1] > 0 or
                    it.border_widths[2] > 0 or it.border_widths[3] > 0;
                // ── 椭圆：填充与描边都走 addEllipse（shape_type=4 的 SDF）──
                // 必须在 per-side / stroke / fill 三条 rect 路径**之前**拦截：
                // 那三条都会写 shape_type=rect，椭圆掉进去就退回圆角矩形
                // （宽高比大时就是"胶囊"）。per-side 宽度在入口折叠成统一宽度 ——
                // 椭圆没有"四条边"，且 shader 的 per-side 分支硬编码矩形内轮廓。
                // ── 椭圆：填充与描边都走 addEllipse（shape_type=4 的 SDF）──
                // 必须在 per-side / stroke / fill 三条 rect 路径**之前**拦截：
                // 那三条都会写 shape_type=rect，椭圆掉进去就退回圆角矩形（宽高
                // 比大时就是"胶囊"）。per-side 宽度在入口折叠成统一宽度 ——
                // 椭圆没有"四条边"，且 shader 的 per-side 分支硬编码矩形内轮廓。
                if (it.shape_kind == 1) {
                    try self.sdf_renderer.addEllipse(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        if (it.stroke_width > 0 or any_border_width)
                            .{ 0, 0, 0, 0 }
                        else
                            colorToFloat4(it.color),
                        if (it.stroke_width > 0 or any_border_width)
                            colorToFloat4(it.color)
                        else
                            .{ 0, 0, 0, 0 },
                        it.stroke_width,
                        it.border_widths,
                    );
                    return;
                }
                if (any_border_width) {
                    try self.sdf_renderer.addBorderedRectPerSide(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        .{ 0, 0, 0, 0 },
                        colorToFloat4(it.color),
                        it.border_widths,
                        radii,
                    );
                    return;
                }
                // stroke_rect / outline_rect (二者都用 addBorderedRect)
                if (it.stroke_width > 0) {
                    try self.sdf_renderer.addBorderedRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        .{ 0, 0, 0, 0 },
                        colorToFloat4(it.color),
                        it.stroke_width,
                        radii,
                    );
                    return;
                }
                // fill_rect (默认)
                try self.sdf_renderer.addRoundedRect(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    colorToFloat4(it.color),
                    radii,
                );
            },
            .text => {
                const dbg_surf = std.posix.getenv("ZENIT_DEBUG_SURFDUMP") != null and self.offscreen_depth > 0;
                const dbg_before = if (dbg_surf) self.text_renderer.instances_nearest.items.len + self.text_renderer.instances_linear.items.len else 0;
                defer if (dbg_surf) {
                    const after = self.text_renderer.instances_nearest.items.len + self.text_renderer.instances_linear.items.len;
                    std.debug.print("[surftext] depth={d} x={d:.1} y={d:.1} len={d} fs={d:.1} pol={d} added={d}\n", .{
                        self.offscreen_depth, it.geom.x, it.geom.y, it.text_content.len, it.text_font_size, it.text_raster_policy, after - dbg_before,
                    });
                };
                if (it.text_content.len == 0 or it.text_font_size <= 0) return;
                const use_italic = (it.text_font_flags & 1) != 0;
                const use_mono = (it.text_font_flags & 2) != 0;
                const use_sym = (it.text_font_flags & 4) != 0;
                const raster = wire_types.textRasterControls(it.text_raster_policy);
                // 右端淡出遮罩：换算成绝对 x 交给 renderer，逐命令设置并复位
                // （同 clip_x_* 的模式；fade 只影响 alpha，不影响 glyph atlas）。
                if (it.text_fade_dx1 > it.text_fade_dx0) {
                    self.text_renderer.fade_x0 = it.geom.x + ox + it.text_fade_dx0;
                    self.text_renderer.fade_x1 = it.geom.x + ox + it.text_fade_dx1;
                }
                defer {
                    self.text_renderer.fade_x0 = std.math.inf(f32);
                    self.text_renderer.fade_x1 = std.math.inf(f32);
                }
                if (it.text_spans) |s| {
                    try self.encodeTextWithSpans(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.text_content,
                        it.color,
                        it.text_font_size,
                        it.text_font_weight,
                        it.text_font_family,
                        use_sym,
                        use_mono,
                        it.text_monospace_char_width,
                        use_italic,
                        raster.force_linear,
                        raster.shader_snap,
                        s,
                    );
                } else {
                    try self.encodeText(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.text_content,
                        it.color,
                        it.text_font_size,
                        it.text_font_weight,
                        it.text_font_family,
                        use_sym,
                        use_mono,
                        it.text_monospace_char_width,
                        use_italic,
                        raster.force_linear,
                        raster.shader_snap,
                    );
                }
            },
            .image => {
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0 or it.image_opacity <= 0) return;
                try self.flushIfTextPending();
                if (it.icon_rep_ptr) |rep_ptr| {
                    // icon_rep
                    try self.flushIfImagePending();
                    if (self.icon_renderer) |ir| {
                        try ir.addIcon(
                            @intCast(it.resource_handle),
                            rep_ptr.*,
                            it.geom.x + ox,
                            it.geom.y + oy,
                            w,
                            h,
                            colorToFloat4(it.icon_tint),
                            it.icon_corner_clip_radius,
                            it.image_opacity,
                            it.rotate,
                        );
                    }
                } else {
                    // image_quad
                    try self.flushIfIconPending();
                    if (self.image_renderer) |ir| {
                        try addImageOrSkip(
                            ir,
                            it.resource_handle,
                            it.geom.x + ox,
                            it.geom.y + oy,
                            w,
                            h,
                            colorToFloat4(it.image_tint),
                            it.image_corner_radius,
                            it.image_opacity,
                            it.rotate,
                        );
                    }
                }
            },
            .shadow => {
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPending();
                const radii = it.radii.toArray();
                // shadow_dual: shadow2_color.a > 0
                if (it.shadow2_color.a > 0) {
                    try self.sdf_renderer.addDualShadowRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        colorToFloat4(it.shadow_secondary_color),
                        it.shadow_blur,
                        it.shadow_offset_x,
                        it.shadow_offset_y,
                        sdf.ShadowParam{
                            .color = colorToFloat4(it.shadow2_color),
                            .blur = it.shadow2_blur,
                            .offset_x = it.shadow2_offset_x,
                            .offset_y = it.shadow2_offset_y,
                        },
                        radii,
                    );
                    return;
                }
                // inset_shadow: shadow_secondary.a > 0 (shadow_color 字段)
                if (it.shadow_secondary_color.a > 0) {
                    try self.sdf_renderer.addInsetShadowRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        colorToFloat4(it.color),
                        colorToFloat4(it.shadow_secondary_color),
                        it.shadow_blur,
                        it.shadow_offset_x,
                        it.shadow_offset_y,
                        radii,
                    );
                    return;
                }
                // 普通 shadow_rect
                if (it.color.a == 0) return;
                try self.sdf_renderer.addShadowRectSpread(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    .{ 0, 0, 0, 0 },
                    colorToFloat4(it.color),
                    it.shadow_blur,
                    it.shadow_offset_x,
                    it.shadow_offset_y,
                    it.shadow_spread,
                    radii,
                );
            },
            .gradient => {
                // 渐变也必须服从形状：否则椭圆/正圆的渐变会铺满整个包围盒
                // （用户实测截图：椭圆外面一个渐变方块）。与 .rect 同一条纪律，
                // defer 复位防止残留污染后面的矩形。
                self.sdf_renderer.current_shape =
                    if (it.shape_kind == 1) .ellipse else .rect;
                defer self.sdf_renderer.current_shape = .rect;
                const w = it.geom.w;
                const h = it.geom.h;
                if (w <= 0 or h <= 0) return;
                try self.flushIfTextPending();
                const radii = it.radii.toArray();
                if (it.mg_stop_count > 0) {
                    // multi_gradient_rect
                    var stops_buf: [16]sdf.GradientStop = undefined;
                    const cnt = @min(@as(usize, it.mg_stop_count), 16);
                    for (0..cnt) |i| {
                        stops_buf[i] = .{
                            .color = colorToFloat4(it.mg_stop_colors[i]),
                            .position = it.mg_stop_positions[i],
                        };
                    }
                    try self.sdf_renderer.addMultiGradientRect(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        w,
                        h,
                        stops_buf[0..cnt],
                        gradientDirToSDFFromU8(it.gradient_direction),
                        radii,
                        it.gradient_radial_center_x,
                        it.gradient_radial_center_y,
                        it.gradient_conic_start_angle,
                        extendModeToSDFFromU8(it.gradient_extend_mode),
                        .{ it.gradient_radial_radius_x, it.gradient_radial_radius_y },
                    );
                    return;
                }
                // 普通 gradient_rect
                if (it.color.a == 0 and it.gradient_to_color.a == 0) return;
                try self.encodeGradient(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    w,
                    h,
                    it.color,
                    it.gradient_to_color,
                    gradientDirToSDFFromU8(it.gradient_direction),
                    radii,
                    it.gradient_radial_center_x,
                    it.gradient_radial_center_y,
                    it.gradient_conic_start_angle,
                    extendModeToSDFFromU8(it.gradient_extend_mode),
                );
            },
            .path => {
                if (is_arc) {
                    // 零宽 / 全透明的 arc 没有可见像素，直接早退。
                    // 关键是**不能**让它继续往下掉：arc 命令不带
                    // path_geometry_ptr，掉进 fill_path 分支只会被静默丢弃。
                    if (it.stroke_width <= 0 or it.color.a == 0) return;
                    try self.flushIfTextPending();
                    try self.sdf_renderer.addArc(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.arc_outer_radius,
                        it.stroke_width,
                        it.arc_start_angle,
                        it.arc_end_angle,
                        colorToFloat4(it.color),
                    );
                    return;
                }
                // fill_path / stroke_path：先落盘其它 pipeline 保证 z-order，
                // 自身在 path_renderer 里累积——连续多条 path 合并为一次 flush
                //（反向 fence 在 dispatchCommand 顶部：非 path 命令先 flush path pending）
                const geo_ptr = it.path_geometry_ptr orelse return;
                try self.flushNonPathPending();
                if (it.stroke_width > 0) {
                    try self.encodeStrokePathPaint(it, geo_ptr);
                } else {
                    try self.encodeFillPathPaint(it, geo_ptr);
                }
            },
            .control => {
                try self.dispatchControlKind(it);
            },
        }
    }

    /// GPU retained 命中的合成收尾（内容 pass 被跳过，只贴一次缓存纹理）。
    fn compositeRetainedLayer(self: *RenderCommandEncoder) !void {
        try opacity_layer.compositeRetainedLayer(self);
    }

    /// control kind dispatch (8 sub-kinds via control_kind enum)
    fn dispatchControlKind(self: *RenderCommandEncoder, it: anytype) !void {
        const off = self.offscreenOffset();
        const ox = off[0];
        const oy = off[1];
        switch (it.control_kind) {
            .none => return,
            .push_clip => {
                if (std.posix.getenv("ZENIT_DEBUG_SURFDUMP") != null and self.offscreen_depth > 0) {
                    std.debug.print("[surfclip] depth={d} clip=({d:.1},{d:.1},{d:.1},{d:.1}) off=({d:.1},{d:.1})\n", .{
                        self.offscreen_depth, it.geom.x, it.geom.y, it.geom.w, it.geom.h, ox, oy,
                    });
                }
                // shape_kind 0/1/2/3 (rect/rounded_rect/ellipse/polygon)。polygon 通过
                // clip_polygon_ptr 取 source ClipPolygon ptr，其它走 inline 字段。
                const polygon: ClipPolygon = if (it.clip_polygon_ptr) |pp|
                    coerceClipPolygon(pp.*)
                else
                    ClipPolygon.empty();
                try self.pushClip(
                    it.geom.x + ox,
                    it.geom.y + oy,
                    it.geom.w,
                    it.geom.h,
                    it.radii.tl,
                    @enumFromInt(it.clip_shape_kind),
                    polygon,
                );
            },
            .pop_clip => {
                try self.popClip();
            },
            .begin_opacity_layer => {
                const content_seq = self.retained_begin_seq;
                const content_hash: u64 = blk: {
                    const seq = self.retained_begin_seq;
                    self.retained_begin_seq += 1;
                    if (seq >= self.retained_hashes.len) break :blk 0;
                    if (seq >= self.retained_hash_count) break :blk 0;
                    break :blk self.retained_hashes[seq];
                };
                const draw_x = if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x;
                const draw_y = if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y;
                const draw_w = if (std.math.isNan(it.draw_w)) it.geom.w else it.draw_w;
                const draw_h = if (std.math.isNan(it.draw_h)) it.geom.h else it.draw_h;
                const blend_mode_val: BlendMode = @enumFromInt(it.blend_mode);
                // Malformed/deep display lists degrade to a direct-rendering noop layer.
                // Never open an offscreen layer that cannot be paired in our mode stack.
                if (self.opacity_mode_overflow_depth > 0 or self.opacity_mode_depth >= self.opacity_mode_stack.len) {
                    self.opacity_mode_overflow_depth +|= 1;
                    return;
                }
                // 带 corner_radius（rounded-clip 折叠进 opacity layer）时不可走
                // noop 短路——mask 依赖 composite blit 施加。
                const trivial = it.opacity >= 0.999 and
                    blend_mode_val == .normal and
                    !it.use_draw_transform and
                    it.rotate == 0 and
                    it.radii.tl < 0.5;
                if (trivial) {
                    self.pushOpacityMode(.noop);
                } else switch (try opacity_layer.tryBeginRetainedOpacityLayer(
                    self,
                    it.geom.x,
                    it.geom.y,
                    it.geom.w,
                    it.geom.h,
                    it.opacity,
                    it.rotate,
                    draw_x,
                    draw_y,
                    draw_w,
                    draw_h,
                    it.use_draw_transform,
                    it.draw_transform,
                    blend_mode_val,
                    it.radii.tl,
                    it.surface_stable_id,
                    content_hash,
                    content_seq,
                )) {
                    // 命中：内容 pass 整个跳过，end 处只做一次合成 draw。
                    .hit => self.retained_skip_depth = 1,
                    // retained 已经替我们开好层了（画进专属纹理），内容命令照常
                    // 编码。**绝不能再调一次 beginOpacityLayer** —— 那会套两层。
                    .opened_for_repaint => self.pushOpacityMode(.layer),
                    .declined => {
                        const opened = try opacity_layer.beginOpacityLayer(
                            self,
                            it.geom.x,
                            it.geom.y,
                            it.geom.w,
                            it.geom.h,
                            it.opacity,
                            it.rotate,
                            draw_x,
                            draw_y,
                            draw_w,
                            draw_h,
                            it.use_draw_transform,
                            it.draw_transform,
                            blend_mode_val,
                        );
                        self.pushOpacityMode(if (opened) .layer else .noop);
                        if (opened and it.radii.tl >= 0.5 and self.offscreen_depth > 0) {
                            self.offscreen_stack[self.offscreen_depth - 1].corner_radius = it.radii.tl;
                        }
                    },
                }
            },
            .end_opacity_layer => {
                if (self.opacity_mode_overflow_depth > 0) {
                    self.opacity_mode_overflow_depth -= 1;
                    return;
                }
                const mode = self.popOpacityMode() orelse return;
                if (mode == .layer) try opacity_layer.endOpacityLayer(self);
            },
            .begin_rounded_clip => {
                if (self.rounded_clip_overflow_depth > 0 or self.rounded_clip_mode_depth >= self.rounded_clip_mode_stack.len) {
                    self.rounded_clip_overflow_depth +|= 1;
                    return;
                }
                // Shader clip 转换：轴对齐（无 rotate/draw_transform）且当前没有
                // 别的 shape clip 占用 mask 槽时，圆角裁剪走各 pipeline 已有的
                // fragment SDF clip，省掉整个离屏往返（flush + end pass + clear
                // pass + 内容 + 合成 pass）。否则回退旧的 offscreen layer 路径。
                const can_shader_clip = it.rotate == 0 and
                    !it.use_draw_transform and
                    self.activeRoundedClip() == null and
                    !self.forceRoundedClipLayer();
                if (std.posix.getenv("ZENIT_DEBUG_PASSCOUNT") != null) {
                    std.debug.print("[rclip] mode={s}\n", .{if (can_shader_clip) "shader" else "layer"});
                }
                if (can_shader_clip) {
                    try self.pushClip(
                        it.geom.x + ox,
                        it.geom.y + oy,
                        it.geom.w,
                        it.geom.h,
                        it.radii.tl,
                        .rounded_rect,
                        ClipPolygon.empty(),
                    );
                    self.rounded_clip_mode_stack[self.rounded_clip_mode_depth] = .shader;
                    self.rounded_clip_mode_depth += 1;
                } else {
                    const draw_x = if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x;
                    const draw_y = if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y;
                    const draw_w = if (std.math.isNan(it.draw_w)) it.geom.w else it.draw_w;
                    const draw_h = if (std.math.isNan(it.draw_h)) it.geom.h else it.draw_h;
                    const opened = try opacity_layer.beginOpacityLayer(
                        self,
                        it.geom.x,
                        it.geom.y,
                        it.geom.w,
                        it.geom.h,
                        1.0,
                        it.rotate,
                        draw_x,
                        draw_y,
                        draw_w,
                        draw_h,
                        it.use_draw_transform,
                        it.draw_transform,
                        .normal,
                    );
                    if (opened and self.offscreen_depth > 0) {
                        self.offscreen_stack[self.offscreen_depth - 1].corner_radius = it.radii.tl;
                    }
                    if (self.rounded_clip_mode_depth < self.rounded_clip_mode_stack.len) {
                        self.rounded_clip_mode_stack[self.rounded_clip_mode_depth] = if (opened) .layer else .noop;
                        self.rounded_clip_mode_depth += 1;
                    }
                }
            },
            .end_rounded_clip => {
                if (self.rounded_clip_overflow_depth > 0) {
                    self.rounded_clip_overflow_depth -= 1;
                    return;
                }
                if (self.rounded_clip_mode_depth > 0) {
                    self.rounded_clip_mode_depth -= 1;
                    switch (self.rounded_clip_mode_stack[self.rounded_clip_mode_depth]) {
                        .shader => try self.popClip(),
                        .layer => try opacity_layer.endOpacityLayer(self),
                        .noop => {},
                    }
                }
            },
            .begin_blur_layer => {
                const glass_ptr = it.glass_ptr orelse return;
                const g = glass_ptr.*;
                const draw_x = if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x;
                const draw_y = if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y;
                const draw_w = if (std.math.isNan(it.draw_w)) it.geom.w else it.draw_w;
                const draw_h = if (std.math.isNan(it.draw_h)) it.geom.h else it.draw_h;
                // 测试 mock item 无此字段——@hasField 守卫（生产 PaintItem 恒有）。
                const glass_owner: u32 = if (@hasField(@TypeOf(it), "glass_owner_id")) it.glass_owner_id else std.math.maxInt(u32);
                // 同 owner 一帧只合成一次背板（见 blur_applied_owners 注释）。
                if (glass_owner != std.math.maxInt(u32)) {
                    for (self.blur_applied_owners[0..self.blur_applied_count]) |applied| {
                        if (applied == glass_owner) return;
                    }
                    if (self.blur_applied_count < self.blur_applied_owners.len) {
                        self.blur_applied_owners[self.blur_applied_count] = glass_owner;
                        self.blur_applied_count += 1;
                    }
                }
                try backdrop_blur.applyBackdropBlur(self, .{
                    .glass_owner_id = glass_owner,
                    .x = it.geom.x,
                    .y = it.geom.y,
                    .w = it.geom.w,
                    .h = it.geom.h,
                    .blur_radius = g.backdrop_blur,
                    .corner_radius = it.radii.tl,
                    .glass_tint = g.glass_tint,
                    .glass_intensity = g.glass_intensity,
                    .specular_opacity = g.specular_opacity,
                    .specular_saturation = g.specular_saturation,
                    .refraction_level = g.refraction_level,
                    .blur_level = g.blur_level,
                    .warp_gain = g.warp_gain,
                    .center_thickness = g.center_thickness,
                    .surface_kind = coerceGlassSurfaceValue(g.surface),
                    .bezel_width = g.bezel_width,
                    .bottom_surface_kind = coerceGlassSurfaceValue(g.bottom_surface),
                    .bottom_bezel_width = g.bottom_bezel_width,
                    .backdrop_saturation = g.backdrop_saturation,
                    .backdrop_brightness = g.backdrop_brightness,
                    .specular_angle = g.specular_angle,
                    .magnification = g.magnification,
                    .scale_ratio = g.scale_ratio,
                    .edge_field_strength = g.edge_field_strength,
                    .center_zoom_radius = g.center_zoom_radius,
                    .center_zoom_falloff = g.center_zoom_falloff,
                    .backdrop_distance = g.backdrop_distance,
                    .blur_gradient_direction = @floatFromInt(g.blur_gradient_direction),
                    .blur_gradient_strength = g.blur_gradient_strength,
                    .blur_gradient_stop_pos = g.blur_gradient_stop_pos,
                    .blur_gradient_stop_str = g.blur_gradient_stop_str,
                    .blur_gradient_stop_count = @floatFromInt(g.blur_gradient_stop_count),
                    .draw_x = draw_x,
                    .draw_y = draw_y,
                    .draw_w = draw_w,
                    .draw_h = draw_h,
                    .use_draw_transform = it.use_draw_transform,
                    .draw_transform = it.draw_transform,
                    .rotate = it.rotate,
                });
            },
            .end_blur_layer => {
                // backdrop blur 在 begin 时已完成，end 无需操作
            },
        }
    }

    /// paint_table.DisplayItem 主路径的 fill_path 编码。
    /// it 是 paint_table.DisplayItem (anytype)，geo 是 source PathGeometry ptr (来自 it.path_geometry_ptr)。
    /// Phase C：path mesh 缓存键 —— 几何逐 tag payload + fill/stroke 判别 +
    /// scale（fringe/stroke expand 的 AA 宽度依赖 scale）+ stroke 参数。
    /// offset 不进 key（mesh 平移不变，缓存存 path-local 顶点）。
    fn pathMeshKey(geo: anytype, scale: f32, is_stroke: bool, stroke_width: f32, line_join: u8) u64 {
        var h = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        h.update(std.mem.asBytes(&geo.fill_rule));
        var cmd_len: usize = geo.commands.len;
        h.update(std.mem.asBytes(&cmd_len));
        for (geo.commands) |cmd| {
            const tag: u8 = @intFromEnum(cmd);
            h.update(std.mem.asBytes(&tag));
            switch (cmd) {
                .move_to, .line_to => |pt| h.update(std.mem.asBytes(&pt)),
                .quad_to => |q| h.update(std.mem.asBytes(&q)),
                .cubic_to => |c| h.update(std.mem.asBytes(&c)),
                .close => {},
            }
        }
        h.update(std.mem.asBytes(&scale));
        h.update(std.mem.asBytes(&is_stroke));
        if (is_stroke) {
            h.update(std.mem.asBytes(&stroke_width));
            h.update(std.mem.asBytes(&line_join));
        }
        return h.final();
    }

    fn encodeFillPathPaint(self: *RenderCommandEncoder, it: anytype, geo: anytype) !void {
        if (self.persistent.path_renderer == null) {
            const device = self.sdf_renderer.device;
            self.persistent.path_renderer = try PathRenderer.init(self.sdf_renderer.allocator, device);
        }
        if (self.persistent.path_tessellator == null) {
            self.persistent.path_tessellator = path_tess_mod.PathTessellator.init(self.sdf_renderer.allocator);
        }
        var tess = &self.persistent.path_tessellator.?;
        var path_rend = &self.persistent.path_renderer.?;
        path_rend.setViewport(self.viewport_width, self.viewport_height, self.scale);

        const off = self.offscreenOffset();
        const ox = it.geom.x + off[0];
        const oy = it.geom.y + off[1];

        const c = it.color;
        const a = @as(f32, @floatFromInt(c.a)) / 255.0 * it.image_opacity;
        const color = [4]f32{
            srgbByteToLinear(c.r),
            srgbByteToLinear(c.g),
            srgbByteToLinear(c.b),
            a,
        };

        // 矢量填充与描边走**同一条**自适应细分管线（tess.flatten 按
        // FLATNESS_THRESHOLD/scale，无点数上限），这是唯一正确形态：
        // 此前这里优先走 ≤32 点 clip 多边形的快速路径（直边弦多边形、
        // 每段 cubic 最多 12 步），填充边界与描边边界是两套分辨率的几何
        // —— 曲线段上弦误差肉眼可见，描边与填充之间露出楔形缺口。
        // clip 多边形是 clip 的专用结构（display_list 的 32 点上限），
        // 不该复用为填充渲染器。
        // 已知取舍：earclip 逐轮廓三角化，多轮廓挖洞（nonzero/evenodd 的
        // hole 语义）不自洽 —— 该局限对超出 32 点的填充一直存在，矢量填充
        // 的实际使用域（单轮廓 path）不受影响；多轮廓正确性属于离屏
        // alpha mask 那一层。
        if (geo.commands.len == 0) return;
        // 渐变填充：把 DisplayItem 上的 stop 列表转成 renderer 的 FillGradient。
        // 逐顶点着色（GPU 侧 PathVertex.color 早就支持，见 path.metal），
        // 多边形（三角/星形）的渐变填充就靠这条 —— 此前只能退化成纯色。
        var grad_stops: [16]PathRendererMod.FillGradient.GradientStopIn = undefined;
        var fill_grad: ?PathRendererMod.FillGradient = null;
        if (it.gradient_direction != 0 and it.mg_stop_count > 0) {
            const cnt = @min(@as(usize, it.mg_stop_count), grad_stops.len);
            for (0..cnt) |i| {
                const sc = it.mg_stop_colors[i];
                grad_stops[i] = .{
                    .color = .{
                        srgbByteToLinear(sc.r),
                        srgbByteToLinear(sc.g),
                        srgbByteToLinear(sc.b),
                        @as(f32, @floatFromInt(sc.a)) / 255.0,
                    },
                    .position = it.mg_stop_positions[i],
                };
            }
            fill_grad = .{
                .dir = it.gradient_direction,
                .stops = grad_stops[0..cnt],
                .center_x = it.gradient_radial_center_x,
                .center_y = it.gradient_radial_center_y,
                .start_angle = it.gradient_conic_start_angle,
            };
        }
        // Phase C：mesh 缓存 —— 命中跳过 flatten + earclip/fringe。
        // ⚠ 渐变**必须绕开缓存**：`appendCachedMesh` 回放时会把统一色重新写进
        // 每个顶点（它就是为纯色设计的），命中一次渐变就被拍平成纯色。
        path_rend.setFrame(self.frame_index);
        const mesh_key = pathMeshKey(geo.*, self.scale, false, 0, 0);
        if (fill_grad == null) {
            if (try path_rend.appendCachedMesh(mesh_key, color, ox, oy)) return;
        }
        const PathCommand = @TypeOf(geo.commands[0]);
        const contours = try tess.flatten(PathCommand, geo.commands, self.scale);
        if (try path_rend.addFillPathGradient(contours, color, ox, oy, fill_grad)) |range| {
            if (fill_grad == null) path_rend.storeMesh(mesh_key, range[0], range[1], ox, oy);
        }
    }

    /// paint_table.DisplayItem 主路径的 stroke_path 编码。
    fn encodeStrokePathPaint(self: *RenderCommandEncoder, it: anytype, geo: anytype) !void {
        if (self.persistent.path_renderer == null) {
            const device = self.sdf_renderer.device;
            self.persistent.path_renderer = try PathRenderer.init(self.sdf_renderer.allocator, device);
        }
        if (self.persistent.path_tessellator == null) {
            self.persistent.path_tessellator = path_tess_mod.PathTessellator.init(self.sdf_renderer.allocator);
        }
        var tess = &self.persistent.path_tessellator.?;
        var path_rend = &self.persistent.path_renderer.?;
        path_rend.setViewport(self.viewport_width, self.viewport_height, self.scale);

        const off = self.offscreenOffset();
        const ox = it.geom.x + off[0];
        const oy = it.geom.y + off[1];

        if (geo.commands.len == 0) return;

        const c = it.color;
        const a = @as(f32, @floatFromInt(c.a)) / 255.0 * it.image_opacity;
        const color = [4]f32{
            srgbByteToLinear(c.r),
            srgbByteToLinear(c.g),
            srgbByteToLinear(c.b),
            a,
        };

        const PathLineJoin = @import("path_renderer.zig").LineJoin;
        const line_join: PathLineJoin = @enumFromInt(it.path_line_join);
        // Phase C：mesh 缓存 —— 命中跳过 flatten + stroke expand
        path_rend.setFrame(self.frame_index);
        // `stroke_width` 与 path 顶点一样都已经是逻辑像素。PathRenderer 的
        // viewport/shader 会把逻辑坐标映射到 Retina 物理像素；这里只需把
        // device scale 用于曲线细分容差与 1px AA fringe。旧实现再乘一次
        // `self.scale`，导致 3px stroke 在 2× 屏幕上成为 6 个逻辑像素
        // （12 个设备像素），而 Box border 仍是正确的 3px。
        const logical_stroke_width = pathStrokeWidthForTessellation(it.stroke_width, self.scale);
        const mesh_key = pathMeshKey(geo.*, self.scale, true, logical_stroke_width, it.path_line_join);
        if (try path_rend.appendCachedMesh(mesh_key, color, ox, oy)) return;
        const PathCommand = @TypeOf(geo.commands[0]);
        const contours = try tess.flatten(PathCommand, geo.commands, self.scale);
        if (try path_rend.addStrokePath(contours, color, logical_stroke_width, line_join, ox, oy)) |range| {
            path_rend.storeMesh(mesh_key, range[0], range[1], ox, oy);
        }
    }

    fn coerceAffineTransform(transform: anytype) [6]f32 {
        return .{
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.tx,
            transform.ty,
        };
    }

    fn coerceGlassSurfaceValue(surface: anytype) f32 {
        return switch (@typeInfo(@TypeOf(surface))) {
            .@"enum" => @floatFromInt(@intFromEnum(surface)),
            .int, .comptime_int => @floatFromInt(surface),
            else => 1.0,
        };
    }

    /// z-order 屏障：即将分派 SDF 命令时，若 text/image/icon 任一 pipeline 有
    /// pending instances，说明这个 SDF 图元需要画在它们上方——默认 flush 顺序
    /// SDF→Image→Text 会把后来的 SDF 沉到底下（例：画布首个孩子是全幅点阵底图，
    /// 其后的 SDF 盒子全被底图盖住）。先整体 flush 清空再开新批。
    /// 代价是 SDF 与图片/图标交错时批次变碎；先正确后快（下游应用）。
    fn flushIfTextPending(self: *RenderCommandEncoder) !void {
        const text_pending = self.text_renderer.getPendingInstanceCount() > 0;
        const image_pending = if (self.image_renderer) |ir| ir.instances.items.len > 0 else false;
        const icon_pending = if (self.icon_renderer) |ir| ir.instances.items.len > 0 else false;
        if (!(text_pending or image_pending or icon_pending)) return;
        if (self.render_pass) |rp| {
            if (self.sdf_renderer.instances.items.len > 0) {
                self.sdf_renderer.flush(rp) catch |err| self.noteFlushDropped("sdf", err);
            }
            if (image_pending) {
                if (self.image_renderer) |ir| ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
            }
            if (icon_pending) {
                if (self.icon_renderer) |ir| ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
            }
            if (text_pending) self.text_renderer.flush(rp) catch |err| self.noteFlushDropped("text", err);
        }
    }

    fn flushIfImagePending(self: *RenderCommandEncoder) !void {
        if (self.image_renderer) |ir| {
            if (ir.instances.items.len > 0) {
                if (self.render_pass) |rp| ir.flush(rp) catch |err| self.noteFlushDropped("image", err);
            }
        }
    }

    fn flushIfIconPending(self: *RenderCommandEncoder) !void {
        if (self.icon_renderer) |ir| {
            if (ir.instances.items.len > 0) {
                if (self.render_pass) |rp| ir.flush(rp) catch |err| self.noteFlushDropped("icon", err);
            }
        }
    }

    // 脚本判定 / ASCII 分类纯函数簇已析出到 command_encoder/script_detect.zig。
    // 这里保留同名 re-export，公共 API（RenderCommandEncoder.preferCjkFallback
    // 等）与既有调用点、单测全部不变。
    const isAllAscii = script_detect.isAllAscii;
    const fixedMonospaceAdvance = script_detect.fixedMonospaceAdvance;

    /// 编码文本
    fn encodeText(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        content: []const u8,
        color: anytype,
        font_size: f32,
        font_weight: u16,
        font_family: u16,
        use_symbols_font: bool,
        use_monospace_font: bool,
        monospace_char_width: f32,
        use_italic_font: bool,
        force_linear: bool,
        shader_snap: bool,
    ) !void {
        if (self.fonts) |fonts| {
            // 字体决策**全部**交给 FontSelector.resolveFonts —— 与测量端同一个
            // 函数。这里曾经内联一整条 if 链 + selectCjkFallbackFont，与
            // measureTextWidth 各选各的，于是同一段文字量出来和画出来不一样宽
            // （symbols 覆盖 / CJK 内容相关回退 / force_linear 三处分岔）。
            // 不要把任何字体判断搬回这里。
            const resolved = fonts.resolveFonts(content, .{
                .font_size = font_size,
                .font_weight = font_weight,
                .font_family = font_family,
                .use_italic = use_italic_font,
                .use_monospace = use_monospace_font,
                .use_symbols = use_symbols_font,
                .force_linear = force_linear,
            });
            const font = resolved.primary;
            const render_color = colorToRenderColor(color);
            const cjk_fallback = resolved.fallback;
            const fixed_advance = fixedMonospaceAdvance(content, use_monospace_font, monospace_char_width);
            self.text_renderer.drawTextWithOptions(
                content,
                x,
                y,
                font,
                render_color,
                font_size,
                use_italic_font,
                cjk_fallback,
                force_linear,
                shader_snap,
                fixed_advance,
            ) catch |err| {
                if (err == error.TextShapingFailed or err == error.OutOfMemory) {
                    return;
                }
                return err;
            };
        }
    }

    /// 编码带颜色 spans 的文本（整行一次塑形 + 逐 glyph 按 span 着色）
    fn encodeTextWithSpans(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        content: []const u8,
        color: anytype,
        font_size: f32,
        font_weight: u16,
        font_family: u16,
        use_symbols_font: bool,
        use_monospace_font: bool,
        monospace_char_width: f32,
        use_italic_font: bool,
        force_linear: bool,
        shader_snap: bool,
        spans: anytype,
    ) !void {
        if (self.fonts) |fonts| {
            // 同 drawText：字体决策收口到 FontSelector.resolveFonts。
            // 这里原本是第二份一模一样的 if 链 —— 两份拷贝各自演化正是
            // 「量的和画的不一样」能反复复发的原因。
            const resolved = fonts.resolveFonts(content, .{
                .font_size = font_size,
                .font_weight = font_weight,
                .font_family = font_family,
                .use_italic = use_italic_font,
                .use_monospace = use_monospace_font,
                .use_symbols = use_symbols_font,
                .force_linear = force_linear,
            });
            const font = resolved.primary;
            const render_color = colorToRenderColor(color);
            const cjk_fallback = resolved.fallback;
            const fixed_advance = fixedMonospaceAdvance(content, use_monospace_font, monospace_char_width);

            // 构建 render-level color spans
            var render_spans_buf: [128]TextRenderer.ColorSpan = undefined;
            const span_count = @min(spans.len, render_spans_buf.len);
            for (spans[0..span_count], 0..) |s, i| {
                render_spans_buf[i] = .{
                    .start = s.start,
                    .end = s.end,
                    .color = if (s.color) |c| colorToRenderColor(c) else render_color,
                };
            }

            self.text_renderer.drawTextWithSpans(
                content,
                x,
                y,
                font,
                render_color,
                font_size,
                use_italic_font,
                cjk_fallback,
                force_linear,
                shader_snap,
                fixed_advance,
                render_spans_buf[0..span_count],
            ) catch |err| {
                if (err == error.TextShapingFailed) {
                    // Graceful fallback: if span-aware shaping fails, render plain text without spans
                    // so editor body remains visible (syntax colors temporarily degraded).
                    self.text_renderer.drawTextWithOptions(
                        content,
                        x,
                        y,
                        font,
                        render_color,
                        font_size,
                        use_italic_font,
                        cjk_fallback,
                        force_linear,
                        shader_snap,
                        fixed_advance,
                    ) catch |fallback_err| {
                        if (fallback_err == error.TextShapingFailed or fallback_err == error.OutOfMemory) {
                            return;
                        }
                        return fallback_err;
                    };
                    return;
                }
                if (err == error.OutOfMemory) {
                    return;
                }
                return err;
            };
        }
    }

    // selectCjkFallbackFont 已删除（2026-08-17）：内容相关回退统一由
    // FontSelector.resolveContentFallback 决定，渲染与测量共用。
    // 想加回退规则请改那里，不要在 encoder 里重开一份。

    pub const preferKoreanFallback = script_detect.preferKoreanFallback;
    pub const preferCjkFallback = script_detect.preferCjkFallback;
    const containsHangul = script_detect.containsHangul;
    const containsHanOrKana = script_detect.containsHanOrKana;

    const gradientDirToSDFFromU8 = wire_types.gradientDirection;
    const extendModeToSDFFromU8 = wire_types.gradientExtendMode;

    fn encodeGradient(
        self: *RenderCommandEncoder,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from: anytype,
        to: anytype,
        dir: GradientDir,
        radius: [4]f32,
        radial_center_x: f32,
        radial_center_y: f32,
        conic_start_angle: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        switch (dir) {
            .radial => try self.sdf_renderer.addRadialGradientRect(
                x,
                y,
                w,
                h,
                colorToFloat4(from),
                colorToFloat4(to),
                radius,
                radial_center_x,
                radial_center_y,
                extend_mode,
            ),
            .conic => try self.sdf_renderer.addConicGradientRect(
                x,
                y,
                w,
                h,
                colorToFloat4(from),
                colorToFloat4(to),
                radius,
                conic_start_angle,
                extend_mode,
            ),
            else => {
                // 线性渐变：使用 addGradientRect 但需传递 extend_mode
                // 通过直接写 packed_flags 支持 extend_mode
                try self.sdf_renderer.addGradientRectEx(
                    x,
                    y,
                    w,
                    h,
                    colorToFloat4(from),
                    colorToFloat4(to),
                    dir,
                    radius,
                    extend_mode,
                );
            },
        }
    }

    // ========== Clip Stack (Phase 1) ==========

    /// 推入裁剪区域（延迟 flush：只更新 clip stack，实际 GPU scissor 设置推迟到下一个绘制命令）
    /// pub：单测（command_encoder_test.zig）直接驱动 clip 栈。
    pub fn pushClip(self: *RenderCommandEncoder, x: f32, y: f32, w: f32, h: f32, radius: f32, shape_kind: ClipShapeKind, polygon: ClipPolygon) !void {
        if (self.clip_overflow_depth > 0 or self.clip_depth >= self.logical_clip_stack.len) {
            if (self.clip_overflow_depth == 0) {
                std.debug.print("[ENC pushClip] WARNING: clip stack overflow (depth=64), ignoring\n", .{});
            }
            self.clip_overflow_depth +|= 1;
            return;
        }

        const prev_rounded = self.activeRoundedClip();
        const raw_rect = [4]f32{ x, y, @max(w, 0), @max(h, 0) };
        self.effective_rect_clip_stack[self.clip_depth] = if (self.currentRectClip()) |parent_rect|
            intersectClipRects(parent_rect, raw_rect)
        else
            raw_rect;
        self.logical_clip_stack[self.clip_depth] = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .radius = radius,
            .shape_kind = shape_kind,
            .polygon = polygon,
        };
        self.clip_depth += 1;
        try self.syncClipStateAfterMutation(prev_rounded);
    }

    /// 弹出裁剪区域（延迟 flush：只更新 clip stack，实际 GPU scissor 恢复推迟到下一个绘制命令）
    pub fn popClip(self: *RenderCommandEncoder) !void {
        // 先抵消栈满时被忽略的 push —— 它们没压栈，对应的 pop 也不能弹。
        if (self.clip_overflow_depth > 0) {
            self.clip_overflow_depth -= 1;
            return;
        }
        if (self.clip_depth == 0) return;

        const prev_rounded = self.activeRoundedClip();
        self.clip_depth -= 1;
        try self.syncClipStateAfterMutation(prev_rounded);
    }

    inline fn viewportScissorRect(self: *const RenderCommandEncoder) ScissorRect {
        return .{
            .x = 0,
            .y = 0,
            .width = physicalPixelExtent(self.viewport_width, self.scale),
            .height = physicalPixelExtent(self.viewport_height, self.scale),
        };
    }

    fn pushOpacityMode(self: *RenderCommandEncoder, mode: OpacityLayerMode) void {
        if (self.opacity_mode_depth >= self.opacity_mode_stack.len) return;
        self.opacity_mode_stack[self.opacity_mode_depth] = mode;
        self.opacity_mode_depth += 1;
    }

    fn popOpacityMode(self: *RenderCommandEncoder) ?OpacityLayerMode {
        if (self.opacity_mode_depth == 0) return null;
        self.opacity_mode_depth -= 1;
        return self.opacity_mode_stack[self.opacity_mode_depth];
    }

    /// 根据当前 clip stack 同步 text_renderer 的水平裁剪范围
    pub fn syncTextClipX(self: *RenderCommandEncoder) void {
        if (self.currentRectClip()) |cur| {
            self.text_renderer.clip_x_min = cur[0];
            self.text_renderer.clip_x_max = cur[0] + cur[2];
        } else {
            self.text_renderer.clip_x_min = 0;
            self.text_renderer.clip_x_max = self.viewport_width;
        }
    }

    // ========== Phase C2/C3: Offscreen Opacity Layer ==========

    /// 开始离屏 opacity 图层
    pub fn restoreSavedClipState(self: *RenderCommandEncoder, layer: OffscreenLayer) void {
        self.clip_depth = layer.saved_clip_depth;
        self.clip_overflow_depth = layer.saved_clip_overflow_depth;
        self.logical_clip_stack = layer.saved_logical_clip_stack;
        self.effective_rect_clip_stack = layer.saved_effective_rect_clip_stack;
    }

    /// 将积累的命令刷新到 GPU RenderPass
    pub fn flush(self: *RenderCommandEncoder, render_pass: *gpu.Backend.RenderPass) !void {
        // 保存 render_pass 引用（用于 clip stack）
        self.render_pass = render_pass;

        // 先渲染 SDF 图元（背景在下层）
        try self.sdf_renderer.flush(render_pass);
        // 渲染图片（中间层）
        if (self.image_renderer) |ir| {
            try ir.render(render_pass);
        }
        if (self.icon_renderer) |ir| {
            try ir.render(render_pass);
        }
        // 渲染矢量路径（路径在图片之上，文字之下）
        if (self.persistent.path_renderer) |*pr| {
            try pr.flush(render_pass);
        }
        // 再渲染文本（文字在上层）
        try self.text_renderer.flush(render_pass);
        // 清除引用
        self.render_pass = null;
    }
};
