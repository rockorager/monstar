//! A raster target for Renderer: a view of CPU pixels or of a GPU draw list.
//!
//! Renderer decides what to draw (layout, shaping, glyph positions, colors,
//! damage) and calls these primitives; the target decides how pixels are
//! produced. CPU views write ARGB8888 storage through pixel_raster. GPU views
//! append the same operations, clipped to the same rectangles, to a
//! GpuDrawList that the Vulkan backend rasterizes in submission order.
//!
//! A view has its own origin and size. Coordinates passed to the primitives
//! are view-relative, and every primitive clips to the view exactly as the
//! CPU functions clip to their buffer bounds.

const Canvas = @This();

const std = @import("std");
const Font = @import("Font.zig");
const GpuDrawList = @import("GpuDrawList.zig");
const pixel_raster = @import("pixel_raster.zig");

pub const Target = union(enum) {
    /// Row-major ARGB8888 storage whose first element is the view origin.
    pixels: []u32,
    gpu: *GpuDrawList,
};

target: Target,
/// Physical row stride of `pixels`; unused for GPU views.
stride: u31,
width: u31,
height: u31,
/// GPU only: view origin in surface pixels.
origin_x: i32 = 0,
origin_y: i32 = 0,
/// GPU only: surface-space clip, already intersected with the view.
clip: GpuDrawList.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },

pub fn cpu(pixels: []u32, stride: u31, width: u31, height: u31) Canvas {
    std.debug.assert(stride >= width);
    std.debug.assert(width == 0 or height == 0 or pixels.len >= @as(usize, height - 1) * stride + width);
    return .{ .target = .{ .pixels = pixels }, .stride = stride, .width = width, .height = height };
}

pub fn gpu(list: *GpuDrawList, width: u31, height: u31) Canvas {
    return .{
        .target = .{ .gpu = list },
        .stride = width,
        .width = width,
        .height = height,
        .clip = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height },
    };
}

/// A sub-view whose origin is (`x`, `y`) in this view. The sub-view clips to
/// its own size; GPU views also keep this view's clip.
pub fn view(self: Canvas, x: u31, y: u31, width: u31, height: u31) Canvas {
    std.debug.assert(x + width <= self.width and y + height <= self.height);
    var result = self;
    result.width = width;
    result.height = height;
    switch (self.target) {
        .pixels => |pixels| result.target = .{ .pixels = pixels[@as(usize, y) * self.stride + x ..] },
        .gpu => {
            result.origin_x = self.origin_x + x;
            result.origin_y = self.origin_y + y;
            result.clip = self.clip.intersect(result.bounds());
        },
    }
    return result;
}

/// A GPU view translated by (`dx`, `dy`) surface pixels with size
/// `width`×`height` but clipped to this view. Drawing the view at its own
/// coordinates lands `dy` pixels lower in this one; renderScrolled uses a
/// negative `dy` to crop an overscanned grid without an intermediate buffer.
pub fn translated(self: Canvas, dy: i32, width: u31, height: u31) Canvas {
    std.debug.assert(self.target == .gpu);
    var result = self;
    result.origin_y = self.origin_y + dy;
    result.width = width;
    result.height = height;
    result.clip = self.clip.intersect(result.bounds());
    return result;
}

fn bounds(self: Canvas) GpuDrawList.Rect {
    return .{
        .x0 = self.origin_x,
        .y0 = self.origin_y,
        .x1 = self.origin_x + self.width,
        .y1 = self.origin_y + self.height,
    };
}

/// Surface-space rectangle for view coordinates, clipped. Null when empty.
fn surfaceRect(self: Canvas, x0: i64, y0: i64, x1: i64, y1: i64) ?GpuDrawList.Rect {
    const list = self.target.gpu;
    const clip_y0 = @max(self.clip.y0, list.clip_min_y);
    const rx0 = @max(x0 + self.origin_x, self.clip.x0);
    const ry0 = @max(y0 + self.origin_y, clip_y0);
    const rx1 = @min(x1 + self.origin_x, self.clip.x1);
    const ry1 = @min(y1 + self.origin_y, self.clip.y1);
    if (rx1 <= rx0 or ry1 <= ry0) return null;
    return .{ .x0 = @intCast(rx0), .y0 = @intCast(ry0), .x1 = @intCast(rx1), .y1 = @intCast(ry1) };
}

/// Replace a rectangle with `color` (premultiplied ARGB8888), clipped.
pub fn fillRect(self: Canvas, x: u31, y: u31, w: u31, h: u31, color: u32) !void {
    switch (self.target) {
        .pixels => |pixels| pixel_raster.fillRect(pixels, self.stride, self.width, self.height, x, y, w, h, color),
        .gpu => |list| {
            if (x >= self.width or y >= self.height) return;
            const rect = self.surfaceRect(x, y, @min(@as(u32, x) + w, self.width), @min(@as(u32, y) + h, self.height)) orelse return;
            try list.fill(rect, color);
        },
    }
}

