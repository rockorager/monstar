//! Overlay and canvas rasterizer for TC-Wayland surfaces.
//! Blits CanvasCell grids into 32-bit ARGB8888 framebuffers using Font and pixel_raster.

const TcOverlayRenderer = @This();

const std = @import("std");
const c = @import("c");
const Font = @import("../Font.zig");
const pixel_raster = @import("../pixel_raster.zig");
const Compositor = @import("Compositor.zig");
const Surface = @import("Surface.zig");

pub fn rgbaToArgb(rgba: u32) u32 {
    const a = rgba & 0xFF;
    const rgb = rgba >> 8;
    return (@as(u32, a) << 24) | rgb;
}

pub const Cursor = struct {
    col: u32,
    row: u32,
    visible: bool,
};

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
    cursor: ?Cursor,
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

pub fn blendPixel(src: u32, dst: u32) u32 {
    const a: u32 = (src >> 24) & 0xFF;
    if (a == 255) return src;
    if (a == 0) return dst;
    const inv_a: u32 = 255 - a;
    const dst_r: u32 = (dst >> 16) & 0xFF;
    const dst_g: u32 = (dst >> 8) & 0xFF;
    const dst_b: u32 = dst & 0xFF;

    const src_r: u32 = (src >> 16) & 0xFF;
    const src_g: u32 = (src >> 8) & 0xFF;
    const src_b: u32 = src & 0xFF;

    // Support both premultiplied (Wayland standard) and straight alpha
    const is_straight = (src_r > a or src_g > a or src_b > a);
    const r = if (is_straight)
        (src_r * a + dst_r * inv_a + 127) / 255
    else
        @min(255, src_r + (dst_r * inv_a + 127) / 255);
    const g = if (is_straight)
        (src_g * a + dst_g * inv_a + 127) / 255
    else
        @min(255, src_g + (dst_g * inv_a + 127) / 255);
    const b = if (is_straight)
        (src_b * a + dst_b * inv_a + 127) / 255
    else
        @min(255, src_b + (dst_b * inv_a + 127) / 255);

    return (0xFF << 24) | (r << 16) | (g << 8) | b;
}

