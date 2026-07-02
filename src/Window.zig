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
seat: ?*wl.Seat,
keyboard: ?*wl.Keyboard,
surface: *wl.Surface,
xdg_surface: *xdg.Surface,
toplevel: *xdg.Toplevel,
buffers: std.ArrayList(*Buffer),
width: u31,
height: u31,
pending_width: u31,
pending_height: u31,
running: bool,
/// A frame callback is outstanding; drawing now would outpace the
/// compositor. `redraw()` queues instead.
frame_pending: bool,
redraw_queued: bool,
render_ctx: ?*anyopaque,
render_fn: ?RenderFn,
resize_fn: ?ResizeFn,
keyboard_fn: ?KeyboardFn,

/// Draw delegate: fills `pixels` (width*height ARGB8888, stride == width).
pub const RenderFn = *const fn (ctx: *anyopaque, pixels: []u32, width: u31, height: u31) anyerror!void;

/// Called when the window size changed, before the next draw.
pub const ResizeFn = *const fn (ctx: *anyopaque, width: u31, height: u31) anyerror!void;

/// Raw wl_keyboard events, forwarded as-is.
pub const KeyboardFn = *const fn (ctx: *anyopaque, event: wl.Keyboard.Event) void;

/// Globals collected during the initial registry roundtrip.
const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
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
        .seat = globals.seat,
        .keyboard = null,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .buffers = .empty,
        // Zero until the first configure so the resize callback always
        // fires before the first draw.
        .width = 0,
        .height = 0,
        .pending_width = default_width,
        .pending_height = default_height,
        .running = true,
        .frame_pending = false,
        .redraw_queued = false,
        .render_ctx = null,
        .render_fn = null,
        .resize_fn = null,
        .keyboard_fn = null,
    };

    if (globals.seat) |seat| seat.setListener(*Window, seatListener, self);
    wm_base.setListener(*Window, wmBaseListener, self);
    xdg_surface.setListener(*Window, xdgSurfaceListener, self);
    toplevel.setListener(*Window, toplevelListener, self);
    surface.commit();

    return self;
}

pub fn destroy(self: *Window) void {
    for (self.buffers.items) |buffer| buffer.destroy(self.alloc);
    self.buffers.deinit(self.alloc);
    if (self.keyboard) |keyboard| keyboard.release();
    if (self.seat) |seat| seat.release();
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

/// Set the delegates for drawing, resizing, and keyboard input.
pub fn setCallbacks(
    self: *Window,
    ctx: *anyopaque,
    render_fn: RenderFn,
    resize_fn: ?ResizeFn,
    keyboard_fn: ?KeyboardFn,
) void {
    self.render_ctx = ctx;
    self.render_fn = render_fn;
    self.resize_fn = resize_fn;
    self.keyboard_fn = keyboard_fn;
}

/// Redraw as soon as the compositor is ready for a new frame: now if no
/// frame callback is outstanding, otherwise when it fires.
pub fn redraw(self: *Window) !void {
    // Not configured yet; the first configure triggers the first draw.
    if (self.width == 0) return;
    if (self.frame_pending) {
        self.redraw_queued = true;
        return;
    }
    try self.draw();
}

/// Redraw the window contents and commit.
fn draw(self: *Window) !void {
    const buffer = try self.acquireBuffer(self.width, self.height);
    if (self.render_fn) |render_fn| {
        try render_fn(self.render_ctx.?, buffer.pixels(), self.width, self.height);
    } else {
        @memset(buffer.pixels(), bg_color);
    }

    // Throttle future redraws to the compositor's pace. Configure-driven
    // draws may run while a callback is already outstanding; don't stack.
    if (!self.frame_pending) {
        const frame_cb = try self.surface.frame();
        frame_cb.setListener(*Window, frameListener, self);
        self.frame_pending = true;
    }

    self.surface.attach(buffer.wl_buffer, 0, 0);
    self.surface.damageBuffer(0, 0, self.width, self.height);
    self.surface.commit();
    buffer.busy = true;
}

fn frameListener(frame_cb: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
    switch (event) {
        .done => {
            frame_cb.destroy();
            self.frame_pending = false;
            if (self.redraw_queued) {
                self.redraw_queued = false;
                self.draw() catch |err| {
                    log.err("draw failed: {}", .{err});
                    self.running = false;
                };
            }
        },
    }
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
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, @min(global.version, 5)) catch return;
            }
        },
        .global_remove => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Window) void {
    switch (event) {
        .capabilities => |caps| {
            const has_keyboard = caps.capabilities.keyboard;
            if (has_keyboard and self.keyboard == null) {
                self.keyboard = seat.getKeyboard() catch |err| keyboard: {
                    log.err("getKeyboard failed: {}", .{err});
                    break :keyboard null;
                };
                if (self.keyboard) |keyboard| {
                    keyboard.setListener(*Window, keyboardListener, self);
                }
            } else if (!has_keyboard and self.keyboard != null) {
                self.keyboard.?.release();
                self.keyboard = null;
            }
        },
        .name => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Window) void {
    if (self.keyboard_fn) |keyboard_fn| keyboard_fn(self.render_ctx.?, event);
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
            const resized = self.width != self.pending_width or
                self.height != self.pending_height;
            self.width = self.pending_width;
            self.height = self.pending_height;
            if (resized) {
                if (self.resize_fn) |resize_fn| {
                    resize_fn(self.render_ctx.?, self.width, self.height) catch |err| {
                        log.err("resize handler failed: {}", .{err});
                        self.running = false;
                        return;
                    };
                }
            }
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
