//! Headless rendering benchmarks (`monstar --bench`).
//!
//! Times the CPU rendering hot paths without a Wayland connection:
//! RenderState update, full and dirty-row renders, and the frame copy
//! into a swapchain buffer. The render target is heap memory, which
//! behaves like the wl_shm buffer (both are plain anonymous pages).

const std = @import("std");
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");

const cols = 240;
const rows = 64;

extern fn memcpy(noalias dest: ?*anyopaque, noalias src: ?*const anyopaque, n: usize) ?*anyopaque;

pub fn run(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    var config = Config.load(arena, init.minimal.environ);
    try config.resolveThemes(init.io, arena, init.minimal.environ);

    const font_size_px = Config.fontSizePixels(config.font_size, 120);
    var font: Font = try .init(alloc, config.font_family, font_size_px);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height * rows;

    var term: vt.Terminal = try .init(init.io, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = config.scrollback_limit,
        .colors = config.terminalColors(.dark),
    });
    defer term.deinit(alloc);
    term.width_px = width;
    term.height_px = height;
    var stream = term.vtStream();
    defer stream.deinit();

    var render_state: vt.RenderState = .empty;
    defer render_state.deinit(alloc);

    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);
    const shm = try alloc.alloc(u32, pixels.len);
    defer alloc.free(shm);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    try w.print(
        "grid {d}x{d}, {d}x{d} px ({d:.1} MB frame), font {s} {d:.1}{s} ({d}px)\n\n",
        .{
            cols,                                          rows,
            width,                                         height,
            @as(f64, @floatFromInt(pixels.len * 4)) / 1e6, config.font_family,
            config.font_size.value(),                      config.font_size.unit(),
            font_size_px,
        },
    );

    // A screenful of colored words: exercises shaping, blitting, and
    // per-cell style resolution like a busy TUI.
    try fillScreen(alloc, &stream);

    // Warm up: first full render populates the glyph caches.
    try render_state.update(alloc, &term);
    try renderer.render(&render_state, pixels, width, height);
    clearDirty(&render_state);

    // Full render of static content (worst case: every frame is full).
    {
        const iters = 100;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            try renderer.render(&render_state, pixels, width, height);
        }
        try report(w, "full render", nowNs(init.io) - start, iters, null);
    }

    // Baseline end-to-end scroll frame without the application's async
    // viewport-shift reuse. This remains useful as the full-repaint cost
    // against which the live scroll-blit path is measured.
    {
        const scroll_line = comptime scrollLine();
        const iters = 100;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            stream.nextSlice(scroll_line);
            try render_state.update(alloc, &term);
            try renderer.renderDirty(&render_state, pixels, width, height);
            clearDirty(&render_state);
        }
        try report(w, "scroll frame (feed+update+render)", nowNs(init.io) - start, iters, null);
    }

    // Steady-state frame: one row changes (cursor line, status bar).
    {
        const status_line = "\x1b[5;1H\x1b[36mstatus 0123456789 abcdefghijklmnop\x1b[0m";
        const iters = 1000;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            stream.nextSlice(status_line);
            try render_state.update(alloc, &term);
            try renderer.renderDirty(&render_state, pixels, width, height);
            clearDirty(&render_state);
        }
        try report(w, "one-row frame (feed+update+render)", nowNs(init.io) - start, iters, null);
    }

    // Background-heavy content: TUIs paint most cell backgrounds, which
    // exercises the per-cell fill path in prepareRow.
    {
        try fillScreenBg(alloc, &stream);
        try render_state.update(alloc, &term);
        try renderer.render(&render_state, pixels, width, height);
        clearDirty(&render_state);
        const iters = 100;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            try renderer.render(&render_state, pixels, width, height);
        }
        try report(w, "full render (bg-heavy)", nowNs(init.io) - start, iters, null);
    }

    // Frame copy strategies: still useful for comparing stale-buffer
    // repair costs and direct-SHM write tradeoffs.
    {
        const iters = 300;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            @memcpy(shm, pixels);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy full frame", nowNs(init.io) - start, iters, pixels.len * 4);
    }
    {
        const iters = 300;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            _ = memcpy(shm.ptr, pixels.ptr, pixels.len * 4);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy full frame (libc)", nowNs(init.io) - start, iters, pixels.len * 4);
    }
    {
        const iters = 300;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            Renderer.copyPixels(shm, pixels);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy full frame (NT stores)", nowNs(init.io) - start, iters, pixels.len * 4);
        if (!std.mem.eql(u32, shm, pixels)) try w.writeAll("  (!) NT copy MISMATCH\n");
    }
    {
        // A typical partial frame: one dirty row expanded to three.
        const span_rows: usize = 3;
        const span_len = @as(usize, font.cell_height) * span_rows * width;
        const offset = @as(usize, font.cell_height) * 20 * width;
        const iters = 300;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            @memcpy(shm[offset..][0..span_len], pixels[offset..][0..span_len]);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy 3-row span", nowNs(init.io) - start, iters, span_len * 4);
    }

    try w.writeAll("\n4K-ish stress cases\n");
    var row_renderer: Renderer = try .init(alloc, &font, .{
        .track_cell_damage = false,
        .partial_cell_raster = false,
    });
    defer row_renderer.deinit();
    try benchFullGrid(init.io, alloc, config, &row_renderer, w, 384, 112, "full render rows 384x112");
    try benchShapePrefixChurn(init.io, alloc, config, &row_renderer, w, 384, 112, "prefix-churn rows 384x112", false);
    try benchFullGrid(init.io, alloc, config, &renderer, w, 384, 112, "full render+cell snapshot 384x112");
    try benchShapePrefixChurn(init.io, alloc, config, &renderer, w, 384, 112, "prefix-churn cells 384x112", false);
    var pipeline_renderer: Renderer = try .init(alloc, &font, .{});
    defer pipeline_renderer.deinit();
    try benchShapePrefixChurn(init.io, alloc, config, &pipeline_renderer, w, 384, 112, "prefix-churn cells+repair 384x112", true);
    try benchCopies(init.io, alloc, w, 3840, 2160, "copy 3840x2160");
}

