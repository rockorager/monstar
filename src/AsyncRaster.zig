//! Asynchronous CPU raster worker.

const AsyncRaster = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");

pub const Job = struct {
    pixels: []u32,
    source_pixels: ?[]const u32,
    width: u31,
    height: u31,
    age: usize,
    generation: u64,
    focused: bool,
    /// Underline hovered hyperlinks in the base render.
    hyperlink_hints: bool,
    /// IME preedit overlay text. Owned by the submitter; must stay valid
    /// until the job's result is taken.
    preedit: ?[]const u8,
    /// Hovered-hyperlink URI overlay. Same ownership as `preedit`.
    link_hint: ?[]const u8,
    /// Visible kitty placements, resolved on the main thread with image
    /// data repointed at cache-pinned copies. Same ownership as
    /// `preedit`; empty when no graphics are visible.
    kitty_items: []const Renderer.KittyRenderItem,
    /// Any overlay input (kitty snapshot, preedit, link hint, hint
    /// flag) differs from the previously submitted job. Unchanged
    /// overlays over clean content need no repaint.
    overlay_dirty: bool,

    fn hasOverlay(self: *const Job) bool {
        return self.preedit != null or self.link_hint != null or self.kitty_items.len > 0;
    }
};

pub const Damage = enum { full, partial, none };

pub const Result = struct {
    job: Job,
    err: ?anyerror,
    damage: Damage,
};

pub const LoadResult = union(enum) {
    ready: AsyncRaster,
    failed: anyerror,
};

/// Builds the worker's independent FreeType and renderer state after the
/// first frame without repeating the main Font's immutable discovery.
pub const Loader = struct {
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    state: *vt.RenderState,
    thread: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?LoadResult = null,
    complete_fd: posix.fd_t,

    pub fn init(
        discovery: *Font.Discovery,
        selection_background: vt.color.RGB,
        selection_foreground: ?vt.color.RGB,
        state: *vt.RenderState,
    ) !Loader {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
        discovery.ref();
        return .{
            .discovery = discovery,
            .selection_background = selection_background,
            .selection_foreground = selection_foreground,
            .state = state,
            .complete_fd = @intCast(rc),
        };
    }

    pub fn start(self: *Loader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, loadMain, .{self});
    }

    pub fn takeResult(self: *Loader) ?LoadResult {
        drainEventFd(self.complete_fd);
        self.lock();
        const result = self.result orelse {
            self.mutex.unlock();
            return null;
        };
        self.result = null;
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        return result;
    }

    pub fn deinit(self: *Loader) void {
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| switch (result.*) {
            .ready => |*raster| raster.deinit(),
            .failed => {},
        };
        _ = linux.close(self.complete_fd);
        self.discovery.unref();
        self.* = undefined;
    }

    fn loadMain(self: *Loader) void {
        const result: LoadResult = if (AsyncRaster.init(
            self.discovery,
            self.selection_background,
            self.selection_foreground,
            self.state,
        )) |raster|
            .{ .ready = raster }
        else |err|
            .{ .failed = err };

        self.lock();
        self.result = result;
        self.mutex.unlock();
        writeEventfd(self.complete_fd) catch |err| {
            std.debug.panic("failed to notify async raster load completion: {}", .{err});
        };
    }

    fn lock(self: *Loader) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
};

alloc: std.mem.Allocator,
font: Font,
renderer: Renderer,
thread: ?std.Thread,
mutex: std.atomic.Mutex = .unlocked,
job_fd: posix.fd_t,
complete_fd: posix.fd_t,
stop: bool = false,
has_job: bool = false,
working: bool = false,
job: Job = undefined,
result: ?Result = null,
state: *vt.RenderState,

