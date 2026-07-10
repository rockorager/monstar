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

pub const WindowPadding = struct {
    first: u31 = 0,
    second: u31 = 0,
};

pub const Command = union(enum) {
    shell: [:0]const u8,
    direct: []const [:0]const u8,
};

pub const MouseScrollMultiplier = struct {
    precision: f64 = 1,
    discrete: f64 = 3,
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
/// Font size in typographic points. Rasterization uses a 96 DPI baseline and
/// the output's fractional scale.
font_size: f32 = 12,
/// Minimum window padding in logical pixels. One configured value applies to
/// both sides; two values are left/right for X and top/bottom for Y.
window_padding_x: WindowPadding = .{},
window_padding_y: WindowPadding = .{},
/// Command to run; unset falls back to $SHELL, then /bin/sh.
command: ?Command = null,
/// Shell command that receives the last semantic command output on stdin.
pipe_command_output: ?[:0]const u8 = null,
/// Whether newly spawned children should be moved into their own transient
/// systemd scope. This only affects startup; reloads do not move a live child.
linux_cgroup: LinuxCgroup = .never,
/// Logical terminal page storage in bytes, including the active screen.
scrollback_limit: usize = 50_000_000,
/// Total storage limit in bytes for kitty graphics images per screen;
/// 0 disables the protocol. A single image larger than this limit is
/// rejected, so it must comfortably fit a fullscreen RGBA frame.
image_storage_limit: usize = 320 * 1000 * 1000,
mouse_scroll_multiplier: MouseScrollMultiplier = .{},

background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?vt.color.RGB = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
palette: [256]?vt.color.RGB = @splat(null),

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
        const size = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
        if (!std.math.isFinite(size) or size <= 0 or size > 512) return error.InvalidValue;
        self.font_size = size;
    } else if (std.mem.eql(u8, key, "window-padding-x")) {
        self.window_padding_x = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "window-padding-y")) {
        self.window_padding_y = try parseWindowPadding(value);
    } else if (std.mem.eql(u8, key, "command")) {
        self.command = try parseCommand(arena, value);
    } else if (std.mem.eql(u8, key, "pipe-command-output")) {
        self.pipe_command_output = try arena.dupeZ(u8, value);
    } else if (std.mem.eql(u8, key, "linux-cgroup")) {
        self.linux_cgroup = std.meta.stringToEnum(LinuxCgroup, value) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "scrollback-limit")) {
        self.scrollback_limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "image-storage-limit")) {
        const limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
        // Same cap as Ghostty's image-storage-limit (4GiB).
        if (limit > std.math.maxInt(u32)) return error.InvalidValue;
        self.image_storage_limit = limit;
    } else if (std.mem.eql(u8, key, "mouse-scroll-multiplier")) {
        self.mouse_scroll_multiplier = try parseMouseScrollMultiplier(self.mouse_scroll_multiplier, value);
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
    } else if (std.mem.eql(u8, key, "palette")) {
        const entry = try parsePaletteEntry(value);
        self.palette[entry.index] = entry.color;
    } else {
        warn("unknown key '{s}', ignoring", .{key});
    }
}

fn parseCommand(arena: std.mem.Allocator, value: []const u8) SetError!Command {
    const trimmed = std.mem.trim(u8, value, " \t");
    const mode: std.meta.Tag(Command), const text = mode: {
        if (std.mem.startsWith(u8, trimmed, "direct:")) {
            break :mode .{ .direct, std.mem.trim(u8, trimmed["direct:".len..], " \t") };
        }
        if (std.mem.startsWith(u8, trimmed, "shell:")) {
            break :mode .{ .shell, std.mem.trim(u8, trimmed["shell:".len..], " \t") };
        }
        break :mode .{ .shell, trimmed };
    };
    if (text.len == 0) return error.InvalidValue;

    return switch (mode) {
        .shell => .{ .shell = try arena.dupeZ(u8, text) },
        .direct => direct: {
            var args: std.ArrayList([:0]const u8) = .empty;
            var tokens = std.mem.tokenizeAny(u8, text, " \t");
            while (tokens.next()) |arg| try args.append(arena, try arena.dupeZ(u8, arg));
            if (args.items.len == 0) return error.InvalidValue;
            break :direct .{ .direct = try args.toOwnedSlice(arena) };
        },
    };
}

