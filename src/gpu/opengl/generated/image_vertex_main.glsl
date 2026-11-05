#version 430
#ifdef GL_ARB_shader_draw_parameters
#extension GL_ARB_shader_draw_parameters : enable
#endif

struct ImageInstanceData
{
    vec4 rect;
    vec4 uv_rect;
    vec4 tint_color;
    vec4 transform_linear;
    vec4 corner_radii;
    vec2 transform_translation;
    float opacity;
    float source_premultiplied;
    vec4 sampling;
    vec4 rect_clip;
};

const vec2 _76[4] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0));
const uint _84[6] = uint[](0u, 1u, 2u, 1u, 3u, 2u);

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

float _498 = 0.0;

layout(binding = 1, std430) readonly buffer instances
{
    ImageInstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform ImageParams
{
    Uniforms uniforms;
} _102;

uniform int zenit_first_instance;
layout(location = 0) out vec2 _entryPointOutput_uv;
layout(location = 1) out vec2 _entryPointOutput_local_pos;
layout(location = 2) out vec2 _entryPointOutput_size;
layout(location = 3) out vec2 _entryPointOutput_screen_pos;
layout(location = 4) out vec4 _entryPointOutput_rect_clip;
layout(location = 5) flat out vec4 _entryPointOutput_tint_color;
layout(location = 6) flat out vec2 _entryPointOutput_material;
layout(location = 7) flat out vec4 _entryPointOutput_corner_radii;

void main()
{
    vec2 _332 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy + (_76[_84[uint(gl_VertexID)]] * instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw);
    float _336 = _332.x;
    float _341 = _332.y;
    vec2 _364 = vec2(((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_linear.x * _336) + (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_linear.z * _341)) + instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_translation.x, ((instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_linear.y * _336) + (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_linear.w * _341)) + instances_1._data[uint((gl_InstanceID + zenit_first_instance))].transform_translation.y) * _102.uniforms.scale_factor;
    vec2 _379 = ((_364 / _102.uniforms.viewport_size) * 2.0) - vec2(1.0);
    vec4 _387 = vec4(_379.x, _498, 0.0, 1.0);
    _387.y = _379.y;
    gl_Position = _387;
    _entryPointOutput_uv = mix(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].uv_rect.xy, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].uv_rect.zw, _76[_84[uint(gl_VertexID)]]);
    _entryPointOutput_local_pos = (_332 - (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy + (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * 0.5))) * _102.uniforms.scale_factor;
    _entryPointOutput_size = (instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * _102.uniforms.scale_factor) * 0.5;
    _entryPointOutput_screen_pos = _364;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_tint_color = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].tint_color;
    _entryPointOutput_material = vec2(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].opacity, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].source_premultiplied);
    _entryPointOutput_corner_radii = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].corner_radii;
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

