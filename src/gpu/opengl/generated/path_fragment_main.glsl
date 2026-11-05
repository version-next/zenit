#version 430
#extension GL_ARB_derivative_control : require

struct PathUniforms
{
    vec2 viewport_size;
    float scale_factor;
    uint draw_mode;
    vec4 color;
    vec4 rect;
    uint fill_rule;
    uint point_count;
    uint contour_count;
    uint pad0;
    uvec4 contour_end_points[2];
    vec4 polygon_points[16];
    vec4 clip_rect;
    vec4 clip_radii;
    uint clip_shape_kind;
    uint pad1;
    uint pad2;
    uint pad6;
    uint grad_dir;
    uint grad_stop_count;
    vec2 grad_center;
    float grad_angle;
    uint pad3;
    uint pad4;
    uint pad5;
    vec4 grad_colors[16];
    vec4 grad_positions[4];
};

layout(binding = 1, std140) uniform PathParams
{
    PathUniforms u;
} _103;

layout(location = 0) in vec4 input_fill_color;
layout(location = 1) in vec2 input_local_pos;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3886 = vec4(0.0);
    do
    {
        float _3842 = 0.0;
        do
        {
            if (_103.u.clip_shape_kind == 0u)
            {
                _3842 = 1.0;
                break;
            }
            vec2 _2518 = (_103.u.clip_rect.xy + (_103.u.clip_rect.zw * 0.5)) * _103.u.scale_factor;
            vec2 _2525 = (_103.u.clip_rect.zw * _103.u.scale_factor) * 0.5;
            float _3840 = 0.0;
            if (_103.u.clip_shape_kind == 1u)
            {
                vec2 _2532 = gl_FragCoord.xy - _2518;
                vec4 _2537 = _103.u.clip_radii * _103.u.scale_factor;
                bool _2579 = _2532.y < 0.0;
                float _2593 = (_2532.x < 0.0) ? (_2579 ? _2537.x : _2537.w) : (_2579 ? _2537.y : _2537.z);
                vec2 _2607 = (abs(_2532) - _2525) + vec2(_2593);
                _3840 = (length(max(_2607, vec2(0.0))) + min(max(_2607.x, _2607.y), 0.0)) - _2593;
            }
            else
            {
                float _3841 = 0.0;
                if (_103.u.clip_shape_kind == 2u)
                {
                    vec2 _2626 = max(_2525, vec2(9.9999997473787516355514526367188e-05));
                    _3841 = (length((gl_FragCoord.xy - _2518) / _2626) - 1.0) * min(_2626.x, _2626.y);
                }
                else
                {
                    _3841 = -1.0;
                }
                _3840 = _3841;
            }
            float _2560 = max((abs(dFdxFine(_3840)) + abs(dFdyFine(_3840))) * 0.5, 0.5);
            _3842 = smoothstep(_2560, -_2560, _3840);
            break;
        } while(false);
        if (_103.u.draw_mode == 1u)
        {
            uint _1826 = min(_103.u.point_count, 32u);
            uint _1829 = min(_103.u.contour_count, 8u);
            if ((_1826 < 3u) || (_1829 == 0u))
            {
                _3886 = vec4(0.0);
                break;
            }
            bool _3869 = false;
            do
            {
                if (_103.u.fill_rule == 0u)
                {
                    bool _3868 = false;
                    _3868 = false;
                    uint _2694 = 0u;
                    bool _3901 = false;
                    for (uint _3867 = 0u, _3878 = 0u; _3867 < _103.u.contour_count; _3878 = _2694, _3868 = _3901, _3867++)
                    {
                        _2694 = min(_103.u.contour_end_points[_3867 / 4u][_3867 % 4u], _103.u.point_count);
                        if (_2694 <= (_3878 + 1u))
                        {
                            _3901 = _3868;
                            continue;
                        }
                        bool _3881 = false;
                        _3881 = _3868;
                        bool _3906 = false;
                        for (uint _3879 = _3878; _3879 < _2694; _3881 = _3906, _3879++)
                        {
                            uint _2710 = _3879 + 1u;
                            uint _2716 = (_2710 < _2694) ? _2710 : _3878;
                            uint _2929 = _3879 / 2u;
                            bvec2 _2939 = bvec2((_3879 % 2u) == 0u);
                            vec2 _2940 = vec2(_2939.x ? _103.u.polygon_points[_2929].xy.x : _103.u.polygon_points[_2929].zw.x, _2939.y ? _103.u.polygon_points[_2929].xy.y : _103.u.polygon_points[_2929].zw.y);
                            uint _2945 = _2716 / 2u;
                            bvec2 _2955 = bvec2((_2716 % 2u) == 0u);
                            vec2 _2956 = vec2(_2955.x ? _103.u.polygon_points[_2945].xy.x : _103.u.polygon_points[_2945].zw.x, _2955.y ? _103.u.polygon_points[_2945].xy.y : _103.u.polygon_points[_2945].zw.y);
                            float _2724 = _2956.y;
                            float _2726 = _2940.y;
                            float _2727 = _2724 - _2726;
                            float _2752 = _2940.x;
                            if (((_2726 > input_local_pos.y) != (_2724 > input_local_pos.y)) && (input_local_pos.x < ((((_2956.x - _2752) * (input_local_pos.y - _2726)) / ((abs(_2727) < 9.9999997473787516355514526367188e-05) ? ((_2727 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _2727)) + _2752)))
                            {
                                _3906 = !_3881;
                            }
                            else
                            {
                                _3906 = _3881;
                            }
                        }
                        _3901 = _3881;
                    }
                    _3869 = _3868;
                    break;
                }
                int _3850 = 0;
                _3850 = 0;
                uint _2795 = 0u;
                int _3889 = 0;
                for (uint _3849 = 0u, _3851 = 0u; _3849 < _103.u.contour_count; _3851 = _2795, _3850 = _3889, _3849++)
                {
                    _2795 = min(_103.u.contour_end_points[_3849 / 4u][_3849 % 4u], _103.u.point_count);
                    if (_2795 <= (_3851 + 1u))
                    {
                        _3889 = _3850;
                        continue;
                    }
                    int _3854 = 0;
                    _3854 = _3850;
                    int _3896 = 0;
                    for (uint _3852 = _3851; _3852 < _2795; _3854 = _3896, _3852++)
                    {
                        uint _2811 = _3852 + 1u;
                        uint _2817 = (_2811 < _2795) ? _2811 : _3851;
                        uint _2969 = _3852 / 2u;
                        bvec2 _2979 = bvec2((_3852 % 2u) == 0u);
                        vec2 _2980 = vec2(_2979.x ? _103.u.polygon_points[_2969].xy.x : _103.u.polygon_points[_2969].zw.x, _2979.y ? _103.u.polygon_points[_2969].xy.y : _103.u.polygon_points[_2969].zw.y);
                        uint _2985 = _2817 / 2u;
                        bvec2 _2995 = bvec2((_2817 % 2u) == 0u);
                        vec2 _2996 = vec2(_2995.x ? _103.u.polygon_points[_2985].xy.x : _103.u.polygon_points[_2985].zw.x, _2995.y ? _103.u.polygon_points[_2985].xy.y : _103.u.polygon_points[_2985].zw.y);
                        float _2825 = _2980.y;
                        if (_2825 <= input_local_pos.y)
                        {
                            float _2831 = _2996.y;
                            int _3897 = 0;
                            if (_2831 > input_local_pos.y)
                            {
                                float _2839 = _2980.x;
                                int _3898 = 0;
                                if ((((_2996.x - _2839) * (input_local_pos.y - _2825)) - ((input_local_pos.x - _2839) * (_2831 - _2825))) > 0.0)
                                {
                                    _3898 = _3854 + 1;
                                }
                                else
                                {
                                    _3898 = _3854;
                                }
                                _3897 = _3898;
                            }
                            else
                            {
                                _3897 = _3854;
                            }
                            _3896 = _3897;
                        }
                        else
                        {
                            float _2868 = _2996.y;
                            int _3899 = 0;
                            if (_2868 <= input_local_pos.y)
                            {
                                float _2876 = _2980.x;
                                int _3900 = 0;
                                if ((((_2996.x - _2876) * (input_local_pos.y - _2825)) - ((input_local_pos.x - _2876) * (_2868 - _2825))) < 0.0)
                                {
                                    _3900 = _3854 - 1;
                                }
                                else
                                {
                                    _3900 = _3854;
                                }
                                _3899 = _3900;
                            }
                            else
                            {
                                _3899 = _3854;
                            }
                            _3896 = _3899;
                        }
                    }
                    _3889 = _3854;
                }
                _3869 = _3850 != 0;
                break;
            } while(false);
            float _3871 = 0.0;
            uint _3872 = 0u;
            _3872 = 0u;
            _3871 = uintBitsToFloat(0x7f800000u /* inf */);
            uint _2111 = 0u;
            uvec4 _3428[2] = uvec4[](uvec4(0u), uvec4(0u));
            vec4 _3456[16] = vec4[](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
            vec4 _3483[16] = vec4[](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
            float _3902 = 0.0;
            for (uint _3870 = 0u; _3870 < _1829; _3872 = _2111, _3871 = _3902, _3870++)
            {
                _3428[0] = _103.u.contour_end_points[0];
                _3428[1] = _103.u.contour_end_points[1];
                _2111 = min(_3428[_3870 / 4u][_3870 % 4u], _1826);
                if (_2111 <= (_3872 + 1u))
                {
                    _3902 = _3871;
                    continue;
                }
                float _3875 = 0.0;
                _3875 = _3871;
                for (uint _3873 = _3872; _3873 < _2111; )
                {
                    uint _2127 = _3873 + 1u;
                    uint _2133 = (_2127 < _2111) ? _2127 : _3872;
                    _3456[0] = _103.u.polygon_points[0];
                    _3456[1] = _103.u.polygon_points[1];
                    _3456[2] = _103.u.polygon_points[2];
                    _3456[3] = _103.u.polygon_points[3];
                    _3456[4] = _103.u.polygon_points[4];
                    _3456[5] = _103.u.polygon_points[5];
                    _3456[6] = _103.u.polygon_points[6];
                    _3456[7] = _103.u.polygon_points[7];
                    _3456[8] = _103.u.polygon_points[8];
                    _3456[9] = _103.u.polygon_points[9];
                    _3456[10] = _103.u.polygon_points[10];
                    _3456[11] = _103.u.polygon_points[11];
                    _3456[12] = _103.u.polygon_points[12];
                    _3456[13] = _103.u.polygon_points[13];
                    _3456[14] = _103.u.polygon_points[14];
                    _3456[15] = _103.u.polygon_points[15];
                    uint _3009 = _3873 / 2u;
                    bvec2 _3019 = bvec2((_3873 % 2u) == 0u);
                    vec2 _3020 = vec2(_3019.x ? _3456[_3009].xy.x : _3456[_3009].zw.x, _3019.y ? _3456[_3009].xy.y : _3456[_3009].zw.y);
                    _3483[0] = _103.u.polygon_points[0];
                    _3483[1] = _103.u.polygon_points[1];
                    _3483[2] = _103.u.polygon_points[2];
                    _3483[3] = _103.u.polygon_points[3];
                    _3483[4] = _103.u.polygon_points[4];
                    _3483[5] = _103.u.polygon_points[5];
                    _3483[6] = _103.u.polygon_points[6];
                    _3483[7] = _103.u.polygon_points[7];
                    _3483[8] = _103.u.polygon_points[8];
                    _3483[9] = _103.u.polygon_points[9];
                    _3483[10] = _103.u.polygon_points[10];
                    _3483[11] = _103.u.polygon_points[11];
                    _3483[12] = _103.u.polygon_points[12];
                    _3483[13] = _103.u.polygon_points[13];
                    _3483[14] = _103.u.polygon_points[14];
                    _3483[15] = _103.u.polygon_points[15];
                    uint _3025 = _2133 / 2u;
                    bvec2 _3035 = bvec2((_2133 % 2u) == 0u);
                    vec2 _3044 = vec2(_3035.x ? _3483[_3025].xy.x : _3483[_3025].zw.x, _3035.y ? _3483[_3025].xy.y : _3483[_3025].zw.y) - _3020;
                    _3875 = min(_3875, length(input_local_pos - (_3020 + (_3044 * clamp(dot(input_local_pos - _3020, _3044) / max(dot(_3044, _3044), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                    _3873++;
                    continue;
                }
                _3902 = _3875;
            }
            float _2426 = max(length(vec2(dFdxFine(input_local_pos.x), dFdyFine(input_local_pos.y))) * 0.5, 0.75 / max(_103.u.scale_factor, 1.0));
            float _2441 = (smoothstep(_2426, -_2426, _3869 ? (-_3871) : _3871) * _103.u.color.w) * _3842;
            _3886 = vec4(_103.u.color.xyz * _2441, _2441);
            break;
        }
        if (_103.u.draw_mode == 2u)
        {
            float _3843 = 0.0;
            do
            {
                vec2 _3075 = (input_local_pos / max(_103.u.rect.zw, vec2(9.9999999747524270787835121154785e-07))) - _103.u.grad_center;
                if (_103.u.grad_dir == 4u)
                {
                    _3843 = clamp(length(_3075) * 2.0, 0.0, 1.0);
                    break;
                }
                float _3092 = atan(_3075.y, _3075.x) - _103.u.grad_angle;
                _3843 = (_3092 - (6.283185482025146484375 * floor(_3092 * 0.15915493667125701904296875))) * 0.15915493667125701904296875;
                break;
            } while(false);
            vec4 _3848 = vec4(0.0);
            do
            {
                uint _3122 = min(_103.u.grad_stop_count, 16u);
                if (_3122 == 0u)
                {
                    _3848 = vec4(0.0);
                    break;
                }
                if (_3122 == 1u)
                {
                    _3848 = _103.u.grad_colors[0];
                    break;
                }
                float _3134 = clamp(_3843, 0.0, 1.0);
                if (_3134 <= _103.u.grad_positions[0u].x)
                {
                    _3848 = _103.u.grad_colors[0];
                    break;
                }
                vec4 _3845 = vec4(0.0);
                _3845 = _103.u.grad_colors[_3122 - 1u];
                bool _3994 = false;
                vec4 _3887 = vec4(0.0);
                uint _3844 = 1u;
                bool _3846 = false;
                for (; _3844 < _3122; _3846 = _3994, _3845 = _3887, _3844++)
                {
                    uint _3205 = _3844 / 4u;
                    uint _3207 = _3844 % 4u;
                    bool _3158 = (!_3846) && (_3134 <= _103.u.grad_positions[_3205][_3207]);
                    if (_3158)
                    {
                        uint _3163 = _3844 - 1u;
                        uint _3221 = _3163 / 4u;
                        uint _3223 = _3163 % 4u;
                        float _3165 = _103.u.grad_positions[_3205][_3207] - _103.u.grad_positions[_3221][_3223];
                        _3887 = mix(_103.u.grad_colors[_3163], _103.u.grad_colors[_3844], vec4((_3165 > 9.9999999747524270787835121154785e-07) ? ((_3134 - _103.u.grad_positions[_3221][_3223]) / _3165) : 0.0));
                    }
                    else
                    {
                        _3887 = _3845;
                    }
                    _3994 = _3158 ? true : _3846;
                }
                _3848 = _3845;
                break;
            } while(false);
            float _2472 = (_3848.w * input_fill_color.w) * _3842;
            _3886 = vec4(_3848.xyz * _2472, _2472);
            break;
        }
        _3886 = input_fill_color * _3842;
        break;
    } while(false);
    _entryPointOutput = _3886;
}

