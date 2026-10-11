//! Renders Kitty drag images (OSC 72 t=p with a negative index) into
//! premultiplied ARGB pixels for a drag icon surface.

const std = @import("std");
const c = @import("c");
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const glyph_constraints = @import("glyph_constraints.zig");
const raster = @import("pixel_raster.zig");

/// Bounds a converted preview to 16 MiB of ARGB.
pub const max_pixels = 4 * 1024 * 1024;
const max_font_px = 512;

pub const Pixels = struct {
    width: u31,
    height: u31,
    /// Buffer pixels per logical pixel; both dimensions are multiples of it.
    scale: u31,
    argb: []u32,

    pub fn deinit(self: Pixels, alloc: std.mem.Allocator) void {
        alloc.free(self.argb);
    }
};

/// Converts RGB or RGBA rows (`channels` 3 or 4) shown one image pixel per
/// logical pixel, the size the client asked for on any display.
pub fn fromRgb(alloc: std.mem.Allocator, width: u32, height: u32, channels: u3, data: []const u8) error{ TooLarge, OutOfMemory }!Pixels {
    std.debug.assert(channels == 3 or channels == 4);
    const count = @as(u64, width) * height;
    if (width == 0 or height == 0 or count > max_pixels) return error.TooLarge;
    std.debug.assert(data.len == count * channels);
    const argb = try alloc.alloc(u32, @intCast(count));
    for (argb, 0..) |*pixel, i| {
        const src = data[i * channels ..][0..channels];
        pixel.* = raster.premultipliedArgb(.{ .r = src[0], .g = src[1], .b = src[2] }, if (channels == 4) src[3] else 255);
    }
    return .{ .width = @intCast(width), .height = @intCast(height), .scale = 1, .argb = argb };
}

pub const TextStyle = struct {
    font_family: [:0]const u8,
    font_size: Config.FontSize,
    adjust_cell_height: ?Config.MetricModifier,
    foreground: vt.color.RGB,
    background: vt.color.RGB,
};

/// Renders UTF-8 `text` on one line at the terminal font size times
/// `scale_x / scale_y` (1 when either is zero), over the background at
/// `opacity` / 1024. `scale` is the integer buffer scale to render at.
pub fn text(
    alloc: std.mem.Allocator,
    style: TextStyle,
    utf8: []const u8,
    scale_x: u32,
    scale_y: u32,
    opacity: u32,
    scale: u31,
) !Pixels {
    std.debug.assert(scale >= 1);
    const ratio: f64 = if (scale_x == 0 or scale_y == 0) 1 else @as(f64, @floatFromInt(scale_x)) / @as(f64, @floatFromInt(scale_y));
    const size_px = Config.fontSizePixels(style.font_size, @as(u32, scale) * 120) * ratio;
    if (size_px > max_font_px) return error.TooLarge;
    var font: Font = try .init(alloc, style.font_family, @max(1, size_px), style.adjust_cell_height);
    defer font.deinit(alloc);

    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(alloc);
    var it = (std.unicode.Utf8View.init(utf8) catch return error.InvalidImage).iterator();
    // The protocol lets terminals draw everything on one line.
    while (it.nextCodepoint()) |cp| try codepoints.append(alloc, if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) ' ' else cp);
    var columns: u64 = 0;
    var i: usize = 0;
    while (i < codepoints.items.len) {
        const cluster = vt.unicode.graphemeWidth(u21, codepoints.items[i..]);
        if (cluster.len == 0) break;
        i += cluster.len;
        columns += cluster.width;
    }

    const padding = @max(scale, font.cell_height / 4);
    const width = alignUp(columns * font.cell_width + 2 * padding, scale);
    const height = alignUp(@as(u64, font.cell_height) + 2 * padding, scale);
    if (width * height > max_pixels) return error.TooLarge;
    const pixels: Pixels = .{
        .width = @intCast(width),
        .height = @intCast(height),
        .scale = scale,
        .argb = try alloc.alloc(u32, @intCast(width * height)),
    };
    errdefer pixels.deinit(alloc);
    const alpha: u8 = @intCast((@as(u32, @min(opacity, 1024)) * 255 + 512) / 1024);
    @memset(pixels.argb, raster.premultipliedArgb(style.background, alpha));

    const color = raster.argb(style.foreground);
    const baseline: i32 = @intCast(padding + font.baseline);
    var x: i32 = @intCast(padding);
    i = 0;
    while (i < codepoints.items.len) {
        const cluster = vt.unicode.graphemeWidth(u21, codepoints.items[i..]);
        if (cluster.len == 0) break;
        const cp = codepoints.items[i];
        i += cluster.len;
        if (cluster.width == 0) continue;
        const span: u2 = @intCast(@min(cluster.width, 2));
        const face_index = font.faceForCodepoint(alloc, cp);
        const glyph = if (face_index == Font.sprite_face_index)
            try font.spriteGlyph(alloc, cp, span)
        else glyph: {
            const face = font.face(face_index);
            const index = c.FT_Get_Char_Index(face.ft_face, cp);
            if (index == 0) break :glyph null;
            break :glyph try face.glyph(alloc, index, span, glyph_constraints.isSymbol(cp));
        };
        if (glyph) |g| raster.blitGlyph(pixels.argb, pixels.width, pixels.width, pixels.height, g, x + g.bearing_x, baseline - g.bearing_y, color, false, null);
        x += @as(i32, cluster.width) * font.cell_width;
    }
    return pixels;
}

