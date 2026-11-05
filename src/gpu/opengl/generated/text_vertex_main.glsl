#version 430
#ifdef GL_ARB_shader_draw_parameters
#extension GL_ARB_shader_draw_parameters : enable
#endif

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

const vec2 _73[4] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0));
const uint _81[6] = uint[](0u, 1u, 2u, 1u, 3u, 2u);

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

float _376 = 0.0;

layout(binding = 1, std430) readonly buffer instances
{
    GlyphInstance _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _99;

uniform int zenit_first_instance;
layout(location = 0) out vec2 _entryPointOutput_uv;
layout(location = 1) out vec2 _entryPointOutput_screen_pos;
layout(location = 2) out vec4 _entryPointOutput_rect_clip;
layout(location = 3) flat out uint _entryPointOutput_instance_id;

void main()
{
    vec2 _273 = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].position * _99.uniforms.scale_factor;
    vec2 _278 = roundEven(_273);
    bvec2 _280 = bvec2(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].shader_snap > 0.5);
    vec2 _289 = vec2(_280.x ? _278.x : _273.x, _280.y ? _278.y : _273.y) + ((_73[_81[uint(gl_VertexID)]] * instances_1._data[uint((gl_InstanceID + zenit_first_instance))].size) * _99.uniforms.scale_factor);
    _289.x = _289.x + (((1.0 - _73[_81[uint(gl_VertexID)]].y) * instances_1._data[uint((gl_InstanceID + zenit_first_instance))].skew_x) * _99.uniforms.scale_factor);
    vec2 _308 = ((_289 / _99.uniforms.viewport_size) * 2.0) - vec2(1.0);
    vec4 _316 = vec4(_308.x, _376, 0.0, 1.0);
    _316.y = _308.y;
    gl_Position = _316;
    _entryPointOutput_uv = mix(instances_1._data[uint((gl_InstanceID + zenit_first_instance))].uv_rect.xy, instances_1._data[uint((gl_InstanceID + zenit_first_instance))].uv_rect.zw, _73[_81[uint(gl_VertexID)]]);
    _entryPointOutput_screen_pos = _289;
    _entryPointOutput_rect_clip = instances_1._data[uint((gl_InstanceID + zenit_first_instance))].rect_clip;
    _entryPointOutput_instance_id = uint((gl_InstanceID + zenit_first_instance));
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

