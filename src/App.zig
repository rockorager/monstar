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
const zwp = wayland.client.zwp;
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Keyboard = @import("Keyboard.zig");
const Pty = @import("Pty.zig");
const Renderer = @import("Renderer.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.app);

alloc: std.mem.Allocator,
config: *const Config,
term: vt.Terminal,
stream: vt.TerminalStream,
render_state: vt.RenderState,
pty: Pty,
child_pid: posix.pid_t,
font: Font,
/// The physical pixel size the font is currently loaded at.
font_size_px: u31,
renderer: Renderer,
window: *Window,
keyboard: Keyboard,
/// Terminal contents changed since the last committed frame.
needs_redraw: bool,
/// Cached DEC mode 2048 state, to detect the application enabling
/// in-band size reports.
in_band_reports: bool,
/// PTY input that couldn't be written yet (master is nonblocking to
/// avoid deadlocking against a child that has stopped reading while
/// flooding output). Flushed when the master polls writable.
write_queue: std.ArrayList(u8),
/// The child hung up; drain and quit.
child_eof: bool,
/// Key repeat: timerfd armed while a repeating key is held.
repeat_fd: posix.fd_t,
repeat_keycode: ?u32,
/// From wl_keyboard.repeat_info: characters per second and delay in ms.
repeat_rate: i32,
repeat_delay: i32,
/// Pointer position in logical surface coordinates.
pointer_x: f64,
pointer_y: f64,
/// Wheel state accumulated between pointer frame events.
scroll_pixels: f64,
scroll_clicks: i32,
scroll_had_discrete: bool,
/// Left-button drag selection. The anchor is a cell-boundary caret:
/// a tracked pin for the anchored cell plus which of its vertical
/// edges (0 = left, 1 = right) the press grabbed. The pin belongs to
/// the screen that was active at press time (`sel_screen`), which is
/// the only screen it may be untracked on.
selecting: bool,
sel_anchor: ?*vt.Pin,
sel_anchor_off: u1,
sel_screen: vt.ScreenSet.Key,
/// Active screen at the last check, to detect alt screen switches.
active_screen: vt.ScreenSet.Key,
/// Serial of the most recent input event, required to claim selections.
last_serial: u32,
/// Current clipboard/primary offers from other clients (paste sources).
clip_offer: ?*wl.DataOffer,
primary_offer: ?*zwp.PrimarySelectionOfferV1,
/// Our own outgoing selection sources, so exit can reclaim them if the
/// compositor never cancels them (nobody else took the selection).
clip_source: ?*SourceCtx,
primary_source: ?*SourceCtx,
/// An in-flight paste: pipe read end (-1 when idle) and received bytes.
paste_fd: posix.fd_t,
paste_buf: std.ArrayList(u8),

const paste_mime = "text/plain;charset=utf-8";

/// Terminal lines per wheel click.
const initial_cols = 80;
const initial_rows = 24;

/// `argv`/`envp` must stay valid for the lifetime of the call (the child
/// copies them via execve); `config` must outlive the App.
pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    config: *const Config,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) !*App {
    var font: Font = try .init(alloc, config.font_family, config.font_size);
    errdefer font.deinit(alloc);

    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = initial_cols,
        .rows = initial_rows,
        .max_scrollback = config.scrollback,
        .colors = config.terminalColors(),
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

    // Nonblocking master: a blocking write can deadlock the whole loop
    // when the child floods output (echoed responses need output-queue
    // space) while we respond to queries embedded in that output.
    setNonblocking(pty.master);

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
        .config = config,
        .term = term,
        .stream = undefined, // needs the final Terminal address; set below
        .render_state = .empty,
        .pty = pty,
        .child_pid = child_pid,
        .font = font,
        .font_size_px = config.font_size,
        .renderer = try .init(alloc, &self.font, .{
            .selection_background = config.selection_background,
            .selection_foreground = config.selection_foreground,
        }),
        .window = window,
        .keyboard = try .init(),
        .needs_redraw = true,
        .in_band_reports = false,
        .write_queue = .empty,
        .child_eof = false,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
        .pointer_x = 0,
        .pointer_y = 0,
        .scroll_pixels = 0,
        .scroll_clicks = 0,
        .scroll_had_discrete = false,
        .selecting = false,
        .sel_anchor = null,
        .sel_anchor_off = 0,
        .sel_screen = .primary,
        .active_screen = .primary,
        .last_serial = 0,
        .clip_offer = null,
        .primary_offer = null,
        .clip_source = null,
        .primary_source = null,
        .paste_fd = -1,
        .paste_buf = .empty,
    };
    self.stream = self.term.vtStream();

    if (window.data_device) |device| {
        device.setListener(*App, dataDeviceListener, self);
    }
    if (window.primary_device) |device| {
        device.setListener(*App, primaryDeviceListener, self);
    }

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

    window.setCallbacks(self, render, resize, keyboardEvent, pointerEvent, scaleChanged);
    return self;
}

