//! Renders a ghostty-vt RenderState into an ARGB8888 pixel buffer.
//!
//! Per row: a background pass fills cell backgrounds, then text runs of
//! equal style are shaped with HarfBuzz and the resulting glyphs are
//! alpha-blended at their cells. Glyph clusters are snapped to their cell
//! origin so the grid stays aligned while ligatures still work.

const Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");
const Font = @import("Font.zig");

const log = std.log.scoped(.renderer);
const KittyImage = vt.kitty.graphics.Image;
const KittyPlacement = vt.kitty.graphics.ImageStorage.Placement;
const KittyRenderPlacement = vt.kitty.graphics.RenderPlacement;
const kitty_placeholder = vt.kitty.graphics.unicode.placeholder;

alloc: std.mem.Allocator,
font: *Font,
hb_buf: *c.hb_buffer_t,
/// Selection colors; a null foreground uses the default foreground.
selection_bg: vt.color.RGB,
selection_fg: ?vt.color.RGB,
/// Highlight colors for the selected scrollback-search match.
search_bg: vt.color.RGB,
search_fg: vt.color.RGB,
/// Explicit text color under a focused block cursor. Null preserves the
/// terminal background fallback.
cursor_text: ?vt.color.RGB,
/// Alpha applied only to the default terminal background and window padding.
/// Explicit cell backgrounds, selections, cursors, and foregrounds stay opaque.
background_alpha: u8,
/// Keyboard focus: unfocused windows draw the cursor as a hollow
/// rectangle regardless of the requested style. Set by the caller.
focused: bool = true,
/// When true, OSC 8 hyperlink cells get an underline affordance.
hyperlink_hints: bool = false,
/// Hovered automatically detected link, in viewport cell coordinates.
link_range: ?LinkRange = null,
/// Selected scrollback-search match, in viewport cell coordinates.
search_range: ?LinkRange = null,
/// Per-cell resolved foreground colors for the row being rendered.
fg_scratch: std.ArrayList(vt.color.RGB),
/// Per-cell font face indices for the row being rendered.
face_scratch: std.ArrayList(u16),
/// Per-cell reverse-video state for color glyphs, including block cursor.
reverse_scratch: std.ArrayList(bool),
/// Per-row flag: the row's last render blitted ink above its own
/// pixel strip (accented capitals exceed the font ascender in many
/// fonts). renderDirty repaints a dirty row's neighbors only when
/// these bits demand it. Descender overshoot is not tracked: rows
/// render top to bottom, so ink below a row's strip has never
/// survived a neighboring repaint.
row_overhang: std.DynamicBitSetUnmanaged,
/// Whether the row currently being rendered blitted above its strip.
overhang_scratch: bool = false,
/// The rows the last renderDirty call actually repainted, for the
/// caller's damage bookkeeping.
repainted: std.DynamicBitSetUnmanaged,
/// Shaped-run cache: HarfBuzz output keyed by face and run content
/// (codepoints with run-relative clusters), so repeated text shapes
/// once no matter where it appears on screen. Cleared wholesale when
/// full and on font changes.
shape_cache: std.StringHashMapUnmanaged([]ShapedGlyph),
/// Scratch for the current run's cache key.
shape_key: std.ArrayList(u32),
/// Scratch codepoints for cluster-width measurement of overlay text.
codepoint_scratch: std.ArrayList(u21),
/// Scratch codepoints for per-cell grapheme cluster face resolution.
cluster_scratch: std.ArrayList(u21),
/// Shape cache counters for benchmarks/profiling. Production rendering does
/// not read these, so they stay deliberately cheap and approximate.
shape_stats: ShapeStats = .{},
/// Final RGBA bytes for scaled Kitty variants. Unlike the terminal-owned
/// source data, these remain valid across renders of the long-lived worker.
kitty_scale_cache: std.AutoHashMapUnmanaged(KittyScaleKey, []u8),
kitty_scale_cache_bytes: usize = 0,
/// Private observable for the focused cache test and profiling.
kitty_scale_count: usize = 0,
/// Physical framebuffer row stride. Zero means the visible width, which is
/// convenient for standalone renderer tests and tightly packed buffers.
buffer_stride: u31 = 0,

/// Shape cache entry limit; at ~300 bytes per typical entry the cache
/// tops out around a few megabytes before it resets.
const shape_cache_max_entries = 8192;
const kitty_scale_cache_max_entries = 32;
const kitty_scale_cache_max_bytes = 32 * 1024 * 1024;

const KittyScaleKey = struct {
    image_id: u32,
    generation: u64,
    format: @FieldType(KittyImage, "format"),
    image_width: u32,
    image_height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    dest_width: u32,
    dest_height: u32,
};

/// One glyph of a shaped run, positions already in pixels.
const ShapedGlyph = struct {
    glyph: u32,
    /// Cell offset from the run start.
    cluster: u32,
    /// Face the glyph index belongs to. Usually the run's face; differs
    /// for clusters that shaped to .notdef and were repaired against a
    /// further fallback candidate.
    face: u16,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

/// Fallback candidates tried when a cluster shapes to .notdef before
/// accepting the tofu box.
const max_notdef_retries = 3;

pub const InitOptions = struct {
    selection_background: ?vt.color.RGB = null,
    selection_foreground: ?vt.color.RGB = null,
    cursor_text: ?vt.color.RGB = null,
    background_alpha: u8 = 255,
};

pub const ShapeStats = struct {
    cache_hits: usize = 0,
    cache_misses: usize = 0,
    shaped_cells: usize = 0,
    cache_clears: usize = 0,
};

pub const LinkRange = struct {
    start: vt.Coordinate,
    end: vt.Coordinate,

    fn contains(self: LinkRange, x: usize, y: u31) bool {
        if (y < self.start.y or y > self.end.y) return false;
        if (self.start.y == self.end.y) {
            return x >= self.start.x and x <= self.end.x;
        }
        if (y == self.start.y) return x >= self.start.x;
        if (y == self.end.y) return x <= self.end.x;
        return true;
    }
};

pub fn init(alloc: std.mem.Allocator, font: *Font, opts: InitOptions) !Renderer {
    const hb_buf = c.hb_buffer_create() orelse return error.OutOfMemory;
    if (c.hb_buffer_allocation_successful(hb_buf) == 0) return error.OutOfMemory;
    return .{
        .alloc = alloc,
        .font = font,
        .hb_buf = hb_buf,
        .selection_bg = opts.selection_background orelse Config.dark_theme.selection_background,
        .selection_fg = opts.selection_foreground,
        .search_bg = Config.dark_theme.copy_highlight,
        .search_fg = Config.dark_theme.copy_highlight_foreground,
        .cursor_text = opts.cursor_text,
        .background_alpha = opts.background_alpha,
        .fg_scratch = .empty,
        .face_scratch = .empty,
        .reverse_scratch = .empty,
        .row_overhang = .{},
        .repainted = .{},
        .shape_cache = .empty,
        .shape_key = .empty,
        .codepoint_scratch = .empty,
        .cluster_scratch = .empty,
        .shape_stats = .{},
        .kitty_scale_cache = .empty,
        .buffer_stride = 0,
    };
}

pub fn deinit(self: *Renderer) void {
    c.hb_buffer_destroy(self.hb_buf);
    self.fg_scratch.deinit(self.alloc);
    self.face_scratch.deinit(self.alloc);
    self.reverse_scratch.deinit(self.alloc);
    self.row_overhang.deinit(self.alloc);
    self.repainted.deinit(self.alloc);
    self.clearShapeCache();
    self.shape_cache.deinit(self.alloc);
    self.shape_key.deinit(self.alloc);
    self.codepoint_scratch.deinit(self.alloc);
    self.cluster_scratch.deinit(self.alloc);
    self.clearKittyScaleCache();
    self.kitty_scale_cache.deinit(self.alloc);
    self.* = undefined;
}

fn clearKittyScaleCache(self: *Renderer) void {
    var it = self.kitty_scale_cache.valueIterator();
    while (it.next()) |bytes| self.alloc.free(bytes.*);
    self.kitty_scale_cache.clearRetainingCapacity();
    self.kitty_scale_cache_bytes = 0;
}

/// Drop all cached shaping results. Must be called when the font (and
/// with it the face set and metrics) changes.
pub fn clearShapeCache(self: *Renderer) void {
    var it = self.shape_cache.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.*);
    }
    self.shape_cache.clearRetainingCapacity();
}

pub fn resetShapeStats(self: *Renderer) void {
    self.shape_stats = .{};
}

pub fn shapeStats(self: *const Renderer) ShapeStats {
    return self.shape_stats;
}

fn pixelStride(self: *const Renderer, width: u31) u31 {
    const stride = if (self.buffer_stride == 0) width else self.buffer_stride;
    std.debug.assert(stride >= width);
    return stride;
}

fn pixelBufferFits(pixels: []const u32, stride: u31, width: u31, height: u31) bool {
    if (width == 0 or height == 0) return true;
    return pixels.len >= @as(usize, height - 1) * stride + width;
}

/// Draw the full render state into `pixels` (width*height, stride == width).
pub fn render(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixelBufferFits(pixels, self.pixelStride(width), width, height));

    if (state.rows == 0 or state.cols == 0) {
        fillRect(pixels, self.pixelStride(width), width, height, 0, 0, width, height, self.backgroundPixel(state.colors.background));
        return;
    }
    try self.row_overhang.resize(self.alloc, state.rows, false);

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    const all_selections = rows.items(.selection);
    for (0..state.rows) |y| {
        try self.renderRow(
            state,
            all_cells[y].slice(),
            all_selections[y],
            @intCast(y),
            pixels,
            width,
            height,
        );
    }

    // Rows cover their own background; only the strip below the last
    // grid row remains.
    const grid_bottom = @as(usize, state.rows) * self.font.cell_height;
    if (grid_bottom < height) {
        fillRect(
            pixels,
            self.pixelStride(width),
            width,
            height,
            0,
            @intCast(grid_bottom),
            width,
            height - @as(u31, @intCast(grid_bottom)),
            self.backgroundPixel(state.colors.background),
        );
    }
}

pub fn renderWithKittyGraphics(
    self: *Renderer,
    state: *const vt.RenderState,
    terminal: *const vt.Terminal,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    const items = try collectKittyPlacements(self.font, self.alloc, terminal);
    defer self.alloc.free(items);
    try self.renderWithKittyItems(state, items, pixels, width, height);
}

/// Full render interleaving kitty placements with the grid by z layer.
/// Items must come from collectKittyPlacements; their image data may
/// point at caller-owned copies, so this never touches the terminal.
pub fn renderWithKittyItems(
    self: *Renderer,
    state: *const vt.RenderState,
    items: []const KittyRenderItem,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixelBufferFits(pixels, self.pixelStride(width), width, height));

    // An opaque above-text image covering the framebuffer determines
    // every output pixel. Video players send exactly this shape, so do
    // not clear and rasterize the terminal grid only to overwrite it.
    if (items.len > 0) {
        const final = items[items.len - 1];
        const rect = kittyDestRect(final, self.font.cell_width, self.font.cell_height);
        if (final.z >= 0 and kittyItemOpaque(final) and
            rect.x0 <= 0 and rect.y0 <= 0 and rect.x1 >= width and rect.y1 >= height)
        {
            try self.renderKittyPlacement(pixels, width, height, final.image, final.viewport);
            return;
        }
    }

    fillRect(pixels, self.pixelStride(width), width, height, 0, 0, width, height, self.backgroundPixel(state.colors.background));
    if (state.rows == 0 or state.cols == 0) return;

    try self.renderKittyItems(items, pixels, width, height, .below_bg);

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    const all_selections = rows.items(.selection);
    for (0..state.rows) |y| {
        try self.prepareRow(
            state,
            all_cells[y].slice(),
            all_selections[y],
            @intCast(y),
            pixels,
            width,
            height,
            .styled,
        );
    }

    try self.renderKittyItems(items, pixels, width, height, .below_text);

    for (0..state.rows) |y| {
        try self.prepareRow(
            state,
            all_cells[y].slice(),
            all_selections[y],
            @intCast(y),
            pixels,
            width,
            height,
            .none,
        );
        try self.renderRowForeground(
            state,
            all_cells[y].slice(),
            @intCast(y),
            pixels,
            width,
            height,
        );
    }

    try self.renderKittyItems(items, pixels, width, height, .above_text);
}

/// Draw only rows marked dirty in `state`, preserving other pixels.
/// A dirty row's neighbors are repainted only when the row_overhang
/// bits demand it: the row above when the dirty row's previous
/// content inked into it, the row below when its ink reaches into the
/// dirty row's freshly cleared strip. The rows actually repainted are
/// recorded in `repainted` for the caller's damage bookkeeping.
pub fn renderDirty(
    self: *Renderer,
    state: *vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixelBufferFits(pixels, self.pixelStride(width), width, height));
    if (state.rows == 0 or state.cols == 0) return;
    try self.row_overhang.resize(self.alloc, state.rows, false);
    try self.repainted.resize(self.alloc, state.rows, false);
    self.repainted.unsetAll();

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    const all_selections = rows.items(.selection);
    const all_dirty = rows.items(.dirty);
    var rendered_until: usize = 0;
    for (all_dirty[0..state.rows], 0..) |dirty, y| {
        if (!dirty) continue;
        const expand_up = y > 0 and self.row_overhang.isSet(y);
        const expand_down = y + 1 < state.rows and self.row_overhang.isSet(y + 1);
        const start = y - @intFromBool(expand_up);
        const end = y + 1 + @intFromBool(expand_down);
        var row = @max(start, rendered_until);
        while (row < end) : (row += 1) {
            self.repainted.set(row);
            try self.renderRow(
                state,
                all_cells[row].slice(),
                all_selections[row],
                @intCast(row),
                pixels,
                width,
                height,
            );
        }
        rendered_until = @max(rendered_until, end);
    }
}