/// Blend glyph `g` with its top-left at (`x0`, `y0`); see pixel_raster.blitGlyph.
pub fn blitGlyph(
    self: Canvas,
    g: *const Font.Glyph,
    x0: i32,
    y0: i32,
    color: u32,
    reverse_color_glyph: bool,
    clip_x: ?pixel_raster.PixelRange,
) !void {
    switch (self.target) {
        .pixels => |pixels| pixel_raster.blitGlyph(pixels, self.stride, self.width, self.height, g, x0, y0, color, reverse_color_glyph, clip_x),
        .gpu => |list| {
            const x_start: i64 = if (clip_x) |range| @max(0, range.start) else 0;
            const x_end: i64 = if (clip_x) |range| @min(self.width, range.end) else self.width;
            const gx0 = @max(@as(i64, x0), x_start);
            const gy0 = @max(@as(i64, y0), 0);
            const gx1 = @min(@as(i64, x0) + g.width, x_end);
            const gy1 = @min(@as(i64, y0) + g.height, self.height);
            if (gx1 <= gx0 or gy1 <= gy0) return;
            const rect = self.surfaceRect(gx0, gy0, gx1, gy1) orelse return;
            const kind: GpuDrawList.GlyphKind = switch (g.format) {
                .alpha => if (g.fully_opaque) return list.fill(rect, color) else .text,
                .bgra => if (reverse_color_glyph) .color_as_text else .color,
            };
            // Glyph-space texel under the clipped rectangle's origin.
            const texel_x: u31 = @intCast(rect.x0 - self.origin_x - x0);
            const texel_y: u31 = @intCast(rect.y0 - self.origin_y - y0);
            try list.glyph(rect, g, texel_x, texel_y, kind, color);
        },
    }
}

/// Blend the overlay scrollbar capsule; see pixel_raster.blendCapsule.
pub fn blendCapsule(self: Canvas, thumb: pixel_raster.ScrollbarThumb, color: u32) !void {
    switch (self.target) {
        .pixels => |pixels| pixel_raster.blendCapsule(pixels, self.stride, self.width, self.height, thumb, color),
        .gpu => |list| {
            std.debug.assert(std.math.isFinite(thumb.y) and thumb.y >= 0);
            if (thumb.alpha == 0 or thumb.width == 0 or thumb.height == 0 or
                thumb.x >= self.width or thumb.y >= @as(f64, @floatFromInt(self.height))) return;
            const bottom = thumb.y + @as(f64, @floatFromInt(thumb.height));
            const y_start: i64 = @intFromFloat(@floor(@max(0, thumb.y - 0.5)));
            const y_end: i64 = @intFromFloat(@ceil(@min(bottom + 0.5, @as(f64, @floatFromInt(self.height)))));
            const x_end = @min(@as(u32, thumb.x) + thumb.width, self.width);
            const rect = self.surfaceRect(thumb.x, y_start, x_end, y_end) orelse return;
            var surface_thumb = thumb;
            surface_thumb.x = @intCast(@as(i64, thumb.x) + self.origin_x);
            surface_thumb.y = thumb.y + @as(f64, @floatFromInt(self.origin_y));
            try list.capsule(rect, surface_thumb, color);
        },
    }
}

/// Draw `width`×`height` RGBA texels of GPU image `slot` with their top-left
/// at (`dest_x`, `dest_y`), clipped. `background` marks images below the text
/// layer, which text coverage correction sees as background.
pub fn drawImage(
    self: Canvas,
    slot: u16,
    width: u32,
    height: u32,
    dest_x: i64,
    dest_y: i64,
    background: bool,
) !void {
    const list = self.target.gpu;
    const x0 = @max(dest_x, 0);
    const y0 = @max(dest_y, 0);
    const x1 = @min(dest_x + width, self.width);
    const y1 = @min(dest_y + height, self.height);
    if (x1 <= x0 or y1 <= y0) return;
    const rect = self.surfaceRect(x0, y0, x1, y1) orelse return;
    const texel_x: u32 = @intCast(rect.x0 - self.origin_x - dest_x);
    const texel_y: u32 = @intCast(rect.y0 - self.origin_y - dest_y);
    try list.image(rect, slot, texel_x, texel_y, background);
}

test "gpu views clip and translate like cpu views" {
    var list: GpuDrawList = .init(std.testing.allocator);
    defer list.deinit();
    const root = gpu(&list, 100, 50);
    const grid = root.view(10, 5, 80, 40);
    try grid.fillRect(70, 30, 20, 20, 0xff102030);
    try std.testing.expectEqual(@as(usize, 1), list.ops.items.len);
    const op = list.ops.items[0];
    try std.testing.expectEqual(GpuDrawList.Rect{ .x0 = 80, .y0 = 35, .x1 = 90, .y1 = 45 }, op.rect());

    // A translated view crops above the parent's top edge.
    const scrolled = grid.translated(-7, 80, 47);
    try scrolled.fillRect(0, 0, 4, 10, 0xff000000);
    try std.testing.expectEqual(GpuDrawList.Rect{ .x0 = 10, .y0 = 5, .x1 = 14, .y1 = 8 }, list.ops.items[1].rect());
}
