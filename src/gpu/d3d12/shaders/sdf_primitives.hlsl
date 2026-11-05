// Windows counterpart of src/render/shaders/sdf_primitives.metal.
// zenit-entry: vertex sdf_tiled_rect_vertex_main
// zenit-entry: vertex sdf_region_vertex_main
// zenit-entry: vertex sdf_vertex_main
// zenit-entry: vertex sdf_shadow_ring_vertex_main
// zenit-entry: vertex sdf_dual_shadow_vertex_main
// zenit-entry: fragment sdf_shadow_ring_fragment_main
// zenit-entry: fragment sdf_dual_shadow_fragment_main
// zenit-entry: fragment sdf_linear_x_fragment_main
// zenit-entry: fragment sdf_linear_y_fragment_main
// zenit-entry: fragment sdf_inset_rect_fragment_main
// zenit-entry: fragment sdf_fragment_main
// zenit-entry: fragment sdf_body_fragment_main
// zenit-entry: fragment sdf_outer_shadow_fragment_main
// zenit-entry: fragment sdf_inset_layer_fragment_main
// zenit-entry: fragment sdf_border_layer_fragment_main
// zenit-entry: fragment sdf_rounded_clip_rect_fragment_main
// zenit-entry: fragment sdf_rect_fragment_main
// zenit-entry: fragment sdf_solid_fragment_main
// zenit-entry: fragment sdf_plain_rect_fragment_main
struct Uniforms {
    float2 viewport_size; // viewport size (physical pixels).
    float scale_factor; // DPI scale factor (Retina=2.0).
    uint clip_shape_kind;
    float4 clip_rect;
    float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_pad; // keeps the polygon arrays 16-byte aligned (cbuffer register)
    uint4 clip_polygon_end_points[2];
    float4 clip_polygon_points[16];
    uint frame_seed; // Per-frame increment driving film_grain dynamic noise.
    uint raster_clip_pos; // Raster pixel centers when viewport matches SDF coordinates
};

/// Instance data (one per primitive) — 176 bytes.
struct InstanceData {
    // Core geometry --- offset 0.
    float4 rect; // x, y, width, height (logical pixels).
    float4 rect_clip; // x, y, w, h (logical pixels); negative size = disabled.
    // Color --- offset 32.
    float4 fill_color; // fill color RGBA (gradient: from).
    float4 border_color; // border color RGBA.
    float4 shadow_color; // shadow color RGBA.
    float4 gradient_to_color; // gradient end color RGBA (used when stop_count=0).
    float4 corner_radii; // corner radii: TL, TR, BR, BL.
    // Scalar effect parameters --- offset 112.
    float border_width; // border width.
    float shadow_blur; // shadow blur radius (outer shadow).
    float shadow_offset_x; // shadow X offset.
    float shadow_offset_y; // shadow Y offset.
    // Type and flags --- offset 128.
    uint shape_type;          // 0=rect, 1=circle, 2=line, 3=arc
    /// packed_flags layout:
    ///   bit 0-7: gradient_direction (0=none, 1=vert, 2=horiz, 3=diag, 4=radial,
    ///            5=conic)
    ///   bit 8-15: noise_mode (0=none, 1=value, 2=film_grain)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24: inset_shadow
    ///   bit 25: has_shadow2.
    uint packed_flags;
    float noise_scale; // noise scale (logical pixels, 0=disabled).
    float noise_intensity; // noise blend intensity [0..1].
    // ── Per-side border ──────────────────────────────── offset 144
    float4 border_widths; // per-side: top, right, bottom, left; all zero = use border_width.
    // Multi-color gradient / multi-shadow indices --- offset 160.
    uint gradient_stop_offset; // GradientStop buffer start index (ignored when stop_count=0).
    uint gradient_stop_count; // stop count (0 = use legacy fill/gradient_to_color).
    uint shadow2_index; // ShadowParam buffer index for second shadow.
    uint _ext_reserved; // reserved for extension.
};

/// Vertex output.
struct VertexOutput {
    float4 position : SV_Position;
    float2 local_pos : TEXCOORD0;
    float2 size : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float2 screen_pos : TEXCOORD3;
    float4 rect_clip : TEXCOORD4;
    nointerpolation uint instance_id : TEXCOORD5;
    // Solid fragments consume vertex-fetched constants, avoiding repeated
    // structured-buffer loads for every covered pixel on software adapters.
    nointerpolation float4 solid_fill : TEXCOORD6;
    nointerpolation float4 solid_border : TEXCOORD7;
    nointerpolation float4 solid_radii : TEXCOORD8;
    nointerpolation float4 solid_widths : TEXCOORD9;
    nointerpolation float3 solid_metrics : TEXCOORD10;
    nointerpolation uint solid_shape : TEXCOORD11;
    nointerpolation float3 second_shadow_metrics : TEXCOORD12;
};

// Identical varyings plus per-quad rasterizer viewport selection.
struct RegionVertexOutput {
    float4 position : SV_Position;
    float2 local_pos : TEXCOORD0;
    float2 size : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float2 screen_pos : TEXCOORD3;
    float4 rect_clip : TEXCOORD4;
    nointerpolation uint instance_id : TEXCOORD5;
    // Solid fragments consume vertex-fetched constants, avoiding repeated
    // structured-buffer loads for every covered pixel on software adapters.
    nointerpolation float4 solid_fill : TEXCOORD6;
    nointerpolation float4 solid_border : TEXCOORD7;
    nointerpolation float4 solid_radii : TEXCOORD8;
    nointerpolation float4 solid_widths : TEXCOORD9;
    nointerpolation float3 solid_metrics : TEXCOORD10;
    nointerpolation uint solid_shape : TEXCOORD11;
    nointerpolation float3 second_shadow_metrics : TEXCOORD12;
    uint region_index : SV_ViewportArrayIndex;
};

// Procedural noise functions

