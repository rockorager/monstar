//! Theme data, parsing, and named-theme file resolution for configuration.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");

const log = std.log.scoped(.config);

fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

pub const Theme = struct {
    light: [:0]const u8,
    dark: [:0]const u8,
};

/// A configured color that can be a concrete RGB value or a runtime
/// reference to the cell's foreground or background.
pub const TerminalColor = union(enum) {
    rgb: vt.color.RGB,
    cell_foreground,
    cell_background,

    pub fn toRgb(self: TerminalColor) ?vt.color.RGB {
        return switch (self) {
            .rgb => |color| color,
            .cell_foreground, .cell_background => null,
        };
    }

    pub fn resolve(self: TerminalColor, cell_fg: vt.color.RGB, cell_bg: vt.color.RGB) vt.color.RGB {
        return switch (self) {
            .rgb => |color| color,
            .cell_foreground => cell_fg,
            .cell_background => cell_bg,
        };
    }

    pub fn eql(self: TerminalColor, other: TerminalColor) bool {
        return switch (self) {
            .rgb => |color| switch (other) {
                .rgb => |other_color| color.eql(other_color),
                else => false,
            },
            .cell_foreground => switch (other) {
                .cell_foreground => true,
                else => false,
            },
            .cell_background => switch (other) {
                .cell_background => true,
                else => false,
            },
        };
    }
};

pub const ThemeOverrides = struct {
    background: ?vt.color.RGB = null,
    foreground: ?vt.color.RGB = null,
    cursor_color: ?TerminalColor = null,
    cursor_text: ?TerminalColor = null,
    selection_background: ?vt.color.RGB = null,
    selection_foreground: ?vt.color.RGB = null,
    copy_highlight: ?vt.color.RGB = null,
    copy_highlight_foreground: ?vt.color.RGB = null,
    palette: [256]?vt.color.RGB = @splat(null),
};

pub const ThemeColors = struct {
    background: vt.color.RGB,
    foreground: vt.color.RGB,
    cursor_color: vt.color.RGB,
    selection_background: vt.color.RGB,
    selection_foreground: vt.color.RGB,
    copy_highlight: vt.color.RGB,
    copy_highlight_foreground: vt.color.RGB,
    palette: [16]vt.color.RGB,
};

// Fluent 2 Web semantic colors supply the terminal UI roles. ANSI colors use
// the matching global shade ramps in light mode and tint ramps in dark mode.
pub const light_theme: ThemeColors = .{
    .background = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .foreground = .{ .r = 0x24, .g = 0x24, .b = 0x24 },
    .cursor_color = .{ .r = 0x24, .g = 0x24, .b = 0x24 },
    .selection_background = .{ .r = 0xcf, .g = 0xe4, .b = 0xfa },
    .selection_foreground = .{ .r = 0x24, .g = 0x24, .b = 0x24 },
    .copy_highlight = .{ .r = 0xfd, .g = 0xea, .b = 0x3d },
    .copy_highlight_foreground = .{ .r = 0x24, .g = 0x24, .b = 0x24 },
    .palette = .{
        .{ .r = 0x24, .g = 0x24, .b = 0x24 },
        .{ .r = 0xbc, .g = 0x2f, .b = 0x32 },
        .{ .r = 0x0e, .g = 0x70, .b = 0x0e },
        .{ .r = 0x81, .g = 0x74, .b = 0x00 },
        .{ .r = 0x0f, .g = 0x6c, .b = 0xbd },
        .{ .r = 0xac, .g = 0x00, .b = 0x6b },
        .{ .r = 0x00, .g = 0x74, .b = 0x8f },
        .{ .r = 0x61, .g = 0x61, .b = 0x61 },
        .{ .r = 0x70, .g = 0x70, .b = 0x70 },
        .{ .r = 0xd1, .g = 0x34, .b = 0x38 },
        .{ .r = 0x10, .g = 0x7c, .b = 0x10 },
        .{ .r = 0xc0, .g = 0xad, .b = 0x00 },
        .{ .r = 0x28, .g = 0x86, .b = 0xde },
        .{ .r = 0xbf, .g = 0x00, .b = 0x77 },
        .{ .r = 0x00, .g = 0x8a, .b = 0xa9 },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
    },
};

