// Windows counterpart of src/render/shaders/blur.metal (hand port).
// ported-from-metal-sha256: f30f5c5519d3e0a9080415596db451cef8eadfbb51317b677ce6708197adb2b5
// tools/metal_to_hlsl.py --check fails when blur.metal changes; port the change
// here and update the hash above after auditing backend-specific additions.
// The audited Metal suffix adds only *_bank attachmentless fragment variants
// and copy_bank. backdrop_blur.zig enables them exclusively on Metal; Windows
// keeps the unchanged attachment passes below and copyTextureRegion. The shared
// Metal prefix is byte-identical to the previously ported fd76c34b source.
// zenit-entry: vertex kawase_vertex_main
// zenit-entry: fragment kawase_downsample
// zenit-entry: fragment kawase_upsample
// zenit-entry: fragment gaussian_blur
// zenit-entry: fragment gaussian_downsample
// zenit-entry: fragment gaussian_encode
// zenit-entry: fragment gaussian_decode
// zenit-entry: fragment gaussian_filter_gamma
// zenit-entry: fragment gaussian_downsample_gamma
//
// Every entry binds its own uniform layout at b0 (an entry references exactly
// one of the cbuffers below, so each compiled entry reflects a single b0).
// Targets and captures hold sRGB-encoded values (gpu.color_format is a
// non-_sRGB format), so every average here is a gamma-space average.

// backdrop_blur.zig KawaseUniforms (32 bytes).
cbuffer KawaseUniforms : register(b0, space0) {
    float2 kawase_texel_size;
    float kawase_offset_scale;
    float kawase_padding;
    float4 kawase_valid_uv;
};

// backdrop_blur.zig GaussianUniforms (1584 bytes). Metal packs `float
// weights[385]` contiguously after valid_uv; a cbuffer float array would give
// each element its own register, so the weights are read from packed float4s.
// `radius` follows the last weight: byte 1572 = gaussian_packed[96].y.
cbuffer GaussianUniforms : register(b0, space0) {
    float2 gaussian_texel_size;
    float2 gaussian_direction;
    float4 gaussian_valid_uv;
    float4 gaussian_packed[97];
};

// backdrop_blur.zig GaussianAreaUniforms (32 bytes).
cbuffer GaussianAreaUniforms : register(b0, space0) {
    float2 area_source_size;
    float2 area_output_size;
    float area_input_gamma;
    float3 area_padding;
};

Texture2D<float4> source_texture : register(t0, space1);
SamplerState source_sampler : register(s0, space2);

float gaussian_weight(uint i) { return gaussian_packed[i >> 2][i & 3]; }
uint gaussian_radius() { return asuint(gaussian_packed[96].y); }

float4 tap(float2 uv) { return source_texture.SampleLevel(source_sampler, uv, 0); }

struct KawaseVertexOutput { float4 position : SV_Position; float2 uv : TEXCOORD0; };

// Fullscreen triangle — 3 vertices cover entire screen, no vertex buffer needed
KawaseVertexOutput kawase_vertex_main(uint id : SV_VertexID) {
    KawaseVertexOutput result;
    float2 pos = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
    result.position = float4(pos, 0, 1);
    result.uv = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return result;
}

// Same-resolution separable Gaussian; every coefficient uses its own texel tap.
float4 gaussian_blur(KawaseVertexOutput input) : SV_Target {
    float2 lo = gaussian_valid_uv.xy;
    float2 hi = gaussian_valid_uv.zw;
    float2 uv = input.uv;
    float2 step_uv = gaussian_direction * gaussian_texel_size;
    uint radius = min(gaussian_radius(), 384u);
    float4 sum = tap(clamp(uv, lo, hi)) * gaussian_weight(0);
    for (uint i = 1; i <= radius; ++i) {
        float2 offset = step_uv * float(i);
        float4 pair = tap(clamp(uv + offset, lo, hi));
        pair += tap(clamp(uv - offset, lo, hi));
        sum += pair * gaussian_weight(i);
    }
    return sum;
}

// Exact 2x box downsample (destination centers lie between four source texels).
float4 gaussian_downsample(KawaseVertexOutput input) : SV_Target {
    float2 lo = kawase_valid_uv.xy;
    float2 hi = kawase_valid_uv.zw;
    float2 uv = input.uv;
    float2 half_texel = kawase_texel_size * 0.5;
    float4 sum = tap(clamp(uv + float2(-half_texel.x, -half_texel.y), lo, hi));
    sum += tap(clamp(uv + float2(half_texel.x, -half_texel.y), lo, hi));
    sum += tap(clamp(uv + float2(-half_texel.x, half_texel.y), lo, hi));
    sum += tap(clamp(uv + float2(half_texel.x, half_texel.y), lo, hi));
    return sum * 0.25;
}

