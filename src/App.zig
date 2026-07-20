//! The live terminal application: owns the terminal state, PTY, renderer,
//! and window, and runs the event loop that ties them together.
//!
//! The loop polls the Wayland display and the read pipeline's ready
//! eventfd (a gather thread drains the PTY master concurrently). PTY
//! output feeds the terminal and schedules a redraw; redraws are throttled
//! by the window's frame callbacks.

const App = @This();

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const c = @import("c");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const vt = @import("ghostty-vt");
const terminfo = @import("ghostty-terminfo");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Keyboard = @import("Keyboard.zig");
const Link = @import("Link.zig");
const Pty = @import("Pty.zig");
const ReadPipeline = @import("ReadPipeline.zig");
const Renderer = @import("Renderer.zig");
const AsyncRaster = @import("AsyncRaster.zig");
const AsyncJobSnapshot = @import("AsyncJobSnapshot.zig");
const KittyImageCache = @import("KittyImageCache.zig");
const ScrollbackSearch = @import("ScrollbackSearch.zig");
const ScrollDetector = @import("ScrollDetector.zig");
const TerminalLayout = @import("TerminalLayout.zig");
const cgroup = @import("cgroup.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.app);

const xtgettcap_map = terminfo.ghostty.xtgettcapMap();

fn hexEncodeComptime(comptime input: []const u8) []const u8 {
    return comptime &(std.fmt.bytesToHex(input, .upper));
}

const HoveredLink = struct {
    uri: []u8,
    range: ?Renderer.LinkRange,
};

const LinkPress = struct {
    uri: []u8,
    cell: vt.Coordinate,
};

alloc: std.mem.Allocator,
io: std.Io,
config_arena: std.heap.ArenaAllocator,
config: Config,
config_path: ?[:0]const u8,
config_overrides: []const []const u8,
environ: std.process.Environ,
term: vt.Terminal,
stream: AppStream,
/// The single terminal snapshot both render paths draw from. Updated
/// only on the main thread while no render target is checked out, so
/// the async worker can read it without locks while a job is in flight.
render_state: vt.RenderState,
/// Main-thread scratch for recognizing viewport movement before
/// RenderState.update consumes Ghostty's row dirtiness.
scroll_detector: ScrollDetector,
async_raster: ?AsyncRaster,
async_raster_loader: ?AsyncRaster.Loader,
async_generation: u64,
/// The next async snapshot must be rebuilt completely because renderer-only
/// state changed or a prior snapshot was rendered but not committed.
async_force_full: bool,
/// A finished async frame whose buffer is checked out, waiting for the
/// outstanding frame callback before it can be committed. While held,
/// `window.rendering_pending` stays true so no new render can start.
held_frame: ?*Window.Buffer,
/// Owned overlay and Kitty inputs for the in-flight async job.
async_job: AsyncJobSnapshot,
/// Pinned copies of kitty image data shared between consecutive async
/// jobs, so the worker never reads terminal-owned image bytes.
kitty_cache: KittyImageCache,
/// The window geometry changed, so a repaint at the new size must
/// happen even while synchronized output has content frames frozen.
geometry_redraw: bool,
/// Ring of per-frame damage records: what changed in each of the last
/// N frames. Stale shm buffers use this to copy missed rectangles from the
/// newest rendered shm buffer before this frame's dirty cells are drawn.
frame_damage: [frame_damage_len]FrameDamage,
/// Ring index of the current frame's entry.
frame_damage_index: usize,
/// Scratch for the damage rectangles reported to the window each frame.
damage_rects: std.ArrayList(Window.DamageRect),
/// Repair rectangles owned by the main thread and borrowed by the in-flight
/// raster job. Kept separate from surface-damage scratch used at commit.
repair_rects: std.ArrayList(AsyncRaster.RepairRect),
pty: Pty,
/// Gather-thread pipeline draining the pty master; the main loop
/// consumes parsed batches via its ready_fd in the poll set.
pipeline: ReadPipeline,
child_pid: posix.pid_t,
font: Font,
/// The physical pixel size the font is currently loaded at.
font_size_px: u31,
/// Runtime-only size override from keyboard shortcuts, preserving the
/// configured point or logical-pixel unit.
runtime_font_size: ?Config.FontSize,
/// Current physical grid rectangle and effective padding.
layout: TerminalLayout,
/// Selection highlight colors, from config or OSC 17/19. Snapshotted
/// into the raster worker's renderer on (re)configure.
selection_bg: vt.color.RGB,
selection_fg: ?vt.color.RGB,
selection_bg_override: ?vt.color.RGB,
selection_fg_override: ?vt.color.RGB,
/// Background used briefly after the current selection is copied.
copy_highlight: vt.color.RGB,
copy_highlight_fg: vt.color.RGB,
copy_highlight_active: bool,
/// Configured text color beneath a focused block cursor.
cursor_text: ?vt.color.RGB,
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
/// Native incremental scrollback search, active even with an empty query.
search: ?ScrollbackSearch,
/// Cached DEC mode 2048 state, to detect the application enabling
/// in-band size reports.
in_band_reports: bool,
/// Cached DEC mode 2026 state, to detect synchronized output boundaries.
sync_output: bool,
/// PTY input that couldn't be written yet (master is nonblocking to
/// avoid deadlocking against a child that has stopped reading while
/// flooding output). Flushed when the master polls writable.
write_queue: std.ArrayList(u8),
/// The child has exited and been reaped (via SIGCHLD).
child_exited: bool,
/// Keep the window open after the child exits.
hold: bool,
/// Session bus connection, used for notifications and future desktop settings.
dbus: ?*c.DBusConnection,
dbus_fd: posix.fd_t,
/// URI held while the compositor creates a token for activating its handler.
pending_open_uri: ?[]u8,
/// A null value means the notification is awaiting its activation token.
notifications: std.AutoHashMapUnmanaged(u32, ?[]u8),
color_scheme: vt.device_status.ColorScheme,
/// signalfd for process-local signals, polled in the event loop.
signal_fd: posix.fd_t,
/// Key repeat: timerfd armed while a repeating key is held.
repeat_fd: posix.fd_t,
repeat_keycode: ?u32,
/// From wl_keyboard.repeat_info: characters per second and delay in ms.
repeat_rate: i32,
repeat_delay: i32,
/// Kinetic touchpad scrolling after a finger-axis sequence stops.
fling_fd: posix.fd_t,
fling_active: bool,
fling_velocity: f64,
scroll_velocity: f64,
last_scroll_time_ms: ?u32,
/// Safety timer for DEC mode 2026 synchronized output.
sync_output_fd: posix.fd_t,
/// Timer for ghostty-vt selection autoscroll while dragging past an edge.
selection_autoscroll_fd: posix.fd_t,
/// One-shot timer restoring the normal selection color after a copy.
copy_highlight_fd: posix.fd_t,
/// One-shot timer that clears stale OSC 9;4 taskbar progress.
taskbar_progress_fd: posix.fd_t,
/// Drives bounded libghostty search work without blocking the event loop.
search_fd: posix.fd_t,
/// One-shot visibility delay followed by periodic scrollbar fade ticks.
scrollbar_fd: posix.fd_t,
scrollbar_alpha: u8,
scrollbar_reveal_hovered: bool,
scrollbar_hovered: bool,
scrollbar_drag: ?ScrollbarDrag,
/// Pointer position in logical surface coordinates.
pointer_x: f64,
pointer_y: f64,
pointer_inside: bool,
/// Demand-driven link detection cache. The URI is owned by App.
hovered_link: ?HoveredLink,
link_checked_cell: ?vt.Coordinate,
link_active: bool,
/// A link click opens only if release occurs over the original cell.
link_press: ?LinkPress,
/// Wheel state accumulated between pointer frame events.
scroll_pixels: f64,
scroll_frame_pixels: f64,
scroll_clicks: i32,
scroll_value120: i32,
scroll_line_remainder: f64,
scroll_source: wl.Pointer.AxisSource,
scroll_time_ms: u32,
scroll_had_pixels: bool,
scroll_had_discrete: bool,
scroll_had_value120: bool,
scroll_stopped: bool,
/// True while the left button is down for terminal-side selection.
selecting: bool,
/// True when the active drag should produce a rectangular selection.
selection_rectangle: bool,
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
/// Active drag-and-drop offer, valid between wl_data_device.enter/leave.
dnd_offer: ?*ClipboardOffer,
/// Our own outgoing selection sources, so exit can reclaim them if the
/// compositor never cancels them (nobody else took the selection).
clip_source: ?*SourceCtx,
primary_source: ?*SourceCtx,
/// An in-flight paste: pipe read end (-1 when idle) and received bytes.
paste_fd: posix.fd_t,
paste_buf: std.ArrayList(u8),
paste_action: PasteAction,

const paste_mime = "text/plain;charset=utf-8";
const uri_list_mime = "text/uri-list";
const paste_mime_preference = [_][:0]const u8{
    paste_mime,
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};
const dnd_mime_preference = [_][:0]const u8{
    uri_list_mime,
    paste_mime,
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};
const PasteAction = union(enum) {
    terminal,
    osc52_read: u8,
    dnd: *ClipboardOffer,
};
const TransferOffer = union(enum) {
    clipboard: *ClipboardOffer,
    primary: *PrimaryOffer,

    fn receive(self: TransferOffer, mime: [*:0]const u8, fd: posix.fd_t) void {
        switch (self) {
            .clipboard => |offer| offer.offer.receive(mime, fd),
            .primary => |offer| offer.offer.receive(mime, fd),
        }
    }
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
const app_name = "monstar";
const sync_output_reset_ms = 1000;
const taskbar_progress_timeout_seconds = 15;
const selection_repeat_ms = 500;
const selection_autoscroll_ms = 15;
const search_tick_ms = 1;
const search_ticks_per_wake = 8;
const max_search_query_bytes = 64 * 1024;
const scrollbar_hold_ms = 700;
const scrollbar_fade_interval_ms = 40;
const scrollbar_default_alpha = 150;
const scrollbar_hover_alpha = 220;
const scrollbar_fade_step = 25;
const scrollbar_width = 6;
const scrollbar_inset = 3;
const scrollbar_min_thumb = 24;
const scrollbar_hit_width = 14;
const scrollbar_reveal_width = 24;
const disarmed_timer: std.os.linux.itimerspec = .{
    .it_value = .{ .sec = 0, .nsec = 0 },
    .it_interval = .{ .sec = 0, .nsec = 0 },
};
/// Preserve Monstar's Wayland precision-scroll normalization before applying
/// the user-facing Ghostty-compatible multiplier.
const wayland_precision_scroll_scale = 3.0;
/// Kinetic scroll tuning, matching Keywork's touchpad fling behavior.
const fling_decay_per_ms = 0.998;
const fling_interval_ms = 8;
const fling_start_velocity = 150.0;
const fling_min_velocity = 30.0;
const fling_max_velocity = 8000.0;
const velocity_smoothing = 0.75;

/// Damage history length; shm buffers older than this get a full copy.
const frame_damage_len = 8;

const ScrollbarDrag = struct {
    grab_offset: f64,
    screen: vt.ScreenSet.Key,
};

const ScrollbarGeometry = struct {
    thumb: Renderer.ScrollbarThumb,
    track_y: u31,
    travel: u31,
    max_offset: usize,
};

pub const InitialSize = union(enum) {
    default,
    chars: struct { cols: u16, rows: u16 },
    pixels: struct { width: u31, height: u31 },
};

pub const InitOptions = struct {
    config_path: ?[:0]const u8 = null,
    config_overrides: []const []const u8 = &.{},
    working_directory: ?[:0]const u8 = null,
    title: [:0]const u8 = "monstar",
    initial_size: InitialSize = .default,
    hold: bool = false,
};

const StartupSize = struct {
    cols: u16,
    rows: u16,
    window: Window.InitialSize,
};

fn initialTerminalSize(size: InitialSize, font: *const Font, config: Config) StartupSize {
    const padding = physicalPadding(config, 120);
    return switch (size) {
        .default => .{
            .cols = initial_cols,
            .rows = initial_rows,
            .window = .{},
        },
        .chars => |chars| .{
            .cols = chars.cols,
            .rows = chars.rows,
            .window = .{
                .width = dimensionForCells(chars.cols, font.cell_width, padding.left, padding.right),
                .height = dimensionForCells(chars.rows, font.cell_height, padding.top, padding.bottom),
            },
        },
        .pixels => |pixels| pixels: {
            const layout = TerminalLayout.init(pixels.width, pixels.height, font.cell_width, font.cell_height, padding);
            break :pixels .{
                .cols = layout.columns,
                .rows = layout.rows,
                .window = .{
                    .width = pixels.width,
                    .height = pixels.height,
                },
            };
        },
    };
}

fn dimensionForCells(cells: u16, cell_size: u31, before: u31, after: u31) u31 {
    return @intCast(@min(
        std.math.maxInt(u31),
        @as(u64, cells) * cell_size + before + after,
    ));
}

/// What one frame changed, recorded so stale shm buffers can be brought
/// current from the newest rendered shm buffer without copying everything.
const FrameDamage = struct {
    /// Everything changed (or rendering failed partway); ignore `rects`.
    full: bool,
    /// Physical buffer rectangles changed by Renderer.renderDirty.
    rects: std.ArrayList(Renderer.PixelRect),
    /// Pixel geometry this entry was recorded at.
    width: u31,
    height: u31,
    grid_x: u31,
    grid_y: u31,
    grid_width: u31,
    grid_height: u31,
    cell_width: u31,
    cell_height: u31,
};

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
            .color_operation => self.app.handleOscColorOperation(&value.requests, value.terminator),
            .kitty_color_report => self.app.answerKittySelectionColorQueries(value),
            .clipboard_contents => self.app.setOsc52Clipboard(value.kind, value.data),
            .show_desktop_notification => self.app.showDesktopNotification(value.title, value.body),
            .progress_report => self.app.reportTaskbarProgress(value),
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

/// The directory for kitty t=t temporary-file transmissions, resolved
/// like Ghostty: $TMPDIR, then $TMP, then /tmp. Returned slices point
/// into the process environment and stay valid for its lifetime.
fn tmpDirPath(environ: std.process.Environ) []const u8 {
    const dir = environ.getPosix("TMPDIR") orelse
        environ.getPosix("TMP") orelse
        return "/tmp";
    return std.mem.trimEnd(u8, dir, &.{std.fs.path.sep});
}

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
    options: InitOptions,
) !*App {
    const font_size_px = Config.fontSizePixels(config.font_size, 120);
    var font: Font = try .init(alloc, config.font_family, font_size_px);
    errdefer font.deinit(alloc);

    vt.sys.decode_png = decodePng;

    const startup_size = initialTerminalSize(options.initial_size, &font, config);
    const startup_padding = physicalPadding(config, 120);
    const startup_layout = TerminalLayout.init(
        dimensionForCells(startup_size.cols, font.cell_width, startup_padding.left, startup_padding.right),
        dimensionForCells(startup_size.rows, font.cell_height, startup_padding.top, startup_padding.bottom),
        font.cell_width,
        font.cell_height,
        startup_padding,
    );

    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = startup_size.cols,
        .rows = startup_size.rows,
        .max_scrollback = config.scrollback_limit,
        .colors = config.terminalColors(.dark),
        .default_modes = .{ .grapheme_cluster = true },
        // libghostty-vt defaults to a conservative 10MB, which rejects a
        // single fullscreen image on large displays (a 4K RGBA frame is
        // ~32MB). Default matches the Ghostty app (320MB).
        .kitty_image_storage_limit = config.image_storage_limit,
        // Accept every kitty transmission medium, matching the Ghostty
        // app. t=s shared memory matters most for throughput: senders
        // like `mpv --vo=kitty --vo-kitty-use-shm=yes` move pixels
        // through POSIX shm instead of base64 escape data, which is
        // orders of magnitude cheaper to parse. t=t temporary files are
        // only read (and then deleted) from inside the temp dir.
        .kitty_image_loading_limits = .allWithTempDir(tmpDirPath(environ)),
    });
    errdefer term.deinit(alloc);
    term.width_px = startup_size.cols * font.cell_width;
    term.height_px = startup_size.rows * font.cell_height;

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

    // Connect to dbus before the fork so the child can be moved into
    // its own systemd scope before it execs. Filter and fd wiring happen
    // in initDbus once the App has a stable address.
    const dbus_connection: ?*c.DBusConnection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null);
    if (dbus_connection == null) log.warn("session dbus unavailable; desktop integration disabled", .{});
    errdefer if (dbus_connection) |connection| {
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
    };

    var pty: Pty = try .open(.{
        .row = startup_size.rows,
        .col = startup_size.cols,
        .xpixel = @intCast(startup_size.cols * font.cell_width),
        .ypixel = @intCast(startup_size.rows * font.cell_height),
    });
    errdefer pty.deinit();

    // When enabled, move the child into its own transient systemd scope
    // before it can exec. The gate holds the child so grandchildren cannot
    // escape the scope; on failure, releasing the gate lets it proceed
    // un-isolated. Only the request is sent here: systemd's reply and the
    // pid migration land while we set up the window, and the gate is
    // released once both are confirmed below.
    const use_cgroup_scope = config.linux_cgroup == .always and
        dbus_connection != null and
        cgroup.systemdBooted();
    const child_pid = try pty.spawn(path, argv, envp, .{
        .cwd = if (options.working_directory) |cwd| cwd.ptr else null,
        .gate_child = use_cgroup_scope,
    });
    var pending_scope: ?cgroup.Pending = null;
    if (use_cgroup_scope) {
        pending_scope = cgroup.startMoveIntoScope(dbus_connection.?, @intCast(child_pid)) catch blk: {
            log.warn("cgroup isolation unavailable; child stays in our cgroup", .{});
            break :blk null;
        };
    }
    // On error paths the errdefer'd pty.deinit releases the gate.
    errdefer if (pending_scope) |pending| pending.cancel();
    if (pending_scope == null) pty.releaseChild();

    // Nonblocking master: a blocking write can deadlock the whole loop
    // when the child floods output (echoed responses need output-queue
    // space) while we respond to queries embedded in that output.
    setNonblocking(pty.master);

    const window = try Window.create(alloc, config.app_id, options.title, startup_size.window);
    errdefer window.destroy();
    window.setBufferAlpha(config.background_opacity < 255);
    window.setBackgroundBlur(config.background_blur and config.background_opacity < 255);

    // Timerfds must be nonblocking: disarming a timerfd clears its
    // pending expirations, so a reader acting on stale poll revents
    // (event dispatched earlier in the same loop iteration disarmed
    // the timer) would otherwise block the whole loop forever.
    const repeat_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(repeat_fd);

    const fling_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(fling_fd);

    const sync_output_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(sync_output_fd);

    const selection_autoscroll_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(selection_autoscroll_fd);

    const copy_highlight_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(copy_highlight_fd);

    const taskbar_progress_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(taskbar_progress_fd);

    const search_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(search_fd);

    const scrollbar_fd = try createTimerFd();
    errdefer _ = std.os.linux.close(scrollbar_fd);

    // Scope confirmation ran concurrently with the window setup above,
    // so this rarely waits; the child stays gated until its migration
    // is confirmed (or abandoned).
    if (pending_scope) |pending| {
        pending_scope = null;
        pending.finish() catch {
            log.warn("cgroup isolation unavailable; child stays in our cgroup", .{});
        };
        pty.releaseChild();
    }

    // Self-reference into listeners/streams requires a stable address.
    const self = try alloc.create(App);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .config_arena = .init(alloc),
        .config = config,
        .config_path = options.config_path,
        .config_overrides = options.config_overrides,
        .environ = environ,
        .term = term,
        .stream = undefined, // needs the final Terminal address; set below
        .render_state = .empty,
        .scroll_detector = .{},
        .async_raster = null,
        .async_raster_loader = null,
        .async_generation = 1,
        .async_force_full = true,
        .held_frame = null,
        .async_job = .{},
        .kitty_cache = .empty,
        .geometry_redraw = false,
        .frame_damage = @splat(.{
            .full = true,
            .rects = .empty,
            .width = 0,
            .height = 0,
            .grid_x = 0,
            .grid_y = 0,
            .grid_width = 0,
            .grid_height = 0,
            .cell_width = 0,
            .cell_height = 0,
        }),
        .frame_damage_index = 0,
        .damage_rects = .empty,
        .repair_rects = .empty,
        .pty = pty,
        .pipeline = try .init(pty.master),
        .child_pid = child_pid,
        .font = font,
        .font_size_px = font_size_px,
        .runtime_font_size = null,
        .layout = startup_layout,
        .selection_bg = config.effectiveSelectionBackground(.dark),
        .selection_fg = config.effectiveSelectionForeground(.dark),
        .selection_bg_override = null,
        .selection_fg_override = null,
        .copy_highlight = config.effectiveCopyHighlight(.dark),
        .copy_highlight_fg = config.effectiveCopyHighlightForeground(.dark),
        .copy_highlight_active = false,
        .cursor_text = config.effectiveCursorText(.dark),
        .window = window,
        .keyboard = try .init(),
        .needs_redraw = true,
        .focused = true,
        .ime_focused = false,
        .ime_preedit = null,
        .ime_pending_preedit = null,
        .ime_pending_commit = null,
        .search = null,
        .in_band_reports = false,
        .sync_output = false,
        .write_queue = .empty,
        .child_exited = false,
        .hold = options.hold,
        .dbus = dbus_connection,
        .dbus_fd = -1,
        .pending_open_uri = null,
        .notifications = .empty,
        .color_scheme = .dark,
        .signal_fd = signal_fd,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
        .fling_fd = fling_fd,
        .fling_active = false,
        .fling_velocity = 0,
        .scroll_velocity = 0,
        .last_scroll_time_ms = null,
        .sync_output_fd = sync_output_fd,
        .selection_autoscroll_fd = selection_autoscroll_fd,
        .copy_highlight_fd = copy_highlight_fd,
        .taskbar_progress_fd = taskbar_progress_fd,
        .search_fd = search_fd,
        .scrollbar_fd = scrollbar_fd,
        .scrollbar_alpha = 0,
        .scrollbar_reveal_hovered = false,
        .scrollbar_hovered = false,
        .scrollbar_drag = null,
        .pointer_x = 0,
        .pointer_y = 0,
        .pointer_inside = false,
        .hovered_link = null,
        .link_checked_cell = null,
        .link_active = false,
        .link_press = null,
        .scroll_pixels = 0,
        .scroll_frame_pixels = 0,
        .scroll_clicks = 0,
        .scroll_value120 = 0,
        .scroll_line_remainder = 0,
        .scroll_source = .wheel,
        .scroll_time_ms = 0,
        .scroll_had_pixels = false,
        .scroll_had_discrete = false,
        .scroll_had_value120 = false,
        .scroll_stopped = false,
        .selecting = false,
        .selection_rectangle = false,
        .selection_gesture = .init,
        .mouse_button = null,
        .mouse_shape_explicit = false,
        .active_screen = .primary,
        .last_serial = 0,
        .clip_offer = null,
        .clip_pending_offer = null,
        .primary_offer = null,
        .primary_pending_offer = null,
        .dnd_offer = null,
        .clip_source = null,
        .primary_source = null,
        .paste_fd = -1,
        .paste_buf = .empty,
        .paste_action = .terminal,
    };
    self.stream = .initAlloc(alloc, .{
        .app = self,
        .terminal_handler = .init(&self.term),
    });

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
    window.setCallbacks(
        self,
        resize,
        keyboardEvent,
        pointerEvent,
        textInputEvent,
        scaleChanged,
        redrawReady,
        activationTokenReady,
        clipboardDevicesChanged,
    );
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
    const size_px = Config.fontSizePixels(self.effectiveFontSize(), scale120);
    if (size_px == 0 or size_px == self.font_size_px) return;

    const new_font: Font = try .init(self.alloc, self.config.font_family, size_px);
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = size_px;
    self.requestFullAsyncRedraw();
}

