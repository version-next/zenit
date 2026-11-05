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
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6935 = vec4(0.0);
    do
    {
        SPIRV_CROSS_BRANCH
        if (input_solid_shape == 99u)
        {
            if (input_solid_fill.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6935 = vec4(input_solid_fill.xyz * input_solid_fill.w, input_solid_fill.w);
            break;
        }
        vec4 _6934 = vec4(0.0);
        do
        {
            vec4 _3435 = input_solid_radii * _1794.uniforms.scale_factor;
            float _3450 = input_solid_metrics.x * _1794.uniforms.scale_factor;
            bool _4333 = input_local_pos.y < 0.0;
            float _4347 = (input_local_pos.x < 0.0) ? (_4333 ? _3435.x : _3435.w) : (_4333 ? _3435.y : _3435.z);
            vec2 _4354 = (abs(input_local_pos) - input_size) + vec2(_4347);
            float _4366 = (min(max(_4354.x, _4354.y), 0.0) + length(max(_4354, vec2(0.0)))) - _4347;
            float _4581 = dFdxFine(_4366);
            float _4583 = dFdyFine(_4366);
            float _3529 = max(length(vec2(_4581, _4583)) * 0.5, 0.5);
            float _4594 = -_3529;
            float _4596 = smoothstep(_3529, _4594, _4366);
            bvec2 _4603 = bvec2(_1794.uniforms.raster_clip_pos != 0u);
            vec2 _4604 = vec2(_4603.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4603.y ? gl_FragCoord.xy.y : input_screen_pos.y);
            float _6805 = 0.0;
            do
            {
                if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
                {
                    _6805 = 1.0;
                    break;
                }
                vec2 _4682 = abs(_4604 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1794.uniforms.scale_factor)) - ((input_rect_clip.zw * _1794.uniforms.scale_factor) * 0.5);
                float _4695 = min(max(_4682.x, _4682.y), 0.0) + length(max(_4682, vec2(0.0)));
                float _4668 = max((abs(dFdxFine(_4695)) + abs(dFdyFine(_4695))) * 0.5, 0.5);
                _6805 = smoothstep(_4668, -_4668, _4695);
                break;
            } while(false);
            float _6845 = 0.0;
            do
            {
                if (_1794.uniforms.clip_shape_kind == 0u)
                {
                    _6845 = 1.0;
                    break;
                }
                vec2 _4755 = (_1794.uniforms.clip_rect.xy + (_1794.uniforms.clip_rect.zw * 0.5)) * _1794.uniforms.scale_factor;
                vec2 _4762 = (_1794.uniforms.clip_rect.zw * _1794.uniforms.scale_factor) * 0.5;
                float _6843 = 0.0;
                if (_1794.uniforms.clip_shape_kind == 1u)
                {
                    vec4 _4771 = _1794.uniforms.clip_radii * _1794.uniforms.scale_factor;
                    vec2 _4774 = _4604 - _4755;
                    bool _4928 = _4774.y < 0.0;
                    float _4942 = (_4774.x < 0.0) ? (_4928 ? _4771.x : _4771.w) : (_4928 ? _4771.y : _4771.z);
                    vec2 _4949 = (abs(_4774) - _4762) + vec2(_4942);
                    _6843 = (min(max(_4949.x, _4949.y), 0.0) + length(max(_4949, vec2(0.0)))) - _4942;
                }
                else
                {
                    float _6844 = 0.0;
                    if (_1794.uniforms.clip_shape_kind == 2u)
                    {
                        _6844 = length((_4604 - _4755) / max(_4762, vec2(0.001000000047497451305389404296875))) - 1.0;
                    }
                    else
                    {
                        if (_1794.uniforms.clip_shape_kind == 3u)
                        {
                            uint _4795 = min(_1794.uniforms.clip_point_count, 32u);
                            uint _4798 = min(_1794.uniforms.clip_contour_count, 8u);
                            if ((_4795 < 3u) || (_4798 == 0u))
                            {
                                _6845 = 1.0;
                                break;
                            }
                            vec2 _4813 = _4604 - (_1794.uniforms.clip_rect.xy * _1794.uniforms.scale_factor);
                            bool _6826 = false;
                            do
                            {
                                if (_1794.uniforms.clip_fill_rule == 0u)
                                {
                                    bool _6825 = false;
                                    _6825 = false;
                                    uint _5012 = 0u;
                                    bool _6948 = false;
                                    for (uint _6824 = 0u, _6835 = 0u; _6824 < _4798; _6835 = _5012, _6825 = _6948, _6824++)
                                    {
                                        _5012 = min(_1794.uniforms.clip_polygon_end_points[_6824 / 4u][_6824 % 4u], _4795);
                                        if (_5012 <= (_6835 + 1u))
                                        {
                                            _6948 = _6825;
                                            continue;
                                        }
                                        bool _6838 = false;
                                        _6838 = _6825;
                                        bool _6953 = false;
                                        for (uint _6836 = _6835; _6836 < _5012; _6838 = _6953, _6836++)
                                        {
                                            uint _5028 = _6836 + 1u;
                                            uint _5034 = (_5028 < _5012) ? _5028 : _6835;
                                            uint _5127 = _6836 / 2u;
                                            bvec2 _5137 = bvec2((_6836 % 2u) == 0u);
                                            vec2 _5040 = vec2(_5137.x ? _1794.uniforms.clip_polygon_points[_5127].xy.x : _1794.uniforms.clip_polygon_points[_5127].zw.x, _5137.y ? _1794.uniforms.clip_polygon_points[_5127].xy.y : _1794.uniforms.clip_polygon_points[_5127].zw.y) * _1794.uniforms.scale_factor;
                                            uint _5143 = _5034 / 2u;
                                            bvec2 _5153 = bvec2((_5034 % 2u) == 0u);
                                            vec2 _5046 = vec2(_5153.x ? _1794.uniforms.clip_polygon_points[_5143].xy.x : _1794.uniforms.clip_polygon_points[_5143].zw.x, _5153.y ? _1794.uniforms.clip_polygon_points[_5143].xy.y : _1794.uniforms.clip_polygon_points[_5143].zw.y) * _1794.uniforms.scale_factor;
                                            float _5048 = _5046.y;
                                            float _5050 = _5040.y;
                                            float _5051 = _5048 - _5050;
                                            float _5063 = _4813.y;
                                            float _5076 = _5040.x;
                                            if (((_5050 > _5063) != (_5048 > _5063)) && (_4813.x < ((((_5046.x - _5076) * (_5063 - _5050)) / ((abs(_5051) < 9.9999997473787516355514526367188e-05) ? ((_5051 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _5051)) + _5076)))
                                            {
                                                _6953 = !_6838;
                                            }
                                            else
                                            {
                                                _6953 = _6838;
                                            }
                                        }
                                        _6948 = _6838;
                                    }
                                    _6826 = _6825;
                                    break;
                                }
                                int _6807 = 0;
                                _6807 = 0;
                                uint _5183 = 0u;
                                int _6936 = 0;
                                for (uint _6806 = 0u, _6808 = 0u; _6806 < _4798; _6808 = _5183, _6807 = _6936, _6806++)
                                {
                                    _5183 = min(_1794.uniforms.clip_polygon_end_points[_6806 / 4u][_6806 % 4u], _4795);
                                    if (_5183 <= (_6808 + 1u))
                                    {
                                        _6936 = _6807;
                                        continue;
                                    }
                                    int _6811 = 0;
                                    _6811 = _6807;
                                    int _6943 = 0;
                                    for (uint _6809 = _6808; _6809 < _5183; _6811 = _6943, _6809++)
                                    {
                                        uint _5199 = _6809 + 1u;
                                        uint _5205 = (_5199 < _5183) ? _5199 : _6808;
                                        uint _5320 = _6809 / 2u;
                                        bvec2 _5330 = bvec2((_6809 % 2u) == 0u);
                                        vec2 _5211 = vec2(_5330.x ? _1794.uniforms.clip_polygon_points[_5320].xy.x : _1794.uniforms.clip_polygon_points[_5320].zw.x, _5330.y ? _1794.uniforms.clip_polygon_points[_5320].xy.y : _1794.uniforms.clip_polygon_points[_5320].zw.y) * _1794.uniforms.scale_factor;
                                        uint _5336 = _5205 / 2u;
                                        bvec2 _5346 = bvec2((_5205 % 2u) == 0u);
                                        vec2 _5217 = vec2(_5346.x ? _1794.uniforms.clip_polygon_points[_5336].xy.x : _1794.uniforms.clip_polygon_points[_5336].zw.x, _5346.y ? _1794.uniforms.clip_polygon_points[_5336].xy.y : _1794.uniforms.clip_polygon_points[_5336].zw.y) * _1794.uniforms.scale_factor;
                                        float _5219 = _5211.y;
                                        float _5221 = _4813.y;
                                        if (_5219 <= _5221)
                                        {
                                            float _5225 = _5217.y;
                                            int _6944 = 0;
                                            if (_5225 > _5221)
                                            {
                                                float _5233 = _5211.x;
                                                int _6945 = 0;
                                                if ((((_5217.x - _5233) * (_5221 - _5219)) - ((_4813.x - _5233) * (_5225 - _5219))) > 0.0)
                                                {
                                                    _6945 = _6811 + 1;
                                                }
                                                else
                                                {
                                                    _6945 = _6811;
                                                }
                                                _6944 = _6945;
                                            }
                                            else
                                            {
                                                _6944 = _6811;
                                            }
                                            _6943 = _6944;
                                        }
                                        else
                                        {
                                            float _5262 = _5217.y;
                                            int _6946 = 0;
                                            if (_5262 <= _5221)
                                            {
                                                float _5270 = _5211.x;
                                                int _6947 = 0;
                                                if ((((_5217.x - _5270) * (_5221 - _5219)) - ((_4813.x - _5270) * (_5262 - _5219))) < 0.0)
                                                {
                                                    _6947 = _6811 - 1;
                                                }
                                                else
                                                {
                                                    _6947 = _6811;
                                                }
                                                _6946 = _6947;
                                            }
                                            else
                                            {
                                                _6946 = _6811;
                                            }
                                            _6943 = _6946;
                                        }
                                    }
                                    _6936 = _6811;
                                }
                                _6826 = _6807 != 0;
                                break;
                            } while(false);
                            float _6828 = 0.0;
                            uint _6829 = 0u;
                            _6829 = 0u;
                            _6828 = uintBitsToFloat(0x7f800000u /* inf */);
                            uint _4830 = 0u;
                            float _6949 = 0.0;
                            for (uint _6827 = 0u; _6827 < _4798; _6829 = _4830, _6828 = _6949, _6827++)
                            {
                                _4830 = min(_1794.uniforms.clip_polygon_end_points[_6827 / 4u][_6827 % 4u], _4795);
                                if (_4830 <= (_6829 + 1u))
                                {
                                    _6949 = _6828;
                                    continue;
                                }
                                float _6832 = 0.0;
                                _6832 = _6828;
                                for (uint _6830 = _6829; _6830 < _4830; )
                                {
                                    uint _4846 = _6830 + 1u;
                                    uint _4852 = (_4846 < _4830) ? _4846 : _6829;
                                    uint _5360 = _6830 / 2u;
                                    bvec2 _5370 = bvec2((_6830 % 2u) == 0u);
                                    vec2 _4858 = vec2(_5370.x ? _1794.uniforms.clip_polygon_points[_5360].xy.x : _1794.uniforms.clip_polygon_points[_5360].zw.x, _5370.y ? _1794.uniforms.clip_polygon_points[_5360].xy.y : _1794.uniforms.clip_polygon_points[_5360].zw.y) * _1794.uniforms.scale_factor;
                                    uint _5376 = _4852 / 2u;
                                    bvec2 _5386 = bvec2((_4852 % 2u) == 0u);
                                    vec2 _5395 = (vec2(_5386.x ? _1794.uniforms.clip_polygon_points[_5376].xy.x : _1794.uniforms.clip_polygon_points[_5376].zw.x, _5386.y ? _1794.uniforms.clip_polygon_points[_5376].xy.y : _1794.uniforms.clip_polygon_points[_5376].zw.y) * _1794.uniforms.scale_factor) - _4858;
                                    _6832 = min(_6832, length(_4813 - (_4858 + (_5395 * clamp(dot(_4813 - _4858, _5395) / max(dot(_5395, _5395), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                    _6830++;
                                    continue;
                                }
                                _6949 = _6832;
                            }
                            float _4889 = max(length(vec2(dFdxFine(_4604.x), dFdyFine(_4604.y))) * 0.5, 0.75);
                            _6845 = smoothstep(_4889, -_4889, _6826 ? (-_6828) : _6828);
                            break;
                        }
                        _6844 = 1.0;
                    }
                    _6843 = _6844;
                }
                float _4911 = max((abs(dFdxFine(_6843)) + abs(dFdyFine(_6843))) * 0.5, 0.5);
                _6845 = smoothstep(_4911, -_4911, _6843);
                break;
            } while(false);
            float _4620 = _6805 * _6845;
            SPIRV_CROSS_BRANCH
            if (((true && (input_solid_metrics.x == 0.0)) && all(equal(input_solid_widths, vec4(0.0)))) && true)
            {
                float _3597 = input_solid_fill.w * _4596;
                vec4 _3612 = vec4(input_solid_fill.xyz * _3597, _3597) * _4620;
                if (_3612.w < 0.001000000047497451305389404296875)
                {
                    discard;
                }
                _6934 = _3612;
                break;
            }
            vec4 _3623 = input_solid_widths * _1794.uniforms.scale_factor;
            float _3625 = _3623.x;
            float _3627 = _3623.y;
            float _3630 = _3623.z;
            float _3633 = _3623.w;
            float _6886 = 0.0;
            if (true && (((((_3625 + _3627) + _3630) + _3633) > 0.0) && true))
            {
                vec4 _3720 = max(_3435 - vec4(max(_3625, _3633), max(_3625, _3627), max(_3630, _3627), max(_3630, _3633)), vec4(0.0));
                vec2 _3724 = input_local_pos - vec2((_3633 - _3627) * 0.5, (_3625 - _3630) * 0.5);
                bool _5425 = _3724.y < 0.0;
                float _5439 = (_3724.x < 0.0) ? (_5425 ? _3720.x : _3720.w) : (_5425 ? _3720.y : _3720.z);
                vec2 _5446 = (abs(_3724) - max(vec2(input_size.x - ((_3627 + _3633) * 0.5), input_size.y - ((_3625 + _3630) * 0.5)), vec2(0.0))) + vec2(_5439);
                _6886 = _4596 - smoothstep(_3529, _4594, (min(max(_5446.x, _5446.y), 0.0) + length(max(_5446, vec2(0.0)))) - _5439);
            }
            else
            {
                float _6887 = 0.0;
                if (true && (_3450 > 0.0))
                {
                    _6887 = _4596 - smoothstep(_3529, _4594, _4366 + _3450);
                }
                else
                {
                    _6887 = 0.0;
                }
                _6886 = _6887;
            }
            vec4 _7119 = vec4(0.0);
            if (_4596 > 0.0)
            {
                float _3765 = input_solid_fill.w * _4596;
                _7119 = vec4(input_solid_fill.xyz * _3765, _3765) * 1.0;
            }
            else
            {
                _7119 = vec4(0.0);
            }
            vec4 _7120 = vec4(0.0);
            if (_6886 > 0.0)
            {
                float _3791 = input_solid_border.w * _6886;
                _7120 = _7119 + (vec4(input_solid_border.xyz * _3791, _3791) * (1.0 - _7119.w));
            }
            else
            {
                _7120 = _7119;
            }
            vec4 _3811 = _7120 * _4620;
            if (_3811.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6934 = _3811;
            break;
        } while(false);
        _6935 = _6934;
        break;
    } while(false);
    _entryPointOutput = _6935;
}

