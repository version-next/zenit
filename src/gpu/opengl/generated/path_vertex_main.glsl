#version 430

struct PathVertexIn
{
    float x;
    float y;
    float alpha_scale;
    float color_r;
    float color_g;
    float color_b;
    float color_a;
};

struct PathUniforms
{
    vec2 viewport_size;
    float scale_factor;
    uint draw_mode;
    vec4 color;
    vec4 rect;
    uint fill_rule;
    uint point_count;
    uint contour_count;
    uint pad0;
    uvec4 contour_end_points[2];
    vec4 polygon_points[16];
    vec4 clip_rect;
    vec4 clip_radii;
    uint clip_shape_kind;
    uint pad1;
    uint pad2;
    uint pad6;
    uint grad_dir;
    uint grad_stop_count;
    vec2 grad_center;
    float grad_angle;
    uint pad3;
    uint pad4;
    uint pad5;
    vec4 grad_colors[16];
    vec4 grad_positions[4];
};

float _271 = 0.0;

layout(binding = 0, std430) readonly buffer vertices
{
    PathVertexIn _data[];
} vertices_1;

layout(binding = 1, std140) uniform PathParams
{
    PathUniforms u;
} _69;

layout(location = 0) out vec4 _entryPointOutput_fill_color;
layout(location = 1) out vec2 _entryPointOutput_local_pos;

void main()
{
    vec4 _202 = vec4(((vertices_1._data[uint(gl_VertexID)].x / _69.u.viewport_size.x) * 2.0) - 1.0, _271, 0.0, 1.0);
    float _228 = vertices_1._data[uint(gl_VertexID)].color_a * vertices_1._data[uint(gl_VertexID)].alpha_scale;
    _202.y = ((vertices_1._data[uint(gl_VertexID)].y / _69.u.viewport_size.y) * 2.0) - 1.0;
    gl_Position = _202;
    _entryPointOutput_fill_color = vec4(vec4(vertices_1._data[uint(gl_VertexID)].color_r, vertices_1._data[uint(gl_VertexID)].color_g, vertices_1._data[uint(gl_VertexID)].color_b, vertices_1._data[uint(gl_VertexID)].color_a).xyz * _228, _228);
    _entryPointOutput_local_pos = vec2(vertices_1._data[uint(gl_VertexID)].x - _69.u.rect.x, vertices_1._data[uint(gl_VertexID)].y - _69.u.rect.y);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

