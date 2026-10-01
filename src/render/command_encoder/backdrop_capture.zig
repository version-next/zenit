//! command_encoder/backdrop_capture.zig, backdrop 采样的区域解析
//!
//! 从 command_encoder.zig 析出（2026-08-05）。它回答一个自洽的问题：
//! **一块逻辑坐标的 glass 采样区，落到 64px 桶纹理 + 物理像素 + 可视裁剪
//! 之后，到底该从源 RT 的哪里拷多少、贴到目标纹理的哪里**。
//!
//! 为什么能独立：`computeBackdropCaptureRegion` 是 `RenderCommandEncoder`
//! 上的**静态**函数（调用点 backdrop_blur.zig:753 一直用
//! `@TypeOf(encoder.*).computeBackdropCaptureRegion(...)` 反射调用，从不用
//! self），它放在 encoder 结构体里纯属历史寄居。依赖只有
//! `offscreen_texture` 的桶化尺寸（同目录已有模块），零 encoder 状态。
//!
//! 像素域转换（finitePixelCoordinate / physicalPixelExtent /
//! max_safe_pixel_coordinate）与 encoder 的 viewport/scissor 路径共享,
//! 它们因此独立成 pixel_domain.zig，本模块与 command_encoder.zig 都从那里
//! import（析出模块不反向 import 母文件，否则母文件里的同名 decl 会变成
//! ambiguous reference）。
//!
//! 接口切在：**逻辑区域 -> {纹理尺寸, src/copy/dst 物理矩形}**。拿到区域
//! 之后做 blit、建 kawase 链、composite 是 backdrop_blur.zig 的事。
//!
//! ⚠ 行为合同（搬动时逐字符保留，注释里的坑也原样带走）：
//!   - 纹理按 64px 桶分配（morph/resize 动画期池命中）；
//!   - 跨视口底/右的 src 必须 clamp 到源纹理，否则 blit 报
//!     InvalidTextureRegion，调用方静默放弃**整个**玻璃合成，节点滚入
//!     期间只剩文字边框（下游应用验收实拍）；
//!   - src_tex_w/h == 0 表示未知，跳过右/下 clamp（仅为单测兼容保留）。

const std = @import("std");
const offscreen_texture = @import("../offscreen_texture.zig");
const clip_geometry = @import("clip_geometry.zig");
const pixel_domain = @import("pixel_domain.zig");

const finitePixelCoordinate = pixel_domain.finitePixelCoordinate;
const intersectClipRects = clip_geometry.intersectClipRects;

pub const BackdropCaptureRegion = struct {
    tex_w: u32,
    tex_h: u32,
    src_x: u32,
    src_y: u32,
    copy_w: u32,
    copy_h: u32,
    dst_x: u32,
    dst_y: u32,

    pub fn coversFullTexture(self: BackdropCaptureRegion) bool {
        return self.src_x == 0 and
            self.src_y == 0 and
            self.dst_x == 0 and
            self.dst_y == 0 and
            self.copy_w == self.tex_w and
            self.copy_h == self.tex_h;
    }
};

pub fn computeBackdropCaptureRegion(
    sample_x: f32,
    sample_y: f32,
    w: f32,
    h: f32,
    scale: f32,
    clip_rect: ?[4]f32,
    /// 源纹理（当前 RT）物理尺寸。0 = 未知（跳过右/下边界 clamp，仅测试兼容）。
    src_tex_w: u32,
    src_tex_h: u32,
) ?BackdropCaptureRegion {
    if (!std.math.isFinite(sample_x) or !std.math.isFinite(sample_y) or
        !std.math.isFinite(w) or !std.math.isFinite(h) or
        !std.math.isFinite(scale) or scale <= 0 or w <= 0 or h <= 0)
    {
        return null;
    }
    if (clip_rect) |clip| {
        for (clip) |value| if (!std.math.isFinite(value)) return null;
    }
    // 纹理分配尺寸落 64px 桶（下游回归性能项）：capture/kawase 链/
    // glass composite 全链纹理尺寸都由 tex_w/tex_h 派生（chain 逐级减半、
    // composite 同尺寸）。glass 几何动画（morph/resize）时精确尺寸逐帧变
    // -> 池永不命中、全链每帧 create（下游应用 --pillprobe 一轮 17 万张）。
    // 桶化后同桶帧共享纹理。下游 UV/texel 全部以 tex_w/tex_h 为基准计算，
    // pad 出来的右/下区域走既有的"部分捕获"路径：coversFullTexture()=false
    // -> 透明 clear，valid_uv 钳采样把 pad 排除在 rim 位移采样之外。
    const max_capture_dimension: u32 = 1 << 24;
    const exact_size = offscreen_texture.computeOffscreenTextureSize(w, h, scale, max_capture_dimension) orelse return null;
    const tex_w = offscreen_texture.bucketDimension(exact_size.width, max_capture_dimension);
    const tex_h = offscreen_texture.bucketDimension(exact_size.height, max_capture_dimension);

    const base_rect = [4]f32{
        sample_x,
        sample_y,
        @max(w, 0),
        @max(h, 0),
    };
    var visible_rect = base_rect;
    if (clip_rect) |clip| {
        visible_rect = intersectClipRects(visible_rect, clip);
    }
    // 当前 RT 的左/上边界之外没有有效 backdrop，可视区域要在复制前裁掉。
    visible_rect = intersectClipRects(visible_rect, .{ 0, 0, std.math.inf(f32), std.math.inf(f32) });
    for (visible_rect) |value| if (!std.math.isFinite(value)) return null;
    if (visible_rect[2] <= 0 or visible_rect[3] <= 0) return null;

    const src_x = finitePixelCoordinate(@floor(visible_rect[0] * scale)) orelse return null;
    const src_y = finitePixelCoordinate(@floor(visible_rect[1] * scale)) orelse return null;
    const src_x_end = finitePixelCoordinate(@ceil((visible_rect[0] + visible_rect[2]) * scale)) orelse return null;
    const src_y_end = finitePixelCoordinate(@ceil((visible_rect[1] + visible_rect[3]) * scale)) orelse return null;
    const dst_x = finitePixelCoordinate(@floor((visible_rect[0] - sample_x) * scale)) orelse return null;
    const dst_y = finitePixelCoordinate(@floor((visible_rect[1] - sample_y) * scale)) orelse return null;

    if (dst_x >= tex_w or dst_y >= tex_h) return null;

    // 右/下边界 clamp 到源纹理：跨视口底/右边缘的 glass（滚入过程中的瓦片）
    // 若 src 越界，blit wrapper 会报 InvalidTextureRegion -> 调用方静默放弃
    // **整个玻璃合成** -> 节点滚入期间只剩文字/边框的"素面"（下游应用验收实拍）。
    // clamp 后部分捕获 + 透明 pad 填充，玻璃正常渐入。
    const src_x_end_c = if (src_tex_w > 0) @min(src_x_end, src_tex_w) else src_x_end;
    const src_y_end_c = if (src_tex_h > 0) @min(src_y_end, src_tex_h) else src_y_end;
    if (src_x >= src_x_end_c or src_y >= src_y_end_c) return null;
    const raw_copy_w = src_x_end_c - src_x;
    const raw_copy_h = src_y_end_c - src_y;
    const copy_w = @min(raw_copy_w, tex_w - dst_x);
    const copy_h = @min(raw_copy_h, tex_h - dst_y);
    if (copy_w == 0 or copy_h == 0) return null;

    return .{
        .tex_w = tex_w,
        .tex_h = tex_h,
        .src_x = src_x,
        .src_y = src_y,
        .copy_w = copy_w,
        .copy_h = copy_h,
        .dst_x = dst_x,
        .dst_y = dst_y,
    };
}

