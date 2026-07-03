//! The live terminal application: owns the terminal state, PTY, renderer,
//! and window, and runs the event loop that ties them together.
//!
//! The loop polls two fds: the Wayland display and the PTY master. PTY
//! output feeds the terminal and schedules a redraw; redraws are throttled
//! by the window's frame callbacks.

const App = @This();

const std = @import("std");
const posix = std.posix;
const c = @import("c");
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

const xtgettcap_map = std.StaticStringMap([]const u8).initComptime(&.{
    .{ hexEncodeComptime("TN"), "xterm-ghostty" },
    .{ hexEncodeComptime("Co"), "256" },
    .{ hexEncodeComptime("RGB"), "8" },
    .{ hexEncodeComptime("am"), "" },
    .{ hexEncodeComptime("bce"), "" },
    .{ hexEncodeComptime("ccc"), "" },
    .{ hexEncodeComptime("hs"), "" },
    .{ hexEncodeComptime("km"), "" },
    .{ hexEncodeComptime("mc5i"), "" },
    .{ hexEncodeComptime("mir"), "" },
    .{ hexEncodeComptime("msgr"), "" },
    .{ hexEncodeComptime("npc"), "" },
    .{ hexEncodeComptime("xenl"), "" },
    .{ hexEncodeComptime("AX"), "" },
    .{ hexEncodeComptime("Tc"), "" },
    .{ hexEncodeComptime("Su"), "" },
    .{ hexEncodeComptime("XT"), "" },
    .{ hexEncodeComptime("fullkbd"), "" },
    .{ hexEncodeComptime("colors"), "256" },
    .{ hexEncodeComptime("cols"), "80" },
    .{ hexEncodeComptime("it"), "8" },
    .{ hexEncodeComptime("lines"), "24" },
    .{ hexEncodeComptime("pairs"), "32767" },
    .{ hexEncodeComptime("Smulx"), tcapString("\\E[4:%p1%dm") },
    .{ hexEncodeComptime("Setulc"), tcapString("\\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m") },
    .{ hexEncodeComptime("Ss"), tcapString("\\E[%p1%d q") },
    .{ hexEncodeComptime("Se"), tcapString("\\E[0 q") },
    .{ hexEncodeComptime("Ms"), tcapString("\\E]52;%p1%s;%p2%s\\007") },
    .{ hexEncodeComptime("Sync"), tcapString("\\E[?2026%?%p1%{1}%-%tl%eh%;") },
    .{ hexEncodeComptime("BD"), tcapString("\\E[?2004l") },
    .{ hexEncodeComptime("BE"), tcapString("\\E[?2004h") },
    .{ hexEncodeComptime("PS"), tcapString("\\E[200~") },
    .{ hexEncodeComptime("PE"), tcapString("\\E[201~") },
});

fn hexEncodeComptime(comptime input: []const u8) []const u8 {
    return comptime &(std.fmt.bytesToHex(input, .upper));
}

/// Prepare a terminfo string capability for an XTGETTCAP reply.
/// Parameterized values (containing `%`) are sent in terminfo source
/// form (kitty convention); plain strings get `\E` decoded to the
/// escape byte (xterm convention). Mirrors ghostty's
/// terminfo.Source.xtgettcapMap.
fn tcapString(comptime v: []const u8) []const u8 {
    comptime {
        if (std.mem.indexOfScalar(u8, v, '%') != null) return v;
        if (std.mem.indexOfScalar(u8, v, '^') != null)
            @compileError("control-char escapes not handled: " ++ v);
        var buf: [v.len]u8 = undefined;
        const replacements = std.mem.replace(u8, v, "\\E", "\x1b", &buf);
        const final = buf;
        return final[0 .. v.len - replacements];
    }
}

alloc: std.mem.Allocator,
config_arena: std.heap.ArenaAllocator,
config: Config,
environ: std.process.Environ,
term: vt.Terminal,
stream: AppStream,
render_state: vt.RenderState,
/// Complete ARGB8888 backing frame. Dirty-row rendering updates this
/// buffer, then the window copies it into the Wayland shm buffer it acquired.
render_pixels: std.ArrayList(u32),
render_width: u31,
render_height: u31,
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
/// Keyboard focus state; unfocused windows draw a hollow cursor.
focused: bool,
ime_focused: bool,
ime_preedit: ?[]u8,
ime_pending_preedit: ?[]u8,
ime_pending_commit: ?[]u8,
/// Cached DEC mode 2048 state, to detect the application enabling
/// in-band size reports.
in_band_reports: bool,
/// Cached DEC mode 2026 state, to detect synchronized output boundaries.
sync_output: bool,
/// PTY input that couldn't be written yet (master is nonblocking to
/// avoid deadlocking against a child that has stopped reading while
/// flooding output). Flushed when the master polls writable.
write_queue: std.ArrayList(u8),
/// The child has exited and been reaped (via SIGCHLD); quit.
child_exited: bool,
/// The pty master returned EIO/EOF while the child is still alive
/// (e.g. the child transiently closed every slave fd, as some shells
/// do at startup). Reads are retried on a timer until the child
/// reopens the tty or exits; EIO alone never shuts the terminal down.
pty_suspended: bool,
/// Session bus connection, used for notifications and future desktop settings.
dbus: ?*c.DBusConnection,
dbus_fd: posix.fd_t,
notification_ids: std.AutoHashMapUnmanaged(u32, void),
notification_tokens: std.AutoHashMapUnmanaged(u32, []u8),
color_scheme: vt.device_status.ColorScheme,
/// signalfd for process-local signals, polled in the event loop.
signal_fd: posix.fd_t,
/// Key repeat: timerfd armed while a repeating key is held.
repeat_fd: posix.fd_t,
repeat_keycode: ?u32,
/// From wl_keyboard.repeat_info: characters per second and delay in ms.
repeat_rate: i32,
repeat_delay: i32,
/// Safety timer for DEC mode 2026 synchronized output.
sync_output_fd: posix.fd_t,
/// Timer for ghostty-vt selection autoscroll while dragging past an edge.
selection_autoscroll_fd: posix.fd_t,
/// Pointer position in logical surface coordinates.
pointer_x: f64,
pointer_y: f64,
/// Wheel state accumulated between pointer frame events.
scroll_pixels: f64,
scroll_clicks: i32,
scroll_value120: i32,
scroll_value120_remainder: i32,
scroll_had_discrete: bool,
scroll_had_value120: bool,
/// True while the left button is down for terminal-side selection.
selecting: bool,
selection_gesture: vt.SelectionGesture,
/// Button press currently owned by application mouse reporting.
mouse_button: ?vt.input.MouseButton,
/// True after OSC 22 explicitly set the pointer shape; otherwise mouse
/// reporting uses an arrow and normal terminal selection uses I-beam.
mouse_shape_explicit: bool,
/// Active screen at the last check, to detect alt screen switches.
active_screen: vt.ScreenSet.Key,
/// Serial of the most recent input event, required to claim selections.
last_serial: u32,
/// Current clipboard/primary offers from other clients (paste sources).
clip_offer: ?*ClipboardOffer,
clip_pending_offer: ?*ClipboardOffer,
primary_offer: ?*PrimaryOffer,
primary_pending_offer: ?*PrimaryOffer,
/// Our own outgoing selection sources, so exit can reclaim them if the
/// compositor never cancels them (nobody else took the selection).
clip_source: ?*SourceCtx,
primary_source: ?*SourceCtx,
/// An in-flight paste: pipe read end (-1 when idle) and received bytes.
paste_fd: posix.fd_t,
paste_buf: std.ArrayList(u8),

const paste_mime = "text/plain;charset=utf-8";
const paste_mime_preference = [_][:0]const u8{
    paste_mime,
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};
const selection_word_boundaries = [_]u21{
    0,   ' ', '\t', '\'', '"',
    '│',
    '`', '|', ':',  ';',  ',',
    '(', ')', '[',  ']',  '{',
    '}', '<', '>',  '$',
};

/// Terminal lines per wheel click.
const initial_cols = 80;
const initial_rows = 24;
const app_id = "dev.rockorager.monstar";
const app_name = "Monstar";
const sync_output_reset_ms = 1000;
const selection_repeat_ms = 500;
const selection_autoscroll_ms = 15;
const precision_scroll_multiplier = 10.0;

const TerminalHandler = vt.TerminalStream.Handler;
const AppStream = vt.Stream(AppStreamHandler);

