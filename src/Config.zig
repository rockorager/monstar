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
pub const default_theme: Theme = .system;

pub const Theme = enum { system, light, dark };

pub const WindowPadding = struct {
    first: u31 = 0,
    second: u31 = 0,
};

pub const ThemeColors = struct {
    background: vt.color.RGB,
    foreground: vt.color.RGB,
    cursor_color: vt.color.RGB,
    selection_background: vt.color.RGB,
    selection_foreground: vt.color.RGB,
    palette: [16]vt.color.RGB,
};

pub const light_theme: ThemeColors = .{
    .background = .{ .r = 0xf9, .g = 0xf9, .b = 0xfb },
    .foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .cursor_color = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .selection_background = .{ .r = 0xc2, .g = 0xe5, .b = 0xff },
    .selection_foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .palette = .{
        .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
        .{ .r = 0xce, .g = 0x2c, .b = 0x31 },
        .{ .r = 0x21, .g = 0x83, .b = 0x58 },
        .{ .r = 0xab, .g = 0x64, .b = 0x00 },
        .{ .r = 0x0d, .g = 0x74, .b = 0xce },
        .{ .r = 0x81, .g = 0x45, .b = 0xb5 },
        .{ .r = 0x10, .g = 0x7d, .b = 0x98 },
        .{ .r = 0x60, .g = 0x64, .b = 0x6c },
        .{ .r = 0x8b, .g = 0x8d, .b = 0x98 },
        .{ .r = 0xe5, .g = 0x48, .b = 0x4d },
        .{ .r = 0x30, .g = 0xa4, .b = 0x6c },
        .{ .r = 0xff, .g = 0xc5, .b = 0x3d },
        .{ .r = 0x00, .g = 0x90, .b = 0xff },
        .{ .r = 0x8e, .g = 0x4e, .b = 0xc6 },
        .{ .r = 0x00, .g = 0xa2, .b = 0xc7 },
        .{ .r = 0xfc, .g = 0xfc, .b = 0xfd },
    },
};

pub const dark_theme: ThemeColors = .{
    .background = .{ .r = 0x18, .g = 0x19, .b = 0x1b },
    .foreground = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .cursor_color = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .selection_background = .{ .r = 0x10, .g = 0x4d, .b = 0x87 },
    .selection_foreground = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .palette = .{
        .{ .r = 0x18, .g = 0x19, .b = 0x1b },
        .{ .r = 0xff, .g = 0x95, .b = 0x92 },
        .{ .r = 0x3d, .g = 0xd6, .b = 0x8c },
        .{ .r = 0xff, .g = 0xca, .b = 0x16 },
        .{ .r = 0x70, .g = 0xb8, .b = 0xff },
        .{ .r = 0xd1, .g = 0x9d, .b = 0xff },
        .{ .r = 0x4c, .g = 0xcc, .b = 0xe6 },
        .{ .r = 0xb0, .g = 0xb4, .b = 0xba },
        .{ .r = 0x69, .g = 0x6e, .b = 0x77 },
        .{ .r = 0xff, .g = 0xd1, .b = 0xd9 },
        .{ .r = 0xb1, .g = 0xf1, .b = 0xcb },
        .{ .r = 0xff, .g = 0xe7, .b = 0xb3 },
        .{ .r = 0xc2, .g = 0xe6, .b = 0xff },
        .{ .r = 0xec, .g = 0xd9, .b = 0xfa },
        .{ .r = 0xb6, .g = 0xec, .b = 0xf7 },
        .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
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
/// Minimum window padding in logical pixels. One configured value applies to
/// both sides; two values are left/right for X and top/bottom for Y.
window_padding_x: WindowPadding = .{},
window_padding_y: WindowPadding = .{},
/// Shell to run; unset falls back to $SHELL, then /bin/sh.
shell: ?[:0]const u8 = null,
/// Shell command that receives the last semantic command output on stdin.
pipe_command_output: ?[:0]const u8 = null,
/// Whether newly spawned children should be moved into their own transient
/// systemd scope. This only affects startup; reloads do not move a live child.
linux_cgroup: LinuxCgroup = .never,
scrollback: usize = 10_000,
/// Total storage limit in bytes for kitty graphics images per screen;
/// 0 disables the protocol. A single image larger than this limit is
/// rejected, so it must comfortably fit a fullscreen RGBA frame.
image_storage_limit: usize = 320 * 1000 * 1000,
wheel_scroll_lines: u31 = 3,

theme: Theme = default_theme,
background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?vt.color.RGB = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
palette: [16]?vt.color.RGB = @splat(null),

pub const LinuxCgroup = enum { never, always };

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
    } else if (std.mem.eql(u8, key, "window-padding-x")) {
        self.window_padding_x = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "window-padding-y")) {
        self.window_padding_y = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "pipe-command-output")) {
        self.pipe_command_output = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "linux-cgroup")) {
        self.linux_cgroup = std.meta.stringToEnum(LinuxCgroup, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "scrollback")) {
        self.scrollback = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "image-storage-limit")) {
        const limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
        // Same cap as Ghostty's image-storage-limit (4GiB).
        if (limit > std.math.maxInt(u32)) return error.InvalidValue;
        self.image_storage_limit = limit;
    } else if (std.mem.eql(u8, key, "wheel-scroll-lines")) {
        const lines = std.fmt.parseInt(u31, value, 10) catch return error.InvalidValue;
        if (lines == 0) return error.InvalidValue;
        self.wheel_scroll_lines = lines;
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

fn parseWindowPadding(value: []const u8) error{InvalidValue}!WindowPadding {
    var values = std.mem.splitScalar(u8, value, ',');
    const first_text = std.mem.trim(u8, values.next() orelse return error.InvalidValue, " \t");
    if (first_text.len == 0) return error.InvalidValue;
    const first = std.fmt.parseInt(u31, first_text, 10) catch return error.InvalidValue;
    const second_text = values.next() orelse return .{ .first = first, .second = first };
    if (values.next() != null) return error.InvalidValue;
    const trimmed_second = std.mem.trim(u8, second_text, " \t");
    if (trimmed_second.len == 0) return error.InvalidValue;
    return .{
        .first = first,
        .second = std.fmt.parseInt(u31, trimmed_second, 10) catch return error.InvalidValue,
    };
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
        .system => dark_theme,
        .light => light_theme,
        .dark => dark_theme,
    };
}

