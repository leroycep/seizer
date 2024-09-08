#version 450
layout(location = 0) in vec2 uv;

layout(location = 0) out vec4 color;

layout(binding = 0) uniform sampler2D texID;

void main() {
    color = texture(texID, uv);
}

