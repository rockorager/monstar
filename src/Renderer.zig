//! Renders a ghostty-vt RenderState into an ARGB8888 pixel buffer.
//!
//! Per row: a background pass fills cell backgrounds, then text runs of
//! equal style are shaped with HarfBuzz and the resulting glyphs are
//! alpha-blended at their cells. Glyph clusters are snapped to their cell
//! origin so the grid stays aligned while ligatures still work.

const Renderer = @This();

const std = @import("std");
const c = @import("c");
const vt = @import("ghostty-vt");
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
/// Keyboard focus: unfocused windows draw the cursor as a hollow
/// rectangle regardless of the requested style. Set by the caller.
focused: bool = true,
/// When true, OSC 8 hyperlink cells get an underline affordance.
hyperlink_hints: bool = false,
/// Per-cell resolved foreground colors for the row being rendered.
fg_scratch: std.ArrayList(vt.color.RGB),
/// Per-cell font face indices for the row being rendered.
face_scratch: std.ArrayList(u16),
/// Per-cell reverse-video state for color glyphs, including block cursor.
reverse_scratch: std.ArrayList(bool),

pub const InitOptions = struct {
    selection_background: ?vt.color.RGB = null,
    selection_foreground: ?vt.color.RGB = null,
};

pub fn init(alloc: std.mem.Allocator, font: *Font, opts: InitOptions) !Renderer {
    const hb_buf = c.hb_buffer_create() orelse return error.OutOfMemory;
    if (c.hb_buffer_allocation_successful(hb_buf) == 0) return error.OutOfMemory;
    return .{
        .alloc = alloc,
        .font = font,
        .hb_buf = hb_buf,
        .selection_bg = opts.selection_background orelse .{ .r = 0x33, .g = 0x46, .b = 0x7c },
        .selection_fg = opts.selection_foreground,
        .fg_scratch = .empty,
        .face_scratch = .empty,
        .reverse_scratch = .empty,
    };
}

pub fn deinit(self: *Renderer) void {
    c.hb_buffer_destroy(self.hb_buf);
    self.fg_scratch.deinit(self.alloc);
    self.face_scratch.deinit(self.alloc);
    self.reverse_scratch.deinit(self.alloc);
    self.* = undefined;
}

/// Draw the full render state into `pixels` (width*height, stride == width).
pub fn render(
    self: *Renderer,
    state: *const vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height);

    @memset(pixels, argb(state.colors.background));
    if (state.rows == 0 or state.cols == 0) return;

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
}

