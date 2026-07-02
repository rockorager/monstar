//! Wayland window: display connection, global binding, an xdg_toplevel
//! surface, and wl_shm buffer management for CPU rendering.

const Window = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const zwp = wayland.client.zwp;

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
pointer: ?*wl.Pointer,
cursor_shape_manager: ?*wp.CursorShapeManagerV1,
cursor_shape_device: ?*wp.CursorShapeDeviceV1,
cursor_shape: CursorShape,
pointer_enter_serial: ?u32,
/// Clipboard: managers create sources (copy); devices carry offers
/// (paste) and set selections. Null when the compositor lacks them.
data_manager: ?*wl.DataDeviceManager,
data_device: ?*wl.DataDevice,
primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1,
primary_device: ?*zwp.PrimarySelectionDeviceV1,
decoration_manager: ?*zxdg.DecorationManagerV1,
toplevel_decoration: ?*zxdg.ToplevelDecorationV1,
viewport: ?*wp.Viewport,
fractional_scale: ?*wp.FractionalScaleV1,
surface: *wl.Surface,
xdg_surface: *xdg.Surface,
toplevel: *xdg.Toplevel,
buffers: std.ArrayList(*Buffer),
/// Window size in logical (surface-local) coordinates.
width: u31,
height: u31,
pending_width: u31,
pending_height: u31,
/// Output scale in 1/120ths (wp_fractional_scale unit); 120 == 1.0.
/// Buffers are sized in physical pixels: logical * scale120 / 120.
scale120: u32,
running: bool,
fatal_error: ?anyerror,
/// A frame callback is outstanding; drawing now would outpace the
/// compositor. `redraw()` queues instead.
frame_pending: bool,
redraw_queued: bool,
suspended: bool,
render_ctx: ?*anyopaque,
render_fn: ?RenderFn,
resize_fn: ?ResizeFn,
keyboard_fn: ?KeyboardFn,
pointer_fn: ?PointerFn,
scale_fn: ?ScaleFn,

/// Draw delegate: fills `pixels` (width*height ARGB8888, stride == width).
/// Dimensions are physical pixels.
pub const RenderFn = *const fn (ctx: *anyopaque, pixels: []u32, width: u31, height: u31) anyerror!void;

/// Called when the window size changed, before the next draw.
/// Dimensions are physical pixels.
pub const ResizeFn = *const fn (ctx: *anyopaque, width: u31, height: u31) anyerror!void;

/// Raw wl_keyboard events, forwarded as-is.
pub const KeyboardFn = *const fn (ctx: *anyopaque, event: wl.Keyboard.Event) void;

/// Raw wl_pointer events, forwarded as-is.
pub const PointerFn = *const fn (ctx: *anyopaque, event: wl.Pointer.Event) void;

pub const CursorShape = wp.CursorShapeDeviceV1.Shape;

/// Called when the output scale changed, before the resize/draw that
/// follows. `scale120` is the scale in 1/120ths (120 == 1.0).
pub const ScaleFn = *const fn (ctx: *anyopaque, scale120: u32) anyerror!void;

