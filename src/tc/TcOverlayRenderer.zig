//! Overlay and canvas rasterizer for TC-Wayland surfaces.
//! Blits CanvasCell grids into 32-bit ARGB8888 framebuffers using Font and pixel_raster.

const TcOverlayRenderer = @This();

const std = @import("std");
const c = @import("c");
const Font = @import("../Font.zig");
const pixel_raster = @import("../pixel_raster.zig");
const Compositor = @import("Compositor.zig");

pub fn rgbaToArgb(rgba: u32) u32 {
    const a = rgba & 0xFF;
    const rgb = rgba >> 8;
    return (@as(u32, a) << 24) | rgb;
}

pub fn renderCanvas(
    allocator: std.mem.Allocator,
    font: *Font,
    canvas: []const Compositor.CanvasCell,
    cols: u32,
    rows: u32,
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    cursor: ?struct { col: u32, row: u32, visible: bool },
    cursor_rgba: u32,
) void {
    const grid_w: u31 = @intCast(@min(@as(u64, cols) * font.cell_width, buf_width));
    const grid_h: u31 = @intCast(@min(@as(u64, rows) * font.cell_height, buf_height));
    const default_bg = if (canvas.len > 0) rgbaToArgb(canvas[0].bg_rgba) else 0xFF181825;

    // Fill margins if window exceeds grid boundaries
    if (grid_w < buf_width) {
        pixel_raster.fillRect(pixels, stride, buf_width, buf_height, grid_w, 0, buf_width - grid_w, buf_height, default_bg);
    }
    if (grid_h < buf_height) {
        pixel_raster.fillRect(pixels, stride, buf_width, buf_height, 0, grid_h, buf_width, buf_height - grid_h, default_bg);
    }

    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        const y_px: u31 = @intCast(r * font.cell_height);
        if (y_px + font.cell_height > buf_height) break;
        const baseline_y: i32 = @as(i32, @intCast(r)) * font.cell_height + font.baseline;

        var c_idx: u32 = 0;
        while (c_idx < cols) : (c_idx += 1) {
            const x_px: u31 = @intCast(c_idx * font.cell_width);
            if (x_px + font.cell_width > buf_width) break;

            const idx = r * cols + c_idx;
            if (idx >= canvas.len) break;
            const cell = canvas[idx];

            const is_cursor = if (cursor) |cur|
                (cur.visible and cur.col == c_idx and cur.row == r)
            else
                false;

            var bg_argb = rgbaToArgb(cell.bg_rgba);
            var fg_argb = rgbaToArgb(cell.fg_rgba);

            if (is_cursor) {
                bg_argb = rgbaToArgb(cursor_rgba);
                fg_argb = rgbaToArgb(cell.bg_rgba);
            }

            // Fill cell background
            pixel_raster.fillRect(
                pixels,
                stride,
                buf_width,
                buf_height,
                x_px,
                y_px,
                font.cell_width,
                font.cell_height,
                bg_argb,
            );

            // Draw glyph if non-space
            if (cell.codepoint != ' ' and cell.codepoint != 0) {
                const style = Font.FaceStyle.init(cell.bold, cell.italic);
                const cp: u21 = @truncate(cell.codepoint);
                const face_idx = font.faceForCluster(allocator, &.{cp}, style);

                if (face_idx == Font.sprite_face_index) {
                    if (font.spriteGlyph(allocator, cp, 1)) |g| {
                        pixel_raster.blitGlyph(
                            pixels,
                            stride,
                            buf_width,
                            buf_height,
                            g,
                            @as(i32, @intCast(x_px)) + g.bearing_x,
                            baseline_y - g.bearing_y,
                            fg_argb,
                            false,
                            null,
                        );
                    } else |_| {}
                } else {
                    const face = font.face(face_idx);
                    const g_idx = c.FT_Get_Char_Index(face.ft_face, cp);
                    if (g_idx != 0) {
                        if (face.glyph(allocator, g_idx, 0, false)) |g| {
                            pixel_raster.blitGlyph(
                                pixels,
                                stride,
                                buf_width,
                                buf_height,
                                g,
                                @as(i32, @intCast(x_px)) + g.bearing_x,
                                baseline_y - g.bearing_y,
                                fg_argb,
                                false,
                                null,
                            );
                        } else |_| {}
                    }
                }
            }

            // Draw underline if set
            if (cell.underline) {
                if (font.decorationGlyph(allocator, .underline)) |deco| {
                    pixel_raster.blitGlyph(
                        pixels,
                        stride,
                        buf_width,
                        buf_height,
                        deco,
                        @as(i32, @intCast(x_px)) + deco.bearing_x,
                        baseline_y - deco.bearing_y,
                        fg_argb,
                        false,
                        null,
                    );
                } else |_| {}
            }
        }
    }
}