const AppStreamHandler = struct {
    app: *App,
    terminal_handler: TerminalHandler,
    dcs: @import("ghostty-vt").dcs.Handler = .{},

    pub fn deinit(self: *AppStreamHandler) void {
        self.dcs.deinit();
        self.terminal_handler.deinit();
    }

    pub fn vt(
        self: *AppStreamHandler,
        comptime action: AppStream.Action.Tag,
        value: AppStream.Action.Value(action),
    ) void {
        self.terminal_handler.vt(action, value);
        switch (action) {
            .color_operation => self.app.answerOscColorQueries(&value.requests, value.terminator),
            .kitty_color_report => self.app.answerKittyColorQueries(value),
            .clipboard_contents => self.app.setOsc52Clipboard(value.kind, value.data),
            .show_desktop_notification => self.app.showDesktopNotification(value.title, value.body),
            .dcs_hook => self.dcsHook(value),
            .dcs_put => self.dcsPut(value),
            .dcs_unhook => self.dcsUnhook(),
            .mouse_shape => {
                self.app.mouse_shape_explicit = true;
                self.app.syncCursorShape();
            },
            .set_mode => {
                if (value.mode == .report_color_scheme) self.app.sendColorSchemeReport();
                if (value.mode == .in_band_size_reports) {
                    self.app.in_band_reports = true;
                    self.app.sendSizeReport();
                }
                self.app.syncCursorShape();
            },
            .restore_mode => {
                if (value.mode == .report_color_scheme and self.app.term.modes.get(.report_color_scheme)) {
                    self.app.sendColorSchemeReport();
                }
                if (value.mode == .in_band_size_reports) {
                    const enabled = self.app.term.modes.get(.in_band_size_reports);
                    self.app.in_band_reports = enabled;
                    if (enabled) self.app.sendSizeReport();
                }
                self.app.syncCursorShape();
            },
            .reset_mode => {
                if (value.mode == .in_band_size_reports) self.app.in_band_reports = false;
                self.app.syncCursorShape();
            },
            .full_reset => {
                self.app.mouse_shape_explicit = false;
                self.app.in_band_reports = false;
                self.app.syncCursorShape();
            },
            else => {},
        }
    }

    fn dcsHook(self: *AppStreamHandler, dcs: @import("ghostty-vt").DCS) void {
        var cmd = self.dcs.hook(self.app.alloc, dcs) orelse return;
        defer cmd.deinit();
        self.app.answerDcsCommand(&cmd);
    }

    fn dcsPut(self: *AppStreamHandler, byte: u8) void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        self.app.answerDcsCommand(&cmd);
    }

    fn dcsUnhook(self: *AppStreamHandler) void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        self.app.answerDcsCommand(&cmd);
    }
};

/// `argv`/`envp` must stay valid for the lifetime of the call (the child
/// copies them via execve). `config` strings must remain valid until the
/// first successful reload or App teardown.
pub fn init(
    io: std.Io,
    alloc: std.mem.Allocator,
    config: Config,
    environ: std.process.Environ,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) !*App {
    var font: Font = try .init(alloc, config.font_family, config.font_size);
    errdefer font.deinit(alloc);

    vt.sys.decode_png = decodePng;

    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = initial_cols,
        .rows = initial_rows,
        .max_scrollback = config.scrollback,
        .colors = config.terminalColors(),
    });
    errdefer term.deinit(alloc);
    term.width_px = initial_cols * font.cell_width;
    term.height_px = initial_rows * font.cell_height;

    // Child-exit detection is driven by SIGCHLD, not pty EOF; config
    // reloads are driven by SIGUSR1. Block both and receive them through
    // signalfd in the poll loop. This must happen before the fork so an
    // early child exit cannot be missed.
    var sigmask = posix.sigemptyset();
    posix.sigaddset(&sigmask, .CHLD);
    posix.sigaddset(&sigmask, .USR1);
    posix.sigprocmask(std.os.linux.SIG.BLOCK, &sigmask, null);
    const signal_fd = posix.signalfd(
        -1,
        &sigmask,
        std.os.linux.SFD.CLOEXEC | std.os.linux.SFD.NONBLOCK,
    ) catch return error.SignalFdFailed;
    errdefer _ = std.os.linux.close(signal_fd);

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

    // Timerfds must be nonblocking: disarming a timerfd clears its
    // pending expirations, so a reader acting on stale poll revents
    // (event dispatched earlier in the same loop iteration disarmed
    // the timer) would otherwise block the whole loop forever.
    const repeat_rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(repeat_rc) != .SUCCESS) return error.TimerFdFailed;
    const repeat_fd: posix.fd_t = @intCast(repeat_rc);
    errdefer _ = std.os.linux.close(repeat_fd);

    const sync_output_rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(sync_output_rc) != .SUCCESS) return error.TimerFdFailed;
    const sync_output_fd: posix.fd_t = @intCast(sync_output_rc);
    errdefer _ = std.os.linux.close(sync_output_fd);

    const selection_autoscroll_rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(selection_autoscroll_rc) != .SUCCESS) return error.TimerFdFailed;
    const selection_autoscroll_fd: posix.fd_t = @intCast(selection_autoscroll_rc);
    errdefer _ = std.os.linux.close(selection_autoscroll_fd);

    // Self-reference into listeners/streams requires a stable address.
    const self = try alloc.create(App);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .config_arena = .init(alloc),
        .config = config,
        .environ = environ,
        .term = term,
        .stream = undefined, // needs the final Terminal address; set below
        .render_state = .empty,
        .render_pixels = .empty,
        .render_width = 0,
        .render_height = 0,
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
        .focused = true,
        .ime_focused = false,
        .ime_preedit = null,
        .ime_pending_preedit = null,
        .ime_pending_commit = null,
        .in_band_reports = false,
        .sync_output = false,
        .write_queue = .empty,
        .child_exited = false,
        .pty_suspended = false,
        .dbus = null,
        .dbus_fd = -1,
        .notification_ids = .empty,
        .notification_tokens = .empty,
        .color_scheme = .dark,
        .signal_fd = signal_fd,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
        .sync_output_fd = sync_output_fd,
        .selection_autoscroll_fd = selection_autoscroll_fd,
        .pointer_x = 0,
        .pointer_y = 0,
        .scroll_pixels = 0,
        .scroll_clicks = 0,
        .scroll_value120 = 0,
        .scroll_value120_remainder = 0,
        .scroll_had_discrete = false,
        .scroll_had_value120 = false,
        .selecting = false,
        .selection_gesture = .init,
        .mouse_button = null,
        .mouse_shape_explicit = false,
        .active_screen = .primary,
        .last_serial = 0,
        .clip_offer = null,
        .clip_pending_offer = null,
        .primary_offer = null,
        .primary_pending_offer = null,
        .clip_source = null,
        .primary_source = null,
        .paste_fd = -1,
        .paste_buf = .empty,
    };
    self.stream = .initAlloc(alloc, .{
        .app = self,
        .terminal_handler = .init(&self.term),
    });

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
    effects.bell = effectBell;
    self.stream.handler.terminal_handler.effects = effects;

    self.initDbus();
    window.setCallbacks(self, render, resize, keyboardEvent, pointerEvent, textInputEvent, scaleChanged);
    return self;
}

fn decodePng(alloc: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const decoded = c.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4,
    ) orelse return error.InvalidData;
    defer c.stbi_image_free(decoded);

    if (width <= 0 or height <= 0) return error.InvalidData;
    const pixel_count = std.math.mul(usize, @intCast(width), @intCast(height)) catch return error.InvalidData;
    const len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);

    @memcpy(out, decoded[0..len]);
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .data = out,
    };
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
    self.render_state.dirty = .full;
    self.needs_redraw = true;
}

const Handler = TerminalHandler;
const Effects = Handler.Effects;

/// Effects callbacks only receive the terminal handler; walk back up through
/// Monstar's wrapper handler.
fn appFromHandler(handler: *Handler) *App {
    const app_handler: *AppStreamHandler = @fieldParentPtr("terminal_handler", handler);
    return app_handler.app;
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
    return deviceAttributes();
}

fn deviceAttributes() EffectResult("device_attributes") {
    return .{
        .primary = .{
            .features = &.{ .ansi_color, .clipboard },
        },
    };
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

fn effectColorScheme(handler: *Handler) ?vt.device_status.ColorScheme {
    return appFromHandler(handler).color_scheme;
}

fn sendColorSchemeReport(self: *App) void {
    self.writePty(switch (self.color_scheme) {
        .dark => "\x1B[?997;1n",
        .light => "\x1B[?997;2n",
    });
}

fn effectXtversion(_: *Handler) []const u8 {
    return "monstar 0.0.0";
}

fn effectTitleChanged(handler: *Handler) void {
    const self = appFromHandler(handler);
    const title = self.term.getTitle() orelse return;
    self.window.toplevel.setTitle(title.ptr);
}

fn effectBell(handler: *Handler) void {
    const self = appFromHandler(handler);
    if (self.focused) return;
    self.window.setUrgent(true) catch |err| {
        log.warn("failed to request window attention: {}", .{err});
    };
}

fn showDesktopNotification(self: *App, title: []const u8, body: []const u8) void {
    const effective_title = if (title.len > 0)
        title
    else
        self.term.getTitle() orelse app_name;

    self.sendDesktopNotification(effective_title, body) catch |err| {
        log.warn("failed to send desktop notification: {}", .{err});
    };
}

fn initDbus(self: *App) void {
    const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse {
        log.warn("session dbus unavailable; desktop integration disabled", .{});
        return;
    };

    if (c.dbus_connection_add_filter(connection, dbusFilter, self, null) == 0) {
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
        return;
    }
    c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.Notifications'", null);
    c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.portal.Settings'", null);

    var fd: c_int = -1;
    if (c.dbus_connection_get_unix_fd(connection, &fd) == 0) {
        c.dbus_connection_remove_filter(connection, dbusFilter, self);
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
        return;
    }

    self.dbus = connection;
    self.dbus_fd = fd;
    self.readPortalColorScheme();
}

fn deinitDbus(self: *App) void {
    self.notification_ids.deinit(self.alloc);

    var it = self.notification_tokens.valueIterator();
    while (it.next()) |token| self.alloc.free(token.*);
    self.notification_tokens.deinit(self.alloc);

    if (self.dbus) |connection| {
        c.dbus_connection_remove_filter(connection, dbusFilter, self);
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
        self.dbus = null;
        self.dbus_fd = -1;
    }
}

fn dispatchDbus(self: *App) void {
    const connection = self.dbus orelse return;
    _ = c.dbus_connection_read_write(connection, 0);
    while (c.dbus_connection_dispatch(connection) == c.DBUS_DISPATCH_DATA_REMAINS) {}
}

fn readPortalColorScheme(self: *App) void {
    const connection = self.dbus orelse return;

    const message = c.dbus_message_new_method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings",
        "ReadOne",
    ) orelse return;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);
    var namespace: [*:0]const u8 = "org.freedesktop.appearance";
    dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &namespace) catch return;
    var key: [*:0]const u8 = "color-scheme";
    dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &key) catch return;

    const reply = c.dbus_connection_send_with_reply_and_block(connection, message, 1000, null) orelse return;
    defer c.dbus_message_unref(reply);

    var reply_iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &reply_iter) == 0) return;
    const value = dbusVariantUint32(&reply_iter) orelse return;
    self.color_scheme = portalColorScheme(value);
}

