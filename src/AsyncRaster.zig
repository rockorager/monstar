//! Asynchronous CPU raster worker.
//!
//! A single controlling thread owns each `Loader` and `AsyncRaster` and calls
//! its public methods; their internal threads only perform loading or raster
//! work. Once started, either object must remain at a stable address until its
//! thread is joined by `takeResult` or `deinit`. The supplied `RenderState` is
//! borrowed for the lifetime of the resulting `AsyncRaster` and must not be
//! accessed by the controlling thread while a raster job is busy.

const AsyncRaster = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const vt = @import("ghostty-vt");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");

pub const RepairRect = Renderer.PixelRect;

pub const Repair = union(enum) {
    none,
    full,
    rects: []const RepairRect,
};

/// A borrowed render snapshot. On successful submission, every slice and any
/// memory reachable through its elements must remain valid until the matching
/// result is taken, or until `AsyncRaster.deinit` returns. The worker has
/// exclusive access to mutate `pixels` during that interval; all other slices
/// are read-only. A returned `Result.job` preserves these borrows and does not
/// transfer ownership of their backing storage.
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
    /// Every visible scrollback-search match as a row-major cell mask.
    search_matches: []const bool,
    /// Colors shared by the full-strength selected match and dimmed matches.
    search_background: vt.color.RGB,
    search_foreground: vt.color.RGB,
    /// IME preedit overlay text.
    preedit: ?[]const u8,
    /// Hovered-hyperlink URI overlay.
    link_hint: ?[]const u8,
    /// Top-right scrollback-search overlay.
    search: ?[]const u8,
    /// Use the terminal's red palette entry for the search overlay.
    search_no_match: bool,
    /// Transient right-edge scrollback indicator in full-surface pixels.
    scrollbar: ?Renderer.ScrollbarThumb,
    /// Visible kitty placements, resolved on the main thread with image
    /// data repointed at cache-pinned copies; empty when no graphics are
    /// visible.
    kitty_items: []const Renderer.KittyRenderItem,
    /// Any overlay input (kitty snapshot, preedit, link hint, hint
    /// flag) differs from the previously submitted job. Unchanged
    /// overlays over clean content need no repaint.
    overlay_dirty: bool,
    /// Whole terminal rows by which previous-frame pixels move. Positive
    /// shifts content up; negative shifts it down.
    scroll_shift: ?isize,
    /// Work needed to bring a stale target up to the previous committed
    /// frame.
    repair: Repair,

    fn hasOverlay(self: *const Job) bool {
        return self.preedit != null or self.link_hint != null or
            self.search != null or self.search_matches.len > 0 or
            self.scrollbar != null or
            self.kitty_items.len > 0;
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
/// first frame without repeating the main Font's immutable discovery. The
/// controlling thread owns the loader and must eventually call `deinit`, even
/// after taking its result.
pub const Loader = struct {
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    background_alpha_cells: bool,
    state: *vt.RenderState,
    thread: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?LoadResult = null,
    complete_fd: posix.fd_t,

    /// Retains `discovery` and borrows `state`. The borrow is transferred to a
    /// successful `.ready` raster; otherwise it ends when the loader is
    /// deinitialized.
    pub fn init(
        discovery: *Font.Discovery,
        selection_background: vt.color.RGB,
        selection_foreground: ?vt.color.RGB,
        cursor_text: ?vt.color.RGB,
        background_alpha: u8,
        background_alpha_cells: bool,
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
            .background_alpha_cells = background_alpha_cells,
            .state = state,
            .complete_fd = @intCast(rc),
        };
    }

    /// Starts the load thread. Requires no thread to have been started for
    /// this loader; `self` must not move until that thread is joined.
    pub fn start(self: *Loader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, loadMain, .{self});
    }

    /// Returns null while loading is incomplete. A non-null return joins the
    /// load thread; `.ready` transfers an `AsyncRaster` that the caller must
    /// deinitialize, while `.failed` produces no raster.
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

    /// Joins an outstanding load, destroys any result not taken by the caller,
    /// releases the retained discovery, and invalidates the loader. This may
    /// block until loading completes.
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
            self.background_alpha_cells,
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
font: *Font,
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

/// Creates an idle raster worker but does not start its thread. The returned
/// value owns its renderer, font, and event descriptors and borrows `state`
/// until `deinit`.
pub fn init(
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    background_alpha_cells: bool,
    state: *vt.RenderState,
) !AsyncRaster {
    const alloc = std.heap.smp_allocator;
    const font = try alloc.create(Font);
    errdefer alloc.destroy(font);
    font.* = try .initWithDiscovery(alloc, discovery);
    errdefer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
        .background_alpha_cells = background_alpha_cells,
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

/// Starts the raster thread. Requires no thread to have been started for this
/// instance; `self` must not move until that thread is joined.
pub fn start(self: *AsyncRaster) !void {
    std.debug.assert(self.thread == null);
    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
}

/// Stops and joins the raster thread, releases owned resources, and invalidates
/// the instance. This may block for an in-progress job; that job's borrowed
/// storage must remain valid until this function returns.
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
    self.alloc.destroy(self.font);
    self.* = undefined;
}

