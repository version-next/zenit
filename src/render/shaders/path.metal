/// Path Fill Shader (D5: 含边缘抗锯齿)
///
/// 顶点格式：(position.xy, alpha_scale)
///   - 填充三角形：alpha_scale = 1.0
///   - AA fringe 三角形：内侧顶点 alpha_scale = 1.0，外侧顶点 alpha_scale = 0.0
///
/// 通过 fringe strip 沿多边形轮廓软化边缘（约 0.5-1.0 像素宽）。
/// 使用 buffer(0) 直接访问顶点（与 SDF/Image renderer 保持一致，无需 VertexDescriptor）。

#include <metal_stdlib>
using namespace metal;

struct PathUniforms {
    float2 viewport_size;   // 逻辑像素视口尺寸
    float  scale_factor;    // Retina 比例（1.0 或 2.0）
    uint   draw_mode;       // 0 = triangles, 1 = polygon fill
    float4 color;           // draw color（通过 uniforms 传入）
    float4 rect;            // bbox x,y,w,h（逻辑像素）
    uint   fill_rule;       // 0 = evenodd, 1 = nonzero
    uint   point_count;
    uint   contour_count;
    uint   _pad0;
    uint   contour_end_points[8];
    float2 polygon_points[32];
    // shape clip mask（与 sdf/text/image/icon pipeline 对齐；path 只支持
    // kind 0=none / 1=rounded_rect / 2=ellipse，polygon clip 对 path 不生效）
    float4 clip_rect;       // 逻辑像素 x,y,w,h
    float  clip_radius;
    uint   clip_shape_kind;
    uint   _pad1;
    uint   _pad2;
};

struct PathVertexIn {
    float x;
    float y;
    float alpha_scale;
    // linear RGB + alpha（非预乘）。packed_float4 保持 4 字节对齐，
    // 与 CPU 端 28 字节 extern struct 布局一致（float4 会被对齐到 16）。
    packed_float4 color;
};

struct PathVertexOut {
    float4 position [[position]];
    float4 fill_color;
    float2 local_pos;
};

/// 将逻辑像素坐标转换为 NDC（clip space）
float4 to_clip(float2 pos, float2 vp_size) {
    float x = (pos.x / vp_size.x) * 2.0 - 1.0;
    float y = 1.0 - (pos.y / vp_size.y) * 2.0;
    return float4(x, y, 0.0, 1.0);
}

vertex PathVertexOut path_vertex_main(
    uint                          vid      [[vertex_id]],
    device const PathVertexIn*    vertices [[buffer(0)]],
    constant PathUniforms&        u        [[buffer(1)]])
{
    PathVertexIn v = vertices[vid];
    PathVertexOut out;
    out.position = to_clip(float2(v.x, v.y), u.viewport_size);
    out.local_pos = float2(v.x - u.rect.x, v.y - u.rect.y);
    // 颜色 per-vertex（CPU 端已做 sRGB→linear），使 triangles draw call 可合批；
    // polygon_fill 分支的 fragment 仍读 u.color。alpha_scale 用于 AA fringe。
    float4 vcolor = float4(v.color);
    float a = vcolor.a * v.alpha_scale;
    out.fill_color = float4(vcolor.rgb * a, a);
    return out;
}

bool polygon_contains_path(float2 p, constant PathUniforms& uniforms) {
    if (uniforms.fill_rule == 0u) {
        bool inside = false;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < uniforms.contour_count; contour++) {
            const uint contour_end = min(uniforms.contour_end_points[contour], uniforms.point_count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = uniforms.polygon_points[i];
                const float2 b = uniforms.polygon_points[next];
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
    for (uint contour = 0u; contour < uniforms.contour_count; contour++) {
        const uint contour_end = min(uniforms.contour_end_points[contour], uniforms.point_count);
        if (contour_end <= contour_start + 1u) {
            contour_start = contour_end;
            continue;
        }
        for (uint i = contour_start; i < contour_end; i++) {
            const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
            const float2 a = uniforms.polygon_points[i];
            const float2 b = uniforms.polygon_points[next];
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

float point_segment_distance_path(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

float sdf_rounded_rect_path(float2 p, float2 half_size, float radius) {
    const float2 q = abs(p) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float sdf_ellipse_path(float2 p, float2 half_size) {
    const float2 safe = max(half_size, float2(0.0001));
    const float2 n = p / safe;
    const float d = length(n) - 1.0;
    return d * min(safe.x, safe.y);
}

/// screen_pos 为 device px（fragment [[position]]）；clip_rect 为逻辑像素。
float shape_clip_alpha_path(float2 screen_pos, constant PathUniforms& u) {
    if (u.clip_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (u.clip_rect.xy + u.clip_rect.zw * 0.5) * u.scale_factor;
    const float2 clip_size = u.clip_rect.zw * u.scale_factor * 0.5;
    float clip_sdf = -1.0;
    if (u.clip_shape_kind == 1u) {
        clip_sdf = sdf_rounded_rect_path(screen_pos - clip_center, clip_size, u.clip_radius * u.scale_factor);
    } else if (u.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_path(screen_pos - clip_center, clip_size);
    }
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

fragment float4 path_fragment_main(PathVertexOut in [[stage_in]], constant PathUniforms& u [[buffer(1)]])
{
    const float clip_alpha = shape_clip_alpha_path(in.position.xy, u);
    if (u.draw_mode == 1u) {
        const uint count = min(u.point_count, 32u);
        const uint contour_count = min(u.contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return float4(0.0);
        }

        const float2 polygon_pos = in.local_pos;
        const bool inside = polygon_contains_path(polygon_pos, u);
        float min_dist = INFINITY;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(u.contour_end_points[contour], count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = u.polygon_points[i];
                const float2 b = u.polygon_points[next];
                min_dist = min(min_dist, point_segment_distance_path(polygon_pos, a, b));
            }
            contour_start = contour_end;
        }

        const float aa = max(length(float2(dfdx(in.local_pos.x), dfdy(in.local_pos.y))) * 0.5, 0.75 / max(u.scale_factor, 1.0));
        const float signed_dist = inside ? -min_dist : min_dist;
        const float alpha = smoothstep(aa, -aa, signed_dist) * u.color.a * clip_alpha;
        return float4(u.color.rgb * alpha, alpha);
    }
    return in.fill_color * clip_alpha;
}
