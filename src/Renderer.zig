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
const CellDamageTracker = @import("CellDamageTracker.zig");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const TextShaper = @import("TextShaper.zig");
const glyph_constraints = @import("glyph_constraints.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const pixel_copy = @import("pixel_copy.zig");
const pixel_raster = @import("pixel_raster.zig");

const log = std.log.scoped(.renderer);
const KittyImage = vt.kitty.graphics.Image;
const KittyPlacementViewport = kitty_graphics.KittyPlacementViewport;
const kittyDestRect = kitty_graphics.kittyDestRect;
const kittyItemOpaque = kitty_graphics.kittyItemOpaque;
const kitty_placeholder = vt.kitty.graphics.unicode.placeholder;
const search_match_alpha = 128;
/// Foreground weight for faint (SGR 2) text; the rest blends to background.
const faint_alpha = 128;

pub const ScrollbarThumb = pixel_raster.ScrollbarThumb;
pub const KittyRenderItem = kitty_graphics.KittyRenderItem;
pub const collectKittyPlacements = kitty_graphics.collectKittyPlacements;
pub const kittyItemsEqual = kitty_graphics.kittyItemsEqual;

const PixelRange = pixel_raster.PixelRange;
const argb = pixel_raster.argb;
const blendCapsule = pixel_raster.blendCapsule;
const blendPixel = pixel_raster.blendPixel;
const blendRgb = pixel_raster.blendRgb;
const blitGlyph = pixel_raster.blitGlyph;
const fillRect = pixel_raster.fillRect;

alloc: std.mem.Allocator,
font: *Font,
text_shaper: TextShaper,
/// Selection colors; a null foreground uses the default foreground.
selection_bg: vt.color.RGB,
selection_fg: ?vt.color.RGB,
/// Highlight colors for the selected scrollback-search match.
search_bg: vt.color.RGB,
search_fg: vt.color.RGB,
/// Explicit text color under a focused block cursor. Null preserves the
/// terminal background fallback.
cursor_text: ?vt.color.RGB,
/// Alpha applied to the default terminal background and window padding.
background_alpha: u8,
/// Whether background alpha also applies to explicit terminal cell
/// backgrounds. Selections, cursors, and renderer overlays stay opaque.
background_alpha_cells: bool,
/// Keyboard focus: unfocused windows draw the cursor as a hollow
/// rectangle regardless of the requested style. Set by the caller.
focused: bool = true,
/// When true, OSC 8 hyperlink cells get an underline affordance.
hyperlink_hints: bool = false,
/// Hovered automatically detected link, in viewport cell coordinates.
link_range: ?LinkRange = null,
/// Selected scrollback-search match, in viewport cell coordinates.
search_range: ?LinkRange = null,
/// Every visible scrollback-search match as a row-major cell mask. The
/// selected match takes precedence over this dimmed highlight.
search_matches: []const bool = &.{},
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
/// Horizontal framebuffer interval glyph blits may modify while a
/// partial row is being painted. Shaping still sees complete runs.
glyph_clip_x: ?PixelRange = null,
/// Grid-local pixel rectangles modified by the last renderDirty call.
rendered_rects: std.ArrayList(PixelRect),
cell_damage_tracker: CellDamageTracker,
track_cell_damage: bool,
partial_cell_raster: bool,
/// Scratch codepoints for cluster-width measurement of overlay text.
codepoint_scratch: std.ArrayList(u21),
/// Scratch codepoints for per-cell grapheme cluster face resolution.
cluster_scratch: std.ArrayList(u21),
/// Final RGBA bytes for scaled Kitty variants. Unlike the terminal-owned
/// source data, these remain valid across renders of the long-lived worker.
kitty_scale_cache: std.AutoHashMapUnmanaged(KittyScaleKey, []u8),
kitty_scale_cache_bytes: usize = 0,
/// Private observable for the focused cache test and profiling.
kitty_scale_count: usize = 0,
/// Physical framebuffer row stride. Zero means the visible width, which is
/// convenient for standalone renderer tests and tightly packed buffers.
buffer_stride: u31 = 0,

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

pub const InitOptions = struct {
    selection_background: ?vt.color.RGB = null,
    selection_foreground: ?vt.color.RGB = null,
    cursor_text: ?vt.color.RGB = null,
    background_alpha: u8 = 255,
    background_alpha_cells: bool = false,
    /// Benchmark escape hatch for comparing the superseded row path.
    track_cell_damage: bool = true,
    partial_cell_raster: bool = true,
};

pub const ShapeStats = TextShaper.ShapeStats;
pub const CellDamageStats = CellDamageTracker.CellDamageStats;

pub const PixelRect = struct {
    x: u31,
    y: u31,
    width: u31,
    height: u31,
};

const CellFingerprint = CellDamageTracker.CellFingerprint;
const CellRange = CellDamageTracker.CellRange;

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
    std.debug.assert(!opts.partial_cell_raster or opts.track_cell_damage);
    return .{
        .alloc = alloc,
        .font = font,
        .text_shaper = try .init(alloc, font),
        .selection_bg = opts.selection_background orelse Config.dark_theme.selection_background,
        .selection_fg = opts.selection_foreground,
        .search_bg = Config.dark_theme.copy_highlight,
        .search_fg = Config.dark_theme.copy_highlight_foreground,
        .cursor_text = opts.cursor_text,
        .background_alpha = opts.background_alpha,
        .background_alpha_cells = opts.background_alpha_cells,
        .fg_scratch = .empty,
        .face_scratch = .empty,
        .reverse_scratch = .empty,
        .row_overhang = .{},
        .rendered_rects = .empty,
        .cell_damage_tracker = .init(alloc),
        .track_cell_damage = opts.track_cell_damage,
        .partial_cell_raster = opts.partial_cell_raster,
        .codepoint_scratch = .empty,
        .cluster_scratch = .empty,
        .kitty_scale_cache = .empty,
        .buffer_stride = 0,
    };
}

