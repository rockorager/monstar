//! Generic ARGB8888 pixel filling, blending, and glyph rasterization.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");

pub const ScrollbarThumb = struct {
    x: u31,
    y: u31,
    width: u31,
    height: u31,
    alpha: u8,
};

pub const PixelRange = struct {
    start: i32,
    end: i32,
};

pub fn argb(rgb: vt.color.RGB) u32 {
    return 0xff000000 |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

pub fn blendRgb(fg: vt.color.RGB, bg: vt.color.RGB, alpha: u8) vt.color.RGB {
    const a: u32 = alpha;
    const na: u32 = 255 - a;
    return .{
        .r = @intCast((@as(u32, fg.r) * a + @as(u32, bg.r) * na) / 255),
        .g = @intCast((@as(u32, fg.g) * a + @as(u32, bg.g) * na) / 255),
        .b = @intCast((@as(u32, fg.b) * a + @as(u32, bg.b) * na) / 255),
    };
}

pub fn premultipliedArgb(rgb: vt.color.RGB, alpha_u8: u8) u32 {
    const alpha: u32 = alpha_u8;
    const r = (@as(u32, rgb.r) * alpha + 127) / 255;
    const g = (@as(u32, rgb.g) * alpha + 127) / 255;
    const b = (@as(u32, rgb.b) * alpha + 127) / 255;
    return (alpha << 24) | (r << 16) | (g << 8) | b;
}

/// Pack opaque foreign image bytes without color conversion. Kitty image
/// data uses this: like foot's pixman pipeline, foreign pixels are treated
/// as already being in the framebuffer's encoding (sRGB for 8-bit,
/// linear-expanded for the 16-bit `linear` namespace).
pub fn expandedArgb(r: u8, g: u8, b: u8) u32 {
    return 0xff000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub fn fillRect(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    x: u31,
    y: u31,
    w: u31,
    h: u31,
    color: u32,
) void {
    if (x >= buf_width or y >= buf_height) return;
    const x_end = @min(x + w, buf_width);
    const y_end = @min(y + h, buf_height);
    for (y..y_end) |row| {
        fillSpan(pixels[row * stride + x .. row * stride + x_end], color);
    }
}

/// Fill a pixel span with explicit wide stores. `@memset` here lowers
/// to a scalar dword loop (LLVM unrolls the enclosing row loop instead
/// of vectorizing), capping background fills at 4 bytes per store.
fn fillSpan(dst: []u32, color: u32) void {
    const V = @Vector(8, u32);
    const splat: V = @splat(color);
    var i: usize = 0;
    while (i + 8 <= dst.len) : (i += 8) dst[i..][0..8].* = splat;
    for (dst[i..]) |*px| px.* = color;
}

pub fn blendCapsule(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    thumb: ScrollbarThumb,
    color: u32,
) void {
    if (thumb.alpha == 0 or thumb.width == 0 or thumb.height == 0 or
        thumb.x >= buf_width or thumb.y >= buf_height) return;
    std.debug.assert(color >> 24 == 0xff);

    const x_end = @min(thumb.x + thumb.width, buf_width);
    const y_end = @min(thumb.y + thumb.height, buf_height);
    const radius = @as(f64, @floatFromInt(@min(thumb.width, thumb.height))) / 2.0;
    const center_x = @as(f64, @floatFromInt(thumb.x)) +
        @as(f64, @floatFromInt(thumb.width)) / 2.0;
    const cap_top = @as(f64, @floatFromInt(thumb.y)) + radius;
    const cap_bottom = @as(f64, @floatFromInt(thumb.y + thumb.height)) - radius;

    for (thumb.y..y_end) |y| {
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        const nearest_y = std.math.clamp(py, cap_top, cap_bottom);
        for (thumb.x..x_end) |x| {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const dx = px - center_x;
            const dy = py - nearest_y;
            // One pixel of coverage around the mathematical edge gives the
            // small pill smooth caps without involving the vector renderer.
            const coverage = std.math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
            if (coverage == 0) continue;
            const alpha: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(thumb.alpha)) * coverage));
            const pixel = &pixels[@as(usize, y) * stride + x];
            pixel.* = blend(color, pixel.*, alpha);
        }
    }
}

/// Alpha-blend an 8-bit coverage bitmap in `color` over the buffer.
pub fn blitGlyph(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    reverse_color_glyph: bool,
    clip_x: ?PixelRange,
) void {
    switch (g.format) {
        .alpha => if (g.fully_opaque)
            blitOpaqueGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x)
        else
            blitAlphaGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x),
        .bgra => if (reverse_color_glyph)
            blitBgraGlyphAsAlpha(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x)
        else
            blitBgraGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, clip_x),
    }
}

/// The glyph-space pixel ranges that land inside the buffer, computed
/// once so the blit loops run branch-free over valid pixels.
const GlyphClip = struct {
    gx_start: usize,
    gx_end: usize,
    gy_start: usize,
    gy_end: usize,
};

