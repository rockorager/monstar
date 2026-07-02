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

alloc: std.mem.Allocator,
font: *Font,
hb_buf: *c.hb_buffer_t,
/// Per-cell resolved foreground colors for the row being rendered.
fg_scratch: std.ArrayList(vt.color.RGB),
/// Per-cell font face indices for the row being rendered.
face_scratch: std.ArrayList(u16),

pub fn init(alloc: std.mem.Allocator, font: *Font) !Renderer {
    const hb_buf = c.hb_buffer_create() orelse return error.OutOfMemory;
    if (c.hb_buffer_allocation_successful(hb_buf) == 0) return error.OutOfMemory;
    return .{
        .alloc = alloc,
        .font = font,
        .hb_buf = hb_buf,
        .fg_scratch = .empty,
        .face_scratch = .empty,
    };
}

pub fn deinit(self: *Renderer) void {
    c.hb_buffer_destroy(self.hb_buf);
    self.fg_scratch.deinit(self.alloc);
    self.face_scratch.deinit(self.alloc);
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
    const font = self.font;
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

    // Background + foreground-color + face-resolution pass.
    try self.fg_scratch.resize(self.alloc, cols);
    try self.face_scratch.resize(self.alloc, cols);
    for (0..cols) |x| {
        self.face_scratch.items[x] = face: {
            switch (raws[x].content_tag) {
                .codepoint, .codepoint_grapheme => {},
                else => break :face 0,
            }
            const cp = raws[x].content.codepoint.data;
            if (cp == 0 or cp == ' ') break :face 0;
            break :face self.font.faceForCodepoint(self.alloc, cp);
        };
        const style: vt.Style = if (raws[x].style_id == 0) .{} else styles[x];
        var fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        var bg = style.bg(&raws[x], &colors.palette);
        // Selection renders as inverse video; a selected inverse cell
        // flips back to normal.
        const selected = if (selection) |sel| x >= sel[0] and x <= sel[1] else false;
        if (style.flags.inverse != selected) {
            const old_fg = fg;
            fg = bg orelse colors.background;
            bg = old_fg;
        }
        // Block cursor: swap in the cursor color, invert the glyph.
        if (cursor_x != null and cursor_x.? == x) {
            bg = colors.cursor orelse colors.foreground;
            fg = colors.background;
        }
        self.fg_scratch.items[x] = fg;
        if (bg) |bg_color| {
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

    // Text pass: shape and draw runs of consecutive cells with the same
    // style and font face.
    const faces = self.face_scratch.items;
    var run_start: u31 = 0;
    var x: u31 = 0;
    while (x < cols) : (x += 1) {
        const has_text = switch (raws[x].content_tag) {
            .codepoint, .codepoint_grapheme => raws[x].content.codepoint.data != 0,
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
        const g = try face.glyph(self.alloc, info.codepoint);
        blitGlyph(
            pixels,
            width,
            height,
            g,
            pen_x + (pos.x_offset >> 6) + g.bearing_x,
            baseline_y - (pos.y_offset >> 6) - g.bearing_y,
            argb(self.fg_scratch.items[cluster]),
        );
        pen_x += pos.x_advance >> 6;
    }
}

/// How many cells a cell's background covers (wide chars span two).
fn cellSpan(cell: vt.Cell) u31 {
    return if (cell.wide == .wide) 2 else 1;
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

fn blend(fg: u32, bg: u32, alpha: u8) u32 {
    if (alpha == 0xff) return fg;
    const a: u32 = alpha;
    const na: u32 = 255 - a;
    const r = ((fg >> 16 & 0xff) * a + (bg >> 16 & 0xff) * na) / 255;
    const g = ((fg >> 8 & 0xff) * a + (bg >> 8 & 0xff) * na) / 255;
    const b = ((fg & 0xff) * a + (bg & 0xff) * na) / 255;
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

test "blend endpoints" {
    try std.testing.expectEqual(@as(u32, 0xffffffff), blend(0xffffffff, 0xff000000, 255));
    try std.testing.expectEqual(@as(u32, 0xff000000), blend(0xffffffff, 0xff000000, 0));
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
    var renderer: Renderer = try .init(alloc, &font);
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
