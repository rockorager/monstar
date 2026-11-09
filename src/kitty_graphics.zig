//! Collects Kitty graphics placements into renderer-independent snapshots.
//!
//! Ghostty's RenderState resolves where placements go; this module
//! snapshots them on the main thread and owns pure placement policy such as
//! occlusion culling. Image bytes remain owned by the terminal after
//! collection.

const std = @import("std");
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");

const KittyImage = vt.kitty.graphics.Image;

pub const KittyPlacementViewport = struct {
    viewport_col: i32,
    viewport_row: i32,
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
    /// Value copy of the storage's image record. `data` is the current
    /// frame and points into terminal storage after collection; async
    /// callers must repoint it at a pinned copy before handing items to
    /// the worker. The terminal-owned `animation` pointer is cleared.
    image: KittyImage,
    viewport: KittyPlacementViewport,
};

/// Snapshot the kitty placements that `state`'s last update found into
/// terminal-independent render items, z-sorted. `state` must have been
/// updated from `terminal` with no terminal changes since. Renderers clip
/// to their pixel viewport. The returned slice is owned by the caller;
/// each item's image data still points into the terminal's storage.
pub fn collectKittyPlacements(
    font: *const Font,
    alloc: std.mem.Allocator,
    terminal: *const vt.Terminal,
    state: *const vt.RenderState,
) ![]KittyRenderItem {
    const storage = &terminal.screens.active.kitty_images;

    var placements: std.ArrayList(KittyRenderItem) = .empty;
    errdefer placements.deinit(alloc);

    var it = state.imagePlacementIterator();
    while (it.next()) |placement| {
        // Ghostty saturates placement sizes that overflow u32. Drawing
        // one would allocate a scaled image billions of pixels tall.
        if (placement.width == std.math.maxInt(u32) or placement.height == std.math.maxInt(u32)) continue;
        var image = storage.imageById(placement.image_id) orelse continue;
        image.data = image.renderData();
        image.animation = null;
        if (image.data.bytes() == null) continue;
        try placements.append(alloc, .{
            .image_id = placement.image_id,
            .placement_id = placement.protocol.kitty.placement_id,
            .z = placement.z,
            .image = image,
            .viewport = .{
                .viewport_col = placement.x,
                .viewport_row = placement.y,
                .offset_x = placement.offset_x,
                .offset_y = placement.offset_y,
                .pixel_width = placement.width,
                .pixel_height = placement.height,
                .source_x = placement.source_x,
                .source_y = placement.source_y,
                .source_width = placement.source_width,
                .source_height = placement.source_height,
            },
        });
    }

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
                .image = .{ .width = w, .height = h, .format = format },
                .viewport = .{
                    .viewport_col = col,
                    .viewport_row = row,
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

test "collect relative kitty placement rooted at a pin" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16, .{}, null);
    defer font.deinit(alloc);
    var terminal: vt.Terminal = try .init(std.testing.io, alloc, .{ .rows = 10, .cols = 10 });
    defer terminal.deinit(alloc);
    terminal.width_px = terminal.cols * font.cell_width;
    terminal.height_px = terminal.rows * font.cell_height;

    const storage = &terminal.screens.active.kitty_images;
    try storage.addImage(std.testing.io, alloc, terminal.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 0, 0, 0 }) },
    });
    const pin = try terminal.screens.active.pages.trackPin(
        terminal.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
    );
    try storage.addPlacement(std.testing.io, alloc, terminal.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try storage.addPlacement(std.testing.io, alloc, terminal.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 3,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 1,
    });

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    const items = try collectKittyPlacements(&font, alloc, &terminal, &state);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i32, 2), items[0].viewport.viewport_col);
    try std.testing.expectEqual(@as(i32, 1), items[0].viewport.viewport_row);
    try std.testing.expectEqual(@as(i32, 5), items[1].viewport.viewport_col);
    try std.testing.expectEqual(@as(i32, 3), items[1].viewport.viewport_row);
}

test "collect relative kitty placement rooted at virtual placeholders" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16, .{}, null);
    defer font.deinit(alloc);
    var terminal: vt.Terminal = try .init(std.testing.io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    terminal.width_px = terminal.cols * font.cell_width;
    terminal.height_px = terminal.rows * font.cell_height;
    terminal.modes.set(.grapheme_cluster, true);

    const storage = &terminal.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(std.testing.io, alloc, terminal.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(std.testing.io, alloc, terminal.screens.active, 1, 1, .{
        .location = .virtual,
    });

    try terminal.setAttribute(.{ .@"256_fg" = 1 });
    try terminal.setAttribute(.{ .@"256_underline_color" = 1 });
    terminal.screens.active.cursorAbsolute(1, 1);
    try terminal.printString("\u{10EEEE}\u{0305}\u{0305}");
    terminal.screens.active.cursorAbsolute(3, 2);
    try terminal.printString("\u{10EEEE}\u{0305}\u{0305}");

    try storage.addPlacement(std.testing.io, alloc, terminal.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    const items = try collectKittyPlacements(&font, alloc, &terminal, &state);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i32, 5), items[2].z);
    try std.testing.expectEqual(@as(i32, 2), items[2].viewport.viewport_col);
    try std.testing.expectEqual(@as(i32, 3), items[2].viewport.viewport_row);
}

test "collect drops kitty placements with overflowing geometry" {
    const alloc = std.testing.allocator;
    var font: Font = try .init(alloc, "monospace", 16, .{}, null);
    defer font.deinit(alloc);
    var terminal: vt.Terminal = try .init(std.testing.io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    terminal.width_px = terminal.cols * font.cell_width;
    terminal.height_px = terminal.rows * font.cell_height;

    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=1,C=1;////\x1b\\");
    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=2,s=1,v=1,c=1,r=4294967295,C=1;////\x1b\\");
    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=3,s=1,v=1,c=1,r=1,C=1;////\x1b\\");
    try std.testing.expectEqual(@as(usize, 3), terminal.screens.active.kitty_images.placements.count());

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &terminal);
    const items = try collectKittyPlacements(&font, alloc, &terminal, &state);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u32, 3), items[0].image_id);
}
