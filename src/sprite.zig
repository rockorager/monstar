//! Built-in "sprite" glyphs: box drawing and related characters drawn
//! procedurally at exact cell metrics so lines join seamlessly across
//! cells, regardless of the font in use. These override font glyphs.
//! Also renders text decorations (underlines, strikethrough, overline).
//!
//! Draw functions are vendored from ghostty (see sprite/draw/), painting
//! onto a canvas padded by a quarter cell per edge so glyphs may
//! intentionally overhang the cell for seamless corners and diagonals.
//! The codepoint dispatch table is adapted from ghostty's sprite Face.

const std = @import("std");
const z2d = @import("z2d");
const canvas_mod = @import("sprite/canvas.zig");
const metrics_mod = @import("sprite/metrics.zig");
const special = @import("sprite/draw/special.zig");

const log = std.log.scoped(.sprite);

pub const Metrics = metrics_mod.Metrics;

pub const DrawFnError =
    std.mem.Allocator.Error ||
    z2d.Path.Error ||
    z2d.painter.FillError ||
    z2d.painter.StrokeError ||
    error{MathError};

pub const DrawFn = fn (
    cp: u32,
    canvas: *canvas_mod.Canvas,
    width: u32,
    height: u32,
    metrics: Metrics,
) DrawFnError!void;

const Range = struct {
    min: u21,
    max: u21,
    draw: *const DrawFn,
};

/// Sorted codepoint ranges with their draw functions, gathered at
/// comptime from `draw<HEX>` / `draw<MIN>_<MAX>` function names in the
/// draw modules (same convention as ghostty).
const ranges: []const Range = ranges: {
    const structs = [_]type{
        @import("sprite/draw/block.zig"),
        @import("sprite/draw/box.zig"),
        @import("sprite/draw/braille.zig"),
        @import("sprite/draw/branch.zig"),
        @import("sprite/draw/geometric_shapes.zig"),
        @import("sprite/draw/powerline.zig"),
        @import("sprite/draw/symbols_for_legacy_computing.zig"),
        @import("sprite/draw/symbols_for_legacy_computing_supplement.zig"),
    };

    @setEvalBranchQuota(100_000);

    var range_count = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;
            range_count += 1;
        }
    }

    var r: [range_count]Range = undefined;
    var i = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;

            const sep = std.mem.indexOfScalar(u8, decl.name, '_') orelse decl.name.len;
            const min = std.fmt.parseInt(u21, decl.name[4..sep], 16) catch unreachable;
            const max = if (sep == decl.name.len)
                min
            else
                std.fmt.parseInt(u21, decl.name[sep + 1 ..], 16) catch unreachable;

            r[i] = .{ .min = min, .max = max, .draw = @field(s, decl.name) };
            i += 1;
        }
    }

    std.mem.sortUnstable(Range, &r, {}, struct {
        pub fn lessThan(_: void, a: Range, b: Range) bool {
            return a.min < b.min;
        }
    }.lessThan);

    // Overlapping ranges would make dispatch ambiguous.
    for (r[1..], 1..) |range, k| {
        if (range.min <= r[k - 1].max) @compileError("overlapping sprite ranges");
    }

    const fixed = r;
    break :ranges &fixed;
};

fn getDrawFn(cp: u21) ?*const DrawFn {
    for (ranges) |range| {
        if (cp >= range.min and cp <= range.max) return range.draw;
    }
    return null;
}

/// Whether `cp` is drawn as a sprite (overriding any font).
pub fn covers(cp: u21) bool {
    return getDrawFn(cp) != null;
}

/// Text decorations and cursor shapes, drawn with the same machinery.
/// Names match the vendored function names in draw/special.zig.
pub const Decoration = enum {
    underline,
    underline_double,
    underline_dotted,
    underline_dashed,
    underline_curly,
    strikethrough,
    overline,
    cursor_bar,
    cursor_underline,
    cursor_hollow_rect,
};

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
    cell_span: u2,
) !Glyph {
    std.debug.assert(cell_span >= 1);
    const draw = getDrawFn(cp) orelse unreachable; // covers() gates this
    return renderWith(alloc, draw, cp, metrics, baseline, cell_span);
}

