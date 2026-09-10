//! xpty: The Legacy PTY Bridge ("Xwayland for Terminals") for TC-Wayland.
//! Wraps legacy VT100/ANSI processes (bash, zsh, vim, htop) into an isolated
//! TC-Wayland grid surface backed by master/slave PTY descriptors.
//! Uses libghostty-vt for full VT100/xterm emulation and screen state management.

const Xpty = @This();

const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland");
const wl_client = wayland.client;
const wl = wl_client.wl;
const zterm = wl_client.zterm;
const vt = @import("ghostty-vt");
const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const CompactFlags = abi.CompactFlags;
const Buffer = @import("Buffer.zig");
const Client = @import("Client.zig");
const Pty = @import("../Pty.zig");

allocator: std.mem.Allocator,
client: ?*Client,
surface: ?*wl.Surface,
grid_surface: ?*zterm.GridSurfaceV1,

cols: u32,
rows: u32,
cells: []CompactCell,
cursor_col: u32 = 0,
cursor_row: u32 = 0,
cursor_visible: bool = true,
wrap_next: bool = false,

// Terminal emulation via ghostty-vt
term: vt.Terminal,
stream: vt.TerminalStream,
render_state: vt.RenderState = .empty,

// PTY State (optional when running simulated shell)
pty: ?Pty = null,
child_pid: ?std.posix.pid_t = null,
pty_buffer: [4096]u8 = undefined,

// Output hook (e.g. for streaming PTY bytes into command blocks)
output_fn: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
output_ctx: ?*anyopaque = null,

// Simulated shell state if no real PTY is spawned
is_simulated: bool = false,
is_visible: bool = true,
sim_prompt: []const u8 = "monstar:xpty$ ",
sim_input_buf: [256]u8 = undefined,
sim_input_len: usize = 0,

fn defaultIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

fn effectWritePty(handler: *vt.TerminalStream.Handler, data: [:0]const u8) void {
    const self: *Xpty = @fieldParentPtr("term", handler.terminal);
    if (self.pty) |p| {
        _ = std.c.write(p.master, data.ptr, data.len);
    }
}

fn effectTitleChanged(handler: *vt.TerminalStream.Handler) void {
    const self: *Xpty = @fieldParentPtr("term", handler.terminal);
    if (self.grid_surface) |grid| {
        if (handler.terminal.getTitle()) |title| {
            grid.setTitle(title);
        }
    }
}

pub fn init(
    allocator: std.mem.Allocator,
    c: ?*Client,
    cols: u32,
    rows: u32,
) !*Xpty {
    var surf: ?*wl.Surface = null;
    errdefer if (surf) |s| s.destroy();

    var grid: ?*zterm.GridSurfaceV1 = null;

    if (c) |client| {
        const comp = client.compositor orelse return error.NoCompositor;
        const zcomp = client.zterm_compositor orelse return error.NoZtermCompositor;

        surf = try comp.createSurface();
        grid = try zcomp.getGridSurface(surf.?);
        grid.?.setTitle(" xpty terminal ");
    }

    const cell_count = @as(usize, cols) * rows;
    const cells = try allocator.alloc(CompactCell, cell_count);
    errdefer allocator.free(cells);

    for (cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, 0);
    }

    var term: vt.Terminal = try .init(defaultIo(), allocator, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .max_scrollback_bytes = 0,
    });
    errdefer term.deinit(allocator);

    const self = try allocator.create(Xpty);
    self.* = .{
        .allocator = allocator,
        .client = c,
        .surface = surf,
        .grid_surface = grid,
        .cols = cols,
        .rows = rows,
        .cells = cells,
        .term = term,
        .stream = undefined,
        .is_visible = true,
    };
    self.stream = self.term.vtStream();
    self.stream.handler.effects.write_pty = effectWritePty;
    self.stream.handler.effects.title_changed = effectTitleChanged;

    return self;
}

pub fn deinit(self: *Xpty) void {
    if (self.child_pid) |pid| {
        _ = Pty.tryWait(pid) catch {};
        self.child_pid = null;
    }
    if (self.pty) |*p| {
        p.deinit();
    }
    self.stream.deinit();
    self.render_state.deinit(self.allocator);
    self.term.deinit(self.allocator);
    self.allocator.free(self.cells);
    if (self.grid_surface) |grid| grid.destroy();
    if (self.surface) |surf| surf.destroy();
    self.allocator.destroy(self);
}