const Handler = TerminalHandler;
const Effects = Handler.Effects;

/// Effects callbacks only receive the terminal handler; walk back up through
/// monstar's wrapper handler.
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
    return "monstar " ++ build_options.version;
}

fn effectTitleChanged(handler: *Handler) void {
    const self = appFromHandler(handler);
    const title = self.term.getTitle() orelse return;
    self.window.toplevel.setTitle(title.ptr);
}

fn effectBell(handler: *Handler) void {
    appFromHandler(handler).window.ringBell();
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

fn reportTaskbarProgress(self: *App, report: vt.osc.Command.ProgressReport) void {
    self.sendTaskbarProgress(report) catch |err| {
        if (err != error.DBusUnavailable) {
            log.warn("failed to send taskbar progress: {}", .{err});
        }
        return;
    };

    if (report.state == .remove) {
        self.stopTaskbarProgressTimer();
    } else {
        self.armTaskbarProgressTimer();
    }
}

/// Finish setting up the session bus connection made in init (filter,
/// matches, poll fd); the connection itself is created before the child
/// fork so that cgroup scope creation can use it.
fn initDbus(self: *App) void {
    const connection = self.dbus orelse return;

    if (c.dbus_connection_add_filter(connection, dbusFilter, self, null) == 0) {
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
        self.dbus = null;
        return;
    }
    c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.Notifications'", null);
    c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.portal.Settings'", null);

    var fd: c_int = -1;
    if (c.dbus_connection_get_unix_fd(connection, &fd) == 0) {
        c.dbus_connection_remove_filter(connection, dbusFilter, self);
        c.dbus_connection_close(connection);
        c.dbus_connection_unref(connection);
        self.dbus = null;
        return;
    }

    self.dbus_fd = fd;
    self.readPortalColorScheme();
}

fn deinitDbus(self: *App) void {
    self.sendTaskbarProgress(.{ .state = .remove }) catch {};
    var it = self.notifications.valueIterator();
    while (it.next()) |token| {
        if (token.*) |value| self.alloc.free(value);
    }
    self.notifications.deinit(self.alloc);

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
    self.setColorScheme(portalColorScheme(value), false);
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
    try dbusAppendStringVariant(&hints, "desktop-entry", self.config.app_id);
    if (c.dbus_message_iter_close_container(&iter, &hints) == 0) return error.OutOfMemory;

    var expire_timeout: i32 = -1;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_INT32, &expire_timeout);

    const reply = c.dbus_connection_send_with_reply_and_block(connection, message, 1000, null) orelse return error.DBusUnavailable;
    defer c.dbus_message_unref(reply);

    const notification_id = dbusMessageUint32(reply) orelse return;
    if (try self.notifications.fetchPut(self.alloc, notification_id, null)) |old| {
        if (old.value) |token| self.alloc.free(token);
    }
}

fn sendTaskbarProgress(self: *App, report: vt.osc.Command.ProgressReport) !void {
    const connection = self.dbus orelse return error.DBusUnavailable;

    const message = c.dbus_message_new_signal(
        "/com/canonical/Unity/LauncherEntry",
        "com.canonical.Unity.LauncherEntry",
        "Update",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);
    const desktop_uri_z = try std.fmt.allocPrintSentinel(self.alloc, "application://{s}.desktop", .{self.config.app_id}, 0);
    defer self.alloc.free(desktop_uri_z);
    var desktop_uri: [*:0]const u8 = desktop_uri_z;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &desktop_uri);

    var properties: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "{sv}", &properties) == 0) return error.OutOfMemory;

    const value = taskbarProgressValue(report);
    const visible = report.state != .remove;
    try dbusAppendBoolVariant(&properties, "progress-visible", visible);
    try dbusAppendDoubleVariant(&properties, "progress", value);

    if (c.dbus_message_iter_close_container(&iter, &properties) == 0) return error.OutOfMemory;

    if (c.dbus_connection_send(connection, message, null) == 0) return error.OutOfMemory;
    c.dbus_connection_flush(connection);
}

fn taskbarProgressValue(report: vt.osc.Command.ProgressReport) f64 {
    return switch (report.state) {
        .remove, .indeterminate => 0.0,
        .set, .@"error", .pause => if (report.progress) |progress|
            @as(f64, @floatFromInt(progress)) / 100.0
        else
            0.0,
    };
}

fn openUriPortal(self: *App, uri: []const u8, activation_token: ?[:0]const u8) !void {
    const connection = self.dbus orelse return error.PortalUnavailable;

    // The portal's OpenURI method rejects file:// URIs by design; local
    // paths go through the fd-passing OpenFile/OpenDirectory methods.
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    if (try osc7Path(arena_state.allocator(), uri)) |path| {
        return openFilePortal(connection, path, activation_token);
    }

    const uri_z = try self.alloc.dupeZ(u8, uri);
    defer self.alloc.free(uri_z);

    const message = c.dbus_message_new_method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.OpenURI",
        "OpenURI",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);
    var parent_window: [*:0]const u8 = "";
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &parent_window);
    var uri_ptr: [*:0]const u8 = uri_z;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &uri_ptr);

    var options: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "{sv}", &options) == 0) return error.OutOfMemory;
    if (activation_token) |token| try dbusAppendStringVariant(&options, "activation_token", token);
    if (c.dbus_message_iter_close_container(&iter, &options) == 0) return error.OutOfMemory;

    try sendPortalCall(connection, message);
}

/// Open a local file or directory through the portal by passing an fd:
/// files open with the default handler, directories in the file manager.
fn openFilePortal(connection: *c.DBusConnection, path: [:0]const u8, activation_token: ?[:0]const u8) !void {
    const linux = std.os.linux;

    // Directory-ness decides the portal method; O_DIRECTORY fails with
    // ENOTDIR on regular files. NONBLOCK guards against FIFOs blocking
    // the event loop (a no-op for regular files).
    var is_dir = true;
    var rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NONBLOCK = true,
    }, 0);
    if (linux.errno(rc) == .NOTDIR) {
        is_dir = false;
        rc = linux.openat(linux.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
    }
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: posix.fd_t = @intCast(rc);
    // libdbus dups the fd when it is appended, so ours closes here.
    defer _ = linux.close(fd);

    const message = c.dbus_message_new_method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.OpenURI",
        if (is_dir) "OpenDirectory" else "OpenFile",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);
    var parent_window: [*:0]const u8 = "";
    try dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &parent_window);
    var fd_value: c_int = fd;
    try dbusAppendBasic(&iter, c.DBUS_TYPE_UNIX_FD, &fd_value);

    var options: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "{sv}", &options) == 0) return error.OutOfMemory;
    if (activation_token) |token| try dbusAppendStringVariant(&options, "activation_token", token);
    if (c.dbus_message_iter_close_container(&iter, &options) == 0) return error.OutOfMemory;

    try sendPortalCall(connection, message);
}

/// Send a portal request while preserving the distinction between a portal
/// that is absent and a request whose outcome is ambiguous. Falling back after
/// a timeout could open the URI twice if the portal handles the request late.
fn sendPortalCall(connection: *c.DBusConnection, message: *c.DBusMessage) !void {
    var call: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(connection, message, &call, 1000) == 0)
        return error.OutOfMemory;
    const pending = call orelse return error.DBusUnavailable;
    defer c.dbus_pending_call_unref(pending);

    c.dbus_pending_call_block(pending);
    const reply = c.dbus_pending_call_steal_reply(pending) orelse
        return error.DBusUnavailable;
    defer c.dbus_message_unref(reply);

    if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_ERROR) return;
    const name = c.dbus_message_get_error_name(reply);
    if (name != null and isPortalUnavailableErrorName(std.mem.span(name))) {
        return error.PortalUnavailable;
    }
    return error.DBusUnavailable;
}

fn isPortalUnavailableErrorName(name: []const u8) bool {
    const unavailable = [_][]const u8{
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
        "org.freedesktop.DBus.Error.UnknownMethod",
        "org.freedesktop.DBus.Error.UnknownInterface",
        "org.freedesktop.DBus.Error.UnknownObject",
    };
    for (unavailable) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "only definitive portal errors enable fallback" {
    try std.testing.expect(isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.ServiceUnknown",
    ));
    try std.testing.expect(isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.UnknownMethod",
    ));
    try std.testing.expect(!isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.NoReply",
    ));
    try std.testing.expect(!isPortalUnavailableErrorName(
        "org.freedesktop.DBus.Error.TimedOut",
    ));
}

fn dbusAppendBasic(iter: *c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn dbusAppendStringVariant(iter: *c.DBusMessageIter, key: [:0]const u8, value: [:0]const u8) !void {
    var value_ptr: [*:0]const u8 = value;
    try dbusAppendVariant(iter, key, "s", c.DBUS_TYPE_STRING, &value_ptr);
}

fn dbusAppendBoolVariant(iter: *c.DBusMessageIter, key: [:0]const u8, value: bool) !void {
    var dbus_value: c.dbus_bool_t = if (value) 1 else 0;
    try dbusAppendVariant(iter, key, "b", c.DBUS_TYPE_BOOLEAN, &dbus_value);
}

fn dbusAppendDoubleVariant(iter: *c.DBusMessageIter, key: [:0]const u8, value: f64) !void {
    var dbus_value = value;
    try dbusAppendVariant(iter, key, "d", c.DBUS_TYPE_DOUBLE, &dbus_value);
}

fn dbusAppendVariant(
    iter: *c.DBusMessageIter,
    key: [:0]const u8,
    comptime signature: [:0]const u8,
    type_: c_int,
    value: anytype,
) !void {
    var entry: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
    var key_ptr: [*:0]const u8 = key;
    try dbusAppendBasic(&entry, c.DBUS_TYPE_STRING, &key_ptr);

    var variant: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, signature, &variant) == 0) return error.OutOfMemory;
    try dbusAppendBasic(&variant, type_, value);
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
    self.setColorScheme(color_scheme, true);
}

fn setColorScheme(self: *App, color_scheme: vt.device_status.ColorScheme, report: bool) void {
    self.color_scheme = color_scheme;
    self.applyColorDefaults();
    if (report and self.term.modes.get(.report_color_scheme)) self.sendColorSchemeReport();
}

fn handleNotificationActivationToken(self: *App, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_UINT32) return;
    var notification_id: u32 = 0;
    c.dbus_message_iter_get_basic(&iter, &notification_id);
    const token_slot = self.notifications.getPtr(notification_id) orelse return;
    if (c.dbus_message_iter_next(&iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var token_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&token_ptr));

    const token = std.mem.span(token_ptr);
    const owned = self.alloc.dupe(u8, token) catch return;
    if (token_slot.*) |old| self.alloc.free(old);
    token_slot.* = owned;
}

fn handleNotificationActionInvoked(self: *App, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_UINT32) return;
    var notification_id: u32 = 0;
    c.dbus_message_iter_get_basic(&iter, &notification_id);
    const notification = self.notifications.fetchRemove(notification_id) orelse return;
    defer if (notification.value) |token| self.alloc.free(token);
    if (c.dbus_message_iter_next(&iter) == 0) return;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
    var action_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&action_ptr));
    if (!std.mem.eql(u8, std.mem.span(action_ptr), "default")) return;

    const token = notification.value orelse return;
    if (token.len == 0) return;

    const token_z = self.alloc.dupeZ(u8, token) catch return;
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
    self.pipeline.deinit();
    self.pty.deinit();
    self.cancelDrag();
    self.selection_gesture.deinit(&self.term);
    for (&self.frame_damage) |*damage| damage.rects.deinit(self.alloc);
    if (self.async_raster_loader) |*loader| loader.deinit();
    if (self.async_raster) |*async_raster| async_raster.deinit();
    self.async_job.deinit(self.alloc, &self.kitty_cache);
    if (self.hovered_link) |link| self.alloc.free(link.uri);
    if (self.link_press) |press| self.alloc.free(press.uri);
    self.kitty_cache.deinit(self.alloc);
    self.damage_rects.deinit(self.alloc);
    self.repair_rects.deinit(self.alloc);
    self.clearImeText();
    if (self.search) |*search| search.deinit(self.alloc, &self.term);
    if (self.paste_fd >= 0) _ = std.os.linux.close(self.paste_fd);
    self.paste_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.dnd_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
    self.write_queue.deinit(self.alloc);
    if (self.pending_open_uri) |uri| self.alloc.free(uri);
    self.deinitDbus();
    _ = std.os.linux.close(self.scrollbar_fd);
    _ = std.os.linux.close(self.search_fd);
    _ = std.os.linux.close(self.taskbar_progress_fd);
    _ = std.os.linux.close(self.copy_highlight_fd);
    _ = std.os.linux.close(self.selection_autoscroll_fd);
    _ = std.os.linux.close(self.sync_output_fd);
    _ = std.os.linux.close(self.fling_fd);
    _ = std.os.linux.close(self.repeat_fd);
    _ = std.os.linux.close(self.signal_fd);
    self.keyboard.deinit();
    self.window.destroy();
    self.scroll_detector.deinit(self.alloc);
    self.render_state.deinit(self.alloc);
    self.stream.deinit();
    self.term.deinit(self.alloc);
    self.font.deinit(self.alloc);
    self.config_arena.deinit();
    self.alloc.destroy(self);
}

