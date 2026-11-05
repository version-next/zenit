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
    vec4 _6850 = vec4(0.0);
    do
    {
        vec4 _3388 = instances_1._data[input_instance_id].corner_radii * _1788.uniforms.scale_factor;
        float _3403 = instances_1._data[input_instance_id].border_width * _1788.uniforms.scale_factor;
        float _3407 = instances_1._data[input_instance_id].shadow_blur * _1788.uniforms.scale_factor;
        vec2 _3414 = vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1788.uniforms.scale_factor;
        bool _3418 = instances_1._data[input_instance_id].shape_type == 0u;
        float _6708 = 0.0;
        if (_3418)
        {
            bool _4286 = input_local_pos.y < 0.0;
            float _4300 = (input_local_pos.x < 0.0) ? (_4286 ? _3388.x : _3388.w) : (_4286 ? _3388.y : _3388.z);
            vec2 _4307 = (abs(input_local_pos) - input_size) + vec2(_4300);
            _6708 = (min(max(_4307.x, _4307.y), 0.0) + length(max(_4307, vec2(0.0)))) - _4300;
        }
        else
        {
            float _6709 = 0.0;
            if (instances_1._data[input_instance_id].shape_type == 1u)
            {
                _6709 = length(input_local_pos) - min(input_size.x, input_size.y);
            }
            else
            {
                float _6710 = 0.0;
                if (instances_1._data[input_instance_id].shape_type == 2u)
                {
                    _6710 = abs(input_local_pos.y) - _3388.x;
                }
                else
                {
                    float _6711 = 0.0;
                    if (instances_1._data[input_instance_id].shape_type == 3u)
                    {
                        float _3459 = _3388.x;
                        float _6707 = 0.0;
                        do
                        {
                            float _4349 = _3403 * 0.5;
                            float _4359 = abs(length(input_local_pos) - (_3459 - _4349)) - _4349;
                            float _4363 = clamp(instances_1._data[input_instance_id].shadow_offset_y - instances_1._data[input_instance_id].shadow_offset_x, 0.0, 6.283185482025146484375);
                            if (_4363 >= 6.283085346221923828125)
                            {
                                _6707 = _4359;
                                break;
                            }
                            if (_4363 <= 0.0)
                            {
                                _6707 = max(_4359, 0.0) + 1.0;
                                break;
                            }
                            float _4379 = max(_3459 - _3403, 0.0);
                            vec2 _4428 = vec2(cos(instances_1._data[input_instance_id].shadow_offset_x), sin(instances_1._data[input_instance_id].shadow_offset_x));
                            float _4435 = _3459 - _4379;
                            vec2 _4436 = _4428 * _4435;
                            vec2 _4439 = input_local_pos - (_4428 * _4379);
                            float _4387 = instances_1._data[input_instance_id].shadow_offset_x + _4363;
                            vec2 _4464 = vec2(cos(_4387), sin(_4387));
                            vec2 _4472 = _4464 * _4435;
                            vec2 _4475 = input_local_pos - (_4464 * _4379);
                            float _4392 = min(length(_4439 - (_4436 * clamp(dot(_4439, _4436) / max(dot(_4436, _4436), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4475 - (_4472 * clamp(dot(_4475, _4472) / max(dot(_4472, _4472), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                            float _4400 = atan(input_local_pos.y, input_local_pos.x) - instances_1._data[input_instance_id].shadow_offset_x;
                            _6707 = ((_4400 - (floor(_4400 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4363) ? max(_4359, -_4392) : _4392;
                            break;
                        } while(false);
                        _6711 = _6707;
                    }
                    else
                    {
                        float _6712 = 0.0;
                        if (instances_1._data[input_instance_id].shape_type == 4u)
                        {
                            float _6706 = 0.0;
                            do
                            {
                                vec2 _4500 = max(input_size, vec2(0.001000000047497451305389404296875));
                                float _4505 = length(input_local_pos / _4500);
                                if (_4505 < 9.9999999747524270787835121154785e-07)
                                {
                                    _6706 = -min(_4500.x, _4500.y);
                                    break;
                                }
                                _6706 = (_4505 - 1.0) / max(length(input_local_pos / (_4500 * _4500)) / _4505, 9.9999999747524270787835121154785e-07);
                                break;
                            } while(false);
                            _6712 = _6706;
                        }
                        else
                        {
                            _6712 = 1.0;
                        }
                        _6711 = _6712;
                    }
                    _6710 = _6711;
                }
                _6709 = _6710;
            }
            _6708 = _6709;
        }
        float _4534 = dFdxFine(_6708);
        float _4536 = dFdyFine(_6708);
        float _3482 = max(length(vec2(_4534, _4536)) * 0.5, 0.5);
        float _4547 = -_3482;
        float _4549 = smoothstep(_3482, _4547, _6708);
        bvec2 _4556 = bvec2(_1788.uniforms.raster_clip_pos != 0u);
        vec2 _4557 = vec2(_4556.x ? gl_FragCoord.xy.x : input_screen_pos.x, _4556.y ? gl_FragCoord.xy.y : input_screen_pos.y);
        float _6721 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6721 = 1.0;
                break;
            }
            vec2 _4635 = abs(_4557 - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1788.uniforms.scale_factor)) - ((input_rect_clip.zw * _1788.uniforms.scale_factor) * 0.5);
            float _4648 = min(max(_4635.x, _4635.y), 0.0) + length(max(_4635, vec2(0.0)));
            float _4621 = max((abs(dFdxFine(_4648)) + abs(dFdyFine(_4648))) * 0.5, 0.5);
            _6721 = smoothstep(_4621, -_4621, _4648);
            break;
        } while(false);
        float _6761 = 0.0;
        do
        {
            if (_1788.uniforms.clip_shape_kind == 0u)
            {
                _6761 = 1.0;
                break;
            }
            vec2 _4708 = (_1788.uniforms.clip_rect.xy + (_1788.uniforms.clip_rect.zw * 0.5)) * _1788.uniforms.scale_factor;
            vec2 _4715 = (_1788.uniforms.clip_rect.zw * _1788.uniforms.scale_factor) * 0.5;
            float _6759 = 0.0;
            if (_1788.uniforms.clip_shape_kind == 1u)
            {
                vec4 _4724 = _1788.uniforms.clip_radii * _1788.uniforms.scale_factor;
                vec2 _4727 = _4557 - _4708;
                bool _4881 = _4727.y < 0.0;
                float _4895 = (_4727.x < 0.0) ? (_4881 ? _4724.x : _4724.w) : (_4881 ? _4724.y : _4724.z);
                vec2 _4902 = (abs(_4727) - _4715) + vec2(_4895);
                _6759 = (min(max(_4902.x, _4902.y), 0.0) + length(max(_4902, vec2(0.0)))) - _4895;
            }
            else
            {
                float _6760 = 0.0;
                if (_1788.uniforms.clip_shape_kind == 2u)
                {
                    _6760 = length((_4557 - _4708) / max(_4715, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1788.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4748 = min(_1788.uniforms.clip_point_count, 32u);
                        uint _4751 = min(_1788.uniforms.clip_contour_count, 8u);
                        if ((_4748 < 3u) || (_4751 == 0u))
                        {
                            _6761 = 1.0;
                            break;
                        }
                        vec2 _4766 = _4557 - (_1788.uniforms.clip_rect.xy * _1788.uniforms.scale_factor);
                        bool _6742 = false;
                        do
                        {
                            if (_1788.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6741 = false;
                                _6741 = false;
                                uint _4965 = 0u;
                                bool _6863 = false;
                                for (uint _6740 = 0u, _6751 = 0u; _6740 < _4751; _6751 = _4965, _6741 = _6863, _6740++)
                                {
                                    _4965 = min(_1788.uniforms.clip_polygon_end_points[_6740 / 4u][_6740 % 4u], _4748);
                                    if (_4965 <= (_6751 + 1u))
                                    {
                                        _6863 = _6741;
                                        continue;
                                    }
                                    bool _6754 = false;
                                    _6754 = _6741;
                                    bool _6868 = false;
                                    for (uint _6752 = _6751; _6752 < _4965; _6754 = _6868, _6752++)
                                    {
                                        uint _4981 = _6752 + 1u;
                                        uint _4987 = (_4981 < _4965) ? _4981 : _6751;
                                        uint _5080 = _6752 / 2u;
                                        bvec2 _5090 = bvec2((_6752 % 2u) == 0u);
                                        vec2 _4993 = vec2(_5090.x ? _1788.uniforms.clip_polygon_points[_5080].xy.x : _1788.uniforms.clip_polygon_points[_5080].zw.x, _5090.y ? _1788.uniforms.clip_polygon_points[_5080].xy.y : _1788.uniforms.clip_polygon_points[_5080].zw.y) * _1788.uniforms.scale_factor;
                                        uint _5096 = _4987 / 2u;
                                        bvec2 _5106 = bvec2((_4987 % 2u) == 0u);
                                        vec2 _4999 = vec2(_5106.x ? _1788.uniforms.clip_polygon_points[_5096].xy.x : _1788.uniforms.clip_polygon_points[_5096].zw.x, _5106.y ? _1788.uniforms.clip_polygon_points[_5096].xy.y : _1788.uniforms.clip_polygon_points[_5096].zw.y) * _1788.uniforms.scale_factor;
                                        float _5001 = _4999.y;
                                        float _5003 = _4993.y;
                                        float _5004 = _5001 - _5003;
                                        float _5016 = _4766.y;
                                        float _5029 = _4993.x;
                                        if (((_5003 > _5016) != (_5001 > _5016)) && (_4766.x < ((((_4999.x - _5029) * (_5016 - _5003)) / ((abs(_5004) < 9.9999997473787516355514526367188e-05) ? ((_5004 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _5004)) + _5029)))
                                        {
                                            _6868 = !_6754;
                                        }
                                        else
                                        {
                                            _6868 = _6754;
                                        }
                                    }
                                    _6863 = _6754;
                                }
                                _6742 = _6741;
                                break;
                            }
                            int _6723 = 0;
                            _6723 = 0;
                            uint _5136 = 0u;
                            int _6851 = 0;
                            for (uint _6722 = 0u, _6724 = 0u; _6722 < _4751; _6724 = _5136, _6723 = _6851, _6722++)
                            {
                                _5136 = min(_1788.uniforms.clip_polygon_end_points[_6722 / 4u][_6722 % 4u], _4748);
                                if (_5136 <= (_6724 + 1u))
                                {
                                    _6851 = _6723;
                                    continue;
                                }
                                int _6727 = 0;
                                _6727 = _6723;
                                int _6858 = 0;
                                for (uint _6725 = _6724; _6725 < _5136; _6727 = _6858, _6725++)
                                {
                                    uint _5152 = _6725 + 1u;
                                    uint _5158 = (_5152 < _5136) ? _5152 : _6724;
                                    uint _5273 = _6725 / 2u;
                                    bvec2 _5283 = bvec2((_6725 % 2u) == 0u);
                                    vec2 _5164 = vec2(_5283.x ? _1788.uniforms.clip_polygon_points[_5273].xy.x : _1788.uniforms.clip_polygon_points[_5273].zw.x, _5283.y ? _1788.uniforms.clip_polygon_points[_5273].xy.y : _1788.uniforms.clip_polygon_points[_5273].zw.y) * _1788.uniforms.scale_factor;
                                    uint _5289 = _5158 / 2u;
                                    bvec2 _5299 = bvec2((_5158 % 2u) == 0u);
                                    vec2 _5170 = vec2(_5299.x ? _1788.uniforms.clip_polygon_points[_5289].xy.x : _1788.uniforms.clip_polygon_points[_5289].zw.x, _5299.y ? _1788.uniforms.clip_polygon_points[_5289].xy.y : _1788.uniforms.clip_polygon_points[_5289].zw.y) * _1788.uniforms.scale_factor;
                                    float _5172 = _5164.y;
                                    float _5174 = _4766.y;
                                    if (_5172 <= _5174)
                                    {
                                        float _5178 = _5170.y;
                                        int _6859 = 0;
                                        if (_5178 > _5174)
                                        {
                                            float _5186 = _5164.x;
                                            int _6860 = 0;
                                            if ((((_5170.x - _5186) * (_5174 - _5172)) - ((_4766.x - _5186) * (_5178 - _5172))) > 0.0)
                                            {
                                                _6860 = _6727 + 1;
                                            }
                                            else
                                            {
                                                _6860 = _6727;
                                            }
                                            _6859 = _6860;
                                        }
                                        else
                                        {
                                            _6859 = _6727;
                                        }
                                        _6858 = _6859;
                                    }
                                    else
                                    {
                                        float _5215 = _5170.y;
                                        int _6861 = 0;
                                        if (_5215 <= _5174)
                                        {
                                            float _5223 = _5164.x;
                                            int _6862 = 0;
                                            if ((((_5170.x - _5223) * (_5174 - _5172)) - ((_4766.x - _5223) * (_5215 - _5172))) < 0.0)
                                            {
                                                _6862 = _6727 - 1;
                                            }
                                            else
                                            {
                                                _6862 = _6727;
                                            }
                                            _6861 = _6862;
                                        }
                                        else
                                        {
                                            _6861 = _6727;
                                        }
                                        _6858 = _6861;
                                    }
                                }
                                _6851 = _6727;
                            }
                            _6742 = _6723 != 0;
                            break;
                        } while(false);
                        float _6744 = 0.0;
                        uint _6745 = 0u;
                        _6745 = 0u;
                        _6744 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4783 = 0u;
                        float _6864 = 0.0;
                        for (uint _6743 = 0u; _6743 < _4751; _6745 = _4783, _6744 = _6864, _6743++)
                        {
                            _4783 = min(_1788.uniforms.clip_polygon_end_points[_6743 / 4u][_6743 % 4u], _4748);
                            if (_4783 <= (_6745 + 1u))
                            {
                                _6864 = _6744;
                                continue;
                            }
                            float _6748 = 0.0;
                            _6748 = _6744;
                            for (uint _6746 = _6745; _6746 < _4783; )
                            {
                                uint _4799 = _6746 + 1u;
                                uint _4805 = (_4799 < _4783) ? _4799 : _6745;
                                uint _5313 = _6746 / 2u;
                                bvec2 _5323 = bvec2((_6746 % 2u) == 0u);
                                vec2 _4811 = vec2(_5323.x ? _1788.uniforms.clip_polygon_points[_5313].xy.x : _1788.uniforms.clip_polygon_points[_5313].zw.x, _5323.y ? _1788.uniforms.clip_polygon_points[_5313].xy.y : _1788.uniforms.clip_polygon_points[_5313].zw.y) * _1788.uniforms.scale_factor;
                                uint _5329 = _4805 / 2u;
                                bvec2 _5339 = bvec2((_4805 % 2u) == 0u);
                                vec2 _5348 = (vec2(_5339.x ? _1788.uniforms.clip_polygon_points[_5329].xy.x : _1788.uniforms.clip_polygon_points[_5329].zw.x, _5339.y ? _1788.uniforms.clip_polygon_points[_5329].xy.y : _1788.uniforms.clip_polygon_points[_5329].zw.y) * _1788.uniforms.scale_factor) - _4811;
                                _6748 = min(_6748, length(_4766 - (_4811 + (_5348 * clamp(dot(_4766 - _4811, _5348) / max(dot(_5348, _5348), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6746++;
                                continue;
                            }
                            _6864 = _6748;
                        }
                        float _4842 = max(length(vec2(dFdxFine(_4557.x), dFdyFine(_4557.y))) * 0.5, 0.75);
                        _6761 = smoothstep(_4842, -_4842, _6742 ? (-_6744) : _6744);
                        break;
                    }
                    _6760 = 1.0;
                }
                _6759 = _6760;
            }
            float _4864 = max((abs(dFdxFine(_6759)) + abs(dFdyFine(_6759))) * 0.5, 0.5);
            _6761 = smoothstep(_4864, -_4864, _6759);
            break;
        } while(false);
        float _4573 = _6721 * _6761;
        SPIRV_CROSS_BRANCH
        if ((((true && (instances_1._data[input_instance_id].packed_flags == 0u)) && (instances_1._data[input_instance_id].border_width == 0.0)) && all(equal(instances_1._data[input_instance_id].border_widths, vec4(0.0)))) && (instances_1._data[input_instance_id].shadow_color.w == 0.0))
        {
            float _3550 = instances_1._data[input_instance_id].fill_color.w * _4549;
            vec4 _3565 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _3550, _3550) * _4573;
            if (_3565.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6850 = _3565;
            break;
        }
        vec4 _3576 = instances_1._data[input_instance_id].border_widths * _1788.uniforms.scale_factor;
        float _3578 = _3576.x;
        float _3580 = _3576.y;
        float _3583 = _3576.z;
        float _3586 = _3576.w;
        bool _3604 = _4549 > 0.0;
        float _6802 = 0.0;
        if (true && (((((_3578 + _3580) + _3583) + _3586) > 0.0) && _3418))
        {
            vec4 _3673 = max(_3388 - vec4(max(_3578, _3586), max(_3578, _3580), max(_3583, _3580), max(_3583, _3586)), vec4(0.0));
            vec2 _3677 = input_local_pos - vec2((_3586 - _3580) * 0.5, (_3578 - _3583) * 0.5);
            bool _5378 = _3677.y < 0.0;
            float _5392 = (_3677.x < 0.0) ? (_5378 ? _3673.x : _3673.w) : (_5378 ? _3673.y : _3673.z);
            vec2 _5399 = (abs(_3677) - max(vec2(input_size.x - ((_3580 + _3586) * 0.5), input_size.y - ((_3578 + _3583) * 0.5)), vec2(0.0))) + vec2(_5392);
            _6802 = _4549 - smoothstep(_3482, _4547, (min(max(_5399.x, _5399.y), 0.0) + length(max(_5399, vec2(0.0)))) - _5392);
        }
        else
        {
            float _6803 = 0.0;
            if (true && (_3403 > 0.0))
            {
                _6803 = _4549 - smoothstep(_3482, _4547, _6708 + _3403);
            }
            else
            {
                _6803 = 0.0;
            }
            _6802 = _6803;
        }
        uint _3774 = instances_1._data[input_instance_id].packed_flags & 255u;
        uint _3778 = (instances_1._data[input_instance_id].packed_flags >> 8u) & 255u;
        uint _3782 = (instances_1._data[input_instance_id].packed_flags >> 16u) & 255u;
        bool _3786 = (instances_1._data[input_instance_id].packed_flags & 33554432u) != 0u;
        vec4 _7128 = vec4(0.0);
        _7128 = vec4(0.0);
        vec4 _7151 = vec4(0.0);
        SPIRV_CROSS_LOOP
        for (uint _6782 = 0u; _6782 < 2u; _7128 = _7151, _6782++)
        {
            bool _3794 = _6782 == 0u;
            if (true && (_3794 ? (_3407 > 0.0) : _3786))
            {
                vec2 _6825 = vec2(0.0);
                vec2 _6827 = vec2(0.0);
                vec4 _6830 = vec4(0.0);
                vec4 _6836 = vec4(0.0);
                float _6840 = 0.0;
                if (_3794)
                {
                    float _3820 = ((instances_1._data[input_instance_id].packed_flags & 268435456u) != 0u) ? (instances_1._data[input_instance_id].noise_scale * _1788.uniforms.scale_factor) : 0.0;
                    vec2 _6828 = vec2(0.0);
                    vec4 _6831 = vec4(0.0);
                    if (_3418)
                    {
                        _6831 = max(_3388 + vec4(_3820), vec4(0.0));
                        _6828 = max(input_size + vec2(_3820), vec2(0.0));
                    }
                    else
                    {
                        _6831 = _3388;
                        _6828 = input_size;
                    }
                    _6840 = _3407;
                    _6836 = instances_1._data[input_instance_id].shadow_color;
                    _6830 = _6831;
                    _6827 = _6828;
                    _6825 = _3414;
                }
                else
                {
                    _6840 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].blur * _1788.uniforms.scale_factor;
                    _6836 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].color;
                    _6830 = _3388;
                    _6827 = input_size;
                    _6825 = vec2(shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_y) * _1788.uniforms.scale_factor;
                }
                vec2 _3885 = input_local_pos - _6825;
                float _6834 = 0.0;
                do
                {
                    if (_3418)
                    {
                        bool _5518 = _3885.y < 0.0;
                        float _5532 = (_3885.x < 0.0) ? (_5518 ? _6830.x : _6830.w) : (_5518 ? _6830.y : _6830.z);
                        vec2 _5539 = (abs(_3885) - _6827) + vec2(_5532);
                        _6834 = (min(max(_5539.x, _5539.y), 0.0) + length(max(_5539, vec2(0.0)))) - _5532;
                        break;
                    }
                    if (instances_1._data[input_instance_id].shape_type == 1u)
                    {
                        _6834 = length(_3885) - min(_6827.x, _6827.y);
                        break;
                    }
                    if (instances_1._data[input_instance_id].shape_type == 4u)
                    {
                        float _6833 = 0.0;
                        do
                        {
                            vec2 _5568 = max(_6827, vec2(0.001000000047497451305389404296875));
                            float _5573 = length(_3885 / _5568);
                            if (_5573 < 9.9999999747524270787835121154785e-07)
                            {
                                _6833 = -min(_5568.x, _5568.y);
                                break;
                            }
                            _6833 = (_5573 - 1.0) / max(length(_3885 / (_5568 * _5568)) / _5573, 9.9999999747524270787835121154785e-07);
                            break;
                        } while(false);
                        _6834 = _6833;
                        break;
                    }
                    _6834 = 1.0;
                    break;
                } while(false);
                float _3902 = _6836.w * (smoothstep(_6840, -_6840, _6834) * (1.0 - _4549));
                _7151 = _7128 + (vec4(_6836.xyz * _3902, _3902) * (1.0 - _7128.w));
            }
            else
            {
                _7151 = _7128;
            }
        }
        vec4 _7143 = vec4(0.0);
        if (true && _3604)
        {
            vec4 _7124 = vec4(0.0);
            if (_3774 > 0u)
            {
                float _6783 = 0.0;
                if (_3774 == 4u)
                {
                    vec2 _3943 = vec2(0.5 + instances_1._data[input_instance_id].shadow_offset_x, 0.5 + instances_1._data[input_instance_id].shadow_offset_y);
                    float _6784 = 0.0;
                    if ((instances_1._data[input_instance_id].packed_flags & 536870912u) != 0u)
                    {
                        _6784 = length((input_uv - _3943) / max(vec2(instances_1._data[input_instance_id].noise_scale, instances_1._data[input_instance_id].noise_intensity), vec2(9.9999997473787516355514526367188e-05)));
                    }
                    else
                    {
                        _6784 = length(input_uv - _3943) * 2.0;
                    }
                    _6783 = _6784;
                }
                else
                {
                    float _6785 = 0.0;
                    if (_3774 == 5u)
                    {
                        _6785 = fract(((atan(input_uv.y - 0.5, input_uv.x - 0.5) - uintBitsToFloat(instances_1._data[input_instance_id]._ext_reserved)) * 0.15915493667125701904296875) + 0.5);
                    }
                    else
                    {
                        float _4005 = (instances_1._data[input_instance_id].shape_type == 3u) ? 0.0 : (((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y));
                        vec2 _4025 = clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_4005 * 2.0))) - vec2(_4005)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0));
                        float _6786 = 0.0;
                        if (_3774 == 1u)
                        {
                            _6786 = _4025.y;
                        }
                        else
                        {
                            float _6787 = 0.0;
                            if (_3774 == 2u)
                            {
                                _6787 = _4025.x;
                            }
                            else
                            {
                                _6787 = (_4025.x + _4025.y) * 0.5;
                            }
                            _6786 = _6787;
                        }
                        _6785 = _6786;
                    }
                    _6783 = _6785;
                }
                uint _4051 = (instances_1._data[input_instance_id].packed_flags >> 26u) & 3u;
                float _6788 = 0.0;
                if (_4051 == 1u)
                {
                    _6788 = fract(_6783);
                }
                else
                {
                    float _6789 = 0.0;
                    if (_4051 == 2u)
                    {
                        float _4063 = mod(abs(_6783), 2.0);
                        _6789 = (_4063 > 1.0) ? (2.0 - _4063) : _4063;
                    }
                    else
                    {
                        _6789 = clamp(_6783, 0.0, 1.0);
                    }
                    _6788 = _6789;
                }
                vec4 _7121 = vec4(0.0);
                if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
                {
                    vec4 _6794 = vec4(0.0);
                    do
                    {
                        if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                        {
                            _6794 = vec4(0.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                        {
                            _6794 = vec4(1.0, 0.0, 1.0, 1.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                        {
                            _6794 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                            break;
                        }
                        uint _5646 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                        float _5652 = clamp(_6788, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5646].position);
                        vec4 _6791 = vec4(0.0);
                        _6791 = grad_stops_1._data[_5646].color;
                        bool _7160 = false;
                        vec4 _6869 = vec4(0.0);
                        uint _6790 = 0u;
                        bool _6792 = false;
                        for (; _6790 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6792 = _7160, _6791 = _6869, _6790++)
                        {
                            uint _5668 = instances_1._data[input_instance_id].gradient_stop_offset + _6790;
                            uint _5684 = _5668 + 1u;
                            bool _5708 = ((!_6792) && (_5652 >= grad_stops_1._data[_5668].position)) && (_5652 <= grad_stops_1._data[_5684].position);
                            if (_5708)
                            {
                                float _5714 = grad_stops_1._data[_5684].position - grad_stops_1._data[_5668].position;
                                vec4 _5732 = mix(vec4(grad_stops_1._data[_5668].color.xyz * grad_stops_1._data[_5668].color.w, grad_stops_1._data[_5668].color.w), vec4(grad_stops_1._data[_5684].color.xyz * grad_stops_1._data[_5684].color.w, grad_stops_1._data[_5684].color.w), vec4((_5714 > 9.9999999747524270787835121154785e-07) ? ((_5652 - grad_stops_1._data[_5668].position) / _5714) : 0.0));
                                float _5771 = _5732.w;
                                vec4 _5784 = vec4(_5732.xyz / vec3(_5771), _5771);
                                bvec4 _5785 = bvec4(_5771 > 9.9999999747524270787835121154785e-07);
                                _6869 = vec4(_5785.x ? _5784.x : vec4(0.0).x, _5785.y ? _5784.y : vec4(0.0).y, _5785.z ? _5784.z : vec4(0.0).z, _5785.w ? _5784.w : vec4(0.0).w);
                            }
                            else
                            {
                                _6869 = _6791;
                            }
                            _7160 = _5708 ? true : _6792;
                        }
                        _6794 = _6791;
                        break;
                    } while(false);
                    _7121 = _6794;
                }
                else
                {
                    vec4 _4096 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_6788));
                    float _5816 = _4096.w;
                    vec4 _5829 = vec4(_4096.xyz / vec3(_5816), _5816);
                    bvec4 _5830 = bvec4(_5816 > 9.9999999747524270787835121154785e-07);
                    _7121 = vec4(_5830.x ? _5829.x : vec4(0.0).x, _5830.y ? _5829.y : vec4(0.0).y, _5830.z ? _5829.z : vec4(0.0).z, _5830.w ? _5829.w : vec4(0.0).w);
                }
                vec3 _4109 = clamp(_7121.xyz + vec3((float(_648[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
                vec4 _7058 = _7121;
                _7058.x = _4109.x;
                _7058.y = _4109.y;
                _7058.z = _4109.z;
                _7124 = _7058;
            }
            else
            {
                _7124 = instances_1._data[input_instance_id].fill_color;
            }
            vec4 _7125 = vec4(0.0);
            if ((_3778 > 0u) && (instances_1._data[input_instance_id].noise_scale > 0.0))
            {
                float _6795 = 0.0;
                if (_3778 == 1u)
                {
                    float _5874 = float(_3782);
                    vec2 _5880 = ((input_local_pos / vec2(_1788.uniforms.scale_factor)) / vec2(max(instances_1._data[input_instance_id].noise_scale, 0.001000000047497451305389404296875))) + vec2(_5874 * 17.299999237060546875, _5874 * 31.700000762939453125);
                    vec2 _5882 = floor(_5880);
                    vec2 _5884 = fract(_5880);
                    vec2 _5892 = (_5884 * _5884) * (vec2(3.0) - (_5884 * 2.0));
                    uint _5935 = uint(abs(_5882.y) * 1000.0) * 2654435761u;
                    uint _5947 = (_5935 ^ 61u) ^ (_5935 >> 16u);
                    uint _5951 = _5947 + (_5947 << 3u);
                    uint _5957 = (_5951 ^ (_5951 >> 4u)) * 668265261u;
                    uint _5937 = uint(abs(_5882.x) * 1000.0) ^ (_5957 ^ (_5957 >> 15u));
                    uint _5969 = (_5937 ^ 61u) ^ (_5937 >> 16u);
                    uint _5973 = _5969 + (_5969 << 3u);
                    uint _5979 = (_5973 ^ (_5973 >> 4u)) * 668265261u;
                    vec2 _5896 = _5882 + vec2(1.0, 0.0);
                    uint _6003 = uint(abs(_5896.y) * 1000.0) * 2654435761u;
                    uint _6015 = (_6003 ^ 61u) ^ (_6003 >> 16u);
                    uint _6019 = _6015 + (_6015 << 3u);
                    uint _6025 = (_6019 ^ (_6019 >> 4u)) * 668265261u;
                    uint _6005 = uint(abs(_5896.x) * 1000.0) ^ (_6025 ^ (_6025 >> 15u));
                    uint _6037 = (_6005 ^ 61u) ^ (_6005 >> 16u);
                    uint _6041 = _6037 + (_6037 << 3u);
                    uint _6047 = (_6041 ^ (_6041 >> 4u)) * 668265261u;
                    vec2 _5899 = _5882 + vec2(0.0, 1.0);
                    uint _6071 = uint(abs(_5899.y) * 1000.0) * 2654435761u;
                    uint _6083 = (_6071 ^ 61u) ^ (_6071 >> 16u);
                    uint _6087 = _6083 + (_6083 << 3u);
                    uint _6093 = (_6087 ^ (_6087 >> 4u)) * 668265261u;
                    uint _6073 = uint(abs(_5899.x) * 1000.0) ^ (_6093 ^ (_6093 >> 15u));
                    uint _6105 = (_6073 ^ 61u) ^ (_6073 >> 16u);
                    uint _6109 = _6105 + (_6105 << 3u);
                    uint _6115 = (_6109 ^ (_6109 >> 4u)) * 668265261u;
                    vec2 _5902 = _5882 + vec2(1.0);
                    uint _6139 = uint(abs(_5902.y) * 1000.0) * 2654435761u;
                    uint _6151 = (_6139 ^ 61u) ^ (_6139 >> 16u);
                    uint _6155 = _6151 + (_6151 << 3u);
                    uint _6161 = (_6155 ^ (_6155 >> 4u)) * 668265261u;
                    uint _6141 = uint(abs(_5902.x) * 1000.0) ^ (_6161 ^ (_6161 >> 15u));
                    uint _6173 = (_6141 ^ 61u) ^ (_6141 >> 16u);
                    uint _6177 = _6173 + (_6173 << 3u);
                    uint _6183 = (_6177 ^ (_6177 >> 4u)) * 668265261u;
                    float _5907 = _5892.x;
                    _6795 = mix(mix(float(_5979 ^ (_5979 >> 15u)) * 2.3283064365386962890625e-10, float(_6047 ^ (_6047 >> 15u)) * 2.3283064365386962890625e-10, _5907), mix(float(_6115 ^ (_6115 >> 15u)) * 2.3283064365386962890625e-10, float(_6183 ^ (_6183 >> 15u)) * 2.3283064365386962890625e-10, _5907), _5892.y) - 0.5;
                }
                else
                {
                    float _6796 = 0.0;
                    if (_3778 == 2u)
                    {
                        uint _4150 = _3782 ^ (_1788.uniforms.frame_seed & 255u);
                        vec2 _6204 = floor(input_screen_pos) + vec2(float(_4150 & 255u) * 3.7000000476837158203125, float((_4150 >> 8u) & 255u) * 5.099999904632568359375);
                        uint _6225 = uint(abs(_6204.y) * 1000.0) * 2654435761u;
                        uint _6237 = (_6225 ^ 61u) ^ (_6225 >> 16u);
                        uint _6241 = _6237 + (_6237 << 3u);
                        uint _6247 = (_6241 ^ (_6241 >> 4u)) * 668265261u;
                        uint _6227 = uint(abs(_6204.x) * 1000.0) ^ (_6247 ^ (_6247 >> 15u));
                        uint _6259 = (_6227 ^ 61u) ^ (_6227 >> 16u);
                        uint _6263 = _6259 + (_6259 << 3u);
                        uint _6269 = (_6263 ^ (_6263 >> 4u)) * 668265261u;
                        _6796 = (float(_6269 ^ (_6269 >> 15u)) * 2.3283064365386962890625e-10) - 0.5;
                    }
                    else
                    {
                        _6796 = 0.0;
                    }
                    _6795 = _6796;
                }
                float _4161 = _6795 * instances_1._data[input_instance_id].noise_intensity;
                _7125 = clamp(_7124 + vec4(_4161, _4161, _4161, 0.0), vec4(0.0), vec4(1.0));
            }
            else
            {
                _7125 = _7124;
            }
            float _4175 = _7125.w * _4549;
            _7143 = _7128 + (vec4(_7125.xyz * _4175, _4175) * (1.0 - _7128.w));
        }
        else
        {
            _7143 = _7128;
        }
        vec4 _7145 = vec4(0.0);
        if ((true && ((instances_1._data[input_instance_id].packed_flags & 16777216u) != 0u)) && _3604)
        {
            vec2 _4198 = input_local_pos - _3414;
            float _6798 = 0.0;
            do
            {
                if (_3418)
                {
                    bool _6333 = _4198.y < 0.0;
                    float _6347 = (_4198.x < 0.0) ? (_6333 ? _3388.x : _3388.w) : (_6333 ? _3388.y : _3388.z);
                    vec2 _6354 = (abs(_4198) - input_size) + vec2(_6347);
                    _6798 = (min(max(_6354.x, _6354.y), 0.0) + length(max(_6354, vec2(0.0)))) - _6347;
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 1u)
                {
                    _6798 = length(_4198) - min(input_size.x, input_size.y);
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 4u)
                {
                    float _6797 = 0.0;
                    do
                    {
                        vec2 _6383 = max(input_size, vec2(0.001000000047497451305389404296875));
                        float _6388 = length(_4198 / _6383);
                        if (_6388 < 9.9999999747524270787835121154785e-07)
                        {
                            _6797 = -min(_6383.x, _6383.y);
                            break;
                        }
                        _6797 = (_6388 - 1.0) / max(length(_4198 / (_6383 * _6383)) / _6388, 9.9999999747524270787835121154785e-07);
                        break;
                    } while(false);
                    _6798 = _6797;
                    break;
                }
                _6798 = -1.0;
                break;
            } while(false);
            float _4219 = instances_1._data[input_instance_id].shadow_color.w * (_4549 * smoothstep(-max(_3407, 1.0), 0.0, _6798));
            _7145 = _7143 + (vec4(instances_1._data[input_instance_id].shadow_color.xyz * _4219, _4219) * (1.0 - _7143.w));
        }
        else
        {
            _7145 = _7143;
        }
        vec4 _7146 = vec4(0.0);
        if (true && (_6802 > 0.0))
        {
            float _4247 = instances_1._data[input_instance_id].border_color.w * _6802;
            _7146 = _7145 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4247, _4247) * (1.0 - _7145.w));
        }
        else
        {
            _7146 = _7145;
        }
        vec4 _4267 = _7146 * _4573;
        if (_4267.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6850 = _4267;
        break;
    } while(false);
    _entryPointOutput = _6850;
}

