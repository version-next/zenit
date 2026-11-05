#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; };

vertex VOut damage_clear_vertex_main(uint vid [[vertex_id]]) {
    float2 pos[3] = {
        float2(-1.0, -3.0),
        float2(3.0, 1.0),
        float2(-1.0, 1.0),
    };
    VOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    return out;
}

fragment float4 damage_clear_fragment_main() {
    return float4(0.0);
}

// Main-target frame damage: the damage rect starts as the frame's clear
// colour (the same value the full frame's load action writes).
fragment float4 damage_fill_fragment_main(constant float4& color [[buffer(0)]]) {
    return color;
}

// Main-target frame damage: the presented frame, texel for texel, under the
// whole target before the damage rect is repainted.
fragment float4 damage_copy_fragment_main(float4 pos [[position]], texture2d<float> src [[texture(0)]]) {
    return src.read(uint2(pos.xy));
}
