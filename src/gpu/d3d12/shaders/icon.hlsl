// Windows counterpart of src/render/shaders/icon.metal.
// zenit-entry: vertex icon_vertex_main
// zenit-entry: fragment icon_fragment_main
struct Uniforms {
    float2 viewport_size;
    float scale_factor;
    uint clip_shape_kind;
    float4 clip_rect;
    float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_pad; // keeps the polygon arrays 16-byte aligned (cbuffer register)
    uint4 clip_polygon_end_points[2];
    float4 clip_polygon_points[16];
};
struct IconInstanceData {
    float4 rect;
    float4 tint_color;
    float4 rect_clip;
    float corner_radius;
    float opacity;
    float rotate; // Rotation angle (radians), with center as transform origin
    float _padding2;
};
cbuffer Params : register(b0,space0) { Uniforms uniforms; };
cbuffer ZenitDrawInfo : register(b0,space4) { uint first_vertex; uint first_instance; uint2 reserved; };
StructuredBuffer<IconInstanceData> instances : register(t1,space0);
Texture2D<float4> mask_tex : register(t0,space1);
SamplerState atlas_sampler : register(s0,space2);
struct IconVertexOutput { float4 position : SV_Position; float2 uv : TEXCOORD0; float2 local_pos : TEXCOORD1; float2 size : TEXCOORD2; float2 screen_pos : TEXCOORD3; float4 rect_clip : TEXCOORD4; nointerpolation uint instance_id : TEXCOORD5; };
uint get_clip_end(Uniforms data, uint i) { return data.clip_polygon_end_points[i / 4][i % 4]; }
float2 get_clip_point(Uniforms data, uint i) { float4 pair = data.clip_polygon_points[i / 2]; return i % 2 == 0 ? pair.xy : pair.zw; }
float sdf_rounded_rect_icon(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0,0))) - radius;
}

/// Overflow clip with per-corner radii (TL, TR, BR, BL): the quadrant picks the corner, so a
/// uniform radius evaluates exactly as the single-radius distance.
float sdf_rounded_rect_corners_icon(float2 p, float2 size, float4 radii) {
    const float r = (p.x < 0.0) ? ((p.y < 0.0) ? radii.x : radii.w) : ((p.y < 0.0) ? radii.y : radii.z);
    return sdf_rounded_rect_icon(p, size, r);
}

float sdf_ellipse_icon(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001,0.001));
    return length(q) - 1.0;
}

float point_segment_distance_icon(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = max(dot(ab, ab), 0.0001);
    const float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

bool polygon_contains_icon(float2 p, Uniforms uniforms, uint count, uint contour_count) {
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

float rect_clip_alpha_icon(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect_icon(screen_pos - clip_center, clip_size, 0.0);
    const float clip_aa = max((abs(ddx_fine(clip_sdf)) + abs(ddy_fine(clip_sdf))) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha_icon(float2 screen_pos, Uniforms uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        const float4 clip_radii = uniforms.clip_radii * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_corners_icon(screen_pos - clip_center, clip_size, clip_radii);
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
                min_dist = min(min_dist, point_segment_distance_icon(polygon_pos, a, b));
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

float clip_alpha_icon(float2 screen_pos, float4 rect_clip, Uniforms uniforms) {
    return rect_clip_alpha_icon(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha_icon(screen_pos, uniforms);
}

IconVertexOutput icon_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    IconVertexOutput output;
    IconInstanceData inst = instances[instance_id + first_instance];

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };
    uint indices[6] = {0, 1, 2, 1, 3, 2};
    const uint corner_index = indices[vertex_id + first_vertex];
    const float2 corner = corners[corner_index];

    const float s = uniforms.scale_factor;
    const float2 pos = inst.rect.xy * s;
    const float2 size = inst.rect.zw * s;
    float2 pixel_pos = pos + corner * size;

    // Rotate: with center as transform origin
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

    output.position = float4(ndc, 0.0, 1.0);
    output.uv = corner;
    // Local coordinates for SDF clipping (pre-rotation space)
    output.local_pos = (pos + corner * size) - center;
    output.size = size * 0.5;
    output.screen_pos = pixel_pos;
    output.rect_clip = inst.rect_clip;
    output.instance_id = instance_id + first_instance;
    return output;
}

float4 icon_fragment_main(IconVertexOutput input) : SV_Target {
    const IconInstanceData inst = instances[input.instance_id];
    const float corner_radius = inst.corner_radius * uniforms.scale_factor;

    float alpha = mask_tex.Sample(atlas_sampler, input.uv).r;
    if (corner_radius > 0.0) {
        const float sdf = sdf_rounded_rect_icon(input.local_pos, input.size, corner_radius);
        const float aa = (abs(ddx_fine(sdf)) + abs(ddy_fine(sdf))) * 0.5;
        alpha *= smoothstep(aa, -aa, sdf);
    }
    alpha *= clip_alpha_icon(input.screen_pos, input.rect_clip, uniforms);

    float4 color = inst.tint_color;
    color.a *= alpha * inst.opacity;
    if (color.a < 0.001) {
        discard;
    }
    color.rgb *= color.a;
    return color;
}