fn portalColorScheme(value: u32) vt.device_status.ColorScheme {
    return switch (value) {
        2 => .light,
        else => .dark,
    };
}

fn sendDesktopNotification(self: *App, title: []const u8, body: []const u8) !void {
    const connection = self.dbus orelse return error.DBusUnavailable;

    const title_z = try self.alloc.dupeZ(u8, title);
    defer self.alloc.free(title_z);
    const body_z = try self.alloc.dupeZ(u8, body);
    defer self.alloc.free(body_z);

    const message = c.dbus_message_new_method_call(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);

    var notify_app_name: [*:0]const u8 = app_name;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &notify_app_name);
    var replaces_id: u32 = 0;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_UINT32, &replaces_id);
    var app_icon: [*:0]const u8 = "";
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &app_icon);
    var summary: [*:0]const u8 = title_z;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &summary);
    var notification_body: [*:0]const u8 = body_z;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &notification_body);

    var actions: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "s", &actions) == 0) return error.OutOfMemory;
    var default_action_key: [*:0]const u8 = "default";
    try dbusAppendBasic(&actions, c.DBUS_TYPE_STRING, &default_action_key);
    var default_action_label: [*:0]const u8 = "Open";
    try dbusAppendBasic(&actions, c.DBUS_TYPE_STRING, &default_action_label);
    if (c.dbus_message_iter_close_container(&iter, &actions) == 0) return error.OutOfMemory;

    var hints: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "{sv}", &hints) == 0) return error.OutOfMemory;
    try dbusAppendStringHint(&hints, "desktop-entry", app_id);
    if (c.dbus_message_iter_close_container(&iter, &hints) == 0) return error.OutOfMemory;

    var expire_timeout: i32 = -1;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_INT32, &expire_timeout);

    const reply = c.dbus_connection_send_with_reply_and_block(connection, message, 1000, null) orelse return error.DBusUnavailable;
    defer c.dbus_message_unref(reply);

    const notification_id = dbusMessageUint32(reply) orelse return;
    try self.notification_ids.put(self.alloc, notification_id, {});
}

fn dbusAppendBasic(iter: *c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn dbusAppendStringHint(iter: *c.DBusMessageIter, key: [:0]const u8, value: [:0]const u8) !void {
    var entry: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
    var key_ptr: [*:0]const u8 = key;
    try dbusAppendBasic(&entry, c.DBUS_TYPE_STRING, &key_ptr);

    var variant: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "s", &variant) == 0) return error.OutOfMemory;
    var value_ptr: [*:0]const u8 = value;
    try dbusAppendBasic(&variant, c.DBUS_TYPE_STRING, &value_ptr);
    if (c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.OutOfMemory;

    if (c.dbus_message_iter_close_container(iter, &entry) == 0) return error.OutOfMemory;
}

fn dbusMessageUint32(message: *c.DBusMessage) ?u32 {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return null;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_UINT32) return null;
    var value: u32 = 0;
    c.dbus_message_iter_get_basic(&iter, &value);
    return value;
}

fn dbusVariantUint32(iter: *c.DBusMessageIter) ?u32 {
    if (c.dbus_message_iter_get_arg_type(iter) != c.DBUS_TYPE_VARIANT) return null;
    var variant: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(iter, &variant);
    if (c.dbus_message_iter_get_arg_type(&variant) != c.DBUS_TYPE_UINT32) return null;
    var value: u32 = 0;
    c.dbus_message_iter_get_basic(&variant, &value);
    return value;
}

fn dbusFilter(_: ?*c.DBusConnection, message: ?*c.DBusMessage, user_data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const self: *App = @ptrCast(@alignCast(user_data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const msg = message orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (c.dbus_message_is_signal(msg, "org.freedesktop.Notifications", "ActivationToken") != 0) {
        self.handleNotificationActivationToken(msg);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    if (c.dbus_message_is_signal(msg, "org.freedesktop.Notifications", "ActionInvoked") != 0) {
        self.handleNotificationActionInvoked(msg);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    if (c.dbus_message_is_signal(msg, "org.freedesktop.portal.Settings", "SettingChanged") != 0) {
        self.handlePortalSettingChanged(msg);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn handlePortalSettingChanged(self: *App, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var namespace_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&namespace_ptr));
    if (!std.mem.eql(u8, std.mem.span(namespace_ptr), "org.freedesktop.appearance")) return;

    if (c.dbus_message_iter_next(&iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var key_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&key_ptr));
    if (!std.mem.eql(u8, std.mem.span(key_ptr), "color-scheme")) return;

    if (c.dbus_message_iter_next(&iter) == 0) return;
    const value = dbusVariantUint32(&iter) orelse return;
    const color_scheme = portalColorScheme(value);
    if (self.color_scheme == color_scheme) return;
    self.color_scheme = color_scheme;
    if (self.term.modes.get(.report_color_scheme)) self.sendColorSchemeReport();
}

fn handleNotificationActivationToken(self: *App, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_UINT32) return;
    var notification_id: u32 = 0;
    c.dbus_message_iter_get_basic(&iter, &notification_id);
    if (!self.notification_ids.contains(notification_id)) return;
    if (c.dbus_message_iter_next(&iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var token_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&token_ptr));

    const token = std.mem.span(token_ptr);
    const owned = self.alloc.dupe(u8, token) catch return;
    if (self.notification_tokens.fetchPut(self.alloc, notification_id, owned) catch null) |old| {
        self.alloc.free(old.value);
    }
}

fn handleNotificationActionInvoked(self: *App, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_UINT32) return;
    var notification_id: u32 = 0;
    c.dbus_message_iter_get_basic(&iter, &notification_id);
    if (!self.notification_ids.remove(notification_id)) return;
    if (c.dbus_message_iter_next(&iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var action_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&action_ptr));
    if (!std.mem.eql(u8, std.mem.span(action_ptr), "default")) return;

    const kv = self.notification_tokens.fetchRemove(notification_id) orelse return;
    defer self.alloc.free(kv.value);
    if (kv.value.len == 0) return;

    const token_z = self.alloc.dupeZ(u8, kv.value) catch return;
    defer self.alloc.free(token_z);
    self.window.activate(token_z);
}

fn setNonblocking(fd: posix.fd_t) void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

pub fn deinit(self: *App) void {
    self.hangupChild();
    self.pty.deinit();
    self.cancelDrag();
    self.selection_gesture.deinit(&self.term);
    self.render_pixels.deinit(self.alloc);
    self.clearImeText();
    if (self.paste_fd >= 0) _ = std.os.linux.close(self.paste_fd);
    self.paste_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
    self.write_queue.deinit(self.alloc);
    self.deinitDbus();
    _ = std.os.linux.close(self.selection_autoscroll_fd);
    _ = std.os.linux.close(self.sync_output_fd);
    _ = std.os.linux.close(self.repeat_fd);
    _ = std.os.linux.close(self.signal_fd);
    self.keyboard.deinit();
    self.window.destroy();
    self.renderer.deinit();
    self.render_state.deinit(self.alloc);
    self.stream.deinit();
    self.term.deinit(self.alloc);
    self.font.deinit(self.alloc);
    self.config_arena.deinit();
    self.alloc.destroy(self);
}

/// Run until the window is closed or the child exits.
pub fn run(self: *App) !void {
    errdefer self.hangupChild();

    const display = self.window.display;
    var fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 },
        // In-flight paste pipe; negative (ignored) while idle.
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.signal_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.sync_output_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.selection_autoscroll_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.dbus_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const wl_fd = &fds[0];
    const pty_fd = &fds[1];
    const repeat_fd = &fds[2];
    const paste_fd = &fds[3];
    const signal_fd = &fds[4];
    const sync_output_fd = &fds[5];
    const selection_autoscroll_fd = &fds[6];
    const dbus_fd = &fds[7];

    while (self.window.running and !self.child_exited) {
        wl_fd.events = posix.POLL.IN;
        dbus_fd.fd = self.dbus_fd;

        // Standard libwayland read dance: drain the local queue, flush
        // requests, then sleep until one of the fds is ready.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        switch (display.flush()) {
            .SUCCESS => {},
            // Socket full: wait for writability in the main poll set so
            // PTY output still drains while the compositor catches up.
            .AGAIN => wl_fd.events |= posix.POLL.OUT,
            else => {
                display.cancelRead();
                return error.FlushFailed;
            },
        }

        // Only ask for writability while a backlog exists, otherwise
        // POLLOUT would make every poll return immediately.
        pty_fd.events = posix.POLL.IN;
        if (self.write_queue.items.len > 0) pty_fd.events |= posix.POLL.OUT;
        paste_fd.fd = self.paste_fd;

        // A suspended pty would report POLLHUP continuously; drop it
        // from the set and probe on a timer instead until the child
        // reopens the tty (or exits, via SIGCHLD).
        pty_fd.fd = if (self.pty_suspended) -1 else self.pty.master;
        const timeout: i32 = if (self.pty_suspended) 100 else -1;

        const ready = posix.poll(&fds, timeout) catch {
            display.cancelRead();
            return error.PollFailed;
        };
        _ = ready;

        if (wl_fd.revents & posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
        } else {
            display.cancelRead();
        }
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;

        if (signal_fd.revents & posix.POLL.IN != 0) {
            self.drainSignals();
        }

        if (pty_fd.revents & posix.POLL.OUT != 0) {
            self.flushWriteQueue();
        }
        if (self.pty_suspended or
            pty_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0)
        {
            self.readPty();
        }

        if (repeat_fd.revents & posix.POLL.IN != 0) {
            self.fireRepeat();
        }

        if (sync_output_fd.revents & posix.POLL.IN != 0) {
            self.fireSyncOutputReset();
        }

        if (selection_autoscroll_fd.revents & posix.POLL.IN != 0) {
            self.fireSelectionAutoscroll();
        }

        if (dbus_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.dispatchDbus();
        }

        if (self.paste_fd >= 0 and paste_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.readPaste();
        }

        if (self.needs_redraw) {
            if (!self.term.modes.get(.synchronized_output)) {
                self.needs_redraw = false;
                try self.window.redraw();
            }
        }
    }

    if (self.window.fatal_error != null) {
        self.hangupChild();
        return error.WindowFatal;
    }

    // Window closed while the child is alive: hang it up like a real
    // terminal whose master side went away. Do not synchronously wait
    // here: shells can wait on foreground jobs that still hold the
    // slave side open, which would wedge the terminal process.
    if (!self.child_exited) {
        self.hangupChild();
    }
}

