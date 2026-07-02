//! The live terminal application: owns the terminal state, PTY, renderer,
//! and window, and runs the event loop that ties them together.
//!
//! The loop polls two fds: the Wayland display and the PTY master. PTY
//! output feeds the terminal and schedules a redraw; redraws are throttled
//! by the window's frame callbacks.

const App = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const Keyboard = @import("Keyboard.zig");
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
keyboard: Keyboard,
/// Terminal contents changed since the last committed frame.
needs_redraw: bool,
/// Cached DEC mode 2048 state, to detect the application enabling
/// in-band size reports.
in_band_reports: bool,
/// The child hung up; drain and quit.
child_eof: bool,
/// Key repeat: timerfd armed while a repeating key is held.
repeat_fd: posix.fd_t,
repeat_keycode: ?u32,
/// From wl_keyboard.repeat_info: characters per second and delay in ms.
repeat_rate: i32,
repeat_delay: i32,

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

    const repeat_rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
    if (std.os.linux.errno(repeat_rc) != .SUCCESS) return error.TimerFdFailed;
    const repeat_fd: posix.fd_t = @intCast(repeat_rc);
    errdefer _ = std.os.linux.close(repeat_fd);

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
        .keyboard = try .init(),
        .needs_redraw = true,
        .in_band_reports = false,
        .child_eof = false,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
    };
    self.stream = self.term.vtStream();

    // Handle sequences that need responses or side effects.
    var effects: Effects = .readonly;
    effects.write_pty = effectWritePty;
    effects.device_attributes = effectDeviceAttributes;
    effects.enquiry = effectEnquiry;
    effects.size = effectSize;
    effects.color_scheme = effectColorScheme;
    effects.xtversion = effectXtversion;
    effects.title_changed = effectTitleChanged;
    self.stream.handler.effects = effects;

    window.setCallbacks(self, render, resize, keyboardEvent);
    return self;
}

const Handler = vt.TerminalStream.Handler;
const Effects = Handler.Effects;

/// Effects callbacks only receive the handler; walk back up to the App
/// through the stream that embeds it.
fn appFromHandler(handler: *Handler) *App {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    return @fieldParentPtr("stream", stream);
}

/// Return type of an Effects callback, e.g. device_attributes.
fn EffectResult(comptime field_name: []const u8) type {
    const FnPtr = @typeInfo(@FieldType(Effects, field_name)).optional.child;
    return @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
}

fn effectWritePty(handler: *Handler, data: [:0]const u8) void {
    appFromHandler(handler).writePty(data);
}

fn effectDeviceAttributes(_: *Handler) EffectResult("device_attributes") {
    // Defaults report a reasonable VT220-level terminal.
    return .{};
}

fn effectEnquiry(_: *Handler) []const u8 {
    return "";
}

fn effectSize(handler: *Handler) ?vt.size_report.Size {
    return appFromHandler(handler).currentSize();
}

fn currentSize(self: *App) vt.size_report.Size {
    return .{
        .rows = self.term.rows,
        .columns = self.term.cols,
        .cell_width = self.font.cell_width,
        .cell_height = self.font.cell_height,
    };
}

fn effectColorScheme(_: *Handler) ?vt.device_status.ColorScheme {
    return .dark;
}

fn effectXtversion(_: *Handler) []const u8 {
    return "vtread 0.0.0";
}

fn effectTitleChanged(handler: *Handler) void {
    const self = appFromHandler(handler);
    const title = self.term.getTitle() orelse return;
    self.window.toplevel.setTitle(title.ptr);
}

pub fn deinit(self: *App) void {
    _ = std.os.linux.close(self.repeat_fd);
    self.keyboard.deinit();
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
        .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const wl_fd = &fds[0];
    const pty_fd = &fds[1];
    const repeat_fd = &fds[2];

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

        if (repeat_fd.revents & posix.POLL.IN != 0) {
            self.fireRepeat();
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
    self.syncInBandSizeReports();
    self.needs_redraw = true;
}

/// DEC mode 2048 (in-band size reports): the terminal must send a size
/// report when the application enables the mode, and again on every
/// resize while it stays enabled. Neovim relies on these instead of
/// SIGWINCH once DECRQM confirms support.
///
/// Detected by edge-triggering on the mode value after each PTY chunk,
/// so re-enabling an already-enabled mode sends no duplicate report.
fn syncInBandSizeReports(self: *App) void {
    const enabled = self.term.modes.get(.in_band_size_reports);
    if (enabled and !self.in_band_reports) self.sendSizeReport();
    self.in_band_reports = enabled;
}

fn sendSizeReport(self: *App) void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    vt.size_report.encode(&writer, .mode_2048, self.currentSize()) catch return;
    self.writePty(writer.buffered());
}