/// Window scale delegate: reload the font at the physical pixel size so
/// glyphs are rasterized crisply instead of upscaled by the compositor.
/// The window calls the resize delegate right after, re-fitting the grid
/// to the new cell metrics.
fn scaleChanged(ctx: *anyopaque, scale120: u32) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const size_px: u31 = @intCast((@as(u64, self.config.font_size) * scale120 + 60) / 120);
    if (size_px == 0 or size_px == self.font_size_px) return;

    const new_font: Font = try .init(self.alloc, self.config.font_family, size_px);
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = size_px;
    self.needs_redraw = true;
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

fn setNonblocking(fd: posix.fd_t) void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

pub fn deinit(self: *App) void {
    self.cancelDrag();
    if (self.paste_fd >= 0) _ = std.os.linux.close(self.paste_fd);
    self.paste_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
    self.write_queue.deinit(self.alloc);
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
        // In-flight paste pipe; negative (ignored) while idle.
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
    };
    const wl_fd = &fds[0];
    const pty_fd = &fds[1];
    const repeat_fd = &fds[2];
    const paste_fd = &fds[3];

    while (self.window.running and !self.child_eof) {
        // Standard libwayland read dance: drain the local queue, flush
        // requests, then sleep until one of the fds is ready.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        flush: while (true) {
            switch (display.flush()) {
                .SUCCESS => break :flush,
                // Socket full: wait until the compositor drains it.
                .AGAIN => {
                    var out_fd = [_]posix.pollfd{
                        .{ .fd = display.getFd(), .events = posix.POLL.OUT, .revents = 0 },
                    };
                    _ = posix.poll(&out_fd, -1) catch {
                        display.cancelRead();
                        return error.FlushFailed;
                    };
                },
                else => {
                    display.cancelRead();
                    return error.FlushFailed;
                },
            }
        }

        // Only ask for writability while a backlog exists, otherwise
        // POLLOUT would make every poll return immediately.
        pty_fd.events = posix.POLL.IN;
        if (self.write_queue.items.len > 0) pty_fd.events |= posix.POLL.OUT;
        paste_fd.fd = self.paste_fd;

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

        if (pty_fd.revents & posix.POLL.OUT != 0) {
            self.flushWriteQueue();
        }
        if (pty_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.readPty();
        }

        if (repeat_fd.revents & posix.POLL.IN != 0) {
            self.fireRepeat();
        }

        if (self.paste_fd >= 0 and paste_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.readPaste();
        }

        if (self.needs_redraw) {
            self.needs_redraw = false;
            try self.window.redraw();
        }
    }

    // Window closed while the child is alive: hang it up like a real
    // terminal whose master side went away. The child is its own
    // session leader (setsid in spawn), so it owns SIGHUP delivery to
    // its jobs.
    if (!self.child_eof) {
        _ = std.os.linux.kill(self.child_pid, std.os.linux.SIG.HUP);
    }
    _ = Pty.wait(self.child_pid) catch {};
}

/// Drain available PTY output into the terminal. Bounded so a
/// flooding child cannot starve the Wayland side of the loop.
fn readPty(self: *App) void {
    var buf: [16 * 1024]u8 = undefined;
    for (0..16) |_| {
        const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            // EIO on the master means the slave side is gone (child exited).
            error.Unexpected, error.InputOutput => {
                self.child_eof = true;
                break;
            },
            else => {
                log.err("pty read failed: {}", .{err});
                self.child_eof = true;
                break;
            },
        };
        if (n == 0) {
            self.child_eof = true;
            break;
        }
        self.stream.nextSlice(buf[0..n]);
        self.needs_redraw = true;
        if (n < buf.len) break;
    }
    self.syncInBandSizeReports();
    self.syncActiveScreen();
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