struct GradientStop {
    float4 color;    // RGBA linear
    float  position; // [0.0, 1.0]
    float  _pad0;
    float  _pad1;
    float  _pad2;
    // 32 bytes per stop
};
struct ShadowParam {
    float4 color;
    float  blur;
    float  offset_x;
    float  offset_y;
    float  _pad;
    // 32 bytes
};
cbuffer Params : register(b0,space0) { Uniforms uniforms; };
cbuffer ZenitDrawInfo : register(b0,space4) { uint first_vertex; uint first_instance; uint2 reserved; };
StructuredBuffer<InstanceData> instances : register(t1,space0);
StructuredBuffer<GradientStop> grad_stops : register(t2,space0);
StructuredBuffer<ShadowParam> shadow_params : register(t3,space0);
uint get_clip_end(Uniforms data, uint i) { return data.clip_polygon_end_points[i / 4][i % 4]; }
float2 get_clip_point(Uniforms data, uint i) { float4 pair = data.clip_polygon_points[i / 2]; return i % 2 == 0 ? pair.xy : pair.zw; }
/// Wang hash — fast integer hash.
uint hash_wang(uint x) {
    x = (x ^ 61u) ^ (x >> 16u);
    x = x + (x << 3u);
    x = x ^ (x >> 4u);
    x = x * 0x27d4eb2du;
    x = x ^ (x >> 15u);
    return x;
}

/// 2D integer coords -> [0,1] float hash.
float hash2d(float2 p) {
    uint ix = uint(abs(p.x) * 1000.0);
    uint iy = uint(abs(p.y) * 1000.0);
    return float(hash_wang(ix ^ hash_wang(iy * 2654435761u))) / 4294967295.0;
}

/// Value Noise: bilinear interpolation of lattice-point (random value) noise.
/// p: local coords (logical pixels), scale: lattice spacing, seed: instance seed.
float value_noise(float2 p, float scale, uint seed) {
    float2 sp = p / max(scale, 0.001) + float2(float(seed) * 17.3, float(seed) * 31.7);
    float2 i = floor(sp);
    float2 f = frac(sp);
    float2 u = f * f * (3.0 - 2.0 * f); // Hermite smooth interpolation.
    float a = hash2d(i);
    float b = hash2d(i + float2(1.0, 0.0));
    float c = hash2d(i + float2(0.0, 1.0));
    float d = hash2d(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

/// Film Grain: high-frequency grain noise based on physical pixel coords.
/// screen_pos: physical pixel coords, seed: instance seed.
float film_grain(float2 screen_pos, uint seed) {
    return hash2d(floor(screen_pos) + float2(float(seed & 255u) * 3.7, float((seed >> 8u) & 255u) * 5.1)) - 0.5;
}

// Multi-color gradients

/// GradientStop: multi-color gradient stop (buffer slot 2).


// Bayer ordered dithering (Blend2D-inspired)
// 16x16 Bayer matrix, range [0, 255], compile-time constant.
// Adds sub-pixel offset to gradients before 8bit framebuffer writes to eliminate banding.
// Reference: Blend2D fetchgradientpart.cpp GradientDitheringContext
static const uint bayer_16x16[256] = {
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

/// Get Bayer threshold from physical pixel coords, normalized to
/// [-0.5/255, +0.5/255] for sub-pixel dithering before gradient write.
inline float bayer_dither(float2 screen_pos) {
    uint ix = uint(screen_pos.x) & 15u;
    uint iy = uint(screen_pos.y) & 15u;
    return (float(bayer_16x16[iy * 16u + ix]) - 127.5) / 65025.0; // ÷ (255×255) preserves energy conservation.
}

// Multi-color gradients

/// Premultiplied alpha helper (Blend2D-inspired). Interpolate in premul space
/// to avoid color shift between semi-transparent stops.
inline float4 premul(float4 c)   { return float4(c.rgb * c.a, c.a); }
inline float4 unpremul(float4 c) {
    return c.a > 1e-6 ? float4(c.rgb / c.a, c.a) : float4(0.0,0.0,0.0,0.0);
}

/// Evaluate multi-color gradient (premultiplied interpolation; stops must be
/// in ascending position order).
float4 eval_gradient_stops(float t, StructuredBuffer<GradientStop> stops, uint offset, uint count) {
    if (count == 0u) return float4(0.0,0.0,0.0,0.0);
    if (count > 16u) return float4(1.0, 0.0, 1.0, 1.0); // magenta = parameter error (count limit 16).
    if (count == 1u) return stops[offset].color;
    float min_pos = stops[offset].position;
    float max_pos = stops[offset + count - 1u].position;
    float t_c = clamp(t, min_pos, max_pos);
    // First segment containing t_c, without a return inside the loop: the
    // Windows 10 WARP JIT mis-executes that form (3-stop gradients rendered
    // transparent).
    float4 result = stops[offset + count - 1u].color;
    bool found = false;
    for (uint i = 0u; i < count - 1u; i++) {
        GradientStop s0 = stops[offset + i];
        GradientStop s1 = stops[offset + i + 1u];
        if (!found && t_c >= s0.position && t_c <= s1.position) {
            float span = s1.position - s0.position;
            float lt = (span > 1e-6) ? (t_c - s0.position) / span : 0.0;
            // Premul-space interpolation: avoids RGB shift between semi-transparent stops.
            result = unpremul(lerp(premul(s0.color), premul(s1.color), lt));
            found = true;
        }
    }
    return result;
}

// Multiple shadows

/// ShadowParam: second shadow parameters (buffer slot 3).


// SDF functions

/// SDF rounded rectangle (uniform radius).
float sdf_rounded_rect(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0,0.0))) - radius;
}

float sdf_ellipse_clip(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001,0.001));
    return length(q) - 1.0;
}

/// Ellipse SDF: returns true pixel distance (first-order Newton estimate of the
/// normalized gradient).
/// WARNING: don't reuse `sdf_ellipse_clip` above: it returns the dimensionless
/// `length(p/r)-1`, valid only for clipping (`shape_clip_alpha` self-normalizes via
/// `fwidth`). Fill AA width comes from `sdf_aa_width(sdf)`, floor 0.5 pixels; a
/// dimension mismatch scales the AA band by 10x+ or leaves edges aliased / mushy.
/// Also don't use `(length(p/r)-1) * min(rx,ry)` (path.metal style): on a 10:1 ellipse
/// the major-axis endpoint reads 1/10 of the true distance and AA stretches 10x at the
/// thin end; a 2:1 ellipse stroke is already 2x wide.
/// An ellipse has no closed-form SDF. Use implicit `f = |p/r| - 1` divided by its
/// gradient magnitude for a first-order distance. Error near the boundary (where
/// AA/stroke works) is 0.2-2.4%, worst case 10:1 aspect 8%; imperceptible.
float sdf_ellipse(float2 p, float2 radius_xy) {
    const float2 r = max(radius_xy, float2(0.001,0.001));
    const float2 q = p / r;
    const float k = length(q);
    // At center: gradient zero, degenerates to shortest semi-axis distance.
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

int polygon_winding(float2 p, Uniforms uniforms, uint count, uint contour_count) {
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
    return winding;
}

bool polygon_contains(float2 p, Uniforms uniforms, uint count, uint contour_count) {
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
    return polygon_winding(p, uniforms, count, contour_count) != 0;
}

/// SDF rounded rectangle (per-corner radius).
/// radii: top-left, top-right, bottom-right, bottom-left.
float sdf_rounded_rect_4(float2 p, float2 size, float4 radii) {
    // Pick radius by quadrant.
    float r = (p.x < 0.0)
        ? ((p.y < 0.0) ? radii.x : radii.w) // left: TL / BL.
        : ((p.y < 0.0) ? radii.y : radii.z); // right: TR / BR.
    float2 d = abs(p) - size + r;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0,0.0))) - r;
}

