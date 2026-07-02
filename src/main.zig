//! Application entry point.
//!
//! `vtread` opens a Wayland window (milestone 2: solid background only).
//! `vtread --dump [command...]` runs the headless pipeline: spawn a command
//! on a PTY, feed its output through ghostty-vt, and dump the screen as text.

const std = @import("std");
const vt = @import("ghostty-vt");
const Pty = @import("Pty.zig");
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

    const window = try Window.create(init.gpa);
    defer window.destroy();
    while (try window.dispatch()) {}
}

/// Headless mode: run a command under terminal emulation, print the screen.
fn dump(init: std.process.Init, args: []const [:0]const u8) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    // Command to run: CLI args joined, or a colorful default.
    const cmd: [:0]const u8 = if (args.len > 0)
        try std.mem.joinZ(arena, " ", args)
    else
        "ls --color=auto /";

    var term: vt.Terminal = try .init(init.io, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer term.deinit(alloc);

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

    // Dump the screen contents.
    const text = try term.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(text);

    var out_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &out_buf);
    defer writer.interface.flush() catch {};
    try writer.interface.print("{s}\n", .{text});
}

/// Build an envp block for the child: the inherited environment with
/// TERM forced to our terminfo entry.
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
    // TODO: ship a vtread terminfo entry; xterm-256color is a stopgap.
    try list.append(arena, "TERM=xterm-256color");
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

test {
    _ = Pty;
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
