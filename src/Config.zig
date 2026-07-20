//! Configuration: a flat `key = value` file, one entry per line, with
//! `#` comments. Located at $XDG_CONFIG_HOME/monstar/config (falling
//! back to ~/.config/monstar/config). Missing file means defaults;
//! invalid lines warn and keep their default.

const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const config_theme = @import("config_theme.zig");

const log = std.log.scoped(.config);
const baseline_dpi = 96.0;
const points_per_inch = 72.0;

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

pub const Theme = config_theme.Theme;
pub const ThemeColors = config_theme.ThemeColors;
pub const light_theme = config_theme.light_theme;
pub const dark_theme = config_theme.dark_theme;
const ThemeOverrides = config_theme.ThemeOverrides;

pub const FontSize = union(enum) {
    points: f32,
    pixels: f32,

    pub fn value(self: FontSize) f32 {
        return switch (self) {
            .points => |size| size,
            .pixels => |size| size,
        };
    }

    pub fn unit(self: FontSize) []const u8 {
        return switch (self) {
            .points => "pt",
            .pixels => "px",
        };
    }
};

/// Wayland app-id and desktop-entry hint for desktop integration.
app_id: [:0]const u8 = default_app_id,
font_family: [:0]const u8 = "monospace",
/// Bare and `pt` values are typographic points; `px` values are logical
/// pixels. Both apply the output's fractional scale during rasterization.
font_size: FontSize = .{ .points = 12 },
/// Minimum window padding in logical pixels. One configured value applies to
/// both sides; two values are left/right for X and top/bottom for Y.
window_padding_x: WindowPadding = .{},
window_padding_y: WindowPadding = .{},
/// Command to run; unset falls back to $SHELL, then /bin/sh. This only
/// affects startup because reloading does not replace a running child.
command: ?Command = null,
/// Shell command that receives the last semantic command output on stdin.
pipe_command_output: ?[:0]const u8 = null,
/// Whether newly spawned children should be moved into their own transient
/// systemd scope. This only affects startup; reloads do not move a live child.
linux_cgroup: LinuxCgroup = .never,
/// Logical terminal page storage in bytes, including the active screen. This
/// only affects startup because libghostty-vt does not resize live scrollback.
scrollback_limit: usize = 50_000_000,
/// Total storage limit in bytes for kitty graphics images per screen;
/// 0 disables the protocol. A single image larger than this limit is
/// rejected, so it must comfortably fit a fullscreen RGBA frame.
image_storage_limit: usize = 320 * 1000 * 1000,
mouse_scroll_multiplier: MouseScrollMultiplier = .{},
/// Whether finger scrolling continues with inertial motion after release.
inertial_scrolling: bool = true,
/// Duration of the post-copy selection flash in milliseconds; 0 disables it.
copy_highlight_duration: u32 = 200,
/// Effective alpha of the default terminal background. Keeping this as an
/// 8-bit value matches the wl_shm buffer and makes the opaque fast path exact.
background_opacity: u8 = 255,
/// Request compositor-provided blur whenever the background is translucent.
background_blur: bool = true,
/// Whether background opacity also applies to explicit cell backgrounds.
background_opacity_cells: bool = false,

theme: ?Theme = null,
light_theme_overrides: ?ThemeOverrides = null,
dark_theme_overrides: ?ThemeOverrides = null,
background: ?vt.color.RGB = null,
foreground: ?vt.color.RGB = null,
cursor_color: ?vt.color.RGB = null,
cursor_text: ?vt.color.RGB = null,
selection_background: ?vt.color.RGB = null,
selection_foreground: ?vt.color.RGB = null,
copy_highlight: ?vt.color.RGB = null,
copy_highlight_foreground: ?vt.color.RGB = null,
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

        config.set(arena, key, value) catch |err| switch (err) {
            error.UnknownKey => warn("line {d}: unknown key '{s}', ignoring", .{ line_no, key }),
            else => warn("line {d}: invalid value for '{s}': {s}", .{ line_no, key, value }),
        };
    }
    return config;
}

