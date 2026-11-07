//! Records one frame of Renderer drawing for the Vulkan backend.
//!
//! The list holds clipped, surface-space operations in exactly the order the
//! CPU renderer would rasterize them, plus the glyph and image uploads they
//! need. It owns the CPU-side bookkeeping of the persistent glyph atlases and
//! image slots, so recording needs no Vulkan calls and no GPU synchronization;
//! VulkanRenderer consumes a finished list when it submits the frame.
//!
//! Operations that text coverage correction treats as background (fills and
//! images below the text layer) are also recorded in `bg_ops`. The backend
//! rasterizes those into a second image first, and text reads its background
//! luminance from there instead of from the pixel being blended.

const GpuDrawList = @This();

const std = @import("std");
const Font = @import("Font.zig");
const pixel_raster = @import("pixel_raster.zig");

pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x0, b.x0);
        const y0 = @max(a.y0, b.y0);
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = @max(x0, @min(a.x1, b.x1)),
            .y1 = @max(y0, @min(a.y1, b.y1)),
        };
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }
};

/// Shader operation kinds; keep in sync with shaders/canvas.frag.
pub const Kind = enum(u16) {
    /// Replace with `color`'s premultiplied bytes.
    fill = 0,
    /// Coverage-corrected A8 glyph in `color`.
    text = 1,
    /// Premultiplied BGRA glyph, blended uncorrected.
    color = 2,
    /// BGRA glyph alpha used as coverage-corrected text in `color`.
    color_as_text = 3,
    /// Straight-alpha RGBA image slot `tex`.
    image = 4,
    /// Antialiased scrollbar capsule.
    capsule = 5,
};

pub const GlyphKind = enum { text, color, color_as_text };

/// One instance in the backend's storage buffer (std430, 32 bytes).
pub const Op = extern struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
    /// Source texel under (x0, y0): atlas or image coordinates. Capsules
    /// store twice their center x and their diameter instead.
    sx: u16,
    sy: u16,
    kind: Kind,
    /// Image slot, or capsule alpha.
    tex: u16,
    /// ARGB8888; premultiplied for fills.
    color: u32,
    /// Capsule cap centers (top, bottom) in surface pixels.
    p0: f32 = 0,
    p1: f32 = 0,
    _pad: u32 = 0,

    pub fn rect(self: Op) Rect {
        return .{ .x0 = self.x0, .y0 = self.y0, .x1 = self.x1, .y1 = self.y1 };
    }
};

comptime {
    std.debug.assert(@sizeOf(Op) == 32);
}

pub const AtlasFormat = enum { alpha, color };

/// A glyph bitmap copied into `upload_bytes`, destined for an atlas.
pub const GlyphUpload = struct {
    format: AtlasFormat,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    offset: usize,
};

/// RGBA texels copied into `upload_bytes`, replacing image slot `slot`.
pub const ImageUpload = struct {
    slot: u16,
    width: u32,
    height: u32,
    offset: usize,
};

/// Copy retained grid rows between the backend's canvas images.
pub const Scroll = struct {
    x: u31,
    width: u31,
    src_y: u31,
    dst_y: u31,
    height: u31,
};

/// Identifies the RGBA content of a kitty placement. Renderer fills it from
/// the image identity, source crop and destination size.
pub const ImageKey = struct {
    image_id: u32,
    generation: u64,
    format: u8,
    image_width: u32,
    image_height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    dest_width: u32,
    dest_height: u32,
};

pub const max_images = 32;
pub const atlas_width = 2048;
const atlas_initial_height = 256;
pub const atlas_max_height = 8192;

alloc: std.mem.Allocator,
ops: std.ArrayList(Op) = .empty,
bg_ops: std.ArrayList(Op) = .empty,
glyph_uploads: std.ArrayList(GlyphUpload) = .empty,
image_uploads: std.ArrayList(ImageUpload) = .empty,
upload_bytes: std.ArrayList(u8) = .empty,
scroll: ?Scroll = null,
/// The backend's canvas holds the previous frame, so drawing may build on
/// it; false after the canvas was (re)created. Set by the backend.
previous_frame: bool = false,
/// Union of everything this frame writes, in surface pixels.
bounds: ?Rect = null,
/// Operations above this surface row are discarded (Renderer's strip
/// preservation on the CPU path).
clip_min_y: i32 = std.math.minInt(i32),
alpha_atlas: Shelves = .{},
color_atlas: Shelves = .{},
glyphs: std.AutoHashMapUnmanaged(usize, AtlasEntry) = .empty,
images: [max_images]ImageSlot = @splat(.{}),
frame: u64 = 1,