/// The overhang bits describe rendered row content, so move them with a
/// scroll blit. Newly exposed rows are conservatively marked until their
/// first repaint determines their actual overhang.
pub fn shiftRowOverhang(self: *Renderer, rows: usize, shift_rows: isize) !void {
    const shift: usize = @abs(shift_rows);
    std.debug.assert(shift > 0 and shift < rows);
    if (self.row_overhang.bit_length != rows) {
        try self.row_overhang.resize(self.alloc, rows, true);
        self.row_overhang.setRangeValue(.{ .start = 0, .end = rows }, true);
    } else if (shift_rows > 0) {
        for (0..rows - shift) |y| {
            self.row_overhang.setValue(y, self.row_overhang.isSet(y + shift));
        }
        self.row_overhang.setRangeValue(.{ .start = rows - shift, .end = rows }, true);
    } else {
        var y = rows;
        while (y > shift) {
            y -= 1;
            self.row_overhang.setValue(y, self.row_overhang.isSet(y - shift));
        }
        self.row_overhang.setRangeValue(.{ .start = 0, .end = shift }, true);
    }
}

pub fn renderPreedit(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const cursor = state.cursor.viewport orelse return;
    if (cursor.y >= state.rows) return;

    var x: u31 = @intCast(cursor.x -| @intFromBool(cursor.wide_tail));
    const y: u31 = @intCast(cursor.y);
    const baseline_y: i32 = @as(i32, y) * self.font.cell_height + self.font.baseline;
    const cps = try self.overlayCodepoints(text);

    var i: usize = 0;
    while (i < cps.len) {
        const cluster = vt.unicode.graphemeWidth(u21, cps[i..]);
        if (cluster.len == 0) break;
        i += cluster.len;

        const span: u31 = cluster.width;
        if (span == 0) continue;
        if (x >= state.cols) break;
        const clipped_span: u31 = @min(span, state.cols - x);
        const cp = cps[i - cluster.len];

        fillRect(
            pixels,
            self.pixelStride(width),
            width,
            height,
            x * self.font.cell_width,
            y * self.font.cell_height,
            clipped_span * self.font.cell_width,
            self.font.cell_height,
            self.backgroundPixel(state.colors.background),
        );

        const face_idx = self.font.faceForCodepoint(self.alloc, cp);
        const face = self.font.face(face_idx);
        const glyph_idx = c.FT_Get_Char_Index(face.ft_face, cp);
        if (glyph_idx != 0) {
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), isSymbol(cp));
            blitGlyph(
                pixels,
                self.pixelStride(width),
                width,
                height,
                g,
                @as(i32, x) * self.font.cell_width + g.bearing_x,
                baseline_y - g.bearing_y,
                argb(state.colors.foreground),
                false,
            );
        }
        try self.blitDecoration(.underline, x, y, argb(state.colors.foreground), pixels, width, height);
        x += span;
    }
}

pub fn renderLinkHint(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
    uri: []const u8,
) !void {
    try self.renderTextOverlay(
        pixels,
        width,
        height,
        uri,
        .bottom_left,
        self.selection_bg,
        self.selection_fg orelse state.colors.foreground,
    );
}

pub fn renderSearch(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
    text: []const u8,
    no_match: bool,
) !void {
    try self.renderTextOverlay(
        pixels,
        width,
        height,
        text,
        .top_right,
        if (no_match) state.colors.palette[1] else self.selection_bg,
        self.selection_fg orelse state.colors.foreground,
    );
}

const OverlayPosition = enum { bottom_left, top_right };

const OverlayText = struct {
    start: usize,
    width: u31,
};

fn overlayText(cps: []const u21, max_width: u31, suffix: bool) OverlayText {
    var total: usize = 0;
    var i: usize = 0;
    while (i < cps.len) {
        const cluster = vt.unicode.graphemeWidth(u21, cps[i..]);
        if (cluster.len == 0) break;
        i += cluster.len;
        total += cluster.width;
    }

    if (!suffix) {
        var width_: usize = 0;
        i = 0;
        while (i < cps.len) {
            const cluster = vt.unicode.graphemeWidth(u21, cps[i..]);
            if (cluster.len == 0 or width_ + cluster.width > max_width) break;
            i += cluster.len;
            width_ += cluster.width;
        }
        return .{ .start = 0, .width = @intCast(width_) };
    }

    i = 0;
    while (i < cps.len and total > max_width) {
        const cluster = vt.unicode.graphemeWidth(u21, cps[i..]);
        if (cluster.len == 0) break;
        i += cluster.len;
        total -= cluster.width;
    }
    return .{ .start = i, .width = @intCast(total) };
}

fn renderTextOverlay(
    self: *Renderer,
    pixels: []u32,
    width: u31,
    height: u31,
    text: []const u8,
    position: OverlayPosition,
    bg: vt.color.RGB,
    fg: vt.color.RGB,
) !void {
    if (text.len == 0 or width == 0 or height < self.font.cell_height) return;

    const cols: u31 = @max(1, width / self.font.cell_width);
    const padding: u31 = @intFromBool(cols > 2);
    const max_text_width = cols - padding * 2;
    const cps = try self.overlayCodepoints(text);
    const visible = overlayText(cps, max_text_width, position == .top_right);
    const box_width = visible.width + padding * 2;
    const box_x: u31 = if (position == .top_right) cols - box_width else 0;
    const y: u31 = if (position == .top_right) 0 else height - self.font.cell_height;
    const baseline_y: i32 = @as(i32, @intCast(y)) + self.font.baseline;

    fillRect(
        pixels,
        self.pixelStride(width),
        width,
        height,
        box_x * self.font.cell_width,
        y,
        box_width * self.font.cell_width,
        self.font.cell_height,
        argb(bg),
    );

    var x = box_x + padding;
    var i = visible.start;
    const text_end = x + visible.width;
    while (i < cps.len and x < text_end) {
        const cluster = vt.unicode.graphemeWidth(u21, cps[i..]);
        if (cluster.len == 0) break;
        const cp = cps[i];
        i += cluster.len;
        const span: u31 = cluster.width;
        if (span == 0) continue;

        const face_idx = self.font.faceForCodepoint(self.alloc, cp);
        const face = self.font.face(face_idx);
        const glyph_idx = c.FT_Get_Char_Index(face.ft_face, cp);
        if (glyph_idx != 0) {
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), isSymbol(cp));
            blitGlyph(
                pixels,
                self.pixelStride(width),
                width,
                height,
                g,
                @as(i32, x) * self.font.cell_width + g.bearing_x,
                baseline_y - g.bearing_y,
                argb(fg),
                false,
            );
        }
        x += span;
    }
}

/// Resolve every visible kitty placement (pinned and Unicode-virtual)
/// into terminal-independent render items, z-sorted. The returned
/// slice is owned by the caller; each item's image data still points
/// into the terminal's storage.
pub fn collectKittyPlacements(
    font: *const Font,
    alloc: std.mem.Allocator,
    terminal: *const vt.Terminal,
) ![]KittyRenderItem {
    const storage = &terminal.screens.active.kitty_images;

    var placements: std.ArrayList(KittyRenderItem) = .empty;
    errdefer placements.deinit(alloc);

    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        switch (entry.value_ptr.location) {
            .pin => {},
            .virtual => continue,
        }
        const viewport = kittyPlacementViewport(terminal, entry.value_ptr.*, image, font.cell_width, font.cell_height) orelse continue;
        if (!viewport.visible) continue;
        try placements.append(alloc, .{
            .image_id = entry.key_ptr.image_id,
            .placement_id = entry.key_ptr.placement_id.id,
            .z = entry.value_ptr.z,
            .image = image,
            .viewport = viewport,
        });
    }

    try collectKittyVirtualPlacements(font, alloc, terminal, &placements);

    // Video senders commonly retain every prior full-frame placement
    // until the storage quota evicts it. If the final item in draw order
    // is opaque and covers every other item, the sorted result would be
    // that item alone. Detect that in linear time and avoid sorting and
    // quadratic pairwise culling dozens of dead video frames.
    if (keepOnlyFinalKittyCover(placements.items, font.cell_width, font.cell_height)) {
        placements.items.len = 1;
        return placements.toOwnedSlice(alloc);
    }

    std.mem.sortUnstable(KittyRenderItem, placements.items, {}, kittyRenderItemLessThan);
    placements.items.len = cullOccludedKittyItems(
        placements.items,
        font.cell_width,
        font.cell_height,
    );
    return placements.toOwnedSlice(alloc);
}

/// A placement's destination rectangle in framebuffer pixels,
/// unclipped. Mirrors the dest math in renderKittyPlacement.
fn kittyDestRect(item: KittyRenderItem, cell_width: u31, cell_height: u31) struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,
} {
    const x0 = @as(i64, item.viewport.viewport_col) * cell_width + item.viewport.offset_x;
    const y0 = @as(i64, item.viewport.viewport_row) * cell_height + item.viewport.offset_y;
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + item.viewport.pixel_width,
        .y1 = y0 + item.viewport.pixel_height,
    };
}

/// True when the item overwrites every destination pixel it touches:
/// alpha-free formats blit with alpha forced to 0xff on both the
/// unscaled and resampled paths.
fn kittyItemOpaque(item: KittyRenderItem) bool {
    return switch (item.image.format) {
        .rgb, .gray => true,
        .rgba, .gray_alpha, .png => false,
    };
}

/// Replace the items with the final-drawn item when it is opaque and
/// fully covers every other destination rectangle. Returns whether the
/// caller may truncate the slice to one item. Unlike the general culler,
/// this needs no sorting and is linear in the number of placements.
fn keepOnlyFinalKittyCover(items: []KittyRenderItem, cell_width: u31, cell_height: u31) bool {
    if (items.len < 2) return false;

    var final_index: usize = 0;
    var final_unique = true;
    for (items[1..], 1..) |item, i| {
        if (kittyRenderItemLessThan({}, items[final_index], item)) {
            final_index = i;
            final_unique = true;
        } else if (!kittyRenderItemLessThan({}, item, items[final_index])) {
            // Virtual placements can share every sort key while having
            // different geometry. Unstable sorting gives no defined final
            // item for a tie, so preserve the general path in that case.
            final_unique = false;
        }
    }
    if (!final_unique) return false;
    const final = items[final_index];
    if (!kittyItemOpaque(final)) return false;

    const cover = kittyDestRect(final, cell_width, cell_height);
    for (items, 0..) |item, i| {
        if (i == final_index) continue;
        const rect = kittyDestRect(item, cell_width, cell_height);
        if (cover.x0 > rect.x0 or cover.y0 > rect.y0 or
            cover.x1 < rect.x1 or cover.y1 < rect.y1)
        {
            return false;
        }
    }
    items[0] = final;
    return true;
}

/// Drop placements that a later-drawn opaque placement fully covers.
/// Items must already be in draw order (z-sorted): a later item is
/// composited after everything before it, so any earlier item whose
/// dest rect sits inside a later opaque item's rect — along with any
/// text between their layers — cannot affect the final pixels. Senders
/// like mpv stream each video frame as a fresh full-screen image and
/// rely on the terminal's storage quota for cleanup, stacking dozens
/// of dead placements. Compacts in place and returns the new length.
fn cullOccludedKittyItems(items: []KittyRenderItem, cell_width: u31, cell_height: u31) usize {
    if (items.len < 2) return items.len;
    var kept: usize = 0;
    outer: for (items, 0..) |item, i| {
        const rect = kittyDestRect(item, cell_width, cell_height);
        for (items[i + 1 ..]) |later| {
            if (!kittyItemOpaque(later)) continue;
            const cover = kittyDestRect(later, cell_width, cell_height);
            if (cover.x0 <= rect.x0 and cover.y0 <= rect.y0 and
                cover.x1 >= rect.x1 and cover.y1 >= rect.y1)
            {
                continue :outer;
            }
        }
        items[kept] = item;
        kept += 1;
    }
    return kept;
}

fn renderKittyItems(
    self: *Renderer,
    items: []const KittyRenderItem,
    pixels: []u32,
    width: u31,
    height: u31,
    layer: KittyGraphicsLayer,
) !void {
    for (items) |item| {
        if (!layer.matches(item.z)) continue;
        try self.renderKittyPlacement(pixels, width, height, item.image, item.viewport);
    }
}

const KittyGraphicsLayer = enum {
    below_bg,
    below_text,
    above_text,

    fn matches(self: KittyGraphicsLayer, z: i32) bool {
        const bg_limit = std.math.minInt(i32) / 2;
        return switch (self) {
            .below_bg => z < bg_limit,
            .below_text => z >= bg_limit and z < 0,
            .above_text => z >= 0,
        };
    }
};

pub const KittyRenderItem = struct {
    image_id: u32,
    placement_id: u32,
    z: i32,
    /// Value copy of the storage's image record. `data` points into
    /// the terminal's storage after collection; async callers must
    /// repoint it at a pinned copy before handing items to the worker.
    image: KittyImage,
    viewport: KittyPlacementViewport,
};

