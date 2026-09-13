//! ARGB8888 filling and glyph rasterization with linear-light composition.
//! Storage stays encoded and premultiplied; blends use piecewise sRGB and
//! 16-bit linear intermediates. Each blend requantizes to 8-bit storage.

const std = @import("std");
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

/// Interpolate encoded colors for faint/search styling, not pixel composition.
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

fn toLinear(value: f64) f64 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

const decode: [256]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, i| {
        const c: f64 = @as(f64, @floatFromInt(i)) / 255.0;
        entry.* = @intFromFloat(toLinear(c) * 65535.0 + 0.5);
    }
    break :blk table;
};
// Construct the 64 KiB encode table using the 255 boundaries between
// rounded output bytes, instead of evaluating pow for all 65536 entries.
const encode: [65536]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [65536]u8 = undefined;
    var start: usize = 0;
    for (0..256) |value| {
        const end: usize = if (value == 255) table.len else @intFromFloat(@ceil(
            toLinear((@as(f64, @floatFromInt(value)) + 0.5) / 255) * 65535,
        ));
        @memset(table[start..end], @intCast(value));
        start = end;
    }
    break :blk table;
};

fn decodeRgb(color: u32) [3]u32 {
    return .{ decode[color >> 16 & 0xff], decode[color >> 8 & 0xff], decode[color & 0xff] };
}

// Text repeatedly uses the same color pairs and coverage bytes. Keep
// exact encoded results, populated lazily so rare pairs do not pay for
// 256 blends. Thread-local storage isolates independent raster workers.
const CoverageCache = struct {
    foreground: u32 = 0,
    background: u32 = 0,
    valid: [4]u64 = @splat(0),
    pixels: [256]u32 = undefined,
};
threadlocal var coverage_cache: [32]CoverageCache = @splat(.{});

fn blendAlphaSpan(noalias dst: []u32, noalias coverage: []const u8, color: u32) void {
    std.debug.assert(dst.len == coverage.len and color >> 24 == 255);
    if (dst.len == 0) return;
    const fg = decodeRgb(color);
    const background = dst[0];
    const cache = &coverage_cache[((color *% 0x9e3779b9) ^ (background *% 0x85ebca6b)) >> 27];
    if (cache.foreground != color or cache.background != background) {
        cache.foreground = color;
        cache.background = background;
        cache.valid = @splat(0);
    }
    for (dst, coverage) |*pixel, cov| {
        if (cov == 0) continue;
        if (cov == 255) {
            pixel.* = color;
        } else if (pixel.* == background) {
            const bit = @as(u64, 1) << @as(u6, @truncate(cov));
            const valid = &cache.valid[cov >> 6];
            if (valid.* & bit == 0) {
                cache.pixels[cov] = blendDecoded(color, fg, background, cov);
                valid.* |= bit;
            }
            pixel.* = cache.pixels[cov];
        } else {
            // Overlapping glyphs and images may change the destination
            // within a span. Never substitute the assumed background.
            pixel.* = blendDecoded(color, fg, pixel.*, cov);
        }
    }
}

fn blend(fg: u32, bg: u32, alpha: u8) u32 {
    std.debug.assert(fg >> 24 == 255);
    return blendDecoded(fg, decodeRgb(fg), bg, alpha);
}

fn blendDecoded(fg: u32, fg_linear: [3]u32, bg: u32, alpha: u8) u32 {
    if (alpha == 0) return bg;
    if (alpha == 255 or fg == bg) return fg;
    const a: u32 = alpha;
    const na = 255 - a;
    const bg_alpha = bg >> 24;
    if (bg_alpha == 255) {
        var result: u32 = 0xff000000;
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
            const bg_linear: u32 = decode[bg >> shift & 0xff];
            const mixed = (fg_linear[channel] * a + bg_linear * na + 127) / 255;
            result |= @as(u32, encode[mixed]) << shift;
        }
        return result;
    }
    if (bg_alpha == 0) return premultipliedArgb(.{
        .r = @truncate(fg >> 16),
        .g = @truncate(fg >> 8),
        .b = @truncate(fg),
    }, alpha);

    // Unassociate the encoded destination before decoding, blend with
    // exact alpha weights, then encode and premultiply for wl_shm.
    const fg_weight = a * 255;
    const bg_weight = bg_alpha * na;
    const weight = fg_weight + bg_weight;
    const out_alpha = (weight + 127) / 255;
    var result: u32 = out_alpha << 24;
    inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
        const bg_linear: u32 = decode[unassociate(bg >> shift & 0xff, bg_alpha)];
        const mixed = (fg_linear[channel] * fg_weight + bg_linear * bg_weight + weight / 2) / weight;
        const premultiplied = (@as(u32, encode[mixed]) * out_alpha + 127) / 255;
        result |= premultiplied << shift;
    }
    return result;
}

