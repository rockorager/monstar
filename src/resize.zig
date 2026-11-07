//! Separable 8-bit image resizing for glyph bitmaps and Kitty images.
//!
//! The arithmetic follows stb_image_resize 0.97's `stbir_resize_uint8`
//! defaults step for step: Catmull-Rom on an axis that grows, Mitchell on
//! one that shrinks or keeps its size, edges clamped, samples filtered as
//! stored at `f32` precision, and each output rounded half up. Straight
//! alpha is premultiplied for filtering and divided out after, as stb's
//! generic entry point does with an alpha channel, so that a transparent
//! pixel's color does not bleed into its neighbors.

const std = @import("std");

pub const Format = enum {
    /// One coverage or gray sample a pixel.
    gray,
    /// Four samples a pixel with alpha already multiplied in, filtered as
    /// stored.
    bgra_premultiplied,
    /// Red, green, blue, and straight alpha.
    rgba,

    fn channels(format: Format) comptime_int {
        return switch (format) {
            .gray => 1,
            .bgra_premultiplied, .rgba => 4,
        };
    }
};

/// Resizes `src`, `src_height` rows of `src_width` pixels `src_stride`
/// bytes apart, into the tightly packed `dst`. Both images must have
/// pixels. Allocates only scratch memory, freed before returning.
pub fn resize(
    alloc: std.mem.Allocator,
    comptime format: Format,
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
    src: []const u8,
    src_stride: usize,
    src_width: u32,
    src_height: u32,
) error{OutOfMemory}!void {
    const ch = format.channels();
    std.debug.assert(dst_width > 0 and dst_height > 0 and src_width > 0 and src_height > 0);
    std.debug.assert(dst.len >= @as(usize, dst_width) * dst_height * ch);
    std.debug.assert(src_stride >= @as(usize, src_width) * ch);
    std.debug.assert(src.len >= src_stride * (src_height - 1) + @as(usize, src_width) * ch);
    const Pixel = @Vector(ch, f32);

    var h: Axis = try .init(alloc, src_width, dst_width);
    defer h.deinit(alloc);
    var v: Axis = try .init(alloc, src_height, dst_height);
    defer v.deinit(alloc);

    // A decoded source row with the clamped edge pixels the horizontal
    // taps reach past either side.
    const pad_left: usize = @intCast(@max(0, -h.lowest));
    const pad_right: usize = @intCast(@max(0, h.highest - @as(i64, src_width) + 1));
    const line = try alloc.alloc(Pixel, pad_left + src_width + pad_right);
    defer alloc.free(line);
    // Horizontally filtered source rows: row `y` in slot `y % v.taps`.
    const ring = try alloc.alloc(Pixel, v.taps * dst_width);
    defer alloc.free(ring);
    const out = try alloc.alloc(Pixel, dst_width);
    defer alloc.free(out);

    var next: u32 = 0;
    for (0..dst_height) |y| {
        const first = v.first[y];
        const count = v.count[y];
        const weights = v.weights[y * v.taps ..][0..count];
        const lo = clampIndex(first, src_height);
        const hi = clampIndex(first + count - 1, src_height);
        next = @max(next, lo);
        while (next <= hi) : (next += 1) {
            const row = src[next * src_stride ..][0 .. src_width * ch];
            decodeRow(format, line[pad_left..][0..src_width], row);
            @memset(line[0..pad_left], line[pad_left]);
            @memset(line[pad_left + src_width ..], line[pad_left + src_width - 1]);
            const slot = ring[(next % v.taps) * dst_width ..][0..dst_width];
            filterRow(ch, slot, line, pad_left, h);
        }

        @memset(out, @splat(0));
        for (weights, 0..) |w, t| {
            const sy = clampIndex(first + @as(i64, @intCast(t)), src_height);
            const row = ring[(sy % v.taps) * dst_width ..][0..dst_width];
            for (out, row) |*o, p| o.* += p * @as(Pixel, @splat(w));
        }
        encodeRow(format, dst[y * dst_width * ch ..][0 .. dst_width * ch], out);
    }
}

