#version 430

layout(binding = 0, std140) uniform BlendUniforms
{
    vec2 target_size;
    vec2 rect_size;
    vec2 src_uv_scale;
    vec2 inv_offset;
    vec4 inv;
    vec4 params;
    vec4 corner_radii;
    vec4 clip_rect;
    vec4 clip_shape;
    vec4 clip_shape_rect;
    vec4 clip_shape_radii;
    vec4 warp;
    vec4 src_uv_origin;
} _469;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combineddestination_textureSPIRV_Cross_DummySampler;
layout(binding = 1) uniform sampler2D SPIRV_Cross_Combinedsource_texturetexture_sampler;

layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _2111 = vec4(0.0);
    do
    {
        vec4 _1150 = texelFetch(SPIRV_Cross_Combineddestination_textureSPIRV_Cross_DummySampler, ivec3(ivec2(gl_FragCoord.xy), 0).xy, 0);
        vec2 _1176 = vec2((_469.inv.x * gl_FragCoord.x) + (_469.inv.z * gl_FragCoord.y), (_469.inv.y * gl_FragCoord.x) + (_469.inv.w * gl_FragCoord.y)) + _469.inv_offset;
        float _1178 = _1176.x;
        float _1181 = _1176.y;
        if ((((_1178 < 0.0) || (_1181 < 0.0)) || (_1178 >= _469.rect_size.x)) || (_1181 >= _469.rect_size.y))
        {
            _2111 = _1150;
            break;
        }
        vec2 _2097 = vec2(0.0);
        if ((_469.warp.x != 0.0) || (_469.warp.y != 0.0))
        {
            vec2 _1210 = _469.rect_size * 0.5;
            vec2 _1216 = max(_1210 - vec2(_469.params.w), vec2(0.5));
            vec2 _1219 = _1176 - _1210;
            bool _1486 = _1219.x < 0.0;
            bool _1489 = _1219.y < 0.0;
            float _1229 = min(_1486 ? (_1489 ? _469.corner_radii.x : _469.corner_radii.w) : (_1489 ? _469.corner_radii.y : _469.corner_radii.z), min(_1216.x, _1216.y));
            vec2 _1236 = (abs(_1219) - _1216) + vec2(_1229);
            float _1241 = _1236.x;
            float _1243 = _1236.y;
            vec2 _1268 = normalize(_1236);
            bvec2 _1274 = bvec2(_1241 > _1243);
            vec2 _1275 = vec2(_1274.x ? vec2(1.0, 0.0).x : vec2(0.0, 1.0).x, _1274.y ? vec2(1.0, 0.0).y : vec2(0.0, 1.0).y);
            bvec2 _1276 = bvec2((_1241 > 0.0) && (_1243 > 0.0));
            vec2 _1280 = vec2(_1276.x ? _1268.x : _1275.x, _1276.y ? _1268.y : _1275.y) * vec2(_1486 ? (-1.0) : 1.0, _1489 ? (-1.0) : 1.0);
            _2097 = clamp(_1176 - ((_1280 * mix(_469.warp.x, _469.warp.y, _1280.y * _1280.y)) * (1.0 - smoothstep(_469.warp.z, _469.warp.z + max(_469.warp.w, 0.00999999977648258209228515625), max(-((length(max(_1236, vec2(0.0))) + min(max(_1241, _1243), 0.0)) - _1229), 0.0)))), vec2(0.0), _469.rect_size - vec2(1.0));
        }
        else
        {
            _2097 = _1176;
        }
        vec4 _1331 = texture(SPIRV_Cross_Combinedsource_texturetexture_sampler, _469.src_uv_origin.xy + ((_2097 / _469.rect_size) * _469.src_uv_scale));
        float _2098 = 0.0;
        do
        {
            vec2 _1516 = (_469.rect_size - vec2(2.0 * _469.params.w)) * 0.5;
            vec2 _1519 = (_1176 - vec2(_469.params.w)) - _1516;
            bool _1559 = _1519.y < 0.0;
            float _1573 = (_1519.x < 0.0) ? (_1559 ? _469.corner_radii.x : _469.corner_radii.w) : (_1559 ? _469.corner_radii.y : _469.corner_radii.z);
            if (_1573 <= 0.5)
            {
                _2098 = 1.0;
                break;
            }
            vec2 _1534 = (abs(_1519) - _1516) + vec2(_1573);
            _2098 = clamp(0.5 - ((length(max(_1534, vec2(0.0))) + min(max(_1534.x, _1534.y), 0.0)) - _1573), 0.0, 1.0);
            break;
        } while(false);
        float _2101 = 0.0;
        if ((_469.clip_rect.z >= 0.0) && (_469.clip_rect.w >= 0.0))
        {
            vec2 _1600 = _469.clip_rect.zw * 0.5;
            vec2 _1610 = abs(gl_FragCoord.xy - (_469.clip_rect.xy + _1600)) - _1600;
            _2101 = clamp(0.5 - (length(max(_1610, vec2(0.0))) + min(max(_1610.x, _1610.y), 0.0)), 0.0, 1.0);
        }
        else
        {
            _2101 = 1.0;
        }
        uint _1629 = uint(_469.clip_shape.x);
        bool _1631 = _1629 == 1u;
        float _2102 = 0.0;
        if (_1631 || (_1629 == 2u))
        {
            vec2 _1639 = _469.clip_shape_rect.zw * 0.5;
            vec2 _1646 = gl_FragCoord.xy - (_469.clip_shape_rect.xy + _1639);
            float _2099 = 0.0;
            if (_1631)
            {
                bool _1708 = _1646.y < 0.0;
                float _1659 = min((_1646.x < 0.0) ? (_1708 ? _469.clip_shape_radii.x : _469.clip_shape_radii.w) : (_1708 ? _469.clip_shape_radii.y : _469.clip_shape_radii.z), min(_1639.x, _1639.y));
                vec2 _1666 = (abs(_1646) - _1639) + vec2(_1659);
                _2099 = (length(max(_1666, vec2(0.0))) + min(max(_1666.x, _1666.y), 0.0)) - _1659;
            }
            else
            {
                vec2 _1681 = max(_1639, vec2(0.001000000047497451305389404296875));
                _2099 = (length(_1646 / _1681) - 1.0) * min(_1681.x, _1681.y);
            }
            _2102 = _2101 * clamp(0.5 - _2099, 0.0, 1.0);
        }
        else
        {
            _2102 = _2101;
        }
        vec4 _1351 = _1331 * (_2098 * _2102);
        vec4 _2107 = vec4(0.0);
        do
        {
            float _1729 = _1351.w;
            if (_1729 < 9.9999997473787516355514526367188e-05)
            {
                _2107 = vec4(0.0);
                break;
            }
            _2107 = vec4(_1351.xyz / vec3(_1729), _1729);
            break;
        } while(false);
        vec4 _2108 = vec4(0.0);
        do
        {
            float _1753 = _1150.w;
            if (_1753 < 9.9999997473787516355514526367188e-05)
            {
                _2108 = vec4(0.0);
                break;
            }
            _2108 = vec4(_1150.xyz / vec3(_1753), _1753);
            break;
        } while(false);
        vec3 _2109 = vec3(0.0);
        switch (uint(_469.params.y))
        {
            case 1u:
            {
                _2109 = _2107.xyz * _2108.xyz;
                break;
            }
            case 2u:
            {
                _2109 = (_2107.xyz + _2108.xyz) - (_2107.xyz * _2108.xyz);
                break;
            }
            case 3u:
            {
                vec3 _1799 = (_2108.xyz * 2.0) * _2107.xyz;
                vec3 _1809 = vec3(1.0) - (((vec3(1.0) - _2108.xyz) * 2.0) * (vec3(1.0) - _2107.xyz));
                _2109 = vec3((_2108.x <= 0.5) ? _1799.x : _1809.x, (_2108.y <= 0.5) ? _1799.y : _1809.y, (_2108.z <= 0.5) ? _1799.z : _1809.z);
                break;
            }
            case 4u:
            {
                _2109 = min(_2107.xyz, _2108.xyz);
                break;
            }
            case 5u:
            {
                _2109 = max(_2107.xyz, _2108.xyz);
                break;
            }
            case 6u:
            {
                _2109 = vec3((_2107.x >= 1.0) ? 1.0 : min(1.0, _2108.x / max(1.0 - _2107.x, 9.9999997473787516355514526367188e-05)), (_2107.y >= 1.0) ? 1.0 : min(1.0, _2108.y / max(1.0 - _2107.y, 9.9999997473787516355514526367188e-05)), (_2107.z >= 1.0) ? 1.0 : min(1.0, _2108.z / max(1.0 - _2107.z, 9.9999997473787516355514526367188e-05)));
                break;
            }
            case 7u:
            {
                _2109 = vec3((_2107.x <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _2108.x) / max(_2107.x, 9.9999997473787516355514526367188e-05))), (_2107.y <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _2108.y) / max(_2107.y, 9.9999997473787516355514526367188e-05))), (_2107.z <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _2108.z) / max(_2107.z, 9.9999997473787516355514526367188e-05))));
                break;
            }
            case 8u:
            {
                vec3 _1933 = (_2107.xyz * 2.0) * _2108.xyz;
                vec3 _1943 = vec3(1.0) - (((vec3(1.0) - _2107.xyz) * 2.0) * (vec3(1.0) - _2108.xyz));
                _2109 = vec3((_2107.x <= 0.5) ? _1933.x : _1943.x, (_2107.y <= 0.5) ? _1933.y : _1943.y, (_2107.z <= 0.5) ? _1933.z : _1943.z);
                break;
            }
            case 9u:
            {
                vec3 _2031 = _2107.xyz * 2.0;
                vec3 _2040 = _2108.xyz - (((vec3(1.0) - _2031) * _2108.xyz) * (vec3(1.0) - _2108.xyz));
                vec3 _2050 = _2108.xyz + ((_2031 - vec3(1.0)) * (vec3((_2108.x <= 0.25) ? (((((16.0 * _2108.x) - 12.0) * _2108.x) + 4.0) * _2108.x) : sqrt(_2108.x), (_2108.y <= 0.25) ? (((((16.0 * _2108.y) - 12.0) * _2108.y) + 4.0) * _2108.y) : sqrt(_2108.y), (_2108.z <= 0.25) ? (((((16.0 * _2108.z) - 12.0) * _2108.z) + 4.0) * _2108.z) : sqrt(_2108.z)) - _2108.xyz));
                _2109 = vec3((_2107.x <= 0.5) ? _2040.x : _2050.x, (_2107.y <= 0.5) ? _2040.y : _2050.y, (_2107.z <= 0.5) ? _2040.z : _2050.z);
                break;
            }
            case 10u:
            {
                _2109 = abs(_2107.xyz - _2108.xyz);
                break;
            }
            case 11u:
            {
                _2109 = (_2107.xyz + _2108.xyz) - ((_2107.xyz * 2.0) * _2108.xyz);
                break;
            }
            default:
            {
                _2109 = _2107.xyz;
                break;
            }
        }
        float _1433 = _2107.w * _469.params.x;
        float _1438 = 1.0 - _1433;
        float _1440 = _1433 + (_2108.w * _1438);
        vec3 _2110 = vec3(0.0);
        if (_1440 >= 9.9999997473787516355514526367188e-05)
        {
            _2110 = (((_2108.xyz * (_1438 * _2108.w)) + (_2109 * (_1433 * _2108.w))) + (_2107.xyz * ((1.0 - _2108.w) * _1433))) / vec3(_1440);
        }
        else
        {
            _2110 = vec3(0.0);
        }
        _2111 = vec4(_2110 * _1440, _1440);
        break;
    } while(false);
    _entryPointOutput = _2111;
}

