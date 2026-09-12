//! tc-shell Application: Terminal Compositor Shell for TC-Wayland.
//! Coordinates:
//! - Stationary command launcher prompt at row 0 (hostname banner, line editor, history).
//!   Zero focus state: the prompt is the single, persistent point of input.
//! - 1D vertical document reflow canvas below the prompt (row 1+).
//! - Subsurface command blocks tagged $1..$n and $prev with memfd-backed streams.
//! - Floating cursor-anchored Tab completion popup overlay.
//! - Dispatcher for stateful built-ins (cd, export, collapse, expand, fullscreen, edit, run, rm, copy, view).

const TcShellApp = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const vt = @import("ghostty-vt");

const Window = @import("../Window.zig");
const Font = @import("../Font.zig");
const Keyboard = @import("../Keyboard.zig");
const Compositor = @import("../tc/Compositor.zig");
const Client = @import("../tc/Client.zig");
const Xpty = @import("../tc/Xpty.zig");
const TcOverlayRenderer = @import("../tc/TcOverlayRenderer.zig");
const PromptSurface = @import("PromptSurface.zig");
const CommandBlock = @import("CommandBlock.zig");
const SessionState = @import("SessionState.zig");
const CompactCell = @import("../tc/abi.zig").CompactCell;
const Config = @import("../Config.zig");
const log = std.log.scoped(.tc_shell);

const disarmed_timer: linux.itimerspec = .{
    .it_value = .{ .sec = 0, .nsec = 0 },
    .it_interval = .{ .sec = 0, .nsec = 0 },
};

fn createTimerFd() !posix.fd_t {
    const rc = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(rc) != .SUCCESS) return error.TimerFdFailed;
    return @intCast(rc);
}

fn setTimer(fd: posix.fd_t, spec: linux.itimerspec, label: []const u8) bool {
    const rc = linux.timerfd_settime(fd, .{}, &spec, null);
    const err = linux.errno(rc);
    if (err == .SUCCESS) return true;
    log.err("{s} timerfd_settime failed: {}", .{ label, err });
    return false;
}

fn readTimer(fd: posix.fd_t) ?u64 {
    var expirations: u64 = 0;
    const n = posix.read(fd, std.mem.asBytes(&expirations)) catch return null;
    return if (n == @sizeOf(u64) and expirations > 0) expirations else null;
}

fn timespecFromNs(ns: u64) linux.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn repeatTimerSpec(rate: i32, delay_ms: i32) ?linux.itimerspec {
    if (rate <= 0 or delay_ms < 0) return null;
    const interval_ns = @max(
        1,
        @divTrunc(std.time.ns_per_s, @as(u64, @intCast(rate))),
    );
    const delay_ns = @max(1, @as(u64, @intCast(delay_ms)) * std.time.ns_per_ms);
    return .{
        .it_value = timespecFromNs(delay_ns),
        .it_interval = timespecFromNs(interval_ns),
    };
}

fn currentMonotonicMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub const InteractiveJob = struct {
    block_id: usize,
    xpty: *Xpty,
    suspended: bool,
    start_time_ms: u64 = 0,
    is_fullscreen: bool = false,
    user_demoted: bool = false,
    is_interactive: bool = false,
    promoted_by_alt_screen: bool = false,
};

extern "c" fn popen(command: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fgets(s: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;

allocator: std.mem.Allocator,
window: *Window,
font: Font,
font_size_px: u32,
keyboard: Keyboard,
compositor: *Compositor,
client: ?*Client = null,
prompt: *PromptSurface,
session: *SessionState,

// Interactive child jobs (e.g. vim, htop)
jobs: std.ArrayList(InteractiveJob) = .empty,
active_job_id: ?usize = null,
signal_fd: posix.fd_t = -1,

// Command blocks for pipeline / non-interactive commands
blocks: std.ArrayList(*CommandBlock) = .empty,

cols: u32,
rows: u32,
running: bool = true,
needs_render: bool = true,

pointer_x: f64 = 0,
pointer_y: f64 = 0,
last_serial: u32 = 0,

selecting: bool = false,
selection_active: bool = false,
sel_start_col: u32 = 0,
sel_start_row: u32 = 0,
sel_end_col: u32 = 0,
sel_end_row: u32 = 0,
pinned_block_id: ?usize = null,
scroll_offset: usize = 0,
scroll_pixels: f64 = 0,
scroll_clicks: i32 = 0,
scroll_value120: i32 = 0,
scroll_had_pixels: bool = false,
scroll_had_discrete: bool = false,
scroll_had_value120: bool = false,

repeat_fd: posix.fd_t,
repeat_keycode: ?u32 = null,
repeat_rate: i32 = 25,
repeat_delay: i32 = 600,

pub fn init(allocator: std.mem.Allocator) !*TcShellApp {
    const initial_w: u31 = 900;
    const initial_h: u31 = 600;

    const repeat_fd = try createTimerFd();
    errdefer _ = linux.close(repeat_fd);

    const window = try Window.create(allocator, "dev.rockorager.monstar-tc-shell", "tc-shell (TC-Wayland)", .{
        .width = initial_w,
        .height = initial_h,
    });
    errdefer window.destroy();

    var font = try Font.init(allocator, "monospace", 13);
    errdefer font.deinit(allocator);

    const font_size_px = Config.fontSizePixels(.{ .points = 13 }, window.scale120);
    if (font_size_px != 0 and font_size_px != font.size_px) {
        font.deinit(allocator);
        font = try Font.init(allocator, "monospace", font_size_px);
    }

    var keyboard = try Keyboard.init();
    errdefer keyboard.deinit();

    const cols: u32 = @max(20, @as(u32, @intCast(initial_w / font.cell_width)));
    const rows: u32 = @max(4, @as(u32, @intCast(initial_h / font.cell_height)));

    var comp = try Compositor.init(allocator, null, cols, rows);
    errdefer comp.deinit();
    comp.cell_width_px = font.cell_width;
    comp.cell_height_px = font.cell_height;

    var cl = try comp.createDirectClient();
    errdefer cl.deinit();

    var prompt_surf = try PromptSurface.init(allocator, cl, cols);
    errdefer prompt_surf.deinit();

    prompt_surf.setPosition(0, @as(i32, @intCast(rows - 1)));

    var session = try SessionState.init(allocator);
    errdefer session.deinit();

    prompt_surf.updateBanner(session.getCwd()) catch {};

    var sigmask = posix.sigemptyset();
    posix.sigaddset(&sigmask, .CHLD);
    posix.sigprocmask(std.os.linux.SIG.BLOCK, &sigmask, null);
    const signal_fd: posix.fd_t = posix.signalfd(
        -1,
        &sigmask,
        std.os.linux.SFD.CLOEXEC | std.os.linux.SFD.NONBLOCK,
    ) catch -1;

    const self = try allocator.create(TcShellApp);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .window = window,
        .font = font,
        .font_size_px = font_size_px,
        .keyboard = keyboard,
        .compositor = comp,
        .client = cl,
        .prompt = prompt_surf,
        .session = session,
        .jobs = .empty,
        .active_job_id = null,
        .signal_fd = signal_fd,
        .blocks = .empty,
        .cols = cols,
        .rows = rows,
        .pinned_block_id = null,
        .scroll_offset = 0,
        .scroll_pixels = 0,
        .scroll_clicks = 0,
        .scroll_value120 = 0,
        .scroll_had_pixels = false,
        .scroll_had_discrete = false,
        .scroll_had_value120 = false,
        .repeat_fd = repeat_fd,
        .repeat_keycode = null,
        .repeat_rate = 25,
        .repeat_delay = 600,
    };

    window.setCallbacks(
        self,
        onResize,
        onKeyboard,
        onPointer,
        onTextInput,
        onScale,
        onRedrawReady,
        null,
        null,
    );

    return self;
}

pub fn deinit(self: *TcShellApp) void {
    self.cancelRepeat();
    _ = linux.close(self.repeat_fd);
    if (self.signal_fd >= 0) {
        _ = linux.close(self.signal_fd);
    }

    self.compositor.stop();

    for (self.jobs.items) |j| {
        j.xpty.deinit();
    }
    self.jobs.deinit(self.allocator);

    for (self.blocks.items) |b| {
        b.deinit();
    }
    self.blocks.deinit(self.allocator);

    self.prompt.deinit();
    self.session.deinit();
    if (self.client) |cl| cl.deinit();
    self.compositor.deinit();
    self.keyboard.deinit();
    self.font.deinit(self.allocator);
    self.window.destroy();
    self.allocator.destroy(self);
}

pub fn armRepeat(self: *TcShellApp, evdev_keycode: u32) void {
    const spec = repeatTimerSpec(self.repeat_rate, self.repeat_delay) orelse return;
    self.repeat_keycode = evdev_keycode;
    _ = setTimer(self.repeat_fd, spec, "key repeat");
}

pub fn cancelRepeat(self: *TcShellApp) void {
    self.repeat_keycode = null;
    _ = setTimer(self.repeat_fd, disarmed_timer, "key repeat");
}

pub fn fireRepeat(self: *TcShellApp) void {
    const expirations = readTimer(self.repeat_fd) orelse return;
    const keycode = self.repeat_keycode orelse return;
    for (0..@min(expirations, 8)) |_| self.onKey(keycode, .repeat);
}

pub fn getActiveJob(self: *TcShellApp) ?*InteractiveJob {
    if (self.active_job_id) |jid| {
        for (self.jobs.items) |*j| {
            if (j.block_id == jid) return j;
        }
    }
    var i = self.jobs.items.len;
    while (i > 0) {
        i -= 1;
        if (!self.jobs.items[i].suspended and self.jobs.items[i].is_fullscreen) {
            return &self.jobs.items[i];
        }
    }
    return null;
}

pub fn findJob(self: *TcShellApp, block_id: usize) ?*InteractiveJob {
    for (self.jobs.items) |*j| {
        if (j.block_id == block_id) return j;
    }
    return null;
}

pub fn findJobConst(self: *const TcShellApp, block_id: usize) ?*const InteractiveJob {
    for (self.jobs.items) |*j| {
        if (j.block_id == block_id) return j;
    }
    return null;
}

pub fn getEmbeddedJobRows(self: *const TcShellApp) u32 {
    const default_rows: u32 = 12;
    if (self.rows <= 6) return @max(2, self.rows - 2);
    return @min(default_rows, self.rows - 3);
}

pub fn getBlockContentHeight(self: *const TcShellApp, block: *const CommandBlock) usize {
    if (block.folded) return 0;
    if (self.findJobConst(block.id)) |job| {
        if (!job.is_fullscreen) {
            return job.xpty.rows;
        }
    }
    return block.output_lines.items.len;
}

pub fn demoteActiveJob(self: *TcShellApp) void {
    if (self.getActiveJob()) |job| {
        job.is_fullscreen = false;
        job.suspended = false;
        job.user_demoted = true;
        job.promoted_by_alt_screen = false;
        job.is_interactive = true;
        job.xpty.is_visible = false;
        self.active_job_id = null;
        self.pinned_block_id = job.block_id;

        const emb_rows = self.getEmbeddedJobRows();
        job.xpty.resize(self.cols, emb_rows) catch {};

        self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
        self.prompt.render();
        self.prompt.commit() catch {};
        job.xpty.setPosition(0, -100);
        _ = self.client.display.flush();
        self.needs_render = true;
    }
}

pub fn suspendActiveJob(self: *TcShellApp) void {
    if (self.getActiveJob()) |job| {
        if (job.xpty.child_pid) |pid| {
            const pgrp = blk: {
                if (job.xpty.pty) |p| {
                    var fg_pgrp: std.posix.pid_t = 0;
                    if (std.os.linux.ioctl(p.master, std.os.linux.T.IOCGPGRP, @intFromPtr(&fg_pgrp)) == 0 and fg_pgrp > 0) {
                        break :blk fg_pgrp;
                    }
                }
                break :blk pid;
            };
            _ = std.posix.kill(-pgrp, std.posix.SIG.STOP) catch {
                _ = std.posix.kill(-pid, std.posix.SIG.STOP) catch {
                    _ = std.posix.kill(pid, std.posix.SIG.STOP) catch {};
                };
            };
        }
        job.suspended = true;
        job.is_fullscreen = false;
        job.promoted_by_alt_screen = false;
        job.user_demoted = true;
        job.is_interactive = true;
        job.xpty.is_visible = false;
        self.active_job_id = null;
        self.pinned_block_id = job.block_id;

        const emb_rows = self.getEmbeddedJobRows();
        job.xpty.resize(self.cols, emb_rows) catch {};

        self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
        self.prompt.render();
        self.prompt.commit() catch {};
        job.xpty.setPosition(0, -100);
        _ = self.client.display.flush();
        self.needs_render = true;
    }
}

pub fn resumeJob(self: *TcShellApp, maybe_target: ?[]const u8) bool {
    var target_job: ?*InteractiveJob = null;
    if (maybe_target) |target| {
        if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
            target_job = self.findJob(b.id);
        }
    } else {
        var i = self.jobs.items.len;
        while (i > 0) {
            i -= 1;
            if (self.jobs.items[i].suspended or !self.jobs.items[i].is_fullscreen) {
                target_job = &self.jobs.items[i];
                break;
            }
        }
    }

    if (target_job) |job| {
        if (self.active_job_id != null and self.active_job_id.? != job.block_id) {
            self.demoteActiveJob();
        }

        if (job.suspended) {
            if (job.xpty.child_pid) |pid| {
                const pgrp = blk: {
                    if (job.xpty.pty) |p| {
                        var fg_pgrp: std.posix.pid_t = 0;
                        if (std.os.linux.ioctl(p.master, std.os.linux.T.IOCGPGRP, @intFromPtr(&fg_pgrp)) == 0 and fg_pgrp > 0) {
                            break :blk fg_pgrp;
                        }
                    }
                    break :blk pid;
                };
                _ = std.posix.kill(-pgrp, std.posix.SIG.CONT) catch {
                    _ = std.posix.kill(-pid, std.posix.SIG.CONT) catch {
                        _ = std.posix.kill(pid, std.posix.SIG.CONT) catch {};
                    };
                };
            }
            job.suspended = false;
        }
        job.user_demoted = false;
        job.promoted_by_alt_screen = false;
        job.is_fullscreen = true;
        job.is_interactive = true;
        job.xpty.is_visible = true;
        self.active_job_id = job.block_id;

        job.xpty.resize(self.cols, self.rows) catch {};

        self.prompt.setPosition(0, -100);
        job.xpty.setPosition(0, 0);
        job.xpty.commit() catch {};
        _ = self.client.display.flush();

        self.needs_render = true;
        return true;
    }
    return false;
}