fn clipGlyph(
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    buf_width: u31,
    buf_height: u31,
    clip_x: ?PixelRange,
) ?GlyphClip {
    const x_start: i64 = if (clip_x) |clip| clip.start else 0;
    const x_end: i64 = if (clip_x) |clip| clip.end else buf_width;
    const gx_start: i64 = @max(0, x_start - x0);
    const gy_start: i64 = @max(0, -@as(i64, y0));
    const gx_end: i64 = @min(@as(i64, g.width), @min(@as(i64, buf_width), x_end) - x0);
    const gy_end: i64 = @min(@as(i64, g.height), @as(i64, buf_height) - y0);
    if (gx_end <= gx_start or gy_end <= gy_start) return null;
    return .{
        .gx_start = @intCast(gx_start),
        .gx_end = @intCast(gx_end),
        .gy_start = @intCast(gy_start),
        .gy_end = @intCast(gy_end),
    };
}

fn blitOpaqueGlyph(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    clip_x: ?PixelRange,
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    const span_len = clip.gx_end - clip.gx_start;
    for (clip.gy_start..clip.gy_end) |gy| {
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        fillSpan(pixels[py * stride + px_start ..][0..span_len], color);
    }
}

fn blitAlphaGlyph(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    clip_x: ?PixelRange,
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    for (clip.gy_start..clip.gy_end) |gy| {
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        const src = g.bitmap[gy * g.width + clip.gx_start .. gy * g.width + clip.gx_end];
        const dst = pixels[py * stride + px_start ..][0..src.len];
        blendAlphaSpan(dst, src, color);
    }
}

/// Blend a constant color over a pixel span with per-pixel 8-bit
/// coverage, four pixels per iteration. Produces the same value as
/// scalar `blend` for every pixel; zero-coverage pixels keep their
/// background (all-zero groups skip the store entirely).
fn blendAlphaSpan(noalias dst: []u32, noalias coverage: []const u8, color: u32) void {
    std.debug.assert(dst.len == coverage.len);
    // Foregrounds are opaque. Coverage becomes source alpha and is
    // composited over the framebuffer's premultiplied destination.
    std.debug.assert(color >> 24 == 0xff);
    const V = @Vector(16, u16);
    const fg: V = @as(@Vector(16, u8), @bitCast([_]u32{color} ** 4));
    // Broadcast each pixel's coverage across its four channel lanes.
    const expand: [16]i32 = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };
    var i: usize = 0;
    while (i + 4 <= dst.len) : (i += 4) {
        const cov: @Vector(4, u8) = coverage[i..][0..4].*;
        if (@reduce(.Or, cov) == 0) continue;
        if (@reduce(.And, cov == @as(@Vector(4, u8), @splat(0xff)))) {
            dst[i..][0..4].* = @as(@Vector(4, u32), @splat(color));
            continue;
        }
        const a: V = @shuffle(u8, cov, undefined, expand);
        const na = @as(V, @splat(255)) - a;
        const bg: V = @as(@Vector(16, u8), @bitCast(dst[i..][0..4].*));
        const mixed = (fg * a + bg * na) / @as(V, @splat(255));
        const px: @Vector(4, u32) = @bitCast(@as(@Vector(16, u8), @intCast(mixed)));
        dst[i..][0..4].* = px;
    }
    for (dst[i..], coverage[i..]) |*pixel, cov| {
        if (cov == 0) continue;
        pixel.* = blend(color, pixel.*, cov);
    }
}

fn blitBgraGlyph(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    clip_x: ?PixelRange,
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    for (clip.gy_start..clip.gy_end) |gy| {
        const src = g.bitmap[(gy * g.width + clip.gx_start) * 4 ..];
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        const dst = pixels[py * stride + px_start ..][0 .. clip.gx_end - clip.gx_start];
        blendPremultipliedBgraSpan(dst, src[0 .. dst.len * 4]);
    }
}

/// Blend premultiplied BGRA color-glyph pixels four at a time. Color
/// emoji are large relative to text glyphs, so doing this per channel
/// instead of per pixel keeps full-screen emoji output from dominating
/// frame rendering.
fn blendPremultipliedBgraSpan(noalias dst: []u32, noalias src: []const u8) void {
    std.debug.assert(src.len == dst.len * 4);
    // ARGB8888 u32 pixels have BGRA byte order only on little-endian
    // machines. Keep the scalar channel-explicit path elsewhere.
    if (comptime builtin.target.cpu.arch.endian() != .little) {
        for (dst, 0..) |*pixel, i| {
            const cell = src[i * 4 ..][0..4];
            if (cell[3] == 0) continue;
            pixel.* = blendPremultipliedBgra(cell, pixel.*);
        }
        return;
    }

    const ByteVector = @Vector(16, u8);
    const WideVector = @Vector(16, u16);
    const PixelVector = @Vector(4, u32);
    const alpha_lanes: [4]i32 = .{ 3, 7, 11, 15 };
    const expand_alpha: [16]i32 = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };

    var i: usize = 0;
    while (i + 4 <= dst.len) : (i += 4) {
        const source: ByteVector = src[i * 4 ..][0..16].*;
        const alpha: @Vector(4, u8) = @shuffle(u8, source, undefined, alpha_lanes);
        if (@reduce(.Or, alpha) == 0) continue;
        if (@reduce(.And, alpha == @as(@Vector(4, u8), @splat(0xff)))) {
            dst[i..][0..4].* = @bitCast(source);
            continue;
        }

        const a: WideVector = @shuffle(u8, alpha, undefined, expand_alpha);
        const inverse = @as(WideVector, @splat(255)) - a;
        const background: WideVector = @as(ByteVector, @bitCast(dst[i..][0..4].*));
        const foreground: WideVector = source;
        // Fonts ship glyphs whose color channels exceed their alpha. Clamp
        // every output channel to its resulting alpha so wl_shm's
        // premultiplied-alpha invariant still holds over transparent pixels.
        const unclamped = @min(
            foreground + (background * inverse) / @as(WideVector, @splat(255)),
            @as(WideVector, @splat(255)),
        );
        const output_alpha: @Vector(4, u16) = @shuffle(u16, unclamped, undefined, alpha_lanes);
        const alpha_limit: WideVector = @shuffle(u16, output_alpha, undefined, expand_alpha);
        const mixed = @min(unclamped, alpha_limit);
        const result: PixelVector = @bitCast(@as(ByteVector, @intCast(mixed)));
        dst[i..][0..4].* = result;
    }
    for (dst[i..], 0..) |*pixel, tail_i| {
        const cell = src[(i + tail_i) * 4 ..][0..4];
        if (cell[3] == 0) continue;
        pixel.* = blendPremultipliedBgra(cell, pixel.*);
    }
}

