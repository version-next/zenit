/// Image Shader.
/// Metal Shading Language implementation of image rendering.
/// Supports: texture sampling, SDF rounded corner clipping, alpha blending.
/// Each instance corresponds to one textured rectangle.

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Uniforms and vertex data structures
// ============================================================================

/// Global uniforms.
struct Uniforms {
    float2 viewport_size; // Viewport size (physical pixels).
    float scale_factor; // DPI scale factor (Retina=2.0).
    uint clip_shape_kind;
    float4 clip_rect;
    float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_pad; // keeps the polygon arrays 16-byte aligned (cbuffer register)
    uint clip_polygon_end_points[8];
    float2 clip_polygon_points[32];
    // Second shape clip (shape_clip_pair.zig): kind 0 none, 1 rounded rect, 2 ellipse;
    // logical px like clip_rect. Coverage multiplies the primary shape clip's.
    float4 clip2_rect;
    float4 clip2_radii; // TL, TR, BR, BL
    uint clip2_shape_kind;
};

/// Per-instance data (one per image) - 128 bytes.
struct ImageInstanceData {
    float4 rect; // x, y, width, height (logical pixels).
    float4 uv_rect; // u0, v0, u1, v1 (texture coordinate range).
    float4 tint_color; // Tint color RGBA (1,1,1,1 = no tint).
    float4 transform_linear; // a, b, c, d (logical pixel affine).
    float4 corner_radii; // Corner radii TL, TR, BR, BL (logical pixels; a rounded layer's mask).
    float2 transform_translation; // tx, ty (logical pixel affine).
    float opacity; // Opacity (0-1).
    float source_premultiplied; // Whether source is premultiplied alpha texture (offscreen layer composite).
    float sampling_max_u;
    float sampling_max_v;
    float sampling_padding0;
    float sampling_padding1;
    float4 rect_clip; // x, y, w, h (logical pixels); zero-size = disabled.
};

/// Vertex output.
struct ImageVertexOutput {
    float4 position [[position]];
    float2 uv; // Texture coordinate.
    float2 local_pos; // Position relative to primitive center.
    float2 size; // Half of primitive size.
    float2 screen_pos; // Current fragment physical pixel coordinate.
    float4 rect_clip;
    uint instance_id;
};

// ============================================================================
// SDF functions (for rounded corner clipping)
// ============================================================================

float sdf_rounded_rect_image(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

/// Overflow clip with per-corner radii (TL, TR, BR, BL): the quadrant picks the corner, so a
/// uniform radius evaluates exactly as the single-radius distance.
float sdf_rounded_rect_corners_image(float2 p, float2 size, float4 radii) {
    const float r = (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
    return sdf_rounded_rect_image(p, size, r);
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

float primary_shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float4 clip_radii = uniforms.clip_radii * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_corners_image(screen_pos - clip_center, clip_size, clip_radii);
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

float partner_shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip2_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (uniforms.clip2_rect.xy + uniforms.clip2_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip2_rect.zw * uniforms.scale_factor * 0.5;
    const float clip_sdf = uniforms.clip2_shape_kind == 2u
        ? sdf_ellipse_image(screen_pos - clip_center, clip_size)
        : sdf_rounded_rect_corners_image(screen_pos - clip_center, clip_size, uniforms.clip2_radii * uniforms.scale_factor);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    return primary_shape_clip_alpha(screen_pos, uniforms) * partner_shape_clip_alpha(screen_pos, uniforms);
}

float clip_alpha(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha(screen_pos, uniforms);
}

// ============================================================================
// Vertex shader
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

    // Texture coordinate interpolation.
    out.uv = mix(inst.uv_rect.xy, inst.uv_rect.zw, corner);

    // Local coords for SDF clipping stay in untransformed space; corners follow content geometry,
    // not screen AABB.
    out.local_pos = (local_pos - center_local) * s;
    out.size = inst.rect.zw * s * 0.5;
    out.screen_pos = pixel_pos;
    out.rect_clip = inst.rect_clip;

    out.instance_id = instance_id;

    return out;
}

// ============================================================================
// Fragment shader
// ============================================================================

fragment float4 image_fragment_main(
    ImageVertexOutput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant ImageInstanceData* instances [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    ImageInstanceData inst = instances[in.instance_id];
    const float4 corner_radii = inst.corner_radii * uniforms.scale_factor;

    // Sample texture.
    float2 uv = in.uv;
    if (inst.sampling_max_u > 0.0 && inst.sampling_max_v > 0.0)
        uv = min(uv, float2(inst.sampling_max_u, inst.sampling_max_v));
    float4 color = tex.sample(smp, uv);

    // Apply tint.
    color *= inst.tint_color;

    float coverage = 1.0;

    // Rounded corner clipping.
    if (any(corner_radii > 0.0)) {
        float sdf = sdf_rounded_rect_corners_image(in.local_pos, in.size, corner_radii);
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
