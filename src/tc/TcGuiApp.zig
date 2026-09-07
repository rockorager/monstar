//! Standalone Native Wayland GUI for the TC-Wayland Compositor Prototype.
//! Hosts the TC compositor, legacy PTY bridge (xpty), and floating overlay
//! surfaces (command palette) inside a real GPU-accelerated desktop Wayland window.

const TcGuiApp = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const vt = @import("ghostty-vt");

const Window = @import("../Window.zig");
const Font = @import("../Font.zig");
const Keyboard = @import("../Keyboard.zig");
const abi = @import("abi.zig");
const Compositor = @import("Compositor.zig");
const Client = @import("Client.zig");
const Xpty = @import("Xpty.zig");
const CommandPalette = @import("CommandPalette.zig");
const TcOverlayRenderer = @import("TcOverlayRenderer.zig");

pub const SplitDirection = enum {
    left,
    right,
};

pub const FocusedPane = enum {
    primary,
    split,
};

allocator: std.mem.Allocator,
window: *Window,
font: Font,
keyboard: Keyboard,
compositor: *Compositor,
client: *Client,
xpty: *Xpty,
palette: *CommandPalette,

cols: u32,
rows: u32,
running: bool = true,
needs_render: bool = true,

pointer_x: f64 = 0,
pointer_y: f64 = 0,
last_serial: u32 = 0,

// Split pane terminal state
split_xpty: ?*Xpty = null,
split_direction: ?SplitDirection = null,
focused_xpty: FocusedPane = .primary,

fn spawnShell(allocator: std.mem.Allocator, target: *Xpty) void {
    const shell_c = std.c.getenv("SHELL");
    const shell: []const u8 = if (shell_c) |s| std.mem.span(s) else "/bin/bash";
    const shell_z = allocator.dupeZ(u8, shell) catch {
        target.initSimulatedShell();
        return;
    };
    defer allocator.free(shell_z);

    const argv = [_:null]?[*:0]const u8{ shell_z.ptr, null };

    var env_list: std.ArrayList(?[*:0]const u8) = .empty;
    defer env_list.deinit(allocator);

    var env_idx: usize = 0;
    while (std.c.environ[env_idx]) |entry| : (env_idx += 1) {
        const val = std.mem.span(entry);
        if (std.mem.startsWith(u8, val, "TERM=")) continue;
        if (std.mem.startsWith(u8, val, "COLORTERM=")) continue;
        env_list.append(allocator, entry) catch continue;
    }
    env_list.append(allocator, "TERM=xterm-256color") catch {};
    env_list.append(allocator, "COLORTERM=truecolor") catch {};
    const envp = env_list.toOwnedSliceSentinel(allocator, null) catch {
        target.initSimulatedShell();
        return;
    };
    defer allocator.free(envp);

    target.spawnPty(shell_z.ptr, &argv, envp.ptr) catch {
        target.initSimulatedShell();
    };
}

