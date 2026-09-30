/// SDF Primitives Shader
///
/// Metal Shading Language 实现的 SDF 图元渲染
/// 支持：圆角矩形、圆形、线条
/// 特性：抗锯齿、阴影、渐变、发光

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
    uint frame_seed;  // 每帧递增，驱动 film_grain 动态噪声
};

/// 实例数据（每个图元一个）— 176 bytes
struct InstanceData {
    // ── 核心几何 ─────────────────────────────────────── offset 0
    float4 rect;              // x, y, width, height（逻辑像素）
    float4 rect_clip;         // x, y, w, h（逻辑像素）；negative size = disabled
    // ── 颜色 ────────────────────────────────────────── offset 32
    float4 fill_color;        // 填充颜色 RGBA (gradient: from)
    float4 border_color;      // 边框颜色 RGBA
    float4 shadow_color;      // 阴影颜色 RGBA
    float4 gradient_to_color; // 渐变终止颜色 RGBA（stop_count=0 时使用）
    float4 corner_radii;      // 四角圆角半径: TL, TR, BR, BL
    // ── 标量效果参数 ──────────────────────────────────── offset 112
    float border_width;       // 边框宽度
    float shadow_blur;        // 阴影模糊半径（外阴影）
    float shadow_offset_x;    // 阴影 X 偏移
    float shadow_offset_y;    // 阴影 Y 偏移
    // ── 类型和标志 ────────────────────────────────────── offset 128
    uint shape_type;          // 0=rect, 1=circle, 2=line, 3=arc
    /// packed_flags 布局：
    ///   bit 0-7:  gradient_direction (0=none,1=vert,2=horiz,3=diag,4=radial,5=conic)
    ///   bit 8-15: noise_mode (0=none, 1=value, 2=film_grain)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:   inset_shadow
    ///   bit 25:   has_shadow2
    uint packed_flags;
    float noise_scale;        // 噪声缩放（逻辑像素单位，0=禁用）
    float noise_intensity;    // 噪声混合强度 [0..1]
    // ── Per-side border ──────────────────────────────── offset 144
    float4 border_widths;     // per-side: top, right, bottom, left; 全零=用 border_width
    // ── 多色渐变 / 多重阴影索引 ──────────────────────── offset 160
    uint gradient_stop_offset; // GradientStop buffer 起始索引（stop_count=0 时忽略）
    uint gradient_stop_count;  // stop 数量（0 = 用旧两色 fill/gradient_to_color）
    uint shadow2_index;        // ShadowParam buffer 中第二阴影的索引
    uint _ext_reserved;        // 保留扩展
};

/// 顶点输出
struct VertexOutput {
    float4 position [[position]];
    float2 local_pos;      // 相对于图元中心的位置
    float2 size;           // 图元尺寸的一半
    float2 uv;            // 归一化坐标 (0-1)
    float2 screen_pos;    // 当前片元的物理像素坐标
    float4 rect_clip;
    uint instance_id;
};

// ============================================================================
// 程序性噪声函数
// ============================================================================

/// Wang hash — 快速整数 hash
uint hash_wang(uint x) {
    x = (x ^ 61u) ^ (x >> 16u);
    x = x + (x << 3u);
    x = x ^ (x >> 4u);
    x = x * 0x27d4eb2du;
    x = x ^ (x >> 15u);
    return x;
}

/// 2D 整数坐标 → [0,1] float hash
float hash2d(float2 p) {
    uint ix = uint(abs(p.x) * 1000.0);
    uint iy = uint(abs(p.y) * 1000.0);
    return float(hash_wang(ix ^ hash_wang(iy * 2654435761u))) / 4294967295.0;
}

