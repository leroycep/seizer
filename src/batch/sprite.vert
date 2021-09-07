#version 300 es

layout(location = 0) in vec2 vertexPosition;
layout(location = 1) in vec2 vertexUV;
layout(location = 2) in vec4 vertexColor;

uniform ivec2 screenSize;
uniform ivec2 screenPos;

out vec2 uv;
out vec4 frag_vertexColor;

void main() {
  vec2 virtual_position = (vertexPosition - vec2(screenPos) + 0.5) / vec2(screenSize);
  gl_Position = vec4(2.0 * virtual_position.x - 1.0, 1.0 - 2.0 * virtual_position.y, 0.0, 1.0);
  frag_vertexColor = vertexColor;
  uv = vertexUV;
}
