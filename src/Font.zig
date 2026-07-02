//! Monospace font loading, glyph rasterization, and fallback.
//!
//! Uses fontconfig to resolve a family name to a sorted list of candidate
//! fonts, FreeType to rasterize glyphs, and exposes a HarfBuzz font per
//! face for shaping. The primary face defines the cell metrics; fallback
//! faces are loaded lazily (at the same pixel size) when the primary lacks
//! a codepoint, walking the fontconfig sort order by charset coverage.

const Font = @This();

const std = @import("std");
const c = @import("c");
const sprite = @import("sprite.zig");

const log = std.log.scoped(.font);

/// Virtual face index for procedurally drawn sprite glyphs (box
/// drawing etc.). Never a valid index into `faces`.
pub const sprite_face_index: u16 = std.math.maxInt(u16);

/// Bundled Nerd Font symbols (MIT licensed, see assets/): icon glyphs
/// render identically everywhere without requiring an installed patched
/// font. Consulted after the primary face, before system fallbacks.
const embedded_symbols = @embedFile("assets/SymbolsNerdFontMono-Regular.ttf");

/// Marks a sort-list candidate that failed to load.
const failed_face = std.math.maxInt(u16);

ft_lib: c.FT_Library,
/// Loaded faces; faces[0] is the primary and defines cell metrics.
faces: std.ArrayList(Face),
/// Fontconfig's sorted candidate list for fallback lookups.
sort_set: *c.FcFontSet,
/// sort_set index -> faces index (or failed_face).
sort_faces: std.AutoHashMapUnmanaged(u32, u16),
/// codepoint -> faces index, for codepoints the primary lacks.
codepoint_faces: std.AutoHashMapUnmanaged(u21, u16),
/// faces index of the embedded symbols face, if it loaded.
embedded_face: ?u16,
/// Procedural sprite glyphs, keyed by codepoint (metrics are fixed
/// per Font instance, so no size key is needed).
sprite_glyphs: std.AutoHashMapUnmanaged(u21, Glyph),
sprite_metrics: sprite.Metrics,
size_px: u31,

/// Fixed cell metrics in pixels, derived from the primary face.
cell_width: u31,
cell_height: u31,
/// Distance from the cell top to the text baseline.
baseline: u31,

pub const Error = error{ FontNotFound, FontLoadFailed, OutOfMemory };