fn alignUp(value: u64, scale: u31) u64 {
    return std.mem.alignForwardAnyAlign(u64, value, scale);
}

test "RGBA previews are premultiplied and RGB previews are opaque" {
    const alloc = std.testing.allocator;
    const rgba = try fromRgb(alloc, 2, 1, 4, &.{ 200, 100, 50, 128, 10, 20, 30, 0 });
    defer rgba.deinit(alloc);
    try std.testing.expectEqualSlices(u32, &.{ 0x80643219, 0x00000000 }, rgba.argb);

    const rgb = try fromRgb(alloc, 1, 2, 3, &.{ 1, 2, 3, 4, 5, 6 });
    defer rgb.deinit(alloc);
    try std.testing.expectEqual(@as(u31, 1), rgb.width);
    try std.testing.expectEqual(@as(u31, 2), rgb.height);
    try std.testing.expectEqualSlices(u32, &.{ 0xff010203, 0xff040506 }, rgb.argb);

    try std.testing.expectError(error.TooLarge, fromRgb(alloc, 4096, 1025, 3, &.{}));
}

test "text previews fit the buffer scale and honor background opacity" {
    const alloc = std.testing.allocator;
    const style: TextStyle = .{
        .font_family = "monospace",
        .font_size = .{ .pixels = 13 },
        .adjust_cell_height = null,
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .background = .{ .r = 0, .g = 0, .b = 200 },
    };
    const label = try text(alloc, style, "Ab\ncd", 2, 1, 512, 3);
    defer label.deinit(alloc);
    try std.testing.expectEqual(@as(u31, 3), label.scale);
    try std.testing.expectEqual(@as(u31, 0), label.width % 3);
    try std.testing.expectEqual(@as(u31, 0), label.height % 3);
    // The corner is padding: background blue at half opacity, premultiplied.
    try std.testing.expectEqual(@as(u32, 0x80000064), label.argb[0]);
    var lit: usize = 0;
    for (label.argb) |pixel| lit += @intFromBool(pixel >> 16 & 0xff > 0x80);
    try std.testing.expect(lit > 0);

    // Twice the scale ratio gives a wider label for the same text.
    const small = try text(alloc, style, "Ab\ncd", 1, 1, 0, 3);
    defer small.deinit(alloc);
    try std.testing.expect(label.width > small.width);
    try std.testing.expectEqual(@as(u32, 0), small.argb[0]);

    try std.testing.expectError(error.InvalidImage, text(alloc, style, "\xff", 1, 1, 0, 1));
}