/// Checks if the spawned child process has exited and reaps it.
/// Returns the wait status if exited, or null if still running.
pub fn checkChildExited(self: *Xpty) ?u32 {
    const pid = self.child_pid orelse return null;
    const status = Pty.tryWait(pid) catch return null;
    if (status) |st| {
        self.child_pid = null;
        return st;
    }
    return null;
}

/// Converts a Linux wait status into a standard exit code (0-255).
pub fn statusToExitCode(status: u32) u8 {
    if ((status & 0x7f) == 0) {
        return @truncate(status >> 8);
    } else {
        return @truncate(128 + (status & 0x7f));
    }
}

/// Returns true if the terminal is currently in the alternate screen buffer
/// (e.g. entered via \x1b[?1049h or \x1b[?47h by curses/TUI applications).
pub fn isAlternateScreen(self: *const Xpty) bool {
    return self.term.screens.active_key == .alternate;
}

pub fn setPosition(self: *Xpty, x: i32, y: i32) void {
    if (self.grid_surface) |grid| {
        grid.setPosition(x, y);
    }
}

pub fn resize(self: *Xpty, new_cols: u32, new_rows: u32) !void {
    if (self.cols == new_cols and self.rows == new_rows) return;
    if (new_cols == 0 or new_rows == 0) return;

    try self.term.resize(self.allocator, .{
        .cols = @intCast(new_cols),
        .rows = @intCast(new_rows),
    });

    const new_count = @as(usize, new_cols) * new_rows;
    const new_cells = try self.allocator.alloc(CompactCell, new_count);
    for (new_cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, 0);
    }

    self.allocator.free(self.cells);
    self.cells = new_cells;
    self.cols = new_cols;
    self.rows = new_rows;

    if (self.pty) |*p| {
        p.setWinsize(.{
            .row = @intCast(new_rows),
            .col = @intCast(new_cols),
            .xpixel = 0,
            .ypixel = 0,
        }) catch {};
    }

    try self.commit();
}

/// Spawns a real child process attached to a PTY master/slave pair.
pub fn spawnPty(
    self: *Xpty,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) !void {
    var p = try Pty.open(.{
        .col = @intCast(self.cols),
        .row = @intCast(self.rows),
        .xpixel = 0,
        .ypixel = 0,
    });
    errdefer p.deinit();

    // Set master fd non-blocking so reads don't block event loops
    const flags = std.os.linux.fcntl(p.master, std.os.linux.F.GETFL, 0);
    _ = std.os.linux.fcntl(p.master, std.os.linux.F.SETFL, flags | 0x800);

    const pid = try p.spawn(path, argv, envp, .{});
    self.pty = p;
    self.child_pid = pid;
    self.is_simulated = false;
}

/// Initializes an interactive simulated shell for standalone testing and demos.
pub fn initSimulatedShell(self: *Xpty) void {
    self.is_simulated = true;
    self.clearGrid();
    self.feedBytes("\x1b[1;36m=== xpty bridge (Xwayland for Terminals) ===\x1b[0m\r\n");
    self.feedBytes("Type commands: 'help', 'ls', 'uname', 'clear'\r\n\r\n");
    self.writeSimPrompt();
    self.commit() catch {};
}

fn writeSimPrompt(self: *Xpty) void {
    self.feedBytes("\x1b[1;32mmonstar:xpty$ \x1b[0m");
    self.sim_input_len = 0;
}

