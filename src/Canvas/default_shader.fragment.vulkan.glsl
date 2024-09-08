#version 450

precision mediump float;

layout(location=0) in vec2 uv;
layout(location=1) in vec4 tint;

layout(binding=1) uniform sampler2D texture_handle;

layout(location=0) out vec4 color;

void main() {
    color = tint * texture(texture_handle, uv);
}