/// Resolve configured theme names after the config file and command-line
/// overrides have both been applied. User themes take priority over the
/// installed iTerm2 theme collection.
pub fn resolveThemes(
    self: *Config,
    io: std.Io,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
) error{OutOfMemory}!void {
    self.light_theme_overrides = null;
    self.dark_theme_overrides = null;
    const theme = self.theme orelse return;

    self.light_theme_overrides = try config_theme.loadOverrides(io, arena, environ, theme.light);
    if (std.mem.eql(u8, theme.light, theme.dark)) {
        self.dark_theme_overrides = self.light_theme_overrides;
    } else {
        self.dark_theme_overrides = try config_theme.loadOverrides(io, arena, environ, theme.dark);
    }
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
        self.font_size = try parseFontSize(value);
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
    } else if (std.mem.eql(u8, key, "inertial-scrolling")) {
        self.inertial_scrolling = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "copy-highlight-duration")) {
        self.copy_highlight_duration = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "background-opacity")) {
        self.background_opacity = try parseOpacity(value);
    } else if (std.mem.eql(u8, key, "background-blur")) {
        self.background_blur = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "background-opacity-cells")) {
        self.background_opacity_cells = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "theme")) {
        self.theme = try config_theme.parse(arena, value);
    } else if (std.mem.eql(u8, key, "background")) {
        self.background = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "foreground")) {
        self.foreground = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        self.cursor_color = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor-text")) {
        self.cursor_text = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-background")) {
        self.selection_background = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-foreground")) {
        self.selection_foreground = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "copy-highlight")) {
        self.copy_highlight = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "copy-highlight-foreground")) {
        self.copy_highlight_foreground = try config_theme.parseColor(value);
    } else if (std.mem.eql(u8, key, "palette")) {
        const entry = try config_theme.parsePaletteEntry(value);
        self.palette[entry.index] = entry.color;
    } else {
        return error.UnknownKey;
    }
}

fn parseFontSize(value: []const u8) error{InvalidValue}!FontSize {
    var number = value;
    var unit: std.meta.Tag(FontSize) = .points;
    if (std.mem.endsWith(u8, value, "pt")) {
        number = value[0 .. value.len - 2];
    } else if (std.mem.endsWith(u8, value, "px")) {
        number = value[0 .. value.len - 2];
        unit = .pixels;
    }
    if (number.len == 0) return error.InvalidValue;

    const size = std.fmt.parseFloat(f32, number) catch return error.InvalidValue;
    if (!std.math.isFinite(size) or size <= 0 or size > 512) return error.InvalidValue;
    return switch (unit) {
        .points => .{ .points = size },
        .pixels => .{ .pixels = size },
    };
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

fn parseOpacity(value: []const u8) error{InvalidValue}!u8 {
    const opacity = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidValue;
    if (opacity == 1) return 255;
    return @min(254, @as(u8, @intFromFloat(@round(opacity * 255))));
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

/// Convert a configured size to physical pixels. Point sizes use the
/// conventional Linux 96 DPI baseline; pixel sizes are already logical pixels.
pub fn fontSizePixels(size: FontSize, scale120: u32) u31 {
    std.debug.assert(std.math.isFinite(size.value()) and size.value() > 0);
    std.debug.assert(scale120 > 0);

    const output_scale = @as(f64, @floatFromInt(scale120)) / 120.0;
    const logical_pixels: f64 = switch (size) {
        .points => |points| @as(f64, points) * baseline_dpi / points_per_inch,
        .pixels => |pixels| pixels,
    };
    const pixels = logical_pixels * output_scale;
    return @max(1, @as(u31, @intFromFloat(@round(pixels))));
}

pub const colorsForScheme = config_theme.colorsForScheme;

fn namedThemeOverrides(self: *const Config, color_scheme: vt.device_status.ColorScheme) ?*const ThemeOverrides {
    return switch (color_scheme) {
        .light => if (self.light_theme_overrides) |*theme| theme else null,
        .dark => if (self.dark_theme_overrides) |*theme| theme else null,
    };
}

fn effectiveColor(
    self: *const Config,
    color_scheme: vt.device_status.ColorScheme,
    comptime field: []const u8,
) vt.color.RGB {
    const named = if (self.namedThemeOverrides(color_scheme)) |theme|
        @field(theme, field)
    else
        null;
    return config_theme.resolveColor(
        @field(self, field),
        named,
        @field(colorsForScheme(color_scheme), field),
    );
}

pub fn effectiveSelectionBackground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.effectiveColor(color_scheme, "selection_background");
}

pub fn effectiveSelectionForeground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.effectiveColor(color_scheme, "selection_foreground");
}

