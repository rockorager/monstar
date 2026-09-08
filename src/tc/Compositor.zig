//! Terminal Compositor implementation for TC-Wayland.
//! Runs the Wayland display server, advertises TC-Wayland globals,
//! manages cell buffers, surfaces, z-ordering, and composites 2D grids.

const Compositor = @This();

const std = @import("std");
const wayland = @import("wayland");
const server = wayland.server;

const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const RichCell = abi.RichCell;
const Buffer = @import("Buffer.zig");
const Surface = @import("Surface.zig");
const Client = @import("Client.zig");

pub const CanvasCell = struct {
    codepoint: u32 = ' ',
    fg_rgba: u32 = 0xFFFFFFFF,
    bg_rgba: u32 = 0x000000FF,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const DragState = struct {
    surface: ?*Surface = null,
    grab_offset_x: i32 = 0,
    grab_offset_y: i32 = 0,
    dragging: bool = false,
};

allocator: std.mem.Allocator,
display: *server.wl.Server,
loop: *server.wl.EventLoop,
socket_path: ?[:0]const u8 = null,
server_thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),
mutex: std.atomic.Mutex = .unlocked,

// Screen geometry
cols: u32,
rows: u32,
cell_width_px: u32 = 9,
cell_height_px: u32 = 18,
canvas: []CanvasCell,

// Globals
global_compositor: *server.wl.Global,
global_zterm_compositor: *server.wl.Global,
global_buffer_factory: *server.wl.Global,
global_keyboard: *server.wl.Global,
global_theme_manager: *server.wl.Global,
global_xpty: *server.wl.Global,
global_layer_shell: *server.wl.Global,

// Object mappings
surfaces: std.ArrayList(*Surface) = .empty,
surface_map: std.AutoHashMapUnmanaged(*server.wl.Surface, *Surface) = .empty,
grid_map: std.AutoHashMapUnmanaged(*server.zterm.GridSurfaceV1, *Surface) = .empty,
layer_map: std.AutoHashMapUnmanaged(*server.zwlr.LayerSurfaceV1, *Surface) = .empty,
buffer_map: std.AutoHashMapUnmanaged(*server.wl.Buffer, Buffer) = .empty,
keyboard_clients: std.ArrayList(*server.zterm.KeyboardV1) = .empty,

// Active Theme State
theme_name: [:0]const u8 = "Monstar Dark",
theme_is_dark: u32 = 1,
theme_bg_rgba: u32 = 0x181825FF,
theme_fg_rgba: u32 = 0xCDD6F4FF,
theme_cursor_rgba: u32 = 0xF5E0DCFF,
theme_palette: [16]u32 = [_]u32{
    0x181825FF, 0xF38BA8FF, 0xA6E3A1FF, 0xF9E2AFFF,
    0x89B4FAFF, 0xF5C2E7FF, 0x94E2D5FF, 0xBAC2DEFF,
    0x585B70FF, 0xF38BA8FF, 0xA6E3A1FF, 0xF9E2AFFF,
    0x89B4FAFF, 0xF5C2E7FF, 0x94E2D5FF, 0xA6ADC8FF,
},

dirty: bool = true,
drag_state: DragState = .{},

pub fn lock(self: *Compositor) void {
    while (!self.mutex.tryLock()) std.Thread.yield() catch {};
}

pub fn unlock(self: *Compositor) void {
    self.mutex.unlock();
}

