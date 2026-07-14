//! Asynchronous CPU raster worker.

const AsyncRaster = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");

pub const RepairSpan = struct {
    y: u31,
    height: u31,
};

pub const Repair = union(enum) {
    none,
    full,
    spans: []const RepairSpan,
};

pub const Job = struct {
    pixels: []u32,
    source_pixels: ?[]const u32,
    width: u31,
    height: u31,
    grid_x: u31,
    grid_y: u31,
    grid_width: u31,
    grid_height: u31,
    age: usize,
    generation: u64,
    focused: bool,
    /// Underline hovered hyperlinks in the base render.
    hyperlink_hints: bool,
    /// Hovered automatically detected link in viewport cell coordinates.
    link_range: ?Renderer.LinkRange,
    /// Selected scrollback-search match in viewport cell coordinates.
    search_range: ?Renderer.LinkRange,
    /// IME preedit overlay text. Owned by the submitter; must stay valid
    /// until the job's result is taken.
    preedit: ?[]const u8,
    /// Hovered-hyperlink URI overlay. Same ownership as `preedit`.
    link_hint: ?[]const u8,
    /// Top-right scrollback-search overlay. Same ownership as `preedit`.
    search: ?[]const u8,
    /// Use the terminal's red palette entry for the search overlay.
    search_no_match: bool,
    /// Visible kitty placements, resolved on the main thread with image
    /// data repointed at cache-pinned copies. Same ownership as
    /// `preedit`; empty when no graphics are visible.
    kitty_items: []const Renderer.KittyRenderItem,
    /// Any overlay input (kitty snapshot, preedit, link hint, hint
    /// flag) differs from the previously submitted job. Unchanged
    /// overlays over clean content need no repaint.
    overlay_dirty: bool,
    /// Whole terminal rows by which previous-frame pixels move. Positive
    /// shifts content up; negative shifts it down.
    scroll_shift: ?isize,
    /// Work needed to bring a stale target up to the previous committed
    /// frame. Span storage belongs to the submitter and remains valid until
    /// the result is taken.
    repair: Repair,

    fn hasOverlay(self: *const Job) bool {
        return self.preedit != null or self.link_hint != null or
            self.search != null or self.kitty_items.len > 0;
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
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    state: *vt.RenderState,
    thread: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?LoadResult = null,
    complete_fd: posix.fd_t,

    pub fn init(
        discovery: *Font.Discovery,
        selection_background: vt.color.RGB,
        selection_foreground: ?vt.color.RGB,
        cursor_text: ?vt.color.RGB,
        background_alpha: u8,
        state: *vt.RenderState,
    ) !Loader {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
        discovery.ref();
        return .{
            .discovery = discovery,
            .selection_background = selection_background,
            .selection_foreground = selection_foreground,
            .cursor_text = cursor_text,
            .background_alpha = background_alpha,
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
            self.cursor_text,
            self.background_alpha,
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
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    state: *vt.RenderState,
) !AsyncRaster {
    const alloc = std.heap.smp_allocator;
    var font: Font = try .initWithDiscovery(alloc, discovery);
    errdefer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
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

pub fn reconfigure(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    var font: Font = try .initWithDiscovery(self.alloc, discovery);
    errdefer font.deinit(self.alloc);
    var renderer: Renderer = try .init(self.alloc, &font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
    });
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
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.font.discovery() == discovery and
        self.renderer.selection_bg.eql(selection_background) and
        optionalRgbEql(self.renderer.selection_fg, selection_foreground) and
        optionalRgbEql(self.renderer.cursor_text, cursor_text) and
        self.renderer.background_alpha == background_alpha;
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
        self.renderer.link_range = job.link_range;
        self.renderer.search_range = job.search_range;
        self.renderer.buffer_stride = job.width;
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
    const grid_pixels = gridPixels(job);
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
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        if (job.kitty_items.len > 0) {
            try self.renderer.renderWithKittyItems(self.state, job.kitty_items, grid_pixels, job.grid_width, job.grid_height);
        } else {
            try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
        }
        if (job.preedit) |text| {
            try self.renderer.renderPreedit(self.state, grid_pixels, job.grid_width, job.grid_height, text);
        }
        if (job.link_hint) |uri| {
            try self.renderer.renderLinkHint(self.state, grid_pixels, job.grid_width, job.grid_height, uri);
        }
        if (job.search) |text| {
            try self.renderer.renderSearch(
                self.state,
                grid_pixels,
                job.grid_width,
                job.grid_height,
                text,
                job.search_no_match,
            );
        }
        damage.* = .full;
        return;
    }
    if (job.scroll_shift) |shift| {
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        if (scrollFromPreviousFrame(job, shift, self.font.cell_height)) {
            try self.renderer.shiftRowOverhang(self.state.rows, shift);
            try self.renderer.renderDirty(self.state, grid_pixels, job.grid_width, job.grid_height);
            // Rasterization touched only dirty rows, but every retained row
            // moved to a different surface location.
            damage.* = .full;
            return;
        }
        // App normally excludes this case before narrowing the dirty rows.
        // A full render is still a safe fallback if the job is malformed.
        try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
        damage.* = .full;
        return;
    }
    switch (self.state.dirty) {
        .full => {
            clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
            try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
            damage.* = .full;
        },
        .partial => {
            if (!repairToPreviousFrame(job)) {
                clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
                try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
                damage.* = .full;
                return;
            }
            try self.renderer.renderDirty(self.state, grid_pixels, job.grid_width, job.grid_height);
            damage.* = .partial;
        },
        .false => {
            if (!repairToPreviousFrame(job)) {
                clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
                try self.renderer.render(self.state, grid_pixels, job.grid_width, job.grid_height);
                damage.* = .full;
                return;
            }
            damage.* = .none;
        },
    }
}

fn gridPixels(job: Job) []u32 {
    std.debug.assert(job.grid_x + job.grid_width <= job.width);
    std.debug.assert(job.grid_y + job.grid_height <= job.height);
    const offset = @as(usize, job.grid_y) * job.width + job.grid_x;
    return job.pixels[offset..];
}

fn clearPadding(job: Job, color: u32) void {
    @memset(job.pixels[0 .. @as(usize, job.grid_y) * job.width], color);
    const grid_bottom = @as(usize, job.grid_y + job.grid_height) * job.width;
    @memset(job.pixels[grid_bottom..], color);
    for (job.grid_y..job.grid_y + job.grid_height) |y| {
        const row = @as(usize, y) * job.width;
        @memset(job.pixels[row .. row + job.grid_x], color);
        const right = row + job.grid_x + job.grid_width;
        @memset(job.pixels[right .. row + job.width], color);
    }
}

fn repairToPreviousFrame(job: Job) bool {
    return switch (job.repair) {
        .none => true,
        .full => repair: {
            const source = job.source_pixels orelse break :repair false;
            if (source.len != job.pixels.len) break :repair false;
            if (source.ptr != job.pixels.ptr) Renderer.copyPixels(job.pixels, source);
            break :repair true;
        },
        .spans => |spans| repair: {
            const source = job.source_pixels orelse break :repair false;
            if (source.len != job.pixels.len) break :repair false;
            if (source.ptr == job.pixels.ptr) break :repair true;
            for (spans) |span| {
                if (span.y > job.height or span.height > job.height - span.y) break :repair false;
                const offset = @as(usize, span.y) * job.width;
                const len = @as(usize, span.height) * job.width;
                Renderer.copyPixels(job.pixels[offset..][0..len], source[offset..][0..len]);
            }
            break :repair true;
        },
    };
}

/// Move retained framebuffer rows directly from the previous frame into
/// their new positions. This avoids a full stale-buffer repair followed by
/// a second in-place shift when source and destination differ.
fn scrollFromPreviousFrame(job: Job, shift_rows: isize, cell_height: u31) bool {
    const rows: usize = @abs(shift_rows);
    if (rows == 0) return false;
    const shift_pixels = rows * cell_height;
    if (shift_pixels >= job.grid_height) return false;

    const source = if (job.age == 1)
        @as([]const u32, job.pixels)
    else
        job.source_pixels orelse return false;
    if (source.len != job.pixels.len) return false;

    const stride: usize = job.width;
    const grid_start = @as(usize, job.grid_y) * stride;
    const grid_end = @as(usize, job.grid_y + job.grid_height) * stride;
    const offset = shift_pixels * stride;
    const retained = grid_end - grid_start - offset;
    if (shift_rows > 0) {
        const dst = job.pixels[grid_start .. grid_start + retained];
        const src = source[grid_start + offset .. grid_end];
        if (source.ptr == job.pixels.ptr)
            @memmove(dst, src)
        else
            Renderer.copyPixels(dst, src);
    } else {
        const dst = job.pixels[grid_start + offset .. grid_end];
        const src = source[grid_start .. grid_start + retained];
        if (source.ptr == job.pixels.ptr)
            @memmove(dst, src)
        else
            Renderer.copyPixels(dst, src);
    }
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
        .grid_x = 0,
        .grid_y = 0,
        .grid_width = 2,
        .grid_height = 2,
        .age = 0,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = null,
        .repair = .full,
    };

    try std.testing.expect(repairToPreviousFrame(base));
    try std.testing.expectEqualSlices(u32, &source, &target);

    target = .{ 1, 2, 3, 4 };
    var current = base;
    current.source_pixels = null;
    current.age = 1;
    current.repair = .none;
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    const spans = [_]RepairSpan{.{ .y = 1, .height = 1 }};
    current = base;
    current.repair = .{ .spans = &spans };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 7, 8 }, &target);

    target = .{ 1, 2, 3, 4 };
    current.repair = .{ .spans = &.{} };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    const invalid_spans = [_]RepairSpan{
        .{ .y = 0, .height = 1 },
        .{ .y = 2, .height = 1 },
    };
    current.repair = .{ .spans = &invalid_spans };
    try std.testing.expect(!repairToPreviousFrame(current));

    current.source_pixels = null;
    current.age = 0;
    current.repair = .full;
    try std.testing.expect(!repairToPreviousFrame(current));
}

