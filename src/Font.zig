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
/// Procedural sprite glyphs, keyed by codepoint and occupied cell span
/// (metrics are fixed per Font instance, so no size key is needed).
sprite_glyphs: std.AutoHashMapUnmanaged(SpriteGlyphKey, Glyph),
/// Text decoration sprites (underline styles, strikethrough, overline).
decoration_glyphs: std.AutoHashMapUnmanaged(sprite.Decoration, Glyph),
sprite_metrics: sprite.Metrics,
size_px: u31,

/// Fixed cell metrics in pixels, derived from the primary face.
cell_width: u31,
cell_height: u31,
/// Distance from the cell top to the text baseline.
baseline: u31,

pub const Error = error{ FontNotFound, FontLoadFailed, GlyphResizeFailed, OutOfMemory };

/// A single loaded font face with its glyph cache.
pub const Face = struct {
    ft_face: c.FT_Face,
    hb_font: *c.hb_font_t,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph),
    cell_width: u31,
    cell_height: u31,
    baseline: u31,

    fn load(
        ft_lib: c.FT_Library,
        path: [*:0]const u8,
        index: c_int,
        size_px: u31,
        metrics: GlyphMetrics,
    ) Error!Face {
        var ft_face: c.FT_Face = undefined;
        if (c.FT_New_Face(ft_lib, path, index, &ft_face) != 0) return error.FontLoadFailed;
        return fromFtFace(ft_face, size_px, metrics);
    }

    /// `bytes` must outlive the face (fine for @embedFile data).
    fn loadMemory(
        ft_lib: c.FT_Library,
        bytes: []const u8,
        size_px: u31,
        metrics: GlyphMetrics,
    ) Error!Face {
        var ft_face: c.FT_Face = undefined;
        if (c.FT_New_Memory_Face(ft_lib, bytes.ptr, @intCast(bytes.len), 0, &ft_face) != 0)
            return error.FontLoadFailed;
        return fromFtFace(ft_face, size_px, metrics);
    }

    fn fromFtFace(ft_face: c.FT_Face, size_px: u31, metrics: GlyphMetrics) Error!Face {
        errdefer _ = c.FT_Done_Face(ft_face);
        if (c.FT_Set_Pixel_Sizes(ft_face, 0, size_px) != 0) {
            if (!selectNearestStrike(ft_face, size_px)) return error.FontLoadFailed;
        }

        const hb_font = c.hb_ft_font_create_referenced(ft_face) orelse
            return error.FontLoadFailed;

        return .{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .glyphs = .empty,
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
            .baseline = metrics.baseline,
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
    pub fn glyph(
        self: *Face,
        alloc: std.mem.Allocator,
        index: u32,
        constraint_width: u2,
        constrain_alpha: bool,
    ) Error!*const Glyph {
        const key: GlyphKey = .{
            .index = index,
            .constraint_width = constraint_width,
            .constrain_alpha = constrain_alpha,
        };
        const gop = try self.glyphs.getOrPut(alloc, key);
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = self.glyphs.remove(key);

        const load_flags: c.FT_Int32 = @intCast(c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR);
        if (c.FT_Load_Glyph(self.ft_face, index, load_flags) != 0)
            return error.FontLoadFailed;
        if (c.FT_Render_Glyph(self.ft_face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
            return error.FontLoadFailed;

        const slot = self.ft_face.*.glyph;
        const bitmap = slot.*.bitmap;
        const rendered = switch (bitmap.pixel_mode) {
            c.FT_PIXEL_MODE_GRAY => try self.copyGrayBitmap(alloc, bitmap, constraint_width, constrain_alpha),
            c.FT_PIXEL_MODE_BGRA => try self.copyBgraBitmap(alloc, bitmap, constraint_width),
            else => return error.FontLoadFailed,
        };
        errdefer alloc.free(rendered.bitmap);

        const bearing_x, const bearing_y = switch (rendered.format) {
            .alpha => if (rendered.constrained) .{
                rendered.left,
                @as(i32, @intCast(self.baseline)) - rendered.top,
            } else .{
                slot.*.bitmap_left,
                slot.*.bitmap_top,
            },
            .bgra => .{
                rendered.left,
                @as(i32, @intCast(self.baseline)) - rendered.top,
            },
        };

        gop.value_ptr.* = .{
            .bitmap = rendered.bitmap,
            .format = rendered.format,
            .width = rendered.width,
            .height = rendered.height,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
        };
        return gop.value_ptr;
    }

    fn copyGrayBitmap(
        self: *const Face,
        alloc: std.mem.Allocator,
        bitmap: c.FT_Bitmap,
        constraint_width: u2,
        constrain_alpha: bool,
    ) Error!RenderedBitmap {
        const src_width: u31 = @intCast(bitmap.width);
        const src_height: u31 = @intCast(bitmap.rows);
        if (src_width == 0 or src_height == 0) {
            return .{
                .bitmap = try alloc.alloc(u8, 0),
                .format = .alpha,
                .width = 0,
                .height = 0,
            };
        }

        if (!constrain_alpha or constraint_width <= 1) {
            const copy = try alloc.alloc(u8, @as(usize, src_width) * src_height);
            errdefer alloc.free(copy);
            try copyGrayRows(copy, bitmap, src_width, src_height);
            return .{ .bitmap = copy, .format = .alpha, .width = src_width, .height = src_height };
        }

        const available_width = @as(u31, constraint_width) * self.cell_width;
        const target_width = @as(f64, @floatFromInt(available_width)) -
            @as(f64, @floatFromInt(self.cell_width)) * 0.05;
        const target_height: f64 = @floatFromInt(self.cell_height);
        const scale = @min(
            target_width / @as(f64, @floatFromInt(src_width)),
            target_height / @as(f64, @floatFromInt(src_height)),
        );
        const width: u31 = @max(1, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(src_width)) * scale))));
        const height: u31 = @max(1, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(src_height)) * scale))));
        const left: i32 = @intFromFloat(@round(
            (@as(f64, @floatFromInt(available_width)) - @as(f64, @floatFromInt(width))) / 2,
        ));
        const top: i32 = @intFromFloat(@round(
            (@as(f64, @floatFromInt(self.cell_height)) - @as(f64, @floatFromInt(height))) / 2,
        ));

        const copy = try alloc.alloc(u8, @as(usize, width) * height);
        errdefer alloc.free(copy);
        try resizeGrayWithStbir(alloc, copy, width, height, bitmap, src_width, src_height);

        return .{
            .bitmap = copy,
            .format = .alpha,
            .width = width,
            .height = height,
            .left = left,
            .top = top,
            .constrained = true,
        };
    }

    fn copyBgraBitmap(
        self: *const Face,
        alloc: std.mem.Allocator,
        bitmap: c.FT_Bitmap,
        constraint_width: u2,
    ) Error!RenderedBitmap {
        const src_width: u31 = @intCast(bitmap.width);
        const src_height: u31 = @intCast(bitmap.rows);
        if (src_width == 0 or src_height == 0) {
            return .{
                .bitmap = try alloc.alloc(u8, 0),
                .format = .bgra,
                .width = 0,
                .height = 0,
            };
        }

        const available_width = @as(u31, constraint_width) * self.cell_width;
        const target_width = @as(f64, @floatFromInt(available_width)) -
            @as(f64, @floatFromInt(self.cell_width)) * 0.05;
        const target_height: f64 = @floatFromInt(self.cell_height);
        const scale = @min(
            target_width / @as(f64, @floatFromInt(src_width)),
            target_height / @as(f64, @floatFromInt(src_height)),
        );
        const width: u31 = @max(1, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(src_width)) * scale))));
        const height: u31 = @max(1, @as(u31, @intFromFloat(@round(@as(f64, @floatFromInt(src_height)) * scale))));
        const left: i32 = @intFromFloat(@round(
            (@as(f64, @floatFromInt(available_width)) - @as(f64, @floatFromInt(width))) / 2,
        ));
        const top: i32 = @intFromFloat(@round(
            (@as(f64, @floatFromInt(self.cell_height)) - @as(f64, @floatFromInt(height))) / 2,
        ));

        const copy = try alloc.alloc(u8, @as(usize, width) * height * 4);
        errdefer alloc.free(copy);
        try resizeBgraWithStbir(alloc, copy, width, height, bitmap, src_width, src_height);

        return .{
            .bitmap = copy,
            .format = .bgra,
            .width = width,
            .height = height,
            .left = left,
            .top = top,
        };
    }
};