/// Run until the window is closed or, without hold mode, the child exits.
pub fn run(self: *App) !void {
    errdefer self.hangupChild();

    // The raster worker is the only renderer; start building it before
    // the first configure so it is usually ready by the first frame.
    self.startAsyncRasterLoad();

    try self.pipeline.start();

    const display = self.window.display;
    var fds = [_]posix.pollfd{
        .{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        // Parsed pty batches arrive via the pipeline's ready eventfd;
        // the master itself is only polled for writability (below).
        .{ .fd = self.pipeline.ready_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 },
        .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 },
        // In-flight paste pipe; negative (ignored) while idle.
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.signal_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.sync_output_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.selection_autoscroll_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.copy_highlight_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.taskbar_progress_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.dbus_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.fling_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.search_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.scrollbar_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const wl_fd = &fds[0];
    const pipeline_fd = &fds[1];
    const pty_write_fd = &fds[2];
    const repeat_fd = &fds[3];
    const paste_fd = &fds[4];
    const signal_fd = &fds[5];
    const sync_output_fd = &fds[6];
    const selection_autoscroll_fd = &fds[7];
    const copy_highlight_fd = &fds[8];
    const taskbar_progress_fd = &fds[9];
    const dbus_fd = &fds[10];
    const async_fd = &fds[11];
    const fling_fd = &fds[12];
    const search_fd = &fds[13];
    const scrollbar_fd = &fds[14];

    while (self.window.running and (!self.child_exited or self.hold)) {
        wl_fd.events = posix.POLL.IN;
        dbus_fd.fd = self.dbus_fd;
        async_fd.fd = if (self.async_raster_loader) |*loader|
            loader.complete_fd
        else if (self.async_raster) |*async_raster|
            async_raster.complete_fd
        else
            -1;

        // Standard libwayland read dance: drain the local queue, flush
        // requests, then sleep until one of the fds is ready.
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            self.window.flushPending();
        }
        // Pending Wayland callbacks can request a redraw while prepareRead
        // drains the local queue. Do that work before entering an infinite
        // poll, or it may remain stranded until an unrelated fd wakes us.
        if (self.hasReadyRedraw()) {
            display.cancelRead();
            try self.redrawIfNeeded();
            continue;
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

        // Only poll the master while a write backlog exists, otherwise
        // POLLOUT would make every poll return immediately.
        pty_write_fd.fd = if (self.write_queue.items.len > 0) self.pty.master else -1;
        paste_fd.fd = self.paste_fd;

        const ready = posix.poll(&fds, -1) catch {
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
        self.window.flushPending();

        if (signal_fd.revents & posix.POLL.IN != 0) {
            try self.drainSignals();
        }

        if (pty_write_fd.revents & posix.POLL.OUT != 0) {
            self.flushWriteQueue();
        }
        if (pipeline_fd.revents & posix.POLL.IN != 0) {
            try self.drainPipeline();
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

        if (copy_highlight_fd.revents & posix.POLL.IN != 0) {
            self.fireCopyHighlightTimeout();
        }

        if (fling_fd.revents & posix.POLL.IN != 0) {
            self.fireFling();
        }

        if (search_fd.revents & posix.POLL.IN != 0) {
            self.fireSearch();
        }

        if (scrollbar_fd.revents & posix.POLL.IN != 0) {
            self.fireScrollbarFade();
        }

        if (taskbar_progress_fd.revents & posix.POLL.IN != 0) {
            self.fireTaskbarProgressTimeout();
        }

        if (dbus_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.dispatchDbus();
        }

        if (async_fd.revents & posix.POLL.IN != 0) {
            if (self.async_raster_loader != null)
                self.finishAsyncRasterLoad()
            else
                self.finishAsyncRender();
        }

        if (self.paste_fd >= 0 and paste_fd.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            self.readPaste();
        }

        try self.redrawIfNeeded();
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
    // The gather thread must be joined before the master can be closed;
    // stop() is idempotent and deinit covers the child-exited path.
    self.pipeline.stop();
    if (self.child_exited) {
        return;
    }
    self.pty.closeMaster();
    _ = std.os.linux.kill(self.child_pid, std.os.linux.SIG.HUP);
}

/// Signal events arrived. SIGCHLD is the only place the terminal decides
/// the session is over; SIGUSR1 reloads process-local configuration.
fn drainSignals(self: *App) !void {
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
        if (try Pty.tryWait(self.child_pid)) |status| {
            log.debug("child exited with status {d}", .{status});
            self.child_exited = true;
        }
    }
}

fn reloadConfig(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    var committed = false;
    defer if (!committed) arena_state.deinit();

    const arena = arena_state.allocator();
    var new_config = if (self.config_path) |path|
        Config.loadPath(arena, path)
    else
        Config.load(arena, self.environ);
    for (self.config_overrides) |override| {
        new_config.applyOverride(arena, override) catch |err| {
            log.warn("config override failed: {s}: {}", .{ override, err });
            return;
        };
    }
    new_config.resolveThemes(self.io, arena, self.environ) catch |err| {
        log.warn("theme reload failed: {}", .{err});
        return;
    };
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

/// Ctrl+Shift+N: spawn an independent monstar window in the shell's
/// current directory through the user service manager so the new window
/// is not adopted by this monstar's launcher.
fn spawnNewWindow(self: *App) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pwd: ?[:0]const u8 = pwd: {
        const url = self.term.getPwd() orelse break :pwd null;
        break :pwd osc7Path(arena, url) catch null;
    };

    const envp = self.spawnEnvp(arena, pwd, null) catch |err| {
        log.err("spawn env setup failed: {}", .{err});
        return;
    };
    const exe_path = resolveCommandPathZ(arena, self.environ, "monstar") catch "monstar";

    self.spawnSystemdRun(arena, envp, exe_path, pwd) catch |err| {
        log.err("new window launch failed: {}", .{err});
    };
}

fn spawnSystemdRun(
    self: *App,
    arena: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    exe_path: [:0]const u8,
    pwd: ?[:0]const u8,
) !void {
    const systemd_run = try resolveCommandPath(arena, self.environ, "systemd-run");

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "systemd-run", "--user", "--collect" });
    if (pwd) |p| {
        const cwd_arg = try std.fmt.allocPrintSentinel(arena, "--working-directory={s}", .{p}, 0);
        try argv.append(arena, cwd_arg.ptr);
    }
    try argv.append(arena, exe_path.ptr);
    const argv_slice = try argv.toOwnedSliceSentinel(arena, null);
    if (!spawnLauncher(systemd_run, argv_slice.ptr, envp, "systemd-run")) {
        return error.SystemdRunFailed;
    }
}

fn spawnLauncher(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    label: []const u8,
) bool {
    const linux = std.os.linux;

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("{s} fork failed: {}", .{ label, linux.errno(fork_rc) });
        return false;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.execve(path, argv, envp);
        linux.exit(127);
    }

    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
    return waitStatusExitedZero(status);
}

fn spawnDetached(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
    label: []const u8,
) bool {
    const linux = std.os.linux;

    // Double fork: the intermediate child exits immediately so init adopts
    // the launched process and it never lingers as our zombie.
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("{s} fork failed: {}", .{ label, linux.errno(fork_rc) });
        return false;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // Intermediate child. Only async-signal-safe calls from here on.
        // We block SIGCHLD/SIGUSR1 for our signalfd; the launched process must
        // start with a clean mask and its own session.
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.setsid();
        const detached_rc = linux.fork();
        if (linux.errno(detached_rc) != .SUCCESS) linux.exit(127);
        if (detached_rc != 0) linux.exit(0);

        if (pwd) |p| _ = linux.chdir(p.ptr);
        _ = linux.execve(path, argv, envp);
        linux.exit(127); // exec failed
    }

    // Reap the intermediate child; it exits right after the second fork.
    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
    return waitStatusExitedZero(status);
}

fn waitStatusExitedZero(status: u32) bool {
    return (status & 0x7f) == 0 and (status >> 8) == 0;
}

pub fn resolveCommandPath(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    command: [:0]const u8,
) ![*:0]const u8 {
    return (try resolveCommandPathZ(arena, environ, command)).ptr;
}

pub fn resolveCommandPathZ(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    command: [:0]const u8,
) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;

    const path_env = environ.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        const base = if (dir.len == 0) "." else dir;
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ base, command }, 0);
        var stat = std.mem.zeroes(std.os.linux.Statx);
        const stat_rc = std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            candidate,
            std.os.linux.AT.NO_AUTOMOUNT,
            .{ .TYPE = true },
            &stat,
        );
        if (std.os.linux.errno(stat_rc) == .SUCCESS and stat.mask.TYPE and
            std.os.linux.S.ISREG(stat.mode) and
            std.os.linux.errno(std.os.linux.access(candidate, std.os.linux.X_OK)) == .SUCCESS)
        {
            return candidate;
        }
    }
    return command;
}

/// Ctrl+Shift+Z/X: move the scrollback viewport between OSC 133 prompt marks.
fn jumpPrompt(self: *App, delta: isize) void {
    const screen = self.term.screens.active;
    if (!screen.semantic_prompt.seen) return;
    screen.pages.scroll(.{ .delta_prompt = delta });
    self.revealScrollbar();
    self.clearSelection();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

/// Ctrl+Shift+G: pipe the most recent OSC 133-delimited command output to
/// the configured shell command. The command runs as `/bin/sh -c <value>`.
fn pipeCommandOutput(self: *App) void {
    const command = self.config.pipe_command_output orelse return;
    const output = self.lastCommandOutput() orelse return;
    defer self.alloc.free(output);

    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pwd: ?[:0]const u8 = pwd: {
        const url = self.term.getPwd() orelse break :pwd null;
        break :pwd osc7Path(arena, url) catch null;
    };
    const envp = self.spawnEnvp(arena, pwd, null) catch |err| {
        log.err("pipe command env setup failed: {}", .{err});
        return;
    };

    spawnPipeCommand(command, output, envp, pwd);
}

fn lastCommandOutput(self: *App) ?[:0]const u8 {
    return semanticCommandOutputText(self.alloc, self.term.screens.active);
}

fn semanticCommandOutputText(alloc: std.mem.Allocator, screen: *vt.Screen) ?[:0]const u8 {
    if (!screen.semantic_prompt.seen) return null;

    var it = screen.pages.promptIterator(.left_up, .{ .screen = .{} }, null);
    while (it.next()) |prompt_pin| {
        const hl = screen.pages.highlightSemanticContent(prompt_pin, .output) orelse continue;
        const sel = vt.Selection.init(hl.start, hl.end, false);
        return screen.selectionString(alloc, .{ .sel = sel, .trim = false }) catch null;
    }
    return null;
}

fn spawnPipeCommand(
    command: [:0]const u8,
    output: []const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
) void {
    const linux = std.os.linux;

    var fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
    if (linux.errno(pipe_rc) != .SUCCESS) {
        log.err("pipe command pipe failed: {}", .{linux.errno(pipe_rc)});
        return;
    }
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        log.err("pipe command fork failed: {}", .{linux.errno(fork_rc)});
        return;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        _ = linux.setsid();

        const runner_rc = linux.fork();
        if (linux.errno(runner_rc) == .SUCCESS and runner_rc == 0) {
            runPipeCommandChild(command, envp, pwd, fds[0], fds[1]);
        }

        const writer_rc = linux.fork();
        if (linux.errno(writer_rc) == .SUCCESS and writer_rc == 0) {
            writePipeCommandChild(output, fds[0], fds[1]);
        }

        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        linux.exit(0);
    }

    var status: u32 = undefined;
    _ = linux.wait4(pid, &status, 0, null);
}

fn runPipeCommandChild(
    command: [:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    pwd: ?[:0]const u8,
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
) noreturn {
    const linux = std.os.linux;
    if (pwd) |p| _ = linux.chdir(p.ptr);
    _ = linux.dup2(read_fd, 0);
    _ = linux.close(read_fd);
    _ = linux.close(write_fd);

    const devnull = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(devnull) == .SUCCESS) {
        const fd: posix.fd_t = @intCast(devnull);
        _ = linux.dup2(fd, 1);
        _ = linux.dup2(fd, 2);
        if (fd > 2) _ = linux.close(fd);
    }

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command.ptr };
    _ = linux.execve("/bin/sh", &argv, envp);
    linux.exit(127);
}

fn writePipeCommandChild(output: []const u8, read_fd: posix.fd_t, write_fd: posix.fd_t) noreturn {
    const linux = std.os.linux;
    _ = linux.close(read_fd);
    writeAllFd(write_fd, output);
    _ = linux.close(write_fd);
    linux.exit(0);
}

fn writeAllFd(fd: posix.fd_t, data: []const u8) void {
    const linux = std.os.linux;
    var offset: usize = 0;
    while (offset < data.len) {
        const rc = linux.write(fd, data.ptr + offset, data.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                offset += rc;
            },
            .INTR => {},
            else => return,
        }
    }
}

/// Environment for a spawned process, with optional PWD and activation-token
/// overrides.
fn spawnEnvp(
    self: *App,
    arena: std.mem.Allocator,
    pwd: ?[:0]const u8,
    activation_token: ?[:0]const u8,
) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (self.environ.block.slice) |entry| {
        const e = entry orelse continue;
        if (pwd != null and std.mem.startsWith(u8, std.mem.span(e), "PWD=")) continue;
        // Activation tokens are single-use and must not leak from the process
        // that launched us into unrelated children.
        if (std.mem.startsWith(u8, std.mem.span(e), "XDG_ACTIVATION_TOKEN=")) continue;
        try list.append(arena, e);
    }
    if (pwd) |p| {
        const entry = try std.mem.joinZ(arena, "", &.{ "PWD=", p });
        try list.append(arena, entry.ptr);
    }
    if (activation_token) |token| {
        const entry = try std.mem.joinZ(arena, "", &.{ "XDG_ACTIVATION_TOKEN=", token });
        try list.append(arena, entry.ptr);
    }
    const slice = try list.toOwnedSliceSentinel(arena, null);
    return slice.ptr;
}

/// Decode an OSC 7 payload (`file://host/path`) into a local filesystem
/// path. Returns null for anything that is not an absolute path on this
/// machine: foreign schemes, remote hosts, malformed URIs.
fn osc7Path(arena: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) return null;

    if (uri.host) |host| {
        const h = try host.toRawMaybeAlloc(arena);
        if (h.len > 0 and !std.mem.eql(u8, h, "localhost")) {
            var name_buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = posix.gethostname(&name_buf) catch return null;
            if (!std.mem.eql(u8, h, hostname)) return null;
        }
    }

    const path = try uri.path.toRawMaybeAlloc(arena);
    if (path.len == 0 or path[0] != '/') return null;
    return try arena.dupeZ(u8, path);
}

fn formatUriListDrop(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();

    var first = true;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (line.len == 0 or line[0] == '#') continue;
        const path = (try osc7Path(arena, line)) orelse continue;

        if (!first) try writer.writer.writeByte(' ');
        first = false;
        try writeShellQuoted(&writer.writer, path);
    }

    return writer.toOwnedSlice();
}

fn writeShellQuoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

test "osc7Path decodes local file URIs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "/home/tim",
        (try osc7Path(arena, "file:///home/tim")).?,
    );
    try std.testing.expectEqualStrings(
        "/home/tim",
        (try osc7Path(arena, "file://localhost/home/tim")).?,
    );
    try std.testing.expectEqualStrings(
        "/home/tim/my dir",
        (try osc7Path(arena, "file:///home/tim/my%20dir")).?,
    );

    // Remote hosts, foreign schemes, and junk must not produce a path.
    try std.testing.expectEqual(null, try osc7Path(arena, "file://otherhost.example/home/tim"));
    try std.testing.expectEqual(null, try osc7Path(arena, "https://example.com/x"));
    try std.testing.expectEqual(null, try osc7Path(arena, "not a uri"));
    try std.testing.expectEqual(null, try osc7Path(arena, "file://"));
}

test "formatUriListDrop shell quotes local file paths" {
    const text = try formatUriListDrop(
        std.testing.allocator,
        "# comment\r\nfile:///tmp/a%20b\r\nhttps://example.com/nope\nfile:///tmp/it%27s\n",
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("'/tmp/a b' '/tmp/it'\\''s'", text);
}

fn applyConfig(self: *App, new_config: Config) !void {
    const desired_font_size = Config.fontSizePixels(self.runtime_font_size orelse new_config.font_size, self.window.scale120);
    const new_font: Font = try .init(self.alloc, new_config.font_family, desired_font_size);

    self.applyColorDefaultsForConfig(new_config);
    self.window.setBufferAlpha(new_config.background_opacity < 255);
    self.window.setBackgroundBlur(new_config.background_blur and new_config.background_opacity < 255);
    self.window.toplevel.setAppId(new_config.app_id);

    if (new_config.image_storage_limit != self.config.image_storage_limit) {
        self.term.setKittyGraphicsSizeLimit(self.alloc, new_config.image_storage_limit) catch |err| {
            log.warn("kitty image storage limit change failed: {}", .{err});
        };
    }

    // Always rebuild the Font on config reload so a reload also picks up
    // fontconfig/file changes for the same family name. The resize path is
    // responsible for deciding whether the new cell metrics changed enough
    // to notify the pty and DEC 2048 in-band size-report listeners.
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = desired_font_size;
    resizeForConfig(
        self,
        Window.physicalDimension(self.window.width, self.window.scale120),
        Window.physicalDimension(self.window.height, self.window.scale120),
        new_config,
    ) catch |err| {
        log.warn("config reload resize failed: {}", .{err});
    };

    if (!new_config.inertial_scrolling) self.stopFling();
    self.requestFullAsyncRedraw();
}

fn applyColorDefaults(self: *App) void {
    self.applyColorDefaultsForConfig(self.config);
    self.requestFullAsyncRedraw();
}

fn applyColorDefaultsForConfig(self: *App, config: Config) void {
    const colors = config.terminalColors(self.color_scheme);
    self.term.colors.background.default = colors.background.default;
    self.term.colors.foreground.default = colors.foreground.default;
    self.term.colors.cursor.default = colors.cursor.default;
    self.term.colors.palette.changeDefault(colors.palette.original);

    self.selection_bg = colorWithRuntimeOverride(
        config.effectiveSelectionBackground(self.color_scheme),
        self.selection_bg_override,
    );
    self.selection_fg = colorWithRuntimeOverride(
        config.effectiveSelectionForeground(self.color_scheme),
        self.selection_fg_override,
    );
    self.copy_highlight = config.effectiveCopyHighlight(self.color_scheme);
    self.copy_highlight_fg = config.effectiveCopyHighlightForeground(self.color_scheme);
    self.cursor_text = config.effectiveCursorText(self.color_scheme);
}

fn selectionBackgroundForRender(self: *const App) vt.color.RGB {
    return if (self.copy_highlight_active) self.copy_highlight else self.selection_bg;
}

fn selectionForegroundForRender(self: *const App) ?vt.color.RGB {
    return if (self.copy_highlight_active) self.copy_highlight_fg else self.selection_fg;
}

fn colorWithRuntimeOverride(default: vt.color.RGB, runtime: ?vt.color.RGB) vt.color.RGB {
    return runtime orelse default;
}

test "runtime color override survives default changes until reset" {
    const first_default: vt.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
    const next_default: vt.color.RGB = .{ .r = 4, .g = 5, .b = 6 };
    const runtime: vt.color.RGB = .{ .r = 7, .g = 8, .b = 9 };

    try std.testing.expectEqual(runtime, colorWithRuntimeOverride(first_default, runtime));
    try std.testing.expectEqual(runtime, colorWithRuntimeOverride(next_default, runtime));
    try std.testing.expectEqual(next_default, colorWithRuntimeOverride(next_default, null));
}

fn effectiveFontSize(self: *const App) Config.FontSize {
    return self.runtime_font_size orelse self.config.font_size;
}

fn setRuntimeFontSize(self: *App, configured_size: ?Config.FontSize) void {
    const next_size = configured_size orelse self.config.font_size;
    const size_px = Config.fontSizePixels(next_size, self.window.scale120);
    const new_font: Font = Font.init(self.alloc, self.config.font_family, size_px) catch |err| {
        log.warn("font size change failed: {}", .{err});
        return;
    };

    self.runtime_font_size = configured_size;
    self.font.deinit(self.alloc);
    self.font = new_font;
    self.font_size_px = size_px;
    resize(
        self,
        Window.physicalDimension(self.window.width, self.window.scale120),
        Window.physicalDimension(self.window.height, self.window.scale120),
    ) catch |err| {
        log.warn("font size change resize failed: {}", .{err});
    };
    self.requestFullAsyncRedraw();
}

fn adjustRuntimeFontSize(self: *App, delta: i32) void {
    const current = self.effectiveFontSize();
    const amount = @as(f32, @floatFromInt(delta));
    const next: Config.FontSize = switch (current) {
        .points => |value| .{ .points = std.math.clamp(value + amount, 1, 512) },
        .pixels => |value| .{ .pixels = std.math.clamp(value + amount, 1, 512) },
    };
    if (std.meta.eql(next, current)) return;
    self.setRuntimeFontSize(next);
}

fn resetRuntimeFontSize(self: *App) void {
    if (self.runtime_font_size == null) return;
    self.setRuntimeFontSize(null);
}

/// Feed pipeline batches of PTY output into the terminal. Bounded to
/// one ring's worth so a flooding child cannot starve the Wayland side
/// of the loop; rearm() keeps the eventfd hot while batches remain.
///
/// The master can never return EIO/EOF because Pty.spawn retains a
/// slave fd in this process; only SIGCHLD ends the session.
fn drainPipeline(self: *App) !void {
    self.pipeline.clearReady();
    var consumed = false;
    for (0..ReadPipeline.buffer_count) |_| {
        const batch = self.pipeline.take() orelse break;
        self.stream.nextSlice(batch);
        self.pipeline.release();
        consumed = true;
        self.needs_redraw = true;
    }
    self.pipeline.rearm();
    if (self.pipeline.hasFailed()) return error.PtyReadFailed;
    self.syncInBandSizeReports();
    self.syncSynchronizedOutput();
    self.syncActiveScreen();
    self.syncScrollbarHover();
    if (consumed) self.refreshSearch();
    if (consumed) self.syncHoveredLink(true);
}

fn handleOscColorOperation(
    self: *App,
    requests: *const vt.osc.color.List,
    terminator: vt.osc.Terminator,
) void {
    var it = requests.constIterator(0);
    while (it.next()) |req| {
        switch (req.*) {
            .set => |set| self.setOscColor(set),
            .query => |target| self.answerOscSelectionColorQuery(target, terminator),
            .reset => |target| self.resetOscColor(target),
            else => {},
        }
    }
}

fn setOscColor(self: *App, set: vt.osc.color.ColoredTarget) void {
    switch (set.target) {
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => {
                self.selection_bg_override = set.color;
                self.selection_bg = set.color;
            },
            .highlight_foreground => {
                self.selection_fg_override = set.color;
                self.selection_fg = set.color;
            },
            else => return,
        },
        else => return,
    }
    self.requestFullAsyncRedraw();
}

