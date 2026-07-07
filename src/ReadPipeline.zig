//! Two-stage PTY read pipeline, ported from Ghostty's io-gather design:
//! a gather thread drains the pty master into a small ring of large
//! buffers while the main loop parses the previous batch concurrently.
//! This lets the child keep producing while a batch is being parsed and
//! rendered, instead of blocking on the kernel pty queue.
//!
//! The ring is single-producer/single-consumer: the gather thread owns
//! `head`, the main thread owns `tail`, and the atomic `count` transfers
//! buffer ownership between them. Wakeups are fds so both sides keep
//! their existing poll loops: `ready_fd` (gather -> main, joins the main
//! poll set) and `slot_free_fd` (main -> gather, polled when the ring is
//! full). Backpressure is the bounded ring: when it is full the gather
//! thread stops reading and kernel pty flow control throttles the child.

const ReadPipeline = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.read_pipeline);

pub const buffer_count = 4;
pub const buffer_capacity = 64 * 1024;

/// Batches smaller than this are delivered on the first WouldBlock:
/// interactive trickles must not pay any coalescing latency.
const bridge_threshold = 1024;
/// Immediate read retries before falling back to poll while bridging
/// producer refill gaps on a saturated stream.
const bridge_spin_max = 16;
/// Poll timeout for each bridging attempt.
const bridge_poll_timeout_ms = 1;
/// Max total time one batch may spend bridging refill gaps: bounds
/// delivery latency while still coalescing bulk output into large
/// batches instead of ~1KiB kernel-queue drains.
const gather_budget_ns = 3 * std.time.ns_per_ms;

/// PTY master, owned by the caller. Must stay open until `stop`
/// (or `deinit`) has joined the gather thread.
master: posix.fd_t,
/// Wakes the main loop: bumped when a batch is published or the
/// suspended state changes. Nonblocking; polled in the main poll set.
ready_fd: posix.fd_t,
/// Wakes the gather thread when the main thread frees a ring slot.
slot_free_fd: posix.fd_t,
/// Wakes the gather thread from a bridge poll when the parser goes idle.
idle_fds: [2]posix.fd_t,
/// Wakes and stops the gather thread; read end is index 0.
quit_fds: [2]posix.fd_t,
thread: ?std.Thread,

/// Published, unconsumed batches. The producer increments with .release
/// after filling a slot; the consumer decrements with .release after
/// parsing one. The .acquire loads on the other side order the buffer
/// contents themselves, so `bufs` and `lens` need no locking.
count: std.atomic.Value(usize),

/// Batch byte length per slot; written by the producer before publish.
lens: [buffer_count]usize,
/// Next slot the gather thread fills. Producer-owned.
head: usize,
/// Next slot the main thread consumes. Consumer-owned.
tail: usize,

/// Set while the gather thread is sleeping in a bridge poll. The main
/// thread only writes the idle pipe when this is set, so interactive
/// output never pays the extra syscall.
bridging: std.atomic.Value(bool),

bufs: [buffer_count][buffer_capacity]u8,

pub const Error = error{PipelineFailed};