/// True when two snapshots would render identical placements: same
/// images (by id and generation) at the same viewport geometry. Image
/// data pointers are ignored; a generation match means equal bytes.
pub fn kittyItemsEqual(a: []const KittyRenderItem, b: []const KittyRenderItem) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.image_id != y.image_id) return false;
        if (x.placement_id != y.placement_id) return false;
        if (x.z != y.z) return false;
        if (x.image.generation != y.image.generation) return false;
        if (!std.meta.eql(x.viewport, y.viewport)) return false;
    }
    return true;
}

fn kittyRenderItemLessThan(_: void, lhs: KittyRenderItem, rhs: KittyRenderItem) bool {
    if (lhs.z != rhs.z) return lhs.z < rhs.z;
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    return lhs.placement_id < rhs.placement_id;
}

fn renderKittyPlacement(
    self: *Renderer,
    pixels: []u32,
    width: u31,
    height: u31,
    image: KittyImage,
    viewport: KittyPlacementViewport,
) !void {
    if (image.width == 0 or image.height == 0 or image.data.len == 0) return;

    const dest_width = viewport.pixel_width;
    const dest_height = viewport.pixel_height;
    if (dest_width == 0 or dest_height == 0) return;

    const source_width = viewport.source_width;
    const source_height = viewport.source_height;
    if (source_width == 0 or source_height == 0) return;

    const dest_x = viewport.viewport_col * @as(i32, @intCast(self.font.cell_width)) +
        @as(i32, @intCast(viewport.offset_x));
    const dest_y = viewport.viewport_row * @as(i32, @intCast(self.font.cell_height)) +
        @as(i32, @intCast(viewport.offset_y));

    // Senders like mpv pre-scale frames to the cell area and place them
    // without c=/r=, making dest dims equal source dims. Blit straight
    // from the image bytes: no staging buffers, no resampler.
    if (dest_width == source_width and dest_height == source_height) {
        blitKittyUnscaled(pixels, self.pixelStride(width), width, height, image, viewport, dest_x, dest_y);
        return;
    }

    const scaled = try self.scaledKittyRgba(image, viewport) orelse return;
    defer if (!scaled.cached) self.alloc.free(scaled.bytes);

    blendRgba(pixels, self.pixelStride(width), width, height, scaled.bytes, dest_width, dest_height, dest_x, dest_y);
}

fn scaledKittyRgba(
    self: *Renderer,
    image: KittyImage,
    viewport: KittyPlacementViewport,
) !?struct { bytes: []const u8, cached: bool } {
    const key: KittyScaleKey = .{
        .image_id = image.id,
        .generation = image.generation,
        .format = image.format,
        .image_width = image.width,
        .image_height = image.height,
        .source_x = viewport.source_x,
        .source_y = viewport.source_y,
        .source_width = viewport.source_width,
        .source_height = viewport.source_height,
        .dest_width = viewport.pixel_width,
        .dest_height = viewport.pixel_height,
    };
    if (self.kitty_scale_cache.get(key)) |bytes| return .{ .bytes = bytes, .cached = true };

    const scaled_len = @as(usize, viewport.pixel_width) * viewport.pixel_height * 4;
    const cacheable = scaled_len <= kitty_scale_cache_max_bytes;
    if (cacheable and (self.kitty_scale_cache.count() >= kitty_scale_cache_max_entries or
        self.kitty_scale_cache_bytes + scaled_len > kitty_scale_cache_max_bytes))
    {
        self.clearKittyScaleCache();
    }

    var source = try self.alloc.alloc(u8, @as(usize, viewport.source_width) * viewport.source_height * 4);
    defer self.alloc.free(source);
    if (!copyKittySourceRgba(&source, image, viewport)) return null;

    const scaled = try self.alloc.alloc(u8, scaled_len);
    errdefer self.alloc.free(scaled);
    try resizeRgba(source, viewport.source_width, viewport.source_height, scaled, viewport.pixel_width, viewport.pixel_height);
    self.kitty_scale_count += 1;
    if (!cacheable) return .{ .bytes = scaled, .cached = false };

    try self.kitty_scale_cache.put(self.alloc, key, scaled);
    self.kitty_scale_cache_bytes += scaled.len;
    return .{ .bytes = scaled, .cached = true };
}

/// Draw an unscaled placement directly from the terminal-owned image
/// bytes: one pass per row with the destination rect clipped up front,
/// converting from the image's wire format as it writes.
fn blitKittyUnscaled(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    image: KittyImage,
    viewport: KittyPlacementViewport,
    dest_x: i32,
    dest_y: i32,
) void {
    std.debug.assert(viewport.pixel_width == viewport.source_width);
    std.debug.assert(viewport.pixel_height == viewport.source_height);

    const channels: usize = switch (image.format) {
        .gray => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        .png => return,
    };
    const expected_len = @as(usize, image.width) * image.height * channels;
    if (image.data.len < expected_len) return;

    const x_begin: i64 = @max(dest_x, 0);
    const y_begin: i64 = @max(dest_y, 0);
    const x_end: i64 = @min(@as(i64, dest_x) + viewport.source_width, width);
    const y_end: i64 = @min(@as(i64, dest_y) + viewport.source_height, height);
    if (x_end <= x_begin or y_end <= y_begin) return;

    const cols: usize = @intCast(x_end - x_begin);
    const rows: usize = @intCast(y_end - y_begin);
    const dest_col: usize = @intCast(x_begin);
    const dest_row: usize = @intCast(y_begin);
    const src_x = viewport.source_x + @as(usize, @intCast(x_begin - dest_x));
    const src_y = viewport.source_y + @as(usize, @intCast(y_begin - dest_y));

    for (0..rows) |row| {
        const src_off = ((src_y + row) * image.width + src_x) * channels;
        const src = image.data[src_off..];
        const dst = pixels[(dest_row + row) * stride + dest_col ..][0..cols];
        switch (image.format) {
            .rgb => copyOpaqueRgbSpan(dst, src[0 .. cols * 3]),
            .rgba => for (dst, 0..) |*px, i| {
                const s = src[i * 4 ..][0..4];
                switch (s[3]) {
                    0 => {},
                    0xff => px.* = 0xff000000 |
                        (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2],
                    else => px.* = blendPixel(px.*, s),
                }
            },
            .gray => for (dst, 0..) |*px, i| {
                const gray: u32 = src[i];
                px.* = 0xff000000 | (gray << 16) | (gray << 8) | gray;
            },
            .gray_alpha => for (dst, 0..) |*px, i| {
                const gray = src[i * 2];
                px.* = blendPixel(px.*, &.{ gray, gray, gray, src[i * 2 + 1] });
            },
            .png => unreachable,
        }
    }
}

/// Expand packed RGB into the framebuffer's opaque ARGB8888 format.
/// Kitty video frames are normally RGB and cover millions of pixels,
/// so shuffle four pixels at a time instead of assembling each u32
/// channel by channel. ARGB8888 is BGRA in memory only on little-endian
/// targets; keep the channel-explicit fallback everywhere else.
fn copyOpaqueRgbSpan(noalias dst: []u32, noalias src: []const u8) void {
    std.debug.assert(src.len == dst.len * 3);
    if (comptime builtin.target.cpu.arch.endian() != .little) {
        for (dst, 0..) |*pixel, i| {
            const rgb = src[i * 3 ..][0..3];
            pixel.* = 0xff000000 |
                (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | rgb[2];
        }
        return;
    }

    const ByteVector = @Vector(16, u8);
    const PixelVector = @Vector(4, u32);
    const bgra_lanes: [16]i32 = .{
        2,  1,  0, 12,
        5,  4,  3, 13,
        8,  7,  6, 14,
        11, 10, 9, 15,
    };
    const alpha_mask: PixelVector = @splat(0xff000000);

    var i: usize = 0;
    // A vector load reads 16 bytes for 12 bytes of output. Leave enough
    // source at the end of the span rather than reading across a row or
    // past the image allocation.
    while (i + 6 <= dst.len) : (i += 4) {
        const source: ByteVector = src[i * 3 ..][0..16].*;
        const bgra: ByteVector = @shuffle(u8, source, source, bgra_lanes);
        dst[i..][0..4].* = @as(PixelVector, @bitCast(bgra)) | alpha_mask;
    }
    for (dst[i..], 0..) |*pixel, tail_i| {
        const rgb = src[(i + tail_i) * 3 ..][0..3];
        pixel.* = 0xff000000 |
            (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | rgb[2];
    }
}

const KittyPlacementViewport = struct {
    viewport_col: i32,
    viewport_row: i32,
    visible: bool,
    offset_x: u32,
    offset_y: u32,
    pixel_width: u32,
    pixel_height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

fn kittyPlacementViewport(
    terminal: *const vt.Terminal,
    placement: KittyPlacement,
    image: KittyImage,
    cell_width: u31,
    cell_height: u31,
) ?KittyPlacementViewport {
    const pin = switch (placement.location) {
        .pin => |pin| pin,
        .virtual => return null,
    };

    const pages = &terminal.screens.active.pages;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse return null;
    const vp_tl = pages.getTopLeft(.viewport);
    const vp_screen = pages.pointFromPin(.screen, vp_tl) orelse return null;

    const pixel_size = kittyPlacementPixelSize(placement, image, cell_width, cell_height);
    const grid_rows = std.math.divCeil(u32, pixel_size.height + placement.y_offset, cell_height) catch return null;
    const viewport_row: i32 = @as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y));
    const viewport_col: i32 = @intCast(pin_screen.screen.x);
    const visible = viewport_row + @as(i32, @intCast(grid_rows)) > 0 and
        viewport_row < @as(i32, @intCast(terminal.rows));

    const source_x = @min(placement.source_x, image.width);
    const source_y = @min(placement.source_y, image.height);
    const source_width = @min(if (placement.source_width > 0) placement.source_width else image.width, image.width - source_x);
    const source_height = @min(if (placement.source_height > 0) placement.source_height else image.height, image.height - source_y);
    // An out-of-range source origin resolves to an empty crop. Do not let
    // that no-op placement participate in occlusion or full-frame skips.
    if (source_width == 0 or source_height == 0) return null;
    return .{
        .viewport_col = viewport_col,
        .viewport_row = viewport_row,
        .visible = visible,
        .offset_x = placement.x_offset,
        .offset_y = placement.y_offset,
        .pixel_width = pixel_size.width,
        .pixel_height = pixel_size.height,
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
    };
}

fn collectKittyVirtualPlacements(
    font: *const Font,
    alloc: std.mem.Allocator,
    terminal: *const vt.Terminal,
    placements: *std.ArrayList(KittyRenderItem),
) !void {
    const storage = &terminal.screens.active.kitty_images;
    const top = terminal.screens.active.pages.getTopLeft(.viewport);
    const bot = terminal.screens.active.pages.getBottomRight(.viewport) orelse return;

    var it = vt.kitty.graphics.unicode.placementIterator(top, bot);
    while (it.next()) |virtual_placement| {
        const image = storage.imageById(virtual_placement.image_id) orelse continue;
        const render_placement = virtual_placement.renderPlacement(
            storage,
            &image,
            font.cell_width,
            font.cell_height,
        ) catch |err| {
            log.warn("error rendering kitty virtual placement: {}", .{err});
            continue;
        };
        const viewport = kittyVirtualPlacementViewport(terminal, render_placement) orelse continue;
        if (!viewport.visible) continue;
        try placements.append(alloc, .{
            .image_id = virtual_placement.image_id,
            .placement_id = virtual_placement.placement_id,
            .z = -1,
            .image = image,
            .viewport = viewport,
        });
    }
}

fn kittyVirtualPlacementViewport(
    terminal: *const vt.Terminal,
    placement: KittyRenderPlacement,
) ?KittyPlacementViewport {
    const viewport = terminal.screens.active.pages.pointFromPin(.viewport, placement.top_left) orelse return null;
    const source_x = @min(placement.source_x, std.math.maxInt(u32));
    const source_y = @min(placement.source_y, std.math.maxInt(u32));
    return .{
        .viewport_col = @intCast(viewport.viewport.x),
        .viewport_row = @intCast(viewport.viewport.y),
        .visible = placement.dest_width > 0 and placement.dest_height > 0,
        .offset_x = placement.offset_x,
        .offset_y = placement.offset_y,
        .pixel_width = placement.dest_width,
        .pixel_height = placement.dest_height,
        .source_x = source_x,
        .source_y = source_y,
        .source_width = placement.source_width,
        .source_height = placement.source_height,
    };
}

fn kittyPlacementPixelSize(
    placement: KittyPlacement,
    image: KittyImage,
    cell_width: u31,
    cell_height: u31,
) struct { width: u32, height: u32 } {
    const source_width = if (placement.source_width > 0) placement.source_width else image.width;
    const source_height = if (placement.source_height > 0) placement.source_height else image.height;

    if (placement.columns == 0 and placement.rows == 0) return .{
        .width = source_width,
        .height = source_height,
    };

    if (placement.columns > 0 and placement.rows > 0) return .{
        .width = placement.columns * cell_width,
        .height = placement.rows * cell_height,
    };

    const width_f64: f64 = @floatFromInt(source_width);
    const height_f64: f64 = @floatFromInt(source_height);
    if (placement.columns > 0) {
        const width = placement.columns * cell_width;
        return .{
            .width = width,
            .height = @intFromFloat(@round(@as(f64, @floatFromInt(width)) * height_f64 / width_f64)),
        };
    }

    const height = placement.rows * cell_height;
    return .{
        .width = @intFromFloat(@round(@as(f64, @floatFromInt(height)) * width_f64 / height_f64)),
        .height = height,
    };
}

fn copyKittySourceRgba(
    dst: *[]u8,
    image: KittyImage,
    viewport: KittyPlacementViewport,
) bool {
    const channels: usize = switch (image.format) {
        .gray => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        .png => return false,
    };
    const expected_len = @as(usize, image.width) * image.height * channels;
    if (image.data.len < expected_len) return false;

    var out: usize = 0;
    for (0..viewport.source_height) |row| {
        const source_y = viewport.source_y + row;
        for (0..viewport.source_width) |col| {
            const source_x = viewport.source_x + col;
            const offset = (@as(usize, source_y) * image.width + source_x) * channels;
            switch (image.format) {
                .gray => {
                    const gray = image.data[offset];
                    dst.*[out + 0] = gray;
                    dst.*[out + 1] = gray;
                    dst.*[out + 2] = gray;
                    dst.*[out + 3] = 0xff;
                },
                .gray_alpha => {
                    const gray = image.data[offset];
                    dst.*[out + 0] = gray;
                    dst.*[out + 1] = gray;
                    dst.*[out + 2] = gray;
                    dst.*[out + 3] = image.data[offset + 1];
                },
                .rgb => {
                    dst.*[out + 0] = image.data[offset + 0];
                    dst.*[out + 1] = image.data[offset + 1];
                    dst.*[out + 2] = image.data[offset + 2];
                    dst.*[out + 3] = 0xff;
                },
                .rgba => {
                    dst.*[out + 0] = image.data[offset + 0];
                    dst.*[out + 1] = image.data[offset + 1];
                    dst.*[out + 2] = image.data[offset + 2];
                    dst.*[out + 3] = image.data[offset + 3];
                },
                .png => unreachable,
            }
            out += 4;
        }
    }
    return true;
}

fn resizeRgba(
    source: []const u8,
    source_width: u32,
    source_height: u32,
    dest: []u8,
    dest_width: u32,
    dest_height: u32,
) !void {
    if (c.stbir_resize_uint8(
        source.ptr,
        @intCast(source_width),
        @intCast(source_height),
        @intCast(source_width * 4),
        dest.ptr,
        @intCast(dest_width),
        @intCast(dest_height),
        @intCast(dest_width * 4),
        4,
    ) == 0) return error.ImageResizeFailed;
}

fn blendRgba(
    pixels: []u32,
    stride: u31,
    width: u31,
    height: u31,
    rgba: []const u8,
    image_width: u32,
    image_height: u32,
    dest_x: i32,
    dest_y: i32,
) void {
    for (0..image_height) |src_y| {
        const y = dest_y + @as(i32, @intCast(src_y));
        if (y < 0 or y >= height) continue;

        for (0..image_width) |src_x| {
            const x = dest_x + @as(i32, @intCast(src_x));
            if (x < 0 or x >= width) continue;

            const src_offset = (@as(usize, src_y) * image_width + src_x) * 4;
            const alpha = rgba[src_offset + 3];
            if (alpha == 0) continue;

            const dst_idx = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x));
            if (alpha == 0xff) {
                pixels[dst_idx] = 0xff000000 |
                    (@as(u32, rgba[src_offset + 0]) << 16) |
                    (@as(u32, rgba[src_offset + 1]) << 8) |
                    @as(u32, rgba[src_offset + 2]);
                continue;
            }

            pixels[dst_idx] = blendPixel(pixels[dst_idx], rgba[src_offset..][0..4]);
        }
    }
}

