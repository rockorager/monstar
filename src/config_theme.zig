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

pub const ThemeOverrides = struct {
    background: ?vt.color.RGB = null,
    foreground: ?vt.color.RGB = null,
    cursor_color: ?vt.color.RGB = null,
    cursor_text: ?vt.color.RGB = null,
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

pub const light_theme: ThemeColors = .{
    .background = .{ .r = 0xf0, .g = 0xf0, .b = 0xf3 },
    .foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .cursor_color = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .selection_background = .{ .r = 0xc2, .g = 0xe5, .b = 0xff },
    .selection_foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
    .copy_highlight = .{ .r = 0xff, .g = 0xe6, .b = 0x29 },
    .copy_highlight_foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
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
    .background = .{ .r = 0x21, .g = 0x22, .b = 0x25 },
    .foreground = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .cursor_color = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .selection_background = .{ .r = 0x10, .g = 0x4d, .b = 0x87 },
    .selection_foreground = .{ .r = 0xed, .g = 0xee, .b = 0xf0 },
    .copy_highlight = .{ .r = 0xff, .g = 0xe6, .b = 0x29 },
    .copy_highlight_foreground = .{ .r = 0x1c, .g = 0x20, .b = 0x24 },
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
            result.cursor_color = parseColor(value) catch {
                warn("theme line {d}: invalid cursor-color", .{line_no});
                continue;
            };
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            result.cursor_text = parseColor(value) catch {
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
