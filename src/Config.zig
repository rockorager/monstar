//! Configuration: a flat `key = value` file, one entry per line, with
//! `#` comments. Located at $XDG_CONFIG_HOME/monstar/config (falling
//! back to ~/.config/monstar/config). Missing file means defaults;
//! invalid lines warn and keep their default.

const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");

const log = std.log.scoped(.config);

fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

pub const default_app_id = "dev.rockorager.monstar";
pub const default_theme: Theme = .dark;

pub const Theme = enum { light, dark };

pub const ThemeColors = struct {
    background: vt.color.RGB,
    foreground: vt.color.RGB,
    cursor_color: vt.color.RGB,
    selection_background: vt.color.RGB,
    selection_foreground: vt.color.RGB,
    palette: [16]vt.color.RGB,
};

pub const light_theme: ThemeColors = .{
    .background = .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    .foreground = .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
    .cursor_color = .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
    .selection_background = .{ .r = 0xc9, .g = 0xe3, .b = 0xff },
    .selection_foreground = .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
    .palette = .{
        .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
        .{ .r = 0xad, .g = 0x41, .b = 0x43 },
        .{ .r = 0x1c, .g = 0x80, .b = 0x5b },
        .{ .r = 0x96, .g = 0x72, .b = 0x22 },
        .{ .r = 0x26, .g = 0x5e, .b = 0xb2 },
        .{ .r = 0x76, .g = 0x53, .b = 0x9c },
        .{ .r = 0x12, .g = 0x7f, .b = 0x76 },
        .{ .r = 0x9a, .g = 0x9b, .b = 0xa0 },
        .{ .r = 0x75, .g = 0x77, .b = 0x7b },
        .{ .r = 0x82, .g = 0x2d, .b = 0x2f },
        .{ .r = 0x0e, .g = 0x5e, .b = 0x42 },
        .{ .r = 0x6e, .g = 0x53, .b = 0x13 },
        .{ .r = 0x19, .g = 0x45, .b = 0x87 },
        .{ .r = 0x58, .g = 0x3c, .b = 0x75 },
        .{ .r = 0x04, .g = 0x5e, .b = 0x57 },
        .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    },
};

pub const dark_theme: ThemeColors = .{
    .background = .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
    .foreground = .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    .cursor_color = .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    .selection_background = .{ .r = 0x19, .g = 0x45, .b = 0x87 },
    .selection_foreground = .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    .palette = .{
        .{ .r = 0x0c, .g = 0x0e, .b = 0x12 },
        .{ .r = 0xff, .g = 0x8e, .b = 0x8c },
        .{ .r = 0x71, .g = 0xd2, .b = 0xa7 },
        .{ .r = 0xee, .g = 0xc5, .b = 0x74 },
        .{ .r = 0x6c, .g = 0xac, .b = 0xff },
        .{ .r = 0xc5, .g = 0x9e, .b = 0xf3 },
        .{ .r = 0x6e, .g = 0xd2, .b = 0xc7 },
        .{ .r = 0xbb, .g = 0xbc, .b = 0xc0 },
        .{ .r = 0x75, .g = 0x77, .b = 0x7b },
        .{ .r = 0xff, .g = 0xa6, .b = 0xa2 },
        .{ .r = 0x90, .g = 0xde, .b = 0xb9 },
        .{ .r = 0xf3, .g = 0xd1, .b = 0x8f },
        .{ .r = 0x8a, .g = 0xc0, .b = 0xff },
        .{ .r = 0xd3, .g = 0xb3, .b = 0xfb },
        .{ .r = 0x8d, .g = 0xdd, .b = 0xd3 },
        .{ .r = 0xf5, .g = 0xf6, .b = 0xfa },
    },
};

pub const default_background: vt.color.RGB = dark_theme.background;
pub const default_foreground: vt.color.RGB = dark_theme.foreground;
pub const default_cursor_color: vt.color.RGB = dark_theme.cursor_color;
pub const default_selection_background: vt.color.RGB = dark_theme.selection_background;
pub const default_selection_foreground: vt.color.RGB = dark_theme.selection_foreground;
pub const default_palette: [16]vt.color.RGB = dark_theme.palette;