fn unassociate(channel: u32, alpha: u32) u8 {
    std.debug.assert(alpha > 0 and alpha <= 255);
    return @intCast(@min(255, (channel * 255 + alpha / 2) / alpha));
}

pub fn blendPixel(dst: u32, src: *const [4]u8) u32 {
    return blend(argb(.{ .r = src[0], .g = src[1], .b = src[2] }), dst, src[3]);
}

fn blendPremultipliedBgraSpan(noalias dst: []u32, noalias src: []const u8) void {
    std.debug.assert(src.len == dst.len * 4);
    for (dst, 0..) |*pixel, i| {
        const bgra = src[i * 4 ..][0..4];
        if (bgra[3] == 0) continue;
        const fg = argb(.{
            .r = unassociate(bgra[2], bgra[3]),
            .g = unassociate(bgra[1], bgra[3]),
            .b = unassociate(bgra[0], bgra[3]),
        });
        pixel.* = blend(fg, pixel.*, bgra[3]);
    }
}

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

test "BGRA spans preserve endpoints and clamp malformed premultiplied colors" {
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
}

test "linear-light encode table matches the inverse transfer function" {
    for (encode, 0..) |encoded, i| {
        const value = @as(f64, @floatFromInt(i)) / 65535;
        const expected: u8 = @intFromFloat(@round((if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055) * 255));
        try std.testing.expectEqual(expected, encoded);
    }
    try std.testing.expectEqual(@as(u32, 0xffbcbcbc), blend(0xffffffff, 0xff000000, 128));
    try std.testing.expectEqual(@as(u32, 0xffbbbbbb), blend(0xff000000, 0xffffffff, 128));
    // Independently tabulated sRGB values on either side of the linear toe.
    try std.testing.expectEqual(@as(u16, 199), decode[10]);
    try std.testing.expectEqual(@as(u16, 219), decode[11]);
    try std.testing.expectEqual(@as(u16, 14146), decode[128]);
}

test "linear-light composition matches floating point for opaque and premultiplied destinations" {
    const fg: u32 = 0xff60c811;
    for ([_]u8{ 0, 1, 63, 128, 254, 255 }) |bg_alpha| {
        const bg = premultipliedArgb(.{ .r = 5, .g = 80, .b = 224 }, bg_alpha);
        for (0..256) |alpha| {
            const got = blend(fg, bg, @intCast(alpha));
            const expected = referenceLinearLightBlend(fg, bg, @intCast(alpha));
            try std.testing.expectEqual(expected >> 24, got >> 24);
            inline for (.{ 16, 8, 0 }) |shift| {
                const channel: i32 = @intCast(got >> shift & 0xff);
                const want: i32 = @intCast(expected >> shift & 0xff);
                // Quantized decode and unassociation can each cost a byte
                // step, but encoded-space blending differs by much more.
                try std.testing.expect(@abs(channel - want) <= 2);
                try std.testing.expect(channel <= got >> 24);
            }
        }
        try std.testing.expectEqual(bg, blend(fg, bg, 0));
        try std.testing.expectEqual(fg, blend(fg, bg, 255));
    }
}

