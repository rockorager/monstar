//! The representations of one outgoing drag. A protocol session fills them
//! while native transfers read them, and those transfers may outlive both
//! the session and the native drag, so the offer is reference counted.
//! Items never change after the offer is built; only their data grows.

const DragOffer = @This();

const std = @import("std");

alloc: std.mem.Allocator,
refs: u32 = 1,
items: std.ArrayList(Item) = .empty,

pub const Item = struct {
    mime: [:0]u8,
    /// Whether the native drag advertises this representation.
    advertised: bool,
    data: std.ArrayList(u8) = .empty,
    state: State = .pending,
};

/// Pending data may still grow. Complete data is final, and failed data
/// must not be served.
pub const State = enum { pending, complete, failed };

/// The caller owns the single initial reference.
pub fn create(alloc: std.mem.Allocator) std.mem.Allocator.Error!*DragOffer {
    const self = try alloc.create(DragOffer);
    self.* = .{ .alloc = alloc };
    return self;
}

pub fn retain(self: *DragOffer) *DragOffer {
    std.debug.assert(self.refs > 0);
    self.refs += 1;
    return self;
}

pub fn release(self: *DragOffer) void {
    std.debug.assert(self.refs > 0);
    self.refs -= 1;
    if (self.refs > 0) return;
    for (self.items.items) |*item| {
        self.alloc.free(item.mime);
        item.data.deinit(self.alloc);
    }
    self.items.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Copies `mime`.
pub fn append(self: *DragOffer, mime: []const u8, advertised: bool) std.mem.Allocator.Error!void {
    const owned = try self.alloc.dupeZ(u8, mime);
    errdefer self.alloc.free(owned);
    try self.items.append(self.alloc, .{ .mime = owned, .advertised = advertised });
}

/// The first advertised item with this MIME type.
pub fn advertisedIndex(self: *const DragOffer, mime: []const u8) ?usize {
    for (self.items.items, 0..) |item, i| {
        if (item.advertised and std.mem.eql(u8, item.mime, mime)) return i;
    }
    return null;
}
