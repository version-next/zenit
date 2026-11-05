/// Dual Kawase Blur Shader.
/// Downsample chain + upsample chain implement high-quality Gaussian-like blur.
/// Each level: downsample halves resolution, upsample doubles.
/// Radius controlled by level count: 3 levels ~= 8px, 4 ~= 16px, 5 ~= 32px.
/// Reference: ARM SIGGRAPH 2015 "Bandwidth-Efficient Rendering";
/// KDE Plasma / picom / Unity URP all use this algorithm.

#include <metal_stdlib>
using namespace metal;

struct KawaseUniforms {
    float2 texel_size; // 1.0 / source_texture_size (texel step of source texture).
    float offset_scale;
    float _padding;
    /// UV sub-rectangle of "actual backdrop" in source texture {x0, y0, x1, y1}.
    ///
    /// Capture texture is allocated in 64px buckets (texture pool reuse), but the blit only copies
    /// copy_w x copy_h; right/bottom padding is cleared to **transparent black**, never written.
    /// If Kawase downsamples the entire texture, this black bleeds into valid content per level
    /// (at radius 180 with a 6-level chain it spreads far): backdrop washed out + gray halo fringe.
    ///
    /// Clamp uv to this rect before sampling, equivalent to clamp-to-edge on the valid region
    /// (standard semantics for CSS backdrop-filter / Core Image boundaries).
    float4 valid_uv;
};

// Matches backdrop_blur.zig GaussianUniforms (1584 bytes). The normalized
// weights contain the center coefficient followed by one side of the kernel.
struct GaussianUniforms {
    float2 texel_size;
    float2 direction;
    float4 valid_uv;
    float weights[385];
    uint radius;
    uint _padding[2];
};

struct KawaseVertexOutput {
    float4 position [[position]];
    float2 uv;
};

// The blur averages gamma-encoded values (what CSS backdrop-filter and the
// native Liquid Glass backdrop do; measured on live glassEffect step edges).
// All targets and captures are non-sRGB textures holding encoded values
// (docs/SRGB_BLENDING_PLAN.md), so taps already arrive encoded: tap / untap
// are identity and every average below is a gamma-space average.
static inline float4 tap(texture2d<float> source, sampler smp, float2 uv) {
    return source.sample(smp, uv);
}
static inline float4 untap(float4 sum) {
    return sum;
}