/// Window pointer delegate: track position and accumulate wheel scroll,
/// applying it at frame boundaries.
fn pointerEvent(ctx: *anyopaque, event: wl.Pointer.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => |enter| {
            self.pointer_x = enter.surface_x.toDouble();
            self.pointer_y = enter.surface_y.toDouble();
        },
        .motion => |motion| {
            self.pointer_x = motion.surface_x.toDouble();
            self.pointer_y = motion.surface_y.toDouble();
            if (self.selecting) self.extendSelection();
        },
        .axis => |axis| {
            if (axis.axis == .vertical_scroll and !self.scroll_had_discrete) {
                self.scroll_pixels += axis.value.toDouble();
            }
        },
        .axis_discrete => |discrete| {
            if (discrete.axis == .vertical_scroll) {
                self.scroll_clicks += discrete.discrete;
                self.scroll_had_discrete = true;
            }
        },
        .frame => self.finishScrollFrame(),
        .button => |button| {
            self.last_serial = button.serial;
            // Mouse reporting wins when the application asked for it,
            // except that shift bypasses it for terminal-side selection.
            const reporting = self.term.flags.mouse_event != .none and
                !self.keyboard.currentMods().shift;

            if (button.button == 272) { // BTN_LEFT
                switch (button.state) {
                    .pressed => if (reporting) {
                        self.forwardMouseButton(button);
                    } else {
                        self.startSelection();
                    },
                    // Routing may have changed since the press (shift
                    // released mid-drag, app toggled mouse mode): an
                    // armed drag always finishes; only presses the app
                    // saw get their release.
                    .released => if (self.selecting) {
                        self.finishSelection();
                    } else if (reporting) {
                        self.forwardMouseButton(button);
                    },
                    else => {},
                }
                return;
            }

            if (reporting) {
                self.forwardMouseButton(button);
                return;
            }
            if (button.button == 274 and button.state == .pressed) {
                // BTN_MIDDLE: paste the primary selection.
                self.beginPaste(.primary);
            }
        },
        .leave, .axis_source, .axis_stop => {},
    }
}

/// The viewport cell under the pointer, clamped to the grid.
fn cellAtPointer(self: *App) struct { x: u16, y: u16 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const px: f64 = @max(0, self.pointer_x * scale);
    const py: f64 = @max(0, self.pointer_y * scale);
    const x: u16 = @intFromFloat(@min(
        px / @as(f64, @floatFromInt(self.font.cell_width)),
        @as(f64, @floatFromInt(self.term.cols -| 1)),
    ));
    const y: u16 = @intFromFloat(@min(
        py / @as(f64, @floatFromInt(self.font.cell_height)),
        @as(f64, @floatFromInt(self.term.rows -| 1)),
    ));
    return .{ .x = x, .y = y };
}

/// The cell-boundary caret under the pointer: the row under the
/// pointer and the nearest vertical cell edge (0..=cols), so grabbing
/// the right half of a cell means "after this cell".
fn boundaryAtPointer(self: *App) struct { x: u16, y: u16 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const fx = @max(0, self.pointer_x * scale) / @as(f64, @floatFromInt(self.font.cell_width));
    const fy = @max(0, self.pointer_y * scale) / @as(f64, @floatFromInt(self.font.cell_height));
    const bx: u16 = @intFromFloat(@min(@floor(fx + 0.5), @as(f64, @floatFromInt(self.term.cols))));
    const by: u16 = @intFromFloat(@min(@floor(fy), @as(f64, @floatFromInt(self.term.rows -| 1))));
    return .{ .x = bx, .y = by };
}

fn forwardMouseButton(self: *App, button: anytype) void {
    const mouse_button: vt.input.MouseButton = switch (button.button) {
        272 => .left, // BTN_LEFT
        273 => .right, // BTN_RIGHT
        274 => .middle, // BTN_MIDDLE
        else => return,
    };
    // Buttons owned by the application dismiss any terminal-side
    // selection; the application handles the event its own way.
    self.clearSelection();
    self.sendMouseEvent(.{
        .action = if (button.state == .pressed) .press else .release,
        .button = mouse_button,
        .mods = self.keyboard.currentMods(),
        .pos = self.pointerPosPhysical(),
    });
}

