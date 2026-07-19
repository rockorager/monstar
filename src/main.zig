//! Application entry point.
//!
//! `monstar [options]` runs a shell in a Wayland terminal window.

const std = @import("std");
const build_options = @import("build_options");
const vt = @import("ghostty-vt");
const App = @import("App.zig");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Link = @import("Link.zig");
const Pty = @import("Pty.zig");
const Renderer = @import("Renderer.zig");
const TerminalLayout = @import("TerminalLayout.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const cli = parseCli(arena, args[1..]) catch |err| switch (err) {
        error.InvalidCli => invalidCli(init),
        else => return err,
    };
    switch (cli.action) {
        .run => {},
        .bench => return @import("bench.zig").run(init),
        .help => return printUsage(init),
        .version => return printVersion(init),
    }

    return gui(init, cli) catch |err| switch (err) {
        error.InvalidCli => invalidCli(init),
        else => return err,
    };
}

const CliAction = enum { run, bench, help, version };

const CommandMode = enum { shell, exec };

const CliOptions = struct {
    action: CliAction = .run,
    config_path: ?[:0]const u8 = null,
    config_overrides: []const []const u8 = &.{},
    working_directory: ?[:0]const u8 = null,
    title: [:0]const u8 = "monstar",
    initial_size: App.InitialSize = .default,
    hold: bool = false,
    command_mode: CommandMode = .shell,
    command: []const [:0]const u8 = &.{},
};

const CliError = error{InvalidCli} || std.mem.Allocator.Error;

fn parseCli(arena: std.mem.Allocator, args: []const [:0]const u8) CliError!CliOptions {
    var parser: CliParser = .{ .arena = arena, .args = args };
    return parser.parse();
}

const CliParser = struct {
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    index: usize = 0,
    cli: CliOptions = .{},
    overrides: std.ArrayList([]const u8) = .empty,

    fn parse(self: *CliParser) CliError!CliOptions {
        while (self.index < self.args.len) : (self.index += 1) {
            const arg = self.args[self.index];
            if (std.mem.eql(u8, arg, "--bench")) {
                self.cli.action = .bench;
                return self.cli;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                self.cli.action = .help;
                return self.cli;
            } else if (std.mem.eql(u8, arg, "--version")) {
                self.cli.action = .version;
                return self.cli;
            } else if (std.mem.eql(u8, arg, "--")) {
                self.setCommand(.shell, self.index + 1);
                break;
            } else if (std.mem.eql(u8, arg, "-e")) {
                if (self.index + 1 >= self.args.len) return error.InvalidCli;
                self.setCommand(.exec, self.index + 1);
                break;
            } else if (try self.pathOption(arg, "--config", &self.cli.config_path)) {
                continue;
            } else if (try self.pathOption(arg, "--title", &self.cli.title)) {
                continue;
            } else if (try self.pathOption(arg, "--working-directory", &self.cli.working_directory)) {
                continue;
            } else if (std.mem.eql(u8, arg, "--hold")) {
                self.cli.hold = true;
            } else if (try self.configOption(arg, "--app-id", "app-id")) {
                continue;
            } else if (try self.configOption(arg, "--font", "font-family")) {
                continue;
            } else if (std.mem.eql(u8, arg, "-o")) {
                try self.appendRawOverride(try self.nextValue());
            } else if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
                try self.appendRawOverride(arg[2..]);
            } else if (try self.initialSizeOption(arg, "--window-size-chars", .chars)) {
                continue;
            } else if (try self.initialSizeOption(arg, "--window-size-pixels", .pixels)) {
                continue;
            } else {
                // Keep bare words reserved for future subcommands. Commands
                // must use `-e` or `--` so option parsing stays extensible.
                return error.InvalidCli;
            }
        }

        self.cli.config_overrides = try self.overrides.toOwnedSlice(self.arena);
        return self.cli;
    }

    fn setCommand(self: *CliParser, mode: CommandMode, start: usize) void {
        self.cli.command = self.args[start..];
        self.cli.command_mode = mode;
        self.index = self.args.len;
    }

    fn pathOption(self: *CliParser, arg: []const u8, long: []const u8, out: anytype) CliError!bool {
        if (std.mem.eql(u8, arg, long)) {
            out.* = try self.nextValue();
            return true;
        }
        if (self.optionValue(arg, long)) |value| {
            out.* = try self.arena.dupeZ(u8, value);
            return true;
        }
        return false;
    }

    fn configOption(self: *CliParser, arg: []const u8, long: []const u8, key: []const u8) CliError!bool {
        if (std.mem.eql(u8, arg, long)) {
            try self.appendOverride(key, try self.nextValue());
            return true;
        }
        if (self.optionValue(arg, long)) |value| {
            try self.appendOverride(key, value);
            return true;
        }
        return false;
    }

    const SizeKind = enum { chars, pixels };

    fn initialSizeOption(self: *CliParser, arg: []const u8, long: []const u8, kind: SizeKind) CliError!bool {
        const value = value: {
            if (std.mem.eql(u8, arg, long)) break :value try self.nextValue();
            break :value self.optionValue(arg, long) orelse return false;
        };
        self.cli.initial_size = switch (kind) {
            .chars => try parseInitialChars(value),
            .pixels => try parseInitialPixels(value),
        };
        return true;
    }

    fn nextValue(self: *CliParser) CliError![:0]const u8 {
        if (self.index + 1 >= self.args.len) return error.InvalidCli;
        self.index += 1;
        return self.args[self.index];
    }

    fn optionValue(_: *CliParser, arg: []const u8, long: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, arg, long) or arg.len <= long.len or arg[long.len] != '=') return null;
        const value = arg[long.len + 1 ..];
        return if (value.len == 0) null else value;
    }

    fn appendOverride(self: *CliParser, key: []const u8, value: []const u8) !void {
        try self.appendRawOverride(try std.fmt.allocPrint(self.arena, "{s}={s}", .{ key, value }));
    }

    fn appendRawOverride(self: *CliParser, override: []const u8) !void {
        if (std.mem.indexOfScalar(u8, override, '=') == null) return error.InvalidCli;
        try self.overrides.append(self.arena, override);
    }
};