// ── 测试 ───────────────────────────────────────────────────────────────
// command_encoder_test.zig 已有 4 条端到端 region 测试（clip 裁剪 / 负 origin
// pad / 非有限值拒绝 / src clamp）。这里补的是**此前没有入口可测**的分支：
// copy 矩形落在桶化纹理内的结果不变量、src_tex=0 的「未知」语义、以及
// 两种零可视面积拒绝路径。像素域转换原语自身的边界测试在 pixel_domain.zig
//（与实现同处）。

test "computeBackdropCaptureRegion: copy 矩形始终完整落在目标纹理内（dst+copy ≤ tex）" {
    // dst_x=20/copy_w、dst_y=12/copy_h 的负 origin pad 场景。截断 clamp
    // （copy_w = min(raw, tex_w - dst_x)）是防御性的：几何上可视矩形永远
    // 在采样区内，raw + dst ≤ tex 恒成立，这里钉住的是**结果不变量**
    // dst + copy ≤ tex（blit 目标越界 = InvalidTextureRegion = 整个玻璃
    // 合成被放弃），而不是宣称触发了截断分支本身。
    const region = computeBackdropCaptureRegion(-10, -6, 30, 20, 2, null, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 64), region.tex_w);
    try std.testing.expectEqual(@as(u32, 64), region.tex_h);
    try std.testing.expectEqual(@as(u32, 20), region.dst_x);
    try std.testing.expectEqual(@as(u32, 12), region.dst_y);
    // 不变量：copy 矩形右/下缘不得越过桶化后的纹理尺寸。
    try std.testing.expect(region.dst_x + region.copy_w <= region.tex_w);
    try std.testing.expect(region.dst_y + region.copy_h <= region.tex_h);
    // 有 pad（dst 非零原点）⇒ 必然不是全纹理覆盖。
    try std.testing.expect(!region.coversFullTexture());
}

test "computeBackdropCaptureRegion: src_tex 尺寸未知(0)时跳过 clamp" {
    // src_tex_w/h = 0 是「未知」而不是「零尺寸」：右/下 clamp 不生效。
    const a = computeBackdropCaptureRegion(0, 0, 30, 20, 2, null, 0, 0).?;
    const b = computeBackdropCaptureRegion(0, 0, 30, 20, 2, null, 1_000_000, 1_000_000).?;
    // 足够大的源纹理 clamp 无效 ⇒ 两者一致；这是该分支的可观测语义。
    try std.testing.expectEqual(a.copy_w, b.copy_w);
    try std.testing.expectEqual(a.copy_h, b.copy_h);
}

test "computeBackdropCaptureRegion: 采样区完全在 RT 之上（可视高 ≤ 0）返回 null" {
    // clip 把可视区裁到零面积 -> null（不是零尺寸 region）。
    const clipped = computeBackdropCaptureRegion(0, 0, 30, 20, 2, .{ 0, 100, 10, 1 }, 0, 0);
    try std.testing.expect(clipped == null);
}

test "computeBackdropCaptureRegion: 采样区完全在 RT 左侧（可视宽 ≤ 0）返回 null" {
    // 采样窗口整体在当前 RT 之外 -> 与 (0,0,inf,inf) 求交后零面积 -> null
    //（不是零尺寸 region；调用方据此放弃整次玻璃捕获）。
    const offscreen = computeBackdropCaptureRegion(-10_000, -6, 30, 20, 2, null, 0, 0);
    try std.testing.expect(offscreen == null);
}
