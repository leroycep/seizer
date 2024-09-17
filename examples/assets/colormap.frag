#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(location=0) in vec2 uv;
layout(location=1) in vec4 tint;

layout(push_constant, std430) uniform PushConstants {
    mat4 transform;
    int texture_id;
};

layout(binding=1) uniform sampler2D textures[];

layout(location=0) out vec4 color;

layout(binding=2) uniform ColormappingValues {
    int colormap_texture_id;
    float min_value;
    float max_value;
};

void main() {
    float value = texture(textures[nonuniformEXT(texture_id)], uv).r;
    if (value < min_value) {
        discard;
    } else if (value > max_value) {
        color = tint * vec4(1,0,0,1);
    } else {
        // float colormap_index = (log(value) - log(min_value)) / (log(max_value) - log(min_value));
        float colormap_index = (value - min_value) / (max_value - min_value);
        color = tint * texture(textures[nonuniformEXT(colormap_texture_id)], vec2(colormap_index, 0.5));
    }
}