pub fn deinit(self: *Renderer) void {
    self.text_shaper.deinit();
    self.fg_scratch.deinit(self.alloc);
    self.face_scratch.deinit(self.alloc);
    self.reverse_scratch.deinit(self.alloc);
    self.row_overhang.deinit(self.alloc);
    self.rendered_rects.deinit(self.alloc);
    self.cell_damage_tracker.deinit();
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

pub fn resetShapeStats(self: *Renderer) void {
    self.text_shaper.resetStats();
}

pub fn shapeStats(self: *const Renderer) ShapeStats {
    return self.text_shaper.readStats();
}

pub fn resetCellDamageStats(self: *Renderer) void {
    self.cell_damage_tracker.resetStats();
}

pub fn cellDamageStats(self: *const Renderer) CellDamageStats {
    return self.cell_damage_tracker.readStats();
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
        if (self.track_cell_damage) try self.snapshotCellFingerprints(state);
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
    if (self.track_cell_damage) try self.snapshotCellFingerprints(state);
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
            if (self.track_cell_damage) try self.snapshotCellFingerprints(state);
            return;
        }
    }

    fillRect(pixels, self.pixelStride(width), width, height, 0, 0, width, height, self.backgroundPixel(state.colors.background));
    if (state.rows == 0 or state.cols == 0) {
        if (self.track_cell_damage) try self.snapshotCellFingerprints(state);
        return;
    }

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
    if (self.track_cell_damage) try self.snapshotCellFingerprints(state);
}