pub fn init(master: posix.fd_t) Error!ReadPipeline {
    std.debug.assert(master >= 0);

    const ready_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(ready_rc) != .SUCCESS) return error.PipelineFailed;
    const ready_fd: posix.fd_t = @intCast(ready_rc);
    errdefer _ = linux.close(ready_fd);

    const slot_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(slot_rc) != .SUCCESS) return error.PipelineFailed;
    const slot_free_fd: posix.fd_t = @intCast(slot_rc);
    errdefer _ = linux.close(slot_free_fd);

    var idle_fds: [2]posix.fd_t = .{ -1, -1 };
    if (linux.errno(linux.pipe2(&idle_fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
        log.warn("failed to create read pipeline idle pipe; bridge polls are timeout-bound", .{});
    }
    errdefer if (idle_fds[0] >= 0) {
        _ = linux.close(idle_fds[0]);
        _ = linux.close(idle_fds[1]);
    };

    var quit_fds: [2]posix.fd_t = undefined;
    if (linux.errno(linux.pipe2(&quit_fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        return error.PipelineFailed;
    }

    return .{
        .master = master,
        .ready_fd = ready_fd,
        .slot_free_fd = slot_free_fd,
        .idle_fds = idle_fds,
        .quit_fds = quit_fds,
        .thread = null,
        .count = .init(0),
        .lens = @splat(0),
        .head = 0,
        .tail = 0,
        .bridging = .init(false),
        .bufs = undefined,
    };
}

/// Spawn the gather thread. The pipeline must have its final address.
pub fn start(self: *ReadPipeline) Error!void {
    std.debug.assert(self.thread == null);
    self.thread = std.Thread.spawn(.{}, gatherMain, .{self}) catch |err| {
        log.err("failed to spawn gather thread: {}", .{err});
        return error.PipelineFailed;
    };
}

/// Stop and join the gather thread. Idempotent. Must run before the
/// master fd is closed so the thread never touches a stale fd.
pub fn stop(self: *ReadPipeline) void {
    const thread = self.thread orelse return;
    self.thread = null;
    _ = linux.write(self.quit_fds[1], "x", 1);
    thread.join();
}

pub fn deinit(self: *ReadPipeline) void {
    self.stop();
    _ = linux.close(self.ready_fd);
    _ = linux.close(self.slot_free_fd);
    if (self.idle_fds[0] >= 0) {
        _ = linux.close(self.idle_fds[0]);
        _ = linux.close(self.idle_fds[1]);
    }
    _ = linux.close(self.quit_fds[0]);
    _ = linux.close(self.quit_fds[1]);
    self.* = undefined;
}

/// Clear the ready eventfd. Call before consuming batches so a publish
/// racing the drain re-arms it instead of getting lost.
pub fn clearReady(self: *ReadPipeline) void {
    var counter: u64 = undefined;
    _ = linux.read(self.ready_fd, std.mem.asBytes(&counter), 8);
}

/// The oldest published batch, or null. The slice stays valid until the
/// matching `release`.
pub fn take(self: *const ReadPipeline) ?[]const u8 {
    if (self.count.load(.acquire) == 0) return null;
    return self.bufs[self.tail][0..self.lens[self.tail]];
}

/// Return the batch from `take` to the ring and wake the gather thread.
pub fn release(self: *ReadPipeline) void {
    std.debug.assert(self.count.load(.monotonic) > 0);
    self.tail = (self.tail + 1) % buffer_count;
    const previous_count = self.count.fetchSub(1, .release);
    if (previous_count == 1 and self.bridging.load(.acquire) and self.idle_fds[1] >= 0) {
        _ = linux.write(self.idle_fds[1], "i", 1);
    }
    bump(self.slot_free_fd);
}

/// Re-arm the ready eventfd if batches remain after a bounded drain, so
/// the next poll iteration continues without waiting for a new publish.
pub fn rearm(self: *ReadPipeline) void {
    if (self.count.load(.acquire) > 0) bump(self.ready_fd);
}

fn bump(fd: posix.fd_t) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one), 8);
}

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const Wait = enum { readable, timeout, quit, hangup };
const BridgeWait = enum { readable, timeout, quit, idle, hangup };

/// Wait for the master to become readable, the quit pipe to fire, or
/// the timeout (ms, -1 blocks) to expire.
fn waitReadable(self: *ReadPipeline, timeout_ms: i32) Wait {
    var fds = [_]posix.pollfd{
        .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.quit_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };
    const n = posix.poll(&fds, timeout_ms) catch return .quit;
    if (n == 0) return .timeout;
    if (fds[1].revents != 0) return .quit;
    if (fds[0].revents & posix.POLL.IN != 0) return .readable;
    // POLLHUP/POLLERR alone: let read() observe and classify the error.
    return .hangup;
}

/// Wait for a producer refill while bridging a saturated burst. If the
/// parser consumes the last published batch first, deliver immediately:
/// any extra wait is visible latency, and a frame-synced producer may be
/// blocked on a reply to data already in this unpublished batch.
fn waitBridge(self: *ReadPipeline, timeout_ms: i32) BridgeWait {
    if (self.idle_fds[0] >= 0) self.drainIdlePipe();

    self.bridging.store(true, .release);
    if (self.count.load(.acquire) == 0) {
        self.bridging.store(false, .release);
        if (self.idle_fds[0] >= 0) self.drainIdlePipe();
        return .idle;
    }

    var fds = [_]posix.pollfd{
        .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.quit_fds[0], .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.idle_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };
    const n = posix.poll(&fds, timeout_ms) catch {
        self.bridging.store(false, .release);
        return .quit;
    };
    self.bridging.store(false, .release);

    const idle_fd_ready = self.idle_fds[0] >= 0 and fds[2].revents & posix.POLL.IN != 0;
    const parser_idle = self.count.load(.acquire) == 0;
    if (self.idle_fds[0] >= 0 and (idle_fd_ready or parser_idle)) self.drainIdlePipe();

    if (n == 0) return .timeout;
    if (fds[1].revents != 0) return .quit;
    if (idle_fd_ready or parser_idle) return .idle;
    if (fds[0].revents & posix.POLL.IN != 0) return .readable;
    return .hangup;
}

fn drainIdlePipe(self: *ReadPipeline) void {
    std.debug.assert(self.idle_fds[0] >= 0);
    var trash: [16]u8 = undefined;
    while (true) {
        const rc = linux.read(self.idle_fds[0], &trash, trash.len);
        if (linux.errno(rc) != .SUCCESS or rc < trash.len) break;
    }
}

/// Wait for a free ring slot (or quit). Returns false on quit.
fn waitSlotFree(self: *ReadPipeline) bool {
    var fds = [_]posix.pollfd{
        .{ .fd = self.slot_free_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.quit_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };
    while (self.count.load(.acquire) == buffer_count) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        const n = posix.poll(&fds, -1) catch return false;
        if (n == 0) continue;
        if (fds[1].revents != 0) return false;
        var counter: u64 = undefined;
        _ = linux.read(self.slot_free_fd, std.mem.asBytes(&counter), 8);
    }
    return true;
}

