//! Stationary 1-row command launcher prompt surface for tc-shell.
//! Anchored at the top of the viewport (row 0).
//! Features line editing, cursor navigation, command history, and focus management.

const PromptSurface = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl_client = wayland.client;
const wl = wl_client.wl;
const zterm = wl_client.zterm;
const abi = @import("../tc/abi.zig");
const CompactCell = abi.CompactCell;
const CompactFlags = abi.CompactFlags;
const Client = @import("../tc/Client.zig");

allocator: std.mem.Allocator,
client: *Client,
surface: *wl.Surface,
grid_surface: *zterm.GridSurfaceV1,

cols: u32,
rows: u32 = 1,
cells: []CompactCell,

// Editing buffer (Zig 0.16 unmanaged style)
input_buf: std.ArrayList(u8) = .empty,
cursor_pos: usize = 0, // byte / character offset in input_buf
focused: bool = true,

// History
history: std.ArrayList([]const u8) = .empty,
history_idx: ?usize = null,
saved_draft: ?[]const u8 = null,

// Hostname banner for prompt (e.g., "monstar:tc> ")
hostname_banner: []const u8,

pub fn init(
    allocator: std.mem.Allocator,
    client: *Client,
    cols: u32,
) !*PromptSurface {
    const comp = client.compositor orelse return error.NoCompositor;
    const zcomp = client.zterm_compositor orelse return error.NoZtermCompositor;

    const surf = try comp.createSurface();
    errdefer surf.destroy();

    const grid = try zcomp.getGridSurface(surf);
    grid.setTitle("tc-shell:prompt");
    grid.setPosition(0, 0);

    const rows: u32 = 1;
    const cell_count = cols * rows;
    const cells = try allocator.alloc(CompactCell, cell_count);
    errdefer allocator.free(cells);

    for (cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, 0);
    }

    // Determine host banner
    var host_buf: [64]u8 = undefined;
    const host = std.posix.gethostname(&host_buf) catch "localhost";
    const banner = try std.fmt.allocPrint(allocator, "{s}:tc> ", .{host});
    errdefer allocator.free(banner);

    const self = try allocator.create(PromptSurface);
    self.* = .{
        .allocator = allocator,
        .client = client,
        .surface = surf,
        .grid_surface = grid,
        .cols = cols,
        .rows = rows,
        .cells = cells,
        .input_buf = .empty,
        .history = .empty,
        .hostname_banner = banner,
    };

    self.render();
    try self.commit();

    return self;
}

pub fn deinit(self: *PromptSurface) void {
    self.allocator.free(self.hostname_banner);
    self.input_buf.deinit(self.allocator);
    if (self.saved_draft) |d| self.allocator.free(d);
    for (self.history.items) |cmd| {
        self.allocator.free(cmd);
    }
    self.history.deinit(self.allocator);
    self.allocator.free(self.cells);
    self.grid_surface.destroy();
    self.surface.destroy();
    self.allocator.destroy(self);
}

pub fn resize(self: *PromptSurface, new_cols: u32) !void {
    if (new_cols == self.cols) return;
    self.cols = new_cols;
    self.cells = try self.allocator.realloc(self.cells, new_cols * self.rows);
    self.render();
    try self.commit();
}

pub fn setFocus(self: *PromptSurface, focused: bool) void {
    if (self.focused != focused) {
        self.focused = focused;
        self.render();
        self.commit() catch {};
    }
}

pub fn render(self: *PromptSurface) void {
    const bg_color: u8 = if (self.focused) 8 else 0;
    const fg_color: u8 = if (self.focused) 15 else 7;
    const banner_fg: u8 = if (self.focused) 14 else 6;

    for (self.cells) |*cell| {
        cell.* = CompactCell.ascii(' ', fg_color, bg_color);
    }

    var col: usize = 0;

    // 1. Draw hostname banner
    for (self.hostname_banner) |byte| {
        if (col >= self.cols) break;
        var cell = CompactCell.ascii(byte, banner_fg, bg_color);
        cell.flags.bold = true;
        self.cells[col] = cell;
        col += 1;
    }

    // 2. Draw user input
    for (self.input_buf.items, 0..) |byte, idx| {
        if (col >= self.cols) break;
        var cell = CompactCell.ascii(byte, fg_color, bg_color);
        if (self.focused and idx == self.cursor_pos) {
            cell.flags.reverse = true;
        }
        self.cells[col] = cell;
        col += 1;
    }

    // 3. Draw cursor if at end of input
    if (self.focused and self.cursor_pos == self.input_buf.items.len and col < self.cols) {
        var cell = CompactCell.ascii(' ', fg_color, bg_color);
        cell.flags.reverse = true;
        self.cells[col] = cell;
    }
}