const GlyphKey = struct {
    index: u32,
    constraint_width: u2,
    constrain_alpha: bool,
};

const SpriteGlyphKey = struct {
    cp: u21,
    cell_span: u2,
};

const GlyphMetrics = struct {
    cell_width: u31 = 0,
    cell_height: u31 = 0,
    baseline: u31 = 0,
};

const GlyphFormat = enum { alpha, bgra };

const RenderedBitmap = struct {
    bitmap: []u8,
    format: GlyphFormat,
    width: u31,
    height: u31,
    left: i32 = 0,
    top: i32 = 0,
    constrained: bool = false,
};

/// A rasterized glyph: either an 8-bit coverage bitmap or premultiplied
/// BGRA pixels, plus placement metrics.
/// `bearing_y` is the distance from the baseline up to the bitmap top.
pub const Glyph = struct {
    bitmap: []u8,
    format: GlyphFormat = .alpha,
    width: u31,
    height: u31,
    bearing_x: i32,
    bearing_y: i32,
};

fn selectNearestStrike(ft_face: c.FT_Face, size_px: u31) bool {
    if (!c.FT_HAS_FIXED_SIZES(ft_face) or ft_face.*.num_fixed_sizes <= 0) return false;

    const target: i64 = size_px;
    var best: c_int = 0;
    var best_delta: i64 = std.math.maxInt(i64);
    const sizes = ft_face.*.available_sizes[0..@intCast(ft_face.*.num_fixed_sizes)];
    for (sizes, 0..) |strike, i| {
        const strike_size: i64 = if (strike.width > 0)
            strike.width
        else
            strike.x_ppem >> 6;
        const delta = if (strike_size > target) strike_size - target else target - strike_size;
        if (delta < best_delta) {
            best_delta = delta;
            best = @intCast(i);
        }
    }
    return c.FT_Select_Size(ft_face, best) == 0;
}

