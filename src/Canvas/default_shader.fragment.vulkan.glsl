#version 450
#extension GL_EXT_nonuniform_qualifier : enable

precision mediump float;

layout(location=0) in vec2 uv;
layout(location=1) in vec4 tint;

layout(push_constant, std430) uniform PushConstants {
    mat4 transform;
    int texture_id;
};

layout(binding=1) uniform sampler2D textures[];

layout(location=0) out vec4 color;

void main() {
    color = tint * texture(textures[nonuniformEXT(texture_id)], uv);
}