pub fn init(
    allocator: std.mem.Allocator,
    socket_name: ?[*:0]const u8,
    screen_cols: u32,
    screen_rows: u32,
) !*Compositor {
    const display = try server.wl.Server.create();
    errdefer display.destroy();

    const loop = display.getEventLoop();

    var socket_owned: ?[:0]const u8 = null;
    if (socket_name) |name| {
        display.addSocket(name) catch |err| {
            std.log.warn("Failed to bind Wayland socket '{s}': {s}", .{ name, @errorName(err) });
        };
        socket_owned = allocator.dupeZ(u8, std.mem.sliceTo(name, 0)) catch null;
    } else {
        // Never call addSocketAuto() as it iterates wayland-0, wayland-1 and collides
        // with desktop compositors (Sway, GNOME, Hyprland, etc.).
        // Instead, try to bind to a unique private socket name: monstar-tc-<pid>.
        var name_buf: [64]u8 = undefined;
        const pid = std.os.linux.getpid();
        const priv_name = std.fmt.bufPrintZ(&name_buf, "monstar-tc-{d}", .{pid}) catch "monstar-tc";
        if (display.addSocket(priv_name)) {
            socket_owned = allocator.dupeZ(u8, priv_name) catch null;
        } else |_| {
            // If adding filesystem socket fails, continue gracefully.
            // Direct internal clients connect via socketpair.
            socket_owned = null;
        }
    }
    errdefer if (socket_owned) |s| allocator.free(s);

    const self = try allocator.create(Compositor);
    errdefer allocator.destroy(self);

    const canvas = try allocator.alloc(CanvasCell, @as(usize, screen_cols) * screen_rows);
    errdefer allocator.free(canvas);
    for (canvas) |*c| c.* = .{};

    self.* = .{
        .allocator = allocator,
        .display = display,
        .loop = loop,
        .socket_path = socket_owned,
        .cols = screen_cols,
        .rows = screen_rows,
        .canvas = canvas,
        .global_compositor = undefined,
        .global_zterm_compositor = undefined,
        .global_buffer_factory = undefined,
        .global_keyboard = undefined,
        .global_theme_manager = undefined,
        .global_xpty = undefined,
        .global_layer_shell = undefined,
    };

    try display.initShm();
    _ = try display.addShmFormat(Buffer.Format.compact_v1.toShmFormat());
    _ = try display.addShmFormat(Buffer.Format.rich_v1.toShmFormat());

    self.global_compositor = try server.wl.Global.create(
        display,
        server.wl.Compositor,
        4,
        *Compositor,
        self,
        bindCompositor,
    );
    self.global_zterm_compositor = try server.wl.Global.create(
        display,
        server.zterm.CompositorV1,
        1,
        *Compositor,
        self,
        bindZtermCompositor,
    );
    self.global_buffer_factory = try server.wl.Global.create(
        display,
        server.zterm.BufferFactoryV1,
        1,
        *Compositor,
        self,
        bindBufferFactory,
    );
    self.global_keyboard = try server.wl.Global.create(
        display,
        server.zterm.KeyboardV1,
        1,
        *Compositor,
        self,
        bindKeyboard,
    );
    self.global_theme_manager = try server.wl.Global.create(
        display,
        server.zterm.ThemeManagerV1,
        1,
        *Compositor,
        self,
        bindThemeManager,
    );
    self.global_xpty = try server.wl.Global.create(
        display,
        server.zterm.XptyV1,
        1,
        *Compositor,
        self,
        bindXpty,
    );
    self.global_layer_shell = try server.wl.Global.create(
        display,
        server.zwlr.LayerShellV1,
        4,
        *Compositor,
        self,
        bindLayerShell,
    );

    return self;
}

pub fn deinit(self: *Compositor) void {
    self.stop();

    for (self.surfaces.items) |surf| {
        surf.deinit();
    }
    self.surfaces.deinit(self.allocator);

    var buf_iter = self.buffer_map.valueIterator();
    while (buf_iter.next()) |buf| {
        var b = buf.*;
        b.deinit();
    }
    self.buffer_map.deinit(self.allocator);
    self.surface_map.deinit(self.allocator);
    self.grid_map.deinit(self.allocator);
    self.layer_map.deinit(self.allocator);
    self.keyboard_clients.deinit(self.allocator);

    self.global_compositor.destroy();
    self.global_zterm_compositor.destroy();
    self.global_buffer_factory.destroy();
    self.global_keyboard.destroy();
    self.global_theme_manager.destroy();
    self.global_xpty.destroy();
    self.global_layer_shell.destroy();

    self.allocator.free(self.canvas);
    if (self.socket_path) |p| {
        self.allocator.free(p);
    }
    self.display.destroy();
    self.allocator.destroy(self);
}

