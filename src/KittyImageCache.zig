//! Refcounted copies of kitty image pixel data.
//!
//! The terminal owns kitty image bytes and may free or replace them
//! whenever a delete or retransmission is parsed. The async raster
//! worker reads image bytes off the main thread, so each submitted job
//! pins a private copy here, keyed by the storage's (id, generation)
//! stamp: a new generation means new contents and therefore a new
//! copy, while repeated frames of an unchanged image share one copy.

const KittyImageCache = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

const Key = struct {
    image_id: u32,
    generation: u64,
};

const Entry = struct {
    /// Number of submitted jobs pinning this copy. The map itself
    /// holds no reference; sweep() frees entries no job pins.
    refs: u32,
    data: []u8,
};

entries: std.AutoHashMapUnmanaged(Key, *Entry),

pub const empty: KittyImageCache = .{ .entries = .empty };

pub fn deinit(self: *KittyImageCache, alloc: std.mem.Allocator) void {
    var it = self.entries.valueIterator();
    while (it.next()) |entry| {
        alloc.free(entry.*.data);
        alloc.destroy(entry.*);
    }
    self.entries.deinit(alloc);
    self.* = undefined;
}

/// Pin a copy of `image`'s pixel data, copying it on first use for
/// this (id, generation). Pair with release() when the job no longer
/// needs the bytes.
pub fn acquire(
    self: *KittyImageCache,
    alloc: std.mem.Allocator,
    image: vt.kitty.graphics.Image,
) ![]const u8 {
    std.debug.assert(image.generation != 0);
    const gop = try self.entries.getOrPut(alloc, .{
        .image_id = image.id,
        .generation = image.generation,
    });
    if (gop.found_existing) {
        gop.value_ptr.*.refs += 1;
        return gop.value_ptr.*.data;
    }
    errdefer self.entries.removeByPtr(gop.key_ptr);
    const entry = try alloc.create(Entry);
    errdefer alloc.destroy(entry);
    entry.* = .{ .refs = 1, .data = try alloc.dupe(u8, image.data) };
    gop.value_ptr.* = entry;
    return entry.data;
}

/// Drop a job's pin. The copy stays cached until the next sweep() so
/// consecutive frames of the same image never re-copy.
pub fn release(self: *KittyImageCache, image_id: u32, generation: u64) void {
    const entry = self.entries.get(.{
        .image_id = image_id,
        .generation = generation,
    }) orelse unreachable;
    std.debug.assert(entry.refs > 0);
    entry.refs -= 1;
}

/// Free entries no job pins. Run after a submit has re-pinned the
/// images it still needs, so copies shared by consecutive frames
/// survive the sweep.
pub fn sweep(self: *KittyImageCache, alloc: std.mem.Allocator) void {
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.*.refs > 0) continue;
        alloc.free(kv.value_ptr.*.data);
        alloc.destroy(kv.value_ptr.*);
        self.entries.removeByPtr(kv.key_ptr);
    }
}

test "acquire shares copies by generation and sweep frees unpinned" {
    const alloc = std.testing.allocator;
    var cache: KittyImageCache = .empty;
    defer cache.deinit(alloc);

    const image: vt.kitty.graphics.Image = .{
        .id = 7,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = &.{ 1, 2, 3, 4 },
        .generation = 1,
    };

    const a = try cache.acquire(alloc, image);
    const b = try cache.acquire(alloc, image);
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqualSlices(u8, image.data, a);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    var next = image;
    next.generation = 2;
    const c = try cache.acquire(alloc, next);
    try std.testing.expect(c.ptr != a.ptr);
    try std.testing.expectEqual(@as(u32, 2), cache.entries.count());

    // Still pinned: sweep frees nothing.
    cache.sweep(alloc);
    try std.testing.expectEqual(@as(u32, 2), cache.entries.count());

    cache.release(7, 1);
    cache.release(7, 1);
    cache.sweep(alloc);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    cache.release(7, 2);
    cache.sweep(alloc);
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}
