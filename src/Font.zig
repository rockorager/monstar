//! Monospace font loading, glyph rasterization, and fallback.
//!
//! Uses fontconfig to resolve a family name to a sorted list of candidate
//! fonts, FreeType to rasterize glyphs, and exposes a HarfBuzz font per
//! face for shaping. The primary face defines the cell metrics; fallback
//! faces are loaded lazily (at the same pixel size) when the primary lacks
//! a grapheme cluster, walking the fontconfig sort order and verifying
//! that a candidate's cmap covers every non-ignorable codepoint in the
//! cluster before accepting it.

const Font = @This();

const std = @import("std");
const c = @import("c");
const uucode = @import("uucode");
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
/// Immutable Fontconfig matches shared with other rasterizers at this size.
discovery_data: *Discovery,
/// Primary face index for each style; 0 means fall back to regular.
primary_faces: [style_count]u16,
/// Whether the resolved primary face for each style covers printable ASCII.
/// This makes the common terminal text path avoid repeated FreeType coverage
/// probes without assuming every configured font is well-formed.
primary_ascii: [style_count]bool,
/// styled sort_set index -> faces index (or failed_face).
sort_faces: std.AutoHashMapUnmanaged(SortFaceKey, u16),
/// styled codepoint -> resolved faces index, including primary hits.
codepoint_faces: std.AutoHashMapUnmanaged(CodepointFaceKey, u16),
/// styled multi-codepoint cluster -> resolved faces index; keys own
/// their codepoint slices.
cluster_faces: std.HashMapUnmanaged(ClusterFaceKey, u16, ClusterFaceContext, std.hash_map.default_max_load_percentage),
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

pub const FaceStyle = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn init(bold: bool, italic: bool) FaceStyle {
        return if (bold)
            if (italic) .bold_italic else .bold
        else if (italic) .italic else .regular;
    }

    fn weight(self: FaceStyle) ?c_int {
        return switch (self) {
            .regular, .italic => null,
            .bold, .bold_italic => c.FC_WEIGHT_BOLD,
        };
    }

    fn slant(self: FaceStyle) ?c_int {
        return switch (self) {
            .regular, .bold => null,
            .italic, .bold_italic => c.FC_SLANT_ITALIC,
        };
    }
};

const style_count = std.meta.fields(FaceStyle).len;