/// Wayland app-id and desktop-entry hint for desktop integration.
app_id: [:0]const u8 = default_app_id,
font_family: [:0]const u8 = "monospace",
/// Font size in logical pixels (scaled by the output's fractional scale).
font_size: u31 = 16,
/// Shell to run; unset falls back to $SHELL, then /bin/sh.
shell: ?[:0]const u8 = null,
/// Shell command that receives the last semantic command output on stdin.
pipe_command_output: ?[:0]const u8 = null,
scrollback: usize = 10_000,
wheel_scroll_lines: u31 = 3,
/// Frame timing readout: `overlay` draws the previous frame's CPU
/// cost in the top-right corner, `log` writes per-frame timings to
/// stderr, `both` does both.
frame_timer: FrameTimer = .off,

theme: Theme = default_theme,
background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?vt.color.RGB = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
palette: [16]?vt.color.RGB = @splat(null),

pub const FrameTimer = enum { off, overlay, log, both };

/// Load the default config file, if any. Strings are allocated in `arena`
/// and live as long as it does.
pub fn load(arena: std.mem.Allocator, environ: std.process.Environ) Config {
    const path = path: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |base| {
            break :path std.fmt.allocPrintSentinel(arena, "{s}/monstar/config", .{base}, 0) catch return .{};
        }
        if (environ.getPosix("HOME")) |home| {
            break :path std.fmt.allocPrintSentinel(arena, "{s}/.config/monstar/config", .{home}, 0) catch return .{};
        }
        return .{};
    };

    return loadPath(arena, path);
}

/// Load a specific config file. Missing or unreadable file means defaults.
pub fn loadPath(arena: std.mem.Allocator, path: [:0]const u8) Config {
    const text = readFile(arena, path) orelse return .{};
    log.info("loaded {s}", .{path});
    return parse(arena, text);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warn("line {d}: missing '=', ignoring: {s}", .{ line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) {
            warn("line {d}: empty value for '{s}', ignoring", .{ line_no, key });
            continue;
        }

        config.set(arena, key, value) catch {
            warn("line {d}: invalid value for '{s}': {s}", .{ line_no, key, value });
        };
    }
    return config;
}

pub const SetError = error{ InvalidValue, UnknownKey, OutOfMemory };

pub fn applyOverride(self: *Config, arena: std.mem.Allocator, text: []const u8) SetError!void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidValue;
    const key = std.mem.trim(u8, text[0..eq], " \t");
    const value = std.mem.trim(u8, text[eq + 1 ..], " \t");
    if (key.len == 0 or value.len == 0) return error.InvalidValue;
    try self.set(arena, key, value);
}

pub fn set(self: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) SetError!void {
    if (std.mem.eql(u8, key, "app-id")) {
        self.app_id = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "font-family")) {
        self.font_family = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "font-size")) {
        const size = std.fmt.parseInt(u31, value, 10) catch return error.InvalidValue;
        if (size == 0 or size > 512) return error.InvalidValue;
        self.font_size = size;
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "pipe-command-output")) {
        self.pipe_command_output = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "scrollback")) {
        self.scrollback = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wheel-scroll-lines")) {
        const lines = std.fmt.parseInt(u31, value, 10) catch return error.InvalidValue;
        if (lines == 0) return error.InvalidValue;
        self.wheel_scroll_lines = lines;
    } else if (std.mem.eql(u8, key, "frame-timer")) {
        self.frame_timer = std.meta.stringToEnum(FrameTimer, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "theme")) {
        self.theme = std.meta.stringToEnum(Theme, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "background")) {
        self.background = try parseColor(value);
    } else if (std.mem.eql(u8, key, "foreground")) {
        self.foreground = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        self.cursor_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-background")) {
        self.selection_background = try parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-foreground")) {
        self.selection_foreground = try parseColor(value);
    } else if (std.mem.startsWith(u8, key, "palette")) {
        const idx = std.fmt.parseInt(u8, key["palette".len..], 10) catch return error.UnknownKey;
        if (idx >= 16) return error.UnknownKey;
        self.palette[idx] = try parseColor(value);
    } else {
        warn("unknown key '{s}', ignoring", .{key});
    }
}

/// "#RRGGBB" or "RRGGBB".
fn parseColor(value: []const u8) error{InvalidValue}!vt.color.RGB {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return error.InvalidValue;
    const num = std.fmt.parseInt(u24, hex, 16) catch return error.InvalidValue;
    return .{
        .r = @intCast(num >> 16),
        .g = @intCast((num >> 8) & 0xff),
        .b = @intCast(num & 0xff),
    };
}

pub fn themeColors(theme: Theme) ThemeColors {
    return switch (theme) {
        .light => light_theme,
        .dark => dark_theme,
    };
}