/// Window keyboard delegate: track xkb state and encode key presses
/// into PTY input.
fn keyboardEvent(ctx: *anyopaque, event: wl.Keyboard.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .keymap => |keymap| {
            if (keymap.format != .xkb_v1) {
                log.err("unsupported keymap format {}", .{keymap.format});
                _ = std.os.linux.close(keymap.fd);
                return;
            }
            // setKeymap takes ownership of the fd.
            self.keyboard.setKeymap(keymap.fd, keymap.size) catch |err| {
                log.err("keymap load failed: {}", .{err});
            };
        },
        .modifiers => |mods| self.keyboard.updateMods(
            mods.mods_depressed,
            mods.mods_latched,
            mods.mods_locked,
            mods.group,
        ),
        .key => |key| {
            const action: vt.input.KeyAction = switch (key.state) {
                .pressed => .press,
                .released => .release,
                else => return,
            };
            self.onKey(key.key, action);
            switch (action) {
                .press => if (self.keyboard.keyRepeats(key.key)) self.armRepeat(key.key),
                .release => if (self.repeat_keycode == key.key) self.cancelRepeat(),
                else => {},
            }
        },
        .repeat_info => |info| {
            self.repeat_rate = info.rate;
            self.repeat_delay = info.delay;
        },
        // Keys held across a focus change must not keep repeating.
        .leave => self.cancelRepeat(),
        .enter => {},
    }
}

/// Start (or move) key repeat to the given key: first fire after the
/// configured delay, then at the configured rate.
fn armRepeat(self: *App, evdev_keycode: u32) void {
    if (self.repeat_rate <= 0 or self.repeat_delay <= 0) return;
    self.repeat_keycode = evdev_keycode;

    const delay_ms: u64 = @intCast(self.repeat_delay);
    const interval_ns: u64 = @divTrunc(std.time.ns_per_s, @as(u64, @intCast(self.repeat_rate)));
    self.setRepeatTimer(.{
        .it_value = timespecFromNs(delay_ms * std.time.ns_per_ms),
        .it_interval = timespecFromNs(interval_ns),
    });
}

fn cancelRepeat(self: *App) void {
    self.repeat_keycode = null;
    self.setRepeatTimer(.{
        .it_value = .{ .sec = 0, .nsec = 0 },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    });
}

fn setRepeatTimer(self: *App, spec: std.os.linux.itimerspec) void {
    const rc = std.os.linux.timerfd_settime(self.repeat_fd, .{}, &spec, null);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        log.err("timerfd_settime failed: {}", .{std.os.linux.errno(rc)});
    }
}

fn timespecFromNs(ns: u64) std.os.linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// The repeat timer expired: re-send the held key.
fn fireRepeat(self: *App) void {
    var expirations: u64 = 0;
    const n = posix.read(self.repeat_fd, std.mem.asBytes(&expirations)) catch return;
    if (n != @sizeOf(u64)) return;
    const keycode = self.repeat_keycode orelse return;
    // Cap the burst so a stalled loop can't flood the PTY.
    for (0..@min(expirations, 8)) |_| self.onKey(keycode, .repeat);
}

fn onKey(self: *App, evdev_keycode: u32, action: vt.input.KeyAction) void {
    var utf8_buf: [16]u8 = undefined;
    const event = self.keyboard.translate(&utf8_buf, evdev_keycode, action) orelse return;

    var out_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    vt.input.encodeKey(&writer, event, .fromTerminal(&self.term)) catch |err| {
        log.err("key encode failed: {}", .{err});
        return;
    };
    const bytes = writer.buffered();
    if (bytes.len == 0) return;
    self.writePty(bytes);
}

fn writePty(self: *App, bytes: []const u8) void {
    const linux = std.os.linux;
    var remaining = bytes;
    while (remaining.len > 0) {
        const rc = linux.write(self.pty.master, remaining.ptr, remaining.len);
        switch (linux.errno(rc)) {
            .SUCCESS => remaining = remaining[rc..],
            .INTR => continue,
            else => |err| {
                log.err("pty write failed: {}", .{err});
                return;
            },
        }
    }
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
    if (self.term.modes.get(.in_band_size_reports)) self.sendSizeReport();
    self.needs_redraw = true;
}
