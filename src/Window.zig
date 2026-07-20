//! Wayland window: display connection, global binding, an xdg_toplevel
//! surface, and wl_shm buffer management for CPU rendering.

const Window = @This();

const std = @import("std");
const ShmBuffer = @import("ShmBuffer.zig");
const wayland = @import("wayland");
const ext = wayland.client.ext;
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
registry_state: *Globals,
compositor: *wl.Compositor,
shm: *wl.Shm,
wm_base: *xdg.WmBase,
activation: ?*xdg.ActivationV1,
activation_token: ?*xdg.ActivationTokenV1,
activation_token_purpose: ?ActivationTokenPurpose,
system_bell: ?*xdg.SystemBellV1,
toplevel_icon_manager: ?*xdg.ToplevelIconManagerV1,
background_effect_manager: ?*ext.BackgroundEffectManagerV1,
background_effect: ?*ext.BackgroundEffectSurfaceV1,
seat: ?*wl.Seat,
keyboard: ?*wl.Keyboard,
pointer: ?*wl.Pointer,
cursor_shape_manager: ?*wp.CursorShapeManagerV1,
cursor_shape_device: ?*wp.CursorShapeDeviceV1,
cursor_theme: ?*wl.CursorTheme,
cursor_surface: ?*wl.Surface,
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
/// Format new render buffers use. Old-format buffers may remain in the list
/// while the compositor owns them; acquireBuffer retires them after release.
buffer_format: BufferFormat,
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
/// Core wl_surface v6 preference, when available. Fractional-scale-v1 takes
/// priority; wl_output.scale remains the fallback before this event arrives.
surface_preferred_scale: ?u32,
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
resizing: bool,
render_ctx: ?*anyopaque,
resize_fn: ?ResizeFn,
keyboard_fn: ?KeyboardFn,
pointer_fn: ?PointerFn,
text_input_fn: ?TextInputFn,
scale_fn: ?ScaleFn,
redraw_ready_fn: ?RedrawReadyFn,
activation_token_fn: ?ActivationTokenFn,
clipboard_devices_fn: ?ClipboardDevicesFn,

/// A changed rectangle in physical buffer coordinates.
pub const DamageRect = struct {
    x: u31,
    y: u31,
    width: u31,
    height: u31,
};

/// The buffer region a render changed relative to the previous frame.
pub const Damage = union(enum) {
    full,
    /// A non-empty slice of changed rectangles.
    /// The slice is borrowed for the duration of `commitRender`.
    rects: []const DamageRect,
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

/// Clipboard devices change when a seat is removed or re-announced.
pub const ClipboardDevicesFn = *const fn (
    ctx: *anyopaque,
    data_device: ?*wl.DataDevice,
    primary_device: ?*zwp.PrimarySelectionDeviceV1,
) void;

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
    activate_other,
};

const BufferFormat = ShmBuffer.Format;

/// A wl_shm backed pixel buffer. `busy` prevents mutable reuse while the
/// compositor owns it, but the mapping remains readable; wl_buffer.release
/// clears the flag. `rendering` reserves it for one checked-out RenderTarget.
/// `frame` records its latest commitRender attempt for age bookkeeping; 0
/// means no attempt has been recorded. A failed commit attempt or a later
/// canceled render can leave that record unrelated to displayed contents.
pub const Buffer = ShmBuffer;

/// Called when the output scale changed, before the resize/draw that
/// follows. `scale120` is the scale in 1/120ths (120 == 1.0).
pub const ScaleFn = *const fn (ctx: *anyopaque, scale120: u32) anyerror!void;

/// Called when configure work requires a new frame (first configure,
/// resize, scale change, resume). The application owns all render
/// scheduling; Window never draws or commits on its own initiative.
pub const RedrawReadyFn = *const fn (ctx: *anyopaque) void;

