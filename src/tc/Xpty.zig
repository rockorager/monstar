//! xpty: The Legacy PTY Bridge ("Xwayland for Terminals") for TC-Wayland.
//! Wraps legacy VT100/ANSI processes (bash, zsh, vim, htop) into an isolated
//! TC-Wayland grid surface backed by master/slave PTY descriptors.
//! Clamps all escapes to the surface bounds and produces atomic cell buffer commits.

const Xpty = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl_client = wayland.client;
const wl = wl_client.wl;
const zterm = wl_client.zterm;
const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const CompactFlags = abi.CompactFlags;
const Buffer = @import("Buffer.zig");
const Client = @import("Client.zig");
const Pty = @import("../Pty.zig");

allocator: std.mem.Allocator,
client: *Client,
surface: *wl.Surface,
grid_surface: *zterm.GridSurfaceV1,

cols: u32,
rows: u32,
cells: []CompactCell,
cursor_col: u32 = 0,
cursor_row: u32 = 0,
cursor_visible: bool = true,
wrap_next: bool = false,
autowrap: bool = true,
in_osc: bool = false,

current_fg: u8 = 7,
current_bg: u8 = 0,
current_bold: bool = false,
current_inverse: bool = false,
current_underline: bool = false,
saved_cursor_col: u32 = 0,
saved_cursor_row: u32 = 0,

// PTY State (optional when running simulated shell)
pty: ?Pty = null,
child_pid: ?std.posix.pid_t = null,
pty_buffer: [4096]u8 = undefined,
pending_buf: [128]u8 = undefined,
pending_len: usize = 0,

// Simulated shell state if no real PTY is spawned
is_simulated: bool = false,
sim_prompt: []const u8 = "monstar:xpty$ ",
sim_input_buf: [256]u8 = undefined,
sim_input_len: usize = 0,

pub fn init(
    allocator: std.mem.Allocator,
    c: *Client,
    cols: u32,
    rows: u32,
) !*Xpty {
    const comp = c.compositor orelse return error.NoCompositor;
    const zcomp = c.zterm_compositor orelse return error.NoZtermCompositor;

    const surf = try comp.createSurface();
    errdefer surf.destroy();

    const grid = try zcomp.getGridSurface(surf);
    grid.setTitle(" xpty terminal ");

    const cell_count = cols * rows;
    const cells = try allocator.alloc(CompactCell, cell_count);
    errdefer allocator.free(cells);

    for (cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, 0);
    }

    const self = try allocator.create(Xpty);
    self.* = .{
        .allocator = allocator,
        .client = c,
        .surface = surf,
        .grid_surface = grid,
        .cols = cols,
        .rows = rows,
        .cells = cells,
    };

    return self;
}

pub fn deinit(self: *Xpty) void {
    if (self.pty) |*p| {
        p.deinit();
    }
    self.allocator.free(self.cells);
    self.grid_surface.destroy();
    self.surface.destroy();
    self.allocator.destroy(self);
}

pub fn setPosition(self: *Xpty, x: i32, y: i32) void {
    self.grid_surface.setPosition(x, y);
}

pub fn resize(self: *Xpty, new_cols: u32, new_rows: u32) !void {
    if (self.cols == new_cols and self.rows == new_rows) return;

    const new_count = @as(usize, new_cols) * new_rows;
    const new_cells = try self.allocator.alloc(CompactCell, new_count);
    for (new_cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, 0);
    }

    const copy_rows = @min(self.rows, new_rows);
    const copy_cols = @min(self.cols, new_cols);
    var r: usize = 0;
    while (r < copy_rows) : (r += 1) {
        @memcpy(new_cells[r * new_cols .. r * new_cols + copy_cols], self.cells[r * self.cols .. r * self.cols + copy_cols]);
    }

    self.allocator.free(self.cells);
    self.cells = new_cells;
    self.cols = new_cols;
    self.rows = new_rows;
    if (new_cols > 0) self.cursor_col = @min(self.cursor_col, new_cols - 1);
    if (new_rows > 0) self.cursor_row = @min(self.cursor_row, new_rows - 1);

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
    self.writeStringAt(0, 0, "=== xpty bridge (Xwayland for Terminals) ===", 6, 0, true);
    self.writeStringAt(0, 1, "Type commands: 'help', 'ls', 'uname', 'clear'", 7, 0, false);
    self.cursor_row = 3;
    self.cursor_col = 0;
    self.writeSimPrompt();
    self.commit() catch {};
}

