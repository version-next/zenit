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
};

layout(binding = 0, std140) uniform ImageParams
{
    Uniforms uniforms;
} _812;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedimage_textureimage_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in vec4 input_tint_color;
layout(location = 6) flat in vec2 input_material;
layout(location = 7) flat in vec4 input_corner_radii;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _1146 = input_corner_radii * _812.uniforms.scale_factor;
    vec4 _1152 = texture(SPIRV_Cross_Combinedimage_textureimage_sampler, input_uv);
    vec4 _1156 = _1152 * input_tint_color;
    float _2282 = 0.0;
    if (any(greaterThan(_1146, vec4(0.0))))
    {
        bool _1238 = input_local_pos.y < 0.0;
        float _1252 = (input_local_pos.x < 0.0) ? (_1238 ? _1146.x : _1146.w) : (_1238 ? _1146.y : _1146.z);
        vec2 _1266 = (abs(input_local_pos) - input_size) + vec2(_1252);
        float _1278 = (min(max(_1266.x, _1266.y), 0.0) + length(max(_1266, vec2(0.0)))) - _1252;
        float _1173 = abs(dFdxFine(_1278)) + abs(dFdyFine(_1278));
        _2282 = smoothstep(_1173 * 0.5, _1173 * (-0.5), _1278);
    }
    else
    {
        _2282 = 1.0;
    }
    float _2239 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2239 = 1.0;
            break;
        }
        vec2 _1356 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _812.uniforms.scale_factor)) - ((input_rect_clip.zw * _812.uniforms.scale_factor) * 0.5);
        float _1369 = min(max(_1356.x, _1356.y), 0.0) + length(max(_1356, vec2(0.0)));
        float _1342 = max((abs(dFdxFine(_1369)) + abs(dFdyFine(_1369))) * 0.5, 0.5);
        _2239 = smoothstep(_1342, -_1342, _1369);
        break;
    } while(false);
    float _2279 = 0.0;
    do
    {
        if (_812.uniforms.clip_shape_kind == 0u)
        {
            _2279 = 1.0;
            break;
        }
        vec2 _1429 = (_812.uniforms.clip_rect.xy + (_812.uniforms.clip_rect.zw * 0.5)) * _812.uniforms.scale_factor;
        vec2 _1436 = (_812.uniforms.clip_rect.zw * _812.uniforms.scale_factor) * 0.5;
        float _2277 = 0.0;
        if (_812.uniforms.clip_shape_kind == 1u)
        {
            vec4 _1445 = _812.uniforms.clip_radii * _812.uniforms.scale_factor;
            vec2 _1448 = input_screen_pos - _1429;
            bool _1604 = _1448.y < 0.0;
            float _1618 = (_1448.x < 0.0) ? (_1604 ? _1445.x : _1445.w) : (_1604 ? _1445.y : _1445.z);
            vec2 _1632 = (abs(_1448) - _1436) + vec2(_1618);
            _2277 = (min(max(_1632.x, _1632.y), 0.0) + length(max(_1632, vec2(0.0)))) - _1618;
        }
        else
        {
            float _2278 = 0.0;
            if (_812.uniforms.clip_shape_kind == 2u)
            {
                _2278 = length((input_screen_pos - _1429) / max(_1436, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_812.uniforms.clip_shape_kind == 3u)
                {
                    uint _1469 = min(_812.uniforms.clip_point_count, 32u);
                    uint _1472 = min(_812.uniforms.clip_contour_count, 8u);
                    if ((_1469 < 3u) || (_1472 == 0u))
                    {
                        _2279 = 1.0;
                        break;
                    }
                    vec2 _1487 = input_screen_pos - (_812.uniforms.clip_rect.xy * _812.uniforms.scale_factor);
                    bool _2260 = false;
                    do
                    {
                        if (_812.uniforms.clip_fill_rule == 0u)
                        {
                            bool _2259 = false;
                            _2259 = false;
                            uint _1707 = 0u;
                            bool _2313 = false;
                            for (uint _2258 = 0u, _2269 = 0u; _2258 < _1472; _2269 = _1707, _2259 = _2313, _2258++)
                            {
                                _1707 = min(_812.uniforms.clip_polygon_end_points[_2258 / 4u][_2258 % 4u], _1469);
                                if (_1707 <= (_2269 + 1u))
                                {
                                    _2313 = _2259;
                                    continue;
                                }
                                bool _2272 = false;
                                _2272 = _2259;
                                bool _2318 = false;
                                for (uint _2270 = _2269; _2270 < _1707; _2272 = _2318, _2270++)
                                {
                                    uint _1723 = _2270 + 1u;
                                    uint _1729 = (_1723 < _1707) ? _1723 : _2269;
                                    uint _1952 = _2270 / 2u;
                                    bvec2 _1962 = bvec2((_2270 % 2u) == 0u);
                                    vec2 _1735 = vec2(_1962.x ? _812.uniforms.clip_polygon_points[_1952].xy.x : _812.uniforms.clip_polygon_points[_1952].zw.x, _1962.y ? _812.uniforms.clip_polygon_points[_1952].xy.y : _812.uniforms.clip_polygon_points[_1952].zw.y) * _812.uniforms.scale_factor;
                                    uint _1968 = _1729 / 2u;
                                    bvec2 _1978 = bvec2((_1729 % 2u) == 0u);
                                    vec2 _1741 = vec2(_1978.x ? _812.uniforms.clip_polygon_points[_1968].xy.x : _812.uniforms.clip_polygon_points[_1968].zw.x, _1978.y ? _812.uniforms.clip_polygon_points[_1968].xy.y : _812.uniforms.clip_polygon_points[_1968].zw.y) * _812.uniforms.scale_factor;
                                    float _1743 = _1741.y;
                                    float _1745 = _1735.y;
                                    float _1746 = _1743 - _1745;
                                    float _1758 = _1487.y;
                                    float _1771 = _1735.x;
                                    if (((_1745 > _1758) != (_1743 > _1758)) && (_1487.x < ((((_1741.x - _1771) * (_1758 - _1745)) / ((abs(_1746) < 9.9999997473787516355514526367188e-05) ? ((_1746 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _1746)) + _1771)))
                                    {
                                        _2318 = !_2272;
                                    }
                                    else
                                    {
                                        _2318 = _2272;
                                    }
                                }
                                _2313 = _2272;
                            }
                            _2260 = _2259;
                            break;
                        }
                        int _2241 = 0;
                        _2241 = 0;
                        uint _1812 = 0u;
                        int _2301 = 0;
                        for (uint _2240 = 0u, _2242 = 0u; _2240 < _1472; _2242 = _1812, _2241 = _2301, _2240++)
                        {
                            _1812 = min(_812.uniforms.clip_polygon_end_points[_2240 / 4u][_2240 % 4u], _1469);
                            if (_1812 <= (_2242 + 1u))
                            {
                                _2301 = _2241;
                                continue;
                            }
                            int _2245 = 0;
                            _2245 = _2241;
                            int _2308 = 0;
                            for (uint _2243 = _2242; _2243 < _1812; _2245 = _2308, _2243++)
                            {
                                uint _1828 = _2243 + 1u;
                                uint _1834 = (_1828 < _1812) ? _1828 : _2242;
                                uint _1992 = _2243 / 2u;
                                bvec2 _2002 = bvec2((_2243 % 2u) == 0u);
                                vec2 _1840 = vec2(_2002.x ? _812.uniforms.clip_polygon_points[_1992].xy.x : _812.uniforms.clip_polygon_points[_1992].zw.x, _2002.y ? _812.uniforms.clip_polygon_points[_1992].xy.y : _812.uniforms.clip_polygon_points[_1992].zw.y) * _812.uniforms.scale_factor;
                                uint _2008 = _1834 / 2u;
                                bvec2 _2018 = bvec2((_1834 % 2u) == 0u);
                                vec2 _1846 = vec2(_2018.x ? _812.uniforms.clip_polygon_points[_2008].xy.x : _812.uniforms.clip_polygon_points[_2008].zw.x, _2018.y ? _812.uniforms.clip_polygon_points[_2008].xy.y : _812.uniforms.clip_polygon_points[_2008].zw.y) * _812.uniforms.scale_factor;
                                float _1848 = _1840.y;
                                float _1850 = _1487.y;
                                if (_1848 <= _1850)
                                {
                                    float _1854 = _1846.y;
                                    int _2309 = 0;
                                    if (_1854 > _1850)
                                    {
                                        float _1862 = _1840.x;
                                        int _2310 = 0;
                                        if ((((_1846.x - _1862) * (_1850 - _1848)) - ((_1487.x - _1862) * (_1854 - _1848))) > 0.0)
                                        {
                                            _2310 = _2245 + 1;
                                        }
                                        else
                                        {
                                            _2310 = _2245;
                                        }
                                        _2309 = _2310;
                                    }
                                    else
                                    {
                                        _2309 = _2245;
                                    }
                                    _2308 = _2309;
                                }
                                else
                                {
                                    float _1891 = _1846.y;
                                    int _2311 = 0;
                                    if (_1891 <= _1850)
                                    {
                                        float _1899 = _1840.x;
                                        int _2312 = 0;
                                        if ((((_1846.x - _1899) * (_1850 - _1848)) - ((_1487.x - _1899) * (_1891 - _1848))) < 0.0)
                                        {
                                            _2312 = _2245 - 1;
                                        }
                                        else
                                        {
                                            _2312 = _2245;
                                        }
                                        _2311 = _2312;
                                    }
                                    else
                                    {
                                        _2311 = _2245;
                                    }
                                    _2308 = _2311;
                                }
                            }
                            _2301 = _2245;
                        }
                        _2260 = _2241 != 0;
                        break;
                    } while(false);
                    float _2262 = 0.0;
                    uint _2263 = 0u;
                    _2263 = 0u;
                    _2262 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _1504 = 0u;
                    float _2314 = 0.0;
                    for (uint _2261 = 0u; _2261 < _1472; _2263 = _1504, _2262 = _2314, _2261++)
                    {
                        _1504 = min(_812.uniforms.clip_polygon_end_points[_2261 / 4u][_2261 % 4u], _1469);
                        if (_1504 <= (_2263 + 1u))
                        {
                            _2314 = _2262;
                            continue;
                        }
                        float _2266 = 0.0;
                        _2266 = _2262;
                        for (uint _2264 = _2263; _2264 < _1504; )
                        {
                            uint _1520 = _2264 + 1u;
                            uint _1526 = (_1520 < _1504) ? _1520 : _2263;
                            uint _2032 = _2264 / 2u;
                            bvec2 _2042 = bvec2((_2264 % 2u) == 0u);
                            vec2 _1532 = vec2(_2042.x ? _812.uniforms.clip_polygon_points[_2032].xy.x : _812.uniforms.clip_polygon_points[_2032].zw.x, _2042.y ? _812.uniforms.clip_polygon_points[_2032].xy.y : _812.uniforms.clip_polygon_points[_2032].zw.y) * _812.uniforms.scale_factor;
                            uint _2048 = _1526 / 2u;
                            bvec2 _2058 = bvec2((_1526 % 2u) == 0u);
                            vec2 _2067 = (vec2(_2058.x ? _812.uniforms.clip_polygon_points[_2048].xy.x : _812.uniforms.clip_polygon_points[_2048].zw.x, _2058.y ? _812.uniforms.clip_polygon_points[_2048].xy.y : _812.uniforms.clip_polygon_points[_2048].zw.y) * _812.uniforms.scale_factor) - _1532;
                            _2266 = min(_2266, length(_1487 - (_1532 + (_2067 * clamp(dot(_1487 - _1532, _2067) / max(dot(_2067, _2067), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _2264++;
                            continue;
                        }
                        _2314 = _2266;
                    }
                    float _1563 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _2279 = smoothstep(_1563, -_1563, _2260 ? (-_2262) : _2262);
                    break;
                }
                _2278 = 1.0;
            }
            _2277 = _2278;
        }
        float _1585 = max((abs(dFdxFine(_2277)) + abs(dFdyFine(_2277))) * 0.5, 0.5);
        _2279 = smoothstep(_1585, -_1585, _2277);
        break;
    } while(false);
    float _1194 = (_2282 * (_2239 * _2279)) * input_material.x;
    vec4 _2444 = vec4(0.0);
    if (input_material.y > 0.5)
    {
        _2444 = _1156 * _1194;
    }
    else
    {
        float _1206 = _1156.w * _1194;
        _2444 = vec4(_1156.xyz * _1206, _1206);
    }
    if (_2444.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _2444;
}

