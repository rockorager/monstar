//! Opt-in per-frame telemetry for benchmarks (`MONSTAR_FRAME_TELEMETRY=path`).
//!
//! Each line of the output file is one JSON object. `start` opens the file,
//! `path` names the effective renderer and presentation path whenever it
//! changes (a Vulkan renderer may start on the CPU path and switch), `clock` reports the wp_presentation clock, `key` marks wl_keyboard
//! key presses as Monstar receives them, and `frame` describes one committed
//! frame once the compositor reports it presented or discarded. All times
//! are CLOCK_MONOTONIC nanoseconds; presentation timestamps use the
//! compositor's clock, which `clock` names (1 is CLOCK_MONOTONIC).
//!
//! When telemetry is off, Window holds no FrameTelemetry, binds no
//! wp_presentation, and every hook is a null check.
const FrameTelemetry = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const linux = std.os.linux;

const log = std.log.scoped(.frame_telemetry);

pub const env_var = "MONSTAR_FRAME_TELEMETRY";

/// Committed frames awaiting feedback. Frame callbacks keep at most a few in
/// flight; a slot still waiting when reused has its feedback dropped.
const slot_count = 16;

alloc: std.mem.Allocator,
fd: linux.fd_t,
presentation: ?*wp.Presentation = null,
renderer: []const u8 = "",
presentation_path: []const u8 = "",
/// Main-thread time the in-flight render was submitted, and the time its
/// result came back. Monstar renders at most one frame at a time.
render_start: u64 = 0,
render_done: u64 = 0,
/// Reads a committed frame's GPU time; set while a GPU renderer draws.
gpu_time: ?GpuTime = null,
/// Token that `gpu_time` takes for the next commit; 0 for none.
gpu_token: u64 = 0,
last_presented: u64 = 0,
next_id: u64 = 1,
next_slot: usize = 0,
slots: [slot_count]Slot = @splat(.{}),

/// GPU time in ns of the frame identified by `token`, or null when the
/// renderer cannot tell. Called when the frame's feedback arrives.
pub const GpuTime = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, token: u64) ?u64,
};

const Slot = struct {
    owner: ?*FrameTelemetry = null,
    gpu_token: u64 = 0,
    feedback: ?*wp.PresentationFeedback = null,
    id: u64 = 0,
    start: u64 = 0,
    done: u64 = 0,
    commit: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Open `path` for writing (truncating it). Returns null and logs when the
/// file cannot be opened so a bad path never prevents startup.
pub fn create(alloc: std.mem.Allocator, path: [:0]const u8) ?*FrameTelemetry {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) {
        log.warn("cannot open {s}: {t}", .{ path, linux.errno(rc) });
        return null;
    }
    const self = alloc.create(FrameTelemetry) catch {
        _ = linux.close(@intCast(rc));
        return null;
    };
    self.* = .{ .alloc = alloc, .fd = @intCast(rc) };
    self.print("{{\"ev\":\"start\",\"t\":{d},\"pid\":{d}}}\n", .{ now(), linux.getpid() });
    return self;
}

/// Destroy protocol objects. Call before the display disconnects.
pub fn releaseProtocol(self: *FrameTelemetry) void {
    for (&self.slots) |*slot| {
        if (slot.feedback) |feedback| feedback.destroy();
        slot.feedback = null;
    }
    if (self.presentation) |presentation| presentation.destroy();
    self.presentation = null;
}

pub fn destroy(self: *FrameTelemetry) void {
    self.releaseProtocol();
    _ = linux.close(self.fd);
    self.alloc.destroy(self);
}

pub fn setPresentation(self: *FrameTelemetry, presentation: *wp.Presentation) void {
    std.debug.assert(self.presentation == null);
    self.presentation = presentation;
    presentation.setListener(*FrameTelemetry, presentationListener, self);
}

pub fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Record the renderer and presentation path in effect; only a change
/// writes a line. Both strings must outlive the telemetry (use literals).
pub fn notePath(self: *FrameTelemetry, renderer: []const u8, presentation: []const u8) void {
    if (std.mem.eql(u8, renderer, self.renderer) and std.mem.eql(u8, presentation, self.presentation_path)) return;
    self.renderer = renderer;
    self.presentation_path = presentation;
    self.print("{{\"ev\":\"path\",\"t\":{d},\"renderer\":\"{s}\",\"presentation\":\"{s}\"}}\n", .{ now(), renderer, presentation });
}

