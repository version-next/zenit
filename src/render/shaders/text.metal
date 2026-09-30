/// Text Shader - Metal Shading Language
///
/// GPU 实例化文本渲染
/// 每个字形作为一个实例渲染

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 数据结构
// ============================================================================

/// 全局 Uniforms
struct Uniforms {
    float2 viewport_size;  // 视口尺寸（像素）
    float scale_factor;    // DPI 缩放因子
    uint clip_shape_kind;
    float4 clip_rect;
    float clip_radius;
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_polygon_end_points[8];
    float2 clip_polygon_points[32];
};

/// 字形实例数据
struct GlyphInstance {
    float2 position;      // 字形左下角位置（像素）
    float2 size;          // 字形尺寸（像素）
    float4 uv_rect;       // UV 矩形 (u_min, v_min, u_max, v_max)
    float4 color;         // 字形颜色 RGBA
    float4 rect_clip;     // x, y, w, h（逻辑像素）；0-size = disabled
    float skew_x;         // 合成斜体 x 偏移（逻辑像素）
    float page_index;     // Atlas 页号（CPU 分桶用，shader 不读）
    float is_color;       // >0.5 = 该字形在 BGRA 彩色页（emoji），采样即最终颜色
    float shader_snap;    // >0.5 = position 吸附到物理像素；动画文本置 0（连续坐标）
};

/// 顶点输出
struct VertexOutput {
    float4 position [[position]];
    float2 uv;
    float2 screen_pos;
    float4 rect_clip;
    uint instance_id;
};

float sdf_rounded_rect_text(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

float sdf_ellipse_text(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001));
    return length(q) - 1.0;
}

float point_segment_distance_text(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

bool polygon_contains_text(float2 p, constant Uniforms& uniforms, uint count, uint contour_count) {
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

float rect_clip_alpha_text(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect_text(screen_pos - clip_center, clip_size, 0.0);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_text(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float clip_radius = uniforms.clip_radius * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_text(screen_pos - clip_center, clip_size, clip_radius);
    } else if (uniforms.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_text(screen_pos - clip_center, clip_size);
    } else if (uniforms.clip_shape_kind == 3u) {
        const uint count = min(uniforms.clip_point_count, 32u);
        const uint contour_count = min(uniforms.clip_contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return 1.0;
        }
        const float2 polygon_pos = screen_pos - uniforms.clip_rect.xy * uniforms.scale_factor;
        const bool inside = polygon_contains_text(polygon_pos, uniforms, count, contour_count);
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
                min_dist = min(min_dist, point_segment_distance_text(polygon_pos, a, b));
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

float clip_alpha_text(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha_text(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha_text(screen_pos, uniforms);
}

// ============================================================================
// 顶点着色器
// ============================================================================

vertex VertexOutput text_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant GlyphInstance* instances [[buffer(1)]]
) {
    VertexOutput out;

    GlyphInstance inst = instances[instance_id];

    // 四边形顶点位置（相对于字形左下角）
    // 顶点顺序: 0=左下, 1=右下, 2=左上, 3=右上
    // 三角形: 0-1-2, 1-3-2
    float2 corners[4] = {
        float2(0.0, 0.0),  // 左下
        float2(1.0, 0.0),  // 右下
        float2(0.0, 1.0),  // 左上
        float2(1.0, 1.0)   // 右上
    };

    uint indices[6] = {0, 1, 2, 1, 3, 2};
    uint corner_index = indices[vertex_id];
    float2 corner = corners[corner_index];

    // 计算像素位置（逻辑像素 -> 物理像素）
    // shader_snap>0.5 时吸附到物理像素（静态/surface 内文本；CPU 已按同规则吸附，
    // 此处幂等）。动画文本 (direct_animated) 传 0：保持连续浮点坐标，逐 glyph
    // round 会让相邻字形在不同帧跨越取整阈值，产生字距/基线跳动。
    float s = uniforms.scale_factor;
    float2 scaled_pos = inst.position * s;
    float2 base_pos = (inst.shader_snap > 0.5) ? round(scaled_pos) : scaled_pos;
    float2 pixel_pos = base_pos + corner * inst.size * s;

    // 合成斜体：顶部向右偏移，底部不动
    // 屏幕坐标系 Y 向下：corner.y=0 是顶部，corner.y=1 是底部
    pixel_pos.x += (1.0 - corner.y) * inst.skew_x * s;

    // 转换到 NDC（-1 到 1）
    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Metal Y 轴向下

    out.position = float4(ndc, 0.0, 1.0);

    // 计算 UV
    out.uv = mix(inst.uv_rect.xy, inst.uv_rect.zw, corner);
    out.screen_pos = pixel_pos;
    out.rect_clip = inst.rect_clip;

    out.instance_id = instance_id;

    return out;
}

// ============================================================================
// 片段着色器
// ============================================================================

fragment float4 text_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant GlyphInstance* instances [[buffer(1)]],
    texture2d<float> glyph_atlas [[texture(0)]],
    texture2d<float> glyph_atlas_color [[texture(1)]],
    sampler atlas_sampler [[sampler(0)]]
) {
    const GlyphInstance inst = instances[in.instance_id];
    const float clip_a = clip_alpha_text(in.screen_pos, in.rect_clip, uniforms);

    float4 result;
    if (inst.is_color > 0.5) {
        // 彩色字形（emoji）：BGRA 页里存的已经是 premultiplied 的最终颜色。
        // **不能**乘 inst.color —— emoji 自带颜色，乘上文字色会把它重新染成
        // 单色，等于白做。这里只叠 clip alpha 与整体不透明度。
        const float4 texel = glyph_atlas_color.sample(atlas_sampler, in.uv);
        const float a = clip_a * inst.color.a;
        result = texel * a;  // texel 已预乘，整体再缩放保持预乘不变式
        if (result.a < 0.001) {
            discard_fragment();
        }
        return result;
    }

    // 灰度字形：单通道当覆盖率，乘文字颜色（原逻辑，一字未改）
    float alpha = glyph_atlas.sample(atlas_sampler, in.uv).r;

    result = inst.color;
    result.a *= alpha * clip_a;

    // 丢弃完全透明的像素
    if (result.a < 0.001) {
        discard_fragment();
    }

    // 输出预乘 alpha，匹配 premultiplied blend state
    result.rgb *= result.a;
    return result;
}
