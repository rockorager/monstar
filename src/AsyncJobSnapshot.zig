//! Owned overlay and Kitty inputs borrowed by an in-flight async raster job.

const AsyncJobSnapshot = @This();

const std = @import("std");
const Renderer = @import("Renderer.zig");
const KittyImageCache = @import("KittyImageCache.zig");

preedit: ?[]u8 = null,
link_hint: ?[]u8 = null,
search: ?[]u8 = null,
search_no_match: bool = false,
link_range: ?Renderer.LinkRange = null,
search_range: ?Renderer.LinkRange = null,
search_matches: std.ArrayList(bool) = .empty,
scrollbar: ?Renderer.ScrollbarThumb = null,
hyperlink_hints: bool = false,
kitty: []Renderer.KittyRenderItem = &.{},

pub fn deinit(self: *AsyncJobSnapshot, alloc: std.mem.Allocator, cache: *KittyImageCache) void {
    if (self.preedit) |value| alloc.free(value);
    if (self.link_hint) |value| alloc.free(value);
    if (self.search) |value| alloc.free(value);
    self.search_matches.deinit(alloc);
    self.releaseKitty(alloc, cache);
}

pub fn replaceOverlays(
    self: *AsyncJobSnapshot,
    alloc: std.mem.Allocator,
    preedit: ?[]const u8,
    link_hint: ?[]const u8,
    search: ?[]u8,
    search_no_match: bool,
    link_range: ?Renderer.LinkRange,
    search_range: ?Renderer.LinkRange,
    search_matches: std.ArrayList(bool),
    scrollbar: ?Renderer.ScrollbarThumb,
    hyperlink_hints: bool,
) !void {
    var new_preedit: ?[]u8 = null;
    errdefer if (new_preedit) |value| alloc.free(value);
    var new_link_hint: ?[]u8 = null;
    errdefer if (new_link_hint) |value| alloc.free(value);
    errdefer if (search) |value| alloc.free(value);
    const matches = search_matches;
    if (preedit) |value| new_preedit = try alloc.dupe(u8, value);
    if (link_hint) |value| new_link_hint = try alloc.dupe(u8, value);

    if (self.preedit) |value| alloc.free(value);
    if (self.link_hint) |value| alloc.free(value);
    if (self.search) |value| alloc.free(value);
    self.search_matches.deinit(alloc);
    self.preedit = new_preedit;
    self.link_hint = new_link_hint;
    self.search = search;
    self.search_no_match = search_no_match;
    self.link_range = link_range;
    self.search_range = search_range;
    self.search_matches = matches;
    self.scrollbar = scrollbar;
    self.hyperlink_hints = hyperlink_hints;
}

pub fn releaseKitty(self: *AsyncJobSnapshot, alloc: std.mem.Allocator, cache: *KittyImageCache) void {
    for (self.kitty) |item| cache.release(item.image.id, item.image.generation);
    alloc.free(self.kitty);
    self.kitty = &.{};
}

pub fn replaceKitty(self: *AsyncJobSnapshot, alloc: std.mem.Allocator, cache: *KittyImageCache, items: []Renderer.KittyRenderItem) !void {
    errdefer alloc.free(items);
    var acquired: usize = 0;
    errdefer for (items[0..acquired]) |item| cache.release(item.image.id, item.image.generation);
    for (items) |*item| {
        item.image.data = try cache.acquire(alloc, item.image);
        acquired += 1;
    }
    self.releaseKitty(alloc, cache);
    self.kitty = items;
}