/// SDF circle.
float sdf_circle(float2 p, float radius) {
    return length(p) - radius;
}

/// SDF line (capsule).
float sdf_line(float2 p, float2 a, float2 b, float thickness) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - thickness;
}

/// SDF arc (annulus segment).
/// p: position relative to center.
/// outer_radius: outer radius.
/// stroke_width: line width.
/// start_angle: start (radians, any value, need not normalize).
/// end_angle: end (radians, end >= start, sweep = end - start).
float sdf_arc_cap(float2 p, float angle, float inner_radius, float outer_radius) {
    float2 dir = float2(cos(angle), sin(angle));
    float2 a = dir * inner_radius;
    float2 ba = dir * (outer_radius - inner_radius);
    float2 pa = p - a;
    return length(pa - ba * clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0));
}

float sdf_arc(float2 p, float outer_radius, float stroke_width, float start_angle, float end_angle) {
    float mid_radius = outer_radius - stroke_width * 0.5;
    float half_stroke = stroke_width * 0.5;

    // Ring SDF (no angle clipping)
    float ring_sdf = abs(length(p) - mid_radius) - half_stroke;

    // sweep = arc angle, clamp to [0, 2pi]
    float sweep = clamp(end_angle - start_angle, 0.0, 2.0 * 3.14159265358979323846);

    // sweep >= 2pi: full ring, return directly
    if (sweep >= 2.0 * 3.14159265358979323846 - 0.0001) {
        return ring_sdf;
    }
    // Empty arc: positive everywhere and continuous (no line along the start ray).
    if (sweep <= 0.0) {
        return max(ring_sdf, 0.0) + 1.0;
    }

    // Flat-capped arc: the ring band clipped by the two radial end caps. The distance to the
    // nearer cap segment closes the field on both sides of each boundary ray: inside the sweep
    // it bounds the ring distance from below (approaching 0 at the cap), outside it is the
    // distance itself. A constant outside the sweep jumped by the ring distance along those
    // rays, and the derivative-based AA drew a line along each of them.
    float inner_radius = max(outer_radius - stroke_width, 0.0);
    float cap = min(sdf_arc_cap(p, start_angle, inner_radius, outer_radius),
                    sdf_arc_cap(p, start_angle + sweep, inner_radius, outer_radius));

    // Normalize p's polar angle relative to start_angle to [0, 2pi)
    float raw_angle = atan2(p.y, p.x);
    float rel = raw_angle - start_angle;
    rel = rel - floor(rel / (2.0 * 3.14159265358979323846)) * (2.0 * 3.14159265358979323846);

    return rel <= sweep ? max(ring_sdf, -cap) : cap;
}

// Anti-aliasing functions

float aa_step(float edge, float x, float aa_width) {
    return smoothstep(edge + aa_width, edge - aa_width, x);
}

// sdf-clip-shared-begin (generated by tools/metal_to_hlsl.py; do not edit)
float2 sdf_clip_screen_pos(float2 raster_pos, float2 screen_pos, uint raster_clip_pos) {
    // Tiling changes interpolation rounding. Clip derivatives need the same pixel
    // centers in every entry; retain interpolated coordinates for other viewports.
    return raster_clip_pos != 0u ? raster_pos : screen_pos;
}

