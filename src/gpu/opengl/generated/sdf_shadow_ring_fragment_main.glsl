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

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _1788;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 2) in vec2 input_uv;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    uint _3107 = input_solid_shape & 268435456u;
    vec4 _3348 = input_solid_radii * _1788.uniforms.scale_factor;
    float _3367 = input_solid_border.x * _1788.uniforms.scale_factor;
    vec2 _3374 = vec2(input_solid_metrics.y, input_solid_metrics.z) * _1788.uniforms.scale_factor;
    bool _4246 = input_local_pos.y < 0.0;
    float _4248 = _3348.x;
    float _4250 = _3348.w;
    float _4256 = _3348.y;
    float _4258 = _3348.z;
    float _4260 = (input_local_pos.x < 0.0) ? (_4246 ? _4248 : _4250) : (_4246 ? _4256 : _4258);
    vec2 _4267 = (abs(input_local_pos) - input_size) + vec2(_4260);
    float _4279 = (min(max(_4267.x, _4267.y), 0.0) + length(max(_4267, vec2(0.0)))) - _4260;
    float _4494 = dFdxFine(_4279);
    float _4496 = dFdyFine(_4279);
    float _3442 = max(length(vec2(_4494, _4496)) * 0.5, 0.5);
    float _4509 = smoothstep(_3442, -_3442, _4279);
    bvec2 _4516 = bvec2(_1788.uniforms.raster_clip_pos != 0u);
    vec2 _4517 = vec2(_4516.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4516.y ? gl_FragCoord.xy.y : input_screen_pos.y);
    float _6710 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6710 = 1.0;
            break;
        }
        vec2 _4595 = abs(_4517 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1788.uniforms.scale_factor)) - ((input_rect_clip.zw * _1788.uniforms.scale_factor) * 0.5);
        float _4608 = min(max(_4595.x, _4595.y), 0.0) + length(max(_4595, vec2(0.0)));
        float _4581 = max((abs(dFdxFine(_4608)) + abs(dFdyFine(_4608))) * 0.5, 0.5);
        _6710 = smoothstep(_4581, -_4581, _4608);
        break;
    } while(false);
    float _6750 = 0.0;
    do
    {
        if (_1788.uniforms.clip_shape_kind == 0u)
        {
            _6750 = 1.0;
            break;
        }
        vec2 _4668 = (_1788.uniforms.clip_rect.xy + (_1788.uniforms.clip_rect.zw * 0.5)) * _1788.uniforms.scale_factor;
        vec2 _4675 = (_1788.uniforms.clip_rect.zw * _1788.uniforms.scale_factor) * 0.5;
        float _6748 = 0.0;
        if (_1788.uniforms.clip_shape_kind == 1u)
        {
            vec4 _4684 = _1788.uniforms.clip_radii * _1788.uniforms.scale_factor;
            vec2 _4687 = _4517 - _4668;
            bool _4841 = _4687.y < 0.0;
            float _4855 = (_4687.x < 0.0) ? (_4841 ? _4684.x : _4684.w) : (_4841 ? _4684.y : _4684.z);
            vec2 _4862 = (abs(_4687) - _4675) + vec2(_4855);
            _6748 = (min(max(_4862.x, _4862.y), 0.0) + length(max(_4862, vec2(0.0)))) - _4855;
        }
        else
        {
            float _6749 = 0.0;
            if (_1788.uniforms.clip_shape_kind == 2u)
            {
                _6749 = length((_4517 - _4668) / max(_4675, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1788.uniforms.clip_shape_kind == 3u)
                {
                    uint _4708 = min(_1788.uniforms.clip_point_count, 32u);
                    uint _4711 = min(_1788.uniforms.clip_contour_count, 8u);
                    if ((_4708 < 3u) || (_4711 == 0u))
                    {
                        _6750 = 1.0;
                        break;
                    }
                    vec2 _4726 = _4517 - (_1788.uniforms.clip_rect.xy * _1788.uniforms.scale_factor);
                    bool _6731 = false;
                    do
                    {
                        if (_1788.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6730 = false;
                            _6730 = false;
                            uint _4925 = 0u;
                            bool _6852 = false;
                            for (uint _6729 = 0u, _6740 = 0u; _6729 < _4711; _6740 = _4925, _6730 = _6852, _6729++)
                            {
                                _4925 = min(_1788.uniforms.clip_polygon_end_points[_6729 / 4u][_6729 % 4u], _4708);
                                if (_4925 <= (_6740 + 1u))
                                {
                                    _6852 = _6730;
                                    continue;
                                }
                                bool _6743 = false;
                                _6743 = _6730;
                                bool _6857 = false;
                                for (uint _6741 = _6740; _6741 < _4925; _6743 = _6857, _6741++)
                                {
                                    uint _4941 = _6741 + 1u;
                                    uint _4947 = (_4941 < _4925) ? _4941 : _6740;
                                    uint _5040 = _6741 / 2u;
                                    bvec2 _5050 = bvec2((_6741 % 2u) == 0u);
                                    vec2 _4953 = vec2(_5050.x ? _1788.uniforms.clip_polygon_points[_5040].xy.x : _1788.uniforms.clip_polygon_points[_5040].zw.x, _5050.y ? _1788.uniforms.clip_polygon_points[_5040].xy.y : _1788.uniforms.clip_polygon_points[_5040].zw.y) * _1788.uniforms.scale_factor;
                                    uint _5056 = _4947 / 2u;
                                    bvec2 _5066 = bvec2((_4947 % 2u) == 0u);
                                    vec2 _4959 = vec2(_5066.x ? _1788.uniforms.clip_polygon_points[_5056].xy.x : _1788.uniforms.clip_polygon_points[_5056].zw.x, _5066.y ? _1788.uniforms.clip_polygon_points[_5056].xy.y : _1788.uniforms.clip_polygon_points[_5056].zw.y) * _1788.uniforms.scale_factor;
                                    float _4961 = _4959.y;
                                    float _4963 = _4953.y;
                                    float _4964 = _4961 - _4963;
                                    float _4976 = _4726.y;
                                    float _4989 = _4953.x;
                                    if (((_4963 > _4976) != (_4961 > _4976)) && (_4726.x < ((((_4959.x - _4989) * (_4976 - _4963)) / ((abs(_4964) < 9.9999997473787516355514526367188e-05) ? ((_4964 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4964)) + _4989)))
                                    {
                                        _6857 = !_6743;
                                    }
                                    else
                                    {
                                        _6857 = _6743;
                                    }
                                }
                                _6852 = _6743;
                            }
                            _6731 = _6730;
                            break;
                        }
                        int _6712 = 0;
                        _6712 = 0;
                        uint _5096 = 0u;
                        int _6840 = 0;
                        for (uint _6711 = 0u, _6713 = 0u; _6711 < _4711; _6713 = _5096, _6712 = _6840, _6711++)
                        {
                            _5096 = min(_1788.uniforms.clip_polygon_end_points[_6711 / 4u][_6711 % 4u], _4708);
                            if (_5096 <= (_6713 + 1u))
                            {
                                _6840 = _6712;
                                continue;
                            }
                            int _6716 = 0;
                            _6716 = _6712;
                            int _6847 = 0;
                            for (uint _6714 = _6713; _6714 < _5096; _6716 = _6847, _6714++)
                            {
                                uint _5112 = _6714 + 1u;
                                uint _5118 = (_5112 < _5096) ? _5112 : _6713;
                                uint _5233 = _6714 / 2u;
                                bvec2 _5243 = bvec2((_6714 % 2u) == 0u);
                                vec2 _5124 = vec2(_5243.x ? _1788.uniforms.clip_polygon_points[_5233].xy.x : _1788.uniforms.clip_polygon_points[_5233].zw.x, _5243.y ? _1788.uniforms.clip_polygon_points[_5233].xy.y : _1788.uniforms.clip_polygon_points[_5233].zw.y) * _1788.uniforms.scale_factor;
                                uint _5249 = _5118 / 2u;
                                bvec2 _5259 = bvec2((_5118 % 2u) == 0u);
                                vec2 _5130 = vec2(_5259.x ? _1788.uniforms.clip_polygon_points[_5249].xy.x : _1788.uniforms.clip_polygon_points[_5249].zw.x, _5259.y ? _1788.uniforms.clip_polygon_points[_5249].xy.y : _1788.uniforms.clip_polygon_points[_5249].zw.y) * _1788.uniforms.scale_factor;
                                float _5132 = _5124.y;
                                float _5134 = _4726.y;
                                if (_5132 <= _5134)
                                {
                                    float _5138 = _5130.y;
                                    int _6848 = 0;
                                    if (_5138 > _5134)
                                    {
                                        float _5146 = _5124.x;
                                        int _6849 = 0;
                                        if ((((_5130.x - _5146) * (_5134 - _5132)) - ((_4726.x - _5146) * (_5138 - _5132))) > 0.0)
                                        {
                                            _6849 = _6716 + 1;
                                        }
                                        else
                                        {
                                            _6849 = _6716;
                                        }
                                        _6848 = _6849;
                                    }
                                    else
                                    {
                                        _6848 = _6716;
                                    }
                                    _6847 = _6848;
                                }
                                else
                                {
                                    float _5175 = _5130.y;
                                    int _6850 = 0;
                                    if (_5175 <= _5134)
                                    {
                                        float _5183 = _5124.x;
                                        int _6851 = 0;
                                        if ((((_5130.x - _5183) * (_5134 - _5132)) - ((_4726.x - _5183) * (_5175 - _5132))) < 0.0)
                                        {
                                            _6851 = _6716 - 1;
                                        }
                                        else
                                        {
                                            _6851 = _6716;
                                        }
                                        _6850 = _6851;
                                    }
                                    else
                                    {
                                        _6850 = _6716;
                                    }
                                    _6847 = _6850;
                                }
                            }
                            _6840 = _6716;
                        }
                        _6731 = _6712 != 0;
                        break;
                    } while(false);
                    float _6733 = 0.0;
                    uint _6734 = 0u;
                    _6734 = 0u;
                    _6733 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4743 = 0u;
                    float _6853 = 0.0;
                    for (uint _6732 = 0u; _6732 < _4711; _6734 = _4743, _6733 = _6853, _6732++)
                    {
                        _4743 = min(_1788.uniforms.clip_polygon_end_points[_6732 / 4u][_6732 % 4u], _4708);
                        if (_4743 <= (_6734 + 1u))
                        {
                            _6853 = _6733;
                            continue;
                        }
                        float _6737 = 0.0;
                        _6737 = _6733;
                        for (uint _6735 = _6734; _6735 < _4743; )
                        {
                            uint _4759 = _6735 + 1u;
                            uint _4765 = (_4759 < _4743) ? _4759 : _6734;
                            uint _5273 = _6735 / 2u;
                            bvec2 _5283 = bvec2((_6735 % 2u) == 0u);
                            vec2 _4771 = vec2(_5283.x ? _1788.uniforms.clip_polygon_points[_5273].xy.x : _1788.uniforms.clip_polygon_points[_5273].zw.x, _5283.y ? _1788.uniforms.clip_polygon_points[_5273].xy.y : _1788.uniforms.clip_polygon_points[_5273].zw.y) * _1788.uniforms.scale_factor;
                            uint _5289 = _4765 / 2u;
                            bvec2 _5299 = bvec2((_4765 % 2u) == 0u);
                            vec2 _5308 = (vec2(_5299.x ? _1788.uniforms.clip_polygon_points[_5289].xy.x : _1788.uniforms.clip_polygon_points[_5289].zw.x, _5299.y ? _1788.uniforms.clip_polygon_points[_5289].xy.y : _1788.uniforms.clip_polygon_points[_5289].zw.y) * _1788.uniforms.scale_factor) - _4771;
                            _6737 = min(_6737, length(_4726 - (_4771 + (_5308 * clamp(dot(_4726 - _4771, _5308) / max(dot(_5308, _5308), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6735++;
                            continue;
                        }
                        _6853 = _6737;
                    }
                    float _4802 = max(length(vec2(dFdxFine(_4517.x), dFdyFine(_4517.y))) * 0.5, 0.75);
                    _6750 = smoothstep(_4802, -_4802, _6731 ? (-_6733) : _6733);
                    break;
                }
                _6749 = 1.0;
            }
            _6748 = _6749;
        }
        float _4824 = max((abs(dFdxFine(_6748)) + abs(dFdyFine(_6748))) * 0.5, 0.5);
        _6750 = smoothstep(_4824, -_4824, _6748);
        break;
    } while(false);
    SPIRV_CROSS_BRANCH
    if ((((true && (_3107 == 0u)) && true) && all(bvec4(true))) && (input_solid_fill.w == 0.0))
    {
        discard;
    }
    bool _3564 = _4509 > 0.0;
    uint _3734 = _3107 & 255u;
    bool _3746 = (_3107 & 33554432u) != 0u;
    vec4 _7085 = vec4(0.0);
    _7085 = vec4(0.0);
    vec4 _7097 = vec4(0.0);
    SPIRV_CROSS_LOOP
    for (uint _6771 = 0u; _6771 < 2u; _7085 = _7097, _6771++)
    {
        bool _3754 = _6771 == 0u;
        if (true && (_3754 ? (_3367 > 0.0) : _3746))
        {
            vec2 _6814 = vec2(0.0);
            vec2 _6816 = vec2(0.0);
            vec4 _6819 = vec4(0.0);
            vec4 _6825 = vec4(0.0);
            float _6829 = 0.0;
            if (_3754)
            {
                float _3780 = ((_3107 & 268435456u) != 0u) ? (input_solid_border.y * _1788.uniforms.scale_factor) : 0.0;
                _6829 = _3367;
                _6825 = input_solid_fill;
                _6819 = max(_3348 + vec4(_3780), vec4(0.0));
                _6816 = max(input_size + vec2(_3780), vec2(0.0));
                _6814 = _3374;
            }
            else
            {
                _6829 = shadow_params_1._data[0u].blur * _1788.uniforms.scale_factor;
                _6825 = shadow_params_1._data[0u].color;
                _6819 = _3348;
                _6816 = input_size;
                _6814 = vec2(shadow_params_1._data[0u].offset_x, shadow_params_1._data[0u].offset_y) * _1788.uniforms.scale_factor;
            }
            vec2 _3845 = input_local_pos - _6814;
            bool _5478 = _3845.y < 0.0;
            float _5492 = (_3845.x < 0.0) ? (_5478 ? _6819.x : _6819.w) : (_5478 ? _6819.y : _6819.z);
            vec2 _5499 = (abs(_3845) - _6816) + vec2(_5492);
            float _3862 = _6825.w * (smoothstep(_6829, -_6829, (min(max(_5499.x, _5499.y), 0.0) + length(max(_5499, vec2(0.0)))) - _5492) * (1.0 - _4509));
            _7097 = _7085 + (vec4(_6825.xyz * _3862, _3862) * (1.0 - _7085.w));
        }
        else
        {
            _7097 = _7085;
        }
    }
    vec4 _7093 = vec4(0.0);
    if (true && _3564)
    {
        vec4 _7081 = vec4(0.0);
        if (_3734 > 0u)
        {
            float _6772 = 0.0;
            if (_3734 == 4u)
            {
                vec2 _3903 = vec2(0.5 + input_solid_metrics.y, 0.5 + input_solid_metrics.z);
                float _6773 = 0.0;
                if ((_3107 & 536870912u) != 0u)
                {
                    _6773 = length((input_uv - _3903) / max(vec2(input_solid_border.y, 0.0), vec2(9.9999997473787516355514526367188e-05)));
                }
                else
                {
                    _6773 = length(input_uv - _3903) * 2.0;
                }
                _6772 = _6773;
            }
            else
            {
                float _6774 = 0.0;
                if (_3734 == 5u)
                {
                    _6774 = fract((atan(input_uv.y - 0.5, input_uv.x - 0.5) * 0.15915493667125701904296875) + 0.5);
                }
                else
                {
                    float _3964 = ((input_solid_border.x * 2.0) + abs(input_solid_metrics.y)) + abs(input_solid_metrics.z);
                    vec2 _3985 = clamp(((input_uv * vec2(_3964 * 2.0)) - vec2(_3964)) * vec2(999.99993896484375), vec2(0.0), vec2(1.0));
                    float _6775 = 0.0;
                    if (_3734 == 1u)
                    {
                        _6775 = _3985.y;
                    }
                    else
                    {
                        float _6776 = 0.0;
                        if (_3734 == 2u)
                        {
                            _6776 = _3985.x;
                        }
                        else
                        {
                            _6776 = (_3985.x + _3985.y) * 0.5;
                        }
                        _6775 = _6776;
                    }
                    _6774 = _6775;
                }
                _6772 = _6774;
            }
            uint _4011 = (_3107 >> 26u) & 3u;
            float _6777 = 0.0;
            if (_4011 == 1u)
            {
                _6777 = fract(_6772);
            }
            else
            {
                float _6778 = 0.0;
                if (_4011 == 2u)
                {
                    float _4023 = mod(abs(_6772), 2.0);
                    _6778 = (_4023 > 1.0) ? (2.0 - _4023) : _4023;
                }
                else
                {
                    _6778 = clamp(_6772, 0.0, 1.0);
                }
                _6777 = _6778;
            }
            vec4 _4056 = mix(vec4(0.0), vec4(0.0), vec4(_6777));
            float _5776 = _4056.w;
            vec4 _5789 = vec4(_4056.xyz / vec3(_5776), _5776);
            bvec4 _5790 = bvec4(_5776 > 9.9999999747524270787835121154785e-07);
            vec4 _5791 = vec4(_5790.x ? _5789.x : vec4(0.0).x, _5790.y ? _5789.y : vec4(0.0).y, _5790.z ? _5789.z : vec4(0.0).z, _5790.w ? _5789.w : vec4(0.0).w);
            vec3 _4069 = clamp(_5791.xyz + vec3((float(_648[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
            vec4 _7033 = _5791;
            _7033.x = _4069.x;
            _7033.y = _4069.y;
            _7033.z = _4069.z;
            _7081 = _7033;
        }
        else
        {
            _7081 = vec4(0.0);
        }
        vec4 _7082 = vec4(0.0);
        if ((((_3107 >> 8u) & 255u) > 0u) && (input_solid_border.y > 0.0))
        {
            _7082 = clamp(_7081, vec4(0.0), vec4(1.0));
        }
        else
        {
            _7082 = _7081;
        }
        float _4135 = _7082.w * _4509;
        _7093 = _7085 + (vec4(_7082.xyz * _4135, _4135) * (1.0 - _7085.w));
    }
    else
    {
        _7093 = _7085;
    }
    vec4 _7094 = vec4(0.0);
    if ((true && ((_3107 & 16777216u) != 0u)) && _3564)
    {
        vec2 _4158 = input_local_pos - _3374;
        bool _6293 = _4158.y < 0.0;
        float _6307 = (_4158.x < 0.0) ? (_6293 ? _4248 : _4250) : (_6293 ? _4256 : _4258);
        vec2 _6314 = (abs(_4158) - input_size) + vec2(_6307);
        float _4179 = input_solid_fill.w * (_4509 * smoothstep(-max(_3367, 1.0), 0.0, (min(max(_6314.x, _6314.y), 0.0) + length(max(_6314, vec2(0.0)))) - _6307));
        _7094 = _7093 + (vec4(input_solid_fill.xyz * _4179, _4179) * (1.0 - _7093.w));
    }
    else
    {
        _7094 = _7093;
    }
    vec4 _4227 = _7094 * (_6710 * _6750);
    if (_4227.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4227;
}

