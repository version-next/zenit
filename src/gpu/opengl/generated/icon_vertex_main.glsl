#version 430
#ifdef GL_ARB_shader_draw_parameters
#extension GL_ARB_shader_draw_parameters : enable
#endif

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

const vec2 _66[4] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0));
const uint _74[6] = uint[](0u, 1u, 2u, 1u, 3u, 2u);

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

float _440 = 0.0;

layout(binding = 1, std430) readonly buffer instances
{
    IconInstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _93;

uniform int zenit_first_instance;
layout(location = 0) out vec2 _entryPointOutput_uv;
layout(location = 1) out vec2 _entryPointOutput_local_pos;
layout(location = 2) out vec2 _entryPointOutput_size;
layout(location = 3) out vec2 _entryPointOutput_screen_pos;
layout(location = 4) out vec4 _entryPointOutput_rect_clip;
layout(location = 5) flat out uint _entryPointOutput_instance_id;

void main()
{
    vec2 _304 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.xy * _93.uniforms.scale_factor;
    vec2 _309 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect.zw * _93.uniforms.scale_factor;
    vec2 _314 = _304 + (_66[_74[uint(gl_VertexID)]] * _309);
    vec2 _317 = _309 * 0.5;
    vec2 _318 = _304 + _317;
    vec2 _429 = vec2(0.0);
    if (abs(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rotate) > 9.9999997473787516355514526367188e-05)
    {
        float _326 = cos(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rotate);
        float _329 = sin(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rotate);
        vec2 _332 = _314 - _318;
        float _335 = _332.x;
        float _339 = _332.y;
        _429 = _318 + vec2((_335 * _326) - (_339 * _329), (_335 * _329) + (_339 * _326));
    }
    else
    {
        _429 = _314;
    }
    vec2 _361 = ((_429 / _93.uniforms.viewport_size) * 2.0) - vec2(1.0);
    vec4 _369 = vec4(_361.x, _440, 0.0, 1.0);
    _369.y = _361.y;
    gl_Position = _369;
    _entryPointOutput_uv = _66[_74[uint(gl_VertexID)]];
    _entryPointOutput_local_pos = _314 - _318;
    _entryPointOutput_size = _317;
    _entryPointOutput_screen_pos = _429;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_instance_id = uint((gl_InstanceID + zenit_first_instance));
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