pub fn init(allocator: std.mem.Allocator) !*TcGuiApp {
    const font_size_px = 15;
    var font = try Font.init(allocator, "monospace", font_size_px);
    errdefer font.deinit(allocator);

    const initial_w: u31 = 900;
    const initial_h: u31 = 600;

    const cols: u32 = @max(20, @as(u32, @intCast(initial_w / font.cell_width)));
    const rows: u32 = @max(10, @as(u32, @intCast(initial_h / font.cell_height)));

    const window = try Window.create(allocator, "dev.rockorager.monstar-tc-gui", "Monstar TC-Wayland GUI", .{
        .width = initial_w,
        .height = initial_h,
    });
    errdefer window.destroy();

    var keyboard = try Keyboard.init();
    errdefer keyboard.deinit();

    // 1. Initialize TC-Wayland Compositor
    var comp = try Compositor.init(allocator, null, cols, rows);
    errdefer comp.deinit();
    comp.cell_width_px = font.cell_width;
    comp.cell_height_px = font.cell_height;

    // 2. Connect client helper (anonymous socketpair)
    var cl = try comp.createDirectClient();
    errdefer cl.deinit();

    // 3. Initialize xpty terminal bridge
    var xpty_inst = try Xpty.init(allocator, cl, cols, rows);
    errdefer xpty_inst.deinit();

    spawnShell(allocator, xpty_inst);

    // 4. Initialize Command Palette overlay
    const palette_cols = @min(64, if (cols > 10) cols - 8 else cols);
    const palette_rows = @min(12, if (rows > 6) rows - 4 else rows);
    var palette_inst = try CommandPalette.init(allocator, cl, palette_cols, palette_rows);
    errdefer palette_inst.deinit();

    const pal_w_px = @as(i32, @intCast(palette_cols * font.cell_width));
    const win_w_px = @as(i32, @intCast(initial_w));
    const pal_x = if (win_w_px > pal_w_px) @divFloor(win_w_px - pal_w_px, 2) else 0;
    const pal_y = @as(i32, @intCast(2 * font.cell_height));
    palette_inst.setPosition(pal_x, pal_y);
    palette_inst.hide();

    const self = try allocator.create(TcGuiApp);
    self.* = .{
        .allocator = allocator,
        .window = window,
        .font = font,
        .keyboard = keyboard,
        .compositor = comp,
        .client = cl,
        .xpty = xpty_inst,
        .palette = palette_inst,
        .cols = cols,
        .rows = rows,
    };

    window.setCallbacks(
        self,
        onResize,
        onKeyboard,
        onPointer,
        onTextInput,
        onScale,
        onRedrawReady,
        null,
        null,
    );

    return self;
}

pub fn deinit(self: *TcGuiApp) void {
    self.compositor.stop();

    if (self.split_xpty) |split| {
        split.deinit();
        self.split_xpty = null;
    }

    self.palette.deinit();
    self.xpty.deinit();
    self.client.deinit();
    self.compositor.deinit();
    self.keyboard.deinit();
    self.font.deinit(self.allocator);
    self.window.destroy();
    self.allocator.destroy(self);
}

pub fn togglePalette(self: *TcGuiApp) void {
    if (self.palette.active) {
        self.palette.hide();
    } else {
        const pal_w_px = @as(i32, @intCast(self.palette.cols * self.font.cell_width));
        const win_w_px = @as(i32, @intCast(self.window.width));
        const pal_x = if (win_w_px > pal_w_px) @divFloor(win_w_px - pal_w_px, 2) else 0;
        const pal_y = @as(i32, @intCast(2 * self.font.cell_height));
        self.palette.setPosition(pal_x, pal_y);
        self.palette.show();
    }
    self.needs_render = true;
}

pub fn splitPane(self: *TcGuiApp, direction: SplitDirection) void {
    if (self.split_xpty != null) {
        if (self.split_direction == direction) {
            self.closeSplit();
            return;
        }
        self.closeSplit();
    }

    if (self.cols < 16) return;

    const left_cols = self.cols / 2;
    const right_cols = self.cols - left_cols;
    const rows = self.rows;

    const primary_x: i32 = if (direction == .left) @intCast(left_cols) else 0;
    const primary_cols = if (direction == .left) right_cols else left_cols;

    const split_x: i32 = if (direction == .left) 0 else @intCast(left_cols);
    const split_cols = if (direction == .left) left_cols else right_cols;

    // Resize and position primary xpty
    self.xpty.setPosition(primary_x, 0);
    self.xpty.resize(primary_cols, rows) catch return;

    // Create and position split xpty with its own shell
    var new_xpty = Xpty.init(self.allocator, self.client, split_cols, rows) catch return;
    new_xpty.setPosition(split_x, 0);
    spawnShell(self.allocator, new_xpty);

    self.split_xpty = new_xpty;
    self.split_direction = direction;
    self.focused_xpty = .split;
    _ = self.client.display.flush();
    self.needs_render = true;
}

pub fn closeSplit(self: *TcGuiApp) void {
    if (self.split_xpty) |split| {
        split.deinit();
        self.split_xpty = null;
        self.split_direction = null;
        self.focused_xpty = .primary;

        self.xpty.setPosition(0, 0);
        self.xpty.resize(self.cols, self.rows) catch {};
        _ = self.client.display.flush();
        self.needs_render = true;
    }
}

