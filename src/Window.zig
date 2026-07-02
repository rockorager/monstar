//! Wayland window: display connection, global binding, an xdg_toplevel
//! surface, and wl_shm buffer management for CPU rendering.

const Window = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.window);

const default_width = 800;
const default_height = 600;

/// Opaque dark background, ARGB8888.
const bg_color: u32 = 0xff1a1b26;

alloc: std.mem.Allocator,
display: *wl.Display,
registry: *wl.Registry,
compositor: *wl.Compositor,
shm: *wl.Shm,
wm_base: *xdg.WmBase,
surface: *wl.Surface,
xdg_surface: *xdg.Surface,
toplevel: *xdg.Toplevel,
buffers: std.ArrayList(*Buffer),
width: u31,
height: u31,
pending_width: u31,
pending_height: u31,
running: bool,

/// Globals collected during the initial registry roundtrip.
const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
};

/// Heap-allocated because Wayland listeners hold a pointer to the Window.
pub fn create(alloc: std.mem.Allocator) !*Window {
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    var globals: Globals = .{};
    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const shm = globals.shm orelse return error.NoWlShm;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;

    const surface = try compositor.createSurface();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    const toplevel = try xdg_surface.getToplevel();
    toplevel.setAppId("vtread");
    toplevel.setTitle("vtread");

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .display = display,
        .registry = registry,
        .compositor = compositor,
        .shm = shm,
        .wm_base = wm_base,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .buffers = .empty,
        .width = default_width,
        .height = default_height,
        .pending_width = default_width,
        .pending_height = default_height,
        .running = true,
    };

    wm_base.setListener(*Window, wmBaseListener, self);
    xdg_surface.setListener(*Window, xdgSurfaceListener, self);
    toplevel.setListener(*Window, toplevelListener, self);
    surface.commit();

    return self;
}

pub fn destroy(self: *Window) void {
    for (self.buffers.items) |buffer| buffer.destroy(self.alloc);
    self.buffers.deinit(self.alloc);
    self.toplevel.destroy();
    self.xdg_surface.destroy();
    self.surface.destroy();
    self.wm_base.destroy();
    self.shm.destroy();
    self.compositor.destroy();
    self.registry.destroy();
    self.display.disconnect();
    self.alloc.destroy(self);
}

/// Block until there are events, dispatching them. Returns false once
/// the window has been closed.
pub fn dispatch(self: *Window) !bool {
    if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
    return self.running;
}

/// Fill the window with the background color and commit.
fn draw(self: *Window) !void {
    const buffer = try self.acquireBuffer(self.width, self.height);
    @memset(buffer.pixels(), bg_color);

    self.surface.attach(buffer.wl_buffer, 0, 0);
    self.surface.damageBuffer(0, 0, self.width, self.height);
    self.surface.commit();
    buffer.busy = true;
}

/// Return a free shm buffer of the requested size, creating one if
/// needed. Frees stale buffers of other sizes as they are released.
fn acquireBuffer(self: *Window, width: u31, height: u31) !*Buffer {
    var i: usize = 0;
    while (i < self.buffers.items.len) {
        const buffer = self.buffers.items[i];
        if (buffer.busy) {
            i += 1;
            continue;
        }
        if (buffer.width == width and buffer.height == height) return buffer;
        buffer.destroy(self.alloc);
        _ = self.buffers.swapRemove(i);
    }

    const buffer = try Buffer.create(self.alloc, self.shm, width, height);
    errdefer buffer.destroy(self.alloc);
    try self.buffers.append(self.alloc, buffer);
    return buffer;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                globals.wm_base = registry.bind(global.name, xdg.WmBase, 2) catch return;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            self.width = self.pending_width;
            self.height = self.pending_height;
            self.draw() catch |err| {
                log.err("draw failed: {}", .{err});
                self.running = false;
            };
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            // Zero means "client decides"; keep the current size then.
            if (configure.width > 0) self.pending_width = @intCast(configure.width);
            if (configure.height > 0) self.pending_height = @intCast(configure.height);
        },
        .close => self.running = false,
    }
}

/// A wl_shm backed pixel buffer. `busy` is true while the compositor
/// holds the buffer; the release event clears it.
const Buffer = struct {
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool,

    fn create(alloc: std.mem.Allocator, shm: *wl.Shm, width: u31, height: u31) !*Buffer {
        std.debug.assert(width > 0 and height > 0);
        const stride: u31 = width * 4;
        const size: u31 = stride * height;

        const fd = try posix.memfd_create("vtread-shm", linux.MFD.CLOEXEC);
        defer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, size)) != .SUCCESS) return error.ShmFailed;

        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pool = try shm.createPool(fd, size);
        defer pool.destroy();
        const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
        errdefer wl_buffer.destroy();

        const self = try alloc.create(Buffer);
        self.* = .{
            .wl_buffer = wl_buffer,
            .data = data,
            .width = width,
            .height = height,
            .busy = false,
        };
        wl_buffer.setListener(*Buffer, bufferListener, self);
        return self;
    }

    fn destroy(self: *Buffer, alloc: std.mem.Allocator) void {
        self.wl_buffer.destroy();
        posix.munmap(self.data);
        alloc.destroy(self);
    }

    fn pixels(self: *Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, self.data));
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};