fn blitBgraGlyphAsAlpha(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    clip_x: ?PixelRange,
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    for (clip.gy_start..clip.gy_end) |gy| {
        const src = g.bitmap[(gy * g.width + clip.gx_start) * 4 ..];
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        const dst = pixels[py * stride + px_start ..][0 .. clip.gx_end - clip.gx_start];
        for (dst, 0..) |*pixel, i| {
            const alpha = src[i * 4 + 3];
            if (alpha == 0) continue;
            pixel.* = blend(color, pixel.*, alpha);
        }
    }
}

fn blend(fg: u32, bg: u32, alpha: u8) u32 {
    if (alpha == 0xff) return fg;
    const a: u32 = alpha;
    const na: u32 = 255 - a;
    const r = ((fg >> 16 & 0xff) * a + (bg >> 16 & 0xff) * na) / 255;
    const g = ((fg >> 8 & 0xff) * a + (bg >> 8 & 0xff) * na) / 255;
    const b = ((fg & 0xff) * a + (bg & 0xff) * na) / 255;
    const out_alpha = ((fg >> 24) * a + (bg >> 24) * na) / 255;
    return (out_alpha << 24) | (r << 16) | (g << 8) | b;
}

pub fn blendPixel(dst: u32, src: *const [4]u8) u32 {
    const alpha = @as(u32, src[3]);
    const inv_alpha = 255 - alpha;
    const dst_r = (dst >> 16) & 0xff;
    const dst_g = (dst >> 8) & 0xff;
    const dst_b = dst & 0xff;
    const dst_a = dst >> 24;
    const r = (@as(u32, src[0]) * alpha + dst_r * inv_alpha + 127) / 255;
    const g = (@as(u32, src[1]) * alpha + dst_g * inv_alpha + 127) / 255;
    const b = (@as(u32, src[2]) * alpha + dst_b * inv_alpha + 127) / 255;
    const a = (255 * alpha + dst_a * inv_alpha + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn blendPremultipliedBgra(src: []const u8, bg: u32) u32 {
    const a: u32 = src[3];
    if (a == 0xff) {
        return 0xff000000 |
            (@as(u32, src[2]) << 16) |
            (@as(u32, src[1]) << 8) |
            @as(u32, src[0]);
    }
    const na: u32 = 255 - a;
    const out_alpha: u32 = @min(255, a + ((bg >> 24) * na) / 255);
    const r: u32 = @min(out_alpha, @as(u32, src[2]) + ((bg >> 16 & 0xff) * na) / 255);
    const g: u32 = @min(out_alpha, @as(u32, src[1]) + ((bg >> 8 & 0xff) * na) / 255);
    const b: u32 = @min(out_alpha, @as(u32, src[0]) + ((bg & 0xff) * na) / 255);
    return (out_alpha << 24) | (r << 16) | (g << 8) | b;
}

/// Gamma-correct blending primitives for 16-bit linear-light framebuffers
/// (WL_SHM_FORMAT_ABGR16161616, little-endian u64 pixels: R bits 0-15,
/// G 16-31, B 32-47, A 48-63). Mirrors foot's gamma-correct-blending:
/// terminal colors decode from sRGB to 16-bit linear at the color→pixel
/// boundary, coverage blending runs in linear space, and the compositor
/// converts linear→display because the surface is tagged as linear sRGB
/// via wp-color-manager-v1. Foreign pixel data (color emoji, Kitty
/// images) expands to 16-bit without decoding, the same tradeoff foot's
/// pixman pipeline makes. Signatures mirror the 8-bit root namespace so
/// render code can alias one of the two with a comptime pixel type.
pub const linear = struct {
    /// 8-bit sRGB to 16-bit linear decode table. Like foot, this uses a
    /// pure 2.2 gamma rather than the piece-wise sRGB transfer function
    /// because that is what compositors apply to tagged surfaces.
    pub const srgb_decode_8_to_16_table: [256]u16 = blk: {
        @setEvalBranchQuota(100_000);
        var table: [256]u16 = undefined;
        for (&table, 0..) |*entry, i| {
            const c: f64 = @as(f64, @floatFromInt(i)) / 255.0;
            entry.* = @intFromFloat(std.math.pow(f64, c, 2.2) * 65535.0 + 0.5);
        }
        break :blk table;
    };

    /// Pack an opaque color as a linear ABGR16161616 pixel.
    pub fn argb(rgb: vt.color.RGB) u64 {
        return @as(u64, 0xffff) << 48 |
            @as(u64, srgb_decode_8_to_16_table[rgb.b]) << 32 |
            @as(u64, srgb_decode_8_to_16_table[rgb.g]) << 16 |
            @as(u64, srgb_decode_8_to_16_table[rgb.r]);
    }

    pub fn premultipliedArgb(rgb: vt.color.RGB, alpha_u8: u8) u64 {
        const a: u64 = @as(u64, alpha_u8) * 257;
        const r = (@as(u64, srgb_decode_8_to_16_table[rgb.r]) * a + 32767) / 65535;
        const g = (@as(u64, srgb_decode_8_to_16_table[rgb.g]) * a + 32767) / 65535;
        const b = (@as(u64, srgb_decode_8_to_16_table[rgb.b]) * a + 32767) / 65535;
        return (a << 48) | (b << 32) | (g << 16) | r;
    }

    /// Pack opaque foreign image bytes without sRGB decoding, the same
    /// tradeoff foot's pixman pipeline makes for 8-bit sources on its
    /// 16-bit surface.
    pub fn expandedArgb(r: u8, g: u8, b: u8) u64 {
        return @as(u64, 0xffff) << 48 |
            @as(u64, b) * 257 << 32 |
            @as(u64, g) * 257 << 16 |
            @as(u64, r) * 257;
    }

    pub fn fillRect(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        x: u31,
        y: u31,
        w: u31,
        h: u31,
        color: u64,
    ) void {
        if (x >= buf_width or y >= buf_height) return;
        const x_end = @min(x + w, buf_width);
        const y_end = @min(y + h, buf_height);
        for (y..y_end) |row| {
            linear.fillSpan(pixels[row * stride + x .. row * stride + x_end], color);
        }
    }

    fn fillSpan(dst: []u64, color: u64) void {
        const V = @Vector(4, u64);
        const splat: V = @splat(color);
        var i: usize = 0;
        while (i + 4 <= dst.len) : (i += 4) dst[i..][0..4].* = splat;
        for (dst[i..]) |*px| px.* = color;
    }

    pub fn blendCapsule(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        thumb: ScrollbarThumb,
        color: u64,
    ) void {
        if (thumb.alpha == 0 or thumb.width == 0 or thumb.height == 0 or
            thumb.x >= buf_width or thumb.y >= buf_height) return;
        std.debug.assert(color >> 48 == 0xffff);

        const x_end = @min(thumb.x + thumb.width, buf_width);
        const y_end = @min(thumb.y + thumb.height, buf_height);
        const radius = @as(f64, @floatFromInt(@min(thumb.width, thumb.height))) / 2.0;
        const center_x = @as(f64, @floatFromInt(thumb.x)) +
            @as(f64, @floatFromInt(thumb.width)) / 2.0;
        const cap_top = @as(f64, @floatFromInt(thumb.y)) + radius;
        const cap_bottom = @as(f64, @floatFromInt(thumb.y + thumb.height)) - radius;

        for (thumb.y..y_end) |y| {
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const nearest_y = std.math.clamp(py, cap_top, cap_bottom);
            for (thumb.x..x_end) |x| {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const dx = px - center_x;
                const dy = py - nearest_y;
                // One pixel of coverage around the mathematical edge gives the
                // small pill smooth caps without involving the vector renderer.
                const coverage = std.math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
                if (coverage == 0) continue;
                const alpha: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(thumb.alpha)) * 257.0 * coverage));
                const pixel = &pixels[@as(usize, y) * stride + x];
                pixel.* = linear.blend(color, pixel.*, alpha);
            }
        }
    }

    /// Alpha-blend an 8-bit coverage bitmap in `color` over the buffer.
    pub fn blitGlyph(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        g: *const Font.Glyph,
        x0: i32,
        y0: i32,
        color: u64,
        reverse_color_glyph: bool,
        clip_x: ?PixelRange,
    ) void {
        switch (g.format) {
            .alpha => if (g.fully_opaque)
                linear.blitOpaqueGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x)
            else
                linear.blitAlphaGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x),
            .bgra => if (reverse_color_glyph)
                linear.blitBgraGlyphAsAlpha(pixels, stride, buf_width, buf_height, g, x0, y0, color, clip_x)
            else
                linear.blitBgraGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, clip_x),
        }
    }

    fn blitOpaqueGlyph(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        g: *const Font.Glyph,
        x0: i32,
        y0: i32,
        color: u64,
        clip_x: ?PixelRange,
    ) void {
        const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
        const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
        const span_len = clip.gx_end - clip.gx_start;
        for (clip.gy_start..clip.gy_end) |gy| {
            const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
            linear.fillSpan(pixels[py * stride + px_start ..][0..span_len], color);
        }
    }

    fn blitAlphaGlyph(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        g: *const Font.Glyph,
        x0: i32,
        y0: i32,
        color: u64,
        clip_x: ?PixelRange,
    ) void {
        const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
        const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
        for (clip.gy_start..clip.gy_end) |gy| {
            const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
            const src = g.bitmap[gy * g.width + clip.gx_start .. gy * g.width + clip.gx_end];
            const dst = pixels[py * stride + px_start ..][0..src.len];
            linear.blendAlphaSpan(dst, src, color);
        }
    }

    /// Scalar counterpart of the 8-bit blendAlphaSpan: coverage expands
    /// to 16-bit (v*257, pixman's mask expansion) and blending runs on
    /// the linear 16-bit channels. Zero-coverage pixels keep their
    /// background; full coverage stores the foreground unchanged.
    fn blendAlphaSpan(noalias dst: []u64, noalias coverage: []const u8, color: u64) void {
        std.debug.assert(dst.len == coverage.len);
        std.debug.assert(color >> 48 == 0xffff);
        for (dst, coverage) |*pixel, cov| {
            if (cov == 0) continue;
            if (cov == 0xff) {
                pixel.* = color;
                continue;
            }
            pixel.* = linear.blend(color, pixel.*, @as(u16, cov) * 257);
        }
    }

    fn blitBgraGlyph(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        g: *const Font.Glyph,
        x0: i32,
        y0: i32,
        clip_x: ?PixelRange,
    ) void {
        const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
        const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
        for (clip.gy_start..clip.gy_end) |gy| {
            const src = g.bitmap[(gy * g.width + clip.gx_start) * 4 ..];
            const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
            const dst = pixels[py * stride + px_start ..][0 .. clip.gx_end - clip.gx_start];
            for (dst, 0..) |*pixel, i| {
                const cell = src[i * 4 ..][0..4];
                if (cell[3] == 0) continue;
                pixel.* = linear.blendPremultipliedBgra(cell, pixel.*);
            }
        }
    }

    fn blitBgraGlyphAsAlpha(
        pixels: []u64,
        stride: u31,
        buf_width: u31,
        buf_height: u31,
        g: *const Font.Glyph,
        x0: i32,
        y0: i32,
        color: u64,
        clip_x: ?PixelRange,
    ) void {
        const clip = clipGlyph(g, x0, y0, buf_width, buf_height, clip_x) orelse return;
        const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
        for (clip.gy_start..clip.gy_end) |gy| {
            const src = g.bitmap[(gy * g.width + clip.gx_start) * 4 ..];
            const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
            const dst = pixels[py * stride + px_start ..][0 .. clip.gx_end - clip.gx_start];
            for (dst, 0..) |*pixel, i| {
                const alpha = src[i * 4 + 3];
                if (alpha == 0) continue;
                pixel.* = linear.blend(color, pixel.*, @as(u16, alpha) * 257);
            }
        }
    }

    fn blend(fg: u64, bg: u64, alpha: u16) u64 {
        if (alpha == 0xffff) return fg;
        const a: u64 = alpha;
        const na: u64 = 65535 - a;
        const r = ((fg & 0xffff) * a + (bg & 0xffff) * na) / 65535;
        const g = ((fg >> 16 & 0xffff) * a + (bg >> 16 & 0xffff) * na) / 65535;
        const b = ((fg >> 32 & 0xffff) * a + (bg >> 32 & 0xffff) * na) / 65535;
        const out_alpha = ((fg >> 48) * a + (bg >> 48) * na) / 65535;
        return (out_alpha << 48) | (b << 32) | (g << 16) | r;
    }

    pub fn blendPixel(dst: u64, src: *const [4]u8) u64 {
        const alpha = @as(u64, src[3]) * 257;
        const inv_alpha = 65535 - alpha;
        const dst_r = dst & 0xffff;
        const dst_g = (dst >> 16) & 0xffff;
        const dst_b = (dst >> 32) & 0xffff;
        const dst_a = dst >> 48;
        const r = (@as(u64, src[0]) * 257 * alpha + dst_r * inv_alpha + 32767) / 65535;
        const g = (@as(u64, src[1]) * 257 * alpha + dst_g * inv_alpha + 32767) / 65535;
        const b = (@as(u64, src[2]) * 257 * alpha + dst_b * inv_alpha + 32767) / 65535;
        const a = (65535 * alpha + dst_a * inv_alpha + 32767) / 65535;
        return (a << 48) | (b << 32) | (g << 16) | r;
    }

    /// Blend 8-bit premultiplied BGRA over the linear buffer. The source
    /// channels expand to 16-bit without sRGB decoding: they are treated
    /// as linear, exactly what foot's pixman pipeline does when
    /// compositing 8-bit emoji onto its 16-bit surface.
    fn blendPremultipliedBgra(src: []const u8, bg: u64) u64 {
        const a: u64 = @as(u64, src[3]) * 257;
        const r16 = @as(u64, src[2]) * 257;
        const g16 = @as(u64, src[1]) * 257;
        const b16 = @as(u64, src[0]) * 257;
        if (a == 0xffff) {
            return (a << 48) | (b16 << 32) | (g16 << 16) | r16;
        }
        const na: u64 = 65535 - a;
        const out_alpha: u64 = @min(65535, a + ((bg >> 48) * na) / 65535);
        const r: u64 = @min(out_alpha, r16 + ((bg & 0xffff) * na) / 65535);
        const g: u64 = @min(out_alpha, g16 + ((bg >> 16 & 0xffff) * na) / 65535);
        const b: u64 = @min(out_alpha, b16 + ((bg >> 32 & 0xffff) * na) / 65535);
        return (out_alpha << 48) | (b << 32) | (g << 16) | r;
    }
};