/// Each destination index's source taps on one axis: `count[i]` source
/// indexes from `first[i]` (clamped to the image when outside it), with
/// their weights `taps` apart in `weights`.
const Axis = struct {
    first: []i64,
    count: []u32,
    weights: []f32,
    taps: usize,
    /// The lowest and highest source index any tap reads.
    lowest: i64,
    highest: i64,

    fn init(alloc: std.mem.Allocator, src: u32, dst: u32) error{OutOfMemory}!Axis {
        const first = try alloc.alloc(i64, dst);
        errdefer alloc.free(first);
        const count = try alloc.alloc(u32, dst);
        errdefer alloc.free(count);
        const scale = @as(f32, @floatFromInt(dst)) / @as(f32, @floatFromInt(src));
        if (scale > 1) return initGrow(alloc, dst, scale, first, count);
        return initShrink(alloc, src, dst, scale, first, count);
    }

    fn deinit(a: *Axis, alloc: std.mem.Allocator) void {
        alloc.free(a.first);
        alloc.free(a.count);
        alloc.free(a.weights);
    }

    /// Catmull-Rom over the source pixels around each destination
    /// pixel's center (stb's `calculate_coefficients_upsample`).
    fn initGrow(alloc: std.mem.Allocator, dst: u32, scale: f32, first: []i64, count: []u32) error{OutOfMemory}!Axis {
        const radius = 2 * scale;
        var taps: usize = 0;
        for (first, count, 0..) |*f, *n, i| {
            const lo, const hi = growRange(i, radius, scale);
            f.* = lo;
            n.* = @intCast(hi - lo + 1);
            taps = @max(taps, n.*);
        }
        const weights = try alloc.alloc(f32, dst * taps);
        for (0..dst) |i| {
            const w = weights[i * taps ..][0..count[i]];
            const center = (@as(f32, @floatFromInt(i)) + 0.5) / scale;
            var total: f32 = 0;
            for (w, 0..) |*c, t| {
                const in_center = @as(f32, @floatFromInt(first[i] + @as(i64, @intCast(t)))) + 0.5;
                c.* = catmullRom(center - in_center);
                total += c.*;
            }
            const norm = 1 / total;
            for (w) |*c| c.* *= norm;
        }
        return .{
            .first = first,
            .count = count,
            .weights = weights,
            .taps = taps,
            .lowest = first[0],
            .highest = first[dst - 1] + count[dst - 1] - 1,
        };
    }

    fn growRange(i: usize, radius: f32, scale: f32) struct { i64, i64 } {
        const center = @as(f32, @floatFromInt(i)) + 0.5;
        const lower = (center - radius) / scale;
        const upper = (center + radius) / scale;
        return .{
            @intFromFloat(@floor(@as(f64, lower) + 0.5)),
            @intFromFloat(@floor(@as(f64, upper) - 0.5)),
        };
    }

    /// Mitchell stretched over the destination pixels each source pixel
    /// covers, then normalized per destination pixel (stb's
    /// `calculate_coefficients_downsample` and
    /// `normalize_downsample_coefficients`). Only source pixels within
    /// stb's filter margin of the image contribute.
    fn initShrink(alloc: std.mem.Allocator, src: u32, dst: u32, scale: f32, first: []i64, count: []u32) error{OutOfMemory}!Axis {
        const margin: i64 = @divTrunc(@as(i64, @intFromFloat(@ceil(2 * 2 / scale))), 2);
        const radius = 2 / scale;
        const end = @as(i64, src) + margin;

        // Each destination pixel's source taps are a contiguous run, since
        // both ends of a source pixel's reach grow with it.
        const last = try alloc.alloc(i64, dst);
        defer alloc.free(last);
        @memset(first, std.math.maxInt(i64));
        @memset(last, std.math.minInt(i64));
        var n = -margin;
        while (n < end) : (n += 1) {
            const lo, const hi = shrinkRange(n, radius, scale);
            var i = @max(lo, 0);
            while (i <= @min(hi, @as(i64, dst) - 1)) : (i += 1) {
                const k: usize = @intCast(i);
                first[k] = @min(first[k], n);
                last[k] = @max(last[k], n);
            }
        }
        var taps: usize = 0;
        for (first, last, count) |f, l, *c| {
            c.* = @intCast(l - f + 1);
            taps = @max(taps, c.*);
        }

        const weights = try alloc.alloc(f32, dst * taps);
        @memset(weights, 0);
        n = -margin;
        while (n < end) : (n += 1) {
            const lo, const hi = shrinkRange(n, radius, scale);
            const in_center = (@as(f32, @floatFromInt(n)) + 0.5) * scale;
            var i = @max(lo, 0);
            while (i <= @min(hi, @as(i64, dst) - 1)) : (i += 1) {
                const k: usize = @intCast(i);
                const out_center = @as(f32, @floatFromInt(i)) + 0.5;
                weights[k * taps + @as(usize, @intCast(n - first[k]))] = mitchell(out_center - in_center) * scale;
            }
        }
        for (0..dst) |k| {
            const w = weights[k * taps ..][0..count[k]];
            var total: f32 = 0;
            for (w) |c| total += c;
            const norm = 1 / total;
            for (w) |*c| c.* *= norm;
        }
        return .{
            .first = first,
            .count = count,
            .weights = weights,
            .taps = taps,
            .lowest = first[0],
            .highest = last[dst - 1],
        };
    }

    fn shrinkRange(n: i64, radius: f32, scale: f32) struct { i64, i64 } {
        const center = @as(f32, @floatFromInt(n)) + 0.5;
        const lower = (center - radius) * scale;
        const upper = (center + radius) * scale;
        return .{
            @intFromFloat(@floor(@as(f64, lower) + 0.5)),
            @intFromFloat(@floor(@as(f64, upper) - 0.5)),
        };
    }
};