pub fn resize(self: *Compositor, new_cols: u32, new_rows: u32) !void {
    self.lock();
    defer self.unlock();

    if (self.cols == new_cols and self.rows == new_rows) return;

    const new_canvas = try self.allocator.alloc(CanvasCell, @as(usize, new_cols) * new_rows);
    for (new_canvas) |*c| {
        c.* = .{
            .codepoint = ' ',
            .fg_rgba = self.theme_fg_rgba,
            .bg_rgba = self.theme_bg_rgba,
        };
    }
    self.allocator.free(self.canvas);
    self.canvas = new_canvas;
    self.cols = new_cols;
    self.rows = new_rows;
    self.dirty = true;
}

pub fn createClientSocket(self: *Compositor) !std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    errdefer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    const s_client = server.wl.Client.create(self.display, fds[0]) orelse {
        return error.ServerClientCreateFailed;
    };
    _ = s_client;
    return fds[1];
}

pub fn createDirectClient(self: *Compositor) !*Client {
    const client_fd = try self.createClientSocket();
    if (!self.running.load(.acquire)) {
        try self.start();
    }
    return try Client.connectFd(self.allocator, client_fd);
}

pub fn start(self: *Compositor) !void {
    if (self.running.load(.acquire)) return;
    self.running.store(true, .release);
    self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
}

fn serverLoop(self: *Compositor) void {
    self.display.run();
}

pub fn stop(self: *Compositor) void {
    if (!self.running.swap(false, .acq_rel)) return;
    self.display.terminate();
    if (self.server_thread) |t| {
        t.join();
        self.server_thread = null;
    }
}

pub fn dispatch(self: *Compositor, timeout_ms: c_int) !void {
    if (self.running.load(.acquire)) return;
    try self.loop.dispatch(timeout_ms);
    self.display.flushClients();
}

// -----------------------------------------------------------------------------
// Wayland Global Binders
// -----------------------------------------------------------------------------

fn bindCompositor(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.wl.Compositor.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleCompositorRequest, null, data);
}

fn handleCompositorRequest(res: *server.wl.Compositor, req: server.wl.Compositor.Request, self: *Compositor) void {
    switch (req) {
        .create_surface => |args| {
            const client = res.getClient();
            const surf_res = server.wl.Surface.create(client, res.getVersion(), args.id) catch return;
            const surf = Surface.init(self.allocator, surf_res) catch return;
            self.lock();
            defer self.unlock();
            self.surfaces.append(self.allocator, surf) catch return;
            self.surface_map.put(self.allocator, surf_res, surf) catch return;
            surf_res.setHandler(*Compositor, handleSurfaceRequest, handleSurfaceDestroy, self);
        },
        .create_region => {},
        .release => {},
    }
}

fn handleSurfaceRequest(res: *server.wl.Surface, req: server.wl.Surface.Request, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    const surf = self.surface_map.get(res) orelse return;
    switch (req) {
        .destroy => {},
        .attach => |args| {
            if (args.buffer) |buf_res| {
                if (self.buffer_map.get(buf_res)) |buf| {
                    const copy = buf.clone(self.allocator) catch return;
                    surf.attach(copy);
                    buf_res.sendRelease();
                } else if (server.wl.shm.Buffer.get(@ptrCast(buf_res))) |shm_buf| {
                    const width: u32 = @intCast(@max(0, shm_buf.getWidth()));
                    const height: u32 = @intCast(@max(0, shm_buf.getHeight()));
                    const stride: u32 = @intCast(@max(0, shm_buf.getStride()));
                    const format = Buffer.Format.fromShmFormat(shm_buf.getFormat()) orelse .compact_v1;
                    shm_buf.beginAccess();
                    defer shm_buf.endAccess();
                    if (shm_buf.getData()) |raw_ptr| {
                        const total_bytes = Buffer.expectedByteSize(format, width, height, stride);
                        const slice: []const u8 = @as([*]const u8, @ptrCast(raw_ptr))[0..total_bytes];
                        const buf = Buffer.initWithStride(self.allocator, width, height, stride, format, slice) catch return;
                        surf.attach(buf);
                    }
                    buf_res.sendRelease();
                }
            } else {
                surf.attach(null);
            }
        },
        .damage => {},
        .damage_buffer => {},
        .commit => {
            if (surf.commit()) {
                self.dirty = true;
            }
        },
        else => {},
    }
}