fn benchFullGrid(
    io: std.Io,
    alloc: std.mem.Allocator,
    config: Config,
    renderer: *Renderer,
    w: *std.Io.Writer,
    comptime bench_cols: u16,
    comptime bench_rows: u16,
    comptime name: []const u8,
) !void {
    const width: u31 = renderer.font.cell_width * bench_cols;
    const height: u31 = renderer.font.cell_height * bench_rows;
    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = bench_cols,
        .rows = bench_rows,
        .max_scrollback = config.scrollback_limit,
        .colors = config.terminalColors(.dark),
    });
    defer term.deinit(alloc);
    term.width_px = width;
    term.height_px = height;
    var stream = term.vtStream();
    defer stream.deinit();

    var render_state: vt.RenderState = .empty;
    defer render_state.deinit(alloc);

    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    defer alloc.free(pixels);

    try fillScreenDims(alloc, &stream, bench_cols, bench_rows);
    try render_state.update(alloc, &term);
    try renderer.render(&render_state, pixels, width, height);
    clearDirty(&render_state);

    try w.print(
        "{s}: grid {d}x{d}, {d}x{d} px ({d:.1} MB frame)\n",
        .{
            name,
            bench_cols,
            bench_rows,
            width,
            height,
            @as(f64, @floatFromInt(pixels.len * 4)) / 1e6,
        },
    );

    const iters = 30;
    const start = nowNs(io);
    for (0..iters) |_| {
        try renderer.render(&render_state, pixels, width, height);
    }
    try report(w, name, nowNs(io) - start, iters, null);
}

