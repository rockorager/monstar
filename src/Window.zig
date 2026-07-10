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

alloc: std.mem.Allocator,
display: *wl.Display,
registry: *wl.Registry,
compositor: *wl.Compositor,
shm: *wl.Shm,
wm_base: *xdg.WmBase,
activation: ?*xdg.ActivationV1,
activation_token: ?*xdg.ActivationTokenV1,
activation_token_purpose: ?ActivationTokenPurpose,
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
text_input_manager: ?*zwp.TextInputManagerV3,
text_input: ?*zwp.TextInputV3,
text_input_enabled: bool,
text_input_rect: ?TextInputRect,
decoration_manager: ?*zxdg.DecorationManagerV1,
toplevel_decoration: ?*zxdg.ToplevelDecorationV1,
viewport: ?*wp.Viewport,
fractional_scale: ?*wp.FractionalScaleV1,
surface: *wl.Surface,
xdg_surface: *xdg.Surface,
toplevel: *xdg.Toplevel,
buffers: std.ArrayList(*Buffer),
/// Most recently committed buffer. Its memory may still be busy with the
/// compositor, but wl_shm memory remains readable and can seed stale buffers.
newest_buffer: ?*Buffer,
/// Window size in logical (surface-local) coordinates.
width: u31,
height: u31,
pending_width: u31,
pending_height: u31,
/// Output scale in 1/120ths (wp_fractional_scale unit); 120 == 1.0.
/// Buffers are sized in physical pixels: logical * scale120 / 120.
scale120: u32,
/// Wayland callbacks update pending state; expensive/app-visible work is
/// flushed once after the current dispatch batch.
pending_scale_changed: bool,
pending_geometry_changed: bool,
pending_draw: bool,
running: bool,
fatal_error: ?anyerror,
/// A frame callback is outstanding; committing now would outpace the
/// compositor. The application's scheduler decides what to do instead.
frame_pending: bool,
/// A render target is checked out (a raster job in flight, or a
/// finished frame held for the next callback).
rendering_pending: bool,
/// Monotonic count of frames drawn, for buffer-age tracking. Each
/// buffer remembers the frame it last held; the difference tells the
/// renderer how stale a reused buffer is.
frame_counter: u64,
suspended: bool,
render_ctx: ?*anyopaque,
resize_fn: ?ResizeFn,
keyboard_fn: ?KeyboardFn,
pointer_fn: ?PointerFn,
text_input_fn: ?TextInputFn,
scale_fn: ?ScaleFn,
redraw_ready_fn: ?RedrawReadyFn,
activation_token_fn: ?ActivationTokenFn,

/// A full-width horizontal band of pixels, in buffer coordinates.
pub const RowSpan = struct { y: u31, height: u31 };

/// The buffer region a render changed relative to the previous frame.
pub const Damage = union(enum) {
    full,
    /// Changed full-width bands; an empty slice means nothing changed.
    /// The slice must remain valid until the next render callback.
    spans: []const RowSpan,
};

/// Called when the window size changed, before the next draw.
/// Dimensions are physical pixels.
pub const ResizeFn = *const fn (ctx: *anyopaque, width: u31, height: u31) anyerror!void;

/// Raw wl_keyboard events, forwarded as-is.
pub const KeyboardFn = *const fn (ctx: *anyopaque, event: wl.Keyboard.Event) void;

/// Raw wl_pointer events, forwarded as-is.
pub const PointerFn = *const fn (ctx: *anyopaque, event: wl.Pointer.Event) void;

/// A token requested from the compositor for activating another client.
/// The string is only valid for the duration of the callback.
pub const ActivationTokenFn = *const fn (ctx: *anyopaque, token: [:0]const u8) void;

/// Raw text-input-v3 events, forwarded as-is. String pointers are only
/// valid for the duration of the callback.
pub const TextInputFn = *const fn (ctx: *anyopaque, event: zwp.TextInputV3.Event) void;

pub const CursorShape = wp.CursorShapeDeviceV1.Shape;

pub const TextInputRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const InitialSize = struct {
    width: u31 = default_width,
    height: u31 = default_height,
};

const ActivationTokenPurpose = enum {
    activate_self,
    activate_other,
};

/// Called when the output scale changed, before the resize/draw that
/// follows. `scale120` is the scale in 1/120ths (120 == 1.0).
pub const ScaleFn = *const fn (ctx: *anyopaque, scale120: u32) anyerror!void;

/// Called when configure work requires a new frame (first configure,
/// resize, scale change, resume). The application owns all render
/// scheduling; Window never draws or commits on its own initiative.
pub const RedrawReadyFn = *const fn (ctx: *anyopaque) void;