pub fn getSkipLines(self: *const TcShellApp, max_canvas_rows: usize) usize {
    var total_lines: usize = 0;
    var pinned_start_line: ?usize = null;

    for (self.blocks.items) |block| {
        if (self.pinned_block_id) |p_id| {
            if (block.id == p_id and pinned_start_line == null) {
                pinned_start_line = total_lines;
            }
        }
        total_lines += 1;
        total_lines += self.getBlockContentHeight(block);
    }

    if (total_lines <= max_canvas_rows) return 0;
    const max_scroll = total_lines - max_canvas_rows;

    if (pinned_start_line) |start| {
        return @min(start, max_scroll);
    }

    const effective_scroll = @min(self.scroll_offset, max_scroll);
    return max_scroll - effective_scroll;
}

pub fn toggleBlockAtRow(self: *TcShellApp, row: u32) void {
    if (self.active_job_id != null or row >= self.rows - 1) return;
    const max_canvas_rows = if (self.rows > 1) self.rows - 1 else 0;
    const skip_lines = self.getSkipLines(max_canvas_rows);

    var line_idx: usize = 0;
    for (self.blocks.items) |block| {
        if (line_idx >= skip_lines) {
            const cur_draw_row = line_idx - skip_lines;
            if (cur_draw_row == row) {
                block.toggleFold();
                self.needs_render = true;
                return;
            }
        }
        line_idx += 1;
        line_idx += self.getBlockContentHeight(block);
    }
}

pub fn finishScrollFrame(self: *TcShellApp) void {
    var lines: i32 = 0;
    if (self.scroll_had_value120) {
        const wheel_ticks = @as(f64, @floatFromInt(self.scroll_value120)) / 120.0;
        lines = @intFromFloat(@trunc(wheel_ticks * 3.0));
    } else if (self.scroll_had_discrete) {
        lines = self.scroll_clicks * 3;
    } else if (self.scroll_pixels != 0) {
        const cell_h = @as(f64, @floatFromInt(@max(1, self.font.cell_height)));
        const whole = @divTrunc(self.scroll_pixels, cell_h);
        lines = @intFromFloat(whole);
        self.scroll_pixels -= whole * cell_h;
    }

    self.scroll_clicks = 0;
    self.scroll_value120 = 0;
    self.scroll_had_pixels = false;
    self.scroll_had_discrete = false;
    self.scroll_had_value120 = false;

    if (lines != 0) {
        self.scrollLines(lines);
    }
}

pub fn scrollLines(self: *TcShellApp, lines: i32) void {
    const active_job = self.getActiveJob();
    if (active_job != null and !active_job.?.suspended) {
        // Forward scroll to active interactive xpty (e.g. vim, htop, less)
        const x = active_job.?.xpty;
        if (lines < 0) {
            const count = @min(10, @as(usize, @intCast(-lines)));
            for (0..count) |_| {
                x.sendInput("\x1b[A") catch {};
            }
        } else if (lines > 0) {
            const count = @min(10, @as(usize, @intCast(lines)));
            for (0..count) |_| {
                x.sendInput("\x1b[B") catch {};
            }
        }
        self.needs_render = true;
        return;
    }

    const max_canvas_rows = if (self.rows > 1) self.rows - 1 else 0;
    var total_lines: usize = 0;
    for (self.blocks.items) |block| {
        total_lines += 1;
        total_lines += self.getBlockContentHeight(block);
    }

    if (total_lines <= max_canvas_rows) {
        self.scroll_offset = 0;
        self.pinned_block_id = null;
        return;
    }

    const max_scroll = total_lines - max_canvas_rows;

    if (self.pinned_block_id != null) {
        const current_skip = self.getSkipLines(max_canvas_rows);
        self.scroll_offset = if (max_scroll > current_skip) max_scroll - current_skip else 0;
        self.pinned_block_id = null;
    }

    if (lines < 0) {
        // Scroll UP (towards older commands)
        const delta: usize = @intCast(-lines);
        self.scroll_offset = @min(self.scroll_offset + delta, max_scroll);
    } else if (lines > 0) {
        // Scroll DOWN (towards prompt / recent commands)
        const delta: usize = @intCast(lines);
        if (self.scroll_offset >= delta) {
            self.scroll_offset -= delta;
        } else {
            self.scroll_offset = 0;
        }
    }
    self.needs_render = true;
}

