//! Built-in "sprite" glyphs: box drawing and related characters drawn
//! procedurally at exact cell metrics so lines join seamlessly across
//! cells, regardless of the font in use. These override font glyphs.
//!
//! Draw functions are vendored from ghostty (see sprite/draw/), painting
//! onto a canvas padded by a quarter cell per edge so glyphs may
//! intentionally overhang the cell for seamless corners and diagonals.

const std = @import("std");
const canvas_mod = @import("sprite/canvas.zig");
const metrics_mod = @import("sprite/metrics.zig");
const box = @import("sprite/draw/box.zig");
const block = @import("sprite/draw/block.zig");

const log = std.log.scoped(.sprite);

pub const Metrics = metrics_mod.Metrics;

/// Whether `cp` is drawn as a sprite (overriding any font).
pub fn covers(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => true, // box drawing
        0x2580...0x259F => true, // block elements
        else => false,
    };
}

fn draw(cp: u21, canvas: *canvas_mod.Canvas, metrics: Metrics) !void {
    switch (cp) {
        0x2500...0x257F => try box.draw2500_257F(
            cp,
            canvas,
            metrics.cell_width,
            metrics.cell_height,
            metrics,
        ),
        0x2580...0x259F => try block.draw2580_259F(
            cp,
            canvas,
            metrics.cell_width,
            metrics.cell_height,
            metrics,
        ),
        else => unreachable, // covers() gates this
    }
}

/// A rendered sprite in the same shape as a font glyph: tightly packed
/// A8 coverage bitmap plus placement relative to the cell origin.
/// `bearing_y` is measured from the baseline up to the bitmap top, to
/// match Font.Glyph semantics.
pub const Glyph = struct {
    bitmap: []u8,
    width: u31,
    height: u31,
    bearing_x: i32,
    bearing_y: i32,
};

/// Render `cp` at the given metrics. `baseline` is the distance from
/// the cell top to the text baseline (used only to express placement
/// in the renderer's baseline-relative terms).
pub fn render(
    alloc: std.mem.Allocator,
    cp: u21,
    metrics: Metrics,
    baseline: u31,
) !Glyph {
    std.debug.assert(covers(cp));

    const pad_x = metrics.cell_width / 4;
    const pad_y = metrics.cell_height / 4;
    var canvas: canvas_mod.Canvas = try .init(
        alloc,
        metrics.cell_width,
        metrics.cell_height,
        pad_x,
        pad_y,
    );
    defer canvas.deinit();

    try draw(cp, &canvas, metrics);

    const bitmap = try canvas.toBitmap(alloc);
    // Bitmap top relative to the cell top: clip_top - pad_y.
    const top: i32 = @as(i32, @intCast(bitmap.clip_top)) - @as(i32, @intCast(pad_y));
    return .{
        .bitmap = bitmap.data,
        .width = @intCast(bitmap.width),
        .height = @intCast(bitmap.height),
        .bearing_x = @as(i32, @intCast(bitmap.clip_left)) - @as(i32, @intCast(pad_x)),
        .bearing_y = @as(i32, @intCast(baseline)) - top,
    };
}

test "sprite coverage" {
    try std.testing.expect(covers(0x2500)); // ─
    try std.testing.expect(covers(0x2588)); // █
    try std.testing.expect(!covers('A'));
    try std.testing.expect(!covers(0x25A0)); // ■ (geometric, not yet)
}

test "render box drawing sprites" {
    const alloc = std.testing.allocator;
    const metrics: Metrics = .{ .cell_width = 10, .cell_height = 20, .box_thickness = 1 };

    // Horizontal line: full cell width, thin, vertically centered.
    {
        const g = try render(alloc, 0x2500, metrics, 15);
        defer alloc.free(g.bitmap);
        try std.testing.expectEqual(@as(u31, 10), g.width);
        try std.testing.expect(g.height < 5);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }

    // Full block: covers the whole cell exactly.
    {
        const g = try render(alloc, 0x2588, metrics, 15);
        defer alloc.free(g.bitmap);
        try std.testing.expectEqual(@as(u31, 10), g.width);
        try std.testing.expectEqual(@as(u31, 20), g.height);
        try std.testing.expectEqual(@as(i32, 0), g.bearing_x);
        try std.testing.expectEqual(@as(i32, 15), g.bearing_y); // top of cell
        for (g.bitmap) |px| try std.testing.expectEqual(@as(u8, 0xFF), px);
    }

    // Rounded corner: uses the z2d path rasterizer.
    {
        const g = try render(alloc, 0x256D, metrics, 15); // ╭
        defer alloc.free(g.bitmap);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }
}
