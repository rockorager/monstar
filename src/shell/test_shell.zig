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
    try std.testing.expect(TcShellApp.isInteractiveCommand("kak"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("kak file.txt"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("/usr/bin/kak src/main.zig"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("sudo kak /etc/hosts"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("sudo -E kak /etc/hosts"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("env FOO=bar kak"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("hx"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("helix src/main.zig"));
    try std.testing.expect(TcShellApp.isInteractiveCommand("fzf"));
    try std.testing.expect(!TcShellApp.isInteractiveCommand("ls -la"));
    try std.testing.expect(!TcShellApp.isInteractiveCommand("cat foo.txt"));
}

test "renderRowText parses ANSI SGR color sequences for ls and diff" {
    const TcShellApp = @import("TcShellApp.zig");
    const Compositor = @import("../tc/Compositor.zig");

    var canvas: [20]Compositor.CanvasCell = undefined;
    for (&canvas) |*c| {
        c.* = .{};
    }

    const palette = [_]u32{
        0x000000FF, // 0: black
        0xFF0000FF, // 1: red
        0x00FF00FF, // 2: green
        0xFFFF00FF, // 3: yellow
        0x0000FFFF, // 4: blue
        0xFF00FFFF, // 5: magenta
        0x00FFFFFF, // 6: cyan
        0xFFFFFFFF, // 7: white
        0x555555FF, // 8: bright black
        0xFF5555FF, // 9: bright red
        0x55FF55FF, // 10: bright green
        0xFFFF55FF, // 11: bright yellow
        0x5555FFFF, // 12: bright blue
        0xFF55FFFF, // 13: bright magenta
        0x55FFFFFF, // 14: bright cyan
        0xFFFFFFFF, // 15: bright white
    };

    // Test text containing colored output like jj diff --stat or ls:
    // \x1b[32m+10\x1b[0m \x1b[31m-2\x1b[0m
    const text = "\x1b[32m+10\x1b[0m \x1b[31m-2\x1b[0m";
    TcShellApp.renderRowText(&canvas, 20, 0, text, 0xCCCCCCFF, 0x000000FF, false, palette);

    // canvas[0] should be '+' in green (palette[2])
    try std.testing.expectEqual(@as(u32, '+'), canvas[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0x00FF00FF), canvas[0].fg_rgba);

    // canvas[1] should be '1' in green
    try std.testing.expectEqual(@as(u32, '1'), canvas[1].codepoint);
    try std.testing.expectEqual(@as(u32, 0x00FF00FF), canvas[1].fg_rgba);

    // canvas[2] should be '0' in green
    try std.testing.expectEqual(@as(u32, '0'), canvas[2].codepoint);
    try std.testing.expectEqual(@as(u32, 0x00FF00FF), canvas[2].fg_rgba);

    // canvas[3] should be ' ' in default fg (0xCCCCCCFF)
    try std.testing.expectEqual(@as(u32, ' '), canvas[3].codepoint);
    try std.testing.expectEqual(@as(u32, 0xCCCCCCFF), canvas[3].fg_rgba);

    // canvas[4] should be '-' in red (palette[1])
    try std.testing.expectEqual(@as(u32, '-'), canvas[4].codepoint);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), canvas[4].fg_rgba);

    // canvas[5] should be '2' in red
    try std.testing.expectEqual(@as(u32, '2'), canvas[5].codepoint);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), canvas[5].fg_rgba);
}

test "tc-shell keeps top of running command block at top of screen" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");

    var blocks: std.ArrayList(*CommandBlock) = .empty;
    defer {
        for (blocks.items) |b| b.deinit();
        blocks.deinit(allocator);
    }

    // Block 1: 10 lines of output (1 header + 10 lines = 11 lines)
    var b1 = try CommandBlock.init(allocator, 1, "echo first");
    for (0..10) |_| {
        try b1.appendOutput("line\n");
    }
    b1.finish(0, 5);
    try blocks.append(allocator, b1);

    // Block 2: running command with 50 lines of output (exceeding canvas of 23 rows)
    var b2 = try CommandBlock.init(allocator, 2, "ls --help");
    for (0..50) |_| {
        try b2.appendOutput("help option\n");
    }
    try blocks.append(allocator, b2);

    const max_canvas_rows: usize = 23;
    var app: TcShellApp = undefined;
    app.blocks = blocks;
    app.jobs = .empty;
    app.scroll_offset = 0;
    app.pinned_block_id = 2; // Pinned to block 2

    // While b2 is running, skip_lines should be 11 (the start line of b2)
    // so b2's header appears at row 0 (top of the screen)
    try std.testing.expectEqual(@as(usize, 11), app.getSkipLines(max_canvas_rows));

    // When b2 finishes with 50 lines, it still fills the screen, so its header stays at row 0
    b2.finish(0, 10);
    try std.testing.expectEqual(@as(usize, 11), app.getSkipLines(max_canvas_rows));
}

test "getBlockContentHeight returns xpty rows for embedded job" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const Xpty = @import("../tc/Xpty.zig");

    var blocks: std.ArrayList(*CommandBlock) = .empty;
    defer {
        for (blocks.items) |b| b.deinit();
        blocks.deinit(allocator);
    }

    var b1 = try CommandBlock.init(allocator, 1, "htop");
    try blocks.append(allocator, b1);

    var app: TcShellApp = undefined;
    app.allocator = allocator;
    app.blocks = blocks;
    app.jobs = .empty;
    defer app.jobs.deinit(allocator);
    app.cols = 80;
    app.rows = 24;

    var xpty = try Xpty.init(allocator, null, 80, 12);
    defer xpty.deinit();

    try app.jobs.append(allocator, .{
        .block_id = 1,
        .xpty = xpty,
        .suspended = false,
        .is_fullscreen = false, // embedded live TUI
        .user_demoted = true,
    });

    // Content height should match embedded job rows (12)
    try std.testing.expectEqual(@as(usize, 12), app.getBlockContentHeight(b1));

    // When folded, content height should be 0
    b1.folded = true;
    try std.testing.expectEqual(@as(usize, 0), app.getBlockContentHeight(b1));

    // When fullscreen, embedded content height is 0 (overlay mode)
    b1.folded = false;
    app.jobs.items[0].is_fullscreen = true;
    try std.testing.expectEqual(@as(usize, 0), app.getBlockContentHeight(b1));
}