fn blendPixel(dst: u32, src: *const [4]u8) u32 {
    const alpha = @as(u32, src[3]);
    const inv_alpha = 255 - alpha;
    const dst_r = (dst >> 16) & 0xff;
    const dst_g = (dst >> 8) & 0xff;
    const dst_b = dst & 0xff;
    const dst_a = dst >> 24;
    const r = (@as(u32, src[0]) * alpha + dst_r * inv_alpha + 127) / 255;
    const g = (@as(u32, src[1]) * alpha + dst_g * inv_alpha + 127) / 255;
    const b = (@as(u32, src[2]) * alpha + dst_b * inv_alpha + 127) / 255;
    const a = (255 * alpha + dst_a * inv_alpha + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn renderRow(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    try self.prepareRow(state, cells, selection, y, pixels, width, height, .all);
    try self.renderRowForeground(state, cells, y, pixels, width, height);
}

/// Which cell backgrounds prepareRow paints. `.all` covers the entire
/// row rect (unstyled cells and the right margin get the default
/// background), so callers need no separate clear pass. `.styled`
/// leaves unstyled pixels untouched, letting below-text kitty images
/// show through.
const Backgrounds = enum { none, styled, all };

fn prepareRow(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
    backgrounds: Backgrounds,
) !void {
    const font = self.font;
    const colors = &state.colors;
    const raws = cells.items(.raw);
    const styles = cells.items(.style);
    const cols: u31 = @min(state.cols, cells.len);

    const cursor_x: ?u31 = cursor: {
        if (!state.cursor.visible) break :cursor null;
        const viewport = state.cursor.viewport orelse break :cursor null;
        if (viewport.y != y) break :cursor null;
        break :cursor @intCast(viewport.x -| @intFromBool(viewport.wide_tail));
    };

    // Background + foreground-color + face-resolution pass. Adjacent
    // cells sharing a background color coalesce into one fill.
    try self.fg_scratch.resize(self.alloc, cols);
    try self.face_scratch.resize(self.alloc, cols);
    try self.reverse_scratch.resize(self.alloc, cols);
    const y_px: u31 = y * font.cell_height;
    const graphemes = cells.items(.grapheme);
    var bg_run: BgRun = .{};
    for (0..cols) |x| {
        const style: vt.Style = if (raws[x].style_id == 0) .{} else styles[x];
        self.face_scratch.items[x] = face: {
            switch (raws[x].content_tag) {
                .codepoint, .codepoint_grapheme => {},
                else => break :face 0,
            }
            const cp = raws[x].content.codepoint.data;
            if (cp == 0 or cp == kitty_placeholder) break :face 0;
            const extras: []const u21 =
                if (raws[x].content_tag == .codepoint_grapheme) graphemes[x] else &.{};
            if (cp == ' ' and extras.len == 0) break :face 0;
            self.cluster_scratch.clearRetainingCapacity();
            try self.cluster_scratch.append(self.alloc, cp);
            try self.cluster_scratch.appendSlice(self.alloc, extras);
            break :face self.font.faceForCluster(
                self.alloc,
                self.cluster_scratch.items,
                .init(style.flags.bold, style.flags.italic),
            );
        };
        var fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        var bg = style.bg(&raws[x], &colors.palette);
        var reverse_color_glyph = false;
        if (style.flags.inverse) {
            const old_fg = fg;
            fg = bg orelse colors.background;
            bg = old_fg;
        }
        // Selection overrides cell colors: fixed background, default
        // foreground, so selected text reads uniformly.
        const selected = if (selection) |sel| x >= sel[0] and x <= sel[1] else false;
        const search_selected = if (self.search_range) |range| range.contains(x, y) else false;
        if (selected) {
            bg = self.selection_bg;
            fg = self.selection_fg orelse colors.foreground;
            reverse_color_glyph = false;
        } else if (search_selected) {
            bg = self.search_bg;
            fg = self.search_fg;
            reverse_color_glyph = false;
        }
        // Focused block cursor: swap in the cursor color, invert the
        // glyph. All other cursor shapes (and any unfocused cursor)
        // overlay a sprite after drawing instead.
        if (cursor_x != null and cursor_x.? == x and
            state.cursor.visual_style == .block and self.focused)
        {
            bg = colors.cursor orelse colors.foreground;
            fg = self.cursor_text orelse colors.background;
            reverse_color_glyph = false;
        }
        self.fg_scratch.items[x] = fg;
        self.reverse_scratch.items[x] = reverse_color_glyph;
        if (backgrounds != .none) {
            const color: ?u32 = if (bg) |bg_color|
                argb(bg_color)
            else switch (backgrounds) {
                .all => self.backgroundPixel(colors.background),
                else => null,
            };
            if (color) |pixel| {
                const px_start = @as(u31, @intCast(x)) * font.cell_width;
                const px_end = px_start + font.cell_width * cellSpan(raws[x]);
                // Wide heads overlap their spacer tail; extend instead
                // of restarting when the color holds.
                if (bg_run.active and pixel == bg_run.color and px_start <= bg_run.end_px) {
                    bg_run.end_px = @max(bg_run.end_px, px_end);
                } else {
                    bg_run.flush(pixels, self.pixelStride(width), width, height, y_px, font.cell_height);
                    bg_run = .{ .active = true, .color = pixel, .start_px = px_start, .end_px = px_end };
                }
            } else {
                bg_run.flush(pixels, self.pixelStride(width), width, height, y_px, font.cell_height);
            }
        }
    }
    // In .all mode the row rect must be fully covered: extend to the
    // buffer's right edge past the last column.
    if (backgrounds == .all) {
        const margin_start: u31 = cols * font.cell_width;
        if (margin_start < width) {
            const color = self.backgroundPixel(colors.background);
            if (bg_run.active and color == bg_run.color) {
                bg_run.end_px = width;
            } else {
                bg_run.flush(pixels, self.pixelStride(width), width, height, y_px, font.cell_height);
                bg_run = .{ .active = true, .color = color, .start_px = margin_start, .end_px = width };
            }
        }
    }
    bg_run.flush(pixels, self.pixelStride(width), width, height, y_px, font.cell_height);
}

/// A pending run of adjacent equal-color cell backgrounds.
const BgRun = struct {
    active: bool = false,
    color: u32 = 0,
    start_px: u31 = 0,
    end_px: u31 = 0,

    fn flush(run: *BgRun, pixels: []u32, stride: u31, buf_width: u31, buf_height: u31, y_px: u31, h: u31) void {
        if (!run.active) return;
        fillRect(pixels, stride, buf_width, buf_height, run.start_px, y_px, run.end_px - run.start_px, h, run.color);
        run.active = false;
    }
};

fn renderRowForeground(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    const colors = &state.colors;
    const raws = cells.items(.raw);
    const styles = cells.items(.style);
    const graphemes = cells.items(.grapheme);
    const cols: u31 = @min(state.cols, cells.len);
    self.overhang_scratch = false;
    defer if (y < self.row_overhang.bit_length) {
        self.row_overhang.setValue(y, self.overhang_scratch);
    };

    const cursor_x: ?u31 = cursor: {
        if (!state.cursor.visible) break :cursor null;
        const viewport = state.cursor.viewport orelse break :cursor null;
        if (viewport.y != y) break :cursor null;
        break :cursor @intCast(viewport.x -| @intFromBool(viewport.wide_tail));
    };

    // Text pass: shape and draw runs of consecutive cells with the same
    // style and font face.
    const faces = self.face_scratch.items;
    var run_start: u31 = 0;
    var x: u31 = 0;
    while (x < cols) : (x += 1) {
        const has_text = switch (raws[x].content_tag) {
            .codepoint => raws[x].content.codepoint.data != 0 and
                raws[x].content.codepoint.data != ' ' and
                raws[x].content.codepoint.data != kitty_placeholder,
            .codepoint_grapheme => raws[x].content.codepoint.data != 0 and
                raws[x].content.codepoint.data != kitty_placeholder,
            else => false,
        };
        const breaks_run = !has_text or
            raws[x].style_id != raws[run_start].style_id or
            faces[x] != faces[run_start];
        if (breaks_run) {
            try self.drawRun(raws, styles, graphemes, run_start, x, cols, y, pixels, width, height);
            run_start = if (has_text) x else x + 1;
        }
    }
    try self.drawRun(raws, styles, graphemes, run_start, cols, cols, y, pixels, width, height);

    // Decoration pass: underlines, strikethrough, overline, and hyperlink
    // hints overlay the glyphs, in the style's underline color (or the
    // resolved fg).
    for (0..cols) |dx| {
        const show_hyperlink = (self.hyperlink_hints and raws[dx].hyperlink) or
            if (self.link_range) |range| range.contains(dx, y) else false;
        if (raws[dx].style_id == 0 and !show_hyperlink) continue;
        const style: vt.Style = if (raws[dx].style_id == 0) .{} else styles[dx];
        const underline: ?vt.sgr.Attribute.Underline = switch (style.flags.underline) {
            .none => null,
            else => |u| u,
        };
        if (underline == null and !style.flags.strikethrough and !style.flags.overline and !show_hyperlink)
            continue;

        const cell_x: u31 = @intCast(dx);
        if (show_hyperlink) {
            try self.blitDecoration(.underline, cell_x, y, argb(self.fg_scratch.items[dx]), pixels, width, height);
        }
        if (underline) |u| {
            const kind: @import("sprite.zig").Decoration = switch (u) {
                .single => .underline,
                .double => .underline_double,
                .curly => .underline_curly,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .none => unreachable,
            };
            const color = style.underlineColor(&colors.palette) orelse self.fg_scratch.items[dx];
            try self.blitDecoration(kind, cell_x, y, argb(color), pixels, width, height);
        }
        if (style.flags.strikethrough) {
            const color = self.fg_scratch.items[dx];
            try self.blitDecoration(.strikethrough, cell_x, y, argb(color), pixels, width, height);
        }
        if (style.flags.overline) {
            const color = self.fg_scratch.items[dx];
            try self.blitDecoration(.overline, cell_x, y, argb(color), pixels, width, height);
        }
    }

    // Non-block cursor shapes (DECSCUSR bar/underline, hollow block)
    // overlay the cell rather than recoloring it. Without keyboard
    // focus the cursor is always a hollow rectangle.
    if (cursor_x) |cx| {
        const kind: ?@import("sprite.zig").Decoration = if (!self.focused)
            .cursor_hollow_rect
        else switch (state.cursor.visual_style) {
            .block => null, // handled via color swap in the color pass
            .bar => .cursor_bar,
            .underline => .cursor_underline,
            .block_hollow => .cursor_hollow_rect,
        };
        if (kind) |k| {
            const color = colors.cursor orelse colors.foreground;
            try self.blitDecoration(k, cx, y, argb(color), pixels, width, height);
        }
    }
}

/// Record a glyph blit whose ink starts above the current row's strip
/// (`rel_top` is relative to the strip top). Feeds row_overhang via
/// renderRowForeground.
fn noteOverhang(self: *Renderer, rel_top: i32, glyph_height: u31) void {
    if (glyph_height > 0 and rel_top < 0) self.overhang_scratch = true;
}

fn blitDecoration(
    self: *Renderer,
    kind: @import("sprite.zig").Decoration,
    cell_x: u31,
    y: u31,
    color: u32,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    const font = self.font;
    const g = try font.decorationGlyph(self.alloc, kind);
    self.noteOverhang(@as(i32, font.baseline) - g.bearing_y, g.height);
    const baseline_y: i32 = @as(i32, y) * font.cell_height + font.baseline;
    blitGlyph(
        pixels,
        self.pixelStride(width),
        width,
        height,
        g,
        @as(i32, cell_x) * font.cell_width + g.bearing_x,
        baseline_y - g.bearing_y,
        color,
        false,
    );
}

/// Shape cells [start, end) as one HarfBuzz run and blit the glyphs.
/// The run's face is the one resolved for its first cell.
fn drawRun(
    self: *Renderer,
    raws: []const vt.Cell,
    styles: []const vt.Style,
    graphemes: []const []const u21,
    start: u31,
    end: u31,
    cols: u31,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    if (start >= end) return;
    const font = self.font;

    // Sprite glyphs are drawn directly, one per cell: they never shape
    // and their geometry comes from cell metrics, not a font.
    if (self.face_scratch.items[start] == Font.sprite_face_index) {
        const baseline_y: i32 = @as(i32, y) * font.cell_height + font.baseline;
        for (start..end) |x| {
            const raw = raws[x];
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            const cp = raw.content.codepoint.data;
            if (cp == 0) continue;
            const cell_span: u2 = @intCast(@min(cellSpan(raw), 2));
            const g = try font.spriteGlyph(self.alloc, cp, cell_span);
            self.noteOverhang(@as(i32, font.baseline) - g.bearing_y, g.height);
            blitGlyph(
                pixels,
                self.pixelStride(width),
                width,
                height,
                g,
                @as(i32, @intCast(x)) * font.cell_width + g.bearing_x,
                baseline_y - g.bearing_y,
                argb(self.fg_scratch.items[x]),
                false,
            );
        }
        return;
    }

    const face_index = self.face_scratch.items[start];
    const run_style: vt.Style = if (raws[start].style_id == 0) .{} else styles[start];
    const face_style: Font.FaceStyle = .init(run_style.flags.bold, run_style.flags.italic);

    // Build the run's cache key: the face plus (run-relative cluster,
    // codepoint) pairs. Relative clusters make the shape result
    // position-independent, so the same text hits one entry anywhere
    // on screen.
    self.shape_key.clearRetainingCapacity();
    try self.shape_key.append(self.alloc, face_index);
    var non_space = false;
    for (start..end) |x| {
        const raw = raws[x];
        if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
        const cp = raw.content.codepoint.data;
        if (cp != ' ' or raw.content_tag == .codepoint_grapheme) non_space = true;
        const rel: u32 = @intCast(x - start);
        try self.appendShapeKeyCodepoints(rel, cp, if (raw.content_tag == .codepoint_grapheme) graphemes[x] else &.{});
    }
    if (!non_space) return;

    const shaped = if (self.shape_cache.get(std.mem.sliceAsBytes(self.shape_key.items))) |cached| shaped: {
        self.shape_stats.cache_hits += 1;
        break :shaped cached;
    } else shaped: {
        self.shape_stats.cache_misses += 1;
        self.shape_stats.shaped_cells += end - start;
        break :shaped try self.shapeRun(face_index, face_style);
    };

    const baseline_y: i32 = @as(i32, y) * font.cell_height + font.baseline;
    var pen_x: i32 = 0;
    var cluster: u32 = std.math.maxInt(u32);
    for (shaped) |sg| {
        const abs_cluster: u32 = start + sg.cluster;
        // Snap each new cluster to its cell so the grid stays aligned.
        if (abs_cluster != cluster) {
            cluster = abs_cluster;
            pen_x = @as(i32, @intCast(cluster)) * font.cell_width;
        }
        const cluster_x: usize = @intCast(cluster);
        const constraint_width = constraintWidth(raws, cluster_x, cols);
        const cp = cellCodepoint(raws[cluster_x]);
        const g = font.face(sg.face).glyph(
            self.alloc,
            sg.glyph,
            constraint_width,
            isSymbol(cp),
        ) catch |err| switch (err) {
            error.FontLoadFailed, error.GlyphResizeFailed => {
                log.warn("skipping glyph render face={d} glyph={d} codepoint=U+{X}: {}", .{
                    sg.face,
                    sg.glyph,
                    cp,
                    err,
                });
                pen_x += sg.x_advance;
                continue;
            },
            else => |e| return e,
        };
        self.noteOverhang(@as(i32, font.baseline) - sg.y_offset - g.bearing_y, g.height);
        blitGlyph(
            pixels,
            self.pixelStride(width),
            width,
            height,
            g,
            pen_x + sg.x_offset + g.bearing_x,
            baseline_y - sg.y_offset - g.bearing_y,
            argb(self.fg_scratch.items[cluster]),
            self.reverse_scratch.items[cluster],
        );
        pen_x += sg.x_advance;
    }
}

/// Shape the run described by shape_key with HarfBuzz and cache the
/// result under a copy of the key. Clusters that shape to .notdef are
/// re-resolved against further fallback candidates before caching.
fn shapeRun(self: *Renderer, face_index: u16, style: Font.FaceStyle) ![]ShapedGlyph {
    const key = self.shape_key.items;
    const face = self.font.face(face_index);

    c.hb_buffer_clear_contents(self.hb_buf);
    var i: usize = 1;
    while (i + 1 < key.len) : (i += 2) {
        c.hb_buffer_add(self.hb_buf, key[i + 1], key[i]);
    }
    c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_guess_segment_properties(self.hb_buf);
    c.hb_shape(face.hb_font, self.hb_buf, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

    var shaped = try self.alloc.alloc(ShapedGlyph, glyph_count);
    errdefer self.alloc.free(shaped);
    var has_notdef = false;
    if (glyph_count > 0) {
        for (shaped, infos[0..glyph_count], positions[0..glyph_count]) |*sg, info, pos| {
            sg.* = .{
                .glyph = info.codepoint,
                .cluster = info.cluster,
                .face = face_index,
                .x_advance = pos.x_advance >> 6,
                .x_offset = pos.x_offset >> 6,
                .y_offset = pos.y_offset >> 6,
            };
            if (info.codepoint == 0) has_notdef = true;
        }
    }
    if (has_notdef) shaped = try self.repairNotdefClusters(shaped, face_index, style);

    // Full cache: reset wholesale. Terminal content is repetitive
    // enough that the working set repopulates within a frame or two.
    if (self.shape_cache.count() >= shape_cache_max_entries) {
        self.shape_stats.cache_clears += 1;
        self.clearShapeCache();
    }
    const owned_key = try self.alloc.dupe(u8, std.mem.sliceAsBytes(key));
    errdefer self.alloc.free(owned_key);
    try self.shape_cache.put(self.alloc, owned_key, shaped);
    return shaped;
}

/// Replaces .notdef glyphs in a freshly shaped run by re-resolving the
/// failing clusters against further fallback candidates and re-shaping
/// each in isolation. Cluster origins snap to their cells at draw time,
/// so per-cluster splices cannot disturb the rest of the run. Frees
/// `shaped` and returns the corrected run; clusters no candidate can
/// shape keep their original .notdef glyphs.
fn repairNotdefClusters(
    self: *Renderer,
    shaped: []ShapedGlyph,
    face_index: u16,
    style: Font.FaceStyle,
) ![]ShapedGlyph {
    const key = self.shape_key.items;
    var out: std.ArrayList(ShapedGlyph) = .empty;
    errdefer out.deinit(self.alloc);
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(self.alloc);
    // Clusters already replaced, in case HarfBuzz reordered one into
    // non-contiguous groups; later fragments are dropped.
    var repaired: std.ArrayList(u32) = .empty;
    defer repaired.deinit(self.alloc);

    var i: usize = 0;
    while (i < shaped.len) {
        const cluster = shaped[i].cluster;
        var end = i + 1;
        var has_notdef = shaped[i].glyph == 0;
        while (end < shaped.len and shaped[end].cluster == cluster) : (end += 1) {
            if (shaped[end].glyph == 0) has_notdef = true;
        }
        if (std.mem.findScalar(u32, repaired.items, cluster) != null) {
            i = end;
            continue;
        }
        if (!has_notdef) {
            try out.appendSlice(self.alloc, shaped[i..end]);
            i = end;
            continue;
        }

        cps.clearRetainingCapacity();
        var k: usize = 1;
        while (k + 1 < key.len) : (k += 2) {
            if (key[k] == cluster) try cps.append(self.alloc, @intCast(key[k + 1]));
        }

        var fixed = false;
        if (cps.items.len > 0) {
            var candidates = self.font.clusterCandidates(cps.items, style);
            var attempts: usize = 0;
            while (attempts < max_notdef_retries) {
                const candidate = candidates.next(self.alloc) orelse break;
                if (candidate == face_index) continue;
                attempts += 1;
                if (try self.shapeClusterWith(candidate, cluster, cps.items, &out)) {
                    fixed = true;
                    break;
                }
            }
        }
        if (fixed) {
            try repaired.append(self.alloc, cluster);
        } else {
            try out.appendSlice(self.alloc, shaped[i..end]);
        }
        i = end;
    }

    self.alloc.free(shaped);
    return out.toOwnedSlice(self.alloc);
}

/// Shapes `cps` as one isolated cluster with `face_index`, appending the
/// glyphs to `out`. Returns false (leaving `out` untouched) when the
/// result still contains .notdef.
fn shapeClusterWith(
    self: *Renderer,
    face_index: u16,
    cluster: u32,
    cps: []const u21,
    out: *std.ArrayList(ShapedGlyph),
) !bool {
    const face = self.font.face(face_index);
    c.hb_buffer_clear_contents(self.hb_buf);
    for (cps) |cp| c.hb_buffer_add(self.hb_buf, cp, cluster);
    c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_guess_segment_properties(self.hb_buf);
    c.hb_shape(face.hb_font, self.hb_buf, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);
    for (infos[0..glyph_count]) |info| {
        if (info.codepoint == 0) return false;
    }

    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    for (infos[0..glyph_count], positions[0..glyph_count]) |info, pos| {
        try out.append(self.alloc, .{
            .glyph = info.codepoint,
            .cluster = cluster,
            .face = face_index,
            .x_advance = pos.x_advance >> 6,
            .x_offset = pos.x_offset >> 6,
            .y_offset = pos.y_offset >> 6,
        });
    }
    return true;
}

fn appendShapeKeyCodepoints(self: *Renderer, rel: u32, cp: u21, grapheme: []const u21) !void {
    try self.shape_key.appendSlice(self.alloc, &.{ rel, cp });
    for (grapheme) |extra| {
        try self.shape_key.appendSlice(self.alloc, &.{ rel, extra });
    }
}

/// How many cells a cell's background covers (wide chars span two).
fn cellSpan(cell: vt.Cell) u31 {
    return if (cell.wide == .wide) 2 else 1;
}

fn overlayCodepoints(self: *Renderer, text: []const u8) ![]const u21 {
    self.codepoint_scratch.clearRetainingCapacity();
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| try self.codepoint_scratch.append(self.alloc, cp);
    return self.codepoint_scratch.items;
}

/// Renderer-only glyph constraint width, matching Ghostty's symbol heuristic:
/// symbol-like one-column glyphs may render into the following empty/space
/// cell, without changing the terminal grid width.
fn constraintWidth(raws: []const vt.Cell, x: usize, cols: usize) u2 {
    const grid_width: u2 = @intCast(@min(cellSpan(raws[x]), 2));
    if (grid_width > 1) return grid_width;

    const cp = cellCodepoint(raws[x]);
    if (!isSymbol(cp)) return grid_width;

    if (x + 1 >= cols) return 1;

    if (x > 0) {
        const prev_cp = cellCodepoint(raws[x - 1]);
        if (isSymbol(prev_cp) and !isGraphicsElement(prev_cp)) return 1;
    }

    const next_cp = cellCodepoint(raws[x + 1]);
    return if (next_cp == 0 or isSpace(next_cp)) 2 else 1;
}

fn cellCodepoint(cell: vt.Cell) u21 {
    return switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.content.codepoint.data,
        else => 0,
    };
}

fn isSymbol(cp: u21) bool {
    return switch (cp) {
        0x2190...0x21FF, // Arrows
        0x2460...0x24FF, // Enclosed Alphanumerics
        0x2600...0x27BF, // Miscellaneous Symbols, Dingbats
        0x1F000...0x1FAFF, // Emoji/symbol blocks
        0xE000...0xF8FF, // BMP private use area, where Nerd Fonts live
        0xF0000...0xFFFFD, // Supplementary private use area A
        0x100000...0x10FFFD, // Supplementary private use area B
        => true,
        else => false,
    };
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x0020, // SPACE
        0x2002, // EN SPACE
        => true,
        else => false,
    };
}

fn isGraphicsElement(cp: u21) bool {
    return isBoxDrawing(cp) or isBlockElement(cp) or isLegacyComputing(cp) or isPowerline(cp);
}

fn isBoxDrawing(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => true,
        else => false,
    };
}