pub fn init(
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    state: *vt.RenderState,
) !AsyncRaster {
    const alloc = std.heap.smp_allocator;
    var font: Font = try .initWithDiscovery(alloc, discovery);
    errdefer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
    });
    errdefer renderer.deinit();
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
    errdefer _ = linux.close(@as(posix.fd_t, @intCast(rc)));
    const job_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(job_rc) != .SUCCESS) return error.EventFdFailed;
    errdefer _ = linux.close(@as(posix.fd_t, @intCast(job_rc)));
    const self: AsyncRaster = .{
        .alloc = alloc,
        .font = font,
        .renderer = renderer,
        .thread = null,
        .job_fd = @intCast(job_rc),
        .complete_fd = @intCast(rc),
        .state = state,
    };
    return self;
}

pub fn start(self: *AsyncRaster) !void {
    std.debug.assert(self.thread == null);
    // init returns this structure by value, so repair the renderer's pointer
    // after it reaches its stable address and before the worker can use it.
    self.renderer.font = &self.font;
    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
}

pub fn deinit(self: *AsyncRaster) void {
    if (self.thread) |thread| {
        self.lock();
        self.stop = true;
        self.mutex.unlock();
        self.notifyJob() catch |err| std.debug.panic("failed to wake async raster worker during shutdown: {}", .{err});
        thread.join();
    }
    _ = linux.close(self.job_fd);
    _ = linux.close(self.complete_fd);
    self.renderer.deinit();
    self.font.deinit(self.alloc);
    self.* = undefined;
}

pub fn reconfigure(self: *AsyncRaster, discovery: *Font.Discovery, selection_background: vt.color.RGB, selection_foreground: ?vt.color.RGB) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    var font: Font = try .initWithDiscovery(self.alloc, discovery);
    errdefer font.deinit(self.alloc);
    var renderer: Renderer = try .init(self.alloc, &font, .{ .selection_background = selection_background, .selection_foreground = selection_foreground });
    errdefer renderer.deinit();
    self.renderer.deinit();
    self.font.deinit(self.alloc);
    self.font = font;
    self.renderer = renderer;
    self.renderer.font = &self.font;
}

pub fn busy(self: *AsyncRaster) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.has_job or self.working or self.result != null;
}

pub fn configuredFor(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.font.discovery() == discovery and
        self.renderer.selection_bg.eql(selection_background) and
        optionalRgbEql(self.renderer.selection_fg, selection_foreground);
}

pub fn submit(self: *AsyncRaster, job: Job) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    self.job = job;
    self.has_job = true;
    self.notifyJob() catch |err| {
        self.has_job = false;
        return err;
    };
}

pub fn takeResult(self: *AsyncRaster) ?Result {
    self.drainEventfd();
    self.lock();
    defer self.mutex.unlock();
    const result = self.result orelse return null;
    self.result = null;
    return result;
}

pub fn copyRepaintedRows(self: *AsyncRaster, alloc: std.mem.Allocator, dest: *std.DynamicBitSetUnmanaged) !void {
    self.lock();
    defer self.mutex.unlock();
    std.debug.assert(!self.has_job and !self.working and self.result == null);
    try dest.resize(alloc, self.renderer.repainted.bit_length, false);
    dest.unsetAll();
    var it = self.renderer.repainted.iterator(.{});
    while (it.next()) |row| dest.set(row);
}

fn lock(self: *AsyncRaster) void {
    while (!self.mutex.tryLock()) std.Thread.yield() catch {};
}

fn optionalRgbEql(a: ?vt.color.RGB, b: ?vt.color.RGB) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn drainEventfd(self: *AsyncRaster) void {
    drainEventFd(self.complete_fd);
}

fn drainEventFd(fd: posix.fd_t) void {
    var value: u64 = 0;
    while (posix.read(fd, std.mem.asBytes(&value))) |_| {} else |_| {}
}

fn notifyJob(self: *AsyncRaster) !void {
    try writeEventfd(self.job_fd);
}

fn writeEventfd(fd: posix.fd_t) !void {
    const one: u64 = 1;
    while (true) {
        const rc = linux.write(fd, @ptrCast(&one), @sizeOf(u64));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc != @sizeOf(u64)) return error.ShortEventFdWrite;
                return;
            },
            .INTR => continue,
            else => return error.EventFdWriteFailed,
        }
    }
}