/// Immutable Fontconfig results. Rasterizers need independent FreeType,
/// HarfBuzz, and glyph-cache state, but can safely share these read-only
/// candidate lists instead of repeating font discovery.
pub const Discovery = struct {
    refs: std.atomic.Value(usize),
    family: [:0]u8,
    size_px: u31,
    sort_sets: [style_count]*c.FcFontSet,

    fn init(family: [:0]const u8, size_px: u31) Error!*Discovery {
        if (c.FcInit() != c.FcTrue) return error.FontLoadFailed;

        var sort_sets_opt: [style_count]?*c.FcFontSet = @splat(null);
        errdefer {
            for (sort_sets_opt) |sort_set| {
                if (sort_set) |set| c.FcFontSetDestroy(set);
            }
        }
        inline for (std.meta.fields(FaceStyle)) |field| {
            const style: FaceStyle = @enumFromInt(field.value);
            sort_sets_opt[field.value] = try fontSort(family, size_px, style);
        }
        var sort_sets: [style_count]*c.FcFontSet = undefined;
        for (sort_sets_opt, 0..) |sort_set, i| sort_sets[i] = sort_set.?;

        const alloc = std.heap.smp_allocator;
        const family_copy = try alloc.dupeZ(u8, family);
        errdefer alloc.free(family_copy);
        const self = try alloc.create(Discovery);
        self.* = .{
            .refs = .init(1),
            .family = family_copy,
            .size_px = size_px,
            .sort_sets = sort_sets,
        };
        return self;
    }

    pub fn ref(self: *Discovery) void {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    pub fn unref(self: *Discovery) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;

        for (self.sort_sets) |sort_set| c.FcFontSetDestroy(sort_set);
        const alloc = std.heap.smp_allocator;
        alloc.free(self.family);
        alloc.destroy(self);
    }
};

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
        const rendered = if (bitmap.width == 0 or bitmap.rows == 0) RenderedBitmap{
            .bitmap = try alloc.alloc(u8, 0),
            .format = .alpha,
            .width = 0,
            .height = 0,
        } else switch (bitmap.pixel_mode) {
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
            .fully_opaque = rendered.format == .alpha and alphaBitmapOpaque(rendered.bitmap),
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

        if (!constrain_alpha) {
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

        // Ghostty's fallback symbol constraint is `.fit`: the extra cell is
        // permission to avoid clipping oversized symbols, not a request to
        // grow normal Nerd Font icons to fill the two-cell box.
        if (scale >= 1.0) {
            const copy = try alloc.alloc(u8, @as(usize, src_width) * src_height);
            errdefer alloc.free(copy);
            try copyGrayRows(copy, bitmap, src_width, src_height);
            return .{ .bitmap = copy, .format = .alpha, .width = src_width, .height = src_height };
        }

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

const SortFaceKey = struct {
    style: FaceStyle,
    sort_index: u32,
};

const CodepointFaceKey = struct {
    style: FaceStyle,
    cp: u21,
};

const ClusterFaceKey = struct {
    style: FaceStyle,
    cps: []const u21,
};

const ClusterFaceContext = struct {
    pub fn hash(_: ClusterFaceContext, key: ClusterFaceKey) u64 {
        var hasher = std.hash.Wyhash.init(@intFromEnum(key.style));
        hasher.update(std.mem.sliceAsBytes(key.cps));
        return hasher.final();
    }

    pub fn eql(_: ClusterFaceContext, a: ClusterFaceKey, b: ClusterFaceKey) bool {
        return a.style == b.style and std.mem.eql(u21, a.cps, b.cps);
    }
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
    /// Every A8 sample is fully covered, so the renderer can replace
    /// per-pixel alpha blending with a clipped rectangle fill.
    fully_opaque: bool = false,
    width: u31,
    height: u31,
    bearing_x: i32,
    bearing_y: i32,
};

fn alphaBitmapOpaque(bitmap: []const u8) bool {
    if (bitmap.len == 0) return false;
    for (bitmap) |coverage| {
        if (coverage != 0xff) return false;
    }
    return true;
}

test "classify fully opaque alpha bitmap" {
    try std.testing.expect(!alphaBitmapOpaque(&.{}));
    try std.testing.expect(alphaBitmapOpaque(&.{ 0xff, 0xff, 0xff }));
    try std.testing.expect(!alphaBitmapOpaque(&.{ 0xff, 0xfe, 0xff }));
}

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

fn fontSort(family: [:0]const u8, size_px: u31, style: FaceStyle) Error!*c.FcFontSet {
    const pattern = c.FcPatternCreate() orelse return error.FontLoadFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, family.ptr);
    _ = c.FcPatternAddDouble(pattern, c.FC_PIXEL_SIZE, @floatFromInt(size_px));
    _ = c.FcPatternAddInteger(pattern, c.FC_SPACING, c.FC_MONO);
    if (style.weight()) |weight| _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, weight);
    if (style.slant()) |slant| _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, slant);
    if (c.FcConfigSubstitute(null, pattern, c.FcMatchPattern) != c.FcTrue)
        return error.FontLoadFailed;
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const sort_set = c.FcFontSort(null, pattern, c.FcTrue, null, &result) orelse
        return error.FontNotFound;
    errdefer c.FcFontSetDestroy(sort_set);
    if (result != c.FcResultMatch or sort_set.*.nfont < 1) return error.FontNotFound;
    return sort_set;
}

fn loadPrimaryStyle(
    alloc: std.mem.Allocator,
    faces: *std.ArrayList(Face),
    ft_lib: c.FT_Library,
    sort_sets: [style_count]*c.FcFontSet,
    style: FaceStyle,
    size_px: u31,
    metrics: GlyphMetrics,
) ?u16 {
    const regular = sort_sets[@intFromEnum(FaceStyle.regular)].*.fonts[0];
    const styled = sort_sets[@intFromEnum(style)].*.fonts[0];
    if (samePatternFace(regular, styled)) return null;

    const new_face = loadFromPattern(ft_lib, styled, size_px, metrics) catch return null;
    const face_idx: u16 = @intCast(faces.items.len);
    faces.append(alloc, new_face) catch {
        var f = new_face;
        f.deinit(alloc);
        return null;
    };
    return face_idx;
}

