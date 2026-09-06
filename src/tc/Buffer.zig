//! Character cell buffer implementation for TC-Wayland.
//! Represents either an inline stream buffer (SCM_RIGHTS-free) or shared memory pool buffer.

const Buffer = @This();

const std = @import("std");
const wayland = @import("wayland");
const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const RichCell = abi.RichCell;

pub const Format = enum(u32) {
    compact_v1 = 1,
    rich_v1 = 2,
};

cols: u32,
rows: u32,
format: Format,
data: []u8,
allocator: ?std.mem.Allocator = null,

pub fn init(
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    format: Format,
    raw_bytes: []const u8,
) !Buffer {
    const expected_size = switch (format) {
        .compact_v1 => @as(usize, cols) * rows * @sizeOf(CompactCell),
        .rich_v1 => @as(usize, cols) * rows * @sizeOf(RichCell),
    };
    if (raw_bytes.len < expected_size) {
        return error.BufferTruncated;
    }

    const copy = try allocator.dupe(u8, raw_bytes[0..expected_size]);
    return .{
        .cols = cols,
        .rows = rows,
        .format = format,
        .data = copy,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Buffer) void {
    if (self.allocator) |alloc| {
        alloc.free(self.data);
    }
    self.* = undefined;
}

pub fn asCompactSlice(self: Buffer) []const CompactCell {
    std.debug.assert(self.format == .compact_v1);
    const count = @as(usize, self.cols) * self.rows;
    const ptr: [*]const CompactCell = @ptrCast(@alignCast(self.data.ptr));
    return ptr[0..count];
}

pub fn asRichSlice(self: Buffer) []const RichCell {
    std.debug.assert(self.format == .rich_v1);
    const count = @as(usize, self.cols) * self.rows;
    const ptr: [*]const RichCell = @ptrCast(@alignCast(self.data.ptr));
    return ptr[0..count];
}

test "Buffer compact_v1 lifecycle" {
    const allocator = std.testing.allocator;
    const cols: u32 = 4;
    const rows: u32 = 2;
    var cells: [8]CompactCell = undefined;
    for (&cells, 0..) |*c, i| {
        c.* = CompactCell.ascii(@intCast('0' + i), 15, 0);
    }

    var buf = try Buffer.init(allocator, cols, rows, .compact_v1, std.mem.sliceAsBytes(&cells));
    defer buf.deinit();

    try std.testing.expectEqual(cols, buf.cols);
    try std.testing.expectEqual(rows, buf.rows);
    const slice = buf.asCompactSlice();
    try std.testing.expectEqual(@as(u32, '0'), slice[0].codepoint);
    try std.testing.expectEqual(@as(u32, '7'), slice[7].codepoint);
}
