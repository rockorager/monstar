//! Stationary 1-row command launcher prompt surface for tc-shell.
//! Anchored at the top of the viewport (row 0).
//! Features Fish-grade line editing:
//! - Real-time syntax highlighting (commands, flags, strings, pipes, block tags).
//! - Inline dimmed auto-suggestions from history (ghost text).
//! - Cursor-anchored Tab completion popup overlay.

const PromptSurface = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wayland = @import("wayland");
const wl_client = wayland.client;
const wl = wl_client.wl;
const zterm = wl_client.zterm;
const abi = @import("../tc/abi.zig");
const CompactCell = abi.CompactCell;
const CompactFlags = abi.CompactFlags;
const Client = @import("../tc/Client.zig");
const SessionState = @import("SessionState.zig");

pub const SyntaxColor = struct {
    fg: u8,
    bold: bool = false,
};

allocator: std.mem.Allocator,
client: *Client,
surface: *wl.Surface,
grid_surface: *zterm.GridSurfaceV1,
session: ?*SessionState = null,

cols: u32,
rows: u32 = 1,
cells: []CompactCell,

// Editing buffer (Zig 0.16 unmanaged style)
input_buf: std.ArrayList(u8) = .empty,
cursor_pos: usize = 0, // byte offset in input_buf
focused: bool = true,

// History
history: std.ArrayList([]const u8) = .empty,
history_idx: ?usize = null,
saved_draft: ?[]const u8 = null,

// Hostname banner for prompt (e.g., "monstar:tc> ")
hostname_banner: []const u8,

// Floating Tab completion state
completion_active: bool = false,
completion_items: std.ArrayList([]const u8) = .empty,
completion_selected: usize = 0,
completion_token_start: usize = 0,

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
        .session = null,
        .cols = cols,
        .rows = rows,
        .cells = cells,
        .input_buf = .empty,
        .history = .empty,
        .hostname_banner = banner,
        .completion_active = false,
        .completion_items = .empty,
        .completion_selected = 0,
        .completion_token_start = 0,
    };

    self.render();
    try self.commit();

    return self;
}

pub fn deinit(self: *PromptSurface) void {
    self.clearCompletions();
    self.completion_items.deinit(self.allocator);
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

pub fn setSession(self: *PromptSurface, session: *SessionState) void {
    self.session = session;
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

pub fn setInput(self: *PromptSurface, text: []const u8) !void {
    self.input_buf.clearRetainingCapacity();
    try self.input_buf.appendSlice(self.allocator, text);
    self.cursor_pos = self.input_buf.items.len;
    self.dismissCompletion();
    self.render();
    try self.commit();
}

pub fn getCursorScreenCol(self: *const PromptSurface) usize {
    return self.hostname_banner.len + self.cursor_pos;
}

fn isBuiltinName(name: []const u8) bool {
    const builtins = [_][]const u8{
        "cd",   "collapse", "expand", "fullscreen", "fg",    "edit",
        "run",  "rm",       "copy",   "view",       "clear", "exit",
        "quit", "export",   "unset",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

fn isExecutable(name: []const u8) bool {
    if (name.len == 0) return false;
    if (isBuiltinName(name)) return true;

    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return false;
        return linux.access(name_z.ptr, linux.X_OK) == 0;
    }

    const common_paths = [_][]const u8{
        "/usr/bin", "/bin", "/usr/local/bin",
    };
    for (common_paths) |p| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ p, name }) catch continue;
        if (linux.access(full.ptr, linux.X_OK) == 0) return true;
    }
    return false;
}

pub fn getGhostSuggestion(self: *PromptSurface) ?[]const u8 {
    if (self.input_buf.items.len == 0) return null;
    var i = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.history.items[i];
        if (std.mem.startsWith(u8, entry, self.input_buf.items) and entry.len > self.input_buf.items.len) {
            return entry[self.input_buf.items.len..];
        }
    }
    return null;
}

