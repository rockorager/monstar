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

test "TC-Wayland command palette file and live grep selection prints filepath to xpty" {
    const allocator = std.testing.allocator;

    const test_socket = "tc-test-wayland-1";
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

    var xpty = try tc.Xpty.init(allocator, client, 80, 24);
    defer xpty.deinit();
    xpty.is_simulated = true;

    var palette = try tc.CommandPalette.init(allocator, client, 60, 10);
    defer palette.deinit();

    palette.show();

    // 1. Test File Search selection
    palette.mode = .file_search;
    palette.query_len = 0;
    palette.selected_idx = 0;
    try std.testing.expect(palette.file_list.items.len > 0);

    const first_file = palette.file_list.items[0];
    const file_act = palette.handleKey("Enter", "");
    switch (file_act) {
        .select_file => |path| {
            try std.testing.expectEqualStrings(first_file, path);
            try xpty.sendInput(path);
            const input = xpty.sim_input_buf[0..xpty.sim_input_len];
            try std.testing.expect(std.mem.indexOf(u8, input, path) != null);
        },
        else => return error.ExpectedSelectFile,
    }

    // 2. Test Live Grep selection
    palette.show();
    palette.mode = .live_grep;
    try palette.runLiveGrep("Compositor");
    try std.testing.expect(palette.grep_list.items.len > 0);

    palette.selected_idx = 0;
    const grep_act = palette.handleKey("Enter", "");
    switch (grep_act) {
        .select_file => |path| {
            try std.testing.expect(path.len > 0);
            // Must be a pure filepath without line numbers or colons
            try std.testing.expect(std.mem.indexOfScalar(u8, path, ':') == null);
            try xpty.sendInput(path);
            const input = xpty.sim_input_buf[0..xpty.sim_input_len];
            try std.testing.expect(std.mem.indexOf(u8, input, path) != null);
        },
        else => return error.ExpectedSelectFile,
    }
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

    // Command palette overlay
    var palette = try tc.CommandPalette.init(allocator, client, 60, 10);
    defer palette.deinit();

    try client.roundtrip();
    sleepMs(10);

    // Verify palette has overlay z-index on compositor side
    comp.lock();
    var palette_found = false;
    for (comp.surfaces.items) |s| {
        if (s.title) |t| {
            if (std.mem.indexOf(u8, t, "Palette") != null) {
                try std.testing.expectEqual(@as(i32, 100), s.z_index);
                palette_found = true;
            }
        }
    }
    comp.unlock();
    try std.testing.expect(palette_found);

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