pub fn effectiveTheme(self: *const Config, color_scheme: vt.device_status.ColorScheme) Theme {
    return switch (self.theme) {
        .system => switch (color_scheme) {
            .light => .light,
            .dark => .dark,
        },
        .light, .dark => self.theme,
    };
}

pub fn effectiveSelectionBackground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.selection_background orelse themeColors(self.effectiveTheme(color_scheme)).selection_background;
}

pub fn effectiveSelectionForeground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.selection_foreground orelse themeColors(self.effectiveTheme(color_scheme)).selection_foreground;
}

/// The terminal color options this config describes: config colors form
/// the *default* layer, so OSC 10/11/12/4 can still override and reset.
pub fn terminalColors(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.Terminal.Colors {
    var palette = vt.color.default;
    const themed = themeColors(self.effectiveTheme(color_scheme));
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
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.shell);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.pipe_command_output);
    try std.testing.expectEqual(LinuxCgroup.never, config.linux_cgroup);
    try std.testing.expectEqual(default_theme, config.theme);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.foreground);
    try std.testing.expectEqual(default_selection_background, config.effectiveSelectionBackground(.dark));
    try std.testing.expectEqual(default_selection_foreground, config.effectiveSelectionForeground(.dark));
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
        \\window-padding-x = 4
        \\window-padding-y = 6, 10
        \\shell = /usr/bin/fish
        \\pipe-command-output = cat > /tmp/monstar-output
        \\linux-cgroup = always
        \\scrollback = 5000
        \\image-storage-limit = 50000000
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
    try std.testing.expectEqual(WindowPadding{ .first = 4, .second = 4 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{ .first = 6, .second = 10 }, config.window_padding_y);
    try std.testing.expectEqualStrings("/usr/bin/fish", config.shell.?);
    try std.testing.expectEqualStrings("cat > /tmp/monstar-output", config.pipe_command_output.?);
    try std.testing.expectEqual(LinuxCgroup.always, config.linux_cgroup);
    try std.testing.expectEqual(@as(usize, 5000), config.scrollback);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(u31, 5), config.wheel_scroll_lines);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf7, .g = 0x76, .b = 0x8e }, config.palette[1].?);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.palette[2]);
}

test "invalid window padding keeps the previous value" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(),
        \\window-padding-x = 3,7
        \\window-padding-x = 1,2,3
        \\window-padding-y = -1
    );
    try std.testing.expectEqual(WindowPadding{ .first = 3, .second = 7 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
}

test "terminal colors from config" {
    var config: Config = .{};
    config.background = .{ .r = 1, .g = 2, .b = 3 };
    const colors = config.terminalColors(.dark);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(default_foreground, colors.foreground.get().?);
    try std.testing.expectEqual(default_cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(default_palette[0], colors.palette.current[0]);
    try std.testing.expectEqual(default_palette[15], colors.palette.current[15]);
}

test "system theme follows color scheme" {
    const config: Config = .{};
    try std.testing.expectEqual(Theme.system, config.theme);
    try std.testing.expectEqual(Theme.dark, config.effectiveTheme(.dark));
    try std.testing.expectEqual(Theme.light, config.effectiveTheme(.light));

    const light_colors = config.terminalColors(.light);
    try std.testing.expectEqual(light_theme.background, light_colors.background.get().?);
    try std.testing.expectEqual(light_theme.foreground, light_colors.foreground.get().?);
    try std.testing.expectEqual(light_theme.selection_background, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(light_theme.selection_foreground, config.effectiveSelectionForeground(.light));
}

test "dark theme" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\theme = dark
    );

    const colors = config.terminalColors(.light);
    try std.testing.expectEqual(Theme.dark, config.theme);
    try std.testing.expectEqual(dark_theme.background, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(dark_theme.cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(dark_theme.palette[1], colors.palette.current[1]);
    try std.testing.expectEqual(dark_theme.selection_background, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground(.light));
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

    const colors = config.terminalColors(.light);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, colors.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground(.light));
}
