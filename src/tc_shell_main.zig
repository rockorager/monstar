//! Main entry point for standalone tc-shell application.
//! Run with `monstar-tc-shell` or `zig build tc-shell`.

const std = @import("std");
const shell = @import("shell.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var app = try shell.TcShellApp.init(allocator);
    defer app.deinit();

    try app.run();
}
