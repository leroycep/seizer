#version 450

layout(location = 0) in vec2 vertexPosition;
layout(location = 1) in vec2 texturePosition;

layout(location = 0) out vec2 uv;

void main() {
    gl_Position = vec4(vertexPosition.xy, 0.0, 1.0);
    uv = texturePosition;
}