/// Value Noise：双线性插值格点噪声
/// p: 局部坐标（逻辑像素），scale: 格点间距，seed: 实例种子
float value_noise(float2 p, float scale, uint seed) {
    float2 sp = p / max(scale, 0.001) + float2(float(seed) * 17.3, float(seed) * 31.7);
    float2 i = floor(sp);
    float2 f = fract(sp);
    float2 u = f * f * (3.0 - 2.0 * f); // Hermite 平滑插值
    float a = hash2d(i);
    float b = hash2d(i + float2(1.0, 0.0));
    float c = hash2d(i + float2(0.0, 1.0));
    float d = hash2d(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Film Grain：基于物理像素坐标的高频颗粒噪声
/// screen_pos: 物理像素坐标，seed: 实例种子
float film_grain(float2 screen_pos, uint seed) {
    return hash2d(floor(screen_pos) + float2(float(seed & 255u) * 3.7, float((seed >> 8u) & 255u) * 5.1)) - 0.5;
}

// ============================================================================
// 多色渐变
// ============================================================================

/// GradientStop：多色渐变色标（buffer slot 2）
struct GradientStop {
    float4 color;    // RGBA linear
    float  position; // [0.0, 1.0]
    float  _pad0;
    float  _pad1;
    float  _pad2;
    // 32 bytes per stop
};

// ============================================================================
// Bayer 有序抖动（Blend2D 启发）
// ============================================================================
//
// 16×16 Bayer 矩阵，值域 [0, 255]，编译期常量
// 用于在渐变写入 8bit framebuffer 前添加次像素偏移，消除色阶 banding
// 参考：Blend2D fetchgradientpart.cpp GradientDitheringContext
constant uchar bayer_16x16[256] = {
      0,128, 32,160,  8,136, 40,168,  2,130, 34,162, 10,138, 42,170,
    192, 64,224, 96,200, 72,232,104,194, 66,226, 98,202, 74,234,106,
     48,176, 16,144, 56,184, 24,152, 50,178, 18,146, 58,186, 26,154,
    240,112,208, 80,248,120,216, 88,242,114,210, 82,250,122,218, 90,
     12,140, 44,172,  4,132, 36,164, 14,142, 46,174,  6,134, 38,166,
    204, 76,236,108,196, 68,228,100,206, 78,238,110,198, 70,230,102,
     60,188, 28,156, 52,180, 20,148, 62,190, 30,158, 54,182, 22,150,
    252,124,220, 92,244,116,212, 84,254,126,222, 94,246,118,214, 86,
      3,131, 35,163, 11,139, 43,171,  1,129, 33,161,  9,137, 41,169,
    195, 67,227, 99,203, 75,235,107,193, 65,225, 97,201, 73,233,105,
     51,179, 19,147, 59,187, 27,155, 49,177, 17,145, 57,185, 25,153,
    243,115,211, 83,251,123,219, 91,241,113,209, 81,249,121,217, 89,
     15,143, 47,175,  7,135, 39,167, 13,141, 45,173,  5,133, 37,165,
    207, 79,239,111,199, 71,231,103,205, 77,237,109,197, 69,229,101,
     63,191, 31,159, 55,183, 23,151, 61,189, 29,157, 53,181, 21,149,
    255,127,223, 95,247,119,215, 87,253,125,221, 93,245,117,213, 85,
};

/// 从物理像素坐标取 Bayer 阈值，归一化到 [-0.5/255, +0.5/255]
/// 用于渐变颜色写入前的次像素抖动
inline float bayer_dither(float2 screen_pos) {
    uint ix = uint(screen_pos.x) & 15u;
    uint iy = uint(screen_pos.y) & 15u;
    return (float(bayer_16x16[iy * 16u + ix]) - 127.5) / 65025.0; // ÷(255×255) 保持能量守恒
}

// ============================================================================
// 多色渐变
// ============================================================================

/// Premultiplied alpha 辅助（Blend2D 启发）
/// 渐变插值在 premul 空间进行，避免半透明 stop 间颜色偏移
inline float4 premul(float4 c)   { return float4(c.rgb * c.a, c.a); }
inline float4 unpremul(float4 c) {
    return c.a > 1e-6 ? float4(c.rgb / c.a, c.a) : float4(0.0);
}

/// 多色渐变求值（premultiplied alpha 空间插值，stops 须按 position 升序）
float4 eval_gradient_stops(float t, constant GradientStop* stops, uint offset, uint count) {
    if (count == 0u) return float4(0.0);
    if (count > 16u) return float4(1.0, 0.0, 1.0, 1.0); // 品红 = 参数错误（count 上限 16）
    if (count == 1u) return stops[offset].color;
    float min_pos = stops[offset].position;
    float max_pos = stops[offset + count - 1u].position;
    float t_c = clamp(t, min_pos, max_pos);
    for (uint i = 0u; i < count - 1u; i++) {
        GradientStop s0 = stops[offset + i];
        GradientStop s1 = stops[offset + i + 1u];
        if (t_c >= s0.position && t_c <= s1.position) {
            float span = s1.position - s0.position;
            float lt = (span > 1e-6) ? (t_c - s0.position) / span : 0.0;
            // premul 空间插值：避免半透明 stop 之间 RGB 颜色偏移
            float4 result_premul = mix(premul(s0.color), premul(s1.color), lt);
            return unpremul(result_premul);
        }
    }
    return stops[offset + count - 1u].color;
}

// ============================================================================
// 多重阴影
// ============================================================================

/// ShadowParam：第二个阴影参数（buffer slot 3）
struct ShadowParam {
    float4 color;
    float  blur;
    float  offset_x;
    float  offset_y;
    float  _pad;
    // 32 bytes
};

// ============================================================================
// SDF 函数
// ============================================================================

/// SDF 圆角矩形（统一半径）
float sdf_rounded_rect(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

float sdf_ellipse_clip(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001));
    return length(q) - 1.0;
}

/// 椭圆 SDF —— **返回真实像素距离**（梯度归一化的一阶 Newton 估计）。
///
/// ⚠ 不要复用上面的 `sdf_ellipse_clip`：它返回**无量纲**的 `length(p/r)-1`，
/// 只对裁剪成立（`shape_clip_alpha` 用 `fwidth` 自归一化）。填充路径的 AA 宽度
/// 来自 `get_aa_width(local_pos)`，单位是**像素** —— 量纲不匹配会让 AA 过渡带
/// 错几十倍，边缘要么硬锯齿要么糊成一片。
///
/// 也不要退回 `(length(p/r)-1) * min(rx,ry)`（`path.metal` 里那种）：实测
/// 10:1 椭圆的长轴端点读数只有真实距离的 **1/10**，AA 在扁端被拉宽 10 倍，
/// 而 2:1 椭圆的描边就已经一边粗一倍（`abs(sdf)` 型描边宽 2.0px→4.0px）。
///
/// 正确做法：椭圆没有解析闭式 SDF，用隐函数 `f = |p/r| - 1` 除以梯度模长
/// 得到一阶距离估计。实测贴近边界处（AA/描边真正生效的地方）误差 0.2~2.4%，
/// 远小于一个像素；10:1 极端比例下最坏 8%，肉眼不可察。
float sdf_ellipse(float2 p, float2 radius_xy) {
    const float2 r = max(radius_xy, float2(0.001));
    const float2 q = p / r;
    const float k = length(q);
    // 中心点：梯度为 0，退化成"到最近边界"的最短半轴距离
    if (k < 1e-6) return -min(r.x, r.y);
    // |∇f| = length(p / r²) / k
    const float g = length(p / (r * r)) / k;
    return (k - 1.0) / max(g, 1e-6);
}

float point_segment_distance(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

int polygon_winding(float2 p, constant Uniforms& uniforms, uint count, uint contour_count) {
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
    return winding;
}

bool polygon_contains(float2 p, constant Uniforms& uniforms, uint count, uint contour_count) {
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
    return polygon_winding(p, uniforms, count, contour_count) != 0;
}

/// SDF 圆角矩形（四角独立半径）
/// radii: top-left, top-right, bottom-right, bottom-left
float sdf_rounded_rect_4(float2 p, float2 size, float4 radii) {
    // 根据象限选择对应圆角
    float r = (p.x < 0.0)
        ? ((p.y < 0.0) ? radii.x : radii.w)   // 左侧: TL / BL
        : ((p.y < 0.0) ? radii.y : radii.z);   // 右侧: TR / BR
    float2 d = abs(p) - size + r;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - r;
}

/// SDF 圆形
float sdf_circle(float2 p, float radius) {
    return length(p) - radius;
}

/// SDF 线条（胶囊形）
float sdf_line(float2 p, float2 a, float2 b, float thickness) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - thickness;
}

/// SDF 圆弧（圆环的一段）
/// p: 相对于圆心的位置
/// outer_radius: 外半径
/// stroke_width: 线宽
/// start_angle: 起始角（弧度，任意值，不需要规范化）
/// end_angle: 结束角（弧度，end >= start，sweep = end - start）
float sdf_arc(float2 p, float outer_radius, float stroke_width, float start_angle, float end_angle) {
    float mid_radius = outer_radius - stroke_width * 0.5;
    float half_stroke = stroke_width * 0.5;

    // 圆环 SDF（不带角度裁剪）
    float ring_sdf = abs(length(p) - mid_radius) - half_stroke;

    // sweep = 弧长角度，clamp 到 [0, 2π]
    float sweep = clamp(end_angle - start_angle, 0.0, 2.0 * M_PI_F);

    // sweep >= 2π：完整圆环，直接返回
    if (sweep >= 2.0 * M_PI_F - 0.0001) {
        return ring_sdf;
    }

    // 把 p 的极角相对 start_angle 规范化到 [0, 2π)
    float raw_angle = atan2(p.y, p.x);
    float rel = raw_angle - start_angle;
    // 规范化到 [0, 2π)
    rel = rel - floor(rel / (2.0 * M_PI_F)) * (2.0 * M_PI_F);

    // rel 在 [0, sweep] 内 → 在弧段内
    if (rel <= sweep) {
        return ring_sdf;
    }

    // 弧段外：直接返回正数（不渲染端帽，平头截断）
    return half_stroke + 1.0;
}

// ============================================================================
// 抗锯齿函数
// ============================================================================

float aa_step(float edge, float x, float aa_width) {
    return smoothstep(edge + aa_width, edge - aa_width, x);
}

float rect_clip_alpha(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect(screen_pos - clip_center, clip_size, 0.0);
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
        clip_sdf = sdf_rounded_rect(screen_pos - clip_center, clip_size, clip_radius);
    } else if (uniforms.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_clip(screen_pos - clip_center, clip_size);
    } else if (uniforms.clip_shape_kind == 3u) {
        const uint count = min(uniforms.clip_point_count, 32u);
        const uint contour_count = min(uniforms.clip_contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return 1.0;
        }
        const float2 polygon_pos = screen_pos - uniforms.clip_rect.xy * uniforms.scale_factor;
        bool inside = polygon_contains(polygon_pos, uniforms, count, contour_count);
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
                min_dist = min(min_dist, point_segment_distance(polygon_pos, a, b));
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

float get_aa_width(float2 local_pos) {
    return length(float2(dfdx(local_pos.x), dfdy(local_pos.y))) * 0.5;
}

// src-over 预乘 alpha 合成
inline void composite_premul(thread float4& dst, float4 src) {
    dst += src * (1.0 - dst.a);
}

// ============================================================================
// 顶点着色器
// ============================================================================

vertex VertexOutput sdf_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant InstanceData* instances [[buffer(1)]],
    constant ShadowParam* shadow_params [[buffer(3)]]
) {
    VertexOutput out;

    InstanceData inst = instances[instance_id];

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    uint indices[6] = {0, 1, 2, 1, 3, 2};
    uint corner_index = indices[vertex_id];
    float2 corner = corners[corner_index];

    // Instance 坐标是逻辑像素，乘以 scale_factor 转物理像素
    float s = uniforms.scale_factor;

    float expand = inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
    // bit 28：外阴影带 spread（noise_scale 复用），正 spread 让 quad 同步外扩。
    if ((inst.packed_flags & (1u << 28u)) != 0u) expand += max(inst.noise_scale, 0.0);
    // 双层阴影：quad 必须覆盖两层中扩展更大的那层，否则第二层大 blur 阴影
    // 在 quad 边缘被硬切（面板周围一圈矩形亮带）。
    if ((inst.packed_flags & (1u << 25u)) != 0u) {
        ShadowParam s2v = shadow_params[inst.shadow2_index];
        float expand2 = s2v.blur * 2.0 + abs(s2v.offset_x) + abs(s2v.offset_y);
        expand = max(expand, expand2);
    }

    float2 pos = (inst.rect.xy - expand) * s;
    float2 size = (inst.rect.zw + expand * 2.0) * s;
    float2 pixel_pos = pos + corner * size;

    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    out.position = float4(ndc, 0.0, 1.0);

    float2 center = inst.rect.xy * s + inst.rect.zw * s * 0.5;
    out.local_pos = pixel_pos - center;
    out.size = inst.rect.zw * s * 0.5;
    out.screen_pos = pixel_pos;

    out.uv = corner;
    out.rect_clip = inst.rect_clip;
    out.instance_id = instance_id;

    return out;
}

// ============================================================================
// 片段着色器
// ============================================================================

fragment float4 sdf_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms        [[buffer(0)]],
    constant InstanceData* instances   [[buffer(1)]],
    constant GradientStop* grad_stops  [[buffer(2)]],
    constant ShadowParam* shadow_params[[buffer(3)]]
) {
    InstanceData inst = instances[in.instance_id];
    const float s = uniforms.scale_factor;
    const float4 corner_radii = inst.corner_radii * s;
    const float corner_radius_max = max(max(corner_radii.x, corner_radii.y), max(corner_radii.z, corner_radii.w));
    const float border_width = inst.border_width * s;
    const float shadow_blur = inst.shadow_blur * s;
    const float2 shadow_offset = float2(inst.shadow_offset_x, inst.shadow_offset_y) * s;

    float sdf;

    switch (inst.shape_type) {
        case 0:
            sdf = sdf_rounded_rect_4(in.local_pos, in.size, corner_radii);
            break;
        case 1:
            sdf = sdf_circle(in.local_pos, min(in.size.x, in.size.y));
            break;
        case 2:
            sdf = abs(in.local_pos.y) - corner_radii.x;
            break;
        case 3:
            // arc: corner_radii.x = 外半径, border_width = 线宽
            //      shadow_offset_x = 起始角(弧度), shadow_offset_y = 结束角(弧度)
            sdf = sdf_arc(
                in.local_pos,
                corner_radii.x,
                inst.border_width * s,
                inst.shadow_offset_x,
                inst.shadow_offset_y
            );
            break;
        case 4:
            // ellipse: in.size 是半轴 (与 sdf_rounded_rect_4 同约定)
            sdf = sdf_ellipse(in.local_pos, in.size);
            break;
        default:
            sdf = 1.0;
            break;
    }

    float aa_width = get_aa_width(in.local_pos);
    if (aa_width < 0.5) aa_width = 0.5;

    float fill_alpha = aa_step(0.0, sdf, aa_width);

    float border_alpha = 0.0;
    float4 bw = inst.border_widths * s;
    // ⚠ per-side 分支的内轮廓**硬编码** sdf_rounded_rect_4（见下），对非矩形
    // 形状会画出"矩形描边套在椭圆填充外面"。椭圆没有"四条边"，per-side 本身
    // 无意义 —— 这里直接门禁掉，让它走 uniform 快速路径（`sdf + border_width`，
    // 与形状无关，自动正确）。Zig 侧 `addEllipse` 负责把四个值折叠成
    // `border_width = max(...)`，不能取第一个：{0,0,0,4} 会静默变成 0 宽描边。
    bool has_per_side = (bw.x + bw.y + bw.z + bw.w) > 0.0 && inst.shape_type == 0u;

    if (has_per_side) {
        // Per-side border: 计算内轮廓 SDF
        // bw = (top, right, bottom, left)
        float2 inner_half = float2(
            in.size.x - (bw.y + bw.w) * 0.5,
            in.size.y - (bw.x + bw.z) * 0.5
        );
        inner_half = max(inner_half, float2(0.0));

        // 不对称 border 导致内矩形中心偏移
        float2 inner_offset = float2(
            (bw.w - bw.y) * 0.5,
            (bw.x - bw.z) * 0.5
        );

        // 内圆角 = max(0, 外圆角 - max(相邻两边宽度))
        float4 inner_radii = max(corner_radii - float4(
            max(bw.x, bw.w),  // TL: top, left
            max(bw.x, bw.y),  // TR: top, right
            max(bw.z, bw.y),  // BR: bottom, right
            max(bw.z, bw.w)   // BL: bottom, left
        ), float4(0.0));

        float inner_sdf = sdf_rounded_rect_4(in.local_pos - inner_offset, inner_half, inner_radii);
        float outer_mask = aa_step(0.0, sdf, aa_width);
        float inner_mask = aa_step(0.0, inner_sdf, aa_width);
        border_alpha = outer_mask - inner_mask;
    } else if (border_width > 0.0) {
        // Uniform border: 快速路径
        float inner_sdf = sdf + border_width;
        border_alpha = aa_step(0.0, sdf, aa_width) - aa_step(0.0, inner_sdf, aa_width);
    }

    float shadow_alpha = 0.0;
    if (shadow_blur > 0.0) {
        float2 shadow_pos = in.local_pos - shadow_offset;
        float shadow_sdf;
        // CSS spread：阴影形状按 spread 外扩 / 收缩（圆角同步），挖空仍按本体。
        const bool has_spread = (inst.packed_flags & (1u << 28u)) != 0u;
        const float spread = has_spread ? inst.noise_scale * s : 0.0;
        const float2 shadow_half = max(in.size + spread, float2(0.0));
        const float4 shadow_radii = max(corner_radii + spread, float4(0.0));

        switch (inst.shape_type) {
            case 0:
                shadow_sdf = sdf_rounded_rect_4(shadow_pos, shadow_half, shadow_radii);
                break;
            case 1:
                shadow_sdf = sdf_circle(shadow_pos, min(in.size.x, in.size.y));
                break;
            case 4:
                shadow_sdf = sdf_ellipse(shadow_pos, in.size);
                break;
            default:
                shadow_sdf = 1.0;
                break;
        }

        shadow_alpha = smoothstep(shadow_blur, -shadow_blur, shadow_sdf);
        shadow_alpha *= (1.0 - fill_alpha);
    }

    // ── 解包 packed_flags ──────────────────────────────────────────────────────
    uint gradient_dir  = inst.packed_flags & 0xFFu;
    uint noise_mode    = (inst.packed_flags >> 8u)  & 0xFFu;
    uint noise_seed    = (inst.packed_flags >> 16u) & 0xFFu;
    bool has_inset_shad = (inst.packed_flags & (1u << 24u)) != 0u;
    bool has_shadow2    = (inst.packed_flags & (1u << 25u)) != 0u;

    float4 result = float4(0.0);

    // 1. 外阴影
    if (shadow_alpha > 0.0) {
        float4 shadow = inst.shadow_color;
        shadow.a *= shadow_alpha;
        shadow.rgb *= shadow.a;
        composite_premul(result, shadow);
    }

    // 1b. 第二外阴影（has_shadow2）
    if (has_shadow2) {
        ShadowParam s2 = shadow_params[inst.shadow2_index];
        float2 sp2 = in.local_pos - float2(s2.offset_x, s2.offset_y) * s;
        float shadow_sdf2;
        switch (inst.shape_type) {
            case 0: shadow_sdf2 = sdf_rounded_rect_4(sp2, in.size, corner_radii); break;
            case 1: shadow_sdf2 = sdf_circle(sp2, min(in.size.x, in.size.y));     break;
            case 4: shadow_sdf2 = sdf_ellipse(sp2, in.size);                      break;
            default: shadow_sdf2 = 1.0; break;
        }
        float blur2 = s2.blur * s;
        float sa2 = smoothstep(blur2, -blur2, shadow_sdf2) * (1.0 - fill_alpha);
        float4 shd2 = s2.color;
        shd2.a *= sa2;
        shd2.rgb *= shd2.a;
        composite_premul(result, shd2);
    }

    // 2. 填充（渐变 + 噪声）
    if (fill_alpha > 0.0) {
        // ── 渐变 t 值计算 ─────────────────────────────────────────────────────
        float4 fill = inst.fill_color;
        if (gradient_dir > 0u) {
            float t = 0.0;

            if (gradient_dir == 4u) {
                // Radial 渐变：直接用原始 UV，不做 shadow expand
                // shadow_offset_x/y 复用为圆心偏移（UV 空间，默认 0,0 = 中心 0.5,0.5）
                float2 center_uv = float2(0.5 + inst.shadow_offset_x, 0.5 + inst.shadow_offset_y);
                // bit 29：自定义椭圆半径（UV 单位；CSS radial-gradient(rx ry at cx cy)）。
                if ((inst.packed_flags & (1u << 29u)) != 0u) {
                    float2 rr = max(float2(inst.noise_scale, inst.noise_intensity), float2(1e-4));
                    t = length((in.uv - center_uv) / rr);
                } else {
                    t = length(in.uv - center_uv) * 2.0;
                }
            } else if (gradient_dir == 5u) {
                // Conic 渐变：直接用原始 UV，不做 shadow expand
                // _ext_reserved 复用为起始角（bitcast float，弧度）
                float start_angle = as_type<float>(inst._ext_reserved);
                float angle = atan2(in.uv.y - 0.5, in.uv.x - 0.5) - start_angle;
                t = fract(angle / (2.0 * M_PI_F) + 0.5);
            } else {
                // 线性渐变（vert/horiz/diag）：保留原有 shadow expand 逻辑
                float expand = inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
                float2 orig_size = inst.rect.zw;
                float2 expanded_size = orig_size + expand * 2.0;
                float2 remap_uv = (in.uv * expanded_size - float2(expand)) / max(orig_size, float2(0.001));
                remap_uv = clamp(remap_uv, 0.0, 1.0);
                if      (gradient_dir == 1u) t = remap_uv.y;
                else if (gradient_dir == 2u) t = remap_uv.x;
                else                         t = (remap_uv.x + remap_uv.y) * 0.5;
            }
            // Extend Mode (packed_flags bit 26-27): 0=pad, 1=repeat, 2=reflect
            uint extend_mode = (inst.packed_flags >> 26u) & 0x3u;
            if (extend_mode == 1u) {
                t = fract(t);                               // REPEAT: 循环平铺
            } else if (extend_mode == 2u) {
                float t2 = fmod(abs(t), 2.0);
                t = (t2 > 1.0) ? (2.0 - t2) : t2;         // REFLECT: 镜像反射
            } else {
                t = clamp(t, 0.0, 1.0);                    // PAD（默认）：夹制到边界颜色
            }

            // 多色渐变（stop_count > 0）或旧两色模式
            if (inst.gradient_stop_count > 0u) {
                fill = eval_gradient_stops(t, grad_stops, inst.gradient_stop_offset, inst.gradient_stop_count);
            } else {
                // 旧两色模式也在 premul 空间插值
                float4 from_p = premul(inst.fill_color);
                float4 to_p   = premul(inst.gradient_to_color);
                fill = unpremul(mix(from_p, to_p, t));
            }

            // Bayer 有序抖动：消除 8bit framebuffer 的色阶 banding
            // 仅对 RGB 通道施加次像素偏移，alpha 不动
            float dither = bayer_dither(in.screen_pos);
            fill.rgb = saturate(fill.rgb + dither);
        }

        // ── 程序性噪声叠加 ───────────────────────────────────────────────────
        if (noise_mode > 0u && inst.noise_scale > 0.0) {
            float n = 0.0;
            float ns = inst.noise_scale * s; // 转物理像素
            if (noise_mode == 1u) {
                // Value Noise（基于逻辑坐标，随缩放自适应）
                n = value_noise(in.local_pos / s, ns / s, noise_seed) - 0.5;
            } else if (noise_mode == 2u) {
                // Film Grain（基于物理像素坐标，与 DPI 无关）
                // 用 frame_seed XOR instance seed，每帧产生不同噪声图案
                n = film_grain(in.screen_pos, noise_seed ^ (uniforms.frame_seed & 0xFFu));
            }
            float ni = inst.noise_intensity;
            fill = clamp(fill + float4(n * ni, n * ni, n * ni, 0.0), float4(0.0), float4(1.0));
        }

        fill.a *= fill_alpha;
        fill.rgb *= fill.a;
        composite_premul(result, fill);
    }

    // 2b. Inset Shadow（在填充之上）
    if (has_inset_shad && fill_alpha > 0.0) {
        // CSS inset 语义：阴影形状 = 本体按 offset 平移；内阴影落在「本体内、形状外」。
        // offset_y > 0 → 形状下移 → 顶边露出一条（inset 0 1px 0 白 = 顶部高光）。
        float2 inset_pos = in.local_pos - shadow_offset;
        float inset_sdf;
        switch (inst.shape_type) {
            case 0: inset_sdf = sdf_rounded_rect_4(inset_pos, in.size, corner_radii); break;
            case 1: inset_sdf = sdf_circle(inset_pos, min(in.size.x, in.size.y));     break;
            case 4: inset_sdf = sdf_ellipse(inset_pos, in.size);                  break;
            default: inset_sdf = -1.0; break;
        }
        // 内阴影仅在形状内部（fill_alpha > 0），沿内边界衰减。
        // blur 为 0 是 CSS 常见的 1px 硬高光（inset 0 1px 0 …）：smoothstep 的两端
        // 相等时未定义，给一个像素宽的抗锯齿带兜底。
        float inset_soft = max(shadow_blur, 1.0);
        // 平移后形状的外侧（sdf ≥ 0）满强度，向内 blur 宽度内渐隐到 0；形状内部深处不画。
        // （曾写成 1 − smoothstep，整块本体被内阴影色填满——白玻璃卡片因此变成实心白。）
        float inset_a = fill_alpha * smoothstep(-inset_soft, 0.0, inset_sdf);
        float4 inset_c = inst.shadow_color;
        inset_c.a *= inset_a;
        inset_c.rgb *= inset_c.a;
        composite_premul(result, inset_c);
    }

    // 3. 边框
    if (border_alpha > 0.0) {
        float4 border = inst.border_color;
        border.a *= border_alpha;
        border.rgb *= border.a;
        composite_premul(result, border);
    }

    result *= clip_alpha(in.screen_pos, in.rect_clip, uniforms);
    if (result.a < 0.001) {
        discard_fragment();
    }

    return result;
}
