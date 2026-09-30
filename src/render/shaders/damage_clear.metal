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
