//! Client library / helper for TC-Wayland applications.
//! Connects to TC-Wayland server, binds zterm globals, creates cell buffers,
//! attaches them to grid surfaces, and handles structured input.

const Client = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zterm = wayland.client.zterm;
const zwlr = wayland.client.zwlr;

const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const RichCell = abi.RichCell;
const Buffer = @import("Buffer.zig");

pub const KeyEvent = struct {
    key_name: []const u8,
    utf8_text: []const u8,
    modifiers: zterm.KeyboardV1.ModifierMask,
    state: zterm.KeyboardV1.KeyState,
};

pub const ConfigureEvent = struct {
    cols: u32,
    rows: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    serial: u32,
};

pub const ThemeEvent = struct {
    name: []const u8,
    is_dark: bool,
    bg_rgba: u32,
    fg_rgba: u32,
    cursor_rgba: u32,
};

allocator: std.mem.Allocator,
display: *wl.Display,
registry: *wl.Registry,

// Bound globals
compositor: ?*wl.Compositor = null,
zterm_compositor: ?*zterm.CompositorV1 = null,
keyboard: ?*zterm.KeyboardV1 = null,
theme_manager: ?*zterm.ThemeManagerV1 = null,
layer_shell: ?*zwlr.LayerShellV1 = null,
shm: ?*wl.Shm = null,

// Client surfaces
surface: ?*wl.Surface = null,
grid_surface: ?*zterm.GridSurfaceV1 = null,

// Received events
last_configure: ?ConfigureEvent = null,
last_theme: ?ThemeEvent = null,
received_keys: std.ArrayList(KeyEvent) = .empty,

pub fn connectFd(allocator: std.mem.Allocator, fd: std.posix.fd_t) !*Client {
    const display = try wl.Display.connectToFd(fd);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    errdefer registry.destroy();

    const self = try allocator.create(Client);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .display = display,
        .registry = registry,
    };

    registry.setListener(*Client, registryListener, self);
    if (display.roundtrip() != .SUCCESS) {
        return error.RoundtripFailed;
    }

    if (self.keyboard) |kb| {
        kb.setListener(*Client, keyboardListener, self);
    }
    if (self.theme_manager) |tm| {
        tm.setListener(*Client, themeListener, self);
        tm.getTheme();
        if (display.roundtrip() != .SUCCESS) {
            return error.RoundtripFailed;
        }
    }

    return self;
}

pub fn connect(allocator: std.mem.Allocator, socket_name: ?[*:0]const u8) !*Client {
    const display = try wl.Display.connect(socket_name);
    errdefer display.disconnect();

    const registry = try display.getRegistry();
    errdefer registry.destroy();

    const self = try allocator.create(Client);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .display = display,
        .registry = registry,
    };

    registry.setListener(*Client, registryListener, self);
    if (display.roundtrip() != .SUCCESS) {
        return error.RoundtripFailed;
    }

    if (self.keyboard) |kb| {
        kb.setListener(*Client, keyboardListener, self);
    }
    if (self.theme_manager) |tm| {
        tm.setListener(*Client, themeListener, self);
        tm.getTheme();
        if (display.roundtrip() != .SUCCESS) {
            return error.RoundtripFailed;
        }
    }

    return self;
}

pub fn deinit(self: *Client) void {
    for (self.received_keys.items) |k| {
        self.allocator.free(k.key_name);
        self.allocator.free(k.utf8_text);
    }
    self.received_keys.deinit(self.allocator);

    if (self.last_theme) |t| {
        self.allocator.free(t.name);
    }

    if (self.grid_surface) |gs| gs.destroy();
    if (self.surface) |s| s.destroy();
    if (self.layer_shell) |ls| ls.destroy();
    if (self.theme_manager) |tm| tm.destroy();
    if (self.keyboard) |kb| kb.release();
    if (self.zterm_compositor) |zc| zc.destroy();
    if (self.shm) |s| s.destroy();
    if (self.compositor) |c| c.destroy();

    self.registry.destroy();
    self.display.disconnect();
    self.allocator.destroy(self);
}