fn benchCopies(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    comptime width: usize,
    comptime height: usize,
    comptime name: []const u8,
) !void {
    const pixels = try alloc.alloc(u32, width * height);
    defer alloc.free(pixels);
    const shm = try alloc.alloc(u32, pixels.len);
    defer alloc.free(shm);
    @memset(pixels, 0xff1a1b26);

    const bytes = pixels.len * 4;
    try w.print("{s}: {d}x{d} px ({d:.1} MB frame)\n", .{
        name,
        width,
        height,
        @as(f64, @floatFromInt(bytes)) / 1e6,
    });
    {
        const iters = 60;
        const start = nowNs(io);
        for (0..iters) |_| {
            @memcpy(shm, pixels);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy 4K frame", nowNs(io) - start, iters, bytes);
    }
    {
        const iters = 60;
        const start = nowNs(io);
        for (0..iters) |_| {
            _ = memcpy(shm.ptr, pixels.ptr, bytes);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy 4K frame (libc)", nowNs(io) - start, iters, bytes);
    }
    {
        const iters = 60;
        const start = nowNs(io);
        for (0..iters) |_| {
            Renderer.copyPixels(shm, pixels);
            std.mem.doNotOptimizeAway(shm);
        }
        try report(w, "copy 4K frame (NT stores)", nowNs(io) - start, iters, bytes);
        if (!std.mem.eql(u32, shm, pixels)) try w.writeAll("  (!) NT copy MISMATCH\n");
    }
}

fn benchShapePrefixChurn(
    io: std.Io,
    alloc: std.mem.Allocator,
    config: Config,
    renderer: *Renderer,
    w: *std.Io.Writer,
    comptime bench_cols: u16,
    comptime bench_rows: u16,
    name: []const u8,
    repair_stale_buffers: bool,
) !void {
    const width: u31 = renderer.font.cell_width * bench_cols;
    const height: u31 = renderer.font.cell_height * bench_rows;
    var term: vt.Terminal = try .init(io, alloc, .{
        .cols = bench_cols,
        .rows = bench_rows,
        .max_scrollback = config.scrollback_limit,
        .colors = config.terminalColors(.dark),
    });
    defer term.deinit(alloc);
    term.width_px = width;
    term.height_px = height;
    var stream = term.vtStream();
    defer stream.deinit();

    var render_state: vt.RenderState = .empty;
    defer render_state.deinit(alloc);

    const frame_len = @as(usize, width) * height;
    const buffer_count: usize = if (repair_stale_buffers) 3 else 1;
    const buffers = try alloc.alloc(u32, frame_len * buffer_count);
    defer alloc.free(buffers);
    var damage_history: [2]std.ArrayList(Renderer.PixelRect) = .{ .empty, .empty };
    defer for (&damage_history) |*rects| rects.deinit(alloc);

    try fillPrefixChurnFrame(alloc, &stream, bench_cols, bench_rows, 0);
    try render_state.update(alloc, &term);
    try renderer.render(&render_state, buffers[0..frame_len], width, height);
    for (1..buffer_count) |i| {
        @memcpy(buffers[i * frame_len ..][0..frame_len], buffers[0..frame_len]);
    }
    clearDirty(&render_state);

    renderer.resetShapeStats();
    renderer.resetCellDamageStats();
    const iters = 30;
    const start = nowNs(io);
    for (0..iters) |frame| {
        const target_index = if (repair_stale_buffers) (frame + 1) % buffer_count else 0;
        const newest_index = if (repair_stale_buffers) frame % buffer_count else 0;
        const target = buffers[target_index * frame_len ..][0..frame_len];
        const newest = buffers[newest_index * frame_len ..][0..frame_len];
        if (repair_stale_buffers) {
            const history_len = @min(frame, damage_history.len);
            for (damage_history[0..history_len]) |rects| {
                copyDamageRects(target, newest, width, rects.items);
            }
        }
        try fillPrefixChurnFrame(alloc, &stream, bench_cols, bench_rows, frame + 1);
        try render_state.update(alloc, &term);
        try renderer.renderDirty(&render_state, target, width, height);
        if (repair_stale_buffers) {
            damage_history[1].clearRetainingCapacity();
            try damage_history[1].appendSlice(alloc, damage_history[0].items);
            try replaceCoalescedDamage(alloc, &damage_history[0], renderer.rendered_rects.items);
        }
        clearDirty(&render_state);
    }
    try report(w, name, nowNs(io) - start, iters, null);
    try reportShapeStats(w, renderer.shapeStats());
    const damage_stats = renderer.cellDamageStats();
    if (damage_stats.scanned_cells > 0) try reportCellDamageStats(w, damage_stats);
}

fn replaceCoalescedDamage(
    alloc: std.mem.Allocator,
    dest: *std.ArrayList(Renderer.PixelRect),
    source: []const Renderer.PixelRect,
) !void {
    dest.clearRetainingCapacity();
    for (source) |rect| {
        if (dest.items.len > 0) {
            const previous = &dest.items[dest.items.len - 1];
            const previous_end = previous.y + previous.height;
            if (previous.x == rect.x and previous.width == rect.width and rect.y <= previous_end) {
                previous.height = @max(previous_end, rect.y + rect.height) - previous.y;
                continue;
            }
        }
        try dest.append(alloc, rect);
    }
}

fn copyDamageRects(dest: []u32, source: []const u32, stride: u31, rects: []const Renderer.PixelRect) void {
    for (rects) |rect| {
        for (rect.y..rect.y + rect.height) |y| {
            const offset = @as(usize, y) * stride + rect.x;
            @memcpy(dest[offset..][0..rect.width], source[offset..][0..rect.width]);
        }
    }
}

/// Fill every grid row with colored words and park the cursor at the
/// bottom so later newlines scroll.
fn fillScreen(alloc: std.mem.Allocator, stream: anytype) !void {
    try fillScreenDims(alloc, stream, cols, rows);
}

fn fillScreenDims(alloc: std.mem.Allocator, stream: anytype, fill_cols: usize, fill_rows: usize) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    for (0..fill_rows) |y| {
        if (y > 0) try aw.writer.writeAll("\r\n");
        var col: usize = 0;
        var color: u8 = 1;
        while (col + 8 <= fill_cols) : (col += 8) {
            // "mÔnstar": the accented capital overhangs its cell top in
            // many fonts, exercising the renderer's overhang tracking.
            try aw.writer.print("\x1b[3{d}mm\u{d4}nstar ", .{color});
            color = if (color == 6) 1 else color + 1;
        }
        try aw.writer.writeAll("\x1b[0m");
    }
    stream.nextSlice(aw.writer.buffered());
}

/// Fill every grid row with words carrying colored backgrounds, like a
/// full-screen TUI.
fn fillScreenBg(alloc: std.mem.Allocator, stream: anytype) !void {
    try fillScreenBgDims(alloc, stream, cols, rows);
}

fn fillScreenBgDims(alloc: std.mem.Allocator, stream: anytype, fill_cols: usize, fill_rows: usize) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("\x1b[H");
    for (0..fill_rows) |y| {
        if (y > 0) try aw.writer.writeAll("\r\n");
        var col: usize = 0;
        var color: u8 = 1;
        while (col + 8 <= fill_cols) : (col += 8) {
            try aw.writer.print("\x1b[4{d};30mpanels  ", .{color});
            color = if (color == 6) 1 else color + 1;
        }
        try aw.writer.writeAll("\x1b[0m");
    }
    stream.nextSlice(aw.writer.buffered());
}