fn unwrapCommand(cmd: []const u8) ?struct { base: []const u8, iter: std.mem.TokenIterator(u8, .any) } {
    var iter = std.mem.tokenizeAny(u8, cmd, " \t");
    var bin = iter.next() orelse return null;

    // Skip common execution wrappers like sudo, doas, env, exec, nohup, time
    while (true) {
        const base_cur = if (std.mem.lastIndexOfScalar(u8, bin, '/')) |idx| bin[idx + 1 ..] else bin;
        if (std.mem.eql(u8, base_cur, "sudo") or
            std.mem.eql(u8, base_cur, "doas") or
            std.mem.eql(u8, base_cur, "exec") or
            std.mem.eql(u8, base_cur, "nohup") or
            std.mem.eql(u8, base_cur, "time"))
        {
            while (iter.next()) |next_tok| {
                if (!std.mem.startsWith(u8, next_tok, "-")) {
                    bin = next_tok;
                    break;
                }
            } else return null;
        } else if (std.mem.eql(u8, base_cur, "env")) {
            while (iter.next()) |next_tok| {
                if (std.mem.indexOfScalar(u8, next_tok, '=') != null or std.mem.startsWith(u8, next_tok, "-")) {
                    continue;
                }
                bin = next_tok;
                break;
            } else return null;
        } else {
            break;
        }
    }

    const base = if (std.mem.lastIndexOfScalar(u8, bin, '/')) |idx| bin[idx + 1 ..] else bin;
    return .{ .base = base, .iter = iter };
}

/// Checks if command is typically an interactive fullscreen/TUI tool.
pub fn isInteractiveCommand(cmd: []const u8) bool {
    const unwrapped = unwrapCommand(cmd) orelse return false;
    const base = unwrapped.base;

    const interactive = [_][]const u8{
        // Editors
        "kak",        "helix",      "hx",        "vim",      "nvim",    "vi",
        "view",       "emacs",      "nano",      "pico",     "micro",   "joe",
        "jed",        "ed",

        // Pagers & Documentation
                "less",      "more",     "most",    "bat",
        "glow",       "man",        "info",

        // System Monitors
             "htop",     "top",     "btop",
        "glances",    "bottom",     "vtop",      "gtop",     "ncdu",    "gdu",
        "dua",

        // Shells & Multiplexers
               "bash",       "zsh",       "sh",       "fish",    "dash",
        "ksh",        "tcsh",       "csh",       "elvish",   "nu",      "tmux",
        "screen",     "zellij",

        // File Managers
            "ranger",    "yazi",     "nnn",     "lf",
        "mc",         "vifm",       "broot",

        // Git & Container TUIs
            "lazygit",  "tig",     "gitui",
        "lazydocker", "k9s",

        // Fuzzy Finders & Selection
               "fzf",       "fzy",      "peco",    "sk",

        // Audio & Chat & Mail
        "alsamixer",  "pulsemixer", "ncpamixer", "ncmpcpp",  "cmus",    "mpv",
        "mutt",       "neomutt",    "aerc",      "newsboat", "weechat", "irssi",

        // Debuggers & REPLs
        "gdb",        "lldb",       "python",    "python3",  "ipython", "node",
        "irb",        "ghci",       "lua",       "sqlite3",  "psql",    "mysql",
        "mongosh",    "redis-cli",

        // Network
         "ssh",       "mosh",     "telnet",  "nmtui",
    };
    for (interactive) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

/// Checks if command is an interactive shell (e.g. bash, zsh, fish) rather than
/// a batch script invocation (e.g. bash script.sh or bash -c "cmd").
pub fn isInteractiveShell(cmd: []const u8) bool {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return false;

    // Redirections, pipelines, or background jobs are never interactive shells
    if (std.mem.indexOfAny(u8, trimmed, "|><&;") != null) return false;

    var unwrapped = unwrapCommand(trimmed) orelse return false;
    const base = unwrapped.base;

    const known_shells = [_][]const u8{
        "bash",
        "zsh",
        "fish",
        "sh",
        "dash",
        "ksh",
        "tcsh",
        "csh",
        "nu",
        "elvish",
        "xonsh",
    };

    var is_shell = false;
    for (known_shells) |name| {
        if (std.mem.eql(u8, base, name)) {
            is_shell = true;
            break;
        }
    }
    if (!is_shell) return false;

    // Check remaining arguments for batch / script execution
    while (unwrapped.iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-c") or
            std.mem.eql(u8, arg, "--command") or
            std.mem.startsWith(u8, arg, "-lc") or
            std.mem.startsWith(u8, arg, "-cl"))
        {
            return false;
        }
        // Non-option argument: indicates a script file to execute
        if (!std.mem.startsWith(u8, arg, "-")) {
            return false;
        }
    }

    return true;
}

fn getNormalizedSelection(self: *const TcShellApp) ?struct { r1: u32, c1: u32, r2: u32, c2: u32 } {
    if (!self.selection_active) return null;
    if (self.sel_start_row < self.sel_end_row or (self.sel_start_row == self.sel_end_row and self.sel_start_col <= self.sel_end_col)) {
        return .{
            .r1 = self.sel_start_row,
            .c1 = self.sel_start_col,
            .r2 = self.sel_end_row,
            .c2 = self.sel_end_col,
        };
    } else {
        return .{
            .r1 = self.sel_end_row,
            .c1 = self.sel_end_col,
            .r2 = self.sel_start_row,
            .c2 = self.sel_start_col,
        };
    }
}

fn extractSelectedText(self: *TcShellApp) ![]u8 {
    const norm = self.getNormalizedSelection() orelse return try self.allocator.dupe(u8, "");
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);

    var r = norm.r1;
    while (r <= norm.r2 and r < self.rows) : (r += 1) {
        const c_start = if (r == norm.r1) norm.c1 else 0;
        const c_end = if (r == norm.r2) norm.c2 else self.cols - 1;

        var row_buf: std.ArrayList(u8) = .empty;
        defer row_buf.deinit(self.allocator);

        var c = c_start;
        while (c <= c_end and c < self.cols) : (c += 1) {
            const idx = r * self.cols + c;
            const cp = self.compositor.canvas[idx].codepoint;
            var utf8_bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cp), &utf8_bytes) catch 1;
            try row_buf.appendSlice(self.allocator, utf8_bytes[0..len]);
        }

        const trimmed = std.mem.trimEnd(u8, row_buf.items, " ");
        try list.appendSlice(self.allocator, trimmed);
        if (r < norm.r2) {
            try list.append(self.allocator, '\n');
        }
    }

    return list.toOwnedSlice(self.allocator);
}

fn extractScreenText(self: *TcShellApp) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);

    var r: u32 = 0;
    while (r < self.rows) : (r += 1) {
        var row_buf: std.ArrayList(u8) = .empty;
        defer row_buf.deinit(self.allocator);

        var c: u32 = 0;
        while (c < self.cols) : (c += 1) {
            const idx = r * self.cols + c;
            const cp = self.compositor.canvas[idx].codepoint;
            var utf8_bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cp), &utf8_bytes) catch 1;
            try row_buf.appendSlice(self.allocator, utf8_bytes[0..len]);
        }

        const trimmed = std.mem.trimEnd(u8, row_buf.items, " ");
        try list.appendSlice(self.allocator, trimmed);
        if (r + 1 < self.rows) {
            try list.append(self.allocator, '\n');
        }
    }

    const trimmed_all = std.mem.trimEnd(u8, list.items, "\n");
    const result = try self.allocator.dupe(u8, trimmed_all);
    list.deinit(self.allocator);
    return result;
}

fn extractSessionText(self: *TcShellApp) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);

    for (self.blocks.items) |b| {
        try list.appendSlice(self.allocator, "▶ [$");
        var num_buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}] ", .{b.id}) catch "";
        try list.appendSlice(self.allocator, num_str);
        try list.appendSlice(self.allocator, b.command);
        try list.append(self.allocator, '\n');
        try list.appendSlice(self.allocator, b.getRawOutput());
        if (b.raw_output.items.len > 0 and b.raw_output.items[b.raw_output.items.len - 1] != '\n') {
            try list.append(self.allocator, '\n');
        }
    }

    return list.toOwnedSlice(self.allocator);
}

fn copyToClipboard(_: *TcShellApp, text: []const u8) void {
    if (text.len == 0) return;
    if (popen("wl-copy", "w")) |pipe| {
        _ = std.c.fwrite(text.ptr, 1, text.len, @ptrCast(pipe));
        _ = pclose(pipe);
    }
    if (popen("wl-copy --primary", "w")) |pipe| {
        _ = std.c.fwrite(text.ptr, 1, text.len, @ptrCast(pipe));
        _ = pclose(pipe);
    }
}

fn onJobOutput(ctx: ?*anyopaque, bytes: []const u8) void {
    const block: *CommandBlock = @ptrCast(@alignCast(ctx orelse return));
    block.appendOutput(bytes) catch {};
}

pub fn launchJob(self: *TcShellApp, cmd: []const u8, force_interactive: bool) !void {
    if (self.active_job_id != null) {
        self.demoteActiveJob();
    }

    const block_id = self.session.allocateBlockId();
    var block = try CommandBlock.init(self.allocator, block_id, cmd);
    block.status = .running;
    if (force_interactive) {
        try block.appendOutput("[running in interactive xpty]\n");
    }
    try self.blocks.append(self.allocator, block);
    self.pinned_block_id = block_id;

    var new_xpty = try Xpty.init(self.allocator, self.client, self.cols, self.rows);

    if (force_interactive) {
        self.prompt.setPosition(0, -100);
        new_xpty.setPosition(0, 0);
        new_xpty.is_visible = true;
        self.active_job_id = block_id;
    } else {
        self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
        new_xpty.setPosition(0, -100);
        new_xpty.is_visible = false;
        self.active_job_id = null;
    }

    new_xpty.setOutputHandler(block, onJobOutput);

    const cmd_z = try self.allocator.dupeZ(u8, cmd);
    defer self.allocator.free(cmd_z);

    const sh_z: [*:0]const u8 = "/bin/sh";
    const c_arg: [*:0]const u8 = "-c";
    const argv = [_:null]?[*:0]const u8{ sh_z, c_arg, cmd_z.ptr, null };

    var env_list: std.ArrayList(?[*:0]const u8) = .empty;
    defer env_list.deinit(self.allocator);

    var env_idx: usize = 0;
    while (std.c.environ[env_idx]) |entry| : (env_idx += 1) {
        const val = std.mem.span(entry);
        if (std.mem.startsWith(u8, val, "TERM=")) continue;
        if (std.mem.startsWith(u8, val, "COLORTERM=")) continue;
        env_list.append(self.allocator, entry) catch continue;
    }
    env_list.append(self.allocator, "TERM=xterm-256color") catch {};
    env_list.append(self.allocator, "COLORTERM=truecolor") catch {};
    const envp = env_list.toOwnedSliceSentinel(self.allocator, null) catch {
        new_xpty.initSimulatedShell();
        try self.jobs.append(self.allocator, .{
            .block_id = block_id,
            .xpty = new_xpty,
            .suspended = false,
            .start_time_ms = currentMonotonicMs(),
            .is_fullscreen = force_interactive,
            .is_interactive = force_interactive,
        });
        _ = self.client.display.flush();
        self.needs_render = true;
        return;
    };
    defer self.allocator.free(envp);

    new_xpty.spawnPty(sh_z, &argv, envp.ptr) catch {
        new_xpty.initSimulatedShell();
    };

    try self.jobs.append(self.allocator, .{
        .block_id = block_id,
        .xpty = new_xpty,
        .suspended = false,
        .start_time_ms = currentMonotonicMs(),
        .is_fullscreen = force_interactive,
        .is_interactive = force_interactive,
    });

    _ = self.client.display.flush();
    self.needs_render = true;
}

