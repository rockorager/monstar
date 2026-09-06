//! Command Palette Overlay Surface for TC-Wayland.
//! Floats above the main terminal, hosting mini-programs (File Search, Live Grep, Split Views).
//! Invoked via Ctrl+Shift+P (or Ctrl+P).

const CommandPalette = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl_client = wayland.client;
const wl = wl_client.wl;
const zterm = wl_client.zterm;
const abi = @import("abi.zig");
const CompactCell = abi.CompactCell;
const CompactFlags = abi.CompactFlags;
const Client = @import("Client.zig");

pub const Mode = enum {
    menu,
    file_search,
    live_grep,
};

pub const Action = union(enum) {
    none,
    close,
    split_left,
    split_right,
    select_file: []const u8,
};

pub const MenuItem = struct {
    icon: []const u8,
    name: []const u8,
    desc: []const u8,
    action: enum { file_search, live_grep, split_left, split_right, close },
};

const menu_items = [_]MenuItem{
    .{ .icon = "📁", .name = "File Search", .desc = "Fuzzy find files in workspace", .action = .file_search },
    .{ .icon = "🔍", .name = "Live Grep", .desc = "Search text across codebase", .action = .live_grep },
    .{ .icon = "◫", .name = "Split Left", .desc = "Add new terminal pane on left", .action = .split_left },
    .{ .icon = "◫", .name = "Split Right", .desc = "Add new terminal pane on right", .action = .split_right },
    .{ .icon = "✕", .name = "Close Palette", .desc = "Dismiss overlay (Esc)", .action = .close },
};

allocator: std.mem.Allocator,
client: *Client,
surface: *wl.Surface,
grid_surface: *zterm.GridSurfaceV1,

cols: u32,
rows: u32,
cells: []CompactCell,

active: bool = false,
mode: Mode = .menu,
selected_idx: usize = 0,

query_buf: [128]u8 = undefined,
query_len: usize = 0,

// Mini-program cached results
file_list: std.ArrayList([]const u8) = .empty,
grep_list: std.ArrayList([]const u8) = .empty,
status_message: ?[]const u8 = null,

pub fn init(
    allocator: std.mem.Allocator,
    c: *Client,
    cols: u32,
    rows: u32,
) !*CommandPalette {
    const comp = c.compositor orelse return error.NoCompositor;
    const zcomp = c.zterm_compositor orelse return error.NoZtermCompositor;

    const surf = try comp.createSurface();
    errdefer surf.destroy();

    const grid = try zcomp.getGridSurface(surf);
    grid.setTitle(" Command Palette ");

    const cell_count = cols * rows;
    const cells = try allocator.alloc(CompactCell, cell_count);
    errdefer allocator.free(cells);

    for (cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 15, 8);
    }

    const self = try allocator.create(CommandPalette);
    self.* = .{
        .allocator = allocator,
        .client = c,
        .surface = surf,
        .grid_surface = grid,
        .cols = cols,
        .rows = rows,
        .cells = cells,
    };

    try self.populateWorkspaceFiles();

    return self;
}