/// Draw only rows marked dirty in `state`, preserving other pixels.
/// A dirty row's neighbors are repainted only when the row_overhang
/// bits demand it: the row above when the dirty row's previous
/// content inked into it, the row below when its ink reaches into the
/// dirty row's freshly cleared strip. Modified grid-pixel rectangles
/// are recorded in `rendered_rects` for repair and surface damage.
pub fn renderDirty(
    self: *Renderer,
    state: *vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixelBufferFits(pixels, self.pixelStride(width), width, height));
    self.rendered_rects.clearRetainingCapacity();
    if (state.rows == 0 or state.cols == 0) return;
    if (self.track_cell_damage) try self.measureCellDamage(state);
    try self.row_overhang.resize(self.alloc, state.rows, false);

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    const all_selections = rows.items(.selection);
    const all_dirty = rows.items(.dirty);
    var rendered_until: usize = 0;
    for (all_dirty[0..state.rows], 0..) |dirty, y| {
        if (!dirty) continue;
        if (self.partial_cell_raster and self.cell_damage_tracker.damageForRow(y) == null) continue;
        const expand_up = y > 0 and self.row_overhang.isSet(y);
        const expand_down = y + 1 < state.rows and self.row_overhang.isSet(y + 1);
        const start = y - @intFromBool(expand_up);
        const end = y + 1 + @intFromBool(expand_down);
        var row = @max(start, rendered_until);
        while (row < end) : (row += 1) {
            const cell_damage = if (self.partial_cell_raster and
                row == y and start == y and end == y + 1)
                self.cell_damage_tracker.damageForRow(y)
            else
                null;
            if (cell_damage) |cell_range| {
                try self.renderRowCells(
                    state,
                    all_cells[row].slice(),
                    all_selections[row],
                    cell_range,
                    @intCast(row),
                    pixels,
                    width,
                    height,
                );
                try self.recordRenderedRect(cell_range, row, state.cols, width, height);
            } else {
                try self.renderRow(
                    state,
                    all_cells[row].slice(),
                    all_selections[row],
                    @intCast(row),
                    pixels,
                    width,
                    height,
                );
                try self.recordRenderedRect(.{ .start = 0, .end = state.cols }, row, state.cols, width, height);
            }
        }
        rendered_until = @max(rendered_until, end);
    }
}

fn recordRenderedRect(
    self: *Renderer,
    cell_range: CellRange,
    row: usize,
    cols: usize,
    width: u31,
    height: u31,
) !void {
    const cell_width: u64 = self.font.cell_width;
    const cell_height: u64 = self.font.cell_height;
    const x_start: u31 = @intCast(@min(@as(u64, cell_range.start) * cell_width, width));
    const x_end: u31 = if (cell_range.end == cols)
        width
    else
        @intCast(@min(@as(u64, cell_range.end) * cell_width, width));
    var y_start: u31 = @intCast(@min(@as(u64, row) * cell_height, height));
    const y_end: u31 = @intCast(@min(@as(u64, row + 1) * cell_height, height));
    if (self.overhang_scratch) y_start -|= self.font.cell_height;
    if (x_end <= x_start or y_end <= y_start) return;
    try self.rendered_rects.append(self.alloc, .{
        .x = @intCast(x_start),
        .y = @intCast(y_start),
        .width = @intCast(x_end - x_start),
        .height = @intCast(y_end - y_start),
    });
}

fn snapshotCellFingerprints(self: *Renderer, state: *const vt.RenderState) !void {
    const rows: usize = state.rows;
    const cols: usize = state.cols;
    try self.cell_damage_tracker.beginSnapshot(rows, cols, state.colors);

    const row_data = state.row_data.slice();
    const all_cells = row_data.items(.cells);
    const all_selections = row_data.items(.selection);
    for (0..rows) |y| {
        const cells = all_cells[y].slice();
        for (0..cols) |x| {
            self.cell_damage_tracker.snapshotCell(
                y,
                x,
                self.cellFingerprint(state, cells, all_selections[y], x, @intCast(y)),
            );
        }
    }
}

fn measureCellDamage(self: *Renderer, state: *const vt.RenderState) !void {
    const rows: usize = state.rows;
    const cols: usize = state.cols;
    const row_data = state.row_data.slice();
    const all_cells = row_data.items(.cells);
    const all_selections = row_data.items(.selection);
    const all_dirty = row_data.items(.dirty);
    switch (try self.cell_damage_tracker.beginMeasurement(rows, cols, state.colors, all_dirty)) {
        .snapshot => {
            for (0..rows) |y| {
                const cells = all_cells[y].slice();
                for (0..cols) |x| {
                    self.cell_damage_tracker.snapshotCell(
                        y,
                        x,
                        self.cellFingerprint(state, cells, all_selections[y], x, @intCast(y)),
                    );
                }
            }
            return;
        },
        .compare => {},
    }

    for (all_dirty[0..rows], 0..) |dirty, y| {
        if (!dirty) continue;
        const cells = all_cells[y].slice();
        const fingerprints = try self.cell_damage_tracker.rowScratch(cols);
        for (0..cols) |x| {
            fingerprints[x] = self.cellFingerprint(
                state,
                cells,
                all_selections[y],
                x,
                @intCast(y),
            );
        }
        self.cell_damage_tracker.measureRow(y, cells.items(.raw), fingerprints);
    }
}

