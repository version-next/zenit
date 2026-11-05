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

float _1485 = 0.0;

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
    float _1063 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shape_type == 3u) ? 0.0 : (((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_blur * 2.0) + abs(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_x)) + abs(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_y));
    float _1473 = 0.0;
    if ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags & 268435456u) != 0u)
    {
        _1473 = _1063 + max(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].noise_scale, 0.0);
    }
    else
    {
        _1473 = _1063;
    }
    float _1474 = 0.0;
    if ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags & 33554432u) != 0u)
    {
        _1474 = max(_1473, ((shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].blur * 2.0) + abs(shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_x)) + abs(shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_y));
    }
    else
    {
        _1474 = _1473;
    }
    float _1475 = 0.0;
    if (((((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shape_type == 0u) && (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].packed_flags == 0u)) && (_1474 == 0.0)) && all(greaterThan(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw, vec2(0.0)))) && (min(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.z * _146.uniforms.scale_factor, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.w * _146.uniforms.scale_factor) <= 2.0))
    {
        _1475 = 0.5 / _146.uniforms.scale_factor;
    }
    else
    {
        _1475 = _1474;
    }
    vec2 _1161 = ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy - vec2(_1475)) * _146.uniforms.scale_factor) + (_114[_122[uint(gl_VertexID)]] * ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw + vec2(_1475 * 2.0)) * _146.uniforms.scale_factor));
    vec2 _1249 = ((_1161 / _146.uniforms.viewport_size) * 2.0) - vec2(1.0);
    vec4 _1257 = vec4(_1249.x, _1485, 0.0, 1.0);
    vec2 _1269 = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * _146.uniforms.scale_factor) * 0.5;
    _1257.y = _1249.y;
    gl_Position = _1257;
    _entryPointOutput_local_pos = _1161 - ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy * _146.uniforms.scale_factor) + _1269);
    _entryPointOutput_size = _1269;
    _entryPointOutput_uv = _114[_122[uint(gl_VertexID)]];
    _entryPointOutput_screen_pos = _1161;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_instance_id = uint((gl_InstanceID + zenit_first_instance));
    _entryPointOutput_solid_fill = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].fill_color;
    _entryPointOutput_solid_border = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_color;
    _entryPointOutput_solid_radii = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii;
    _entryPointOutput_solid_widths = shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].color;
    _entryPointOutput_solid_metrics = vec3(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_blur, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_x, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow_offset_y);
    _entryPointOutput_solid_shape = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shape_type;
    _entryPointOutput_second_shadow_metrics = vec3(shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].blur, shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shadow2_index].offset_y);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