fn handleSurfaceDestroy(res: *server.wl.Surface, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    if (self.surface_map.fetchRemove(res)) |kv| {
        const surf = kv.value;
        for (self.surfaces.items, 0..) |s, i| {
            if (s == surf) {
                _ = self.surfaces.orderedRemove(i);
                break;
            }
        }
        surf.deinit();
        self.dirty = true;
    }
}

fn bindZtermCompositor(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zterm.CompositorV1.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleZtermCompositorRequest, null, data);
}

fn handleZtermCompositorRequest(res: *server.zterm.CompositorV1, req: server.zterm.CompositorV1.Request, self: *Compositor) void {
    const client = res.getClient();
    switch (req) {
        .destroy => {},
        .get_grid_surface => |args| {
            const surf = self.surface_map.get(args.surface) orelse return;
            surf.role = .grid;
            const grid_res = server.zterm.GridSurfaceV1.create(client, res.getVersion(), args.id) catch return;
            surf.grid_resource = grid_res;
            self.grid_map.put(self.allocator, grid_res, surf) catch return;
            grid_res.setHandler(*Compositor, handleGridSurfaceRequest, handleGridSurfaceDestroy, self);

            // Emit initial configure event
            grid_res.sendConfigure(self.cols, self.rows, self.cell_width_px, self.cell_height_px, 1);
        },
        .get_stream_surface => |args| {
            const surf = self.surface_map.get(args.surface) orelse return;
            surf.role = .stream;
            _ = server.zterm.StreamSurfaceV1.create(client, res.getVersion(), args.id) catch return;
        },
        .get_cursor_anchor => |args| {
            const overlay_surf = self.surface_map.get(args.surface) orelse return;
            const target_surf = self.surface_map.get(args.target_surface) orelse return;
            overlay_surf.anchor = .{ .target = target_surf };
            _ = server.zterm.CursorAnchorV1.create(client, res.getVersion(), args.id) catch return;
        },
    }
}

fn handleGridSurfaceRequest(res: *server.zterm.GridSurfaceV1, req: server.zterm.GridSurfaceV1.Request, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    const surf = self.grid_map.get(res) orelse return;
    switch (req) {
        .destroy => {},
        .set_title => |args| {
            const title_slice = std.mem.sliceTo(args.title, 0);
            surf.setTitle(title_slice) catch return;
        },
        .set_scrollback_max_lines => {},
        .clear_scrollback => {},
        .ack_configure => {},
        .set_position => |args| {
            surf.x = args.x;
            surf.y = args.y;
            self.dirty = true;
        },
    }
}

fn handleGridSurfaceDestroy(res: *server.zterm.GridSurfaceV1, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    _ = self.grid_map.remove(res);
}

fn bindLayerShell(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zwlr.LayerShellV1.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleLayerShellRequest, null, data);
}