/// Globals collected during the initial registry roundtrip.
const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    activation: ?*xdg.ActivationV1 = null,
    seat: ?*wl.Seat = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    data_manager: ?*wl.DataDeviceManager = null,
    primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1 = null,
    text_input_manager: ?*zwp.TextInputManagerV3 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
};

/// Heap-allocated because Wayland listeners hold a pointer to the Window.
pub fn create(
    alloc: std.mem.Allocator,
    app_id: [:0]const u8,
    title: [:0]const u8,
    initial_size: InitialSize,
) !*Window {
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
    toplevel.setAppId(app_id);
    toplevel.setTitle(title);

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
    var text_input: ?*zwp.TextInputV3 = null;
    if (globals.seat) |seat| {
        if (globals.data_manager) |manager| {
            data_device = manager.getDataDevice(seat) catch null;
        }
        if (globals.primary_manager) |manager| {
            primary_device = manager.getDevice(seat) catch null;
        }
        if (globals.text_input_manager) |manager| {
            text_input = manager.getTextInput(seat) catch |err| text_input: {
                log.warn("text-input-v3 setup failed: {}", .{err});
                break :text_input null;
            };
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
        .activation = globals.activation,
        .activation_token = null,
        .activation_token_purpose = null,
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
        .text_input_manager = globals.text_input_manager,
        .text_input = text_input,
        .text_input_enabled = false,
        .text_input_rect = null,
        .decoration_manager = globals.decoration_manager,
        .toplevel_decoration = toplevel_decoration,
        .viewport = viewport,
        .fractional_scale = fractional_scale,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .buffers = .empty,
        .newest_buffer = null,
        // Zero until the first configure so the resize callback always
        // fires before the first draw.
        .width = 0,
        .height = 0,
        .pending_width = initial_size.width,
        .pending_height = initial_size.height,
        .scale120 = 120,
        .pending_scale_changed = false,
        .pending_geometry_changed = false,
        .pending_draw = false,
        .running = true,
        .fatal_error = null,
        .frame_pending = false,
        .rendering_pending = false,
        .frame_counter = 0,
        .suspended = false,
        .render_ctx = null,
        .resize_fn = null,
        .keyboard_fn = null,
        .pointer_fn = null,
        .text_input_fn = null,
        .scale_fn = null,
        .redraw_ready_fn = null,
        .activation_token_fn = null,
    };

    if (toplevel_decoration) |decoration| decoration.setListener(*Window, decorationListener, self);
    if (fractional_scale) |fs| fs.setListener(*Window, fractionalScaleListener, self);
    if (text_input) |ti| ti.setListener(*Window, textInputListener, self);
    if (globals.seat) |seat| seat.setListener(*Window, seatListener, self);
    wm_base.setListener(*Window, wmBaseListener, self);
    xdg_surface.setListener(*Window, xdgSurfaceListener, self);
    toplevel.setListener(*Window, toplevelListener, self);
    surface.commit();
    // Send the initial commit now so the compositor can prepare configure
    // while the App finishes initialization. A full socket is harmless: the
    // main poll loop will flush it when writable.
    switch (display.flush()) {
        .SUCCESS, .AGAIN => {},
        else => |err| log.warn("initial Wayland flush failed: {}", .{err}),
    }

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
    if (self.text_input) |text_input| text_input.destroy();
    if (self.text_input_manager) |manager| manager.destroy();
    if (self.toplevel_decoration) |decoration| decoration.destroy();
    if (self.decoration_manager) |manager| manager.destroy();
    if (self.activation_token) |token| token.destroy();
    if (self.activation) |activation| activation.destroy();
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
    self.flushPending();
    return self.running;
}

/// Apply coalesced state from the most recent Wayland dispatch batch. Scale,
/// configure, and redraw events can arrive as a related group; doing the
/// expensive side effects here avoids resizing/drawing intermediate states.
pub fn flushPending(self: *Window) void {
    if (!self.running) return;

    if (self.pending_scale_changed) {
        self.pending_scale_changed = false;
        if (self.scale_fn) |scale_fn| {
            scale_fn(self.render_ctx.?, self.scale120) catch |err| {
                log.err("scale handler failed: {}", .{err});
                self.fatal_error = err;
                self.running = false;
                return;
            };
        }
    }

    if (!self.pending_draw) return;
    const resized = self.pending_geometry_changed;
    self.pending_draw = false;
    self.pending_geometry_changed = false;
    self.geometryChanged(resized);
}

/// Set the delegates for redraw scheduling, resizing, input, and scale.
pub fn setCallbacks(
    self: *Window,
    ctx: *anyopaque,
    resize_fn: ?ResizeFn,
    keyboard_fn: ?KeyboardFn,
    pointer_fn: ?PointerFn,
    text_input_fn: ?TextInputFn,
    scale_fn: ?ScaleFn,
    redraw_ready_fn: ?RedrawReadyFn,
    activation_token_fn: ?ActivationTokenFn,
) void {
    self.render_ctx = ctx;
    self.resize_fn = resize_fn;
    self.keyboard_fn = keyboard_fn;
    self.pointer_fn = pointer_fn;
    self.text_input_fn = text_input_fn;
    self.scale_fn = scale_fn;
    self.redraw_ready_fn = redraw_ready_fn;
    self.activation_token_fn = activation_token_fn;
}

pub fn setCursorShape(self: *Window, shape: CursorShape) void {
    if (self.cursor_shape == shape) return;
    self.cursor_shape = shape;
    self.applyCursorShape();
}

pub fn setUrgent(self: *Window, urgent: bool) !void {
    const activation = self.activation orelse return;

    if (!urgent) {
        if (self.activation_token_purpose == .activate_self) self.cancelActivationToken();
        return;
    }

    // A user-initiated launch takes precedence over an attention request.
    // Let its token complete rather than stranding the pending launch.
    if (self.activation_token_purpose == .activate_other) return;
    self.cancelActivationToken();

    const token = try activation.getActivationToken();
    token.setSurface(self.surface);
    token.setListener(*Window, activationTokenListener, self);
    token.commit();
    self.activation_token = token;
    self.activation_token_purpose = .activate_self;
}

/// Request a token for transferring the activation caused by an input event
/// to another client. Returns false when the compositor lacks the protocol.
pub fn requestActivationToken(self: *Window, serial: u32) !bool {
    const activation = self.activation orelse return false;
    const seat = self.seat orelse return false;

    self.cancelActivationToken();

    const token = try activation.getActivationToken();
    token.setSerial(serial, seat);
    token.setSurface(self.surface);
    token.setListener(*Window, activationTokenListener, self);
    token.commit();
    self.activation_token = token;
    self.activation_token_purpose = .activate_other;
    return true;
}

fn cancelActivationToken(self: *Window) void {
    if (self.activation_token) |token| token.destroy();
    self.activation_token = null;
    self.activation_token_purpose = null;
}

pub fn activate(self: *Window, token: [:0]const u8) void {
    const activation = self.activation orelse return;
    activation.activate(token, self.surface);
}

pub fn enableTextInput(self: *Window, rect: TextInputRect) void {
    const text_input = self.text_input orelse return;
    text_input.enable();
    text_input.setContentType(.{}, .terminal);
    text_input.setCursorRectangle(rect.x, rect.y, rect.width, rect.height);
    text_input.commit();
    self.text_input_enabled = true;
    self.text_input_rect = rect;
}

pub fn disableTextInput(self: *Window) void {
    const text_input = self.text_input orelse return;
    if (!self.text_input_enabled) return;
    text_input.disable();
    text_input.commit();
    self.text_input_enabled = false;
    self.text_input_rect = null;
}

pub fn setTextInputCursorRect(self: *Window, rect: TextInputRect) void {
    const text_input = self.text_input orelse return;
    if (!self.text_input_enabled) return;
    if (self.text_input_rect) |old| {
        if (std.meta.eql(old, rect)) return;
    }
    text_input.setCursorRectangle(rect.x, rect.y, rect.width, rect.height);
    text_input.commit();
    self.text_input_rect = rect;
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

pub const RenderTarget = struct {
    buffer: *Buffer,
    pixels: []u32,
    source_pixels: ?[]const u32,
    width: u31,
    height: u31,
    age: usize,
};

/// Check out a buffer for an asynchronous render. Allowed while a frame
/// callback is outstanding so raster work can overlap the frame wait;
/// refused only while another render target is already checked out.
pub fn acquireRenderTarget(self: *Window) !RenderTarget {
    if (self.width == 0 or self.suspended or self.rendering_pending) return error.NotReady;
    return self.beginRender(self.physical(self.width), self.physical(self.height));
}

fn beginRender(self: *Window, phys_width: u31, phys_height: u31) !RenderTarget {
    const buffer = try self.acquireBuffer(phys_width, phys_height);
    buffer.rendering = true;
    self.rendering_pending = true;
    const age: usize = if (buffer.frame == 0) 0 else @intCast(self.frame_counter + 1 - buffer.frame);
    const source_pixels: ?[]const u32 = if (self.newest_buffer) |newest|
        if (newest.frame != 0 and newest.width == phys_width and newest.height == phys_height)
            newest.pixels()
        else
            null
    else
        null;
    return .{ .buffer = buffer, .pixels = buffer.pixels(), .source_pixels = source_pixels, .width = phys_width, .height = phys_height, .age = age };
}

pub fn cancelRender(self: *Window, buffer: *Buffer) void {
    buffer.rendering = false;
    self.rendering_pending = false;
}

pub fn commitRender(self: *Window, buffer: *Buffer, damage: Damage) !void {
    std.debug.assert(buffer.rendering);
    buffer.rendering = false;
    self.rendering_pending = false;
    self.frame_counter += 1;
    buffer.frame = self.frame_counter;
    self.newest_buffer = buffer;
    const phys_width = buffer.width;
    const phys_height = buffer.height;
    if (self.viewport) |viewport| viewport.setDestination(self.width, self.height);

    // Throttle future redraws to the compositor's pace. Configure-driven
    // draws may run while a callback is already outstanding; don't stack.
    if (!self.frame_pending) {
        const frame_cb = try self.surface.frame();
        frame_cb.setListener(*Window, frameListener, self);
        self.frame_pending = true;
    }

    self.surface.attach(buffer.wl_buffer, 0, 0);
    switch (damage) {
        .full => self.surface.damageBuffer(0, 0, phys_width, phys_height),
        .spans => |spans| for (spans) |span| {
            self.surface.damageBuffer(0, span.y, phys_width, span.height);
        },
    }
    self.surface.commit();
    buffer.busy = true;
}

fn frameListener(frame_cb: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
    switch (event) {
        .done => {
            frame_cb.destroy();
            // The application's main loop observes the cleared flag after
            // dispatch and decides whether to commit a held frame or start
            // a new render; Window never draws from this callback.
            self.frame_pending = false;
        },
    }
}

/// Return a free shm buffer of the requested size, creating one if
/// needed. Frees stale buffers of other sizes as they are released.
fn acquireBuffer(self: *Window, width: u31, height: u31) !*Buffer {
    var i: usize = 0;
    while (i < self.buffers.items.len) {
        const buffer = self.buffers.items[i];
        if (buffer.busy or buffer.rendering) {
            i += 1;
            continue;
        }
        if (buffer.width == width and buffer.height == height) return buffer;
        if (self.newest_buffer == buffer) self.newest_buffer = null;
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
            } else if (std.mem.orderZ(u8, global.interface, xdg.ActivationV1.interface.name) == .eq) {
                globals.activation = registry.bind(global.name, xdg.ActivationV1, 1) catch return;
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
            } else if (std.mem.orderZ(u8, global.interface, zwp.TextInputManagerV3.interface.name) == .eq) {
                globals.text_input_manager = registry.bind(global.name, zwp.TextInputManagerV3, 1) catch return;
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

fn textInputListener(_: *zwp.TextInputV3, event: zwp.TextInputV3.Event, self: *Window) void {
    switch (event) {
        .enter => |enter| {
            if (enter.surface != self.surface) return;
        },
        .leave => |leave| {
            if (leave.surface != self.surface) return;
            self.text_input_enabled = false;
            self.text_input_rect = null;
        },
        else => {},
    }
    if (self.text_input_fn) |text_input_fn| text_input_fn(self.render_ctx.?, event);
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn activationTokenListener(
    token: *xdg.ActivationTokenV1,
    event: xdg.ActivationTokenV1.Event,
    self: *Window,
) void {
    const current_token = self.activation_token orelse return;
    if (token.getId() != current_token.getId()) {
        log.warn("received event for stale activation token", .{});
        return;
    }

    switch (event) {
        .done => |done| {
            const purpose = self.activation_token_purpose orelse return;
            token.destroy();
            self.activation_token = null;
            self.activation_token_purpose = null;

            switch (purpose) {
                .activate_self => if (self.activation) |activation| activation.activate(done.token, self.surface),
                .activate_other => if (self.activation_token_fn) |callback| callback(self.render_ctx.?, std.mem.span(done.token)),
            }
        },
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
            self.pending_geometry_changed = self.pending_geometry_changed or resized;
            self.pending_draw = true;
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
    self.scheduleDraw();
}

fn scheduleDraw(self: *Window) void {
    const redraw_ready_fn = self.redraw_ready_fn orelse return;
    redraw_ready_fn(self.render_ctx.?);
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
            self.pending_scale_changed = true;
            if (self.width > 0) {
                self.pending_geometry_changed = true;
                self.pending_draw = true;
            }
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
pub const Buffer = struct {
    wl_buffer: *wl.Buffer,
    data: []align(std.heap.page_size_min) u8,
    width: u31,
    height: u31,
    busy: bool,
    rendering: bool,
    /// Window.frame_counter value when this buffer was last drawn;
    /// 0 means never (content undefined).
    frame: u64,

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
            .rendering = false,
            .frame = 0,
        };
        wl_buffer.setListener(*Buffer, bufferListener, self);
        return self;
    }

    fn destroy(self: *Buffer, alloc: std.mem.Allocator) void {
        self.wl_buffer.destroy();
        posix.munmap(self.data);
        alloc.destroy(self);
    }

    pub fn pixels(self: *Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, self.data));
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};