fn fillPrefixChurnFrame(
    alloc: std.mem.Allocator,
    stream: anytype,
    fill_cols: usize,
    fill_rows: usize,
    frame: usize,
) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("\x1b[H");
    for (0..fill_rows) |y| {
        if (y > 0) try aw.writer.writeAll("\r\n");
        try aw.writer.print("{d:0>6} ", .{frame});
        var col: usize = 7;
        while (col + 16 <= fill_cols) : (col += 16) {
            try aw.writer.print("stable row {d:0>3} ", .{y});
        }
        try aw.writer.writeAll("\x1b[K");
    }
    stream.nextSlice(aw.writer.buffered());
}

/// One line of colored text ending in a newline, for scroll frames.
fn scrollLine() []const u8 {
    var line: []const u8 = "\r\n";
    var color: u8 = 1;
    var col: usize = 0;
    while (col + 8 <= cols) : (col += 8) {
        line = line ++ std.fmt.comptimePrint("\x1b[3{d}mscr\u{d4}lls ", .{color});
        color = if (color == 6) 1 else color + 1;
    }
    return line ++ "\x1b[0m";
}

/// Mirror App.clearRenderDirty.
fn clearDirty(render_state: *vt.RenderState) void {
    for (render_state.row_data.items(.dirty)) |*dirty| dirty.* = false;
    render_state.dirty = .false;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn report(
    w: *std.Io.Writer,
    name: []const u8,
    ns_total: i96,
    iters: usize,
    bytes_per_iter: ?usize,
) !void {
    const ns_per = @as(f64, @floatFromInt(ns_total)) / @as(f64, @floatFromInt(iters));
    try w.print("{s:<36} {d:>9.3} ms/frame", .{ name, ns_per / 1e6 });
    if (bytes_per_iter) |bytes| {
        // bytes per nanosecond == GB/s.
        try w.print("  {d:>7.2} GB/s", .{@as(f64, @floatFromInt(bytes)) / ns_per});
    }
    try w.writeAll("\n");
}

fn reportShapeStats(w: *std.Io.Writer, stats: Renderer.ShapeStats) !void {
    const total = stats.cache_hits + stats.cache_misses;
    const hit_rate: f64 = if (total == 0)
        0
    else
        @as(f64, @floatFromInt(stats.cache_hits)) * 100 / @as(f64, @floatFromInt(total));
    const cells_per_miss: f64 = if (stats.cache_misses == 0)
        0
    else
        @as(f64, @floatFromInt(stats.shaped_cells)) / @as(f64, @floatFromInt(stats.cache_misses));
    try w.print(
        "  shape cache: {d} hits, {d} misses ({d:.1}% hit), {d:.1} cells/miss, {d} clears\n",
        .{ stats.cache_hits, stats.cache_misses, hit_rate, cells_per_miss, stats.cache_clears },
    );
}

fn reportCellDamageStats(w: *std.Io.Writer, stats: Renderer.CellDamageStats) !void {
    const changed_rate: f64 = if (stats.scanned_cells == 0)
        0
    else
        @as(f64, @floatFromInt(stats.changed_cells)) * 100 /
            @as(f64, @floatFromInt(stats.scanned_cells));
    const span_rate: f64 = if (stats.scanned_cells == 0)
        0
    else
        @as(f64, @floatFromInt(stats.spanned_cells)) * 100 /
            @as(f64, @floatFromInt(stats.scanned_cells));
    try w.print(
        "  cell damage: {d} dirty rows ({d} unchanged), {d}/{d} cells changed ({d:.2}%), {d} spanned ({d:.2}%)\n",
        .{
            stats.dirty_rows,
            stats.unchanged_dirty_rows,
            stats.changed_cells,
            stats.scanned_cells,
            changed_rate,
            stats.spanned_cells,
            span_rate,
        },
    );
}