fn copyGrayRows(dst: []u8, bitmap: c.FT_Bitmap, width: u31, height: u31) Error!void {
    if (height == 0) return;

    const pitch: usize = @intCast(@abs(bitmap.pitch));
    for (0..height) |y| {
        const src_y = bitmapRow(bitmap, height, y);
        const src = bitmap.buffer[src_y * pitch ..][0..width];
        @memcpy(dst[y * width ..][0..width], src);
    }
}

fn resizeGrayWithStbir(
    alloc: std.mem.Allocator,
    dst: []u8,
    dst_width: u31,
    dst_height: u31,
    bitmap: c.FT_Bitmap,
    src_width: u31,
    src_height: u31,
) Error!void {
    if (dst_height == 0) return;

    const pitch: usize = @intCast(@abs(bitmap.pitch));
    const src, const src_pitch = src: {
        if (bitmap.pitch >= 0) break :src .{ bitmap.buffer, pitch };

        const packed_pitch = @as(usize, src_width);
        const packed_buf = try alloc.alloc(u8, packed_pitch * src_height);
        errdefer alloc.free(packed_buf);
        try copyGrayRows(packed_buf, bitmap, src_width, src_height);
        break :src .{ packed_buf.ptr, packed_pitch };
    };
    defer if (bitmap.pitch < 0) alloc.free(src[0 .. src_pitch * src_height]);

    if (c.stbir_resize_uint8(
        src,
        @intCast(src_width),
        @intCast(src_height),
        @intCast(src_pitch),
        dst.ptr,
        @intCast(dst_width),
        @intCast(dst_height),
        @intCast(dst_width),
        1,
    ) == 0) return error.GlyphResizeFailed;
}