fn samePatternFace(a: ?*c.FcPattern, b: ?*c.FcPattern) bool {
    var a_file: [*c]c.FcChar8 = undefined;
    var b_file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(a, c.FC_FILE, 0, &a_file) != c.FcResultMatch) return false;
    if (c.FcPatternGetString(b, c.FC_FILE, 0, &b_file) != c.FcResultMatch) return false;
    var a_index: c_int = 0;
    var b_index: c_int = 0;
    _ = c.FcPatternGetInteger(a, c.FC_INDEX, 0, &a_index);
    _ = c.FcPatternGetInteger(b, c.FC_INDEX, 0, &b_index);
    return a_index == b_index and std.mem.orderZ(u8, @ptrCast(a_file), @ptrCast(b_file)) == .eq;
}

/// Load the best match for `family` (e.g. "monospace") at `size_px`.
pub fn init(alloc: std.mem.Allocator, family: [:0]const u8, size_px: u31) Error!Font {
    std.debug.assert(size_px > 0);

    const discovery_data = try Discovery.init(family, size_px);
    defer discovery_data.unref();
    return initWithDiscovery(alloc, discovery_data);
}

/// Build independent raster state from an existing immutable discovery.
/// The returned Font retains `discovery_data`.
pub fn initWithDiscovery(alloc: std.mem.Allocator, discovery_data: *Discovery) Error!Font {
    discovery_data.ref();
    errdefer discovery_data.unref();
    const sort_sets = discovery_data.sort_sets;
    const size_px = discovery_data.size_px;

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
        var primary = try loadFromPattern(ft_lib, sort_sets[@intFromEnum(FaceStyle.regular)].*.fonts[0], size_px, .{});
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

    var primary_faces: [style_count]u16 = @splat(0);
    inline for (std.meta.fields(FaceStyle)) |field| {
        const style: FaceStyle = @enumFromInt(field.value);
        if (style == .regular) continue;
        if (loadPrimaryStyle(alloc, &faces, ft_lib, sort_sets, style, size_px, .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .baseline = baseline,
        })) |idx| {
            primary_faces[field.value] = idx;
        }
    }
    var primary_ascii: [style_count]bool = undefined;
    inline for (std.meta.fields(FaceStyle)) |field| {
        const style: FaceStyle = @enumFromInt(field.value);
        const face_idx = primary_faces[@intFromEnum(style)];
        primary_ascii[field.value] = faceCoversPrintableAscii(&faces.items[face_idx]);
    }

    log.info("loaded primary face ({s}) cell {d}x{d} baseline {d}, {d} fallback candidates", .{
        discovery_data.family,
        cell_width,
        cell_height,
        baseline,
        sort_sets[@intFromEnum(FaceStyle.regular)].*.nfont - 1,
    });

    // Sprite metrics. Line thickness follows the font's underline
    // thickness (scaled to pixels) with a fallback for fonts lacking
    // one; positions are expressed from the cell top, like ghostty.
    const ft_face = faces.items[0].ft_face;
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
        .discovery_data = discovery_data,
        .primary_faces = primary_faces,
        .primary_ascii = primary_ascii,
        .sort_faces = .empty,
        .codepoint_faces = .empty,
        .cluster_faces = .empty,
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
    var cluster_keys = self.cluster_faces.keyIterator();
    while (cluster_keys.next()) |key| alloc.free(key.cps);
    self.cluster_faces.deinit(alloc);
    var sprite_it = self.sprite_glyphs.valueIterator();
    while (sprite_it.next()) |g| alloc.free(g.bitmap);
    self.sprite_glyphs.deinit(alloc);
    var deco_it = self.decoration_glyphs.valueIterator();
    while (deco_it.next()) |g| alloc.free(g.bitmap);
    self.decoration_glyphs.deinit(alloc);
    _ = c.FT_Done_FreeType(self.ft_lib);
    self.discovery_data.unref();
    self.* = undefined;
}

pub fn discovery(self: *const Font) *Discovery {
    return self.discovery_data;
}