test "formatCellsToBlock creates ANSI styled lines from cells" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const abi = @import("../tc/abi.zig");
    const CompactCell = abi.CompactCell;

    var b = try CommandBlock.init(allocator, 1, "htop");
    defer b.deinit();

    var app: TcShellApp = undefined;
    app.allocator = allocator;

    var cells: [4]CompactCell = undefined;
    cells[0] = CompactCell.ascii('C', 2, 0); // green
    cells[1] = CompactCell.ascii('P', 2, 0);
    cells[2] = CompactCell.ascii('U', 2, 0);
    cells[3] = CompactCell.ascii(' ', 7, 0);

    try app.formatCellsToBlock(b, &cells, 4, 1);
    try std.testing.expectEqual(@as(usize, 1), b.output_lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, b.output_lines.items[0], "CPU") != null);
    try std.testing.expect(std.mem.startsWith(u8, b.output_lines.items[0], "\x1b[0;38;5;2;48;5;0m"));
}

test "formatCellsToBlock trims trailing blank rows" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const abi = @import("../tc/abi.zig");
    const CompactCell = abi.CompactCell;

    var b = try CommandBlock.init(allocator, 1, "htop");
    defer b.deinit();

    var app: TcShellApp = undefined;
    app.allocator = allocator;

    // 4 cols x 10 rows grid, but only first 2 rows have content
    var cells: [40]CompactCell = undefined;
    for (&cells) |*cell| cell.* = CompactCell.ascii(' ', 7, 0);
    cells[0] = CompactCell.ascii('h', 7, 0);
    cells[4] = CompactCell.ascii('o', 7, 0);

    try app.formatCellsToBlock(b, &cells, 4, 10);
    try std.testing.expectEqual(@as(usize, 2), b.output_lines.items.len);
}

test "closeJob on non-interactive command preserves streamed output without trailing blank rows" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const Xpty = @import("../tc/Xpty.zig");

    var blocks: std.ArrayList(*CommandBlock) = .empty;
    defer {
        for (blocks.items) |b| b.deinit();
        blocks.deinit(allocator);
    }

    var b1 = try CommandBlock.init(allocator, 1, "ls");
    try b1.appendOutput("file1\nfile2\n");
    try blocks.append(allocator, b1);

    var app: TcShellApp = undefined;
    app.allocator = allocator;
    app.blocks = blocks;
    app.jobs = .empty;
    defer app.jobs.deinit(allocator);
    app.cols = 80;
    app.rows = 24;
    app.active_job_id = null;
    app.client = null;

    var xpty = try Xpty.init(allocator, null, 80, 24);
    errdefer xpty.deinit();

    try app.jobs.append(allocator, .{
        .block_id = 1,
        .xpty = xpty,
        .suspended = false,
        .is_fullscreen = false,
        .user_demoted = false,
        .is_interactive = false, // regular shell command (ls)
    });

    app.closeJob(1, 0);

    // b1 output_lines must NOT be overwritten with 24 empty terminal rows
    try std.testing.expectEqual(@as(usize, 2), b1.output_lines.items.len);
    try std.testing.expectEqualStrings("file1", b1.output_lines.items[0]);
    try std.testing.expectEqualStrings("file2", b1.output_lines.items[1]);
}