/// A single loaded font face with its glyph cache.
pub const Face = struct {
    ft_face: c.FT_Face,
    hb_font: *c.hb_font_t,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph),

    fn load(ft_lib: c.FT_Library, path: [*:0]const u8, index: c_int, size_px: u31) Error!Face {
        var ft_face: c.FT_Face = undefined;
        if (c.FT_New_Face(ft_lib, path, index, &ft_face) != 0) return error.FontLoadFailed;
        return fromFtFace(ft_face, size_px);
    }

    /// `bytes` must outlive the face (fine for @embedFile data).
    fn loadMemory(ft_lib: c.FT_Library, bytes: []const u8, size_px: u31) Error!Face {
        var ft_face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(ft_lib, bytes.ptr, @intCast(bytes.len), 0, &ft_face) != 0)
            return error.FontLoadFailed;
        return fromFtFace(ft_face, size_px);
    }

    fn fromFtFace(ft_face: c.FT_Face, size_px: u31) Error!Face {
        errdefer _ = c.FT_Done_Face(ft_face);
        // Fails for fixed-size (e.g. color emoji) faces; those are
        // treated as unusable rather than rendered at a wrong size.
        if (c.FT_Set_Pixel_Sizes(ft_face, 0, size_px) != 0) return error.FontLoadFailed;

        const hb_font = c.hb_ft_font_create_referenced(ft_face) orelse
            return error.FontLoadFailed;

        return .{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .glyphs = .empty,
        };
    }

    fn deinit(self: *Face, alloc: std.mem.Allocator) void {
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| alloc.free(g.bitmap);
        self.glyphs.deinit(alloc);
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.ft_face);
        self.* = undefined;
    }

    pub fn hasCodepoint(self: *const Face, cp: u21) bool {
        return c.FT_Get_Char_Index(self.ft_face, cp) != 0;
    }

    /// Rasterize (or fetch from cache) the glyph with the given index.
    pub fn glyph(self: *Face, alloc: std.mem.Allocator, index: u32) Error!*const Glyph {
        const gop = try self.glyphs.getOrPut(alloc, index);
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = self.glyphs.remove(index);

        if (c.FT_Load_Glyph(self.ft_face, index, c.FT_LOAD_DEFAULT) != 0)
            return error.FontLoadFailed;
        if (c.FT_Render_Glyph(self.ft_face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
            return error.FontLoadFailed;

        const slot = self.ft_face.*.glyph;
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
};

/// A rasterized glyph: an 8-bit coverage bitmap plus placement metrics.
/// `bearing_y` is the distance from the baseline up to the bitmap top.
pub const Glyph = struct {
    bitmap: []u8,
    width: u31,
    height: u31,
    bearing_x: i32,
    bearing_y: i32,
};

/// Load the best match for `family` (e.g. "monospace") at `size_px`.
pub fn init(alloc: std.mem.Allocator, family: [:0]const u8, size_px: u31) Error!Font {
    std.debug.assert(size_px > 0);

    if (c.FcInit() != c.FcTrue) return error.FontLoadFailed;

    const pattern = c.FcPatternCreate() orelse return error.FontLoadFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, family.ptr);
    _ = c.FcPatternAddDouble(pattern, c.FC_PIXEL_SIZE, @floatFromInt(size_px));
    _ = c.FcPatternAddInteger(pattern, c.FC_SPACING, c.FC_MONO);
    if (c.FcConfigSubstitute(null, pattern, c.FcMatchPattern) != c.FcTrue)
        return error.FontLoadFailed;
    c.FcDefaultSubstitute(pattern);

    // Sorted candidates: entry 0 is the best match (the primary face),
    // the rest are fallbacks in preference order.
    var result: c.FcResult = undefined;
    const sort_set = c.FcFontSort(null, pattern, c.FcTrue, null, &result) orelse
        return error.FontNotFound;
    errdefer c.FcFontSetDestroy(sort_set);
    if (result != c.FcResultMatch or sort_set.*.nfont < 1) return error.FontNotFound;

    var ft_lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FontLoadFailed;
    errdefer _ = c.FT_Done_FreeType(ft_lib);

    // Faces own their resources once appended; the errdefer below is the
    // single cleanup path for all of them.
    var faces: std.ArrayList(Face) = .empty;
    errdefer {
        for (faces.items) |*f| f.deinit(alloc);
        faces.deinit(alloc);
    }
    {
        var primary = try loadFromPattern(ft_lib, sort_set.*.fonts[0], size_px);
        errdefer primary.deinit(alloc);
        try faces.append(alloc, primary);
    }
    const primary = &faces.items[0];

    // Cell metrics: advance of a reference glyph for width, font-global
    // ascender/descender for height. 26.6 fixed point.
    const metrics = primary.ft_face.*.size.*.metrics;
    const cell_height: u31 = @intCast((metrics.ascender - metrics.descender) >> 6);
    const baseline: u31 = @intCast(metrics.ascender >> 6);
    const cell_width: u31 = width: {
        const idx = c.FT_Get_Char_Index(primary.ft_face, 'M');
        if (idx != 0 and c.FT_Load_Glyph(primary.ft_face, idx, c.FT_LOAD_DEFAULT) == 0) {
            break :width @intCast(primary.ft_face.*.glyph.*.advance.x >> 6);
        }
        break :width @intCast(metrics.max_advance >> 6);
    };

    // The embedded symbols face; not fatal if it somehow fails.
    const embedded_face: ?u16 = embedded: {
        var embedded = Face.loadMemory(ft_lib, embedded_symbols, size_px) catch |err| {
            log.warn("embedded symbols font failed to load: {}", .{err});
            break :embedded null;
        };
        errdefer embedded.deinit(alloc);
        try faces.append(alloc, embedded);
        break :embedded @intCast(faces.items.len - 1);
    };

    log.info("loaded primary face ({s}) cell {d}x{d} baseline {d}, {d} fallback candidates", .{
        family, cell_width, cell_height, baseline, sort_set.*.nfont - 1,
    });

    // Sprite line thickness follows the font's underline thickness
    // (scaled to pixels), with a sane fallback for fonts lacking one.
    const box_thickness: u32 = thickness: {
        const ft_face = primary.ft_face;
        const units: i64 = ft_face.*.underline_thickness;
        if (units > 0) {
            const scaled: i64 = @divTrunc(units * ft_face.*.size.*.metrics.y_scale, 1 << 22);
            if (scaled > 0) break :thickness @intCast(scaled);
        }
        break :thickness @max(1, cell_height / 16);
    };

    return .{
        .ft_lib = ft_lib,
        .faces = faces,
        .sort_set = sort_set,
        .sort_faces = .empty,
        .codepoint_faces = .empty,
        .embedded_face = embedded_face,
        .sprite_glyphs = .empty,
        .sprite_metrics = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .box_thickness = box_thickness,
        },
        .size_px = size_px,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .baseline = baseline,
    };
}