pub fn effectiveCopyHighlight(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.effectiveColor(color_scheme, "copy_highlight");
}

pub fn effectiveCopyHighlightForeground(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.color.RGB {
    return self.effectiveColor(color_scheme, "copy_highlight_foreground");
}

pub fn effectiveCursorText(self: *const Config, color_scheme: vt.device_status.ColorScheme) ?vt.color.RGB {
    const named = if (self.namedThemeOverrides(color_scheme)) |theme| theme.cursor_text else null;
    return self.cursor_text orelse named;
}

/// The terminal color options this config describes: config colors form
/// the *default* layer, so OSC 10/11/12/4 can still override and reset.
pub fn terminalColors(self: *const Config, color_scheme: vt.device_status.ColorScheme) vt.Terminal.Colors {
    const themed = colorsForScheme(color_scheme);
    const palette = config_theme.resolvePalette(
        &self.palette,
        self.namedThemeOverrides(color_scheme),
        themed,
    );
    return .{
        .background = .init(self.effectiveColor(color_scheme, "background")),
        .foreground = .init(self.effectiveColor(color_scheme, "foreground")),
        .cursor = .init(self.effectiveColor(color_scheme, "cursor_color")),
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
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{}, config.window_padding_y);
    try std.testing.expectEqual(@as(?Command, null), config.command);
    try std.testing.expectEqual(@as(?[:0]const u8, null), config.pipe_command_output);
    try std.testing.expectEqual(LinuxCgroup.never, config.linux_cgroup);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 320_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 3), config.mouse_scroll_multiplier.discrete);
    try std.testing.expect(config.inertial_scrolling);
    try std.testing.expectEqual(@as(u32, 200), config.copy_highlight_duration);
    try std.testing.expectEqual(@as(u8, 255), config.background_opacity);
    try std.testing.expect(config.background_blur);
    try std.testing.expect(!config.background_opacity_cells);
    try std.testing.expectEqual(@as(?Theme, null), config.theme);
    try std.testing.expectEqual(@as(?ThemeOverrides, null), config.light_theme_overrides);
    try std.testing.expectEqual(@as(?ThemeOverrides, null), config.dark_theme_overrides);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.foreground);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.cursor_color);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.cursor_text);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.selection_background);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.selection_foreground);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.copy_highlight);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.copy_highlight_foreground);
    for (config.palette) |entry| try std.testing.expectEqual(@as(?vt.color.RGB, null), entry);
    try std.testing.expectEqual(dark_theme.selection_background, config.effectiveSelectionBackground(.dark));
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground(.dark));
    try std.testing.expectEqual(dark_theme.copy_highlight, config.effectiveCopyHighlight(.dark));
    try std.testing.expectEqual(dark_theme.copy_highlight_foreground, config.effectiveCopyHighlightForeground(.dark));
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
        \\inertial-scrolling = false
        \\copy-highlight-duration = 250
        \\background-opacity = 0.8
        \\background-blur = false
        \\background-opacity-cells = true
        \\background = #1a1b26
        \\foreground = c0caf5
        \\cursor-color = #aabbcc
        \\cursor-text = #010203
        \\selection-background = #040506
        \\selection-foreground = #070809
        \\copy-highlight = #0a0b0c
        \\copy-highlight-foreground = #0d0e0f
        \\palette = 1=#f7768e
        \\palette = 200=#123456
        \\
        \\bogus-key = whatever
        \\font-size = not-a-number
    );

    try std.testing.expectEqualStrings("com.example.scratchpad", config.app_id);
    try std.testing.expectEqualStrings("Fira Code", config.font_family);
    // invalid re-assignment keeps the previous valid value
    try std.testing.expectEqual(FontSize{ .points = 14.5 }, config.font_size);
    try std.testing.expectEqual(WindowPadding{ .first = 4, .second = 4 }, config.window_padding_x);
    try std.testing.expectEqual(WindowPadding{ .first = 6, .second = 10 }, config.window_padding_y);
    try std.testing.expectEqualStrings("/usr/bin/fish --login", config.command.?.shell);
    try std.testing.expectEqualStrings("cat > /tmp/monstar-output", config.pipe_command_output.?);
    try std.testing.expectEqual(LinuxCgroup.always, config.linux_cgroup);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.scrollback_limit);
    try std.testing.expectEqual(@as(usize, 50_000_000), config.image_storage_limit);
    try std.testing.expectEqual(@as(f64, 1.5), config.mouse_scroll_multiplier.precision);
    try std.testing.expectEqual(@as(f64, 5), config.mouse_scroll_multiplier.discrete);
    try std.testing.expect(!config.inertial_scrolling);
    try std.testing.expectEqual(@as(u32, 250), config.copy_highlight_duration);
    try std.testing.expectEqual(@as(u8, 204), config.background_opacity);
    try std.testing.expect(!config.background_blur);
    try std.testing.expect(config.background_opacity_cells);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1a, .g = 0x1b, .b = 0x26 }, config.background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xc0, .g = 0xca, .b = 0xf5 }, config.foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, config.cursor_color.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, config.cursor_text.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, config.selection_background.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.selection_foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 10, .g = 11, .b = 12 }, config.copy_highlight.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 13, .g = 14, .b = 15 }, config.copy_highlight_foreground.?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf7, .g = 0x76, .b = 0x8e }, config.palette[1].?);
    try std.testing.expectEqual(@as(?vt.color.RGB, null), config.palette[2]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, config.palette[200].?);
}

