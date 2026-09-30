/// Image Shader
///
/// Metal Shading Language 实现的图片渲染
/// 支持：纹理采样、SDF 圆角裁剪、alpha 混合
/// 每个 instance 对应一个纹理化矩形

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Uniforms 和顶点数据结构
// ============================================================================

/// 全局 Uniforms
struct Uniforms {
    float2 viewport_size;  // 视口尺寸（物理像素）
    float scale_factor;    // DPI 缩放因子 (Retina=2.0)
    uint clip_shape_kind;
    float4 clip_rect;
    float clip_radius;
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_polygon_end_points[8];
    float2 clip_polygon_points[32];
};

/// 实例数据（每个图片一个）— 64 bytes
struct ImageInstanceData {
    float4 rect;          // x, y, width, height（逻辑像素）
    float4 uv_rect;       // u0, v0, u1, v1 (纹理坐标范围)
    float4 tint_color;    // 着色颜色 RGBA (1,1,1,1 = 无着色)
    float4 transform_linear; // a, b, c, d（逻辑像素 affine）
    float2 transform_translation; // tx, ty（逻辑像素 affine）
    float corner_radius;  // 圆角半径
    float opacity;        // 不透明度 (0-1)
    float source_premultiplied; // 是否为预乘 alpha 源纹理（离屏 layer 回贴）
    float4 rect_clip;     // x, y, w, h（逻辑像素）；0-size = disabled
};

/// 顶点输出
struct ImageVertexOutput {
    float4 position [[position]];
    float2 uv;            // 纹理坐标
    float2 local_pos;     // 相对于图元中心的位置
    float2 size;          // 图元尺寸的一半
    float2 screen_pos;    // 当前片元的物理像素坐标
    float4 rect_clip;
    uint instance_id;
};

// ============================================================================
// SDF 函数 (用于圆角裁剪)
// ============================================================================

float sdf_rounded_rect_image(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

float sdf_ellipse_image(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001));
    return length(q) - 1.0;
}

float point_segment_distance_image(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

bool polygon_contains_image(float2 p, constant Uniforms& uniforms, uint count, uint contour_count) {
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

float rect_clip_alpha(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect_image(screen_pos - clip_center, clip_size, 0.0);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float clip_radius = uniforms.clip_radius * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_image(screen_pos - clip_center, clip_size, clip_radius);
    } else if (uniforms.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_image(screen_pos - clip_center, clip_size);
    } else if (uniforms.clip_shape_kind == 3u) {
        const uint count = min(uniforms.clip_point_count, 32u);
        const uint contour_count = min(uniforms.clip_contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return 1.0;
        }
        const float2 polygon_pos = screen_pos - uniforms.clip_rect.xy * uniforms.scale_factor;
        const bool inside = polygon_contains_image(polygon_pos, uniforms, count, contour_count);
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
                min_dist = min(min_dist, point_segment_distance_image(polygon_pos, a, b));
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

float clip_alpha(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha(screen_pos, uniforms);
}

// ============================================================================
// 顶点着色器
// ============================================================================

vertex ImageVertexOutput image_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant ImageInstanceData* instances [[buffer(1)]]
) {
    ImageVertexOutput out;

    ImageInstanceData inst = instances[instance_id];

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    uint indices[6] = {0, 1, 2, 1, 3, 2};
    uint corner_index = indices[vertex_id];
    float2 corner = corners[corner_index];

    float s = uniforms.scale_factor;
    float2 local_pos = inst.rect.xy + corner * inst.rect.zw;
    float2 logical_pos = float2(
        inst.transform_linear.x * local_pos.x + inst.transform_linear.z * local_pos.y + inst.transform_translation.x,
        inst.transform_linear.y * local_pos.x + inst.transform_linear.w * local_pos.y + inst.transform_translation.y
    );
    float2 pixel_pos = logical_pos * s;
    float2 center_local = inst.rect.xy + inst.rect.zw * 0.5;

    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    out.position = float4(ndc, 0.0, 1.0);

    // 纹理坐标插值
    out.uv = mix(inst.uv_rect.xy, inst.uv_rect.zw, corner);

    // SDF 裁剪用的本地坐标保持在未变换空间，圆角跟随内容本身而不是跟随屏幕 AABB。
    out.local_pos = (local_pos - center_local) * s;
    out.size = inst.rect.zw * s * 0.5;
    out.screen_pos = pixel_pos;
    out.rect_clip = inst.rect_clip;

    out.instance_id = instance_id;

    return out;
}

// ============================================================================
// 片段着色器
// ============================================================================

fragment float4 image_fragment_main(
    ImageVertexOutput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant ImageInstanceData* instances [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    ImageInstanceData inst = instances[in.instance_id];
    const float corner_radius = inst.corner_radius * uniforms.scale_factor;

    // 采样纹理
    float4 color = tex.sample(smp, in.uv);

    // 着色
    color *= inst.tint_color;

    float coverage = 1.0;

    // 圆角裁剪
    if (corner_radius > 0.0) {
        float sdf = sdf_rounded_rect_image(in.local_pos, in.size, corner_radius);
        float aa = fwidth(sdf) * 0.5;
        coverage *= smoothstep(aa, -aa, sdf);
    }

    coverage *= clip_alpha(in.screen_pos, in.rect_clip, uniforms);
    coverage *= inst.opacity;

    if (inst.source_premultiplied > 0.5) {
        color *= coverage;
    } else {
        color.a *= coverage;
        color.rgb *= color.a;
    }

    if (color.a < 0.001) {
        discard_fragment();
    }
    return color;
}