fn isBlockElement(cp: u21) bool {
    return switch (cp) {
        0x2580...0x259F => true,
        else => false,
    };
}

fn isLegacyComputing(cp: u21) bool {
    return switch (cp) {
        0x1FB00...0x1FBFF => true,
        0x1CC00...0x1CEBF => true,
        else => false,
    };
}

fn isPowerline(cp: u21) bool {
    return switch (cp) {
        0xE0B0...0xE0D7 => true,
        else => false,
    };
}

/// Copy pixels into a buffer the CPU will not read back (a wl_shm
/// buffer). Large copies use non-temporal stores on x86_64: they skip
/// the read-for-ownership of every destination cache line (about a
/// third of the bus traffic) and keep the copy from evicting the
/// render working set.
pub fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    // Below this size the fence and alignment fixup outweigh the saved
    // traffic, and freshly written destination lines may still be hot.
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    // The self-hosted backend's assembler can't parse the SSE memory
    // operands, so the non-temporal path is LLVM-only (all release
    // builds; debug performance doesn't matter).
    if (comptime builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm) {
        if (dst.len >= nt_threshold) return copyNonTemporal(dst, src);
    }
    @memcpy(dst, src);
}

fn copyNonTemporal(noalias dst: []u32, noalias src: []const u32) void {
    var d: [*]u8 = @ptrCast(dst.ptr);
    var s: [*]const u8 = @ptrCast(src.ptr);
    var n: usize = dst.len * @sizeOf(u32);

    // movntdq requires a 16-byte-aligned destination.
    const misalign = @intFromPtr(d) & 15;
    if (misalign != 0) {
        const head = @min(16 - misalign, n);
        @memcpy(d[0..head], s[0..head]);
        d += head;
        s += head;
        n -= head;
    }
    while (n >= 64) {
        asm volatile (
            \\movdqu  (%%rsi), %%xmm0
            \\movdqu 16(%%rsi), %%xmm1
            \\movdqu 32(%%rsi), %%xmm2
            \\movdqu 48(%%rsi), %%xmm3
            \\movntdq %%xmm0,  (%%rdi)
            \\movntdq %%xmm1, 16(%%rdi)
            \\movntdq %%xmm2, 32(%%rdi)
            \\movntdq %%xmm3, 48(%%rdi)
            :
            : [s] "{rsi}" (s),
              [d] "{rdi}" (d),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
        d += 64;
        s += 64;
        n -= 64;
    }
    if (n != 0) @memcpy(d[0..n], s[0..n]);
    // Non-temporal stores are weakly ordered; publish them before the
    // buffer is handed to the compositor.
    asm volatile ("sfence" ::: .{ .memory = true });
}

fn argb(rgb: vt.color.RGB) u32 {
    return 0xff000000 |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

/// Pack the default background in wl_shm's premultiplied ARGB8888 form.
pub fn backgroundPixel(self: *const Renderer, rgb: vt.color.RGB) u32 {
    return premultipliedArgb(rgb, self.background_alpha);
}

fn premultipliedArgb(rgb: vt.color.RGB, alpha_u8: u8) u32 {
    const alpha: u32 = alpha_u8;
    const r = (@as(u32, rgb.r) * alpha + 127) / 255;
    const g = (@as(u32, rgb.g) * alpha + 127) / 255;
    const b = (@as(u32, rgb.b) * alpha + 127) / 255;
    return (alpha << 24) | (r << 16) | (g << 8) | b;
}

fn fillRect(
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

/// Alpha-blend an 8-bit coverage bitmap in `color` over the buffer.
fn blitGlyph(
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    reverse_color_glyph: bool,
) void {
    switch (g.format) {
        .alpha => if (g.fully_opaque)
            blitOpaqueGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color)
        else
            blitAlphaGlyph(pixels, stride, buf_width, buf_height, g, x0, y0, color),
        .bgra => if (reverse_color_glyph)
            blitBgraGlyphAsAlpha(pixels, stride, buf_width, buf_height, g, x0, y0, color)
        else
            blitBgraGlyph(pixels, stride, buf_width, buf_height, g, x0, y0),
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

fn clipGlyph(g: *const Font.Glyph, x0: i32, y0: i32, buf_width: u31, buf_height: u31) ?GlyphClip {
    const gx_start: i64 = @max(0, -@as(i64, x0));
    const gy_start: i64 = @max(0, -@as(i64, y0));
    const gx_end: i64 = @min(@as(i64, g.width), @as(i64, buf_width) - x0);
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
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height) orelse return;
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
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    for (clip.gy_start..clip.gy_end) |gy| {
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        const src = g.bitmap[gy * g.width + clip.gx_start .. gy * g.width + clip.gx_end];
        const dst = pixels[py * stride + px_start ..][0..src.len];
        blendAlphaSpan(dst, src, color);
    }
}

/// Blend a constant color over a pixel span with per-pixel 8-bit
/// coverage, four pixels per iteration. Produces the same value as
/// scalar `blend` for every pixel; zero-coverage pixels keep their
/// background (all-zero groups skip the store entirely).
fn blendAlphaSpan(noalias dst: []u32, noalias coverage: []const u8, color: u32) void {
    std.debug.assert(dst.len == coverage.len);
    // Foregrounds are opaque. Coverage becomes source alpha and is
    // composited over the framebuffer's premultiplied destination.
    std.debug.assert(color >> 24 == 0xff);
    const V = @Vector(16, u16);
    const fg: V = @as(@Vector(16, u8), @bitCast([_]u32{color} ** 4));
    // Broadcast each pixel's coverage across its four channel lanes.
    const expand: [16]i32 = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };
    var i: usize = 0;
    while (i + 4 <= dst.len) : (i += 4) {
        const cov: @Vector(4, u8) = coverage[i..][0..4].*;
        if (@reduce(.Or, cov) == 0) continue;
        if (@reduce(.And, cov == @as(@Vector(4, u8), @splat(0xff)))) {
            dst[i..][0..4].* = @as(@Vector(4, u32), @splat(color));
            continue;
        }
        const a: V = @shuffle(u8, cov, undefined, expand);
        const na = @as(V, @splat(255)) - a;
        const bg: V = @as(@Vector(16, u8), @bitCast(dst[i..][0..4].*));
        const mixed = (fg * a + bg * na) / @as(V, @splat(255));
        const px: @Vector(4, u32) = @bitCast(@as(@Vector(16, u8), @intCast(mixed)));
        dst[i..][0..4].* = px;
    }
    for (dst[i..], coverage[i..]) |*pixel, cov| {
        if (cov == 0) continue;
        pixel.* = blend(color, pixel.*, cov);
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
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height) orelse return;
    const px_start: usize = @intCast(x0 + @as(i32, @intCast(clip.gx_start)));
    for (clip.gy_start..clip.gy_end) |gy| {
        const src = g.bitmap[(gy * g.width + clip.gx_start) * 4 ..];
        const py: usize = @intCast(y0 + @as(i32, @intCast(gy)));
        const dst = pixels[py * stride + px_start ..][0 .. clip.gx_end - clip.gx_start];
        blendPremultipliedBgraSpan(dst, src[0 .. dst.len * 4]);
    }
}

/// Blend premultiplied BGRA color-glyph pixels four at a time. Color
/// emoji are large relative to text glyphs, so doing this per channel
/// instead of per pixel keeps full-screen emoji output from dominating
/// frame rendering.
fn blendPremultipliedBgraSpan(noalias dst: []u32, noalias src: []const u8) void {
    std.debug.assert(src.len == dst.len * 4);
    // ARGB8888 u32 pixels have BGRA byte order only on little-endian
    // machines. Keep the scalar channel-explicit path elsewhere.
    if (comptime builtin.target.cpu.arch.endian() != .little) {
        for (dst, 0..) |*pixel, i| {
            const cell = src[i * 4 ..][0..4];
            if (cell[3] == 0) continue;
            pixel.* = blendPremultipliedBgra(cell, pixel.*);
        }
        return;
    }

    const ByteVector = @Vector(16, u8);
    const WideVector = @Vector(16, u16);
    const PixelVector = @Vector(4, u32);
    const alpha_lanes: [4]i32 = .{ 3, 7, 11, 15 };
    const expand_alpha: [16]i32 = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };

    var i: usize = 0;
    while (i + 4 <= dst.len) : (i += 4) {
        const source: ByteVector = src[i * 4 ..][0..16].*;
        const alpha: @Vector(4, u8) = @shuffle(u8, source, undefined, alpha_lanes);
        if (@reduce(.Or, alpha) == 0) continue;
        if (@reduce(.And, alpha == @as(@Vector(4, u8), @splat(0xff)))) {
            dst[i..][0..4].* = @bitCast(source);
            continue;
        }

        const a: WideVector = @shuffle(u8, alpha, undefined, expand_alpha);
        const inverse = @as(WideVector, @splat(255)) - a;
        const background: WideVector = @as(ByteVector, @bitCast(dst[i..][0..4].*));
        const foreground: WideVector = source;
        // Fonts ship glyphs whose color channels exceed their alpha. Clamp
        // every output channel to its resulting alpha so wl_shm's
        // premultiplied-alpha invariant still holds over transparent pixels.
        const unclamped = @min(
            foreground + (background * inverse) / @as(WideVector, @splat(255)),
            @as(WideVector, @splat(255)),
        );
        const output_alpha: @Vector(4, u16) = @shuffle(u16, unclamped, undefined, alpha_lanes);
        const alpha_limit: WideVector = @shuffle(u16, output_alpha, undefined, expand_alpha);
        const mixed = @min(unclamped, alpha_limit);
        const result: PixelVector = @bitCast(@as(ByteVector, @intCast(mixed)));
        dst[i..][0..4].* = result;
    }
    for (dst[i..], 0..) |*pixel, tail_i| {
        const cell = src[(i + tail_i) * 4 ..][0..4];
        if (cell[3] == 0) continue;
        pixel.* = blendPremultipliedBgra(cell, pixel.*);
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
) void {
    const clip = clipGlyph(g, x0, y0, buf_width, buf_height) orelse return;
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

fn blend(fg: u32, bg: u32, alpha: u8) u32 {
    if (alpha == 0xff) return fg;
    const a: u32 = alpha;
    const na: u32 = 255 - a;
    const r = ((fg >> 16 & 0xff) * a + (bg >> 16 & 0xff) * na) / 255;
    const g = ((fg >> 8 & 0xff) * a + (bg >> 8 & 0xff) * na) / 255;
    const b = ((fg & 0xff) * a + (bg & 0xff) * na) / 255;
    const out_alpha = ((fg >> 24) * a + (bg >> 24) * na) / 255;
    return (out_alpha << 24) | (r << 16) | (g << 8) | b;
}

fn blendPremultipliedBgra(src: []const u8, bg: u32) u32 {
    const a: u32 = src[3];
    if (a == 0xff) {
        return 0xff000000 |
            (@as(u32, src[2]) << 16) |
            (@as(u32, src[1]) << 8) |
            @as(u32, src[0]);
    }
    const na: u32 = 255 - a;
    const out_alpha: u32 = @min(255, a + ((bg >> 24) * na) / 255);
    const r: u32 = @min(out_alpha, @as(u32, src[2]) + ((bg >> 16 & 0xff) * na) / 255);
    const g: u32 = @min(out_alpha, @as(u32, src[1]) + ((bg >> 8 & 0xff) * na) / 255);
    const b: u32 = @min(out_alpha, @as(u32, src[0]) + ((bg & 0xff) * na) / 255);
    return (out_alpha << 24) | (r << 16) | (g << 8) | b;
}

test "kitty unscaled blit converts rgb and clips" {
    const untouched: u32 = 0xff111111;
    var pixels = [_]u32{untouched} ** 9; // 3x3 framebuffer
    const image: KittyImage = .{
        .width = 2,
        .height = 2,
        .format = .rgb,
        .data = &.{
            10, 20, 30, 40,  50,  60,
            70, 80, 90, 100, 110, 120,
        },
    };
    const viewport: KittyPlacementViewport = .{
        .viewport_col = 0,
        .viewport_row = 0,
        .visible = true,
        .offset_x = 0,
        .offset_y = 0,
        .pixel_width = 2,
        .pixel_height = 2,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 2,
    };

    // Left column clips off the framebuffer: only source column 1 lands.
    blitKittyUnscaled(&pixels, 3, 3, 3, image, viewport, -1, 1);
    try std.testing.expectEqual(@as(u32, 0xff28323c), pixels[3]); // src (1,0)
    try std.testing.expectEqual(@as(u32, 0xff646e78), pixels[6]); // src (1,1)
    for ([_]usize{ 0, 1, 2, 4, 5, 7, 8 }) |i| {
        try std.testing.expectEqual(untouched, pixels[i]);
    }

    // Fully off-screen placements draw nothing.
    var before = pixels;
    blitKittyUnscaled(&pixels, 3, 3, 3, image, viewport, 3, 0);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
}

test "kitty unscaled blit honors rgba alpha" {
    const bg: u32 = 0xff111111;
    var pixels = [_]u32{bg} ** 4; // 2x2 framebuffer
    const image: KittyImage = .{
        .width = 2,
        .height = 2,
        .format = .rgba,
        .data = &.{
            200, 200, 200, 0,   200, 200, 200, 255,
            200, 200, 200, 128, 0,   0,   0,   255,
        },
    };
    const viewport: KittyPlacementViewport = .{
        .viewport_col = 0,
        .viewport_row = 0,
        .visible = true,
        .offset_x = 0,
        .offset_y = 0,
        .pixel_width = 2,
        .pixel_height = 2,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 2,
    };

    blitKittyUnscaled(&pixels, 2, 2, 2, image, viewport, 0, 0);
    try std.testing.expectEqual(bg, pixels[0]); // alpha 0 skipped
    try std.testing.expectEqual(@as(u32, 0xffc8c8c8), pixels[1]); // opaque
    try std.testing.expectEqual(
        blendPixel(bg, &.{ 200, 200, 200, 128 }),
        pixels[2],
    ); // partial alpha blends
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[3]);
}

test "scaled kitty placement reuses cached rgba variant" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const image: KittyImage = .{
        .id = 17,
        .width = 2,
        .height = 2,
        .format = .rgb,
        .data = &.{
            10, 20, 30, 40,  50,  60,
            70, 80, 90, 100, 110, 120,
        },
        .generation = 3,
    };
    const viewport: KittyPlacementViewport = .{
        .viewport_col = 0,
        .viewport_row = 0,
        .visible = true,
        .offset_x = 0,
        .offset_y = 0,
        .pixel_width = 3,
        .pixel_height = 3,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 2,
    };
    var pixels = [_]u32{0xff000000} ** 9;

    try renderer.renderKittyPlacement(&pixels, 3, 3, image, viewport);
    const first = pixels;
    @memset(&pixels, 0xff000000);
    try renderer.renderKittyPlacement(&pixels, 3, 3, image, viewport);

    try std.testing.expectEqualSlices(u32, &first, &pixels);
    try std.testing.expectEqual(@as(usize, 1), renderer.kitty_scale_count);
    try std.testing.expectEqual(@as(u32, 1), renderer.kitty_scale_cache.count());
}

test "copyOpaqueRgbSpan matches scalar conversion across vector boundaries" {
    var source: [3 + 23 * 3]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);

    for ([_]usize{ 0, 1, 5, 6, 15, 16, 17, 23 }) |len| {
        var actual = [_]u32{0} ** 23;
        const rgb = source[3..][0 .. len * 3];
        copyOpaqueRgbSpan(actual[0..len], rgb);
        for (actual[0..len], 0..) |pixel, i| {
            try std.testing.expectEqual(
                0xff000000 |
                    (@as(u32, rgb[i * 3]) << 16) |
                    (@as(u32, rgb[i * 3 + 1]) << 8) |
                    rgb[i * 3 + 2],
                pixel,
            );
        }
    }
}

