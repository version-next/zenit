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

struct ShadowParam
{
    vec4 color;
    float blur;
    float offset_x;
    float offset_y;
    float _pad;
};

float _1455 = 0.0;

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _146;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

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
    uint _990 = uint(gl_VertexID) % 6u;
    float _1015 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shape_type == 3u) ? 0.0 : (((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_blur * 2.0) + abs(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_x)) + abs(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_y));
    uint _1018 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags & 268435456u;
    float _1420 = 0.0;
    if (_1018 != 0u)
    {
        _1420 = _1015 + max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].noise_scale, 0.0);
    }
    else
    {
        _1420 = _1015;
    }
    float _1421 = 0.0;
    if ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags & 33554432u) != 0u)
    {
        _1421 = max(_1420, ((shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].blur * 2.0) + abs(shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_x)) + abs(shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_y));
    }
    else
    {
        _1421 = _1420;
    }
    float _1422 = 0.0;
    if (((((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shape_type == 0u) && (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags == 0u)) && (_1421 == 0.0)) && all(greaterThan(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw, vec2(0.0)))) && (min(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.z * _146.uniforms.scale_factor, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.w * _146.uniforms.scale_factor) <= 2.0))
    {
        _1422 = 0.5 / _146.uniforms.scale_factor;
    }
    else
    {
        _1422 = _1421;
    }
    vec2 _1099 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy - vec2(_1422)) * _146.uniforms.scale_factor;
    vec2 _1134 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * _146.uniforms.scale_factor) * 0.5;
    vec2 _1141 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy * _146.uniforms.scale_factor) + _1134;
    vec2 _1149 = max((_1134 - vec2(max(max(max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.y), max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.z, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii.w)) * _146.uniforms.scale_factor, 0.0))) - vec2(2.0), vec2(0.0));
    vec2 _1152 = _1141 - _1149;
    vec2 _1155 = _1141 + _1149;
    vec2 _1159 = _1099 + ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw + vec2(_1422 * 2.0)) * _146.uniforms.scale_factor);
    vec2 _1453 = vec2(0.0);
    vec2 _1454 = vec2(0.0);
    switch (uint(gl_VertexID) / 6u)
    {
        case 0u:
        {
            vec2 _1441 = _1159;
            _1441.x = _1152.x;
            _1454 = _1441;
            _1453 = _1099;
            break;
        }
        case 1u:
        {
            vec2 _1438 = _1099;
            _1438.x = _1155.x;
            _1454 = _1159;
            _1453 = _1438;
            break;
        }
        case 2u:
        {
            vec2 _1433 = _1099;
            _1433.x = _1152.x;
            _1454 = vec2(_1155.x, _1152.y);
            _1453 = _1433;
            break;
        }
        default:
        {
            vec2 _1446 = _1159;
            _1446.x = _1155.x;
            _1454 = _1446;
            _1453 = vec2(_1152.x, _1155.y);
            break;
        }
    }
    vec2 _1193 = mix(_1453, _1454, _114[_122[_990]]);
    vec2 _1201 = ((_1193 / _146.uniforms.viewport_size) * 2.0) - vec2(1.0);
    vec4 _1209 = vec4(_1201.x, _1455, 0.0, 1.0);
    _1209.y = _1201.y;
    gl_Position = _1209;
    _entryPointOutput_local_pos = _1193 - _1141;
    _entryPointOutput_size = _1134;
    _entryPointOutput_uv = _114[_122[_990]];
    _entryPointOutput_screen_pos = _1193;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_instance_id = uint((gl_InstanceID + zenit_first_instance));
    _entryPointOutput_solid_fill = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_color;
    _entryPointOutput_solid_border = vec4(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_blur, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].noise_scale, 0.0, 0.0);
    _entryPointOutput_solid_radii = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii;
    _entryPointOutput_solid_widths = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_widths;
    _entryPointOutput_solid_metrics = vec3(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].border_width, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_y);
    _entryPointOutput_solid_shape = _1018;
    _entryPointOutput_second_shadow_metrics = vec3(0.0);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