fn hangupChild(self: *App) void {
    if (self.child_exited) {
        return;
    }
    self.pty.closeMaster();
    _ = std.os.linux.kill(self.child_pid, std.os.linux.SIG.HUP);
}

/// Signal events arrived. SIGCHLD is the only place the terminal decides
/// the session is over; SIGUSR1 reloads process-local configuration.
fn drainSignals(self: *App) void {
    var info: std.os.linux.signalfd_siginfo = undefined;
    var saw_sigchld = false;
    var saw_sigusr1 = false;
    while (true) {
        const n = posix.read(self.signal_fd, std.mem.asBytes(&info)) catch break;
        if (n == 0) break;
        switch (info.signo) {
            @intFromEnum(std.os.linux.SIG.CHLD) => saw_sigchld = true,
            @intFromEnum(std.os.linux.SIG.USR1) => saw_sigusr1 = true,
            else => {},
        }
    }
    if (saw_sigusr1) self.reloadConfig();
    if (saw_sigchld) {
        if (Pty.tryWait(self.child_pid)) |status| {
            log.debug("child exited with status {d}", .{status});
            self.child_exited = true;
        }
    }
}

fn reloadConfig(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    var committed = false;
    defer if (!committed) arena_state.deinit();

    const new_config = Config.load(arena_state.allocator(), self.environ);
    self.applyConfig(new_config) catch |err| {
        log.warn("config reload failed: {}", .{err});
        return;
    };

    self.config_arena.deinit();
    self.config_arena = arena_state;
    self.config = new_config;
    committed = true;
    log.info("config reloaded", .{});
}

fn applyConfig(self: *App, new_config: Config) !void {
    const desired_font_size: u31 = @intCast((@as(u64, new_config.font_size) * self.window.scale120 + 60) / 120);
    const new_font: Font = try .init(self.alloc, new_config.font_family, desired_font_size);

    const colors = new_config.terminalColors();
    self.term.colors.background.default = colors.background.default;
    self.term.colors.foreground.default = colors.foreground.default;
    self.term.colors.cursor.default = colors.cursor.default;
    self.term.colors.palette.changeDefault(colors.palette.original);

    self.renderer.selection_bg = new_config.selection_background orelse .{ .r = 0x33, .g = 0x46, .b = 0x7c };
    self.renderer.selection_fg = new_config.selection_foreground;

    // Always rebuild the Font on config reload so a reload also picks up
    // fontconfig/file changes for the same family name. The resize path is
    // responsible for deciding whether the new cell metrics changed enough
    // to notify the pty and DEC 2048 in-band size-report listeners.
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = desired_font_size;
    resize(
        self,
        physicalDimension(self.window.width, self.window.scale120),
        physicalDimension(self.window.height, self.window.scale120),
    ) catch |err| {
        log.warn("config reload resize failed: {}", .{err});
    };

    self.render_state.dirty = .full;
    self.needs_redraw = true;
}

/// Drain available PTY output into the terminal. Bounded so a
/// flooding child cannot starve the Wayland side of the loop.
///
/// EIO/EOF on the master only means no process currently holds a
/// slave fd, which can be transient (some shells reopen their tty at
/// startup): reads suspend until the master is usable again, and only
/// SIGCHLD ends the session.
fn readPty(self: *App) void {
    var buf: [16 * 1024]u8 = undefined;
    for (0..16) |_| {
        const n = posix.read(self.pty.master, &buf) catch |err| switch (err) {
            error.WouldBlock => {
                self.resumePty();
                break;
            },
            else => {
                self.suspendPty(err);
                break;
            },
        };
        if (n == 0) {
            self.suspendPty(error.EndOfStream);
            break;
        }
        self.resumePty();
        self.stream.nextSlice(buf[0..n]);
        self.needs_redraw = true;
    }
    self.syncInBandSizeReports();
    self.syncSynchronizedOutput();
    self.syncActiveScreen();
}

fn answerOscColorQueries(
    self: *App,
    requests: *const vt.osc.color.List,
    terminator: vt.osc.Terminator,
) void {
    var it = requests.constIterator(0);
    while (it.next()) |req| {
        switch (req.*) {
            .query => |target| self.answerOscColorQuery(target, terminator),
            else => {},
        }
    }
}

fn answerKittyColorQueries(self: *App, request: vt.kitty.color.OSC) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();

    const wrote_response = self.formatKittyColorResponse(&writer.writer, request) catch return;
    if (!wrote_response) return;

    const response = writer.toOwnedSlice() catch return;
    defer self.alloc.free(response);
    self.writePty(response);
}

fn formatKittyColorResponse(
    self: *const App,
    writer: *std.Io.Writer,
    request: vt.kitty.color.OSC,
) !bool {
    var wrote_response = false;
    for (request.list.items) |item| {
        switch (item) {
            .query => |key| {
                if (!wrote_response) {
                    try writer.writeAll("\x1b]21");
                    wrote_response = true;
                }
                try writeKittyColorReport(writer, key, self.kittyColorValue(key));
            },
            else => {},
        }
    }
    if (wrote_response) try writer.writeAll(request.terminator.string());
    return wrote_response;
}

const KittyColorValue = union(enum) {
    color: vt.color.RGB,
    unset,
};

fn kittyColorValue(self: *const App, key: vt.kitty.color.Kind) KittyColorValue {
    return switch (key) {
        .palette => |idx| .{ .color = self.term.colors.palette.current[idx] },
        .special => |special| switch (special) {
            .foreground => .{ .color = self.effectiveForeground() },
            .background => .{ .color = self.effectiveBackground() },
            .selection_background => .{ .color = self.renderer.selection_bg },
            .selection_foreground => if (self.renderer.selection_fg) |color|
                .{ .color = color }
            else
                .unset,
            .cursor => if (self.term.colors.cursor.get()) |color|
                .{ .color = color }
            else
                .unset,
            .cursor_text,
            .visual_bell,
            .second_transparent_background,
            => .unset,
        },
    };
}

fn writeKittyColorReport(
    writer: *std.Io.Writer,
    key: vt.kitty.color.Kind,
    value: KittyColorValue,
) !void {
    try writer.print(";{f}=", .{key});
    switch (value) {
        .color => |color| try writeKittyColorValue(writer, color),
        .unset => {},
    }
}