test "unknown override is rejected" {
    var config: Config = .{};
    try std.testing.expectError(
        error.UnknownKey,
        config.applyOverride(std.testing.allocator, "font-famly=monospace"),
    );
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

test "theme accepts a shared name or light and dark names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config: Config = .{};
    try config.set(arena, "theme", "TokyoNight");
    try std.testing.expectEqualStrings("TokyoNight", config.theme.?.light);
    try std.testing.expectEqualStrings("TokyoNight", config.theme.?.dark);

    try config.set(arena, "theme", " dark:Rose Pine , light:Rose Pine Dawn ");
    try std.testing.expectEqualStrings("Rose Pine Dawn", config.theme.?.light);
    try std.testing.expectEqualStrings("Rose Pine", config.theme.?.dark);
    try std.testing.expectError(error.InvalidValue, config.set(arena, "theme", "light:Rose Pine Dawn"));
    try std.testing.expectError(error.InvalidValue, config.set(arena, "theme", "light:One,dark:Two,dark:Three"));
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

test "inertial scrolling accepts booleans" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "inertial-scrolling", "false");
    try std.testing.expect(!config.inertial_scrolling);
    try config.set(std.testing.allocator, "inertial-scrolling", "true");
    try std.testing.expect(config.inertial_scrolling);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "inertial-scrolling", "yes"));
}

test "copy highlight duration accepts milliseconds and zero" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "copy-highlight-duration", "350");
    try std.testing.expectEqual(@as(u32, 350), config.copy_highlight_duration);
    try config.set(std.testing.allocator, "copy-highlight-duration", "0");
    try std.testing.expectEqual(@as(u32, 0), config.copy_highlight_duration);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "copy-highlight-duration", "-1"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "copy-highlight-duration", "1.5"));
}