pub fn getActiveXpty(self: *TcGuiApp) *Xpty {
    if (self.split_xpty != null and self.focused_xpty == .split) {
        return self.split_xpty.?;
    }
    return self.xpty;
}

pub fn render(self: *TcGuiApp) void {
    if (self.window.width == 0 or self.window.suspended or self.window.rendering_pending or self.window.frame_pending) return;

    self.compositor.composite();

    const target = self.window.acquireRenderTarget() catch return;
    errdefer self.window.cancelRender(target.buffer);

    const stride: u31 = target.width;
    const active = self.getActiveXpty();
    var cur_x_offset: i32 = 0;
    if (self.split_xpty != null and self.split_direction != null) {
        const left_cols: i32 = @intCast(self.cols / 2);
        if (self.split_direction.? == .right) {
            if (self.focused_xpty == .split) cur_x_offset = left_cols;
        } else {
            if (self.focused_xpty == .primary) cur_x_offset = left_cols;
        }
    }
    const cursor_col: i32 = cur_x_offset + @as(i32, @intCast(active.cursor_col));
    const cursor_row: i32 = @as(i32, @intCast(active.cursor_row));

    TcOverlayRenderer.renderCanvas(
        self.allocator,
        &self.font,
        self.compositor.canvas,
        self.cols,
        self.rows,
        target.pixels,
        stride,
        target.width,
        target.height,
        if (!self.palette.active and active.cursor_visible and cursor_col >= 0 and cursor_col < self.cols and cursor_row >= 0 and cursor_row < self.rows)
            .{ .col = @intCast(cursor_col), .row = @intCast(cursor_row), .visible = true }
        else
            null,
        self.compositor.theme_cursor_rgba,
    );

    // Render floating layer surfaces or pixel buffer surfaces at exact pixel positions
    self.compositor.lock();
    for (self.compositor.surfaces.items) |surf| {
        if (surf.visible and (surf.pixel_x != null or (surf.current_buffer != null and surf.current_buffer.?.isPixel()))) {
            TcOverlayRenderer.renderSurfaceAtPixel(
                self.allocator,
                &self.font,
                surf,
                target.pixels,
                stride,
                target.width,
                target.height,
                &self.compositor.theme_palette,
                self.compositor.theme_fg_rgba,
                self.compositor.theme_bg_rgba,
            );
        }
    }
    self.compositor.unlock();

    self.window.commitRender(target.buffer, .full) catch {
        self.window.cancelRender(target.buffer);
    };
    self.needs_render = false;
}

pub fn run(self: *TcGuiApp) !void {
    const display = self.window.display;

    self.render();

    while (self.running and self.window.running) {
        var fds: [4]posix.pollfd = undefined;
        fds[0] = .{
            .fd = display.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };

        var pty_fd0: posix.fd_t = -1;
        if (self.xpty.pty) |p| {
            pty_fd0 = p.master;
            fds[1] = .{
                .fd = pty_fd0,
                .events = posix.POLL.IN,
                .revents = 0,
            };
        } else {
            fds[1] = .{
                .fd = -1,
                .events = 0,
                .revents = 0,
            };
        }

        fds[2] = .{
            .fd = self.client.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };

        var pty_fd1: posix.fd_t = -1;
        if (self.split_xpty) |split| {
            if (split.pty) |p| {
                pty_fd1 = p.master;
                fds[3] = .{
                    .fd = pty_fd1,
                    .events = posix.POLL.IN,
                    .revents = 0,
                };
            } else {
                fds[3] = .{
                    .fd = -1,
                    .events = 0,
                    .revents = 0,
                };
            }
        } else {
            fds[3] = .{
                .fd = -1,
                .events = 0,
                .revents = 0,
            };
        }

        // 1. Prepare display reads
        while (!display.prepareRead()) {
            _ = display.dispatchPending();
            self.window.flushPending();
        }
        _ = display.flush();

        while (!self.client.display.prepareRead()) {
            self.client.dispatchPending();
        }
        _ = self.client.display.flush();

        const poll_res = posix.poll(&fds, 20) catch |err| {
            display.cancelRead();
            self.client.display.cancelRead();
            if (err == error.Interrupted) continue;
            break;
        };
        _ = poll_res;

        // 2. Dispatch Wayland window events
        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = display.readEvents();
        } else {
            display.cancelRead();
        }
        _ = display.dispatchPending();
        self.window.flushPending();

        // 3. Dispatch internal TC client events
        if (fds[2].revents & posix.POLL.IN != 0) {
            _ = self.client.display.readEvents();
        } else {
            self.client.display.cancelRead();
        }
        self.client.dispatchPending();

        // 4. Drain primary PTY output
        if (pty_fd0 >= 0 and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            if (self.xpty.pollPty()) {
                self.needs_render = true;
            }
            if (fds[1].revents & posix.POLL.HUP != 0) {
                self.running = false;
                break;
            }
        }

        // Drain split PTY output
        if (pty_fd1 >= 0 and (fds[3].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            if (self.split_xpty) |split| {
                if (split.pollPty()) {
                    self.needs_render = true;
                }
            }
            if (fds[3].revents & posix.POLL.HUP != 0) {
                self.closeSplit();
                self.needs_render = true;
            }
        }

        // 5. Redraw if anything changed
        if (self.needs_render or self.compositor.dirty) {
            self.render();
        }
    }
}

