//! A wl_shm-backed pixel buffer and its mapped pool storage.

const ShmBuffer = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;

wl_buffer: *wl.Buffer,
pool: *wl.ShmPool,
fd: posix.fd_t,
data: []align(std.heap.page_size_min) u8,
width: u31,
height: u31,
format: Format,
busy: bool,
rendering: bool,
/// Window.frame_counter value when this buffer was last drawn;
/// 0 means never (content undefined).
frame: u64,

pub const Format = enum {
    xrgb8888,
    argb8888,
};

pub fn create(
    alloc: std.mem.Allocator,
    shm: *wl.Shm,
    width: u31,
    height: u31,
    format: Format,
) !*ShmBuffer {
    std.debug.assert(width > 0 and height > 0);
    const dimensions = try bufferDimensions(width, height);
    const capacity = try grownBufferCapacity(0, dimensions.size);

    const fd = try posix.memfd_create("monstar-shm", linux.MFD.CLOEXEC);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(capacity))) != .SUCCESS) return error.ShmFailed;

    const data = try posix.mmap(
        null,
        capacity,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer posix.munmap(data);

    const pool = try shm.createPool(fd, @intCast(capacity));
    errdefer pool.destroy();
    const wl_buffer = try pool.createBuffer(0, width, height, dimensions.stride, shmFormat(format));
    errdefer wl_buffer.destroy();

    const self = try alloc.create(ShmBuffer);
    self.* = .{
        .wl_buffer = wl_buffer,
        .pool = pool,
        .fd = fd,
        .data = data,
        .width = width,
        .height = height,
        .format = format,
        .busy = false,
        .rendering = false,
        .frame = 0,
    };
    wl_buffer.setListener(*ShmBuffer, bufferListener, self);
    return self;
}

pub fn reshape(self: *ShmBuffer, width: u31, height: u31, format: Format) !void {
    std.debug.assert(!self.busy and !self.rendering);
    std.debug.assert(width > 0 and height > 0);
    const dimensions = try bufferDimensions(width, height);
    if (dimensions.size > self.data.len) {
        const capacity = try grownBufferCapacity(self.data.len, dimensions.size);
        if (linux.errno(linux.ftruncate(self.fd, @intCast(capacity))) != .SUCCESS) return error.ShmFailed;
        const data = try posix.mmap(
            null,
            capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            self.fd,
            0,
        );
        self.pool.resize(@intCast(capacity));
        posix.munmap(self.data);
        self.data = data;
    }

    const wl_buffer = try self.pool.createBuffer(0, width, height, dimensions.stride, shmFormat(format));
    wl_buffer.setListener(*ShmBuffer, bufferListener, self);
    self.wl_buffer.destroy();
    self.wl_buffer = wl_buffer;
    self.width = width;
    self.height = height;
    self.format = format;
    self.frame = 0;
}

pub fn destroy(self: *ShmBuffer, alloc: std.mem.Allocator) void {
    self.wl_buffer.destroy();
    self.pool.destroy();
    posix.munmap(self.data);
    _ = linux.close(self.fd);
    alloc.destroy(self);
}

pub fn pixels(self: *ShmBuffer) []u32 {
    const pixel_count = @as(usize, self.width) * @as(usize, self.height);
    return @alignCast(std.mem.bytesAsSlice(u32, self.data)[0..pixel_count]);
}

fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *ShmBuffer) void {
    switch (event) {
        .release => self.busy = false,
    }
}

const BufferDimensions = struct {
    stride: i32,
    size: usize,
};

fn bufferDimensions(width: u31, height: u31) !BufferDimensions {
    const stride = @as(usize, width) * @sizeOf(u32);
    const size = stride * @as(usize, height);
    if (stride > std.math.maxInt(i32) or size > std.math.maxInt(i32)) return error.ShmBufferTooLarge;
    return .{ .stride = @intCast(stride), .size = size };
}

fn grownBufferCapacity(current: usize, required: usize) !usize {
    const max_capacity: usize = std.math.maxInt(i32);
    if (required > max_capacity) return error.ShmBufferTooLarge;
    const geometric = current +| current / 2;
    const wanted = @max(required, @max(std.heap.page_size_min, geometric));
    const aligned = std.mem.alignForward(usize, wanted, std.heap.page_size_min);
    return if (aligned <= max_capacity) aligned else required;
}

fn shmFormat(format: Format) wl.Shm.Format {
    return switch (format) {
        .xrgb8888 => .xrgb8888,
        .argb8888 => .argb8888,
    };
}

test "SHM buffer capacity grows geometrically and remains page aligned" {
    const initial = try grownBufferCapacity(0, 1000);
    try std.testing.expect(initial >= 1000);
    try std.testing.expectEqual(@as(usize, 0), initial % std.heap.page_size_min);

    const grown = try grownBufferCapacity(initial, initial + 1);
    try std.testing.expect(grown >= initial + initial / 2);
    try std.testing.expectEqual(@as(usize, 0), grown % std.heap.page_size_min);
}