fn startSelection(self: *App) void {
    const screen = self.term.screens.active;
    self.clearSelection();

    // Pin the cell left of the boundary; a boundary past the last
    // column pins the last cell with its right edge.
    const boundary = self.boundaryAtPointer();
    const anchor_x: u16 = @min(boundary.x, self.term.cols - 1);
    self.sel_anchor_off = @intCast(boundary.x - anchor_x);
    const anchor = screen.pages.pin(.{
        .viewport = .{ .x = anchor_x, .y = boundary.y },
    }) orelse return;
    self.sel_anchor = screen.pages.trackPin(anchor) catch null;
    self.sel_screen = self.term.screens.active_key;
    self.selecting = self.sel_anchor != null;
}

fn extendSelection(self: *App) void {
    // A drag never survives a screen switch; the anchor pin belongs
    // to the other screen's pages.
    if (self.term.screens.active_key != self.sel_screen) {
        self.cancelDrag();
        return;
    }
    const screen = self.term.screens.active;
    const pages = &screen.pages;
    const anchor = self.sel_anchor orelse return;
    const cols: u32 = self.term.cols;

    // Both carets in screen coordinates: boundary x in 0..=cols.
    const anchor_pt = pages.pointFromPin(.screen, anchor.*) orelse return;
    const a: [2]u32 = .{ anchor_pt.screen.y, anchor_pt.screen.x + self.sel_anchor_off };
    const boundary = self.boundaryAtPointer();
    const row_pin = pages.pin(.{ .viewport = .{ .x = 0, .y = boundary.y } }) orelse return;
    const row_pt = pages.pointFromPin(.screen, row_pin) orelse return;
    const e: [2]u32 = .{ row_pt.screen.y, boundary.x };

    if (a[0] == e[0] and a[1] == e[1]) {
        // Empty: no boundary crossed yet.
        if (screen.selection != null) {
            screen.clearSelection();
            self.needs_redraw = true;
        }
        return;
    }

    // Cells strictly between the two carets, in reading order.
    const a_first = a[0] < e[0] or (a[0] == e[0] and a[1] < e[1]);
    const first = if (a_first) a else e;
    const last = if (a_first) e else a;
    const start: [2]u32 = if (first[1] >= cols) .{ first[0] + 1, 0 } else first;
    const end: [2]u32 = if (last[1] == 0)
        .{ last[0] -| 1, cols - 1 }
    else
        .{ last[0], last[1] - 1 };
    if (start[0] > end[0] or (start[0] == end[0] and start[1] > end[1])) {
        if (screen.selection != null) {
            screen.clearSelection();
            self.needs_redraw = true;
        }
        return;
    }

    const start_pin = pages.pin(.{
        .screen = .{ .x = @intCast(start[1]), .y = start[0] },
    }) orelse return;
    const end_pin = pages.pin(.{
        .screen = .{ .x = @intCast(end[1]), .y = end[0] },
    }) orelse return;
    screen.select(.init(start_pin, end_pin, false)) catch return;
    self.needs_redraw = true;
}

/// Stop any in-progress drag, untracking the anchor pin on the screen
/// that owns it (which may no longer be the active one).
fn cancelDrag(self: *App) void {
    self.selecting = false;
    if (self.sel_anchor) |anchor| {
        if (self.term.screens.get(self.sel_screen)) |screen| {
            screen.pages.untrackPin(anchor);
        }
        self.sel_anchor = null;
    }
}

fn finishSelection(self: *App) void {
    if (!self.selecting) return;
    self.cancelDrag();
    // Finished selections claim the primary selection, X style.
    self.copyToPrimary();
}

/// Drop the current selection and stop any in-progress drag.
fn clearSelection(self: *App) void {
    self.cancelDrag();
    const screen = self.term.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        self.needs_redraw = true;
    }
}

/// React to alt screen enter/exit: an in-flight drag must not span
/// screens (its anchor pin belongs to the old screen's pages). The
/// terminal itself clears the incoming screen's selection.
fn syncActiveScreen(self: *App) void {
    const key = self.term.screens.active_key;
    if (key == self.active_screen) return;
    self.active_screen = key;
    self.cancelDrag();
}