fn executeSimCommand(self: *Xpty, cmd: []const u8) void {
    if (std.mem.eql(u8, cmd, "help")) {
        self.feedBytes("\x1b[33mxpty: built-in commands: help, ls, uname, clear\x1b[0m");
    } else if (std.mem.eql(u8, cmd, "ls")) {
        self.feedBytes("\x1b[1;34mbuild.zig  protocol/  src/  vendor/  README.md\x1b[0m");
    } else if (std.mem.eql(u8, cmd, "uname")) {
        self.feedBytes("\x1b[35mLinux monstar-tc-wayland 6.12.0-tc-wayland #1 SMP\x1b[0m");
    } else if (std.mem.eql(u8, cmd, "clear")) {
        self.clearGrid();
    } else if (cmd.len > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\x1b[31mxpty: command not found: {s}\x1b[0m", .{cmd}) catch "xpty: command not found";
        self.feedBytes(msg);
    }
}

pub fn clearGrid(self: *Xpty) void {
    self.term.fullReset();
    self.stream.deinit();
    self.stream = self.term.vtStream();
    self.stream.handler.effects.write_pty = effectWritePty;
    self.stream.handler.effects.title_changed = effectTitleChanged;
    self.syncFromVt() catch {};
}

fn rgbToPalette(r: u32, g: u32, b: u32) u8 {
    if (r < 30 and g < 30 and b < 30) return 0;
    if (r > 220 and g > 220 and b > 220) return 15;
    if (r > 150 and g > 150 and b > 150) return 7;
    if (r > 70 and g > 70 and b > 70 and @abs(@as(i32, @intCast(r)) - @as(i32, @intCast(g))) < 20 and @abs(@as(i32, @intCast(g)) - @as(i32, @intCast(b))) < 20) return 8;

    const is_bright = (r > 130 or g > 130 or b > 130);
    var idx: u8 = 0;
    if (r > 75) idx |= 1;
    if (g > 75) idx |= 2;
    if (b > 75) idx |= 4;
    if (is_bright) idx |= 8;
    return idx;
}

fn colorToPalette(c: vt.Style.Color, default_color: u8) u8 {
    return switch (c) {
        .none => default_color,
        .palette => |p| p,
        .rgb => |rgb| rgbToPalette(rgb.r, rgb.g, rgb.b),
    };
}

pub fn writeStringAt(self: *Xpty, col: u32, row: u32, str: []const u8, fg: u8, bg: u8, bold: bool) void {
    if (row >= self.rows or col >= self.cols) return;
    var prefix_buf: [64]u8 = undefined;
    const bold_str = if (bold) "1;" else "";
    const prefix = std.fmt.bufPrint(&prefix_buf, "\x1b[{d};{d}H\x1b[{s}38;5;{d};48;5;{d}m", .{
        row + 1,
        col + 1,
        bold_str,
        fg,
        bg,
    }) catch return;
    self.feedBytes(prefix);
    self.feedBytes(str);
    self.feedBytes("\x1b[0m");
}

/// Parses ANSI escape sequences and text stream into the terminal engine.
pub fn feedBytes(self: *Xpty, bytes: []const u8) void {
    self.stream.nextSlice(bytes);
    self.syncFromVt() catch {};
}

/// Synchronizes visual state from ghostty-vt RenderState into self.cells.
pub fn syncFromVt(self: *Xpty) !void {
    try self.render_state.update(self.allocator, &self.term);
    self.cursor_visible = self.render_state.cursor.visible;
    if (self.render_state.cursor.viewport) |vp| {
        self.cursor_col = vp.x;
        self.cursor_row = vp.y;
    }
    self.wrap_next = self.term.screens.active.cursor.pending_wrap;

    const rows = self.render_state.row_data.slice();
    const all_cells = rows.items(.cells);
    const num_rows = @min(self.rows, self.render_state.rows);
    const num_cols = @min(self.cols, self.render_state.cols);

    for (0..num_rows) |y| {
        const row_cells = all_cells[y].slice();
        const raws = row_cells.items(.raw);
        const styles = row_cells.items(.style);

        for (0..num_cols) |x| {
            const raw = raws[x];
            const has_style = raw.style_id != 0;
            const style = if (has_style) styles[x] else vt.Style{};

            var cp: u32 = ' ';
            switch (raw.content_tag) {
                .codepoint, .codepoint_grapheme => {
                    const c = raw.content.codepoint.data;
                    cp = if (c != 0) c else ' ';
                },
                .bg_color_palette, .bg_color_rgb => {
                    cp = ' ';
                },
            }

            var fg_idx: u8 = colorToPalette(style.fg_color, 7);
            var bg_idx: u8 = switch (raw.content_tag) {
                .bg_color_palette => raw.content.color_palette.data,
                .bg_color_rgb => rgbToPalette(raw.content.color_rgb.r, raw.content.color_rgb.g, raw.content.color_rgb.b),
                else => colorToPalette(style.bg_color, 0),
            };

            const flags: CompactFlags = .{
                .bold = style.flags.bold,
                .dim = style.flags.faint,
                .italic = style.flags.italic,
                .underline = style.flags.underline != .none,
                .blink = style.flags.blink,
                .reverse = style.flags.inverse,
                .strikethrough = style.flags.strikethrough,
                .fg_is_palette = true,
                .bg_is_palette = true,
            };

            if (style.flags.inverse) {
                const tmp = fg_idx;
                fg_idx = bg_idx;
                bg_idx = tmp;
            }

            self.cells[y * self.cols + x] = CompactCell.init(cp, fg_idx, bg_idx, flags);
        }
    }
}

pub fn scrollUp(self: *Xpty, lines: u32) void {
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}S", .{lines}) catch return;
    self.feedBytes(seq);
}

pub fn scrollDown(self: *Xpty, lines: u32) void {
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}T", .{lines}) catch return;
    self.feedBytes(seq);
}