const AtlasEntry = struct { x: u16, y: u16 };

const ImageSlot = struct {
    key: ?ImageKey = null,
    last_used: u64 = 0,
};

pub fn init(alloc: std.mem.Allocator) GpuDrawList {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *GpuDrawList) void {
    self.ops.deinit(self.alloc);
    self.bg_ops.deinit(self.alloc);
    self.glyph_uploads.deinit(self.alloc);
    self.image_uploads.deinit(self.alloc);
    self.upload_bytes.deinit(self.alloc);
    self.alpha_atlas.shelves.deinit(self.alloc);
    self.color_atlas.shelves.deinit(self.alloc);
    self.glyphs.deinit(self.alloc);
    self.* = undefined;
}

/// Start recording a new frame. Atlas contents and image slots persist.
pub fn begin(self: *GpuDrawList) void {
    self.ops.clearRetainingCapacity();
    self.bg_ops.clearRetainingCapacity();
    self.glyph_uploads.clearRetainingCapacity();
    self.image_uploads.clearRetainingCapacity();
    self.upload_bytes.clearRetainingCapacity();
    self.scroll = null;
    self.bounds = null;
    self.clip_min_y = std.math.minInt(i32);
    self.frame += 1;
}

/// Forget every atlas allocation, e.g. after the font changed or an atlas
/// filled. Glyphs are uploaded again on their next use. Must be followed by
/// `begin` before recording, because already recorded glyph operations refer
/// to the old allocations.
pub fn resetGlyphs(self: *GpuDrawList) void {
    self.glyphs.clearRetainingCapacity();
    self.alpha_atlas.reset();
    self.color_atlas.reset();
}

/// Drop a frame whose uploads will never be submitted: forget every atlas
/// allocation and image slot so later frames upload again, then `begin`.
pub fn abortFrame(self: *GpuDrawList) void {
    self.resetGlyphs();
    self.images = @splat(.{});
    self.begin();
}

/// Atlas height the backend must provide for `format` this frame.
pub fn atlasHeight(self: *const GpuDrawList, format: AtlasFormat) u32 {
    return switch (format) {
        .alpha => self.alpha_atlas.height,
        .color => self.color_atlas.height,
    };
}

pub fn opCount(self: *const GpuDrawList) usize {
    return self.ops.items.len;
}

fn noteBounds(self: *GpuDrawList, r: Rect) void {
    self.bounds = if (self.bounds) |b| b.unite(r) else r;
}

/// Request a row copy between canvases. The backend performs it before any
/// recorded op, so callers may record padding fills first.
pub fn setScroll(self: *GpuDrawList, scroll: Scroll) void {
    std.debug.assert(self.scroll == null);
    self.scroll = scroll;
    self.noteBounds(.{ .x0 = scroll.x, .y0 = scroll.dst_y, .x1 = scroll.x + scroll.width, .y1 = scroll.dst_y + scroll.height });
}

fn push(self: *GpuDrawList, op: Op, background: bool) !void {
    std.debug.assert(op.x1 > op.x0 and op.y1 > op.y0);
    try self.ops.append(self.alloc, op);
    if (background) try self.bg_ops.append(self.alloc, op);
    self.noteBounds(op.rect());
}

fn baseOp(r: Rect, kind: Kind, color: u32) Op {
    return .{
        .x0 = @intCast(r.x0),
        .y0 = @intCast(r.y0),
        .x1 = @intCast(r.x1),
        .y1 = @intCast(r.y1),
        .sx = 0,
        .sy = 0,
        .kind = kind,
        .tex = 0,
        .color = color,
    };
}

/// Replace `r` with premultiplied `color`.
pub fn fill(self: *GpuDrawList, r: Rect, color: u32) !void {
    try self.push(baseOp(r, .fill, color), true);
}

/// Blend glyph `g` over `r`; (`texel_x`, `texel_y`) is the glyph texel under
/// the rectangle's top-left corner.
pub fn glyph(
    self: *GpuDrawList,
    r: Rect,
    g: *const Font.Glyph,
    texel_x: u31,
    texel_y: u31,
    kind: GlyphKind,
    color: u32,
) !void {
    std.debug.assert(texel_x + (r.x1 - r.x0) <= g.width and texel_y + (r.y1 - r.y0) <= g.height);
    const entry = try self.atlasEntry(g);
    var op = baseOp(r, switch (kind) {
        .text => .text,
        .color => .color,
        .color_as_text => .color_as_text,
    }, color);
    op.sx = @intCast(entry.x + texel_x);
    op.sy = @intCast(entry.y + texel_y);
    try self.push(op, false);
}

