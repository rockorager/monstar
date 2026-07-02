//! The live terminal application: owns the terminal state, PTY, renderer,
//! and window, and runs the event loop that ties them together.
//!
//! The loop polls two fds: the Wayland display and the PTY master. PTY
//! output feeds the terminal and schedules a redraw; redraws are throttled
//! by the window's frame callbacks.

const App = @This();

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const Pty = @import("Pty.zig");
const Renderer = @import("Renderer.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.app);

alloc: std.mem.Allocator,
term: vt.Terminal,
stream: vt.TerminalStream,
render_state: vt.RenderState,
pty: Pty,
child_pid: posix.pid_t,
font: Font,
renderer: Renderer,
window: *Window,
/// Terminal contents changed since the last committed frame.
needs_redraw: bool,
/// The child hung up; drain and quit.
child_eof: bool,

const initial_cols = 80;
const initial_rows = 24;

pub const Options = struct {
    font_family: [:0]const u8 = "monospace",
    font_size_px: u31 = 16,
};

/// `argv`/`envp` must stay valid for the lifetime of the call (the child
/// copies them via execve).
pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    opts: Options,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) !*App {
    var font: Font = try .init(opts.font_family, opts.font_size_px);
    errdefer font.deinit(alloc);

    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = initial_cols,
        .rows = initial_rows,
    });
    errdefer term.deinit(alloc);

    var pty: Pty = try .open(.{
        .row = initial_rows,
        .col = initial_cols,
        .xpixel = @intCast(initial_cols * font.cell_width),
        .ypixel = @intCast(initial_rows * font.cell_height),
    });
    errdefer pty.deinit();
    const child_pid = try pty.spawn(path, argv, envp);

    const window = try Window.create(alloc);
    errdefer window.destroy();

    // Self-reference into listeners/streams requires a stable address.
    const self = try alloc.create(App);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .term = term,
        .stream = undefined, // needs the final Terminal address; set below
        .render_state = .empty,
        .pty = pty,
        .child_pid = child_pid,
        .font = font,
        .renderer = try .init(alloc, &self.font),
        .window = window,
        .needs_redraw = true,
        .child_eof = false,
    };
    self.stream = self.term.vtStream();
    window.setCallbacks(self, render, resize);
    return self;
}

pub fn deinit(self: *App) void {
    self.window.destroy();
    self.renderer.deinit();
    self.render_state.deinit(self.alloc);
    self.stream.deinit();
    self.term.deinit(self.alloc);
    self.pty.deinit();
    self.font.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Run until the window is closed or the child exits.
pub fn run(self: *App) !void {
    const display = self.window.display;
    var fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 },
    };
    const wl_fd = &fds[0];
    const pty_fd = &fds[1];

    while (self.window.running and !self.child_eof) {
        // Standard libwayland read dance: drain the local queue, flush
        // requests, then sleep until one of the fds is ready.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        if (display.flush() != .SUCCESS) {
            display.cancelRead();
            return error.FlushFailed;
        }

        _ = posix.poll(&fds, -1) catch |err| {
            display.cancelRead();
            return err;
        };

        if (wl_fd.revents & posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
        } else {
            display.cancelRead();
        }
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;

        if (pty_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.readPty();
        }

        if (self.needs_redraw) {
            self.needs_redraw = false;
            try self.window.redraw();
        }
    }

    _ = Pty.wait(self.child_pid) catch {};
}

/// Read one chunk of PTY output into the terminal.
fn readPty(self: *App) void {
    var buf: [16 * 1024]u8 = undefined;
    const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
        // EIO on the master means the slave side is gone (child exited).
        error.Unexpected, error.InputOutput => {
            self.child_eof = true;
            return;
        },
        else => {
            log.err("pty read failed: {}", .{err});
            self.child_eof = true;
            return;
        },
    };
    if (n == 0) {
        self.child_eof = true;
        return;
    }
    self.stream.nextSlice(buf[0..n]);
    self.needs_redraw = true;
}

/// Window render delegate: refresh the render state and draw the grid.
fn render(ctx: *anyopaque, pixels: []u32, width: u31, height: u31) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.render_state.update(self.alloc, &self.term);
    self.render_state.dirty = .false;
    try self.renderer.render(&self.render_state, pixels, width, height);
}

/// Window resize delegate: fit the grid to the new size, resize the
/// terminal (reflow) and tell the child.
fn resize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const cols: u16 = @intCast(@min(std.math.maxInt(u16), @max(1, width / self.font.cell_width)));
    const rows: u16 = @intCast(@min(std.math.maxInt(u16), @max(1, height / self.font.cell_height)));
    if (cols == self.term.cols and rows == self.term.rows) return;

    log.debug("resize to {d}x{d} cells", .{ cols, rows });
    try self.term.resize(self.alloc, cols, rows);
    try self.pty.setWinsize(.{
        .row = rows,
        .col = cols,
        .xpixel = @intCast(width),
        .ypixel = @intCast(height),
    });
    self.needs_redraw = true;
}