/// Globals collected during the initial registry roundtrip.
const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    data_manager: ?*wl.DataDeviceManager = null,
    primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
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
    toplevel.setAppId("monstar");
    toplevel.setTitle("monstar");

    const toplevel_decoration = decoration: {
        const manager = globals.decoration_manager orelse break :decoration null;
        const decoration = manager.getToplevelDecoration(toplevel) catch |err| {
            log.warn("server-side decoration request failed: {}", .{err});
            break :decoration null;
        };
        decoration.setMode(.server_side);
        break :decoration decoration;
    };

    // Fractional scaling needs both protocols: the scale event and a
    // viewport to map the physical-pixel buffer onto the logical size.
    // Without them we render 1:1 and let the compositor scale.
    var viewport: ?*wp.Viewport = null;
    var fractional_scale: ?*wp.FractionalScaleV1 = null;
    if (globals.viewporter) |viewporter| {
        defer viewporter.destroy(); // per-surface objects outlive the manager
        if (globals.fractional_manager) |manager| {
            defer manager.destroy();
            viewport = viewporter.getViewport(surface) catch null;
            if (viewport != null) {
                fractional_scale = manager.getFractionalScale(surface) catch null;
            }
        }
    } else if (globals.fractional_manager) |manager| {
        manager.destroy();
    }

    // Clipboard devices only need the seat, not its capabilities.
    var data_device: ?*wl.DataDevice = null;
    var primary_device: ?*zwp.PrimarySelectionDeviceV1 = null;
    if (globals.seat) |seat| {
        if (globals.data_manager) |manager| {
            data_device = manager.getDataDevice(seat) catch null;
        }
        if (globals.primary_manager) |manager| {
            primary_device = manager.getDevice(seat) catch null;
        }
    }

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
        .pointer = null,
        .cursor_shape_manager = globals.cursor_shape_manager,
        .cursor_shape_device = null,
        .cursor_shape = .text,
        .pointer_enter_serial = null,
        .data_manager = globals.data_manager,
        .data_device = data_device,
        .primary_manager = globals.primary_manager,
        .primary_device = primary_device,
        .decoration_manager = globals.decoration_manager,
        .toplevel_decoration = toplevel_decoration,
        .viewport = viewport,
        .fractional_scale = fractional_scale,
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
        .scale120 = 120,
        .running = true,
        .fatal_error = null,
        .frame_pending = false,
        .redraw_queued = false,
        .suspended = false,
        .render_ctx = null,
        .render_fn = null,
        .resize_fn = null,
        .keyboard_fn = null,
        .pointer_fn = null,
        .scale_fn = null,
    };

    if (toplevel_decoration) |decoration| decoration.setListener(*Window, decorationListener, self);
    if (fractional_scale) |fs| fs.setListener(*Window, fractionalScaleListener, self);
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
    if (self.fractional_scale) |fs| fs.destroy();
    if (self.viewport) |viewport| viewport.destroy();
    if (self.cursor_shape_device) |device| device.destroy();
    if (self.cursor_shape_manager) |manager| manager.destroy();
    if (self.data_device) |device| device.release();
    if (self.data_manager) |manager| manager.destroy();
    if (self.primary_device) |device| device.destroy();
    if (self.primary_manager) |manager| manager.destroy();
    if (self.toplevel_decoration) |decoration| decoration.destroy();
    if (self.decoration_manager) |manager| manager.destroy();
    if (self.pointer) |pointer| pointer.release();
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

/// Set the delegates for drawing, resizing, input, and scale.
pub fn setCallbacks(
    self: *Window,
    ctx: *anyopaque,
    render_fn: RenderFn,
    resize_fn: ?ResizeFn,
    keyboard_fn: ?KeyboardFn,
    pointer_fn: ?PointerFn,
    scale_fn: ?ScaleFn,
) void {
    self.render_ctx = ctx;
    self.render_fn = render_fn;
    self.resize_fn = resize_fn;
    self.keyboard_fn = keyboard_fn;
    self.pointer_fn = pointer_fn;
    self.scale_fn = scale_fn;
}

pub fn setCursorShape(self: *Window, shape: CursorShape) void {
    if (self.cursor_shape == shape) return;
    self.cursor_shape = shape;
    self.applyCursorShape();
}

fn applyCursorShape(self: *Window) void {
    const serial = self.pointer_enter_serial orelse return;
    const device = self.cursor_shape_device orelse return;
    device.setShape(serial, self.cursor_shape);
}

/// Convert a logical dimension to physical pixels (rounded).
fn physical(self: *const Window, logical: u31) u31 {
    return @intCast((@as(u64, logical) * self.scale120 + 60) / 120);
}

/// Redraw as soon as the compositor is ready for a new frame: now if no
/// frame callback is outstanding, otherwise when it fires.
pub fn redraw(self: *Window) !void {
    // Not configured yet; the first configure triggers the first draw.
    if (self.width == 0) return;
    if (self.suspended) {
        self.redraw_queued = true;
        return;
    }
    if (self.frame_pending) {
        self.redraw_queued = true;
        return;
    }
    try self.draw();
}

/// Redraw the window contents and commit. The buffer is sized in
/// physical pixels; the viewport (if any) maps it to the logical size.
fn draw(self: *Window) !void {
    const phys_width = self.physical(self.width);
    const phys_height = self.physical(self.height);
    const buffer = try self.acquireBuffer(phys_width, phys_height);
    if (self.render_fn) |render_fn| {
        try render_fn(self.render_ctx.?, buffer.pixels(), phys_width, phys_height);
    } else {
        @memset(buffer.pixels(), bg_color);
    }
    if (self.viewport) |viewport| viewport.setDestination(self.width, self.height);

    // Throttle future redraws to the compositor's pace. Configure-driven
    // draws may run while a callback is already outstanding; don't stack.
    if (!self.frame_pending) {
        const frame_cb = try self.surface.frame();
        frame_cb.setListener(*Window, frameListener, self);
        self.frame_pending = true;
    }

    self.surface.attach(buffer.wl_buffer, 0, 0);
    self.surface.damageBuffer(0, 0, phys_width, phys_height);
    self.surface.commit();
    buffer.busy = true;
}