fn handleLayerShellRequest(res: *server.zwlr.LayerShellV1, req: server.zwlr.LayerShellV1.Request, self: *Compositor) void {
    const client = res.getClient();
    switch (req) {
        .destroy => {},
        .get_layer_surface => |args| {
            self.lock();
            defer self.unlock();
            const surf = self.surface_map.get(args.surface) orelse return;
            surf.role = .layer;
            surf.layer = args.layer;
            surf.z_index = switch (args.layer) {
                .background => -10,
                .bottom => -1,
                .top => 10,
                .overlay => 100,
                _ => 100,
            };
            const layer_res = server.zwlr.LayerSurfaceV1.create(client, res.getVersion(), args.id) catch return;
            surf.layer_resource = layer_res;
            self.layer_map.put(self.allocator, layer_res, surf) catch return;
            layer_res.setHandler(*Compositor, handleLayerSurfaceRequest, handleLayerSurfaceDestroy, self);

            layer_res.sendConfigure(1, 0, 0);
        },
    }
}

fn handleLayerSurfaceRequest(res: *server.zwlr.LayerSurfaceV1, req: server.zwlr.LayerSurfaceV1.Request, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    const surf = self.layer_map.get(res) orelse return;
    switch (req) {
        .destroy => {},
        .set_size => {},
        .set_anchor => {},
        .set_exclusive_zone => {},
        .set_margin => |args| {
            surf.pixel_x = args.left;
            surf.pixel_y = args.top;
            surf.x = @divFloor(args.left, @as(i32, @intCast(self.cell_width_px)));
            surf.y = @divFloor(args.top, @as(i32, @intCast(self.cell_height_px)));
            self.dirty = true;
        },
        .set_keyboard_interactivity => |args| {
            surf.exclusive_keyboard = (args.keyboard_interactivity == .exclusive);
        },
        .get_popup => {},
        .ack_configure => {},
        .set_layer => |args| {
            surf.layer = args.layer;
            surf.z_index = switch (args.layer) {
                .background => -10,
                .bottom => -1,
                .top => 10,
                .overlay => 100,
                _ => 100,
            };
        },
    }
}

fn handleLayerSurfaceDestroy(res: *server.zwlr.LayerSurfaceV1, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    _ = self.layer_map.remove(res);
}

fn bindBufferFactory(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zterm.BufferFactoryV1.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleBufferFactoryRequest, null, data);
}

fn handleBufferFactoryRequest(res: *server.zterm.BufferFactoryV1, req: server.zterm.BufferFactoryV1.Request, self: *Compositor) void {
    const client = res.getClient();
    switch (req) {
        .destroy => {},
        .create_cell_buffer => |args| {
            const buf_res = server.wl.Buffer.create(client, 1, args.id) catch return;
            const fmt: Buffer.Format = switch (args.format) {
                .compact_v1 => .compact_v1,
                .rich_v1 => .rich_v1,
                _ => return,
            };
            const buf = Buffer.initEmpty(self.allocator, args.cols, args.rows, fmt) catch return;
            self.lock();
            defer self.unlock();
            self.buffer_map.put(self.allocator, buf_res, buf) catch return;
            buf_res.setHandler(*Compositor, handleBufferRequest, handleBufferDestroy, self);
        },
        .upload_cells => |args| {
            self.lock();
            defer self.unlock();
            if (self.buffer_map.getPtr(args.buffer)) |buf| {
                const raw_slice = args.data.slice(u8);
                buf.writeChunk(args.offset, raw_slice) catch return;
            }
        },
    }
}

fn handleBufferRequest(res: *server.wl.Buffer, req: server.wl.Buffer.Request, self: *Compositor) void {
    _ = res;
    _ = self;
    switch (req) {
        .destroy => {},
    }
}

fn handleBufferDestroy(res: *server.wl.Buffer, self: *Compositor) void {
    self.lock();
    defer self.unlock();
    if (self.buffer_map.fetchRemove(res)) |kv| {
        var b = kv.value;
        b.deinit();
    }
}

fn bindKeyboard(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zterm.KeyboardV1.create(client, version, id) catch return;
    data.keyboard_clients.append(data.allocator, res) catch return;
    res.setHandler(*Compositor, handleKeyboardRequest, handleKeyboardDestroy, data);
}

fn handleKeyboardRequest(res: *server.zterm.KeyboardV1, req: server.zterm.KeyboardV1.Request, self: *Compositor) void {
    _ = res;
    _ = self;
    switch (req) {
        .release => {},
    }
}