pub fn effectiveSelectionBackground(self: *const Config) vt.color.RGB {
    return self.selection_background orelse themeColors(self.theme).selection_background;
}

pub fn effectiveSelectionForeground(self: *const Config) vt.color.RGB {
    return self.selection_foreground orelse themeColors(self.theme).selection_foreground;
}

/// The terminal color options this config describes: config colors form
/// the *default* layer, so OSC 10/11/12/4 can still override and reset.
pub fn terminalColors(self: *const Config) vt.Terminal.Colors {
    var palette = vt.color.default;
    const themed = themeColors(self.theme);
    for (themed.palette, 0..) |rgb, i| {
        palette[i] = rgb;
    }
    for (self.palette, 0..) |entry, i| {
        if (entry) |rgb| palette[i] = rgb;
    }
    return .{
        .background = .init(self.background orelse themed.background),
        .foreground = .init(self.foreground orelse themed.foreground),
        .cursor = .init(self.cursor_color orelse themed.cursor_color),
        .palette = .init(palette),
    };
}

fn readFile(arena: std.mem.Allocator, path: [:0]const u8) ?[]const u8 {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    const max_size = 1024 * 1024;
    var buf = std.ArrayList(u8).initCapacity(arena, 4096) catch return null;
    while (buf.items.len < max_size) {
        buf.ensureUnusedCapacity(arena, 4096) catch return null;
        const dest = buf.unusedCapacitySlice();
        const n = std.posix.read(fd, dest) catch return null;
        if (n == 0) break;
        buf.items.len += n;
    }
    return buf.items;
}

test "defaults" {
    const config: Config = .{};
    try std.testing.expectEqualStrings(default_app_id, config.app_id);
    try std.testing.expectEqualStrings("monospace", config.font_family);
    try std.testing.expectEqual(@as(u31, 16), config.font_size);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.shell);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.pipe_command_output);
    try std.testing.expectEqual(default_theme, config.theme);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.foreground);
    try std.testing.expectEqual(default_selection_background, config.effectiveSelectionBackground());
    try std.testing.expectEqual(default_selection_foreground, config.effectiveSelectionForeground());
}

test "parse config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\# a comment
        \\app-id = com.example.scratchpad
        \\font-family = Fira Code
        \\font-size = 14
        \\shell = /usr/bin/fish
        \\pipe-command-output = cat > /tmp/monstar-output
        \\scrollback = 5000
        \\wheel-scroll-lines = 5
        \\background = #1a1b26
        \\foreground = c0caf5
        \\palette1 = #f7768e
        \\
        \\bogus-key = whatever
        \\font-size = not-a-number
    );

    try std.testing.expectEqualStrings("com.example.scratchpad", config.app_id);
    try std.testing.expectEqualStrings("Fira Code", config.font_family);
    // invalid re-assignment keeps the previous valid value
    try std.testing.expectEqual(@as(u31, 14), config.font_size);
    try std.testing.expectEqualStrings("/usr/bin/fish", config.shell.?);
    try std.testing.expectEqualStrings("cat > /tmp/monstar-output", config.pipe_command_output.?);
    try std.testing.expectEqual(@as(usize, 5000), config.scrollback);
    try std.testing.expectEqual(@as(u31, 5), config.wheel_scroll_lines);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf7, .g = 0x76, .b = 0x8e }, config.palette[1].?);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.palette[2]);
}

test "terminal colors from config" {
    var config: Config = .{};
    config.background = .{ .r = 1, .g = 2, .b = 3 };
    const colors = config.terminalColors();
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(default_foreground, colors.foreground.get().?);
    try std.testing.expectEqual(default_cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(default_palette[0], colors.palette.current[0]);
    try std.testing.expectEqual(default_palette[15], colors.palette.current[15]);
}

test "dark theme" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\theme = dark
    );

    const colors = config.terminalColors();
    try std.testing.expectEqual(Theme.dark, config.theme);
    try std.testing.expectEqual(dark_theme.background, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(dark_theme.cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(dark_theme.palette[1], colors.palette.current[1]);
    try std.testing.expectEqual(dark_theme.selection_background, config.effectiveSelectionBackground());
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground());
}

test "theme does not replace explicit color overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\background = #010203
        \\palette1 = #040506
        \\selection-background = #070809
        \\theme = dark
    );

    const colors = config.terminalColors();
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, colors.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveSelectionBackground());
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground());
}
