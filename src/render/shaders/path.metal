/// Path Fill Shader (with edge anti-aliasing)
///
/// Vertex format: (position.xy, alpha_scale)
///   - fill triangles: alpha_scale = 1.0
///   - AA fringe triangles: inner verts alpha_scale = 1.0, outer verts alpha_scale = 0.0
///
/// Edges are softened (~0.5-1.0 px wide) by a fringe strip along the polygon boundary. Vertices are
/// read directly via buffer(0) (consistent with SDF/Image renderer, no VertexDescriptor needed).

#include <metal_stdlib>
using namespace metal;

struct PathUniforms {
    float2 viewport_size; // logical pixel viewport size
    float  scale_factor; // Retina scale (1.0 or 2.0)
    uint   draw_mode;       // 0 = triangles, 1 = polygon fill
    float4 color; // draw color (passed via uniforms)
    float4 rect; // bbox x,y,w,h (logical pixels)
    uint   fill_rule;       // 0 = evenodd, 1 = nonzero
    uint   point_count;
    uint   contour_count;
    uint   _pad0;
    uint   contour_end_points[8];
    float2 polygon_points[32];
    // shape clip mask (align with sdf/text/image/icon pipeline; path only supports kind 0=none /
    // 1=rounded_rect / 2=ellipse, polygon clip not effective for path)
    float4 clip_rect; // logical pixels x,y,w,h
    float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint   clip_shape_kind;
    uint   _pad1;
    uint   _pad2;
    uint   _pad6;
    // draw_mode 2: radial/conic gradient per fragment over `rect`.
    uint   grad_dir;
    uint   grad_stop_count;
    float2 grad_center;
    float  grad_angle;
    uint   _pad3;
    uint   _pad4;
    uint   _pad5;
    float4 grad_colors[16];
    float  grad_positions[16];
    // Second shape clip (shape_clip_pair.zig): kind 0 none, 1 rounded rect, 2 ellipse;
    // logical px like clip_rect. Coverage multiplies the primary shape clip's.
    float4 clip2_rect;
    float4 clip2_radii; // TL, TR, BR, BL
    uint clip2_shape_kind;
};

/// Same t as FillGradient.tAt (4 = radial, 5 = conic) on bounds-normalized uv.
float path_gradient_t(float2 uv, constant PathUniforms& u) {
    const float2 d = uv - u.grad_center;
    if (u.grad_dir == 4u) return clamp(length(d) * 2.0, 0.0, 1.0);
    const float tau = 6.28318530718;
    float ang = atan2(d.y, d.x) - u.grad_angle;
    ang = ang - tau * floor(ang / tau);
    return ang / tau;
}

/// Same stop interpolation as FillGradient.colorAt (pad).
float4 path_gradient_color(float t_in, constant PathUniforms& u) {
    const uint n = min(u.grad_stop_count, 16u);
    if (n == 0u) return float4(0.0);
    if (n == 1u) return u.grad_colors[0];
    const float t = clamp(t_in, 0.0, 1.0);
    if (t <= u.grad_positions[0]) return u.grad_colors[0];
    float4 result = u.grad_colors[n - 1u];
    bool found = false;
    for (uint i = 1u; i < n; i++) {
        if (!found && t <= u.grad_positions[i]) {
            const float span = u.grad_positions[i] - u.grad_positions[i - 1u];
            const float k = span > 1e-6 ? (t - u.grad_positions[i - 1u]) / span : 0.0;
            result = mix(u.grad_colors[i - 1u], u.grad_colors[i], k);
            found = true;
        }
    }
    return result;
}

struct PathVertexIn {
    float x;
    float y;
    float alpha_scale;
    // linear RGB + alpha (unpremultiplied). packed_float4 maintains 4-byte alignment, consistent
    // with CPU side 28-byte extern struct layout (float4 aligned to 16).
    packed_float4 color;
};

struct PathVertexOut {
    float4 position [[position]];
    float4 fill_color;
    float2 local_pos;
};

/// convert logical pixel coords to NDC (clip space)
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
    // color per-vertex (CPU side already sRGB->linear), enables draw call batching; polygon_fill
    // branch fragment still reads u.color. alpha_scale for AA fringe.
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

/// Overflow clip with per-corner radii (TL, TR, BR, BL): the quadrant picks the corner, so a
/// uniform radius evaluates exactly as the single-radius distance.
float sdf_rounded_rect_corners_path(float2 p, float2 size, float4 radii) {
    const float r = (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
    return sdf_rounded_rect_path(p, size, r);
}

float sdf_ellipse_path(float2 p, float2 half_size) {
    const float2 safe = max(half_size, float2(0.0001));
    const float2 n = p / safe;
    const float d = length(n) - 1.0;
    return d * min(safe.x, safe.y);
}

/// screen_pos is device px (fragment [[position]]); clip_rect logical pixels.
float primary_shape_clip_alpha_path(float2 screen_pos, constant PathUniforms& u) {
    if (u.clip_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (u.clip_rect.xy + u.clip_rect.zw * 0.5) * u.scale_factor;
    const float2 clip_size = u.clip_rect.zw * u.scale_factor * 0.5;
    float clip_sdf = -1.0;
    if (u.clip_shape_kind == 1u) {
        clip_sdf = sdf_rounded_rect_corners_path(screen_pos - clip_center, clip_size, u.clip_radii * u.scale_factor);
    } else if (u.clip_shape_kind == 2u) {
        clip_sdf = sdf_ellipse_path(screen_pos - clip_center, clip_size);
    }
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float partner_shape_clip_alpha_path(float2 screen_pos, constant PathUniforms& u) {
    if (u.clip2_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (u.clip2_rect.xy + u.clip2_rect.zw * 0.5) * u.scale_factor;
    const float2 clip_size = u.clip2_rect.zw * u.scale_factor * 0.5;
    const float clip_sdf = u.clip2_shape_kind == 2u
        ? sdf_ellipse_path(screen_pos - clip_center, clip_size)
        : sdf_rounded_rect_corners_path(screen_pos - clip_center, clip_size, u.clip2_radii * u.scale_factor);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_path(float2 screen_pos, constant PathUniforms& u) {
    return primary_shape_clip_alpha_path(screen_pos, u) * partner_shape_clip_alpha_path(screen_pos, u);
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
    if (u.draw_mode == 2u) {
        const float4 g = path_gradient_color(path_gradient_t(in.local_pos / max(u.rect.zw, float2(1e-6)), u), u);
        const float a = g.a * in.fill_color.a * clip_alpha;
        return float4(g.rgb * a, a);
    }
    return in.fill_color * clip_alpha;
}
