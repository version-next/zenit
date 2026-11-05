/// Text Shader - Metal Shading Language
///
/// GPU-instanced text rendering, each glyph renders as one instance

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Data structures
// ============================================================================

/// global uniforms
struct Uniforms {
    float2 viewport_size; // viewport size (pixels)
    float scale_factor; // DPI scale factor
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

/// glyph instance data
struct GlyphInstance {
    packed_float2 position; // glyph bottom-left position (pixels)
    packed_float2 size; // glyph size (pixels)
    // UV compression: fixed 4096 normalized-UV grid, decoded with 1/4096.
    // 2048 physical pages use even grid coordinates; wire layout is unchanged.
    packed_ushort4 uv_rect; // grid coords (u_min, v_min, u_max, v_max); UV = grid / 4096
    packed_float4 color; // glyph color RGBA
    packed_float4 rect_clip; // x, y, w, h (logical pixels); 0-size = disabled
    float skew_x; // synthetic italic x offset (logical pixels)
    // Exact metadata: page[0..7], color mode[8..9], pixel snap[10].
    uint metadata;
};
static_assert(sizeof(GlyphInstance) == 64, "Metal glyph wire stride must match Zig (UV compressed to packed_ushort4)");

/// vertex output
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

/// Overflow clip with per-corner radii (TL, TR, BR, BL): the quadrant picks the corner, so a
/// uniform radius evaluates exactly as the single-radius distance.
float sdf_rounded_rect_corners_text(float2 p, float2 size, float4 radii) {
    const float r = (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
    return sdf_rounded_rect_text(p, size, r);
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

float primary_shape_clip_alpha_text(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float4 clip_radii = uniforms.clip_radii * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_corners_text(screen_pos - clip_center, clip_size, clip_radii);
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

float partner_shape_clip_alpha_text(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip2_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (uniforms.clip2_rect.xy + uniforms.clip2_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip2_rect.zw * uniforms.scale_factor * 0.5;
    const float clip_sdf = uniforms.clip2_shape_kind == 2u
        ? sdf_ellipse_text(screen_pos - clip_center, clip_size)
        : sdf_rounded_rect_corners_text(screen_pos - clip_center, clip_size, uniforms.clip2_radii * uniforms.scale_factor);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_text(float2 screen_pos, constant Uniforms& uniforms) {
    return primary_shape_clip_alpha_text(screen_pos, uniforms) * partner_shape_clip_alpha_text(screen_pos, uniforms);
}

float clip_alpha_text(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha_text(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha_text(screen_pos, uniforms);
}

// ============================================================================
// Vertex shader
// ============================================================================

vertex VertexOutput text_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant GlyphInstance* instances [[buffer(1)]]
) {
    VertexOutput out;

    GlyphInstance inst = instances[instance_id];

    // quad vertex positions (relative to glyph bottom-left)
    // vertex order: 0=bottom-left, 1=bottom-right, 2=top-left, 3=top-right
    // triangles: 0-1-2, 1-3-2
    float2 corners[4] = {
        float2(0.0, 0.0), // bottom-left
        float2(1.0, 0.0), // bottom-right
        float2(0.0, 1.0), // top-left
        float2(1.0, 1.0) // top-right
    };

    float2 corner = corners[vertex_id];

    // compute pixel position (logical -> physical pixel)
    // metadata bit 10 snaps to physical pixel (static/in-surface text; CPU already snapped per same
    // rule, idempotent here). animated text (direct_animated) set 0: keep continuous float coords,
    // per-glyph rounding lets adjacent glyphs cross rounding threshold on different frames,
    // producing kerning/baseline jitter.
    float s = uniforms.scale_factor;
    float2 scaled_pos = inst.position * s;
    float2 base_pos = ((inst.metadata & (1u << 10)) != 0) ? round(scaled_pos) : scaled_pos;
    float2 pixel_pos = base_pos + corner * inst.size * s;

    // synthetic italic: top offset right, bottom fixed
    // screen coords Y-down: corner.y=0 is top, corner.y=1 is bottom
    pixel_pos.x += (1.0 - corner.y) * inst.skew_x * s;

    // convert to NDC (-1 to 1)
    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Metal Y-axis down

    out.position = float4(ndc, 0.0, 1.0);

    // compute UV
    // Decode fixed-grid UV, not physical page texels; exact for2048 and4096 pages.
    constexpr float kAtlasSizeInv = 1.0f / 4096.0f;
    const float4 uv_rect = float4(inst.uv_rect) * kAtlasSizeInv;
    out.uv = mix(uv_rect.xy, uv_rect.zw, corner);
    out.screen_pos = pixel_pos;
    out.rect_clip = inst.rect_clip;

    out.instance_id = instance_id;

    return out;
}

// ============================================================================
// Fragment shader
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
    if (((inst.metadata >> 8) & 3u) != 0) {
        // color glyphs (emoji): BGRA page already stores premultiplied final color. **must not**
        // multiply by inst.color -- emoji has its own color, multiplying by text color would
        // recolor to monochrome, wasted. here only apply clip alpha and overall opacity.
        const float4 texel = glyph_atlas_color.sample(atlas_sampler, in.uv);
        const float a = clip_a * inst.color.a;
        result = texel * a; // texel premultiplied, scale globally preserves premultiplied invariant
        if (result.a < 0.001) {
            discard_fragment();
        }
        return result;
    }

    // grayscale glyphs: single channel as coverage, multiply by text color (original logic,
    // unchanged)
    float alpha = glyph_atlas.sample(atlas_sampler, in.uv).r;

    result = inst.color;
    result.a *= alpha * clip_a;

    // discard fully transparent pixels
    if (result.a < 0.001) {
        discard_fragment();
    }

    // output premultiplied alpha, matches premultiplied blend state
    result.rgb *= result.a;
    return result;
}
