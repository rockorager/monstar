#version 450
// Expands each GpuDrawList.Op into a pixel-aligned quad. The rectangle is
// already clipped on the CPU, so no scissor is needed per operation.

// Two uvec4 per op; see GpuDrawList.Op.
layout(std430, set = 0, binding = 0) readonly buffer Ops {
    uvec4 ops[];
};

layout(push_constant) uniform Push {
    // 2 / canvas size in pixels.
    vec2 scale;
    // First op of this draw.
    uint base;
} pc;

layout(location = 0) flat out uvec4 v_a;
layout(location = 1) flat out uvec4 v_b;

void main() {
    uint i = (pc.base + uint(gl_InstanceIndex)) * 2u;
    uvec4 a = ops[i];
    uvec4 b = ops[i + 1u];
    int x0 = bitfieldExtract(int(a.x), 0, 16);
    int y0 = bitfieldExtract(int(a.x), 16, 16);
    int x1 = bitfieldExtract(int(a.y), 0, 16);
    int y1 = bitfieldExtract(int(a.y), 16, 16);
    uint corner = uint(gl_VertexIndex);
    vec2 p = vec2((corner & 1u) != 0u ? x1 : x0, (corner & 2u) != 0u ? y1 : y0);
    gl_Position = vec4(p * pc.scale - 1.0, 0.0, 1.0);
    v_a = a;
    v_b = b;
}