float4 gaussian_encode(KawaseVertexOutput input) : SV_Target {
    return tap(clamp(input.uv, kawase_valid_uv.xy, kawase_valid_uv.zw));
}

float4 gaussian_decode(KawaseVertexOutput input) : SV_Target {
    return tap(input.uv);
}

float4 gaussian_filter_gamma(KawaseVertexOutput input) : SV_Target {
    float2 step_uv = gaussian_direction * gaussian_texel_size;
    float2 lo = gaussian_valid_uv.xy;
    float2 hi = gaussian_valid_uv.zw;
    uint radius = gaussian_radius();
    float4 sum = tap(clamp(input.uv, lo, hi)) * gaussian_weight(0);
    // Adjacent weighted taps share a bilinear lookup (interpolation happens in
    // the same gamma space as the measured native convolution).
    for (uint i = 1; i <= min(radius, 384u); i += 2) {
        float w0 = gaussian_weight(i);
        float w1 = i < radius ? gaussian_weight(i + 1) : 0.0;
        float w = w0 + w1;
        float2 offset = step_uv * (float(i) + w1 / max(w, 1e-20));
        sum += w * (tap(clamp(input.uv + offset, lo, hi)) + tap(clamp(input.uv - offset, lo, hi)));
    }
    return sum;
}

// Integrates each destination cell over source texel areas.
float4 gaussian_downsample_gamma(KawaseVertexOutput input) : SV_Target {
    float2 cell = area_source_size / area_output_size;
    float2 lo = floor(input.uv * area_output_size) * cell;
    float2 hi = lo + cell;
    int2 first = int2(floor(lo));
    float4 sum = 0;
    // floor(source/2) yields cells of width <=3, intersecting at most 4 texels.
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) {
        float2 p = float2(first + int2(x, y));
        float2 overlap = max(min(p + 1.0, hi) - max(p, lo), 0.0);
        float weight = overlap.x * overlap.y;
        if (weight > 0.0) {
            float2 uv = (p + 0.5) / area_source_size;
            // input_gamma only selects tap vs. raw sample on Metal; both are
            // identity on encoded textures.
            sum += weight * tap(uv);
        }
    }
    return sum / (cell.x * cell.y);
}

// Downsample kernel: center (weight 4) + four half-pixel taps.
float4 kawase_downsample(KawaseVertexOutput input) : SV_Target {
    float2 lo = kawase_valid_uv.xy;
    float2 hi = kawase_valid_uv.zw;
    // valid_uv bounds are texel centers; map via the cell edges, then clamp
    // taps to the centers so no pyramid level contracts the image.
    float2 uv = lerp(lo - kawase_texel_size * 0.5, hi + kawase_texel_size * 0.5, input.uv);
    float2 hp = kawase_texel_size * (0.75 * kawase_offset_scale);
    float4 sum = tap(clamp(uv, lo, hi)) * 4.0;
    sum += tap(clamp(uv + float2(-hp.x, -hp.y), lo, hi));
    sum += tap(clamp(uv + float2( hp.x, -hp.y), lo, hi));
    sum += tap(clamp(uv + float2(-hp.x,  hp.y), lo, hi));
    sum += tap(clamp(uv + float2( hp.x,  hp.y), lo, hi));
    return sum / 8.0;
}

// Upsample kernel: four axial taps (weight 1) + four diagonal taps (weight 2).
float4 kawase_upsample(KawaseVertexOutput input) : SV_Target {
    float2 lo = kawase_valid_uv.xy;
    float2 hi = kawase_valid_uv.zw;
    float2 uv = lerp(lo - kawase_texel_size * 0.5, hi + kawase_texel_size * 0.5, input.uv);
    float2 hp = kawase_texel_size * (0.65 * kawase_offset_scale);
    float4 sum = tap(clamp(uv + float2(-hp.x * 2.0, 0.0), lo, hi));
    sum += tap(clamp(uv + float2( hp.x * 2.0, 0.0), lo, hi));
    sum += tap(clamp(uv + float2(0.0, -hp.y * 2.0), lo, hi));
    sum += tap(clamp(uv + float2(0.0,  hp.y * 2.0), lo, hi));
    sum += tap(clamp(uv + float2(-hp.x, -hp.y), lo, hi)) * 2.0;
    sum += tap(clamp(uv + float2( hp.x, -hp.y), lo, hi)) * 2.0;
    sum += tap(clamp(uv + float2(-hp.x,  hp.y), lo, hi)) * 2.0;
    sum += tap(clamp(uv + float2( hp.x,  hp.y), lo, hi)) * 2.0;
    return sum / 12.0;
}