pub fn launchInteractive(self: *TcShellApp, cmd: []const u8) !void {
    return self.launchJob(cmd, true);
}

pub fn launchBlock(self: *TcShellApp, cmd: []const u8) !void {
    return self.launchJob(cmd, false);
}

pub fn launchCommand(self: *TcShellApp, raw_cmd: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw_cmd, " \t\r\n");
    if (trimmed.len == 0) return;

    // 0. Explicit interactive launcher prefix: "xpty <command>" or "interactive <command>"
    if (std.mem.startsWith(u8, trimmed, "xpty ") or std.mem.startsWith(u8, trimmed, "interactive ")) {
        const cmd_part = if (std.mem.startsWith(u8, trimmed, "xpty "))
            trimmed[5..]
        else
            trimmed[12..];
        const cmd_trimmed = std.mem.trim(u8, cmd_part, " \t");
        if (cmd_trimmed.len > 0) {
            const exp = try SessionState.expandPipeline(self.allocator, self.blocks.items, cmd_trimmed);
            defer self.allocator.free(exp);
            try self.launchInteractive(exp);
            return;
        }
    }

    // 1. Built-in command handling
    const builtin = SessionState.parseBuiltin(trimmed);
    switch (builtin) {
        .clear => {
            for (self.jobs.items) |j| {
                j.xpty.deinit();
            }
            self.jobs.clearRetainingCapacity();
            self.active_job_id = null;
            for (self.blocks.items) |b| b.deinit();
            self.blocks.clearRetainingCapacity();
            self.scroll_offset = 0;
            self.pinned_block_id = null;
            self.needs_render = true;
            return;
        },
        .exit => {
            if (self.active_job_id != null) {
                self.closeActiveJob();
            } else {
                self.running = false;
            }
            return;
        },
        .cd => |maybe_path| {
            const block_id = self.session.allocateBlockId();
            var block = try CommandBlock.init(self.allocator, block_id, raw_cmd);
            var success = true;
            self.session.changeDirectory(maybe_path) catch |err| {
                success = false;
                const err_msg = switch (err) {
                    error.NoPreviousDirectory => "cd: OLDPWD not set\n",
                    error.DirectoryChangeFailed => "cd: no such file or directory\n",
                    error.OutOfMemory => "cd: out of memory\n",
                };
                block.appendOutput(err_msg) catch {};
            };
            block.finish(if (success) 0 else 1, 0);
            try self.blocks.append(self.allocator, block);
            self.pinned_block_id = block_id;
            self.prompt.updateBanner(self.session.getCwd()) catch {};
            self.needs_render = true;
            return;
        },
        .pwd => {
            const block_id = self.session.allocateBlockId();
            var block = try CommandBlock.init(self.allocator, block_id, "pwd");
            const cwd_str = try std.fmt.allocPrint(self.allocator, "{s}\n", .{self.session.getCwd()});
            defer self.allocator.free(cwd_str);
            try block.appendOutput(cwd_str);
            block.finish(0, 0);
            try self.blocks.append(self.allocator, block);
            self.pinned_block_id = block_id;
            self.needs_render = true;
            return;
        },
        .export_var => |entry| {
            self.session.setEnv(entry.key, entry.value) catch {};
            self.needs_render = true;
            return;
        },
        .unset_var => |key| {
            self.session.unsetEnv(key);
            self.needs_render = true;
            return;
        },
        .collapse => |target| {
            if (SessionState.isAllTarget(target)) {
                for (self.blocks.items) |b| {
                    b.collapse();
                }
            } else if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                b.collapse();
            }
            self.needs_render = true;
            return;
        },
        .expand => |target| {
            if (SessionState.isAllTarget(target)) {
                for (self.blocks.items) |b| {
                    b.expand();
                }
            } else if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                b.expand();
            }
            self.needs_render = true;
            return;
        },
        .fullscreen => |maybe_target| {
            if (self.resumeJob(maybe_target)) {
                return;
            }
            var any_fullscreen = false;
            if (maybe_target) |target| {
                if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                    b.fullscreen = !b.fullscreen;
                    any_fullscreen = b.fullscreen;
                }
            } else {
                for (self.blocks.items) |b| {
                    b.fullscreen = false;
                }
            }
            if (any_fullscreen) {
                self.prompt.setPosition(0, -100);
            } else {
                self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
            }
            _ = self.client.display.flush();
            self.needs_render = true;
            return;
        },
        .edit => |target| {
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                try self.prompt.setInput(b.command);
            }
            self.needs_render = true;
            return;
        },
        .run => |target| {
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                const cmd_copy = try self.allocator.dupe(u8, b.command);
                defer self.allocator.free(cmd_copy);
                try self.launchCommand(cmd_copy);
            }
            return;
        },
        .rm => |target| {
            if (SessionState.isAllTarget(target)) {
                for (self.blocks.items) |b| b.deinit();
                self.blocks.clearRetainingCapacity();
                self.scroll_offset = 0;
                self.pinned_block_id = null;
            } else if (SessionState.findBlockIndex(self.blocks.items, target)) |idx| {
                const removed = self.blocks.orderedRemove(idx);
                if (self.pinned_block_id == removed.id) {
                    self.pinned_block_id = null;
                }
                removed.deinit();
            }
            self.needs_render = true;
            return;
        },
        .copy => |info| {
            const block_id = self.session.allocateBlockId();
            var block = try CommandBlock.init(self.allocator, block_id, raw_cmd);
            var copied_len: usize = 0;
            if (info.is_screen) {
                if (self.extractScreenText()) |scr_text| {
                    defer self.allocator.free(scr_text);
                    self.copyToClipboard(scr_text);
                    copied_len = scr_text.len;
                } else |_| {}
            } else if (info.is_all) {
                if (self.extractSessionText()) |sess_text| {
                    defer self.allocator.free(sess_text);
                    self.copyToClipboard(sess_text);
                    copied_len = sess_text.len;
                } else |_| {}
            } else if (SessionState.resolveBlock(self.blocks.items, info.target)) |b| {
                const to_copy = if (info.is_cmd) b.command else b.getRawOutput();
                self.copyToClipboard(to_copy);
                copied_len = to_copy.len;
            } else {
                if (self.extractScreenText()) |scr_text| {
                    defer self.allocator.free(scr_text);
                    self.copyToClipboard(scr_text);
                    copied_len = scr_text.len;
                } else |_| {}
            }
            const msg = try std.fmt.allocPrint(self.allocator, "Copied {d} bytes to clipboard\n", .{copied_len});
            defer self.allocator.free(msg);
            try block.appendOutput(msg);
            block.finish(0, 0);
            try self.blocks.append(self.allocator, block);
            self.pinned_block_id = block_id;
            self.needs_render = true;
            return;
        },
        .view => |target| {
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                if (b.getMemfd()) |fd| {
                    const pid = linux.getpid();
                    const view_cmd = try std.fmt.allocPrint(self.allocator, "less -R /proc/{d}/fd/{d}", .{ pid, fd });
                    defer self.allocator.free(view_cmd);
                    try self.launchInteractive(view_cmd);
                    return;
                }
            }
            return;
        },
        .none => {},
    }

    // 2. Expand pipeline & block references ($1 | grep foo, diff $1 $2)
    const cmd = try SessionState.expandPipeline(self.allocator, self.blocks.items, trimmed);
    defer self.allocator.free(cmd);

    // 3. Dispatch job: external commands run attached to real PTY with Ghostty VT.
    // Interactive shells (bash, zsh, fish, etc.) are launched fullscreen.
    const force_interactive = isInteractiveShell(cmd);
    try self.launchJob(cmd, force_interactive);
}

pub fn closeActiveJob(self: *TcShellApp) void {
    if (self.active_job_id) |bid| {
        self.closeJob(bid, 0);
    }
}