fn parseMouseScrollMultiplier(current: MouseScrollMultiplier, value: []const u8) error{InvalidValue}!MouseScrollMultiplier {
    if (std.mem.indexOfScalar(u8, value, ':') == null) {
        const multiplier = try parseScrollMultiplier(value);
        return .{ .precision = multiplier, .discrete = multiplier };
    }

    var result = current;
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |entry| {
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidValue;
        if (std.mem.indexOfScalarPos(u8, entry, colon + 1, ':') != null) return error.InvalidValue;
        const name = std.mem.trim(u8, entry[0..colon], " \t");
        const multiplier = try parseScrollMultiplier(entry[colon + 1 ..]);
        if (std.mem.eql(u8, name, "precision")) {
            result.precision = multiplier;
        } else if (std.mem.eql(u8, name, "discrete")) {
            result.discrete = multiplier;
        } else {
            return error.InvalidValue;
        }
    }
    return result;
}

fn parseScrollMultiplier(value: []const u8) error{InvalidValue}!f64 {
    const multiplier = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(multiplier)) return error.InvalidValue;
    return std.math.clamp(multiplier, 0.01, 10_000);
}

const PaletteEntry = struct {
    index: u8,
    color: vt.color.RGB,
};

fn parsePaletteEntry(value: []const u8) error{InvalidValue}!PaletteEntry {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidValue;
    if (std.mem.indexOfScalarPos(u8, value, eq + 1, '=') != null) return error.InvalidValue;
    const index_text = std.mem.trim(u8, value[0..eq], " \t");
    const color_text = std.mem.trim(u8, value[eq + 1 ..], " \t");
    if (index_text.len == 0 or color_text.len == 0) return error.InvalidValue;
    return .{
        .index = std.fmt.parseInt(u8, index_text, 0) catch return error.InvalidValue,
        .color = try parseColor(color_text),
    };
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

/// Convert a point size to physical pixels using the conventional Linux
/// baseline of 96 DPI, then apply the Wayland output scale.
pub fn fontSizePixels(points: f32, scale120: u32) u31 {
    std.debug.assert(std.math.isFinite(points) and points > 0);
    std.debug.assert(scale120 > 0);

    const baseline_dpi = 96.0;
    const points_per_inch = 72.0;
    const output_scale = @as(f64, @floatFromInt(scale120)) / 120.0;
    const pixels = @as(f64, points) * baseline_dpi / points_per_inch * output_scale;
    return @max(1, @as(u31, @intFromFloat(@round(pixels))));
}

pub fn colorsForScheme(color_scheme: vt.device_status.ColorScheme) ThemeColors {
    return switch (color_scheme) {
        .light => light_theme,
        .dark => dark_theme,
    };
}

pub fn effectiveSelectionBackground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.selection_background orelse colorsForScheme(color_scheme).selection_background;
}

pub fn effectiveSelectionForeground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.selection_foreground orelse colorsForScheme(color_scheme).selection_foreground;
}