pub fn renderSubmitted(self: *FrameTelemetry, start: u64) void {
    self.render_start = start;
    self.render_done = 0;
}

pub fn renderFinished(self: *FrameTelemetry) void {
    self.render_done = now();
}

/// Identify the GPU work of the next commit for `gpu_time`.
pub fn setGpuToken(self: *FrameTelemetry, token: u64) void {
    self.gpu_token = token;
}

pub fn keyPressed(self: *FrameTelemetry, key: u32) void {
    self.print("{{\"ev\":\"key\",\"t\":{d},\"key\":{d}}}\n", .{ now(), key });
}

/// Request feedback for the content update about to be committed on
/// `surface`. Call immediately before wl_surface.commit.
pub fn beforeCommit(self: *FrameTelemetry, surface: *wl.Surface, width: u32, height: u32) void {
    const slot = &self.slots[self.next_slot];
    self.next_slot = (self.next_slot + 1) % slot_count;
    if (slot.feedback) |stale| {
        stale.destroy();
        self.writeFrame(slot, .{ .lost = {} });
    }
    slot.* = .{
        .owner = self,
        .id = self.next_id,
        .start = self.render_start,
        .done = self.render_done,
        .commit = now(),
        .width = width,
        .height = height,
        .gpu_token = self.gpu_token,
    };
    self.next_id += 1;
    self.render_start = 0;
    self.render_done = 0;
    self.gpu_token = 0;
    const presentation = self.presentation orelse {
        self.writeFrame(slot, .{ .lost = {} });
        return;
    };
    const feedback = presentation.feedback(surface) catch {
        self.writeFrame(slot, .{ .lost = {} });
        return;
    };
    slot.feedback = feedback;
    feedback.setListener(*Slot, feedbackListener, slot);
}

const Presented = struct {
    time: u64,
    refresh: u32,
    msc: u64,
    flags: u32,
};

const Outcome = union(enum) {
    presented: Presented,
    discarded,
    /// No feedback will arrive: no wp_presentation, or the slot was reused.
    lost,
};

/// Refreshes skipped before `present`: only counted when the frame was
/// already rendering by the time the previous frame reached the screen, so
/// a continuous stream of content should advance one refresh per frame.
fn missedRefreshes(start: u64, previous: u64, present: u64, refresh: u32) u64 {
    if (refresh == 0 or previous == 0 or start == 0 or start > previous or present <= previous) return 0;
    const intervals = (present - previous + refresh / 2) / refresh;
    return intervals -| 1;
}

fn feedbackListener(feedback: *wp.PresentationFeedback, event: wp.PresentationFeedback.Event, slot: *Slot) void {
    const self = slot.owner.?;
    std.debug.assert(slot.feedback == feedback);
    // sync_output precedes presented on the same object; keep it alive.
    if (event == .sync_output) return;
    feedback.destroy();
    slot.feedback = null;
    switch (event) {
        .sync_output => unreachable,
        .presented => |p| {
            const sec = (@as(u64, p.tv_sec_hi) << 32) | p.tv_sec_lo;
            self.writeFrame(slot, .{ .presented = .{
                .time = sec * std.time.ns_per_s + p.tv_nsec,
                .refresh = p.refresh,
                .msc = (@as(u64, p.seq_hi) << 32) | p.seq_lo,
                .flags = @as(u32, @bitCast(p.flags)),
            } });
        },
        .discarded => self.writeFrame(slot, .discarded),
    }
}

fn presentationListener(_: *wp.Presentation, event: wp.Presentation.Event, self: *FrameTelemetry) void {
    switch (event) {
        .clock_id => |clock| self.print("{{\"ev\":\"clock\",\"id\":{d}}}\n", .{clock.clk_id}),
    }
}