fn atlasEntry(self: *GpuDrawList, g: *const Font.Glyph) !AtlasEntry {
    // Glyph bitmaps are separately allocated and live until their Font is
    // destroyed, so the allocation address identifies the bitmap.
    const gop = try self.glyphs.getOrPut(self.alloc, @intFromPtr(g.bitmap.ptr));
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.glyphs.remove(@intFromPtr(g.bitmap.ptr));
    const format: AtlasFormat = switch (g.format) {
        .alpha => .alpha,
        .bgra => .color,
    };
    const shelves = switch (format) {
        .alpha => &self.alpha_atlas,
        .color => &self.color_atlas,
    };
    const pos = try shelves.allocate(self.alloc, g.width, g.height);
    const offset = try self.alignUploads();
    try self.upload_bytes.appendSlice(self.alloc, g.bitmap);
    try self.glyph_uploads.append(self.alloc, .{
        .format = format,
        .x = pos.x,
        .y = pos.y,
        .width = @intCast(g.width),
        .height = @intCast(g.height),
        .offset = offset,
    });
    gop.value_ptr.* = pos;
    return pos;
}

/// Pad `upload_bytes` so the next upload starts on a texel boundary, as
/// buffer-to-image copies require.
fn alignUploads(self: *GpuDrawList) !usize {
    const offset = std.mem.alignForward(usize, self.upload_bytes.items.len, 4);
    try self.upload_bytes.resize(self.alloc, offset);
    return offset;
}

/// Blend the scrollbar capsule over `r`. `thumb` is in surface pixels.
pub fn capsule(self: *GpuDrawList, r: Rect, thumb: pixel_raster.ScrollbarThumb, color: u32) !void {
    var op = baseOp(r, .capsule, color);
    const diameter = @min(thumb.width, thumb.height);
    const radius = @as(f64, @floatFromInt(diameter)) / 2.0;
    op.sx = @intCast(@as(u32, thumb.x) * 2 + thumb.width);
    op.sy = @intCast(diameter);
    op.tex = thumb.alpha;
    op.p0 = @floatCast(thumb.y + radius);
    op.p1 = @floatCast(thumb.y + @as(f64, @floatFromInt(thumb.height)) - radius);
    try self.push(op, false);
}

/// Draw image slot `slot` over `r` from texel (`texel_x`, `texel_y`).
pub fn image(self: *GpuDrawList, r: Rect, slot: u16, texel_x: u32, texel_y: u32, background: bool) !void {
    std.debug.assert(slot < max_images and self.images[slot].key != null);
    var op = baseOp(r, .image, 0);
    op.sx = @intCast(texel_x);
    op.sy = @intCast(texel_y);
    op.tex = slot;
    try self.push(op, background);
}

/// The slot already holding `key`, marked as used by this frame.
pub fn findImage(self: *GpuDrawList, key: ImageKey) ?u16 {
    for (&self.images, 0..) |*slot, i| {
        const held = slot.key orelse continue;
        if (std.meta.eql(held, key)) {
            slot.last_used = self.frame;
            return @intCast(i);
        }
    }
    return null;
}

/// Copy `width`×`height` RGBA bytes into the least recently used slot not
/// drawn this frame and return it. Fails with error.TooManyImages when every
/// slot is already in use by this frame.
pub fn uploadImage(self: *GpuDrawList, key: ImageKey, rgba: []const u8, width: u32, height: u32) !u16 {
    std.debug.assert(rgba.len >= @as(usize, width) * height * 4);
    std.debug.assert(width > 0 and height > 0 and width <= std.math.maxInt(u16) and height <= std.math.maxInt(u16));
    var best: ?usize = null;
    for (&self.images, 0..) |*slot, i| {
        if (slot.key == null) {
            best = i;
            break;
        }
        if (slot.last_used == self.frame) continue;
        if (best == null or slot.last_used < self.images[best.?].last_used) best = i;
    }
    const index = best orelse return error.TooManyImages;
    const offset = try self.alignUploads();
    try self.upload_bytes.appendSlice(self.alloc, rgba[0 .. @as(usize, width) * height * 4]);
    try self.image_uploads.append(self.alloc, .{ .slot = @intCast(index), .width = width, .height = height, .offset = offset });
    self.images[index] = .{ .key = key, .last_used = self.frame };
    return @intCast(index);
}