pub fn roundtrip(self: *Client) !void {
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

pub fn getFd(self: *Client) std.posix.fd_t {
    return self.display.getFd();
}

pub fn dispatch(self: *Client) !void {
    _ = self.display.flush();
    if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
}

pub fn dispatchPending(self: *Client) void {
    _ = self.display.flush();
    _ = self.display.dispatchPending();
}

pub fn createGridSurface(self: *Client) !*zterm.GridSurfaceV1 {
    const comp = self.compositor orelse return error.NoCompositor;
    const zcomp = self.zterm_compositor orelse return error.NoZtermCompositor;

    const surf = try comp.createSurface();
    errdefer surf.destroy();

    const grid = try zcomp.getGridSurface(surf);
    grid.setListener(*Client, gridSurfaceListener, self);

    self.surface = surf;
    self.grid_surface = grid;
    return grid;
}

pub fn createBuffer(
    self: *Client,
    cols: u32,
    rows: u32,
    format: Buffer.Format,
    bytes: []const u8,
) !*wl.Buffer {
    const shm = self.shm orelse return error.NoShm;
    const stride: i32 = switch (format) {
        .compact_v1 => @intCast(cols * @sizeOf(CompactCell)),
        .rich_v1 => @intCast(cols * @sizeOf(RichCell)),
        .argb8888, .xrgb8888 => @intCast(cols * 4),
    };
    const fd = try std.posix.memfd_create("tc-shm-buffer", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    if (std.os.linux.ftruncate(fd, @intCast(bytes.len)) != 0) return error.ShmFailed;
    _ = std.c.write(fd, bytes.ptr, bytes.len);

    const pool = try shm.createPool(fd, @intCast(bytes.len));
    defer pool.destroy();
    _ = std.os.linux.close(fd);

    const shm_fmt: wl.Shm.Format = @enumFromInt(format.toShmFormat());
    return try pool.createBuffer(0, @intCast(cols), @intCast(rows), stride, shm_fmt);
}

pub fn createCellBuffer(
    self: *Client,
    cols: u32,
    rows: u32,
    format: Buffer.Format,
    cell_bytes: []const u8,
) !*wl.Buffer {
    return self.createBuffer(cols, rows, format, cell_bytes);
}

pub fn createPixelBuffer(
    self: *Client,
    width: u32,
    height: u32,
    format: Buffer.Format,
    pixel_bytes: []const u8,
) !*wl.Buffer {
    std.debug.assert(format.isPixel());
    return self.createBuffer(width, height, format, pixel_bytes);
}

pub fn createShmBuffer(
    self: *Client,
    fd: std.posix.fd_t,
    size: usize,
    width: i32,
    height: i32,
    stride: i32,
    format: wl.Shm.Format,
) !*wl.Buffer {
    const shm = self.shm orelse return error.NoShm;
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    return try pool.createBuffer(0, width, height, stride, format);
}

pub fn createShmPixelBuffer(
    self: *Client,
    fd: std.posix.fd_t,
    size: usize,
    width: i32,
    height: i32,
    stride: i32,
    format: wl.Shm.Format,
) !*wl.Buffer {
    return self.createShmBuffer(fd, size, width, height, stride, format);
}

pub fn commitBuffer(self: *Client, buffer: *wl.Buffer, cols: u32, rows: u32) !void {
    const surf = self.surface orelse return error.NoSurface;
    surf.attach(buffer, 0, 0);
    surf.damage(0, 0, @as(i32, @intCast(cols)), @as(i32, @intCast(rows)));
    surf.commit();
}

// -----------------------------------------------------------------------------
// Wayland Listeners
// -----------------------------------------------------------------------------

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
    switch (event) {
        .global => |g| {
            if (std.mem.orderZ(u8, g.interface, wl.Compositor.interface.name) == .eq) {
                self.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.orderZ(u8, g.interface, zterm.CompositorV1.interface.name) == .eq) {
                self.zterm_compositor = registry.bind(g.name, zterm.CompositorV1, 1) catch return;
            } else if (std.mem.orderZ(u8, g.interface, zterm.KeyboardV1.interface.name) == .eq) {
                self.keyboard = registry.bind(g.name, zterm.KeyboardV1, 1) catch return;
            } else if (std.mem.orderZ(u8, g.interface, zterm.ThemeManagerV1.interface.name) == .eq) {
                self.theme_manager = registry.bind(g.name, zterm.ThemeManagerV1, 1) catch return;
            } else if (std.mem.orderZ(u8, g.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                self.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (std.mem.orderZ(u8, g.interface, wl.Shm.interface.name) == .eq) {
                self.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn gridSurfaceListener(grid: *zterm.GridSurfaceV1, event: zterm.GridSurfaceV1.Event, self: *Client) void {
    switch (event) {
        .configure => |args| {
            self.last_configure = .{
                .cols = args.cols,
                .rows = args.rows,
                .cell_width_px = args.cell_width_px,
                .cell_height_px = args.cell_height_px,
                .serial = args.serial,
            };
            grid.ackConfigure(args.serial);
        },
        .cursor_position => {},
        .close => {},
    }
}

fn keyboardListener(kb: *zterm.KeyboardV1, event: zterm.KeyboardV1.Event, self: *Client) void {
    _ = kb;
    switch (event) {
        .key => |args| {
            const key_name = self.allocator.dupe(u8, std.mem.sliceTo(args.key_name, 0)) catch return;
            const utf8_text = self.allocator.dupe(u8, std.mem.sliceTo(args.utf8_text, 0)) catch {
                self.allocator.free(key_name);
                return;
            };
            self.received_keys.append(self.allocator, .{
                .key_name = key_name,
                .utf8_text = utf8_text,
                .modifiers = args.modifiers,
                .state = args.state,
            }) catch {
                self.allocator.free(key_name);
                self.allocator.free(utf8_text);
            };
        },
    }
}

fn themeListener(tm: *zterm.ThemeManagerV1, event: zterm.ThemeManagerV1.Event, self: *Client) void {
    _ = tm;
    switch (event) {
        .theme => |args| {
            if (self.last_theme) |t| {
                self.allocator.free(t.name);
            }
            const name = self.allocator.dupe(u8, std.mem.sliceTo(args.theme_name, 0)) catch return;
            self.last_theme = .{
                .name = name,
                .is_dark = args.is_dark != 0,
                .bg_rgba = args.bg_rgba,
                .fg_rgba = args.fg_rgba,
                .cursor_rgba = args.cursor_rgba,
            };
        },
    }
}
