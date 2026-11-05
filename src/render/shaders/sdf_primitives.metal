/// SDF Primitives Shader
///
/// Metal Shading Language SDF primitive rendering.
/// Support: rounded rects, circles, lines.
/// Features: anti-alias, shadows, gradients, glow.

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Uniforms and vertex data structures
// ============================================================================

/// Global Uniforms
struct Uniforms {
    float2 viewport_size; // Viewport size (physical pixels)
    float scale_factor; // DPI scale factor (Retina=2.0)
    uint clip_shape_kind;
    float4 clip_rect;
    float4 clip_radii; // TL, TR, BR, BL (logical px)
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_pad; // keeps the polygon arrays 16-byte aligned (cbuffer register)
    uint clip_polygon_end_points[8];
    float2 clip_polygon_points[32];
    uint frame_seed; // Per-frame increment, drives film_grain dynamic noise
    uint raster_clip_pos; // Raster pixel centers when viewport matches SDF coordinates
    // Second shape clip (shape_clip_pair.zig): kind 0 none, 1 rounded rect, 2 ellipse;
    // logical px like clip_rect. Coverage multiplies the primary shape clip's.
    float4 clip2_rect;
    float4 clip2_radii; // TL, TR, BR, BL
    uint clip2_shape_kind;
};

/// Instance data (one per primitive) - 176 bytes
struct InstanceData {
    // -- Core geometry ------------------------------------------------- offset 0
    float4 rect; // x, y, width, height (logical pixels)
    float4 rect_clip; // x, y, w, h (logical pixels); negative size = disabled
    // -- Color ----------------------------------------------------- offset 32
    float4 fill_color; // Fill color RGBA (gradient: from)
    float4 border_color; // Border color RGBA
    float4 shadow_color; // Shadow color RGBA
    float4 gradient_to_color; // Gradient end color RGBA (stop_count=0 uses this)
    float4 corner_radii; // Four corner radii: TL, TR, BR, BL
    // -- Scalar effect params -------------------------------------------- offset 112
    float border_width; // Border width
    float shadow_blur; // Shadow blur radius (outer shadow)
    float shadow_offset_x; // Shadow X offset
    float shadow_offset_y; // Shadow Y offset
    // -- Type and flags ------------------------------------------------- offset 128
    uint shape_type;          // 0=rect, 1=circle, 2=line, 3=arc
    /// packed_flags layout:
    ///   bit 0-7:  gradient_direction (0=none,1=vert,2=horiz,3=diag,4=radial,5=conic)
    ///   bit 8-15: noise_mode (0=none, 1=value, 2=film_grain)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:   inset_shadow
    ///   bit 25:   has_shadow2
    uint packed_flags;
    float noise_scale; // Noise scale (logical pixel units, 0=disabled)
    float noise_intensity; // Noise blend strength [0..1]
    // ── Per-side border ──────────────────────────────── offset 144
    float4 border_widths; // Per-side: top, right, bottom, left; all zero=use border_width
    // -- Multi-color gradient / dual shadow index ----------------------- offset 160
    uint gradient_stop_offset; // GradientStop buffer start index (ignored when stop_count=0)
    uint gradient_stop_count; // Stop count (0 = use legacy two-color fill/gradient_to_color)
    uint shadow2_index; // Second shadow index in ShadowParam buffer
    uint _ext_reserved; // Reserved extension
};

/// Vertex output
struct VertexOutput {
    float4 position [[position]];
    float2 local_pos; // Position relative to primitive center
    float2 size; // Primitive size half
    float2 uv; // Normalized coordinate (0-1)
    float2 screen_pos; // Current fragment physical pixel coordinate
    float4 rect_clip;
    uint instance_id;
};

// ============================================================================
// Procedural noise functions
// ============================================================================

/// Wang hash - fast integer hash
uint hash_wang(uint x) {
    x = (x ^ 61u) ^ (x >> 16u);
    x = x + (x << 3u);
    x = x ^ (x >> 4u);
    x = x * 0x27d4eb2du;
    x = x ^ (x >> 15u);
    return x;
}