const OutputState = struct {
    global_name: u32,
    proxy: *wl.Output,
    scale: u32 = 1,
    entered: bool = false,
    registry_state: *Globals,

    fn destroy(self: *OutputState) void {
        if (self.proxy.getVersion() >= wl.Output.release_since_version)
            self.proxy.release()
        else
            self.proxy.destroy();
        self.registry_state.alloc.destroy(self);
    }
};

/// Persistent registry callback state. Registry listeners cannot be removed,
/// so this must outlive the stack frame that performs the initial roundtrip.
const Globals = struct {
    alloc: std.mem.Allocator,
    window: ?*Window = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    activation: ?*xdg.ActivationV1 = null,
    system_bell: ?*xdg.SystemBellV1 = null,
    toplevel_icon_manager: ?*xdg.ToplevelIconManagerV1 = null,
    background_effect_manager: ?*ext.BackgroundEffectManagerV1 = null,
    seat: ?*wl.Seat = null,
    seat_name: ?u32 = null,
    viewporter: ?*wp.Viewporter = null,
    fractional_manager: ?*wp.FractionalScaleManagerV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    data_manager: ?*wl.DataDeviceManager = null,
    primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1 = null,
    text_input_manager: ?*zwp.TextInputManagerV3 = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    outputs: std.ArrayList(*OutputState) = .empty,

    fn deinit(self: *Globals) void {
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn removeOutput(self: *Globals, global_name: u32) void {
        for (self.outputs.items, 0..) |output, i| {
            if (output.global_name != global_name) continue;
            const entered = output.entered;
            output.destroy();
            _ = self.outputs.swapRemove(i);
            if (entered) {
                if (self.window) |window| window.updateIntegerScale();
            }
            return;
        }
    }
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
    errdefer registry.destroy();
    const globals = try alloc.create(Globals);
    globals.* = .{ .alloc = alloc };
    errdefer globals.deinit();
    registry.setListener(*Globals, registryListener, globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = globals.compositor orelse return error.NoWlCompositor;
    const shm = globals.shm orelse return error.NoWlShm;
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;

    const surface = try compositor.createSurface();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    const toplevel = try xdg_surface.getToplevel();
    toplevel.setAppId(app_id);
    toplevel.setTitle(title);

    const background_effect: ?*ext.BackgroundEffectSurfaceV1 = effect: {
        const manager = globals.background_effect_manager orelse break :effect null;
        break :effect manager.getBackgroundEffect(surface) catch |err| {
            log.warn("background effect setup failed: {}", .{err});
            break :effect null;
        };
    };

    if (globals.toplevel_icon_manager) |manager| {
        if (manager.createIcon()) |icon| {
            icon.setName("dev.rockorager.monstar");
            manager.setIcon(toplevel, icon);
            icon.destroy();
        } else |_| {}
    }

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
    // Core wl_output integer scaling is installed below as the fallback.
    var viewport: ?*wp.Viewport = null;
    var fractional_scale: ?*wp.FractionalScaleV1 = null;
    if (globals.viewporter) |viewporter| {
        defer viewporter.destroy(); // per-surface objects outlive the manager
        if (globals.fractional_manager) |manager| {
            defer manager.destroy();
            viewport = viewporter.getViewport(surface) catch null;
            if (viewport != null) {
                fractional_scale = manager.getFractionalScale(surface) catch null;
                if (fractional_scale == null) {
                    viewport.?.destroy();
                    viewport = null;
                }
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

    var cursor_theme: ?*wl.CursorTheme = null;
    var cursor_surface: ?*wl.Surface = null;
    if (globals.cursor_shape_manager == null) {
        cursor_theme = wl.CursorTheme.load(null, 24, shm) catch null;
        if (cursor_theme != null) {
            cursor_surface = compositor.createSurface() catch null;
            if (cursor_surface == null) {
                cursor_theme.?.destroy();
                cursor_theme = null;
            }
        }
    }
    errdefer if (cursor_surface) |value| value.destroy();
    errdefer if (cursor_theme) |value| value.destroy();

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .display = display,
        .registry = registry,
        .registry_state = globals,
        .compositor = compositor,
        .shm = shm,
        .wm_base = wm_base,
        .activation = globals.activation,
        .activation_token = null,
        .activation_token_purpose = null,
        .system_bell = globals.system_bell,
        .toplevel_icon_manager = globals.toplevel_icon_manager,
        .background_effect_manager = globals.background_effect_manager,
        .background_effect = background_effect,
        .seat = globals.seat,
        .keyboard = null,
        .pointer = null,
        .cursor_shape_manager = globals.cursor_shape_manager,
        .cursor_shape_device = null,
        .cursor_theme = cursor_theme,
        .cursor_surface = cursor_surface,
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
        .buffer_format = .xrgb8888,
        .newest_buffer = null,
        // Zero until the first configure so the resize callback always
        // fires before the first draw.
        .width = 0,
        .height = 0,
        .pending_width = initial_size.width,
        .pending_height = initial_size.height,
        .scale120 = 120,
        .surface_preferred_scale = null,
        .pending_scale_changed = false,
        .pending_geometry_changed = false,
        .pending_draw = false,
        .running = true,
        .fatal_error = null,
        .frame_pending = false,
        .rendering_pending = false,
        .frame_counter = 0,
        .suspended = false,
        .resizing = false,
        .render_ctx = null,
        .resize_fn = null,
        .keyboard_fn = null,
        .pointer_fn = null,
        .text_input_fn = null,
        .scale_fn = null,
        .redraw_ready_fn = null,
        .activation_token_fn = null,
        .clipboard_devices_fn = null,
    };
    globals.window = self;

    if (toplevel_decoration) |decoration| decoration.setListener(*Window, decorationListener, self);
    if (fractional_scale) |fs| fs.setListener(*Window, fractionalScaleListener, self);
    if (text_input) |ti| ti.setListener(*Window, textInputListener, self);
    if (globals.seat) |seat| seat.setListener(*Window, seatListener, self);
    wm_base.setListener(*Window, wmBaseListener, self);
    surface.setListener(*Window, surfaceListener, self);
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
    self.registry_state.window = null;
    for (self.buffers.items) |buffer| buffer.destroy(self.alloc);
    self.buffers.deinit(self.alloc);
    if (self.fractional_scale) |fs| fs.destroy();
    if (self.viewport) |viewport| viewport.destroy();
    if (self.cursor_shape_device) |device| device.destroy();
    if (self.pointer) |pointer| destroyPointer(pointer);
    if (self.keyboard) |keyboard| destroyKeyboard(keyboard);
    if (self.data_device) |device| destroyDataDevice(device);
    if (self.seat) |seat| destroySeat(seat);
    if (self.cursor_surface) |surface| surface.destroy();
    if (self.cursor_theme) |theme| theme.destroy();
    if (self.cursor_shape_manager) |manager| manager.destroy();
    if (self.data_manager) |manager| {
        if (manager.getVersion() >= wl.DataDeviceManager.release_since_version)
            manager.release()
        else
            manager.destroy();
    }
    if (self.primary_device) |device| device.destroy();
    if (self.primary_manager) |manager| manager.destroy();
    if (self.text_input) |text_input| text_input.destroy();
    if (self.text_input_manager) |manager| manager.destroy();
    if (self.toplevel_decoration) |decoration| decoration.destroy();
    if (self.decoration_manager) |manager| manager.destroy();
    if (self.activation_token) |token| token.destroy();
    if (self.activation) |activation| activation.destroy();
    if (self.system_bell) |bell| bell.destroy();
    if (self.toplevel_icon_manager) |manager| manager.destroy();
    if (self.background_effect) |effect| effect.destroy();
    self.toplevel.destroy();
    self.xdg_surface.destroy();
    self.surface.destroy();
    if (self.background_effect_manager) |manager| manager.destroy();
    self.wm_base.destroy();
    if (self.shm.getVersion() >= wl.Shm.release_since_version)
        self.shm.release()
    else
        self.shm.destroy();
    if (self.compositor.getVersion() >= wl.Compositor.release_since_version)
        self.compositor.release()
    else
        self.compositor.destroy();
    self.registry.destroy();
    self.registry_state.deinit();
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
    clipboard_devices_fn: ?ClipboardDevicesFn,
) void {
    self.render_ctx = ctx;
    self.resize_fn = resize_fn;
    self.keyboard_fn = keyboard_fn;
    self.pointer_fn = pointer_fn;
    self.text_input_fn = text_input_fn;
    self.scale_fn = scale_fn;
    self.redraw_ready_fn = redraw_ready_fn;
    self.activation_token_fn = activation_token_fn;
    self.clipboard_devices_fn = clipboard_devices_fn;
    self.notifyClipboardDevices();
}

pub fn setCursorShape(self: *Window, shape: CursorShape) void {
    if (self.cursor_shape == shape) return;
    self.cursor_shape = shape;
    self.applyCursorShape();
}

/// Select whether future render buffers carry alpha. Existing busy buffers
/// cannot be destroyed until wl_buffer.release, so they are retired lazily.
/// After startup, callers must invalidate any in-flight or held frame.
pub fn setBufferAlpha(self: *Window, enabled: bool) void {
    const format: BufferFormat = if (enabled) .argb8888 else .xrgb8888;
    if (format == self.buffer_format) return;
    self.buffer_format = format;
    if (self.newest_buffer) |newest| {
        if (newest.format != format) self.newest_buffer = null;
    }
}

/// Request compositor blur for the whole surface. The effect state is
/// double-buffered and takes effect with the application's next surface commit.
pub fn setBackgroundBlur(self: *Window, enabled: bool) void {
    const effect = self.background_effect orelse return;
    if (!enabled) {
        effect.setBlurRegion(null);
        return;
    }

    const region = self.compositor.createRegion() catch |err| {
        log.warn("background blur region creation failed: {}", .{err});
        return;
    };
    defer region.destroy();
    region.add(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    effect.setBlurRegion(region);
}

pub fn ringBell(self: *Window) void {
    const bell = self.system_bell orelse return;
    bell.ring(self.surface);
}

pub fn pointerHasFrames(self: *const Window) bool {
    const pointer = self.pointer orelse return true;
    return pointer.getVersion() >= wl.Pointer.Event.frame_since_version;
}

/// Request a token for transferring the activation caused by an input event
/// to another client. When the protocol and a seat are available, cancels any
/// outstanding request before starting another. Completion is delivered
/// asynchronously to ActivationTokenFn when installed. Returns false when the
/// compositor lacks the protocol or there is no seat.
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

/// Ask the compositor to activate this surface; does nothing when the
/// activation protocol is unavailable.
pub fn activate(self: *Window, token: [:0]const u8) void {
    const activation = self.activation orelse return;
    activation.activate(token, self.surface);
}

/// Enable compositor text input for terminal content and commit `rect` as
/// the cursor rectangle. Does nothing when text-input-v3 is unavailable.
pub fn enableTextInput(self: *Window, rect: TextInputRect) void {
    const text_input = self.text_input orelse return;
    text_input.enable();
    text_input.setContentType(.{}, .terminal);
    text_input.setCursorRectangle(rect.x, rect.y, rect.width, rect.height);
    text_input.commit();
    self.text_input_enabled = true;
    self.text_input_rect = rect;
}

/// Disable and commit compositor text input when currently enabled.
pub fn disableTextInput(self: *Window) void {
    const text_input = self.text_input orelse return;
    if (!self.text_input_enabled) return;
    text_input.disable();
    text_input.commit();
    self.text_input_enabled = false;
    self.text_input_rect = null;
}

/// Commit a changed cursor rectangle while compositor text input is enabled.
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
    if (self.cursor_shape_device) |device| {
        device.setShape(serial, self.cursor_shape);
        return;
    }

    const pointer = self.pointer orelse return;
    const theme = self.cursor_theme orelse return;
    const surface = self.cursor_surface orelse return;
    const cursor = theme.getCursor(cursorName(self.cursor_shape)) orelse
        theme.getCursor("default") orelse
        theme.getCursor("left_ptr") orelse return;
    if (cursor.image_count == 0) return;
    const image = cursor.images[0];
    const buffer = image.getBuffer() catch return;
    surface.attach(buffer, 0, 0);
    if (surface.getVersion() >= wl.Surface.damage_buffer_since_version)
        surface.damageBuffer(0, 0, @intCast(image.width), @intCast(image.height))
    else
        surface.damage(0, 0, @intCast(image.width), @intCast(image.height));
    surface.commit();
    pointer.setCursor(serial, surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
}

fn cursorName(shape: CursorShape) [*:0]const u8 {
    return switch (shape) {
        .default => "default",
        .context_menu => "context-menu",
        .help => "help",
        .pointer => "pointer",
        .progress => "progress",
        .wait => "wait",
        .cell => "cell",
        .crosshair => "crosshair",
        .text => "text",
        .vertical_text => "vertical-text",
        .alias => "alias",
        .copy => "copy",
        .move => "move",
        .no_drop => "no-drop",
        .not_allowed => "not-allowed",
        .grab => "grab",
        .grabbing => "grabbing",
        .e_resize => "e-resize",
        .n_resize => "n-resize",
        .ne_resize => "ne-resize",
        .nw_resize => "nw-resize",
        .s_resize => "s-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .w_resize => "w-resize",
        .ew_resize => "ew-resize",
        .ns_resize => "ns-resize",
        .nesw_resize => "nesw-resize",
        .nwse_resize => "nwse-resize",
        .col_resize => "col-resize",
        .row_resize => "row-resize",
        .all_scroll => "all-scroll",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
        else => "default",
    };
}

fn updateIntegerScale(self: *Window) void {
    if (self.fractional_scale != null) return;
    var scale: u32 = self.surface_preferred_scale orelse 1;
    if (self.surface.getVersion() >= wl.Surface.set_buffer_scale_since_version) {
        if (self.surface_preferred_scale == null) {
            for (self.registry_state.outputs.items) |output| {
                if (output.entered) scale = @max(scale, output.scale);
            }
        }
        self.surface.setBufferScale(@intCast(scale));
    }
    self.setScale120(scale * 120);
}

fn setScale120(self: *Window, scale120: u32) void {
    std.debug.assert(scale120 > 0);
    if (scale120 == self.scale120) return;
    log.debug("scale changed to {d}/120", .{scale120});
    self.scale120 = scale120;
    self.pending_scale_changed = true;
    if (self.width > 0) {
        self.pending_geometry_changed = true;
        self.pending_draw = true;
    }
}

/// Convert a logical dimension to physical pixels (rounded).
fn physical(self: *const Window, logical: u31) u31 {
    return physicalDimension(logical, self.scale120);
}

pub fn physicalDimension(logical: u31, scale120: u32) u31 {
    return @intCast(@min(
        std.math.maxInt(u31),
        (@as(u64, logical) * scale120 + 60) / 120,
    ));
}

pub const RenderTarget = struct {
    /// The checked-out buffer to pass to commitRender or cancelRender.
    buffer: *Buffer,
    /// Writable storage owned by `buffer`, valid until the checkout ends.
    pixels: []u32,
    /// Read-only contents of the newest compatible committed buffer, when
    /// available. It may alias `pixels`; the borrowed storage is valid until
    /// the checkout ends.
    source_pixels: ?[]const u32,
    width: u31,
    height: u31,
    /// Buffer-age hint derived from commit-attempt bookkeeping, or 0 when no
    /// prior attempt is recorded. It does not guarantee that the current
    /// pixels appeared in a displayed frame: a commit may have failed, or a
    /// later canceled render may have changed them without updating the age.
    age: usize,
};

/// Check out a buffer for an asynchronous render. Allowed while a frame
/// callback is outstanding so raster work can overlap the frame wait;
/// refused while suspended, unconfigured (`width == 0`), or another target is
/// checked out.
/// End every successful checkout with commitRender or cancelRender using the
/// returned buffer; do not access either pixel slice afterward.
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
        if (newest.frame != 0 and newest.width == phys_width and newest.height == phys_height and
            newest.format == buffer.format)
            newest.pixels()
        else
            null
    else
        null;
    return .{ .buffer = buffer, .pixels = buffer.pixels(), .source_pixels = source_pixels, .width = phys_width, .height = phys_height, .age = age };
}

/// End the checkout for `buffer`. This does not restore pixels changed by the
/// renderer or clear the buffer's prior frame-age bookkeeping.
pub fn cancelRender(self: *Window, buffer: *Buffer) void {
    buffer.rendering = false;
    self.rendering_pending = false;
}

/// End the checkout for `buffer` and attempt to commit it to the surface. The
/// caller must cancel instead if the window geometry changed since acquisition
/// or the Window's current buffer format no longer matches `buffer.format`.
/// The checkout and frame-age bookkeeping are consumed even when this function
/// returns an error before the surface commit.
pub fn commitRender(self: *Window, buffer: *Buffer, damage: Damage) !void {
    std.debug.assert(buffer.rendering);
    std.debug.assert(buffer.format == self.buffer_format);
    switch (damage) {
        .full => {},
        .rects => |rects| std.debug.assert(rects.len > 0),
    }
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
    if (self.surface.getVersion() >= wl.Surface.damage_buffer_since_version) {
        switch (damage) {
            .full => self.surface.damageBuffer(0, 0, phys_width, phys_height),
            .rects => |rects| for (rects) |rect| {
                self.surface.damageBuffer(rect.x, rect.y, rect.width, rect.height);
            },
        }
    } else switch (damage) {
        // Older surfaces only accept surface-local damage. Full damage is
        // conservative and avoids lossy fractional rectangle conversion.
        .full => self.surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32)),
        .rects => |rects| if (rects.len > 0)
            self.surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32)),
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

/// Return a free shm buffer of the requested size, reshaping a released slot
/// when possible so interactive resizing does not rebuild its shm storage.
fn acquireBuffer(self: *Window, width: u31, height: u31) !*Buffer {
    var available: ?*Buffer = null;
    var matching: ?*Buffer = null;
    for (self.buffers.items) |buffer| {
        if (buffer.busy or buffer.rendering) continue;
        if (buffer.width == width and buffer.height == height and buffer.format == self.buffer_format) {
            if (matching == null or buffer.frame > matching.?.frame) matching = buffer;
            continue;
        }
        if (available == null) available = buffer;
    }
    if (matching) |buffer| return buffer;
    if (available) |buffer| {
        if (self.newest_buffer == buffer) self.newest_buffer = null;
        try buffer.reshape(width, height, self.buffer_format);
        return buffer;
    }

    const buffer = try Buffer.create(self.alloc, self.shm, width, height, self.buffer_format);
    errdefer buffer.destroy(self.alloc);
    try self.buffers.append(self.alloc, buffer);
    return buffer;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                if (globals.compositor == null)
                    globals.compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        @min(global.version, wl.Compositor.generated_version),
                    ) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                const proxy = registry.bind(
                    global.name,
                    wl.Output,
                    @min(global.version, wl.Output.generated_version),
                ) catch return;
                const output = globals.alloc.create(OutputState) catch {
                    if (proxy.getVersion() >= wl.Output.release_since_version)
                        proxy.release()
                    else
                        proxy.destroy();
                    return;
                };
                output.* = .{
                    .global_name = global.name,
                    .proxy = proxy,
                    .registry_state = globals,
                };
                globals.outputs.append(globals.alloc, output) catch {
                    output.destroy();
                    return;
                };
                proxy.setListener(*OutputState, outputListener, output);
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                if (globals.shm == null)
                    globals.shm = registry.bind(global.name, wl.Shm, @min(global.version, wl.Shm.generated_version)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                if (globals.wm_base == null)
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, xdg.WmBase.generated_version)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.ActivationV1.interface.name) == .eq) {
                if (globals.activation == null)
                    globals.activation = registry.bind(global.name, xdg.ActivationV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.SystemBellV1.interface.name) == .eq) {
                if (globals.system_bell == null)
                    globals.system_bell = registry.bind(global.name, xdg.SystemBellV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.ToplevelIconManagerV1.interface.name) == .eq) {
                if (globals.toplevel_icon_manager == null)
                    globals.toplevel_icon_manager = registry.bind(global.name, xdg.ToplevelIconManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, ext.BackgroundEffectManagerV1.interface.name) == .eq) {
                if (globals.background_effect_manager == null) {
                    const manager = registry.bind(global.name, ext.BackgroundEffectManagerV1, 1) catch return;
                    globals.background_effect_manager = manager;
                    manager.setListener(*Globals, backgroundEffectManagerListener, globals);
                }
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                if (globals.seat == null) {
                    const seat = registry.bind(global.name, wl.Seat, @min(global.version, wl.Seat.generated_version)) catch return;
                    globals.seat = seat;
                    globals.seat_name = global.name;
                    if (globals.window) |window| window.installSeat(seat);
                }
            } else if (std.mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                if (globals.viewporter == null)
                    globals.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                if (globals.fractional_manager == null)
                    globals.fractional_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                if (globals.cursor_shape_manager == null)
                    globals.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, @min(global.version, wp.CursorShapeManagerV1.generated_version)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                if (globals.data_manager == null)
                    globals.data_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, wl.DataDeviceManager.generated_version)) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwp.PrimarySelectionDeviceManagerV1.interface.name) == .eq) {
                if (globals.primary_manager == null)
                    globals.primary_manager = registry.bind(global.name, zwp.PrimarySelectionDeviceManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwp.TextInputManagerV3.interface.name) == .eq) {
                if (globals.text_input_manager == null)
                    globals.text_input_manager = registry.bind(global.name, zwp.TextInputManagerV3, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                if (globals.decoration_manager == null)
                    globals.decoration_manager = registry.bind(global.name, zxdg.DecorationManagerV1, @min(global.version, zxdg.DecorationManagerV1.generated_version)) catch return;
            }
        },
        .global_remove => |removed| {
            globals.removeOutput(removed.name);
            if (globals.seat_name == removed.name) {
                if (globals.window) |window|
                    window.removeSeat()
                else if (globals.seat) |seat|
                    destroySeat(seat);
                globals.seat = null;
                globals.seat_name = null;
            }
        },
    }
}

