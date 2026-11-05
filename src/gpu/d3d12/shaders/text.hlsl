// Windows counterpart of src/render/shaders/text.metal.
// zenit-entry: vertex text_vertex_main
// zenit-entry: fragment text_fragment_main
#define ZENIT_DWRITE_GAMMA uniforms.dwrite_gamma
#define ZENIT_DWRITE_CONTRAST uniforms.dwrite_settings.x
#define ZENIT_DWRITE_CT_CONTRAST uniforms.dwrite_settings.y
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
    uint4 clip_polygon_end_points[2];
    float4 clip_polygon_points[16];
    float4 dwrite_gamma;
    float4 dwrite_settings;
};
struct GlyphInstance {
    float2 position; // glyph lower-left position (pixels)
    float2 size; // glyph size (pixels)
    float4 uv_rect; // UV rect (u_min, v_min, u_max, v_max)
    float4 color; // glyph color RGBA
    float4 rect_clip; // x, y, w, h (logical pixels); 0-size = disabled
    float skew_x; // synthetic italic x offset (logical pixels)
    float page_index; // atlas page index (CPU bucketing, shader doesn't read)
    float is_color; // >0.5 = glyph on BGRA color page (emoji), sample is final color
    float shader_snap; // >0.5 = position snaps to physical pixels; animated text set 0 (continuous coords)
};
cbuffer Params : register(b0,space0) { Uniforms uniforms; };
cbuffer ZenitDrawInfo : register(b0,space4) { uint first_vertex; uint first_instance; uint2 reserved; };
StructuredBuffer<GlyphInstance> instances : register(t1,space0);
Texture2D<float4> glyph_atlas : register(t0,space1);
Texture2D<float4> glyph_atlas_color : register(t1,space1);
SamplerState atlas_sampler : register(s0,space2);
struct VertexOutput { float4 position : SV_Position; float2 uv : TEXCOORD0; float2 screen_pos : TEXCOORD1; float4 rect_clip : TEXCOORD2; nointerpolation uint instance_id : TEXCOORD3; };
uint get_clip_end(Uniforms data, uint i) { return data.clip_polygon_end_points[i / 4][i % 4]; }
float2 get_clip_point(Uniforms data, uint i) { float4 pair = data.clip_polygon_points[i / 2]; return i % 2 == 0 ? pair.xy : pair.zw; }
float sdf_rounded_rect_text(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0,0))) - radius;
}

/// Overflow clip with per-corner radii (TL, TR, BR, BL): the quadrant picks the corner, so a
/// uniform radius evaluates exactly as the single-radius distance.
float sdf_rounded_rect_corners_text(float2 p, float2 size, float4 radii) {
    const float r = (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
    return sdf_rounded_rect_text(p, size, r);
}

float sdf_ellipse_text(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001,0.001));
    return length(q) - 1.0;
}