fn resizeBgraWithStbir(
    alloc: std.mem.Allocator,
    dst: []u8,
    dst_width: u31,
    dst_height: u31,
    bitmap: c.FT_Bitmap,
    src_width: u31,
    src_height: u31,
) Error!void {
    if (dst_height == 0) return;

    const pitch: usize = @intCast(@abs(bitmap.pitch));
    const src, const src_pitch = src: {
        if (bitmap.pitch >= 0) break :src .{ bitmap.buffer, pitch };

        const packed_pitch = @as(usize, src_width) * 4;
        const packed_buf = try alloc.alloc(u8, packed_pitch * src_height);
        errdefer alloc.free(packed_buf);
        for (0..src_height) |y| {
            const src_y = bitmapRow(bitmap, src_height, y);
            const from = bitmap.buffer[src_y * pitch ..][0..packed_pitch];
            @memcpy(packed_buf[y * packed_pitch ..][0..packed_pitch], from);
        }
        break :src .{ packed_buf.ptr, packed_pitch };
    };
    defer if (bitmap.pitch < 0) alloc.free(src[0 .. src_pitch * src_height]);

    if (c.stbir_resize_uint8(
        src,
        @intCast(src_width),
        @intCast(src_height),
        @intCast(src_pitch),
        dst.ptr,
        @intCast(dst_width),
        @intCast(dst_height),
        @intCast(@as(usize, dst_width) * 4),
        4,
    ) == 0) return error.GlyphResizeFailed;
}