/// Heap context for an outgoing selection source: owns the text and the
/// source proxy. Destroyed when the compositor cancels the source
/// (someone else took the selection), when we replace it with a new
/// source, or at exit — whichever comes first.
const SourceCtx = struct {
    app: *App,
    text: [:0]const u8,
    source: union(enum) {
        clipboard: *wl.DataSource,
        primary: *zwp.PrimarySelectionSourceV1,
    },

    /// Destroy the proxy, release ownership, and detach from the app's
    /// tracking slot (if it still points here).
    fn destroy(self: *SourceCtx) void {
        const app = self.app;
        switch (self.source) {
            .clipboard => |source| {
                if (app.clip_source == self) app.clip_source = null;
                source.destroy();
            },
            .primary => |source| {
                if (app.primary_source == self) app.primary_source = null;
                source.destroy();
            },
        }
        app.alloc.free(self.text);
        app.alloc.destroy(self);
    }

    /// Stream the text to the requesting client and close the fd.
    /// Writes are blocking; selections are small enough in practice.
    fn send(self: *SourceCtx, fd: i32) void {
        const linux = std.os.linux;
        defer _ = linux.close(fd);
        var offset: usize = 0;
        while (offset < self.text.len) {
            const rc = linux.write(fd, self.text.ptr + offset, self.text.len - offset);
            switch (linux.errno(rc)) {
                .SUCCESS => offset += rc,
                .INTR => continue,
                else => return,
            }
        }
    }
};

fn dataSourceListener(_: *wl.DataSource, event: wl.DataSource.Event, ctx: *SourceCtx) void {
    switch (event) {
        .send => |send| ctx.send(send.fd),
        .cancelled => ctx.destroy(),
        else => {},
    }
}

fn primarySourceListener(
    _: *zwp.PrimarySelectionSourceV1,
    event: zwp.PrimarySelectionSourceV1.Event,
    ctx: *SourceCtx,
) void {
    switch (event) {
        .send => |send| ctx.send(send.fd),
        .cancelled => ctx.destroy(),
    }
}

fn dataDeviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *App) void {
    switch (event) {
        .selection => |selection| {
            if (self.clip_offer) |old| old.destroy();
            self.clip_offer = selection.id;
        },
        // Drag and drop is unsupported; those offers are ignored.
        else => {},
    }
}

fn primaryDeviceListener(
    _: *zwp.PrimarySelectionDeviceV1,
    event: zwp.PrimarySelectionDeviceV1.Event,
    self: *App,
) void {
    switch (event) {
        .selection => |selection| {
            if (self.primary_offer) |old| old.destroy();
            self.primary_offer = selection.id;
        },
        .data_offer => {},
    }
}

/// The current selection's text, allocated, or null if nothing selected.
fn selectionText(self: *App) ?[:0]const u8 {
    const screen = self.term.screens.active;
    const sel = screen.selection orelse return null;
    return screen.selectionString(self.alloc, .{ .sel = sel, .trim = true }) catch null;
}

/// Claim the primary selection with the currently selected text.
fn copyToPrimary(self: *App) void {
    const manager = self.window.primary_manager orelse return;
    const device = self.window.primary_device orelse return;
    const text = self.selectionText() orelse return;

    const source = manager.createSource() catch {
        self.alloc.free(text);
        return;
    };
    const ctx = self.alloc.create(SourceCtx) catch {
        source.destroy();
        self.alloc.free(text);
        return;
    };
    ctx.* = .{ .app = self, .text = text, .source = .{ .primary = source } };

    source.offer(paste_mime);
    source.offer("text/plain");
    source.offer("UTF8_STRING");
    source.setListener(*SourceCtx, primarySourceListener, ctx);
    device.setSelection(source, self.last_serial);

    // Replace any previous source of ours eagerly; the compositor's
    // cancelled event for it would hit a destroyed proxy, which
    // libwayland drops safely.
    if (self.primary_source) |old| old.destroy();
    self.primary_source = ctx;
    log.debug("claimed primary selection ({d} bytes)", .{text.len});
}

