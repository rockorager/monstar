//! Tests for tc-shell stationary prompt and command execution blocks.

const std = @import("std");
const PromptSurface = @import("PromptSurface.zig");
const CommandBlock = @import("CommandBlock.zig");
const SessionState = @import("SessionState.zig");

test "CommandBlock basic lifecycle and status" {
    const allocator = std.testing.allocator;

    var block = try CommandBlock.init(allocator, 1, "echo 'hello tc-shell'");
    defer block.deinit();

    try std.testing.expectEqualStrings("echo 'hello tc-shell'", block.command);
    try std.testing.expectEqual(CommandBlock.Status.running, block.status);
    try std.testing.expectEqual(@as(usize, 1), block.id);

    try block.appendOutput("hello tc-shell\nsecond line\n");
    try std.testing.expectEqual(@as(usize, 2), block.output_lines.items.len);
    try std.testing.expectEqualStrings("hello tc-shell", block.output_lines.items[0]);
    try std.testing.expectEqualStrings("second line", block.output_lines.items[1]);

    block.finish(0, 15);
    try std.testing.expectEqual(CommandBlock.Status.success, block.status);
    try std.testing.expectEqual(@as(u8, 0), block.exit_code.?);
    try std.testing.expectEqual(@as(u64, 15), block.elapsed_ms);

    // Memfd verification
    if (block.getMemfd()) |fd| {
        var read_buf: [64]u8 = undefined;
        const rc = std.os.linux.read(fd, &read_buf, read_buf.len);
        try std.testing.expect(rc > 0);
        try std.testing.expect(std.mem.startsWith(u8, read_buf[0..rc], "hello tc-shell\nsecond line\n"));
    }
}

test "SessionState environment and builtins parsing" {
    const allocator = std.testing.allocator;

    var session = try SessionState.init(allocator);
    defer session.deinit();

    try session.setEnv("TEST_VAR", "monstar_value");
    try std.testing.expectEqualStrings("monstar_value", session.getEnv("TEST_VAR").?);

    session.unsetEnv("TEST_VAR");
    try std.testing.expect(session.getEnv("TEST_VAR") == null);

    // Test parseBuiltin
    const b_cd = SessionState.parseBuiltin("cd /tmp");
    try std.testing.expectEqualStrings("/tmp", b_cd.cd.?);

    const b_collapse = SessionState.parseBuiltin("collapse $2");
    try std.testing.expectEqualStrings("$2", b_collapse.collapse);

    const b_collapse_default = SessionState.parseBuiltin("collapse");
    try std.testing.expectEqualStrings("$prev", b_collapse_default.collapse);

    const b_expand = SessionState.parseBuiltin("expand $1");
    try std.testing.expectEqualStrings("$1", b_expand.expand);

    const b_copy_cmd = SessionState.parseBuiltin("copy $1.cmd");
    try std.testing.expectEqualStrings("$1", b_copy_cmd.copy.target);
    try std.testing.expect(b_copy_cmd.copy.is_cmd);

    const b_copy_out = SessionState.parseBuiltin("copy $prev");
    try std.testing.expectEqualStrings("$prev", b_copy_out.copy.target);
    try std.testing.expect(!b_copy_out.copy.is_cmd);

    const b_run = SessionState.parseBuiltin("run $3");
    try std.testing.expectEqualStrings("$3", b_run.run);

    const b_edit = SessionState.parseBuiltin("edit $2");
    try std.testing.expectEqualStrings("$2", b_edit.edit);

    const b_rm = SessionState.parseBuiltin("rm $1");
    try std.testing.expectEqualStrings("$1", b_rm.rm);

    const b_view = SessionState.parseBuiltin("view $1");
    try std.testing.expectEqualStrings("$1", b_view.view);
}

test "SessionState block resolution and pipeline expansion" {
    const allocator = std.testing.allocator;

    var b1 = try CommandBlock.init(allocator, 1, "cat file.txt");
    defer b1.deinit();
    try b1.appendOutput("line1\nline2\n");
    b1.finish(0, 5);

    var b2 = try CommandBlock.init(allocator, 2, "echo foo");
    defer b2.deinit();
    try b2.appendOutput("foo\n");
    b2.finish(0, 2);

    const blocks = [_]*CommandBlock{ b1, b2 };

    const resolved_1 = SessionState.resolveBlock(&blocks, "$1");
    try std.testing.expect(resolved_1.? == b1);

    const resolved_prev = SessionState.resolveBlock(&blocks, "$prev");
    try std.testing.expect(resolved_prev.? == b2);

    // Test pipeline expansion
    const expanded_pipe = try SessionState.expandPipeline(allocator, &blocks, "$1 | grep line1");
    defer allocator.free(expanded_pipe);
    try std.testing.expect(std.mem.startsWith(u8, expanded_pipe, "cat /proc/self/fd/"));
    try std.testing.expect(std.mem.endsWith(u8, expanded_pipe, " | grep line1"));

    // Test multi-arg expansion
    const expanded_diff = try SessionState.expandPipeline(allocator, &blocks, "diff $1 $2");
    defer allocator.free(expanded_diff);
    try std.testing.expect(std.mem.startsWith(u8, expanded_diff, "diff /proc/self/fd/"));
}