pub fn render(self: *PromptSurface) void {
    const bg_color: u8 = 0; // standard shell theme
    const banner_fg: u8 = 14; // bright cyan

    for (self.cells) |*cell| {
        cell.* = CompactCell.ascii(' ', 7, bg_color);
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

    // 2. Syntax highlight input buffer
    const input = self.input_buf.items;
    var colors_buf: [256]SyntaxColor = undefined;
    const colors = if (input.len <= colors_buf.len) colors_buf[0..input.len] else null;

    if (colors) |col_slice| {
        @memset(col_slice, .{ .fg = 15, .bold = false });
        var i: usize = 0;
        var token_idx: usize = 0;

        while (i < input.len) {
            if (std.ascii.isWhitespace(input[i])) {
                i += 1;
                continue;
            }

            const start = i;

            // Quoted string
            if (input[i] == '"' or input[i] == '\'') {
                const quote = input[i];
                i += 1;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                if (i < input.len and input[i] == quote) i += 1;
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = 11, .bold = false }; // Yellow
                }
                token_idx += 1;
                continue;
            }

            // Pipe / redirection
            if (input[i] == '|' or input[i] == '>' or input[i] == '<') {
                while (i < input.len and (input[i] == '|' or input[i] == '>' or input[i] == '<' or input[i] == '&')) : (i += 1) {}
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = 13, .bold = true }; // Magenta
                }
                token_idx = 0;
                continue;
            }

            // Word
            while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '|' and input[i] != '>' and input[i] != '<') : (i += 1) {}
            const word = input[start..i];

            if (token_idx == 0) {
                const is_ok = isExecutable(word);
                const fg: u8 = if (is_ok) 10 else 9; // Green or Red
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = fg, .bold = true };
                }
            } else if (std.mem.startsWith(u8, word, "-")) {
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = 14, .bold = false }; // Cyan
                }
            } else if (std.mem.startsWith(u8, word, "$")) {
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = 13, .bold = true }; // Magenta
                }
            } else {
                for (start..i) |idx| {
                    col_slice[idx] = .{ .fg = 15, .bold = false }; // White
                }
            }
            token_idx += 1;
        }

        // Render colorized text
        for (input, 0..) |byte, idx| {
            if (col >= self.cols) break;
            const sc = col_slice[idx];
            var cell = CompactCell.ascii(byte, sc.fg, bg_color);
            cell.flags.bold = sc.bold;
            if (idx == self.cursor_pos) {
                cell.flags.reverse = true;
            }
            self.cells[col] = cell;
            col += 1;
        }
    } else {
        // Fallback for massive inputs
        for (input, 0..) |byte, idx| {
            if (col >= self.cols) break;
            var cell = CompactCell.ascii(byte, 15, bg_color);
            if (idx == self.cursor_pos) cell.flags.reverse = true;
            self.cells[col] = cell;
            col += 1;
        }
    }

    // 3. Draw cursor if at end of input
    const cursor_at_end = self.cursor_pos == self.input_buf.items.len;
    if (cursor_at_end and col < self.cols) {
        var cell = CompactCell.ascii(' ', 15, bg_color);
        cell.flags.reverse = true;
        self.cells[col] = cell;
    }

    // 4. Ghost text auto-suggestions from history
    if (self.getGhostSuggestion()) |ghost| {
        var ghost_col = if (cursor_at_end) col + 1 else col;
        for (ghost) |byte| {
            if (ghost_col >= self.cols) break;
            const cell = CompactCell.ascii(byte, 8, bg_color); // Dimmed / Dark Gray
            self.cells[ghost_col] = cell;
            ghost_col += 1;
        }
    }
}

pub fn commit(self: *PromptSurface) !void {
    const cell_bytes = std.mem.sliceAsBytes(self.cells);
    const buf = try self.client.createCellBuffer(self.cols, self.rows, .compact_v1, cell_bytes);
    try self.client.commitBuffer(buf, self.cols, self.rows);
    _ = self.client.display.flush();
}