fn parseInitialChars(value: []const u8) CliError!App.InitialSize {
    const dims = try parseDimensions(value);
    if (dims.a > std.math.maxInt(u16) or dims.b > std.math.maxInt(u16)) return error.InvalidCli;
    return .{ .chars = .{ .cols = @intCast(dims.a), .rows = @intCast(dims.b) } };
}

fn parseInitialPixels(value: []const u8) CliError!App.InitialSize {
    const dims = try parseDimensions(value);
    if (dims.a > std.math.maxInt(u31) or dims.b > std.math.maxInt(u31)) return error.InvalidCli;
    return .{ .pixels = .{ .width = @intCast(dims.a), .height = @intCast(dims.b) } };
}

fn parseDimensions(value: []const u8) CliError!struct { a: u32, b: u32 } {
    const sep = std.mem.indexOfAny(u8, value, "xX") orelse return error.InvalidCli;
    if (sep == 0 or sep + 1 == value.len) return error.InvalidCli;
    const a = std.fmt.parseInt(u32, value[0..sep], 10) catch return error.InvalidCli;
    const b = std.fmt.parseInt(u32, value[sep + 1 ..], 10) catch return error.InvalidCli;
    if (a == 0 or b == 0) return error.InvalidCli;
    return .{ .a = a, .b = b };
}

fn printUsage(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(
        \\usage: monstar [options]
        \\       monstar [options] -e command [args...]
        \\       monstar [options] -- command...
        \\
        \\Options:
        \\  -h, --help                         Show this help
        \\      --version                      Show version
        \\      --title TITLE                  Set initial window title
        \\      --app-id APP_ID                Override app-id config
        \\      --working-directory DIR        Run the child in DIR
        \\      --hold                         Keep window open after command exits
        \\      --window-size-chars COLSxROWS  Set initial grid size
        \\      --window-size-pixels WxH       Set initial window size
        \\      --font FAMILY                  Override font-family config
        \\      --config PATH                  Load alternate config file
        \\  -o key=value                       Override a config key
        \\  -e command [args...]               Execute command directly
        \\  -- command...                      Run command through /bin/sh -c
        \\
    );
}