pub fn face(self: *Font, index: u16) *Face {
    std.debug.assert(index != sprite_face_index);
    return &self.faces.items[index];
}

fn faceCoversPrintableAscii(candidate: *const Face) bool {
    for (0x20..0x7f) |cp| {
        if (!candidate.hasCodepoint(@intCast(cp))) return false;
    }
    return true;
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
        .fully_opaque = alphaBitmapOpaque(g.bitmap),
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
        .fully_opaque = alphaBitmapOpaque(g.bitmap),
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
    return self.faceForCluster(alloc, &.{cp}, .regular);
}

/// Codepoints per cluster the coverage requirement tracks; longer
/// pathological clusters keep their leading codepoints, which only
/// weakens verification, never rejects a usable face.
const max_cluster_codepoints = 15;

/// Coverage requirements and emoji-presentation signals derived from one
/// grapheme cluster's codepoints.
const ClusterInfo = struct {
    /// Codepoints the chosen face must map. Joiners and variation
    /// selectors are excluded: HarfBuzz hides unsupported
    /// default-ignorables instead of emitting .notdef.
    required: [max_cluster_codepoints]u21,
    required_len: usize,
    /// VS16, keycap, or a ZWJ emoji sequence: the cluster explicitly asks
    /// for emoji presentation, so color faces win over the primary even
    /// when the primary covers the base (text-style hearts, keycap digits).
    explicit_emoji: bool,
    /// The base codepoint defaults to emoji presentation: color faces are
    /// preferred over other fallbacks, but a covering primary still wins.
    default_emoji: bool,

    fn init(cps: []const u21) ClusterInfo {
        std.debug.assert(cps.len > 0);
        var info: ClusterInfo = .{
            .required = undefined,
            .required_len = 0,
            .explicit_emoji = false,
            .default_emoji = hasDefaultEmojiPresentation(cps[0]),
        };
        var force_text = false;
        var has_zwj = false;
        for (cps) |cp| {
            switch (cp) {
                0xFE0E => force_text = true,
                0xFE0F => info.explicit_emoji = true,
                0x200D => has_zwj = true,
                0x20E3 => info.explicit_emoji = info.explicit_emoji or isKeycapBase(cps[0]),
                else => {},
            }
            if (isCoverageExempt(cp)) continue;
            if (info.required_len < info.required.len) {
                info.required[info.required_len] = cp;
                info.required_len += 1;
            }
        }
        if (has_zwj and !info.explicit_emoji) {
            for (cps) |cp| {
                if (hasDefaultEmojiPresentation(cp)) {
                    info.explicit_emoji = true;
                    break;
                }
            }
        }
        if (force_text) {
            info.explicit_emoji = false;
            info.default_emoji = false;
        }
        return info;
    }

    fn requiredSlice(self: *const ClusterInfo) []const u21 {
        return self.required[0..self.required_len];
    }
};

fn isKeycapBase(cp: u21) bool {
    return switch (cp) {
        '0'...'9', '#', '*' => true,
        else => false,
    };
}

/// Codepoints a face need not map to render a cluster: HarfBuzz treats
/// them as default-ignorable and hides them when the font lacks them.
fn isCoverageExempt(cp: u21) bool {
    return switch (cp) {
        0x200C,
        0x200D, // zero-width (non-)joiner
        0x180B...0x180D, // Mongolian variation selectors
        0xFE00...0xFE0F, // variation selectors
        0xE0100...0xE01EF, // variation selectors supplement
        => true,
        else => false,
    };
}