/// Render a text decoration sprite.
pub fn renderDecoration(
    alloc: std.mem.Allocator,
    kind: Decoration,
    metrics: Metrics,
    baseline: u31,
) !Glyph {
    return switch (kind) {
        inline else => |k| renderWith(
            alloc,
            @field(special, @tagName(k)),
            0,
            metrics,
            baseline,
            1,
        ),
    };
}

fn renderWith(
    alloc: std.mem.Allocator,
    draw: *const DrawFn,
    cp: u21,
    metrics: Metrics,
    baseline: u31,
    cell_span: u2,
) !Glyph {
    var draw_metrics = metrics;
    draw_metrics.cell_width *= cell_span;
    const pad_x = metrics.cell_width / 4;
    const pad_y = metrics.cell_height / 4;
    var canvas: canvas_mod.Canvas = try .init(
        alloc,
        draw_metrics.cell_width,
        metrics.cell_height,
        pad_x,
        pad_y,
    );
    defer canvas.deinit();

    try draw(cp, &canvas, draw_metrics.cell_width, metrics.cell_height, draw_metrics);

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

const test_metrics: Metrics = .{
    .cell_width = 10,
    .cell_height = 20,
    .box_thickness = 1,
    .underline_position = 17,
    .underline_thickness = 1,
    .strikethrough_position = 10,
    .strikethrough_thickness = 1,
    .overline_position = 0,
    .overline_thickness = 1,
    .cursor_thickness = 1,
};

test "sprite coverage" {
    try std.testing.expect(covers(0x2500)); // ─ box drawing
    try std.testing.expect(covers(0x2588)); // █ block
    try std.testing.expect(covers(0x2800)); // ⠀ braille
    try std.testing.expect(covers(0xE0B0)); // powerline
    try std.testing.expect(covers(0x1FB00)); // legacy computing
    try std.testing.expect(covers(0x1CC1F)); // supplement double diagonal
    try std.testing.expect(covers(0x1CC20)); // supplement double diagonal
    try std.testing.expect(!covers('A'));
    try std.testing.expect(!covers(0x3042)); // あ
}

test "render box drawing sprites" {
    const alloc = std.testing.allocator;

    // Horizontal line: full cell width, thin, vertically centered.
    {
        const g = try render(alloc, 0x2500, test_metrics, 15, 1);
        defer alloc.free(g.bitmap);
        try std.testing.expectEqual(@as(u31, 10), g.width);
        try std.testing.expect(g.height < 5);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }

    // Wide variants use the occupied cell span while preserving vertical metrics.
    {
        const g = try render(alloc, 0x2500, test_metrics, 15, 2);
        defer alloc.free(g.bitmap);
        try std.testing.expectEqual(@as(u31, 20), g.width);
        try std.testing.expect(g.height < 5);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }

    // Full block: covers the whole cell exactly.
    {
        const g = try render(alloc, 0x2588, test_metrics, 15, 1);
        defer alloc.free(g.bitmap);
        try std.testing.expectEqual(@as(u31, 10), g.width);
        try std.testing.expectEqual(@as(u31, 20), g.height);
        try std.testing.expectEqual(@as(i32, 0), g.bearing_x);
        try std.testing.expectEqual(@as(i32, 15), g.bearing_y); // top of cell
        for (g.bitmap) |px| try std.testing.expectEqual(@as(u8, 0xFF), px);
    }

    // Rounded corner: uses the z2d path rasterizer.
    {
        const g = try render(alloc, 0x256D, test_metrics, 15, 1); // ╭
        defer alloc.free(g.bitmap);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }

    // Diagonal fills and supplement double diagonals render at awkward
    // non-even cell metrics, which exercises the hatch alignment path.
    const odd_metrics: Metrics = .{
        .cell_width = 11,
        .cell_height = 23,
        .box_thickness = 1,
    };
    inline for (&.{ 0x1FB98, 0x1FB99, 0x1CC1F, 0x1CC20 }) |cp| {
        const g = try render(alloc, cp, odd_metrics, 17, 1);
        defer alloc.free(g.bitmap);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }
}

test "render decorations" {
    const alloc = std.testing.allocator;
    inline for (@typeInfo(Decoration).@"enum".fields) |field| {
        const g = try renderDecoration(
            alloc,
            @field(Decoration, field.name),
            test_metrics,
            15,
        );
        defer alloc.free(g.bitmap);
        var sum: usize = 0;
        for (g.bitmap) |px| sum += px;
        try std.testing.expect(sum > 0);
    }
}