pub fn setOutputHandler(self: *Xpty, ctx: ?*anyopaque, handler: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void) void {
    self.output_ctx = ctx;
    self.output_fn = handler;
}

/// Drains any pending output from the real PTY and commits on damage.
pub fn pollPty(self: *Xpty) bool {
    const p = self.pty orelse return false;
    var any_read = false;

    // Read up to 32 chunks (128 KB) per poll tick to avoid starving user input and Wayland events
    var chunk_count: usize = 0;
    while (chunk_count < 32) : (chunk_count += 1) {
        const rc = std.c.read(p.master, &self.pty_buffer, self.pty_buffer.len);
        if (rc > 0) {
            any_read = true;
            const chunk = self.pty_buffer[0..@intCast(rc)];
            self.stream.nextSlice(chunk);
            if (self.output_fn) |cb| {
                if (!self.isAlternateScreen()) {
                    cb(self.output_ctx, chunk);
                }
            }
        } else {
            break;
        }
    }

    if (any_read and self.is_visible) {
        self.commit() catch {};
    }
    return any_read;
}

/// Sends user keystroke or string into the PTY master or simulated shell.
pub fn sendInput(self: *Xpty, bytes: []const u8) !void {
    if (self.pty) |p| {
        _ = std.c.write(p.master, bytes.ptr, bytes.len);
    } else if (self.is_simulated) {
        for (bytes) |b| {
            if (b == '\r' or b == '\n') {
                const cmd = self.sim_input_buf[0..self.sim_input_len];
                self.feedBytes("\r\n");
                self.executeSimCommand(cmd);
                self.feedBytes("\r\n");
                self.writeSimPrompt();
            } else if (b == 0x7f or b == '\x08') {
                if (self.sim_input_len > 0) {
                    self.sim_input_len -= 1;
                    self.feedBytes("\x08 \x08");
                }
            } else if (b >= 32 and b < 127) {
                if (self.sim_input_len < self.sim_input_buf.len) {
                    self.sim_input_buf[self.sim_input_len] = b;
                    self.sim_input_len += 1;
                    const char_slice = [1]u8{b};
                    self.feedBytes(&char_slice);
                }
            }
        }
        try self.commit();
    }
}

/// Commits the current grid cells to the Wayland surface.
pub fn commit(self: *Xpty) !void {
    try self.syncFromVt();
    const cl = self.client orelse return;
    const surf = self.surface orelse return;

    const raw_bytes = std.mem.sliceAsBytes(self.cells);
    const buf = try cl.createCellBuffer(self.cols, self.rows, .compact_v1, raw_bytes);
    surf.attach(buf, 0, 0);
    surf.damage(0, 0, @intCast(self.cols), @intCast(self.rows));
    surf.commit();
}

