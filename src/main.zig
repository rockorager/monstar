//! Application entry point.
//!
//! `monstar [command...]` runs a command (default: $SHELL) in a Wayland
//! terminal window with live output.
//! `monstar --dump [command...]` runs a command to completion headlessly
//! and prints the emulated screen as text.

const std = @import("std");
const vt = @import("ghostty-vt");
const App = @import("App.zig");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Pty = @import("Pty.zig");
const Renderer = @import("Renderer.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.main);

const cols = 80;
const rows = 24;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "--dump")) {
        return dump(init, args[2..]);
    }
    return gui(init, args[1..]);
}

/// Run a command to completion under terminal emulation, filling `term`.
fn runCommand(init: std.process.Init, term: *vt.Terminal, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();

    // Command to run: CLI args joined, or a colorful default.
    const cmd: [:0]const u8 = if (args.len > 0)
        try std.mem.joinZ(arena, " ", args)
    else
        "ls --color=auto /";

    var stream = term.vtStream();
    defer stream.deinit();

    var pty: Pty = try .open(.{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 });
    defer pty.deinit();

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
    const envp = try buildEnvp(arena, init.minimal.environ);
    const pid = try pty.spawn("/bin/sh", &argv, envp);

    // Drain PTY output into the terminal until the child hangs up.
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(pty.master, &read_buf) catch |err| switch (err) {
            // EIO on the master means the slave side is gone (child exited).
            error.Unexpected, error.InputOutput => break,
            else => return err,
        };
        if (n == 0) break;
        stream.nextSlice(read_buf[0..n]);
    }
    const status = try Pty.wait(pid);
    log.debug("child exited with status {d}", .{status});
}

/// GUI mode: run a live terminal session in a window.
fn gui(init: std.process.Init, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();

    const config = Config.load(arena, init.minimal.environ);

    // With arguments, run them as a shell command; otherwise run the
    // configured shell (falling back to $SHELL) interactively.
    const shell: [:0]const u8 = config.shell orelse
        init.minimal.environ.getPosix("SHELL") orelse
        "/bin/sh";
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    if (args.len > 0) {
        try argv.appendSlice(arena, &.{ "/bin/sh", "-c", try std.mem.joinZ(arena, " ", args) });
    } else {
        try argv.append(arena, shell.ptr);
    }
    const argv_z = try argv.toOwnedSliceSentinel(arena, null);
    const envp = try buildEnvp(arena, init.minimal.environ);

    const app = try App.init(init.io, init.gpa, config, init.minimal.environ, argv_z[0].?, argv_z.ptr, envp);
    defer app.deinit();
    try app.run();
}

/// Headless mode: run a command under terminal emulation, print the screen.
fn dump(init: std.process.Init, args: []const [:0]const u8) !void {
    const alloc = init.gpa;

    var term: vt.Terminal = try .init(init.io, alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    try runCommand(init, &term, args);

    const text = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(text);

    var out_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print("{s}\n", .{text});
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
    _ = Config;
    _ = Font;
    _ = @import("Keyboard.zig");
    _ = Pty;
    _ = Renderer;
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