test "cullOccludedKittyItems drops placements under later opaque covers" {
    const cell_w: u31 = 10;
    const cell_h: u31 = 20;
    const makeItem = struct {
        fn makeItem(id: u32, z: i32, format: @FieldType(KittyImage, "format"), col: i32, row: i32, w: u32, h: u32) KittyRenderItem {
            return .{
                .image_id = id,
                .placement_id = 1,
                .z = z,
                .image = .{ .width = w, .height = h, .format = format, .data = &.{} },
                .viewport = .{
                    .viewport_col = col,
                    .viewport_row = row,
                    .visible = true,
                    .offset_x = 0,
                    .offset_y = 0,
                    .pixel_width = w,
                    .pixel_height = h,
                    .source_x = 0,
                    .source_y = 0,
                    .source_width = w,
                    .source_height = h,
                },
            };
        }
    }.makeItem;

    // Draw order (already z/id sorted):
    //   0: rgb  full-screen  — occluded by 2 (same rect, opaque, later)
    //   1: rgb  small inset  — occluded by 2
    //   2: rgb  full-screen  — kept: only a non-opaque item follows
    //   3: rgba full-screen  — kept: nothing follows
    var items = [_]KittyRenderItem{
        makeItem(1, 0, .rgb, 0, 0, 100, 100),
        makeItem(2, 0, .rgb, 2, 1, 30, 40),
        makeItem(3, 0, .rgb, 0, 0, 100, 100),
        makeItem(4, 1, .rgba, 0, 0, 100, 100),
    };
    const kept = cullOccludedKittyItems(&items, cell_w, cell_h);
    try std.testing.expectEqual(@as(usize, 2), kept);
    try std.testing.expectEqual(@as(u32, 3), items[0].image_id);
    try std.testing.expectEqual(@as(u32, 4), items[1].image_id);

    // A later opaque item that only partially covers must not cull.
    var partial = [_]KittyRenderItem{
        makeItem(1, 0, .rgb, 0, 0, 100, 100),
        makeItem(2, 0, .rgb, 1, 0, 100, 100),
    };
    try std.testing.expectEqual(@as(usize, 2), cullOccludedKittyItems(&partial, cell_w, cell_h));

    // The linear fast path finds the final item without pre-sorting.
    var full_cover = [_]KittyRenderItem{
        makeItem(8, 0, .rgb, 2, 1, 30, 40),
        makeItem(10, 0, .rgb, 0, 0, 100, 100),
        makeItem(9, 0, .rgb, 0, 0, 100, 100),
    };
    try std.testing.expect(keepOnlyFinalKittyCover(&full_cover, cell_w, cell_h));
    try std.testing.expectEqual(@as(u32, 10), full_cover[0].image_id);
    try std.testing.expect(!keepOnlyFinalKittyCover(&partial, cell_w, cell_h));

    // Equal sort keys can occur for separate virtual fragments; their
    // unstable-sort order is undefined, so the fast path must decline.
    var tied = [_]KittyRenderItem{
        makeItem(10, 0, .rgb, 0, 0, 100, 100),
        makeItem(10, 0, .rgb, 2, 1, 30, 40),
    };
    try std.testing.expect(!keepOnlyFinalKittyCover(&tied, cell_w, cell_h));
}