// Full-screen triangle -- 3 vertices cover screen; no vertex buffer.
vertex KawaseVertexOutput kawase_vertex_main(uint vertex_id [[vertex_id]]) {
    KawaseVertexOutput out;
    float2 pos;
    pos.x = (vertex_id == 1) ? 3.0 : -1.0;
    pos.y = (vertex_id == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return out;
}

/// Same-resolution separable Gaussian, averaged in gamma space. Every
/// coefficient uses its own texel tap: combining adjacent coefficients with
/// bilinear sampling would interpolate linear colors before gamma encoding.
fragment float4 gaussian_blur(
    KawaseVertexOutput in [[stage_in]],
    constant GaussianUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    // Source and destination have the same dimensions. Preserve raster UVs;
    // mapping them into valid_uv would scale the captured backdrop content.
    float2 uv = in.uv;
    float2 step = uniforms.direction * uniforms.texel_size;
    uint radius = min(uniforms.radius, 384u);

    float4 sum = tap(source, smp, clamp(uv, lo, hi)) * uniforms.weights[0];
    for (uint i = 1; i <= radius; ++i) {
        float2 offset = step * float(i);
        float4 pair = tap(source, smp, clamp(uv + offset, lo, hi));
        pair += tap(source, smp, clamp(uv - offset, lo, hi));
        sum += pair * uniforms.weights[i];
    }

    return untap(sum);
}

/// Exact 2x box downsample in gamma space. With both source dimensions evenly
/// divisible by two, each destination center lies halfway between four source
/// texel centers; the half-texel offsets below therefore need no interpolation.
fragment float4 gaussian_downsample(
    KawaseVertexOutput in [[stage_in]],
    constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = in.uv;
    float2 half_texel = uniforms.texel_size * 0.5;

    float4 sum = tap(source, smp, clamp(uv + float2(-half_texel.x, -half_texel.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(half_texel.x, -half_texel.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(-half_texel.x, half_texel.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(half_texel.x, half_texel.y), lo, hi));

    return untap(sum * 0.25);
}

// Production intermediates hold premultiplied gamma values in RGBA16Float.
// Encode each source texel once, keeping precision through every convolution.
fragment float4 gaussian_encode(
    KawaseVertexOutput in [[stage_in]], constant KawaseUniforms& u [[buffer(0)]],
    texture2d<float> source [[texture(0)]], sampler smp [[sampler(0)]]) {
    return tap(source, smp, clamp(in.uv, u.valid_uv.xy, u.valid_uv.zw));
}

fragment float4 gaussian_decode(
    KawaseVertexOutput in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]) {
    return untap(source.sample(smp, in.uv));
}

fragment float4 gaussian_filter_gamma(
    KawaseVertexOutput in [[stage_in]], constant GaussianUniforms& u [[buffer(0)]],
    texture2d<float> source [[texture(0)]], sampler smp [[sampler(0)]]) {
    float2 step = u.direction * u.texel_size;
    float4 sum = source.sample(smp, clamp(in.uv, u.valid_uv.xy, u.valid_uv.zw)) * u.weights[0];
    // Adjacent weighted taps may share a bilinear lookup because interpolation
    // now occurs in the same gamma space as the measured native convolution.
    for (uint i = 1; i <= min(u.radius, 384u); i += 2) {
        float w0 = u.weights[i];
        float w1 = i < u.radius ? u.weights[i + 1] : 0.0;
        float w = w0 + w1;
        float2 offset = step * (float(i) + w1 / max(w, 1e-20));
        sum += w * (source.sample(smp, clamp(in.uv + offset, u.valid_uv.xy, u.valid_uv.zw))
                  + source.sample(smp, clamp(in.uv - offset, u.valid_uv.xy, u.valid_uv.zw)));
    }
    return sum;
}

struct GaussianAreaUniforms {
    float2 source_size;
    float2 output_size;
    float input_gamma;
    float padding[3];
};

fragment float4 gaussian_downsample_gamma(
    KawaseVertexOutput in [[stage_in]], constant GaussianAreaUniforms& u [[buffer(0)]],
    texture2d<float> source [[texture(0)]], sampler smp [[sampler(0)]]) {
    // Integrate each destination cell over source texel areas. Sampling at
    // source centers before encoding gamma avoids linear-light interpolation
    // of fractional cells when a viewport dimension is odd.
    float2 cell = u.source_size / u.output_size;
    float2 lo = floor(in.uv * u.output_size) * cell;
    float2 hi = lo + cell;
    int2 first = int2(floor(lo));
    float4 sum = 0;
    // floor(source/2) yields cells of width <=3, intersecting at most 4 texels.
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) {
        float2 p = float2(first + int2(x, y));
        float2 overlap = max(min(p + 1.0, hi) - max(p, lo), 0.0);
        float weight = overlap.x * overlap.y;
        if (weight > 0.0) {
            float2 uv = (p + 0.5) / u.source_size;
            sum += weight * (u.input_gamma > 0.5 ? source.sample(smp, uv) : tap(source, smp, uv));
        }
    }
    return sum / (cell.x * cell.y);
}

/// Downsample kernel: 5 texture samples.
/// Center 1 tap (weight 4) + 4 half-pixel offset taps (weight 1 each).
/// Bilinear at half-pixel covers 4 texels weighted average.
/// So 5 texture samples actually cover 13 texels.
fragment float4 kawase_downsample(
    KawaseVertexOutput in [[stage_in]],
    constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // in.uv is 0~1 covering entire dst texture. src valid content occupies only
    // valid_uv sub-rect, so **linearly map** (not clamp)--clamp makes dst right edge
    // beyond valid ratio sample same boundary line, showing as streaking/solid blocks.
    // After mapping, clamp tap offsets to prevent kernel sampling outside valid region.
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    // valid_uv bounds are texel centers. Map via the corresponding cell edges,
    // then clamp taps to the centers; otherwise every pyramid level contracts
    // the image by another texel and moves content underneath the glass.
    float2 uv = mix(lo - uniforms.texel_size * 0.5,
                    hi + uniforms.texel_size * 0.5, in.uv);
    float2 hp = uniforms.texel_size * (0.75 * uniforms.offset_scale);

    float4 sum = tap(source, smp, clamp(uv, lo, hi)) * 4.0;
    sum += tap(source, smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2( hp.x, -hp.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi));
    sum += tap(source, smp, clamp(uv + float2( hp.x,  hp.y), lo, hi));

    return untap(sum / 8.0);
}

/// Upsample kernel: 8 texture samples.
/// 4 axial taps (weight 1) + 4 diagonal taps (weight 2).
/// Total weight = 4*1 + 4*2 = 12.
fragment float4 kawase_upsample(
    KawaseVertexOutput in [[stage_in]],
    constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    // Same as downsample: map dst normalized coords into src valid sub-rect first.
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = mix(lo - uniforms.texel_size * 0.5,
                    hi + uniforms.texel_size * 0.5, in.uv);
    float2 hp = uniforms.texel_size * (0.65 * uniforms.offset_scale);

    // 4 axial taps (weight 1 each).
    float4 sum  = tap(source, smp, clamp(uv + float2(-hp.x * 2.0, 0.0), lo, hi));
    sum += tap(source, smp, clamp(uv + float2( hp.x * 2.0, 0.0), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(0.0, -hp.y * 2.0), lo, hi));
    sum += tap(source, smp, clamp(uv + float2(0.0,  hp.y * 2.0), lo, hi));

    // 4 diagonal taps (weight 2 each).
    sum += tap(source, smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi)) * 2.0;
    sum += tap(source, smp, clamp(uv + float2( hp.x, -hp.y), lo, hi)) * 2.0;
    sum += tap(source, smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi)) * 2.0;
    sum += tap(source, smp, clamp(uv + float2( hp.x,  hp.y), lo, hi)) * 2.0;

    return untap(sum / 12.0);
}

