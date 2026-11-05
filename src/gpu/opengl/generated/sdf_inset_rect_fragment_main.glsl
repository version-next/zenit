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
    uint frame_seed;
    uint raster_clip_pos;
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
    vec4 _3362 = instances_1._data[input_instance_id].corner_radii * _1780.uniforms.scale_factor;
    float _3377 = instances_1._data[input_instance_id].border_width * _1780.uniforms.scale_factor;
    bool _4260 = input_local_pos.y < 0.0;
    float _4262 = _3362.x;
    float _4264 = _3362.w;
    float _4270 = _3362.y;
    float _4272 = _3362.z;
    float _4274 = (input_local_pos.x < 0.0) ? (_4260 ? _4262 : _4264) : (_4260 ? _4270 : _4272);
    vec2 _4281 = (abs(input_local_pos) - input_size) + vec2(_4274);
    float _4293 = (min(max(_4281.x, _4281.y), 0.0) + length(max(_4281, vec2(0.0)))) - _4274;
    float _4508 = dFdxFine(_4293);
    float _4510 = dFdyFine(_4293);
    float _3456 = max(length(vec2(_4508, _4510)) * 0.5, 0.5);
    float _4521 = -_3456;
    float _4523 = smoothstep(_3456, _4521, _4293);
    bvec2 _4530 = bvec2(_1780.uniforms.raster_clip_pos != 0u);
    vec2 _4531 = vec2(_4530.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4530.y ? gl_FragCoord.xy.y : input_screen_pos.y);
    float _6695 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6695 = 1.0;
            break;
        }
        vec2 _4609 = abs(_4531 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1780.uniforms.scale_factor)) - ((input_rect_clip.zw * _1780.uniforms.scale_factor) * 0.5);
        float _4622 = min(max(_4609.x, _4609.y), 0.0) + length(max(_4609, vec2(0.0)));
        float _4595 = max((abs(dFdxFine(_4622)) + abs(dFdyFine(_4622))) * 0.5, 0.5);
        _6695 = smoothstep(_4595, -_4595, _4622);
        break;
    } while(false);
    float _6735 = 0.0;
    do
    {
        if (_1780.uniforms.clip_shape_kind == 0u)
        {
            _6735 = 1.0;
            break;
        }
        vec2 _4682 = (_1780.uniforms.clip_rect.xy + (_1780.uniforms.clip_rect.zw * 0.5)) * _1780.uniforms.scale_factor;
        vec2 _4689 = (_1780.uniforms.clip_rect.zw * _1780.uniforms.scale_factor) * 0.5;
        float _6733 = 0.0;
        if (_1780.uniforms.clip_shape_kind == 1u)
        {
            vec4 _4698 = _1780.uniforms.clip_radii * _1780.uniforms.scale_factor;
            vec2 _4701 = _4531 - _4682;
            bool _4855 = _4701.y < 0.0;
            float _4869 = (_4701.x < 0.0) ? (_4855 ? _4698.x : _4698.w) : (_4855 ? _4698.y : _4698.z);
            vec2 _4876 = (abs(_4701) - _4689) + vec2(_4869);
            _6733 = (min(max(_4876.x, _4876.y), 0.0) + length(max(_4876, vec2(0.0)))) - _4869;
        }
        else
        {
            float _6734 = 0.0;
            if (_1780.uniforms.clip_shape_kind == 2u)
            {
                _6734 = length((_4531 - _4682) / max(_4689, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1780.uniforms.clip_shape_kind == 3u)
                {
                    uint _4722 = min(_1780.uniforms.clip_point_count, 32u);
                    uint _4725 = min(_1780.uniforms.clip_contour_count, 8u);
                    if ((_4722 < 3u) || (_4725 == 0u))
                    {
                        _6735 = 1.0;
                        break;
                    }
                    vec2 _4740 = _4531 - (_1780.uniforms.clip_rect.xy * _1780.uniforms.scale_factor);
                    bool _6716 = false;
                    do
                    {
                        if (_1780.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6715 = false;
                            _6715 = false;
                            uint _4939 = 0u;
                            bool _6837 = false;
                            for (uint _6714 = 0u, _6725 = 0u; _6714 < _4725; _6725 = _4939, _6715 = _6837, _6714++)
                            {
                                _4939 = min(_1780.uniforms.clip_polygon_end_points[_6714 / 4u][_6714 % 4u], _4722);
                                if (_4939 <= (_6725 + 1u))
                                {
                                    _6837 = _6715;
                                    continue;
                                }
                                bool _6728 = false;
                                _6728 = _6715;
                                bool _6842 = false;
                                for (uint _6726 = _6725; _6726 < _4939; _6728 = _6842, _6726++)
                                {
                                    uint _4955 = _6726 + 1u;
                                    uint _4961 = (_4955 < _4939) ? _4955 : _6725;
                                    uint _5054 = _6726 / 2u;
                                    bvec2 _5064 = bvec2((_6726 % 2u) == 0u);
                                    vec2 _4967 = vec2(_5064.x ? _1780.uniforms.clip_polygon_points[_5054].xy.x : _1780.uniforms.clip_polygon_points[_5054].zw.x, _5064.y ? _1780.uniforms.clip_polygon_points[_5054].xy.y : _1780.uniforms.clip_polygon_points[_5054].zw.y) * _1780.uniforms.scale_factor;
                                    uint _5070 = _4961 / 2u;
                                    bvec2 _5080 = bvec2((_4961 % 2u) == 0u);
                                    vec2 _4973 = vec2(_5080.x ? _1780.uniforms.clip_polygon_points[_5070].xy.x : _1780.uniforms.clip_polygon_points[_5070].zw.x, _5080.y ? _1780.uniforms.clip_polygon_points[_5070].xy.y : _1780.uniforms.clip_polygon_points[_5070].zw.y) * _1780.uniforms.scale_factor;
                                    float _4975 = _4973.y;
                                    float _4977 = _4967.y;
                                    float _4978 = _4975 - _4977;
                                    float _4990 = _4740.y;
                                    float _5003 = _4967.x;
                                    if (((_4977 > _4990) != (_4975 > _4990)) && (_4740.x < ((((_4973.x - _5003) * (_4990 - _4977)) / ((abs(_4978) < 9.9999997473787516355514526367188e-05) ? ((_4978 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4978)) + _5003)))
                                    {
                                        _6842 = !_6728;
                                    }
                                    else
                                    {
                                        _6842 = _6728;
                                    }
                                }
                                _6837 = _6728;
                            }
                            _6716 = _6715;
                            break;
                        }
                        int _6697 = 0;
                        _6697 = 0;
                        uint _5110 = 0u;
                        int _6825 = 0;
                        for (uint _6696 = 0u, _6698 = 0u; _6696 < _4725; _6698 = _5110, _6697 = _6825, _6696++)
                        {
                            _5110 = min(_1780.uniforms.clip_polygon_end_points[_6696 / 4u][_6696 % 4u], _4722);
                            if (_5110 <= (_6698 + 1u))
                            {
                                _6825 = _6697;
                                continue;
                            }
                            int _6701 = 0;
                            _6701 = _6697;
                            int _6832 = 0;
                            for (uint _6699 = _6698; _6699 < _5110; _6701 = _6832, _6699++)
                            {
                                uint _5126 = _6699 + 1u;
                                uint _5132 = (_5126 < _5110) ? _5126 : _6698;
                                uint _5247 = _6699 / 2u;
                                bvec2 _5257 = bvec2((_6699 % 2u) == 0u);
                                vec2 _5138 = vec2(_5257.x ? _1780.uniforms.clip_polygon_points[_5247].xy.x : _1780.uniforms.clip_polygon_points[_5247].zw.x, _5257.y ? _1780.uniforms.clip_polygon_points[_5247].xy.y : _1780.uniforms.clip_polygon_points[_5247].zw.y) * _1780.uniforms.scale_factor;
                                uint _5263 = _5132 / 2u;
                                bvec2 _5273 = bvec2((_5132 % 2u) == 0u);
                                vec2 _5144 = vec2(_5273.x ? _1780.uniforms.clip_polygon_points[_5263].xy.x : _1780.uniforms.clip_polygon_points[_5263].zw.x, _5273.y ? _1780.uniforms.clip_polygon_points[_5263].xy.y : _1780.uniforms.clip_polygon_points[_5263].zw.y) * _1780.uniforms.scale_factor;
                                float _5146 = _5138.y;
                                float _5148 = _4740.y;
                                if (_5146 <= _5148)
                                {
                                    float _5152 = _5144.y;
                                    int _6833 = 0;
                                    if (_5152 > _5148)
                                    {
                                        float _5160 = _5138.x;
                                        int _6834 = 0;
                                        if ((((_5144.x - _5160) * (_5148 - _5146)) - ((_4740.x - _5160) * (_5152 - _5146))) > 0.0)
                                        {
                                            _6834 = _6701 + 1;
                                        }
                                        else
                                        {
                                            _6834 = _6701;
                                        }
                                        _6833 = _6834;
                                    }
                                    else
                                    {
                                        _6833 = _6701;
                                    }
                                    _6832 = _6833;
                                }
                                else
                                {
                                    float _5189 = _5144.y;
                                    int _6835 = 0;
                                    if (_5189 <= _5148)
                                    {
                                        float _5197 = _5138.x;
                                        int _6836 = 0;
                                        if ((((_5144.x - _5197) * (_5148 - _5146)) - ((_4740.x - _5197) * (_5189 - _5146))) < 0.0)
                                        {
                                            _6836 = _6701 - 1;
                                        }
                                        else
                                        {
                                            _6836 = _6701;
                                        }
                                        _6835 = _6836;
                                    }
                                    else
                                    {
                                        _6835 = _6701;
                                    }
                                    _6832 = _6835;
                                }
                            }
                            _6825 = _6701;
                        }
                        _6716 = _6697 != 0;
                        break;
                    } while(false);
                    float _6718 = 0.0;
                    uint _6719 = 0u;
                    _6719 = 0u;
                    _6718 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4757 = 0u;
                    float _6838 = 0.0;
                    for (uint _6717 = 0u; _6717 < _4725; _6719 = _4757, _6718 = _6838, _6717++)
                    {
                        _4757 = min(_1780.uniforms.clip_polygon_end_points[_6717 / 4u][_6717 % 4u], _4722);
                        if (_4757 <= (_6719 + 1u))
                        {
                            _6838 = _6718;
                            continue;
                        }
                        float _6722 = 0.0;
                        _6722 = _6718;
                        for (uint _6720 = _6719; _6720 < _4757; )
                        {
                            uint _4773 = _6720 + 1u;
                            uint _4779 = (_4773 < _4757) ? _4773 : _6719;
                            uint _5287 = _6720 / 2u;
                            bvec2 _5297 = bvec2((_6720 % 2u) == 0u);
                            vec2 _4785 = vec2(_5297.x ? _1780.uniforms.clip_polygon_points[_5287].xy.x : _1780.uniforms.clip_polygon_points[_5287].zw.x, _5297.y ? _1780.uniforms.clip_polygon_points[_5287].xy.y : _1780.uniforms.clip_polygon_points[_5287].zw.y) * _1780.uniforms.scale_factor;
                            uint _5303 = _4779 / 2u;
                            bvec2 _5313 = bvec2((_4779 % 2u) == 0u);
                            vec2 _5322 = (vec2(_5313.x ? _1780.uniforms.clip_polygon_points[_5303].xy.x : _1780.uniforms.clip_polygon_points[_5303].zw.x, _5313.y ? _1780.uniforms.clip_polygon_points[_5303].xy.y : _1780.uniforms.clip_polygon_points[_5303].zw.y) * _1780.uniforms.scale_factor) - _4785;
                            _6722 = min(_6722, length(_4740 - (_4785 + (_5322 * clamp(dot(_4740 - _4785, _5322) / max(dot(_5322, _5322), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6720++;
                            continue;
                        }
                        _6838 = _6722;
                    }
                    float _4816 = max(length(vec2(dFdxFine(_4531.x), dFdyFine(_4531.y))) * 0.5, 0.75);
                    _6735 = smoothstep(_4816, -_4816, _6716 ? (-_6718) : _6718);
                    break;
                }
                _6734 = 1.0;
            }
            _6733 = _6734;
        }
        float _4838 = max((abs(dFdxFine(_6733)) + abs(dFdyFine(_6733))) * 0.5, 0.5);
        _6735 = smoothstep(_4838, -_4838, _6733);
        break;
    } while(false);
    vec4 _3550 = instances_1._data[input_instance_id].border_widths * _1780.uniforms.scale_factor;
    float _3552 = _3550.x;
    float _3554 = _3550.y;
    float _3557 = _3550.z;
    float _3560 = _3550.w;
    bool _3579 = true && (_4523 > 0.0);
    float _6776 = 0.0;
    if (true && (((((_3552 + _3554) + _3557) + _3560) > 0.0) && true))
    {
        vec4 _3647 = max(_3362 - vec4(max(_3552, _3560), max(_3552, _3554), max(_3557, _3554), max(_3557, _3560)), vec4(0.0));
        vec2 _3651 = input_local_pos - vec2((_3560 - _3554) * 0.5, (_3552 - _3557) * 0.5);
        bool _5352 = _3651.y < 0.0;
        float _5366 = (_3651.x < 0.0) ? (_5352 ? _3647.x : _3647.w) : (_5352 ? _3647.y : _3647.z);
        vec2 _5373 = (abs(_3651) - max(vec2(input_size.x - ((_3554 + _3560) * 0.5), input_size.y - ((_3552 + _3557) * 0.5)), vec2(0.0))) + vec2(_5366);
        _6776 = _4523 - smoothstep(_3456, _4521, (min(max(_5373.x, _5373.y), 0.0) + length(max(_5373, vec2(0.0)))) - _5366);
    }
    else
    {
        float _6777 = 0.0;
        if (true && (_3377 > 0.0))
        {
            _6777 = _4523 - smoothstep(_3456, _4521, _4293 + _3377);
        }
        else
        {
            _6777 = 0.0;
        }
        _6776 = _6777;
    }
    vec4 _7017 = vec4(0.0);
    if (_3579)
    {
        float _4149 = instances_1._data[input_instance_id].fill_color.w * _4523;
        _7017 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _4149, _4149) * 1.0;
    }
    else
    {
        _7017 = vec4(0.0);
    }
    vec4 _7018 = vec4(0.0);
    if (_3579)
    {
        vec2 _4172 = input_local_pos - (vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1780.uniforms.scale_factor);
        bool _6307 = _4172.y < 0.0;
        float _6321 = (_4172.x < 0.0) ? (_6307 ? _4262 : _4264) : (_6307 ? _4270 : _4272);
        vec2 _6328 = (abs(_4172) - input_size) + vec2(_6321);
        float _4193 = instances_1._data[input_instance_id].shadow_color.w * (_4523 * smoothstep(-max(instances_1._data[input_instance_id].shadow_blur * _1780.uniforms.scale_factor, 1.0), 0.0, (min(max(_6328.x, _6328.y), 0.0) + length(max(_6328, vec2(0.0)))) - _6321));
        _7018 = _7017 + (vec4(instances_1._data[input_instance_id].shadow_color.xyz * _4193, _4193) * (1.0 - _7017.w));
    }
    else
    {
        _7018 = _7017;
    }
    vec4 _7019 = vec4(0.0);
    if (true && (_6776 > 0.0))
    {
        float _4221 = instances_1._data[input_instance_id].border_color.w * _6776;
        _7019 = _7018 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4221, _4221) * (1.0 - _7018.w));
    }
    else
    {
        _7019 = _7018;
    }
    vec4 _4241 = _7019 * (_6695 * _6735);
    if (_4241.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4241;
}