fn backgroundEffectManagerListener(
    _: *ext.BackgroundEffectManagerV1,
    event: ext.BackgroundEffectManagerV1.Event,
    _: *Globals,
) void {
    switch (event) {
        .capabilities => |capabilities| log.debug("background blur capability: {}", .{capabilities.flags.blur}),
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, output: *OutputState) void {
    switch (event) {
        .scale => |scale| {
            if (scale.factor <= 0) return;
            const factor: u32 = @intCast(scale.factor);
            if (factor == output.scale) return;
            output.scale = factor;
            if (output.entered) {
                if (output.registry_state.window) |window| window.updateIntegerScale();
            }
        },
        else => {},
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, self: *Window) void {
    const output_proxy = switch (event) {
        .enter => |enter| enter.output,
        .leave => |leave| leave.output,
        .preferred_buffer_scale => |preferred| {
            if (preferred.factor <= 0) return;
            self.surface_preferred_scale = @intCast(preferred.factor);
            self.updateIntegerScale();
            return;
        },
        // Monstar renders in the compositor's normal surface orientation.
        // Ignoring this optimization hint is always protocol-correct.
        .preferred_buffer_transform => return,
    } orelse return;
    const entered = event == .enter;
    for (self.registry_state.outputs.items) |output| {
        if (output.proxy.getId() != output_proxy.getId()) continue;
        if (output.entered == entered) return;
        output.entered = entered;
        self.updateIntegerScale();
        return;
    }
}

fn installSeat(self: *Window, seat: *wl.Seat) void {
    std.debug.assert(self.seat == null);
    self.seat = seat;
    seat.setListener(*Window, seatListener, self);
    if (self.data_manager) |manager| {
        self.data_device = manager.getDataDevice(seat) catch null;
    }
    if (self.primary_manager) |manager| {
        self.primary_device = manager.getDevice(seat) catch null;
    }
    if (self.text_input_manager) |manager| {
        self.text_input = manager.getTextInput(seat) catch null;
        if (self.text_input) |text_input| {
            text_input.setListener(*Window, textInputListener, self);
        }
    }
    self.notifyClipboardDevices();
}

fn removeSeat(self: *Window) void {
    if (self.cursor_shape_device) |device| device.destroy();
    self.cursor_shape_device = null;
    if (self.pointer) |pointer| destroyPointer(pointer);
    self.pointer = null;
    self.pointer_enter_serial = null;
    if (self.keyboard) |keyboard| destroyKeyboard(keyboard);
    self.keyboard = null;
    if (self.data_device) |device| destroyDataDevice(device);
    self.data_device = null;
    if (self.primary_device) |device| device.destroy();
    self.primary_device = null;
    self.notifyClipboardDevices();
    if (self.text_input) |text_input| text_input.destroy();
    self.text_input = null;
    self.text_input_enabled = false;
    self.text_input_rect = null;
    if (self.seat) |seat| destroySeat(seat);
    self.seat = null;
}

fn notifyClipboardDevices(self: *Window) void {
    const callback = self.clipboard_devices_fn orelse return;
    callback(self.render_ctx.?, self.data_device, self.primary_device);
}

fn destroySeat(seat: *wl.Seat) void {
    if (seat.getVersion() >= wl.Seat.release_since_version)
        seat.release()
    else
        seat.destroy();
}

fn destroyPointer(pointer: *wl.Pointer) void {
    if (pointer.getVersion() >= wl.Pointer.release_since_version)
        pointer.release()
    else
        pointer.destroy();
}

fn destroyKeyboard(keyboard: *wl.Keyboard) void {
    if (keyboard.getVersion() >= wl.Keyboard.release_since_version)
        keyboard.release()
    else
        keyboard.destroy();
}

fn destroyDataDevice(device: *wl.DataDevice) void {
    if (device.getVersion() >= wl.DataDevice.release_since_version)
        device.release()
    else
        device.destroy();
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
                destroyKeyboard(self.keyboard.?);
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
                destroyPointer(self.pointer.?);
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
        self.commitResizedViewport();
    }
    self.scheduleDraw();
}

/// Apply an acked configure immediately by scaling the attached buffer to the
/// new logical size. The full-resolution replacement can then rasterize in the
/// background without making an interactive compositor wait for its commit.
fn commitResizedViewport(self: *Window) void {
    const viewport = self.viewport orelse return;
    if (!self.resizing or self.frame_counter == 0 or self.suspended) return;
    std.debug.assert(self.width > 0 and self.height > 0);

    viewport.setDestination(self.width, self.height);
    if (self.surface.getVersion() >= wl.Surface.damage_buffer_since_version)
        self.surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32))
    else
        self.surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    self.surface.commit();
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
        .preferred_scale => |preferred| self.setScale120(preferred.scale),
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            // Zero means "client decides"; keep the current size then.
            if (configure.width > 0) self.pending_width = @intCast(configure.width);
            if (configure.height > 0) self.pending_height = @intCast(configure.height);
            self.suspended = toplevelState(configure.states, .suspended);
            self.resizing = toplevelState(configure.states, .resizing);
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