// ---- Batched forms of the native bank passes (Metal) ----
//
// A render pass costs the CPU a render encoder (~4 us of driver setup on
// Apple GPUs even when hot; a native glass encoded 11 for its banks alone).
// These forms write their target from the fragment function inside a render
// pass without attachments, so independent bank passes of one glass share an
// encoder (backdrop_blur bank batch). Each computes exactly what its form
// above stores: the same rasterized uv (same full-screen triangle and
// viewport), the same expressions, the same sampler at level 0 (one-level
// textures: implicit and explicit LOD pick the same filter, and the explicit
// level stays defined in the divergent branch), and the same float -> half
// conversion on store. The render pass's clear + scissor becomes an explicit
// region: outside it the clear color, or the texel untouched for a loaded
// target. The GPU test "metal bank batch matches the render passes bit for
// bit" pins this. (Compute kernels would cost even less CPU, but the first
// compute dispatch makes the driver hold ~160 MB more while frames run.)

struct BankRegion {
    uint4 bounds; // x0, y0, x1, y1: texels computed; others cleared or kept.
    uint keep_outside;
    uint _padding[3];
};

// The bank render passes clear to gpu.Color.BLACK (opaque black).
constant float4 bank_clear = float4(0, 0, 0, 1);

// True when the texel is outside the region (and has been cleared if due).
static inline bool bank_skip(uint2 g, constant BankRegion& r, texture2d<float, access::write> out) {
    if (g.x >= r.bounds.x && g.y >= r.bounds.y && g.x < r.bounds.z && g.y < r.bounds.w) return false;
    if (r.keep_outside == 0) out.write(bank_clear, g);
    return true;
}

