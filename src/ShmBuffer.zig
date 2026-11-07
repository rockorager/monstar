//! A CPU-writable pixel buffer backed by a memfd sealed against shrinking.
//! The compositor receives it as a LINEAR dma-buf when Udmabuf can wrap the
//! memfd, and as wl_shm otherwise. Both paths share one padded row layout.

const ShmBuffer = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const Udmabuf = @import("Udmabuf.zig");

/// Row pitch alignment in bytes. GPUs import LINEAR buffers only with aligned
/// pitches; 256 bytes satisfies amdgpu, the strictest common driver. wl_shm
/// accepts any pitch.
pub const stride_alignment = 256;

wl_buffer: *wl.Buffer,
pool: *wl.ShmPool,
fd: posix.fd_t,
data: []align(std.heap.page_size_min) u8,
/// Null presents through wl_shm only.
udmabuf: ?*Udmabuf,
/// dma-buf view of all of `data`, recreated when the pool grows.
udmabuf_fd: ?posix.fd_t,
width: u31,
height: u31,
/// Row pitch in pixels; at least `width`.
stride: u31,
format: Format,
busy: bool,
rendering: bool,
/// Window.frame_counter assigned by the latest commitRender attempt;
/// 0 means no commit attempt has been recorded.
frame: u64,

pub const Format = enum {
    xrgb8888,
    argb8888,
};

pub fn create(
    alloc: std.mem.Allocator,
    shm: *wl.Shm,
    udmabuf: ?*Udmabuf,
    width: u31,
    height: u31,
    format: Format,
) !*ShmBuffer {
    std.debug.assert(width > 0 and height > 0);
    const dimensions = try bufferDimensions(width, height);
    const capacity = try grownBufferCapacity(0, dimensions.size);

    const fd = try posix.memfd_create("monstar-shm", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(capacity))) != .SUCCESS) return error.ShmFailed;
    // udmabuf requires this seal, and it keeps a compositor mapping of the
    // pool from faulting: the pool only ever grows.
    if (linux.errno(linux.fcntl(fd, linux.F.ADD_SEALS, linux.F.SEAL_SHRINK)) != .SUCCESS) return error.ShmFailed;

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
    const udmabuf_fd = if (udmabuf) |value| value.wrap(fd, capacity) else null;
    errdefer if (udmabuf_fd) |value| {
        _ = linux.close(value);
    };
    const wl_buffer = try createWlBuffer(pool, udmabuf, udmabuf_fd, width, height, dimensions.stride, format);
    errdefer wl_buffer.destroy();

    const self = try alloc.create(ShmBuffer);
    self.* = .{
        .wl_buffer = wl_buffer,
        .pool = pool,
        .fd = fd,
        .data = data,
        .udmabuf = udmabuf,
        .udmabuf_fd = udmabuf_fd,
        .width = width,
        .height = height,
        .stride = dimensions.stridePixels(),
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
        // A udmabuf covers a fixed range; the grown tail needs a new one.
        if (self.udmabuf_fd) |fd| _ = linux.close(fd);
        self.udmabuf_fd = if (self.udmabuf) |udmabuf| udmabuf.wrap(self.fd, capacity) else null;
    }

    const wl_buffer = try createWlBuffer(self.pool, self.udmabuf, self.udmabuf_fd, width, height, dimensions.stride, format);
    wl_buffer.setListener(*ShmBuffer, bufferListener, self);
    self.wl_buffer.destroy();
    self.wl_buffer = wl_buffer;
    self.width = width;
    self.height = height;
    self.stride = dimensions.stridePixels();
    self.format = format;
    self.frame = 0;
}

pub fn destroy(self: *ShmBuffer, alloc: std.mem.Allocator) void {
    self.wl_buffer.destroy();
    self.pool.destroy();
    posix.munmap(self.data);
    _ = linux.close(self.fd);
    if (self.udmabuf_fd) |fd| _ = linux.close(fd);
    alloc.destroy(self);
}

/// Prefer the dma-buf view of the pool and fall back to wl_shm when there is
/// none or the compositor cannot import it.
fn createWlBuffer(
    pool: *wl.ShmPool,
    udmabuf: ?*Udmabuf,
    udmabuf_fd: ?posix.fd_t,
    width: u31,
    height: u31,
    stride: i32,
    format: Format,
) !*wl.Buffer {
    if (udmabuf_fd) |fd| {
        if (udmabuf.?.createBuffer(fd, width, height, @intCast(stride), format)) |buffer| return buffer;
    }
    return pool.createBuffer(0, width, height, stride, shmFormat(format));
}

/// Rows of `stride` pixels; columns at and beyond `width` are not displayed.
pub fn pixels(self: *ShmBuffer) []u32 {
    const pixel_count = @as(usize, self.stride) * @as(usize, self.height);
    return @alignCast(std.mem.bytesAsSlice(u32, self.data)[0..pixel_count]);
}

fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *ShmBuffer) void {
    switch (event) {
        .release => self.busy = false,
    }
}

const BufferDimensions = struct {
    /// Row pitch in bytes.
    stride: i32,
    size: usize,

    fn stridePixels(self: BufferDimensions) u31 {
        return @intCast(@divExact(self.stride, @sizeOf(u32)));
    }
};

fn bufferDimensions(width: u31, height: u31) !BufferDimensions {
    const stride = std.mem.alignForward(usize, @as(usize, width) * @sizeOf(u32), stride_alignment);
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