fn writeKittyColorValue(writer: *std.Io.Writer, color: vt.color.RGB) !void {
    try writer.print("rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ color.r, color.g, color.b });
}

fn setOsc52Clipboard(self: *App, kind: u8, data: []const u8) void {
    if (data.len == 1 and data[0] == '?') {
        log.debug("ignoring unsupported OSC 52 clipboard read", .{});
        return;
    }

    const text = decodeOsc52ClipboardData(self.alloc, data) catch |err| {
        switch (err) {
            error.OutOfMemory => log.warn("out of memory decoding OSC 52 clipboard data", .{}),
            else => log.info("application sent invalid base64 data for OSC 52", .{}),
        }
        return;
    };

    switch (osc52Target(kind)) {
        .clipboard => self.claimClipboardText(text),
        .primary => self.claimPrimaryText(text),
    }
}

const Osc52Target = enum { clipboard, primary };

fn osc52Target(kind: u8) Osc52Target {
    return switch (kind) {
        's', 'p' => .primary,
        else => .clipboard,
    };
}

fn decodeOsc52ClipboardData(alloc: std.mem.Allocator, data: []const u8) ![:0]const u8 {
    const dec = std.base64.standard.Decoder;
    const size = try dec.calcSizeForSlice(data);
    const buf = try alloc.allocSentinel(u8, size, 0);
    errdefer alloc.free(buf);
    dec.decode(buf, data) catch |err| switch (err) {
        error.InvalidPadding => {},
        else => return err,
    };
    return buf;
}

fn answerDcsCommand(self: *App, cmd: *vt.dcs.Command) void {
    switch (cmd.*) {
        .xtgettcap => |*gettcap| self.answerXtgettcap(gettcap),
        .decrqss => |decrqss| self.answerDecrqss(decrqss),
        .tmux => {},
    }
}

fn answerXtgettcap(self: *App, gettcap: *vt.dcs.Command.XTGETTCAP) void {
    while (gettcap.next()) |key| {
        const value = xtgettcap_map.get(key) orelse continue;
        var response: [512]u8 = undefined;
        const len = formatXtgettcapResponse(&response, key, value) catch return;
        self.writePty(response[0..len]);
    }
}

fn formatXtgettcapResponse(response: []u8, key: []const u8, value: []const u8) !usize {
    var writer: std.Io.Writer = .fixed(response);
    try writer.print("\x1bP1+r{s}", .{key});
    if (value.len > 0) {
        try writer.writeByte('=');
        for (value) |byte| try writer.print("{X:0>2}", .{byte});
    }
    try writer.writeAll("\x1b\\");
    return writer.end;
}

fn answerDecrqss(self: *App, decrqss: vt.dcs.Command.DECRQSS) void {
    var response: [128]u8 = undefined;
    const len = formatDecrqssResponse(&response, &self.term, decrqss) catch return;
    self.writePty(response[0..len]);
}

fn formatDecrqssResponse(
    response: []u8,
    term: *vt.Terminal,
    decrqss: vt.dcs.Command.DECRQSS,
) !usize {
    var writer: std.Io.Writer = .fixed(response);

    const prefix_fmt = "\x1bP{d}$r";
    const prefix_len = std.fmt.comptimePrint(prefix_fmt, .{0}).len;
    writer.end = prefix_len;

    switch (decrqss) {
        .none => {},
        .sgr => {
            const attrs = try term.printAttributes(writer.buffer[writer.end..]);
            writer.end += attrs.len;
            try writer.writeByte('m');
        },
        .decscusr => {
            const blink = term.modes.get(.cursor_blinking);
            const style: u8 = switch (term.screens.active.cursor.cursor_style) {
                .block, .block_hollow => if (blink) 1 else 2,
                .underline => if (blink) 3 else 4,
                .bar => if (blink) 5 else 6,
            };
            try writer.print("{d} q", .{style});
        },
        .decstbm => try writer.print("{d};{d}r", .{
            term.scrolling_region.top + 1,
            term.scrolling_region.bottom + 1,
        }),
        .decslrm => if (term.modes.get(.enable_left_and_right_margin)) {
            try writer.print("{d};{d}s", .{
                term.scrolling_region.left + 1,
                term.scrolling_region.right + 1,
            });
        },
    }

    const valid = writer.end > prefix_len;
    try writer.writeAll("\x1b\\");
    _ = try std.fmt.bufPrint(response[0..prefix_len], prefix_fmt, .{@intFromBool(valid)});
    return writer.end;
}

fn answerOscColorQuery(
    self: *App,
    target: vt.osc.color.Target,
    terminator: vt.osc.Terminator,
) void {
    switch (target) {
        .palette => |idx| self.writeOscPaletteReport(idx, terminator),
        .dynamic => |dynamic| switch (dynamic) {
            .foreground => self.writeOscDynamicReport(10, self.effectiveForeground(), terminator),
            .background => self.writeOscDynamicReport(11, self.effectiveBackground(), terminator),
            .cursor => self.writeOscDynamicReport(
                12,
                self.term.colors.cursor.get() orelse self.effectiveForeground(),
                terminator,
            ),
            else => {},
        },
        .special => {},
    }
}

fn writeOscPaletteReport(self: *App, idx: u8, terminator: vt.osc.Terminator) void {
    self.writeOscColorReport(.{ .palette = idx }, self.term.colors.palette.current[idx], terminator);
}

fn writeOscDynamicReport(
    self: *App,
    dynamic: u16,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) void {
    self.writeOscColorReport(.{ .dynamic = dynamic }, color, terminator);
}

const OscColorReport = union(enum) {
    palette: u8,
    dynamic: u16,
};

fn writeOscColorReport(
    self: *App,
    report: OscColorReport,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) void {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    formatOscColorReport(&writer, report, color, terminator) catch return;
    self.writePty(writer.buffered());
}

fn formatOscColorReport(
    writer: *std.Io.Writer,
    report: OscColorReport,
    color: vt.color.RGB,
    terminator: vt.osc.Terminator,
) !void {
    switch (report) {
        .palette => |idx| try writer.print(
            "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
            .{
                idx,
                @as(u16, color.r) * 257,
                @as(u16, color.g) * 257,
                @as(u16, color.b) * 257,
            },
        ),
        .dynamic => |dynamic| try writer.print(
            "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
            .{
                dynamic,
                @as(u16, color.r) * 257,
                @as(u16, color.g) * 257,
                @as(u16, color.b) * 257,
            },
        ),
    }
    try writer.writeAll(terminator.string());
}

fn effectiveForeground(self: *const App) vt.color.RGB {
    return self.term.colors.foreground.get() orelse self.term.colors.palette.current[7];
}

fn effectiveBackground(self: *const App) vt.color.RGB {
    return self.term.colors.background.get() orelse self.term.colors.palette.current[0];
}

fn syncCursorShape(self: *App) void {
    self.window.setCursorShape(self.currentCursorShape());
}

fn currentCursorShape(self: *const App) Window.CursorShape {
    if (self.mouse_shape_explicit) return cursorShapeFromMouseShape(self.term.mouse_shape);
    return if (self.term.flags.mouse_event != .none) .default else .text;
}

fn cursorShapeFromMouseShape(shape: vt.MouseShape) Window.CursorShape {
    return switch (shape) {
        .default => .default,
        .context_menu => .context_menu,
        .help => .help,
        .pointer => .pointer,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .text => .text,
        .vertical_text => .vertical_text,
        .alias => .alias,
        .copy => .copy,
        .move => .move,
        .no_drop => .no_drop,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .all_scroll => .all_scroll,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .n_resize => .n_resize,
        .e_resize => .e_resize,
        .s_resize => .s_resize,
        .w_resize => .w_resize,
        .ne_resize => .ne_resize,
        .nw_resize => .nw_resize,
        .se_resize => .se_resize,
        .sw_resize => .sw_resize,
        .ew_resize => .ew_resize,
        .ns_resize => .ns_resize,
        .nesw_resize => .nesw_resize,
        .nwse_resize => .nwse_resize,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
    };
}

test "OSC color reports use 16-bit rgb format" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOscColorReport(
        &writer,
        .{ .dynamic = 10 },
        .{ .r = 0x12, .g = 0x34, .b = 0x56 },
        .st,
    );
    try std.testing.expectEqualStrings("\x1b]10;rgb:1212/3434/5656\x1b\\", writer.buffered());

    writer = .fixed(&buf);
    try formatOscColorReport(
        &writer,
        .{ .palette = 7 },
        .{ .r = 0xab, .g = 0xcd, .b = 0xef },
        .bel,
    );
    try std.testing.expectEqualStrings("\x1b]4;7;rgb:abab/cdcd/efef\x07", writer.buffered());
}

test "kitty color reports use OSC 21 key value format" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeAll("\x1b]21");
    try writeKittyColorReport(
        &writer,
        .{ .special = .foreground },
        .{ .color = .{ .r = 0x12, .g = 0x34, .b = 0x56 } },
    );
    try writeKittyColorReport(&writer, .{ .special = .cursor }, .unset);
    try writeKittyColorReport(
        &writer,
        .{ .palette = 7 },
        .{ .color = .{ .r = 0xab, .g = 0xcd, .b = 0xef } },
    );
    try writer.writeAll(vt.osc.Terminator.st.string());

    try std.testing.expectEqualStrings(
        "\x1b]21;foreground=rgb:12/34/56;cursor=;7=rgb:ab/cd/ef\x1b\\",
        writer.buffered(),
    );
}

test "OSC 52 set decodes clipboard payload" {
    const text = try decodeOsc52ClipboardData(std.testing.allocator, "aGVsbG8=");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    try std.testing.expectEqual(.clipboard, osc52Target('c'));
    try std.testing.expectEqual(.primary, osc52Target('s'));
    try std.testing.expectEqual(.primary, osc52Target('p'));
    try std.testing.expectEqual(.clipboard, osc52Target('7'));
}

test "kitty PNG direct transmit installs decoded RGBA image" {
    const alloc = std.testing.allocator;
    const old_decode_png = vt.sys.decode_png;
    vt.sys.decode_png = decodePng;
    defer vt.sys.decode_png = old_decode_png;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var command: std.Io.Writer.Allocating = .init(alloc);
    defer command.deinit();
    try command.writer.print("\x1b_Ga=T,f=100,i=7;{s}\x1b\\", .{
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
    });

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(command.writer.buffered());

    const img = term.screens.active.kitty_images.imageById(7) orelse return error.MissingImage;
    try std.testing.expectEqual(.rgba, img.format);
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
    try std.testing.expectEqual(@as(usize, img.width) * img.height * 4, img.data.len);
    try std.testing.expectEqual(@as(usize, 1), term.screens.active.kitty_images.placements.count());
}