pub const dark_theme: ThemeColors = .{
    .background = .{ .r = 0x29, .g = 0x29, .b = 0x29 },
    .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .cursor_color = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .selection_background = .{ .r = 0x0f, .g = 0x6c, .b = 0xbd },
    .selection_foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
    .copy_highlight = .{ .r = 0xfd, .g = 0xea, .b = 0x3d },
    .copy_highlight_foreground = .{ .r = 0x24, .g = 0x24, .b = 0x24 },
    .palette = .{
        .{ .r = 0x5c, .g = 0x5c, .b = 0x5c },
        .{ .r = 0xe3, .g = 0x7d, .b = 0x80 },
        .{ .r = 0x54, .g = 0xb0, .b = 0x54 },
        .{ .r = 0xfe, .g = 0xee, .b = 0x66 },
        .{ .r = 0x47, .g = 0x9e, .b = 0xf5 },
        .{ .r = 0xd9, .g = 0x57, .b = 0xa8 },
        .{ .r = 0x56, .g = 0xbf, .b = 0xd7 },
        .{ .r = 0xd6, .g = 0xd6, .b = 0xd6 },
        .{ .r = 0x99, .g = 0x99, .b = 0x99 },
        .{ .r = 0xf1, .g = 0xbb, .b = 0xbc },
        .{ .r = 0x9f, .g = 0xd8, .b = 0x9f },
        .{ .r = 0xfe, .g = 0xf7, .b = 0xb2 },
        .{ .r = 0x96, .g = 0xc6, .b = 0xfa },
        .{ .r = 0xec, .g = 0xa5, .b = 0xd1 },
        .{ .r = 0xa4, .g = 0xde, .b = 0xeb },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
    },
};

pub fn parse(arena: std.mem.Allocator, value: []const u8) error{ InvalidValue, OutOfMemory }!Theme {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return error.InvalidValue;

    if (std.mem.indexOfAny(u8, trimmed, ",:=") == null) {
        const name = try arena.dupeZ(u8, trimmed);
        return .{ .light = name, .dark = name };
    }

    var light: ?[:0]const u8 = null;
    var dark: ?[:0]const u8 = null;
    var entries = std.mem.splitScalar(u8, trimmed, ',');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidValue;
        if (std.mem.indexOfScalarPos(u8, entry, colon + 1, ':') != null) return error.InvalidValue;
        const kind = std.mem.trim(u8, entry[0..colon], " \t");
        const name = std.mem.trim(u8, entry[colon + 1 ..], " \t");
        if (name.len == 0) return error.InvalidValue;
        if (std.mem.eql(u8, kind, "light")) {
            if (light != null) return error.InvalidValue;
            light = try arena.dupeZ(u8, name);
        } else if (std.mem.eql(u8, kind, "dark")) {
            if (dark != null) return error.InvalidValue;
            dark = try arena.dupeZ(u8, name);
        } else {
            return error.InvalidValue;
        }
    }
    return .{
        .light = light orelse return error.InvalidValue,
        .dark = dark orelse return error.InvalidValue,
    };
}

pub const PaletteEntry = struct {
    index: u8,
    color: vt.color.RGB,
};

pub fn parsePaletteEntry(value: []const u8) error{InvalidValue}!PaletteEntry {
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

/// "#RRGGBB" or "RRGGBB".
pub fn parseColor(value: []const u8) error{InvalidValue}!vt.color.RGB {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return error.InvalidValue;
    const num = std.fmt.parseInt(u24, hex, 16) catch return error.InvalidValue;
    return .{
        .r = @intCast(num >> 16),
        .g = @intCast((num >> 8) & 0xff),
        .b = @intCast(num & 0xff),
    };
}

/// Hex color, `cell-foreground`, or `cell-background`.
pub fn parseTerminalColor(value: []const u8) error{InvalidValue}!TerminalColor {
    if (std.mem.eql(u8, value, "cell-foreground")) return .cell_foreground;
    if (std.mem.eql(u8, value, "cell-background")) return .cell_background;
    return .{ .rgb = try parseColor(value) };
}

pub fn loadOverrides(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    name: []const u8,
) error{OutOfMemory}!?ThemeOverrides {
    if (std.fs.path.isAbsolute(name)) {
        const path = try arena.dupeZ(u8, name);
        if (readFile(arena, path)) |text| return parseOverrides(text);
        warn("theme '{s}' could not be read", .{name});
        return null;
    }
    if (!std.mem.eql(u8, name, std.fs.path.basename(name))) {
        warn("theme '{s}' cannot contain path separators", .{name});
        return null;
    }

    if (environ.getPosix("XDG_CONFIG_HOME")) |base| {
        const path = try std.fs.path.joinZ(arena, &.{ base, "monstar", "themes", name });
        if (readFile(arena, path)) |text| return parseOverrides(text);
    } else if (environ.getPosix("HOME")) |home| {
        const path = try std.fs.path.joinZ(arena, &.{ home, ".config", "monstar", "themes", name });
        if (readFile(arena, path)) |text| return parseOverrides(text);
    }

    if (environ.getPosix("MONSTAR_RESOURCES_DIR")) |resources| {
        const path = try std.fs.path.joinZ(arena, &.{ resources, "themes", name });
        if (readFile(arena, path)) |text| return parseOverrides(text);
    }

    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &exe_dir_buf)) |len| {
        const path = try std.fs.path.joinZ(arena, &.{
            exe_dir_buf[0..len], "..", "share", "monstar", "themes", name,
        });
        if (readFile(arena, path)) |text| return parseOverrides(text);
    } else |_| {}

    warn("theme '{s}' not found", .{name});
    return null;
}

