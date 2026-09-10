//! End-to-end integration test for TC-Wayland.
//! Launches Compositor and Client, connects over Wayland socket, creates cell buffer,
//! commits to surface, verifies 2D canvas composition, tests keyboard input and theme broadcast.

const std = @import("std");
const tc = @import("../tc.zig");
const CompactCell = tc.CompactCell;
const RichCell = tc.RichCell;

fn sleepMs(ms: u32) void {
    const ts: std.os.linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

test "TC-Wayland end-to-end client-server protocol interaction" {
    const allocator = std.testing.allocator;

    // 1. Initialize Compositor with isolated socket name (40 cols x 10 rows)
    const test_socket = "tc-test-wayland-0";
    var comp = try tc.Compositor.init(allocator, test_socket, 40, 10);
    defer comp.deinit();

    var running: std.atomic.Value(bool) = .init(true);

    const ServerRunner = struct {
        fn run(c: *tc.Compositor, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                c.dispatch(10) catch break;
            }
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ comp, &running });
    defer {
        running.store(false, .release);
        comp.stop();
        server_thread.join();
    }

    // Small yield to let server start loop
    sleepMs(10);

    // 2. Connect Client using compositor socket name
    var client = try tc.Client.connect(allocator, test_socket);
    defer client.deinit();

    // Verify theme broadcast was received by client
    try std.testing.expect(client.last_theme != null);
    if (client.last_theme) |theme| {
        try std.testing.expectEqualStrings("Monstar Dark", theme.name);
        try std.testing.expect(theme.is_dark);
    }

    // 3. Client creates grid surface
    _ = try client.createGridSurface();
    try client.roundtrip();

    // Verify client received configure event
    try std.testing.expect(client.last_configure != null);
    if (client.last_configure) |cfg| {
        try std.testing.expectEqual(@as(u32, 40), cfg.cols);
        try std.testing.expectEqual(@as(u32, 10), cfg.rows);
    }

    // 4. Client creates compact_v1 cell buffer (12 cols x 3 rows)
    const cols: u32 = 12;
    const rows: u32 = 3;
    var cells: [cols * rows]CompactCell = undefined;
    for (&cells) |*c| {
        c.* = CompactCell.ascii(' ', 7, 0);
    }

    // Draw text: "TC-WAYLAND"
    const text = "TC-WAYLAND";
    for (text, 0..) |ch, i| {
        cells[cols + 1 + i] = CompactCell.ascii(ch, 2, 0); // green text
    }

    const cell_bytes = std.mem.sliceAsBytes(&cells);
    const buffer = try client.createCellBuffer(cols, rows, .compact_v1, cell_bytes);

    // 5. Attach buffer and commit
    try client.commitBuffer(buffer, cols, rows);
    try client.roundtrip();

    // Allow compositor pass to run
    sleepMs(20);

    const rendered = try comp.renderToString(allocator);
    defer allocator.free(rendered);

    // Verify that "TC-WAYLAND" appears in the rendered composited scene
    try std.testing.expect(std.mem.indexOf(u8, rendered, "TC-WAYLAND") != null);

    // 6. Structured keyboard event test: Compositor -> Client
    comp.sendKey("Enter", "\r", .{}, .pressed);
    sleepMs(10);
    try client.dispatch();

    try std.testing.expect(client.received_keys.items.len > 0);
    const last_key = client.received_keys.items[client.received_keys.items.len - 1];
    try std.testing.expectEqualStrings("Enter", last_key.key_name);
    try std.testing.expectEqualStrings("\r", last_key.utf8_text);
    try std.testing.expectEqual(.pressed, last_key.state);
}