test "background opacity accepts the closed unit interval" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "background-opacity", "0");
    try std.testing.expectEqual(@as(u8, 0), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "0.5");
    try std.testing.expectEqual(@as(u8, 128), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "1");
    try std.testing.expectEqual(@as(u8, 255), config.background_opacity);
    try config.set(std.testing.allocator, "background-opacity", "0.999");
    try std.testing.expectEqual(@as(u8, 254), config.background_opacity);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "-0.1"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "1.1"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity", "nan"));
}

test "background blur accepts booleans" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "background-blur", "false");
    try std.testing.expect(!config.background_blur);
    try config.set(std.testing.allocator, "background-blur", "true");
    try std.testing.expect(config.background_blur);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-blur", "yes"));
}

test "background opacity cells accepts booleans" {
    var config: Config = .{};
    try config.set(std.testing.allocator, "background-opacity-cells", "true");
    try std.testing.expect(config.background_opacity_cells);
    try config.set(std.testing.allocator, "background-opacity-cells", "false");
    try std.testing.expect(!config.background_opacity_cells);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "background-opacity-cells", "yes"));
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
    try std.testing.expectEqual(@as(u31, 16), fontSizePixels(.{ .points = 12 }, 120));
    try std.testing.expectEqual(@as(u31, 24), fontSizePixels(.{ .points = 12 }, 180));
    try std.testing.expectEqual(@as(u31, 32), fontSizePixels(.{ .points = 12 }, 240));
    try std.testing.expectEqual(@as(u31, 17), fontSizePixels(.{ .points = 12.5 }, 120));
}

test "font size pixels scale directly with the output" {
    try std.testing.expectEqual(@as(u31, 12), fontSizePixels(.{ .pixels = 12 }, 120));
    try std.testing.expectEqual(@as(u31, 18), fontSizePixels(.{ .pixels = 12 }, 180));
    try std.testing.expectEqual(@as(u31, 24), fontSizePixels(.{ .pixels = 12 }, 240));
}

test "font size accepts bare points and explicit point or pixel units" {
    var config: Config = .{};

    try config.set(std.testing.allocator, "font-size", "12");
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try config.set(std.testing.allocator, "font-size", "12pt");
    try std.testing.expectEqual(FontSize{ .points = 12 }, config.font_size);
    try config.set(std.testing.allocator, "font-size", "12px");
    try std.testing.expectEqual(FontSize{ .pixels = 12 }, config.font_size);
    try std.testing.expectEqual(@as(u31, 12), fontSizePixels(config.font_size, 120));

    try config.set(std.testing.allocator, "font-size", "16.5px");
    try std.testing.expectEqual(FontSize{ .pixels = 16.5 }, config.font_size);
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "font-size", "12em"));
    try std.testing.expectError(error.InvalidValue, config.set(std.testing.allocator, "font-size", "px"));
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
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(dark_theme.cursor_color, colors.cursor.get().?);
    try std.testing.expectEqual(dark_theme.palette[0], colors.palette.current[0]);
    try std.testing.expectEqual(dark_theme.palette[15], colors.palette.current[15]);
}

