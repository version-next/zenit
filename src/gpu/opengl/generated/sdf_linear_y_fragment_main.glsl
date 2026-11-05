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

struct GradientStop
{
    vec4 color;
    float position;
    float _pad0;
    float _pad1;
    float _pad2;
};

const uint _648[256] = uint[](0u, 128u, 32u, 160u, 8u, 136u, 40u, 168u, 2u, 130u, 34u, 162u, 10u, 138u, 42u, 170u, 192u, 64u, 224u, 96u, 200u, 72u, 232u, 104u, 194u, 66u, 226u, 98u, 202u, 74u, 234u, 106u, 48u, 176u, 16u, 144u, 56u, 184u, 24u, 152u, 50u, 178u, 18u, 146u, 58u, 186u, 26u, 154u, 240u, 112u, 208u, 80u, 248u, 120u, 216u, 88u, 242u, 114u, 210u, 82u, 250u, 122u, 218u, 90u, 12u, 140u, 44u, 172u, 4u, 132u, 36u, 164u, 14u, 142u, 46u, 174u, 6u, 134u, 38u, 166u, 204u, 76u, 236u, 108u, 196u, 68u, 228u, 100u, 206u, 78u, 238u, 110u, 198u, 70u, 230u, 102u, 60u, 188u, 28u, 156u, 52u, 180u, 20u, 148u, 62u, 190u, 30u, 158u, 54u, 182u, 22u, 150u, 252u, 124u, 220u, 92u, 244u, 116u, 212u, 84u, 254u, 126u, 222u, 94u, 246u, 118u, 214u, 86u, 3u, 131u, 35u, 163u, 11u, 139u, 43u, 171u, 1u, 129u, 33u, 161u, 9u, 137u, 41u, 169u, 195u, 67u, 227u, 99u, 203u, 75u, 235u, 107u, 193u, 65u, 225u, 97u, 201u, 73u, 233u, 105u, 51u, 179u, 19u, 147u, 59u, 187u, 27u, 155u, 49u, 177u, 17u, 145u, 57u, 185u, 25u, 153u, 243u, 115u, 211u, 83u, 251u, 123u, 219u, 91u, 241u, 113u, 209u, 81u, 249u, 121u, 217u, 89u, 15u, 143u, 47u, 175u, 7u, 135u, 39u, 167u, 13u, 141u, 45u, 173u, 5u, 133u, 37u, 165u, 207u, 79u, 239u, 111u, 199u, 71u, 231u, 103u, 205u, 77u, 237u, 109u, 197u, 69u, 229u, 101u, 63u, 191u, 31u, 159u, 55u, 183u, 23u, 151u, 61u, 189u, 29u, 157u, 53u, 181u, 21u, 149u, 255u, 127u, 223u, 95u, 247u, 119u, 215u, 87u, 253u, 125u, 221u, 93u, 245u, 117u, 213u, 85u);

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
} _1788;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

