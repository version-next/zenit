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

struct ShadowParam
{
    vec4 color;
    float blur;
    float offset_x;
    float offset_y;
    float _pad;
};

struct InstanceData
{
    vec4 rect;
    vec4 rect_clip;
    vec4 fill_color;
    vec4 border_color;
    vec4 shadow_color;
    vec4 gradient_to_color;
    vec4 corner_radii;
    float border_width;
    float shadow_blur;
    float shadow_offset_x;
    float shadow_offset_y;
    uint shape_type;
    uint packed_flags;
    float noise_scale;
    float noise_intensity;
    vec4 border_widths;
    uint gradient_stop_offset;
    uint gradient_stop_count;
    uint shadow2_index;
    uint _ext_reserved;
};

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _1780;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3354 = instances_1._data[input_instance_id].corner_radii * _1780.uniforms.scale_factor;
    float _3373 = instances_1._data[input_instance_id].shadow_blur * _1780.uniforms.scale_factor;
    vec2 _3380 = vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1780.uniforms.scale_factor;
    bool _3384 = instances_1._data[input_instance_id].shape_type == 0u;
    float _6615 = 0.0;
    if (_3384)
    {
        bool _4252 = input_local_pos.y < 0.0;
        float _4266 = (input_local_pos.x < 0.0) ? (_4252 ? _3354.x : _3354.w) : (_4252 ? _3354.y : _3354.z);
        vec2 _4273 = (abs(input_local_pos) - input_size) + vec2(_4266);
        _6615 = (min(max(_4273.x, _4273.y), 0.0) + length(max(_4273, vec2(0.0)))) - _4266;
    }
    else
    {
        float _6616 = 0.0;
        if (instances_1._data[input_instance_id].shape_type == 1u)
        {
            _6616 = length(input_local_pos) - min(input_size.x, input_size.y);
        }
        else
        {
            float _6617 = 0.0;
            if (instances_1._data[input_instance_id].shape_type == 2u)
            {
                _6617 = abs(input_local_pos.y) - _3354.x;
            }
            else
            {
                float _6618 = 0.0;
                if (instances_1._data[input_instance_id].shape_type == 3u)
                {
                    float _3421 = instances_1._data[input_instance_id].border_width * _1780.uniforms.scale_factor;
                    float _3425 = _3354.x;
                    float _6614 = 0.0;
                    do
                    {
                        float _4315 = _3421 * 0.5;
                        float _4325 = abs(length(input_local_pos) - (_3425 - _4315)) - _4315;
                        float _4329 = clamp(instances_1._data[input_instance_id].shadow_offset_y - instances_1._data[input_instance_id].shadow_offset_x, 0.0, 6.283185482025146484375);
                        if (_4329 >= 6.283085346221923828125)
                        {
                            _6614 = _4325;
                            break;
                        }
                        if (_4329 <= 0.0)
                        {
                            _6614 = max(_4325, 0.0) + 1.0;
                            break;
                        }
                        float _4345 = max(_3425 - _3421, 0.0);
                        vec2 _4394 = vec2(cos(instances_1._data[input_instance_id].shadow_offset_x), sin(instances_1._data[input_instance_id].shadow_offset_x));
                        float _4401 = _3425 - _4345;
                        vec2 _4402 = _4394 * _4401;
                        vec2 _4405 = input_local_pos - (_4394 * _4345);
                        float _4353 = instances_1._data[input_instance_id].shadow_offset_x + _4329;
                        vec2 _4430 = vec2(cos(_4353), sin(_4353));
                        vec2 _4438 = _4430 * _4401;
                        vec2 _4441 = input_local_pos - (_4430 * _4345);
                        float _4358 = min(length(_4405 - (_4402 * clamp(dot(_4405, _4402) / max(dot(_4402, _4402), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4441 - (_4438 * clamp(dot(_4441, _4438) / max(dot(_4438, _4438), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                        float _4366 = atan(input_local_pos.y, input_local_pos.x) - instances_1._data[input_instance_id].shadow_offset_x;
                        _6614 = ((_4366 - (floor(_4366 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4329) ? max(_4325, -_4358) : _4358;
                        break;
                    } while(false);
                    _6618 = _6614;
                }
                else
                {
                    float _6619 = 0.0;
                    if (instances_1._data[input_instance_id].shape_type == 4u)
                    {
                        float _6613 = 0.0;
                        do
                        {
                            vec2 _4466 = max(input_size, vec2(0.001000000047497451305389404296875));
                            float _4471 = length(input_local_pos / _4466);
                            if (_4471 < 9.9999999747524270787835121154785e-07)
                            {
                                _6613 = -min(_4466.x, _4466.y);
                                break;
                            }
                            _6613 = (_4471 - 1.0) / max(length(input_local_pos / (_4466 * _4466)) / _4471, 9.9999999747524270787835121154785e-07);
                            break;
                        } while(false);
                        _6619 = _6613;
                    }
                    else
                    {
                        _6619 = 1.0;
                    }
                    _6618 = _6619;
                }
                _6617 = _6618;
            }
            _6616 = _6617;
        }
        _6615 = _6616;
    }
    float _4500 = dFdxFine(_6615);
    float _4502 = dFdyFine(_6615);
    float _3448 = max(length(vec2(_4500, _4502)) * 0.5, 0.5);
    float _4515 = smoothstep(_3448, -_3448, _6615);
    bvec2 _4522 = bvec2(_1780.uniforms.raster_clip_pos != 0u);
    vec2 _4523 = vec2(_4522.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4522.y ? gl_FragCoord.xy.y : input_screen_pos.y);
    float _6628 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6628 = 1.0;
            break;
        }
        vec2 _4601 = abs(_4523 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1780.uniforms.scale_factor)) - ((input_rect_clip.zw * _1780.uniforms.scale_factor) * 0.5);
        float _4614 = min(max(_4601.x, _4601.y), 0.0) + length(max(_4601, vec2(0.0)));
        float _4587 = max((abs(dFdxFine(_4614)) + abs(dFdyFine(_4614))) * 0.5, 0.5);
        _6628 = smoothstep(_4587, -_4587, _4614);
        break;
    } while(false);
    float _6668 = 0.0;
    do
    {
        if (_1780.uniforms.clip_shape_kind == 0u)
        {
            _6668 = 1.0;
            break;
        }
        vec2 _4674 = (_1780.uniforms.clip_rect.xy + (_1780.uniforms.clip_rect.zw * 0.5)) * _1780.uniforms.scale_factor;
        vec2 _4681 = (_1780.uniforms.clip_rect.zw * _1780.uniforms.scale_factor) * 0.5;
        float _6666 = 0.0;
        if (_1780.uniforms.clip_shape_kind == 1u)
        {
            vec4 _4690 = _1780.uniforms.clip_radii * _1780.uniforms.scale_factor;
            vec2 _4693 = _4523 - _4674;
            bool _4847 = _4693.y < 0.0;
            float _4861 = (_4693.x < 0.0) ? (_4847 ? _4690.x : _4690.w) : (_4847 ? _4690.y : _4690.z);
            vec2 _4868 = (abs(_4693) - _4681) + vec2(_4861);
            _6666 = (min(max(_4868.x, _4868.y), 0.0) + length(max(_4868, vec2(0.0)))) - _4861;
        }
        else
        {
            float _6667 = 0.0;
            if (_1780.uniforms.clip_shape_kind == 2u)
            {
                _6667 = length((_4523 - _4674) / max(_4681, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1780.uniforms.clip_shape_kind == 3u)
                {
                    uint _4714 = min(_1780.uniforms.clip_point_count, 32u);
                    uint _4717 = min(_1780.uniforms.clip_contour_count, 8u);
                    if ((_4714 < 3u) || (_4717 == 0u))
                    {
                        _6668 = 1.0;
                        break;
                    }
                    vec2 _4732 = _4523 - (_1780.uniforms.clip_rect.xy * _1780.uniforms.scale_factor);
                    bool _6649 = false;
                    do
                    {
                        if (_1780.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6648 = false;
                            _6648 = false;
                            uint _4931 = 0u;
                            bool _6770 = false;
                            for (uint _6647 = 0u, _6658 = 0u; _6647 < _4717; _6658 = _4931, _6648 = _6770, _6647++)
                            {
                                _4931 = min(_1780.uniforms.clip_polygon_end_points[_6647 / 4u][_6647 % 4u], _4714);
                                if (_4931 <= (_6658 + 1u))
                                {
                                    _6770 = _6648;
                                    continue;
                                }
                                bool _6661 = false;
                                _6661 = _6648;
                                bool _6775 = false;
                                for (uint _6659 = _6658; _6659 < _4931; _6661 = _6775, _6659++)
                                {
                                    uint _4947 = _6659 + 1u;
                                    uint _4953 = (_4947 < _4931) ? _4947 : _6658;
                                    uint _5046 = _6659 / 2u;
                                    bvec2 _5056 = bvec2((_6659 % 2u) == 0u);
                                    vec2 _4959 = vec2(_5056.x ? _1780.uniforms.clip_polygon_points[_5046].xy.x : _1780.uniforms.clip_polygon_points[_5046].zw.x, _5056.y ? _1780.uniforms.clip_polygon_points[_5046].xy.y : _1780.uniforms.clip_polygon_points[_5046].zw.y) * _1780.uniforms.scale_factor;
                                    uint _5062 = _4953 / 2u;
                                    bvec2 _5072 = bvec2((_4953 % 2u) == 0u);
                                    vec2 _4965 = vec2(_5072.x ? _1780.uniforms.clip_polygon_points[_5062].xy.x : _1780.uniforms.clip_polygon_points[_5062].zw.x, _5072.y ? _1780.uniforms.clip_polygon_points[_5062].xy.y : _1780.uniforms.clip_polygon_points[_5062].zw.y) * _1780.uniforms.scale_factor;
                                    float _4967 = _4965.y;
                                    float _4969 = _4959.y;
                                    float _4970 = _4967 - _4969;
                                    float _4982 = _4732.y;
                                    float _4995 = _4959.x;
                                    if (((_4969 > _4982) != (_4967 > _4982)) && (_4732.x < ((((_4965.x - _4995) * (_4982 - _4969)) / ((abs(_4970) < 9.9999997473787516355514526367188e-05) ? ((_4970 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4970)) + _4995)))
                                    {
                                        _6775 = !_6661;
                                    }
                                    else
                                    {
                                        _6775 = _6661;
                                    }
                                }
                                _6770 = _6661;
                            }
                            _6649 = _6648;
                            break;
                        }
                        int _6630 = 0;
                        _6630 = 0;
                        uint _5102 = 0u;
                        int _6758 = 0;
                        for (uint _6629 = 0u, _6631 = 0u; _6629 < _4717; _6631 = _5102, _6630 = _6758, _6629++)
                        {
                            _5102 = min(_1780.uniforms.clip_polygon_end_points[_6629 / 4u][_6629 % 4u], _4714);
                            if (_5102 <= (_6631 + 1u))
                            {
                                _6758 = _6630;
                                continue;
                            }
                            int _6634 = 0;
                            _6634 = _6630;
                            int _6765 = 0;
                            for (uint _6632 = _6631; _6632 < _5102; _6634 = _6765, _6632++)
                            {
                                uint _5118 = _6632 + 1u;
                                uint _5124 = (_5118 < _5102) ? _5118 : _6631;
                                uint _5239 = _6632 / 2u;
                                bvec2 _5249 = bvec2((_6632 % 2u) == 0u);
                                vec2 _5130 = vec2(_5249.x ? _1780.uniforms.clip_polygon_points[_5239].xy.x : _1780.uniforms.clip_polygon_points[_5239].zw.x, _5249.y ? _1780.uniforms.clip_polygon_points[_5239].xy.y : _1780.uniforms.clip_polygon_points[_5239].zw.y) * _1780.uniforms.scale_factor;
                                uint _5255 = _5124 / 2u;
                                bvec2 _5265 = bvec2((_5124 % 2u) == 0u);
                                vec2 _5136 = vec2(_5265.x ? _1780.uniforms.clip_polygon_points[_5255].xy.x : _1780.uniforms.clip_polygon_points[_5255].zw.x, _5265.y ? _1780.uniforms.clip_polygon_points[_5255].xy.y : _1780.uniforms.clip_polygon_points[_5255].zw.y) * _1780.uniforms.scale_factor;
                                float _5138 = _5130.y;
                                float _5140 = _4732.y;
                                if (_5138 <= _5140)
                                {
                                    float _5144 = _5136.y;
                                    int _6766 = 0;
                                    if (_5144 > _5140)
                                    {
                                        float _5152 = _5130.x;
                                        int _6767 = 0;
                                        if ((((_5136.x - _5152) * (_5140 - _5138)) - ((_4732.x - _5152) * (_5144 - _5138))) > 0.0)
                                        {
                                            _6767 = _6634 + 1;
                                        }
                                        else
                                        {
                                            _6767 = _6634;
                                        }
                                        _6766 = _6767;
                                    }
                                    else
                                    {
                                        _6766 = _6634;
                                    }
                                    _6765 = _6766;
                                }
                                else
                                {
                                    float _5181 = _5136.y;
                                    int _6768 = 0;
                                    if (_5181 <= _5140)
                                    {
                                        float _5189 = _5130.x;
                                        int _6769 = 0;
                                        if ((((_5136.x - _5189) * (_5140 - _5138)) - ((_4732.x - _5189) * (_5181 - _5138))) < 0.0)
                                        {
                                            _6769 = _6634 - 1;
                                        }
                                        else
                                        {
                                            _6769 = _6634;
                                        }
                                        _6768 = _6769;
                                    }
                                    else
                                    {
                                        _6768 = _6634;
                                    }
                                    _6765 = _6768;
                                }
                            }
                            _6758 = _6634;
                        }
                        _6649 = _6630 != 0;
                        break;
                    } while(false);
                    float _6651 = 0.0;
                    uint _6652 = 0u;
                    _6652 = 0u;
                    _6651 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4749 = 0u;
                    float _6771 = 0.0;
                    for (uint _6650 = 0u; _6650 < _4717; _6652 = _4749, _6651 = _6771, _6650++)
                    {
                        _4749 = min(_1780.uniforms.clip_polygon_end_points[_6650 / 4u][_6650 % 4u], _4714);
                        if (_4749 <= (_6652 + 1u))
                        {
                            _6771 = _6651;
                            continue;
                        }
                        float _6655 = 0.0;
                        _6655 = _6651;
                        for (uint _6653 = _6652; _6653 < _4749; )
                        {
                            uint _4765 = _6653 + 1u;
                            uint _4771 = (_4765 < _4749) ? _4765 : _6652;
                            uint _5279 = _6653 / 2u;
                            bvec2 _5289 = bvec2((_6653 % 2u) == 0u);
                            vec2 _4777 = vec2(_5289.x ? _1780.uniforms.clip_polygon_points[_5279].xy.x : _1780.uniforms.clip_polygon_points[_5279].zw.x, _5289.y ? _1780.uniforms.clip_polygon_points[_5279].xy.y : _1780.uniforms.clip_polygon_points[_5279].zw.y) * _1780.uniforms.scale_factor;
                            uint _5295 = _4771 / 2u;
                            bvec2 _5305 = bvec2((_4771 % 2u) == 0u);
                            vec2 _5314 = (vec2(_5305.x ? _1780.uniforms.clip_polygon_points[_5295].xy.x : _1780.uniforms.clip_polygon_points[_5295].zw.x, _5305.y ? _1780.uniforms.clip_polygon_points[_5295].xy.y : _1780.uniforms.clip_polygon_points[_5295].zw.y) * _1780.uniforms.scale_factor) - _4777;
                            _6655 = min(_6655, length(_4732 - (_4777 + (_5314 * clamp(dot(_4732 - _4777, _5314) / max(dot(_5314, _5314), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6653++;
                            continue;
                        }
                        _6771 = _6655;
                    }
                    float _4808 = max(length(vec2(dFdxFine(_4523.x), dFdyFine(_4523.y))) * 0.5, 0.75);
                    _6668 = smoothstep(_4808, -_4808, _6649 ? (-_6651) : _6651);
                    break;
                }
                _6667 = 1.0;
            }
            _6666 = _6667;
        }
        float _4830 = max((abs(dFdxFine(_6666)) + abs(dFdyFine(_6666))) * 0.5, 0.5);
        _6668 = smoothstep(_4830, -_4830, _6666);
        break;
    } while(false);
    bool _3752 = (instances_1._data[input_instance_id].packed_flags & 33554432u) != 0u;
    vec4 _6906 = vec4(0.0);
    _6906 = vec4(0.0);
    vec4 _6911 = vec4(0.0);
    SPIRV_CROSS_LOOP
    for (uint _6689 = 0u; _6689 < 2u; _6906 = _6911, _6689++)
    {
        bool _3760 = _6689 == 0u;
        if (true && (_3760 ? (_3373 > 0.0) : _3752))
        {
            vec2 _6732 = vec2(0.0);
            vec2 _6734 = vec2(0.0);
            vec4 _6737 = vec4(0.0);
            vec4 _6743 = vec4(0.0);
            float _6747 = 0.0;
            if (_3760)
            {
                float _3786 = ((instances_1._data[input_instance_id].packed_flags & 268435456u) != 0u) ? (instances_1._data[input_instance_id].noise_scale * _1780.uniforms.scale_factor) : 0.0;
                vec2 _6735 = vec2(0.0);
                vec4 _6738 = vec4(0.0);
                if (_3384)
                {
                    _6738 = max(_3354 + vec4(_3786), vec4(0.0));
                    _6735 = max(input_size + vec2(_3786), vec2(0.0));
                }
                else
                {
                    _6738 = _3354;
                    _6735 = input_size;
                }
                _6747 = _3373;
                _6743 = instances_1._data[input_instance_id].shadow_color;
                _6737 = _6738;
                _6734 = _6735;
                _6732 = _3380;
            }
            else
            {
                _6747 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].blur * _1780.uniforms.scale_factor;
                _6743 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].color;
                _6737 = _3354;
                _6734 = input_size;
                _6732 = vec2(shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_y) * _1780.uniforms.scale_factor;
            }
            vec2 _3851 = input_local_pos - _6732;
            float _6741 = 0.0;
            do
            {
                if (_3384)
                {
                    bool _5484 = _3851.y < 0.0;
                    float _5498 = (_3851.x < 0.0) ? (_5484 ? _6737.x : _6737.w) : (_5484 ? _6737.y : _6737.z);
                    vec2 _5505 = (abs(_3851) - _6734) + vec2(_5498);
                    _6741 = (min(max(_5505.x, _5505.y), 0.0) + length(max(_5505, vec2(0.0)))) - _5498;
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 1u)
                {
                    _6741 = length(_3851) - min(_6734.x, _6734.y);
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 4u)
                {
                    float _6740 = 0.0;
                    do
                    {
                        vec2 _5534 = max(_6734, vec2(0.001000000047497451305389404296875));
                        float _5539 = length(_3851 / _5534);
                        if (_5539 < 9.9999999747524270787835121154785e-07)
                        {
                            _6740 = -min(_5534.x, _5534.y);
                            break;
                        }
                        _6740 = (_5539 - 1.0) / max(length(_3851 / (_5534 * _5534)) / _5539, 9.9999999747524270787835121154785e-07);
                        break;
                    } while(false);
                    _6741 = _6740;
                    break;
                }
                _6741 = 1.0;
                break;
            } while(false);
            float _3868 = _6743.w * (smoothstep(_6747, -_6747, _6741) * (1.0 - _4515));
            _6911 = _6906 + (vec4(_6743.xyz * _3868, _3868) * (1.0 - _6906.w));
        }
        else
        {
            _6911 = _6906;
        }
    }
    vec4 _4233 = _6906 * (_6628 * _6668);
    if (_4233.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4233;
}

