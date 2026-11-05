#version 430
#ifdef GL_ARB_shader_draw_parameters
#extension GL_ARB_shader_draw_parameters : enable
#endif

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

const vec2 _114[4] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0));
const uint _122[6] = uint[](0u, 1u, 2u, 1u, 3u, 2u);

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

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _146;

uniform int zenit_first_instance;
layout(location = 0) out vec2 _entryPointOutput_local_pos;
layout(location = 1) out vec2 _entryPointOutput_size;
layout(location = 2) out vec2 _entryPointOutput_uv;
layout(location = 3) out vec2 _entryPointOutput_screen_pos;
layout(location = 4) out vec4 _entryPointOutput_rect_clip;
layout(location = 5) flat out uint _entryPointOutput_instance_id;
layout(location = 6) flat out vec4 _entryPointOutput_solid_fill;
layout(location = 7) flat out vec4 _entryPointOutput_solid_border;
layout(location = 8) flat out vec4 _entryPointOutput_solid_radii;
layout(location = 9) flat out vec4 _entryPointOutput_solid_widths;
layout(location = 10) flat out vec3 _entryPointOutput_solid_metrics;
layout(location = 11) flat out uint _entryPointOutput_solid_shape;
layout(location = 12) flat out vec3 _entryPointOutput_second_shadow_metrics;

void main()
{
    uint _1058 = uint(gl_VertexID) % 6u;
    vec2 _1111 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy * _146.uniforms.scale_factor;
    vec2 _1120 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy + instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw) * _146.uniforms.scale_factor;
    vec2 _1156 = vec2(((max(max(max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.y), max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.z, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.w)), 0.0) + max(max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_width, max(max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths.x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths.y), max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths.z, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths.w))), 0.0)) * _146.uniforms.scale_factor) + 2.0);
    vec2 _1157 = _1111 + _1156;
    vec2 _1161 = _1120 - _1156;
    vec2 _1824 = vec2(0.0);
    vec2 _1825 = vec2(0.0);
    if ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip.z >= 0.0) && (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip.w >= 0.0))
    {
        _1825 = max(_1157, (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip.xy * _146.uniforms.scale_factor) + vec2(2.0));
        _1824 = min(_1161, ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip.xy + instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip.zw) * _146.uniforms.scale_factor) - vec2(2.0));
    }
    else
    {
        _1825 = _1157;
        _1824 = _1161;
    }
    vec2 _1827 = vec2(0.0);
    vec2 _1829 = vec2(0.0);
    if (any(lessThanEqual(_1824, _1825)))
    {
        vec2 _1201 = (_1111 + _1120) * 0.5;
        _1829 = _1201;
        _1827 = _1201;
    }
    else
    {
        _1829 = _1824;
        _1827 = _1825;
    }
    vec2 _1826 = vec2(0.0);
    vec2 _1828 = vec2(0.0);
    if (instances_1._data[uint((gl_InstanceID + zenit_first_instance))]._ext_reserved == 1u)
    {
        _1828 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].gradient_to_color.zw;
        _1826 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].gradient_to_color.xy;
    }
    else
    {
        _1828 = _1829;
        _1826 = _1827;
    }
    uint _1217 = uint(gl_VertexID) / 6u;
    vec2 _1830 = vec2(0.0);
    vec2 _1831 = vec2(0.0);
    switch (_1217)
    {
        case 0u:
        {
            vec2 _1820 = _1120;
            _1820.x = _1826.x;
            _1831 = _1820;
            _1830 = _1111;
            break;
        }
        case 1u:
        {
            vec2 _1817 = _1111;
            _1817.x = _1828.x;
            _1831 = _1120;
            _1830 = _1817;
            break;
        }
        case 2u:
        {
            vec2 _1812 = _1111;
            _1812.x = _1826.x;
            _1831 = vec2(_1828.x, _1826.y);
            _1830 = _1812;
            break;
        }
        case 3u:
        {
            vec2 _1809 = _1120;
            _1809.x = _1828.x;
            _1831 = _1809;
            _1830 = vec2(_1826.x, _1828.y);
            break;
        }
        default:
        {
            _1831 = _1828;
            _1830 = _1826;
            break;
        }
    }
    vec2 _1253 = mix(_1830, _1831, _114[_122[_1058]]);
    vec2 _1259 = ((_1253 / _146.uniforms.viewport_size) * vec2(2.0, -2.0)) + vec2(-1.0, 1.0);
    vec4 _1262 = vec4(_1259, 0.0, 1.0);
    _1262.y = -_1259.y;
    gl_Position = _1262;
    _entryPointOutput_local_pos = _1253 - ((_1111 + _1120) * 0.5);
    _entryPointOutput_size = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * _146.uniforms.scale_factor) * 0.5;
    _entryPointOutput_uv = _114[_122[_1058]];
    _entryPointOutput_screen_pos = _1253;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_instance_id = uint((gl_InstanceID + zenit_first_instance));
    _entryPointOutput_solid_fill = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].fill_color;
    _entryPointOutput_solid_border = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_color;
    _entryPointOutput_solid_radii = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii;
    _entryPointOutput_solid_widths = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths;
    _entryPointOutput_solid_metrics = vec3(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_width, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_y);
    _entryPointOutput_solid_shape = (_1217 == 4u) ? 99u : 0u;
    _entryPointOutput_second_shadow_metrics = vec3(0.0);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