fn resetOscColor(self: *App, target: vt.osc.color.Target) void {
    switch (target) {
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => {
                self.selection_bg_override = null;
                self.selection_bg = self.config.effectiveSelectionBackground(self.color_scheme);
            },
            .highlight_foreground => {
                self.selection_fg_override = null;
                self.selection_fg = self.config.effectiveSelectionForeground(self.color_scheme);
            },
            else => return,
        },
        else => return,
    }
    self.requestFullAsyncRedraw();
}

fn answerKittySelectionColorQueries(self: *App, request: vt.kitty.color.OSC) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();

    const wrote_response = self.formatKittySelectionColorResponse(&writer.writer, request) catch return;
    if (!wrote_response) return;

    const response = writer.toOwnedSlice() catch return;
    defer self.alloc.free(response);
    self.writePty(response);
}

fn formatKittySelectionColorResponse(
    self: *const App,
    writer: *std.Io.Writer,
    request: vt.kitty.color.OSC,
) !bool {
    var wrote_response = false;
    for (request.list.items) |item| {
        switch (item) {
            .query => |key| {
                const value = self.kittySelectionColorValue(key) orelse continue;
                if (!wrote_response) {
                    try writer.writeAll("\x1b]21");
                    wrote_response = true;
                }
                try writeKittyColorReport(writer, key, value);
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

fn kittySelectionColorValue(self: *const App, key: vt.kitty.color.Kind) ?KittyColorValue {
    return switch (key) {
        .palette => null,
        .special => |special| switch (special) {
            .selection_background => .{ .color = self.selection_bg },
            .selection_foreground => if (self.selection_fg) |color|
                .{ .color = color }
            else
                .unset,
            .foreground,
            .background,
            .cursor,
            .cursor_text,
            .visual_bell,
            .second_transparent_background,
            => null,
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
        self.beginOsc52Read(kind);
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
        .clipboard => _ = self.claimClipboardText(text),
        .primary => self.claimPrimaryText(text),
    }
}

fn beginOsc52Read(self: *App, kind: u8) void {
    if (self.paste_fd >= 0) return;

    switch (osc52Target(kind)) {
        .clipboard => {
            const offer = self.clip_offer orelse return self.writeOsc52ClipboardReport(kind, "");
            self.beginClipboardTransfer(offer.bestMime() orelse return self.writeOsc52ClipboardReport(kind, ""), .{ .clipboard = offer }, .{ .osc52_read = kind }) catch {
                self.writeOsc52ClipboardReport(kind, "");
            };
        },
        .primary => {
            const offer = self.primary_offer orelse return self.writeOsc52ClipboardReport(kind, "");
            self.beginClipboardTransfer(offer.bestMime() orelse return self.writeOsc52ClipboardReport(kind, ""), .{ .primary = offer }, .{ .osc52_read = kind }) catch {
                self.writeOsc52ClipboardReport(kind, "");
            };
        },
    }
}

fn writeOsc52ClipboardReport(self: *App, kind: u8, data: []const u8) void {
    var writer: std.Io.Writer.Allocating = .init(self.alloc);
    defer writer.deinit();
    formatOsc52ClipboardReport(&writer.writer, kind, data) catch return;
    const response = writer.toOwnedSlice() catch return;
    defer self.alloc.free(response);
    self.writePty(response);
}

fn formatOsc52ClipboardReport(writer: *std.Io.Writer, kind: u8, data: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    var encoded_buf: [4096]u8 = undefined;
    if (enc.calcSize(data.len) <= encoded_buf.len) {
        const payload = enc.encode(&encoded_buf, data);
        try writer.print("\x1b]52;{c};{s}\x07", .{ kind, payload });
        return;
    }

    try writer.print("\x1b]52;{c};", .{kind});
    try enc.encodeWriter(writer, data);
    try writer.writeByte(0x07);
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
        const response = xtgettcap_map.get(key) orelse continue;
        self.writePty(response);
    }
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

fn answerOscSelectionColorQuery(
    self: *App,
    target: vt.osc.color.Target,
    terminator: vt.osc.Terminator,
) void {
    switch (target) {
        .palette => {},
        .dynamic => |dynamic| switch (dynamic) {
            .highlight_background => self.writeOscDynamicReport(17, self.selection_bg, terminator),
            .highlight_foreground => self.writeOscDynamicReport(
                19,
                self.selection_fg orelse self.effectiveForeground(),
                terminator,
            ),
            .foreground,
            .background,
            .cursor,
            .pointer_foreground,
            .pointer_background,
            .tektronix_foreground,
            .tektronix_background,
            .tektronix_cursor,
            => {},
        },
        .special => {},
    }
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

fn syncCursorShape(self: *App) void {
    self.window.setCursorShape(self.currentCursorShape());
}

fn currentCursorShape(self: *App) Window.CursorShape {
    if (self.scrollbar_hovered or self.scrollbar_drag != null or self.scrollbarThumbHit() != null) return .default;
    if (self.hoveredLinkUri() != null) return .pointer;
    if (self.mouse_shape_explicit) return cursorShapeFromMouseShape(self.term.mouse_shape);
    return if (self.term.flags.mouse_event != .none) .default else .text;
}

fn linkModifiersActive(mods: vt.input.KeyMods, mouse_reporting: bool) bool {
    if (!mods.ctrl or mods.alt or mods.super) return false;
    return mods.shift or !mouse_reporting;
}

fn linksActive(self: *App) bool {
    return linkModifiersActive(
        self.keyboard.currentMods(),
        self.term.flags.mouse_event != .none,
    );
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

test "link modifiers are exact and shift bypasses mouse reporting" {
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true }, false));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .shift = true }, false));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .caps_lock = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true, .alt = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true, .super = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .shift = true }, false));
    try std.testing.expect(!linkModifiersActive(.{ .ctrl = true }, true));
    try std.testing.expect(linkModifiersActive(.{ .ctrl = true, .shift = true }, true));
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

test "OSC 52 read reports base64 clipboard payload" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52ClipboardReport(&writer, 'c', "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", writer.buffered());
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
    try std.testing.expectEqualStrings(
        "\x1bP1+r5463\x1b\\",
        xtgettcap_map.get(hexEncodeComptime("Tc")).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bP1+r636C656172=1B5B481B5B324A\x1b\\",
        xtgettcap_map.get(hexEncodeComptime("clear")).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bP1+r62656C=07\x1b\\",
        xtgettcap_map.get(hexEncodeComptime("bel")).?,
    );
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
        _ = setTimer(self.sync_output_fd, .{
            .it_value = timespecFromNs(sync_output_reset_ms * std.time.ns_per_ms),
            .it_interval = .{ .sec = 0, .nsec = 0 },
        }, "synchronized output");
    } else {
        _ = setTimer(self.sync_output_fd, disarmed_timer, "synchronized output");
        self.needs_redraw = true;
    }
}

fn fireSyncOutputReset(self: *App) void {
    _ = readTimer(self.sync_output_fd) orelse return;
    if (self.term.modes.get(.synchronized_output)) {
        log.debug("synchronized output timed out; forcing redraw", .{});
        self.term.modes.set(.synchronized_output, false);
    }
    self.syncSynchronizedOutput();
}

fn armTaskbarProgressTimer(self: *App) void {
    _ = setTimer(self.taskbar_progress_fd, .{
        .it_value = .{ .sec = taskbar_progress_timeout_seconds, .nsec = 0 },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "taskbar progress");
}

fn stopTaskbarProgressTimer(self: *App) void {
    _ = setTimer(self.taskbar_progress_fd, disarmed_timer, "taskbar progress");
}

fn fireTaskbarProgressTimeout(self: *App) void {
    _ = readTimer(self.taskbar_progress_fd) orelse return;
    self.sendTaskbarProgress(.{ .state = .remove }) catch |err| {
        if (err != error.DBusUnavailable) {
            log.warn("failed to clear stale taskbar progress: {}", .{err});
        }
    };
}

/// Window pointer delegate: track position and accumulate wheel scroll,
/// applying it at frame boundaries.
fn pointerEvent(ctx: *anyopaque, event: wl.Pointer.Event) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => |enter| {
            self.pointer_x = enter.surface_x.toDouble();
            self.pointer_y = enter.surface_y.toDouble();
            self.pointer_inside = true;
            self.syncScrollbarHoverFromPointer();
            self.syncHoveredLink(false);
            self.syncCursorShape();
        },
        .motion => |motion| {
            self.pointer_x = motion.surface_x.toDouble();
            self.pointer_y = motion.surface_y.toDouble();
            if (self.scrollbar_drag != null) {
                self.dragScrollbar();
                return;
            }
            self.syncScrollbarHoverFromPointer();
            self.syncHoveredLink(false);
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
            self.stopFling();
            if (axis.axis == .vertical_scroll and !self.scroll_had_discrete and !self.scroll_had_value120) {
                const pixels = axis.value.toDouble();
                self.scroll_pixels += pixels;
                self.scroll_frame_pixels += pixels;
                self.scroll_time_ms = axis.time;
                self.scroll_had_pixels = true;
            }
            if (!self.window.pointerHasFrames()) self.finishScrollFrame();
        },
        .axis_discrete => |discrete| {
            self.stopFling();
            if (discrete.axis == .vertical_scroll) {
                self.scroll_clicks += discrete.discrete;
                self.scroll_had_discrete = true;
            }
        },
        .axis_value120 => |axis| {
            self.stopFling();
            if (axis.axis == .vertical_scroll) {
                self.scroll_value120 += axis.value120;
                self.scroll_had_value120 = true;
            }
        },
        .frame => self.finishScrollFrame(),
        .button => |button| {
            self.last_serial = button.serial;
            if (button.state == .pressed) self.stopFling();
            if (button.button == 272) { // BTN_LEFT
                if (button.state == .pressed and self.beginScrollbarDrag()) return;
                if (button.state == .released and self.finishScrollbarDrag()) return;
            }
            // Mouse reporting wins when the application asked for it,
            // except that shift bypasses it for terminal-side selection.
            const reporting = self.term.flags.mouse_event != .none and
                !self.keyboard.currentMods().shift;
            const mouse_button = mouseButtonFromEvdev(button.button);

            if (button.button == 272) { // BTN_LEFT
                if (button.state == .pressed) {
                    if (self.armLinkPress()) {
                        self.syncScrollbarHover();
                        return;
                    }
                    self.cancelLinkPress();
                }
                if (button.state == .released and self.finishLinkPress()) {
                    self.syncScrollbarHover();
                    return;
                }
                switch (button.state) {
                    .pressed => if (reporting) {
                        self.forwardMouseButton(button, mouse_button.?);
                    } else {
                        self.startSelection(button.time);
                        self.syncScrollbarHover();
                    },
                    // Routing may have changed since the press (shift
                    // released mid-drag, app toggled mouse mode): an
                    // armed drag always finishes; only presses the app
                    // saw get their release.
                    .released => if (self.selecting) {
                        self.finishSelection();
                        self.syncScrollbarHover();
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
        .axis_source => |source| self.scroll_source = source.axis_source,
        .axis_stop => |stop| {
            if (stop.axis == .vertical_scroll) self.scroll_stopped = true;
        },
        // Terminal scrolling follows the compositor-provided logical axis;
        // the physical direction hint does not change that behavior.
        .axis_relative_direction => {},
        .leave => {
            self.pointer_inside = false;
            self.syncScrollbarHover();
            self.syncHoveredLink(false);
        },
    }
}

fn pointerSurfacePhysical(self: *const App) struct { x: f64, y: f64 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @max(0, self.pointer_x * scale),
        .y = @max(0, self.pointer_y * scale),
    };
}

fn scrollbarPointerEligible(self: *App) bool {
    if (!self.pointer_inside or self.term.screens.active_key != .primary or
        self.scrollbar_drag != null or self.selecting or self.mouse_button != null or
        self.link_press != null)
    {
        return false;
    }
    const scrollbar = self.term.screens.active.pages.scrollbar();
    return scrollbar.total > scrollbar.len;
}

fn scrollbarRevealHovered(self: *App) bool {
    if (!self.scrollbarPointerEligible()) return false;
    const pos = self.pointerSurfacePhysical();
    const reveal_width = Window.physicalDimension(scrollbar_reveal_width, self.window.scale120);
    const reveal_left = self.layout.surface_width -| reveal_width;
    return pos.x >= reveal_left and pos.x < self.layout.surface_width and
        pos.y >= self.layout.grid_y and pos.y < self.layout.grid_y + self.layout.grid_height;
}

fn syncScrollbarHover(self: *App) void {
    const reveal_hovered = self.scrollbarRevealHovered();
    const hovered = reveal_hovered and self.scrollbarThumbUnderPointer() != null;
    if (reveal_hovered == self.scrollbar_reveal_hovered and hovered == self.scrollbar_hovered) return;
    self.scrollbar_reveal_hovered = reveal_hovered;
    self.scrollbar_hovered = hovered;
    if (reveal_hovered) {
        self.revealScrollbar();
    } else {
        const scrollbar = self.term.screens.active.pages.scrollbar();
        if (self.term.screens.active_key != .primary or scrollbar.total <= scrollbar.len) {
            self.hideScrollbar();
        } else if (self.scrollbar_alpha > 0) {
            const changed = self.scrollbar_alpha != scrollbar_default_alpha;
            self.scrollbar_alpha = scrollbar_default_alpha;
            self.armScrollbarHold();
            if (changed) self.requestFullAsyncRedraw();
        }
    }
    self.syncCursorShape();
}

fn syncScrollbarHoverFromPointer(self: *App) void {
    self.syncScrollbarHover();
    if (self.scrollbar_reveal_hovered) self.revealScrollbar();
}

fn scrollbarThumbUnderPointer(self: *App) ?ScrollbarGeometry {
    if (!self.scrollbarPointerEligible()) return null;
    const scrollbar = self.term.screens.active.pages.scrollbar();
    const geometry = scrollbarGeometry(scrollbar, self.layout, self.window.scale120, scrollbar_default_alpha) orelse return null;
    const pos = self.pointerSurfacePhysical();
    const hit_width = @max(geometry.thumb.width, Window.physicalDimension(scrollbar_hit_width, self.window.scale120));
    const hit_left = self.layout.surface_width -| hit_width;
    const thumb_bottom = geometry.thumb.y + geometry.thumb.height;
    if (pos.x < hit_left or pos.x >= self.layout.surface_width or
        pos.y < geometry.thumb.y or pos.y >= thumb_bottom) return null;
    return geometry;
}

fn scrollbarThumbHit(self: *App) ?ScrollbarGeometry {
    if (self.scrollbar_alpha == 0) return null;
    const scrollbar = self.term.screens.active.pages.scrollbar();
    if (!scrollbarShouldRender(scrollbar, self.scrollbar_alpha)) return null;
    return self.scrollbarThumbUnderPointer();
}

fn beginScrollbarDrag(self: *App) bool {
    const geometry = self.scrollbarThumbHit() orelse return false;
    const pos = self.pointerSurfacePhysical();
    self.cancelDrag();
    self.cancelLinkPress();
    self.scrollbar_reveal_hovered = false;
    self.scrollbar_hovered = false;
    self.scrollbar_drag = .{
        .grab_offset = std.math.clamp(
            pos.y - @as(f64, @floatFromInt(geometry.thumb.y)),
            0,
            @as(f64, @floatFromInt(geometry.thumb.height)),
        ),
        .screen = self.term.screens.active_key,
    };
    self.revealScrollbar();
    self.syncHoveredLink(true);
    self.syncCursorShape();
    return true;
}

fn dragScrollbar(self: *App) void {
    const drag = self.scrollbar_drag orelse return;
    if (drag.screen != self.term.screens.active_key) return;
    const geometry = self.currentScrollbarGeometry(scrollbar_hover_alpha) orelse return;
    const pos = self.pointerSurfacePhysical();
    const row = scrollbarRowForThumbY(geometry, pos.y - drag.grab_offset);
    self.term.screens.active.pages.scroll(.{ .row = row });
    self.revealScrollbar();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

fn finishScrollbarDrag(self: *App) bool {
    if (self.scrollbar_drag == null) return false;
    self.scrollbar_drag = null;
    self.syncScrollbarHover();
    self.revealScrollbar();
    self.syncHoveredLink(true);
    self.syncCursorShape();
    return true;
}

/// The viewport cell under the pointer, clamped to the grid.
fn cellAtPointer(self: *App) struct { x: u16, y: u16 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const px: f64 = @max(0, self.pointer_x * scale - @as(f64, @floatFromInt(self.layout.grid_x)));
    const py: f64 = @max(0, self.pointer_y * scale - @as(f64, @floatFromInt(self.layout.grid_y)));
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

/// Unlike selection coordinates, link coordinates must be inside the grid;
/// padding must not clamp to a clickable edge cell.
fn linkCellAtPointer(self: *App) ?vt.Coordinate {
    if (!self.pointer_inside) return null;
    if (self.scrollbar_hovered or self.scrollbar_drag != null or self.scrollbarThumbHit() != null) return null;
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    const px = self.pointer_x * scale;
    const py = self.pointer_y * scale;
    const grid_x: f64 = @floatFromInt(self.layout.grid_x);
    const grid_y: f64 = @floatFromInt(self.layout.grid_y);
    const grid_right: f64 = @floatFromInt(self.layout.grid_x + self.layout.grid_width);
    const grid_bottom: f64 = @floatFromInt(self.layout.grid_y + self.layout.grid_height);
    if (px < grid_x or px >= grid_right or py < grid_y or py >= grid_bottom) return null;
    return .{
        .x = @intFromFloat((px - grid_x) / @as(f64, @floatFromInt(self.font.cell_width))),
        .y = @intFromFloat((py - grid_y) / @as(f64, @floatFromInt(self.font.cell_height))),
    };
}

fn linkPinAtPointer(self: *App) ?vt.Pin {
    const cell = self.linkCellAtPointer() orelse return null;
    return self.term.screens.active.pages.pin(.{ .viewport = cell });
}

fn oscHyperlinkAtPin(pin: vt.Pin) ?[]const u8 {
    const page = pin.node.page();
    const rac = pin.rowAndCell();
    if (!rac.cell.hyperlink) return null;
    const link_id = page.lookupHyperlink(rac.cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    return entry.uri.slice(page.memory);
}

fn detectHoveredLink(self: *App) !?HoveredLink {
    const pin = self.linkPinAtPointer() orelse return null;
    if (oscHyperlinkAtPin(pin)) |uri| {
        return .{ .uri = try self.alloc.dupe(u8, uri), .range = null };
    }

    const screen = self.term.screens.active;
    const line = screen.selectLine(.{
        .pin = pin,
        .whitespace = null,
        .semantic_prompt_boundary = true,
    }) orelse return null;
    var strmap: vt.StringMap = undefined;
    const text = try screen.selectionString(self.alloc, .{
        .sel = line,
        .trim = false,
        .map = &strmap,
    });
    defer self.alloc.free(text);
    defer strmap.deinit(self.alloc);

    var offset: usize = 0;
    while (Link.find(text, offset)) |match| {
        if (match.end > strmap.map.len) break;
        const selection: vt.Selection = .init(
            strmap.map[match.start],
            strmap.map[match.end - 1],
            false,
        );
        if (selection.contains(screen, pin)) {
            return .{
                .uri = try self.alloc.dupe(u8, text[match.start..match.end]),
                .range = self.linkRange(selection),
            };
        }
        offset = match.end;
    }
    return null;
}

fn linkRange(self: *App, selection: vt.Selection) ?Renderer.LinkRange {
    const screen = self.term.screens.active;
    return highlightRange(
        screen,
        selection.topLeft(screen),
        selection.bottomRight(screen),
        self.term.rows,
        self.term.cols,
    );
}

fn highlightRange(
    screen: *vt.Screen,
    start: vt.Pin,
    end: vt.Pin,
    rows: u16,
    cols: u16,
) ?Renderer.LinkRange {
    const tl = screen.pages.pointFromPin(.screen, start) orelse return null;
    const br = screen.pages.pointFromPin(.screen, end) orelse return null;
    const viewport = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)) orelse return null;
    const last_y = viewport.screen.y + rows - 1;
    if (br.screen.y < viewport.screen.y or tl.screen.y > last_y) return null;

    return .{
        .start = .{
            .x = if (tl.screen.y < viewport.screen.y) 0 else tl.screen.x,
            .y = @max(tl.screen.y, viewport.screen.y) - viewport.screen.y,
        },
        .end = .{
            .x = if (br.screen.y > last_y) cols - 1 else br.screen.x,
            .y = @min(br.screen.y, last_y) - viewport.screen.y,
        },
    };
}

fn hoveredLinksEqual(a: ?HoveredLink, b: ?HoveredLink) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.uri, b.?.uri) and std.meta.eql(a.?.range, b.?.range);
}

/// Recompute the link only while the exact activation modifiers are held.
/// Repeated pointer motion inside one cell is deliberately a no-op.
fn syncHoveredLink(self: *App, force: bool) void {
    const active = self.linksActive();
    const activation_changed = active != self.link_active;
    self.link_active = active;
    const cell = if (active) self.linkCellAtPointer() else null;
    if (!force and !activation_changed and std.meta.eql(cell, self.link_checked_cell)) return;
    self.link_checked_cell = cell;

    const next: ?HoveredLink = if (cell != null)
        self.detectHoveredLink() catch |err| next: {
            log.warn("automatic link detection failed: {}", .{err});
            break :next null;
        }
    else
        null;
    const changed = !hoveredLinksEqual(self.hovered_link, next);
    if (changed) {
        if (self.hovered_link) |old| self.alloc.free(old.uri);
        self.hovered_link = next;
    } else if (next) |unchanged| {
        self.alloc.free(unchanged.uri);
    }
    if (changed or activation_changed) self.requestFullAsyncRedraw();
    self.syncCursorShape();
}

fn hoveredLinkUri(self: *App) ?[]const u8 {
    if (!self.linksActive()) return null;
    const link = self.hovered_link orelse return null;
    return link.uri;
}

fn armLinkPress(self: *App) bool {
    const uri = self.hoveredLinkUri() orelse return false;
    const cell = self.linkCellAtPointer() orelse return false;
    const owned = self.alloc.dupe(u8, uri) catch |err| {
        log.warn("failed to save pressed link: {}", .{err});
        return false;
    };
    if (self.link_press) |old| self.alloc.free(old.uri);
    self.link_press = .{ .uri = owned, .cell = cell };
    return true;
}

fn cancelLinkPress(self: *App) void {
    if (self.link_press) |press| self.alloc.free(press.uri);
    self.link_press = null;
}

fn finishLinkPress(self: *App) bool {
    const press = self.link_press orelse return false;
    self.link_press = null;
    defer self.alloc.free(press.uri);

    const cell = self.linkCellAtPointer();
    const uri = self.hoveredLinkUri();
    if (cell != null and uri != null and
        std.meta.eql(cell.?, press.cell) and std.mem.eql(u8, uri.?, press.uri))
    {
        self.openUri(press.uri);
    }
    return true;
}

fn openUri(self: *App, uri: []const u8) void {
    const owned = self.alloc.dupe(u8, uri) catch |err| {
        log.warn("failed to save hyperlink URI: {}", .{err});
        return;
    };

    if (self.pending_open_uri) |pending| self.alloc.free(pending);
    self.pending_open_uri = owned;

    const requested = self.window.requestActivationToken(self.last_serial) catch |err| requested: {
        log.warn("failed to request hyperlink activation token: {}", .{err});
        break :requested false;
    };
    if (requested) return;

    self.openPendingUri(null);
}

fn activationTokenReady(ctx: *anyopaque, token: [:0]const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.openPendingUri(token);
}

fn openPendingUri(self: *App, activation_token: ?[:0]const u8) void {
    const uri = self.pending_open_uri orelse return;
    self.pending_open_uri = null;
    defer self.alloc.free(uri);

    self.openUriPortal(uri, activation_token) catch |err| {
        if (err == error.PortalUnavailable) {
            self.openUriXdg(uri, activation_token) catch |fallback_err| {
                log.warn("failed to open hyperlink with xdg-open: {}", .{fallback_err});
            };
            return;
        }
        log.warn("failed to open hyperlink through portal: {}", .{err});
    };
}

fn openUriXdg(self: *App, uri: []const u8, activation_token: ?[:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const xdg_open = try resolveCommandPathZ(arena, self.environ, "xdg-open");
    if (std.mem.indexOfScalar(u8, xdg_open, '/') == null) return error.XdgOpenUnavailable;

    const uri_z = try arena.dupeZ(u8, uri);
    const envp = try self.spawnEnvp(arena, null, activation_token);
    const argv = [_:null]?[*:0]const u8{ "xdg-open", uri_z.ptr };
    if (!spawnDetached(xdg_open.ptr, &argv, envp, null, "xdg-open")) {
        return error.SpawnFailed;
    }
}

fn pointerPhysical(self: *App) struct { x: f64, y: f64 } {
    const scale: f64 = @as(f64, @floatFromInt(self.window.scale120)) / 120.0;
    return .{
        .x = @max(0, self.pointer_x * scale),
        // SelectionGesture supports horizontal padding explicitly; make Y
        // grid-local so its top/bottom autoscroll thresholds do the same.
        .y = @max(0, self.pointer_y * scale - @as(f64, @floatFromInt(self.layout.grid_y))),
    };
}

fn selectionGeometry(self: *App) vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = self.term.cols,
        .cell_width = self.font.cell_width,
        .padding_left = self.layout.grid_x,
        .screen_height = self.layout.grid_height,
    };
}