/// Walks fallback candidates for one grapheme cluster in preference order,
/// yielding only faces whose actual cmap covers every required codepoint.
/// Used for initial face resolution and for re-resolving clusters that
/// shaped to .notdef; never yields the same face twice.
pub const ClusterCandidates = struct {
    font: *Font,
    style: FaceStyle,
    info: ClusterInfo,
    stage: Stage,
    sort_index: usize = 0,
    returned: [max_returned]u16 = undefined,
    returned_len: usize = 0,

    /// Distinct faces one resolution can reasonably visit; later
    /// duplicates slip through, which callers bound with attempt limits.
    const max_returned = 8;

    const Stage = enum { color_front, styled_primary, primary, embedded, color, any, done };

    pub fn next(self: *ClusterCandidates, alloc: std.mem.Allocator) ?u16 {
        while (true) {
            switch (self.stage) {
                .color_front => {
                    if (self.nextSortCandidate(alloc, true)) |idx| {
                        if (self.take(idx)) |taken| return taken;
                    } else {
                        self.stage = .styled_primary;
                        self.sort_index = 0;
                    }
                },
                .styled_primary => {
                    self.stage = .primary;
                    const idx = self.font.primary_faces[@intFromEnum(self.style)];
                    if (idx != 0 and self.covers(idx)) {
                        if (self.take(idx)) |taken| return taken;
                    }
                },
                .primary => {
                    self.stage = .embedded;
                    if (self.covers(0)) {
                        if (self.take(0)) |taken| return taken;
                    }
                },
                .embedded => {
                    self.stage = if (self.info.default_emoji and !self.info.explicit_emoji) .color else .any;
                    if (self.font.embedded_face) |idx| {
                        if (self.covers(idx)) {
                            if (self.take(idx)) |taken| return taken;
                        }
                    }
                },
                .color => {
                    if (self.nextSortCandidate(alloc, true)) |idx| {
                        if (self.take(idx)) |taken| return taken;
                    } else {
                        self.stage = .any;
                        self.sort_index = 0;
                    }
                },
                .any => {
                    if (self.nextSortCandidate(alloc, false)) |idx| {
                        if (self.take(idx)) |taken| return taken;
                    } else {
                        self.stage = .done;
                    }
                },
                .done => return null,
            }
        }
    }

    fn take(self: *ClusterCandidates, idx: u16) ?u16 {
        for (self.returned[0..self.returned_len]) |seen| {
            if (seen == idx) return null;
        }
        if (self.returned_len < self.returned.len) {
            self.returned[self.returned_len] = idx;
            self.returned_len += 1;
        }
        return idx;
    }

    fn covers(self: *const ClusterCandidates, idx: u16) bool {
        return self.font.faceCoversAll(idx, self.info.requiredSlice());
    }

    fn nextSortCandidate(self: *ClusterCandidates, alloc: std.mem.Allocator, color_only: bool) ?u16 {
        const font = self.font;
        const sort_set = font.discovery_data.sort_sets[@intFromEnum(self.style)];
        const nfont: usize = @intCast(sort_set.*.nfont);
        const start: usize = if (self.style == .regular) 1 else 0;
        var i: usize = @max(self.sort_index, start);
        while (i < nfont) : (i += 1) {
            const pattern = sort_set.*.fonts[i];
            if (color_only and !patternHasColor(pattern)) continue;
            if (!patternCoversAll(pattern, self.info.requiredSlice())) continue;
            const idx = font.loadFallbackAt(alloc, self.style, i) orelse continue;
            // The fontconfig charset can drift from the font file on
            // disk; trust only the loaded face's cmap.
            if (!font.faceCoversAll(idx, self.info.requiredSlice())) continue;
            self.sort_index = i + 1;
            return idx;
        }
        self.sort_index = nfont;
        return null;
    }
};

/// Candidate faces for a cluster, in fallback preference order.
pub fn clusterCandidates(self: *Font, cps: []const u21, style: FaceStyle) ClusterCandidates {
    const info: ClusterInfo = .init(cps);
    return .{
        .font = self,
        .style = style,
        .info = info,
        .stage = if (info.explicit_emoji) .color_front else .styled_primary,
    };
}