float point_segment_distance_text(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

bool polygon_contains_text(float2 p, Uniforms uniforms, uint count, uint contour_count) {
    if (uniforms.clip_fill_rule == 0u) {
        bool inside = false;
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(get_clip_end(uniforms, contour), count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = get_clip_point(uniforms, i) * uniforms.scale_factor;
                const float2 b = get_clip_point(uniforms, next) * uniforms.scale_factor;
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
        const uint contour_end = min(get_clip_end(uniforms, contour), count);
        if (contour_end <= contour_start + 1u) {
            contour_start = contour_end;
            continue;
        }
        for (uint i = contour_start; i < contour_end; i++) {
            const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
            const float2 a = get_clip_point(uniforms, i) * uniforms.scale_factor;
            const float2 b = get_clip_point(uniforms, next) * uniforms.scale_factor;
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
    const float clip_aa = max((abs(ddx_fine(clip_sdf)) + abs(ddy_fine(clip_sdf))) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_text(float2 screen_pos, Uniforms uniforms) {
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
        float min_dist = asfloat(0x7f800000u);
        uint contour_start = 0u;
        for (uint contour = 0u; contour < contour_count; contour++) {
            const uint contour_end = min(get_clip_end(uniforms, contour), count);
            if (contour_end <= contour_start + 1u) {
                contour_start = contour_end;
                continue;
            }
            for (uint i = contour_start; i < contour_end; i++) {
                const uint next = (i + 1u < contour_end) ? (i + 1u) : contour_start;
                const float2 a = get_clip_point(uniforms, i) * uniforms.scale_factor;
                const float2 b = get_clip_point(uniforms, next) * uniforms.scale_factor;
                min_dist = min(min_dist, point_segment_distance_text(polygon_pos, a, b));
            }
            contour_start = contour_end;
        }
        const float clip_aa = max(length(float2(ddx_fine(screen_pos.x), ddy_fine(screen_pos.y))) * 0.5, 0.75);
        const float signed_dist = inside ? -min_dist : min_dist;
        return smoothstep(clip_aa, -clip_aa, signed_dist);
    }
    const float clip_aa = max((abs(ddx_fine(clip_sdf)) + abs(ddy_fine(clip_sdf))) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float clip_alpha_text(float2 screen_pos, float4 rect_clip, Uniforms uniforms) {
    return rect_clip_alpha_text(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha_text(screen_pos, uniforms);
}

// ============================================================================
// Vertex shader
// ============================================================================

VertexOutput text_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VertexOutput output;

    GlyphInstance inst = instances[instance_id + first_instance];

    // quad vertex positions (relative to glyph lower-left)
    // vertex order: 0=lower-left, 1=lower-right, 2=upper-left, 3=upper-right
    // triangles: 0-1-2, 1-3-2
    float2 corners[4] = {
        float2(0.0, 0.0), // lower-left
        float2(1.0, 0.0), // lower-right
        float2(0.0, 1.0), // upper-left
        float2(1.0, 1.0) // upper-right
    };

    uint indices[6] = {0, 1, 2, 1, 3, 2};
    uint corner_index = indices[vertex_id + first_vertex];
    float2 corner = corners[corner_index];

    // compute pixel position (logical pixels -> physical pixels). shader_snap>0.5 snaps to physical
    // pixels (static/in-surface text; CPU already snaps by same rule, idempotent here). animated
    // text (direct_animated) pass 0: keep continuous float coords, per-glyph rounding crosses
    // rounding threshold in different frames, producing kerning/baseline jitter.
    float s = uniforms.scale_factor;
    float2 scaled_pos = inst.position * s;
    float2 base_pos = (inst.shader_snap > 0.5) ? round(scaled_pos) : scaled_pos;
    float2 pixel_pos = base_pos + corner * inst.size * s;

    // synthetic italic: offset right at top, bottom fixed. screen coords Y down: corner.y=0 is top,
    // corner.y=1 is bottom
    pixel_pos.x += (1.0 - corner.y) * inst.skew_x * s;

    // transform to NDC (-1 to 1)
    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Metal Y axis down

    output.position = float4(ndc, 0.0, 1.0);

    // compute UV
    output.uv = lerp(inst.uv_rect.xy, inst.uv_rect.zw, corner);
    output.screen_pos = pixel_pos;
    output.rect_clip = inst.rect_clip;

    output.instance_id = instance_id + first_instance;

    return output;
}

// ============================================================================
// Fragment shader
// ============================================================================

#ifdef ZENIT_DWRITE_GAMMA
// Microsoft Windows Terminal's DirectWrite alpha correction (MIT license).
// Copyright (c) Microsoft Corporation. See native/windows/dwrite_alpha_correction.LICENSE.
float dwrite_grayscale_alpha(float alpha, float3 foreground) {
    float lightness = dot(foreground, float3(0.30, 0.59, 0.11));
    float contrast = ZENIT_DWRITE_CONTRAST * saturate(3.0 - 4.0 * lightness);
    float a = alpha * (1.0 + contrast) / (1.0 + alpha * contrast);
    float intensity = dot(foreground, float3(0.25, 0.5, 0.25));
    float4 g = ZENIT_DWRITE_GAMMA;
    return saturate(a + a * (1.0 - a) * ((g.x * intensity + g.y) * a + g.z * intensity + g.w));
}
#endif

#ifdef ZENIT_DWRITE_GAMMA
struct TextOutput { float4 color : SV_Target0; float4 weights : SV_Target1; };
TextOutput text_fragment_main(VertexOutput input) {
#else
float4 text_fragment_main(VertexOutput input) : SV_Target {
#endif
    const GlyphInstance inst = instances[input.instance_id];
    const float clip_a = clip_alpha_text(input.screen_pos, input.rect_clip, uniforms);

    float4 result;
    if (inst.is_color > 0.5 && inst.is_color < 1.5) {
        // color glyphs (emoji): BGRA page already holds premultiplied final color. **cannot
        // multiply by inst.color** -- emoji has own color, multiply by text color re-tints to
        // single color, wasted work. here only layer clip alpha and overall opacity.
        const float4 texel = glyph_atlas_color.Sample(atlas_sampler, input.uv);
        const float a = clip_a * inst.color.a;
        result = texel * a; // texel premultiplied, overall scale maintains premultiplied invariant
        if (result.a < 0.001) {
            discard;
        }
#ifdef ZENIT_DWRITE_GAMMA
        TextOutput output; output.color = result; output.weights = result.aaaa; return output;
#else
        return result;
#endif
    }

#ifdef ZENIT_DWRITE_GAMMA
    if (inst.is_color > 1.5) {
        float3 mask = glyph_atlas.Sample(atlas_sampler, input.uv).rgb;
        // D2D has already applied the monitor's pixel geometry and ClearType level.
        float lightness = dot(inst.color.rgb, float3(0.30, 0.59, 0.11));
        float contrast = ZENIT_DWRITE_CT_CONTRAST * saturate(3.0 - 4.0 * lightness);
        float3 a = mask * (1.0 + contrast) / (1.0 + mask * contrast);
        float4 g = ZENIT_DWRITE_GAMMA;
        a = saturate(a + a * (1.0 - a) * ((g.x * inst.color.rgb + g.y) * a + g.z * inst.color.rgb + g.w));
        a *= clip_a * inst.color.a;
        float coverage = max(a.r, max(a.g, a.b));
        TextOutput output; output.weights = float4(a, coverage); output.color = float4(inst.color.rgb * a, coverage); return output;
    }
#endif
    // grayscale glyph: single channel as coverage, multiply by text color (original logic,
    // unchanged)
    float alpha = glyph_atlas.Sample(atlas_sampler, input.uv).r;
#ifdef ZENIT_DWRITE_GAMMA
    alpha = dwrite_grayscale_alpha(alpha, inst.color.rgb);
#endif

    result = inst.color;
    result.a *= alpha * clip_a;

    // discard fully transparent pixels
    if (result.a < 0.001) {
        discard;
    }

    // output premultiplied alpha, match premultiplied blend state
    result.rgb *= result.a;
#ifdef ZENIT_DWRITE_GAMMA
    TextOutput output; output.color = result; output.weights = result.aaaa; return output;
#else
    return result;
#endif
}