test "fillRect clips to a view while honoring framebuffer stride" {
    const untouched: u32 = 0x12345678;
    var pixels = [_]u32{untouched} ** 15;
    fillRect(&pixels, 5, 2, 2, 0, 0, 2, 2, 0xffabcdef);
    try std.testing.expectEqual(@as(u32, 0xffabcdef), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffabcdef), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xffabcdef), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xffabcdef), pixels[6]);
    for ([_]usize{ 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14 }) |i| {
        try std.testing.expectEqual(untouched, pixels[i]);
    }
}

test "blend endpoints" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), blend(0xffffffff, 0xff000000, 255));
    try std.testing.expectEqual(@as(u32, 0xff000000), blend(0xffffffff, 0xff000000, 0));
    try std.testing.expectEqual(@as(u32, 0x80808080), blend(0xffffffff, 0x00000000, 128));
    try std.testing.expectEqual(@as(u32, 0xbf808080), blend(0xffffffff, 0x80000000, 128));
    try std.testing.expectEqual(@as(u32, 0x80643219), blendPixel(0, &.{ 200, 100, 50, 128 }));
    try std.testing.expectEqual(
        @as(u32, 0xff804000),
        blendPremultipliedBgra(&.{ 0x00, 0x40, 0x80, 0xff }, 0xff000000),
    );
    try std.testing.expectEqual(
        @as(u32, 0x801e140a),
        blendPremultipliedBgra(&.{ 10, 20, 30, 128 }, 0),
    );
}

