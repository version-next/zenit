/// Icon Shader
///
/// 专用于 UI icon 的单通道 mask 渲染。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport_size;
    float scale_factor;
    uint clip_shape_kind;
    float4 clip_rect;
    float clip_radius;
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_polygon_end_points[8];
    float2 clip_polygon_points[32];
};

struct IconInstanceData {
    float4 rect;
    float4 tint_color;
    float4 rect_clip;
    float corner_radius;
    float opacity;
    float rotate;         // 旋转角度（弧度），以中心为 transform origin
    float _padding2;
};

struct IconVertexOutput {
    float4 position [[position]];
    float2 uv;
    float2 local_pos;
    float2 size;
    float2 screen_pos;
    float4 rect_clip;
    uint instance_id;
};

float sdf_rounded_rect_icon(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

float sdf_ellipse_icon(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001));
    return length(q) - 1.0;
}

float point_segment_distance_icon(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

bool polygon_contains_icon(float2 p, constant Uniforms& uniforms, uint count, uint contour_count) {
    if (uniforms.clip_fill_rule == 0u) {
        bool inside = false;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(uniforms.clip_polygon_end_points[contour], count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = uniforms.clip_polygon_points[i] * uniforms.scale_factor;
                const float2 b = uniforms.clip_polygon_points[next] * uniforms.scale_factor;
                const float dy = b.y - a.y;
                const float denom = abs(dy) < 0.0001 ? (dy < 0.0 ? -0.0001 : 0.0001) : dy;
                const bool intersects = ((a.y > p.y) != (b.y > p.y)) &&
                    (p.x < (b.x - a.x) * (p.y - a.y) / denom + a.x);
                if (intersects) inside = !inside;
            }
            contour_start = contour_end;
        }
        return inside;
    }
    int winding = 0;
    uint contour_start = 0u;
    for (uint contour = 0u; contour < contour_count; contour++) {
        const uint contour_end = min(uniforms.clip_polygon_end_points[contour], count);
        if (contour_end <= contour_start + 1u) {
            contour_start = contour_end;
            continue;
        }
        for (uint i = contour_start; i < contour_end; i++) {
            const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
            const float2 a = uniforms.clip_polygon_points[i] * uniforms.scale_factor;
            const float2 b = uniforms.clip_polygon_points[next] * uniforms.scale_factor;
            if (a.y <= p.y) {
                if (b.y > p.y) {
                    const float cross = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y);
                    if (cross > 0.0) winding += 1;
                }
            } else if (b.y <= p.y) {
                const float cross = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y);
                if (cross < 0.0) winding -= 1;
            }
        }
        contour_start = contour_end;
    }
    return winding != 0;
}

float rect_clip_alpha_icon(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect_icon(screen_pos - clip_center, clip_size, 0.0);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_icon(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float clip_radius = uniforms.clip_radius * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_icon(screen_pos - clip_center, clip_size, clip_radius);
    } else if (uniforms.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_icon(screen_pos - clip_center, clip_size);
    } else if (uniforms.clip_shape_kind == 3u) {
        const uint count = min(uniforms.clip_point_count, 32u);
        const uint contour_count = min(uniforms.clip_contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return 1.0;
        }
        const float2 polygon_pos = screen_pos - uniforms.clip_rect.xy * uniforms.scale_factor;
        const bool inside = polygon_contains_icon(polygon_pos, uniforms, count, contour_count);
        float min_dist = INFINITY;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(uniforms.clip_polygon_end_points[contour], count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = uniforms.clip_polygon_points[i] * uniforms.scale_factor;
                const float2 b = uniforms.clip_polygon_points[next] * uniforms.scale_factor;
                min_dist = min(min_dist, point_segment_distance_icon(polygon_pos, a, b));
            }
            contour_start = contour_end;
        }
        const float clip_aa = max(length(float2(dfdx(screen_pos.x), dfdy(screen_pos.y))) * 0.5, 0.75);
        const float signed_dist = inside ? -min_dist : min_dist;
        return smoothstep(clip_aa, -clip_aa, signed_dist);
    }
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float clip_alpha_icon(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha_icon(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha_icon(screen_pos, uniforms);
}

vertex IconVertexOutput icon_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant IconInstanceData* instances [[buffer(1)]]
) {
    IconVertexOutput out;
    IconInstanceData inst = instances[instance_id];

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    uint indices[6] = {0, 1, 2, 1, 3, 2};
    const uint corner_index = indices[vertex_id];
    const float2 corner = corners[corner_index];

    const float s = uniforms.scale_factor;
    const float2 pos = inst.rect.xy * s;
    const float2 size = inst.rect.zw * s;
    float2 pixel_pos = pos + corner * size;

    // 旋转：以中心为 transform origin
    const float2 center = pos + size * 0.5;
    if (abs(inst.rotate) > 0.0001) {
        float cos_r = cos(inst.rotate);
        float sin_r = sin(inst.rotate);
        float2 rel = pixel_pos - center;
        pixel_pos = center + float2(
            rel.x * cos_r - rel.y * sin_r,
            rel.x * sin_r + rel.y * cos_r
        );
    }

    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    out.position = float4(ndc, 0.0, 1.0);
    out.uv = corner;
    // SDF 裁剪用的本地坐标（旋转前空间）
    out.local_pos = (pos + corner * size) - center;
    out.size = size * 0.5;
    out.screen_pos = pixel_pos;
    out.rect_clip = inst.rect_clip;
    out.instance_id = instance_id;
    return out;
}

fragment float4 icon_fragment_main(
    IconVertexOutput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant IconInstanceData* instances [[buffer(1)]],
    texture2d<float> mask_tex [[texture(0)]],
    sampler mask_sampler [[sampler(0)]]
) {
    const IconInstanceData inst = instances[in.instance_id];
    const float corner_radius = inst.corner_radius * uniforms.scale_factor;

    float alpha = mask_tex.sample(mask_sampler, in.uv).r;
    if (corner_radius > 0.0) {
        const float sdf = sdf_rounded_rect_icon(in.local_pos, in.size, corner_radius);
        const float aa = fwidth(sdf) * 0.5;
        alpha *= smoothstep(aa, -aa, sdf);
    }
    alpha *= clip_alpha_icon(in.screen_pos, in.rect_clip, uniforms);

    float4 color = inst.tint_color;
    color.a *= alpha * inst.opacity;
    if (color.a < 0.001) {
        discard_fragment();
    }
    color.rgb *= color.a;
    return color;
}
