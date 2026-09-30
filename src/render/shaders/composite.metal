#include <metal_stdlib>
using namespace metal;

struct BlendUniforms {
    float2 target_size;
    float2 rect_origin;
    float2 rect_size;
    float2 src_uv_scale;
    float4 params;
};

struct VOut { float4 position [[position]]; };

vertex VOut blend_vertex_main(uint vid [[vertex_id]]) {
    VOut out;
    float2 point = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    out.position = float4(point, 0.0, 1.0);
    return out;
}

float4 zb_unpremul(float4 color) {
    if (color.a < 0.0001) return float4(0.0);
    return float4(color.rgb / color.a, color.a);
}

float3 zb_multiply(float3 source, float3 destination) { return source * destination; }
float3 zb_screen(float3 source, float3 destination) { return source + destination - source * destination; }
float3 zb_hard_light(float3 source, float3 destination) {
    float3 low = 2.0 * source * destination;
    float3 high = 1.0 - 2.0 * (1.0 - source) * (1.0 - destination);
    return select(high, low, source <= 0.5);
}
float3 zb_overlay(float3 source, float3 destination) { return zb_hard_light(destination, source); }
float3 zb_darken(float3 source, float3 destination) { return min(source, destination); }
float3 zb_lighten(float3 source, float3 destination) { return max(source, destination); }
float3 zb_color_dodge(float3 source, float3 destination) {
    return select(min(float3(1.0), destination / max(1.0 - source, 0.0001)), float3(1.0), source >= 1.0);
}
float3 zb_color_burn(float3 source, float3 destination) {
    return select(1.0 - min(float3(1.0), (1.0 - destination) / max(source, 0.0001)), float3(0.0), source <= 0.0);
}
float3 zb_soft_light(float3 source, float3 destination) {
    float3 dd = select(sqrt(destination), ((16.0 * destination - 12.0) * destination + 4.0) * destination, destination <= 0.25);
    float3 low = destination - (1.0 - 2.0 * source) * destination * (1.0 - destination);
    float3 high = destination + (2.0 * source - 1.0) * (dd - destination);
    return select(high, low, source <= 0.5);
}
float3 zb_difference(float3 source, float3 destination) { return abs(source - destination); }
float3 zb_exclusion(float3 source, float3 destination) { return source + destination - 2.0 * source * destination; }

float zb_rounded_rect_mask(float2 point, float2 size, float radius) {
    if (radius <= 0.5) return 1.0;
    float2 half_size = size * 0.5;
    float2 q = abs(point - half_size) - half_size + radius;
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return clamp(0.5 - distance, 0.0, 1.0);
}

fragment float4 blend_fragment_main(
    VOut in [[stage_in]],
    texture2d<float> source_texture [[texture(0)]],
    texture2d<float> destination_texture [[texture(1)]],
    sampler texture_sampler [[sampler(0)]],
    constant BlendUniforms& uniforms [[buffer(0)]])
{
    float2 fragment_pixel = in.position.xy;
    float4 destination_premul = destination_texture.read(uint2(fragment_pixel));
    float2 local = fragment_pixel - uniforms.rect_origin;
    if (local.x < 0.0 || local.y < 0.0 ||
        local.x >= uniforms.rect_size.x || local.y >= uniforms.rect_size.y) {
        return destination_premul;
    }

    float2 source_uv = (local / uniforms.rect_size) * uniforms.src_uv_scale;
    float4 source_premul = source_texture.sample(texture_sampler, source_uv);
    source_premul *= zb_rounded_rect_mask(local, uniforms.rect_size, uniforms.params.z);
    float4 source = zb_unpremul(source_premul);
    float4 destination = zb_unpremul(destination_premul);

    float3 blended;
    switch (uint(uniforms.params.y)) {
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

    float source_alpha = source.a * uniforms.params.x;
    float result_alpha = source_alpha + destination.a * (1.0 - source_alpha);
    float3 result_rgb = float3(0.0);
    if (result_alpha >= 0.0001) {
        result_rgb = (
            (1.0 - source_alpha) * destination.a * destination.rgb +
            source_alpha * destination.a * blended +
            (1.0 - destination.a) * source_alpha * source.rgb
        ) / result_alpha;
    }
    return float4(result_rgb * result_alpha, result_alpha);
}