fn frameListener(frame_cb: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
    switch (event) {
        .done => {
            frame_cb.destroy();
            self.frame_pending = false;
            if (self.redraw_queued) {
                if (self.suspended) return;
                self.redraw_queued = false;
                self.draw() catch |err| {
                    log.err("draw failed: {}", .{err});
                    self.fatal_error = err;
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
                globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, 6)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                globals.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                globals.fractional_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                globals.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                globals.data_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, 3)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwp.PrimarySelectionDeviceManagerV1.interface.name) == .eq) {
                globals.primary_manager = registry.bind(global.name, zwp.PrimarySelectionDeviceManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                globals.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
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

            const has_pointer = caps.capabilities.pointer;
            if (has_pointer and self.pointer == null) {
                self.pointer = seat.getPointer() catch |err| pointer: {
                    log.err("getPointer failed: {}", .{err});
                    break :pointer null;
                };
                if (self.pointer) |pointer| {
                    pointer.setListener(*Window, pointerListener, self);
                    if (self.cursor_shape_manager) |manager| {
                        self.cursor_shape_device = manager.getPointer(pointer) catch null;
                    }
                }
            } else if (!has_pointer and self.pointer != null) {
                if (self.cursor_shape_device) |device| device.destroy();
                self.cursor_shape_device = null;
                self.pointer.?.release();
                self.pointer = null;
            }
        },
        .name => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Window) void {
    // The cursor image is undefined on enter until the client sets one.
    switch (event) {
        .enter => |enter| {
            self.pointer_enter_serial = enter.serial;
            self.applyCursorShape();
        },
        .leave => self.pointer_enter_serial = null,
        else => {},
    }
    if (self.pointer_fn) |pointer_fn| pointer_fn(self.render_ctx.?, event);
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Window) void {
    if (self.keyboard_fn) |keyboard_fn| keyboard_fn(self.render_ctx.?, event);
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn decorationListener(
    _: *zxdg.ToplevelDecorationV1,
    event: zxdg.ToplevelDecorationV1.Event,
    _: *Window,
) void {
    switch (event) {
        .configure => {},
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
            self.geometryChanged(resized);
        },
    }
}

/// Notify the resize delegate (if the grid geometry changed) and redraw.
fn geometryChanged(self: *Window, resized: bool) void {
    if (resized) {
        if (self.resize_fn) |resize_fn| {
            resize_fn(
                self.render_ctx.?,
                self.physical(self.width),
                self.physical(self.height),
            ) catch |err| {
                log.err("resize handler failed: {}", .{err});
                self.fatal_error = err;
                self.running = false;
                return;
            };
        }
    }
    if (self.suspended) {
        self.redraw_queued = true;
        return;
    }
    self.draw() catch |err| {
        log.err("draw failed: {}", .{err});
        self.fatal_error = err;
        self.running = false;
    };
}

fn fractionalScaleListener(
    _: *wp.FractionalScaleV1,
    event: wp.FractionalScaleV1.Event,
    self: *Window,
) void {
    switch (event) {
        .preferred_scale => |preferred| {
            if (preferred.scale == self.scale120) return;
            log.debug("scale changed to {d}/120", .{preferred.scale});
            self.scale120 = preferred.scale;
            if (self.scale_fn) |scale_fn| {
                scale_fn(self.render_ctx.?, self.scale120) catch |err| {
                    log.err("scale handler failed: {}", .{err});
                    self.fatal_error = err;
                    self.running = false;
                    return;
                };
            }
            // Before the first configure there is nothing to redraw yet.
            if (self.width > 0) self.geometryChanged(true);
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            // Zero means "client decides"; keep the current size then.
            if (configure.width > 0) self.pending_width = @intCast(configure.width);
            if (configure.height > 0) self.pending_height = @intCast(configure.height);
            self.suspended = toplevelState(configure.states, .suspended);
        },
        .close => self.running = false,
        .configure_bounds, .wm_capabilities => {},
    }
}

fn toplevelState(states: anytype, needle: xdg.Toplevel.State) bool {
    const raw_needle: u32 = @intCast(@intFromEnum(needle));
    for (states.slice(u32)) |state| {
        if (state == raw_needle) return true;
    }
    return false;
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

        const fd = try posix.memfd_create("monstar-shm", linux.MFD.CLOEXEC);
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
