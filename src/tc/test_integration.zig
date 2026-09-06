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