test "TC-Wayland split terminal panes, resizing, and overlay z-index" {
    const allocator = std.testing.allocator;

    const test_socket = "tc-test-wayland-2";
    var comp = try tc.Compositor.init(allocator, test_socket, 80, 24);
    defer comp.deinit();

    var running: std.atomic.Value(bool) = .init(true);
    const ServerRunner = struct {
        fn run(c: *tc.Compositor, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                c.dispatch(10) catch break;
            }
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ comp, &running });
    defer {
        running.store(false, .release);
        comp.stop();
        server_thread.join();
    }

    sleepMs(10);

    var client = try tc.Client.connect(allocator, test_socket);
    defer client.deinit();

    // Primary terminal: initially 80x24 at (0, 0)
    var primary_xpty = try tc.Xpty.init(allocator, client, 80, 24);
    defer primary_xpty.deinit();
    primary_xpty.is_simulated = true;

    // Layer shell overlay
    const comp_wl = client.compositor orelse return error.NoCompositor;
    const overlay_surf = try comp_wl.createSurface();
    defer overlay_surf.destroy();

    const layer_surf = try client.layer_shell.?.getLayerSurface(overlay_surf, null, .overlay, "test-overlay");
    defer layer_surf.destroy();

    const grid = try client.zterm_compositor.?.getGridSurface(overlay_surf);
    defer grid.destroy();
    grid.setTitle("Test Overlay");

    try client.roundtrip();
    sleepMs(10);

    // Verify overlay has overlay z-index on compositor side
    comp.lock();
    var overlay_found = false;
    for (comp.surfaces.items) |s| {
        if (s.title) |t| {
            if (std.mem.indexOf(u8, t, "Overlay") != null) {
                try std.testing.expectEqual(@as(i32, 100), s.z_index);
                overlay_found = true;
            }
        }
    }
    comp.unlock();
    try std.testing.expect(overlay_found);

    // Split right: primary becomes 40x24 at (0,0), split becomes 40x24 at (40, 0)
    primary_xpty.setPosition(0, 0);
    try primary_xpty.resize(40, 24);
    try std.testing.expectEqual(@as(u32, 40), primary_xpty.cols);

    var split_xpty = try tc.Xpty.init(allocator, client, 40, 24);
    defer split_xpty.deinit();
    split_xpty.is_simulated = true;
    split_xpty.setPosition(40, 0);

    try std.testing.expectEqual(@as(u32, 40), split_xpty.cols);
    try std.testing.expectEqual(@as(u32, 24), split_xpty.rows);

    // Resize window: e.g. 100 cols x 30 rows -> both splits resize to 50x30
    try comp.resize(100, 30);
    try primary_xpty.resize(50, 30);
    try split_xpty.resize(50, 30);
    split_xpty.setPosition(50, 0);

    try std.testing.expectEqual(@as(u32, 50), primary_xpty.cols);
    try std.testing.expectEqual(@as(u32, 50), split_xpty.cols);
    try std.testing.expectEqual(@as(u32, 30), primary_xpty.rows);
    try std.testing.expectEqual(@as(u32, 30), split_xpty.rows);
}

test "TC-Wayland pixel buffer creation, wl_shm, and overlay rendering" {
    const allocator = std.testing.allocator;

    const test_socket = "tc-test-pixel-0";
    var comp = try tc.Compositor.init(allocator, test_socket, 40, 10);
    defer comp.deinit();

    var running: std.atomic.Value(bool) = .init(true);
    const ServerRunner = struct {
        fn run(c: *tc.Compositor, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                c.dispatch(10) catch break;
            }
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ comp, &running });
    defer {
        running.store(false, .release);
        comp.stop();
        server_thread.join();
    }

    sleepMs(10);

    var client = try tc.Client.connect(allocator, test_socket);
    defer client.deinit();

    // 1. Create grid surface
    _ = try client.createGridSurface();
    try client.roundtrip();

    // 2. Create ARGB8888 pixel buffer via createPixelBuffer
    const width: u32 = 8;
    const height: u32 = 8;
    var pixel_data: [width * height]u32 = undefined;
    // 50% transparent red
    for (&pixel_data) |*p| p.* = 0x80800000;
    const pixel_bytes = std.mem.sliceAsBytes(&pixel_data);

    const pixel_buf = try client.createPixelBuffer(width, height, .argb8888, pixel_bytes);
    try client.commitBuffer(pixel_buf, width, height);
    try client.roundtrip();
    sleepMs(20);

    // Verify compositor received pixel buffer
    comp.lock();
    var found_pixel_buf = false;
    for (comp.surfaces.items) |s| {
        if (s.current_buffer) |b| {
            if (b.isPixel()) {
                try std.testing.expectEqual(tc.Buffer.Format.argb8888, b.format);
                try std.testing.expectEqual(@as(u32, 8), b.cols);
                try std.testing.expectEqual(@as(u32, 8), b.rows);
                found_pixel_buf = true;
            }
        }
    }
    comp.unlock();
    try std.testing.expect(found_pixel_buf);

    // 3. Test standard Wayland wl_shm pixel buffer
    const shm_fd = try std.posix.memfd_create("tc-test-shm", 0);
    defer _ = std.os.linux.close(shm_fd);
    const shm_size: usize = width * height * 4;
    _ = std.c.ftruncate(shm_fd, @intCast(shm_size));
    var shm_pixels: [width * height]u32 = undefined;
    for (&shm_pixels) |*p| p.* = 0xFF00FF00; // opaque green
    _ = std.c.write(shm_fd, std.mem.sliceAsBytes(&shm_pixels).ptr, shm_size);

    const wayland_shm_buf = try client.createShmPixelBuffer(
        shm_fd,
        shm_size,
        @intCast(width),
        @intCast(height),
        @intCast(width * 4),
        .argb8888,
    );
    try client.commitBuffer(wayland_shm_buf, width, height);
    try client.roundtrip();
    sleepMs(20);

    comp.lock();
    var found_shm_buf = false;
    for (comp.surfaces.items) |s| {
        if (s.current_buffer) |b| {
            if (b.isPixel()) {
                try std.testing.expectEqual(tc.Buffer.Format.argb8888, b.format);
                try std.testing.expectEqual(@as(u32, 8), b.cols);
                try std.testing.expectEqual(@as(u32, 8), b.rows);
                const slice = b.asPixelSlice();
                try std.testing.expectEqual(@as(u32, 0xFF00FF00), slice[0]);
                found_shm_buf = true;
            }
        }
    }
    comp.unlock();
    try std.testing.expect(found_shm_buf);
}