fn referenceLinearLightBlend(fg: u32, bg: u32, alpha: u8) u32 {
    const a = @as(f64, @floatFromInt(alpha)) / 255;
    const ba = @as(f64, @floatFromInt(bg >> 24)) / 255;
    const out_alpha = a + ba * (1 - a);
    if (out_alpha == 0) return 0;
    const out_byte: u32 = @intFromFloat(@round(out_alpha * 255));
    var result = out_byte << 24;
    inline for (.{ 16, 8, 0 }) |shift| {
        const f = @as(f64, @floatFromInt(fg >> shift & 0xff)) / 255;
        const b = if (ba == 0) 0 else @as(f64, @floatFromInt(bg >> shift & 0xff)) / (ba * 255);
        const fl = if (f <= 0.04045) f / 12.92 else std.math.pow(f64, (f + 0.055) / 1.055, 2.4);
        const bl = if (b <= 0.04045) b / 12.92 else std.math.pow(f64, (b + 0.055) / 1.055, 2.4);
        const value = (fl * a + bl * ba * (1 - a)) / out_alpha;
        const encoded = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
        const channel: u32 = @intFromFloat(@round(encoded * @as(f64, @floatFromInt(out_byte))));
        result |= channel << shift;
    }
    return result;
}

test "linear-light glyph clipping and image color preservation" {
    var bitmap = [_]u8{ 255, 128, 0, 64, 192, 255 };
    const glyph: Font.Glyph = .{ .bitmap = &bitmap, .width = 3, .height = 2, .bearing_x = 0, .bearing_y = 0 };
    var pixels = [_]u32{0xff000000} ** 12;
    blitGlyph(&pixels, 4, 3, 3, &glyph, -1, 1, 0xffffffff, false, .{ .start = 0, .end = 1 });
    try std.testing.expectEqual(@as(u32, 0xffbcbcbc), pixels[4]);
    try std.testing.expectEqual(referenceLinearLightBlend(0xffffffff, 0xff000000, 192), pixels[8]);
    for (pixels, 0..) |pixel, i| {
        if (i != 4 and i != 8) try std.testing.expectEqual(@as(u32, 0xff000000), pixel);
    }
    try std.testing.expectEqual(@as(u32, 0xff804020), blendPixel(0, &.{ 128, 64, 32, 255 }));
    try std.testing.expectEqual(@as(u32, 0x80402010), blendPixel(0, &.{ 128, 64, 32, 128 }));
    var emoji = [_]u32{0} ** 3;
    blendPremultipliedBgraSpan(&emoji, &.{ 32, 64, 128, 255, 16, 32, 64, 128, 255, 255, 255, 128 });
    try std.testing.expectEqualSlices(u32, &.{ 0xff804020, 0x80402010, 0x80808080 }, &emoji);
}

test "linear-light coverage cache preserves exact blends across backgrounds and eviction" {
    var coverage: [256]u8 = undefined;
    for (&coverage, 0..) |*cov, i| cov.* = @intCast(i);
    // More distinct pairs than cache slots forces eviction. Repeat in reverse
    // order to exercise both warm entries and slots holding different keys.
    for (0..2) |pass| {
        for (0..96) |index| {
            const i: u32 = @intCast(if (pass == 0) index else 95 - index);
            const foreground = 0xff000000 | (i * 0x010203);
            for ([_]u8{ 0, 1, 63, 128, 254, 255 }) |alpha| {
                const background = premultipliedArgb(.{ .r = 17, .g = 95, .b = 231 }, alpha);
                for ([_]bool{ false, true }) |overlap| {
                    var got: [256]u32 = @splat(background);
                    var want: [256]u32 = undefined;
                    // The first pixel stays on the nominal background. Some
                    // later pixels contain previous ink with different alpha.
                    if (overlap) {
                        for (&got, 0..) |*pixel, x| {
                            if (x % 3 == 1) pixel.* = 0xa0137d48;
                        }
                    }
                    for (&want, got, coverage) |*expected, bg, cov| {
                        expected.* = blend(foreground, bg, cov);
                    }
                    blendAlphaSpan(&got, &coverage, foreground);
                    try std.testing.expectEqualSlices(u32, &want, &got);
                }
            }
        }
    }
    blendAlphaSpan(&.{}, &.{}, 0xff123456);
}