test "DA1 advertises OSC 52 clipboard support" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try deviceAttributes().encode(.primary, &writer);
    try std.testing.expectEqualStrings("\x1b[?62;22;52c", writer.buffered());
}

test "portal color scheme values map to terminal reports" {
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(0));
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(1));
    try std.testing.expectEqual(vt.device_status.ColorScheme.light, portalColorScheme(2));
    try std.testing.expectEqual(vt.device_status.ColorScheme.dark, portalColorScheme(99));
}

test "XTGETTCAP reports hex encoded capabilities" {
    var buf: [512]u8 = undefined;

    const bool_len = try formatXtgettcapResponse(&buf, hexEncodeComptime("Tc"), "");
    try std.testing.expectEqualStrings("\x1bP1+r5463\x1b\\", buf[0..bool_len]);

    const num_len = try formatXtgettcapResponse(&buf, hexEncodeComptime("RGB"), "8");
    try std.testing.expectEqualStrings("\x1bP1+r524742=38\x1b\\", buf[0..num_len]);

    const str_len = try formatXtgettcapResponse(&buf, hexEncodeComptime("Smulx"), "\\E[4:%p1%dm");
    try std.testing.expectEqualStrings(
        "\x1bP1+r536D756C78=5C455B343A25703125646D\x1b\\",
        buf[0..str_len],
    );
}

test "XTGETTCAP string values decode tcap escapes unless parameterized" {
    // Parameterized: terminfo source form is preserved.
    try std.testing.expectEqualStrings("\\E[4:%p1%dm", comptime tcapString("\\E[4:%p1%dm"));
    // Plain: \E decodes to the escape byte before hex encoding.
    try std.testing.expectEqualStrings("\x1b[0 q", comptime tcapString("\\E[0 q"));

    var buf: [512]u8 = undefined;
    const len = try formatXtgettcapResponse(&buf, hexEncodeComptime("Se"), comptime tcapString("\\E[0 q"));
    try std.testing.expectEqualStrings("\x1bP1+r5365=1B5B302071\x1b\\", buf[0..len]);
}

fn suspendPty(self: *App, err: anyerror) void {
    if (self.pty_suspended or self.child_exited) return;
    // Most of the time this is a real child exit; the SIGCHLD arriving
    // right after ends the session. Reap eagerly to avoid one poll
    // round trip.
    if (Pty.tryWait(self.child_pid)) |status| {
        log.debug("child exited with status {d}", .{status});
        self.child_exited = true;
        return;
    }
    log.debug("pty read failed ({}) with child alive; suspending reads", .{err});
    self.pty_suspended = true;
}

fn resumePty(self: *App) void {
    if (!self.pty_suspended) return;
    log.debug("pty readable again; resuming reads", .{});
    self.pty_suspended = false;
}

/// DEC mode 2048 (in-band size reports): the terminal must send a size
/// report when the application enables the mode, and again on every
/// resize while it stays enabled. Neovim relies on these instead of
/// SIGWINCH once DECRQM confirms support.
///
/// Mode actions send the immediate report, including when an application
/// re-enables an already-enabled mode. This end-of-chunk sync is a
/// fallback for any state changes that do not pass through AppStreamHandler.
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

/// DEC mode 2026 (synchronized output): while enabled, the terminal
/// state may change but frames should not expose the intermediate state.
/// A one-shot timer prevents a misbehaving child from freezing output.
fn syncSynchronizedOutput(self: *App) void {
    const enabled = self.term.modes.get(.synchronized_output);
    if (enabled == self.sync_output) return;

    self.sync_output = enabled;
    if (enabled) {
        self.setSyncOutputTimer(.{
            .it_value = timespecFromNs(sync_output_reset_ms * std.time.ns_per_ms),
            .it_interval = .{ .sec = 0, .nsec = 0 },
        });
    } else {
        self.setSyncOutputTimer(.{
            .it_value = .{ .sec = 0, .nsec = 0 },
            .it_interval = .{ .sec = 0, .nsec = 0 },
        });
        self.needs_redraw = true;
    }
}

fn setSyncOutputTimer(self: *App, spec: std.os.linux.itimerspec) void {
    const rc = std.os.linux.timerfd_settime(self.sync_output_fd, .{}, &spec, null);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        log.err("sync output timerfd_settime failed: {}", .{std.os.linux.errno(rc)});
    }
}

fn fireSyncOutputReset(self: *App) void {
    var expirations: u64 = 0;
    const n = posix.read(self.sync_output_fd, std.mem.asBytes(&expirations)) catch return;
    if (n != @sizeOf(u64) or expirations == 0) return;
    if (self.term.modes.get(.synchronized_output)) {
        log.debug("synchronized output timed out; forcing redraw", .{});
        self.term.modes.set(.synchronized_output, false);
    }
    self.syncSynchronizedOutput();
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
            if (self.selecting) {
                self.extendSelection();
            } else if (self.mouse_button != null or self.reportingMouse()) {
                self.sendMouseEvent(.{
                    .action = .motion,
                    .button = self.mouse_button,
                    .mods = self.keyboard.currentMods(),
                    .pos = self.pointerPosPhysical(),
                });
            }
        },
        .axis => |axis| {
            if (axis.axis == .vertical_scroll and !self.scroll_had_discrete and !self.scroll_had_value120) {
                self.scroll_pixels += axis.value.toDouble();
            }
        },
        .axis_discrete => |discrete| {
            if (discrete.axis == .vertical_scroll) {
                self.scroll_clicks += discrete.discrete;
                self.scroll_had_discrete = true;
            }
        },
        .axis_value120 => |axis| {
            if (axis.axis == .vertical_scroll) {
                self.scroll_value120 += axis.value120;
                self.scroll_had_value120 = true;
            }
        },
        .frame => self.finishScrollFrame(),
        .button => |button| {
            self.last_serial = button.serial;
            // Mouse reporting wins when the application asked for it,
            // except that shift bypasses it for terminal-side selection.
            const reporting = self.term.flags.mouse_event != .none and
                !self.keyboard.currentMods().shift;
            const mouse_button = mouseButtonFromEvdev(button.button);

            if (button.button == 272) { // BTN_LEFT
                switch (button.state) {
                    .pressed => if (reporting) {
                        self.forwardMouseButton(button, mouse_button.?);
                    } else {
                        self.startSelection(button.time);
                    },
                    // Routing may have changed since the press (shift
                    // released mid-drag, app toggled mouse mode): an
                    // armed drag always finishes; only presses the app
                    // saw get their release.
                    .released => if (self.selecting) {
                        self.finishSelection();
                    } else if (self.mouse_button == mouse_button) {
                        self.forwardMouseButton(button, mouse_button.?);
                    } else if (reporting) {
                        self.forwardMouseButton(button, mouse_button.?);
                    },
                    else => {},
                }
                return;
            }

            if (reporting and mouse_button != null) {
                self.forwardMouseButton(button, mouse_button.?);
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

fn pinAtPointer(self: *App) ?vt.Pin {
    const cell = self.cellAtPointer();
    return self.term.screens.active.pages.pin(.{
        .viewport = .{ .x = cell.x, .y = cell.y },
    });
}

fn pointerPhysical(self: *App) struct { x: f64, y: f64 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @max(0, self.pointer_x * scale),
        .y = @max(0, self.pointer_y * scale),
    };
}

fn selectionGeometry(self: *App) vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = self.term.cols,
        .cell_width = self.font.cell_width,
        .padding_left = 0,
        .screen_height = physicalDimension(self.window.height, self.window.scale120),
    };
}

fn physicalDimension(logical: u31, scale120: u32) u31 {
    return @intCast((@as(u64, logical) * scale120 + 60) / 120);
}

fn selectionTimestamp(ms: u32) std.Io.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(
        @as(i96, @intCast(ms)) * @as(i96, @intCast(std.time.ns_per_ms)),
    );
}

fn mouseButtonFromEvdev(button: u32) ?vt.input.MouseButton {
    return switch (button) {
        272 => .left, // BTN_LEFT
        273 => .right, // BTN_RIGHT
        274 => .middle, // BTN_MIDDLE
        else => null,
    };
}

fn reportingMouse(self: *App) bool {
    return self.term.flags.mouse_event != .none and !self.keyboard.currentMods().shift;
}

fn forwardMouseButton(self: *App, button: anytype, mouse_button: vt.input.MouseButton) void {
    // Buttons owned by the application dismiss any terminal-side
    // selection; the application handles the event its own way.
    self.clearSelection();
    if (button.state == .pressed) self.mouse_button = mouse_button;
    self.sendMouseEvent(.{
        .action = if (button.state == .pressed) .press else .release,
        .button = mouse_button,
        .mods = self.keyboard.currentMods(),
        .pos = self.pointerPosPhysical(),
    });
    if (button.state == .released and self.mouse_button == mouse_button) self.mouse_button = null;
}

fn startSelection(self: *App, time_ms: u32) void {
    const pin = self.pinAtPointer() orelse return;
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.press(&self.term, .{
        .time = selectionTimestamp(time_ms),
        .pin = pin,
        .xpos = pos.x,
        .ypos = pos.y,
        .max_distance = @floatFromInt(self.font.cell_width),
        .repeat_interval = selection_repeat_ms * std.time.ns_per_ms,
        .word_boundary_codepoints = &selection_word_boundaries,
    }) catch return;
    self.selecting = true;
    self.applySelection(selection, true);
}

