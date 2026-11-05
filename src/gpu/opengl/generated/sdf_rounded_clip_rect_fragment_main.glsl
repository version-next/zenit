#version 430
#extension GL_ARB_derivative_control : require
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
} _1794;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 9) flat in vec4 input_solid_widths;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6870 = vec4(0.0);
    do
    {
        vec4 _3378 = input_solid_radii * _1794.uniforms.scale_factor;
        float _3393 = input_solid_metrics.x * _1794.uniforms.scale_factor;
        bool _4276 = input_local_pos.y < 0.0;
        float _4290 = (input_local_pos.x < 0.0) ? (_4276 ? _3378.x : _3378.w) : (_4276 ? _3378.y : _3378.z);
        vec2 _4297 = (abs(input_local_pos) - input_size) + vec2(_4290);
        float _4309 = (min(max(_4297.x, _4297.y), 0.0) + length(max(_4297, vec2(0.0)))) - _4290;
        float _4524 = dFdxFine(_4309);
        float _4526 = dFdyFine(_4309);
        float _3472 = max(length(vec2(_4524, _4526)) * 0.5, 0.5);
        float _4537 = -_3472;
        float _4539 = smoothstep(_3472, _4537, _4309);
        bvec2 _4546 = bvec2(_1794.uniforms.raster_clip_pos != 0u);
        vec2 _4547 = vec2(_4546.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4546.y ? gl_FragCoord.xy.y : input_screen_pos.y);
        float _6741 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6741 = 1.0;
                break;
            }
            vec2 _4625 = abs(_4547 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1794.uniforms.scale_factor)) - ((input_rect_clip.zw * _1794.uniforms.scale_factor) * 0.5);
            float _4638 = min(max(_4625.x, _4625.y), 0.0) + length(max(_4625, vec2(0.0)));
            float _4611 = max((abs(dFdxFine(_4638)) + abs(dFdyFine(_4638))) * 0.5, 0.5);
            _6741 = smoothstep(_4611, -_4611, _4638);
            break;
        } while(false);
        vec4 _4714 = _1794.uniforms.clip_radii * _1794.uniforms.scale_factor;
        vec2 _4717 = _4547 - ((_1794.uniforms.clip_rect.xy + (_1794.uniforms.clip_rect.zw * 0.5)) * _1794.uniforms.scale_factor);
        bool _4871 = _4717.y < 0.0;
        float _4885 = (_4717.x < 0.0) ? (_4871 ? _4714.x : _4714.w) : (_4871 ? _4714.y : _4714.z);
        vec2 _4892 = (abs(_4717) - ((_1794.uniforms.clip_rect.zw * _1794.uniforms.scale_factor) * 0.5)) + vec2(_4885);
        float _4904 = (min(max(_4892.x, _4892.y), 0.0) + length(max(_4892, vec2(0.0)))) - _4885;
        float _4847 = dFdxFine(_4904);
        float _4850 = dFdyFine(_4904);
        float _4854 = max((abs(_4847) + abs(_4850)) * 0.5, 0.5);
        float _4563 = _6741 * smoothstep(_4854, -_4854, _4904);
        SPIRV_CROSS_BRANCH
        if (((true && (input_solid_metrics.x == 0.0)) && all(equal(input_solid_widths, vec4(0.0)))) && true)
        {
            float _3540 = input_solid_fill.w * _4539;
            vec4 _3555 = vec4(input_solid_fill.xyz * _3540, _3540) * _4563;
            if (_3555.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6870 = _3555;
            break;
        }
        vec4 _3566 = input_solid_widths * _1794.uniforms.scale_factor;
        float _3568 = _3566.x;
        float _3570 = _3566.y;
        float _3573 = _3566.z;
        float _3576 = _3566.w;
        float _6822 = 0.0;
        if (true && (((((_3568 + _3570) + _3573) + _3576) > 0.0) && true))
        {
            vec4 _3663 = max(_3378 - vec4(max(_3568, _3576), max(_3568, _3570), max(_3573, _3570), max(_3573, _3576)), vec4(0.0));
            vec2 _3667 = input_local_pos - vec2((_3576 - _3570) * 0.5, (_3568 - _3573) * 0.5);
            bool _5368 = _3667.y < 0.0;
            float _5382 = (_3667.x < 0.0) ? (_5368 ? _3663.x : _3663.w) : (_5368 ? _3663.y : _3663.z);
            vec2 _5389 = (abs(_3667) - max(vec2(input_size.x - ((_3570 + _3576) * 0.5), input_size.y - ((_3568 + _3573) * 0.5)), vec2(0.0))) + vec2(_5382);
            _6822 = _4539 - smoothstep(_3472, _4537, (min(max(_5389.x, _5389.y), 0.0) + length(max(_5389, vec2(0.0)))) - _5382);
        }
        else
        {
            float _6823 = 0.0;
            if (true && (_3393 > 0.0))
            {
                _6823 = _4539 - smoothstep(_3472, _4537, _4309 + _3393);
            }
            else
            {
                _6823 = 0.0;
            }
            _6822 = _6823;
        }
        vec4 _7016 = vec4(0.0);
        if (_4539 > 0.0)
        {
            float _3708 = input_solid_fill.w * _4539;
            _7016 = vec4(input_solid_fill.xyz * _3708, _3708) * 1.0;
        }
        else
        {
            _7016 = vec4(0.0);
        }
        vec4 _7017 = vec4(0.0);
        if (_6822 > 0.0)
        {
            float _3734 = input_solid_border.w * _6822;
            _7017 = _7016 + (vec4(input_solid_border.xyz * _3734, _3734) * (1.0 - _7016.w));
        }
        else
        {
            _7017 = _7016;
        }
        vec4 _3754 = _7017 * _4563;
        if (_3754.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6870 = _3754;
        break;
    } while(false);
    _entryPointOutput = _6870;
}