pub fn deinit(self: *Font, alloc: std.mem.Allocator) void {
    for (self.faces.items) |*f| f.deinit(alloc);
    self.faces.deinit(alloc);
    self.sort_faces.deinit(alloc);
    self.codepoint_faces.deinit(alloc);
    var sprite_it = self.sprite_glyphs.valueIterator();
    while (sprite_it.next()) |g| alloc.free(g.bitmap);
    self.sprite_glyphs.deinit(alloc);
    c.FcFontSetDestroy(self.sort_set);
    _ = c.FT_Done_FreeType(self.ft_lib);
    self.* = undefined;
}

pub fn face(self: *Font, index: u16) *Face {
    std.debug.assert(index != sprite_face_index);
    return &self.faces.items[index];
}

/// Rasterize (or fetch from cache) the sprite glyph for `cp`.
pub fn spriteGlyph(self: *Font, alloc: std.mem.Allocator, cp: u21) !*const Glyph {
    const gop = try self.sprite_glyphs.getOrPut(alloc, cp);
    if (gop.found_existing) return gop.value_ptr;
    errdefer _ = self.sprite_glyphs.remove(cp);

    const g = try sprite.render(alloc, cp, self.sprite_metrics, self.baseline);
    gop.value_ptr.* = .{
        .bitmap = g.bitmap,
        .width = g.width,
        .height = g.height,
        .bearing_x = g.bearing_x,
        .bearing_y = g.bearing_y,
    };
    return gop.value_ptr;
}

/// The face to render `cp` with: 0 (primary) when the primary covers it
/// or nothing does, otherwise the embedded symbols face or a
/// lazily-loaded system fallback, in that order. The embedded face wins
/// over system fonts so icons render identically everywhere; it only
/// contains symbols, so it never shadows regular text coverage.
pub fn faceForCodepoint(self: *Font, alloc: std.mem.Allocator, cp: u21) u16 {
    // Sprites override fonts so grid glyphs are always seamless.
    if (sprite.covers(cp)) return sprite_face_index;
    if (self.faces.items[0].hasCodepoint(cp)) return 0;
    if (self.codepoint_faces.get(cp)) |idx| return idx;

    const idx = idx: {
        if (self.embedded_face) |embedded| {
            if (self.faces.items[embedded].hasCodepoint(cp)) break :idx embedded;
        }
        break :idx self.searchFallback(alloc, cp) orelse 0;
    };
    self.codepoint_faces.put(alloc, cp, idx) catch {};
    return idx;
}