fn extendSelection(self: *App) void {
    const pin = self.pinAtPointer() orelse return;
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.drag(&self.term, .{
        .pin = pin,
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = false,
        .word_boundary_codepoints = &selection_word_boundaries,
        .geometry = self.selectionGeometry(),
    });
    self.applySelection(selection, false);
    self.syncSelectionAutoscrollTimer();
}

/// Stop any in-progress drag, untracking the anchor pin on the screen
/// that owns it (which may no longer be the active one).
fn cancelDrag(self: *App) void {
    self.selecting = false;
    self.selection_gesture.reset(&self.term);
    self.stopSelectionAutoscrollTimer();
}

fn finishSelection(self: *App) void {
    if (!self.selecting) return;
    self.selecting = false;
    self.selection_gesture.release(&self.term, .{ .pin = self.pinAtPointer() });
    self.stopSelectionAutoscrollTimer();
    // Finished selections claim the primary selection, X style.
    self.copyToPrimary();
}

fn applySelection(self: *App, selection: ?vt.Selection, clear_if_null: bool) void {
    const screen = self.term.screens.active;
    if (selection) |sel| {
        screen.select(sel) catch return;
        self.needs_redraw = true;
    } else if (clear_if_null and screen.selection != null) {
        screen.clearSelection();
        self.needs_redraw = true;
    }
}

fn syncSelectionAutoscrollTimer(self: *App) void {
    if (!self.selecting or self.selection_gesture.left_drag_autoscroll == .none) {
        self.stopSelectionAutoscrollTimer();
        return;
    }
    const interval = timespecFromNs(selection_autoscroll_ms * std.time.ns_per_ms);
    self.setSelectionAutoscrollTimer(.{
        .it_value = interval,
        .it_interval = interval,
    });
}

fn stopSelectionAutoscrollTimer(self: *App) void {
    self.setSelectionAutoscrollTimer(.{
        .it_value = .{ .sec = 0, .nsec = 0 },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    });
}

fn setSelectionAutoscrollTimer(self: *App, spec: std.os.linux.itimerspec) void {
    const rc = std.os.linux.timerfd_settime(self.selection_autoscroll_fd, .{}, &spec, null);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        log.err("selection autoscroll timerfd_settime failed: {}", .{std.os.linux.errno(rc)});
    }
}

fn fireSelectionAutoscroll(self: *App) void {
    var expirations: u64 = 0;
    const n = posix.read(self.selection_autoscroll_fd, std.mem.asBytes(&expirations)) catch return;
    if (n != @sizeOf(u64) or expirations == 0 or !self.selecting) return;

    const cell = self.cellAtPointer();
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.autoscrollTick(&self.term, .{
        .viewport = .{ .x = cell.x, .y = cell.y },
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = false,
        .word_boundary_codepoints = &selection_word_boundaries,
        .geometry = self.selectionGeometry(),
    });
    self.applySelection(selection, false);
    self.needs_redraw = true;
    self.syncSelectionAutoscrollTimer();
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

const MimeMask = u32;

fn mimeBit(mime_type: [*:0]const u8) ?MimeMask {
    const offered = std.mem.span(mime_type);
    inline for (paste_mime_preference, 0..) |candidate, i| {
        if (std.mem.eql(u8, offered, candidate[0..candidate.len])) {
            return @as(MimeMask, 1) << @intCast(i);
        }
    }
    return null;
}

fn bestPasteMime(mask: MimeMask) ?[*:0]const u8 {
    inline for (paste_mime_preference, 0..) |candidate, i| {
        if (mask & (@as(MimeMask, 1) << @intCast(i)) != 0) return candidate.ptr;
    }
    return null;
}

const ClipboardOffer = struct {
    app: *App,
    offer: *wl.DataOffer,
    mimes: MimeMask = 0,

    fn noteMime(self: *ClipboardOffer, mime_type: [*:0]const u8) void {
        if (mimeBit(mime_type)) |bit| self.mimes |= bit;
    }

    fn bestMime(self: *const ClipboardOffer) ?[*:0]const u8 {
        return bestPasteMime(self.mimes);
    }

    fn destroy(self: *ClipboardOffer) void {
        const app = self.app;
        if (app.clip_offer == self) app.clip_offer = null;
        if (app.clip_pending_offer == self) app.clip_pending_offer = null;
        self.offer.destroy();
        app.alloc.destroy(self);
    }
};

const PrimaryOffer = struct {
    app: *App,
    offer: *zwp.PrimarySelectionOfferV1,
    mimes: MimeMask = 0,

    fn noteMime(self: *PrimaryOffer, mime_type: [*:0]const u8) void {
        if (mimeBit(mime_type)) |bit| self.mimes |= bit;
    }

    fn bestMime(self: *const PrimaryOffer) ?[*:0]const u8 {
        return bestPasteMime(self.mimes);
    }

    fn destroy(self: *PrimaryOffer) void {
        const app = self.app;
        if (app.primary_offer == self) app.primary_offer = null;
        if (app.primary_pending_offer == self) app.primary_pending_offer = null;
        self.offer.destroy();
        app.alloc.destroy(self);
    }
};

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

fn dataOfferListener(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *ClipboardOffer) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
        else => {},
    }
}

fn primaryOfferListener(
    _: *zwp.PrimarySelectionOfferV1,
    event: zwp.PrimarySelectionOfferV1.Event,
    offer: *PrimaryOffer,
) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
    }
}

fn createClipboardOffer(self: *App, proxy: *wl.DataOffer) ?*ClipboardOffer {
    if (self.clip_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(ClipboardOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .app = self, .offer = proxy };
    proxy.setListener(*ClipboardOffer, dataOfferListener, offer);
    self.clip_pending_offer = offer;
    return offer;
}

fn takeClipboardOffer(self: *App, proxy: *wl.DataOffer) ?*ClipboardOffer {
    const offer = self.clip_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.clip_pending_offer = null;
    return offer;
}

fn createPrimaryOffer(self: *App, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    if (self.primary_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(PrimaryOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .app = self, .offer = proxy };
    proxy.setListener(*PrimaryOffer, primaryOfferListener, offer);
    self.primary_pending_offer = offer;
    return offer;
}

fn takePrimaryOffer(self: *App, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    const offer = self.primary_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.primary_pending_offer = null;
    return offer;
}

fn dataDeviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *App) void {
    switch (event) {
        .data_offer => |data_offer| {
            _ = self.createClipboardOffer(data_offer.id);
        },
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takeClipboardOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.clip_offer) |old| old.destroy();
            self.clip_offer = offer;
        },
        .enter => |enter| {
            const id = enter.id orelse return;
            if (self.takeClipboardOffer(id)) |offer| {
                offer.destroy();
            } else {
                id.destroy();
            }
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
        .data_offer => |data_offer| {
            _ = self.createPrimaryOffer(data_offer.offer);
        },
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takePrimaryOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.primary_offer) |old| old.destroy();
            self.primary_offer = offer;
        },
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
    const text = self.selectionText() orelse return;
    self.claimPrimaryText(text);
}

fn claimPrimaryText(self: *App, text: [:0]const u8) void {
    const manager = self.window.primary_manager orelse {
        self.alloc.free(text);
        return;
    };
    const device = self.window.primary_device orelse {
        self.alloc.free(text);
        return;
    };

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

    inline for (paste_mime_preference) |mime| source.offer(mime.ptr);
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
    const text = self.selectionText() orelse return;
    self.claimClipboardText(text);
}

fn claimClipboardText(self: *App, text: [:0]const u8) void {
    const manager = self.window.data_manager orelse {
        self.alloc.free(text);
        return;
    };
    const device = self.window.data_device orelse {
        self.alloc.free(text);
        return;
    };

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

    inline for (paste_mime_preference) |mime| source.offer(mime.ptr);
    source.setListener(*SourceCtx, dataSourceListener, ctx);
    device.setSelection(source, self.last_serial);

    if (self.clip_source) |old| old.destroy();
    self.clip_source = ctx;
    log.debug("claimed clipboard ({d} bytes)", .{text.len});
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
            const mime = offer.bestMime() orelse {
                _ = std.os.linux.close(fds[0]);
                _ = std.os.linux.close(fds[1]);
                return;
            };
            offer.offer.receive(mime, fds[1]);
        },
        .primary => {
            const offer = self.primary_offer orelse {
                _ = std.os.linux.close(fds[0]);
                _ = std.os.linux.close(fds[1]);
                return;
            };
            const mime = offer.bestMime() orelse {
                _ = std.os.linux.close(fds[0]);
                _ = std.os.linux.close(fds[1]);
                return;
            };
            offer.offer.receive(mime, fds[1]);
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
    if (self.scroll_had_value120) {
        const scaled = self.scroll_value120 * @as(i32, @intCast(self.config.wheel_scroll_lines)) +
            self.scroll_value120_remainder;
        lines = @divTrunc(scaled, 120);
        self.scroll_value120_remainder = @rem(scaled, 120);
    } else if (self.scroll_had_discrete) {
        lines = self.scroll_clicks * @as(i32, @intCast(self.config.wheel_scroll_lines));
    } else if (self.scroll_pixels != 0) {
        // Logical pixels per row: physical cell height descaled.
        const cell: f64 = @as(f64, @floatFromInt(self.font.cell_height)) * 120.0 /
            @as(f64, @floatFromInt(self.window.scale120));
        // Touchpad scroll deltas are surface-local distances. Ghostty boosts
        // precision scrolls before converting them to rows; without that,
        // Wayland touchpads require a large gesture to move a terminal line.
        const pixels = self.scroll_pixels * precision_scroll_multiplier;
        const whole = @divTrunc(pixels, cell);
        lines = @intFromFloat(whole);
        self.scroll_pixels -= whole * cell / precision_scroll_multiplier;
    }
    if (self.scroll_had_value120 or self.scroll_had_discrete) self.scroll_pixels = 0;
    self.scroll_clicks = 0;
    self.scroll_value120 = 0;
    self.scroll_had_discrete = false;
    self.scroll_had_value120 = false;
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
    var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.term, .{
        .screen = .{
            .width = @intCast(self.term.cols * self.font.cell_width),
            .height = @intCast(self.term.rows * self.font.cell_height),
        },
        .cell = .{ .width = self.font.cell_width, .height = self.font.cell_height },
        .padding = .{},
    });
    opts.any_button_pressed = event.action == .press or self.mouse_button != null;
    vt.input.encodeMouse(&writer, event, opts) catch return;
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
        .leave => {
            self.cancelRepeat();
            self.setFocus(false);
        },
        .enter => self.setFocus(true),
    }
}