pub fn clearGrid(self: *Xpty) void {
    for (self.cells) |*cell| {
        cell.* = CompactCell.ascii(' ', self.current_fg, self.current_bg);
    }
    self.cursor_col = 0;
    self.cursor_row = 0;
    self.wrap_next = false;
    self.autowrap = true;
    self.in_osc = false;
    self.pending_len = 0;
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

pub fn writeStringAt(self: *Xpty, col: u32, row: u32, str: []const u8, fg: u8, bg: u8, bold: bool) void {
    if (row >= self.rows) return;
    var it = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    var c = col;
    while (it.nextCodepoint()) |cp| {
        if (c >= self.cols) break;
        self.cells[row * self.cols + c] = .{
            .codepoint = cp,
            .fg_color = fg,
            .bg_color = bg,
            .flags = .{ .bold = bold },
        };
        c += 1;
    }
}

fn writeSimPrompt(self: *Xpty) void {
    self.writeStringAt(0, self.cursor_row, self.sim_prompt, 2, 0, true);
    self.cursor_col = @intCast(self.sim_prompt.len);
    self.sim_input_len = 0;
}

/// Parses ANSI escape sequences and text stream into the cell grid.
pub fn feedBytes(self: *Xpty, bytes: []const u8) void {
    var stream_buf: [4096 + 128]u8 = undefined;
    var dyn_buf: ?[]u8 = null;
    defer if (dyn_buf) |buf| self.allocator.free(buf);

    const stream = if (self.pending_len > 0) blk: {
        const total = self.pending_len + bytes.len;
        const dest = if (total <= stream_buf.len)
            stream_buf[0..total]
        else b: {
            dyn_buf = self.allocator.alloc(u8, total) catch null;
            if (dyn_buf) |db| break :b db;
            self.pending_len = 0;
            break :blk bytes;
        };
        @memcpy(dest[0..self.pending_len], self.pending_buf[0..self.pending_len]);
        @memcpy(dest[self.pending_len..total], bytes);
        self.pending_len = 0;
        break :blk dest;
    } else bytes;

    var i: usize = 0;
    while (i < stream.len) {
        // 0. Continuation of OSC sequence across chunk boundary
        if (self.in_osc) {
            while (i < stream.len) : (i += 1) {
                if (stream[i] == '\x07') {
                    self.in_osc = false;
                    i += 1;
                    break;
                }
                if (stream[i] == '\x1b' and i + 1 < stream.len and stream[i + 1] == '\\') {
                    self.in_osc = false;
                    i += 2;
                    break;
                }
            }
            if (self.in_osc) {
                if (i > 0 and stream[stream.len - 1] == '\x1b') {
                    self.pending_buf[0] = '\x1b';
                    self.pending_len = 1;
                }
                return;
            }
            continue;
        }

        const b = stream[i];

        // Check for incomplete escape sequence at the end of the buffer
        if (b == '\x1b') {
            if (i + 1 == stream.len) {
                const rem = stream[i..];
                if (rem.len <= self.pending_buf.len) {
                    @memcpy(self.pending_buf[0..rem.len], rem);
                    self.pending_len = rem.len;
                }
                return;
            }
            if (stream[i + 1] == '[') {
                var j = i + 2;
                var found_final = false;
                while (j < stream.len) : (j += 1) {
                    const cj = stream[j];
                    if (cj >= 0x40 and cj <= 0x7e) {
                        found_final = true;
                        break;
                    }
                }
                if (!found_final) {
                    const rem = stream[i..];
                    if (rem.len <= self.pending_buf.len) {
                        @memcpy(self.pending_buf[0..rem.len], rem);
                        self.pending_len = rem.len;
                    }
                    return;
                }
            } else if (stream[i + 1] == '(' or stream[i + 1] == ')') {
                if (i + 2 >= stream.len) {
                    const rem = stream[i..];
                    if (rem.len <= self.pending_buf.len) {
                        @memcpy(self.pending_buf[0..rem.len], rem);
                        self.pending_len = rem.len;
                    }
                    return;
                }
            }
        }

        // 1. OSC sequence: \x1b] ... (\x07 | \x1b\)
        if (b == '\x1b' and i + 1 < stream.len and stream[i + 1] == ']') {
            i += 2;
            var terminated = false;
            while (i < stream.len) : (i += 1) {
                if (stream[i] == '\x07') {
                    self.in_osc = false;
                    i += 1;
                    terminated = true;
                    break;
                }
                if (stream[i] == '\x1b' and i + 1 < stream.len and stream[i + 1] == '\\') {
                    self.in_osc = false;
                    i += 2;
                    terminated = true;
                    break;
                }
            }
            if (!terminated) {
                self.in_osc = true;
                if (stream[stream.len - 1] == '\x1b') {
                    self.pending_buf[0] = '\x1b';
                    self.pending_len = 1;
                }
            }
            continue;
        }

        // 2. CSI sequence: \x1b[ [prefix] [arg;arg...] <cmd>
        if (b == '\x1b' and i + 1 < stream.len and stream[i + 1] == '[') {
            i += 2;
            var prefix: u8 = 0;
            if (i < stream.len and (stream[i] == '?' or stream[i] == '>' or stream[i] == '<' or stream[i] == '=')) {
                prefix = stream[i];
                i += 1;
            }

            var args: [16]u32 = .{0} ** 16;
            var arg_count: usize = 0;
            var has_digits = false;

            while (i < stream.len) {
                const c = stream[i];
                if (c >= '0' and c <= '9') {
                    has_digits = true;
                    if (arg_count < args.len) {
                        args[arg_count] = args[arg_count] * 10 + (c - '0');
                    }
                    i += 1;
                } else if (c == ';' or c == ':') {
                    if (has_digits and arg_count < args.len) arg_count += 1;
                    has_digits = false;
                    i += 1;
                } else {
                    break;
                }
            }
            if (has_digits and arg_count < args.len) arg_count += 1;

            // Skip any intermediate bytes (0x20..0x2F, e.g. space, !, etc.)
            while (i < stream.len and stream[i] >= 0x20 and stream[i] <= 0x2f) : (i += 1) {}

            if (i < stream.len) {
                const cmd = stream[i];
                i += 1;
                self.wrap_next = false;

                if (prefix == '?') {
                    switch (cmd) {
                        'h' => {
                            for (args[0..arg_count]) |arg| {
                                switch (arg) {
                                    7 => self.autowrap = true,
                                    25 => self.cursor_visible = true,
                                    else => {},
                                }
                            }
                        },
                        'l' => {
                            for (args[0..arg_count]) |arg| {
                                switch (arg) {
                                    7 => {
                                        self.autowrap = false;
                                        self.wrap_next = false;
                                    },
                                    25 => self.cursor_visible = false,
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                } else if (prefix == '>') {
                    switch (cmd) {
                        'c' => {
                            // Secondary Device Attributes (DA2)
                            if (self.pty) |p| {
                                const da2 = "\x1b[>0;100;0c";
                                _ = std.c.write(p.master, da2.ptr, da2.len);
                            }
                        },
                        'u' => {}, // Kitty keyboard protocol push
                        else => {},
                    }
                } else if (prefix == '<') {
                    switch (cmd) {
                        'u' => {}, // Kitty keyboard protocol pop
                        else => {},
                    }
                } else {
                    switch (cmd) {
                        'm' => {
                            // SGR color & style
                            if (arg_count == 0) {
                                self.current_fg = 7;
                                self.current_bg = 0;
                                self.current_bold = false;
                                self.current_inverse = false;
                                self.current_underline = false;
                            } else {
                                var a_idx: usize = 0;
                                while (a_idx < arg_count) : (a_idx += 1) {
                                    const a = args[a_idx];
                                    switch (a) {
                                        0 => {
                                            self.current_fg = 7;
                                            self.current_bg = 0;
                                            self.current_bold = false;
                                            self.current_inverse = false;
                                            self.current_underline = false;
                                        },
                                        1 => self.current_bold = true,
                                        4 => self.current_underline = true,
                                        7 => self.current_inverse = true,
                                        22 => self.current_bold = false,
                                        24 => self.current_underline = false,
                                        27 => self.current_inverse = false,
                                        30...37 => self.current_fg = @intCast(a - 30),
                                        38 => {
                                            if (a_idx + 4 < arg_count and args[a_idx + 1] == 2) {
                                                self.current_fg = rgbToPalette(args[a_idx + 2], args[a_idx + 3], args[a_idx + 4]);
                                                a_idx += 4;
                                            } else if (a_idx + 2 < arg_count and args[a_idx + 1] == 5) {
                                                self.current_fg = @truncate(args[a_idx + 2] & 15);
                                                a_idx += 2;
                                            }
                                        },
                                        39 => self.current_fg = 7,
                                        40...47 => self.current_bg = @intCast(a - 40),
                                        48 => {
                                            if (a_idx + 4 < arg_count and args[a_idx + 1] == 2) {
                                                self.current_bg = rgbToPalette(args[a_idx + 2], args[a_idx + 3], args[a_idx + 4]);
                                                a_idx += 4;
                                            } else if (a_idx + 2 < arg_count and args[a_idx + 1] == 5) {
                                                self.current_bg = @truncate(args[a_idx + 2] & 15);
                                                a_idx += 2;
                                            }
                                        },
                                        49 => self.current_bg = 0,
                                        90...97 => self.current_fg = @intCast(8 + (a - 90)),
                                        100...107 => self.current_bg = @intCast(8 + (a - 100)),
                                        else => {},
                                    }
                                }
                            }
                        },
                        'H', 'f' => {
                            // Cursor positioning (1-indexed)
                            const r = if (arg_count >= 1 and args[0] > 0) args[0] - 1 else 0;
                            const c = if (arg_count >= 2 and args[1] > 0) args[1] - 1 else 0;
                            self.cursor_row = @min(r, self.rows - 1);
                            self.cursor_col = @min(c, self.cols - 1);
                        },
                        'A' => {
                            // Cursor Up
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.cursor_row = if (self.cursor_row >= n) self.cursor_row - n else 0;
                        },
                        'B' => {
                            // Cursor Down
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
                        },
                        'C' => {
                            // Cursor Forward
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
                        },
                        'D' => {
                            // Cursor Backward
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.cursor_col = if (self.cursor_col >= n) self.cursor_col - n else 0;
                        },
                        'G' => {
                            // Cursor Horizontal Absolute
                            const c = if (arg_count >= 1 and args[0] > 0) args[0] - 1 else 0;
                            self.cursor_col = @min(c, self.cols - 1);
                        },
                        'd' => {
                            // Cursor Line Absolute
                            const r = if (arg_count >= 1 and args[0] > 0) args[0] - 1 else 0;
                            self.cursor_row = @min(r, self.rows - 1);
                        },
                        'X' => {
                            // Erase Character
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            const r = self.cursor_row;
                            if (r < self.rows) {
                                var count: u32 = 0;
                                while (count < n and self.cursor_col + count < self.cols) : (count += 1) {
                                    self.cells[r * self.cols + self.cursor_col + count] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                }
                            }
                        },
                        'S' => {
                            // Scroll Up
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.scrollUp(n);
                        },
                        'T' => {
                            // Scroll Down
                            const n = if (arg_count >= 1 and args[0] > 0) args[0] else 1;
                            self.scrollDown(n);
                        },
                        's' => {
                            // Save Cursor
                            self.saved_cursor_col = self.cursor_col;
                            self.saved_cursor_row = self.cursor_row;
                        },
                        'u' => {
                            // Restore Cursor
                            self.cursor_col = @min(self.saved_cursor_col, self.cols - 1);
                            self.cursor_row = @min(self.saved_cursor_row, self.rows - 1);
                        },
                        'n' => {
                            // Device Status Report
                            if (arg_count >= 1 and args[0] == 6) {
                                var cpr_buf: [32]u8 = undefined;
                                const cpr = std.fmt.bufPrint(&cpr_buf, "\x1b[{d};{d}R", .{ self.cursor_row + 1, self.cursor_col + 1 }) catch "";
                                if (self.pty) |p| {
                                    _ = std.c.write(p.master, cpr.ptr, cpr.len);
                                }
                            }
                        },
                        'K' => {
                            // Erase in Line
                            const mode = if (arg_count >= 1) args[0] else 0;
                            const r = self.cursor_row;
                            if (r < self.rows) {
                                switch (mode) {
                                    0 => {
                                        var c = self.cursor_col;
                                        while (c < self.cols) : (c += 1) {
                                            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                        }
                                    },
                                    1 => {
                                        var c: u32 = 0;
                                        while (c <= @min(self.cursor_col, self.cols - 1)) : (c += 1) {
                                            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                        }
                                    },
                                    2 => {
                                        var c: u32 = 0;
                                        while (c < self.cols) : (c += 1) {
                                            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                        }
                                    },
                                    else => {},
                                }
                            }
                        },
                        'J' => {
                            // Erase in Display
                            const mode = if (arg_count >= 1) args[0] else 0;
                            switch (mode) {
                                2, 3 => {
                                    for (self.cells) |*cell| {
                                        cell.* = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                    }
                                },
                                0 => {
                                    var r = self.cursor_row;
                                    var c = self.cursor_col;
                                    while (r < self.rows) : (r += 1) {
                                        while (c < self.cols) : (c += 1) {
                                            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                        }
                                        c = 0;
                                    }
                                },
                                1 => {
                                    var r: u32 = 0;
                                    while (r <= self.cursor_row and r < self.rows) : (r += 1) {
                                        const max_c = if (r == self.cursor_row) @min(self.cursor_col, self.cols - 1) else self.cols - 1;
                                        var c: u32 = 0;
                                        while (c <= max_c) : (c += 1) {
                                            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                }
            }
            continue;
        }

        // 3. Simple escapes
        if (b == '\x1b' and i + 1 < stream.len) {
            const next = stream[i + 1];
            switch (next) {
                '7' => {
                    self.saved_cursor_col = self.cursor_col;
                    self.saved_cursor_row = self.cursor_row;
                    self.wrap_next = false;
                    i += 2;
                    continue;
                },
                '8' => {
                    self.cursor_col = @min(self.saved_cursor_col, self.cols - 1);
                    self.cursor_row = @min(self.saved_cursor_row, self.rows - 1);
                    self.wrap_next = false;
                    i += 2;
                    continue;
                },
                '=', '>' => {
                    i += 2;
                    continue;
                },
                '(', ')' => {
                    i += if (i + 2 < stream.len) 3 else 2;
                    continue;
                },
                'M' => {
                    // Reverse index
                    self.wrap_next = false;
                    if (self.cursor_row > 0) {
                        self.cursor_row -= 1;
                    } else {
                        self.scrollDown(1);
                    }
                    i += 2;
                    continue;
                },
                'D' => {
                    // Index
                    self.wrap_next = false;
                    if (self.cursor_row + 1 < self.rows) {
                        self.cursor_row += 1;
                    } else {
                        self.scrollUp(1);
                    }
                    i += 2;
                    continue;
                },
                'E' => {
                    // Next Line
                    self.wrap_next = false;
                    self.cursor_col = 0;
                    if (self.cursor_row + 1 < self.rows) {
                        self.cursor_row += 1;
                    } else {
                        self.scrollUp(1);
                    }
                    i += 2;
                    continue;
                },
                else => {},
            }
        }

        // 4. Standard control characters
        switch (b) {
            '\r' => {
                self.cursor_col = 0;
                self.wrap_next = false;
                i += 1;
            },
            '\n' => {
                self.cursor_col = 0;
                self.wrap_next = false;
                if (self.cursor_row + 1 < self.rows) {
                    self.cursor_row += 1;
                } else {
                    self.scrollUp(1);
                }
                i += 1;
            },
            '\x08', 0x7f => {
                self.wrap_next = false;
                if (self.cursor_col > 0) {
                    self.cursor_col -= 1;
                }
                i += 1;
            },
            '\t' => {
                self.wrap_next = false;
                const tab_stop = (self.cursor_col + 8) & ~@as(u32, 7);
                self.cursor_col = @min(tab_stop, self.cols - 1);
                i += 1;
            },
            '\x07' => {
                // Bell - ignore
                i += 1;
            },
            else => {
                // 5. UTF-8 character decode
                if (b >= 0xc0) {
                    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    if (i + seq_len > stream.len) {
                        // Incomplete UTF-8 sequence at chunk end
                        const rem = stream[i..];
                        if (rem.len <= self.pending_buf.len) {
                            @memcpy(self.pending_buf[0..rem.len], rem);
                            self.pending_len = rem.len;
                        }
                        return;
                    }
                }

                const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + seq_len <= stream.len) {
                    const cp = std.unicode.utf8Decode(stream[i .. i + seq_len]) catch b;

                    // Deferred Autowrap (DECAWM)
                    if (self.autowrap and self.wrap_next) {
                        self.wrap_next = false;
                        self.cursor_col = 0;
                        if (self.cursor_row + 1 < self.rows) {
                            self.cursor_row += 1;
                        } else {
                            self.scrollUp(1);
                        }
                    }

                    if (self.cursor_col < self.cols and self.cursor_row < self.rows) {
                        const fg = if (self.current_inverse) self.current_bg else self.current_fg;
                        const bg = if (self.current_inverse) self.current_fg else self.current_bg;
                        self.cells[self.cursor_row * self.cols + self.cursor_col] = .{
                            .codepoint = cp,
                            .fg_color = fg,
                            .bg_color = bg,
                            .flags = .{
                                .bold = self.current_bold,
                                .underline = self.current_underline,
                            },
                        };
                        if (self.cursor_col + 1 < self.cols) {
                            self.cursor_col += 1;
                        } else if (self.autowrap) {
                            self.wrap_next = true;
                        }
                    }
                    i += seq_len;
                } else {
                    i += 1;
                }
            },
        }
    }
}

pub fn scrollUp(self: *Xpty, lines: u32) void {
    if (lines >= self.rows) {
        self.clearGrid();
        return;
    }
    const move_cells = (self.rows - lines) * self.cols;
    const src_offset = lines * self.cols;
    std.mem.copyForwards(CompactCell, self.cells[0..move_cells], self.cells[src_offset .. src_offset + move_cells]);

    var r = self.rows - lines;
    while (r < self.rows) : (r += 1) {
        var c: u32 = 0;
        while (c < self.cols) : (c += 1) {
            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
        }
    }
}

pub fn scrollDown(self: *Xpty, lines: u32) void {
    if (lines >= self.rows) {
        self.clearGrid();
        return;
    }
    const move_cells = (self.rows - lines) * self.cols;
    const dst_offset = lines * self.cols;
    std.mem.copyBackwards(CompactCell, self.cells[dst_offset .. dst_offset + move_cells], self.cells[0..move_cells]);

    var r: usize = 0;
    while (r < lines) : (r += 1) {
        var c: usize = 0;
        while (c < self.cols) : (c += 1) {
            self.cells[r * self.cols + c] = CompactCell.ascii(' ', self.current_fg, self.current_bg);
        }
    }
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
            self.feedBytes(self.pty_buffer[0..@intCast(rc)]);
        } else {
            break;
        }
    }

    if (any_read) {
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
                self.executeSimCommand(cmd);
                self.cursor_row = @min(self.cursor_row + 1, self.rows - 1);
                self.writeSimPrompt();
            } else if (b == 0x7f or b == '\x08') {
                if (self.sim_input_len > 0) {
                    self.sim_input_len -= 1;
                    if (self.cursor_col > self.sim_prompt.len) {
                        self.cursor_col -= 1;
                        self.cells[self.cursor_row * self.cols + self.cursor_col] = CompactCell.ascii(' ', 7, 0);
                    }
                }
            } else if (b >= 32 and b < 127) {
                if (self.sim_input_len < self.sim_input_buf.len and self.cursor_col < self.cols) {
                    self.sim_input_buf[self.sim_input_len] = b;
                    self.sim_input_len += 1;
                    self.cells[self.cursor_row * self.cols + self.cursor_col] = CompactCell.ascii(b, 7, 0);
                    self.cursor_col += 1;
                }
            }
        }
        try self.commit();
    }
}

fn executeSimCommand(self: *Xpty, cmd: []const u8) void {
    self.cursor_col = 0;
    self.cursor_row = @min(self.cursor_row + 1, self.rows - 1);

    if (std.mem.eql(u8, cmd, "help")) {
        self.writeStringAt(0, self.cursor_row, "xpty: built-in commands: help, ls, uname, clear", 3, 0, false);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        self.writeStringAt(0, self.cursor_row, "build.zig  protocol/  src/  vendor/  README.md", 4, 0, true);
    } else if (std.mem.eql(u8, cmd, "uname")) {
        self.writeStringAt(0, self.cursor_row, "Linux monstar-tc-wayland 6.12.0-tc-wayland #1 SMP", 5, 0, false);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        self.clearGrid();
        self.cursor_row = 0;
    } else if (cmd.len > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "xpty: command not found: {s}", .{cmd}) catch "xpty: command not found";
        self.writeStringAt(0, self.cursor_row, msg, 1, 0, false);
    }
}

/// Commits the current grid cells to the Wayland surface.
pub fn commit(self: *Xpty) !void {
    const raw_bytes = std.mem.sliceAsBytes(self.cells);
    const buf = try self.client.createCellBuffer(self.cols, self.rows, .compact_v1, raw_bytes);
    self.surface.attach(buf, 0, 0);
    self.surface.damage(0, 0, @intCast(self.cols), @intCast(self.rows));
    self.surface.commit();
}

test "xpty deferred autowrap and prompt-sp" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;
    const cells = try allocator.alloc(CompactCell, cols * rows);
    defer allocator.free(cells);
    for (cells) |*c| c.* = CompactCell.ascii(' ', 7, 0);

    var xpty: Xpty = .{
        .allocator = allocator,
        .client = undefined,
        .surface = undefined,
        .grid_surface = undefined,
        .cols = cols,
        .rows = rows,
        .cells = cells,
    };

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
    try std.testing.expectEqual(@as(u21, 'p'), xpty.cells[0].codepoint);
}

test "xpty chunk boundary split CSI and UTF-8 sequences" {
    const allocator = std.testing.allocator;
    const cols: u32 = 80;
    const rows: u32 = 24;
    const cells = try allocator.alloc(CompactCell, cols * rows);
    defer allocator.free(cells);
    for (cells) |*c| c.* = CompactCell.ascii(' ', 7, 0);

    var xpty: Xpty = .{
        .allocator = allocator,
        .client = undefined,
        .surface = undefined,
        .grid_surface = undefined,
        .cols = cols,
        .rows = rows,
        .cells = cells,
    };

    // 1. CSI sequence split between \x1b and [
    xpty.feedBytes("hello\x1b");
    xpty.feedBytes("[10CH");
    // "hello" + cursor forward 10 + "H"
    try std.testing.expectEqual(@as(u32, 16), xpty.cursor_col);
    try std.testing.expectEqual(@as(u21, 'H'), xpty.cells[15].codepoint);

    // 2. CSI sequence split between \x1b[ and 1C
    xpty.clearGrid();
    xpty.feedBytes("a\x1b[");
    xpty.feedBytes("5Cb");
    try std.testing.expectEqual(@as(u32, 7), xpty.cursor_col);
    try std.testing.expectEqual(@as(u21, 'a'), xpty.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), xpty.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), xpty.cells[6].codepoint);

    // 3. CSI sequence split between \x1b[1 and C
    xpty.clearGrid();
    xpty.feedBytes("test\x1b[1");
    xpty.feedBytes("0C!");
    try std.testing.expectEqual(@as(u32, 15), xpty.cursor_col);
    try std.testing.expectEqual(@as(u21, '!'), xpty.cells[14].codepoint);

    // 4. UTF-8 multi-byte sequence split across chunks: "─" (0xE2, 0x94, 0x80)
    xpty.clearGrid();
    xpty.feedBytes("\xe2");
    xpty.feedBytes("\x94\x80");
    try std.testing.expectEqual(@as(u32, 1), xpty.cursor_col);
    try std.testing.expectEqual(@as(u21, 0x2500), xpty.cells[0].codepoint);

    // 5. CSI with intermediate space (DECSCUSR: \x1b[2 q) does not leak 'q'
    xpty.clearGrid();
    xpty.feedBytes("\x1b[2 q");
    try std.testing.expectEqual(@as(u32, 0), xpty.cursor_col);
    try std.testing.expectEqual(@as(u21, ' '), xpty.cells[0].codepoint);
}
