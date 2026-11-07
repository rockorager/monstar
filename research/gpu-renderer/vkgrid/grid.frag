#version 450
// One fullscreen triangle; each fragment finds its cell, fetches the glyph
// coverage from an R8 atlas, and blends fg over bg in linear light.
layout(std430, set = 0, binding = 0) readonly buffer Cells {
    uint cols, rows, top, cw, ch, acols, bg_default, pad;
    uvec2 cell[];
};
layout(set = 0, binding = 1) uniform sampler2D atlas;
layout(location = 0) out vec4 o;

vec3 lin(uint rgb) {
    vec3 c = vec3((rgb >> 16) & 0xffu, (rgb >> 8) & 0xffu, rgb & 0xffu) / 255.0;
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}
vec3 enc(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    uvec2 p = uvec2(gl_FragCoord.xy);
    uint cx = p.x / cw, cy = p.y / ch;
    if (cx >= cols || cy >= rows) { o = vec4(enc(lin(bg_default)), 1.0); return; }
    uvec2 c = cell[((cy + top) % rows) * cols + cx];
    uint g = c.x & 0xffu;
    ivec2 a = ivec2((g % acols) * cw + p.x % cw, (g / acols) * ch + p.y % ch);
    float al = texelFetch(atlas, a, 0).r;
    o = vec4(enc(mix(lin(c.y), lin(c.x >> 8), al)), 1.0);
}