test "blendRgb faint dims foreground toward background" {
    const white: vt.color.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    const black: vt.color.RGB = .{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqual(white, blendRgb(white, black, 255));
    try std.testing.expectEqual(black, blendRgb(white, black, 0));
    // Half blend (the faint weight) lands on mid-gray, dimmer than the source.
    const gray: vt.color.RGB = .{ .r = 0x80, .g = 0x80, .b = 0x80 };
    try std.testing.expectEqual(gray, blendRgb(white, black, 128));
}

test "scrollbar capsule has antialiased caps and a solid center" {
    const background: u32 = 0xff000000;
    var pixels = [_]u32{background} ** 48;
    blendCapsule(&pixels, 8, 8, 6, .{
        .x = 2,
        .y = 0,
        .width = 4,
        .height = 6,
        .alpha = 160,
    }, 0xffffffff);

    try std.testing.expectEqual(background, pixels[0]);
    try std.testing.expect(pixels[2] != background);
    try std.testing.expect(pixels[3] != background);
    try std.testing.expect((pixels[3] & 0xff) > (pixels[2] & 0xff));
    try std.testing.expect(pixels[2 * 8 + 3] != background);
    try std.testing.expect((pixels[2 * 8 + 3] & 0xff) > (pixels[3] & 0xff));
}

test "default background pixels are premultiplied" {
    const rgb: vt.color.RGB = .{ .r = 128, .g = 64, .b = 32 };
    try std.testing.expectEqual(@as(u32, 0), premultipliedArgb(rgb, 0));
    try std.testing.expectEqual(@as(u32, 0x80402010), premultipliedArgb(rgb, 128));
    try std.testing.expectEqual(@as(u32, 0xff804020), premultipliedArgb(rgb, 255));
}

test "blendAlphaSpan matches scalar blend" {
    var prng: std.Random.DefaultPrng = .init(0xb1e4d);
    const random = prng.random();
    // Odd lengths exercise both the vector body and the scalar tail.
    for ([_]usize{ 1, 3, 4, 7, 16, 21 }) |len| {
        var coverage: [21]u8 = undefined;
        var got: [21]u32 = undefined;
        var want: [21]u32 = undefined;
        for (0..10) |_| {
            const color = random.int(u32) | 0xff000000;
            for (coverage[0..len], got[0..len], want[0..len]) |*cov, *g, *w| {
                // Weight the endpoints: real coverage is mostly 0/255.
                cov.* = switch (random.int(u2)) {
                    0 => 0,
                    1 => 0xff,
                    else => random.int(u8),
                };
                const bg_alpha = random.int(u8);
                const bg = (@as(u32, bg_alpha) << 24) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 16) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 8) |
                    random.intRangeAtMost(u8, 0, bg_alpha);
                g.* = bg;
                w.* = if (cov.* == 0) bg else blend(color, bg, cov.*);
            }
            blendAlphaSpan(got[0..len], coverage[0..len], color);
            try std.testing.expectEqualSlices(u32, want[0..len], got[0..len]);
        }
    }
}