pub fn closeJob(self: *TcShellApp, block_id: usize, exit_code: u8) void {
    var elapsed_ms: u64 = 0;
    var was_interactive = false;
    var last_cells: ?[]CompactCell = null;
    var last_cols: u32 = 0;
    var last_rows: u32 = 0;

    var i: usize = 0;
    while (i < self.jobs.items.len) : (i += 1) {
        if (self.jobs.items[i].block_id == block_id) {
            const j_ref = &self.jobs.items[i];
            was_interactive = j_ref.is_interactive or
                j_ref.is_fullscreen or
                j_ref.user_demoted or
                j_ref.suspended or
                j_ref.xpty.isAlternateScreen();
            const now_ms = currentMonotonicMs();
            if (now_ms >= j_ref.start_time_ms) {
                elapsed_ms = now_ms - j_ref.start_time_ms;
            }
            const j = self.jobs.orderedRemove(i);
            if (was_interactive and j.xpty.cells.len > 0) {
                last_cols = j.xpty.cols;
                last_rows = j.xpty.rows;
                last_cells = self.allocator.dupe(CompactCell, j.xpty.cells) catch null;
            }
            j.xpty.deinit();
            break;
        }
    }
    for (self.blocks.items) |b| {
        if (b.id == block_id) {
            b.finish(exit_code, elapsed_ms);
            if (was_interactive) {
                if (last_cells) |cells| {
                    defer self.allocator.free(cells);
                    self.formatCellsToBlock(b, cells, last_cols, last_rows) catch {};
                }
                if (b.output_lines.items.len == 0) {
                    b.output_lines.clearRetainingCapacity();
                    b.appendOutput("[interactive session exited]\n") catch {};
                }
            }
            break;
        }
    }
    if (self.active_job_id == block_id) {
        self.active_job_id = null;
        self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
        self.prompt.render();
        self.prompt.commit() catch {};
        self.prompt.updateBanner(self.session.getCwd()) catch {};
    }
    if (self.client) |cl| {
        _ = cl.display.flush();
    }
    self.needs_render = true;
}

pub fn formatCellsToBlock(self: *TcShellApp, block: *CommandBlock, cells: []const CompactCell, cols: u32, rows: u32) !void {
    for (block.output_lines.items) |line| self.allocator.free(line);
    block.output_lines.clearRetainingCapacity();
    block.pending_line.clearRetainingCapacity();

    var effective_rows: u32 = rows;
    while (effective_rows > 0) {
        const r = effective_rows - 1;
        var row_has_content = false;
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const cell = cells[r * cols + c];
            if ((cell.codepoint != 0 and cell.codepoint != ' ') or cell.bg_color != 0 or cell.flags.reverse) {
                row_has_content = true;
                break;
            }
        }
        if (row_has_content) break;
        effective_rows -= 1;
    }

    var r: u32 = 0;
    while (r < effective_rows) : (r += 1) {
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        var cur_fg: ?u8 = null;
        var cur_bg: ?u8 = null;
        var cur_bold: bool = false;

        var effective_cols: u32 = cols;
        while (effective_cols > 0) {
            const c = effective_cols - 1;
            const cell = cells[r * cols + c];
            if ((cell.codepoint != 0 and cell.codepoint != ' ') or cell.bg_color != 0 or cell.flags.reverse) {
                break;
            }
            effective_cols -= 1;
        }

        var c: u32 = 0;
        while (c < effective_cols) : (c += 1) {
            const cell = cells[r * cols + c];
            const fg = cell.fg_color;
            const bg = cell.bg_color;
            const bold = cell.flags.bold;

            if (cur_fg != fg or cur_bg != bg or cur_bold != bold) {
                cur_fg = fg;
                cur_bg = bg;
                cur_bold = bold;
                var sgr_buf: [32]u8 = undefined;
                const bold_str = if (bold) ";1" else "";
                const sgr = std.fmt.bufPrint(&sgr_buf, "\x1b[0;38;5;{d};48;5;{d}{s}m", .{ fg, bg, bold_str }) catch "";
                try line_buf.appendSlice(self.allocator, sgr);
            }

            var utf8_bytes: [4]u8 = undefined;
            const cp = if (cell.codepoint == 0) ' ' else cell.codepoint;
            const len = std.unicode.utf8Encode(@intCast(cp), &utf8_bytes) catch 1;
            try line_buf.appendSlice(self.allocator, utf8_bytes[0..len]);
        }

        try line_buf.appendSlice(self.allocator, "\x1b[0m");
        const line_str = try line_buf.toOwnedSlice(self.allocator);
        try block.output_lines.append(self.allocator, line_str);
    }
}

fn color256ToRgba(idx: u8, palette: [16]u32) u32 {
    if (idx < 16) return palette[idx];
    if (idx < 232) {
        const cube_idx = idx - 16;
        const b_idx = cube_idx % 6;
        const g_idx = (cube_idx / 6) % 6;
        const r_idx = cube_idx / 36;
        const r: u32 = if (r_idx == 0) 0 else 55 + r_idx * 40;
        const g: u32 = if (g_idx == 0) 0 else 55 + g_idx * 40;
        const b: u32 = if (b_idx == 0) 0 else 55 + b_idx * 40;
        return (r << 24) | (g << 16) | (b << 8) | 0xFF;
    }
    const gray: u32 = (@as(u32, idx - 232)) * 10 + 8;
    return (gray << 24) | (gray << 16) | (gray << 8) | 0xFF;
}

