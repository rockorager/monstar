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

pub const CanvasCell = struct {
    codepoint: u32 = ' ',
    fg_rgba: u32 = 0xFFFFFFFF,
    bg_rgba: u32 = 0x000000FF,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

allocator: std.mem.Allocator,
display: *server.wl.Server,
loop: *server.wl.EventLoop,
socket_path: [:0]const u8,

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

// Object mappings
surfaces: std.ArrayList(*Surface) = .empty,
surface_map: std.AutoHashMapUnmanaged(*server.wl.Surface, *Surface) = .empty,
grid_map: std.AutoHashMapUnmanaged(*server.zterm.GridSurfaceV1, *Surface) = .empty,
buffer_map: std.AutoHashMapUnmanaged(*server.wl.Buffer, Buffer) = .empty,
keyboard_clients: std.ArrayList(*server.zterm.KeyboardV1) = .empty,

// Active Theme State
theme_name: [:0]const u8 = "Monstar Dark",
theme_is_dark: u32 = 1,
theme_bg_rgba: u32 = 0x181825FF,
theme_fg_rgba: u32 = 0xCDD6F4FF,
theme_cursor_rgba: u32 = 0xF5E0DCFF,
theme_palette: [16]u32 = [_]u32{
    0x45475AFF, 0xF38BA8FF, 0xA6E3A1FF, 0xF9E2AFFF,
    0x89B4FAFF, 0xF5C2E7FF, 0x94E2D5FF, 0xBAC2DEFF,
    0x585B70FF, 0xF38BA8FF, 0xA6E3A1FF, 0xF9E2AFFF,
    0x89B4FAFF, 0xF5C2E7FF, 0x94E2D5FF, 0xA6ADC8FF,
},

dirty: bool = true,

pub fn init(
    allocator: std.mem.Allocator,
    socket_name: ?[*:0]const u8,
    screen_cols: u32,
    screen_rows: u32,
) !*Compositor {
    const display = try server.wl.Server.create();
    errdefer display.destroy();

    const loop = display.getEventLoop();

    var socket_owned: [:0]const u8 = undefined;
    if (socket_name) |name| {
        try display.addSocket(name);
        socket_owned = try allocator.dupeZ(u8, std.mem.sliceTo(name, 0));
    } else {
        var buf: [11]u8 = undefined;
        const auto_name = try display.addSocketAuto(&buf);
        socket_owned = try allocator.dupeZ(u8, auto_name);
    }
    errdefer allocator.free(socket_owned);

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
    };

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

    return self;
}

pub fn deinit(self: *Compositor) void {
    for (self.surfaces.items) |surf| {
        surf.deinit();
    }
    self.surfaces.deinit(self.allocator);

    var buf_iter = self.buffer_map.valueIterator();
    while (buf_iter.next()) |buf| {
        buf.deinit();
    }
    self.buffer_map.deinit(self.allocator);
    self.surface_map.deinit(self.allocator);
    self.grid_map.deinit(self.allocator);
    self.keyboard_clients.deinit(self.allocator);

    self.global_compositor.destroy();
    self.global_zterm_compositor.destroy();
    self.global_buffer_factory.destroy();
    self.global_keyboard.destroy();
    self.global_theme_manager.destroy();

    self.allocator.free(self.canvas);
    self.allocator.free(self.socket_path);
    self.display.destroy();
    self.allocator.destroy(self);
}

pub fn dispatch(self: *Compositor, timeout_ms: c_int) !void {
    try self.loop.dispatch(timeout_ms);
    self.display.flushClients();
}

pub fn stop(self: *Compositor) void {
    self.display.terminate();
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
            self.surfaces.append(self.allocator, surf) catch return;
            self.surface_map.put(self.allocator, surf_res, surf) catch return;
            surf_res.setHandler(*Compositor, handleSurfaceRequest, handleSurfaceDestroy, self);
        },
        .create_region => {},
        .release => {},
    }
}

fn handleSurfaceRequest(res: *server.wl.Surface, req: server.wl.Surface.Request, self: *Compositor) void {
    const surf = self.surface_map.get(res) orelse return;
    switch (req) {
        .destroy => {},
        .attach => |args| {
            if (args.buffer) |buf_res| {
                if (self.buffer_map.get(buf_res)) |buf| {
                    const copy = Buffer.init(self.allocator, buf.cols, buf.rows, buf.format, buf.data) catch return;
                    surf.attach(copy);
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
    }
}

fn handleGridSurfaceDestroy(res: *server.zterm.GridSurfaceV1, self: *Compositor) void {
    _ = self.grid_map.remove(res);
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
            const raw_slice = args.data.slice(u8);
            const fmt: Buffer.Format = switch (args.format) {
                .compact_v1 => .compact_v1,
                .rich_v1 => .rich_v1,
                else => return,
            };
            const buf = Buffer.init(self.allocator, args.cols, args.rows, fmt, raw_slice) catch return;
            self.buffer_map.put(self.allocator, buf_res, buf) catch return;
            buf_res.setHandler(*Compositor, handleBufferRequest, handleBufferDestroy, self);
        },
        .create_shm_cell_buffer => {},
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

// -----------------------------------------------------------------------------
// 2D Compositing Pass
// -----------------------------------------------------------------------------

pub fn composite(self: *Compositor) void {
    // Clear canvas
    for (self.canvas) |*c| {
        c.* = .{
            .codepoint = ' ',
            .fg_rgba = self.theme_fg_rgba,
            .bg_rgba = self.theme_bg_rgba,
        };
    }

    // Blit surfaces in z-order
    for (self.surfaces.items) |surf| {
        const buf = surf.current_buffer orelse continue;

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

                        const bg = if (src_cell.flags.bg_is_palette and src_cell.bg_color < 16)
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