test "opaque glyph fast path matches alpha blending with clipping" {
    const bitmap: [12]u8 = @splat(0xff);
    const alpha_glyph: Font.Glyph = .{
        .bitmap = @constCast(&bitmap),
        .width = 4,
        .height = 3,
        .bearing_x = 0,
        .bearing_y = 0,
    };
    var opaque_glyph = alpha_glyph;
    opaque_glyph.fully_opaque = true;

    var alpha_pixels: [5 * 4]u32 = @splat(0xff123456);
    var opaque_pixels = alpha_pixels;
    blitGlyph(&alpha_pixels, 5, 5, 4, &alpha_glyph, -1, 2, 0xffabcdef, false, null);
    blitGlyph(&opaque_pixels, 5, 5, 4, &opaque_glyph, -1, 2, 0xffabcdef, false, null);
    try std.testing.expectEqualSlices(u32, &alpha_pixels, &opaque_pixels);
}

test "blendPremultipliedBgraSpan matches scalar blend" {
    const transparent_source: [4 * 4]u8 = @splat(0);
    var transparent_got = [_]u32{ 0xff010203, 0xff112233, 0xffabcdef, 0xff987654 };
    const transparent_want = transparent_got;
    blendPremultipliedBgraSpan(&transparent_got, &transparent_source);
    try std.testing.expectEqualSlices(u32, &transparent_want, &transparent_got);

    const opaque_source = [_]u8{
        1,  2,  3,  255,
        4,  5,  6,  255,
        7,  8,  9,  255,
        10, 11, 12, 255,
    };
    var opaque_got: [4]u32 = @splat(0xff112233);
    blendPremultipliedBgraSpan(&opaque_got, &opaque_source);
    try std.testing.expectEqualSlices(u32, &.{ 0xff030201, 0xff060504, 0xff090807, 0xff0c0b0a }, &opaque_got);

    const mixed_source = [_]u8{
        0,  0,  0,   0,
        20, 40, 80,  255,
        10, 20, 30,  128,
        1,  2,  3,   64,
        9,  18, 27,  255,
        0,  0,  0,   0,
        20, 30, 100, 200,
    };
    var mixed_got: [7]u32 = @splat(0xff204060);
    var mixed_want = mixed_got;
    for (&mixed_want, 0..) |*pixel, i| {
        const cell = mixed_source[i * 4 ..][0..4];
        if (cell[3] != 0) pixel.* = blendPremultipliedBgra(cell, pixel.*);
    }
    blendPremultipliedBgraSpan(&mixed_got, &mixed_source);
    try std.testing.expectEqualSlices(u32, &mixed_want, &mixed_got);

    // Imperfectly premultiplied glyphs (color > alpha) must clamp to
    // white instead of overflowing; real emoji fonts ship these.
    const over_source = [_]u8{
        255, 255, 255, 128,
        250, 250, 250, 200,
        255, 255, 255, 1,
        128, 128, 128, 127,
    };
    var over_got: [4]u32 = @splat(0xffffffff);
    blendPremultipliedBgraSpan(&over_got, &over_source);
    for (over_got) |pixel| {
        try std.testing.expectEqual(@as(u32, 0xffffffff), pixel);
    }

    var prng: std.Random.DefaultPrng = .init(0xb6a4);
    const random = prng.random();
    for ([_]usize{ 1, 3, 4, 7, 16, 21 }) |len| {
        var source: [21 * 4]u8 = undefined;
        var got: [21]u32 = undefined;
        var want: [21]u32 = undefined;
        for (0..10) |_| {
            for (got[0..len], want[0..len], 0..) |*g, *w, i| {
                const alpha = switch (random.int(u2)) {
                    0 => 0,
                    1 => 0xff,
                    else => random.int(u8),
                };
                const cell = source[i * 4 ..][0..4];
                cell[0] = random.intRangeAtMost(u8, 0, alpha);
                cell[1] = random.intRangeAtMost(u8, 0, alpha);
                cell[2] = random.intRangeAtMost(u8, 0, alpha);
                cell[3] = alpha;
                const bg_alpha = random.int(u8);
                const bg = (@as(u32, bg_alpha) << 24) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 16) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 8) |
                    random.intRangeAtMost(u8, 0, bg_alpha);
                g.* = bg;
                w.* = if (alpha == 0) bg else blendPremultipliedBgra(cell, bg);
            }
            blendPremultipliedBgraSpan(got[0..len], source[0 .. len * 4]);
            try std.testing.expectEqualSlices(u32, want[0..len], got[0..len]);
        }
    }
}