/// Walk the fontconfig sort order for the first usable face whose
/// charset covers `cp`.
fn searchFallback(self: *Font, alloc: std.mem.Allocator, cp: u21) ?u16 {
    const nfont: usize = @intCast(self.sort_set.*.nfont);
    // Entry 0 is the primary, already known not to cover cp.
    for (1..nfont) |i| {
        const pattern = self.sort_set.*.fonts[i];
        var charset: ?*c.FcCharSet = null;
        if (c.FcPatternGetCharSet(pattern, c.FC_CHARSET, 0, &charset) != c.FcResultMatch)
            continue;
        if (c.FcCharSetHasChar(charset, cp) != c.FcTrue) continue;

        if (self.sort_faces.get(@intCast(i))) |loaded| {
            if (loaded == failed_face) continue;
            return loaded;
        }

        const new_face = loadFromPattern(self.ft_lib, pattern, self.size_px) catch {
            self.sort_faces.put(alloc, @intCast(i), failed_face) catch {};
            continue;
        };
        const face_idx: u16 = @intCast(self.faces.items.len);
        self.faces.append(alloc, new_face) catch {
            var f = new_face;
            f.deinit(alloc);
            return null;
        };
        self.sort_faces.put(alloc, @intCast(i), face_idx) catch {};
        log.debug("loaded fallback face {d} for U+{X}", .{ face_idx, cp });
        return face_idx;
    }
    return null;
}

fn loadFromPattern(ft_lib: c.FT_Library, pattern: ?*c.FcPattern, size_px: u31) Error!Face {
    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(pattern, c.FC_FILE, 0, &file) != c.FcResultMatch)
        return error.FontNotFound;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(pattern, c.FC_INDEX, 0, &index);
    return Face.load(ft_lib, @ptrCast(file), index, size_px);
}

test "load monospace font and rasterize a glyph" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    try std.testing.expect(font.cell_width > 0);
    try std.testing.expect(font.cell_height >= font.baseline);

    const primary = font.face(0);
    const idx = c.FT_Get_Char_Index(primary.ft_face, 'A');
    try std.testing.expect(idx != 0);
    const g = try primary.glyph(alloc, idx);
    try std.testing.expect(g.width > 0 and g.height > 0);
    // Cached: same pointer on second lookup.
    try std.testing.expectEqual(g, try primary.glyph(alloc, idx));
}

test "embedded symbols face serves nerd font codepoints" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const embedded = font.embedded_face orelse return error.SkipZigTest;

    // Powerline separator and folder icon: Nerd Font staples that a
    // plain monospace primary won't have.
    for ([_]u21{ 0xE0B0, 0xF07B }) |cp| {
        if (font.faces.items[0].hasCodepoint(cp)) continue; // patched primary
        try std.testing.expectEqual(embedded, font.faceForCodepoint(alloc, cp));
        const g = try font.face(embedded).glyph(
            alloc,
            c.FT_Get_Char_Index(font.face(embedded).ft_face, cp),
        );
        try std.testing.expect(g.width > 0 and g.height > 0);
    }
}

test "fallback face for a codepoint the primary lacks" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    // ASCII stays on the primary face.
    try std.testing.expectEqual(@as(u16, 0), font.faceForCodepoint(alloc, 'A'));

    // CJK is almost never in a latin monospace face; expect a fallback
    // if the system has any font covering it (skip otherwise).
    const cp: u21 = 0x4F60; // 你
    if (font.faces.items[0].hasCodepoint(cp)) return error.SkipZigTest;
    const idx = font.faceForCodepoint(alloc, cp);
    if (idx == 0) return error.SkipZigTest; // no coverage on this system

    const fallback = font.face(idx);
    try std.testing.expect(fallback.hasCodepoint(cp));
    // Cached second lookup returns the same face.
    try std.testing.expectEqual(idx, font.faceForCodepoint(alloc, cp));
}
