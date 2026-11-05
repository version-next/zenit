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
    vec4 dwrite_gamma;
    vec4 dwrite_settings;
};

struct GlyphInstance
{
    vec2 position;
    vec2 size;
    vec4 uv_rect;
    vec4 color;
    vec4 rect_clip;
    float skew_x;
    float page_index;
    float is_color;
    float shader_snap;
};

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _822;

layout(binding = 1, std430) readonly buffer instances
{
    GlyphInstance _data[];
} instances_1;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedglyph_atlas_coloratlas_sampler;
layout(binding = 1) uniform sampler2D SPIRV_Cross_Combinedglyph_atlasatlas_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_screen_pos;
layout(location = 2) in vec4 input_rect_clip;
layout(location = 3) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput_color;
layout(location = 1) out vec4 _entryPointOutput_weights;

void main()
{
    vec4 _2628 = vec4(0.0);
    vec4 _2629 = vec4(0.0);
    do
    {
        float _2587 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _2587 = 1.0;
                break;
            }
            vec2 _1627 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _822.uniforms.scale_factor)) - ((input_rect_clip.zw * _822.uniforms.scale_factor) * 0.5);
            float _1640 = min(max(_1627.x, _1627.y), 0.0) + length(max(_1627, vec2(0.0)));
            float _1613 = max((abs(dFdxFine(_1640)) + abs(dFdyFine(_1640))) * 0.5, 0.5);
            _2587 = smoothstep(_1613, -_1613, _1640);
            break;
        } while(false);
        float _2627 = 0.0;
        do
        {
            if (_822.uniforms.clip_shape_kind == 0u)
            {
                _2627 = 1.0;
                break;
            }
            vec2 _1700 = (_822.uniforms.clip_rect.xy + (_822.uniforms.clip_rect.zw * 0.5)) * _822.uniforms.scale_factor;
            vec2 _1707 = (_822.uniforms.clip_rect.zw * _822.uniforms.scale_factor) * 0.5;
            float _2625 = 0.0;
            if (_822.uniforms.clip_shape_kind == 1u)
            {
                vec4 _1716 = _822.uniforms.clip_radii * _822.uniforms.scale_factor;
                vec2 _1719 = input_screen_pos - _1700;
                bool _1875 = _1719.y < 0.0;
                float _1889 = (_1719.x < 0.0) ? (_1875 ? _1716.x : _1716.w) : (_1875 ? _1716.y : _1716.z);
                vec2 _1903 = (abs(_1719) - _1707) + vec2(_1889);
                _2625 = (min(max(_1903.x, _1903.y), 0.0) + length(max(_1903, vec2(0.0)))) - _1889;
            }
            else
            {
                float _2626 = 0.0;
                if (_822.uniforms.clip_shape_kind == 2u)
                {
                    _2626 = length((input_screen_pos - _1700) / max(_1707, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_822.uniforms.clip_shape_kind == 3u)
                    {
                        uint _1740 = min(_822.uniforms.clip_point_count, 32u);
                        uint _1743 = min(_822.uniforms.clip_contour_count, 8u);
                        if ((_1740 < 3u) || (_1743 == 0u))
                        {
                            _2627 = 1.0;
                            break;
                        }
                        vec2 _1758 = input_screen_pos - (_822.uniforms.clip_rect.xy * _822.uniforms.scale_factor);
                        bool _2608 = false;
                        do
                        {
                            if (_822.uniforms.clip_fill_rule == 0u)
                            {
                                bool _2607 = false;
                                _2607 = false;
                                uint _1978 = 0u;
                                bool _2642 = false;
                                for (uint _2606 = 0u, _2617 = 0u; _2606 < _1743; _2617 = _1978, _2607 = _2642, _2606++)
                                {
                                    _1978 = min(_822.uniforms.clip_polygon_end_points[_2606 / 4u][_2606 % 4u], _1740);
                                    if (_1978 <= (_2617 + 1u))
                                    {
                                        _2642 = _2607;
                                        continue;
                                    }
                                    bool _2620 = false;
                                    _2620 = _2607;
                                    bool _2647 = false;
                                    for (uint _2618 = _2617; _2618 < _1978; _2620 = _2647, _2618++)
                                    {
                                        uint _1994 = _2618 + 1u;
                                        uint _2000 = (_1994 < _1978) ? _1994 : _2617;
                                        uint _2223 = _2618 / 2u;
                                        bvec2 _2233 = bvec2((_2618 % 2u) == 0u);
                                        vec2 _2006 = vec2(_2233.x ? _822.uniforms.clip_polygon_points[_2223].xy.x : _822.uniforms.clip_polygon_points[_2223].zw.x, _2233.y ? _822.uniforms.clip_polygon_points[_2223].xy.y : _822.uniforms.clip_polygon_points[_2223].zw.y) * _822.uniforms.scale_factor;
                                        uint _2239 = _2000 / 2u;
                                        bvec2 _2249 = bvec2((_2000 % 2u) == 0u);
                                        vec2 _2012 = vec2(_2249.x ? _822.uniforms.clip_polygon_points[_2239].xy.x : _822.uniforms.clip_polygon_points[_2239].zw.x, _2249.y ? _822.uniforms.clip_polygon_points[_2239].xy.y : _822.uniforms.clip_polygon_points[_2239].zw.y) * _822.uniforms.scale_factor;
                                        float _2014 = _2012.y;
                                        float _2016 = _2006.y;
                                        float _2017 = _2014 - _2016;
                                        float _2029 = _1758.y;
                                        float _2042 = _2006.x;
                                        if (((_2016 > _2029) != (_2014 > _2029)) && (_1758.x < ((((_2012.x - _2042) * (_2029 - _2016)) / ((abs(_2017) < 9.9999997473787516355514526367188e-05) ? ((_2017 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _2017)) + _2042)))
                                        {
                                            _2647 = !_2620;
                                        }
                                        else
                                        {
                                            _2647 = _2620;
                                        }
                                    }
                                    _2642 = _2620;
                                }
                                _2608 = _2607;
                                break;
                            }
                            int _2589 = 0;
                            _2589 = 0;
                            uint _2083 = 0u;
                            int _2630 = 0;
                            for (uint _2588 = 0u, _2590 = 0u; _2588 < _1743; _2590 = _2083, _2589 = _2630, _2588++)
                            {
                                _2083 = min(_822.uniforms.clip_polygon_end_points[_2588 / 4u][_2588 % 4u], _1740);
                                if (_2083 <= (_2590 + 1u))
                                {
                                    _2630 = _2589;
                                    continue;
                                }
                                int _2593 = 0;
                                _2593 = _2589;
                                int _2637 = 0;
                                for (uint _2591 = _2590; _2591 < _2083; _2593 = _2637, _2591++)
                                {
                                    uint _2099 = _2591 + 1u;
                                    uint _2105 = (_2099 < _2083) ? _2099 : _2590;
                                    uint _2263 = _2591 / 2u;
                                    bvec2 _2273 = bvec2((_2591 % 2u) == 0u);
                                    vec2 _2111 = vec2(_2273.x ? _822.uniforms.clip_polygon_points[_2263].xy.x : _822.uniforms.clip_polygon_points[_2263].zw.x, _2273.y ? _822.uniforms.clip_polygon_points[_2263].xy.y : _822.uniforms.clip_polygon_points[_2263].zw.y) * _822.uniforms.scale_factor;
                                    uint _2279 = _2105 / 2u;
                                    bvec2 _2289 = bvec2((_2105 % 2u) == 0u);
                                    vec2 _2117 = vec2(_2289.x ? _822.uniforms.clip_polygon_points[_2279].xy.x : _822.uniforms.clip_polygon_points[_2279].zw.x, _2289.y ? _822.uniforms.clip_polygon_points[_2279].xy.y : _822.uniforms.clip_polygon_points[_2279].zw.y) * _822.uniforms.scale_factor;
                                    float _2119 = _2111.y;
                                    float _2121 = _1758.y;
                                    if (_2119 <= _2121)
                                    {
                                        float _2125 = _2117.y;
                                        int _2638 = 0;
                                        if (_2125 > _2121)
                                        {
                                            float _2133 = _2111.x;
                                            int _2639 = 0;
                                            if ((((_2117.x - _2133) * (_2121 - _2119)) - ((_1758.x - _2133) * (_2125 - _2119))) > 0.0)
                                            {
                                                _2639 = _2593 + 1;
                                            }
                                            else
                                            {
                                                _2639 = _2593;
                                            }
                                            _2638 = _2639;
                                        }
                                        else
                                        {
                                            _2638 = _2593;
                                        }
                                        _2637 = _2638;
                                    }
                                    else
                                    {
                                        float _2162 = _2117.y;
                                        int _2640 = 0;
                                        if (_2162 <= _2121)
                                        {
                                            float _2170 = _2111.x;
                                            int _2641 = 0;
                                            if ((((_2117.x - _2170) * (_2121 - _2119)) - ((_1758.x - _2170) * (_2162 - _2119))) < 0.0)
                                            {
                                                _2641 = _2593 - 1;
                                            }
                                            else
                                            {
                                                _2641 = _2593;
                                            }
                                            _2640 = _2641;
                                        }
                                        else
                                        {
                                            _2640 = _2593;
                                        }
                                        _2637 = _2640;
                                    }
                                }
                                _2630 = _2593;
                            }
                            _2608 = _2589 != 0;
                            break;
                        } while(false);
                        float _2610 = 0.0;
                        uint _2611 = 0u;
                        _2611 = 0u;
                        _2610 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _1775 = 0u;
                        float _2643 = 0.0;
                        for (uint _2609 = 0u; _2609 < _1743; _2611 = _1775, _2610 = _2643, _2609++)
                        {
                            _1775 = min(_822.uniforms.clip_polygon_end_points[_2609 / 4u][_2609 % 4u], _1740);
                            if (_1775 <= (_2611 + 1u))
                            {
                                _2643 = _2610;
                                continue;
                            }
                            float _2614 = 0.0;
                            _2614 = _2610;
                            for (uint _2612 = _2611; _2612 < _1775; )
                            {
                                uint _1791 = _2612 + 1u;
                                uint _1797 = (_1791 < _1775) ? _1791 : _2611;
                                uint _2303 = _2612 / 2u;
                                bvec2 _2313 = bvec2((_2612 % 2u) == 0u);
                                vec2 _1803 = vec2(_2313.x ? _822.uniforms.clip_polygon_points[_2303].xy.x : _822.uniforms.clip_polygon_points[_2303].zw.x, _2313.y ? _822.uniforms.clip_polygon_points[_2303].xy.y : _822.uniforms.clip_polygon_points[_2303].zw.y) * _822.uniforms.scale_factor;
                                uint _2319 = _1797 / 2u;
                                bvec2 _2329 = bvec2((_1797 % 2u) == 0u);
                                vec2 _2338 = (vec2(_2329.x ? _822.uniforms.clip_polygon_points[_2319].xy.x : _822.uniforms.clip_polygon_points[_2319].zw.x, _2329.y ? _822.uniforms.clip_polygon_points[_2319].xy.y : _822.uniforms.clip_polygon_points[_2319].zw.y) * _822.uniforms.scale_factor) - _1803;
                                _2614 = min(_2614, length(_1758 - (_1803 + (_2338 * clamp(dot(_1758 - _1803, _2338) / max(dot(_2338, _2338), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _2612++;
                                continue;
                            }
                            _2643 = _2614;
                        }
                        float _1834 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                        _2627 = smoothstep(_1834, -_1834, _2608 ? (-_2610) : _2610);
                        break;
                    }
                    _2626 = 1.0;
                }
                _2625 = _2626;
            }
            float _1856 = max((abs(dFdxFine(_2625)) + abs(dFdyFine(_2625))) * 0.5, 0.5);
            _2627 = smoothstep(_1856, -_1856, _2625);
            break;
        } while(false);
        float _1565 = _2587 * _2627;
        if ((instances_1._data[input_instance_id].is_color > 0.5) && (instances_1._data[input_instance_id].is_color < 1.5))
        {
            vec4 _1382 = texture(SPIRV_Cross_Combinedglyph_atlas_coloratlas_sampler, input_uv);
            vec4 _1389 = _1382 * (_1565 * instances_1._data[input_instance_id].color.w);
            if (_1389.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _2629 = _1389;
            _2628 = _1389.wwww;
            break;
        }
        if (instances_1._data[input_instance_id].is_color > 1.5)
        {
            vec3 _1412 = texture(SPIRV_Cross_Combinedglyph_atlasatlas_sampler, input_uv).xyz;
            float _1423 = _822.uniforms.dwrite_settings.y * clamp(3.0 - (4.0 * dot(instances_1._data[input_instance_id].color.xyz, vec3(0.300000011920928955078125, 0.589999973773956298828125, 0.10999999940395355224609375))), 0.0, 1.0);
            vec3 _1433 = (_1412 * (1.0 + _1423)) / (vec3(1.0) + (_1412 * _1423));
            vec3 _1475 = clamp(_1433 + ((_1433 * (vec3(1.0) - _1433)) * (((((instances_1._data[input_instance_id].color.xyz * _822.uniforms.dwrite_gamma.x) + vec3(_822.uniforms.dwrite_gamma.y)) * _1433) + (instances_1._data[input_instance_id].color.xyz * _822.uniforms.dwrite_gamma.z)) + vec3(_822.uniforms.dwrite_gamma.w))), vec3(0.0), vec3(1.0)) * (_1565 * instances_1._data[input_instance_id].color.w);
            float _1477 = _1475.x;
            float _1483 = max(_1477, max(_1475.y, _1475.z));
            _2629 = vec4(instances_1._data[input_instance_id].color.xyz * _1475, _1483);
            _2628 = vec4(_1477, _1475.yz, _1483);
            break;
        }
        vec4 _1509 = texture(SPIRV_Cross_Combinedglyph_atlasatlas_sampler, input_uv);
        float _1510 = _1509.x;
        float _2374 = _822.uniforms.dwrite_settings.x * clamp(3.0 - (4.0 * dot(instances_1._data[input_instance_id].color.xyz, vec3(0.300000011920928955078125, 0.589999973773956298828125, 0.10999999940395355224609375))), 0.0, 1.0);
        float _2383 = (_1510 * (1.0 + _2374)) / (1.0 + (_1510 * _2374));
        float _2385 = dot(instances_1._data[input_instance_id].color.xyz, vec3(0.25, 0.5, 0.25));
        float _1523 = instances_1._data[input_instance_id].color.w * (clamp(_2383 + ((_2383 * (1.0 - _2383)) * (((((_822.uniforms.dwrite_gamma.x * _2385) + _822.uniforms.dwrite_gamma.y) * _2383) + (_822.uniforms.dwrite_gamma.z * _2385)) + _822.uniforms.dwrite_gamma.w)), 0.0, 1.0) * _1565);
        if (_1523 < 0.001000000047497451305389404296875)
        {
            discard;
        }
        vec4 _2764 = vec4(instances_1._data[input_instance_id].color.xyz * _1523, _1523);
        _2629 = _2764;
        _2628 = _2764.wwww;
        break;
    } while(false);
    _entryPointOutput_color = _2629;
    _entryPointOutput_weights = _2628;
}

