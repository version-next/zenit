// Windows counterpart of src/render/shaders/composite.metal.
// zenit-entry: vertex blend_vertex_main
// zenit-entry: fragment blend_fragment_main
cbuffer BlendUniforms : register(b0, space0) {
    float2 target_size; float2 rect_size; float2 src_uv_scale; float2 inv_offset; float4 inv; float4 params;
    float4 corner_radii; // layer rounded mask TL, TR, BR, BL (layer-local physical px)
    float4 clip_rect; float4 clip_shape; float4 clip_shape_rect;
    float4 clip_shape_radii; // kind 1: TL, TR, BR, BL (target physical px)
    float4 warp; // lens warp (physical px): x across the rounded ends, y across the long edges (+ = toward the centre), z fade start, w fade width
    float4 src_uv_origin; // xy = src UV of the quad's origin (grid-aligned rounded layers)
};
Texture2D<float4> source_texture : register(t0, space1);
Texture2D<float4> destination_texture : register(t1, space1);
SamplerState texture_sampler : register(s0, space2);
struct VOut { float4 position : SV_Position; };
VOut blend_vertex_main(uint id : SV_VertexID) {
    VOut result;
    result.position = float4(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0, 0, 1);
    return result;
}
float4 zb_unpremul(float4 color) {
    if (color.a < 0.0001) return float4(0,0,0,0);
    return float4(color.rgb / color.a, color.a);
}

float3 zb_multiply(float3 source, float3 destination) { return source * destination; }
float3 zb_screen(float3 source, float3 destination) { return source + destination - source * destination; }
float3 zb_hard_light(float3 source, float3 destination) {
    float3 low = 2.0 * source * destination;
    float3 high = 1.0 - 2.0 * (1.0 - source) * (1.0 - destination);
    return float3(source.x <= 0.5 ? low.x : high.x, source.y <= 0.5 ? low.y : high.y, source.z <= 0.5 ? low.z : high.z);
}
float3 zb_overlay(float3 source, float3 destination) { return zb_hard_light(destination, source); }
float3 zb_darken(float3 source, float3 destination) { return min(source, destination); }
float3 zb_lighten(float3 source, float3 destination) { return max(source, destination); }
float3 zb_color_dodge(float3 source, float3 destination) {
    return float3(source.x >= 1.0 ? 1.0 : min(1.0, destination.x / max(1.0 - source.x, 0.0001)), source.y >= 1.0 ? 1.0 : min(1.0, destination.y / max(1.0 - source.y, 0.0001)), source.z >= 1.0 ? 1.0 : min(1.0, destination.z / max(1.0 - source.z, 0.0001)));
}
float3 zb_color_burn(float3 source, float3 destination) {
    return float3(source.x <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - destination.x) / max(source.x, 0.0001)), source.y <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - destination.y) / max(source.y, 0.0001)), source.z <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - destination.z) / max(source.z, 0.0001)));
}
float3 zb_soft_light(float3 source, float3 destination) {
    float3 dd = float3(destination.x <= 0.25 ? ((16.0 * destination.x - 12.0) * destination.x + 4.0) * destination.x : sqrt(destination.x), destination.y <= 0.25 ? ((16.0 * destination.y - 12.0) * destination.y + 4.0) * destination.y : sqrt(destination.y), destination.z <= 0.25 ? ((16.0 * destination.z - 12.0) * destination.z + 4.0) * destination.z : sqrt(destination.z));
    float3 low = destination - (1.0 - 2.0 * source) * destination * (1.0 - destination);
    float3 high = destination + (2.0 * source - 1.0) * (dd - destination);
    return float3(source.x <= 0.5 ? low.x : high.x, source.y <= 0.5 ? low.y : high.y, source.z <= 0.5 ? low.z : high.z);
}
float3 zb_difference(float3 source, float3 destination) { return abs(source - destination); }
float3 zb_exclusion(float3 source, float3 destination) { return source + destination - 2.0 * source * destination; }