/// Claim the clipboard with the currently selected text.
fn copyToClipboard(self: *App) void {
    const manager = self.window.data_manager orelse return;
    const device = self.window.data_device orelse return;
    const text = self.selectionText() orelse return;

    const source = manager.createDataSource() catch {
        self.alloc.free(text);
        return;
    };
    const ctx = self.alloc.create(SourceCtx) catch {
        source.destroy();
        self.alloc.free(text);
        return;
    };
    ctx.* = .{ .app = self, .text = text, .source = .{ .clipboard = source } };

    source.offer(paste_mime);
    source.offer("text/plain");
    source.offer("UTF8_STRING");
    source.setListener(*SourceCtx, dataSourceListener, ctx);
    device.setSelection(source, self.last_serial);

    if (self.clip_source) |old| old.destroy();
    self.clip_source = ctx;
}

/// Ask the offer's owner to stream its contents into a pipe; the read
/// end joins the poll loop and the paste completes on EOF.
fn beginPaste(self: *App, comptime which: enum { clipboard, primary }) void {
    if (self.paste_fd >= 0) return; // one paste at a time

    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return;

    switch (which) {
        .clipboard => {
            const offer = self.clip_offer orelse {
                _ = std.os.linux.close(fds[0]);
                _ = std.os.linux.close(fds[1]);
                return;
            };
            offer.receive(paste_mime, fds[1]);
        },
        .primary => {
            const offer = self.primary_offer orelse {
                _ = std.os.linux.close(fds[0]);
                _ = std.os.linux.close(fds[1]);
                return;
            };
            offer.receive(paste_mime, fds[1]);
        },
    }
    _ = std.os.linux.close(fds[1]);
    setNonblocking(fds[0]);
    self.paste_fd = fds[0];
    self.paste_buf.clearRetainingCapacity();
}

/// Drain the paste pipe; on EOF encode and write the paste to the PTY.
fn readPaste(self: *App) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(self.paste_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => break,
        };
        if (n == 0) break; // EOF: sender is done
        self.paste_buf.appendSlice(self.alloc, buf[0..n]) catch break;
    }
    self.finishPaste();
}

fn finishPaste(self: *App) void {
    _ = std.os.linux.close(self.paste_fd);
    self.paste_fd = -1;
    if (self.paste_buf.items.len == 0) return;

    // Mutable input lets the encoder sanitize control bytes in place,
    // so this cannot fail.
    const parts = vt.input.encodePaste(
        @as([]u8, self.paste_buf.items),
        .fromTerminal(&self.term),
    );
    for (parts) |part| self.writePty(part);
    self.paste_buf.clearRetainingCapacity();
}

/// Convert accumulated wheel movement into scrolled lines: wheel clicks
/// count fixed lines, smooth (touchpad) scroll counts cell heights.
fn finishScrollFrame(self: *App) void {
    var lines: i32 = 0;
    if (self.scroll_had_discrete) {
        lines = self.scroll_clicks * @as(i32, @intCast(self.config.wheel_scroll_lines));
    } else if (self.scroll_pixels != 0) {
        // Logical pixels per row: physical cell height descaled.
        const cell: f64 = @as(f64, @floatFromInt(self.font.cell_height)) * 120.0 /
            @as(f64, @floatFromInt(self.window.scale120));
        const whole = @divTrunc(self.scroll_pixels, cell);
        lines = @intFromFloat(whole);
        self.scroll_pixels -= whole * cell;
    }
    self.scroll_clicks = 0;
    self.scroll_had_discrete = false;
    if (lines != 0) self.scrollLines(lines);
}

/// Route wheel scrolling (positive = towards newer content): mouse
/// reports when the application asked for them, arrow keys on the
/// alternate screen, otherwise the scrollback viewport.
fn scrollLines(self: *App, lines_down: i32) void {
    const lines_abs: u32 = @abs(lines_down);
    if (self.term.flags.mouse_event != .none) {
        // A selection can exist here via the shift override; scrolling
        // hands control back to the application, so drop it.
        self.clearSelection();
        const button: vt.input.MouseButton = if (lines_down < 0) .four else .five;
        for (0..lines_abs) |_| {
            self.sendMouseEvent(.{
                .action = .press,
                .button = button,
                .mods = self.keyboard.currentMods(),
                .pos = self.pointerPosPhysical(),
            });
        }
        return;
    }

    if (self.term.screens.active_key == .alternate) {
        // Full-screen apps without mouse support (pagers, editors)
        // expect cursor keys instead of viewport scrolling; the app
        // will move content, so any selection over it goes stale.
        self.clearSelection();
        const key: vt.input.Key = if (lines_down < 0) .arrow_up else .arrow_down;
        for (0..lines_abs) |_| _ = self.encodeAndWriteKey(.{ .key = key, .action = .press });
        return;
    }

    self.term.screens.active.pages.scroll(.{ .delta_row = lines_down });
    self.needs_redraw = true;
}