fn handleKeyboardDestroy(res: *server.zterm.KeyboardV1, self: *Compositor) void {
    for (self.keyboard_clients.items, 0..) |kb, i| {
        if (kb == res) {
            _ = self.keyboard_clients.orderedRemove(i);
            break;
        }
    }
}

fn bindThemeManager(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zterm.ThemeManagerV1.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleThemeRequest, null, data);
    data.sendTheme(res);
}

fn handleThemeRequest(res: *server.zterm.ThemeManagerV1, req: server.zterm.ThemeManagerV1.Request, self: *Compositor) void {
    switch (req) {
        .destroy => {},
        .get_theme => self.sendTheme(res),
    }
}

fn sendTheme(self: *Compositor, res: *server.zterm.ThemeManagerV1) void {
    var arr: server.wl.Array = .{
        .size = @sizeOf(@TypeOf(self.theme_palette)),
        .alloc = @sizeOf(@TypeOf(self.theme_palette)),
        .data = @ptrCast(&self.theme_palette),
    };
    res.sendTheme(
        self.theme_name.ptr,
        self.theme_is_dark,
        self.theme_bg_rgba,
        self.theme_fg_rgba,
        self.theme_cursor_rgba,
        &arr,
    );
}

fn bindXpty(client: *server.wl.Client, data: *Compositor, version: u32, id: u32) void {
    const res = server.zterm.XptyV1.create(client, version, id) catch return;
    res.setHandler(*Compositor, handleXptyRequest, null, data);
}

fn handleXptyRequest(res: *server.zterm.XptyV1, req: server.zterm.XptyV1.Request, self: *Compositor) void {
    _ = res;
    _ = self;
    switch (req) {
        .destroy => {},
        .attach_pty => |args| {
            _ = std.os.linux.close(args.pty_slave_fd);
        },
    }
}

pub fn sendKey(
    self: *Compositor,
    key_name: [:0]const u8,
    utf8_text: [:0]const u8,
    modifiers: server.zterm.KeyboardV1.ModifierMask,
    state: server.zterm.KeyboardV1.KeyState,
) void {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const time: u32 = @truncate(@as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000);
    for (self.keyboard_clients.items) |kb| {
        kb.sendKey(1, time, key_name.ptr, utf8_text.ptr, modifiers, state);
    }
    self.display.flushClients();
}

/// Handles pointer click/release events in pixels.
/// If clicking the header or border of a floating surface, begins interactive click+drag.
pub fn pointerButton(self: *Compositor, px: i32, py: i32, pressed: bool) bool {
    self.lock();
    defer self.unlock();
    if (!pressed) {
        if (self.drag_state.dragging) {
            self.drag_state.dragging = false;
            self.drag_state.surface = null;
            return true;
        }
        return false;
    }

    // Search surfaces in reverse z-order (topmost first)
    var i = self.surfaces.items.len;
    while (i > 0) {
        i -= 1;
        // Never drag the root background terminal surface (index 0)
        if (i == 0) continue;

        const surf = self.surfaces.items[i];
        if (!surf.visible) continue;
        const buf = surf.current_buffer orelse continue;

        const left_px = surf.pixel_x orelse (surf.x * @as(i32, @intCast(self.cell_width_px)));
        const top_px = surf.pixel_y orelse (surf.y * @as(i32, @intCast(self.cell_height_px)));
        const w_px = @as(i32, @intCast(buf.cols * self.cell_width_px));
        const h_px = @as(i32, @intCast(buf.rows * self.cell_height_px));
        const right_px = left_px + w_px;
        const bottom_px = top_px + h_px;

        // Check if click lands on surface title bar (top rows) or border
        if (px >= left_px and px < right_px and py >= top_px and py < bottom_px) {
            const header_h = @as(i32, @intCast(2 * self.cell_height_px));
            const border_w = @as(i32, @intCast(self.cell_width_px));
            if (py <= top_px + header_h or px <= left_px + border_w or px >= right_px - border_w) {
                self.drag_state = .{
                    .surface = surf,
                    .grab_offset_x = px - left_px,
                    .grab_offset_y = py - top_px,
                    .dragging = true,
                };
                return true;
            }
            break;
        }
    }
    return false;
}