/// Like `faceForCodepoint` for a whole grapheme cluster (base codepoint
/// first): the chosen face must cover every non-ignorable codepoint, so
/// combining marks and ZWJ-sequence participants never shape to .notdef,
/// and emoji-presentation signals prefer color faces.
pub fn faceForCluster(self: *Font, alloc: std.mem.Allocator, cps: []const u21, style: FaceStyle) u16 {
    std.debug.assert(cps.len > 0);
    const primary_idx = self.primary_faces[@intFromEnum(style)];
    const base = cps[0];
    if (cps.len == 1 and base >= 0x20 and base < 0x7f and self.primary_ascii[@intFromEnum(style)])
        return primary_idx;

    const info: ClusterInfo = .init(cps);

    // Sprites override fonts so grid glyphs are always seamless; an
    // explicit emoji presentation defers to a color face instead. There
    // are no printable ASCII sprites, so the text path above never pays
    // for this range lookup.
    if (sprite.covers(base) and !info.explicit_emoji) return sprite_face_index;

    if (info.required_len == 0) return primary_idx;

    if (cps.len == 1) {
        const key: CodepointFaceKey = .{ .style = style, .cp = base };
        if (self.codepoint_faces.get(key)) |idx| return idx;
        const idx = self.resolveCluster(alloc, info, style);
        self.codepoint_faces.put(alloc, key, idx) catch {};
        return idx;
    }

    const key: ClusterFaceKey = .{ .style = style, .cps = cps };
    if (self.cluster_faces.getContext(key, .{})) |idx| return idx;
    const idx = self.resolveCluster(alloc, info, style);
    if (alloc.dupe(u21, cps)) |owned| {
        self.cluster_faces.putContext(alloc, .{ .style = style, .cps = owned }, idx, .{}) catch alloc.free(owned);
    } else |_| {}
    return idx;
}

/// First covering candidate, or 0 (primary) when nothing covers the
/// cluster and the primary's .notdef is the honest result.
fn resolveCluster(self: *Font, alloc: std.mem.Allocator, info: ClusterInfo, style: FaceStyle) u16 {
    var candidates: ClusterCandidates = .{
        .font = self,
        .style = style,
        .info = info,
        .stage = if (info.explicit_emoji) .color_front else .styled_primary,
    };
    return candidates.next(alloc) orelse 0;
}

fn faceCoversAll(self: *const Font, idx: u16, cps: []const u21) bool {
    const candidate = &self.faces.items[idx];
    for (cps) |cp| {
        if (!candidate.hasCodepoint(cp)) return false;
    }
    return true;
}

fn patternCoversAll(pattern: ?*c.FcPattern, cps: []const u21) bool {
    var charset: ?*c.FcCharSet = null;
    if (c.FcPatternGetCharSet(pattern, c.FC_CHARSET, 0, &charset) != c.FcResultMatch)
        return false;
    for (cps) |cp| {
        if (c.FcCharSetHasChar(charset, cp) != c.FcTrue) return false;
    }
    return true;
}

fn loadFallbackAt(
    self: *Font,
    alloc: std.mem.Allocator,
    style: FaceStyle,
    sort_index: usize,
) ?u16 {
    const pattern = self.discovery_data.sort_sets[@intFromEnum(style)].*.fonts[sort_index];
    const key: SortFaceKey = .{ .style = style, .sort_index = @intCast(sort_index) };

    if (self.sort_faces.get(key)) |loaded| {
        if (loaded == failed_face) return null;
        return loaded;
    }

    const new_face = loadFromPattern(self.ft_lib, pattern, self.size_px, .{
        .cell_width = self.cell_width,
        .cell_height = self.cell_height,
        .baseline = self.baseline,
    }) catch {
        self.sort_faces.put(alloc, key, failed_face) catch {};
        return null;
    };
    const face_idx: u16 = @intCast(self.faces.items.len);
    self.faces.append(alloc, new_face) catch {
        var f = new_face;
        f.deinit(alloc);
        return null;
    };
    self.sort_faces.put(alloc, key, face_idx) catch {};
    log.debug("loaded fallback face {d} (sort {d}, {})", .{ face_idx, sort_index, style });
    return face_idx;
}

fn patternHasColor(pattern: ?*c.FcPattern) bool {
    var color: c.FcBool = c.FcFalse;
    return c.FcPatternGetBool(pattern, c.FC_COLOR, 0, &color) == c.FcResultMatch and color == c.FcTrue;
}

pub fn hasDefaultEmojiPresentation(cp: u21) bool {
    return uucode.get(.is_emoji_presentation, cp);
}

test "default emoji presentation uses Unicode data" {
    try std.testing.expect(hasDefaultEmojiPresentation(0x1F600)); // 😀
    try std.testing.expect(hasDefaultEmojiPresentation(0x2B1B)); // ⬛
    try std.testing.expect(!hasDefaultEmojiPresentation(0x2600)); // ☀ defaults to text
    try std.testing.expect(!hasDefaultEmojiPresentation('A'));
}

