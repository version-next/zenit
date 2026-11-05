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
} _1788;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 9) flat in vec4 input_solid_widths;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 12) flat in vec3 input_second_shadow_metrics;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3004 = input_solid_fill;
    vec4 _6830 = vec4(0.0);
    do
    {
        vec4 _3342 = input_solid_radii * _1788.uniforms.scale_factor;
        float _3361 = input_solid_metrics.x * _1788.uniforms.scale_factor;
        vec2 _3368 = vec2(input_solid_metrics.y, input_solid_metrics.z) * _1788.uniforms.scale_factor;
        bool _4240 = input_local_pos.y < 0.0;
        float _4254 = (input_local_pos.x < 0.0) ? (_4240 ? _3342.x : _3342.w) : (_4240 ? _3342.y : _3342.z);
        vec2 _4261 = (abs(input_local_pos) - input_size) + vec2(_4254);
        float _4273 = (min(max(_4261.x, _4261.y), 0.0) + length(max(_4261, vec2(0.0)))) - _4254;
        float _4488 = dFdxFine(_4273);
        float _4490 = dFdyFine(_4273);
        float _3436 = max(length(vec2(_4488, _4490)) * 0.5, 0.5);
        float _4503 = smoothstep(_3436, -_3436, _4273);
        bvec2 _4510 = bvec2(_1788.uniforms.raster_clip_pos != 0u);
        vec2 _4511 = vec2(_4510.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4510.y ? gl_FragCoord.xy.y : input_screen_pos.y);
        float _6701 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6701 = 1.0;
                break;
            }
            vec2 _4589 = abs(_4511 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1788.uniforms.scale_factor)) - ((input_rect_clip.zw * _1788.uniforms.scale_factor) * 0.5);
            float _4602 = min(max(_4589.x, _4589.y), 0.0) + length(max(_4589, vec2(0.0)));
            float _4575 = max((abs(dFdxFine(_4602)) + abs(dFdyFine(_4602))) * 0.5, 0.5);
            _6701 = smoothstep(_4575, -_4575, _4602);
            break;
        } while(false);
        float _6741 = 0.0;
        do
        {
            if (_1788.uniforms.clip_shape_kind == 0u)
            {
                _6741 = 1.0;
                break;
            }
            vec2 _4662 = (_1788.uniforms.clip_rect.xy + (_1788.uniforms.clip_rect.zw * 0.5)) * _1788.uniforms.scale_factor;
            vec2 _4669 = (_1788.uniforms.clip_rect.zw * _1788.uniforms.scale_factor) * 0.5;
            float _6739 = 0.0;
            if (_1788.uniforms.clip_shape_kind == 1u)
            {
                vec4 _4678 = _1788.uniforms.clip_radii * _1788.uniforms.scale_factor;
                vec2 _4681 = _4511 - _4662;
                bool _4835 = _4681.y < 0.0;
                float _4849 = (_4681.x < 0.0) ? (_4835 ? _4678.x : _4678.w) : (_4835 ? _4678.y : _4678.z);
                vec2 _4856 = (abs(_4681) - _4669) + vec2(_4849);
                _6739 = (min(max(_4856.x, _4856.y), 0.0) + length(max(_4856, vec2(0.0)))) - _4849;
            }
            else
            {
                float _6740 = 0.0;
                if (_1788.uniforms.clip_shape_kind == 2u)
                {
                    _6740 = length((_4511 - _4662) / max(_4669, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1788.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4702 = min(_1788.uniforms.clip_point_count, 32u);
                        uint _4705 = min(_1788.uniforms.clip_contour_count, 8u);
                        if ((_4702 < 3u) || (_4705 == 0u))
                        {
                            _6741 = 1.0;
                            break;
                        }
                        vec2 _4720 = _4511 - (_1788.uniforms.clip_rect.xy * _1788.uniforms.scale_factor);
                        bool _6722 = false;
                        do
                        {
                            if (_1788.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6721 = false;
                                _6721 = false;
                                uint _4919 = 0u;
                                bool _6843 = false;
                                for (uint _6720 = 0u, _6731 = 0u; _6720 < _4705; _6731 = _4919, _6721 = _6843, _6720++)
                                {
                                    _4919 = min(_1788.uniforms.clip_polygon_end_points[_6720 / 4u][_6720 % 4u], _4702);
                                    if (_4919 <= (_6731 + 1u))
                                    {
                                        _6843 = _6721;
                                        continue;
                                    }
                                    bool _6734 = false;
                                    _6734 = _6721;
                                    bool _6848 = false;
                                    for (uint _6732 = _6731; _6732 < _4919; _6734 = _6848, _6732++)
                                    {
                                        uint _4935 = _6732 + 1u;
                                        uint _4941 = (_4935 < _4919) ? _4935 : _6731;
                                        uint _5034 = _6732 / 2u;
                                        bvec2 _5044 = bvec2((_6732 % 2u) == 0u);
                                        vec2 _4947 = vec2(_5044.x ? _1788.uniforms.clip_polygon_points[_5034].xy.x : _1788.uniforms.clip_polygon_points[_5034].zw.x, _5044.y ? _1788.uniforms.clip_polygon_points[_5034].xy.y : _1788.uniforms.clip_polygon_points[_5034].zw.y) * _1788.uniforms.scale_factor;
                                        uint _5050 = _4941 / 2u;
                                        bvec2 _5060 = bvec2((_4941 % 2u) == 0u);
                                        vec2 _4953 = vec2(_5060.x ? _1788.uniforms.clip_polygon_points[_5050].xy.x : _1788.uniforms.clip_polygon_points[_5050].zw.x, _5060.y ? _1788.uniforms.clip_polygon_points[_5050].xy.y : _1788.uniforms.clip_polygon_points[_5050].zw.y) * _1788.uniforms.scale_factor;
                                        float _4955 = _4953.y;
                                        float _4957 = _4947.y;
                                        float _4958 = _4955 - _4957;
                                        float _4970 = _4720.y;
                                        float _4983 = _4947.x;
                                        if (((_4957 > _4970) != (_4955 > _4970)) && (_4720.x < ((((_4953.x - _4983) * (_4970 - _4957)) / ((abs(_4958) < 9.9999997473787516355514526367188e-05) ? ((_4958 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4958)) + _4983)))
                                        {
                                            _6848 = !_6734;
                                        }
                                        else
                                        {
                                            _6848 = _6734;
                                        }
                                    }
                                    _6843 = _6734;
                                }
                                _6722 = _6721;
                                break;
                            }
                            int _6703 = 0;
                            _6703 = 0;
                            uint _5090 = 0u;
                            int _6831 = 0;
                            for (uint _6702 = 0u, _6704 = 0u; _6702 < _4705; _6704 = _5090, _6703 = _6831, _6702++)
                            {
                                _5090 = min(_1788.uniforms.clip_polygon_end_points[_6702 / 4u][_6702 % 4u], _4702);
                                if (_5090 <= (_6704 + 1u))
                                {
                                    _6831 = _6703;
                                    continue;
                                }
                                int _6707 = 0;
                                _6707 = _6703;
                                int _6838 = 0;
                                for (uint _6705 = _6704; _6705 < _5090; _6707 = _6838, _6705++)
                                {
                                    uint _5106 = _6705 + 1u;
                                    uint _5112 = (_5106 < _5090) ? _5106 : _6704;
                                    uint _5227 = _6705 / 2u;
                                    bvec2 _5237 = bvec2((_6705 % 2u) == 0u);
                                    vec2 _5118 = vec2(_5237.x ? _1788.uniforms.clip_polygon_points[_5227].xy.x : _1788.uniforms.clip_polygon_points[_5227].zw.x, _5237.y ? _1788.uniforms.clip_polygon_points[_5227].xy.y : _1788.uniforms.clip_polygon_points[_5227].zw.y) * _1788.uniforms.scale_factor;
                                    uint _5243 = _5112 / 2u;
                                    bvec2 _5253 = bvec2((_5112 % 2u) == 0u);
                                    vec2 _5124 = vec2(_5253.x ? _1788.uniforms.clip_polygon_points[_5243].xy.x : _1788.uniforms.clip_polygon_points[_5243].zw.x, _5253.y ? _1788.uniforms.clip_polygon_points[_5243].xy.y : _1788.uniforms.clip_polygon_points[_5243].zw.y) * _1788.uniforms.scale_factor;
                                    float _5126 = _5118.y;
                                    float _5128 = _4720.y;
                                    if (_5126 <= _5128)
                                    {
                                        float _5132 = _5124.y;
                                        int _6839 = 0;
                                        if (_5132 > _5128)
                                        {
                                            float _5140 = _5118.x;
                                            int _6840 = 0;
                                            if ((((_5124.x - _5140) * (_5128 - _5126)) - ((_4720.x - _5140) * (_5132 - _5126))) > 0.0)
                                            {
                                                _6840 = _6707 + 1;
                                            }
                                            else
                                            {
                                                _6840 = _6707;
                                            }
                                            _6839 = _6840;
                                        }
                                        else
                                        {
                                            _6839 = _6707;
                                        }
                                        _6838 = _6839;
                                    }
                                    else
                                    {
                                        float _5169 = _5124.y;
                                        int _6841 = 0;
                                        if (_5169 <= _5128)
                                        {
                                            float _5177 = _5118.x;
                                            int _6842 = 0;
                                            if ((((_5124.x - _5177) * (_5128 - _5126)) - ((_4720.x - _5177) * (_5169 - _5126))) < 0.0)
                                            {
                                                _6842 = _6707 - 1;
                                            }
                                            else
                                            {
                                                _6842 = _6707;
                                            }
                                            _6841 = _6842;
                                        }
                                        else
                                        {
                                            _6841 = _6707;
                                        }
                                        _6838 = _6841;
                                    }
                                }
                                _6831 = _6707;
                            }
                            _6722 = _6703 != 0;
                            break;
                        } while(false);
                        float _6724 = 0.0;
                        uint _6725 = 0u;
                        _6725 = 0u;
                        _6724 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4737 = 0u;
                        float _6844 = 0.0;
                        for (uint _6723 = 0u; _6723 < _4705; _6725 = _4737, _6724 = _6844, _6723++)
                        {
                            _4737 = min(_1788.uniforms.clip_polygon_end_points[_6723 / 4u][_6723 % 4u], _4702);
                            if (_4737 <= (_6725 + 1u))
                            {
                                _6844 = _6724;
                                continue;
                            }
                            float _6728 = 0.0;
                            _6728 = _6724;
                            for (uint _6726 = _6725; _6726 < _4737; )
                            {
                                uint _4753 = _6726 + 1u;
                                uint _4759 = (_4753 < _4737) ? _4753 : _6725;
                                uint _5267 = _6726 / 2u;
                                bvec2 _5277 = bvec2((_6726 % 2u) == 0u);
                                vec2 _4765 = vec2(_5277.x ? _1788.uniforms.clip_polygon_points[_5267].xy.x : _1788.uniforms.clip_polygon_points[_5267].zw.x, _5277.y ? _1788.uniforms.clip_polygon_points[_5267].xy.y : _1788.uniforms.clip_polygon_points[_5267].zw.y) * _1788.uniforms.scale_factor;
                                uint _5283 = _4759 / 2u;
                                bvec2 _5293 = bvec2((_4759 % 2u) == 0u);
                                vec2 _5302 = (vec2(_5293.x ? _1788.uniforms.clip_polygon_points[_5283].xy.x : _1788.uniforms.clip_polygon_points[_5283].zw.x, _5293.y ? _1788.uniforms.clip_polygon_points[_5283].xy.y : _1788.uniforms.clip_polygon_points[_5283].zw.y) * _1788.uniforms.scale_factor) - _4765;
                                _6728 = min(_6728, length(_4720 - (_4765 + (_5302 * clamp(dot(_4720 - _4765, _5302) / max(dot(_5302, _5302), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6726++;
                                continue;
                            }
                            _6844 = _6728;
                        }
                        float _4796 = max(length(vec2(dFdxFine(_4511.x), dFdyFine(_4511.y))) * 0.5, 0.75);
                        _6741 = smoothstep(_4796, -_4796, _6722 ? (-_6724) : _6724);
                        break;
                    }
                    _6740 = 1.0;
                }
                _6739 = _6740;
            }
            float _4818 = max((abs(dFdxFine(_6739)) + abs(dFdyFine(_6739))) * 0.5, 0.5);
            _6741 = smoothstep(_4818, -_4818, _6739);
            break;
        } while(false);
        float _4527 = _6701 * _6741;
        SPIRV_CROSS_BRANCH
        if (true && (_4503 == 1.0))
        {
            vec3 _3463 = _3004.xyz * _3004.w;
            vec4 _6960 = _3004;
            _6960.x = _3463.x;
            _6960.y = _3463.y;
            _6960.z = _3463.z;
            vec4 _3472 = _6960 * _4527;
            if (_3472.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6830 = _3472;
            break;
        }
        vec4 _7038 = vec4(0.0);
        _7038 = vec4(0.0);
        vec4 _7042 = vec4(0.0);
        SPIRV_CROSS_LOOP
        for (uint _6762 = 0u; _6762 < 2u; _7038 = _7042, _6762++)
        {
            bool _3748 = _6762 == 0u;
            if (true && (_3748 ? (_3361 > 0.0) : true))
            {
                vec2 _6805 = vec2(0.0);
                vec2 _6807 = vec2(0.0);
                vec4 _6810 = vec4(0.0);
                float _6820 = 0.0;
                if (_3748)
                {
                    _6820 = _3361;
                    _6810 = max(_3342, vec4(0.0));
                    _6807 = max(input_size, vec2(0.0));
                    _6805 = _3368;
                }
                else
                {
                    _6820 = input_second_shadow_metrics.x * _1788.uniforms.scale_factor;
                    _6810 = _3342;
                    _6807 = input_size;
                    _6805 = vec2(input_second_shadow_metrics.y, input_second_shadow_metrics.z) * _1788.uniforms.scale_factor;
                }
                bvec4 _7049 = bvec4(_3748);
                vec4 _7050 = vec4(_7049.x ? input_solid_border.x : input_solid_widths.x, _7049.y ? input_solid_border.y : input_solid_widths.y, _7049.z ? input_solid_border.z : input_solid_widths.z, _7049.w ? input_solid_border.w : input_solid_widths.w);
                vec2 _3839 = input_local_pos - _6805;
                bool _5472 = _3839.y < 0.0;
                float _5486 = (_3839.x < 0.0) ? (_5472 ? _6810.x : _6810.w) : (_5472 ? _6810.y : _6810.z);
                vec2 _5493 = (abs(_3839) - _6807) + vec2(_5486);
                float _3856 = _7050.w * (smoothstep(_6820, -_6820, (min(max(_5493.x, _5493.y), 0.0) + length(max(_5493, vec2(0.0)))) - _5486) * (1.0 - _4503));
                _7042 = _7038 + (vec4(_7050.xyz * _3856, _3856) * (1.0 - _7038.w));
            }
            else
            {
                _7042 = _7038;
            }
        }
        vec4 _7039 = vec4(0.0);
        if (true && (_4503 > 0.0))
        {
            float _4129 = _3004.w * _4503;
            _7039 = _7038 + (vec4(_3004.xyz * _4129, _4129) * (1.0 - _7038.w));
        }
        else
        {
            _7039 = _7038;
        }
        vec4 _4221 = _7039 * _4527;
        if (_4221.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6830 = _4221;
        break;
    } while(false);
    _entryPointOutput = _6830;
}

