//! Tests for tc-shell stationary prompt and command execution blocks.

const std = @import("std");
const PromptSurface = @import("PromptSurface.zig");
const CommandBlock = @import("CommandBlock.zig");
const SessionState = @import("SessionState.zig");

extern "c" fn popen(command: [*:0]const u8, modes: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fgets(s: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;

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

    // Test changeDirectory
    const initial_cwd = try allocator.dupe(u8, session.getCwd());
    defer allocator.free(initial_cwd);
    try session.changeDirectory("/tmp");
    try std.testing.expectEqualStrings("/tmp", session.getCwd());
    try std.testing.expectEqualStrings(initial_cwd, session.old_pwd.?);

    if (popen("pwd", "r")) |p| {
        var buf: [256]u8 = undefined;
        if (fgets(&buf, buf.len, p)) |_| {
            const out = std.mem.sliceTo(&buf, 0);
            try std.testing.expect(std.mem.startsWith(u8, out, "/tmp"));
        }
        _ = pclose(p);
    }

    try session.changeDirectory(initial_cwd);

    // Test parseBuiltin
    const b_cd = SessionState.parseBuiltin("cd /tmp");
    try std.testing.expectEqualStrings("/tmp", b_cd.cd.?);

    const b_pwd = SessionState.parseBuiltin("pwd");
    try std.testing.expect(b_pwd == .pwd);

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

    const b_copy_screen = SessionState.parseBuiltin("copy screen");
    try std.testing.expect(b_copy_screen.copy.is_screen);

    const b_copy_default = SessionState.parseBuiltin("copy");
    try std.testing.expect(b_copy_default.copy.is_screen);

    const b_copy_all = SessionState.parseBuiltin("copy all");
    try std.testing.expect(b_copy_all.copy.is_all);

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
    const pid = std.os.linux.getpid();
    var expected_pipe_prefix_buf: [64]u8 = undefined;
    const expected_pipe_prefix = try std.fmt.bufPrint(&expected_pipe_prefix_buf, "cat /proc/{d}/fd/", .{pid});

    const expanded_pipe = try SessionState.expandPipeline(allocator, &blocks, "$1 | grep line1");
    defer allocator.free(expanded_pipe);
    try std.testing.expect(std.mem.startsWith(u8, expanded_pipe, expected_pipe_prefix));
    try std.testing.expect(std.mem.endsWith(u8, expanded_pipe, " | grep line1"));

    // Test redirection expansion
    const expanded_redir = try SessionState.expandPipeline(allocator, &blocks, "$1 > test.txt");
    defer allocator.free(expanded_redir);
    try std.testing.expect(std.mem.startsWith(u8, expanded_redir, expected_pipe_prefix));
    try std.testing.expect(std.mem.endsWith(u8, expanded_redir, " > test.txt"));

    const expanded_redir_nospace = try SessionState.expandPipeline(allocator, &blocks, "$1>test.txt");
    defer allocator.free(expanded_redir_nospace);
    try std.testing.expect(std.mem.startsWith(u8, expanded_redir_nospace, expected_pipe_prefix));
    try std.testing.expect(std.mem.endsWith(u8, expanded_redir_nospace, " >test.txt"));

    const expanded_append = try SessionState.expandPipeline(allocator, &blocks, "$prev >> output.log");
    defer allocator.free(expanded_append);
    try std.testing.expect(std.mem.startsWith(u8, expanded_append, expected_pipe_prefix));
    try std.testing.expect(std.mem.endsWith(u8, expanded_append, " >> output.log"));

    // Test multi-arg expansion
    var expected_diff_prefix_buf: [64]u8 = undefined;
    const expected_diff_prefix = try std.fmt.bufPrint(&expected_diff_prefix_buf, "diff /proc/{d}/fd/", .{pid});

    const expanded_diff = try SessionState.expandPipeline(allocator, &blocks, "diff $1 $2");
    defer allocator.free(expanded_diff);
    try std.testing.expect(std.mem.startsWith(u8, expanded_diff, expected_diff_prefix));
}

test "SessionState isAllTarget matching" {
    try std.testing.expect(SessionState.isAllTarget("all"));
    try std.testing.expect(SessionState.isAllTarget("$all"));
    try std.testing.expect(SessionState.isAllTarget("*"));
    try std.testing.expect(SessionState.isAllTarget("  all  "));
    try std.testing.expect(!SessionState.isAllTarget("$1"));
    try std.testing.expect(!SessionState.isAllTarget("$prev"));
    try std.testing.expect(!SessionState.isAllTarget(""));
}

test "interactive commands identify less and pager tools" {
    const TcShellApp = @import("TcShellApp.zig");
    try std.testing.expect(TcShellApp.isInteractiveCommand("less file.txt"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("/usr/bin/less -R /tmp/log"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("vim test.zig"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("htop"));
    try std.testing.expect(!TcShellApp.isInteractiveCommand("ls -la"));
    try std.testing.expect(!TcShellApp.isInteractiveCommand("cat foo.txt"));
}
