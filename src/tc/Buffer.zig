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
mmap_len: ?usize = null,
fd: ?std.posix.fd_t = null,
is_borrowed: bool = false,

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

pub fn initMmap(
    cols: u32,
    rows: u32,
    format: Format,
    fd: std.posix.fd_t,
) !Buffer {
    const expected_size = switch (format) {
        .compact_v1 => @as(usize, cols) * rows * @sizeOf(CompactCell),
        .rich_v1 => @as(usize, cols) * rows * @sizeOf(RichCell),
    };
    const ptr = try std.posix.mmap(
        null,
        expected_size,
        std.posix.PROT{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    return .{
        .cols = cols,
        .rows = rows,
        .format = format,
        .data = ptr,
        .mmap_len = expected_size,
        .fd = fd,
    };
}

pub fn clone(self: Buffer, allocator: std.mem.Allocator) !Buffer {
    if (self.mmap_len != null) {
        // For mmapped buffers, borrow the underlying shared memory slice directly
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .format = self.format,
            .data = self.data,
            .is_borrowed = true,
        };
    }
    return try init(allocator, self.cols, self.rows, self.format, self.data);
}

pub fn deinit(self: *Buffer) void {
    if (self.is_borrowed) {
        // Borrowed view into shared memory; do not munmap or free
    } else if (self.mmap_len) |len| {
        const aligned_slice: []align(std.heap.page_size_min) const u8 = @alignCast(self.data[0..len]);
        std.posix.munmap(aligned_slice);
        if (self.fd) |f| _ = std.os.linux.close(f);
    } else if (self.allocator) |alloc| {
        alloc.free(self.data);
    }
    self.data = &.{};
    self.cols = 0;
    self.rows = 0;
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