fn setFocus(self: *App, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    if (focused) {
        self.window.setUrgent(false) catch |err| {
            log.warn("failed to clear window attention: {}", .{err});
        };
    }
    self.render_state.dirty = .full;
    self.needs_redraw = true;

    // Applications with focus reporting (mode 1004) get CSI I / CSI O.
    if (self.term.modes.get(.focus_event)) {
        var buf: [vt.input.max_focus_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        vt.input.encodeFocus(&writer, if (focused) .gained else .lost) catch return;
        self.writePty(writer.buffered());
    }
}

fn textInputEvent(ctx: *anyopaque, event: zwp.TextInputV3.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => {
            self.ime_focused = true;
            self.window.enableTextInput(self.textInputCursorRect());
        },
        .leave => {
            self.ime_focused = false;
            self.window.disableTextInput();
            self.setImePreedit(null);
            self.resetPendingIme();
        },
        .preedit_string => |preedit| {
            self.replaceImeText(&self.ime_pending_preedit, if (preedit.text) |text| std.mem.sliceTo(text, 0) else null);
        },
        .commit_string => |commit| {
            self.replaceImeText(&self.ime_pending_commit, if (commit.text) |text| std.mem.sliceTo(text, 0) else null);
        },
        .delete_surrounding_text => {},
        .done => {
            self.applyPendingIme();
        },
    }
}

fn applyPendingIme(self: *App) void {
    if (self.ime_pending_commit) |commit| {
        if (commit.len > 0) {
            self.writePty(commit);
            self.clearSelection();
            if (self.term.screens.active.pages.viewport != .active) {
                self.term.screens.active.pages.scroll(.active);
            }
        }
    }
    self.setImePreedit(self.ime_pending_preedit);
    self.resetPendingIme();
    self.syncTextInputCursorRect();
}

fn setImePreedit(self: *App, text: ?[]const u8) void {
    self.replaceImeText(&self.ime_preedit, text);
    self.render_state.dirty = .full;
    self.needs_redraw = true;
}

fn replaceImeText(self: *App, slot: *?[]u8, text: ?[]const u8) void {
    if (slot.*) |old| self.alloc.free(old);
    slot.* = null;
    const value = text orelse return;
    if (value.len == 0) return;
    slot.* = self.alloc.dupe(u8, value) catch |err| {
        log.warn("failed to copy IME text: {}", .{err});
        return;
    };
}

fn resetPendingIme(self: *App) void {
    self.replaceImeText(&self.ime_pending_preedit, null);
    self.replaceImeText(&self.ime_pending_commit, null);
}

fn clearImeText(self: *App) void {
    self.replaceImeText(&self.ime_preedit, null);
    self.resetPendingIme();
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
            .comma => return self.reloadConfig(),
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
    self.renderer.focused = self.focused;
    const resized = try self.ensureRenderPixels(width, height);
    const has_kitty_graphics = self.term.screens.active.kitty_images.placements.count() > 0;
    if (self.term.modes.get(.synchronized_output)) {
        if (resized) try self.renderer.render(&self.render_state, self.render_pixels.items, width, height);
        @memcpy(pixels, self.render_pixels.items);
        return;
    }
    const old_cursor = self.render_state.cursor;
    try self.render_state.update(self.alloc, &self.term);
    self.dirtyCursorRows(old_cursor);
    const kitty_graphics_dirty = self.term.screens.active.kitty_images.dirty;
    if (self.ime_preedit != null) self.render_state.dirty = .full;
    if (resized or kitty_graphics_dirty or has_kitty_graphics) self.render_state.dirty = .full;
    switch (self.render_state.dirty) {
        .false => {},
        .full => if (has_kitty_graphics) {
            try self.renderer.renderWithKittyGraphics(&self.render_state, &self.term, self.render_pixels.items, width, height);
        } else {
            try self.renderer.render(&self.render_state, self.render_pixels.items, width, height);
        },
        .partial => try self.renderer.renderDirty(&self.render_state, self.render_pixels.items, width, height),
    }
    if (self.ime_preedit) |preedit| {
        try self.renderer.renderPreedit(&self.render_state, self.render_pixels.items, width, height, preedit);
    }
    self.syncTextInputCursorRect();
    if (kitty_graphics_dirty) self.term.screens.active.kitty_images.dirty = false;
    self.clearRenderDirty();
    @memcpy(pixels, self.render_pixels.items);
}

fn syncTextInputCursorRect(self: *App) void {
    if (!self.ime_focused) return;
    self.window.setTextInputCursorRect(self.textInputCursorRect());
}

fn textInputCursorRect(self: *App) Window.TextInputRect {
    const cursor = self.render_state.cursor.viewport;
    const x_cells: u32 = if (cursor) |cpos| @intCast(cpos.x -| @intFromBool(cpos.wide_tail)) else 0;
    const y_cells: u32 = if (cursor) |cpos| @intCast(cpos.y) else 0;
    return physicalRectToLogical(self.window.scale120, .{
        .x = @intCast(x_cells * self.font.cell_width),
        .y = @intCast(y_cells * self.font.cell_height),
        .width = @intCast(self.font.cell_width),
        .height = @intCast(self.font.cell_height),
    });
}

fn physicalRectToLogical(scale120: u32, rect: Window.TextInputRect) Window.TextInputRect {
    return .{
        .x = scaledPhysicalToLogical(scale120, rect.x),
        .y = scaledPhysicalToLogical(scale120, rect.y),
        .width = @max(1, scaledPhysicalToLogical(scale120, rect.width)),
        .height = @max(1, scaledPhysicalToLogical(scale120, rect.height)),
    };
}

fn scaledPhysicalToLogical(scale120: u32, value: i32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * 120 + @divTrunc(@as(i64, scale120), 2), @as(i64, scale120)));
}

fn dirtyCursorRows(self: *App, old_cursor: vt.RenderState.Cursor) void {
    const new_cursor = self.render_state.cursor;
    if (old_cursor.visible == new_cursor.visible and
        old_cursor.visual_style == new_cursor.visual_style and
        std.meta.eql(old_cursor.viewport, new_cursor.viewport))
    {
        return;
    }

    self.dirtyCursorRow(old_cursor.viewport);
    self.dirtyCursorRow(new_cursor.viewport);
}

fn dirtyCursorRow(self: *App, viewport: ?vt.RenderState.Cursor.Viewport) void {
    const row = viewport orelse return;
    if (row.y >= self.render_state.row_data.len) return;

    self.render_state.row_data.items(.dirty)[row.y] = true;
    if (self.render_state.dirty == .false) self.render_state.dirty = .partial;
}

fn ensureRenderPixels(self: *App, width: u31, height: u31) !bool {
    const len = @as(usize, width) * height;
    if (self.render_width == width and self.render_height == height and
        self.render_pixels.items.len == len)
    {
        return false;
    }
    try self.render_pixels.resize(self.alloc, len);
    self.render_width = width;
    self.render_height = height;
    return true;
}

fn clearRenderDirty(self: *App) void {
    const rows = self.render_state.row_data.slice();
    for (rows.items(.dirty)) |*dirty| dirty.* = false;
    self.render_state.dirty = .false;
}

/// Window resize delegate: fit the grid to the new size, resize the
/// terminal (reflow) and tell the child.
fn resize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const cols: u16 = @intCast(@min(std.math.maxInt(u16), @max(1, width / self.font.cell_width)));
    const rows: u16 = @intCast(@min(std.math.maxInt(u16), @max(1, height / self.font.cell_height)));
    const grid_width_px = @as(u32, cols) * self.font.cell_width;
    const grid_height_px = @as(u32, rows) * self.font.cell_height;
    const pixels_changed = grid_width_px != self.term.width_px or grid_height_px != self.term.height_px;
    const cells_changed = cols != self.term.cols or rows != self.term.rows;
    if (!cells_changed and !pixels_changed) return;

    self.term.width_px = grid_width_px;
    self.term.height_px = grid_height_px;
    if (cells_changed) {
        log.debug("resize to {d}x{d} cells", .{ cols, rows });
        try self.term.resize(self.alloc, cols, rows);
    }
    try self.pty.setWinsize(.{
        .row = rows,
        .col = cols,
        .xpixel = @intCast(width),
        .ypixel = @intCast(height),
    });
    if (self.term.modes.get(.in_band_size_reports)) self.sendSizeReport();
    self.needs_redraw = true;
}