/// Handles pointer motion in pixels. If currently dragging a surface, repositions it live.
pub fn pointerMotion(self: *Compositor, px: i32, py: i32) bool {
    self.lock();
    defer self.unlock();
    if (!self.drag_state.dragging) return false;
    const surf = self.drag_state.surface orelse return false;

    var new_px = px - self.drag_state.grab_offset_x;
    var new_py = py - self.drag_state.grab_offset_y;

    const surf_w = if (surf.current_buffer) |b| @as(i32, @intCast(b.cols * self.cell_width_px)) else 100;
    const surf_h = if (surf.current_buffer) |b| @as(i32, @intCast(b.rows * self.cell_height_px)) else 50;
    const screen_w = @as(i32, @intCast(self.cols * self.cell_width_px));
    const screen_h = @as(i32, @intCast(self.rows * self.cell_height_px));
    const max_x = @max(0, screen_w - surf_w);
    const max_y = @max(0, screen_h - surf_h);
    new_px = std.math.clamp(new_px, 0, max_x);
    new_py = std.math.clamp(new_py, 0, max_y);

    if (surf.role == .layer or surf.pixel_x != null) {
        if (surf.pixel_x != new_px or surf.pixel_y != new_py) {
            surf.pixel_x = new_px;
            surf.pixel_y = new_py;
            surf.x = @divFloor(new_px, @as(i32, @intCast(self.cell_width_px)));
            surf.y = @divFloor(new_py, @as(i32, @intCast(self.cell_height_px)));
            self.dirty = true;
            return true;
        }
    } else {
        const new_col = @divFloor(new_px, @as(i32, @intCast(self.cell_width_px)));
        const new_row = @divFloor(new_py, @as(i32, @intCast(self.cell_height_px)));
        if (surf.x != new_col or surf.y != new_row) {
            surf.x = new_col;
            surf.y = new_row;
            self.dirty = true;
            return true;
        }
    }
    return false;
}

// -----------------------------------------------------------------------------
// 2D Compositing Pass
// -----------------------------------------------------------------------------