fn bitmapRow(bitmap: c.FT_Bitmap, height: u31, y: usize) usize {
    return if (bitmap.pitch < 0) height - 1 - y else y;
}

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
        var primary = try loadFromPattern(ft_lib, sort_set.*.fonts[0], size_px, .{});
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
    primary.cell_width = cell_width;
    primary.cell_height = cell_height;
    primary.baseline = baseline;

    // The embedded symbols face; not fatal if it somehow fails.
    const embedded_face: ?u16 = embedded: {
        var embedded = Face.loadMemory(ft_lib, embedded_symbols, size_px, .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline = baseline,
        }) catch |err| {
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

    // Sprite metrics. Line thickness follows the font's underline
    // thickness (scaled to pixels) with a fallback for fonts lacking
    // one; positions are expressed from the cell top, like ghostty.
    const ft_face = primary.ft_face;
    const y_scale: i64 = ft_face.*.size.*.metrics.y_scale;
    const thickness: u32 = thickness: {
        const units: i64 = ft_face.*.underline_thickness;
        if (units > 0) {
            const scaled: i64 = @divTrunc(units * y_scale, 1 << 22);
            if (scaled > 0) break :thickness @intCast(scaled);
        }
        break :thickness @max(1, cell_height / 16);
    };

    // FreeType underline position: relative to baseline, +up.
    const underline_position: u32 = position: {
        const units: i64 = ft_face.*.underline_position;
        const scaled: i64 = @divTrunc(units * y_scale, 1 << 22);
        const top: i64 = baseline - scaled;
        break :position @intCast(std.math.clamp(top, 0, cell_height - thickness));
    };

    // Center the strikethrough on lowercase text (x-height).
    const strikethrough_position: u32 = position: {
        const ex_height: i64 = ex: {
            const idx = c.FT_Get_Char_Index(ft_face, 'x');
            if (idx != 0 and c.FT_Load_Glyph(ft_face, idx, c.FT_LOAD_DEFAULT) == 0) {
                break :ex @intCast(ft_face.*.glyph.*.metrics.horiBearingY >> 6);
            }
            break :ex @divTrunc(@as(i64, cell_height) * 3, 10);
        };
        const top: i64 = baseline - @divTrunc(ex_height + thickness, 2);
        break :position @intCast(std.math.clamp(top, 0, cell_height - thickness));
    };

    return .{
        .ft_lib = ft_lib,
        .faces = faces,
        .sort_set = sort_set,
        .sort_faces = .empty,
        .codepoint_faces = .empty,
        .embedded_face = embedded_face,
        .sprite_glyphs = .empty,
        .decoration_glyphs = .empty,
        .sprite_metrics = .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .box_thickness = thickness,
            .underline_position = underline_position,
            .underline_thickness = thickness,
            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = thickness,
            .overline_position = 0,
            .overline_thickness = thickness,
            .cursor_thickness = thickness,
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
    var deco_it = self.decoration_glyphs.valueIterator();
    while (deco_it.next()) |g| alloc.free(g.bitmap);
    self.decoration_glyphs.deinit(alloc);
    c.FcFontSetDestroy(self.sort_set);
    _ = c.FT_Done_FreeType(self.ft_lib);
    self.* = undefined;
}

pub fn face(self: *Font, index: u16) *Face {
    std.debug.assert(index != sprite_face_index);
    return &self.faces.items[index];
}

/// Rasterize (or fetch from cache) the sprite glyph for `cp`.
pub fn spriteGlyph(
    self: *Font,
    alloc: std.mem.Allocator,
    cp: u21,
    cell_span: u2,
) !*const Glyph {
    std.debug.assert(cell_span >= 1);
    const key: SpriteGlyphKey = .{ .cp = cp, .cell_span = cell_span };
    const gop = try self.sprite_glyphs.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr;
    errdefer _ = self.sprite_glyphs.remove(key);

    const g = try sprite.render(alloc, cp, self.sprite_metrics, self.baseline, cell_span);
    gop.value_ptr.* = .{
        .bitmap = g.bitmap,
        .width = g.width,
        .height = g.height,
        .bearing_x = g.bearing_x,
        .bearing_y = g.bearing_y,
    };
    return gop.value_ptr;
}

/// Rasterize (or fetch from cache) a text decoration sprite.
pub fn decorationGlyph(
    self: *Font,
    alloc: std.mem.Allocator,
    kind: sprite.Decoration,
) !*const Glyph {
    const gop = try self.decoration_glyphs.getOrPut(alloc, kind);
    if (gop.found_existing) return gop.value_ptr;
    errdefer _ = self.decoration_glyphs.remove(kind);

    const g = try sprite.renderDecoration(alloc, kind, self.sprite_metrics, self.baseline);
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
    if (isEmojiCodepoint(cp)) {
        if (self.searchFallbackPass(alloc, cp, true)) |face_idx| return face_idx;
    }
    return self.searchFallbackPass(alloc, cp, false);
}

fn searchFallbackPass(
    self: *Font,
    alloc: std.mem.Allocator,
    cp: u21,
    color_only: bool,
) ?u16 {
    const nfont: usize = @intCast(self.sort_set.*.nfont);
    // Entry 0 is the primary, already known not to cover cp.
    for (1..nfont) |i| {
        const pattern = self.sort_set.*.fonts[i];
        var charset: ?*c.FcCharSet = null;
        if (c.FcPatternGetCharSet(pattern, c.FC_CHARSET, 0, &charset) != c.FcResultMatch)
            continue;
        if (c.FcCharSetHasChar(charset, cp) != c.FcTrue) continue;
        if (color_only and !patternHasColor(pattern)) continue;
        if (self.loadFallbackAt(alloc, i, cp)) |face_idx| return face_idx;
    }
    return null;
}

fn loadFallbackAt(self: *Font, alloc: std.mem.Allocator, sort_index: usize, cp: u21) ?u16 {
    const pattern = self.sort_set.*.fonts[sort_index];

    if (self.sort_faces.get(@intCast(sort_index))) |loaded| {
        if (loaded == failed_face) return null;
        return loaded;
    }

    const new_face = loadFromPattern(self.ft_lib, pattern, self.size_px, .{
        .cell_width = self.cell_width,
        .cell_height = self.cell_height,
        .baseline = self.baseline,
    }) catch {
        self.sort_faces.put(alloc, @intCast(sort_index), failed_face) catch {};
        return null;
    };
    const face_idx: u16 = @intCast(self.faces.items.len);
    self.faces.append(alloc, new_face) catch {
        var f = new_face;
        f.deinit(alloc);
        return null;
    };
    self.sort_faces.put(alloc, @intCast(sort_index), face_idx) catch {};
    log.debug("loaded fallback face {d} for U+{X}", .{ face_idx, cp });
    return face_idx;
}

fn patternHasColor(pattern: ?*c.FcPattern) bool {
    var color: c.FcBool = c.FcFalse;
    return c.FcPatternGetBool(pattern, c.FC_COLOR, 0, &color) == c.FcResultMatch and color == c.FcTrue;
}

fn isEmojiCodepoint(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x2600 and cp <= 0x27BF) or
        cp == 0x00A9 or cp == 0x00AE or cp == 0x2122 or cp == 0x3030 or cp == 0x303D;
}