test "blend endpoints" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), blend(0xffffffff, 0xff000000, 255));
    try std.testing.expectEqual(@as(u32, 0xff000000), blend(0xffffffff, 0xff000000, 0));
    try std.testing.expectEqual(@as(u32, 0x80808080), blend(0xffffffff, 0x00000000, 128));
    try std.testing.expectEqual(@as(u32, 0xbf808080), blend(0xffffffff, 0x80000000, 128));
    try std.testing.expectEqual(
        @as(u32, 0x80643219),
        blendPixel(0, &.{ 200, 100, 50, 128 }),
    );
    try std.testing.expectEqual(
        @as(u32, 0xff804000),
        blendPremultipliedBgra(&.{ 0x00, 0x40, 0x80, 0xff }, 0xff000000),
    );
    try std.testing.expectEqual(
        @as(u32, 0x801e140a),
        blendPremultipliedBgra(&.{ 10, 20, 30, 128 }, 0),
    );
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
    // Odd lengths exercise both the vector body and the scalar tail.
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
    blitGlyph(&alpha_pixels, 5, 5, 4, &alpha_glyph, -1, 2, 0xffabcdef, false);
    blitGlyph(&opaque_pixels, 5, 5, 4, &opaque_glyph, -1, 2, 0xffabcdef, false);
    try std.testing.expectEqualSlices(u32, &alpha_pixels, &opaque_pixels);
}

test "blendPremultipliedBgraSpan matches scalar blend" {
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

    const mixed_source = [_]u8{
        0,  0,  0,   0,
        20, 40, 80,  255,
        10, 20, 30,  128,
        1,  2,  3,   64,
        9,  18, 27,  255,
        0,  0,  0,   0,
        20, 30, 100, 200,
    };
    var mixed_got: [7]u32 = @splat(0xff204060);
    var mixed_want = mixed_got;
    for (&mixed_want, 0..) |*pixel, i| {
        const cell = mixed_source[i * 4 ..][0..4];
        if (cell[3] != 0) pixel.* = blendPremultipliedBgra(cell, pixel.*);
    }
    blendPremultipliedBgraSpan(&mixed_got, &mixed_source);
    try std.testing.expectEqualSlices(u32, &mixed_want, &mixed_got);

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

    var prng: std.Random.DefaultPrng = .init(0xb6a4);
    const random = prng.random();
    for ([_]usize{ 1, 3, 4, 7, 16, 21 }) |len| {
        var source: [21 * 4]u8 = undefined;
        var got: [21]u32 = undefined;
        var want: [21]u32 = undefined;
        for (0..10) |_| {
            for (got[0..len], want[0..len], 0..) |*g, *w, i| {
                const alpha = switch (random.int(u2)) {
                    0 => 0,
                    1 => 0xff,
                    else => random.int(u8),
                };
                const cell = source[i * 4 ..][0..4];
                cell[0] = random.intRangeAtMost(u8, 0, alpha);
                cell[1] = random.intRangeAtMost(u8, 0, alpha);
                cell[2] = random.intRangeAtMost(u8, 0, alpha);
                cell[3] = alpha;
                const bg_alpha = random.int(u8);
                const bg = (@as(u32, bg_alpha) << 24) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 16) |
                    (@as(u32, random.intRangeAtMost(u8, 0, bg_alpha)) << 8) |
                    random.intRangeAtMost(u8, 0, bg_alpha);
                g.* = bg;
                w.* = if (alpha == 0) bg else blendPremultipliedBgra(cell, bg);
            }
            blendPremultipliedBgraSpan(got[0..len], source[0 .. len * 4]);
            try std.testing.expectEqualSlices(u32, want[0..len], got[0..len]);
        }
    }
}

test "emoji keycap grapheme selects emoji fallback face" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 4,
        .rows = 1,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    stream.nextSlice("1\xEF\xB8\x8F\xE2\x83\xA3");
    try state.update(alloc, &term);

    const cells = state.row_data.get(0).cells.slice();
    const raws = cells.items(.raw);
    const graphemes = cells.items(.grapheme);
    try testing.expectEqual(.codepoint_grapheme, raws[0].content_tag);
    try testing.expectEqual(@as(u21, '1'), raws[0].content.codepoint.data);
    try testing.expectEqualSlices(u21, &.{ 0xFE0F, 0x20E3 }, graphemes[0]);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    const keycap_face = font.faceForCluster(alloc, &.{ '1', 0xFE0F, 0x20E3 }, .regular);
    if (keycap_face == 0) return error.SkipZigTest;
    // The chosen face must cover the whole cluster, keycap included.
    try testing.expect(font.face(keycap_face).hasCodepoint('1'));
    try testing.expect(font.face(keycap_face).hasCodepoint(0x20E3));

    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * 4;
    const height: u31 = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    try renderer.prepareRow(&state, cells, null, 0, pixels, width, height, .none);
    try testing.expectEqual(keycap_face, renderer.face_scratch.items[0]);

    renderer.shape_key.clearRetainingCapacity();
    try renderer.shape_key.append(alloc, keycap_face);
    try renderer.appendShapeKeyCodepoints(0, raws[0].content.codepoint.data, graphemes[0]);
    try testing.expectEqualSlices(u32, &.{ keycap_face, 0, '1', 0, 0xFE0F, 0, 0x20E3 }, renderer.shape_key.items);
    try testing.expect(try renderer.shapeKeyHasColorGlyph(keycap_face));

    try renderer.render(&state, pixels, width, height);
    try testing.expect(chromaticPixelCount(pixels) > 0);
}

test "emoji presentation graphemes select emoji fallback face" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const grinning: u21 = 0x1F600;

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    const emoji_face = font.faceForCodepoint(alloc, grinning);
    if (emoji_face == 0) return error.SkipZigTest;
    const emoji_glyph_idx = c.FT_Get_Char_Index(font.face(emoji_face).ft_face, grinning);
    if (emoji_glyph_idx == 0) return error.SkipZigTest;
    const emoji_glyph = try font.face(emoji_face).glyph(alloc, emoji_glyph_idx, 2, false);
    if (emoji_glyph.format != .bgra) return error.SkipZigTest;

    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 8, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    const width: u31 = font.cell_width * 8;
    const height: u31 = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    const cases = [_][]const u8{
        "\xE2\x9D\xA4\xEF\xB8\x8F", // heart emoji
        "\xC2\xA9\xEF\xB8\x8F", // copyright emoji
        "\xE2\x84\xA2\xEF\xB8\x8F", // trademark emoji
        "\xE2\x98\x80\xEF\xB8\x8F", // sun emoji
        "\xE2\x9D\xA4\xEF\xB8\x8F\xE2\x80\x8D\xF0\x9F\x94\xA5", // heart on fire
    };

    for (cases) |text| {
        term.fullReset();
        stream.nextSlice(text);
        try state.update(alloc, &term);

        const cells = state.row_data.get(0).cells.slice();
        const raws = cells.items(.raw);
        const graphemes = cells.items(.grapheme);
        renderer.cluster_scratch.clearRetainingCapacity();
        try renderer.cluster_scratch.append(alloc, raws[0].content.codepoint.data);
        if (raws[0].content_tag == .codepoint_grapheme)
            try renderer.cluster_scratch.appendSlice(alloc, graphemes[0]);
        const case_face = font.faceForCluster(alloc, renderer.cluster_scratch.items, .regular);
        try testing.expect(case_face != 0);

        try renderer.prepareRow(&state, cells, null, 0, pixels, width, height, .none);
        try testing.expectEqual(case_face, renderer.face_scratch.items[0]);

        renderer.shape_key.clearRetainingCapacity();
        try renderer.shape_key.append(alloc, case_face);
        try renderer.appendShapeKeyCodepoints(
            0,
            raws[0].content.codepoint.data,
            if (raws[0].content_tag == .codepoint_grapheme) graphemes[0] else &.{},
        );
        try testing.expect(try renderer.shapeKeyHasColorGlyph(case_face));

        try renderer.render(&state, pixels, width, height);
        try testing.expect(chromaticPixelCount(pixels) > 0);
    }
}