pub fn renderSurfaceAtPixel(
    allocator: std.mem.Allocator,
    font: *Font,
    surf: *const Surface,
    pixels: []u32,
    stride: u31,
    buf_width: u31,
    buf_height: u31,
    theme_palette: []const u32,
    default_fg: u32,
    default_bg: u32,
) void {
    var origin_x = surf.pixel_x orelse (surf.x * @as(i32, @intCast(font.cell_width)));
    var origin_y = surf.pixel_y orelse (surf.y * @as(i32, @intCast(font.cell_height)));
    if (surf.anchor) |anc| {
        const target_x = anc.target.pixel_x orelse (anc.target.x * @as(i32, @intCast(font.cell_width)));
        const target_y = anc.target.pixel_y orelse (anc.target.y * @as(i32, @intCast(font.cell_height)));
        origin_x = target_x + (anc.target.cursor.col + anc.col_offset) * @as(i32, @intCast(font.cell_width));
        origin_y = target_y + (anc.target.cursor.row + anc.row_offset) * @as(i32, @intCast(font.cell_height));
    }

    const buf = surf.current_buffer orelse return;

    switch (buf.format) {
        .compact_v1 => {
            const cells = buf.asCompactSlice();
            var r: u32 = 0;
            while (r < buf.rows) : (r += 1) {
                const y_px = origin_y + @as(i32, @intCast(r * font.cell_height));
                if (y_px + @as(i32, @intCast(font.cell_height)) <= 0 or y_px >= buf_height) continue;
                const baseline_y = y_px + font.baseline;

                var c_idx: u32 = 0;
                while (c_idx < buf.cols) : (c_idx += 1) {
                    const x_px = origin_x + @as(i32, @intCast(c_idx * font.cell_width));
                    if (x_px + @as(i32, @intCast(font.cell_width)) <= 0 or x_px >= buf_width) continue;

                    const cell = cells[r * buf.cols + c_idx];
                    const fg = if (cell.flags.fg_is_palette and cell.fg_color < 16)
                        theme_palette[cell.fg_color]
                    else
                        default_fg;

                    const bg = if (cell.flags.bg_is_palette and cell.bg_color > 0 and cell.bg_color < 16)
                        theme_palette[cell.bg_color]
                    else
                        default_bg;

                    pixel_raster.fillRect(
                        pixels,
                        stride,
                        buf_width,
                        buf_height,
                        @intCast(@max(0, x_px)),
                        @intCast(@max(0, y_px)),
                        font.cell_width,
                        font.cell_height,
                        rgbaToArgb(bg),
                    );

                    if (cell.codepoint != ' ' and cell.codepoint != 0) {
                        const style = Font.FaceStyle.init(cell.flags.bold, cell.flags.italic);
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
                                    x_px + g.bearing_x,
                                    baseline_y - g.bearing_y,
                                    rgbaToArgb(fg),
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
                                        x_px + g.bearing_x,
                                        baseline_y - g.bearing_y,
                                        rgbaToArgb(fg),
                                        false,
                                        null,
                                    );
                                } else |_| {}
                            }
                        }
                    }

                    if (cell.flags.underline) {
                        if (font.decorationGlyph(allocator, .underline)) |deco| {
                            pixel_raster.blitGlyph(
                                pixels,
                                stride,
                                buf_width,
                                buf_height,
                                deco,
                                x_px + deco.bearing_x,
                                baseline_y - deco.bearing_y,
                                rgbaToArgb(fg),
                                false,
                                null,
                            );
                        } else |_| {}
                    }
                }
            }
        },
        .rich_v1 => {},
        .argb8888, .xrgb8888 => {
            const is_opaque = (buf.format == .xrgb8888);
            const stride_u32 = if (buf.stride > 0) buf.stride / 4 else buf.cols;
            const src_pixels = buf.asPixelSlice();

            var r: u32 = 0;
            while (r < buf.rows) : (r += 1) {
                const dst_y = origin_y + @as(i32, @intCast(r));
                if (dst_y < 0 or dst_y >= buf_height) continue;
                const src_row_offset = r * stride_u32;
                const dst_row_offset = @as(usize, @intCast(dst_y)) * stride;

                var c_idx: u32 = 0;
                while (c_idx < buf.cols) : (c_idx += 1) {
                    const dst_x = origin_x + @as(i32, @intCast(c_idx));
                    if (dst_x < 0 or dst_x >= buf_width) continue;

                    const src_idx = src_row_offset + c_idx;
                    if (src_idx >= src_pixels.len) break;
                    const src_pix = src_pixels[src_idx];
                    const dst_idx = dst_row_offset + @as(usize, @intCast(dst_x));

                    if (is_opaque) {
                        pixels[dst_idx] = 0xFF000000 | (src_pix & 0x00FFFFFF);
                    } else {
                        pixels[dst_idx] = blendPixel(src_pix, pixels[dst_idx]);
                    }
                }
            }
        },
    }
}

test "blendPixel handles transparent, opaque, and blend" {
    // Fully transparent source returns destination
    try std.testing.expectEqual(@as(u32, 0xFF112233), blendPixel(0x00FFFFFF, 0xFF112233));
    // Fully opaque source returns source
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), blendPixel(0xFFFF0000, 0xFF00FF00));
    // Premultiplied blend (50% red over white)
    const premul_result = blendPixel(0x80800000, 0xFFFFFFFF);
    const pr_r = (premul_result >> 16) & 0xFF;
    const pr_g = (premul_result >> 8) & 0xFF;
    const pr_b = premul_result & 0xFF;
    try std.testing.expect(pr_r >= 254);
    try std.testing.expect(pr_g >= 126 and pr_g <= 128);
    try std.testing.expect(pr_b >= 126 and pr_b <= 128);

    // Straight alpha blend (50% red over white)
    const straight_result = blendPixel(0x80FF0000, 0xFFFFFFFF);
    const st_r = (straight_result >> 16) & 0xFF;
    const st_g = (straight_result >> 8) & 0xFF;
    const st_b = straight_result & 0xFF;
    try std.testing.expect(st_r >= 254);
    try std.testing.expect(st_g >= 126 and st_g <= 128);
    try std.testing.expect(st_b >= 126 and st_b <= 128);
}