test "scroll previous frame in place and from distinct source" {
    var pixels = [_]u32{
        0,  1,  2,
        3,  4,  5,
        6,  7,  8,
        9,  10, 11,
        12, 13, 14,
    };
    var job: Job = .{
        .pixels = &pixels,
        .source_pixels = null,
        .width = 3,
        .height = 5,
        .grid_x = 0,
        .grid_y = 1,
        .grid_width = 3,
        .grid_height = 3,
        .age = 1,
        .generation = 1,
        .focused = true,
        .hyperlink_hints = false,
        .link_range = null,
        .search_range = null,
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .kitty_items = &.{},
        .overlay_dirty = false,
        .scroll_shift = 1,
        .repair = .none,
    };

    try std.testing.expect(scrollFromPreviousFrame(job, 1, 1));
    try std.testing.expectEqualSlices(u32, &.{ 6, 7, 8, 9, 10, 11 }, pixels[3..9]);
    // The newly exposed row is deliberately untouched for renderDirty.
    try std.testing.expectEqualSlices(u32, &.{ 9, 10, 11 }, pixels[9..12]);

    const source = [_]u32{
        20, 21, 22,
        23, 24, 25,
        26, 27, 28,
        29, 30, 31,
        32, 33, 34,
    };
    @memset(&pixels, 99);
    job.age = 0;
    job.source_pixels = &source;
    try std.testing.expect(scrollFromPreviousFrame(job, -1, 1));
    try std.testing.expectEqualSlices(u32, &.{ 23, 24, 25, 26, 27, 28 }, pixels[6..12]);
    try std.testing.expectEqualSlices(u32, &.{ 99, 99, 99 }, pixels[3..6]);

    job.source_pixels = null;
    try std.testing.expect(!scrollFromPreviousFrame(job, 1, 1));
    try std.testing.expect(!scrollFromPreviousFrame(job, 3, 1));
}