layout(binding = 2, std430) readonly buffer grad_stops
{
    GradientStop _data[];
} grad_stops_1;

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 2) in vec2 input_uv;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3124 = instances_1._data[input_instance_id].shadow_color;
    _3124.w = 0.0;
    vec4 _3398 = instances_1._data[input_instance_id].corner_radii * _1788.uniforms.scale_factor;
    float _3413 = instances_1._data[input_instance_id].border_width * _1788.uniforms.scale_factor;
    float _3417 = instances_1._data[input_instance_id].shadow_blur * _1788.uniforms.scale_factor;
    vec2 _3424 = vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1788.uniforms.scale_factor;
    bool _4296 = input_local_pos.y < 0.0;
    float _4310 = (input_local_pos.x < 0.0) ? (_4296 ? _3398.x : _3398.w) : (_4296 ? _3398.y : _3398.z);
    vec2 _4317 = (abs(input_local_pos) - input_size) + vec2(_4310);
    float _4329 = (min(max(_4317.x, _4317.y), 0.0) + length(max(_4317, vec2(0.0)))) - _4310;
    float _4544 = dFdxFine(_4329);
    float _4546 = dFdyFine(_4329);
    float _3492 = max(length(vec2(_4544, _4546)) * 0.5, 0.5);
    float _4557 = -_3492;
    float _4559 = smoothstep(_3492, _4557, _4329);
    bvec2 _4566 = bvec2(_1788.uniforms.raster_clip_pos != 0u);
    vec2 _4567 = vec2(_4566.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4566.y ? gl_FragCoord.xy.y : input_screen_pos.y);
    float _6732 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6732 = 1.0;
            break;
        }
        vec2 _4645 = abs(_4567 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1788.uniforms.scale_factor)) - ((input_rect_clip.zw * _1788.uniforms.scale_factor) * 0.5);
        float _4658 = min(max(_4645.x, _4645.y), 0.0) + length(max(_4645, vec2(0.0)));
        float _4631 = max((abs(dFdxFine(_4658)) + abs(dFdyFine(_4658))) * 0.5, 0.5);
        _6732 = smoothstep(_4631, -_4631, _4658);
        break;
    } while(false);
    float _6772 = 0.0;
    do
    {
        if (_1788.uniforms.clip_shape_kind == 0u)
        {
            _6772 = 1.0;
            break;
        }
        vec2 _4718 = (_1788.uniforms.clip_rect.xy + (_1788.uniforms.clip_rect.zw * 0.5)) * _1788.uniforms.scale_factor;
        vec2 _4725 = (_1788.uniforms.clip_rect.zw * _1788.uniforms.scale_factor) * 0.5;
        float _6770 = 0.0;
        if (_1788.uniforms.clip_shape_kind == 1u)
        {
            vec4 _4734 = _1788.uniforms.clip_radii * _1788.uniforms.scale_factor;
            vec2 _4737 = _4567 - _4718;
            bool _4891 = _4737.y < 0.0;
            float _4905 = (_4737.x < 0.0) ? (_4891 ? _4734.x : _4734.w) : (_4891 ? _4734.y : _4734.z);
            vec2 _4912 = (abs(_4737) - _4725) + vec2(_4905);
            _6770 = (min(max(_4912.x, _4912.y), 0.0) + length(max(_4912, vec2(0.0)))) - _4905;
        }
        else
        {
            float _6771 = 0.0;
            if (_1788.uniforms.clip_shape_kind == 2u)
            {
                _6771 = length((_4567 - _4718) / max(_4725, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1788.uniforms.clip_shape_kind == 3u)
                {
                    uint _4758 = min(_1788.uniforms.clip_point_count, 32u);
                    uint _4761 = min(_1788.uniforms.clip_contour_count, 8u);
                    if ((_4758 < 3u) || (_4761 == 0u))
                    {
                        _6772 = 1.0;
                        break;
                    }
                    vec2 _4776 = _4567 - (_1788.uniforms.clip_rect.xy * _1788.uniforms.scale_factor);
                    bool _6753 = false;
                    do
                    {
                        if (_1788.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6752 = false;
                            _6752 = false;
                            uint _4975 = 0u;
                            bool _6874 = false;
                            for (uint _6751 = 0u, _6762 = 0u; _6751 < _4761; _6762 = _4975, _6752 = _6874, _6751++)
                            {
                                _4975 = min(_1788.uniforms.clip_polygon_end_points[_6751 / 4u][_6751 % 4u], _4758);
                                if (_4975 <= (_6762 + 1u))
                                {
                                    _6874 = _6752;
                                    continue;
                                }
                                bool _6765 = false;
                                _6765 = _6752;
                                bool _6879 = false;
                                for (uint _6763 = _6762; _6763 < _4975; _6765 = _6879, _6763++)
                                {
                                    uint _4991 = _6763 + 1u;
                                    uint _4997 = (_4991 < _4975) ? _4991 : _6762;
                                    uint _5090 = _6763 / 2u;
                                    bvec2 _5100 = bvec2((_6763 % 2u) == 0u);
                                    vec2 _5003 = vec2(_5100.x ? _1788.uniforms.clip_polygon_points[_5090].xy.x : _1788.uniforms.clip_polygon_points[_5090].zw.x, _5100.y ? _1788.uniforms.clip_polygon_points[_5090].xy.y : _1788.uniforms.clip_polygon_points[_5090].zw.y) * _1788.uniforms.scale_factor;
                                    uint _5106 = _4997 / 2u;
                                    bvec2 _5116 = bvec2((_4997 % 2u) == 0u);
                                    vec2 _5009 = vec2(_5116.x ? _1788.uniforms.clip_polygon_points[_5106].xy.x : _1788.uniforms.clip_polygon_points[_5106].zw.x, _5116.y ? _1788.uniforms.clip_polygon_points[_5106].xy.y : _1788.uniforms.clip_polygon_points[_5106].zw.y) * _1788.uniforms.scale_factor;
                                    float _5011 = _5009.y;
                                    float _5013 = _5003.y;
                                    float _5014 = _5011 - _5013;
                                    float _5026 = _4776.y;
                                    float _5039 = _5003.x;
                                    if (((_5013 > _5026) != (_5011 > _5026)) && (_4776.x < ((((_5009.x - _5039) * (_5026 - _5013)) / ((abs(_5014) < 9.9999997473787516355514526367188e-05) ? ((_5014 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _5014)) + _5039)))
                                    {
                                        _6879 = !_6765;
                                    }
                                    else
                                    {
                                        _6879 = _6765;
                                    }
                                }
                                _6874 = _6765;
                            }
                            _6753 = _6752;
                            break;
                        }
                        int _6734 = 0;
                        _6734 = 0;
                        uint _5146 = 0u;
                        int _6862 = 0;
                        for (uint _6733 = 0u, _6735 = 0u; _6733 < _4761; _6735 = _5146, _6734 = _6862, _6733++)
                        {
                            _5146 = min(_1788.uniforms.clip_polygon_end_points[_6733 / 4u][_6733 % 4u], _4758);
                            if (_5146 <= (_6735 + 1u))
                            {
                                _6862 = _6734;
                                continue;
                            }
                            int _6738 = 0;
                            _6738 = _6734;
                            int _6869 = 0;
                            for (uint _6736 = _6735; _6736 < _5146; _6738 = _6869, _6736++)
                            {
                                uint _5162 = _6736 + 1u;
                                uint _5168 = (_5162 < _5146) ? _5162 : _6735;
                                uint _5283 = _6736 / 2u;
                                bvec2 _5293 = bvec2((_6736 % 2u) == 0u);
                                vec2 _5174 = vec2(_5293.x ? _1788.uniforms.clip_polygon_points[_5283].xy.x : _1788.uniforms.clip_polygon_points[_5283].zw.x, _5293.y ? _1788.uniforms.clip_polygon_points[_5283].xy.y : _1788.uniforms.clip_polygon_points[_5283].zw.y) * _1788.uniforms.scale_factor;
                                uint _5299 = _5168 / 2u;
                                bvec2 _5309 = bvec2((_5168 % 2u) == 0u);
                                vec2 _5180 = vec2(_5309.x ? _1788.uniforms.clip_polygon_points[_5299].xy.x : _1788.uniforms.clip_polygon_points[_5299].zw.x, _5309.y ? _1788.uniforms.clip_polygon_points[_5299].xy.y : _1788.uniforms.clip_polygon_points[_5299].zw.y) * _1788.uniforms.scale_factor;
                                float _5182 = _5174.y;
                                float _5184 = _4776.y;
                                if (_5182 <= _5184)
                                {
                                    float _5188 = _5180.y;
                                    int _6870 = 0;
                                    if (_5188 > _5184)
                                    {
                                        float _5196 = _5174.x;
                                        int _6871 = 0;
                                        if ((((_5180.x - _5196) * (_5184 - _5182)) - ((_4776.x - _5196) * (_5188 - _5182))) > 0.0)
                                        {
                                            _6871 = _6738 + 1;
                                        }
                                        else
                                        {
                                            _6871 = _6738;
                                        }
                                        _6870 = _6871;
                                    }
                                    else
                                    {
                                        _6870 = _6738;
                                    }
                                    _6869 = _6870;
                                }
                                else
                                {
                                    float _5225 = _5180.y;
                                    int _6872 = 0;
                                    if (_5225 <= _5184)
                                    {
                                        float _5233 = _5174.x;
                                        int _6873 = 0;
                                        if ((((_5180.x - _5233) * (_5184 - _5182)) - ((_4776.x - _5233) * (_5225 - _5182))) < 0.0)
                                        {
                                            _6873 = _6738 - 1;
                                        }
                                        else
                                        {
                                            _6873 = _6738;
                                        }
                                        _6872 = _6873;
                                    }
                                    else
                                    {
                                        _6872 = _6738;
                                    }
                                    _6869 = _6872;
                                }
                            }
                            _6862 = _6738;
                        }
                        _6753 = _6734 != 0;
                        break;
                    } while(false);
                    float _6755 = 0.0;
                    uint _6756 = 0u;
                    _6756 = 0u;
                    _6755 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4793 = 0u;
                    float _6875 = 0.0;
                    for (uint _6754 = 0u; _6754 < _4761; _6756 = _4793, _6755 = _6875, _6754++)
                    {
                        _4793 = min(_1788.uniforms.clip_polygon_end_points[_6754 / 4u][_6754 % 4u], _4758);
                        if (_4793 <= (_6756 + 1u))
                        {
                            _6875 = _6755;
                            continue;
                        }
                        float _6759 = 0.0;
                        _6759 = _6755;
                        for (uint _6757 = _6756; _6757 < _4793; )
                        {
                            uint _4809 = _6757 + 1u;
                            uint _4815 = (_4809 < _4793) ? _4809 : _6756;
                            uint _5323 = _6757 / 2u;
                            bvec2 _5333 = bvec2((_6757 % 2u) == 0u);
                            vec2 _4821 = vec2(_5333.x ? _1788.uniforms.clip_polygon_points[_5323].xy.x : _1788.uniforms.clip_polygon_points[_5323].zw.x, _5333.y ? _1788.uniforms.clip_polygon_points[_5323].xy.y : _1788.uniforms.clip_polygon_points[_5323].zw.y) * _1788.uniforms.scale_factor;
                            uint _5339 = _4815 / 2u;
                            bvec2 _5349 = bvec2((_4815 % 2u) == 0u);
                            vec2 _5358 = (vec2(_5349.x ? _1788.uniforms.clip_polygon_points[_5339].xy.x : _1788.uniforms.clip_polygon_points[_5339].zw.x, _5349.y ? _1788.uniforms.clip_polygon_points[_5339].xy.y : _1788.uniforms.clip_polygon_points[_5339].zw.y) * _1788.uniforms.scale_factor) - _4821;
                            _6759 = min(_6759, length(_4776 - (_4821 + (_5358 * clamp(dot(_4776 - _4821, _5358) / max(dot(_5358, _5358), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6757++;
                            continue;
                        }
                        _6875 = _6759;
                    }
                    float _4852 = max(length(vec2(dFdxFine(_4567.x), dFdyFine(_4567.y))) * 0.5, 0.75);
                    _6772 = smoothstep(_4852, -_4852, _6753 ? (-_6755) : _6755);
                    break;
                }
                _6771 = 1.0;
            }
            _6770 = _6771;
        }
        float _4874 = max((abs(dFdxFine(_6770)) + abs(dFdyFine(_6770))) * 0.5, 0.5);
        _6772 = smoothstep(_4874, -_4874, _6770);
        break;
    } while(false);
    vec4 _3586 = instances_1._data[input_instance_id].border_widths * _1788.uniforms.scale_factor;
    float _3588 = _3586.x;
    float _3590 = _3586.y;
    float _3593 = _3586.z;
    float _3596 = _3586.w;
    float _6813 = 0.0;
    if (true && (((((_3588 + _3590) + _3593) + _3596) > 0.0) && true))
    {
        vec4 _3683 = max(_3398 - vec4(max(_3588, _3596), max(_3588, _3590), max(_3593, _3590), max(_3593, _3596)), vec4(0.0));
        vec2 _3687 = input_local_pos - vec2((_3596 - _3590) * 0.5, (_3588 - _3593) * 0.5);
        bool _5388 = _3687.y < 0.0;
        float _5402 = (_3687.x < 0.0) ? (_5388 ? _3683.x : _3683.w) : (_5388 ? _3683.y : _3683.z);
        vec2 _5409 = (abs(_3687) - max(vec2(input_size.x - ((_3590 + _3596) * 0.5), input_size.y - ((_3588 + _3593) * 0.5)), vec2(0.0))) + vec2(_5402);
        _6813 = _4559 - smoothstep(_3492, _4557, (min(max(_5409.x, _5409.y), 0.0) + length(max(_5409, vec2(0.0)))) - _5402);
    }
    else
    {
        float _6814 = 0.0;
        if (true && (_3413 > 0.0))
        {
            _6814 = _4559 - smoothstep(_3492, _4557, _4329 + _3413);
        }
        else
        {
            _6814 = 0.0;
        }
        _6813 = _6814;
    }
    vec4 _7078 = vec4(0.0);
    _7078 = vec4(0.0);
    vec4 _7085 = vec4(0.0);
    SPIRV_CROSS_LOOP
    for (uint _6793 = 0u; _6793 < 2u; _7078 = _7085, _6793++)
    {
        bool _3804 = _6793 == 0u;
        if (true && (_3804 ? (_3417 > 0.0) : false))
        {
            vec2 _6836 = vec2(0.0);
            vec2 _6838 = vec2(0.0);
            vec4 _6841 = vec4(0.0);
            vec4 _6847 = vec4(0.0);
            float _6851 = 0.0;
            if (_3804)
            {
                _6851 = _3417;
                _6847 = _3124;
                _6841 = max(_3398, vec4(0.0));
                _6838 = max(input_size, vec2(0.0));
                _6836 = _3424;
            }
            else
            {
                _6851 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].blur * _1788.uniforms.scale_factor;
                _6847 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].color;
                _6841 = _3398;
                _6838 = input_size;
                _6836 = vec2(shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_y) * _1788.uniforms.scale_factor;
            }
            vec2 _3895 = input_local_pos - _6836;
            bool _5528 = _3895.y < 0.0;
            float _5542 = (_3895.x < 0.0) ? (_5528 ? _6841.x : _6841.w) : (_5528 ? _6841.y : _6841.z);
            vec2 _5549 = (abs(_3895) - _6838) + vec2(_5542);
            float _3912 = _6847.w * (smoothstep(_6851, -_6851, (min(max(_5549.x, _5549.y), 0.0) + length(max(_5549, vec2(0.0)))) - _5542) * (1.0 - _4559));
            _7085 = _7078 + (vec4(_6847.xyz * _3912, _3912) * (1.0 - _7078.w));
        }
        else
        {
            _7085 = _7078;
        }
    }
    vec4 _7082 = vec4(0.0);
    if (true && (_4559 > 0.0))
    {
        float _4014 = ((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y);
        float _4082 = clamp(clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_4014 * 2.0))) - vec2(_4014)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0)).x, 0.0, 1.0);
        vec4 _7076 = vec4(0.0);
        if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
        {
            vec4 _6805 = vec4(0.0);
            do
            {
                if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                {
                    _6805 = vec4(0.0);
                    break;
                }
                if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                {
                    _6805 = vec4(1.0, 0.0, 1.0, 1.0);
                    break;
                }
                if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                {
                    _6805 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                    break;
                }
                uint _5656 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                float _5662 = clamp(_4082, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5656].position);
                vec4 _6802 = vec4(0.0);
                _6802 = grad_stops_1._data[_5656].color;
                bool _7092 = false;
                vec4 _6880 = vec4(0.0);
                uint _6801 = 0u;
                bool _6803 = false;
                for (; _6801 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6803 = _7092, _6802 = _6880, _6801++)
                {
                    uint _5678 = instances_1._data[input_instance_id].gradient_stop_offset + _6801;
                    uint _5694 = _5678 + 1u;
                    bool _5718 = ((!_6803) && (_5662 >= grad_stops_1._data[_5678].position)) && (_5662 <= grad_stops_1._data[_5694].position);
                    if (_5718)
                    {
                        float _5724 = grad_stops_1._data[_5694].position - grad_stops_1._data[_5678].position;
                        vec4 _5742 = mix(vec4(grad_stops_1._data[_5678].color.xyz * grad_stops_1._data[_5678].color.w, grad_stops_1._data[_5678].color.w), vec4(grad_stops_1._data[_5694].color.xyz * grad_stops_1._data[_5694].color.w, grad_stops_1._data[_5694].color.w), vec4((_5724 > 9.9999999747524270787835121154785e-07) ? ((_5662 - grad_stops_1._data[_5678].position) / _5724) : 0.0));
                        vec4 _5794 = vec4(_5742.xyz / vec3(_5742.w), _5742.w);
                        bvec4 _5795 = bvec4(_5742.w > 9.9999999747524270787835121154785e-07);
                        _6880 = vec4(_5795.x ? _5794.x : vec4(0.0).x, _5795.y ? _5794.y : vec4(0.0).y, _5795.z ? _5794.z : vec4(0.0).z, _5795.w ? _5794.w : vec4(0.0).w);
                    }
                    else
                    {
                        _6880 = _6802;
                    }
                    _7092 = _5718 ? true : _6803;
                }
                _6805 = _6802;
                break;
            } while(false);
            _7076 = _6805;
        }
        else
        {
            vec4 _4106 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_4082));
            float _5826 = _4106.w;
            vec4 _5839 = vec4(_4106.xyz / vec3(_5826), _5826);
            bvec4 _5840 = bvec4(_5826 > 9.9999999747524270787835121154785e-07);
            _7076 = vec4(_5840.x ? _5839.x : vec4(0.0).x, _5840.y ? _5839.y : vec4(0.0).y, _5840.z ? _5839.z : vec4(0.0).z, _5840.w ? _5839.w : vec4(0.0).w);
        }
        float _4185 = _7076.w * _4559;
        vec4 _7089 = vec4(clamp(_7076.xyz + vec3((float(_648[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0)), _4185);
        vec3 _4191 = _7089.xyz * _4185;
        _7089.x = _4191.x;
        _7089.y = _4191.y;
        _7089.z = _4191.z;
        _7082 = _7078 + (_7089 * (1.0 - _7078.w));
    }
    else
    {
        _7082 = _7078;
    }
    vec4 _7083 = vec4(0.0);
    if (true && (_6813 > 0.0))
    {
        float _4257 = instances_1._data[input_instance_id].border_color.w * _6813;
        _7083 = _7082 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4257, _4257) * (1.0 - _7082.w));
    }
    else
    {
        _7083 = _7082;
    }
    vec4 _4277 = _7083 * (_6732 * _6772);
    if (_4277.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4277;
}