fn writeFrame(self: *FrameTelemetry, slot: *const Slot, outcome: Outcome) void {
    var buf: [384]u8 = undefined;
    var head = std.fmt.bufPrint(&buf, "{{\"ev\":\"frame\",\"id\":{d},\"start\":{d},\"render_done\":{d},\"commit\":{d},\"w\":{d},\"h\":{d}", .{
        slot.id, slot.start, slot.done, slot.commit, slot.width, slot.height,
    }) catch unreachable;
    if (outcome == .presented and slot.gpu_token != 0) {
        if (self.gpu_time) |gpu| {
            if (gpu.read(gpu.ctx, slot.gpu_token)) |ns| {
                head = buf[0 .. head.len + (std.fmt.bufPrint(buf[head.len..], ",\"gpu_ns\":{d}", .{ns}) catch unreachable).len];
            }
        }
    }
    const tail = switch (outcome) {
        .presented => |p| tail: {
            const missed = missedRefreshes(slot.start, self.last_presented, p.time, p.refresh);
            self.last_presented = p.time;
            break :tail std.fmt.bufPrint(buf[head.len..], ",\"present\":{d},\"refresh\":{d},\"msc\":{d},\"flags\":{d},\"missed\":{d}}}\n", .{
                p.time, p.refresh, p.msc, p.flags, missed,
            }) catch unreachable;
        },
        .discarded => std.fmt.bufPrint(buf[head.len..], ",\"discarded\":true}}\n", .{}) catch unreachable,
        .lost => std.fmt.bufPrint(buf[head.len..], ",\"lost\":true}}\n", .{}) catch unreachable,
    };
    self.writeAll(buf[0 .. head.len + tail.len]);
}

fn print(self: *FrameTelemetry, comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, format, args) catch return;
    self.writeAll(line);
}

/// One write per line keeps lines whole for a reader tailing the file.
fn writeAll(self: *FrameTelemetry, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(self.fd, bytes.ptr + offset, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => offset += rc,
            .INTR => {},
            else => return,
        }
    }
}

test "missed refreshes count only frames pending at the previous presentation" {
    const r: u32 = 16_666_667;
    const p0: u64 = 1_000_000_000;
    // Rendering began before the previous frame was shown: one refresh later
    // is on time, two refreshes later misses one.
    try std.testing.expectEqual(@as(u64, 0), missedRefreshes(p0 - 5_000_000, p0, p0 + r, r));
    try std.testing.expectEqual(@as(u64, 1), missedRefreshes(p0 - 5_000_000, p0, p0 + 2 * r, r));
    try std.testing.expectEqual(@as(u64, 3), missedRefreshes(p0, p0, p0 + 4 * r + 2_000_000, r));
    // Content that went dirty after the previous frame was shown (typing,
    // idle gaps) is not a missed refresh however long the gap.
    try std.testing.expectEqual(@as(u64, 0), missedRefreshes(p0 + 1, p0, p0 + 30 * r, r));
    // Unknown refresh, first frame, and unrendered commits count nothing.
    try std.testing.expectEqual(@as(u64, 0), missedRefreshes(p0 - 1, p0, p0 + 3 * r, 0));
    try std.testing.expectEqual(@as(u64, 0), missedRefreshes(p0 - 1, 0, p0 + 3 * r, r));
    try std.testing.expectEqual(@as(u64, 0), missedRefreshes(0, p0, p0 + 3 * r, r));
}

test "presented frames with a GPU token report the renderer's GPU time" {
    const rc = linux.memfd_create("telemetry-test", 0);
    try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
    var telemetry: FrameTelemetry = .{ .alloc = std.testing.allocator, .fd = @intCast(rc) };
    defer _ = linux.close(telemetry.fd);
    const Fake = struct {
        fn read(_: *anyopaque, token: u64) ?u64 {
            return if (token == 7) 512_000 else null;
        }
    };
    var ctx: u8 = 0;
    telemetry.gpu_time = .{ .ctx = &ctx, .read = Fake.read };
    const presented: Outcome = .{ .presented = .{ .time = 5, .refresh = 0, .msc = 0, .flags = 0 } };
    telemetry.writeFrame(&.{ .id = 1, .gpu_token = 7 }, presented);
    telemetry.writeFrame(&.{ .id = 2, .gpu_token = 7 }, .discarded);
    telemetry.writeFrame(&.{ .id = 3, .gpu_token = 8 }, presented);
    telemetry.writeFrame(&.{ .id = 4 }, presented);

    var buf: [1024]u8 = undefined;
    const n = linux.pread(telemetry.fd, &buf, buf.len, 0);
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, ",\"gpu_ns\":512000,\"present\":5") != null);
    for (0..3) |_| try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "gpu_ns") == null);
}