/// 2D integer coordinate -> [0,1] float hash
float hash2d(float2 p) {
    uint ix = uint(abs(p.x) * 1000.0);
    uint iy = uint(abs(p.y) * 1000.0);
    return float(hash_wang(ix ^ hash_wang(iy * 2654435761u))) / 4294967295.0;
}

/// Value Noise: bilinear interpolated grid noise.
/// p: local coordinate (logical pixels), scale: grid spacing, seed: instance seed
float value_noise(float2 p, float scale, uint seed) {
    float2 sp = p / max(scale, 0.001) + float2(float(seed) * 17.3, float(seed) * 31.7);
    float2 i = floor(sp);
    float2 f = fract(sp);
    float2 u = f * f * (3.0 - 2.0 * f); // Hermite smooth interpolation
    float a = hash2d(i);
    float b = hash2d(i + float2(1.0, 0.0));
    float c = hash2d(i + float2(0.0, 1.0));
    float d = hash2d(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Film Grain: high-freq grain noise from physical pixel coordinate.
/// screen_pos: physical pixel coordinate, seed: instance seed
float film_grain(float2 screen_pos, uint seed) {
    return hash2d(floor(screen_pos) + float2(float(seed & 255u) * 3.7, float((seed >> 8u) & 255u) * 5.1)) - 0.5;
}

// ============================================================================
// Multi-color gradient
// ============================================================================

/// GradientStop: multi-color gradient stop (buffer slot 2)
struct GradientStop {
    float4 color;    // RGBA linear
    float  position; // [0.0, 1.0]
    float  _pad0;
    float  _pad1;
    float  _pad2;
    // 32 bytes per stop
};

// ============================================================================
// Bayer ordered dithering (Blend2D inspired)
// ============================================================================
//
// 16x16 Bayer matrix, range [0, 255], compile-time constant.
// Adds a sub-pixel offset before gradient write to the 8-bit framebuffer,
// eliminating color banding.
// Reference: Blend2D fetchgradientpart.cpp GradientDitheringContext
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

/// Extract Bayer threshold from physical pixel coord, normalize to [-0.5/255, +0.5/255].
/// Apply sub-pixel dither before gradient color write.
inline float bayer_dither(float2 screen_pos) {
    uint ix = uint(screen_pos.x) & 15u;
    uint iy = uint(screen_pos.y) & 15u;
    return (float(bayer_16x16[iy * 16u + ix]) - 127.5) / 65025.0; // ÷(255×255) preserves energy conservation
}

// ============================================================================
// Multi-color gradient
// ============================================================================

/// Premultiplied alpha helper (Blend2D inspired).
/// Gradient interpolation in premul space, avoid color shift between semi-transparent stops.
inline float4 premul(float4 c)   { return float4(c.rgb * c.a, c.a); }
inline float4 unpremul(float4 c) {
    return c.a > 1e-6 ? float4(c.rgb / c.a, c.a) : float4(0.0);
}

/// Evaluate multi-color gradient (premul alpha interpolation, stops must be position-sorted).
float4 eval_gradient_stops(float t, constant GradientStop* stops, uint offset, uint count) {
    if (count == 0u) return float4(0.0);
    if (count > 16u) return float4(1.0, 0.0, 1.0, 1.0); // Magenta = parameter error (count limit 16)
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
            // Premul space interpolation: avoid RGB shift between semi-transparent stops.
            float4 result_premul = mix(premul(s0.color), premul(s1.color), lt);
            return unpremul(result_premul);
        }
    }
    return stops[offset + count - 1u].color;
}

// ============================================================================
// Multiple shadows
// ============================================================================

/// ShadowParam: second shadow params (buffer slot 3)
struct ShadowParam {
    float4 color;
    float  blur;
    float  offset_x;
    float  offset_y;
    float  _pad;
    // 32 bytes
};

// ============================================================================
// SDF functions
// ============================================================================

/// SDF rounded rect (uniform radius)
float sdf_rounded_rect(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - radius;
}

