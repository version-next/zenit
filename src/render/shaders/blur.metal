/// Dual Kawase Blur Shader
///
/// 降采样链 + 升采样链实现高质量 Gaussian-like blur。
/// 每级降采样分辨率减半，升采样翻倍。
/// 级数控制模糊半径：3 级 ≈ 8px, 4 级 ≈ 16px, 5 级 ≈ 32px。
///
/// 参考：ARM SIGGRAPH 2015 "Bandwidth-Efficient Rendering"
///       KDE Plasma / picom / Unity URP 均采用此算法

#include <metal_stdlib>
using namespace metal;

struct KawaseUniforms {
    float2 texel_size;   // 1.0 / source_texture_size（源纹理的 texel 步长）
    float offset_scale;
    float _padding;
    /// 源纹理里"真实背板"的 uv 子矩形 {x0, y0, x1, y1}。
    ///
    /// capture 纹理尺寸按 64px 桶分配（纹理池复用所需），而实际 blit 进来的
    /// 只有 copy_w×copy_h —— 右/下那圈 pad 是被 clear 成**透明黑**、永不写入
    /// 的区域。若 Kawase 对整张纹理做降采样，这圈黑会被逐级糊进有效内容：
    /// 半径 180 时链深 6 级，污染扩散极远，表现为背板被冲淡 + 边缘糊出一团
    /// 灰（下游应用 header 实拍）。
    ///
    /// 采样前把 uv 钳进本矩形，等价于对有效区做 clamp-to-edge 延展——这也是
    /// CSS backdrop-filter / Core Image 对边界的标准语义。
    float4 valid_uv;
};

struct KawaseVertexOutput {
    float4 position [[position]];
    float2 uv;
};

// 全屏三角形 — 3 个顶点覆盖整个屏幕，无需顶点缓冲区
vertex KawaseVertexOutput kawase_vertex_main(uint vertex_id [[vertex_id]]) {
    KawaseVertexOutput out;
    float2 pos;
    pos.x = (vertex_id == 1) ? 3.0 : -1.0;
    pos.y = (vertex_id == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return out;
}

/// Downsample kernel: 5 次纹理采样
/// 中心 1 tap (权重 4) + 4 个半像素偏移 tap (权重 1 each)
/// 双线性采样在半像素位置实际覆盖 4 个 texel 的加权平均
/// 所以 5 次 texture sample 实际覆盖 13 个 texel
fragment float4 kawase_downsample(
    KawaseVertexOutput in [[stage_in]],
    constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // in.uv 是 0~1 覆盖整张 dst 纹理。src 的有效内容只占 valid_uv 子矩形，
    // 所以要**线性映射**过去（而不是 clamp）——clamp 会让 dst 右侧超出
    // 有效比例的那一带全部采到同一条边界线，表现为拉丝/纯色块。
    // 映射后再对 tap 偏移做 clamp，防止 kernel 采出有效区。
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = lo + in.uv * (hi - lo);
    float2 hp = uniforms.texel_size * (0.75 * uniforms.offset_scale);

    float4 sum = source.sample(smp, uv) * 4.0;
    sum += source.sample(smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi));
    sum += source.sample(smp, clamp(uv + float2( hp.x, -hp.y), lo, hi));
    sum += source.sample(smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi));
    sum += source.sample(smp, clamp(uv + float2( hp.x,  hp.y), lo, hi));

    return sum / 8.0;
}

/// Upsample kernel: 8 次纹理采样
/// 4 个轴向 tap (权重 1) + 4 个对角 tap (权重 2)
/// 总权重 = 4*1 + 4*2 = 12
fragment float4 kawase_upsample(
    KawaseVertexOutput in [[stage_in]],
    constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // 同 downsample：先把 dst 的归一化坐标映射进 src 的有效子矩形。
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = lo + in.uv * (hi - lo);
    float2 hp = uniforms.texel_size * (0.65 * uniforms.offset_scale);

    // 4 个轴向 (权重 1 each)
    float4 sum  = source.sample(smp, clamp(uv + float2(-hp.x * 2.0, 0.0), lo, hi));
    sum += source.sample(smp, clamp(uv + float2( hp.x * 2.0, 0.0), lo, hi));
    sum += source.sample(smp, clamp(uv + float2(0.0, -hp.y * 2.0), lo, hi));
    sum += source.sample(smp, clamp(uv + float2(0.0,  hp.y * 2.0), lo, hi));

    // 4 个对角 (权重 2 each)
    sum += source.sample(smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2( hp.x, -hp.y), lo, hi)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2( hp.x,  hp.y), lo, hi)) * 2.0;

    return sum / 12.0;
}