test "linear sRGB decode table matches pure 2.2 gamma" {
    const table = &linear.srgb_decode_8_to_16_table;
    try std.testing.expectEqual(@as(u16, 0), table[0]);
    try std.testing.expectEqual(@as(u16, 14386), table[128]);
    try std.testing.expectEqual(@as(u16, 64971), table[254]);
    try std.testing.expectEqual(@as(u16, 65535), table[255]);
    for (1..256) |i| try std.testing.expect(table[i] >= table[i - 1]);
}

test "linear argb packs opaque premultiplied ABGR16161616" {
    const white: vt.color.RGB = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    const black: vt.color.RGB = .{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), linear.argb(white));
    try std.testing.expectEqual(@as(u64, 0xffff_0000_0000_0000), linear.argb(black));
    const red: vt.color.RGB = .{ .r = 0xff, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(u64, 0xffff_0000_0000_ffff), linear.argb(red));
}

test "linear premultipliedArgb endpoints" {
    const rgb: vt.color.RGB = .{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectEqual(@as(u64, 0), linear.premultipliedArgb(rgb, 0));
    try std.testing.expectEqual(linear.argb(rgb), linear.premultipliedArgb(rgb, 255));
    // Half alpha premultiplies the linear channel by the same fraction.
    try std.testing.expectEqual(@as(u64, 0x8080_8080_8080_8080), linear.premultipliedArgb(rgb, 128));
}

test "linear blend endpoints" {
    const opaque_white: u64 = 0xffff_ffff_ffff_ffff;
    const opaque_black: u64 = 0xffff_0000_0000_0000;
    try std.testing.expectEqual(opaque_white, linear.blend(opaque_white, opaque_black, 0xffff));
    try std.testing.expectEqual(opaque_black, linear.blend(opaque_white, opaque_black, 0));
    try std.testing.expectEqual(
        @as(u64, 0xffff_8000_8000_8000),
        linear.blend(opaque_white, opaque_black, 0x8000),
    );
}

test "linear blendPixel expands opaque sources and keeps covered pixels" {
    const dst: u64 = 0xffff_1000_2000_3000;
    try std.testing.expectEqual(dst, linear.blendPixel(dst, &.{ 200, 100, 50, 0 }));
    try std.testing.expectEqual(
        @as(u64, 0xffff_0000_0000_0000 | (30 * 257 << 32) | (20 * 257 << 16) | (10 * 257)),
        linear.blendPixel(dst, &.{ 10, 20, 30, 255 }),
    );
}

test "linear premultiplied BGRA clamps channels to alpha" {
    // Imperfectly premultiplied glyphs (color > alpha) must clamp to the
    // resulting alpha so the premultiplied invariant holds.
    const over: [4]u8 = .{ 255, 255, 255, 128 };
    const bg: u64 = 0xffff_ffff_ffff_ffff;
    const pixel = linear.blendPremultipliedBgra(&over, bg);
    const alpha = pixel >> 48;
    try std.testing.expect(pixel & 0xffff <= alpha);
    try std.testing.expect(pixel >> 16 & 0xffff <= alpha);
    try std.testing.expect(pixel >> 32 & 0xffff <= alpha);

    const opaque_px = linear.blendPremultipliedBgra(&.{ 10, 20, 30, 255 }, bg);
    // BGRA byte order: B lands at bits 32-47, R at bits 0-15.
    try std.testing.expectEqual(
        @as(u64, 0xffff_0000_0000_0000 | (10 * 257 << 32) | (20 * 257 << 16) | (30 * 257)),
        opaque_px,
    );
}

test "linear opaque glyph fast path matches alpha blending with clipping" {
    const bitmap: [12]u8 = @splat(0xff);
    const alpha_glyph: Font.Glyph = .{
        .bitmap = @constCast(&bitmap),
        .width = 4,
        .height = 3,
        .bearing_x = 0,
        .bearing_y = 0,
    };
    var opaque_glyph = alpha_glyph;
    opaque_glyph.fully_opaque = true;

    var alpha_pixels: [5 * 4]u64 = @splat(0xffff_1234_5678_9abc);
    var opaque_pixels = alpha_pixels;
    linear.blitGlyph(&alpha_pixels, 5, 5, 4, &alpha_glyph, -1, 2, 0xffff_abcd_ef01_2345, false, null);
    linear.blitGlyph(&opaque_pixels, 5, 5, 4, &opaque_glyph, -1, 2, 0xffff_abcd_ef01_2345, false, null);
    try std.testing.expectEqualSlices(u64, &alpha_pixels, &opaque_pixels);
}

test "linear alpha glyph blending matches scalar blend" {
    const bitmap: [12]u8 = .{ 0, 1, 32, 64, 128, 192, 255, 7, 99, 200, 23, 250 };
    const glyph: Font.Glyph = .{
        .bitmap = @constCast(&bitmap),
        .width = 4,
        .height = 3,
        .bearing_x = 0,
        .bearing_y = 0,
    };
    const color: u64 = 0xffff_abcd_ef01_2345;
    var pixels: [5 * 4]u64 = @splat(0xffff_1111_2222_3333);
    linear.blitGlyph(&pixels, 5, 5, 4, &glyph, -1, 2, color, false, null);
    for (bitmap, 0..) |cov, i| {
        // x0 = -1 clips bitmap column 0; buf_height = 4 clips glyph row 2.
        const x: i32 = @as(i32, @intCast(i % 4)) - 1;
        const y = 2 + i / 4;
        if (x < 0 or y >= 4) continue;
        const px = pixels[y * 5 + @as(usize, @intCast(x))];
        const want: u64 = if (cov == 0)
            0xffff_1111_2222_3333
        else if (cov == 0xff)
            color
        else
            linear.blend(color, 0xffff_1111_2222_3333, @as(u16, cov) * 257);
        try std.testing.expectEqual(want, px);
    }
}
