//! Tests for tc-shell stationary prompt and command execution blocks.

const std = @import("std");
const PromptSurface = @import("PromptSurface.zig");
const CommandBlock = @import("CommandBlock.zig");

test "CommandBlock basic lifecycle and status" {
    const allocator = std.testing.allocator;

    var block = try CommandBlock.init(allocator, "echo 'hello tc-shell'");
    defer block.deinit();

    try std.testing.expectEqualStrings("echo 'hello tc-shell'", block.command);
    try std.testing.expectEqual(CommandBlock.Status.running, block.status);

    try block.appendOutput("hello tc-shell");
    try std.testing.expectEqual(@as(usize, 1), block.output_lines.items.len);
    try std.testing.expectEqualStrings("hello tc-shell", block.output_lines.items[0]);

    block.finish(0, 15);
    try std.testing.expectEqual(CommandBlock.Status.success, block.status);
    try std.testing.expectEqual(@as(u8, 0), block.exit_code.?);
    try std.testing.expectEqual(@as(u64, 15), block.elapsed_ms);
}