// -----------------------------------------------------------------------------
// Window Callbacks
// -----------------------------------------------------------------------------

fn onResize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *TcGuiApp = @ptrCast(@alignCast(ctx));
    const new_cols: u32 = @max(10, @as(u32, @intCast(width / self.font.cell_width)));
    const new_rows: u32 = @max(4, @as(u32, @intCast(height / self.font.cell_height)));

    if (new_cols != self.cols or new_rows != self.rows) {
        self.cols = new_cols;
        self.rows = new_rows;
        try self.compositor.resize(new_cols, new_rows);

        if (self.split_xpty) |split| {
            const left_cols = new_cols / 2;
            const right_cols = new_cols - left_cols;
            const dir = self.split_direction orelse .right;
            if (dir == .right) {
                self.xpty.setPosition(0, 0);
                self.xpty.resize(left_cols, new_rows) catch {};
                split.setPosition(@intCast(left_cols), 0);
                split.resize(right_cols, new_rows) catch {};
            } else {
                split.setPosition(0, 0);
                split.resize(left_cols, new_rows) catch {};
                self.xpty.setPosition(@intCast(left_cols), 0);
                self.xpty.resize(right_cols, new_rows) catch {};
            }
        } else {
            self.xpty.setPosition(0, 0);
            try self.xpty.resize(new_cols, new_rows);
        }

        const pal_x = @as(i32, @intCast(if (new_cols > self.palette.cols) (new_cols - self.palette.cols) / 2 else 0));
        self.palette.setPosition(pal_x, 2);
    }
    self.needs_render = true;
}

