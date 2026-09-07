//! Character cell buffer implementation for TC-Wayland.
//! Represents either an inline stream buffer (SCM_RIGHTS-free) or shared memory pool buffer.

const Buffer = @This();

const std = @import("std");
const wayland = @import("wayland");
const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const RichCell = abi.RichCell;

pub const Format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    compact_v1 = 0x54433143, // 'TC1C'
    rich_v1 = 0x54433152, // 'TC1R'

    pub fn toShmFormat(self: Format) u32 {
        return @intFromEnum(self);
    }

    pub fn fromShmFormat(val: u32) ?Format {
        return switch (val) {
            0 => .argb8888,
            1 => .xrgb8888,
            0x54433143 => .compact_v1,
            0x54433152 => .rich_v1,
            3 => .argb8888,
            4 => .xrgb8888,
            else => null,
        };
    }

    pub fn isPixel(self: Format) bool {
        return self == .argb8888 or self == .xrgb8888;
    }
};

cols: u32,
rows: u32,
stride: u32 = 0,
format: Format,
data: []u8,
allocator: ?std.mem.Allocator = null,

pub fn expectedByteSize(format: Format, cols: u32, rows: u32, stride: u32) usize {
    return switch (format) {
        .compact_v1 => if (stride > 0) @as(usize, stride) * rows else @as(usize, cols) * rows * @sizeOf(CompactCell),
        .rich_v1 => if (stride > 0) @as(usize, stride) * rows else @as(usize, cols) * rows * @sizeOf(RichCell),
        .argb8888, .xrgb8888 => if (stride > 0) @as(usize, stride) * rows else @as(usize, cols) * rows * 4,
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    format: Format,
    raw_bytes: []const u8,
) !Buffer {
    const stride = if (format == .argb8888 or format == .xrgb8888) cols * 4 else 0;
    return initWithStride(allocator, cols, rows, stride, format, raw_bytes);
}

pub fn initWithStride(
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    stride: u32,
    format: Format,
    raw_bytes: []const u8,
) !Buffer {
    const expected_size = expectedByteSize(format, cols, rows, stride);
    if (raw_bytes.len < expected_size) {
        return error.BufferTruncated;
    }

    const copy = try allocator.dupe(u8, raw_bytes[0..expected_size]);
    return .{
        .cols = cols,
        .rows = rows,
        .stride = stride,
        .format = format,
        .data = copy,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Buffer) void {
    if (self.allocator) |alloc| {
        alloc.free(self.data);
    }
    self.data = &.{};
    self.cols = 0;
    self.rows = 0;
    self.stride = 0;
}

pub fn isPixel(self: Buffer) bool {
    return self.format == .argb8888 or self.format == .xrgb8888;
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

pub fn asPixelSlice(self: Buffer) []const u32 {
    std.debug.assert(self.isPixel());
    const count = self.data.len / @sizeOf(u32);
    const ptr: [*]const u32 = @ptrCast(@alignCast(self.data.ptr));
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
