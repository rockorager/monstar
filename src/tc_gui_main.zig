//! Main entry point for the standalone TC-Wayland GUI terminal emulator.
//! Run with `monstar-tc-gui` or `zig build tc-gui`.

const std = @import("std");
const TcGuiApp = @import("tc/TcGuiApp.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var app = try TcGuiApp.init(allocator);
    defer app.deinit();

    try app.run();
}