float sdf_ellipse_clip(float2 p, float2 radius_xy) {
    float2 q = p / max(radius_xy, float2(0.001));
    return length(q) - 1.0;
}

/// Ellipse SDF -- **returns true pixel distance** (1st-order Newton estimate of the
/// normalized gradient).
///
/// WARNING: do not reuse sdf_ellipse_clip above; it returns a **dimensionless**
/// `length(p/r)-1`, valid only for clipping (shape_clip_alpha self-normalizes via fwidth).
/// AA width from sdf_aa_width(sdf) has a 0.5 **pixel** floor, so a dimension mismatch makes
/// the AA band off by tens of times (edges hard-aliased or blurred to mush).
///
/// Also avoid (length(p/r)-1) * min(rx,ry) (path.metal style): on a 10:1 ellipse the major
/// endpoint reads 1/10 of the true distance and AA is 10x too wide at the flat end; a 2:1
/// ellipse stroke is already 2x thicker on one edge (abs(sdf)-type stroke 2.0px->4.0px).
///
/// Ellipse has no closed-form SDF; use implicit f=|p/r|-1 divided by gradient magnitude.
/// Near edges (where AA/stroke apply) error is 0.2-2.4%; 10:1 extreme worst 8%, imperceptible.
float sdf_ellipse(float2 p, float2 radius_xy) {
    const float2 r = max(radius_xy, float2(0.001));
    const float2 q = p / r;
    const float k = length(q);
    // Center: zero gradient, degenerates to 'shortest semi-axis to boundary' distance.
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

/// SDF rounded rect (four independent corner radii).
/// radii: top-left, top-right, bottom-right, bottom-left
float sdf_rounded_rect_4(float2 p, float2 size, float4 radii) {
    // Pick radius by quadrant
    float r = (p.x < 0.0)
        ? ((p.y < 0.0) ? radii.x : radii.w) // Left: TL / BL
        : ((p.y < 0.0) ? radii.y : radii.z); // Right: TR / BR
    float2 d = abs(p) - size + r;
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0))) - r;
}

/// SDF circle
float sdf_circle(float2 p, float radius) {
    return length(p) - radius;
}

/// SDF line (capsule)
float sdf_line(float2 p, float2 a, float2 b, float thickness) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - thickness;
}

/// SDF arc (ring segment).
/// p: position relative to center.
/// outer_radius: outer radius.
/// stroke_width: line width.
/// start_angle: start angle (radians, arbitrary, no normalization needed).
/// end_angle: end angle (radians, end >= start, sweep = end - start).
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
    float sweep = clamp(end_angle - start_angle, 0.0, 2.0 * M_PI_F);

    // sweep >= 2pi: full ring, return directly
    if (sweep >= 2.0 * M_PI_F - 0.0001) {
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
    rel = rel - floor(rel / (2.0 * M_PI_F)) * (2.0 * M_PI_F);

    return rel <= sweep ? max(ring_sdf, -cap) : cap;
}

// ============================================================================
// Anti-aliasing functions
// ============================================================================

float aa_step(float edge, float x, float aa_width) {
    return smoothstep(edge + aa_width, edge - aa_width, x);
}

// sdf-clip-shared-begin (also generated into HLSL)
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
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}
// sdf-clip-shared-end

float primary_shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
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

float partner_shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    if (uniforms.clip2_shape_kind == 0u) {
        return 1.0;
    }
    const float2 clip_center = (uniforms.clip2_rect.xy + uniforms.clip2_rect.zw * 0.5) * uniforms.scale_factor;
    const float2 clip_size = uniforms.clip2_rect.zw * uniforms.scale_factor * 0.5;
    const float clip_sdf = uniforms.clip2_shape_kind == 2u
        ? sdf_ellipse_clip(screen_pos - clip_center, clip_size)
        : sdf_rounded_rect_4(screen_pos - clip_center, clip_size, uniforms.clip2_radii * uniforms.scale_factor);
    const float clip_aa = max(fwidth(clip_sdf) * 0.5, 0.5);
    return smoothstep(clip_aa, -clip_aa, clip_sdf);
}

