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

extern "c" fn popen(command: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fgets(s: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;

allocator: std.mem.Allocator,
window: *Window,
font: Font,
keyboard: Keyboard,
compositor: *Compositor,
client: *Client,
prompt: *PromptSurface,
session: *SessionState,

// Active running interactive child (if any)
xpty: ?*Xpty = null,

// Command blocks for pipeline / non-interactive commands
blocks: std.ArrayList(*CommandBlock) = .empty,

cols: u32,
rows: u32,
running: bool = true,
needs_render: bool = true,

pointer_x: f64 = 0,
pointer_y: f64 = 0,
last_serial: u32 = 0,

pub fn init(allocator: std.mem.Allocator) !*TcShellApp {
    const font_size_px = 15;
    var font = try Font.init(allocator, "monospace", font_size_px);
    errdefer font.deinit(allocator);

    const initial_w: u31 = 900;
    const initial_h: u31 = 600;

    const cols: u32 = @max(20, @as(u32, @intCast(initial_w / font.cell_width)));
    const rows: u32 = @max(10, @as(u32, @intCast(initial_h / font.cell_height)));

    const window = try Window.create(allocator, "dev.rockorager.monstar-tc-shell", "tc-shell (TC-Wayland)", .{
        .width = initial_w,
        .height = initial_h,
    });
    errdefer window.destroy();

    var keyboard = try Keyboard.init();
    errdefer keyboard.deinit();

    // 1. In-process session state
    var session = try SessionState.init(allocator);
    errdefer session.deinit();

    // 2. TC-Wayland Compositor
    var comp = try Compositor.init(allocator, null, cols, rows);
    errdefer comp.deinit();
    comp.cell_width_px = font.cell_width;
    comp.cell_height_px = font.cell_height;

    // 3. Direct client connection
    var cl = try comp.createDirectClient();
    errdefer cl.deinit();

    // 4. Stationary prompt at row 0 (always focused)
    var prompt_surf = try PromptSurface.init(allocator, cl, cols);
    errdefer prompt_surf.deinit();
    prompt_surf.setFocus(true);
    prompt_surf.setSession(session);

    const self = try allocator.create(TcShellApp);
    self.* = .{
        .allocator = allocator,
        .window = window,
        .font = font,
        .keyboard = keyboard,
        .compositor = comp,
        .client = cl,
        .prompt = prompt_surf,
        .session = session,
        .blocks = .empty,
        .cols = cols,
        .rows = rows,
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
    self.compositor.stop();

    if (self.xpty) |x| {
        x.deinit();
        self.xpty = null;
    }

    for (self.blocks.items) |b| {
        b.deinit();
    }
    self.blocks.deinit(self.allocator);

    self.prompt.deinit();
    self.session.deinit();
    self.client.deinit();
    self.compositor.deinit();
    self.keyboard.deinit();
    self.font.deinit(self.allocator);
    self.window.destroy();
    self.allocator.destroy(self);
}

/// Checks if command is typically an interactive fullscreen/TUI tool.
fn isInteractiveCommand(cmd: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, cmd, " \t");
    const bin = iter.next() orelse return false;
    const base = if (std.mem.lastIndexOfScalar(u8, bin, '/')) |idx| bin[idx + 1 ..] else bin;

    const interactive = [_][]const u8{
        "vim",  "nvim", "vi", "emacs", "nano", "htop", "top",    "less", "more",
        "bash", "zsh",  "sh", "fish",  "tmux", "man",  "ranger", "yazi", "lazygit",
    };
    for (interactive) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

fn copyToClipboard(_: *TcShellApp, text: []const u8) void {
    if (popen("wl-copy", "w")) |pipe| {
        _ = std.c.fwrite(text.ptr, 1, text.len, @ptrCast(pipe));
        _ = pclose(pipe);
    }
}

pub fn launchInteractive(self: *TcShellApp, cmd: []const u8) !void {
    if (self.xpty) |x| {
        x.deinit();
        self.xpty = null;
    }

    const workspace_rows = if (self.rows > 1) self.rows - 1 else 1;
    var new_xpty = try Xpty.init(self.allocator, self.client, self.cols, workspace_rows);
    new_xpty.setPosition(0, 1);

    const cmd_z = try self.allocator.dupeZ(u8, cmd);
    defer self.allocator.free(cmd_z);

    const sh_z: [*:0]const u8 = "/bin/sh";
    const c_arg: [*:0]const u8 = "-c";
    const argv = [_:null]?[*:0]const u8{ sh_z, c_arg, cmd_z.ptr, null };

    new_xpty.spawnPty(sh_z, &argv, std.c.environ) catch {
        new_xpty.initSimulatedShell();
    };

    self.xpty = new_xpty;
    _ = self.client.display.flush();
    self.needs_render = true;
}

pub fn launchBlock(self: *TcShellApp, cmd: []const u8) !void {
    const block_id = self.session.allocateBlockId();
    var block = try CommandBlock.init(self.allocator, block_id, cmd);
    try self.blocks.append(self.allocator, block);

    var ts_start: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_start);

    // Redirection to capture stdout & stderr cleanly
    const cmd_with_err_slice = try std.fmt.allocPrint(self.allocator, "{s} 2>&1", .{cmd});
    defer self.allocator.free(cmd_with_err_slice);
    const cmd_with_err = try self.allocator.dupeZ(u8, cmd_with_err_slice);
    defer self.allocator.free(cmd_with_err);

    var exit_code: u8 = 0;
    if (popen(cmd_with_err.ptr, "r")) |pipe| {
        var buf: [4096]u8 = undefined;
        while (fgets(&buf, buf.len, pipe)) |_| {
            const line = std.mem.sliceTo(&buf, 0);
            if (line.len > 0) {
                try block.appendOutput(line);
            }
        }
        const status = pclose(pipe);
        if (status >= 0) {
            exit_code = @truncate(@as(u32, @intCast(status >> 8)));
        } else {
            exit_code = 1;
        }
    } else {
        try block.appendOutput("failed to execute command\n");
        exit_code = 127;
    }

    var ts_end: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_end);
    const start_ms = @as(u64, @intCast(ts_start.sec)) * 1000 + @as(u64, @intCast(ts_start.nsec)) / 1_000_000;
    const end_ms = @as(u64, @intCast(ts_end.sec)) * 1000 + @as(u64, @intCast(ts_end.nsec)) / 1_000_000;
    const elapsed: u64 = if (end_ms >= start_ms) end_ms - start_ms else 0;
    block.finish(exit_code, elapsed);

    self.needs_render = true;
}

pub fn launchCommand(self: *TcShellApp, raw_cmd: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw_cmd, " \t\r\n");
    if (trimmed.len == 0) return;

    // 1. Built-in command handling
    const builtin = SessionState.parseBuiltin(trimmed);
    switch (builtin) {
        .clear => {
            if (self.xpty) |x| {
                x.deinit();
                self.xpty = null;
            }
            for (self.blocks.items) |b| b.deinit();
            self.blocks.clearRetainingCapacity();
            self.needs_render = true;
            return;
        },
        .exit => {
            if (self.xpty != null) {
                self.closeActiveXpty();
            } else {
                self.running = false;
            }
            return;
        },
        .cd => |maybe_path| {
            self.session.changeDirectory(maybe_path) catch |err| {
                std.log.warn("cd failed: {s}", .{@errorName(err)});
            };
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
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                b.collapse();
            }
            self.needs_render = true;
            return;
        },
        .expand => |target| {
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                b.expand();
            }
            self.needs_render = true;
            return;
        },
        .fullscreen => |maybe_target| {
            if (maybe_target) |target| {
                if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                    b.fullscreen = !b.fullscreen;
                }
            } else if (self.xpty != null) {
                // Return to xpty fullscreen
            }
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
            if (SessionState.findBlockIndex(self.blocks.items, target)) |idx| {
                const removed = self.blocks.orderedRemove(idx);
                removed.deinit();
            }
            self.needs_render = true;
            return;
        },
        .copy => |info| {
            if (SessionState.resolveBlock(self.blocks.items, info.target)) |b| {
                const to_copy = if (info.is_cmd) b.command else b.getRawOutput();
                self.copyToClipboard(to_copy);
            }
            return;
        },
        .view => |target| {
            if (SessionState.resolveBlock(self.blocks.items, target)) |b| {
                if (b.getMemfd()) |fd| {
                    const view_cmd = try std.fmt.allocPrint(self.allocator, "less -R /proc/self/fd/{d}", .{fd});
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

    // 3. Dispatch interactive vs block
    if (isInteractiveCommand(cmd)) {
        try self.launchInteractive(cmd);
    } else {
        try self.launchBlock(cmd);
    }
}

pub fn closeActiveXpty(self: *TcShellApp) void {
    if (self.xpty) |x| {
        x.deinit();
        self.xpty = null;
        self.needs_render = true;
    }
}

pub fn render(self: *TcShellApp) void {
    if (self.window.width == 0 or self.window.suspended or self.window.rendering_pending or self.window.frame_pending) return;

    self.compositor.composite();

    // 1D Vertical Document Reflow
    if (self.xpty == null and self.blocks.items.len > 0) {
        var fullscreen_block: ?*CommandBlock = null;
        for (self.blocks.items) |b| {
            if (b.fullscreen) {
                fullscreen_block = b;
                break;
            }
        }

        const total_canvas_rows = self.rows;

        if (fullscreen_block) |fb| {
            var cur_row: usize = 1;
            const header_bg: u32 = 0x24273A00;
            const status_fg: u32 = switch (fb.status) {
                .success => 0xA6E3A100,
                .failed => 0xF38BA800,
                .running => 0xF9E2AF00,
            };

            var header_buf: [128]u8 = undefined;
            const status_str = if (fb.status == .success) "ok" else if (fb.status == .failed) "err" else "...";
            const header_text = std.fmt.bufPrint(&header_buf, "▶ [${d}] {s} [{s}] ({d}ms) [FULLSCREEN]", .{
                fb.id,
                fb.command,
                status_str,
                fb.elapsed_ms,
            }) catch "▶ command";

            for (header_text, 0..) |ch, col_idx| {
                if (col_idx >= self.cols) break;
                const dst_idx = cur_row * self.cols + col_idx;
                self.compositor.canvas[dst_idx] = .{
                    .codepoint = ch,
                    .fg_rgba = status_fg,
                    .bg_rgba = header_bg,
                    .bold = true,
                };
            }
            cur_row += 1;

            for (fb.output_lines.items) |line| {
                if (cur_row >= total_canvas_rows) break;
                for (line, 0..) |ch, col_idx| {
                    if (col_idx >= self.cols) break;
                    const dst_idx = cur_row * self.cols + col_idx;
                    self.compositor.canvas[dst_idx] = .{
                        .codepoint = ch,
                        .fg_rgba = self.compositor.theme_fg_rgba,
                        .bg_rgba = self.compositor.theme_bg_rgba,
                    };
                }
                cur_row += 1;
            }
        } else {
            var cur_row: usize = 1;
            for (self.blocks.items) |block| {
                if (cur_row >= total_canvas_rows) break;

                const header_bg: u32 = 0x24273A00;
                const status_fg: u32 = switch (block.status) {
                    .success => 0xA6E3A100,
                    .failed => 0xF38BA800,
                    .running => 0xF9E2AF00,
                };

                var header_buf: [128]u8 = undefined;
                const status_str = if (block.status == .success) "ok" else if (block.status == .failed) "err" else "...";
                const fold_icon = if (block.folded) "▼" else "▶";
                const header_text = std.fmt.bufPrint(&header_buf, "{s} [${d}] {s} [{s}] ({d}ms)", .{
                    fold_icon,
                    block.id,
                    block.command,
                    status_str,
                    block.elapsed_ms,
                }) catch "▶ command";

                for (header_text, 0..) |ch, col_idx| {
                    if (col_idx >= self.cols) break;
                    const dst_idx = cur_row * self.cols + col_idx;
                    self.compositor.canvas[dst_idx] = .{
                        .codepoint = ch,
                        .fg_rgba = status_fg,
                        .bg_rgba = header_bg,
                        .bold = true,
                    };
                }
                cur_row += 1;

                if (!block.folded) {
                    for (block.output_lines.items) |line| {
                        if (cur_row >= total_canvas_rows) break;
                        for (line, 0..) |ch, col_idx| {
                            if (col_idx >= self.cols) break;
                            const dst_idx = cur_row * self.cols + col_idx;
                            self.compositor.canvas[dst_idx] = .{
                                .codepoint = ch,
                                .fg_rgba = self.compositor.theme_fg_rgba,
                                .bg_rgba = self.compositor.theme_bg_rgba,
                            };
                        }
                        cur_row += 1;
                    }
                }
            }
        }
    }

    // Floating Tab Completion Overlay: renders above blocks directly below cursor
    if (self.prompt.completion_active and self.prompt.completion_items.items.len > 0) {
        const cursor_col = self.prompt.getCursorScreenCol();
        const start_col = @min(cursor_col, if (self.cols > 25) self.cols - 25 else 0);
        const overlay_w: usize = @min(30, self.cols - start_col);
        const items_to_show = @min(self.prompt.completion_items.items.len, 6);

        const overlay_bg: u32 = 0x1E1E2EFF;
        const overlay_fg: u32 = 0xCDD6F4FF;
        const selected_bg: u32 = 0x45475AFF;
        const selected_fg: u32 = 0x89B4FAFF;

        var r: usize = 0;
        while (r < items_to_show) : (r += 1) {
            const target_row = 1 + r;
            if (target_row >= self.rows) break;

            const item = self.prompt.completion_items.items[r];
            const is_sel = (r == self.prompt.completion_selected);
            const fg = if (is_sel) selected_fg else overlay_fg;
            const bg = if (is_sel) selected_bg else overlay_bg;

            var item_buf: [64]u8 = undefined;
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
        null,
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
        var fds: [3]posix.pollfd = undefined;
        fds[0] = .{
            .fd = display.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };

        var pty_fd: posix.fd_t = -1;
        if (self.xpty) |x| {
            if (x.pty) |p| {
                pty_fd = p.master;
                fds[1] = .{
                    .fd = pty_fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                };
            } else {
                fds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
            }
        } else {
            fds[1] = .{ .fd = -1, .events = 0, .revents = 0 };
        }

        fds[2] = .{
            .fd = self.client.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        };

        while (!display.prepareRead()) {
            _ = display.dispatchPending();
            self.window.flushPending();
        }
        _ = display.flush();

        while (!self.client.display.prepareRead()) {
            self.client.dispatchPending();
        }
        _ = self.client.display.flush();

        const poll_res = posix.poll(&fds, 20) catch |err| {
            display.cancelRead();
            self.client.display.cancelRead();
            if (err == error.Interrupted) continue;
            break;
        };
        _ = poll_res;

        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = display.readEvents();
        } else {
            display.cancelRead();
        }
        _ = display.dispatchPending();
        self.window.flushPending();

        if (fds[2].revents & posix.POLL.IN != 0) {
            _ = self.client.display.readEvents();
        } else {
            self.client.display.cancelRead();
        }
        self.client.dispatchPending();

        if (pty_fd >= 0 and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            if (self.xpty) |x| {
                if (x.pollPty()) {
                    self.needs_render = true;
                }
            }
            if (fds[1].revents & posix.POLL.HUP != 0) {
                self.closeActiveXpty();
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

        if (self.xpty) |x| {
            const workspace_rows = if (new_rows > 1) new_rows - 1 else 1;
            x.setPosition(0, 1);
            try x.resize(new_cols, workspace_rows);
        }
    }
    self.needs_render = true;
}

fn onKeyboard(ctx: *anyopaque, event: wl.Keyboard.Event) void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    switch (event) {
        .keymap => |keymap| {
            if (keymap.format != .xkb_v1) {
                _ = std.os.linux.close(keymap.fd);
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

            var utf8_buf: [32]u8 = undefined;
            const k_event = self.keyboard.translate(&utf8_buf, key.key, action) orelse return;

            // Ctrl+Z: Suspend active interactive xpty program and return to prompt
            if (action == .press and k_event.mods.ctrl and k_event.unshifted_codepoint == 'z' and self.xpty != null) {
                self.closeActiveXpty();
                return;
            }

            // Ctrl+C: Clear prompt input
            if (action == .press and k_event.mods.ctrl and k_event.unshifted_codepoint == 'c') {
                self.prompt.input_buf.clearRetainingCapacity();
                self.prompt.cursor_pos = 0;
                self.prompt.dismissCompletion();
                self.prompt.render();
                self.prompt.commit() catch {};
                self.needs_render = true;
                return;
            }

            // Ctrl+F: Accept ghost text auto-suggestion
            if (action == .press and k_event.mods.ctrl and k_event.unshifted_codepoint == 'f') {
                if (self.prompt.getGhostSuggestion()) |ghost| {
                    self.prompt.input_buf.appendSlice(self.allocator, ghost) catch {};
                    self.prompt.cursor_pos = self.prompt.input_buf.items.len;
                    self.prompt.render();
                    self.prompt.commit() catch {};
                    self.needs_render = true;
                    return;
                }
            }

            // If an active xpty program is running in foreground, forward input directly
            if (self.xpty) |x| {
                if (action == .press) {
                    var out_buf: [128]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&out_buf);
                    vt.input.encodeKey(&writer, k_event, .{}) catch {
                        if (k_event.utf8.len > 0) {
                            x.sendInput(k_event.utf8) catch {};
                            self.needs_render = true;
                        }
                        return;
                    };
                    const bytes = writer.buffered();
                    if (bytes.len > 0) {
                        x.sendInput(bytes) catch {};
                        self.needs_render = true;
                    }
                }
                return;
            }

            // Stationary prompt (always focused)
            if (action == .press) {
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
                    self.launchCommand(cmd) catch {};
                }
                self.needs_render = true;
            }
        },
        else => {},
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
            if (self.compositor.pointerMotion(px, py)) {
                self.needs_render = true;
            }
        },
        .button => |btn| {
            self.last_serial = btn.serial;
            const pressed = btn.state == .pressed;
            const px = @as(i32, @intFromFloat(self.pointer_x));
            const py = @as(i32, @intFromFloat(self.pointer_y));
            if (self.compositor.pointerButton(px, py, pressed)) {
                self.needs_render = true;
            }
        },
        else => {},
    }
}

fn onTextInput(_: *anyopaque, _: wayland.client.zwp.TextInputV3.Event) void {}

fn onScale(_: *anyopaque, _: u32) anyerror!void {}

fn onRedrawReady(ctx: *anyopaque) void {
    const self: *TcShellApp = @ptrCast(@alignCast(ctx));
    self.needs_render = true;
}