fn onKeyboard(ctx: *anyopaque, event: wl.Keyboard.Event) void {
    const self: *TcGuiApp = @ptrCast(@alignCast(ctx));
    switch (event) {
        .keymap => |keymap| {
            if (keymap.format != .xkb_v1) {
                _ = std.os.linux.close(keymap.fd);
                return;
            }
            self.keyboard.setKeymap(keymap.fd, keymap.size) catch {};
        },
        .modifiers => |mods| {
            self.keyboard.updateMods(
                mods.mods_depressed,
                mods.mods_latched,
                mods.mods_locked,
                mods.group,
            );
        },
        .key => |key| {
            self.last_serial = key.serial;
            const action: vt.input.KeyAction = switch (key.state) {
                .pressed => .press,
                .released => .release,
                else => return,
            };

            var utf8_buf: [32]u8 = undefined;
            const k_event = self.keyboard.translate(&utf8_buf, key.key, action) orelse return;

            // Hotkey: Ctrl+P toggles command palette
            if (action == .press and k_event.mods.ctrl and k_event.unshifted_codepoint == 'p') {
                self.togglePalette();
                return;
            }

            // If command palette is open, route keystrokes to it
            if (self.palette.active) {
                if (action == .press) {
                    if (k_event.key == .escape) {
                        self.palette.hide();
                        self.needs_render = true;
                        return;
                    }
                    if (k_event.key == .arrow_up) {
                        _ = self.palette.handleKey("Up", "");
                        self.needs_render = true;
                        return;
                    }
                    if (k_event.key == .arrow_down) {
                        _ = self.palette.handleKey("Down", "");
                        self.needs_render = true;
                        return;
                    }
                    if (k_event.key == .enter) {
                        const act = self.palette.handleKey("Enter", "");
                        switch (act) {
                            .close => self.palette.hide(),
                            .split_left => self.splitPane(.left),
                            .split_right => self.splitPane(.right),
                            .select_file => |path| {
                                self.getActiveXpty().sendInput(path) catch {};
                            },
                            else => {},
                        }
                        self.needs_render = true;
                        return;
                    }
                    if (k_event.key == .backspace) {
                        _ = self.palette.handleKey("Backspace", "");
                        self.needs_render = true;
                        return;
                    }
                    if (k_event.utf8.len > 0 and k_event.utf8[0] >= 32 and k_event.utf8[0] < 127) {
                        _ = self.palette.handleKey("", k_event.utf8);
                        self.needs_render = true;
                        return;
                    }
                }
                return;
            }

            // Hotkey: Ctrl+W switches focus between split panes
            if (action == .press and k_event.mods.ctrl and k_event.unshifted_codepoint == 'w' and self.split_xpty != null) {
                self.focused_xpty = if (self.focused_xpty == .primary) .split else .primary;
                self.needs_render = true;
                return;
            }

            // Normal shell input routed to active pane
            if (action == .press) {
                const active = self.getActiveXpty();
                var out_buf: [128]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&out_buf);
                vt.input.encodeKey(&writer, k_event, .{}) catch {
                    if (k_event.utf8.len > 0) {
                        active.sendInput(k_event.utf8) catch {};
                        self.needs_render = true;
                    }
                    return;
                };
                const bytes = writer.buffered();
                if (bytes.len > 0) {
                    active.sendInput(bytes) catch {};
                    self.needs_render = true;
                }
            }
        },
        else => {},
    }
}

fn onPointer(ctx: *anyopaque, event: wl.Pointer.Event) void {
    const self: *TcGuiApp = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => |enter| {
            self.pointer_x = enter.surface_x.toDouble();
            self.pointer_y = enter.surface_y.toDouble();
        },
        .motion => |motion| {
            self.pointer_x = motion.surface_x.toDouble();
            self.pointer_y = motion.surface_y.toDouble();
            const px = @as(i32, @intFromFloat(self.pointer_x));
            const py = @as(i32, @intFromFloat(self.pointer_y));
            if (self.compositor.pointerMotion(px, py)) {
                self.needs_render = true;
            }
        },
        .button => |btn| {
            self.last_serial = btn.serial;
            const pressed = btn.state == .pressed;
            const px = @as(i32, @intFromFloat(self.pointer_x));
            const py = @as(i32, @intFromFloat(self.pointer_y));
            const col = @as(i32, @intFromFloat(self.pointer_x / @as(f64, @floatFromInt(self.font.cell_width))));
            if (pressed and self.split_xpty != null and self.split_direction != null) {
                const left_cols = @as(i32, @intCast(self.cols / 2));
                const clicked_left = (col < left_cols);
                const dir = self.split_direction.?;
                if (dir == .right) {
                    self.focused_xpty = if (clicked_left) .primary else .split;
                } else {
                    self.focused_xpty = if (clicked_left) .split else .primary;
                }
                self.needs_render = true;
            }
            if (self.compositor.pointerButton(px, py, pressed)) {
                self.needs_render = true;
            }
        },
        else => {},
    }
}

fn onTextInput(_: *anyopaque, _: zwp.TextInputV3.Event) void {}

fn onScale(_: *anyopaque, _: u32) anyerror!void {}

fn onRedrawReady(ctx: *anyopaque) void {
    const self: *TcGuiApp = @ptrCast(@alignCast(ctx));
    self.needs_render = true;
}
