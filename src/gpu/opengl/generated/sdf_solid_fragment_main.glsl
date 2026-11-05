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
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6870 = vec4(0.0);
    do
    {
        vec4 _3378 = input_solid_radii * _1794.uniforms.scale_factor;
        float _3393 = input_solid_metrics.x * _1794.uniforms.scale_factor;
        bool _3408 = input_solid_shape == 0u;
        float _6728 = 0.0;
        if (_3408)
        {
            bool _4276 = input_local_pos.y < 0.0;
            float _4290 = (input_local_pos.x < 0.0) ? (_4276 ? _3378.x : _3378.w) : (_4276 ? _3378.y : _3378.z);
            vec2 _4297 = (abs(input_local_pos) - input_size) + vec2(_4290);
            _6728 = (min(max(_4297.x, _4297.y), 0.0) + length(max(_4297, vec2(0.0)))) - _4290;
        }
        else
        {
            float _6729 = 0.0;
            if (input_solid_shape == 1u)
            {
                _6729 = length(input_local_pos) - min(input_size.x, input_size.y);
            }
            else
            {
                float _6730 = 0.0;
                if (input_solid_shape == 2u)
                {
                    _6730 = abs(input_local_pos.y) - _3378.x;
                }
                else
                {
                    float _6731 = 0.0;
                    if (input_solid_shape == 3u)
                    {
                        float _3449 = _3378.x;
                        float _6727 = 0.0;
                        do
                        {
                            float _4339 = _3393 * 0.5;
                            float _4349 = abs(length(input_local_pos) - (_3449 - _4339)) - _4339;
                            float _4353 = clamp(input_solid_metrics.z - input_solid_metrics.y, 0.0, 6.283185482025146484375);
                            if (_4353 >= 6.283085346221923828125)
                            {
                                _6727 = _4349;
                                break;
                            }
                            if (_4353 <= 0.0)
                            {
                                _6727 = max(_4349, 0.0) + 1.0;
                                break;
                            }
                            float _4369 = max(_3449 - _3393, 0.0);
                            vec2 _4418 = vec2(cos(input_solid_metrics.y), sin(input_solid_metrics.y));
                            float _4425 = _3449 - _4369;
                            vec2 _4426 = _4418 * _4425;
                            vec2 _4429 = input_local_pos - (_4418 * _4369);
                            float _4377 = input_solid_metrics.y + _4353;
                            vec2 _4454 = vec2(cos(_4377), sin(_4377));
                            vec2 _4462 = _4454 * _4425;
                            vec2 _4465 = input_local_pos - (_4454 * _4369);
                            float _4382 = min(length(_4429 - (_4426 * clamp(dot(_4429, _4426) / max(dot(_4426, _4426), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4465 - (_4462 * clamp(dot(_4465, _4462) / max(dot(_4462, _4462), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                            float _4390 = atan(input_local_pos.y, input_local_pos.x) - input_solid_metrics.y;
                            _6727 = ((_4390 - (floor(_4390 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4353) ? max(_4349, -_4382) : _4382;
                            break;
                        } while(false);
                        _6731 = _6727;
                    }
                    else
                    {
                        float _6732 = 0.0;
                        if (input_solid_shape == 4u)
                        {
                            float _6726 = 0.0;
                            do
                            {
                                vec2 _4490 = max(input_size, vec2(0.001000000047497451305389404296875));
                                float _4495 = length(input_local_pos / _4490);
                                if (_4495 < 9.9999999747524270787835121154785e-07)
                                {
                                    _6726 = -min(_4490.x, _4490.y);
                                    break;
                                }
                                _6726 = (_4495 - 1.0) / max(length(input_local_pos / (_4490 * _4490)) / _4495, 9.9999999747524270787835121154785e-07);
                                break;
                            } while(false);
                            _6732 = _6726;
                        }
                        else
                        {
                            _6732 = 1.0;
                        }
                        _6731 = _6732;
                    }
                    _6730 = _6731;
                }
                _6729 = _6730;
            }
            _6728 = _6729;
        }
        float _4524 = dFdxFine(_6728);
        float _4526 = dFdyFine(_6728);
        float _3472 = max(length(vec2(_4524, _4526)) * 0.5, 0.5);
        float _4537 = -_3472;
        float _4539 = smoothstep(_3472, _4537, _6728);
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
        float _6781 = 0.0;
        do
        {
            if (_1794.uniforms.clip_shape_kind == 0u)
            {
                _6781 = 1.0;
                break;
            }
            vec2 _4698 = (_1794.uniforms.clip_rect.xy + (_1794.uniforms.clip_rect.zw * 0.5)) * _1794.uniforms.scale_factor;
            vec2 _4705 = (_1794.uniforms.clip_rect.zw * _1794.uniforms.scale_factor) * 0.5;
            float _6779 = 0.0;
            if (_1794.uniforms.clip_shape_kind == 1u)
            {
                vec4 _4714 = _1794.uniforms.clip_radii * _1794.uniforms.scale_factor;
                vec2 _4717 = _4547 - _4698;
                bool _4871 = _4717.y < 0.0;
                float _4885 = (_4717.x < 0.0) ? (_4871 ? _4714.x : _4714.w) : (_4871 ? _4714.y : _4714.z);
                vec2 _4892 = (abs(_4717) - _4705) + vec2(_4885);
                _6779 = (min(max(_4892.x, _4892.y), 0.0) + length(max(_4892, vec2(0.0)))) - _4885;
            }
            else
            {
                float _6780 = 0.0;
                if (_1794.uniforms.clip_shape_kind == 2u)
                {
                    _6780 = length((_4547 - _4698) / max(_4705, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1794.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4738 = min(_1794.uniforms.clip_point_count, 32u);
                        uint _4741 = min(_1794.uniforms.clip_contour_count, 8u);
                        if ((_4738 < 3u) || (_4741 == 0u))
                        {
                            _6781 = 1.0;
                            break;
                        }
                        vec2 _4756 = _4547 - (_1794.uniforms.clip_rect.xy * _1794.uniforms.scale_factor);
                        bool _6762 = false;
                        do
                        {
                            if (_1794.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6761 = false;
                                _6761 = false;
                                uint _4955 = 0u;
                                bool _6883 = false;
                                for (uint _6760 = 0u, _6771 = 0u; _6760 < _4741; _6771 = _4955, _6761 = _6883, _6760++)
                                {
                                    _4955 = min(_1794.uniforms.clip_polygon_end_points[_6760 / 4u][_6760 % 4u], _4738);
                                    if (_4955 <= (_6771 + 1u))
                                    {
                                        _6883 = _6761;
                                        continue;
                                    }
                                    bool _6774 = false;
                                    _6774 = _6761;
                                    bool _6888 = false;
                                    for (uint _6772 = _6771; _6772 < _4955; _6774 = _6888, _6772++)
                                    {
                                        uint _4971 = _6772 + 1u;
                                        uint _4977 = (_4971 < _4955) ? _4971 : _6771;
                                        uint _5070 = _6772 / 2u;
                                        bvec2 _5080 = bvec2((_6772 % 2u) == 0u);
                                        vec2 _4983 = vec2(_5080.x ? _1794.uniforms.clip_polygon_points[_5070].xy.x : _1794.uniforms.clip_polygon_points[_5070].zw.x, _5080.y ? _1794.uniforms.clip_polygon_points[_5070].xy.y : _1794.uniforms.clip_polygon_points[_5070].zw.y) * _1794.uniforms.scale_factor;
                                        uint _5086 = _4977 / 2u;
                                        bvec2 _5096 = bvec2((_4977 % 2u) == 0u);
                                        vec2 _4989 = vec2(_5096.x ? _1794.uniforms.clip_polygon_points[_5086].xy.x : _1794.uniforms.clip_polygon_points[_5086].zw.x, _5096.y ? _1794.uniforms.clip_polygon_points[_5086].xy.y : _1794.uniforms.clip_polygon_points[_5086].zw.y) * _1794.uniforms.scale_factor;
                                        float _4991 = _4989.y;
                                        float _4993 = _4983.y;
                                        float _4994 = _4991 - _4993;
                                        float _5006 = _4756.y;
                                        float _5019 = _4983.x;
                                        if (((_4993 > _5006) != (_4991 > _5006)) && (_4756.x < ((((_4989.x - _5019) * (_5006 - _4993)) / ((abs(_4994) < 9.9999997473787516355514526367188e-05) ? ((_4994 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4994)) + _5019)))
                                        {
                                            _6888 = !_6774;
                                        }
                                        else
                                        {
                                            _6888 = _6774;
                                        }
                                    }
                                    _6883 = _6774;
                                }
                                _6762 = _6761;
                                break;
                            }
                            int _6743 = 0;
                            _6743 = 0;
                            uint _5126 = 0u;
                            int _6871 = 0;
                            for (uint _6742 = 0u, _6744 = 0u; _6742 < _4741; _6744 = _5126, _6743 = _6871, _6742++)
                            {
                                _5126 = min(_1794.uniforms.clip_polygon_end_points[_6742 / 4u][_6742 % 4u], _4738);
                                if (_5126 <= (_6744 + 1u))
                                {
                                    _6871 = _6743;
                                    continue;
                                }
                                int _6747 = 0;
                                _6747 = _6743;
                                int _6878 = 0;
                                for (uint _6745 = _6744; _6745 < _5126; _6747 = _6878, _6745++)
                                {
                                    uint _5142 = _6745 + 1u;
                                    uint _5148 = (_5142 < _5126) ? _5142 : _6744;
                                    uint _5263 = _6745 / 2u;
                                    bvec2 _5273 = bvec2((_6745 % 2u) == 0u);
                                    vec2 _5154 = vec2(_5273.x ? _1794.uniforms.clip_polygon_points[_5263].xy.x : _1794.uniforms.clip_polygon_points[_5263].zw.x, _5273.y ? _1794.uniforms.clip_polygon_points[_5263].xy.y : _1794.uniforms.clip_polygon_points[_5263].zw.y) * _1794.uniforms.scale_factor;
                                    uint _5279 = _5148 / 2u;
                                    bvec2 _5289 = bvec2((_5148 % 2u) == 0u);
                                    vec2 _5160 = vec2(_5289.x ? _1794.uniforms.clip_polygon_points[_5279].xy.x : _1794.uniforms.clip_polygon_points[_5279].zw.x, _5289.y ? _1794.uniforms.clip_polygon_points[_5279].xy.y : _1794.uniforms.clip_polygon_points[_5279].zw.y) * _1794.uniforms.scale_factor;
                                    float _5162 = _5154.y;
                                    float _5164 = _4756.y;
                                    if (_5162 <= _5164)
                                    {
                                        float _5168 = _5160.y;
                                        int _6879 = 0;
                                        if (_5168 > _5164)
                                        {
                                            float _5176 = _5154.x;
                                            int _6880 = 0;
                                            if ((((_5160.x - _5176) * (_5164 - _5162)) - ((_4756.x - _5176) * (_5168 - _5162))) > 0.0)
                                            {
                                                _6880 = _6747 + 1;
                                            }
                                            else
                                            {
                                                _6880 = _6747;
                                            }
                                            _6879 = _6880;
                                        }
                                        else
                                        {
                                            _6879 = _6747;
                                        }
                                        _6878 = _6879;
                                    }
                                    else
                                    {
                                        float _5205 = _5160.y;
                                        int _6881 = 0;
                                        if (_5205 <= _5164)
                                        {
                                            float _5213 = _5154.x;
                                            int _6882 = 0;
                                            if ((((_5160.x - _5213) * (_5164 - _5162)) - ((_4756.x - _5213) * (_5205 - _5162))) < 0.0)
                                            {
                                                _6882 = _6747 - 1;
                                            }
                                            else
                                            {
                                                _6882 = _6747;
                                            }
                                            _6881 = _6882;
                                        }
                                        else
                                        {
                                            _6881 = _6747;
                                        }
                                        _6878 = _6881;
                                    }
                                }
                                _6871 = _6747;
                            }
                            _6762 = _6743 != 0;
                            break;
                        } while(false);
                        float _6764 = 0.0;
                        uint _6765 = 0u;
                        _6765 = 0u;
                        _6764 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4773 = 0u;
                        float _6884 = 0.0;
                        for (uint _6763 = 0u; _6763 < _4741; _6765 = _4773, _6764 = _6884, _6763++)
                        {
                            _4773 = min(_1794.uniforms.clip_polygon_end_points[_6763 / 4u][_6763 % 4u], _4738);
                            if (_4773 <= (_6765 + 1u))
                            {
                                _6884 = _6764;
                                continue;
                            }
                            float _6768 = 0.0;
                            _6768 = _6764;
                            for (uint _6766 = _6765; _6766 < _4773; )
                            {
                                uint _4789 = _6766 + 1u;
                                uint _4795 = (_4789 < _4773) ? _4789 : _6765;
                                uint _5303 = _6766 / 2u;
                                bvec2 _5313 = bvec2((_6766 % 2u) == 0u);
                                vec2 _4801 = vec2(_5313.x ? _1794.uniforms.clip_polygon_points[_5303].xy.x : _1794.uniforms.clip_polygon_points[_5303].zw.x, _5313.y ? _1794.uniforms.clip_polygon_points[_5303].xy.y : _1794.uniforms.clip_polygon_points[_5303].zw.y) * _1794.uniforms.scale_factor;
                                uint _5319 = _4795 / 2u;
                                bvec2 _5329 = bvec2((_4795 % 2u) == 0u);
                                vec2 _5338 = (vec2(_5329.x ? _1794.uniforms.clip_polygon_points[_5319].xy.x : _1794.uniforms.clip_polygon_points[_5319].zw.x, _5329.y ? _1794.uniforms.clip_polygon_points[_5319].xy.y : _1794.uniforms.clip_polygon_points[_5319].zw.y) * _1794.uniforms.scale_factor) - _4801;
                                _6768 = min(_6768, length(_4756 - (_4801 + (_5338 * clamp(dot(_4756 - _4801, _5338) / max(dot(_5338, _5338), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6766++;
                                continue;
                            }
                            _6884 = _6768;
                        }
                        float _4832 = max(length(vec2(dFdxFine(_4547.x), dFdyFine(_4547.y))) * 0.5, 0.75);
                        _6781 = smoothstep(_4832, -_4832, _6762 ? (-_6764) : _6764);
                        break;
                    }
                    _6780 = 1.0;
                }
                _6779 = _6780;
            }
            float _4854 = max((abs(dFdxFine(_6779)) + abs(dFdyFine(_6779))) * 0.5, 0.5);
            _6781 = smoothstep(_4854, -_4854, _6779);
            break;
        } while(false);
        float _4563 = _6741 * _6781;
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
        if (true && (((((_3568 + _3570) + _3573) + _3576) > 0.0) && _3408))
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
                _6823 = _4539 - smoothstep(_3472, _4537, _6728 + _3393);
            }
            else
            {
                _6823 = 0.0;
            }
            _6822 = _6823;
        }
        vec4 _7058 = vec4(0.0);
        if (_4539 > 0.0)
        {
            float _3708 = input_solid_fill.w * _4539;
            _7058 = vec4(input_solid_fill.xyz * _3708, _3708) * 1.0;
        }
        else
        {
            _7058 = vec4(0.0);
        }
        vec4 _7059 = vec4(0.0);
        if (_6822 > 0.0)
        {
            float _3734 = input_solid_border.w * _6822;
            _7059 = _7058 + (vec4(input_solid_border.xyz * _3734, _3734) * (1.0 - _7058.w));
        }
        else
        {
            _7059 = _7058;
        }
        vec4 _3754 = _7059 * _4563;
        if (_3754.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6870 = _3754;
        break;
    } while(false);
    _entryPointOutput = _6870;
}