fn physicalPadding(config: Config, scale120: u32) TerminalLayout.Padding {
    return .{
        .left = Window.physicalDimension(config.window_padding_x.first, scale120),
        .right = Window.physicalDimension(config.window_padding_x.second, scale120),
        .top = Window.physicalDimension(config.window_padding_y.first, scale120),
        .bottom = Window.physicalDimension(config.window_padding_y.second, scale120),
    };
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
    self.syncScrollbarHover();
}

fn startSelection(self: *App, time_ms: u32) void {
    const pin = self.pinAtPointer() orelse return;
    const pos = self.pointerPhysical();
    self.selection_rectangle = self.keyboard.currentMods().ctrl;
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
        .rectangle = self.selection_rectangle,
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
    self.selection_rectangle = false;
    self.selection_gesture.reset(&self.term);
    self.stopSelectionAutoscrollTimer();
}

fn finishSelection(self: *App) void {
    if (!self.selecting) return;
    self.selecting = false;
    self.selection_gesture.release(&self.term, .{ .pin = self.pinAtPointer() });
    self.selection_rectangle = false;
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
    _ = setTimer(self.selection_autoscroll_fd, .{
        .it_value = interval,
        .it_interval = interval,
    }, "selection autoscroll");
}

fn stopSelectionAutoscrollTimer(self: *App) void {
    _ = setTimer(self.selection_autoscroll_fd, disarmed_timer, "selection autoscroll");
}

fn fireSelectionAutoscroll(self: *App) void {
    _ = readTimer(self.selection_autoscroll_fd) orelse return;
    if (!self.selecting) return;

    const cell = self.cellAtPointer();
    const pos = self.pointerPhysical();
    const selection = self.selection_gesture.autoscrollTick(&self.term, .{
        .viewport = .{ .x = cell.x, .y = cell.y },
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = self.selection_rectangle,
        .word_boundary_codepoints = &selection_word_boundaries,
        .geometry = self.selectionGeometry(),
    });
    self.applySelection(selection, false);
    self.needs_redraw = true;
    self.syncHoveredLink(true);
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
    self.scrollbar_reveal_hovered = false;
    self.scrollbar_hovered = false;
    self.hideScrollbar();
    self.cancelDrag();
    self.syncScrollbarHover();
}

const MimeMask = u32;

fn mimeBit(preferences: []const [:0]const u8, mime_type: [*:0]const u8) ?MimeMask {
    const offered = std.mem.span(mime_type);
    for (preferences, 0..) |candidate, i| {
        if (std.mem.eql(u8, offered, candidate[0..candidate.len])) {
            return @as(MimeMask, 1) << @intCast(i);
        }
    }
    return null;
}

fn preferredMime(preferences: []const [:0]const u8, mask: MimeMask) ?[*:0]const u8 {
    for (preferences, 0..) |candidate, i| {
        if (mask & (@as(MimeMask, 1) << @intCast(i)) != 0) return candidate.ptr;
    }
    return null;
}