float rect_clip_alpha(float2 screen_pos, float4 rect_clip, float scale_factor) {
    if (rect_clip.z < 0.0 || rect_clip.w < 0.0) {
        return 1.0;
    }

    const float2 clip_center = (rect_clip.xy + rect_clip.zw * 0.5) * scale_factor;
    const float2 clip_size = rect_clip.zw * scale_factor * 0.5;
    const float clip_sdf = sdf_rounded_rect(screen_pos - clip_center, clip_size, 0.0);
    const float clip_aa = max((abs(ddx_fine(clip_sdf)) + abs(ddy_fine(clip_sdf))) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}
// sdf-clip-shared-end

float shape_clip_alpha(float2 screen_pos, Uniforms uniforms) {
    if (uniforms.clip_shape_kind == 0u) {
        return 1.0;
    }

    const float2 clip_center = (uniforms.clip_rect.xy + uniforms.clip_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip_rect.zw * uniforms.scale_factor * 0.5;
    float clip_sdf = 1.0;
    if (uniforms.clip_shape_kind == 1u) {
        // Per-corner radii (TL, TR, BR, BL); a uniform radius is the single-radius distance.
        const float4 clip_radii = uniforms.clip_radii * uniforms.scale_factor;
        clip_sdf = sdf_rounded_rect_4(screen_pos - clip_center, clip_size, clip_radii);
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
                min_dist = min(min_dist, point_segment_distance(polygon_pos, a, b));
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

float clip_alpha(float2 screen_pos, float4 rect_clip, Uniforms uniforms) {
    return rect_clip_alpha(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha(screen_pos, uniforms);
}

/// Fill AA half-width (pixels): half the SDF change per screen pixel, i.e. the
/// screen-space gradient. A pixel center 0.5px inside the edge covers exactly 1;
/// 0.5px outside covers 0, so adjacent solid rects are seamless at integer boundaries.
/// Do not use `length(float2(ddx(local.x), ddy(local.y)))` (diagonal): it relaxes
/// axis-aligned edges by sqrt(2)x (0.707px), leaving pixels tight against an integer
/// edge only ~94% covered and a dark seam between adjacent color blocks.
float sdf_aa_width(float sdf) {
    return length(float2(ddx_fine(sdf), ddy_fine(sdf))) * 0.5;
}

// src-over premultiplied alpha composite.
inline void composite_premul(inout float4 dst, float4 src) {
    dst += src * (1.0 - dst.a);
}

// Vertex shader

VertexOutput sdf_vertex_impl(uint vertex_id, uint instance_id, bool shadow_ring) {
    VertexOutput output;

    InstanceData inst = instances[instance_id + first_instance];

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    uint indices[6] = {0, 1, 2, 1, 3, 2};
    uint corner_index = indices[shadow_ring ? (vertex_id + first_vertex) % 6u : vertex_id + first_vertex];
    float2 corner = corners[corner_index];

    // Instance coords are logical pixels; multiply by scale_factor to physical.
    float s = uniforms.scale_factor;

    // Arcs carry their start / end angles in the shadow offset slots and draw no shadow:
    // their quad is the ring's bounds (growing angles must not stretch it).
    float expand = inst.shape_type == 3u ? 0.0 : inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
    // bit 28: outer shadow spread (noise_scale reused); positive spread syncs quad expansion.
    if ((inst.packed_flags & (1u << 28u)) != 0u) expand += max(inst.noise_scale, 0.0);
    // Two-layer shadow: quad must cover both layers' max expansion, else large
    // blur shadow in layer 2 hard-cuts at quad edge (bright band around panel).
    if ((inst.packed_flags & (1u << 25u)) != 0u) {
        ShadowParam s2v = shadow_params[inst.shadow2_index];
        float expand2 = s2v.blur * 2.0 + abs(s2v.offset_x) + abs(s2v.offset_y);
        expand = max(expand, expand2);
    }

#if defined(ZENIT_LINUX_GPU)
    // A half-pixel-aligned thin fill needs fragments on both sides of its
    // distance-AA boundary. Its unexpanded triangle otherwise drops one of
    // the two half-covered texels and loses half the divider's opacity.
    if (inst.shape_type == 0u && inst.packed_flags == 0u && expand == 0.0 &&
        all(inst.rect.zw > float2(0.0, 0.0)) && min(inst.rect.z * s, inst.rect.w * s) <= 2.0) {
        expand = 0.5 / s;
    }
#endif

    float2 pos = (inst.rect.xy - expand) * s;
    float2 size = (inst.rect.zw + expand * 2.0) * s;
    float2 pixel_pos = pos + corner * size;
    if (shadow_ring) {
        // The unchanged shadow fragment multiplies coverage by (1-fill_alpha).
        // Remove only a conservative interior where fill_alpha is exactly one.
        // Two physical pixels retain every AA helper/edge pixel around the hole.
        float radius = max(max(inst.corner_radii.x, inst.corner_radii.y),
                           max(inst.corner_radii.z, inst.corner_radii.w)) * s;
        float2 half_size = inst.rect.zw * s * 0.5;
        float2 center = inst.rect.xy * s + half_size;
        float2 inner_half = max(half_size - max(radius, 0.0) - 2.0, float2(0,0));
        float2 lo = center - inner_half;
        float2 hi = center + inner_half;
        float2 tile_lo = pos;
        float2 tile_hi = pos + size;
        switch ((vertex_id + first_vertex) / 6u) {
            case 0: tile_hi.x = lo.x; break;
            case 1: tile_lo.x = hi.x; break;
            case 2: tile_lo.x = lo.x; tile_hi = float2(hi.x, lo.y); break;
            default: tile_lo = float2(lo.x, hi.y); tile_hi.x = hi.x; break;
        }
        pixel_pos = lerp(tile_lo, tile_hi, corner);
    }


    float2 ndc = (pixel_pos / uniforms.viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    output.position = float4(ndc, 0.0, 1.0);

    float2 center = inst.rect.xy * s + inst.rect.zw * s * 0.5;
    output.local_pos = pixel_pos - center;
    output.size = inst.rect.zw * s * 0.5;
    output.screen_pos = pixel_pos;

    output.uv = corner;
    output.rect_clip = inst.rect_clip;
    output.instance_id = instance_id + first_instance;
    output.solid_fill = inst.fill_color;
    output.solid_border = inst.border_color;
    output.solid_radii = inst.corner_radii;
    output.solid_widths = inst.border_widths;
    output.solid_metrics = float3(inst.border_width, inst.shadow_offset_x, inst.shadow_offset_y);
    output.solid_shape = inst.shape_type;
    output.second_shadow_metrics = float3(0,0,0);

    return output;
}

VertexOutput sdf_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    return sdf_vertex_impl(vertex_id, instance_id, false);
}
// Five nonoverlapping tiles preserve instance order. Only a matching 1:1
// viewport uses this entry; two physical pixels retain all AA/helper lanes.
VertexOutput sdf_tiled_rect_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    uint index = vertex_id + first_vertex;
    VertexOutput o = sdf_vertex_impl(index % 6u, instance_id, false);
    InstanceData inst = instances[instance_id + first_instance];
    float s = uniforms.scale_factor;
    float2 outer_lo = inst.rect.xy * s;
    float2 outer_hi = (inst.rect.xy + inst.rect.zw) * s;
    float radius = max(max(inst.corner_radii.x, inst.corner_radii.y), max(inst.corner_radii.z, inst.corner_radii.w));
    float border = max(inst.border_width, max(max(inst.border_widths.x, inst.border_widths.y), max(inst.border_widths.z, inst.border_widths.w)));
    float inset = (max(radius, 0.0) + max(border, 0.0)) * s + 2.0;
    float2 lo = outer_lo + inset;
    float2 hi = outer_hi - inset;
    if (inst.rect_clip.z >= 0 && inst.rect_clip.w >= 0) {
        lo = max(lo, inst.rect_clip.xy * s + 2.0);
        hi = min(hi, (inst.rect_clip.xy + inst.rect_clip.zw) * s - 2.0);
    }
    if (any(hi <= lo)) lo = hi = (outer_lo + outer_hi) * 0.5;
    // Integer pixel bounds supplied by the opaque-clear path. Keeping the
    // exact same hole avoids CPU/GPU rounding disagreements at tile seams.
    if (inst._ext_reserved == 1u) { lo = inst.gradient_to_color.xy; hi = inst.gradient_to_color.zw; }
    float2 tile_lo = outer_lo, tile_hi = outer_hi;
    uint tile = index / 6u;
    switch (tile) {
        case 0: tile_hi.x = lo.x; break;
        case 1: tile_lo.x = hi.x; break;
        case 2: tile_lo.x = lo.x; tile_hi = float2(hi.x, lo.y); break;
        case 3: tile_lo = float2(lo.x, hi.y); tile_hi.x = hi.x; break;
        default: tile_lo = lo; tile_hi = hi; break;
    }
    float2 pixel_pos = lerp(tile_lo, tile_hi, o.uv);
    o.position = float4(pixel_pos / uniforms.viewport_size * float2(2,-2) + float2(-1,1), 0, 1);
    o.local_pos = pixel_pos - (outer_lo + outer_hi) * 0.5;
    o.screen_pos = pixel_pos;
    o.solid_shape = tile == 4u ? 99u : 0u;
    return o;
}
VertexOutput sdf_shadow_ring_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VertexOutput o = sdf_vertex_impl(vertex_id, instance_id, true);
    InstanceData inst = instances[instance_id + first_instance];
    o.solid_fill = inst.shadow_color;
    o.solid_border = float4(inst.shadow_blur, inst.noise_scale, 0, 0);
    o.solid_shape = inst.packed_flags & (1u << 28u);
    return o;
}

// Match the original quad and interpolation, but fetch both shadows once per
// vertex. Dedicated flat varyings remove structured-buffer loads per pixel.
VertexOutput sdf_dual_shadow_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VertexOutput o = sdf_vertex_impl(vertex_id, instance_id, false);
    InstanceData inst = instances[instance_id + first_instance];
    ShadowParam second = shadow_params[inst.shadow2_index];
    o.solid_border = inst.shadow_color;
    o.solid_widths = second.color;
    o.solid_metrics = float3(inst.shadow_blur, inst.shadow_offset_x, inst.shadow_offset_y);
    o.second_shadow_metrics = float3(second.blur, second.offset_x, second.offset_y);
    return o;
}

// Four copies of the original quad; only their scissor/viewport index differs.
RegionVertexOutput sdf_region_vertex_main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    VertexOutput base = sdf_vertex_impl(vertex_id % 6u, instance_id, false);
    RegionVertexOutput output;
    output.position = base.position;
    output.local_pos = base.local_pos;
    output.size = base.size;
    output.uv = base.uv;
    output.screen_pos = base.screen_pos;
    output.rect_clip = base.rect_clip;
    output.instance_id = base.instance_id;
    output.solid_fill = base.solid_fill;
    output.solid_border = base.solid_border;
    output.solid_radii = base.solid_radii;
    output.solid_widths = base.solid_widths;
    output.solid_metrics = base.solid_metrics;
    output.solid_shape = base.solid_shape;
    output.second_shadow_metrics = base.second_shadow_metrics;
    output.region_index = vertex_id / 6u;
    return output;
}

// Fragment shader

// Shadow/inset shapes support rounded rect, circle and ellipse. Uses the same
// if/else form as the primary shape in sdf_fragment_impl (see the WARP note
// there) instead of three duplicated switches.
float shape_sdf_basic(uint shape, float2 p, float2 size, float4 radii, float fallback) {
    if (shape == 0u) return sdf_rounded_rect_4(p, size, radii);
    if (shape == 1u) return sdf_circle(p, min(size.x, size.y));
    if (shape == 4u) return sdf_ellipse(p, size);
    return fallback;
}

// Layer split of the material program for D3D12. composite_premul composites
// front to back (each later layer goes under the result), so one pass stacks,
// top to bottom: outer shadows, fill, inset shadow, border. The Windows 10 WARP
// JIT cannot compile a program holding more than two of the shape SDF
// evaluations (body, per-side inner contour, inset shape, outer shadows):
// process crash or device removed. So an instance may be drawn bottom-up as
// over-blended layer passes instead:
//   border_layer  border
//   inset_layer   inset shadow
//   fill_layer    fill (gradient, noise); also the border when the instance
//                 has no inset shadow (no border pass is drawn for it then)
//   outer_shadows both outer shadows (one [loop] body: a single SDF copy)
// Over is associative, so the passes reproduce the single pass.
float4 sdf_fragment_impl_ex(VertexOutput input, InstanceData inst, bool solid_only, bool dual_shadow_only, bool rounded_clip_only, bool outer_shadows, bool fill_layer, bool inset_layer, bool border_layer) {
    // The CPU selects this specialization only for a rounded-rectangle mask.
    // Keeping its kind constant removes ellipse/polygon programs from WARP.
    Uniforms clip_uniforms = uniforms;
    if (rounded_clip_only) clip_uniforms.clip_shape_kind = 1u;
    const float s = uniforms.scale_factor;
    const float4 corner_radii = inst.corner_radii * s;
    const float corner_radius_max = max(max(corner_radii.x, corner_radii.y), max(corner_radii.z, corner_radii.w));
    const float border_width = inst.border_width * s;
    const float shadow_blur = inst.shadow_blur * s;
    const float2 shadow_offset = float2(inst.shadow_offset_x, inst.shadow_offset_y) * s;

    float sdf;

    // if/else rather than switch: the Windows 10 WARP JIT crashes on this
    // switch (null dereference in d3d10warp.dll on the first draw).
    const uint shape = inst.shape_type;
    if (shape == 0u) {
        sdf = sdf_rounded_rect_4(input.local_pos, input.size, corner_radii);
    } else if (shape == 1u) {
        sdf = sdf_circle(input.local_pos, min(input.size.x, input.size.y));
    } else if (shape == 2u) {
        sdf = abs(input.local_pos.y) - corner_radii.x;
    } else if (shape == 3u) {
        // arc: corner_radii.x = outer radius, border_width = stroke width.
        //      shadow_offset_x = start angle (radians), shadow_offset_y = end angle.
        sdf = sdf_arc(input.local_pos, corner_radii.x, inst.border_width * s, inst.shadow_offset_x, inst.shadow_offset_y);
    } else if (shape == 4u) {
        // ellipse: input.size is semi-axes (same convention as sdf_rounded_rect_4).
        sdf = sdf_ellipse(input.local_pos, input.size);
    } else {
        sdf = 1.0;
    }
    // Floor 0.5: interior centerline SDF gradient discontinuous (quad diff -> 0);
    // can't let transition band collapse.
    float aa_width = max(sdf_aa_width(sdf), 0.5);

    float fill_alpha = aa_step(0.0, sdf, aa_width);

    // clip_alpha takes screen-space derivatives and, for polygon clips, loops
    // over the clip contours. Evaluate it once here, in uniform control flow
    // while every pixel of the 2x2 quad is live, and reuse it on every path:
    // the plain/solid/dual-shadow exits branch per pixel and discard, so a
    // derivative taken inside or after them is undefined (the Windows 10 WARP
    // JIT hangs on the duplicated per-path copies). Same as the Metal shader.
    const float clip_coverage = clip_alpha(sdf_clip_screen_pos(input.position.xy, input.screen_pos, uniforms.raster_clip_pos), input.rect_clip, clip_uniforms);

    // Both outer shadows are multiplied by (1 - fill_alpha). Once geometry
    // coverage is exactly one, they contribute zero even for translucent fill.
    // Keep this specialization out of the general reference entry point.
    [branch]
    if (dual_shadow_only && fill_alpha == 1.0) {
        float4 interior = inst.fill_color;
        interior.rgb *= interior.a;
        interior *= clip_coverage;
        if (interior.a < 0.001) discard;
        return interior;
    }

    // Most UI background pixels have no material effects. Keep them out of
    // the general border/shadow/gradient program, particularly on WARP.
    // Reuse the same SDF coverage, clip and premultiplied-alpha operations.
    [branch]
    if (fill_layer && inst.packed_flags == 0u && inst.border_width == 0.0 &&
        all(inst.border_widths == float4(0.0,0.0,0.0,0.0)) && inst.shadow_color.a == 0.0) {
        float4 plain = inst.fill_color;
        plain.a *= fill_alpha;
        plain.rgb *= plain.a;
        plain *= clip_coverage;
        if (plain.a < 0.001) discard;
        return plain;
    }

    float border_alpha = 0.0;
    float4 bw = inst.border_widths * s;
    // WARNING: per-side inner outline hardcodes sdf_rounded_rect_4 (below).
    // Non-rects draw "rect stroke over ellipse fill". An ellipse has no "four
    // edges", so per-side is meaningless: gatekeep here and use the uniform fast path
    // (sdf + border_width, shape-agnostic). Zig-side `addEllipse` folds the four values
    // to `border_width = max(...)`; taking the first would turn {0,0,0,4} into a
    // 0-width stroke.
    bool has_per_side = (bw.x + bw.y + bw.z + bw.w) > 0.0 && inst.shape_type == 0u;

    const bool has_inset_shad = (inst.packed_flags & (1u << 24u)) != 0u;
    const bool want_inset = inset_layer && !solid_only && has_inset_shad && fill_alpha > 0.0;
    const bool want_border = border_layer || (fill_layer && !has_inset_shad);
    if (want_border && has_per_side) {
        // Per-side border: compute inner outline SDF.
        // bw = (top, right, bottom, left).
        float2 inner_half = float2(
            input.size.x - (bw.y + bw.w) * 0.5,
            input.size.y - (bw.x + bw.z) * 0.5
        );
        inner_half = max(inner_half, float2(0.0,0.0));

        // Asymmetric border shifts inner rect center.
        float2 inner_offset = float2(
            (bw.w - bw.y) * 0.5,
            (bw.x - bw.z) * 0.5
        );

        // Inner radius = max(0, outer - max(adjacent widths)).
        float4 inner_radii = max(corner_radii - float4(
            max(bw.x, bw.w),  // TL: top, left
            max(bw.x, bw.y),  // TR: top, right
            max(bw.z, bw.y),  // BR: bottom, right
            max(bw.z, bw.w)   // BL: bottom, left
        ), float4(0.0,0.0,0.0,0.0));

        float inner_sdf = sdf_rounded_rect_4(input.local_pos - inner_offset, inner_half, inner_radii);
        float outer_mask = aa_step(0.0, sdf, aa_width);
        float inner_mask = aa_step(0.0, inner_sdf, aa_width);
        border_alpha = outer_mask - inner_mask;
    } else if (want_border && border_width > 0.0) {
        // Uniform border: fast path.
        float inner_sdf = sdf + border_width;
        border_alpha = aa_step(0.0, sdf, aa_width) - aa_step(0.0, inner_sdf, aa_width);
    }

    // A separate entry point specializes away material evaluation on WARP.
    // The CPU selects it only for zero flags and transparent shadow color.
    if (solid_only) {
        float4 solid = float4(0.0,0.0,0.0,0.0);
        if (fill_alpha > 0.0) {
            float4 fill = inst.fill_color;
            fill.a *= fill_alpha;
            fill.rgb *= fill.a;
            composite_premul(solid, fill);
        }
        if (border_alpha > 0.0) {
            float4 border = inst.border_color;
            border.a *= border_alpha;
            border.rgb *= border.a;
            composite_premul(solid, border);
        }
        solid *= clip_coverage;
        if (solid.a < 0.001) discard;
        return solid;
    }


    // -- Unpack packed_flags --.
    uint gradient_dir  = inst.packed_flags & 0xFFu;
    uint noise_mode    = (inst.packed_flags >> 8u)  & 0xFFu;
    uint noise_seed    = (inst.packed_flags >> 16u) & 0xFFu;
    bool has_shadow2    = (inst.packed_flags & (1u << 25u)) != 0u;

    float4 result = float4(0.0,0.0,0.0,0.0);

    // 1. Outer shadows: first (inst.shadow_*, CSS spread expand/contract) and
    // second (has_shadow2) share one [loop] body, former on top. Windows 10 WARP
    // JIT can't compile a third SDF expansion. Both multiplied by (1 -
    // fill_alpha): solid interior has no outer shadow.
    [loop]
    for (uint k = 0u; k < 2u; k++) {
        if (outer_shadows && (k == 0u ? shadow_blur > 0.0 : has_shadow2)) {
            float4 color;
            float blur;
            float2 offset;
            float2 half_size = input.size;
            float4 radii = corner_radii;
            if (k == 0u) {
                color = inst.shadow_color;
                blur = shadow_blur;
                offset = shadow_offset;
                // Carving still uses body; only rounded-rect shadow changes shape by spread.
                const bool has_spread = (inst.packed_flags & (1u << 28u)) != 0u;
                const float spread = has_spread ? inst.noise_scale * s : 0.0;
                if (inst.shape_type == 0u) {
                    half_size = max(input.size + spread, float2(0.0,0.0));
                    radii = max(corner_radii + spread, float4(0.0,0.0,0.0,0.0));
                }
            } else {
                ShadowParam s2;
                if (dual_shadow_only) {
                    s2 = (ShadowParam)0;
                    s2.color = input.solid_widths;
                    s2.blur = input.second_shadow_metrics.x;
                    s2.offset_x = input.second_shadow_metrics.y;
                    s2.offset_y = input.second_shadow_metrics.z;
                } else s2 = shadow_params[inst.shadow2_index];
                color = s2.color;
                blur = s2.blur * s;
                offset = float2(s2.offset_x, s2.offset_y) * s;
            }
            float shadow_sdf = shape_sdf_basic(inst.shape_type, input.local_pos - offset, half_size, radii, 1.0);
            float4 shadow = color;
            shadow.a *= smoothstep(blur, -blur, shadow_sdf) * (1.0 - fill_alpha);
            shadow.rgb *= shadow.a;
            composite_premul(result, shadow);
        }
    }

    // 2. Fill (gradient + noise).
    if (fill_layer && fill_alpha > 0.0) {
        // -- Gradient t calculation -.
        float4 fill = inst.fill_color;
        if (gradient_dir > 0u) {
            float t = 0.0;

            if (gradient_dir == 4u) {
                // Radial: use raw UV, no shadow expand. shadow_offset_x/y reused as center
                // offset (UV space, default 0,0 = center 0.5,0.5).
                float2 center_uv = float2(0.5 + inst.shadow_offset_x, 0.5 + inst.shadow_offset_y);
                // bit 29: custom ellipse radii (UV units; CSS radial-gradient(rx ry at cx cy)).
                if ((inst.packed_flags & (1u << 29u)) != 0u) {
                    float2 rr = max(float2(inst.noise_scale, inst.noise_intensity), float2(1e-4,1e-4));
                    t = length((input.uv - center_uv) / rr);
                } else {
                    t = length(input.uv - center_uv) * 2.0;
                }
            } else if (gradient_dir == 5u) {
                // Conic: use raw UV, no shadow expand. _ext_reserved reused as start angle
                // (bitcast float, radians).
                float start_angle = asfloat(inst._ext_reserved);
                float angle = atan2(input.uv.y - 0.5, input.uv.x - 0.5) - start_angle;
                t = frac(angle / (2.0 * 3.14159265358979323846) + 0.5);
            } else {
                // Linear (vert/horiz/diag): same quad expansion as the vertex stage.
                float expand = inst.shape_type == 3u ? 0.0 : inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
                float2 orig_size = inst.rect.zw;
                float2 expanded_size = orig_size + expand * 2.0;
                float2 remap_uv = (input.uv * expanded_size - float2(expand,expand)) / max(orig_size, float2(0.001,0.001));
                remap_uv = clamp(remap_uv, 0.0, 1.0);
                if      (gradient_dir == 1u) t = remap_uv.y;
                else if (gradient_dir == 2u) t = remap_uv.x;
                else                         t = (remap_uv.x + remap_uv.y) * 0.5;
            }
            // Extend Mode (packed_flags bit 26-27): 0=pad, 1=repeat, 2=reflect
            uint extend_mode = (inst.packed_flags >> 26u) & 0x3u;
            if (extend_mode == 1u) {
                t = frac(t); // REPEAT: tile.
            } else if (extend_mode == 2u) {
                float t2 = fmod(abs(t), 2.0);
                t = (t2 > 1.0) ? (2.0 - t2) : t2; // REFLECT: mirror.
            } else {
                t = clamp(t, 0.0, 1.0); // PAD (default): clamp to edge colors.
            }

            // Multi-color gradient (stop_count > 0) or old two-color mode.
            if (inst.gradient_stop_count > 0u) {
                fill = eval_gradient_stops(t, grad_stops, inst.gradient_stop_offset, inst.gradient_stop_count);
            } else {
                // Old two-color mode also interpolates in premul space.
                float4 from_p = premul(inst.fill_color);
                float4 to_p   = premul(inst.gradient_to_color);
                fill = unpremul(lerp(from_p, to_p, t));
            }

            // Bayer ordered dithering: eliminates banding in 8bit framebuffer. Sub-pixel
            // offset RGB only; alpha unchanged.
            float dither = bayer_dither(input.screen_pos);
            fill.rgb = saturate(fill.rgb + dither);
        }

        // -- Procedural noise overlay --.
        if (noise_mode > 0u && inst.noise_scale > 0.0) {
            float n = 0.0;
            float ns = inst.noise_scale * s; // scale to physical pixels.
            if (noise_mode == 1u) {
                // Value Noise (based on logical coords, scales adaptively).
                n = value_noise(input.local_pos / s, ns / s, noise_seed) - 0.5;
            } else if (noise_mode == 2u) {
                // Film Grain (based on physical pixel coords, DPI-invariant). XOR frame_seed
                // with instance seed for per-frame pattern variation.
                n = film_grain(input.screen_pos, noise_seed ^ (uniforms.frame_seed & 0xFFu));
            }
            float ni = inst.noise_intensity;
            fill = clamp(fill + float4(n * ni, n * ni, n * ni, 0.0), float4(0.0,0.0,0.0,0.0), float4(1.0,1.0,1.0,1.0));
        }

        fill.a *= fill_alpha;
        fill.rgb *= fill.a;
        composite_premul(result, fill);
    }

    // 2b. Inset Shadow (atop fill).
    if (want_inset) {
        // CSS inset semantics: shadow shape = body shifted by offset; inner shadow
        // on "inside body, outside shape". offset_y > 0 -> shape down -> top edge
        // exposed (inset 0 1px 0 white = top highlight).
        float2 inset_pos = input.local_pos - shadow_offset;
        float inset_sdf = shape_sdf_basic(inst.shape_type, inset_pos, input.size, corner_radii, -1.0);
        // Inner shadow only inside shape (fill_alpha > 0), fades along inner edge.
        // blur zero is common CSS 1px hard highlight (inset 0 1px 0 ...): smoothstep
        // endpoints equal -> undefined, give AA band 1px wide fallback.
        float inset_soft = max(shadow_blur, 1.0);
        // Shifted shape exterior (sdf >= 0) full intensity, inside blur width fades
        // to 0; interior untouched. (Used to write 1 - smoothstep, whole body filled
        // with inset shadow color — white glass card became solid white.)
        float inset_a = fill_alpha * smoothstep(-inset_soft, 0.0, inset_sdf);
        float4 inset_c = inst.shadow_color;
        inset_c.a *= inset_a;
        inset_c.rgb *= inset_c.a;
        composite_premul(result, inset_c);
    }

    // 3. Border.
    if (want_border && border_alpha > 0.0) {
        float4 border = inst.border_color;
        border.a *= border_alpha;
        border.rgb *= border.a;
        composite_premul(result, border);
    }

    result *= clip_coverage;
    if (result.a < 0.001) {
        discard;
    }

    return result;
}

float4 sdf_fragment_impl(VertexOutput input, InstanceData inst, bool solid_only, bool dual_shadow_only, bool rounded_clip_only) {
    return sdf_fragment_impl_ex(input, inst, solid_only, dual_shadow_only, rounded_clip_only, true, true, true, true);
}

float4 sdf_fragment_main(VertexOutput input) : SV_Target {
    return sdf_fragment_impl(input, instances[input.instance_id], false, false, false);
}
// Layer passes of the general material (see sdf_fragment_impl_ex).
float4 sdf_body_fragment_main(VertexOutput input) : SV_Target {
    return sdf_fragment_impl_ex(input, instances[input.instance_id], false, false, false, false, true, false, false);
}
float4 sdf_inset_layer_fragment_main(VertexOutput input) : SV_Target {
    return sdf_fragment_impl_ex(input, instances[input.instance_id], false, false, false, false, false, true, false);
}
float4 sdf_border_layer_fragment_main(VertexOutput input) : SV_Target {
    return sdf_fragment_impl_ex(input, instances[input.instance_id], false, false, false, false, false, false, true);
}
// Outer shadows only, still cut out by the body's coverage.
float4 sdf_outer_shadow_fragment_main(VertexOutput input) : SV_Target {
    return sdf_fragment_impl_ex(input, instances[input.instance_id], false, false, false, true, false, false, false);
}
// Exact material specializations: eligibility fixes only these fields. All
// distance, AA, border, gradient-stop and shadow math remains the reference.
float4 sdf_linear_x_fragment_main(VertexOutput input) : SV_Target {
    InstanceData inst = instances[input.instance_id];
    inst.shape_type = 0u; inst.packed_flags = 1u; inst.shadow_color.a = 0.0;
    return sdf_fragment_impl(input, inst, false, false, false);
}
float4 sdf_linear_y_fragment_main(VertexOutput input) : SV_Target {
    InstanceData inst = instances[input.instance_id];
    inst.shape_type = 0u; inst.packed_flags = 2u; inst.shadow_color.a = 0.0;
    return sdf_fragment_impl(input, inst, false, false, false);
}
float4 sdf_inset_rect_fragment_main(VertexOutput input) : SV_Target {
    InstanceData inst = instances[input.instance_id];
    inst.shape_type = 0u; inst.packed_flags = 1u << 24u;
    // Outer shadow (shadow_blur > 0) is drawn by a following outer-shadow pass.
    return sdf_fragment_impl_ex(input, inst, false, false, false, false, true, true, true);
}
// CPU guarantees a borderless rectangle with transparent fill and one outer
// shadow. Preserve the reference math while removing unrelated material paths.
float4 sdf_shadow_ring_fragment_main(VertexOutput input) : SV_Target {
    // Per-instance shadow constants are fetched once per vertex, not for every
    // covered pixel. Reuse the solid varyings of this dedicated ring pipeline.
    InstanceData inst = (InstanceData)0;
    inst.shadow_color = input.solid_fill;
    inst.shadow_blur = input.solid_border.x;
    inst.noise_scale = input.solid_border.y;
    inst.corner_radii = input.solid_radii;
    inst.shadow_offset_x = input.solid_metrics.y;
    inst.shadow_offset_y = input.solid_metrics.z;
    inst.packed_flags = input.solid_shape & (1u << 28u);
    return sdf_fragment_impl(input, inst, false, false, false);
}
// CPU guarantees a rectangle with two outer shadows and no other material.
float4 sdf_dual_shadow_fragment_main(VertexOutput input) : SV_Target {
    InstanceData inst = (InstanceData)0;
    inst.fill_color = input.solid_fill;
    inst.shadow_color = input.solid_border;
    inst.corner_radii = input.solid_radii;
    inst.shadow_blur = input.solid_metrics.x;
    inst.shadow_offset_x = input.solid_metrics.y;
    inst.shadow_offset_y = input.solid_metrics.z;
    inst.packed_flags = 1u << 25u;
    return sdf_fragment_impl(input, inst, false, true, false);
}
float4 sdf_solid_impl(VertexOutput input, bool rectangle_only, bool rounded_clip_only) {
    InstanceData inst = (InstanceData)0;
    inst.fill_color = input.solid_fill;
    inst.border_color = input.solid_border;
    inst.corner_radii = input.solid_radii;
    inst.border_widths = input.solid_widths;
    inst.border_width = input.solid_metrics.x;
    inst.shadow_offset_x = input.solid_metrics.y;
    inst.shadow_offset_y = input.solid_metrics.z;
    inst.shape_type = rectangle_only ? 0u : input.solid_shape;
    return sdf_fragment_impl(input, inst, true, false, rounded_clip_only);
}

float4 sdf_solid_fragment_main(VertexOutput input) : SV_Target {
    return sdf_solid_impl(input, false, false);
}
float4 sdf_rounded_clip_rect_fragment_main(VertexOutput input) : SV_Target {
    return sdf_solid_impl(input, true, true);
}
float4 sdf_rect_fragment_main(VertexOutput input) : SV_Target {
    [branch] if (input.solid_shape == 99u) {
        if (input.solid_fill.a < 0.001) discard;
        return float4(input.solid_fill.rgb * input.solid_fill.a, input.solid_fill.a);
    }
    return sdf_solid_impl(input, true, false);
}

// Selected only for an unrounded, borderless solid rectangle with no shape
// mask. Retain the original distance, derivative AA, rectangle clip and discard.
float4 sdf_plain_rect_fragment_main(VertexOutput input) : SV_Target {
    [branch] if (input.solid_shape == 99u) {
        if (input.solid_fill.a < 0.001) discard;
        return float4(input.solid_fill.rgb * input.solid_fill.a, input.solid_fill.a);
    }
    float sdf = sdf_rounded_rect_4(input.local_pos, input.size, float4(0,0,0,0));
    float aa = max(sdf_aa_width(sdf), 0.5);
    float4 color = input.solid_fill;
    color.a *= aa_step(0.0, sdf, aa);
    color.rgb *= color.a;
    color *= rect_clip_alpha(sdf_clip_screen_pos(input.position.xy, input.screen_pos, uniforms.raster_clip_pos), input.rect_clip, uniforms.scale_factor);
    if (color.a < 0.001) discard;
    return color;
}