fn clearCompletions(self: *PromptSurface) void {
    for (self.completion_items.items) |item| {
        self.allocator.free(item);
    }
    self.completion_items.clearRetainingCapacity();
    self.completion_active = false;
    self.completion_selected = 0;
}

pub fn dismissCompletion(self: *PromptSurface) void {
    self.clearCompletions();
}

fn triggerCompletion(self: *PromptSurface) !void {
    self.clearCompletions();

    // Find token boundary before cursor
    const input = self.input_buf.items;
    var start = self.cursor_pos;
    while (start > 0 and !std.ascii.isWhitespace(input[start - 1])) : (start -= 1) {}
    self.completion_token_start = start;
    const token = input[start..self.cursor_pos];

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(self.allocator);

    // If starting with '$', match block tags
    if (std.mem.startsWith(u8, token, "$")) {
        const tags = [_][]const u8{ "$1", "$2", "$3", "$prev" };
        for (tags) |t| {
            if (std.mem.startsWith(u8, t, token)) {
                try matches.append(self.allocator, try self.allocator.dupe(u8, t));
            }
        }
    } else if (start == 0) {
        // Builtins
        const builtins = [_][]const u8{
            "cd",   "collapse", "expand", "fullscreen", "fg",    "edit",
            "run",  "rm",       "copy",   "view",       "clear", "exit",
            "quit", "export",   "unset",
        };
        for (builtins) |b| {
            if (std.mem.startsWith(u8, b, token)) {
                try matches.append(self.allocator, try self.allocator.dupe(u8, b));
            }
        }
    } else {
        // File / directory completions in cwd
        const cwd_path = if (self.session) |s| s.getCwd() else ".";
        const cwd_z = try self.allocator.dupeZ(u8, cwd_path);
        defer self.allocator.free(cwd_z);

        if (std.c.opendir(cwd_z.ptr)) |dir| {
            defer _ = std.c.closedir(dir);
            while (std.c.readdir(dir)) |entry| {
                const name = std.mem.sliceTo(&entry.name, 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (std.mem.startsWith(u8, name, token)) {
                    if (entry.type == 4) { // DT_DIR
                        const with_slash = try std.fmt.allocPrint(self.allocator, "{s}/", .{name});
                        try matches.append(self.allocator, with_slash);
                    } else {
                        try matches.append(self.allocator, try self.allocator.dupe(u8, name));
                    }
                }
            }
        }
    }

    if (matches.items.len == 1) {
        // Single match: complete inline immediately
        const m = matches.items[0];
        defer self.allocator.free(m);

        // Replace current token with match
        try self.input_buf.replaceRange(self.allocator, start, token.len, m);
        self.cursor_pos = start + m.len;
        self.render();
        try self.commit();
        return;
    }

    if (matches.items.len > 1) {
        // Multiple matches: show floating completion overlay
        self.completion_items = matches;
        self.completion_active = true;
        self.completion_selected = 0;
        self.render();
        try self.commit();
    }
}

pub fn applyCompletion(self: *PromptSurface) !void {
    if (!self.completion_active or self.completion_items.items.len == 0) return;
    const item = self.completion_items.items[self.completion_selected];
    const old_len = self.cursor_pos - self.completion_token_start;
    try self.input_buf.replaceRange(self.allocator, self.completion_token_start, old_len, item);
    self.cursor_pos = self.completion_token_start + item.len;
    self.clearCompletions();
    self.render();
    try self.commit();
}

/// Returns an owned slice of the command if Enter was pressed, otherwise null.
pub fn handleKey(self: *PromptSurface, key_name: []const u8, utf8: []const u8) !?[]const u8 {
    // Tab: Trigger or cycle autocompletion
    if (std.mem.eql(u8, key_name, "Tab") or (utf8.len == 1 and utf8[0] == '\t')) {
        if (self.completion_active and self.completion_items.items.len > 0) {
            self.completion_selected = (self.completion_selected + 1) % self.completion_items.items.len;
            self.render();
            try self.commit();
        } else {
            try self.triggerCompletion();
        }
        return null;
    }

    // Escape: Dismiss completion popup
    if (std.mem.eql(u8, key_name, "Escape") or (utf8.len == 1 and utf8[0] == 0x1B)) {
        if (self.completion_active) {
            self.dismissCompletion();
            self.render();
            try self.commit();
            return null;
        }
    }

    // Enter: Select completion or execute command
    if (std.mem.eql(u8, key_name, "Enter") or (utf8.len == 1 and utf8[0] == '\r')) {
        if (self.completion_active) {
            try self.applyCompletion();
            return null;
        }

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
        self.dismissCompletion();

        self.render();
        try self.commit();
        return owned_cmd;
    }

    // Down Arrow: Navigate completion menu or history forward
    if (std.mem.eql(u8, key_name, "Down")) {
        if (self.completion_active and self.completion_items.items.len > 0) {
            self.completion_selected = (self.completion_selected + 1) % self.completion_items.items.len;
            self.render();
            try self.commit();
            return null;
        }

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

    // Up Arrow: Navigate completion menu backward or history backward
    if (std.mem.eql(u8, key_name, "Up")) {
        if (self.completion_active and self.completion_items.items.len > 0) {
            if (self.completion_selected == 0) {
                self.completion_selected = self.completion_items.items.len - 1;
            } else {
                self.completion_selected -= 1;
            }
            self.render();
            try self.commit();
            return null;
        }

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

    // Right Arrow or Ctrl+F: accept ghost suggestion or move right
    if (std.mem.eql(u8, key_name, "Right")) {
        if (self.cursor_pos == self.input_buf.items.len) {
            if (self.getGhostSuggestion()) |ghost| {
                try self.input_buf.appendSlice(self.allocator, ghost);
                self.cursor_pos = self.input_buf.items.len;
                self.render();
                try self.commit();
                return null;
            }
        }
        if (self.cursor_pos < self.input_buf.items.len) {
            self.cursor_pos += 1;
            self.dismissCompletion();
            self.render();
            try self.commit();
        }
        return null;
    }

    // Backspace
    if (std.mem.eql(u8, key_name, "BackSpace") or (utf8.len == 1 and utf8[0] == 0x08)) {
        if (self.cursor_pos > 0 and self.input_buf.items.len > 0) {
            _ = self.input_buf.orderedRemove(self.cursor_pos - 1);
            self.cursor_pos -= 1;
            self.dismissCompletion();
            self.render();
            try self.commit();
        }
        return null;
    }

    // Delete
    if (std.mem.eql(u8, key_name, "Delete") or (utf8.len == 1 and utf8[0] == 0x7F)) {
        if (self.cursor_pos < self.input_buf.items.len) {
            _ = self.input_buf.orderedRemove(self.cursor_pos);
            self.dismissCompletion();
            self.render();
            try self.commit();
        }
        return null;
    }

    // Left Arrow
    if (std.mem.eql(u8, key_name, "Left")) {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
            self.dismissCompletion();
            self.render();
            try self.commit();
        }
        return null;
    }

    // Home
    if (std.mem.eql(u8, key_name, "Home")) {
        self.cursor_pos = 0;
        self.dismissCompletion();
        self.render();
        try self.commit();
        return null;
    }

    // End
    if (std.mem.eql(u8, key_name, "End")) {
        self.cursor_pos = self.input_buf.items.len;
        self.dismissCompletion();
        self.render();
        try self.commit();
        return null;
    }

    // Printable character input
    if (utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127) {
        try self.input_buf.insertSlice(self.allocator, self.cursor_pos, utf8);
        self.cursor_pos += utf8.len;
        self.dismissCompletion();
        self.render();
        try self.commit();
        return null;
    }

    return null;
}