fn catmullRom(x0: f32) f32 {
    const x = @abs(x0);
    if (x < 1) return 1 - x * x * (2.5 - 1.5 * x);
    if (x < 2) return 2 - x * (4 + x * (0.5 * x - 2.5));
    return 0;
}

fn mitchell(x0: f32) f32 {
    const x = @abs(x0);
    if (x < 1) return (16 + x * x * (21 * x - 36)) / 18;
    if (x < 2) return (32 + x * (-60 + x * (36 - 7 * x))) / 18;
    return 0;
}

fn clampIndex(i: i64, len: u32) u32 {
    return @intCast(std.math.clamp(i, 0, @as(i64, len) - 1));
}

/// stb adds this to straight alpha before premultiplying, so that a
/// transparent pixel keeps its color through the division after.
const alpha_epsilon: f32 = 0x1p-80;

fn decodeRow(comptime format: Format, line: []@Vector(format.channels(), f32), row: []const u8) void {
    const ch = format.channels();
    for (line, 0..) |*p, x| {
        var v: [ch]f32 = undefined;
        for (&v, row[x * ch ..][0..ch]) |*f, b| f.* = @as(f32, @floatFromInt(b)) / 255;
        if (format == .rgba) {
            v[3] += alpha_epsilon;
            for (v[0..3]) |*c| c.* *= v[3];
        }
        p.* = v;
    }
}

fn filterRow(
    comptime ch: comptime_int,
    out: []@Vector(ch, f32),
    line: []const @Vector(ch, f32),
    pad_left: usize,
    h: Axis,
) void {
    for (out, 0..) |*o, x| {
        const start: usize = @intCast(h.first[x] + @as(i64, @intCast(pad_left)));
        const weights = h.weights[x * h.taps ..][0..h.count[x]];
        var acc: @Vector(ch, f32) = @splat(0);
        for (weights, line[start..][0..weights.len]) |w, p| acc += p * @as(@Vector(ch, f32), @splat(w));
        o.* = acc;
    }
}

fn encodeRow(comptime format: Format, row: []u8, out: []const @Vector(format.channels(), f32)) void {
    const ch = format.channels();
    for (out, 0..) |p, x| {
        var v: [ch]f32 = p;
        if (format == .rgba) {
            const recip: f32 = if (v[3] != 0) 1 / v[3] else 0;
            for (v[0..3]) |*c| c.* *= recip;
        }
        for (row[x * ch ..][0..ch], v) |*b, f| {
            const s = std.math.clamp(f, 0, 1) * 255;
            b.* = @intFromFloat(@as(f64, s) + 0.5);
        }
    }
}

test "straight alpha does not bleed a transparent pixel's color" {
    // Opaque red beside transparent green: the average is red at half
    // alpha. Filtering the stored values would mix in green.
    const src = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0 };
    var dst: [4]u8 = undefined;
    try resize(std.testing.allocator, .rgba, &dst, 1, 1, &src, 8, 2, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, dst[0..3]);
    try std.testing.expect(dst[3] >= 127 and dst[3] <= 128);
}
