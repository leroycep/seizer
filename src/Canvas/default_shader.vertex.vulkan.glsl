#version 450
layout(location=0) in vec2 point_xy;
layout(location=1) in vec2 point_uv;
layout(location=2) in vec4 point_tint;

layout(std140, binding=0) uniform UniformBlock
{
    mat4 projection;
};

layout(location=0) out vec2 uv;
layout(location=1) out vec4 tint;

void main() {
    uv = point_uv;
    tint = point_tint;
    gl_Position = projection * vec4(point_xy, 1.0, 1.0);
}