test "ls followed by demoted vim preview block has no huge gap" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const Xpty = @import("../tc/Xpty.zig");

    var blocks: std.ArrayList(*CommandBlock) = .empty;
    defer {
        for (blocks.items) |b| b.deinit();
        blocks.deinit(allocator);
    }

    // 1. ls command block with 1 line of output
    var b1 = try CommandBlock.init(allocator, 1, "ls");
    try b1.appendOutput("build.zig  src/\n");
    b1.finish(0, 10);
    try blocks.append(allocator, b1);

    // 2. vim command block with demoted preview job
    const b2 = try CommandBlock.init(allocator, 2, "vim");
    try blocks.append(allocator, b2);

    var app: TcShellApp = undefined;
    app.allocator = allocator;
    app.blocks = blocks;
    app.jobs = .empty;
    defer app.jobs.deinit(allocator);
    app.cols = 80;
    app.rows = 24;
    app.scroll_offset = 0;
    app.pinned_block_id = 2; // Pinned to demoted vim job

    var xpty = try Xpty.init(allocator, null, 80, 12);
    defer xpty.deinit();

    try app.jobs.append(allocator, .{
        .block_id = 2,
        .xpty = xpty,
        .suspended = false,
        .is_fullscreen = false,
        .user_demoted = true,
        .is_interactive = true,
    });

    // Content height of ls is 1 line, vim is 12 rows
    try std.testing.expectEqual(@as(usize, 1), app.getBlockContentHeight(b1));
    try std.testing.expectEqual(@as(usize, 12), app.getBlockContentHeight(b2));

    // Total lines = 1 (b1 header) + 1 (b1 out) + 1 (b2 header) + 12 (b2 out) = 15
    const max_canvas_rows: usize = 23;
    try std.testing.expectEqual(@as(usize, 0), app.getSkipLines(max_canvas_rows));
}

test "isInteractiveShell detects shells and filters batch commands" {
    const TcShellApp = @import("TcShellApp.zig");

    // Interactive shells
    try std.testing.expect(TcShellApp.isInteractiveShell("bash"));
    try std.testing.expect(TcShellApp.isInteractiveShell("/bin/bash"));
    try std.testing.expect(TcShellApp.isInteractiveShell("fish"));
    try std.testing.expect(TcShellApp.isInteractiveShell("zsh"));
    try std.testing.expect(TcShellApp.isInteractiveShell("sh"));
    try std.testing.expect(TcShellApp.isInteractiveShell("nu"));
    try std.testing.expect(TcShellApp.isInteractiveShell("bash -l"));
    try std.testing.expect(TcShellApp.isInteractiveShell("bash --login"));
    try std.testing.expect(TcShellApp.isInteractiveShell("sudo bash"));
    try std.testing.expect(TcShellApp.isInteractiveShell("env FOO=bar fish"));

    // Batch script execution should NOT be classified as interactive shells
    try std.testing.expect(!TcShellApp.isInteractiveShell("bash -c \"echo hi\""));
    try std.testing.expect(!TcShellApp.isInteractiveShell("bash script.sh"));
    try std.testing.expect(!TcShellApp.isInteractiveShell("sh build.sh"));
    try std.testing.expect(!TcShellApp.isInteractiveShell("fish -c ls"));
    try std.testing.expect(!TcShellApp.isInteractiveShell("echo bash"));
    try std.testing.expect(!TcShellApp.isInteractiveShell("cat file | bash"));
    try std.testing.expect(!TcShellApp.isInteractiveShell("ls -la"));
}

test "interactive shell job does not demote without alternate screen" {
    const allocator = std.testing.allocator;
    const TcShellApp = @import("TcShellApp.zig");
    const Xpty = @import("../tc/Xpty.zig");

    var xpty = try Xpty.init(allocator, null, 80, 24);
    defer xpty.deinit();

    var job: TcShellApp.InteractiveJob = .{
        .block_id = 1,
        .xpty = xpty,
        .suspended = false,
        .is_fullscreen = true,
        .is_interactive = true,
        .promoted_by_alt_screen = false,
    };

    // Shell is on primary screen (not alternate screen)
    try std.testing.expect(!job.xpty.isAlternateScreen());

    // Demotion condition only triggers if promoted_by_alt_screen is true
    const would_demote = !job.xpty.isAlternateScreen() and job.is_fullscreen and job.promoted_by_alt_screen and !job.suspended;
    try std.testing.expect(!would_demote);
    try std.testing.expect(job.is_fullscreen);

    // If an alt-screen TUI enters alt-screen, it gets marked as promoted_by_alt_screen
    job.promoted_by_alt_screen = true;
    const tui_would_demote = !job.xpty.isAlternateScreen() and job.is_fullscreen and job.promoted_by_alt_screen and !job.suspended;
    try std.testing.expect(tui_would_demote);
}
