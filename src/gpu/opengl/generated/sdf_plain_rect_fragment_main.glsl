#version 430
#if defined(GL_EXT_control_flow_attributes)
#extension GL_EXT_control_flow_attributes : require
#define SPIRV_CROSS_FLATTEN [[flatten]]
#define SPIRV_CROSS_BRANCH [[dont_flatten]]
#define SPIRV_CROSS_UNROLL [[unroll]]
#define SPIRV_CROSS_LOOP [[dont_unroll]]
#else
#define SPIRV_CROSS_FLATTEN
#define SPIRV_CROSS_BRANCH
#define SPIRV_CROSS_UNROLL
#define SPIRV_CROSS_LOOP
#endif
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
    uint frame_seed;
    uint raster_clip_pos;
};

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _288;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _956 = vec4(0.0);
    do
    {
        SPIRV_CROSS_BRANCH
        if (input_solid_shape == 99u)
        {
            if (input_solid_fill.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _956 = vec4(input_solid_fill.xyz * input_solid_fill.w, input_solid_fill.w);
            break;
        }
        vec2 _785 = abs(input_local_pos) - input_size;
        float _798 = min(max(_785.x, _785.y), 0.0) + length(max(_785, vec2(0.0)));
        float _804 = dFdxFine(_798);
        float _806 = dFdyFine(_798);
        float _713 = max(length(vec2(_804, _806)) * 0.5, 0.5);
        float _721 = input_solid_fill.w * smoothstep(_713, -_713, _798);
        bvec2 _826 = bvec2(_288.uniforms.raster_clip_pos != 0u);
        float _955 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _955 = 1.0;
                break;
            }
            vec2 _889 = abs(vec2(_826.x ? gl_FragCoord.xy.x : input_screen_pos.x, _826.y ? gl_FragCoord.xy.y : input_screen_pos.y) - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _288.uniforms.scale_factor)) - ((input_rect_clip.zw * _288.uniforms.scale_factor) * 0.5);
            float _902 = min(max(_889.x, _889.y), 0.0) + length(max(_889, vec2(0.0)));
            float _875 = max((abs(dFdxFine(_902)) + abs(dFdyFine(_902))) * 0.5, 0.5);
            _955 = smoothstep(_875, -_875, _902);
            break;
        } while(false);
        vec4 _748 = vec4(input_solid_fill.xyz * _721, _721) * _955;
        if (_748.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _956 = _748;
        break;
    } while(false);
    _entryPointOutput = _956;
}

