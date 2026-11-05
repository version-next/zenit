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

const uint _640[256] = uint[](0u, 128u, 32u, 160u, 8u, 136u, 40u, 168u, 2u, 130u, 34u, 162u, 10u, 138u, 42u, 170u, 192u, 64u, 224u, 96u, 200u, 72u, 232u, 104u, 194u, 66u, 226u, 98u, 202u, 74u, 234u, 106u, 48u, 176u, 16u, 144u, 56u, 184u, 24u, 152u, 50u, 178u, 18u, 146u, 58u, 186u, 26u, 154u, 240u, 112u, 208u, 80u, 248u, 120u, 216u, 88u, 242u, 114u, 210u, 82u, 250u, 122u, 218u, 90u, 12u, 140u, 44u, 172u, 4u, 132u, 36u, 164u, 14u, 142u, 46u, 174u, 6u, 134u, 38u, 166u, 204u, 76u, 236u, 108u, 196u, 68u, 228u, 100u, 206u, 78u, 238u, 110u, 198u, 70u, 230u, 102u, 60u, 188u, 28u, 156u, 52u, 180u, 20u, 148u, 62u, 190u, 30u, 158u, 54u, 182u, 22u, 150u, 252u, 124u, 220u, 92u, 244u, 116u, 212u, 84u, 254u, 126u, 222u, 94u, 246u, 118u, 214u, 86u, 3u, 131u, 35u, 163u, 11u, 139u, 43u, 171u, 1u, 129u, 33u, 161u, 9u, 137u, 41u, 169u, 195u, 67u, 227u, 99u, 203u, 75u, 235u, 107u, 193u, 65u, 225u, 97u, 201u, 73u, 233u, 105u, 51u, 179u, 19u, 147u, 59u, 187u, 27u, 155u, 49u, 177u, 17u, 145u, 57u, 185u, 25u, 153u, 243u, 115u, 211u, 83u, 251u, 123u, 219u, 91u, 241u, 113u, 209u, 81u, 249u, 121u, 217u, 89u, 15u, 143u, 47u, 175u, 7u, 135u, 39u, 167u, 13u, 141u, 45u, 173u, 5u, 133u, 37u, 165u, 207u, 79u, 239u, 111u, 199u, 71u, 231u, 103u, 205u, 77u, 237u, 109u, 197u, 69u, 229u, 101u, 63u, 191u, 31u, 159u, 55u, 183u, 23u, 151u, 61u, 189u, 29u, 157u, 53u, 181u, 21u, 149u, 255u, 127u, 223u, 95u, 247u, 119u, 215u, 87u, 253u, 125u, 221u, 93u, 245u, 117u, 213u, 85u);

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
    vec4 _6757 = vec4(0.0);
    do
    {
        vec4 _3354 = instances_1._data[input_instance_id].corner_radii * _1780.uniforms.scale_factor;
        float _3369 = instances_1._data[input_instance_id].border_width * _1780.uniforms.scale_factor;
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
                        float _3425 = _3354.x;
                        float _6614 = 0.0;
                        do
                        {
                            float _4315 = _3369 * 0.5;
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
                            float _4345 = max(_3425 - _3369, 0.0);
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
        float _4513 = -_3448;
        float _4515 = smoothstep(_3448, _4513, _6615);
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
        float _4539 = _6628 * _6668;
        SPIRV_CROSS_BRANCH
        if ((((true && (instances_1._data[input_instance_id].packed_flags == 0u)) && (instances_1._data[input_instance_id].border_width == 0.0)) && all(equal(instances_1._data[input_instance_id].border_widths, vec4(0.0)))) && (instances_1._data[input_instance_id].shadow_color.w == 0.0))
        {
            float _3516 = instances_1._data[input_instance_id].fill_color.w * _4515;
            vec4 _3531 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _3516, _3516) * _4539;
            if (_3531.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6757 = _3531;
            break;
        }
        vec4 _3542 = instances_1._data[input_instance_id].border_widths * _1780.uniforms.scale_factor;
        float _3544 = _3542.x;
        float _3546 = _3542.y;
        float _3549 = _3542.z;
        float _3552 = _3542.w;
        bool _3577 = false || (true && (!((instances_1._data[input_instance_id].packed_flags & 16777216u) != 0u)));
        float _6709 = 0.0;
        if (_3577 && (((((_3544 + _3546) + _3549) + _3552) > 0.0) && _3384))
        {
            vec4 _3639 = max(_3354 - vec4(max(_3544, _3552), max(_3544, _3546), max(_3549, _3546), max(_3549, _3552)), vec4(0.0));
            vec2 _3643 = input_local_pos - vec2((_3552 - _3546) * 0.5, (_3544 - _3549) * 0.5);
            bool _5344 = _3643.y < 0.0;
            float _5358 = (_3643.x < 0.0) ? (_5344 ? _3639.x : _3639.w) : (_5344 ? _3639.y : _3639.z);
            vec2 _5365 = (abs(_3643) - max(vec2(input_size.x - ((_3546 + _3552) * 0.5), input_size.y - ((_3544 + _3549) * 0.5)), vec2(0.0))) + vec2(_5358);
            _6709 = _4515 - smoothstep(_3448, _4513, (min(max(_5365.x, _5365.y), 0.0) + length(max(_5365, vec2(0.0)))) - _5358);
        }
        else
        {
            float _6710 = 0.0;
            if (_3577 && (_3369 > 0.0))
            {
                _6710 = _4515 - smoothstep(_3448, _4513, _6615 + _3369);
            }
            else
            {
                _6710 = 0.0;
            }
            _6709 = _6710;
        }
        uint _3740 = instances_1._data[input_instance_id].packed_flags & 255u;
        uint _3744 = (instances_1._data[input_instance_id].packed_flags >> 8u) & 255u;
        uint _3748 = (instances_1._data[input_instance_id].packed_flags >> 16u) & 255u;
        vec4 _7002 = vec4(0.0);
        if (true && (_4515 > 0.0))
        {
            vec4 _6985 = vec4(0.0);
            if (_3740 > 0u)
            {
                float _6690 = 0.0;
                if (_3740 == 4u)
                {
                    vec2 _3909 = vec2(0.5 + instances_1._data[input_instance_id].shadow_offset_x, 0.5 + instances_1._data[input_instance_id].shadow_offset_y);
                    float _6691 = 0.0;
                    if ((instances_1._data[input_instance_id].packed_flags & 536870912u) != 0u)
                    {
                        _6691 = length((input_uv - _3909) / max(vec2(instances_1._data[input_instance_id].noise_scale, instances_1._data[input_instance_id].noise_intensity), vec2(9.9999997473787516355514526367188e-05)));
                    }
                    else
                    {
                        _6691 = length(input_uv - _3909) * 2.0;
                    }
                    _6690 = _6691;
                }
                else
                {
                    float _6692 = 0.0;
                    if (_3740 == 5u)
                    {
                        _6692 = fract(((atan(input_uv.y - 0.5, input_uv.x - 0.5) - uintBitsToFloat(instances_1._data[input_instance_id]._ext_reserved)) * 0.15915493667125701904296875) + 0.5);
                    }
                    else
                    {
                        float _3971 = (instances_1._data[input_instance_id].shape_type == 3u) ? 0.0 : (((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y));
                        vec2 _3991 = clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_3971 * 2.0))) - vec2(_3971)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0));
                        float _6693 = 0.0;
                        if (_3740 == 1u)
                        {
                            _6693 = _3991.y;
                        }
                        else
                        {
                            float _6694 = 0.0;
                            if (_3740 == 2u)
                            {
                                _6694 = _3991.x;
                            }
                            else
                            {
                                _6694 = (_3991.x + _3991.y) * 0.5;
                            }
                            _6693 = _6694;
                        }
                        _6692 = _6693;
                    }
                    _6690 = _6692;
                }
                uint _4017 = (instances_1._data[input_instance_id].packed_flags >> 26u) & 3u;
                float _6695 = 0.0;
                if (_4017 == 1u)
                {
                    _6695 = fract(_6690);
                }
                else
                {
                    float _6696 = 0.0;
                    if (_4017 == 2u)
                    {
                        float _4029 = mod(abs(_6690), 2.0);
                        _6696 = (_4029 > 1.0) ? (2.0 - _4029) : _4029;
                    }
                    else
                    {
                        _6696 = clamp(_6690, 0.0, 1.0);
                    }
                    _6695 = _6696;
                }
                vec4 _6982 = vec4(0.0);
                if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
                {
                    vec4 _6701 = vec4(0.0);
                    do
                    {
                        if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                        {
                            _6701 = vec4(0.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                        {
                            _6701 = vec4(1.0, 0.0, 1.0, 1.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                        {
                            _6701 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                            break;
                        }
                        uint _5612 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                        float _5618 = clamp(_6695, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5612].position);
                        vec4 _6698 = vec4(0.0);
                        _6698 = grad_stops_1._data[_5612].color;
                        bool _7010 = false;
                        vec4 _6776 = vec4(0.0);
                        uint _6697 = 0u;
                        bool _6699 = false;
                        for (; _6697 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6699 = _7010, _6698 = _6776, _6697++)
                        {
                            uint _5634 = instances_1._data[input_instance_id].gradient_stop_offset + _6697;
                            uint _5650 = _5634 + 1u;
                            bool _5674 = ((!_6699) && (_5618 >= grad_stops_1._data[_5634].position)) && (_5618 <= grad_stops_1._data[_5650].position);
                            if (_5674)
                            {
                                float _5680 = grad_stops_1._data[_5650].position - grad_stops_1._data[_5634].position;
                                vec4 _5698 = mix(vec4(grad_stops_1._data[_5634].color.xyz * grad_stops_1._data[_5634].color.w, grad_stops_1._data[_5634].color.w), vec4(grad_stops_1._data[_5650].color.xyz * grad_stops_1._data[_5650].color.w, grad_stops_1._data[_5650].color.w), vec4((_5680 > 9.9999999747524270787835121154785e-07) ? ((_5618 - grad_stops_1._data[_5634].position) / _5680) : 0.0));
                                float _5737 = _5698.w;
                                vec4 _5750 = vec4(_5698.xyz / vec3(_5737), _5737);
                                bvec4 _5751 = bvec4(_5737 > 9.9999999747524270787835121154785e-07);
                                _6776 = vec4(_5751.x ? _5750.x : vec4(0.0).x, _5751.y ? _5750.y : vec4(0.0).y, _5751.z ? _5750.z : vec4(0.0).z, _5751.w ? _5750.w : vec4(0.0).w);
                            }
                            else
                            {
                                _6776 = _6698;
                            }
                            _7010 = _5674 ? true : _6699;
                        }
                        _6701 = _6698;
                        break;
                    } while(false);
                    _6982 = _6701;
                }
                else
                {
                    vec4 _4062 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_6695));
                    float _5782 = _4062.w;
                    vec4 _5795 = vec4(_4062.xyz / vec3(_5782), _5782);
                    bvec4 _5796 = bvec4(_5782 > 9.9999999747524270787835121154785e-07);
                    _6982 = vec4(_5796.x ? _5795.x : vec4(0.0).x, _5796.y ? _5795.y : vec4(0.0).y, _5796.z ? _5795.z : vec4(0.0).z, _5796.w ? _5795.w : vec4(0.0).w);
                }
                vec3 _4075 = clamp(_6982.xyz + vec3((float(_640[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
                vec4 _6941 = _6982;
                _6941.x = _4075.x;
                _6941.y = _4075.y;
                _6941.z = _4075.z;
                _6985 = _6941;
            }
            else
            {
                _6985 = instances_1._data[input_instance_id].fill_color;
            }
            vec4 _6986 = vec4(0.0);
            if ((_3744 > 0u) && (instances_1._data[input_instance_id].noise_scale > 0.0))
            {
                float _6702 = 0.0;
                if (_3744 == 1u)
                {
                    float _5840 = float(_3748);
                    vec2 _5846 = ((input_local_pos / vec2(_1780.uniforms.scale_factor)) / vec2(max(instances_1._data[input_instance_id].noise_scale, 0.001000000047497451305389404296875))) + vec2(_5840 * 17.299999237060546875, _5840 * 31.700000762939453125);
                    vec2 _5848 = floor(_5846);
                    vec2 _5850 = fract(_5846);
                    vec2 _5858 = (_5850 * _5850) * (vec2(3.0) - (_5850 * 2.0));
                    uint _5901 = uint(abs(_5848.y) * 1000.0) * 2654435761u;
                    uint _5913 = (_5901 ^ 61u) ^ (_5901 >> 16u);
                    uint _5917 = _5913 + (_5913 << 3u);
                    uint _5923 = (_5917 ^ (_5917 >> 4u)) * 668265261u;
                    uint _5903 = uint(abs(_5848.x) * 1000.0) ^ (_5923 ^ (_5923 >> 15u));
                    uint _5935 = (_5903 ^ 61u) ^ (_5903 >> 16u);
                    uint _5939 = _5935 + (_5935 << 3u);
                    uint _5945 = (_5939 ^ (_5939 >> 4u)) * 668265261u;
                    vec2 _5862 = _5848 + vec2(1.0, 0.0);
                    uint _5969 = uint(abs(_5862.y) * 1000.0) * 2654435761u;
                    uint _5981 = (_5969 ^ 61u) ^ (_5969 >> 16u);
                    uint _5985 = _5981 + (_5981 << 3u);
                    uint _5991 = (_5985 ^ (_5985 >> 4u)) * 668265261u;
                    uint _5971 = uint(abs(_5862.x) * 1000.0) ^ (_5991 ^ (_5991 >> 15u));
                    uint _6003 = (_5971 ^ 61u) ^ (_5971 >> 16u);
                    uint _6007 = _6003 + (_6003 << 3u);
                    uint _6013 = (_6007 ^ (_6007 >> 4u)) * 668265261u;
                    vec2 _5865 = _5848 + vec2(0.0, 1.0);
                    uint _6037 = uint(abs(_5865.y) * 1000.0) * 2654435761u;
                    uint _6049 = (_6037 ^ 61u) ^ (_6037 >> 16u);
                    uint _6053 = _6049 + (_6049 << 3u);
                    uint _6059 = (_6053 ^ (_6053 >> 4u)) * 668265261u;
                    uint _6039 = uint(abs(_5865.x) * 1000.0) ^ (_6059 ^ (_6059 >> 15u));
                    uint _6071 = (_6039 ^ 61u) ^ (_6039 >> 16u);
                    uint _6075 = _6071 + (_6071 << 3u);
                    uint _6081 = (_6075 ^ (_6075 >> 4u)) * 668265261u;
                    vec2 _5868 = _5848 + vec2(1.0);
                    uint _6105 = uint(abs(_5868.y) * 1000.0) * 2654435761u;
                    uint _6117 = (_6105 ^ 61u) ^ (_6105 >> 16u);
                    uint _6121 = _6117 + (_6117 << 3u);
                    uint _6127 = (_6121 ^ (_6121 >> 4u)) * 668265261u;
                    uint _6107 = uint(abs(_5868.x) * 1000.0) ^ (_6127 ^ (_6127 >> 15u));
                    uint _6139 = (_6107 ^ 61u) ^ (_6107 >> 16u);
                    uint _6143 = _6139 + (_6139 << 3u);
                    uint _6149 = (_6143 ^ (_6143 >> 4u)) * 668265261u;
                    float _5873 = _5858.x;
                    _6702 = mix(mix(float(_5945 ^ (_5945 >> 15u)) * 2.3283064365386962890625e-10, float(_6013 ^ (_6013 >> 15u)) * 2.3283064365386962890625e-10, _5873), mix(float(_6081 ^ (_6081 >> 15u)) * 2.3283064365386962890625e-10, float(_6149 ^ (_6149 >> 15u)) * 2.3283064365386962890625e-10, _5873), _5858.y) - 0.5;
                }
                else
                {
                    float _6703 = 0.0;
                    if (_3744 == 2u)
                    {
                        uint _4116 = _3748 ^ (_1780.uniforms.frame_seed & 255u);
                        vec2 _6170 = floor(input_screen_pos) + vec2(float(_4116 & 255u) * 3.7000000476837158203125, float((_4116 >> 8u) & 255u) * 5.099999904632568359375);
                        uint _6191 = uint(abs(_6170.y) * 1000.0) * 2654435761u;
                        uint _6203 = (_6191 ^ 61u) ^ (_6191 >> 16u);
                        uint _6207 = _6203 + (_6203 << 3u);
                        uint _6213 = (_6207 ^ (_6207 >> 4u)) * 668265261u;
                        uint _6193 = uint(abs(_6170.x) * 1000.0) ^ (_6213 ^ (_6213 >> 15u));
                        uint _6225 = (_6193 ^ 61u) ^ (_6193 >> 16u);
                        uint _6229 = _6225 + (_6225 << 3u);
                        uint _6235 = (_6229 ^ (_6229 >> 4u)) * 668265261u;
                        _6703 = (float(_6235 ^ (_6235 >> 15u)) * 2.3283064365386962890625e-10) - 0.5;
                    }
                    else
                    {
                        _6703 = 0.0;
                    }
                    _6702 = _6703;
                }
                float _4127 = _6702 * instances_1._data[input_instance_id].noise_intensity;
                _6986 = clamp(_6985 + vec4(_4127, _4127, _4127, 0.0), vec4(0.0), vec4(1.0));
            }
            else
            {
                _6986 = _6985;
            }
            float _4141 = _6986.w * _4515;
            _7002 = vec4(_6986.xyz * _4141, _4141) * 1.0;
        }
        else
        {
            _7002 = vec4(0.0);
        }
        vec4 _7003 = vec4(0.0);
        if (_3577 && (_6709 > 0.0))
        {
            float _4213 = instances_1._data[input_instance_id].border_color.w * _6709;
            _7003 = _7002 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4213, _4213) * (1.0 - _7002.w));
        }
        else
        {
            _7003 = _7002;
        }
        vec4 _4233 = _7003 * _4539;
        if (_4233.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6757 = _4233;
        break;
    } while(false);
    _entryPointOutput = _6757;
}