fn sendMouseEvent(self: *App, event: vt.input.MouseEncodeEvent) void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    vt.input.encodeMouse(&writer, event, .fromTerminal(&self.term, .{
        .screen = .{
            .width = @intCast(self.term.cols * self.font.cell_width),
            .height = @intCast(self.term.rows * self.font.cell_height),
        },
        .cell = .{ .width = self.font.cell_width, .height = self.font.cell_height },
        .padding = .{},
    })) catch return;
    self.writePty(writer.buffered());
}

/// Pointer position in physical (buffer) pixels, as mouse encoding expects.
fn pointerPosPhysical(self: *App) vt.input.MouseEncodeEvent.Pos {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @floatCast(self.pointer_x * scale),
        .y = @floatCast(self.pointer_y * scale),
    };
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
            self.last_serial = key.serial;
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

    // Copy/paste bindings take priority over the application.
    if (action == .press and event.mods.ctrl and event.mods.shift) {
        switch (event.key) {
            .key_c => return self.copyToClipboard(),
            .key_v => return self.beginPaste(.clipboard),
            else => {},
        }
    }

    const wrote = self.encodeAndWriteKey(event);

    // A non-modifier key that produced input dismisses the selection
    // and snaps a scrolled-back viewport to the bottom (ghostty's
    // selection-clear-on-typing behavior).
    if (wrote and action != .release and !event.key.modifier()) {
        self.clearSelection();
        if (self.term.screens.active.pages.viewport != .active) {
            self.term.screens.active.pages.scroll(.active);
            self.needs_redraw = true;
        }
    }
}

fn encodeAndWriteKey(self: *App, event: vt.input.KeyEvent) bool {
    var out_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    vt.input.encodeKey(&writer, event, .fromTerminal(&self.term)) catch |err| {
        log.err("key encode failed: {}", .{err});
        return false;
    };
    const bytes = writer.buffered();
    if (bytes.len == 0) return false;
    self.writePty(bytes);
    return true;
}

/// Write to the PTY without ever blocking: whatever the kernel won't
/// take right now is queued and flushed when the master polls writable.
fn writePty(self: *App, bytes: []const u8) void {
    // A backlog exists; keep ordering by appending behind it.
    if (self.write_queue.items.len > 0) {
        self.queuePtyWrite(bytes);
        return;
    }
    const written = self.tryPtyWrite(bytes);
    if (written < bytes.len) self.queuePtyWrite(bytes[written..]);
}

/// Drain the backlog after the master polled writable.
fn flushWriteQueue(self: *App) void {
    const written = self.tryPtyWrite(self.write_queue.items);
    self.write_queue.replaceRange(self.alloc, 0, written, &.{}) catch unreachable; // shrinking
}

/// Write as much as the kernel accepts; returns the number of bytes
/// consumed. Never blocks.
fn tryPtyWrite(self: *App, bytes: []const u8) usize {
    const linux = std.os.linux;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(self.pty.master, bytes.ptr + offset, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => offset += rc,
            .INTR => continue,
            .AGAIN => break,
            // EIO: child gone; the read side notices and shuts down.
            .IO => break,
            else => |err| {
                log.err("pty write failed: {}", .{err});
                break;
            },
        }
    }
    return offset;
}

fn queuePtyWrite(self: *App, bytes: []const u8) void {
    // Cap the backlog: a child that never reads again must not grow the
    // queue without bound. Dropping input is safe; dropping responses
    // only affects an unresponsive client.
    const max_queue = 1024 * 1024;
    if (self.write_queue.items.len + bytes.len > max_queue) {
        log.warn("pty write queue full; dropping {d} bytes", .{bytes.len});
        return;
    }
    self.write_queue.appendSlice(self.alloc, bytes) catch |err| {
        log.err("pty write queue append failed: {}", .{err});
    };
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