test "default emoji presentation squares select emoji fallback face" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const grinning: u21 = 0x1F600;
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    const emoji_face = font.faceForCodepoint(alloc, grinning);
    if (emoji_face == 0) return error.SkipZigTest;
    const emoji_glyph_idx = c.FT_Get_Char_Index(font.face(emoji_face).ft_face, grinning);
    if (emoji_glyph_idx == 0) return error.SkipZigTest;
    const emoji_glyph = try font.face(emoji_face).glyph(alloc, emoji_glyph_idx, 2, false);
    if (emoji_glyph.format != .bgra) return error.SkipZigTest;

    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 12, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    const width: u31 = font.cell_width * 12;
    const height: u31 = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    const cases = [_][]const u8{
        "\xE2\xAC\x9B", // black large square
        "\xE2\xAC\x9C", // white large square
        "\xE2\xAD\x90", // star
        "\xE2\x9A\xAB", // black circle
        "\xE2\x9A\xAA", // white circle
        "\xF0\x9F\x9F\xAB", // brown square
        "\xF0\x9F\x9F\xA5", // red square
    };

    for (cases) |text| {
        term.fullReset();
        stream.nextSlice(text);
        try state.update(alloc, &term);

        const cells = state.row_data.get(0).cells.slice();
        const raws = cells.items(.raw);
        const graphemes = cells.items(.grapheme);
        const case_face = font.faceForCodepoint(alloc, raws[0].content.codepoint.data);
        try testing.expect(case_face != 0);

        try renderer.prepareRow(&state, cells, null, 0, pixels, width, height, .none);
        try testing.expectEqual(case_face, renderer.face_scratch.items[0]);

        renderer.shape_key.clearRetainingCapacity();
        try renderer.shape_key.append(alloc, case_face);
        try renderer.appendShapeKeyCodepoints(
            0,
            raws[0].content.codepoint.data,
            if (raws[0].content_tag == .codepoint_grapheme) graphemes[0] else &.{},
        );
        try testing.expect(try renderer.shapeKeyHasColorGlyph(case_face));

        try renderer.render(&state, pixels, width, height);
    }
}

fn shapeKeyHasColorGlyph(self: *Renderer, face_index: u16) !bool {
    const shaped = try self.shapeRun(face_index, .regular);
    for (shaped) |sg| {
        const glyph = self.font.face(sg.face).glyph(self.alloc, sg.glyph, 2, false) catch continue;
        if (glyph.format == .bgra) return true;
    }
    return false;
}

fn chromaticPixelCount(pixels: []const u32) usize {
    var count: usize = 0;
    for (pixels) |px| {
        const r: u8 = @truncate(px >> 16);
        const g: u8 = @truncate(px >> 8);
        const b: u8 = @truncate(px);
        if (r != g or g != b) count += 1;
    }
    return count;
}

test "termtest emoji graphemes occupy two grid cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_][]const u8{
        "⬛",
        "⚫",
        "◼️",
        "🟫",
        "🤎",
        "◾",
        "🟥",
        "🔴",
        "❤️",
        "🟧",
        "🟠",
        "🔶",
        "🟨",
        "🟡",
        "⭐",
        "⬜",
        "⚪",
        "💫",
        "▫️",
        "▪️",
        "🧱",
        "🪵",
        "🌑",
        "💥",
        "🌋",
        "❤️‍🔥",
        "🔥",
        "♨️",
        "✨",
        "🌟",
        "⚡",
        "🙂",
        "😐",
        "😃",
        "😅",
        "🙃",
        "🥵",
        "😵‍💫",
        "🤯",
        "🧑‍🚒",
        "👩‍🚒",
        "👨‍🚒",
        "🧑‍🏭",
        "👩‍🏭",
        "👨‍🏭",
        "👨‍👩‍👧‍👦",
        "👩‍👩‍👧‍👦",
        "👨‍👨‍👧‍👦",
    };

    for (cases) |text| {
        var term: vt.Terminal = try .init(std.testing.io, alloc, .{
            .cols = 4,
            .rows = 1,
            .default_modes = .{ .grapheme_cluster = true },
        });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();

        stream.nextSlice(text);

        var state: vt.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &term);

        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(.wide, raws[0].wide);
        try testing.expectEqual(.spacer_tail, raws[1].wide);
    }
}

test "termtest emoji graphemes keep width across stream splits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_][]const u8{
        "❤️‍🔥",
        "😵‍💫",
        "🧑‍🚒",
        "🧑‍🏭",
        "👨‍👩‍👧‍👦",
    };

    for (cases) |text| {
        var term: vt.Terminal = try .init(std.testing.io, alloc, .{
            .cols = 12,
            .rows = 1,
            .default_modes = .{ .grapheme_cluster = true },
        });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();

        for (text) |byte| stream.nextSlice((&byte)[0..1]);

        var state: vt.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &term);

        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(.wide, raws[0].wide);
        try testing.expectEqual(.spacer_tail, raws[1].wide);
        try testing.expectEqual(@as(u21, 0), cellCodepoint(raws[2]));
    }
}

test "symbol glyph constraint widths match Ghostty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    {
        term.fullReset();
        stream.nextSlice("");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice(" z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("   ");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 3, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("   ");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 2, 3));
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 2, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 0, state.cols));
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 1, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 1, state.cols));
    }
}

test "scrollback viewport scrolls and renders older content" {
    const alloc = std.testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    for (0..20) |i| {
        var buf: [16]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}) catch unreachable);
    }

    const pages = &term.screens.active.pages;
    try std.testing.expect(pages.viewport == .active);

    // At the bottom: the viewport shows the most recent lines.
    const bottom = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(bottom);
    try std.testing.expect(std.mem.indexOf(u8, bottom, "line19") != null);

    // Scroll up six lines: older content, no longer pinned to active.
    pages.scroll(.{ .delta_row = -6 });
    try std.testing.expect(pages.viewport != .active);
    const scrolled = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(scrolled);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "line19") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled, "line13") != null);

    // RenderState follows the scrolled viewport.
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    const rows = state.row_data.slice();
    const first_cells = rows.items(.cells)[0].slice();
    // First visible row should start with 'l' of a line label.
    try std.testing.expectEqual(@as(u21, 'l'), first_cells.items(.raw)[0].content.codepoint.data);

    // Scrolling back to active restores the bottom.
    pages.scroll(.active);
    try std.testing.expect(pages.viewport == .active);
}

test "render a simple grid" {
    const alloc = std.testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 8, .rows = 2 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("hi \x1b[31mred\x1b[0m");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * 8;
    const height: u31 = font.cell_height * 2;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try renderer.render(&state, pixels, width, height);

    // Something must have been drawn over the background.
    const bg = argb(state.colors.background);
    var non_bg: usize = 0;
    for (pixels) |px| {
        if (px != bg) non_bg += 1;
    }
    try std.testing.expect(non_bg > 0);
}

test "background opacity does not fade explicit cell backgrounds" {
    const alloc = std.testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l\x1b[41m \x1b[0m ");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{ .background_alpha = 128 });
    defer renderer.deinit();

    const width: u31 = font.cell_width * 2;
    const height: u31 = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    try renderer.render(&state, pixels, width, height);

    const y = font.cell_height / 2;
    const explicit_bg = pixels[@as(usize, y) * width + font.cell_width / 2];
    const default_bg = pixels[@as(usize, y) * width + font.cell_width + font.cell_width / 2];
    try std.testing.expectEqual(@as(u32, 0xff), explicit_bg >> 24);
    try std.testing.expectEqual(renderer.backgroundPixel(state.colors.background), default_bg);
}

test "render rectangular selection spans" {
    const alloc = std.testing.allocator;
    const selection_bg: vt.color.RGB = .{ .r = 0x12, .g = 0x34, .b = 0x56 };

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 8, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l");

    const screen = term.screens.active;
    try screen.select(vt.Selection.init(
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 4, .y = 3 } }).?,
        true,
    ));

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    const rows = state.row_data.slice();
    const selections = rows.items(.selection);
    try std.testing.expectEqual(null, selections[0]);
    try std.testing.expectEqualSlices(vt.size.CellCountInt, &.{ 2, 4 }, &selections[1].?);
    try std.testing.expectEqualSlices(vt.size.CellCountInt, &.{ 2, 4 }, &selections[2].?);
    try std.testing.expectEqualSlices(vt.size.CellCountInt, &.{ 2, 4 }, &selections[3].?);
    try std.testing.expectEqual(null, selections[4]);

    var renderer: Renderer = try .init(alloc, &font, .{ .selection_background = selection_bg });
    defer renderer.deinit();

    const width: u31 = font.cell_width * 8;
    const height: u31 = font.cell_height * 5;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try renderer.render(&state, pixels, width, height);

    const selected = argb(selection_bg);
    const background = argb(state.colors.background);
    for (0..5) |y| {
        for (0..8) |x| {
            const px = (y * font.cell_height + font.cell_height / 2) * width +
                (x * font.cell_width + font.cell_width / 2);
            const expected = if (y >= 1 and y <= 3 and x >= 2 and x <= 4)
                selected
            else
                background;
            try std.testing.expectEqual(expected, pixels[px]);
        }
    }
}

test "render kitty image placement" {
    const alloc = std.testing.allocator;

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 2 });
    defer term.deinit(alloc);
    term.width_px = term.cols * font.cell_width;
    term.height_px = term.rows * font.cell_height;

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=1,s=1,v=1,c=1,r=1;////\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), term.screens.active.kitty_images.placements.count());

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * 4;
    const height: u31 = font.cell_height * 2;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try renderer.renderWithKittyGraphics(&state, &term, pixels, width, height);

    var white_pixels: usize = 0;
    for (pixels) |px| {
        if (px == 0xffffffff) white_pixels += 1;
    }
    try std.testing.expect(white_pixels > 0);
}

test "render kitty unicode placeholder placement" {
    const alloc = std.testing.allocator;

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 2 });
    defer term.deinit(alloc);
    term.width_px = term.cols * font.cell_width;
    term.height_px = term.rows * font.cell_height;

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=1,s=1,v=1,U=1,c=1,r=1;////\x1b\\");
    stream.nextSlice("\x1b[38:2::0:0:1m\xf4\x8e\xbb\xae\x1b[0m");
    try std.testing.expectEqual(@as(usize, 1), term.screens.active.kitty_images.placements.count());

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * 4;
    const height: u31 = font.cell_height * 2;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try renderer.renderWithKittyGraphics(&state, &term, pixels, width, height);

    var white_pixels: usize = 0;
    for (pixels) |px| {
        if (px == 0xffffffff) white_pixels += 1;
    }
    try std.testing.expect(white_pixels > 0);
}

test "dirty row render matches full render" {
    const alloc = std.testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 8, .rows = 3 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("aaaaaaaa\r\nbbbbbbbb\r\ncccccccc");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * 8;
    const height: u31 = font.cell_height * 3;
    const dirty_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(dirty_pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);

    try renderer.render(&state, dirty_pixels, width, height);
    state.dirty = .false;
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;

    stream.nextSlice("\x1b[2;2HX");
    try state.update(alloc, &term);
    try std.testing.expectEqual(vt.RenderState.Dirty.partial, state.dirty);

    try renderer.renderDirty(&state, dirty_pixels, width, height);
    try renderer.render(&state, full_pixels, width, height);
    try std.testing.expectEqualSlices(u32, full_pixels, dirty_pixels);
}

test "top-right overlay keeps the newest complete grapheme clusters" {
    const cps = [_]u21{ 'a', '界', 'b' };

    try std.testing.expectEqual(
        OverlayText{ .start = 0, .width = 3 },
        overlayText(&cps, 3, false),
    );
    try std.testing.expectEqual(
        OverlayText{ .start = 1, .width = 3 },
        overlayText(&cps, 3, true),
    );
    try std.testing.expectEqual(
        OverlayText{ .start = 2, .width = 1 },
        overlayText(&cps, 2, true),
    );
}

test "search match uses its own highlight background" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 2, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("x");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();
    renderer.search_bg = .{ .r = 0xff, .g = 0xe6, .b = 0x29 };
    renderer.search_fg = .{ .r = 0x1c, .g = 0x20, .b = 0x24 };
    renderer.search_range = .{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 0, .y = 0 },
    };

    const width = font.cell_width * 2;
    const height = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    try renderer.render(&state, pixels, width, height);

    var highlighted: usize = 0;
    for (0..height) |y| {
        for (0..font.cell_width) |x| {
            if (pixels[y * width + x] == argb(renderer.search_bg)) highlighted += 1;
        }
    }
    try std.testing.expect(highlighted > 0);
}