pub fn composite(self: *Compositor) void {
    self.lock();
    defer self.unlock();

    // Clear canvas
    for (self.canvas) |*c| {
        c.* = .{
            .codepoint = ' ',
            .fg_rgba = self.theme_fg_rgba,
            .bg_rgba = self.theme_bg_rgba,
        };
    }

    // Blit surfaces in z-order: pass 0 for normal surfaces (z_index <= 0), pass 1 for overlay/popup surfaces (z_index > 0)
    var pass: u32 = 0;
    while (pass < 2) : (pass += 1) {
        for (self.surfaces.items) |surf| {
            if (!surf.visible) continue;
            if (surf.pixel_x != null) continue;
            if (pass == 0 and surf.z_index > 0) continue;
            if (pass == 1 and surf.z_index <= 0) continue;
            const buf = surf.current_buffer orelse continue;
            if (buf.isPixel()) continue;

            var origin_x = surf.x;
            var origin_y = surf.y;

            if (surf.anchor) |anc| {
                origin_x = anc.target.x + anc.target.cursor.col + anc.col_offset;
                origin_y = anc.target.y + anc.target.cursor.row + anc.row_offset;
            }

            switch (buf.format) {
                .compact_v1 => {
                    const cells = buf.asCompactSlice();
                    var r: u32 = 0;
                    while (r < buf.rows) : (r += 1) {
                        const target_y = origin_y + @as(i32, @intCast(r));
                        if (target_y < 0 or target_y >= self.rows) continue;

                        var c: u32 = 0;
                        while (c < buf.cols) : (c += 1) {
                            const target_x = origin_x + @as(i32, @intCast(c));
                            if (target_x < 0 or target_x >= self.cols) continue;

                            const src_cell = cells[r * buf.cols + c];
                            const dst_idx = @as(usize, @intCast(target_y)) * self.cols + @as(usize, @intCast(target_x));

                            const fg = if (src_cell.flags.fg_is_palette and src_cell.fg_color < 16)
                                self.theme_palette[src_cell.fg_color]
                            else
                                self.theme_fg_rgba;

                            const bg = if (src_cell.flags.bg_is_palette and src_cell.bg_color > 0 and src_cell.bg_color < 16)
                                self.theme_palette[src_cell.bg_color]
                            else
                                self.theme_bg_rgba;

                            self.canvas[dst_idx] = .{
                                .codepoint = if (src_cell.codepoint == 0) ' ' else src_cell.codepoint,
                                .fg_rgba = fg,
                                .bg_rgba = bg,
                                .bold = src_cell.flags.bold,
                                .italic = src_cell.flags.italic,
                                .underline = src_cell.flags.underline,
                            };
                        }
                    }
                },
                .rich_v1 => {
                    const cells = buf.asRichSlice();
                    var r: u32 = 0;
                    while (r < buf.rows) : (r += 1) {
                        const target_y = origin_y + @as(i32, @intCast(r));
                        if (target_y < 0 or target_y >= self.rows) continue;

                        var c: u32 = 0;
                        while (c < buf.cols) : (c += 1) {
                            const target_x = origin_x + @as(i32, @intCast(c));
                            if (target_x < 0 or target_x >= self.cols) continue;

                            const src_cell = cells[r * buf.cols + c];
                            const dst_idx = @as(usize, @intCast(target_y)) * self.cols + @as(usize, @intCast(target_x));

                            self.canvas[dst_idx] = .{
                                .codepoint = if (src_cell.codepoint == 0) ' ' else src_cell.codepoint,
                                .fg_rgba = src_cell.fg_rgba,
                                .bg_rgba = src_cell.bg_rgba,
                            };
                        }
                    }
                },
                .argb8888, .xrgb8888 => {},
            }
        }
    }
    self.dirty = false;
}

pub fn renderToString(self: *Compositor, alloc: std.mem.Allocator) ![]u8 {
    self.composite();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var r: usize = 0;
    while (r < self.rows) : (r += 1) {
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            const cell = self.canvas[r * self.cols + c];
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@truncate(cell.codepoint), &utf8_buf) catch blk: {
                utf8_buf[0] = '?';
                break :blk 1;
            };
            try out.appendSlice(alloc, utf8_buf[0..len]);
        }
        if (r + 1 < self.rows) try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

pub fn renderToAnsi(self: *Compositor, writer: anytype) !void {
    self.composite();
    var r: usize = 0;
    while (r < self.rows) : (r += 1) {
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            const cell = self.canvas[r * self.cols + c];
            const fg_r: u8 = @truncate(cell.fg_rgba >> 24);
            const fg_g: u8 = @truncate(cell.fg_rgba >> 16);
            const fg_b: u8 = @truncate(cell.fg_rgba >> 8);
            const bg_r: u8 = @truncate(cell.bg_rgba >> 24);
            const bg_g: u8 = @truncate(cell.bg_rgba >> 16);
            const bg_b: u8 = @truncate(cell.bg_rgba >> 8);

            try writer.print("\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m", .{ fg_r, fg_g, fg_b, bg_r, bg_g, bg_b });
            if (cell.bold) try writer.writeAll("\x1b[1m");
            if (cell.underline) try writer.writeAll("\x1b[4m");

            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@truncate(cell.codepoint), &utf8_buf) catch blk: {
                utf8_buf[0] = '?';
                break :blk 1;
            };
            try writer.writeAll(utf8_buf[0..len]);
            try writer.writeAll("\x1b[0m");
        }
        try writer.writeAll("\n");
    }
}
