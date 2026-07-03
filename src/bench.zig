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
    const config = Config.load(arena, init.minimal.environ);

    var font: Font = try .init(alloc, config.font_family, config.font_size);
    defer font.deinit(alloc);
    var renderer: Renderer = try .init(alloc, &font, .{});
    defer renderer.deinit();

    const width: u31 = font.cell_width * cols;
    const height: u31 = font.cell_height * rows;

    var term: vt.Terminal = try .init(init.io, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = config.scrollback,
        .colors = config.terminalColors(),
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
        "grid {d}x{d}, {d}x{d} px ({d:.1} MB frame), font {s} {d}px\n\n",
        .{
            cols,                                          rows,
            width,                                         height,
            @as(f64, @floatFromInt(pixels.len * 4)) / 1e6, config.font_family,
            config.font_size,
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

    // End-to-end scroll frame: one new line fed, then the same path
    // App.render takes (scroll detection, update, blit or full render).
    // This is the hot path when a program streams output.
    {
        const scroll_line = comptime scrollLine();
        const iters = 100;
        var blitted: usize = 0;
        const start = nowNs(init.io);
        for (0..iters) |_| {
            stream.nextSlice(scroll_line);
            const scroll = try renderer.detectScroll(&render_state, &term);
            const old_cursor = render_state.cursor;
            try render_state.update(alloc, &term);
            if (scroll) |s| {
                const old_cursor_row: ?usize = if (old_cursor.viewport) |viewport| viewport.y else null;
                try renderer.renderScrolled(&render_state, pixels, width, height, s, old_cursor_row);
                blitted += 1;
            } else {
                try renderer.render(&render_state, pixels, width, height);
            }
            clearDirty(&render_state);
        }
        try report(w, "scroll frame (feed+update+render)", nowNs(init.io) - start, iters, null);
        if (blitted != iters) try w.print("  (!) only {d}/{d} frames took the blit path\n", .{ blitted, iters });

        // Compare the blit path against a full render of the same
        // state (using the shm buffer as scratch). Accent overhang
        // re-blits blend over their own previous pixels at repaint
        // boundaries, so anti-aliased edge pixels may drift slightly;
        // anything beyond a small channel delta is a real bug.
        stream.nextSlice(scroll_line);
        const scroll = try renderer.detectScroll(&render_state, &term);
        const old_cursor = render_state.cursor;
        try render_state.update(alloc, &term);
        if (scroll) |s| {
            const old_cursor_row: ?usize = if (old_cursor.viewport) |viewport| viewport.y else null;
            try renderer.renderScrolled(&render_state, pixels, width, height, s, old_cursor_row);
            try renderer.render(&render_state, shm, width, height);
            var diff_count: usize = 0;
            var max_delta: u8 = 0;
            for (pixels, shm) |a, b| {
                if (a == b) continue;
                diff_count += 1;
                const ab: [4]u8 = @bitCast(a);
                const bb: [4]u8 = @bitCast(b);
                for (ab, bb) |ca, cb| {
                    max_delta = @max(max_delta, if (ca > cb) ca - cb else cb - ca);
                }
            }
            try w.print("scroll blit vs full render: {d} pixels differ, max channel delta {d}\n", .{ diff_count, max_delta });
        } else {
            try w.writeAll("scroll blit verification: no scroll detected\n");
        }
        clearDirty(&render_state);
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

    // Frame copy strategies: what App.render pays to move render_pixels
    // into the wl_shm buffer, before and after damage tracking.
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
}

/// Fill every grid row with colored words and park the cursor at the
/// bottom so later newlines scroll.
fn fillScreen(alloc: std.mem.Allocator, stream: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    for (0..rows) |y| {
        if (y > 0) try aw.writer.writeAll("\r\n");
        var col: usize = 0;
        var color: u8 = 1;
        while (col + 8 <= cols) : (col += 8) {
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
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("\x1b[H");
    for (0..rows) |y| {
        if (y > 0) try aw.writer.writeAll("\r\n");
        var col: usize = 0;
        var color: u8 = 1;
        while (col + 8 <= cols) : (col += 8) {
            try aw.writer.print("\x1b[4{d};30mpanels  ", .{color});
            color = if (color == 6) 1 else color + 1;
        }
        try aw.writer.writeAll("\x1b[0m");
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