/// The terminal color options this config describes: config colors form
/// the *default* layer, so OSC 10/11/12/4 can still override and reset.
pub fn terminalColors(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.Terminal.Colors {
    var palette = vt.color.default;
    const themed = colorsForScheme(color_scheme);
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
    try std.testing.expectEqual(@as(f32, 12), config.font_size);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
    try std.testing.expectEqual(@as(?Command, null), config.command);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.pipe_command_output);
    try std.testing.expectEqual(LinuxCgroup.never, config.linux_cgroup);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(f64, 1), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 3), config.mouse_scroll_multiplier.discrete);
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
        \\font-size = 14.5
        \\window-padding-x = 4
        \\window-padding-y = 6, 10
        \\command = /usr/bin/fish --login
        \\pipe-command-output = cat > /tmp/monstar-output
        \\linux-cgroup = always
        \\scrollback-limit = 50000000
        \\image-storage-limit = 50000000
        \\mouse-scroll-multiplier = precision:1.5,discrete:5
        \\background = #1a1b26
        \\foreground = c0caf5
        \\palette = 1=#f7768e
        \\palette = 200=#123456
        \\
        \\bogus-key = whatever
        \\font-size = not-a-number
    );

    try std.testing.expectEqualStrings("com.example.scratchpad", config.app_id);
    try std.testing.expectEqualStrings("Fira Code", config.font_family);
    // invalid re-assignment keeps the previous valid value
    try std.testing.expectEqual(@as(f32, 14.5), config.font_size);
    try std.testing.expectEqual(WindowPadding{ .first = 4, .second = 4 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{ .first = 6, .second = 10 }, config.window_padding_y);
    try std.testing.expectEqualStrings("/usr/bin/fish --login", config.command.?.shell);
    try std.testing.expectEqualStrings("cat > /tmp/monstar-output", config.pipe_command_output.?);
    try std.testing.expectEqual(LinuxCgroup.always, config.linux_cgroup);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1.5), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 5), config.mouse_scroll_multiplier.discrete);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf7, .g = 0x76, .b = 0x8e }, config.palette[1].?);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.palette[2]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, config.palette[200].?);
}

test "direct command parsing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const config = parse(arena_state.allocator(),
        \\command = direct:fish --no-config
    );
    const command = config.command.?.direct;
    try std.testing.expectEqual(@as(usize, 2), command.len);
    try std.testing.expectEqualStrings("fish", command[0]);
    try std.testing.expectEqualStrings("--no-config", command[1]);
}

test "mouse scroll multiplier forms and clamps" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "mouse-scroll-multiplier", "2.5");
    try std.testing.expectEqual(@as(f64, 2.5), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 2.5), config.mouse_scroll_multiplier.discrete);

    try config.set(std.testing.allocator, "mouse-scroll-multiplier", "precision:0,discrete:20000");
    try std.testing.expectEqual(@as(f64, 0.01), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 10_000), config.mouse_scroll_multiplier.discrete);
}

test "palette accepts all indices and numeric bases" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "palette", "0x0f=#010203");
    try config.set(std.testing.allocator, "palette", "255=040506");
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, config.palette[15].?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, config.palette[255].?);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "palette", "256=#000000"));
}

test "font size points convert to scaled physical pixels" {
    try std.testing.expectEqual(@as(u31, 16), fontSizePixels(12, 120));
    try std.testing.expectEqual(@as(u31, 24), fontSizePixels(12, 180));
    try std.testing.expectEqual(@as(u31, 32), fontSizePixels(12, 240));
    try std.testing.expectEqual(@as(u31, 17), fontSizePixels(12.5, 120));
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

test "built-in colors follow color scheme" {
    const config: Config = .{};
    const light_colors = config.terminalColors(.light);
    try std.testing.expectEqual(light_theme.background, light_colors.background.get().?);
    try std.testing.expectEqual(light_theme.foreground, light_colors.foreground.get().?);
    try std.testing.expectEqual(light_theme.selection_background, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(light_theme.selection_foreground, config.effectiveSelectionForeground(.light));

    const dark_colors = config.terminalColors(.dark);
    try std.testing.expectEqual(dark_theme.background, dark_colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, dark_colors.foreground.get().?);
    try std.testing.expectEqual(dark_theme.cursor_color, dark_colors.cursor.get().?);
    try std.testing.expectEqual(dark_theme.palette[1], dark_colors.palette.current[1]);
}

test "built-in colors do not replace explicit color overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = parse(arena,
        \\background = #010203
        \\palette = 1=#040506
        \\selection-background = #070809
    );

    const colors = config.terminalColors(.dark);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, colors.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveSelectionBackground(.dark));
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground(.dark));
}
