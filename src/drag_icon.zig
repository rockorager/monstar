//! Converts OSC 72 text and image previews into immutable ARGB drag buffers.

const std = @import("std");
const c = @import("c");
const wl = @import("wayland").client.wl;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const ShmBuffer = @import("ShmBuffer.zig");
const TextShaper = @import("TextShaper.zig");
const raster = @import("pixel_raster.zig");

pub const max_bytes = 16 * 1024 * 1024;
const max_dimension = 2048;

/// The caller owns the returned buffer. scale is its integer buffer scale.
pub fn create(
    alloc: std.mem.Allocator,
    shm: *wl.Shm,
    base_font: *const Font,
    scale: u31,
    scale120: u32,
    meta: vt.kitty.dnd.Metadata,
    data: []const u8,
    available_bytes: usize,
) !*ShmBuffer {
    if (meta.cell_y == 0) return createText(alloc, shm, base_font, scale, scale120, meta, data, available_bytes);
    if (meta.cell_y != 24 and meta.cell_y != 32 and meta.cell_y != 100) return error.InvalidImage;
    if (meta.pixel_x <= 0 or meta.pixel_y <= 0) return error.InvalidImage;
    const width: u31 = @intCast(meta.pixel_x);
    const height: u31 = @intCast(meta.pixel_y);
    if (width > max_dimension or height > max_dimension) return error.TooLarge;
    const display_width: u31 = @intCast(@max(1, (@as(u64, width) * scale * 120 + scale120 / 2) / scale120));
    const display_height: u31 = @intCast(@max(1, (@as(u64, height) * scale * 120 + scale120 / 2) / scale120));
    const dimensions = try bufferDimensions(display_width, display_height, scale, available_bytes);
    var rgba = data;
    var decoded: ?[*]u8 = null;
    defer if (decoded) |pixels| c.stbi_image_free(pixels);
    if (meta.cell_y == 100) {
        if (!std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return error.InvalidImage;
        var png_width: c_int = 0;
        var png_height: c_int = 0;
        var channels: c_int = 0;
        if (c.stbi_info_from_memory(data.ptr, @intCast(data.len), &png_width, &png_height, &channels) == 0 or
            png_width != width or png_height != height) return error.InvalidImage;
        var status: c_int = 0;
        decoded = c.monstar_load_drag_png(data.ptr, @intCast(data.len), &png_width, &png_height, &status) orelse
            return switch (status) {
                1 => error.TooLarge,
                2 => error.OutOfMemory,
                else => error.InvalidImage,
            };
        rgba = decoded.?[0 .. @as(usize, width) * height * 4];
    }
    const channels: usize = if (meta.cell_y == 24) 3 else 4;
    if (rgba.len != @as(usize, width) * height * channels) return error.InvalidImage;
    var resized: []u8 = &.{};
    defer alloc.free(resized);
    if (display_width != width or display_height != height) {
        resized = try alloc.alloc(u8, @as(usize, display_width) * display_height * channels);
        if (c.stbir_resize_uint8_srgb(
            rgba.ptr,
            width,
            height,
            0,
            resized.ptr,
            display_width,
            display_height,
            0,
            @intCast(channels),
            if (channels == 4) 3 else c.STBIR_ALPHA_CHANNEL_NONE,
            0,
        ) == 0) return error.InvalidImage;
        rgba = resized;
    }
    const buffer = try ShmBuffer.create(alloc, shm, @intCast(dimensions.width), @intCast(dimensions.height), .argb8888);
    @memset(buffer.pixels(), 0);
    const pixels = buffer.pixels();
    for (0..display_height) |y| for (0..display_width) |x| {
        const offset = (y * display_width + x) * channels;
        pixels[y * buffer.width + x] = raster.premultipliedArgb(.{
            .r = rgba[offset],
            .g = rgba[offset + 1],
            .b = rgba[offset + 2],
        }, if (channels == 4) rgba[offset + 3] else 255);
    };
    return buffer;
}

fn bufferDimensions(width: usize, height: usize, scale: u31, available_bytes: usize) !struct { width: usize, height: usize } {
    const w = std.mem.alignForwardAnyAlign(usize, width, scale);
    const h = std.mem.alignForwardAnyAlign(usize, height, scale);
    if (w == 0 or h == 0 or w > max_dimension or h > max_dimension or w * h * 4 > @min(max_bytes, available_bytes)) return error.TooLarge;
    return .{ .width = w, .height = h };
}

fn createText(
    alloc: std.mem.Allocator,
    shm: *wl.Shm,
    base_font: *const Font,
    scale: u31,
    scale120: u32,
    meta: vt.kitty.dnd.Metadata,
    data: []const u8,
    available_bytes: usize,
) !*ShmBuffer {
    if (meta.pixel_x <= 0 or meta.pixel_y <= 0 or meta.operation > 1024 or data.len == 0) return error.InvalidImage;
    if (data.len > 4096) return error.TooLarge;
    var it = (std.unicode.Utf8View.init(data) catch return error.InvalidImage).iterator();
    const size = base_font.size_px * @as(f64, @floatFromInt(meta.pixel_x)) /
        @as(f64, @floatFromInt(meta.pixel_y)) * @as(f64, @floatFromInt(scale * 120)) /
        @as(f64, @floatFromInt(scale120));
    if (size < 1 or size > 256) return error.TooLarge;
    var font = try Font.init(alloc, base_font.discovery_data.family, size, null);
    defer font.deinit(alloc);
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(alloc);
    while (it.nextCodepoint()) |cp| try codepoints.append(alloc, if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) ' ' else cp);
    const padding = @as(usize, scale) * 4;
    var columns: usize = 0;
    var offset: usize = 0;
    while (offset < codepoints.items.len) {
        const cluster = vt.unicode.graphemeWidth(u21, codepoints.items[offset..]);
        columns += @max(cluster.width, 1);
        offset += cluster.len;
    }
    if (columns > max_dimension / font.cell_width) return error.TooLarge;
    const dimensions = try bufferDimensions(columns * font.cell_width + padding * 2, font.cell_height + padding * 2, scale, available_bytes);
    const buffer = try ShmBuffer.create(alloc, shm, @intCast(dimensions.width), @intCast(dimensions.height), .argb8888);
    errdefer buffer.destroy(alloc);
    @memset(buffer.pixels(), raster.premultipliedArgb(.{ .r = 32, .g = 32, .b = 32 }, @intCast(meta.operation * 255 / 1024)));
    var shaper = try TextShaper.init(alloc, &font);
    defer shaper.deinit();
    var column: usize = 0;
    const baseline: i32 = @intCast(padding + font.baseline);
    offset = 0;
    while (offset < codepoints.items.len) {
        const cluster = vt.unicode.graphemeWidth(u21, codepoints.items[offset..]);
        const cells: u2 = @max(cluster.width, 1);
        const cps = codepoints.items[offset..][0..cluster.len];
        offset += cluster.len;
        const face_index = font.faceForCluster(alloc, cps, .regular);
        const x: i32 = @intCast(padding + column * font.cell_width);
        if (face_index == Font.sprite_face_index) {
            const glyph = try font.spriteGlyph(alloc, cps[0], cells);
            raster.blitGlyph(buffer.pixels(), buffer.width, buffer.width, buffer.height, glyph, x + glyph.bearing_x, baseline - glyph.bearing_y, 0xffffffff, false, null);
        } else {
            try shaper.beginKey(face_index, .regular);
            try shaper.appendKeyCodepoints(0, cps[0], cps[1..]);
            const shaped = try shaper.shape(face_index, .regular, cells);
            var pen: i64 = @as(i64, x) * 64;
            for (shaped) |sg| {
                const glyph = try font.face(sg.face).glyph(alloc, sg.glyph, cells, false);
                raster.blitGlyph(buffer.pixels(), buffer.width, buffer.width, buffer.height, glyph, @intCast(@divFloor(pen + sg.x_offset, 64) + glyph.bearing_x), baseline - @as(i32, @intCast(@divFloor(@as(i64, sg.y_offset), 64))) - glyph.bearing_y, 0xffffffff, false, null);
                pen += sg.x_advance;
            }
        }
        column += cells;
    }
    return buffer;
}
