//! OSC 133 command timing and completion-notification policy. Only C/D markers
//! change the timer; focus is checked at completion, and alternate-screen use
//! does not cancel a command. The caller performs bell and desktop actions.

const CommandNotification = @This();

const std = @import("std");
const vt = @import("ghostty-vt");
const Config = @import("Config.zig");

started_ns: ?i96 = null,

pub const Completion = struct {
    duration: std.Io.Duration,
    exit_code: u8,
};

/// Feed a semantic marker with an awake-clock timestamp in nanoseconds.
/// A completion consumes the timer even when policy suppresses notification.
pub fn update(
    self: *CommandNotification,
    command: vt.osc.Command.SemanticPrompt,
    now_ns: i96,
    config: *const Config,
    focused: bool,
) ?Completion {
    switch (command.action) {
        .end_input_start_output => {
            self.started_ns = now_ns;
            return null;
        },
        .end_command => {},
        else => return null,
    }
    const started = self.started_ns orelse return null;
    self.started_ns = null;
    std.debug.assert(now_ns >= started);
    const elapsed = now_ns - started;
    if (elapsed <= config.notify_on_command_finish_after) return null;
    switch (config.notify_on_command_finish) {
        .never => return null,
        .unfocused => if (focused) return null,
        .always => {},
    }
    // Match Ghostty: absent status is success; out-of-range statuses fail.
    const raw = command.readOption(.exit_code) orelse 0;
    return .{
        .duration = .fromNanoseconds(elapsed),
        .exit_code = std.math.cast(u8, raw) orelse 1,
    };
}

test "completion policy uses focus at finish and strictly exceeds threshold" {
    for ([_]struct {
        policy: Config.NotifyOnCommandFinish,
        focused: bool,
        elapsed: i96 = 5_000_000_001,
        notify: bool,
    }{
        .{ .policy = .never, .focused = false, .notify = false },
        .{ .policy = .unfocused, .focused = true, .notify = false },
        .{ .policy = .unfocused, .focused = false, .notify = true },
        .{ .policy = .always, .focused = true, .notify = true },
        .{ .policy = .always, .focused = false, .notify = true },
        .{ .policy = .always, .focused = false, .elapsed = 4_999_999_999, .notify = false },
        .{ .policy = .always, .focused = false, .elapsed = 5_000_000_000, .notify = false },
    }) |case| {
        var state: CommandNotification = .{};
        const config: Config = .{ .notify_on_command_finish = case.policy };
        try std.testing.expectEqual(null, state.update(.init(.end_input_start_output), 123, &config, !case.focused));
        const completion = state.update(.init(.end_command), 123 + case.elapsed, &config, case.focused);
        try std.testing.expectEqual(case.notify, completion != null);
        if (completion) |value| try std.testing.expectEqual(case.elapsed, value.duration.nanoseconds);
        try std.testing.expectEqual(null, state.started_ns);
        try std.testing.expectEqual(null, state.update(.init(.end_command), 20_000_000_000, &config, false));
    }
}

test "command markers restart timing and parse exit status" {
    var state: CommandNotification = .{};
    const config: Config = .{ .notify_on_command_finish = .always, .notify_on_command_finish_after = 0 };
    try std.testing.expectEqual(null, state.update(.init(.end_command), 0, &config, false));
    for ([_]struct { options: []const u8, code: u8 }{
        .{ .options = "", .code = 0 },
        .{ .options = "0", .code = 0 },
        .{ .options = "17", .code = 17 },
        .{ .options = "255", .code = 255 },
        .{ .options = "256", .code = 1 },
        .{ .options = "-1", .code = 1 },
    }) |case| {
        _ = state.update(.init(.end_input_start_output), 10, &config, false);
        _ = state.update(.init(.end_input_start_output), 40, &config, false);
        _ = state.update(.init(.fresh_line_new_prompt), 50, &config, false);
        _ = state.update(.init(.end_prompt_start_input), 60, &config, false);
        const completion = state.update(.{
            .action = .end_command,
            .options_unvalidated = case.options,
        }, 90, &config, true).?;
        try std.testing.expectEqual(@as(i96, 50), completion.duration.nanoseconds);
        try std.testing.expectEqual(case.code, completion.exit_code);
    }
}