test "xpty deferred autowrap and prompt-sp" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;

    var xpty = try Xpty.init(allocator, null, cols, rows);
    defer xpty.deinit();

    // 1. Write 80 characters (fills row 0)
    const line80 = "A" ** 80;
    xpty.feedBytes(line80);
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_row);
    try std.testing.expectEqual(@as(u32, 79), xpty.cursor_col);
    try std.testing.expect(xpty.wrap_next);

    // 2. Carriage return \r resets column to 0 without advancing row
    xpty.feedBytes("\r");
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_row);
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_col);
    try std.testing.expect(!xpty.wrap_next);

    // 3. Test yash prompt-sp sequence:
    // \x1b[7m$ \x1b[m (79 spaces) \r \x1b[J prompt$
    xpty.clearGrid();
    const spaces79 = " " ** 79;
    xpty.feedBytes("\x1b[7m$\x1b[m");
    xpty.feedBytes(spaces79);
    xpty.feedBytes("\r\x1b[Jprompt$ ");

    // Prompt should be on row 0, starting with 'p'
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_row);
    try std.testing.expectEqual(@as(u32, 8), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, 'p'), xpty.cells[0].codepoint);
}

test "xpty chunk boundary split CSI and UTF-8 sequences" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;

    var xpty = try Xpty.init(allocator, null, cols, rows);
    defer xpty.deinit();

    // 1. CSI sequence split between \x1b and [
    xpty.feedBytes("hello\x1b");
    xpty.feedBytes("[10CH");
    // "hello" + cursor forward 10 + "H"
    try std.testing.expectEqual(@as(u32, 16), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, 'H'), xpty.cells[15].codepoint);

    // 2. CSI sequence split between \x1b[ and 1C
    xpty.clearGrid();
    xpty.feedBytes("a\x1b[");
    xpty.feedBytes("5Cb");
    try std.testing.expectEqual(@as(u32, 7), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, 'a'), xpty.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, ' '), xpty.cells[1].codepoint);
    try std.testing.expectEqual(@as(u32, 'b'), xpty.cells[6].codepoint);

    // 3. CSI sequence split between \x1b[1 and C
    xpty.clearGrid();
    xpty.feedBytes("test\x1b[1");
    xpty.feedBytes("0C!");
    try std.testing.expectEqual(@as(u32, 15), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, '!'), xpty.cells[14].codepoint);

    // 4. UTF-8 multi-byte sequence split across chunks: "─" (0xE2, 0x94, 0x80)
    xpty.clearGrid();
    xpty.feedBytes("\xe2");
    xpty.feedBytes("\x94\x80");
    try std.testing.expectEqual(@as(u32, 1), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, 0x2500), xpty.cells[0].codepoint);

    // 5. CSI with intermediate space (DECSCUSR: \x1b[2 q) does not leak 'q'
    xpty.clearGrid();
    xpty.feedBytes("\x1b[2 q");
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_col);
    try std.testing.expectEqual(@as(u32, ' '), xpty.cells[0].codepoint);
}

test "xpty child process exit detection" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;

    var xpty = try Xpty.init(allocator, null, cols, rows);
    defer xpty.deinit();

    const sh_z: [*:0]const u8 = "/bin/sh";
    const c_arg: [*:0]const u8 = "-c";
    const cmd_z: [*:0]const u8 = "exit 42";
    const argv = [_:null]?[*:0]const u8{ sh_z, c_arg, cmd_z, null };

    try xpty.spawnPty(sh_z, &argv, std.c.environ);
    try std.testing.expect(xpty.child_pid != null);

    // Wait for the child to exit
    var exited = false;
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (xpty.checkChildExited()) |st| {
            try std.testing.expectEqual(@as(u8, 42), statusToExitCode(st));
            exited = true;
            break;
        }
        const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 10_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    try std.testing.expect(exited);
    try std.testing.expect(xpty.child_pid == null);
}

test "xpty alternate screen detection" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;

    var xpty = try Xpty.init(allocator, null, cols, rows);
    defer xpty.deinit();

    // Initially in primary screen
    try std.testing.expect(!xpty.isAlternateScreen());

    // Enter alternate screen buffer: \x1b[?1049h
    xpty.feedBytes("\x1b[?1049h");
    try std.testing.expect(xpty.isAlternateScreen());

    // Exit alternate screen buffer: \x1b[?1049l
    xpty.feedBytes("\x1b[?1049l");
    try std.testing.expect(!xpty.isAlternateScreen());

    // Legacy alternate screen buffer: \x1b[?47h / \x1b[?47l
    xpty.feedBytes("\x1b[?47h");
    try std.testing.expect(xpty.isAlternateScreen());

    xpty.feedBytes("\x1b[?47l");
    try std.testing.expect(!xpty.isAlternateScreen());
}