/// Replaces the worker's font and renderer configuration while idle. Returns
/// `error.Busy` if a job is queued, running, or awaiting collection. Other
/// errors leave the existing configuration intact.
pub fn reconfigure(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    background_alpha_cells: bool,
) !void {
    self.lock();
    defer self.mutex.unlock();
    if (self.has_job or self.working or self.result != null) return error.Busy;
    const font = try self.alloc.create(Font);
    errdefer self.alloc.destroy(font);
    font.* = try .initWithDiscovery(self.alloc, discovery);
    errdefer font.deinit(self.alloc);
    var renderer: Renderer = try .init(self.alloc, font, .{
        .selection_background = selection_background,
        .selection_foreground = selection_foreground,
        .cursor_text = cursor_text,
        .background_alpha = background_alpha,
        .background_alpha_cells = background_alpha_cells,
    });
    errdefer renderer.deinit();
    self.renderer.deinit();
    self.font.deinit(self.alloc);
    self.alloc.destroy(self.font);
    self.font = font;
    self.renderer = renderer;
}

/// Reports whether a job is queued, running, or has an uncollected result.
pub fn busy(self: *AsyncRaster) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.has_job or self.working or self.result != null;
}

/// Compares the current renderer settings, including discovery identity. This
/// query is synchronized with the worker and does not require an idle raster.
pub fn configuredFor(
    self: *AsyncRaster,
    discovery: *Font.Discovery,
    selection_background: vt.color.RGB,
    selection_foreground: ?vt.color.RGB,
    cursor_text: ?vt.color.RGB,
    background_alpha: u8,
    background_alpha_cells: bool,
) bool {
    self.lock();
    defer self.mutex.unlock();
    return self.font.discovery() == discovery and
        self.renderer.selection_bg.eql(selection_background) and
        optionalRgbEql(self.renderer.selection_fg, selection_foreground) and
        optionalRgbEql(self.renderer.cursor_text, cursor_text) and
        self.renderer.background_alpha == background_alpha and
        self.renderer.background_alpha_cells == background_alpha_cells;
}

/// Queues one job and wakes the worker. Returns `error.Busy` unless the raster
/// is idle. On success the worker borrows the job's storage as documented by
/// `Job`; on notification failure no job is retained.
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

/// Returns null until a job completes. Taking a result makes the raster idle
/// and ends the worker's borrow of the job storage; the returned `Job` still
/// contains caller-owned slices and performs no cleanup.
pub fn takeResult(self: *AsyncRaster) ?Result {
    self.drainEventfd();
    self.lock();
    defer self.mutex.unlock();
    const result = self.result orelse return null;
    self.result = null;
    return result;
}

/// Copies the most recently rendered rectangles into caller-owned `dest`,
/// clearing its previous contents while retaining capacity. Requires an idle
/// raster, normally immediately after `takeResult`; `alloc` is used only if
/// `dest` must grow.
pub fn copyRenderedRects(self: *AsyncRaster, alloc: std.mem.Allocator, dest: *std.ArrayList(Renderer.PixelRect)) !void {
    self.lock();
    defer self.mutex.unlock();
    std.debug.assert(!self.has_job and !self.working and self.result == null);
    dest.clearRetainingCapacity();
    try dest.appendSlice(alloc, self.renderer.rendered_rects.items);
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
        self.renderer.search_matches = job.search_matches;
        self.renderer.search_bg = job.search_background;
        self.renderer.search_fg = job.search_foreground;
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
        if (job.scrollbar) |thumb| {
            self.renderer.renderScrollbarThumb(
                self.state,
                job.pixels,
                job.width,
                job.height,
                thumb,
            );
        }
        damage.* = .full;
        return;
    }
    if (job.scroll_shift) |shift| {
        clearPadding(job, self.renderer.backgroundPixel(self.state.colors.background));
        if (scrollFromPreviousFrame(job, shift, self.font.cell_height)) {
            try self.renderer.shiftCellState(self.state.rows, self.state.cols, shift);
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
        .rects => |rects| repair: {
            const source = job.source_pixels orelse break :repair false;
            if (source.len != job.pixels.len) break :repair false;
            if (source.ptr == job.pixels.ptr) break :repair true;
            for (rects) |rect| {
                if (rect.x > job.width or rect.width > job.width - rect.x or
                    rect.y > job.height or rect.height > job.height - rect.y)
                {
                    break :repair false;
                }
                for (rect.y..rect.y + rect.height) |y| {
                    const offset = @as(usize, y) * job.width + rect.x;
                    Renderer.copyPixels(
                        job.pixels[offset..][0..rect.width],
                        source[offset..][0..rect.width],
                    );
                }
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
        .search_matches = &.{},
        .search_background = .{ .r = 1, .g = 2, .b = 3 },
        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
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

    const rects = [_]RepairRect{.{ .x = 1, .y = 1, .width = 1, .height = 1 }};
    current = base;
    current.repair = .{ .rects = &rects };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 8 }, &target);

    target = .{ 1, 2, 3, 4 };
    current.repair = .{ .rects = &.{} };
    try std.testing.expect(repairToPreviousFrame(current));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &target);

    const invalid_rects = [_]RepairRect{
        .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .{ .x = 0, .y = 2, .width = 2, .height = 1 },
    };
    current.repair = .{ .rects = &invalid_rects };
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
        .search_matches = &.{},
        .search_background = .{ .r = 1, .g = 2, .b = 3 },
        .search_foreground = .{ .r = 4, .g = 5, .b = 6 },
        .preedit = null,
        .link_hint = null,
        .search = null,
        .search_no_match = false,
        .scrollbar = null,
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