float shape_clip_alpha(float2 screen_pos, constant Uniforms& uniforms) {
    return primary_shape_clip_alpha(screen_pos, uniforms) * partner_shape_clip_alpha(screen_pos, uniforms);
}

float clip_alpha(float2 screen_pos, float4 rect_clip, constant Uniforms& uniforms) {
    return rect_clip_alpha(screen_pos, rect_clip, uniforms.scale_factor) * shape_clip_alpha(screen_pos, uniforms);
}

/// Fill AA half-width (pixels): half the SDF's screen-space gradient magnitude.
/// Coverage is 1 at 0.5px inside the edge and 0 at 0.5px outside, so adjacent rects on integer
/// boundaries are seamless. Do not use `length(float2(dfdx(local.x), dfdy(local.y)))`: the
/// diagonal widens the AA band on axis-aligned edges by sqrt(2) (to 0.707px), so pixels next to
/// integer edges get only ~94% coverage and a dark seam shows between adjacent rects (measured
/// 255->242 on a Windows device with a 4px stripe background).
float sdf_aa_width(float sdf) {
    return length(float2(dfdx(sdf), dfdy(sdf))) * 0.5;
}

// Src-over premultiplied alpha composite
inline void composite_premul(thread float4& dst, float4 src) {
    dst += src * (1.0 - dst.a);
}

// ============================================================================
// Vertex shader
// ============================================================================

// kRing: shadow-only instances emit '4 rects (24 verts) = expanded quad minus inner hole'.
// Hole = body shrunk (max radius + 2 physical px): body SDF <= -2px inside, fill coverage
// is constant 1, shadow * (1 - fill_alpha) = 0, so output is already zero. kClip: clamp quad
// verts into rect_clip expanded by 2 physical px. rect_clip_alpha AA band
// clip_aa = max(fwidth(sdf)*0.5, 0.5) <= 0.71px, so pixels >0.71px outside the clip have
// alpha 0; affine in screen coords, clamping verts does not change kept pixels.
template <bool kRing, bool kClip>
inline VertexOutput sdf_vertex_impl(
    uint vertex_id,
    uint instance_id,
    constant Uniforms& uniforms,
    constant InstanceData* instances,
    constant ShadowParam* shadow_params
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
    uint corner_index = indices[kRing ? vertex_id % 6u : vertex_id];
    float2 corner = corners[corner_index];

    // Instance coords logical pixels, multiply by scale_factor to physical pixels.
    float s = uniforms.scale_factor;

    // Arcs carry their start / end angles in the shadow offset slots and draw no shadow:
    // their quad is the ring's bounds (growing angles must not stretch it).
    float expand = inst.shape_type == 3u ? 0.0 : inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
    // bit 28: outer shadow has spread (noise_scale reused), positive spread expands quad.
    if ((inst.packed_flags & (1u << 28u)) != 0u) expand += max(inst.noise_scale, 0.0);
    // Dual shadow: quad must cover whichever layer has larger expansion, else second shadow's
    // large blur gets hard-cut at quad edge (bright rect rim around panel).
    if ((inst.packed_flags & (1u << 25u)) != 0u) {
        ShadowParam s2v = shadow_params[inst.shadow2_index];
        float expand2 = s2v.blur * 2.0 + abs(s2v.offset_x) + abs(s2v.offset_y);
        expand = max(expand, expand2);
    }

    float2 pos = (inst.rect.xy - expand) * s;
    float2 size = (inst.rect.zw + expand * 2.0) * s;
    float2 pixel_pos = pos + corner * size;
    if (kRing) {
        float radius = max(max(inst.corner_radii.x, inst.corner_radii.y),
                           max(inst.corner_radii.z, inst.corner_radii.w)) * s;
        float2 half_size = inst.rect.zw * s * 0.5;
        float2 body_center = inst.rect.xy * s + half_size;
        float2 inner_half = max(half_size - max(radius, 0.0) - 2.0, float2(0.0));
        float2 lo = body_center - inner_half;
        float2 hi = body_center + inner_half;
        float2 tile_lo = pos;
        float2 tile_hi = pos + size;
        switch (vertex_id / 6u) {
            case 0: tile_hi.x = lo.x; break; // Left stripe
            case 1: tile_lo.x = hi.x; break; // Right stripe
            case 2: tile_lo.x = lo.x; tile_hi = float2(hi.x, lo.y); break; // Top stripe
            default: tile_lo = float2(lo.x, hi.y); tile_hi.x = hi.x; break; // Bottom stripe
        }
        pixel_pos = mix(tile_lo, tile_hi, corner);
    }
    if (kClip && inst.rect_clip.z >= 0.0 && inst.rect_clip.w >= 0.0) {
        float2 clip_lo = inst.rect_clip.xy * s - 2.0;
        float2 clip_hi = (inst.rect_clip.xy + inst.rect_clip.zw) * s + 2.0;
        pixel_pos = clamp(pixel_pos, clip_lo, clip_hi);
    }

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

vertex VertexOutput sdf_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant InstanceData* instances [[buffer(1)]],
    constant ShadowParam* shadow_params [[buffer(3)]]
) {
    return sdf_vertex_impl<false, false>(vertex_id, instance_id, uniforms, instances, shadow_params);
}