pub fn renderRowText(
    canvas: []Compositor.CanvasCell,
    cols: u32,
    row: usize,
    text: []const u8,
    fg: u32,
    bg: u32,
    bold: bool,
    palette: [16]u32,
) void {
    var col_idx: usize = 0;
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");

    var cur_fg: u32 = fg;
    var cur_bg: u32 = bg;
    var cur_bold: bool = bold;
    var cur_italic: bool = false;
    var cur_underline: bool = false;

    var i: usize = 0;
    while (i < trimmed.len and col_idx < cols) {
        if (trimmed[i] == 0x1b) {
            if (i + 1 < trimmed.len and trimmed[i + 1] == '[') {
                // Parse CSI sequence
                i += 2;
                var params: [16]u32 = undefined;
                var param_count: usize = 0;
                var cur_param: u32 = 0;
                var has_param_digit = false;

                while (i < trimmed.len) : (i += 1) {
                    const b = trimmed[i];
                    if (b >= '0' and b <= '9') {
                        cur_param = cur_param * 10 + (b - '0');
                        has_param_digit = true;
                    } else if (b == ';') {
                        if (param_count < 16) {
                            params[param_count] = if (has_param_digit) cur_param else 0;
                            param_count += 1;
                        }
                        cur_param = 0;
                        has_param_digit = false;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        if (has_param_digit or param_count > 0) {
                            if (param_count < 16) {
                                params[param_count] = if (has_param_digit) cur_param else 0;
                                param_count += 1;
                            }
                        }
                        if (b == 'm') {
                            if (param_count == 0) {
                                cur_fg = fg;
                                cur_bg = bg;
                                cur_bold = bold;
                                cur_italic = false;
                                cur_underline = false;
                            } else {
                                var p_idx: usize = 0;
                                while (p_idx < param_count) : (p_idx += 1) {
                                    const p = params[p_idx];
                                    switch (p) {
                                        0 => {
                                            cur_fg = fg;
                                            cur_bg = bg;
                                            cur_bold = bold;
                                            cur_italic = false;
                                            cur_underline = false;
                                        },
                                        1 => cur_bold = true,
                                        3 => cur_italic = true,
                                        4 => cur_underline = true,
                                        7 => {
                                            const tmp = cur_fg;
                                            cur_fg = cur_bg;
                                            cur_bg = tmp;
                                        },
                                        22 => cur_bold = false,
                                        23 => cur_italic = false,
                                        24 => cur_underline = false,
                                        30...37 => cur_fg = palette[p - 30],
                                        39 => cur_fg = fg,
                                        40...47 => cur_bg = palette[p - 40],
                                        49 => cur_bg = bg,
                                        90...97 => cur_fg = palette[8 + (p - 90)],
                                        100...107 => cur_bg = palette[8 + (p - 100)],
                                        38 => {
                                            if (p_idx + 2 < param_count and params[p_idx + 1] == 5) {
                                                cur_fg = color256ToRgba(@truncate(params[p_idx + 2]), palette);
                                                p_idx += 2;
                                            } else if (p_idx + 4 < param_count and params[p_idx + 1] == 2) {
                                                const r = params[p_idx + 2] & 0xFF;
                                                const g = params[p_idx + 3] & 0xFF;
                                                const bl = params[p_idx + 4] & 0xFF;
                                                cur_fg = (r << 24) | (g << 16) | (bl << 8) | 0xFF;
                                                p_idx += 4;
                                            }
                                        },
                                        48 => {
                                            if (p_idx + 2 < param_count and params[p_idx + 1] == 5) {
                                                cur_bg = color256ToRgba(@truncate(params[p_idx + 2]), palette);
                                                p_idx += 2;
                                            } else if (p_idx + 4 < param_count and params[p_idx + 1] == 2) {
                                                const r = params[p_idx + 2] & 0xFF;
                                                const g = params[p_idx + 3] & 0xFF;
                                                const bl = params[p_idx + 4] & 0xFF;
                                                cur_bg = (r << 24) | (g << 16) | (bl << 8) | 0xFF;
                                                p_idx += 4;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        }
                        i += 1;
                        break;
                    }
                }
                continue;
            } else if (i + 1 < trimmed.len and trimmed[i + 1] == ']') {
                // Skip OSC sequence
                i += 2;
                while (i < trimmed.len and trimmed[i] != 0x07) : (i += 1) {
                    if (trimmed[i] == 0x1b and i + 1 < trimmed.len and trimmed[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                if (i < trimmed.len and trimmed[i] == 0x07) i += 1;
                continue;
            } else if (i + 2 < trimmed.len and (trimmed[i + 1] == '(' or trimmed[i + 1] == ')')) {
                i += 3;
                continue;
            } else {
                i += 1;
                continue;
            }
        }

        // Regular character or UTF-8 sequence
        const len = std.unicode.utf8ByteSequenceLength(trimmed[i]) catch 1;
        if (i + len <= trimmed.len) {
            const cp = std.unicode.utf8Decode(trimmed[i .. i + len]) catch trimmed[i];
            i += len;
            if (cp == '\r') {
                col_idx = 0;
                continue;
            }
            canvas[row * cols + col_idx] = .{
                .codepoint = cp,
                .fg_rgba = cur_fg,
                .bg_rgba = cur_bg,
                .bold = cur_bold,
                .italic = cur_italic,
                .underline = cur_underline,
            };
            col_idx += 1;
        } else {
            i += 1;
        }
    }

    while (col_idx < cols) : (col_idx += 1) {
        canvas[row * cols + col_idx] = .{
            .codepoint = ' ',
            .fg_rgba = fg,
            .bg_rgba = bg,
            .bold = false,
        };
    }
}

pub fn render(self: *TcShellApp) void {
    if (self.window.width == 0 or self.window.suspended or self.window.rendering_pending or self.window.frame_pending) return;

    self.compositor.composite();

    const active_job = self.getActiveJob();
    const is_xpty_active = (active_job != null and !active_job.?.suspended);

    // 1D Vertical Document Reflow (active when not viewing foreground xpty)
    if (!is_xpty_active) {
        var fullscreen_block: ?*CommandBlock = null;
        for (self.blocks.items) |b| {
            if (b.fullscreen) {
                fullscreen_block = b;
                break;
            }
        }

        if (fullscreen_block) |fb| {
            // Fullscreen static block: fills all rows from 0 to rows - 1 (prompt is hidden)
            var r_clear: usize = 0;
            while (r_clear < self.rows) : (r_clear += 1) {
                var c_clear: usize = 0;
                while (c_clear < self.cols) : (c_clear += 1) {
                    self.compositor.canvas[r_clear * self.cols + c_clear] = .{
                        .codepoint = ' ',
                        .fg_rgba = self.compositor.theme_fg_rgba,
                        .bg_rgba = self.compositor.theme_bg_rgba,
                    };
                }
            }

            var cur_row: usize = 0;
            const header_bg: u32 = 0x24273AFF;
            const status_fg: u32 = switch (fb.status) {
                .success => 0xA6E3A1FF,
                .failed => 0xF38BA8FF,
                .running => 0xF9E2AFFF,
            };

            var header_buf: [128]u8 = undefined;
            const status_str = if (fb.status == .success) "ok" else if (fb.status == .failed) "err" else "...";
            const header_text = std.fmt.bufPrint(&header_buf, "▶ [${d}] {s} [{s}] ({d}ms) [FULLSCREEN - Esc to exit]", .{
                fb.id,
                fb.command,
                status_str,
                fb.elapsed_ms,
            }) catch "▶ command";

            renderRowText(self.compositor.canvas, self.cols, cur_row, header_text, status_fg, header_bg, true, self.compositor.theme_palette);
            cur_row += 1;

            for (fb.output_lines.items) |line| {
                if (cur_row >= self.rows) break;
                renderRowText(self.compositor.canvas, self.cols, cur_row, line, self.compositor.theme_fg_rgba, self.compositor.theme_bg_rgba, false, self.compositor.theme_palette);
                cur_row += 1;
            }
        } else {
            // Normal document reflow: prompt is at the bottom (row = self.rows - 1)
            // Available rows for command blocks: 0 .. self.rows - 2 (total self.rows - 1 rows)
            const max_canvas_rows = if (self.rows > 1) self.rows - 1 else 0;

            var r_clear: usize = 0;
            while (r_clear < max_canvas_rows) : (r_clear += 1) {
                var c_clear: usize = 0;
                while (c_clear < self.cols) : (c_clear += 1) {
                    self.compositor.canvas[r_clear * self.cols + c_clear] = .{
                        .codepoint = ' ',
                        .fg_rgba = self.compositor.theme_fg_rgba,
                        .bg_rgba = self.compositor.theme_bg_rgba,
                    };
                }
            }

            const skip_lines = self.getSkipLines(max_canvas_rows);

            var line_idx: usize = 0;
            for (self.blocks.items) |block| {
                const header_bg: u32 = 0x24273AFF;
                const status_fg: u32 = switch (block.status) {
                    .success => 0xA6E3A1FF,
                    .failed => 0xF38BA8FF,
                    .running => 0xF9E2AFFF,
                };

                const maybe_job = self.findJob(block.id);
                const is_live_tui = (maybe_job != null and !maybe_job.?.is_fullscreen and !maybe_job.?.suspended);
                const is_paused_tui = (maybe_job != null and maybe_job.?.suspended);

                var header_buf: [128]u8 = undefined;
                const status_str = if (is_live_tui)
                    "live"
                else if (is_paused_tui)
                    "suspended"
                else if (block.status == .success)
                    "ok"
                else if (block.status == .failed)
                    "err"
                else
                    "...";

                const content_len = self.getBlockContentHeight(block);
                const fold_icon = if (content_len == 0 and !block.folded) "•" else (if (block.folded) "▶" else "▼");

                const header_text = if (is_live_tui)
                    std.fmt.bufPrint(&header_buf, "{s} [${d}] {s} [{s}] ({d}ms) [type 'fg' to zoom]", .{
                        fold_icon,
                        block.id,
                        block.command,
                        status_str,
                        block.elapsed_ms,
                    }) catch "▶ command"
                else
                    std.fmt.bufPrint(&header_buf, "{s} [${d}] {s} [{s}] ({d}ms)", .{
                        fold_icon,
                        block.id,
                        block.command,
                        status_str,
                        block.elapsed_ms,
                    }) catch "▶ command";

                if (line_idx >= skip_lines) {
                    const cur_row = line_idx - skip_lines;
                    if (cur_row < max_canvas_rows) {
                        renderRowText(self.compositor.canvas, self.cols, cur_row, header_text, status_fg, header_bg, true, self.compositor.theme_palette);
                    }
                }
                line_idx += 1;

                if (!block.folded) {
                    if (maybe_job) |job| {
                        if (!job.is_fullscreen) {
                            const x_rows = job.xpty.rows;
                            const x_cols = job.xpty.cols;
                            var r: u32 = 0;
                            while (r < x_rows) : (r += 1) {
                                if (line_idx >= skip_lines) {
                                    const cur_row = line_idx - skip_lines;
                                    if (cur_row < max_canvas_rows) {
                                        var c: u32 = 0;
                                        while (c < self.cols) : (c += 1) {
                                            const dst_idx = cur_row * self.cols + c;
                                            if (c < x_cols) {
                                                const src_cell = job.xpty.cells[r * x_cols + c];
                                                var fg = if (src_cell.flags.fg_is_palette and src_cell.fg_color < 16)
                                                    self.compositor.theme_palette[src_cell.fg_color]
                                                else
                                                    self.compositor.theme_fg_rgba;

                                                var bg = if (src_cell.flags.bg_is_palette and src_cell.bg_color > 0 and src_cell.bg_color < 16)
                                                    self.compositor.theme_palette[src_cell.bg_color]
                                                else
                                                    self.compositor.theme_bg_rgba;

                                                if (src_cell.flags.reverse) {
                                                    const tmp = fg;
                                                    fg = bg;
                                                    bg = tmp;
                                                }

                                                self.compositor.canvas[dst_idx] = .{
                                                    .codepoint = if (src_cell.codepoint == 0) ' ' else src_cell.codepoint,
                                                    .fg_rgba = fg,
                                                    .bg_rgba = bg,
                                                    .bold = src_cell.flags.bold,
                                                    .italic = src_cell.flags.italic,
                                                    .underline = src_cell.flags.underline,
                                                };
                                            } else {
                                                self.compositor.canvas[dst_idx] = .{
                                                    .codepoint = ' ',
                                                    .fg_rgba = self.compositor.theme_fg_rgba,
                                                    .bg_rgba = self.compositor.theme_bg_rgba,
                                                    .bold = false,
                                                };
                                            }
                                        }
                                    }
                                }
                                line_idx += 1;
                            }
                        }
                    } else {
                        for (block.output_lines.items) |line| {
                            if (line_idx >= skip_lines) {
                                const cur_row = line_idx - skip_lines;
                                if (cur_row < max_canvas_rows) {
                                    renderRowText(self.compositor.canvas, self.cols, cur_row, line, self.compositor.theme_fg_rgba, self.compositor.theme_bg_rgba, false, self.compositor.theme_palette);
                                }
                            }
                            line_idx += 1;
                        }
                    }
                }
            }
        }
    }

    // Highlight mouse selection on canvas
    if (self.getNormalizedSelection()) |norm| {
        var r = norm.r1;
        while (r <= norm.r2 and r < self.rows) : (r += 1) {
            const c_start = if (r == norm.r1) norm.c1 else 0;
            const c_end = if (r == norm.r2) norm.c2 else self.cols - 1;
            var c = c_start;
            while (c <= c_end and c < self.cols) : (c += 1) {
                const canvas_idx = r * self.cols + c;
                self.compositor.canvas[canvas_idx].bg_rgba = 0x585B70FF;
                self.compositor.canvas[canvas_idx].fg_rgba = 0xF5E0DCFF;
            }
        }
    }

    // Floating Tab Completion Overlay: renders floating directly above the bottom prompt
    if (self.prompt.completion_active and self.prompt.completion_items.items.len > 0) {
        const cursor_col = self.prompt.getCursorScreenCol();
        var max_item_len: usize = 14;
        for (self.prompt.completion_items.items) |item| {
            if (item.len > max_item_len) max_item_len = item.len;
        }
        const overlay_w: usize = @min(@max(max_item_len + 4, 18), self.cols);
        const start_col = if (self.cols > overlay_w) @min(cursor_col, self.cols - overlay_w) else 0;
        const items_to_show = @min(self.prompt.completion_items.items.len, 8);

        const overlay_bg: u32 = 0x1E1E2EFF;
        const overlay_fg: u32 = 0xCDD6F4FF;
        const selected_bg: u32 = 0x45475AFF;
        const selected_fg: u32 = 0x89B4FAFF;

        const prompt_row = if (self.rows > 0) self.rows - 1 else 0;
        const start_row = if (prompt_row >= items_to_show) prompt_row - items_to_show else 0;

        var r: usize = 0;
        while (r < items_to_show) : (r += 1) {
            const target_row = start_row + r;
            if (target_row >= self.rows) break;

            const item = self.prompt.completion_items.items[r];
            const is_sel = (r == self.prompt.completion_selected);
            const fg = if (is_sel) selected_fg else overlay_fg;
            const bg = if (is_sel) selected_bg else overlay_bg;

            var item_buf: [128]u8 = undefined;
            const prefix = if (is_sel) "▶ " else "  ";
            const row_text = std.fmt.bufPrint(&item_buf, "{s}{s}", .{ prefix, item }) catch item;

            var c: usize = 0;
            while (c < overlay_w) : (c += 1) {
                const canvas_idx = target_row * self.cols + (start_col + c);
                const ch: u32 = if (c < row_text.len) row_text[c] else ' ';
                self.compositor.canvas[canvas_idx] = .{
                    .codepoint = ch,
                    .fg_rgba = fg,
                    .bg_rgba = bg,
                    .bold = is_sel,
                };
            }
        }
    }

    const target = self.window.acquireRenderTarget() catch return;
    errdefer self.window.cancelRender(target.buffer);

    const stride: u31 = target.width;

    var maybe_cursor: ?TcOverlayRenderer.Cursor = null;
    if (is_xpty_active) {
        if (active_job) |job| {
            const x = job.xpty;
            const cur_col = x.cursor_col;
            const cur_row = x.cursor_row;
            if (x.cursor_visible and cur_col < self.cols and cur_row < self.rows) {
                maybe_cursor = .{
                    .col = cur_col,
                    .row = cur_row,
                    .visible = true,
                };
            }
        }
    } else {
        const cur_col = self.prompt.getCursorScreenCol();
        if (cur_col < self.cols and self.rows > 0) {
            maybe_cursor = .{
                .col = @intCast(cur_col),
                .row = self.rows - 1,
                .visible = true,
            };
        }
    }

    TcOverlayRenderer.renderCanvas(
        self.allocator,
        &self.font,
        self.compositor.canvas,
        self.cols,
        self.rows,
        target.pixels,
        stride,
        target.width,
        target.height,
        maybe_cursor,
        self.compositor.theme_cursor_rgba,
    );

    self.window.commitRender(target.buffer, .full) catch {
        self.window.cancelRender(target.buffer);
    };
    self.needs_render = false;
}

pub fn run(self: *TcShellApp) !void {
    const display = self.window.display;

    self.render();

    while (self.running and self.window.running) {
        const job_count = self.jobs.items.len;
        var fds_buf: [20]posix.pollfd = undefined;
        fds_buf[0] = .{
            .fd = display.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };
        fds_buf[1] = .{
            .fd = self.client.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };
        fds_buf[2] = .{
            .fd = self.repeat_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        fds_buf[3] = .{
            .fd = if (self.signal_fd >= 0) self.signal_fd else -1,
            .events = if (self.signal_fd >= 0) posix.POLL.IN else 0,
            .revents = 0,
        };

        const poll_jobs = @min(job_count, 16);
        for (0..poll_jobs) |i| {
            const j = &self.jobs.items[i];
            const pty_fd = if (j.xpty.pty) |p| p.master else -1;
            fds_buf[4 + i] = .{
                .fd = pty_fd,
                .events = if (pty_fd >= 0) posix.POLL.IN else 0,
                .revents = 0,
            };
        }

        const total_poll_fds = 4 + poll_jobs;
        const poll_fds = fds_buf[0..total_poll_fds];

        while (!display.prepareRead()) {
            _ = display.dispatchPending();
            self.window.flushPending();
        }
        _ = display.flush();

        while (!self.client.display.prepareRead()) {
            self.client.dispatchPending();
        }
        _ = self.client.display.flush();

        const poll_res = posix.poll(poll_fds, 20) catch |err| {
            display.cancelRead();
            self.client.display.cancelRead();
            if (err == error.Interrupted) continue;
            break;
        };
        _ = poll_res;

        if (fds_buf[0].revents & posix.POLL.IN != 0) {
            _ = display.readEvents();
        } else {
            display.cancelRead();
        }
        _ = display.dispatchPending();
        self.window.flushPending();

        if (fds_buf[1].revents & posix.POLL.IN != 0) {
            _ = self.client.display.readEvents();
        } else {
            self.client.display.cancelRead();
        }
        self.client.dispatchPending();

        if (fds_buf[2].revents & posix.POLL.IN != 0) {
            self.fireRepeat();
        }

        if (self.signal_fd >= 0 and fds_buf[3].revents & posix.POLL.IN != 0) {
            var info: std.os.linux.signalfd_siginfo = undefined;
            while (true) {
                const n = posix.read(self.signal_fd, std.mem.asBytes(&info)) catch break;
                if (n == 0) break;
            }
        }

        var job_idx: usize = self.jobs.items.len;
        while (job_idx > 0) {
            job_idx -= 1;
            const j = &self.jobs.items[job_idx];
            if (job_idx < poll_jobs) {
                const revents = fds_buf[4 + job_idx].revents;
                if ((revents & posix.POLL.IN) != 0) {
                    if (j.xpty.pollPty()) {
                        self.needs_render = true;
                    }
                }
                if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                    const bid = j.block_id;
                    self.closeJob(bid, 0);
                    continue;
                }
            }

            // Dynamic promotion / demotion based on Ghostty VT alt-screen (only when not suspended and not demoted by user)
            if (j.xpty.isAlternateScreen() and !j.is_fullscreen and !j.suspended and !j.user_demoted) {
                j.is_fullscreen = true;
                j.is_interactive = true;
                j.promoted_by_alt_screen = true;
                j.xpty.is_visible = true;
                self.active_job_id = j.block_id;
                self.prompt.setPosition(0, -100);
                j.xpty.setPosition(0, 0);
                j.xpty.resize(self.cols, self.rows) catch {};
                j.xpty.commit() catch {};
                _ = self.client.display.flush();
                self.needs_render = true;
            } else if (!j.xpty.isAlternateScreen() and j.is_fullscreen and j.promoted_by_alt_screen and !j.suspended) {
                j.is_fullscreen = false;
                j.promoted_by_alt_screen = false;
                j.user_demoted = false;
                j.xpty.is_visible = false;
                self.active_job_id = null;
                self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
                j.xpty.setPosition(0, -100);
                _ = self.client.display.flush();
                self.needs_render = true;
            } else if (!j.xpty.isAlternateScreen() and j.user_demoted and !j.is_fullscreen) {
                j.user_demoted = false;
            }

            if (j.xpty.checkChildExited()) |st| {
                _ = j.xpty.pollPty();
                const bid = j.block_id;
                self.closeJob(bid, Xpty.statusToExitCode(st));
            }
        }

        if (self.needs_render or self.compositor.dirty) {
            self.render();
        }
    }
}

fn onResize(ctx: *anyopaque, width: u31, height: u31) anyerror!void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    const new_cols: u32 = @max(20, @as(u32, @intCast(width / self.font.cell_width)));
    const new_rows: u32 = @max(4, @as(u32, @intCast(height / self.font.cell_height)));

    if (new_cols != self.cols or new_rows != self.rows) {
        self.cols = new_cols;
        self.rows = new_rows;
        try self.compositor.resize(new_cols, new_rows);
        try self.prompt.resize(new_cols);

        const is_fullscreen = self.active_job_id != null or blk: {
            for (self.blocks.items) |b| {
                if (b.fullscreen) break :blk true;
            }
            break :blk false;
        };

        if (is_fullscreen) {
            self.prompt.setPosition(0, -100);
        } else {
            self.prompt.setPosition(0, @as(i32, @intCast(new_rows - 1)));
        }

        for (self.jobs.items) |j| {
            if (j.is_fullscreen and !j.suspended) {
                j.xpty.setPosition(0, 0);
                try j.xpty.resize(new_cols, new_rows);
            } else {
                j.xpty.setPosition(0, -100);
                const emb_rows = self.getEmbeddedJobRows();
                try j.xpty.resize(new_cols, emb_rows);
            }
        }
        _ = self.client.display.flush();
    }
    self.needs_render = true;
}

fn onKeyboard(ctx: *anyopaque, event: wl.Keyboard.Event) void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    switch (event) {
        .keymap => |keymap| {
            if (keymap.format != .xkb_v1) {
                _ = linux.close(keymap.fd);
                return;
            }
            self.keyboard.setKeymap(keymap.fd, keymap.size) catch {};
        },
        .modifiers => |mods| {
            self.keyboard.updateMods(
                mods.mods_depressed,
                mods.mods_latched,
                mods.mods_locked,
                mods.group,
            );
        },
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
            if (self.repeat_keycode) |keycode| {
                if (repeatTimerSpec(info.rate, info.delay)) |_|
                    self.armRepeat(keycode)
                else
                    self.cancelRepeat();
            }
        },
        .leave => {
            self.cancelRepeat();
            self.keyboard.resetCompose();
        },
        .enter => |enter| {
            self.last_serial = enter.serial;
        },
    }
}

pub fn onKey(self: *TcShellApp, keycode: u32, action: vt.input.KeyAction) void {
    var utf8_buf: [32]u8 = undefined;
    const k_event = self.keyboard.translate(&utf8_buf, keycode, action) orelse return;

    // 1. If an active xpty program is running in foreground, forward input directly
    if (self.getActiveJob()) |job| {
        if (!job.suspended) {
            // Ctrl+Z: Demote active interactive xpty program into embedded block and return to prompt
            const is_ctrl_z = (action == .press or action == .repeat) and ((k_event.mods.ctrl and (k_event.key == .key_z or k_event.unshifted_codepoint == 'z' or k_event.unshifted_codepoint == 'Z')) or
                (k_event.utf8.len == 1 and k_event.utf8[0] == 0x1a));
            if (is_ctrl_z) {
                self.cancelRepeat();
                self.demoteActiveJob();
                return;
            }

            // Ctrl+Shift+C: Copy selection or full screen
            if (action == .press and k_event.mods.ctrl and k_event.mods.shift and (k_event.unshifted_codepoint == 'c' or k_event.unshifted_codepoint == 'C')) {
                if (self.selection_active) {
                    if (self.extractSelectedText()) |text| {
                        defer self.allocator.free(text);
                        if (text.len > 0) self.copyToClipboard(text);
                    } else |_| {}
                } else {
                    if (self.extractScreenText()) |text| {
                        defer self.allocator.free(text);
                        if (text.len > 0) self.copyToClipboard(text);
                    } else |_| {}
                }
                return;
            }

            if (action == .press or action == .repeat) {
                var out_buf: [128]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&out_buf);
                vt.input.encodeKey(&writer, k_event, .fromTerminal(&job.xpty.term)) catch {
                    if (k_event.utf8.len > 0) {
                        job.xpty.sendInput(k_event.utf8) catch {};
                        self.needs_render = true;
                    }
                    return;
                };
                const bytes = writer.buffered();
                if (bytes.len > 0) {
                    job.xpty.sendInput(bytes) catch {};
                    self.needs_render = true;
                }
            }
            return;
        }
    }

    // 2. No foreground interactive job: prompt and stationary canvas controls
    if (action == .press) {
        // Ctrl+Z fallback: demote any fullscreen job
        if ((k_event.mods.ctrl and (k_event.key == .key_z or k_event.unshifted_codepoint == 'z' or k_event.unshifted_codepoint == 'Z')) or
            (k_event.utf8.len == 1 and k_event.utf8[0] == 0x1a))
        {
            var i = self.jobs.items.len;
            while (i > 0) {
                i -= 1;
                if (!self.jobs.items[i].suspended and self.jobs.items[i].is_fullscreen) {
                    self.active_job_id = self.jobs.items[i].block_id;
                    self.demoteActiveJob();
                    return;
                }
            }
        }

        // Escape or 'q' to exit fullscreen block if one is zoomed
        if (k_event.key == .escape or (k_event.unshifted_codepoint == 'q' and self.prompt.input_buf.items.len == 0)) {
            var was_fullscreen = false;
            for (self.blocks.items) |b| {
                if (b.fullscreen) {
                    b.fullscreen = false;
                    was_fullscreen = true;
                }
            }
            if (was_fullscreen) {
                self.prompt.setPosition(0, @as(i32, @intCast(self.rows - 1)));
                _ = self.client.display.flush();
                self.needs_render = true;
                return;
            }
        }

        // Ctrl+Shift+C: Copy selection or full screen
        if (k_event.mods.ctrl and k_event.mods.shift and (k_event.unshifted_codepoint == 'c' or k_event.unshifted_codepoint == 'C')) {
            if (self.selection_active) {
                if (self.extractSelectedText()) |text| {
                    defer self.allocator.free(text);
                    if (text.len > 0) self.copyToClipboard(text);
                } else |_| {}
            } else {
                if (self.extractScreenText()) |text| {
                    defer self.allocator.free(text);
                    if (text.len > 0) self.copyToClipboard(text);
                } else |_| {}
            }
            return;
        }

        // Ctrl+C: If selection active, copy and dismiss; otherwise clear prompt input
        if (k_event.mods.ctrl and k_event.unshifted_codepoint == 'c') {
            if (self.selection_active) {
                if (self.extractSelectedText()) |text| {
                    defer self.allocator.free(text);
                    if (text.len > 0) self.copyToClipboard(text);
                } else |_| {}
                self.selection_active = false;
                self.selecting = false;
                self.needs_render = true;
                return;
            }
            self.prompt.input_buf.clearRetainingCapacity();
            self.prompt.cursor_pos = 0;
            self.prompt.dismissCompletion();
            self.prompt.render();
            self.prompt.commit() catch {};
            self.needs_render = true;
            return;
        }

        // Ctrl+F: Accept ghost text auto-suggestion
        if (k_event.mods.ctrl and k_event.unshifted_codepoint == 'f') {
            if (self.prompt.getGhostSuggestion()) |ghost| {
                self.prompt.input_buf.appendSlice(self.allocator, ghost) catch {};
                self.prompt.cursor_pos = self.prompt.input_buf.items.len;
                self.prompt.render();
                self.prompt.commit() catch {};
                self.needs_render = true;
                return;
            }
        }
    }

    // Stationary prompt (always focused)
    if (action == .press or action == .repeat) {
        // PageUp / PageDown or Shift+Up / Shift+Down for scrolling history
        if (k_event.key == .page_up or k_event.key == .numpad_page_up or (k_event.mods.shift and k_event.key == .arrow_up)) {
            const delta: i32 = if (k_event.key == .arrow_up) 3 else @intCast(@max(1, self.rows / 2));
            self.scrollLines(-delta);
            return;
        }
        if (k_event.key == .page_down or k_event.key == .numpad_page_down or (k_event.mods.shift and k_event.key == .arrow_down)) {
            const delta: i32 = if (k_event.key == .arrow_down) 3 else @intCast(@max(1, self.rows / 2));
            self.scrollLines(delta);
            return;
        }

        // Any typing dismisses previous mouse selection
        if (self.selection_active) {
            self.selection_active = false;
            self.needs_render = true;
        }
        // Pressing Enter on empty prompt brings view back to bottom
        if (k_event.key == .enter and self.prompt.input_buf.items.len == 0) {
            self.scroll_offset = 0;
            self.pinned_block_id = null;
        }

        const key_str = switch (k_event.key) {
            .enter => "Enter",
            .tab => "Tab",
            .escape => "Escape",
            .backspace => "BackSpace",
            .delete => "Delete",
            .arrow_left => "Left",
            .arrow_right => "Right",
            .arrow_up => "Up",
            .arrow_down => "Down",
            .home => "Home",
            .end => "End",
            else => "",
        };

        const maybe_cmd = self.prompt.handleKey(key_str, k_event.utf8) catch null;
        if (maybe_cmd) |cmd| {
            defer self.allocator.free(cmd);
            self.cancelRepeat();
            self.launchCommand(cmd) catch {};
        }
        self.needs_render = true;
    }
}

fn onPointer(ctx: *anyopaque, event: wl.Pointer.Event) void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    switch (event) {
        .enter => |enter| {
            self.pointer_x = enter.surface_x.toDouble();
            self.pointer_y = enter.surface_y.toDouble();
        },
        .motion => |motion| {
            self.pointer_x = motion.surface_x.toDouble();
            self.pointer_y = motion.surface_y.toDouble();
            const px = @as(i32, @intFromFloat(self.pointer_x));
            const py = @as(i32, @intFromFloat(self.pointer_y));
            if (self.selecting) {
                const cell_w = @max(1, self.font.cell_width);
                const cell_h = @max(1, self.font.cell_height);
                const col: u32 = @min(self.cols - 1, @as(u32, @intCast(@max(0, px))) / cell_w);
                const row: u32 = @min(self.rows - 1, @as(u32, @intCast(@max(0, py))) / cell_h);
                if (col != self.sel_end_col or row != self.sel_end_row) {
                    self.sel_end_col = col;
                    self.sel_end_row = row;
                    self.selection_active = true;
                    self.needs_render = true;
                }
            }
            if (self.compositor.pointerMotion(px, py)) {
                self.needs_render = true;
            }
        },
        .button => |btn| {
            self.last_serial = btn.serial;
            const pressed = btn.state == .pressed;
            const px = @as(i32, @intFromFloat(self.pointer_x));
            const py = @as(i32, @intFromFloat(self.pointer_y));
            if (btn.button == 0x110) { // BTN_LEFT
                const cell_w = @max(1, self.font.cell_width);
                const cell_h = @max(1, self.font.cell_height);
                const col: u32 = @min(self.cols - 1, @as(u32, @intCast(@max(0, px))) / cell_w);
                const row: u32 = @min(self.rows - 1, @as(u32, @intCast(@max(0, py))) / cell_h);
                if (pressed) {
                    self.selecting = true;
                    self.selection_active = false;
                    self.sel_start_col = col;
                    self.sel_start_row = row;
                    self.sel_end_col = col;
                    self.sel_end_row = row;
                    self.needs_render = true;
                } else {
                    if (self.selecting) {
                        self.selecting = false;
                        if (self.selection_active) {
                            if (self.extractSelectedText()) |text| {
                                defer self.allocator.free(text);
                                if (text.len > 0) {
                                    self.copyToClipboard(text);
                                }
                            } else |_| {}
                        } else {
                            // Single click without drag: toggle fold on clicked block header
                            self.toggleBlockAtRow(row);
                        }
                    }
                }
            }
            if (self.compositor.pointerButton(px, py, pressed)) {
                self.needs_render = true;
            }
        },
        .axis => |axis| {
            if (axis.axis == .vertical_scroll and !self.scroll_had_discrete and !self.scroll_had_value120) {
                self.scroll_pixels += axis.value.toDouble();
                self.scroll_had_pixels = true;
            }
            if (!self.window.pointerHasFrames()) self.finishScrollFrame();
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
        else => {},
    }
}

fn onTextInput(_: *anyopaque, _: wayland.client.zwp.TextInputV3.Event) void {}

fn onScale(ctx: *anyopaque, scale120: u32) anyerror!void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    const size_px = Config.fontSizePixels(.{ .points = 13 }, scale120);
    if (size_px == 0 or size_px == self.font_size_px) return;

    const new_font = try Font.init(self.allocator, "monospace", size_px);
    self.font.deinit(self.allocator);
    self.font = new_font;
    self.font_size_px = size_px;

    self.compositor.cell_width_px = self.font.cell_width;
    self.compositor.cell_height_px = self.font.cell_height;

    if (self.window.width > 0 and self.window.height > 0) {
        try onResize(ctx, self.window.width, self.window.height);
    }
    self.needs_render = true;
}

fn onRedrawReady(ctx: *anyopaque) void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    self.needs_render = true;
}