fn printVersion(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll("monstar " ++ build_options.version ++ "\n");
}

fn invalidCli(init: std.process.Init) noreturn {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(init.io, &buf);
    writer.interface.writeAll("monstar: invalid command line\nTry 'monstar --help' for usage.\n") catch {};
    writer.interface.flush() catch {};
    std.process.exit(2);
}

/// GUI mode: run a live terminal session in a window.
fn gui(init: std.process.Init, cli: CliOptions) !void {
    const arena = init.arena.allocator();

    var config = if (cli.config_path) |path|
        Config.loadPath(arena, path)
    else
        Config.load(arena, init.minimal.environ);
    for (cli.config_overrides) |override| {
        config.applyOverride(arena, override) catch return error.InvalidCli;
    }
    try config.resolveThemes(init.io, arena, init.minimal.environ);
    if (cli.working_directory) |cwd| try validateWorkingDirectory(cwd);

    const command = try buildCommand(arena, config, init.minimal.environ, cli.command_mode, cli.command);
    const envp = try buildEnvp(arena, init.minimal.environ);

    const app = try App.init(
        init.io,
        init.gpa,
        config,
        init.minimal.environ,
        command.path,
        command.argv.ptr,
        envp,
        .{
            .config_path = cli.config_path,
            .config_overrides = cli.config_overrides,
            .working_directory = cli.working_directory,
            .title = cli.title,
            .initial_size = cli.initial_size,
            .hold = cli.hold,
        },
    );
    defer app.deinit();
    try app.run();
}

const ChildCommand = struct {
    path: [*:0]const u8,
    argv: [:null]const ?[*:0]const u8,
};

fn buildCommand(
    arena: std.mem.Allocator,
    config: Config,
    environ: std.process.Environ,
    mode: CommandMode,
    command: []const [:0]const u8,
) !ChildCommand {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    var path: [*:0]const u8 = undefined;
    if (command.len > 0) switch (mode) {
        .shell => {
            path = "/bin/sh";
            try argv.appendSlice(arena, &.{ "/bin/sh", "-c", try std.mem.joinZ(arena, " ", command) });
        },
        .exec => {
            path = try App.resolveCommandPath(arena, environ, command[0]);
            for (command) |arg| try argv.append(arena, arg.ptr);
        },
    } else if (config.command) |configured| switch (configured) {
        .shell => |value| {
            path = "/bin/sh";
            try argv.appendSlice(arena, &.{ "/bin/sh", "-c", value.ptr });
        },
        .direct => |args| {
            path = try App.resolveCommandPath(arena, environ, args[0]);
            for (args) |arg| try argv.append(arena, arg.ptr);
        },
    } else {
        const shell: [:0]const u8 = environ.getPosix("SHELL") orelse
            "/bin/sh";
        path = shell.ptr;
        try argv.append(arena, shell.ptr);
    }
    return .{ .path = path, .argv = try argv.toOwnedSliceSentinel(arena, null) };
}

fn validateWorkingDirectory(path: [:0]const u8) !void {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.InvalidCli;
    _ = linux.close(@intCast(rc));
}