fn cellFingerprint(
    self: *const Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    x: usize,
    y: u31,
) CellFingerprint {
    const raw = cells.items(.raw)[x];
    const selected = if (selection) |range| x >= range[0] and x <= range[1] else false;
    const cursor_here = cursor: {
        if (!state.cursor.visible) break :cursor false;
        const viewport = state.cursor.viewport orelse break :cursor false;
        if (viewport.y != y) break :cursor false;
        break :cursor x == viewport.x -| @intFromBool(viewport.wide_tail);
    };
    const hyperlink = (self.hyperlink_hints and raw.hyperlink) or
        if (self.link_range) |range| range.contains(x, y) else false;
    const search_selected = if (self.search_range) |range| range.contains(x, y) else false;
    const search_index = @as(usize, y) * state.cols + x;
    const search_match = search_index < self.search_matches.len and self.search_matches[search_index];
    const visual = @as(u8, @intFromBool(selected)) |
        @as(u8, @intFromBool(cursor_here)) << 1 |
        @as(u8, @intFromBool(cursor_here and self.focused)) << 2 |
        @as(u8, @intFromBool(hyperlink)) << 3 |
        @as(u8, @intFromBool(search_selected)) << 4 |
        @as(u8, @intFromBool(search_match)) << 5;
    return .{
        .raw = raw,
        .style = if (raw.style_id == 0) .{} else cells.items(.style)[x],
        .grapheme = if (raw.content_tag == .codepoint_grapheme)
            std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cells.items(.grapheme)[x]))
        else
            0,
        .visual = visual,
        .cursor_style = if (cursor_here) @intCast(@intFromEnum(state.cursor.visual_style)) else 0,
    };
}

/// Move renderer-owned row state with a framebuffer scroll. Fingerprints
/// for newly exposed rows are invalid until renderDirty repaints them.
pub fn shiftCellState(self: *Renderer, rows: usize, cols: usize, shift_rows: isize) !void {
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

    if (self.track_cell_damage) try self.cell_damage_tracker.shift(rows, cols, shift_rows);
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
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), glyph_constraints.isSymbol(cp));
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
                self.glyph_clip_x,
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

/// Draw a macOS-style overlay scrollbar: a narrow adaptive pill with no
/// track. Geometry is in full-surface physical pixels rather than grid-local
/// pixels, so the thumb stays against the window edge when padding is used.
pub fn renderScrollbarThumb(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
    thumb: ScrollbarThumb,
) void {
    blendCapsule(
        pixels,
        self.pixelStride(width),
        width,
        height,
        thumb,
        argb(state.colors.foreground),
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
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), glyph_constraints.isSymbol(cp));
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
                self.glyph_clip_x,
            );
        }
        x += span;
    }
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

fn renderRowCells(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    cell_range: CellRange,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(self.glyph_clip_x == null);
    self.glyph_clip_x = .{
        .start = @intCast(cell_range.start * self.font.cell_width),
        .end = @intCast(cell_range.end * self.font.cell_width),
    };
    defer self.glyph_clip_x = null;
    try self.prepareRowCells(state, cells, selection, cell_range, y, pixels, width, height, .all);
    try self.renderRowForegroundCells(state, cells, cell_range, y, pixels, width, height);
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
    return self.prepareRowCells(
        state,
        cells,
        selection,
        .{ .start = 0, .end = @min(@as(usize, state.cols), cells.len) },
        y,
        pixels,
        width,
        height,
        backgrounds,
    );
}