fn waitJob(self: *AsyncRaster) void {
    var value: u64 = 0;
    while (posix.read(self.job_fd, std.mem.asBytes(&value))) |_| return else |_| {}
}

fn workerMain(self: *AsyncRaster) void {
    while (true) {
        self.waitJob();
        self.lock();
        if (self.stop) {
            self.mutex.unlock();
            return;
        }
        const job = self.job;
        self.has_job = false;
        self.working = true;
        self.mutex.unlock();

        self.renderer.focused = job.focused;
        self.renderer.hyperlink_hints = job.hyperlink_hints;
        var damage: Damage = .full;
        const maybe_err: ?anyerror = if (self.renderJob(job, &damage)) |_| null else |e| e;

        self.lock();
        self.working = false;
        self.result = .{ .job = job, .err = maybe_err, .damage = damage };
        self.mutex.unlock();
        writeEventfd(self.complete_fd) catch |err| std.debug.panic("failed to notify async raster completion: {}", .{err});
    }
}

fn renderJob(self: *AsyncRaster, job: Job, damage: *Damage) !void {
    // Overlays draw outside the grid rows that dirty tracking accounts
    // for, so an overlay frame is always a full render with full damage.
    if (job.hasOverlay()) {
        // Unless nothing changed at all: clean content plus the same
        // overlays as the previous job reproduce the previous frame,
        // so repair to it instead of re-rendering. Without this a
        // visible kitty image turns every submitted job into a full
        // render.
        if (!job.overlay_dirty and self.state.dirty == .false and repairToPreviousFrame(job)) {
            damage.* = .none;
            return;
        }
        if (job.kitty_items.len > 0) {
            try self.renderer.renderWithKittyItems(self.state, job.kitty_items, job.pixels, job.width, job.height);
        } else {
            try self.renderer.render(self.state, job.pixels, job.width, job.height);
        }
        if (job.preedit) |text| {
            try self.renderer.renderPreedit(self.state, job.pixels, job.width, job.height, text);
        }
        if (job.link_hint) |uri| {
            try self.renderer.renderLinkHint(self.state, job.pixels, job.width, job.height, uri);
        }
        damage.* = .full;
        return;
    }
    switch (self.state.dirty) {
        .full => {
            try self.renderer.render(self.state, job.pixels, job.width, job.height);
            damage.* = .full;
        },
        .partial => {
            if (!repairToPreviousFrame(job)) {
                try self.renderer.render(self.state, job.pixels, job.width, job.height);
                damage.* = .full;
                return;
            }
            try self.renderer.renderDirty(self.state, job.pixels, job.width, job.height);
            damage.* = .partial;
        },
        .false => {
            if (!repairToPreviousFrame(job)) {
                try self.renderer.render(self.state, job.pixels, job.width, job.height);
                damage.* = .full;
                return;
            }
            damage.* = .none;
        },
    }
}

fn repairToPreviousFrame(job: Job) bool {
    if (job.age == 1) return true;
    const source = job.source_pixels orelse return false;
    std.debug.assert(source.len == job.pixels.len);
    if (source.ptr != job.pixels.ptr) Renderer.copyPixels(job.pixels, source);
    return true;
}

test "repair previous frame" {
    var target = [_]u32{ 1, 2, 3, 4 };
    const source = [_]u32{ 5, 6, 7, 8 };
    const base: Job = .{
        .pixels = &target,
        .source_pixels = &source,
        .width = 2,
        .height = 2,
        .age = 0,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .preedit = null,
        .link_hint = null,
        .kitty_items = &.{},
        .overlay_dirty = false,
    };

    try std.testing.expect(repairToPreviousFrame(base));
    try std.testing.expectEqualSlices(u32, &source, &target);

    target = .{ 1, 2, 3, 4 };
    var current = base;
    current.source_pixels = null;
    current.age = 1;
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    current.age = 0;
    try std.testing.expect(!repairToPreviousFrame(current));
}