pub fn parseOverrides(text: []const u8) ThemeOverrides {
    var result: ThemeOverrides = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "background")) {
            result.background = parseColor(value) catch {
                warn("theme line {d}: invalid background", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "foreground")) {
            result.foreground = parseColor(value) catch {
                warn("theme line {d}: invalid foreground", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            result.cursor_color = parseTerminalColor(value) catch {
                warn("theme line {d}: invalid cursor-color", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            result.cursor_text = parseTerminalColor(value) catch {
                warn("theme line {d}: invalid cursor-text", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "selection-background")) {
            result.selection_background = parseColor(value) catch {
                warn("theme line {d}: invalid selection-background", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "selection-foreground")) {
            result.selection_foreground = parseColor(value) catch {
                warn("theme line {d}: invalid selection-foreground", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "copy-highlight")) {
            result.copy_highlight = parseColor(value) catch {
                warn("theme line {d}: invalid copy-highlight", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "copy-highlight-foreground")) {
            result.copy_highlight_foreground = parseColor(value) catch {
                warn("theme line {d}: invalid copy-highlight-foreground", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "palette")) {
            const entry = parsePaletteEntry(value) catch {
                warn("theme line {d}: invalid palette", .{line_no});
                continue;
            };
            result.palette[entry.index] = entry.color;
        } else {
            warn("theme line {d}: unknown key '{s}', ignoring", .{ line_no, key });
        }
    }
    return result;
}

pub fn colorsForScheme(color_scheme: vt.device_status.ColorScheme) ThemeColors {
    return switch (color_scheme) {
        .light => light_theme,
        .dark => dark_theme,
    };
}

pub fn resolveColor(explicit: ?vt.color.RGB, named: ?vt.color.RGB, built_in: vt.color.RGB) vt.color.RGB {
    return explicit orelse named orelse built_in;
}

pub fn resolveTerminalColor(
    explicit: ?TerminalColor,
    named: ?TerminalColor,
    built_in: vt.color.RGB,
) TerminalColor {
    return explicit orelse named orelse .{ .rgb = built_in };
}

pub fn resolvePalette(
    explicit: *const [256]?vt.color.RGB,
    named: ?*const ThemeOverrides,
    built_in: ThemeColors,
) [256]vt.color.RGB {
    var palette = vt.color.default;
    for (built_in.palette, 0..) |rgb, i| palette[i] = rgb;
    if (named) |overrides| {
        for (overrides.palette, 0..) |entry, i| {
            if (entry) |rgb| palette[i] = rgb;
        }
    }
    for (explicit, 0..) |entry, i| {
        if (entry) |rgb| palette[i] = rgb;
    }
    return palette;
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

test "parse terminal colors" {
    try std.testing.expectEqual(@as(TerminalColor, .cell_foreground), try parseTerminalColor("cell-foreground"));
    try std.testing.expectEqual(@as(TerminalColor, .cell_background), try parseTerminalColor("cell-background"));
    try std.testing.expectEqual(
        TerminalColor{ .rgb = .{ .r = 0xaa, .g = 0xbb, .b = 0xcc } },
        try parseTerminalColor("#aabbcc"),
    );
    try std.testing.expectError(error.InvalidValue, parseTerminalColor("cell-foo"));
    try std.testing.expectError(error.InvalidValue, parseColor("cell-foreground"));
}

test "terminal color resolve and equality" {
    const fg: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    const bg: vt.color.RGB = .{ .r = 4, .g = 5, .b = 6 };
    const rgb: TerminalColor = .{ .rgb = fg };
    try std.testing.expectEqual(fg, @as(TerminalColor, .cell_foreground).resolve(fg, bg));
    try std.testing.expectEqual(bg, @as(TerminalColor, .cell_background).resolve(fg, bg));
    try std.testing.expectEqual(fg, rgb.resolve(bg, bg));
    try std.testing.expect(rgb.eql(.{ .rgb = fg }));
    try std.testing.expect(!rgb.eql(.cell_foreground));
    try std.testing.expect(@as(TerminalColor, .cell_foreground).eql(.cell_foreground));
    try std.testing.expect(!@as(TerminalColor, .cell_foreground).eql(.cell_background));
}

test "theme overrides parse cell cursor colors" {
    const theme = parseOverrides(
        \\cursor-color = cell-foreground
        \\cursor-text = cell-background
    );
    try std.testing.expectEqual(@as(TerminalColor, .cell_foreground), theme.cursor_color.?);
    try std.testing.expectEqual(@as(TerminalColor, .cell_background), theme.cursor_text.?);
}