const ClipboardOffer = struct {
    app: *App,
    offer: *wl.DataOffer,
    mimes: MimeMask = 0,
    dnd_mimes: MimeMask = 0,
    dnd_action: wl.DataDeviceManager.DndAction = .{},

    fn noteMime(self: *ClipboardOffer, mime_type: [*:0]const u8) void {
        if (mimeBit(&paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
        if (mimeBit(&dnd_mime_preference, mime_type)) |bit| self.dnd_mimes |= bit;
    }

    fn bestMime(self: *const ClipboardOffer) ?[*:0]const u8 {
        return preferredMime(&paste_mime_preference, self.mimes);
    }

    fn bestDndMime(self: *const ClipboardOffer) ?[*:0]const u8 {
        return preferredMime(&dnd_mime_preference, self.dnd_mimes);
    }

    fn destroy(self: *ClipboardOffer) void {
        const app = self.app;
        if (app.clip_offer == self) app.clip_offer = null;
        if (app.clip_pending_offer == self) app.clip_pending_offer = null;
        if (app.dnd_offer == self) app.dnd_offer = null;
        self.offer.destroy();
        app.alloc.destroy(self);
    }
};

const PrimaryOffer = struct {
    app: *App,
    offer: *zwp.PrimarySelectionOfferV1,
    mimes: MimeMask = 0,

    fn noteMime(self: *PrimaryOffer, mime_type: [*:0]const u8) void {
        if (mimeBit(&paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
    }

    fn bestMime(self: *const PrimaryOffer) ?[*:0]const u8 {
        return preferredMime(&paste_mime_preference, self.mimes);
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
        .action => |ev| offer.dnd_action = ev.dnd_action,
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
            const offer = self.takeClipboardOffer(id) orelse {
                id.destroy();
                return;
            };
            if (offer.bestDndMime()) |mime| {
                offer.offer.accept(enter.serial, mime);
                offer.offer.setActions(.{ .copy = true }, .{ .copy = true });
                if (self.dnd_offer) |old| old.destroy();
                self.dnd_offer = offer;
            } else {
                offer.offer.accept(enter.serial, null);
                offer.destroy();
            }
        },
        .leave => {
            if (self.dnd_offer) |offer| offer.destroy();
        },
        .drop => self.beginDropPaste(),
        .motion => {},
    }
}

fn beginDropPaste(self: *App) void {
    const offer = self.dnd_offer orelse return;
    // The compositor sends leave right after drop; hand ownership to
    // the in-flight paste action now so that leave cannot destroy the
    // offer under it (finishPaste destroys it when the transfer ends).
    self.dnd_offer = null;
    if (self.paste_fd >= 0) {
        offer.destroy();
        return;
    }
    const mime = offer.bestDndMime() orelse {
        offer.destroy();
        return;
    };
    self.beginClipboardTransfer(mime, .{ .clipboard = offer }, .{ .dnd = offer }) catch {
        offer.destroy();
    };
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

fn clipboardDevicesChanged(
    ctx: *anyopaque,
    data_device: ?*wl.DataDevice,
    primary_device: ?*zwp.PrimarySelectionDeviceV1,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (data_device) |device| device.setListener(*App, dataDeviceListener, self);
    if (primary_device) |device| device.setListener(*App, primaryDeviceListener, self);
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
    if (self.claimClipboardText(text)) self.flashCopyHighlight();
}

fn claimClipboardText(self: *App, text: [:0]const u8) bool {
    const manager = self.window.data_manager orelse {
        self.alloc.free(text);
        return false;
    };
    const device = self.window.data_device orelse {
        self.alloc.free(text);
        return false;
    };

    const source = manager.createDataSource() catch {
        self.alloc.free(text);
        return false;
    };
    const ctx = self.alloc.create(SourceCtx) catch {
        source.destroy();
        self.alloc.free(text);
        return false;
    };
    ctx.* = .{ .app = self, .text = text, .source = .{ .clipboard = source } };

    inline for (paste_mime_preference) |mime| source.offer(mime.ptr);
    source.setListener(*SourceCtx, dataSourceListener, ctx);
    device.setSelection(source, self.last_serial);

    if (self.clip_source) |old| old.destroy();
    self.clip_source = ctx;
    log.debug("claimed clipboard ({d} bytes)", .{text.len});
    return true;
}

fn flashCopyHighlight(self: *App) void {
    if (self.config.copy_highlight_duration == 0) return;
    if (!setTimer(self.copy_highlight_fd, .{
        .it_value = timespecFromNs(@as(u64, self.config.copy_highlight_duration) * std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "copy highlight")) return;
    if (self.copy_highlight_active) return;

    self.copy_highlight_active = true;
    self.requestFullAsyncRedraw();
}

fn fireCopyHighlightTimeout(self: *App) void {
    _ = readTimer(self.copy_highlight_fd) orelse return;
    if (!self.copy_highlight_active) return;

    self.copy_highlight_active = false;
    self.requestFullAsyncRedraw();
}

/// Ask the offer's owner to stream its contents into a pipe; the read
/// end joins the poll loop and the paste completes on EOF.
fn beginPaste(self: *App, comptime which: enum { clipboard, primary }) void {
    if (self.paste_fd >= 0) return; // one paste at a time

    switch (which) {
        .clipboard => {
            const offer = self.clip_offer orelse {
                return;
            };
            const mime = offer.bestMime() orelse {
                return;
            };
            self.beginClipboardTransfer(mime, .{ .clipboard = offer }, .terminal) catch return;
        },
        .primary => {
            const offer = self.primary_offer orelse {
                return;
            };
            const mime = offer.bestMime() orelse {
                return;
            };
            self.beginClipboardTransfer(mime, .{ .primary = offer }, .terminal) catch return;
        },
    }
}

fn beginClipboardTransfer(
    self: *App,
    mime: [*:0]const u8,
    offer: TransferOffer,
    action: PasteAction,
) !void {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    errdefer _ = std.os.linux.close(fds[0]);
    errdefer _ = std.os.linux.close(fds[1]);

    offer.receive(mime, fds[1]);
    _ = std.os.linux.close(fds[1]);
    setNonblocking(fds[0]);
    self.paste_fd = fds[0];
    self.paste_buf.clearRetainingCapacity();
    self.paste_action = action;
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
    defer {
        self.paste_buf.clearRetainingCapacity();
        self.paste_action = .terminal;
    }

    switch (self.paste_action) {
        .terminal => self.writeTerminalPaste(self.paste_buf.items),
        .osc52_read => |kind| self.writeOsc52ClipboardReport(kind, self.paste_buf.items),
        .dnd => |offer| {
            defer offer.destroy();
            defer if (offer.dnd_action.copy or offer.dnd_action.move) offer.offer.finish();
            const text = self.formatDropPaste(offer, self.paste_buf.items) catch return;
            defer self.alloc.free(text);
            self.writeTerminalPaste(text);
        },
    }
}

fn writeTerminalPaste(self: *App, data: []u8) void {
    if (data.len == 0) return;

    // Mutable input lets the encoder sanitize control bytes in place,
    // so this cannot fail.
    const parts = vt.input.encodePaste(
        data,
        .fromTerminal(&self.term),
    );
    for (parts) |part| self.writePty(part);
}

fn formatDropPaste(self: *App, offer: *const ClipboardOffer, data: []const u8) ![]u8 {
    const mime = std.mem.span(offer.bestDndMime() orelse return self.alloc.dupe(u8, data));
    if (!std.mem.eql(u8, mime, uri_list_mime)) return self.alloc.dupe(u8, data);
    return try formatUriListDrop(self.alloc, data);
}

/// Convert accumulated wheel movement into scrolled lines: wheel clicks
/// count fixed lines, smooth (touchpad) scroll counts cell heights.
fn finishScrollFrame(self: *App) void {
    if (self.scroll_had_pixels) {
        if (self.scroll_source == .finger) {
            self.trackScrollVelocity(self.scroll_frame_pixels, self.scroll_time_ms);
        } else {
            self.resetScrollVelocity();
        }
    } else if (self.scroll_had_discrete or self.scroll_had_value120) {
        self.resetScrollVelocity();
    }

    var lines: i32 = 0;
    if (self.scroll_had_value120) {
        const wheel_ticks = @as(f64, @floatFromInt(self.scroll_value120)) / 120.0;
        const total = wheel_ticks * self.config.mouse_scroll_multiplier.discrete + self.scroll_line_remainder;
        const whole = @trunc(total);
        lines = @intFromFloat(whole);
        self.scroll_line_remainder = total - whole;
    } else if (self.scroll_had_discrete) {
        const total = @as(f64, @floatFromInt(self.scroll_clicks)) * self.config.mouse_scroll_multiplier.discrete +
            self.scroll_line_remainder;
        const whole = @trunc(total);
        lines = @intFromFloat(whole);
        self.scroll_line_remainder = total - whole;
    } else if (self.scroll_pixels != 0) {
        // Logical pixels per row: physical cell height descaled.
        const cell: f64 = @as(f64, @floatFromInt(self.font.cell_height)) * 120.0 /
            @as(f64, @floatFromInt(self.window.scale120));
        const multiplier = self.precisionScrollScale();
        const pixels = self.scroll_pixels * multiplier;
        const whole = @divTrunc(pixels, cell);
        lines = @intFromFloat(whole);
        self.scroll_pixels -= whole * cell / multiplier;
    }
    if (self.scroll_had_value120 or self.scroll_had_discrete) self.scroll_pixels = 0;
    self.scroll_frame_pixels = 0;
    self.scroll_clicks = 0;
    self.scroll_value120 = 0;
    self.scroll_source = .wheel;
    self.scroll_had_pixels = false;
    self.scroll_had_discrete = false;
    self.scroll_had_value120 = false;
    if (lines != 0) self.scrollLines(lines);
    if (self.scroll_stopped) {
        self.scroll_stopped = false;
        self.startFling();
        self.resetScrollVelocity();
    }
}

fn precisionScrollScale(self: *const App) f64 {
    return wayland_precision_scroll_scale * self.config.mouse_scroll_multiplier.precision;
}

/// Fold one finger-scroll frame into an exponential moving average in
/// effective content pixels per second.
fn trackScrollVelocity(self: *App, pixels: f64, time_ms: u32) void {
    defer self.last_scroll_time_ms = time_ms;
    const last = self.last_scroll_time_ms orelse return;
    const dt_ms: f64 = @floatFromInt(time_ms -% last);
    if (dt_ms <= 0 or dt_ms > 200) return;
    const velocity = pixels * self.precisionScrollScale() / dt_ms * 1000.0;
    self.scroll_velocity = (1 - velocity_smoothing) * self.scroll_velocity + velocity_smoothing * velocity;
}

fn resetScrollVelocity(self: *App) void {
    self.scroll_velocity = 0;
    self.last_scroll_time_ms = null;
}

fn startFling(self: *App) void {
    if (!self.config.inertial_scrolling) return;
    const velocity = std.math.clamp(self.scroll_velocity, -fling_max_velocity, fling_max_velocity);
    if (@abs(velocity) < fling_start_velocity) return;

    const interval = timespecFromNs(fling_interval_ms * std.time.ns_per_ms);
    const spec: std.os.linux.itimerspec = .{ .it_value = interval, .it_interval = interval };
    if (!setTimer(self.fling_fd, spec, "fling")) return;
    self.fling_velocity = velocity;
    self.fling_active = true;
}

fn stopFling(self: *App) void {
    if (!self.fling_active) return;
    self.fling_active = false;
    _ = setTimer(self.fling_fd, disarmed_timer, "fling");
}

fn fireFling(self: *App) void {
    const expirations = readTimer(self.fling_fd) orelse return;
    if (!self.fling_active) return;

    const dt_ms: f64 = @floatFromInt(fling_interval_ms * expirations);
    self.scroll_pixels += self.fling_velocity * dt_ms / 1000.0 / self.precisionScrollScale();
    self.finishScrollFrame();

    self.fling_velocity *= std.math.pow(f64, fling_decay_per_ms, dt_ms);
    if (@abs(self.fling_velocity) < fling_min_velocity) self.stopFling();
}

fn scrollbarAtBottom(scrollbar: vt.PageList.Scrollbar) bool {
    return scrollbar.total <= scrollbar.len or
        scrollbar.offset >= scrollbar.total - scrollbar.len;
}

fn scrollbarShouldRender(
    scrollbar: vt.PageList.Scrollbar,
    alpha: u8,
) bool {
    return alpha > 0 and scrollbar.total > scrollbar.len;
}

fn scrollbarGeometry(
    scrollbar: vt.PageList.Scrollbar,
    layout: TerminalLayout,
    scale120: u32,
    alpha: u8,
) ?ScrollbarGeometry {
    if (scrollbar.total <= scrollbar.len or layout.surface_width == 0 or layout.grid_height == 0) return null;

    const inset = @min(Window.physicalDimension(scrollbar_inset, scale120), layout.grid_height / 2);
    const track_y = layout.grid_y + inset;
    const track_height = layout.grid_height - inset * 2;
    if (track_height == 0) return null;

    const desired_width = @max(1, Window.physicalDimension(scrollbar_width, scale120));
    const right = layout.surface_width -| inset;
    if (right == 0) return null;
    const width = @min(desired_width, right);
    const min_height = @min(track_height, @max(1, Window.physicalDimension(scrollbar_min_thumb, scale120)));
    const proportional: u31 = @intCast(
        (@as(u128, track_height) * scrollbar.len) / scrollbar.total,
    );
    const thumb_height = @min(track_height, @max(min_height, @max(1, proportional)));
    const travel = track_height - thumb_height;
    const max_offset = scrollbar.total - scrollbar.len;
    const offset = @min(scrollbar.offset, max_offset);
    const thumb_offset: u31 = if (travel == 0)
        0
    else
        @intCast((@as(u128, travel) * offset + max_offset / 2) / max_offset);

    return .{
        .thumb = .{
            .x = right - width,
            .y = track_y + thumb_offset,
            .width = width,
            .height = thumb_height,
            .alpha = alpha,
        },
        .track_y = track_y,
        .travel = travel,
        .max_offset = max_offset,
    };
}

fn scrollbarRowForThumbY(geometry: ScrollbarGeometry, thumb_y: f64) usize {
    if (geometry.travel == 0) return 0;
    const relative = std.math.clamp(
        thumb_y - @as(f64, @floatFromInt(geometry.track_y)),
        0,
        @as(f64, @floatFromInt(geometry.travel)),
    );
    return @intFromFloat(@round(
        relative / @as(f64, @floatFromInt(geometry.travel)) *
            @as(f64, @floatFromInt(geometry.max_offset)),
    ));
}

fn currentScrollbarGeometry(self: *App, alpha: u8) ?ScrollbarGeometry {
    return scrollbarGeometry(
        self.term.screens.active.pages.scrollbar(),
        self.layout,
        self.window.scale120,
        alpha,
    );
}

fn currentScrollbarThumb(self: *App) ?Renderer.ScrollbarThumb {
    const scrollbar = self.term.screens.active.pages.scrollbar();
    if (!scrollbarShouldRender(scrollbar, self.scrollbar_alpha)) return null;
    const geometry = scrollbarGeometry(scrollbar, self.layout, self.window.scale120, self.scrollbar_alpha) orelse return null;
    return geometry.thumb;
}

fn armScrollbarHold(self: *App) void {
    _ = setTimer(self.scrollbar_fd, .{
        .it_value = timespecFromNs(scrollbar_hold_ms * std.time.ns_per_ms),
        .it_interval = .{ .sec = 0, .nsec = 0 },
    }, "scrollbar");
}

fn hideScrollbar(self: *App) void {
    _ = setTimer(self.scrollbar_fd, disarmed_timer, "scrollbar");
    if (self.scrollbar_alpha == 0) return;
    self.scrollbar_alpha = 0;
    self.requestFullAsyncRedraw();
}

fn revealScrollbar(self: *App) void {
    const scrollbar = self.term.screens.active.pages.scrollbar();
    const at_bottom = scrollbarAtBottom(scrollbar);

    const alpha: u8 = if (self.scrollbar_drag != null or self.scrollbar_hovered)
        scrollbar_hover_alpha
    else
        scrollbar_default_alpha;
    const changed = self.scrollbar_alpha != alpha;
    self.scrollbar_alpha = alpha;
    if (self.scrollbar_drag == null and !self.scrollbar_hovered and
        (!self.scrollbar_reveal_hovered or at_bottom))
        self.armScrollbarHold()
    else
        _ = setTimer(self.scrollbar_fd, disarmed_timer, "scrollbar");
    if (changed) self.requestFullAsyncRedraw();
}

fn fireScrollbarFade(self: *App) void {
    const expirations = readTimer(self.scrollbar_fd) orelse return;
    const at_bottom = scrollbarAtBottom(self.term.screens.active.pages.scrollbar());
    if (self.scrollbar_drag != null or self.scrollbar_hovered or self.scrollbar_alpha == 0 or
        (self.scrollbar_reveal_hovered and !at_bottom)) return;

    const ticks: u16 = @intCast(@min(expirations, 255));
    const first_tick = self.scrollbar_alpha == scrollbar_default_alpha;
    const decrement: u16 = if (first_tick)
        scrollbar_fade_step
    else
        ticks * scrollbar_fade_step;
    self.scrollbar_alpha -|= @intCast(@min(decrement, self.scrollbar_alpha));
    const hidden = self.scrollbar_alpha == 0;
    if (hidden) {
        _ = setTimer(self.scrollbar_fd, disarmed_timer, "scrollbar");
    } else if (first_tick) {
        const interval = timespecFromNs(scrollbar_fade_interval_ms * std.time.ns_per_ms);
        _ = setTimer(self.scrollbar_fd, .{ .it_value = interval, .it_interval = interval }, "scrollbar");
    }
    self.requestFullAsyncRedraw();
    if (hidden) self.syncHoveredLink(true);
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
    self.revealScrollbar();
    self.needs_redraw = true;
    self.syncHoveredLink(true);
}

fn sendMouseEvent(self: *App, event: vt.input.MouseEncodeEvent) void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var opts = vt.input.MouseEncodeOptions.fromTerminal(&self.term, .{
        .screen = .{
            .width = self.layout.surface_width,
            .height = self.layout.surface_height,
        },
        .cell = .{ .width = self.font.cell_width, .height = self.font.cell_height },
        .padding = .{
            .top = self.layout.padding.top,
            .right = self.layout.padding.right,
            .bottom = self.layout.padding.bottom,
            .left = self.layout.padding.left,
        },
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
        .modifiers => |mods| {
            const links_were_active = self.linksActive();
            self.keyboard.updateMods(
                mods.mods_depressed,
                mods.mods_latched,
                mods.mods_locked,
                mods.group,
            );
            if (links_were_active != self.linksActive()) {
                self.syncHoveredLink(true);
            }
        },
        .key => |key| {
            self.last_serial = key.serial;
            const action: vt.input.KeyAction = switch (key.state) {
                .pressed => .press,
                .released => .release,
                .repeated => .repeat,
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
        .enter => |enter| {
            self.last_serial = enter.serial;
            self.setFocus(true);
        },
    }
}

fn setFocus(self: *App, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    self.requestFullAsyncRedraw();
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
            self.window.enableTextInput(self.textInputCursorRect(self.currentCursorState()));
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
    if (self.search != null) {
        if (self.ime_pending_commit) |commit| self.appendSearchText(commit);
        self.setImePreedit(self.ime_pending_preedit);
        self.resetPendingIme();
        return;
    }
    if (self.ime_pending_commit) |commit| {
        if (commit.len > 0) {
            self.writePty(commit);
            self.clearSelection();
            if (self.term.screens.active.pages.viewport != .active) {
                self.term.screens.active.pages.scroll(.active);
                self.revealScrollbar();
                self.syncHoveredLink(true);
            }
        }
    }
    self.setImePreedit(self.ime_pending_preedit);
    self.resetPendingIme();
    self.syncTextInputCursorRect(&self.render_state);
}

fn setImePreedit(self: *App, text: ?[]const u8) void {
    self.replaceImeText(&self.ime_preedit, text);
    self.requestFullAsyncRedraw();
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
    _ = setTimer(self.repeat_fd, .{
        .it_value = timespecFromNs(delay_ms * std.time.ns_per_ms),
        .it_interval = timespecFromNs(interval_ns),
    }, "key repeat");
}

fn cancelRepeat(self: *App) void {
    self.repeat_keycode = null;
    _ = setTimer(self.repeat_fd, disarmed_timer, "key repeat");
}

fn createTimerFd() !posix.fd_t {
    const rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(rc) != .SUCCESS) return error.TimerFdFailed;
    return @intCast(rc);
}

fn setTimer(fd: posix.fd_t, spec: std.os.linux.itimerspec, label: []const u8) bool {
    const rc = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    const err = std.os.linux.errno(rc);
    if (err == .SUCCESS) return true;
    log.err("{s} timerfd_settime failed: {}", .{ label, err });
    return false;
}

fn readTimer(fd: posix.fd_t) ?u64 {
    var expirations: u64 = 0;
    const n = posix.read(fd, std.mem.asBytes(&expirations)) catch return null;
    return if (n == @sizeOf(u64) and expirations > 0) expirations else null;
}

fn timespecFromNs(ns: u64) std.os.linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

/// The repeat timer expired: re-send the held key.
fn fireRepeat(self: *App) void {
    const expirations = readTimer(self.repeat_fd) orelse return;
    const keycode = self.repeat_keycode orelse return;
    // Cap the burst so a stalled loop can't flood the PTY.
    for (0..@min(expirations, 8)) |_| self.onKey(keycode, .repeat);
}

fn startSearch(self: *App) void {
    if (self.search != null) return;
    self.search = ScrollbackSearch.init(&self.term) catch |err| {
        log.warn("failed to start scrollback search: {}", .{err});
        return;
    };
    self.stopFling();
    self.clearSelection();
    self.requestFullAsyncRedraw();
}

fn finishSearch(self: *App, accept: bool) void {
    var accepted: ?vt.Selection = null;
    if (self.search) |*search| {
        if (accept and search.engineValid(&self.term) and
            search.engine_key == self.term.screens.active_key)
        {
            if (search.engine.?.selectedMatch()) |match| {
                accepted = .init(match.startPin(), match.endPin(), false);
            }
        } else if (!accept) {
            search.restoreViewport(&self.term);
        }
        search.deinit(self.alloc, &self.term);
        self.search = null;
    }
    self.stopSearchTimer();
    self.clearImeText();
    self.revealScrollbar();
    if (accepted) |selection| {
        self.term.screens.active.select(selection) catch |err| {
            log.warn("failed to select accepted search match: {}", .{err});
            self.requestFullAsyncRedraw();
            return;
        };
        self.copyToPrimary();
    }
    self.syncHoveredLink(true);
    self.requestFullAsyncRedraw();
}

fn rebuildSearch(self: *App) void {
    const search = if (self.search) |*value| value else return;
    search.deinitEngine(&self.term);
    self.stopSearchTimer();
    if (search.query.items.len == 0) {
        search.restoreViewport(&self.term);
        self.revealScrollbar();
        self.syncHoveredLink(true);
        self.requestFullAsyncRedraw();
        return;
    }

    const key = self.term.screens.active_key;
    search.engine = vt.search.Screen.init(
        self.alloc,
        self.term.screens.active,
        search.query.items,
    ) catch |err| {
        log.warn("failed to initialize scrollback search: {}", .{err});
        self.requestFullAsyncRedraw();
        return;
    };
    search.engine_key = key;
    search.engine_generation = self.term.screens.generation(key);
    search.complete = false;
    self.ensureSearchSelection();
    self.startSearchTimer();
    self.requestFullAsyncRedraw();
}

/// Reconcile search with live terminal output. Screen generations make it
/// safe to release an engine after an alternate screen was destroyed.
fn refreshSearch(self: *App) void {
    const search = if (self.search) |*value| value else return;
    if (search.query.items.len == 0) return;
    if (!search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key)
    {
        self.rebuildSearch();
        return;
    }

    search.engine.?.reloadActive() catch |err| {
        log.warn("failed to refresh scrollback search: {}", .{err});
        return;
    };
    search.complete = false;
    self.ensureSearchSelection();
    self.startSearchTimer();
    self.requestFullAsyncRedraw();
}

fn startSearchTimer(self: *App) void {
    const interval = timespecFromNs(search_tick_ms * std.time.ns_per_ms);
    _ = setTimer(self.search_fd, .{
        .it_value = interval,
        .it_interval = interval,
    }, "scrollback search");
}

fn stopSearchTimer(self: *App) void {
    _ = setTimer(self.search_fd, disarmed_timer, "scrollback search");
}

fn fireSearch(self: *App) void {
    _ = readTimer(self.search_fd) orelse return;
    var search = if (self.search) |*value| value else {
        self.stopSearchTimer();
        return;
    };
    if (search.query.items.len == 0) {
        self.stopSearchTimer();
        return;
    }
    if (!search.engineValid(&self.term)) {
        self.rebuildSearch();
        return;
    }

    const before_matches = search.engine.?.matchesLen();
    const before_selected: ?usize = if (search.engine.?.selected) |selected| selected.idx else null;
    const before_complete = search.complete;
    for (0..search_ticks_per_wake) |_| {
        search.engine.?.tick() catch |err| switch (err) {
            error.FeedRequired => {
                search.engine.?.feed() catch |feed_err| {
                    log.warn("failed to feed scrollback search: {}", .{feed_err});
                    search.complete = true;
                    self.stopSearchTimer();
                    break;
                };
                continue;
            },
            error.SearchComplete => {
                search.complete = true;
                self.stopSearchTimer();
                break;
            },
            error.OutOfMemory => {
                log.warn("failed to advance scrollback search: {}", .{err});
                search.complete = true;
                self.stopSearchTimer();
                break;
            },
        };
    }
    self.ensureSearchSelection();

    search = &self.search.?;
    const after_selected: ?usize = if (search.engine.?.selected) |selected| selected.idx else null;
    if (before_matches != search.engine.?.matchesLen() or
        before_selected != after_selected or before_complete != search.complete)
    {
        self.requestFullAsyncRedraw();
    }
}

fn ensureSearchSelection(self: *App) void {
    const search = if (self.search) |*value| value else return;
    if (!search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key) return;
    const engine = &search.engine.?;
    if (engine.selected == null and engine.matchesLen() > 0) {
        _ = engine.select(.next) catch |err| {
            log.warn("failed to select scrollback search result: {}", .{err});
            return;
        };
        self.scrollToSearchSelection();
    }
}

fn selectSearch(self: *App, direction: vt.search.Screen.Select) void {
    const search = if (self.search) |*value| value else return;
    if (!search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key) return;
    _ = search.engine.?.select(direction) catch |err| {
        log.warn("failed to move scrollback search selection: {}", .{err});
        return;
    };
    self.scrollToSearchSelection();
    self.requestFullAsyncRedraw();
}

fn scrollToSearchSelection(self: *App) void {
    const search = if (self.search) |*value| value else return;
    if (!search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key) return;
    const match = search.engine.?.selectedMatch() orelse return;
    const screen = search.engine.?.screen;
    if (!searchMatchVisible(screen, match)) {
        screen.pages.scroll(.{ .pin = match.startPin() });
        self.revealScrollbar();
        self.syncHoveredLink(true);
    }
    self.needs_redraw = true;
}

fn searchMatchVisible(screen: *vt.Screen, match: vt.highlight.Flattened) bool {
    var viewport = screen.pages.pageIterator(.right_down, .{ .viewport = .{} }, null);
    const chunks = match.chunks.slice();
    while (viewport.next()) |visible| {
        for (0..chunks.len) |i| {
            const chunk = chunks.get(i);
            if (visible.overlaps(.{
                .node = chunk.node,
                .start = chunk.start,
                .end = chunk.end,
            })) return true;
        }
    }
    return false;
}

fn appendSearchText(self: *App, text: []const u8) void {
    if (text.len == 0) return;
    const search = if (self.search) |*value| value else return;
    if (search.query.items.len + text.len > max_search_query_bytes) return;
    search.query.appendSlice(self.alloc, text) catch |err| {
        log.warn("failed to edit scrollback search: {}", .{err});
        return;
    };
    self.rebuildSearch();
}

fn backspaceSearch(self: *App) void {
    const search = if (self.search) |*value| value else return;
    if (!truncateLastUtf8(&search.query)) return;
    self.rebuildSearch();
}

fn truncateLastUtf8(text: *std.ArrayList(u8)) bool {
    if (text.items.len == 0) return false;
    var start = text.items.len - 1;
    while (start > 0 and text.items[start] & 0xc0 == 0x80) start -= 1;
    text.shrinkRetainingCapacity(start);
    return true;
}

fn handleSearchKey(self: *App, event: vt.input.KeyEvent) void {
    if (event.action == .release) return;
    if (event.mods.ctrl) {
        switch (event.key) {
            .key_n => self.selectSearch(.prev),
            .key_p => self.selectSearch(.next),
            .key_c, .key_g => self.finishSearch(false),
            .key_u => {
                const search = if (self.search) |*value| value else return;
                if (search.query.items.len == 0) return;
                search.query.clearRetainingCapacity();
                self.rebuildSearch();
            },
            else => {},
        }
        return;
    }

    switch (event.key) {
        .escape => self.finishSearch(false),
        .enter, .numpad_enter => self.finishSearch(true),
        .backspace, .numpad_backspace => self.backspaceSearch(),
        else => if (!event.mods.alt and !event.mods.super) self.appendSearchText(event.utf8),
    }
}

fn onKey(self: *App, evdev_keycode: u32, action: vt.input.KeyAction) void {
    var utf8_buf: [16]u8 = undefined;
    const event = self.keyboard.translate(&utf8_buf, evdev_keycode, action) orelse return;

    if (self.search != null) return self.handleSearchKey(event);

    if (action == .press and event.mods.ctrl) {
        switch (event.key) {
            .equal => return self.adjustRuntimeFontSize(1),
            .minus => return self.adjustRuntimeFontSize(-1),
            .digit_0 => return self.resetRuntimeFontSize(),
            else => {},
        }
    }

    // Copy/paste bindings take priority over the application.
    if (action == .press and event.mods.ctrl and event.mods.shift) {
        switch (event.key) {
            .key_c => return self.copyToClipboard(),
            .key_f => return self.startSearch(),
            .key_g => return self.pipeCommandOutput(),
            .key_n => return self.spawnNewWindow(),
            .key_v => return self.beginPaste(.clipboard),
            .key_x => return self.jumpPrompt(1),
            .key_z => return self.jumpPrompt(-1),
            .comma => return self.reloadConfig(),
            else => {},
        }
    }

    const wrote = self.encodeAndWriteKey(event);

    // A non-modifier key that produced input dismisses the selection
    // and snaps a scrolled-back viewport to the bottom (ghostty's
    // selection-clear-on-typing behavior).
    if (wrote and action != .release and !event.key.modifier()) {
        self.stopFling();
        self.clearSelection();
        if (self.term.screens.active.pages.viewport != .active) {
            self.term.screens.active.pages.scroll(.active);
            self.revealScrollbar();
            self.needs_redraw = true;
            self.syncHoveredLink(true);
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

fn searchRangeForRender(self: *App) ?Renderer.LinkRange {
    const search = if (self.search) |*value| value else return null;
    if (!search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key)
    {
        return null;
    }
    const match = search.engine.?.selectedMatch() orelse return null;
    return highlightRange(
        search.engine.?.screen,
        match.startPin(),
        match.endPin(),
        self.term.rows,
        self.term.cols,
    );
}

fn searchMatchesForRender(self: *App) !std.ArrayList(bool) {
    const search = if (self.search) |*value| value else return .empty;
    if (search.query.items.len == 0 or !search.engineValid(&self.term) or
        search.engine_key != self.term.screens.active_key)
    {
        return .empty;
    }
    return searchMatchMask(
        self.alloc,
        search.engine.?.screen,
        search.query.items,
        self.term.rows,
        self.term.cols,
    );
}

fn searchMatchMask(
    alloc: std.mem.Allocator,
    screen: *vt.Screen,
    query: []const u8,
    rows: u16,
    cols: u16,
) !std.ArrayList(bool) {
    std.debug.assert(rows > 0 and cols > 0);
    var result: std.ArrayList(bool) = .empty;
    errdefer result.deinit(alloc);

    var viewport: vt.search.Viewport = try .init(alloc, query);
    defer viewport.deinit();
    _ = try viewport.update(&screen.pages);
    while (viewport.next()) |match| {
        const range = highlightRange(
            screen,
            match.startPin(),
            match.endPin(),
            rows,
            cols,
        ) orelse continue;
        if (result.items.len == 0) {
            try result.resize(alloc, @as(usize, rows) * cols);
            @memset(result.items, false);
        }
        markSearchRange(result.items, cols, range);
    }
    return result;
}

fn markSearchRange(mask: []bool, cols: u16, range: Renderer.LinkRange) void {
    const stride: usize = cols;
    std.debug.assert(mask.len % stride == 0);
    std.debug.assert(range.end.y < mask.len / stride);
    for (range.start.y..range.end.y + 1) |y| {
        const start_x: usize = if (y == range.start.y) range.start.x else 0;
        const end_x: usize = if (y == range.end.y) range.end.x + 1 else stride;
        @memset(mask[@as(usize, y) * stride + start_x .. @as(usize, y) * stride + end_x], true);
    }
}

fn searchNoMatch(self: *App) bool {
    const search = if (self.search) |*value| value else return false;
    if (search.query.items.len == 0 or self.ime_preedit != null or
        !search.complete or !search.engineValid(&self.term))
    {
        return false;
    }
    return search.engine.?.matchesLen() == 0;
}

fn searchOverlayText(self: *App) !?[]u8 {
    const search = if (self.search) |*value| value else return null;
    const preedit: []const u8 = self.ime_preedit orelse "";
    if (!search.engineValid(&self.term)) {
        return try std.fmt.allocPrint(self.alloc, "Search: {s}{s}", .{
            search.query.items,
            preedit,
        });
    }

    const engine = &search.engine.?;
    const total = engine.matchesLen();
    const current: usize = if (engine.selected) |selected| selected.idx + 1 else 0;
    if (search.complete) {
        return try std.fmt.allocPrint(self.alloc, "Search ({d}/{d}): {s}{s}", .{
            current,
            total,
            search.query.items,
            preedit,
        });
    }
    return try std.fmt.allocPrint(self.alloc, "Search ({d}/{d}+): {s}{s}", .{
        current,
        total,
        search.query.items,
        preedit,
    });
}

const AsyncRenderStart = enum { submitted, no_work, deferred };

fn startAsyncRender(self: *App) !AsyncRenderStart {
    var async_raster = &(self.async_raster orelse return .deferred);
    if (async_raster.busy()) return .deferred;
    const selection_bg = self.selectionBackgroundForRender();
    const selection_fg = self.selectionForegroundForRender();
    if (!async_raster.configuredFor(
        self.font.discovery(),
        selection_bg,
        selection_fg,
        self.cursor_text,
        self.config.background_opacity,
        self.config.background_opacity_cells,
    )) {
        async_raster.reconfigure(
            self.font.discovery(),
            selection_bg,
            selection_fg,
            self.cursor_text,
            self.config.background_opacity,
            self.config.background_opacity_cells,
        ) catch |err| {
            self.rasterFatal(err);
            return .deferred;
        };
    }
    // DEC 2026: the terminal is mid-update, so the previous snapshot
    // (and its overlay/kitty copies) is re-rendered as-is — reachable
    // only for geometry redraws. Any pending snapshot rebuild stays
    // deferred until the freeze ends.
    const frozen = self.term.modes.get(.synchronized_output);
    var hyperlink_hints = self.linksActive();
    // Frozen jobs re-render the previous snapshot at a new geometry, so
    // they never take the unchanged-overlay shortcut.
    var overlay_dirty = true;
    var scroll: ?ScrollDetector.Scroll = null;
    var old_cursor: vt.RenderState.Cursor = self.render_state.cursor;
    if (!frozen) {
        const has_kitty_graphics = self.term.screens.active.kitty_images.placements.count() > 0;
        const new_scrollbar = self.currentScrollbarThumb();
        // Detection must precede update(). Both the previous and next frame
        // must be free of overlays because their pixels do not move with
        // terminal rows.
        if (!self.async_force_full and
            !hyperlink_hints and !self.async_job.hyperlink_hints and
            self.ime_preedit == null and self.async_job.preedit == null and
            self.async_job.link_hint == null and
            self.search == null and self.async_job.search == null and
            new_scrollbar == null and self.async_job.scrollbar == null and
            !has_kitty_graphics and self.async_job.kitty.len == 0)
        {
            scroll = try self.scroll_detector.detect(self.alloc, &self.render_state, &self.term);
        }
        if (self.async_force_full) {
            self.render_state.rows = 0;
            self.render_state.dirty = .full;
        }
        old_cursor = self.render_state.cursor;
        try self.render_state.update(self.alloc, &self.term);
        self.dirtyCursorRows(old_cursor);
        // If terminal state (rather than the fade timer) removed the last
        // overlay, redraw its old pixels instead of repairing from a buffer
        // that still contains the thumb.
        if (self.async_job.scrollbar != null and new_scrollbar == null) {
            self.render_state.dirty = .full;
        }
        if (self.render_state.dirty == .partial and self.allRenderRowsDirty()) {
            self.render_state.dirty = .full;
        }
        // Snapshot overlay inputs; the worker cannot safely read App state.
        // The previous job's copies are dead: only one job exists at a time.
        const hovered = if (hyperlink_hints) self.hovered_link else null;
        const new_link: ?[]const u8 = if (hovered) |link| link.uri else null;
        const new_range: ?Renderer.LinkRange = if (hovered) |link| link.range else null;
        const new_preedit: ?[]const u8 = if (self.search == null) self.ime_preedit else null;
        var new_search_matches = try self.searchMatchesForRender();
        errdefer new_search_matches.deinit(self.alloc);
        const new_search = try self.searchOverlayText();
        const new_search_no_match = self.searchNoMatch();
        const new_search_range = self.searchRangeForRender();
        overlay_dirty = hyperlink_hints != self.async_job.hyperlink_hints or
            !optionalStrEql(self.async_job.preedit, new_preedit) or
            !optionalStrEql(self.async_job.link_hint, new_link) or
            !optionalStrEql(self.async_job.search, new_search) or
            self.async_job.search_no_match != new_search_no_match or
            !std.meta.eql(self.async_job.link_range, new_range) or
            !std.meta.eql(self.async_job.search_range, new_search_range) or
            !std.mem.eql(bool, self.async_job.search_matches.items, new_search_matches.items) or
            !std.meta.eql(self.async_job.scrollbar, new_scrollbar);
        try self.async_job.replaceOverlays(self.alloc, new_preedit, new_link, new_search, new_search_no_match, new_range, new_search_range, new_search_matches, new_scrollbar, hyperlink_hints);
        new_search_matches = .empty;
        const kitty_dirty = self.term.screens.active.kitty_images.dirty;
        var kitty_changed = kitty_dirty;
        if (has_kitty_graphics) {
            const items = try Renderer.collectKittyPlacements(&self.font, self.alloc, &self.term);
            if (!Renderer.kittyItemsEqual(self.async_job.kitty, items)) kitty_changed = true;
            try self.async_job.replaceKitty(self.alloc, &self.kitty_cache, items);
        } else {
            if (self.async_job.kitty.len > 0) kitty_changed = true;
            self.async_job.releaseKitty(self.alloc, &self.kitty_cache);
        }
        self.kitty_cache.sweep(self.alloc);
        // Kitty placements are not tracked per row, so any change to
        // the graphics — or any content change underneath them — is a
        // full render.
        if (kitty_changed or (has_kitty_graphics and self.render_state.dirty != .false)) {
            self.render_state.dirty = .full;
        }
        overlay_dirty = overlay_dirty or kitty_changed;
        if (overlay_dirty or self.render_state.dirty != .full) scroll = null;
        // Nothing to draw: content is clean and every overlay input
        // matches the previous job. Parse batches that only stream
        // kitty payload bytes land here; submitting would burn a job
        // round-trip (and often a buffer repair copy) on a frame
        // identical to the last one.
        if (self.render_state.dirty == .false and !overlay_dirty and !self.geometry_redraw) return .no_work;
    } else {
        // Keep link affordances consistent with the stale snapshot.
        hyperlink_hints = self.async_job.hyperlink_hints;
        // Full-surface scrollbar coordinates belong to the old geometry.
        // Remove the thumb while synchronized output holds the old terminal
        // snapshot; the current geometry is picked up when the freeze ends.
        if (self.async_job.scrollbar != null) self.render_state.dirty = .full;
    }
    std.debug.assert(self.held_frame == null);
    const target = self.window.acquireRenderTarget() catch |err| {
        // Overlay snapshots above now describe the pending frame rather than
        // the last submitted one. Ensure the retry cannot mistake them for
        // unchanged inputs and skip the frame.
        self.async_force_full = true;
        // NotReady is transient window state. Every other failure means the
        // only renderer cannot obtain a buffer, so retrying in the pre-poll
        // redraw path would spin indefinitely.
        if (err != error.NotReady) self.rasterFatal(err);
        return .deferred;
    };
    errdefer self.window.cancelRender(target.buffer);
    if (scroll != null and target.age != 1 and target.source_pixels == null) scroll = null;
    if (scroll) |value| self.scroll_detector.prepare(&self.render_state, value, old_cursor);
    const repair: AsyncRaster.Repair = if (scroll == null)
        try self.planFrameRepair(target.age, target.width, target.height)
    else
        .none;
    self.async_generation +%= 1;
    async_raster.submit(.{
        .pixels = target.pixels,
        .source_pixels = target.source_pixels,
        .width = target.width,
        .height = target.height,
        .grid_x = self.layout.grid_x,
        .grid_y = self.layout.grid_y,
        .grid_width = self.layout.grid_width,
        .grid_height = self.layout.grid_height,
        .age = target.age,
        .generation = self.async_generation,
        .focused = self.focused,
        .hyperlink_hints = hyperlink_hints,
        .link_range = self.async_job.link_range,
        .search_range = self.async_job.search_range,
        .search_matches = self.async_job.search_matches.items,
        .search_background = self.copy_highlight,
        .search_foreground = self.copy_highlight_fg,
        .preedit = self.async_job.preedit,
        .link_hint = self.async_job.link_hint,
        .search = self.async_job.search,
        .search_no_match = self.async_job.search_no_match,
        .scrollbar = if (frozen) null else self.async_job.scrollbar,
        .kitty_items = self.async_job.kitty,
        .overlay_dirty = overlay_dirty,
        .scroll_shift = if (scroll) |value| value.shift else null,
        .repair = repair,
    }) catch |err| {
        self.window.cancelRender(target.buffer);
        self.kitty_cache.sweep(self.alloc);
        self.rasterFatal(err);
        return .deferred;
    };
    if (!frozen) self.term.screens.active.kitty_images.dirty = false;
    if (!frozen) self.async_force_full = false;
    return .submitted;
}

fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A finished frame is waiting and the compositor is ready for it.
fn canCommitHeldFrame(self: *const App) bool {
    if (self.held_frame == null) return false;
    return !self.window.frame_pending and !self.window.suspended;
}

/// Dirty content can start a new frame right now. A frame may start
/// while a frame callback is outstanding (raster overlaps the frame
/// wait); it is refused only while the raster worker is still coming up
/// or a render target is already checked out.
fn hasContentRedraw(self: *App) bool {
    if (!self.needs_redraw) return false;
    // DEC 2026 freezes content frames, but geometry changes still
    // repaint (the frozen snapshot at the new size).
    if (self.term.modes.get(.synchronized_output) and !self.geometry_redraw) return false;
    if (self.window.width == 0 or self.window.suspended) return false;
    if (self.window.rendering_pending) return false;
    if (self.async_raster == null) return false;
    return true;
}

/// Must report true exactly when redrawIfNeeded will make progress:
/// the pre-poll fast path in run() otherwise spins without ever reading
/// the display socket.
fn hasReadyRedraw(self: *App) bool {
    return self.canCommitHeldFrame() or self.hasContentRedraw();
}

fn redrawIfNeeded(self: *App) !void {
    if (self.canCommitHeldFrame()) self.commitHeldFrame();
    if (!self.hasContentRedraw()) return;
    switch (try self.startAsyncRender()) {
        .submitted, .no_work => {
            self.needs_redraw = false;
            self.geometry_redraw = false;
        },
        .deferred => {},
    }
}

/// Commit a finished frame that was held for the frame callback, unless
/// the window geometry changed while it waited.
fn commitHeldFrame(self: *App) void {
    const buffer = self.held_frame orelse return;
    self.held_frame = null;
    if (buffer.width != Window.physicalDimension(self.window.width, self.window.scale120) or
        buffer.height != Window.physicalDimension(self.window.height, self.window.scale120))
    {
        self.window.cancelRender(buffer);
        self.invalidateFrameDamageHistory();
        self.async_force_full = true;
        self.needs_redraw = true;
        return;
    }
    self.commitFinishedFrame(buffer);
}

/// Commit an async-rendered buffer using the current frame's damage
/// entry. Commit failures are fatal: the surface is unusable.
fn commitFinishedFrame(self: *App, buffer: *Window.Buffer) void {
    const surface_damage = self.currentFrameDamage(buffer.height) catch |err| {
        log.err("async surface damage failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
        return;
    };
    self.window.commitRender(buffer, surface_damage) catch |err| {
        log.err("async commit failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
    };
}

/// The raster worker is the only renderer; a load failure is fatal.
fn startAsyncRasterLoad(self: *App) void {
    std.debug.assert(self.async_raster == null and self.async_raster_loader == null);

    self.async_raster_loader = AsyncRaster.Loader.init(
        self.font.discovery(),
        self.selectionBackgroundForRender(),
        self.selectionForegroundForRender(),
        self.cursor_text,
        self.config.background_opacity,
        self.config.background_opacity_cells,
        &self.render_state,
    ) catch |err| {
        self.rasterFatal(err);
        return;
    };
    if (self.async_raster_loader) |*loader| {
        loader.start() catch |err| {
            loader.deinit();
            self.async_raster_loader = null;
            self.rasterFatal(err);
        };
    }
}

fn finishAsyncRasterLoad(self: *App) void {
    var loader = &(self.async_raster_loader orelse return);
    const result = loader.takeResult() orelse return;
    loader.deinit();
    self.async_raster_loader = null;

    switch (result) {
        .failed => |err| self.rasterFatal(err),
        .ready => |ready| {
            var raster = ready;
            if (!raster.configuredFor(
                self.font.discovery(),
                self.selectionBackgroundForRender(),
                self.selectionForegroundForRender(),
                self.cursor_text,
                self.config.background_opacity,
                self.config.background_opacity_cells,
            )) {
                // Config changed while loading; rebuild with the new one.
                raster.deinit();
                self.startAsyncRasterLoad();
                return;
            }

            self.async_raster = raster;
            if (self.async_raster) |*async_raster| {
                async_raster.start() catch |err| {
                    async_raster.deinit();
                    self.async_raster = null;
                    self.rasterFatal(err);
                    return;
                };
            }
            // Content may have gone dirty while the worker was loading.
            self.needs_redraw = true;
        },
    }
}

/// The app cannot render without the raster worker; stop with the error.
fn rasterFatal(self: *App, err: anyerror) void {
    log.err("raster worker unavailable: {}", .{err});
    self.window.fatal_error = err;
    self.window.running = false;
}

fn finishAsyncRender(self: *App) void {
    var async_raster = &(self.async_raster orelse return);
    const result = async_raster.takeResult() orelse return;
    const buffer = self.findRenderingBuffer(result.job.pixels) orelse {
        self.needs_redraw = true;
        return;
    };
    if (result.err) |err| {
        self.window.cancelRender(buffer);
        self.async_job.releaseKitty(self.alloc, &self.kitty_cache);
        self.kitty_cache.sweep(self.alloc);
        // A deterministic raster error would retry forever; with no other
        // renderer to fall back to, stop.
        self.rasterFatal(err);
        return;
    }
    if (result.job.generation != self.async_generation or
        self.window.suspended or
        result.job.width != Window.physicalDimension(self.window.width, self.window.scale120) or
        result.job.height != Window.physicalDimension(self.window.height, self.window.scale120))
    {
        self.window.cancelRender(buffer);
        self.async_force_full = true;
        self.needs_redraw = true;
        return;
    }
    const damage = self.beginFrameDamage(&result.job);
    self.recordAsyncFrameDamage(damage, async_raster, result.damage) catch |err| {
        log.err("async damage bookkeeping failed: {}", .{err});
        self.window.cancelRender(buffer);
        self.window.fatal_error = err;
        self.window.running = false;
        return;
    };
    self.clearRenderDirty();
    self.syncTextInputCursorRect(&self.render_state);
    if (self.window.frame_pending) {
        // The compositor is not ready for another commit. Hold the
        // finished buffer; redrawIfNeeded commits it when the frame
        // callback fires, then starts the next render immediately so
        // raster work overlaps the following frame wait.
        std.debug.assert(self.held_frame == null);
        self.held_frame = buffer;
        return;
    }
    self.commitFinishedFrame(buffer);
}

fn redrawReady(ctx: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.needs_redraw = true;
}

fn findRenderingBuffer(self: *App, pixels: []u32) ?*Window.Buffer {
    for (self.window.buffers.items) |buffer| {
        if (buffer.rendering and buffer.pixels().ptr == pixels.ptr) return buffer;
    }
    return null;
}

/// Advance the damage ring and reset the new current entry to full.
fn beginFrameDamage(self: *App, job: *const AsyncRaster.Job) *FrameDamage {
    self.frame_damage_index = (self.frame_damage_index + 1) % frame_damage_len;
    const damage = &self.frame_damage[self.frame_damage_index];
    damage.full = true;
    damage.rects.clearRetainingCapacity();
    damage.width = job.width;
    damage.height = job.height;
    damage.grid_x = job.grid_x;
    damage.grid_y = job.grid_y;
    damage.grid_width = job.grid_width;
    damage.grid_height = job.grid_height;
    damage.cell_width = self.font.cell_width;
    damage.cell_height = self.font.cell_height;
    return damage;
}

fn recordAsyncFrameDamage(self: *App, damage: *FrameDamage, async_raster: *AsyncRaster, rendered: AsyncRaster.Damage) !void {
    if (rendered == .full) return;
    damage.full = false;
    switch (rendered) {
        .full => unreachable,
        .partial => {
            try async_raster.copyRenderedRects(self.alloc, &damage.rects);
            for (damage.rects.items) |*rect| {
                rect.x += damage.grid_x;
                rect.y += damage.grid_y;
            }
            coalesceDamageRects(&damage.rects);
        },
        .none => {},
    }
}

fn coalesceDamageRects(rects: *std.ArrayList(Renderer.PixelRect)) void {
    var kept: usize = 0;
    for (rects.items) |rect| {
        if (kept > 0) {
            const previous = &rects.items[kept - 1];
            const previous_end = previous.y + previous.height;
            if (previous.x == rect.x and previous.width == rect.width and rect.y <= previous_end) {
                previous.height = @max(previous_end, rect.y + rect.height) - previous.y;
                continue;
            }
        }
        rects.items[kept] = rect;
        kept += 1;
    }
    rects.items.len = kept;
}

/// The damage entry recorded `back` frames ago (0 = current frame).
fn frameDamageBack(self: *const App, back: usize) *const FrameDamage {
    std.debug.assert(back < frame_damage_len);
    return &self.frame_damage[(self.frame_damage_index + frame_damage_len - back) % frame_damage_len];
}

/// Describe the rectangles a stale target missed since it last represented
/// a committed frame. Current cell damage is not known until the render
/// worker scans dirty rows, so repair every missed rectangle first.
fn planFrameRepair(self: *App, age: usize, width: u31, height: u31) !AsyncRaster.Repair {
    self.repair_rects.clearRetainingCapacity();
    if (self.render_state.dirty == .full or age == 1) return .none;
    if (age == 0 or age > frame_damage_len + 1) return .full;

    const missed_frames = age - 1;
    const frame_area = @as(u64, width) * height;
    var repair_area: u64 = 0;
    for (0..missed_frames) |back| {
        const entry = self.frameDamageBack(back);
        if (entry.full or
            entry.width != width or entry.height != height or
            entry.grid_x != self.layout.grid_x or entry.grid_y != self.layout.grid_y or
            entry.grid_width != self.layout.grid_width or entry.grid_height != self.layout.grid_height or
            entry.cell_width != self.font.cell_width or entry.cell_height != self.font.cell_height)
        {
            return .full;
        }
        for (entry.rects.items) |rect| {
            if (rect.x > width or rect.width > width - rect.x or
                rect.y > height or rect.height > height - rect.y)
            {
                return .full;
            }
            try self.repair_rects.append(self.alloc, rect);
            repair_area += @as(u64, rect.width) * rect.height;
            // Many small strided copies or enough overlapping area cost more
            // than one linear full-frame copy.
            if (self.repair_rects.items.len > 512 or repair_area * 2 >= frame_area) return .full;
        }
    }
    return .{ .rects = self.repair_rects.items };
}

fn invalidateFrameDamageHistory(self: *App) void {
    for (&self.frame_damage) |*damage| damage.full = true;
}

fn allRenderRowsDirty(self: *const App) bool {
    return allStateRowsDirty(&self.render_state);
}

fn allStateRowsDirty(state: *const vt.RenderState) bool {
    const rows: usize = state.rows;
    if (rows == 0) return false;
    for (state.row_data.items(.dirty)[0..rows]) |dirty| {
        if (!dirty) return false;
    }
    return true;
}

/// Surface damage of the current frame only, in physical buffer pixels.
fn currentFrameDamage(self: *App, height: u31) !Window.Damage {
    const entry = self.frameDamageBack(0);
    if (entry.full) return .full;
    std.debug.assert(entry.height == height);
    self.damage_rects.clearRetainingCapacity();
    for (entry.rects.items) |rect| {
        try self.damage_rects.append(self.alloc, .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        });
    }
    return .{ .rects = self.damage_rects.items };
}

fn syncTextInputCursorRect(self: *App, state: *const vt.RenderState) void {
    if (!self.ime_focused) return;
    self.window.setTextInputCursorRect(self.textInputCursorRect(state));
}

fn textInputCursorRect(self: *App, state: *const vt.RenderState) Window.TextInputRect {
    const cursor = state.cursor.viewport;
    const x_cells: u32 = if (cursor) |cpos| @intCast(cpos.x -| @intFromBool(cpos.wide_tail)) else 0;
    const y_cells: u32 = if (cursor) |cpos| @intCast(cpos.y) else 0;
    return physicalRectToLogical(self.window.scale120, .{
        .x = @intCast(self.layout.grid_x + x_cells * self.font.cell_width),
        .y = @intCast(self.layout.grid_y + y_cells * self.font.cell_height),
        .width = @intCast(self.font.cell_width),
        .height = @intCast(self.font.cell_height),
    });
}

fn currentCursorState(self: *const App) *const vt.RenderState {
    return &self.render_state;
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
    dirtyCursorRowsForState(&self.render_state, old_cursor);
}

fn dirtyCursorRowsForState(state: *vt.RenderState, old_cursor: vt.RenderState.Cursor) void {
    const new_cursor = state.cursor;
    if (old_cursor.visible == new_cursor.visible and
        old_cursor.visual_style == new_cursor.visual_style and
        std.meta.eql(old_cursor.viewport, new_cursor.viewport))
    {
        return;
    }

    dirtyCursorRowInState(state, old_cursor.viewport);
    dirtyCursorRowInState(state, new_cursor.viewport);
}

fn dirtyCursorRowInState(state: *vt.RenderState, viewport: ?vt.RenderState.Cursor.Viewport) void {
    const row = viewport orelse return;
    if (row.y >= state.row_data.len) return;

    state.row_data.items(.dirty)[row.y] = true;
    if (state.dirty == .false) state.dirty = .partial;
}

fn clearRenderDirty(self: *App) void {
    clearStateDirty(&self.render_state);
}

fn clearStateDirty(state: *vt.RenderState) void {
    const rows = state.row_data.slice();
    for (rows.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;
}

/// Renderer-only state changed. Invalidate any in-flight snapshot without
/// touching RenderState while the worker may be reading it; startAsyncRender
/// performs the full rebuild after the worker becomes idle.
fn requestFullAsyncRedraw(self: *App) void {
    self.invalidateAsyncFrame();
    self.needs_redraw = true;
}

fn invalidateAsyncFrame(self: *App) void {
    self.async_generation +%= 1;
    self.async_force_full = true;
    // A held frame was rastered from the now-stale state; drop it rather
    // than commit outdated pixels on the next frame callback.
    if (self.held_frame) |buffer| {
        self.held_frame = null;
        self.window.cancelRender(buffer);
        self.invalidateFrameDamageHistory();
        self.needs_redraw = true;
    }
}

/// Window resize delegate: fit the grid to the new size, resize the
/// terminal (reflow) and tell the child.
fn resize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.resizeForConfig(width, height, self.config);
}

fn resizeForConfig(self: *App, width: u31, height: u31, config: Config) anyerror!void {
    const layout = TerminalLayout.init(
        width,
        height,
        self.font.cell_width,
        self.font.cell_height,
        physicalPadding(config, self.window.scale120),
    );
    const layout_changed = !std.meta.eql(layout, self.layout);
    self.layout = layout;
    const cols = layout.columns;
    const rows = layout.rows;
    const grid_width_px = layout.grid_width;
    const grid_height_px = layout.grid_height;
    const pixels_changed = grid_width_px != self.term.width_px or grid_height_px != self.term.height_px;
    const cells_changed = cols != self.term.cols or rows != self.term.rows;
    if (!cells_changed and !pixels_changed and !layout_changed) return;

    self.term.width_px = grid_width_px;
    self.term.height_px = grid_height_px;
    if (cells_changed) {
        log.debug("resize to {d}x{d} cells", .{ cols, rows });
        try self.term.resize(self.alloc, cols, rows);
        self.refreshSearch();
    }
    try self.pty.setWinsize(.{
        .row = rows,
        .col = cols,
        .xpixel = @intCast(grid_width_px),
        .ypixel = @intCast(grid_height_px),
    });
    if (self.term.modes.get(.in_band_size_reports)) self.sendSizeReport();
    self.geometry_redraw = true;
    self.needs_redraw = true;
    self.syncScrollbarHover();
    self.syncHoveredLink(true);
}

test "damage rectangles coalesce vertically when columns match" {
    const alloc = std.testing.allocator;
    var rects: std.ArrayList(Renderer.PixelRect) = .empty;
    defer rects.deinit(alloc);
    try rects.appendSlice(alloc, &.{
        .{ .x = 9, .y = 18, .width = 27, .height = 18 },
        .{ .x = 9, .y = 36, .width = 27, .height = 18 },
        .{ .x = 18, .y = 54, .width = 18, .height = 18 },
    });

    coalesceDamageRects(&rects);
    try std.testing.expectEqualSlices(Renderer.PixelRect, &.{
        .{ .x = 9, .y = 18, .width = 27, .height = 36 },
        .{ .x = 18, .y = 54, .width = 18, .height = 18 },
    }, rects.items);
}

test "scrollbar geometry maps viewport rows across the track" {
    const layout = TerminalLayout.init(100, 100, 10, 10, .{});
    const top = scrollbarGeometry(.{ .total = 100, .offset = 0, .len = 20 }, layout, 120, scrollbar_default_alpha).?;
    const middle = scrollbarGeometry(.{ .total = 100, .offset = 40, .len = 20 }, layout, 120, scrollbar_default_alpha).?;
    const bottom = scrollbarGeometry(.{ .total = 100, .offset = 80, .len = 20 }, layout, 120, scrollbar_default_alpha).?;

    try std.testing.expectEqual(@as(u31, 91), top.thumb.x);
    try std.testing.expectEqual(@as(u31, 6), top.thumb.width);
    try std.testing.expectEqual(@as(u31, 24), top.thumb.height);
    try std.testing.expectEqual(@as(u31, 3), top.thumb.y);
    try std.testing.expectEqual(@as(u31, 38), middle.thumb.y);
    try std.testing.expectEqual(@as(u31, 73), bottom.thumb.y);
    try std.testing.expectEqual(@as(usize, 0), scrollbarRowForThumbY(top, 3));
    try std.testing.expectEqual(@as(usize, 40), scrollbarRowForThumbY(top, 38));
    try std.testing.expectEqual(@as(usize, 80), scrollbarRowForThumbY(top, 73));
    try std.testing.expect(scrollbarAtBottom(.{ .total = 100, .offset = 80, .len = 20 }));
    try std.testing.expect(!scrollbarAtBottom(.{ .total = 100, .offset = 79, .len = 20 }));
    try std.testing.expect(scrollbarShouldRender(.{ .total = 100, .offset = 80, .len = 20 }, scrollbar_default_alpha));
    try std.testing.expect(scrollbarShouldRender(.{ .total = 100, .offset = 80, .len = 20 }, scrollbar_hover_alpha));
    try std.testing.expect(!scrollbarShouldRender(.{ .total = 20, .offset = 0, .len = 20 }, scrollbar_hover_alpha));
    try std.testing.expect(!scrollbarShouldRender(.{ .total = 100, .offset = 40, .len = 20 }, 0));
    try std.testing.expect(scrollbarGeometry(.{ .total = 20, .offset = 0, .len = 20 }, layout, 120, scrollbar_default_alpha) == null);
}

test "semantic command output extracts most recent completed output" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer term.deinit(alloc);

    try term.semanticPrompt(.init(.fresh_line_new_prompt));
    try term.printString("$ ");
    try term.semanticPrompt(.init(.end_prompt_start_input));
    try term.printString("printf");
    try term.semanticPrompt(.init(.end_input_start_output));
    term.carriageReturn();
    try term.linefeed();
    try term.printString("one");
    term.carriageReturn();
    try term.linefeed();
    try term.printString("two");
    try term.semanticPrompt(.init(.end_command));
    term.carriageReturn();
    try term.linefeed();
    try term.semanticPrompt(.init(.fresh_line_new_prompt));
    try term.printString("$ ");

    const output = semanticCommandOutputText(alloc, term.screens.active).?;
    defer alloc.free(output);
    try std.testing.expectEqualStrings("one\ntwo", output);
}

test "search backspace removes one UTF-8 codepoint" {
    const alloc = std.testing.allocator;
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(alloc);
    try query.appendSlice(alloc, "abé🙂");

    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("abé", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("ab", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expectEqualStrings("a", query.items);
    try std.testing.expect(truncateLastUtf8(&query));
    try std.testing.expect(!truncateLastUtf8(&query));
}

test "scrollback search scrolls a history match into the viewport" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("needle\r\n");
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}) catch unreachable);
    }

    const screen = term.screens.active;
    var search: vt.search.Screen = try .init(alloc, screen, "needle");
    defer search.deinit();
    try search.searchAll();
    try std.testing.expect(try search.select(.next));
    const match = search.selectedMatch().?;
    try std.testing.expect(!searchMatchVisible(screen, match));

    screen.pages.scroll(.{ .pin = match.startPin() });
    try std.testing.expect(searchMatchVisible(screen, match));
    const range = highlightRange(
        screen,
        match.startPin(),
        match.endPin(),
        term.rows,
        term.cols,
    ).?;
    try std.testing.expectEqual(@as(u32, 0), range.start.y);
    try std.testing.expectEqual(@as(u16, 0), range.start.x);
    try std.testing.expectEqual(@as(u16, 5), range.end.x);
}

test "search match mask includes every visible result" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("hit hit");

    var mask = try searchMatchMask(
        alloc,
        term.screens.active,
        "hit",
        term.rows,
        term.cols,
    );
    defer mask.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 20), mask.items.len);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, true, true, true, false, false, false }, mask.items[0..10]);
    const no_matches = [_]bool{false} ** 10;
    try std.testing.expectEqualSlices(bool, &no_matches, mask.items[10..20]);
}
