// Windows counterpart of src/render/shaders/path.metal.
// zenit-entry: vertex path_vertex_main
// zenit-entry: fragment path_fragment_main
struct PathUniforms {
    float2 viewport_size; float scale_factor; uint draw_mode;
    float4 color; float4 rect;
    uint fill_rule; uint point_count; uint contour_count; uint pad0;
    // Packed vectors preserve the Metal/CPU contiguous array ABI in a cbuffer.
    uint4 contour_end_points[2];
    float4 polygon_points[16];
    float4 clip_rect; float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint clip_shape_kind; uint pad1; uint pad2; uint pad6;
    // draw_mode 2: radial/conic gradient per fragment over `rect`.
    uint grad_dir; uint grad_stop_count; float2 grad_center;
    float grad_angle; uint pad3; uint pad4; uint pad5;
    float4 grad_colors[16];
    float4 grad_positions[4];
};
cbuffer PathParams : register(b1, space0) { PathUniforms u; };
cbuffer ZenitDrawInfo : register(b0, space4) { uint first_vertex; uint first_instance; uint2 reserved; };
struct PathVertexIn { float x; float y; float alpha_scale; float4 color; };
StructuredBuffer<PathVertexIn> vertices : register(t0, space0);
struct PathVertexOut { float4 position : SV_Position; float4 fill_color : TEXCOORD0; float2 local_pos : TEXCOORD1; };
uint get_contour_end(PathUniforms data, uint i) { return data.contour_end_points[i / 4][i % 4]; }
float grad_position(uint i) { return u.grad_positions[i / 4][i % 4]; }
// Same t as FillGradient.tAt (4 = radial, 5 = conic) on bounds-normalized uv.
float path_gradient_t(float2 uv) {
    const float2 d = uv - u.grad_center;
    if (u.grad_dir == 4u) return clamp(length(d) * 2.0, 0.0, 1.0);
    const float tau = 6.28318530718;
    float ang = atan2(d.y, d.x) - u.grad_angle;
    ang = ang - tau * floor(ang / tau);
    return ang / tau;
}
// Same stop interpolation as FillGradient.colorAt (pad); no return inside the
// loop (the Windows 10 WARP JIT mis-executes that form).
float4 path_gradient_color(float t_in) {
    const uint n = min(u.grad_stop_count, 16u);
    if (n == 0u) return float4(0.0, 0.0, 0.0, 0.0);
    if (n == 1u) return u.grad_colors[0];
    const float t = clamp(t_in, 0.0, 1.0);
    if (t <= grad_position(0)) return u.grad_colors[0];
    float4 result = u.grad_colors[n - 1u];
    bool found = false;
    for (uint i = 1u; i < n; i++) {
        if (!found && t <= grad_position(i)) {
            const float span = grad_position(i) - grad_position(i - 1u);
            const float k = span > 1e-6 ? (t - grad_position(i - 1u)) / span : 0.0;
            result = lerp(u.grad_colors[i - 1u], u.grad_colors[i], k);
            found = true;
        }
    }
    return result;
}
float2 polygon_point(PathUniforms data, uint i) { float4 pair = data.polygon_points[i / 2]; return (i % 2 == 0) ? pair.xy : pair.zw; }
PathVertexOut path_vertex_main(uint id : SV_VertexID) {
    PathVertexIn v = vertices[id + first_vertex];
    PathVertexOut result;
    result.position = float4(v.x / u.viewport_size.x * 2.0 - 1.0, 1.0 - v.y / u.viewport_size.y * 2.0, 0, 1);
    result.local_pos = float2(v.x - u.rect.x, v.y - u.rect.y);
    float alpha = v.color.a * v.alpha_scale;
    result.fill_color = float4(v.color.rgb * alpha, alpha);
    return result;
}
bool polygon_contains_path(float2 p, PathUniforms uniforms) {
    if (uniforms.fill_rule == 0u) {
        bool inside = false;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < uniforms.contour_count; contour++) {
            const uint contour_end = min(get_contour_end(uniforms, contour), uniforms.point_count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = polygon_point(uniforms, i);
                const float2 b = polygon_point(uniforms, next);
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
        const uint contour_end = min(get_contour_end(uniforms, contour), uniforms.point_count);
        if (contour_end <= contour_start + 1u) {
            contour_start = contour_end;
            continue;
        }
        for (uint i = contour_start; i < contour_end; i++) {
            const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
            const float2 a = polygon_point(uniforms, i);
            const float2 b = polygon_point(uniforms, next);
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
    const float2 safe = max(half_size, float2(0.0001,0.0001));
    const float2 n = p / safe;
    const float d = length(n) - 1.0;
    return d * min(safe.x, safe.y);
}

/// screen_pos is device px (fragment [[position]]); clip_rect is logical pixels.
float shape_clip_alpha_path(float2 screen_pos, PathUniforms u) {
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
    const float clip_aa = max((abs(ddx_fine(clip_sdf)) + abs(ddy_fine(clip_sdf))) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float4 path_fragment_main(PathVertexOut input) : SV_Target
{
    const float clip_alpha = shape_clip_alpha_path(input.position.xy, u);
    if (u.draw_mode == 1u) {
        const uint count = min(u.point_count, 32u);
        const uint contour_count = min(u.contour_count, 8u);
        if (count < 3u || contour_count == 0u) {
            return float4(0,0,0,0);
        }

        const float2 polygon_pos = input.local_pos;
        const bool inside = polygon_contains_path(polygon_pos, u);
        float min_dist = asfloat(0x7f800000u);
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(get_contour_end(u, contour), count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = polygon_point(u, i);
                const float2 b = polygon_point(u, next);
                min_dist = min(min_dist, point_segment_distance_path(polygon_pos, a, b));
            }
            contour_start = contour_end;
        }

        const float aa = max(length(float2(ddx_fine(input.local_pos.x), ddy_fine(input.local_pos.y))) * 0.5, 0.75 / max(u.scale_factor, 1.0));
        const float signed_dist = inside ? -min_dist : min_dist;
        const float alpha = smoothstep(aa, -aa, signed_dist) * u.color.a * clip_alpha;
        return float4(u.color.rgb * alpha, alpha);
    }
    if (u.draw_mode == 2u) {
        const float4 g = path_gradient_color(path_gradient_t(input.local_pos / max(u.rect.zw, float2(1e-6, 1e-6))));
        const float a = g.a * input.fill_color.a * clip_alpha;
        return float4(g.rgb * a, a);
    }
    return input.fill_color * clip_alpha;
}