test "cluster info derives coverage requirements and emoji signals" {
    const keycap: ClusterInfo = .init(&.{ '1', 0xFE0F, 0x20E3 });
    try std.testing.expect(keycap.explicit_emoji);
    try std.testing.expectEqualSlices(u21, &.{ '1', 0x20E3 }, keycap.requiredSlice());

    const zwj: ClusterInfo = .init(&.{ 0x2764, 0xFE0F, 0x200D, 0x1F525 }); // heart on fire
    try std.testing.expect(zwj.explicit_emoji);
    try std.testing.expectEqualSlices(u21, &.{ 0x2764, 0x1F525 }, zwj.requiredSlice());

    // VS15 forces text presentation even for default-emoji codepoints.
    const text_star: ClusterInfo = .init(&.{ 0x2B50, 0xFE0E });
    try std.testing.expect(!text_star.explicit_emoji);
    try std.testing.expect(!text_star.default_emoji);
    try std.testing.expectEqualSlices(u21, &.{0x2B50}, text_star.requiredSlice());

    // Combining marks are required coverage, not exempt.
    const marks: ClusterInfo = .init(&.{ 'e', 0x0301 });
    try std.testing.expect(!marks.explicit_emoji);
    try std.testing.expectEqualSlices(u21, &.{ 'e', 0x0301 }, marks.requiredSlice());
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

test "rasterizers share discovery but own face state" {
    const alloc = std.testing.allocator;
    var first: Font = try .init(alloc, "monospace", 16);
    var first_live = true;
    defer if (first_live) first.deinit(alloc);
    var second: Font = try .initWithDiscovery(alloc, first.discovery());
    defer second.deinit(alloc);

    try std.testing.expectEqual(first.discovery(), second.discovery());
    try std.testing.expect(first.ft_lib != second.ft_lib);
    try std.testing.expect(first.face(0).ft_face != second.face(0).ft_face);

    // The shared result remains valid after the font that discovered it goes
    // away, as when a config reload races a deferred raster load.
    first.deinit(alloc);
    first_live = false;
    try std.testing.expect(c.FT_Get_Char_Index(second.face(0).ft_face, 'A') != 0);
}

test "styled primary faces are selected when available" {
    try std.testing.expectEqual(FaceStyle.bold, FaceStyle.init(true, false));
    try std.testing.expectEqual(FaceStyle.italic, FaceStyle.init(false, true));
    try std.testing.expectEqual(FaceStyle.bold_italic, FaceStyle.init(true, true));

    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const bold_idx = font.primary_faces[@intFromEnum(FaceStyle.bold)];
    if (bold_idx == 0) return error.SkipZigTest;
    try std.testing.expectEqual(bold_idx, font.faceForCluster(alloc, &.{'A'}, .bold));
}

test "embedded symbols face serves nerd font codepoints" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const embedded = font.embedded_face orelse return error.SkipZigTest;

    // Powerline separator and folder icon: Nerd Font staples that a
    // plain monospace primary won't have.
    for ([_]u21{ 0xE0B0, 0xF07B }) |cp| {
        if (sprite.covers(cp)) continue; // sprites intentionally override fonts
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

test "alpha symbols do not upscale for double-cell constraints" {
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
    try std.testing.expectEqual(narrow.width, wide.width);
    try std.testing.expectEqual(narrow.height, wide.height);
}

test "alpha symbols fit within single-cell constraints" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    const embedded = font.embedded_face orelse return error.SkipZigTest;
    const glyph_face = font.face(embedded);
    const glyph_index = c.FT_Get_Char_Index(glyph_face.ft_face, 0xF07B); // nf-fa-folder
    try std.testing.expect(glyph_index != 0);

    const unconstrained = try glyph_face.glyph(alloc, glyph_index, 1, false);
    const constrained = try glyph_face.glyph(alloc, glyph_index, 1, true);
    try std.testing.expectEqual(GlyphFormat.alpha, constrained.format);
    try std.testing.expect(constrained.width <= font.cell_width);
    try std.testing.expect(constrained.height <= font.cell_height);
    try std.testing.expect(constrained.width <= unconstrained.width);
    try std.testing.expect(constrained.height <= unconstrained.height);
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