test "built-in colors follow color scheme" {
    const config: Config = .{};
    const light_colors = config.terminalColors(.light);
    try std.testing.expectEqual(light_theme.background, light_colors.background.get().?);
    try std.testing.expectEqual(light_theme.foreground, light_colors.foreground.get().?);
    try std.testing.expectEqual(light_theme.selection_background, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(light_theme.selection_foreground, config.effectiveSelectionForeground(.light));
    try std.testing.expectEqual(light_theme.copy_highlight, config.effectiveCopyHighlight(.light));
    try std.testing.expectEqual(light_theme.copy_highlight_foreground, config.effectiveCopyHighlightForeground(.light));

    const dark_colors = config.terminalColors(.dark);
    try std.testing.expectEqual(dark_theme.background, dark_colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, dark_colors.foreground.get().?);
    try std.testing.expectEqual(dark_theme.cursor_color, dark_colors.cursor.get().?);
    try std.testing.expectEqual(dark_theme.copy_highlight, config.effectiveCopyHighlight(.dark));
    try std.testing.expectEqual(dark_theme.copy_highlight_foreground, config.effectiveCopyHighlightForeground(.dark));
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
        \\copy-highlight = #0a0b0c
        \\copy-highlight-foreground = #0d0e0f
    );

    const colors = config.terminalColors(.dark);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, colors.background.get().?);
    try std.testing.expectEqual(dark_theme.foreground, colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, colors.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveSelectionBackground(.dark));
    try std.testing.expectEqual(dark_theme.selection_foreground, config.effectiveSelectionForeground(.dark));
    try std.testing.expectEqual(vt.color.RGB{ .r = 10, .g = 11, .b = 12 }, config.effectiveCopyHighlight(.dark));
    try std.testing.expectEqual(vt.color.RGB{ .r = 13, .g = 14, .b = 15 }, config.effectiveCopyHighlightForeground(.dark));
}

test "named themes follow color scheme and remain below explicit colors" {
    var config: Config = .{};
    config.light_theme_overrides = config_theme.parseOverrides(
        \\background = #eeeeee
        \\foreground = #111111
        \\cursor-color = #222222
        \\cursor-text = #fedcba
        \\selection-background = #dddddd
        \\selection-foreground = #333333
        \\copy-highlight = #ffe629
        \\copy-highlight-foreground = #1c2024
        \\palette = 1=#440000
        \\palette = 200=#abcdef
    );
    config.dark_theme_overrides = config_theme.parseOverrides(
        \\background = #101010
        \\foreground = #f0f0f0
        \\selection-background = #303030
        \\selection-foreground = #e0e0e0
        \\palette = 1=#ff0000
    );
    config.background = .{ .r = 1, .g = 2, .b = 3 };
    config.palette[1] = .{ .r = 4, .g = 5, .b = 6 };

    const light = config.terminalColors(.light);
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, light.background.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x11, .g = 0x11, .b = 0x11 }, light.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x22, .g = 0x22, .b = 0x22 }, light.cursor.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, light.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xab, .g = 0xcd, .b = 0xef }, light.palette.current[200]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xdd, .g = 0xdd, .b = 0xdd }, config.effectiveSelectionBackground(.light));
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xff, .g = 0xe6, .b = 0x29 }, config.effectiveCopyHighlight(.light));
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x1c, .g = 0x20, .b = 0x24 }, config.effectiveCopyHighlightForeground(.light));
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xfe, .g = 0xdc, .b = 0xba }, config.effectiveCursorText(.light).?);

    config.cursor_text = .{ .r = 7, .g = 8, .b = 9 };
    try std.testing.expectEqual(vt.color.RGB{ .r = 7, .g = 8, .b = 9 }, config.effectiveCursorText(.light).?);

    const dark = config.terminalColors(.dark);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xf0, .g = 0xf0, .b = 0xf0 }, dark.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, dark.palette.current[1]);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xe0, .g = 0xe0, .b = 0xe0 }, config.effectiveSelectionForeground(.dark));
}

test "absolute theme file resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "custom-theme", .{});
    try file.writeStreamingAll(std.testing.io,
        \\background = #123456
        \\palette = 15=#abcdef
    );
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "custom-theme", &path_buf);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try arena.dupeZ(u8, path_buf[0..path_len]);

    var config: Config = .{ .theme = .{ .light = path, .dark = path } };
    try config.resolveThemes(std.testing.io, arena, .empty);
    const colors = config.terminalColors(.dark);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, colors.background.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xab, .g = 0xcd, .b = 0xef }, colors.palette.current[15]);
}