extern "c" fn popen(command: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fgets(s: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;
extern "c" fn fopen(filename: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;

fn clearFileList(self: *CommandPalette) void {
    for (self.file_list.items) |item| {
        self.allocator.free(item);
    }
    self.file_list.clearRetainingCapacity();
}

fn clearGrepList(self: *CommandPalette) void {
    for (self.grep_list.items) |item| {
        self.allocator.free(item);
    }
    self.grep_list.clearRetainingCapacity();
}

pub fn deinit(self: *CommandPalette) void {
    self.clearFileList();
    self.file_list.deinit(self.allocator);
    self.clearGrepList();
    self.grep_list.deinit(self.allocator);
    self.allocator.free(self.cells);
    self.grid_surface.destroy();
    self.surface.destroy();
    self.allocator.destroy(self);
}

pub fn show(self: *CommandPalette) void {
    self.active = true;
    self.mode = .menu;
    self.query_len = 0;
    self.selected_idx = 0;
    self.status_message = null;
    self.populateWorkspaceFiles() catch {};
    self.render();
    self.commit() catch {};
    _ = self.client.display.flush();
}

pub fn hide(self: *CommandPalette) void {
    self.active = false;
    self.surface.attach(null, 0, 0);
    self.surface.commit();
    _ = self.client.display.flush();
}

pub fn setPosition(self: *CommandPalette, x: i32, y: i32) void {
    self.grid_surface.setPosition(x, y);
}

pub fn populateWorkspaceFiles(self: *CommandPalette) !void {
    self.clearFileList();

    if (popen("git ls-files", "r")) |pipe| {
        defer _ = pclose(pipe);
        var buf: [1024]u8 = undefined;
        while (fgets(&buf, buf.len, pipe)) |_| {
            const line = std.mem.sliceTo(&buf, 0);
            const trimmed = std.mem.trim(u8, line, "\r\n \t");
            if (trimmed.len > 0) {
                const duped = try self.allocator.dupe(u8, trimmed);
                try self.file_list.append(self.allocator, duped);
            }
        }
    }

    if (self.file_list.items.len == 0) {
        const fallback_files = [_][]const u8{
            "src/tc/abi.zig",
            "src/tc/Buffer.zig",
            "src/tc/Surface.zig",
            "src/tc/Compositor.zig",
            "src/tc/Client.zig",
            "src/tc/Xpty.zig",
            "src/tc/CommandPalette.zig",
            "src/tc/TcGuiApp.zig",
            "src/tc/TcOverlayRenderer.zig",
            "src/tc.zig",
            "build.zig",
            "protocol/term-compositor-v1.xml",
            "protocol/term-compositor.md",
        };
        for (fallback_files) |f| {
            const duped = try self.allocator.dupe(u8, f);
            try self.file_list.append(self.allocator, duped);
        }
    }
}

pub fn runLiveGrep(self: *CommandPalette, query: []const u8) !void {
    self.clearGrepList();
    if (query.len == 0) return;

    for (self.file_list.items) |file_path| {
        if (self.grep_list.items.len >= 50) break;

        if (std.mem.endsWith(u8, file_path, ".ttf") or
            std.mem.endsWith(u8, file_path, ".png") or
            std.mem.endsWith(u8, file_path, ".svg") or
            std.mem.endsWith(u8, file_path, ".lock"))
        {
            continue;
        }

        var path_buf: [1024]u8 = undefined;
        if (file_path.len >= path_buf.len - 1) continue;
        @memcpy(path_buf[0..file_path.len], file_path);
        path_buf[file_path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_buf[0..file_path.len]);

        const file = fopen(path_z, "r") orelse continue;
        defer _ = fclose(file);

        var file_buf: [128 * 1024]u8 = undefined;
        const bytes_read = fread(&file_buf, 1, file_buf.len, file);
        if (bytes_read == 0) continue;
        const content = file_buf[0..bytes_read];

        var line_num: u32 = 1;
        var line_start: usize = 0;
        for (content, 0..) |b, idx| {
            if (b == '\n') {
                const line = content[line_start..idx];
                line_start = idx + 1;
                if (std.ascii.indexOfIgnoreCase(line, query) != null) {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    var out_buf: [256]u8 = undefined;
                    const entry = std.fmt.bufPrint(&out_buf, "{s}:{d}: {s}", .{ file_path, line_num, trimmed }) catch continue;
                    const duped = try self.allocator.dupe(u8, entry);
                    try self.grep_list.append(self.allocator, duped);
                    if (self.grep_list.items.len >= 50) break;
                }
                line_num += 1;
            }
        }
    }
}

pub fn handleKey(self: *CommandPalette, key_name: []const u8, utf8_text: []const u8) Action {
    if (!self.active) return .none;

    if (std.mem.eql(u8, key_name, "Escape")) {
        if (self.mode != .menu) {
            self.mode = .menu;
            self.query_len = 0;
            self.selected_idx = 0;
            self.render();
            self.commit() catch {};
            return .none;
        } else {
            self.hide();
            return .close;
        }
    }

    if (std.mem.eql(u8, key_name, "Up")) {
        if (self.selected_idx > 0) self.selected_idx -= 1;
        self.render();
        self.commit() catch {};
        return .none;
    }

    if (std.mem.eql(u8, key_name, "Down")) {
        const max_items = self.getItemCount();
        if (max_items > 0 and self.selected_idx + 1 < max_items) {
            self.selected_idx += 1;
        }
        self.render();
        self.commit() catch {};
        return .none;
    }

    if (std.mem.eql(u8, key_name, "Backspace")) {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.selected_idx = 0;
            if (self.mode == .live_grep) {
                self.runLiveGrep(self.query_buf[0..self.query_len]) catch {};
            }
            self.render();
            self.commit() catch {};
        }
        return .none;
    }

    if (std.mem.eql(u8, key_name, "Enter") or std.mem.eql(u8, key_name, "Return")) {
        switch (self.mode) {
            .menu => {
                const item = menu_items[self.selected_idx];
                switch (item.action) {
                    .file_search => {
                        self.mode = .file_search;
                        self.query_len = 0;
                        self.selected_idx = 0;
                    },
                    .live_grep => {
                        self.mode = .live_grep;
                        self.query_len = 0;
                        self.selected_idx = 0;
                        self.runLiveGrep("") catch {};
                    },
                    .split_left => {
                        self.hide();
                        return .split_left;
                    },
                    .split_right => {
                        self.hide();
                        return .split_right;
                    },
                    .close => {
                        self.hide();
                        return .close;
                    },
                }
                self.render();
                self.commit() catch {};
                return .none;
            },
            .file_search => {
                const query = self.query_buf[0..self.query_len];
                var count: usize = 0;
                for (self.file_list.items) |f| {
                    if (query.len == 0 or std.ascii.indexOfIgnoreCase(f, query) != null) {
                        if (count == self.selected_idx) {
                            self.hide();
                            return .{ .select_file = f };
                        }
                        count += 1;
                    }
                }
                self.hide();
                return .close;
            },
            .live_grep => {
                if (self.grep_list.items.len > 0 and self.selected_idx < self.grep_list.items.len) {
                    const match = self.grep_list.items[self.selected_idx];
                    const path = if (std.mem.indexOfScalar(u8, match, ':')) |pos|
                        match[0..pos]
                    else
                        match;
                    self.hide();
                    return .{ .select_file = path };
                }
                self.hide();
                return .close;
            },
        }
    }

    // Regular typed character input
    if (utf8_text.len > 0 and utf8_text[0] >= 32 and utf8_text[0] < 127) {
        if (self.query_len < self.query_buf.len) {
            self.query_buf[self.query_len] = utf8_text[0];
            self.query_len += 1;
            self.selected_idx = 0;
            if (self.mode == .live_grep) {
                self.runLiveGrep(self.query_buf[0..self.query_len]) catch {};
            }
            self.render();
            self.commit() catch {};
        }
    }

    return .none;
}

fn getItemCount(self: *CommandPalette) usize {
    switch (self.mode) {
        .menu => return menu_items.len,
        .file_search => {
            const query = self.query_buf[0..self.query_len];
            var count: usize = 0;
            for (self.file_list.items) |f| {
                if (query.len == 0 or std.ascii.indexOfIgnoreCase(f, query) != null) count += 1;
            }
            return count;
        },
        .live_grep => return self.grep_list.items.len,
    }
}

pub fn render(self: *CommandPalette) void {
    const bg: u8 = 8; // Dark theme popup background
    const fg: u8 = 15; // Bright white foreground

    // Fill background
    for (self.cells) |*c| {
        c.* = CompactCell.ascii(' ', fg, bg);
    }

    // Border box
    var col: u32 = 0;
    while (col < self.cols) : (col += 1) {
        self.cells[col] = CompactCell.ascii('-', 6, bg);
        self.cells[(self.rows - 1) * self.cols + col] = CompactCell.ascii('-', 6, bg);
    }
    var row: u32 = 0;
    while (row < self.rows) : (row += 1) {
        self.cells[row * self.cols] = CompactCell.ascii('|', 6, bg);
        self.cells[row * self.cols + self.cols - 1] = CompactCell.ascii('|', 6, bg);
    }
    self.cells[0] = CompactCell.ascii('+', 6, bg);
    self.cells[self.cols - 1] = CompactCell.ascii('+', 6, bg);
    self.cells[(self.rows - 1) * self.cols] = CompactCell.ascii('+', 6, bg);
    self.cells[(self.rows - 1) * self.cols + self.cols - 1] = CompactCell.ascii('+', 6, bg);

    // Title & query header
    switch (self.mode) {
        .menu => {
            self.writeString(2, 0, "[ == PALETTE (drag header) == ]", 3, bg, true);
            self.writeString(2, 1, "> Filter: ", 7, bg, false);
            self.writeString(12, 1, self.query_buf[0..self.query_len], 15, bg, true);
            self.writeString(12 + @as(u32, @intCast(self.query_len)), 1, "_", 2, bg, true);
        },
        .file_search => {
            self.writeString(2, 0, "[ == FILE SEARCH == ]", 2, bg, true);
            self.writeString(2, 1, "> Search: ", 7, bg, false);
            self.writeString(12, 1, self.query_buf[0..self.query_len], 15, bg, true);
            self.writeString(12 + @as(u32, @intCast(self.query_len)), 1, "_", 2, bg, true);
        },
        .live_grep => {
            self.writeString(2, 0, "[ == LIVE GREP == ]", 4, bg, true);
            self.writeString(2, 1, "> Pattern: ", 7, bg, false);
            self.writeString(13, 1, self.query_buf[0..self.query_len], 15, bg, true);
            self.writeString(13 + @as(u32, @intCast(self.query_len)), 1, "_", 4, bg, true);
        },
    }

    // Divider line
    col = 1;
    while (col < self.cols - 1) : (col += 1) {
        self.cells[2 * self.cols + col] = CompactCell.ascii('-', 0, bg);
    }

    // List items
    const start_row: u32 = 3;
    const max_rows: u32 = self.rows - 4;

    switch (self.mode) {
        .menu => {
            for (menu_items, 0..) |item, i| {
                if (i >= max_rows) break;
                const r = start_row + @as(u32, @intCast(i));
                const is_sel = (i == self.selected_idx);
                const item_fg: u8 = if (is_sel) 0 else 15;
                const item_bg: u8 = if (is_sel) 6 else bg;

                // Selection highlight span
                col = 2;
                while (col < self.cols - 2) : (col += 1) {
                    self.cells[r * self.cols + col] = CompactCell.ascii(' ', item_fg, item_bg);
                }

                self.writeString(3, r, item.name, item_fg, item_bg, is_sel);
                self.writeString(20, r, item.desc, if (is_sel) 0 else 7, item_bg, false);
            }
        },
        .file_search => {
            const query = self.query_buf[0..self.query_len];
            var match_idx: usize = 0;
            var render_idx: usize = 0;
            const scroll_offset = if (self.selected_idx >= max_rows) self.selected_idx - max_rows + 1 else 0;

            for (self.file_list.items) |f| {
                if (query.len == 0 or std.ascii.indexOfIgnoreCase(f, query) != null) {
                    if (match_idx >= scroll_offset and render_idx < max_rows) {
                        const r = start_row + @as(u32, @intCast(render_idx));
                        const is_sel = (match_idx == self.selected_idx);
                        const item_fg: u8 = if (is_sel) 0 else 2;
                        const item_bg: u8 = if (is_sel) 2 else bg;

                        col = 2;
                        while (col < self.cols - 2) : (col += 1) {
                            self.cells[r * self.cols + col] = CompactCell.ascii(' ', item_fg, item_bg);
                        }

                        self.writeString(3, r, f, item_fg, item_bg, is_sel);
                        render_idx += 1;
                    }
                    match_idx += 1;
                }
            }

            if (match_idx == 0) {
                self.writeString(3, start_row, "(no matching files)", 7, bg, false);
            }
        },
        .live_grep => {
            if (self.grep_list.items.len == 0) {
                if (self.query_len == 0) {
                    self.writeString(3, start_row, "(type characters to search lines across project)", 7, bg, false);
                } else {
                    self.writeString(3, start_row, "(no grep matches found)", 7, bg, false);
                }
            } else {
                const scroll_offset = if (self.selected_idx >= max_rows) self.selected_idx - max_rows + 1 else 0;
                for (self.grep_list.items[scroll_offset..], 0..) |g, i| {
                    if (i >= max_rows) break;
                    const r = start_row + @as(u32, @intCast(i));
                    const actual_idx = scroll_offset + i;
                    const is_sel = (actual_idx == self.selected_idx);
                    const item_fg: u8 = if (is_sel) 0 else 15;
                    const item_bg: u8 = if (is_sel) 4 else bg;

                    col = 2;
                    while (col < self.cols - 2) : (col += 1) {
                        self.cells[r * self.cols + col] = CompactCell.ascii(' ', item_fg, item_bg);
                    }

                    self.writeString(3, r, g, item_fg, item_bg, is_sel);
                }
            }
        },
    }

    // Footer
    const footer_row = self.rows - 1;
    self.writeString(2, footer_row, "[ Enter: Select | Esc: Close ]", 7, bg, false);
}

fn writeString(self: *CommandPalette, x: u32, y: u32, str: []const u8, fg: u8, bg: u8, bold: bool) void {
    if (y >= self.rows) return;
    var it = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
    var c: u32 = x;
    while (it.nextCodepoint()) |cp| {
        if (c >= self.cols - 1) break;
        self.cells[y * self.cols + c] = .{
            .codepoint = cp,
            .fg_color = fg,
            .bg_color = bg,
            .flags = .{ .bold = bold },
        };
        c += 1;
    }
}

pub fn commit(self: *CommandPalette) !void {
    const raw_bytes = std.mem.sliceAsBytes(self.cells);
    const buf = try self.client.createCellBuffer(self.cols, self.rows, .compact_v1, raw_bytes);
    self.surface.attach(buf, 0, 0);
    self.surface.damage(0, 0, @intCast(self.cols), @intCast(self.rows));
    self.surface.commit();
}
