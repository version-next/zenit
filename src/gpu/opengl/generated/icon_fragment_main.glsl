#version 430
#extension GL_ARB_derivative_control : require

struct IconInstanceData
{
    vec4 rect;
    vec4 tint_color;
    vec4 rect_clip;
    float corner_radius;
    float opacity;
    float rotate;
    float _padding2;
};

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

layout(binding = 1, std430) readonly buffer instances
{
    IconInstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _836;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedmask_texatlas_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    float _1080 = instances_1._data[input_instance_id].corner_radius * _836.uniforms.scale_factor;
    vec4 _1086 = texture(SPIRV_Cross_Combinedmask_texatlas_sampler, input_uv);
    float _1087 = _1086.x;
    float _2226 = 0.0;
    if (_1080 > 0.0)
    {
        vec2 _1217 = (abs(input_local_pos) - input_size) + vec2(_1080);
        float _1229 = (min(max(_1217.x, _1217.y), 0.0) + length(max(_1217, vec2(0.0)))) - _1080;
        float _1103 = abs(dFdxFine(_1229)) + abs(dFdyFine(_1229));
        _2226 = _1087 * smoothstep(_1103 * 0.5, _1103 * (-0.5), _1229);
    }
    else
    {
        _2226 = _1087;
    }
    float _2183 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2183 = 1.0;
            break;
        }
        vec2 _1307 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _836.uniforms.scale_factor)) - ((input_rect_clip.zw * _836.uniforms.scale_factor) * 0.5);
        float _1320 = min(max(_1307.x, _1307.y), 0.0) + length(max(_1307, vec2(0.0)));
        float _1293 = max((abs(dFdxFine(_1320)) + abs(dFdyFine(_1320))) * 0.5, 0.5);
        _2183 = smoothstep(_1293, -_1293, _1320);
        break;
    } while(false);
    float _2223 = 0.0;
    do
    {
        if (_836.uniforms.clip_shape_kind == 0u)
        {
            _2223 = 1.0;
            break;
        }
        vec2 _1380 = (_836.uniforms.clip_rect.xy + (_836.uniforms.clip_rect.zw * 0.5)) * _836.uniforms.scale_factor;
        vec2 _1387 = (_836.uniforms.clip_rect.zw * _836.uniforms.scale_factor) * 0.5;
        float _2221 = 0.0;
        if (_836.uniforms.clip_shape_kind == 1u)
        {
            vec4 _1396 = _836.uniforms.clip_radii * _836.uniforms.scale_factor;
            vec2 _1399 = input_screen_pos - _1380;
            bool _1555 = _1399.y < 0.0;
            float _1569 = (_1399.x < 0.0) ? (_1555 ? _1396.x : _1396.w) : (_1555 ? _1396.y : _1396.z);
            vec2 _1583 = (abs(_1399) - _1387) + vec2(_1569);
            _2221 = (min(max(_1583.x, _1583.y), 0.0) + length(max(_1583, vec2(0.0)))) - _1569;
        }
        else
        {
            float _2222 = 0.0;
            if (_836.uniforms.clip_shape_kind == 2u)
            {
                _2222 = length((input_screen_pos - _1380) / max(_1387, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_836.uniforms.clip_shape_kind == 3u)
                {
                    uint _1420 = min(_836.uniforms.clip_point_count, 32u);
                    uint _1423 = min(_836.uniforms.clip_contour_count, 8u);
                    if ((_1420 < 3u) || (_1423 == 0u))
                    {
                        _2223 = 1.0;
                        break;
                    }
                    vec2 _1438 = input_screen_pos - (_836.uniforms.clip_rect.xy * _836.uniforms.scale_factor);
                    bool _2204 = false;
                    do
                    {
                        if (_836.uniforms.clip_fill_rule == 0u)
                        {
                            bool _2203 = false;
                            _2203 = false;
                            uint _1658 = 0u;
                            bool _2257 = false;
                            for (uint _2202 = 0u, _2213 = 0u; _2202 < _1423; _2213 = _1658, _2203 = _2257, _2202++)
                            {
                                _1658 = min(_836.uniforms.clip_polygon_end_points[_2202 / 4u][_2202 % 4u], _1420);
                                if (_1658 <= (_2213 + 1u))
                                {
                                    _2257 = _2203;
                                    continue;
                                }
                                bool _2216 = false;
                                _2216 = _2203;
                                bool _2262 = false;
                                for (uint _2214 = _2213; _2214 < _1658; _2216 = _2262, _2214++)
                                {
                                    uint _1674 = _2214 + 1u;
                                    uint _1680 = (_1674 < _1658) ? _1674 : _2213;
                                    uint _1903 = _2214 / 2u;
                                    bvec2 _1913 = bvec2((_2214 % 2u) == 0u);
                                    vec2 _1686 = vec2(_1913.x ? _836.uniforms.clip_polygon_points[_1903].xy.x : _836.uniforms.clip_polygon_points[_1903].zw.x, _1913.y ? _836.uniforms.clip_polygon_points[_1903].xy.y : _836.uniforms.clip_polygon_points[_1903].zw.y) * _836.uniforms.scale_factor;
                                    uint _1919 = _1680 / 2u;
                                    bvec2 _1929 = bvec2((_1680 % 2u) == 0u);
                                    vec2 _1692 = vec2(_1929.x ? _836.uniforms.clip_polygon_points[_1919].xy.x : _836.uniforms.clip_polygon_points[_1919].zw.x, _1929.y ? _836.uniforms.clip_polygon_points[_1919].xy.y : _836.uniforms.clip_polygon_points[_1919].zw.y) * _836.uniforms.scale_factor;
                                    float _1694 = _1692.y;
                                    float _1696 = _1686.y;
                                    float _1697 = _1694 - _1696;
                                    float _1709 = _1438.y;
                                    float _1722 = _1686.x;
                                    if (((_1696 > _1709) != (_1694 > _1709)) && (_1438.x < ((((_1692.x - _1722) * (_1709 - _1696)) / ((abs(_1697) < 9.9999997473787516355514526367188e-05) ? ((_1697 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _1697)) + _1722)))
                                    {
                                        _2262 = !_2216;
                                    }
                                    else
                                    {
                                        _2262 = _2216;
                                    }
                                }
                                _2257 = _2216;
                            }
                            _2204 = _2203;
                            break;
                        }
                        int _2185 = 0;
                        _2185 = 0;
                        uint _1763 = 0u;
                        int _2245 = 0;
                        for (uint _2184 = 0u, _2186 = 0u; _2184 < _1423; _2186 = _1763, _2185 = _2245, _2184++)
                        {
                            _1763 = min(_836.uniforms.clip_polygon_end_points[_2184 / 4u][_2184 % 4u], _1420);
                            if (_1763 <= (_2186 + 1u))
                            {
                                _2245 = _2185;
                                continue;
                            }
                            int _2189 = 0;
                            _2189 = _2185;
                            int _2252 = 0;
                            for (uint _2187 = _2186; _2187 < _1763; _2189 = _2252, _2187++)
                            {
                                uint _1779 = _2187 + 1u;
                                uint _1785 = (_1779 < _1763) ? _1779 : _2186;
                                uint _1943 = _2187 / 2u;
                                bvec2 _1953 = bvec2((_2187 % 2u) == 0u);
                                vec2 _1791 = vec2(_1953.x ? _836.uniforms.clip_polygon_points[_1943].xy.x : _836.uniforms.clip_polygon_points[_1943].zw.x, _1953.y ? _836.uniforms.clip_polygon_points[_1943].xy.y : _836.uniforms.clip_polygon_points[_1943].zw.y) * _836.uniforms.scale_factor;
                                uint _1959 = _1785 / 2u;
                                bvec2 _1969 = bvec2((_1785 % 2u) == 0u);
                                vec2 _1797 = vec2(_1969.x ? _836.uniforms.clip_polygon_points[_1959].xy.x : _836.uniforms.clip_polygon_points[_1959].zw.x, _1969.y ? _836.uniforms.clip_polygon_points[_1959].xy.y : _836.uniforms.clip_polygon_points[_1959].zw.y) * _836.uniforms.scale_factor;
                                float _1799 = _1791.y;
                                float _1801 = _1438.y;
                                if (_1799 <= _1801)
                                {
                                    float _1805 = _1797.y;
                                    int _2253 = 0;
                                    if (_1805 > _1801)
                                    {
                                        float _1813 = _1791.x;
                                        int _2254 = 0;
                                        if ((((_1797.x - _1813) * (_1801 - _1799)) - ((_1438.x - _1813) * (_1805 - _1799))) > 0.0)
                                        {
                                            _2254 = _2189 + 1;
                                        }
                                        else
                                        {
                                            _2254 = _2189;
                                        }
                                        _2253 = _2254;
                                    }
                                    else
                                    {
                                        _2253 = _2189;
                                    }
                                    _2252 = _2253;
                                }
                                else
                                {
                                    float _1842 = _1797.y;
                                    int _2255 = 0;
                                    if (_1842 <= _1801)
                                    {
                                        float _1850 = _1791.x;
                                        int _2256 = 0;
                                        if ((((_1797.x - _1850) * (_1801 - _1799)) - ((_1438.x - _1850) * (_1842 - _1799))) < 0.0)
                                        {
                                            _2256 = _2189 - 1;
                                        }
                                        else
                                        {
                                            _2256 = _2189;
                                        }
                                        _2255 = _2256;
                                    }
                                    else
                                    {
                                        _2255 = _2189;
                                    }
                                    _2252 = _2255;
                                }
                            }
                            _2245 = _2189;
                        }
                        _2204 = _2185 != 0;
                        break;
                    } while(false);
                    float _2206 = 0.0;
                    uint _2207 = 0u;
                    _2207 = 0u;
                    _2206 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _1455 = 0u;
                    float _2258 = 0.0;
                    for (uint _2205 = 0u; _2205 < _1423; _2207 = _1455, _2206 = _2258, _2205++)
                    {
                        _1455 = min(_836.uniforms.clip_polygon_end_points[_2205 / 4u][_2205 % 4u], _1420);
                        if (_1455 <= (_2207 + 1u))
                        {
                            _2258 = _2206;
                            continue;
                        }
                        float _2210 = 0.0;
                        _2210 = _2206;
                        for (uint _2208 = _2207; _2208 < _1455; )
                        {
                            uint _1471 = _2208 + 1u;
                            uint _1477 = (_1471 < _1455) ? _1471 : _2207;
                            uint _1983 = _2208 / 2u;
                            bvec2 _1993 = bvec2((_2208 % 2u) == 0u);
                            vec2 _1483 = vec2(_1993.x ? _836.uniforms.clip_polygon_points[_1983].xy.x : _836.uniforms.clip_polygon_points[_1983].zw.x, _1993.y ? _836.uniforms.clip_polygon_points[_1983].xy.y : _836.uniforms.clip_polygon_points[_1983].zw.y) * _836.uniforms.scale_factor;
                            uint _1999 = _1477 / 2u;
                            bvec2 _2009 = bvec2((_1477 % 2u) == 0u);
                            vec2 _2018 = (vec2(_2009.x ? _836.uniforms.clip_polygon_points[_1999].xy.x : _836.uniforms.clip_polygon_points[_1999].zw.x, _2009.y ? _836.uniforms.clip_polygon_points[_1999].xy.y : _836.uniforms.clip_polygon_points[_1999].zw.y) * _836.uniforms.scale_factor) - _1483;
                            _2210 = min(_2210, length(_1438 - (_1483 + (_2018 * clamp(dot(_1438 - _1483, _2018) / max(dot(_2018, _2018), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _2208++;
                            continue;
                        }
                        _2258 = _2210;
                    }
                    float _1514 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _2223 = smoothstep(_1514, -_1514, _2204 ? (-_2206) : _2206);
                    break;
                }
                _2222 = 1.0;
            }
            _2221 = _2222;
        }
        float _1536 = max((abs(dFdxFine(_2221)) + abs(dFdyFine(_2221))) * 0.5, 0.5);
        _2223 = smoothstep(_1536, -_1536, _2221);
        break;
    } while(false);
    float _1188 = instances_1._data[input_instance_id].tint_color.w * ((_2226 * (_2183 * _2223)) * instances_1._data[input_instance_id].opacity);
    if (_1188 < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = vec4(instances_1._data[input_instance_id].tint_color.xyz * _1188, _1188);
}