vertex VertexOutput sdf_clipped_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant InstanceData* instances [[buffer(1)]],
    constant ShadowParam* shadow_params [[buffer(3)]]
) {
    return sdf_vertex_impl<false, true>(vertex_id, instance_id, uniforms, instances, shadow_params);
}

vertex VertexOutput sdf_shadow_ring_vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant Uniforms& uniforms [[buffer(0)]],
    constant InstanceData* instances [[buffer(1)]],
    constant ShadowParam* shadow_params [[buffer(3)]]
) {
    return sdf_vertex_impl<true, true>(vertex_id, instance_id, uniforms, instances, shadow_params);
}

// ============================================================================
// Fragment shader
// ============================================================================

// Fragment body is a template: specialization passes compile-time constants and the compiler
// inlines and deletes unreachable branches. Distance / AA / stroke / shadow / composite math
// shares code with the general path; the CPU side (SdfRenderer.metalKind) selects a
// specialization only when the runtime branch is already false, so per-pixel output is identical.
//   kGeneral    : non-rect shapes, gradient/noise/inset shadow/shadow2
//   kBorder     : stroke (uniform or per-side)
//   kShadow     : outer shadow
//   kShadowOnly : transparent fill, shadow-only: body interior shadow * (1-fill_alpha) = 0,
//                 result is discarded anyway, early exit.
template <bool kGeneral, bool kBorder, bool kShadow, bool kShadowOnly>
inline float4 sdf_fragment_impl(
    VertexOutput in,
    constant Uniforms& uniforms,
    constant InstanceData* instances,
    constant GradientStop* grad_stops,
    constant ShadowParam* shadow_params
) {
    InstanceData inst = instances[in.instance_id];
    const float s = uniforms.scale_factor;
    const float4 corner_radii = inst.corner_radii * s;
    const float corner_radius_max = max(max(corner_radii.x, corner_radii.y), max(corner_radii.z, corner_radii.w));
    const float border_width = inst.border_width * s;
    const float shadow_blur = inst.shadow_blur * s;
    const float2 shadow_offset = float2(inst.shadow_offset_x, inst.shadow_offset_y) * s;

    float sdf;

    if (!kGeneral) {
        sdf = sdf_rounded_rect_4(in.local_pos, in.size, corner_radii);
    } else switch (inst.shape_type) {
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
            // arc: corner_radii.x = outer_radius, border_width = line_width.
            //      shadow_offset_x = start_angle(radians), shadow_offset_y = end_angle(radians)
            sdf = sdf_arc(
                in.local_pos,
                corner_radii.x,
                inst.border_width * s,
                inst.shadow_offset_x,
                inst.shadow_offset_y
            );
            break;
        case 4:
            // ellipse: in.size is semi-axes (same convention as sdf_rounded_rect_4)
            sdf = sdf_ellipse(in.local_pos, in.size);
            break;
        default:
            sdf = 1.0;
            break;
    }

    // Floor 0.5: SDF gradient discontinuous on shape centerline (quad diff can collapse to 0),
    // cannot let band collapse to zero.
    float aa_width = max(sdf_aa_width(sdf), 0.5);

    float fill_alpha = aa_step(0.0, sdf, aa_width);
    // Clip alpha uses screen-space derivative (rect_clip_alpha fwidth): must evaluate with
    // all 2x2 quad pixels alive. Early-exit entries pre-compute, result shared at end.
    const float early_clip = kShadowOnly ? clip_alpha(in.screen_pos, in.rect_clip, uniforms) : 1.0;
    if (kShadowOnly && fill_alpha >= 1.0) {
        // Keep discard: large interior area, write 0 then blend costs more (measured +10%).
        discard_fragment();
        return float4(0.0);
    }

    float border_alpha = 0.0;
    float4 bw = inst.border_widths * s;
    // WARNING: the per-side branch hard-codes sdf_rounded_rect_4 and draws 'rect stroke over
    // ellipse fill' for non-rects. Ellipse has no 'four edges', so per-side is meaningless:
    // gate it here and use the uniform fast path (`sdf + border_width`, shape-agnostic).
    // Zig side addEllipse folds the four values to `border_width = max(...)`, not the first:
    // {0,0,0,4} would silently become 0-width.
    bool has_per_side = kBorder && (bw.x + bw.y + bw.z + bw.w) > 0.0 && inst.shape_type == 0u;

    if (has_per_side) {
        // Per-side border: compute inner SDF.
        // bw = (top, right, bottom, left)
        float2 inner_half = float2(
            in.size.x - (bw.y + bw.w) * 0.5,
            in.size.y - (bw.x + bw.z) * 0.5
        );
        inner_half = max(inner_half, float2(0.0));

        // Asymmetric border shifts inner rect center
        float2 inner_offset = float2(
            (bw.w - bw.y) * 0.5,
            (bw.x - bw.z) * 0.5
        );

        // Inner radius = max(0, outer - max(adjacent widths))
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
    } else if (kBorder && border_width > 0.0) {
        // Uniform border: fast path
        float inner_sdf = sdf + border_width;
        border_alpha = aa_step(0.0, sdf, aa_width) - aa_step(0.0, inner_sdf, aa_width);
    }

    float shadow_alpha = 0.0;
    if (kShadow && shadow_blur > 0.0) {
        float2 shadow_pos = in.local_pos - shadow_offset;
        float shadow_sdf;
        // CSS spread: shadow shape expands/shrinks by spread (corner follows), hole per body.
        const bool has_spread = (inst.packed_flags & (1u << 28u)) != 0u;
        const float spread = has_spread ? inst.noise_scale * s : 0.0;
        const float2 shadow_half = max(in.size + spread, float2(0.0));
        const float4 shadow_radii = max(corner_radii + spread, float4(0.0));

        if (!kGeneral) {
            shadow_sdf = sdf_rounded_rect_4(shadow_pos, shadow_half, shadow_radii);
        } else switch (inst.shape_type) {
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

    // -- Unpack packed_flags --
    uint gradient_dir  = kGeneral ? (inst.packed_flags & 0xFFu) : 0u;
    uint noise_mode    = kGeneral ? ((inst.packed_flags >> 8u)  & 0xFFu) : 0u;
    uint noise_seed    = (inst.packed_flags >> 16u) & 0xFFu;
    bool has_inset_shad = kGeneral && (inst.packed_flags & (1u << 24u)) != 0u;
    bool has_shadow2    = kGeneral && (inst.packed_flags & (1u << 25u)) != 0u;

    float4 result = float4(0.0);

    // 1. Outer shadow
    if (shadow_alpha > 0.0) {
        float4 shadow = inst.shadow_color;
        shadow.a *= shadow_alpha;
        shadow.rgb *= shadow.a;
        composite_premul(result, shadow);
    }

    // 1b. Second outer shadow (has_shadow2)
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

    // 2. Fill (gradient + noise)
    if (fill_alpha > 0.0) {
        // -- Gradient t value calc --
        float4 fill = inst.fill_color;
        if (gradient_dir > 0u) {
            float t = 0.0;

            if (gradient_dir == 4u) {
                // Radial gradient: use raw UV, no shadow expand.
                // shadow_offset_x/y reused as center offset (UV space, default 0,0=center 0.5,0.5).
                float2 center_uv = float2(0.5 + inst.shadow_offset_x, 0.5 + inst.shadow_offset_y);
                // bit 29: custom ellipse radii (UV units; CSS radial-gradient(rx ry at cx cy)).
                if ((inst.packed_flags & (1u << 29u)) != 0u) {
                    float2 rr = max(float2(inst.noise_scale, inst.noise_intensity), float2(1e-4));
                    t = length((in.uv - center_uv) / rr);
                } else {
                    t = length(in.uv - center_uv) * 2.0;
                }
            } else if (gradient_dir == 5u) {
                // Conic gradient: use raw UV, no shadow expand.
                // _ext_reserved reused as start angle (bitcast float, radians).
                float start_angle = as_type<float>(inst._ext_reserved);
                float angle = atan2(in.uv.y - 0.5, in.uv.x - 0.5) - start_angle;
                t = fract(angle / (2.0 * M_PI_F) + 0.5);
            } else {
                // Linear gradient (vert/horiz/diag): same quad expansion as the vertex stage.
                float expand = inst.shape_type == 3u ? 0.0 : inst.shadow_blur * 2.0 + abs(inst.shadow_offset_x) + abs(inst.shadow_offset_y);
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
                t = fract(t); // REPEAT: loop tile
            } else if (extend_mode == 2u) {
                float t2 = fmod(abs(t), 2.0);
                t = (t2 > 1.0) ? (2.0 - t2) : t2; // REFLECT: mirror reflect
            } else {
                t = clamp(t, 0.0, 1.0); // PAD (default): clamp to edge color
            }

            // Multi-color gradient (stop_count > 0) or legacy two-color mode
            if (inst.gradient_stop_count > 0u) {
                fill = eval_gradient_stops(t, grad_stops, inst.gradient_stop_offset, inst.gradient_stop_count);
            } else {
                // Legacy two-color also interpolates in premul space
                float4 from_p = premul(inst.fill_color);
                float4 to_p   = premul(inst.gradient_to_color);
                fill = unpremul(mix(from_p, to_p, t));
            }

            // Bayer ordered dither: eliminate 8-bit framebuffer color banding.
            // Apply sub-pixel offset to RGB only, alpha unchanged.
            float dither = bayer_dither(in.screen_pos);
            fill.rgb = saturate(fill.rgb + dither);
        }

        // -- Procedural noise overlay --
        if (noise_mode > 0u && inst.noise_scale > 0.0) {
            float n = 0.0;
            float ns = inst.noise_scale * s; // Convert to physical pixels
            if (noise_mode == 1u) {
                // Value Noise (logical-coord based, scale-adaptive)
                n = value_noise(in.local_pos / s, ns / s, noise_seed) - 0.5;
            } else if (noise_mode == 2u) {
                // Film Grain (physical-pixel based, DPI-agnostic).
                // XOR frame_seed with instance seed for different per-frame patterns.
                n = film_grain(in.screen_pos, noise_seed ^ (uniforms.frame_seed & 0xFFu));
            }
            float ni = inst.noise_intensity;
            fill = clamp(fill + float4(n * ni, n * ni, n * ni, 0.0), float4(0.0), float4(1.0));
        }

        fill.a *= fill_alpha;
        fill.rgb *= fill.a;
        composite_premul(result, fill);
    }

    // 2b. Inset Shadow (atop fill)
    if (has_inset_shad && fill_alpha > 0.0) {
        // CSS inset semantics: shadow shape = body offset. Inset shadow in 'body interior and
        // outside shape'. offset_y > 0 -> shape down -> top edge exposed (inset 0 1px 0 white =
        // highlight).
        float2 inset_pos = in.local_pos - shadow_offset;
        float inset_sdf;
        switch (inst.shape_type) {
            case 0: inset_sdf = sdf_rounded_rect_4(inset_pos, in.size, corner_radii); break;
            case 1: inset_sdf = sdf_circle(inset_pos, min(in.size.x, in.size.y));     break;
            case 4: inset_sdf = sdf_ellipse(inset_pos, in.size);                  break;
            default: inset_sdf = -1.0; break;
        }
        // Inset shadow only where fill_alpha > 0, fade along inner boundary.
        // blur=0 is common CSS 1px hard highlight (inset 0 1px 0 ...): smoothstep endpoints
        // equal is undefined, floor to 1px AA band.
        float inset_soft = max(shadow_blur, 1.0);
        // Offset-shifted shape outside (sdf >= 0) full strength, blur distance inward to 0;
        // deep interior nothing. (Was 1 - smoothstep: entire body filled shadow color -- white
        // glass card became solid white.)
        float inset_a = fill_alpha * smoothstep(-inset_soft, 0.0, inset_sdf);
        float4 inset_c = inst.shadow_color;
        inset_c.a *= inset_a;
        inset_c.rgb *= inset_c.a;
        composite_premul(result, inset_c);
    }

    // 3. Border
    if (border_alpha > 0.0) {
        float4 border = inst.border_color;
        border.a *= border_alpha;
        border.rgb *= border.a;
        composite_premul(result, border);
    }

    result *= kShadowOnly ? early_clip : clip_alpha(in.screen_pos, in.rect_clip, uniforms);
    if (result.a < 0.001) {
        // Under premul blend, output all 0 leaves dst unchanged, bitwise equivalent to discard.
        // fill/bordered entries skip discard (measured -5%); shadow-only already discards body
        // interior, whole pipeline has discard, keep it.
        if (!kGeneral && !kShadowOnly) return float4(0.0);
        discard_fragment();
    }

    return result;
}

fragment float4 sdf_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms        [[buffer(0)]],
    constant InstanceData* instances   [[buffer(1)]],
    constant GradientStop* grad_stops  [[buffer(2)]],
    constant ShadowParam* shadow_params[[buffer(3)]]
) {
    return sdf_fragment_impl<true, true, true, false>(in, uniforms, instances, grad_stops, shadow_params);
}

// Rect + solid fill (with radii), no stroke/shadow/flags. ~70% of real UI SDF fragments.
fragment float4 sdf_fill_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms        [[buffer(0)]],
    constant InstanceData* instances   [[buffer(1)]],
    constant GradientStop* grad_stops  [[buffer(2)]],
    constant ShadowParam* shadow_params[[buffer(3)]]
) {
    return sdf_fragment_impl<false, false, false, false>(in, uniforms, instances, grad_stops, shadow_params);
}

// Rect + fill + stroke (uniform/per-side), no shadow/flags.
fragment float4 sdf_bordered_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms        [[buffer(0)]],
    constant InstanceData* instances   [[buffer(1)]],
    constant GradientStop* grad_stops  [[buffer(2)]],
    constant ShadowParam* shadow_params[[buffer(3)]]
) {
    return sdf_fragment_impl<false, true, false, false>(in, uniforms, instances, grad_stops, shadow_params);
}

// Rect, transparent fill, no stroke, outer shadow (can add spread).
fragment float4 sdf_shadow_only_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms& uniforms        [[buffer(0)]],
    constant InstanceData* instances   [[buffer(1)]],
    constant GradientStop* grad_stops  [[buffer(2)]],
    constant ShadowParam* shadow_params[[buffer(3)]]
) {
    return sdf_fragment_impl<false, false, true, true>(in, uniforms, instances, grad_stops, shadow_params);
}
