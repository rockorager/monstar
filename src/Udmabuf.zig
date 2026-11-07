//! Presents CPU-rendered memfd pixels as LINEAR linux-dmabuf buffers by
//! wrapping the memfd with /dev/udmabuf. The compositor then samples the
//! client's pages directly instead of copying wl_shm contents into a texture
//! on every commit.
//!
//! Every failure leaves callers on wl_shm: the device may be missing or
//! inaccessible, the compositor may not advertise LINEAR XRGB8888/ARGB8888,
//! or it may fail to import the first buffer. The first import of each
//! format uses a blocking `create` on a private queue; later buffers use
//! `create_immed`, whose failure compositors such as wlroots treat as fatal.

const Udmabuf = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const ShmBuffer = @import("ShmBuffer.zig");
const Format = ShmBuffer.Format;

const log = std.log.scoped(.udmabuf);

display: *wl.Display,
manager: *zwp.LinuxDmabufV1,
/// Warn instead of noting falling back to wl_shm, because the user asked for
/// dma-buf presentation.
required: bool,
device: Device = .unopened,
formats: std.EnumArray(Format, FormatState) = .initFill(.unsupported),

const Device = union(enum) {
    unopened,
    open: posix.fd_t,
    unavailable,
};

const FormatState = enum {
    unsupported,
    /// LINEAR advertised; the first import has not been tried.
    advertised,
    verified,
    rejected,
};

/// Takes ownership of `manager`, which must be bound at version 3 so the
/// compositor advertises its format and modifier pairs.
pub fn create(alloc: std.mem.Allocator, display: *wl.Display, manager: *zwp.LinuxDmabufV1, required: bool) !*Udmabuf {
    std.debug.assert(manager.getVersion() >= 3);
    const self = try alloc.create(Udmabuf);
    self.* = .{ .display = display, .manager = manager, .required = required };
    manager.setListener(*Udmabuf, managerListener, self);
    return self;
}

/// Buffers created through `self` stay valid; their dma-buf fds are owned by
/// the caller.
pub fn destroy(self: *Udmabuf, alloc: std.mem.Allocator) void {
    switch (self.device) {
        .open => |fd| _ = linux.close(fd),
        .unopened, .unavailable => {},
    }
    self.manager.destroy();
    alloc.destroy(self);
}

/// Return a new dma-buf fd covering `size` bytes of `memfd` from offset 0, or
/// null when udmabuf cannot be used. `memfd` must be sealed against
/// shrinking and `size` page aligned. The caller owns the returned fd.
pub fn wrap(self: *Udmabuf, memfd: posix.fd_t, size: usize) ?posix.fd_t {
    std.debug.assert(size > 0 and size % std.heap.page_size_min == 0);
    const device: posix.fd_t = switch (self.device) {
        .open => |fd| fd,
        .unavailable => return null,
        .unopened => device: {
            const rc = linux.open("/dev/udmabuf", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) {
                self.fallback("/dev/udmabuf unavailable ({t})", .{linux.errno(rc)});
                self.device = .unavailable;
                return null;
            }
            self.device = .{ .open = @intCast(rc) };
            break :device @intCast(rc);
        },
    };
    const Create = extern struct { memfd: u32, flags: u32, offset: u64, size: u64 };
    const flags_cloexec = 0x01;
    const create_ioctl = 0x40187542; // _IOW('u', 0x42, struct udmabuf_create)
    var request: Create = .{ .memfd = @intCast(memfd), .flags = flags_cloexec, .offset = 0, .size = size };
    const rc = linux.ioctl(device, create_ioctl, @intFromPtr(&request));
    if (linux.errno(rc) != .SUCCESS) {
        // Per-buffer limits such as udmabuf's size_limit_mb leave other
        // buffers eligible.
        log.warn("UDMABUF_CREATE of {d} bytes failed ({t}); presenting this buffer with wl_shm", .{ size, linux.errno(rc) });
        return null;
    }
    return @intCast(rc);
}

/// Create a LINEAR wl_buffer over `fd`, or return null when the compositor
/// cannot import `format`. The first call for each format blocks for one
/// roundtrip on a private queue, which dispatches no other events. The
/// compositor holds its own reference to `fd`.
pub fn createBuffer(
    self: *Udmabuf,
    fd: posix.fd_t,
    width: u31,
    height: u31,
    stride: u32,
    format: Format,
) ?*wl.Buffer {
    std.debug.assert(stride % ShmBuffer.stride_alignment == 0);
    switch (self.formats.get(format)) {
        .rejected => return null,
        .unsupported => {
            self.fallback("compositor does not advertise LINEAR {t}", .{format});
            self.formats.set(format, .rejected);
            return null;
        },
        .verified => {
            const params = self.manager.createParams() catch return null;
            defer params.destroy();
            params.add(fd, 0, 0, stride, 0, 0);
            return params.createImmed(width, height, fourcc(format), .{}) catch null;
        },
        .advertised => {
            const buffer = self.verifyImport(fd, width, height, stride, format) catch |err| blk: {
                log.warn("dma-buf import check failed: {}", .{err});
                break :blk null;
            };
            if (buffer == null) self.fallback("compositor rejected a LINEAR {t} udmabuf", .{format});
            self.formats.set(format, if (buffer != null) .verified else .rejected);
            return buffer;
        },
    }
}

fn fallback(self: *const Udmabuf, comptime format: []const u8, args: anytype) void {
    const message = format ++ "; presenting with wl_shm";
    if (self.required) log.warn(message, args) else log.info(message, args);
}

const ImportResult = union(enum) {
    pending,
    created: *wl.Buffer,
    failed,
};

extern fn wl_proxy_set_queue(proxy: *wl.Proxy, queue: ?*wl.EventQueue) void;

fn verifyImport(self: *Udmabuf, fd: posix.fd_t, width: u31, height: u31, stride: u32, format: Format) !?*wl.Buffer {
    const queue = try self.display.createQueue();
    defer queue.destroy();
    const params = try self.manager.createParams();
    defer params.destroy();
    params.setQueue(queue);
    var result: ImportResult = .pending;
    params.setListener(*ImportResult, importListener, &result);
    params.add(fd, 0, 0, stride, 0, 0);
    params.create(width, height, fourcc(format), .{});
    while (result == .pending) {
        if (self.display.roundtripQueue(queue) != .SUCCESS) return error.RoundtripFailed;
    }
    switch (result) {
        .pending => unreachable,
        .failed => return null,
        .created => |buffer| {
            // The new proxy inherited the private queue; release events
            // must reach the main loop.
            wl_proxy_set_queue(@ptrCast(buffer), null);
            return buffer;
        },
    }
}

fn importListener(_: *zwp.LinuxBufferParamsV1, event: zwp.LinuxBufferParamsV1.Event, result: *ImportResult) void {
    result.* = switch (event) {
        .created => |created| .{ .created = created.buffer },
        .failed => .failed,
    };
}

fn managerListener(_: *zwp.LinuxDmabufV1, event: zwp.LinuxDmabufV1.Event, self: *Udmabuf) void {
    switch (event) {
        .format => {},
        .modifier => |modifier| {
            if (modifier.modifier_hi != 0 or modifier.modifier_lo != 0) return;
            inline for (comptime std.enums.values(Format)) |format| {
                if (modifier.format == fourcc(format) and self.formats.get(format) == .unsupported)
                    self.formats.set(format, .advertised);
            }
        },
    }
}

fn fourcc(format: Format) u32 {
    return switch (format) {
        .xrgb8888 => 0x34325258, // XR24
        .argb8888 => 0x34325241, // AR24
    };
}
