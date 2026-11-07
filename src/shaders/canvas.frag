#version 450
#extension GL_EXT_nonuniform_qualifier : require
// Rasterizes one GpuDrawList.Op per fragment with the CPU renderer's math.
//
// The color attachment is sRGB, so the blend unit composes in linear light.
// Dual-source blending gives every op its own destination weight:
//   result = out_color + dst * (1 - out_weight.a)
// Fills use weight 1 and replace the destination with exact bytes; the rest
// emit premultiplied linear color with their coverage as weight.
//
// Text coverage correction (pixel_raster.TextCorrection) is reproduced in
// integer arithmetic. It reads the background from `bgmap`, which holds
// everything drawn below the text layer.

layout(std430, set = 0, binding = 1) readonly buffer Tables {
    // pixel_raster.decode: sRGB byte -> 16-bit linear.
    uint decode[256];
    // pixel_raster.encode: 16-bit linear -> sRGB byte, four per word.
    uint encode[16384];
};
layout(set = 0, binding = 2) uniform sampler2D alpha_atlas;
layout(set = 0, binding = 3) uniform sampler2D color_atlas;
layout(set = 0, binding = 4) uniform sampler2D bgmap;
layout(set = 0, binding = 5) uniform sampler2D images[32];

layout(location = 0) flat in uvec4 v_a;
layout(location = 1) flat in uvec4 v_b;

layout(location = 0, index = 0) out vec4 out_color;
layout(location = 0, index = 1) out vec4 out_weight;

const uint KIND_FILL = 0u;
const uint KIND_TEXT = 1u;
const uint KIND_COLOR = 2u;
const uint KIND_COLOR_AS_TEXT = 3u;
const uint KIND_IMAGE = 4u;
const uint KIND_CAPSULE = 5u;

uvec4 bytes(vec4 v) {
    return uvec4(v * 255.0 + 0.5);
}

uint enc(uint v16) {
    return (encode[v16 >> 2] >> ((v16 & 3u) * 8u)) & 255u;
}

float lin(uint byte) {
    return float(decode[byte]) / 65535.0;
}

// Rec. 709 luminance in 16-bit linear light; fits in 32 bits because the
// weights sum to 65536.
uint luminance(uvec3 rgb) {
    return (13933u * decode[rgb.r] + 46871u * decode[rgb.g] + 4732u * decode[rgb.b] + 32768u) >> 16;
}

uint unassociate(uint channel, uint alpha) {
    return min(255u, (channel * 255u + alpha / 2u) / alpha);
}

// pixel_raster.TextCorrection.init(fg, bg).apply(cov).
uint correct(uint cov, uvec3 fg, uvec4 bg) {
    if (cov == 0u || cov == 255u || bg.a == 0u) return cov;
    uvec3 bg_rgb = bg.a == 255u ? bg.rgb
        : uvec3(unassociate(bg.r, bg.a), unassociate(bg.g, bg.a), unassociate(bg.b, bg.a));
    uint fg_l = luminance(fg);
    uint bg_l = luminance(bg_rgb);
    int span = int(fg_l) - int(bg_l);
    if (abs(span) <= 65) return cov;
    // trunc(2^32 / span) without 64-bit integers.
    uint s = uint(abs(span));
    uint q = 0xffffffffu / s;
    if ((q + 1u) * s == 0u) q += 1u;
    int inv_span = span < 0 ? -int(q) : int(q);

    uint fg_enc = enc(fg_l);
    uint bg_enc = enc(bg_l);
    uint target_encoded = fg_enc * cov + bg_enc * (255u - cov);
    uint index = target_encoded / 255u;
    int lo = int(decode[index]);
    int hi = int(decode[min(index + 1u, 255u)]);
    int target_scaled = lo * 255 + (hi - lo) * int(target_encoded % 255u);
    int bg_scaled = int(bg_l) * 255;
    // ((target - bg) * inv_span + 2^31) >> 32 on 64-bit two's complement.
    int msb;
    int lsb;
    imulExtended(target_scaled - bg_scaled, inv_span, msb, lsb);
    uint low = uint(lsb);
    uint sum = low + 0x80000000u;
    int corrected = msb + (sum < low ? 1 : 0);
    return uint(clamp(corrected, 0, 255));
}

void emit(uvec3 rgb, uint alpha) {
    if (alpha == 0u) discard;
    float a = float(alpha) / 255.0;
    out_color = vec4(lin(rgb.r) * a, lin(rgb.g) * a, lin(rgb.b) * a, a);
    out_weight = vec4(0.0, 0.0, 0.0, a);
}

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    ivec2 origin = ivec2(bitfieldExtract(int(v_a.x), 0, 16), bitfieldExtract(int(v_a.x), 16, 16));
    ivec2 src = ivec2(int(v_a.z & 0xffffu), int(v_a.z >> 16)) + p - origin;
    uint kind = v_a.w & 0xffffu;
    uint tex = v_a.w >> 16;
    uint color = v_b.x;
    uvec3 fg = uvec3((color >> 16) & 255u, (color >> 8) & 255u, color & 255u);

    if (kind == KIND_FILL) {
        out_color = vec4(lin(fg.r), lin(fg.g), lin(fg.b), float(color >> 24) / 255.0);
        out_weight = vec4(1.0);
    } else if (kind == KIND_TEXT) {
        uint cov = bytes(texelFetch(alpha_atlas, src, 0)).r;
        if (cov == 0u) discard;
        emit(fg, correct(cov, fg, bytes(texelFetch(bgmap, p, 0))));
    } else if (kind == KIND_COLOR) {
        uvec4 t = bytes(texelFetch(color_atlas, src, 0));
        if (t.a == 0u) discard;
        emit(uvec3(unassociate(t.r, t.a), unassociate(t.g, t.a), unassociate(t.b, t.a)), t.a);
    } else if (kind == KIND_COLOR_AS_TEXT) {
        uint cov = bytes(texelFetch(color_atlas, src, 0)).a;
        if (cov == 0u) discard;
        emit(fg, correct(cov, fg, bytes(texelFetch(bgmap, p, 0))));
    } else if (kind == KIND_IMAGE) {
        uvec4 t = bytes(texelFetch(images[nonuniformEXT(tex)], src, 0));
        emit(t.rgb, t.a);
    } else {
        // KIND_CAPSULE: pixel_raster.blendCapsule in single precision.
        float center_x = float(v_a.z & 0xffffu) * 0.5;
        float radius = float(v_a.z >> 16) * 0.5;
        vec2 c = vec2(p) + 0.5;
        float nearest_y = clamp(c.y, uintBitsToFloat(v_b.y), uintBitsToFloat(v_b.z));
        float dx = c.x - center_x;
        float dy = c.y - nearest_y;
        float coverage = clamp(radius + 0.5 - sqrt(dx * dx + dy * dy), 0.0, 1.0);
        emit(fg, uint(floor(float(tex) * coverage + 0.5)));
    }
}
