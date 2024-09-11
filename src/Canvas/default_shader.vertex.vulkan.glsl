#version 450
layout(location=0) in vec3 point_xyz;
layout(location=1) in vec2 point_uv;
layout(location=2) in vec4 point_tint;

layout(push_constant, std430) uniform PushConstants {
    mat4 transform;
    int texture_id;
};

layout(location=0) out vec2 uv;
layout(location=1) out vec4 tint;

void main() {
    uv = point_uv;
    tint = point_tint;
    gl_Position = transform * vec4(point_xyz, 1.0);
}