fn prepareRowCells(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    cell_range: CellRange,
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
    std.debug.assert(cell_range.start <= cell_range.end and cell_range.end <= cols);

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
        // Faint (SGR 2) dims the glyph halfway toward its background.
        if (style.flags.faint) fg = blendRgb(fg, bg orelse colors.background, faint_alpha);
        var background_uses_alpha = self.background_alpha_cells and bg != null;
        // Selection overrides cell colors: fixed background, default
        // foreground, so selected text reads uniformly.
        const selected = if (selection) |sel| x >= sel[0] and x <= sel[1] else false;
        const search_selected = if (self.search_range) |range| range.contains(x, y) else false;
        const search_index = @as(usize, y) * state.cols + x;
        const search_match = search_index < self.search_matches.len and self.search_matches[search_index];
        var dim_search_bg = false;
        if (selected) {
            bg = self.selection_bg;
            fg = self.selection_fg orelse colors.foreground;
            reverse_color_glyph = false;
            background_uses_alpha = false;
        } else if (search_selected) {
            bg = self.search_bg;
            fg = self.search_fg;
            reverse_color_glyph = false;
            background_uses_alpha = false;
        } else if (search_match) {
            dim_search_bg = true;
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
            dim_search_bg = false;
            background_uses_alpha = false;
        }
        self.fg_scratch.items[x] = fg;
        self.reverse_scratch.items[x] = reverse_color_glyph;
        if (backgrounds != .none and x >= cell_range.start and x < cell_range.end) {
            const color: ?u32 = if (dim_search_bg) color: {
                const mixed = blendRgb(self.search_bg, bg orelse colors.background, search_match_alpha);
                break :color if (bg == null or background_uses_alpha)
                    self.backgroundPixel(mixed)
                else
                    argb(mixed);
            } else if (bg) |bg_color|
                if (background_uses_alpha) self.backgroundPixel(bg_color) else argb(bg_color)
            else switch (backgrounds) {
                .all => self.backgroundPixel(colors.background),
                else => null,
            };
            if (color) |pixel| {
                const px_start = @as(u31, @intCast(x)) * font.cell_width;
                const px_end = px_start + font.cell_width * glyph_constraints.cellSpan(raws[x]);
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
    if (backgrounds == .all and cell_range.end == cols) {
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
    return self.renderRowForegroundCells(
        state,
        cells,
        .{ .start = 0, .end = @min(@as(usize, state.cols), cells.len) },
        y,
        pixels,
        width,
        height,
    );
}

fn renderRowForegroundCells(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    cell_range: CellRange,
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
    std.debug.assert(cell_range.start <= cell_range.end and cell_range.end <= cols);
    const range_start: u31 = @intCast(cell_range.start);
    const range_end: u31 = @intCast(cell_range.end);
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
            if (run_start <= range_end and x >= range_start) {
                try self.drawRun(raws, styles, graphemes, run_start, x, cols, y, pixels, width, height);
            }
            run_start = if (has_text) x else x + 1;
        }
    }
    if (run_start <= range_end and cols >= range_start) {
        try self.drawRun(raws, styles, graphemes, run_start, cols, cols, y, pixels, width, height);
    }

    // Decoration pass: underlines, strikethrough, overline, and hyperlink
    // hints overlay the glyphs, in the style's underline color (or the
    // resolved fg).
    for (cell_range.start..cell_range.end) |dx| {
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
    if (cursor_x) |cx| cursor: {
        if (cx < range_start or cx >= range_end) break :cursor;
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
        self.glyph_clip_x,
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
            const cell_span: u2 = @intCast(@min(glyph_constraints.cellSpan(raw), 2));
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
                self.glyph_clip_x,
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
    try self.text_shaper.beginKey(face_index);
    var non_space = false;
    for (start..end) |x| {
        const raw = raws[x];
        if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
        const cp = raw.content.codepoint.data;
        if (cp != ' ' or raw.content_tag == .codepoint_grapheme) non_space = true;
        const rel: u32 = @intCast(x - start);
        try self.text_shaper.appendKeyCodepoints(rel, cp, if (raw.content_tag == .codepoint_grapheme) graphemes[x] else &.{});
    }
    if (!non_space) return;

    const shaped = try self.text_shaper.shape(face_index, face_style, end - start);

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
        const constraint_width = glyph_constraints.constraintWidth(raws, cluster_x, cols);
        const cp = glyph_constraints.cellCodepoint(raws[cluster_x]);
        const g = font.face(sg.face).glyph(
            self.alloc,
            sg.glyph,
            constraint_width,
            glyph_constraints.isSymbol(cp),
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
            self.glyph_clip_x,
        );
        pen_x += sg.x_advance;
    }
}

fn overlayCodepoints(self: *Renderer, text: []const u8) ![]const u21 {
    self.codepoint_scratch.clearRetainingCapacity();
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| try self.codepoint_scratch.append(self.alloc, cp);
    return self.codepoint_scratch.items;
}

/// Copy pixels into a buffer the CPU will not read back (a wl_shm
/// buffer). Large copies use non-temporal stores on x86_64: they skip
/// the read-for-ownership of every destination cache line (about a
/// third of the bus traffic) and keep the copy from evicting the
/// render working set.
pub fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    return pixel_copy.copyPixels(dst, src);
}

/// Pack a background color in wl_shm's premultiplied ARGB8888 form.
pub fn backgroundPixel(self: *const Renderer, rgb: vt.color.RGB) u32 {
    return pixel_raster.premultipliedArgb(rgb, self.background_alpha);
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

    try renderer.text_shaper.beginKey(keycap_face);
    try renderer.text_shaper.appendKeyCodepoints(0, raws[0].content.codepoint.data, graphemes[0]);
    try testing.expectEqualSlices(u32, &.{ keycap_face, 0, '1', 0, 0xFE0F, 0, 0x20E3 }, renderer.text_shaper.keyItems());
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

        try renderer.text_shaper.beginKey(case_face);
        try renderer.text_shaper.appendKeyCodepoints(
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

        try renderer.text_shaper.beginKey(case_face);
        try renderer.text_shaper.appendKeyCodepoints(
            0,
            raws[0].content.codepoint.data,
            if (raws[0].content_tag == .codepoint_grapheme) graphemes[0] else &.{},
        );
        try testing.expect(try renderer.shapeKeyHasColorGlyph(case_face));

        try renderer.render(&state, pixels, width, height);
    }
}

fn shapeKeyHasColorGlyph(self: *Renderer, face_index: u16) !bool {
    const shaped = try self.text_shaper.shapeRun(face_index, .regular);
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
        try testing.expectEqual(@as(u21, 0), glyph_constraints.cellCodepoint(raws[2]));
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

test "background opacity cells controls explicit cell backgrounds" {
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
    try std.testing.expectEqual(argb(state.colors.palette[1]), explicit_bg);
    try std.testing.expectEqual(renderer.backgroundPixel(state.colors.background), default_bg);

    renderer.background_alpha_cells = true;
    try renderer.render(&state, pixels, width, height);
    const faded_explicit_bg = pixels[@as(usize, y) * width + font.cell_width / 2];
    try std.testing.expectEqual(renderer.backgroundPixel(state.colors.palette[1]), faded_explicit_bg);
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

    var renderer: Renderer = try .init(alloc, &font, .{
        .selection_background = selection_bg,
        .background_alpha = 128,
        .background_alpha_cells = true,
    });
    defer renderer.deinit();

    const width: u31 = font.cell_width * 8;
    const height: u31 = font.cell_height * 5;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try renderer.render(&state, pixels, width, height);

    const selected = argb(selection_bg);
    const background = renderer.backgroundPixel(state.colors.background);
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

    const items = try collectKittyPlacements(&font, alloc, &term);
    defer alloc.free(items);
    try renderer.renderWithKittyItems(&state, items, pixels, width, height);

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

    const items = try collectKittyPlacements(&font, alloc, &term);
    defer alloc.free(items);
    try renderer.renderWithKittyItems(&state, items, pixels, width, height);

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

test "cell damage render matches full render for sparse row churn" {
    const alloc = std.testing.allocator;
    const cols = 48;
    const rows = 6;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var partial: Renderer = try .init(alloc, &font, .{
        .track_cell_damage = true,
        .partial_cell_raster = true,
    });
    defer partial.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height * rows;
    const partial_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(partial_pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);

    for (0..20) |frame| {
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try output.writer.writeAll("\x1b[H");
        for (0..rows) |y| {
            if (y > 0) try output.writer.writeAll("\r\n");
            try output.writer.print("{d:0>6} stable row {d:0>2}   ", .{ frame, y });
        }
        stream.nextSlice(output.writer.buffered());
        try state.update(alloc, &term);

        if (frame == 0) {
            try partial.render(&state, partial_pixels, width, height);
        } else {
            try partial.renderDirty(&state, partial_pixels, width, height);
        }
        try reference.render(&state, full_pixels, width, height);
        try std.testing.expectEqualSlices(u32, full_pixels, partial_pixels);

        for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
        state.dirty = .false;
    }
}

test "cell damage repairs rotating stale buffers" {
    const alloc = std.testing.allocator;
    const cols = 24;
    const rows = 3;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var partial: Renderer = try .init(alloc, &font, .{});
    defer partial.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height * rows;
    const frame_len = @as(usize, width) * height;
    const buffers = try alloc.alloc(u32, frame_len * 3);
    defer alloc.free(buffers);
    const full_pixels = try alloc.alloc(u32, frame_len);
    defer alloc.free(full_pixels);
    var history: [2]std.ArrayList(PixelRect) = .{ .empty, .empty };
    defer for (&history) |*rects| rects.deinit(alloc);

    stream.nextSlice("\x1b[?25l\x1b[H0000 stable row 0\r\n0000 stable row 1\r\n0000 stable row 2");
    try state.update(alloc, &term);
    try partial.render(&state, buffers[0..frame_len], width, height);
    @memcpy(buffers[frame_len .. frame_len * 2], buffers[0..frame_len]);
    @memcpy(buffers[frame_len * 2 .. frame_len * 3], buffers[0..frame_len]);
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;

    for (0..12) |frame| {
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try output.writer.print(
            "\x1b[H{d:0>4} stable row 0\r\n{d:0>4} stable row 1\r\n{d:0>4} stable row 2",
            .{ frame + 1, frame + 1, frame + 1 },
        );
        stream.nextSlice(output.writer.buffered());
        try state.update(alloc, &term);

        const target_index = (frame + 1) % 3;
        const newest_index = frame % 3;
        const target = buffers[target_index * frame_len ..][0..frame_len];
        const newest = buffers[newest_index * frame_len ..][0..frame_len];
        for (history[0..@min(frame, history.len)]) |rects| {
            for (rects.items) |rect| {
                for (rect.y..rect.y + rect.height) |y| {
                    const offset = @as(usize, y) * width + rect.x;
                    @memcpy(target[offset..][0..rect.width], newest[offset..][0..rect.width]);
                }
            }
        }

        try partial.renderDirty(&state, target, width, height);
        try reference.render(&state, full_pixels, width, height);
        try std.testing.expectEqualSlices(u32, full_pixels, target);

        history[1].clearRetainingCapacity();
        try history[1].appendSlice(alloc, history[0].items);
        history[0].clearRetainingCapacity();
        try history[0].appendSlice(alloc, partial.rendered_rects.items);
        for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
        state.dirty = .false;
    }
}

test "cell damage clips an adjacent text run to the cleared interval" {
    const alloc = std.testing.allocator;
    const cols = 12;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l aaaaaaaaaaa");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var partial: Renderer = try .init(alloc, &font, .{
        .track_cell_damage = true,
        .partial_cell_raster = true,
    });
    defer partial.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height;
    const partial_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(partial_pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);

    try partial.render(&state, partial_pixels, width, height);
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;

    // Changing this non-text cell pads damage one cell into the adjacent
    // shaping run. The whole run must be shaped, but only the cleared two
    // cells may be blended into the existing framebuffer.
    stream.nextSlice("\x1b[H\x1b[41m \x1b[0m");
    try state.update(alloc, &term);
    try partial.renderDirty(&state, partial_pixels, width, height);
    try std.testing.expectEqual(CellRange{ .start = 0, .end = 2 }, partial.cell_damage_tracker.damageForRow(0).?);

    try reference.render(&state, full_pixels, width, height);
    try std.testing.expectEqualSlices(u32, full_pixels, partial_pixels);
}

test "cell damage redraws symbol ink spilling into the interval" {
    const alloc = std.testing.allocator;
    const cols = 10;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l      x");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    try std.testing.expectEqual(
        @as(u2, 2),
        glyph_constraints.constraintWidth(state.row_data.get(0).cells.items(.raw), 5, cols),
    );

    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var partial: Renderer = try .init(alloc, &font, .{});
    defer partial.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height;
    const partial_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(partial_pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);
    try partial.render(&state, partial_pixels, width, height);
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;

    // The symbol at cell 5 renders across the space at cell 6. Damage for
    // cell 7 clears cell 6 as bearing slack, so the adjacent symbol run
    // must be redrawn even though its cells do not overlap the interval.
    stream.nextSlice("\x1b[1;8Hy");
    try state.update(alloc, &term);
    try partial.renderDirty(&state, partial_pixels, width, height);
    try std.testing.expectEqual(CellRange{ .start = 6, .end = 9 }, partial.cell_damage_tracker.damageForRow(0).?);

    try reference.render(&state, full_pixels, width, height);
    try std.testing.expectEqualSlices(u32, full_pixels, partial_pixels);
}