pub fn renderWithKittyGraphics(
    self: *Renderer,
    state: *const vt.RenderState,
    terminal: *const vt.Terminal,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height);

    @memset(pixels, argb(state.colors.background));
    if (state.rows == 0 or state.cols == 0) return;

    try self.renderKittyGraphics(terminal, pixels, width, height, .below_bg);

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
            true,
        );
    }

    try self.renderKittyGraphics(terminal, pixels, width, height, .below_text);

    for (0..state.rows) |y| {
        try self.prepareRow(
            state,
            all_cells[y].slice(),
            all_selections[y],
            @intCast(y),
            pixels,
            width,
            height,
            false,
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

    try self.renderKittyGraphics(terminal, pixels, width, height, .above_text);
}

/// Draw only rows marked dirty in `state`, preserving other pixels.
/// Dirty rows are expanded by one neighboring row to cover glyph and
/// sprite overhang from the previous frame.
pub fn renderDirty(
    self: *Renderer,
    state: *vt.RenderState,
    pixels: []u32,
    width: u31,
    height: u31,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    if (state.rows == 0 or state.cols == 0) return;

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    const all_selections = rows.items(.selection);
    const all_dirty = rows.items(.dirty);
    var rendered_until: usize = 0;
    for (all_dirty[0..state.rows], 0..) |dirty, y| {
        if (!dirty) continue;
        const start = if (y == 0) y else y - 1;
        const end = @min(@as(usize, state.rows), y + 2);
        var row = @max(start, rendered_until);
        while (row < end) : (row += 1) {
            self.clearRow(state, @intCast(row), pixels, width, height);
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
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        const span = codepointCellWidth(cp);
        if (span == 0) continue;
        if (x >= state.cols) break;
        const clipped_span: u31 = @min(span, state.cols - x);

        fillRect(
            pixels,
            width,
            height,
            x * self.font.cell_width,
            y * self.font.cell_height,
            clipped_span * self.font.cell_width,
            self.font.cell_height,
            argb(state.colors.background),
        );

        const face_idx = self.font.faceForCodepoint(self.alloc, cp);
        const face = self.font.face(face_idx);
        const glyph_idx = c.FT_Get_Char_Index(face.ft_face, cp);
        if (glyph_idx != 0) {
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), isSymbol(cp));
            blitGlyph(
                pixels,
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
    if (uri.len == 0 or width == 0 or height < self.font.cell_height) return;

    const cols: u31 = @max(1, width / self.font.cell_width);
    const text_start: u31 = @intFromBool(cols > 1);
    const text_limit: u31 = if (cols > 2) cols - 1 else cols;
    const y: u31 = height - self.font.cell_height;
    const baseline_y: i32 = @as(i32, @intCast(y)) + self.font.baseline;
    const bg = self.selection_bg;
    const fg = self.selection_fg orelse state.colors.foreground;
    var x: u31 = text_start;

    fillRect(
        pixels,
        width,
        height,
        0,
        y,
        text_start * self.font.cell_width,
        self.font.cell_height,
        argb(bg),
    );

    var it = (try std.unicode.Utf8View.init(uri)).iterator();
    while (it.nextCodepoint()) |cp| {
        const span = codepointCellWidth(cp);
        if (span == 0) continue;
        if (x >= text_limit) break;
        const clipped_span: u31 = @min(span, text_limit - x);

        fillRect(
            pixels,
            width,
            height,
            x * self.font.cell_width,
            y,
            clipped_span * self.font.cell_width,
            self.font.cell_height,
            argb(bg),
        );

        const face_idx = self.font.faceForCodepoint(self.alloc, cp);
        const face = self.font.face(face_idx);
        const glyph_idx = c.FT_Get_Char_Index(face.ft_face, cp);
        if (glyph_idx != 0) {
            const g = try face.glyph(self.alloc, glyph_idx, @intCast(@min(span, 2)), isSymbol(cp));
            blitGlyph(
                pixels,
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

    if (x < cols) {
        fillRect(
            pixels,
            width,
            height,
            x * self.font.cell_width,
            y,
            self.font.cell_width,
            self.font.cell_height,
            argb(bg),
        );
    }
}

fn renderKittyGraphics(
    self: *Renderer,
    terminal: *const vt.Terminal,
    pixels: []u32,
    width: u31,
    height: u31,
    layer: KittyGraphicsLayer,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height);

    const storage = &terminal.screens.active.kitty_images;
    if (storage.placements.count() == 0) return;

    var placements: std.ArrayList(KittyRenderItem) = .empty;
    defer placements.deinit(self.alloc);

    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        switch (entry.value_ptr.location) {
            .pin => {},
            .virtual => continue,
        }
        if (!layer.matches(entry.value_ptr.z)) continue;
        const viewport = kittyPlacementViewport(terminal, entry.value_ptr.*, image, self.font.cell_width, self.font.cell_height) orelse continue;
        if (!viewport.visible) continue;
        try placements.append(self.alloc, .{
            .image_id = entry.key_ptr.image_id,
            .placement_id = entry.key_ptr.placement_id.id,
            .z = entry.value_ptr.z,
            .image = image,
            .viewport = viewport,
        });
    }

    if (layer.matches(-1)) {
        try self.collectKittyVirtualPlacements(terminal, &placements);
    }

    std.mem.sortUnstable(KittyRenderItem, placements.items, {}, kittyRenderItemLessThan);
    for (placements.items) |item| try self.renderKittyPlacement(pixels, width, height, item.image, item.viewport);
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

const KittyRenderItem = struct {
    image_id: u32,
    placement_id: u32,
    z: i32,
    image: KittyImage,
    viewport: KittyPlacementViewport,
};

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

    var source = try self.alloc.alloc(u8, @as(usize, source_width) * source_height * 4);
    defer self.alloc.free(source);
    if (!copyKittySourceRgba(&source, image, viewport)) return;

    const scaled = try self.alloc.alloc(u8, @as(usize, dest_width) * dest_height * 4);
    defer self.alloc.free(scaled);
    try resizeRgba(source, source_width, source_height, scaled, dest_width, dest_height);

    const dest_x = viewport.viewport_col * @as(i32, @intCast(self.font.cell_width)) +
        @as(i32, @intCast(viewport.offset_x));
    const dest_y = viewport.viewport_row * @as(i32, @intCast(self.font.cell_height)) +
        @as(i32, @intCast(viewport.offset_y));
    blendRgba(pixels, width, height, scaled, dest_width, dest_height, dest_x, dest_y);
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
        .source_width = @min(if (placement.source_width > 0) placement.source_width else image.width, image.width - source_x),
        .source_height = @min(if (placement.source_height > 0) placement.source_height else image.height, image.height - source_y),
    };
}

fn collectKittyVirtualPlacements(
    self: *Renderer,
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
            self.font.cell_width,
            self.font.cell_height,
        ) catch |err| {
            log.warn("error rendering kitty virtual placement: {}", .{err});
            continue;
        };
        const viewport = kittyVirtualPlacementViewport(terminal, render_placement) orelse continue;
        if (!viewport.visible) continue;
        try placements.append(self.alloc, .{
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

            const dst_idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
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
    const r = (@as(u32, src[0]) * alpha + dst_r * inv_alpha + 127) / 255;
    const g = (@as(u32, src[1]) * alpha + dst_g * inv_alpha + 127) / 255;
    const b = (@as(u32, src[2]) * alpha + dst_b * inv_alpha + 127) / 255;
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

fn clearRow(
    self: *Renderer,
    state: *const vt.RenderState,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
) void {
    fillRect(
        pixels,
        width,
        height,
        0,
        y * self.font.cell_height,
        width,
        self.font.cell_height,
        argb(state.colors.background),
    );
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
    try self.prepareRow(state, cells, selection, y, pixels, width, height, true);
    try self.renderRowForeground(state, cells, y, pixels, width, height);
}

fn prepareRow(
    self: *Renderer,
    state: *const vt.RenderState,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    selection: ?[2]vt.size.CellCountInt,
    y: u31,
    pixels: []u32,
    width: u31,
    height: u31,
    draw_backgrounds: bool,
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

    // Background + foreground-color + face-resolution pass.
    try self.fg_scratch.resize(self.alloc, cols);
    try self.face_scratch.resize(self.alloc, cols);
    try self.reverse_scratch.resize(self.alloc, cols);
    for (0..cols) |x| {
        const style: vt.Style = if (raws[x].style_id == 0) .{} else styles[x];
        self.face_scratch.items[x] = face: {
            switch (raws[x].content_tag) {
                .codepoint, .codepoint_grapheme => {},
                else => break :face 0,
            }
            const cp = raws[x].content.codepoint.data;
            if (cp == 0 or cp == ' ' or cp == kitty_placeholder) break :face 0;
            break :face self.font.faceForCodepointStyle(
                self.alloc,
                cp,
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
        if (selected) {
            bg = self.selection_bg;
            fg = self.selection_fg orelse colors.foreground;
            reverse_color_glyph = false;
        }
        // Focused block cursor: swap in the cursor color, invert the
        // glyph. All other cursor shapes (and any unfocused cursor)
        // overlay a sprite after drawing instead.
        if (cursor_x != null and cursor_x.? == x and
            state.cursor.visual_style == .block and self.focused)
        {
            bg = colors.cursor orelse colors.foreground;
            fg = colors.background;
            reverse_color_glyph = false;
        }
        self.fg_scratch.items[x] = fg;
        self.reverse_scratch.items[x] = reverse_color_glyph;
        if (draw_backgrounds and bg != null) {
            const bg_color = bg.?;
            fillRect(
                pixels,
                width,
                height,
                @as(u31, @intCast(x)) * font.cell_width,
                y * font.cell_height,
                font.cell_width * cellSpan(raws[x]),
                font.cell_height,
                argb(bg_color),
            );
        }
    }
}

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
            .codepoint, .codepoint_grapheme => raws[x].content.codepoint.data != 0 and
                raws[x].content.codepoint.data != kitty_placeholder,
            else => false,
        };
        const breaks_run = !has_text or
            raws[x].style_id != raws[run_start].style_id or
            faces[x] != faces[run_start];
        if (breaks_run) {
            try self.drawRun(raws, graphemes, run_start, x, y, pixels, width, height);
            run_start = if (has_text) x else x + 1;
        }
    }
    try self.drawRun(raws, graphemes, run_start, cols, y, pixels, width, height);

    // Decoration pass: underlines, strikethrough, overline, and hyperlink
    // hints overlay the glyphs, in the style's underline color (or the
    // resolved fg).
    for (0..cols) |dx| {
        const show_hyperlink = self.hyperlink_hints and raws[dx].hyperlink;
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
    const baseline_y: i32 = @as(i32, y) * font.cell_height + font.baseline;
    blitGlyph(
        pixels,
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
    graphemes: []const []const u21,
    start: u31,
    end: u31,
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
            blitGlyph(
                pixels,
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

    const face = font.face(self.face_scratch.items[start]);

    c.hb_buffer_clear_contents(self.hb_buf);
    var non_space = false;
    for (start..end) |x| {
        const raw = raws[x];
        if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
        const cp = raw.content.codepoint.data;
        if (cp != ' ') non_space = true;
        c.hb_buffer_add(self.hb_buf, cp, @intCast(x));
        if (raw.content_tag == .codepoint_grapheme) {
            for (graphemes[x]) |extra| c.hb_buffer_add(self.hb_buf, extra, @intCast(x));
        }
    }
    if (!non_space) return;

    c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_guess_segment_properties(self.hb_buf);
    c.hb_shape(face.hb_font, self.hb_buf, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);
    if (glyph_count == 0) return;

    const baseline_y: i32 = @as(i32, y) * font.cell_height + font.baseline;
    var pen_x: i32 = 0;
    var cluster: u32 = std.math.maxInt(u32);
    for (infos[0..glyph_count], positions[0..glyph_count]) |info, pos| {
        // Snap each new cluster to its cell so the grid stays aligned.
        if (info.cluster != cluster) {
            cluster = info.cluster;
            pen_x = @as(i32, @intCast(cluster)) * font.cell_width;
        }
        const cluster_x: usize = @intCast(cluster);
        const constraint_width = constraintWidth(raws, cluster_x, raws.len);
        const g = try face.glyph(
            self.alloc,
            info.codepoint,
            constraint_width,
            isSymbol(cellCodepoint(raws[cluster_x])),
        );
        blitGlyph(
            pixels,
            width,
            height,
            g,
            pen_x + (pos.x_offset >> 6) + g.bearing_x,
            baseline_y - (pos.y_offset >> 6) - g.bearing_y,
            argb(self.fg_scratch.items[cluster]),
            self.reverse_scratch.items[cluster],
        );
        pen_x += pos.x_advance >> 6;
    }
}

/// How many cells a cell's background covers (wide chars span two).
fn cellSpan(cell: vt.Cell) u31 {
    return if (cell.wide == .wide) 2 else 1;
}

fn codepointCellWidth(cp: u21) u31 {
    if (cp < 0x20) return 0;
    if (isCombiningCodepoint(cp)) return 0;
    return if (isWideCodepoint(cp)) 2 else 1;
}

fn isCombiningCodepoint(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f);
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115f) or
        cp == 0x2329 or cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd);
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

fn argb(rgb: vt.color.RGB) u32 {
    return 0xff000000 |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

fn fillRect(
    pixels: []u32,
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
        @memset(pixels[row * buf_width + x .. row * buf_width + x_end], color);
    }
}

/// Alpha-blend an 8-bit coverage bitmap in `color` over the buffer.
fn blitGlyph(
    pixels: []u32,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    reverse_color_glyph: bool,
) void {
    switch (g.format) {
        .alpha => blitAlphaGlyph(pixels, buf_width, buf_height, g, x0, y0, color),
        .bgra => if (reverse_color_glyph)
            blitBgraGlyphAsAlpha(pixels, buf_width, buf_height, g, x0, y0, color)
        else
            blitBgraGlyph(pixels, buf_width, buf_height, g, x0, y0),
    }
}

fn blitAlphaGlyph(
    pixels: []u32,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
) void {
    for (0..g.height) |gy| {
        const py = y0 + @as(i32, @intCast(gy));
        if (py < 0 or py >= buf_height) continue;
        for (0..g.width) |gx| {
            const px = x0 + @as(i32, @intCast(gx));
            if (px < 0 or px >= buf_width) continue;
            const coverage = g.bitmap[gy * g.width + gx];
            if (coverage == 0) continue;
            const idx = @as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px));
            pixels[idx] = blend(color, pixels[idx], coverage);
        }
    }
}

fn blitBgraGlyph(
    pixels: []u32,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
) void {
    for (0..g.height) |gy| {
        const py = y0 + @as(i32, @intCast(gy));
        if (py < 0 or py >= buf_height) continue;
        for (0..g.width) |gx| {
            const px = x0 + @as(i32, @intCast(gx));
            if (px < 0 or px >= buf_width) continue;
            const src = g.bitmap[(gy * g.width + gx) * 4 ..][0..4];
            const alpha = src[3];
            if (alpha == 0) continue;
            const idx = @as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px));
            pixels[idx] = blendPremultipliedBgra(src, pixels[idx]);
        }
    }
}

fn blitBgraGlyphAsAlpha(
    pixels: []u32,
    buf_width: u31,
    buf_height: u31,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
) void {
    for (0..g.height) |gy| {
        const py = y0 + @as(i32, @intCast(gy));
        if (py < 0 or py >= buf_height) continue;
        for (0..g.width) |gx| {
            const px = x0 + @as(i32, @intCast(gx));
            if (px < 0 or px >= buf_width) continue;
            const alpha = g.bitmap[(gy * g.width + gx) * 4 + 3];
            if (alpha == 0) continue;
            const idx = @as(usize, @intCast(py)) * buf_width + @as(usize, @intCast(px));
            pixels[idx] = blend(color, pixels[idx], alpha);
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
    return 0xff000000 | (r << 16) | (g << 8) | b;
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
    const r = @as(u32, src[2]) + ((bg >> 16 & 0xff) * na) / 255;
    const g = @as(u32, src[1]) + ((bg >> 8 & 0xff) * na) / 255;
    const b = @as(u32, src[0]) + ((bg & 0xff) * na) / 255;
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

test "blend endpoints" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), blend(0xffffffff, 0xff000000, 255));
    try std.testing.expectEqual(@as(u32, 0xff000000), blend(0xffffffff, 0xff000000, 0));
    try std.testing.expectEqual(
        @as(u32, 0xff804000),
        blendPremultipliedBgra(&.{ 0x00, 0x40, 0x80, 0xff }, 0xff000000),
    );
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