/// Shelf allocator over a fixed-width atlas whose height grows on demand.
const Shelves = struct {
    shelves: std.ArrayList(Shelf) = .empty,
    next_y: u32 = 0,
    height: u32 = atlas_initial_height,

    const Shelf = struct { y: u32, height: u32, x: u32 };

    fn reset(self: *Shelves) void {
        self.shelves.clearRetainingCapacity();
        self.next_y = 0;
    }

    fn allocate(self: *Shelves, alloc: std.mem.Allocator, width: u31, height: u31) !AtlasEntry {
        if (width > atlas_width) return error.GlyphTooLarge;
        var best: ?*Shelf = null;
        for (self.shelves.items) |*shelf| {
            if (shelf.height < height or shelf.x + width > atlas_width) continue;
            // Avoid wasting tall shelves on short glyphs.
            if (shelf.height > height + height / 4 + 2) continue;
            if (best == null or shelf.height < best.?.height) best = shelf;
        }
        if (best) |shelf| {
            const entry: AtlasEntry = .{ .x = @intCast(shelf.x), .y = @intCast(shelf.y) };
            shelf.x += width;
            return entry;
        }
        if (self.next_y + height > atlas_max_height) return error.AtlasFull;
        try self.shelves.append(alloc, .{ .y = self.next_y, .height = height, .x = width });
        const entry: AtlasEntry = .{ .x = 0, .y = @intCast(self.next_y) };
        self.next_y += height;
        while (self.height < self.next_y) self.height *= 2;
        return entry;
    }
};

test "glyphs upload once and grow the atlas" {
    var list: GpuDrawList = .init(std.testing.allocator);
    defer list.deinit();
    var bitmap: [6]u8 = .{ 1, 2, 3, 4, 5, 6 };
    const g: Font.Glyph = .{ .bitmap = &bitmap, .width = 3, .height = 2, .bearing_x = 0, .bearing_y = 0 };
    list.begin();
    try list.glyph(.{ .x0 = 10, .y0 = 4, .x1 = 12, .y1 = 6 }, &g, 1, 0, .text, 0xffffffff);
    try list.glyph(.{ .x0 = 20, .y0 = 4, .x1 = 23, .y1 = 6 }, &g, 0, 0, .text, 0xffffffff);
    try std.testing.expectEqual(@as(usize, 1), list.glyph_uploads.items.len);
    try std.testing.expectEqualSlices(u8, &bitmap, list.upload_bytes.items);
    try std.testing.expectEqual(@as(u16, 1), list.ops.items[0].sx);
    try std.testing.expectEqual(@as(usize, 0), list.bg_ops.items.len);
    try std.testing.expectEqual(Rect{ .x0 = 10, .y0 = 4, .x1 = 23, .y1 = 6 }, list.bounds.?);

    list.begin();
    try list.glyph(.{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 2 }, &g, 0, 0, .text, 0xffffffff);
    try std.testing.expectEqual(@as(usize, 0), list.glyph_uploads.items.len);

    var shelves: Shelves = .{};
    defer shelves.shelves.deinit(std.testing.allocator);
    _ = try shelves.allocate(std.testing.allocator, 10, 300);
    try std.testing.expectEqual(@as(u32, 512), shelves.height);
    try std.testing.expectError(error.AtlasFull, shelves.allocate(std.testing.allocator, 10, atlas_max_height));
}

test "image slots evict the least recently used slot not drawn this frame" {
    var list: GpuDrawList = .init(std.testing.allocator);
    defer list.deinit();
    const rgba: [4]u8 = .{ 1, 2, 3, 4 };
    var key: ImageKey = std.mem.zeroes(ImageKey);
    for (0..max_images) |i| {
        list.begin();
        key.image_id = @intCast(i);
        try std.testing.expectEqual(@as(u16, @intCast(i)), try list.uploadImage(key, &rgba, 1, 1));
    }
    list.begin();
    key.image_id = 0;
    try std.testing.expectEqual(@as(?u16, 0), list.findImage(key));
    key.image_id = 1000;
    // Slot 0 was used this frame; slot 1 is the oldest other slot.
    try std.testing.expectEqual(@as(u16, 1), try list.uploadImage(key, &rgba, 1, 1));
}