fn loadFromPattern(
    ft_lib: c.FT_Library,
    pattern: ?*c.FcPattern,
    size_px: u31,
    metrics: GlyphMetrics,
) Error!Face {
    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(pattern, c.FC_FILE, 0, &file) != c.FcResultMatch)
        return error.FontNotFound;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(pattern, c.FC_INDEX, 0, &index);
    return Face.load(ft_lib, @ptrCast(file), index, size_px, metrics);
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
    const g = try primary.glyph(alloc, idx, 1, false);
    try std.testing.expect(g.width > 0 and g.height > 0);
    // Cached: same pointer on second lookup.
    try std.testing.expectEqual(g, try primary.glyph(alloc, idx, 1, false));
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
            1,
            false,
        );
        try std.testing.expect(g.width > 0 and g.height > 0);
    }
}

test "alpha symbols honor double-cell constraints" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const embedded = font.embedded_face orelse return error.SkipZigTest;
    const glyph_face = font.face(embedded);
    const glyph_index = c.FT_Get_Char_Index(glyph_face.ft_face, 0xF07B); // nf-fa-folder
    try std.testing.expect(glyph_index != 0);

    const narrow = try glyph_face.glyph(alloc, glyph_index, 1, false);
    const wide = try glyph_face.glyph(alloc, glyph_index, 2, true);
    try std.testing.expectEqual(GlyphFormat.alpha, narrow.format);
    try std.testing.expectEqual(GlyphFormat.alpha, wide.format);
    try std.testing.expect(wide.width <= font.cell_width * 2);
    try std.testing.expect(wide.height <= font.cell_height);
    try std.testing.expect(wide.width > narrow.width or wide.height > narrow.height);
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

test "color emoji fallback rasterizes as scaled BGRA" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const cp: u21 = 0x1F600; // grinning face
    if (font.faces.items[0].hasCodepoint(cp)) return error.SkipZigTest;
    const idx = font.faceForCodepoint(alloc, cp);
    if (idx == 0) return error.SkipZigTest;

    const fallback = font.face(idx);
    const glyph_index = c.FT_Get_Char_Index(fallback.ft_face, cp);
    try std.testing.expect(glyph_index != 0);
    const g = try fallback.glyph(alloc, glyph_index, 2, false);
    try std.testing.expectEqual(GlyphFormat.bgra, g.format);
    try std.testing.expect(g.width <= font.cell_width * 2);
    try std.testing.expect(g.height <= font.cell_height);
    try std.testing.expect(g.bearing_x >= 0);

    var opaque_pixels: usize = 0;
    var i: usize = 3;
    while (i < g.bitmap.len) : (i += 4) {
        if (g.bitmap[i] != 0) opaque_pixels += 1;
    }
    try std.testing.expect(opaque_pixels > 0);
}