test "scroll invalidates newly exposed cell fingerprints" {
    const alloc = std.testing.allocator;
    const cols = 4;
    const rows = 3;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height * rows;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);
    try renderer.render(&state, pixels, width, height);

    try renderer.shiftCellState(rows, cols, 1);
    try std.testing.expect(renderer.cell_damage_tracker.fingerprintIsValid(0));
    try std.testing.expect(renderer.cell_damage_tracker.fingerprintIsValid(1));
    try std.testing.expect(!renderer.cell_damage_tracker.fingerprintIsValid(2));

    const bottom_start = @as(usize, 2 * font.cell_height) * width;
    @memset(pixels[bottom_start..], 0xffabcdef);
    for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    state.row_data.items(.dirty)[2] = true;
    state.dirty = .partial;
    try renderer.renderDirty(&state, pixels, width, height);
    try std.testing.expectEqual(CellRange{ .start = 0, .end = cols }, renderer.cell_damage_tracker.damageForRow(2).?);

    try reference.render(&state, full_pixels, width, height);
    try std.testing.expectEqualSlices(u32, full_pixels, pixels);
}

test "cell damage repaints dirty rows after terminal colors change" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?25labcd");

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    var font: Font = try .init(alloc, "monospace", 16);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();
    var reference: Renderer = try .init(alloc, &font, .{});
    defer reference.deinit();

    const width: u31 = font.cell_width * 4;
    const height: u31 = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    const full_pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(full_pixels);
    try renderer.render(&state, pixels, width, height);

    state.colors.background = .{ .r = 12, .g = 34, .b = 56 };
    state.row_data.items(.dirty)[0] = true;
    state.dirty = .partial;
    try renderer.renderDirty(&state, pixels, width, height);
    try std.testing.expectEqual(CellRange{ .start = 0, .end = 4 }, renderer.cell_damage_tracker.damageForRow(0).?);

    try reference.render(&state, full_pixels, width, height);
    try std.testing.expectEqualSlices(u32, full_pixels, pixels);
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
    renderer.search_matches = &.{ true, false };

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

test "unselected search match tints its existing background" {
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
    renderer.search_matches = &.{ true, false };

    const width = font.cell_width * 2;
    const height = font.cell_height;
    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    try renderer.render(&state, pixels, width, height);

    const expected = renderer.backgroundPixel(blendRgb(
        renderer.search_bg,
        state.colors.background,
        search_match_alpha,
    ));
    var highlighted: usize = 0;
    for (0..height) |y| {
        for (0..font.cell_width) |x| {
            if (pixels[y * width + x] == expected) highlighted += 1;
        }
    }
    try std.testing.expect(highlighted > 0);
    try std.testing.expect(expected != argb(renderer.search_bg));
}