/// The master returned EIO/EOF, which Pty.spawn's retained slave fd
/// makes impossible in normal operation. Log and park until stop():
/// reads are over, but session lifetime belongs to SIGCHLD.
fn parkUntilQuit(self: *ReadPipeline) void {
    log.warn("unexpected EIO/EOF on pty master; pty reads stopped", .{});
    var fds = [_]posix.pollfd{
        .{ .fd = self.quit_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, -1) catch {};
}

fn gatherMain(self: *ReadPipeline) void {
    // Best-effort thread name for debugging; matches Ghostty's.
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr("io-gather"), 0, 0, 0);

    while (true) {
        // Claim the next slot. A full ring means parsing is behind:
        // stop reading and let the kernel pty queue throttle the child.
        if (!self.waitSlotFree()) return;
        const buf: *[buffer_capacity]u8 = &self.bufs[self.head];

        var total: usize = 0;
        var spins: usize = 0;
        var bridge_start: ?i128 = null;
        var quit = false;
        var failed = false;

        gather: while (total < buffer_capacity) {
            const n = posix.read(self.master, buf[total..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // Deliver interactive trickles immediately. For
                    // saturated streams the producer usually refills the
                    // drained kernel queue within microseconds, so spin
                    // briefly, then poll, bounded by the bridge budget.
                    if (total < bridge_threshold) break :gather;
                    if (spins < bridge_spin_max) {
                        spins += 1;
                        continue :gather;
                    }
                    const now = nowNs();
                    if (bridge_start) |started| {
                        if (now - started >= gather_budget_ns) break :gather;
                    } else bridge_start = now;
                    switch (self.waitBridge(bridge_poll_timeout_ms)) {
                        .readable => continue :gather,
                        .timeout, .idle, .hangup => break :gather,
                        .quit => {
                            quit = true;
                            break :gather;
                        },
                    }
                },
                else => {
                    failed = true;
                    break :gather;
                },
            };
            if (n == 0) {
                failed = true;
                break :gather;
            }
            total += n;
            spins = 0;
        }

        if (total > 0) {
            self.lens[self.head] = total;
            self.head = (self.head + 1) % buffer_count;
            std.debug.assert(self.count.load(.monotonic) < buffer_count);
            _ = self.count.fetchAdd(1, .release);
            bump(self.ready_fd);
        }

        if (quit) return;

        if (failed) {
            self.parkUntilQuit();
            return;
        }

        // A full buffer means the stream is hot: skip the poll and keep
        // draining into the next slot immediately.
        if (total == buffer_capacity) continue;

        switch (self.waitReadable(-1)) {
            // .hangup: read() will observe and classify the error.
            .readable, .hangup => {},
            .timeout => unreachable, // infinite timeout
            .quit => return,
        }
    }
}

fn setNonblocking(fd: posix.fd_t) void {
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

test "pipeline delivers batches and stops cleanly after EOF" {
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe_fds[0]);
    setNonblocking(pipe_fds[0]);

    var pipeline: ReadPipeline = try .init(pipe_fds[0]);
    defer pipeline.deinit();
    try pipeline.start();

    _ = linux.write(pipe_fds[1], "hello", 5);

    // Wait for the batch to be published.
    var fds = [_]posix.pollfd{
        .{ .fd = pipeline.ready_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    try std.testing.expect(try posix.poll(&fds, 1000) == 1);
    pipeline.clearReady();

    const batch = pipeline.take() orelse return error.TestExpectedBatch;
    try std.testing.expectEqualStrings("hello", batch);
    pipeline.release();
    try std.testing.expectEqual(null, pipeline.take());

    // EOF (write end closed) parks the gather thread on the quit pipe;
    // deinit must still stop and join it without hanging.
    _ = linux.close(pipe_fds[1]);
    const ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
}

fn releaseAfterBridgeArmed(pipeline: *ReadPipeline) void {
    const deadline = nowNs() + 500 * std.time.ns_per_ms;
    while (!pipeline.bridging.load(.acquire)) {
        if (nowNs() >= deadline) return;
        std.Thread.yield() catch {};
    }
    pipeline.release();
}

test "bridge wait wakes when consumer releases last batch" {
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);
    setNonblocking(pipe_fds[0]);

    var pipeline: ReadPipeline = try .init(pipe_fds[0]);
    defer pipeline.deinit();
    try std.testing.expect(pipeline.idle_fds[0] >= 0);

    pipeline.lens[0] = 1;
    pipeline.count.store(1, .release);

    const started = nowNs();
    const releaser = try std.Thread.spawn(.{}, releaseAfterBridgeArmed, .{&pipeline});
    const result = pipeline.waitBridge(1000);
    releaser.join();

    try std.testing.expectEqual(.idle, result);
    try std.testing.expect(nowNs() - started < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), pipeline.count.load(.acquire));
}