test "TC-Wayland stream-safe chunked cell buffer upload over SSH-friendly transport" {
    const allocator = std.testing.allocator;

    const test_socket = "tc-test-chunked-0";
    var comp = try tc.Compositor.init(allocator, test_socket, 80, 24);
    defer comp.deinit();

    var running: std.atomic.Value(bool) = .init(true);
    const ServerRunner = struct {
        fn run(c: *tc.Compositor, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                c.dispatch(10) catch break;
            }
        }
    };

    const server_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ comp, &running });
    defer {
        running.store(false, .release);
        comp.stop();
        server_thread.join();
    }

    sleepMs(10);

    var client = try tc.Client.connect(allocator, test_socket);
    defer client.deinit();

    // Verify buffer_factory global was bound
    try std.testing.expect(client.buffer_factory != null);

    // Create grid surface
    _ = try client.createGridSurface();
    try client.roundtrip();

    // 80 cols x 24 rows = 1920 cells = 15,360 bytes (spans ~5 chunks of 3072 bytes)
    const cols: u32 = 80;
    const rows: u32 = 24;
    const total_cells = cols * rows;
    const cells = try allocator.alloc(CompactCell, total_cells);
    defer allocator.free(cells);

    for (cells) |*c| {
        c.* = CompactCell.ascii(' ', 7, 0);
    }

    // Write text near start (chunk 1)
    const text_start = "CHUNK-START";
    for (text_start, 0..) |ch, i| {
        cells[i] = CompactCell.ascii(ch, 2, 0);
    }

    // Write text in the middle (chunk 3, around row 12)
    const text_mid = "CHUNK-MIDDLE";
    const mid_idx = 12 * cols + 10;
    for (text_mid, 0..) |ch, i| {
        cells[mid_idx + i] = CompactCell.ascii(ch, 3, 0);
    }

    // Write text near the end (chunk 5, row 23)
    const text_end = "CHUNK-END";
    const end_idx = 23 * cols + 20;
    for (text_end, 0..) |ch, i| {
        cells[end_idx + i] = CompactCell.ascii(ch, 4, 0);
    }

    const cell_bytes = std.mem.sliceAsBytes(cells);
    try std.testing.expect(cell_bytes.len > 4096);

    const buffer = try client.createCellBuffer(cols, rows, .compact_v1, cell_bytes);
    try client.commitBuffer(buffer, cols, rows);
    try client.roundtrip();

    sleepMs(20);

    // Verify compositor rendered all chunks across the full 80x24 canvas
    const rendered = try comp.renderToString(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "CHUNK-START") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CHUNK-MIDDLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CHUNK-END") != null);
}

test "TC-Wayland prompt visibility restored after interactive xpty exit" {
    const allocator = std.testing.allocator;
    const test_socket = "tc-test-prompt-exit-0";
    var comp = try tc.Compositor.init(allocator, test_socket, 80, 24);
    defer comp.deinit();

    var running: std.atomic.Value(bool) = .init(true);
    const ServerRunner = struct {
        fn run(c: *tc.Compositor, r: *std.atomic.Value(bool)) void {
            while (r.load(.acquire)) {
                c.dispatch(10) catch break;
            }
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ comp, &running });
    defer {
        running.store(false, .release);
        comp.stop();
        server_thread.join();
    }

    sleepMs(10);

    var client = try tc.Client.connect(allocator, test_socket);
    defer client.deinit();

    const PromptSurface = @import("../shell/PromptSurface.zig");
    var prompt = try PromptSurface.init(allocator, client, 80);
    defer prompt.deinit();

    prompt.setPosition(0, 23);
    prompt.render();
    try prompt.commit();
    try client.roundtrip();
    sleepMs(10);

    comp.composite();
    var rendered = try comp.renderToString(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":tc>") != null);
    allocator.free(rendered);

    // Hide prompt and launch interactive job (like less)
    prompt.setPosition(0, -100);
    _ = client.display.flush();

    var xpty = try tc.Xpty.init(allocator, client, 80, 24);
    xpty.is_simulated = true;
    xpty.setPosition(0, 0);
    try xpty.commit();
    try client.roundtrip();
    sleepMs(10);

    // Now close the interactive job (exactly like closeJob does)
    xpty.deinit();
    prompt.setPosition(0, 23);
    try client.roundtrip();
    sleepMs(10);

    // DO WHAT closeJob + render DOES:
    comp.composite();
    rendered = try comp.renderToString(allocator);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, ":tc>") != null);
}
