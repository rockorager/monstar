//! Monospace font loading and glyph rasterization.
//!
//! Uses fontconfig to resolve a family name to a font file, FreeType to
//! rasterize glyphs, and exposes a HarfBuzz font for shaping. Rasterized
//! glyphs are cached by glyph index.

const Font = @This();

const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.font);

ft_lib: c.FT_Library,
face: c.FT_Face,
hb_font: *c.hb_font_t,
glyphs: std.AutoHashMapUnmanaged(u32, Glyph),

/// Fixed cell metrics in pixels, derived from the font.
cell_width: u31,
cell_height: u31,
/// Distance from the cell top to the text baseline.
baseline: u31,

/// A rasterized glyph: an 8-bit coverage bitmap plus placement metrics.
/// `bearing_y` is the distance from the baseline up to the bitmap top.
pub const Glyph = struct {
    bitmap: []u8,
    width: u31,
    height: u31,
    bearing_x: i32,
    bearing_y: i32,
};

pub const Error = error{ FontNotFound, FontLoadFailed, OutOfMemory };

/// Load the best match for `family` (e.g. "monospace") at `size_px`.
pub fn init(family: [:0]const u8, size_px: u31) Error!Font {
    std.debug.assert(size_px > 0);

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try resolveFontFile(family, size_px, &file_buf);

    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FontLoadFailed;
    errdefer _ = c.FT_Done_FreeType(ft_lib);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(ft_lib, file.path.ptr, file.index, &face) != 0) {
        log.err("FT_New_Face failed for {s}", .{file.path});
        return error.FontLoadFailed;
    }
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return error.FontLoadFailed;

    const hb_font = c.hb_ft_font_create_referenced(face) orelse return error.FontLoadFailed;

    // Cell metrics: advance of a reference glyph for width, font-global
    // ascender/descender for height. 26.6 fixed point.
    const metrics = face.*.size.*.metrics;
    const cell_height: u31 = @intCast((metrics.ascender - metrics.descender) >> 6);
    const baseline: u31 = @intCast(metrics.ascender >> 6);
    const cell_width: u31 = width: {
        const idx = c.FT_Get_Char_Index(face, 'M');
        if (idx != 0 and c.FT_Load_Glyph(face, idx, c.FT_LOAD_DEFAULT) == 0) {
            break :width @intCast(face.*.glyph.*.advance.x >> 6);
        }
        break :width @intCast(metrics.max_advance >> 6);
    };

    log.info("loaded {s} ({s}) cell {d}x{d} baseline {d}", .{
        file.path, family, cell_width, cell_height, baseline,
    });

    return .{
        .ft_lib = ft_lib,
        .face = face,
        .hb_font = hb_font,
        .glyphs = .empty,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .baseline = baseline,
    };
}

pub fn deinit(self: *Font, alloc: std.mem.Allocator) void {
    var it = self.glyphs.valueIterator();
    while (it.next()) |g| alloc.free(g.bitmap);
    self.glyphs.deinit(alloc);
    c.hb_font_destroy(self.hb_font);
    _ = c.FT_Done_Face(self.face);
    _ = c.FT_Done_FreeType(self.ft_lib);
    self.* = undefined;
}

/// Rasterize (or fetch from cache) the glyph with the given index.
pub fn glyph(self: *Font, alloc: std.mem.Allocator, index: u32) Error!*const Glyph {
    const gop = try self.glyphs.getOrPut(alloc, index);
    if (gop.found_existing) return gop.value_ptr;
    errdefer _ = self.glyphs.remove(index);

    if (c.FT_Load_Glyph(self.face, index, c.FT_LOAD_DEFAULT) != 0)
        return error.FontLoadFailed;
    if (c.FT_Render_Glyph(self.face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
        return error.FontLoadFailed;

    const slot = self.face.*.glyph;
    const bitmap = slot.*.bitmap;
    std.debug.assert(bitmap.pixel_mode == c.FT_PIXEL_MODE_GRAY);

    const width: u31 = @intCast(bitmap.width);
    const height: u31 = @intCast(bitmap.rows);
    const copy = try alloc.alloc(u8, @as(usize, width) * height);
    errdefer alloc.free(copy);

    // FreeType rows are padded to `pitch` bytes; store tightly packed.
    if (height > 0) {
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..height) |y| {
            const src = bitmap.buffer[y * pitch ..][0..width];
            @memcpy(copy[y * width ..][0..width], src);
        }
    }

    gop.value_ptr.* = .{
        .bitmap = copy,
        .width = width,
        .height = height,
        .bearing_x = slot.*.bitmap_left,
        .bearing_y = slot.*.bitmap_top,
    };
    return gop.value_ptr;
}

const FontFile = struct {
    path: [:0]const u8,
    index: c_int,
};

/// Ask fontconfig for the font file backing `family` at the given size.
fn resolveFontFile(family: [:0]const u8, size_px: u31, buf: []u8) Error!FontFile {
    if (c.FcInit() != c.FcTrue) return error.FontLoadFailed;

    const pattern = c.FcPatternCreate() orelse return error.FontLoadFailed;
    defer c.FcPatternDestroy(pattern);

    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, family.ptr);
    _ = c.FcPatternAddDouble(pattern, c.FC_PIXEL_SIZE, @floatFromInt(size_px));
    _ = c.FcPatternAddInteger(pattern, c.FC_SPACING, c.FC_MONO);
    if (c.FcConfigSubstitute(null, pattern, c.FcMatchPattern) != c.FcTrue)
        return error.FontLoadFailed;
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(match);
    if (result != c.FcResultMatch) return error.FontNotFound;

    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch)
        return error.FontNotFound;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(match, c.FC_INDEX, 0, &index);

    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    if (path.len >= buf.len) return error.FontLoadFailed;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return .{ .path = buf[0..path.len :0], .index = index };
}

test "load monospace font and rasterize a glyph" {
    const alloc = std.testing.allocator;
    var font: Font = try .init("monospace", 16);
    defer font.deinit(alloc);

    try std.testing.expect(font.cell_width > 0);
    try std.testing.expect(font.cell_height >= font.baseline);

    const idx = c.FT_Get_Char_Index(font.face, 'A');
    try std.testing.expect(idx != 0);
    const g = try font.glyph(alloc, idx);
    try std.testing.expect(g.width > 0 and g.height > 0);
    // Cached: same pointer on second lookup.
    try std.testing.expectEqual(g, try font.glyph(alloc, idx));
}
