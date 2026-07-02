//! Configuration: a flat `key = value` file, one entry per line, with
//! `#` comments. Located at $XDG_CONFIG_HOME/monstar/config (falling
//! back to ~/.config/monstar/config). Missing file means defaults;
//! invalid lines warn and keep their default.

const Config = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

const log = std.log.scoped(.config);

font_family: [:0]const u8 = "monospace",
/// Font size in logical pixels (scaled by the output's fractional scale).
font_size: u31 = 16,
/// Shell to run; unset falls back to $SHELL, then /bin/sh.
shell: ?[:0]const u8 = null,
scrollback: usize = 10_000,
wheel_scroll_lines: u31 = 3,

background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?vt.color.RGB = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
palette: [16]?vt.color.RGB = @splat(null),

/// Load the config file, if any. Strings are allocated in `arena` and
/// live as long as it does.
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
            log.warn("line {d}: missing '=', ignoring: {s}", .{ line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) {
            log.warn("line {d}: empty value for '{s}', ignoring", .{ line_no, key });
            continue;
        }

        config.set(arena, key, value) catch {
            log.warn("line {d}: invalid value for '{s}': {s}", .{ line_no, key, value });
        };
    }
    return config;
}

const SetError = error{ InvalidValue, UnknownKey, OutOfMemory };

fn set(self: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) SetError!void {
    if (std.mem.eql(u8, key, "font-family")) {
        self.font_family = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "font-size")) {
        const size = std.fmt.parseInt(u31, value, 10) catch return error.InvalidValue;
        if (size == 0 or size > 512) return error.InvalidValue;
        self.font_size = size;
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "scrollback")) {
        self.scrollback = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wheel-scroll-lines")) {
        const lines = std.fmt.parseInt(u31, value, 10) catch return error.InvalidValue;
        if (lines == 0) return error.InvalidValue;
        self.wheel_scroll_lines = lines;
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
        log.warn("unknown key '{s}', ignoring", .{key});
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

/// The terminal color options this config describes: config colors form
/// the *default* layer, so OSC 10/11/12/4 can still override and reset.
pub fn terminalColors(self: *const Config) vt.Terminal.Colors {
    var palette = vt.color.default;
    for (self.palette, 0..) |entry, i| {
        if (entry) |rgb| palette[i] = rgb;
    }
    return .{
        .background = if (self.background) |rgb| .init(rgb) else .unset,
        .foreground = if (self.foreground) |rgb| .init(rgb) else .unset,
        .cursor = if (self.cursor_color) |rgb| .init(rgb) else .unset,
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
    try std.testing.expectEqualStrings("monospace", config.font_family);
    try std.testing.expectEqual(@as(u31, 16), config.font_size);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.shell);
}

test "parse config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\# a comment
        \\font-family = Fira Code
        \\font-size = 14
        \\shell = /usr/bin/fish
        \\scrollback = 5000
        \\wheel-scroll-lines = 5
        \\background = #1a1b26
        \\foreground = c0caf5
        \\palette1 = #f7768e
        \\
        \\bogus-key = whatever
        \\font-size = not-a-number
    );

    try std.testing.expectEqualStrings("Fira Code", config.font_family);
    // invalid re-assignment keeps the previous valid value
    try std.testing.expectEqual(@as(u31, 14), config.font_size);
    try std.testing.expectEqualStrings("/usr/bin/fish", config.shell.?);
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
    try std.testing.expectEqual(@as(?vt.color.RGB, null), colors.foreground.get());
}