fragment void gaussian_filter_gamma_bank(
    KawaseVertexOutput in [[stage_in]], constant GaussianUniforms& u [[buffer(0)]],
    constant BankRegion& region [[buffer(1)]],
    texture2d<float> source [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
    sampler smp [[sampler(0)]]) {
    uint2 g = uint2(in.position.xy);
    if (bank_skip(g, region, out)) return;
    float2 step = u.direction * u.texel_size;
    float4 sum = source.sample(smp, clamp(in.uv, u.valid_uv.xy, u.valid_uv.zw), level(0)) * u.weights[0];
    for (uint i = 1; i <= min(u.radius, 384u); i += 2) {
        float w0 = u.weights[i];
        float w1 = i < u.radius ? u.weights[i + 1] : 0.0;
        float w = w0 + w1;
        float2 offset = step * (float(i) + w1 / max(w, 1e-20));
        sum += w * (source.sample(smp, clamp(in.uv + offset, u.valid_uv.xy, u.valid_uv.zw), level(0))
                  + source.sample(smp, clamp(in.uv - offset, u.valid_uv.xy, u.valid_uv.zw), level(0)));
    }
    out.write(sum, g);
}

fragment void gaussian_downsample_gamma_bank(
    KawaseVertexOutput in [[stage_in]], constant GaussianAreaUniforms& u [[buffer(0)]],
    constant BankRegion& region [[buffer(1)]],
    texture2d<float> source [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
    sampler smp [[sampler(0)]]) {
    uint2 g = uint2(in.position.xy);
    if (bank_skip(g, region, out)) return;
    float2 cell = u.source_size / u.output_size;
    float2 lo = floor(in.uv * u.output_size) * cell;
    float2 hi = lo + cell;
    int2 first = int2(floor(lo));
    float4 sum = 0;
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) {
        float2 p = float2(first + int2(x, y));
        float2 overlap = max(min(p + 1.0, hi) - max(p, lo), 0.0);
        float weight = overlap.x * overlap.y;
        if (weight > 0.0) {
            float2 uv = (p + 0.5) / u.source_size;
            sum += weight * source.sample(smp, uv, level(0));
        }
    }
    out.write(sum / (cell.x * cell.y), g);
}

// kawase_downsample / kawase_upsample: their passes write every texel (full
// viewport, no scissor), so no region.
fragment void kawase_downsample_bank(
    KawaseVertexOutput in [[stage_in]], constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
    sampler smp [[sampler(0)]]) {
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = mix(lo - uniforms.texel_size * 0.5,
                    hi + uniforms.texel_size * 0.5, in.uv);
    float2 hp = uniforms.texel_size * (0.75 * uniforms.offset_scale);
    float4 sum = source.sample(smp, clamp(uv, lo, hi), level(0)) * 4.0;
    sum += source.sample(smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2( hp.x, -hp.y), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2( hp.x,  hp.y), lo, hi), level(0));
    out.write(untap(sum / 8.0), uint2(in.position.xy));
}

fragment void kawase_upsample_bank(
    KawaseVertexOutput in [[stage_in]], constant KawaseUniforms& uniforms [[buffer(0)]],
    texture2d<float> source [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
    sampler smp [[sampler(0)]]) {
    float2 lo = uniforms.valid_uv.xy;
    float2 hi = uniforms.valid_uv.zw;
    float2 uv = mix(lo - uniforms.texel_size * 0.5,
                    hi + uniforms.texel_size * 0.5, in.uv);
    float2 hp = uniforms.texel_size * (0.65 * uniforms.offset_scale);
    float4 sum  = source.sample(smp, clamp(uv + float2(-hp.x * 2.0, 0.0), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2( hp.x * 2.0, 0.0), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2(0.0, -hp.y * 2.0), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2(0.0,  hp.y * 2.0), lo, hi), level(0));
    sum += source.sample(smp, clamp(uv + float2(-hp.x, -hp.y), lo, hi), level(0)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2( hp.x, -hp.y), lo, hi), level(0)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2(-hp.x,  hp.y), lo, hi), level(0)) * 2.0;
    sum += source.sample(smp, clamp(uv + float2( hp.x,  hp.y), lo, hi), level(0)) * 2.0;
    out.write(untap(sum / 12.0), uint2(in.position.xy));
}

// The render copy (native/macos/render_copy.inc) as a batched draw: texels in
// the destination rect take the source texel, the rest of the target is
// cleared to transparent black (clear) or kept. Same pixel format both sides;
// reads and writes are exact.
struct BankCopy {
    uint4 rect; // dst x0, y0, x1, y1
    int2 offset; // source texel = destination texel + offset
    uint clear;
    uint _padding;
};

fragment void copy_bank(
    KawaseVertexOutput in [[stage_in]], constant BankCopy& c [[buffer(0)]],
    texture2d<float> source [[texture(0)]], texture2d<float, access::write> out [[texture(1)]]) {
    uint2 g = uint2(in.position.xy);
    if (g.x >= c.rect.x && g.y >= c.rect.y && g.x < c.rect.z && g.y < c.rect.w) {
        out.write(source.read(uint2(int2(g) + c.offset)), g);
    } else if (c.clear != 0) {
        out.write(float4(0), g);
    }
}