pub fn commit(self: *PromptSurface) !void {
    const cell_bytes = std.mem.sliceAsBytes(self.cells);
    const buf = try self.client.createCellBuffer(self.cols, self.rows, .compact_v1, cell_bytes);
    try self.client.commitBuffer(buf, self.cols, self.rows);
    _ = self.client.display.flush();
}

/// Returns an owned slice of the command if Enter was pressed, otherwise null.
pub fn handleKey(self: *PromptSurface, key_name: []const u8, utf8: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, key_name, "Enter") or (utf8.len == 1 and utf8[0] == '\r')) {
        const cmd = std.mem.trim(u8, self.input_buf.items, " \t\r\n");
        if (cmd.len == 0) return null;

        const owned_cmd = try self.allocator.dupe(u8, cmd);

        // Add to history if not duplicate of last
        if (self.history.items.len == 0 or !std.mem.eql(u8, self.history.items[self.history.items.len - 1], owned_cmd)) {
            const hist_copy = try self.allocator.dupe(u8, owned_cmd);
            try self.history.append(self.allocator, hist_copy);
        }

        self.input_buf.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.history_idx = null;
        if (self.saved_draft) |d| {
            self.allocator.free(d);
            self.saved_draft = null;
        }

        self.render();
        try self.commit();
        return owned_cmd;
    }

    if (std.mem.eql(u8, key_name, "BackSpace") or (utf8.len == 1 and utf8[0] == 0x08)) {
        if (self.cursor_pos > 0 and self.input_buf.items.len > 0) {
            _ = self.input_buf.orderedRemove(self.cursor_pos - 1);
            self.cursor_pos -= 1;
            self.render();
            try self.commit();
        }
        return null;
    }

    if (std.mem.eql(u8, key_name, "Delete") or (utf8.len == 1 and utf8[0] == 0x7F)) {
        if (self.cursor_pos < self.input_buf.items.len) {
            _ = self.input_buf.orderedRemove(self.cursor_pos);
            self.render();
            try self.commit();
        }
        return null;
    }

    if (std.mem.eql(u8, key_name, "Left")) {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
            self.render();
            try self.commit();
        }
        return null;
    }

    if (std.mem.eql(u8, key_name, "Right")) {
        if (self.cursor_pos < self.input_buf.items.len) {
            self.cursor_pos += 1;
            self.render();
            try self.commit();
        }
        return null;
    }

    if (std.mem.eql(u8, key_name, "Home")) {
        self.cursor_pos = 0;
        self.render();
        try self.commit();
        return null;
    }

    if (std.mem.eql(u8, key_name, "End")) {
        self.cursor_pos = self.input_buf.items.len;
        self.render();
        try self.commit();
        return null;
    }

    // Up: History backward
    if (std.mem.eql(u8, key_name, "Up")) {
        if (self.history.items.len == 0) return null;

        if (self.history_idx == null) {
            if (self.saved_draft) |d| self.allocator.free(d);
            self.saved_draft = try self.allocator.dupe(u8, self.input_buf.items);
            self.history_idx = self.history.items.len - 1;
        } else if (self.history_idx.? > 0) {
            self.history_idx.? -= 1;
        }

        if (self.history_idx) |idx| {
            self.input_buf.clearRetainingCapacity();
            try self.input_buf.appendSlice(self.allocator, self.history.items[idx]);
            self.cursor_pos = self.input_buf.items.len;
            self.render();
            try self.commit();
        }
        return null;
    }

    // Down: History forward
    if (std.mem.eql(u8, key_name, "Down")) {
        if (self.history_idx) |idx| {
            if (idx + 1 < self.history.items.len) {
                self.history_idx = idx + 1;
                self.input_buf.clearRetainingCapacity();
                try self.input_buf.appendSlice(self.allocator, self.history.items[idx + 1]);
                self.cursor_pos = self.input_buf.items.len;
            } else {
                self.history_idx = null;
                self.input_buf.clearRetainingCapacity();
                if (self.saved_draft) |d| {
                    try self.input_buf.appendSlice(self.allocator, d);
                }
                self.cursor_pos = self.input_buf.items.len;
            }
            self.render();
            try self.commit();
        }
        return null;
    }

    // Printable character input
    if (utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127) {
        try self.input_buf.insertSlice(self.allocator, self.cursor_pos, utf8);
        self.cursor_pos += utf8.len;
        self.render();
        try self.commit();
        return null;
    }

    return null;
}
