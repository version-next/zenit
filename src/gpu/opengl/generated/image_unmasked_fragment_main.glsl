#version 430
#extension GL_ARB_derivative_control : require

struct Uniforms
{
    vec2 viewport_size;
    float scale_factor;
    uint clip_shape_kind;
    vec4 clip_rect;
    vec4 clip_radii;
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uint clip_pad;
    uvec4 clip_polygon_end_points[2];
    vec4 clip_polygon_points[16];
};

layout(binding = 0, std140) uniform ImageParams
{
    Uniforms uniforms;
} _812;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedimage_textureimage_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in vec4 input_tint_color;
layout(location = 6) flat in vec2 input_material;
layout(location = 7) flat in vec4 input_corner_radii;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _1146 = input_corner_radii * _812.uniforms.scale_factor;
    vec4 _1152 = texture(SPIRV_Cross_Combinedimage_textureimage_sampler, input_uv);
    vec4 _1156 = _1152 * input_tint_color;
    float _2282 = 0.0;
    if (any(greaterThan(_1146, vec4(0.0))))
    {
        bool _1238 = input_local_pos.y < 0.0;
        float _1252 = (input_local_pos.x < 0.0) ? (_1238 ? _1146.x : _1146.w) : (_1238 ? _1146.y : _1146.z);
        vec2 _1266 = (abs(input_local_pos) - input_size) + vec2(_1252);
        float _1278 = (min(max(_1266.x, _1266.y), 0.0) + length(max(_1266, vec2(0.0)))) - _1252;
        float _1173 = abs(dFdxFine(_1278)) + abs(dFdyFine(_1278));
        _2282 = smoothstep(_1173 * 0.5, _1173 * (-0.5), _1278);
    }
    else
    {
        _2282 = 1.0;
    }
    float _2239 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2239 = 1.0;
            break;
        }
        vec2 _1356 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _812.uniforms.scale_factor)) - ((input_rect_clip.zw * _812.uniforms.scale_factor) * 0.5);
        float _1369 = min(max(_1356.x, _1356.y), 0.0) + length(max(_1356, vec2(0.0)));
        float _1342 = max((abs(dFdxFine(_1369)) + abs(dFdyFine(_1369))) * 0.5, 0.5);
        _2239 = smoothstep(_1342, -_1342, _1369);
        break;
    } while(false);
    float _1194 = (_2282 * _2239) * input_material.x;
    vec4 _2379 = vec4(0.0);
    if (input_material.y > 0.5)
    {
        _2379 = _1156 * _1194;
    }
    else
    {
        float _1206 = _1156.w * _1194;
        _2379 = vec4(_1156.xyz * _1206, _1206);
    }
    if (_2379.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _2379;
}