/// Build an envp block for the child: the inherited environment with
/// TERM forced to Ghostty's terminfo entry for now.
fn buildEnvp(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (environ.block.slice) |entry| {
        const e = entry orelse continue;
        if (std.mem.startsWith(u8, std.mem.span(e), "TERM=")) continue;
        try list.append(arena, e);
    }
    try list.append(arena, "TERM=xterm-ghostty");
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

test {
    _ = App;
    _ = @import("AsyncRaster.zig");
    _ = Config;
    _ = Font;
    _ = @import("cgroup.zig");
    _ = @import("Keyboard.zig");
    _ = @import("KittyImageCache.zig");
    _ = Link;
    _ = Pty;
    _ = @import("ReadPipeline.zig");
    _ = Renderer;
    _ = @import("pixel_copy.zig");
    _ = @import("sprite.zig");
    _ = @import("sprite/canvas.zig");
    _ = @import("sprite/draw/box.zig");
    _ = @import("sprite/draw/block.zig");
    _ = @import("sprite/draw/powerline.zig");
    _ = @import("sprite/draw/braille.zig");
    _ = @import("sprite/draw/geometric_shapes.zig");
    _ = @import("sprite/draw/branch.zig");
    _ = @import("sprite/draw/symbols_for_legacy_computing.zig");
    _ = @import("sprite/draw/symbols_for_legacy_computing_supplement.zig");
    _ = @import("sprite/draw/special.zig");
    _ = Window;
}

test "parse CLI options and config overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = [_][:0]const u8{
        "--config",            "/tmp/monstar.conf",
        "--title=Scratch",     "--app-id",
        "com.example.monstar", "--font=Iosevka",
        "-o",                  "scrollback-limit=42",
        "--window-size-chars", "100x40",
        "--working-directory", "/tmp",
        "--hold",              "-e",
        "env",                 "A=B",
    };
    const cli = try parseCli(arena, &args);

    try std.testing.expectEqualStrings("/tmp/monstar.conf", cli.config_path.?);
    try std.testing.expectEqualStrings("Scratch", cli.title);
    try std.testing.expectEqualStrings("/tmp", cli.working_directory.?);
    try std.testing.expect(cli.hold);
    try std.testing.expectEqual(.exec, cli.command_mode);
    try std.testing.expectEqualStrings("env", cli.command[0]);
    try std.testing.expectEqualStrings("A=B", cli.command[1]);
    try std.testing.expectEqual(@as(usize, 3), cli.config_overrides.len);
    try std.testing.expectEqualStrings("app-id=com.example.monstar", cli.config_overrides[0]);
    try std.testing.expectEqualStrings("font-family=Iosevka", cli.config_overrides[1]);
    try std.testing.expectEqualStrings("scrollback-limit=42", cli.config_overrides[2]);
    try std.testing.expectEqual(@as(u16, 100), cli.initial_size.chars.cols);
    try std.testing.expectEqual(@as(u16, 40), cli.initial_size.chars.rows);
}

test "configured shell command runs through sh" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try buildCommand(
        arena_state.allocator(),
        .{ .command = .{ .shell = "printf '%s' hello" } },
        .empty,
        .shell,
        &.{},
    );
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.path));
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("-c", std.mem.span(command.argv[1].?));
    try std.testing.expectEqualStrings("printf '%s' hello", std.mem.span(command.argv[2].?));
}

test "configured direct command preserves arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try buildCommand(
        arena_state.allocator(),
        .{ .command = .{ .direct = &.{ "/usr/bin/env", "A=B" } } },
        .empty,
        .shell,
        &.{},
    );
    try std.testing.expectEqualStrings("/usr/bin/env", std.mem.span(command.path));
    try std.testing.expectEqualStrings("/usr/bin/env", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("A=B", std.mem.span(command.argv[1].?));
}

test "parse CLI reserves bare words for future subcommands" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const args = [_][:0]const u8{ "echo", "hello" };
    try std.testing.expectError(error.InvalidCli, parseCli(arena_state.allocator(), &args));
}

test "parse CLI double dash command uses shell mode" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const args = [_][:0]const u8{ "--", "echo", "hello" };
    const cli = try parseCli(arena_state.allocator(), &args);

    try std.testing.expectEqual(.shell, cli.command_mode);
    try std.testing.expectEqualStrings("echo", cli.command[0]);
    try std.testing.expectEqualStrings("hello", cli.command[1]);
}

test "parse CLI rejects invalid dimensions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const args = [_][:0]const u8{ "--window-size-pixels", "80x0" };
    try std.testing.expectError(error.InvalidCli, parseCli(arena_state.allocator(), &args));
}

test "terminal emulation of simple output" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("a\r\n\x1b[1;32mb\x1b[0m\r\nc");

    const text = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(text);
    try std.testing.expectEqualStrings("a\nb\nc", text);
}
