#version 430

layout(location = 0) out vec2 _entryPointOutput_uv;

void main()
{
    float _151 = (uint(gl_VertexID) == 1u) ? 3.0 : (-1.0);
    float _155 = (uint(gl_VertexID) == 2u) ? 3.0 : (-1.0);
    vec4 _160 = vec4(_151, _155, 0.0, 1.0);
    _160.y = -_155;
    gl_Position = _160;
    _entryPointOutput_uv = vec2((_151 + 1.0) * 0.5, (1.0 - _155) * 0.5);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

