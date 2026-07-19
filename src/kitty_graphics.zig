//! Collects Kitty graphics placements into renderer-independent snapshots.
//!
//! This module owns main-thread terminal placement resolution and pure
//! placement policy. Image bytes remain owned by the terminal after collection.

const std = @import("std");
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");

const log = std.log.scoped(.renderer);
const KittyImage = vt.kitty.graphics.Image;
const KittyPlacement = vt.kitty.graphics.ImageStorage.Placement;
const KittyRenderPlacement = vt.kitty.graphics.RenderPlacement;

pub const KittyPlacementViewport = struct {
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

fn kittyRenderItemLessThan(_: void, lhs: KittyRenderItem, rhs: KittyRenderItem) bool {
    if (lhs.z != rhs.z) return lhs.z < rhs.z;
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    return lhs.placement_id < rhs.placement_id;
}

/// A placement's destination rectangle in framebuffer pixels,
/// unclipped. Mirrors the dest math in Renderer.renderKittyPlacement.
pub fn kittyDestRect(item: KittyRenderItem, cell_width: u31, cell_height: u31) struct {
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
pub fn kittyItemOpaque(item: KittyRenderItem) bool {
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