/// Corner radius (TL, TR, BR, BL) of the quadrant `p` lies in, `p` relative to the rect centre.
float zb_corner_radius(float2 p, float4 radii) {
    return (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
}

float zb_rounded_rect_mask(float2 coord, float2 size, float4 radii) {
    float2 half_size = size * 0.5;
    float radius = zb_corner_radius(coord - half_size, radii);
    if (radius <= 0.5) return 1.0;
    float2 q = abs(coord - half_size) - half_size + radius;
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return clamp(0.5 - distance, 0.0, 1.0);
}

// Clip coverage at a target pixel (rect x shape), 0.5px antialiasing band.
float zb_clip_coverage(float2 pixel) {
    float coverage = 1.0;
    if (clip_rect.z >= 0.0 && clip_rect.w >= 0.0) {
        float2 half_size = clip_rect.zw * 0.5;
        float2 q = abs(pixel - (clip_rect.xy + half_size)) - half_size;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        coverage *= clamp(0.5 - d, 0.0, 1.0);
    }
    uint kind = uint(clip_shape.x);
    if (kind == 1u || kind == 2u) {
        float2 half_size = clip_shape_rect.zw * 0.5;
        float2 p = pixel - (clip_shape_rect.xy + half_size);
        float d;
        if (kind == 1u) {
            float r = min(zb_corner_radius(p, clip_shape_radii), min(half_size.x, half_size.y));
            float2 q = abs(p) - half_size + r;
            d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        } else {
            float2 safe = max(half_size, 0.001);
            d = (length(p / safe) - 1.0) * min(safe.x, safe.y);
        }
        coverage *= clamp(0.5 - d, 0.0, 1.0);
    }
    return coverage;
}
float4 blend_fragment_main(VOut input) : SV_Target {
    float2 fragment_pixel = input.position.xy;
    float4 destination_premul = destination_texture.Load(int3(int2(fragment_pixel),0));
    // Target pixel to layer-local pixel (any affine: rotate / draw_transform).
    float2 local = float2(inv.x * fragment_pixel.x + inv.z * fragment_pixel.y,
                          inv.y * fragment_pixel.x + inv.w * fragment_pixel.y) + inv_offset;
    if (local.x < 0.0 || local.y < 0.0 ||
        local.x >= rect_size.x || local.y >= rect_size.y) {
        return destination_premul;
    }

    // Lens warp: sample the surface shifted along the contour's normal, fading inward from the
    // contour (the rounded rect of corner_radii, inset by params.w).
    float2 sample_local = local;
    if (warp.x != 0.0 || warp.y != 0.0) {
        float2 half_size = rect_size * 0.5;
        float2 clip_half = max(half_size - params.w, float2(0.5, 0.5));
        float2 p = local - half_size;
        float r = min(zb_corner_radius(p, corner_radii), min(clip_half.x, clip_half.y));
        float2 q = abs(p) - clip_half + r;
        float inset = max(-(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r), 0.0);
        // along the contour's normal (see composite.metal)
        float2 sp = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
        float2 dir = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? float2(1.0, 0.0) : float2(0.0, 1.0));
        dir *= sp;
        float ny2 = dir.y * dir.y;
        float amount = lerp(warp.x, warp.y, ny2);
        float fade = 1.0 - smoothstep(warp.z, warp.z + max(warp.w, 0.01), inset);
        sample_local = clamp(local - dir * amount * fade, float2(0.0, 0.0), rect_size - 1.0);
    }
    float2 source_uv = src_uv_origin.xy + (sample_local / rect_size) * src_uv_scale;
    float4 source_premul = source_texture.Sample(texture_sampler, source_uv);
    // params.w: mask inset (the clip rect inside the quad)
    source_premul *= zb_rounded_rect_mask(local - params.w, rect_size - 2.0 * params.w, corner_radii) * zb_clip_coverage(fragment_pixel);
    float4 source = zb_unpremul(source_premul);
    float4 destination = zb_unpremul(destination_premul);

    float3 blended;
    switch (uint(params.y)) {
        case 1u:  blended = zb_multiply(source.rgb, destination.rgb);    break;
        case 2u:  blended = zb_screen(source.rgb, destination.rgb);      break;
        case 3u:  blended = zb_overlay(source.rgb, destination.rgb);     break;
        case 4u:  blended = zb_darken(source.rgb, destination.rgb);      break;
        case 5u:  blended = zb_lighten(source.rgb, destination.rgb);     break;
        case 6u:  blended = zb_color_dodge(source.rgb, destination.rgb); break;
        case 7u:  blended = zb_color_burn(source.rgb, destination.rgb);  break;
        case 8u:  blended = zb_hard_light(source.rgb, destination.rgb);  break;
        case 9u:  blended = zb_soft_light(source.rgb, destination.rgb);  break;
        case 10u: blended = zb_difference(source.rgb, destination.rgb);  break;
        case 11u: blended = zb_exclusion(source.rgb, destination.rgb);   break;
        default:  blended = source.rgb; break;
    }

    float source_alpha = source.a * params.x;
    float result_alpha = source_alpha + destination.a * (1.0 - source_alpha);
    float3 result_rgb = float3(0,0,0);
    if (result_alpha >= 0.0001) {
        result_rgb = (
            (1.0 - source_alpha) * destination.a * destination.rgb +
            source_alpha * destination.a * blended +
            (1.0 - destination.a) * source_alpha * source.rgb
        ) / result_alpha;
    }
    return float4(result_rgb * result_alpha, result_alpha);
}
