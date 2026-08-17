//! Bidirectional coprocess management for --attach and --share streams.
//!
//! Spawns an external command with piped stdin/stdout and sets both
//! descriptors to non-blocking mode.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;

const log = std.log.scoped(.coprocess);

const Coprocess = @This();

child: std.process.Child,
io: Io,
stdin_fd: posix.fd_t,
stdout_fd: posix.fd_t,
child_id: posix.pid_t,

/// Spawn a shell command with piped stdin and stdout.
pub fn spawn(io: Io, command: []const u8) !Coprocess {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const stdin_fd = child.stdin.?.handle;
    const stdout_fd = child.stdout.?.handle;
    const child_id = child.id orelse 0;

    try setNonblocking(stdin_fd);
    try setNonblocking(stdout_fd);

    return .{
        .child = child,
        .io = io,
        .stdin_fd = stdin_fd,
        .stdout_fd = stdout_fd,
        .child_id = child_id,
    };
}

/// Close pipes and cleanly terminate the child process if running.
pub fn deinit(self: *Coprocess) void {
    if (self.stdin_fd >= 0) {
        _ = linux.close(self.stdin_fd);
        self.stdin_fd = -1;
    }
    if (self.stdout_fd >= 0) {
        _ = linux.close(self.stdout_fd);
        self.stdout_fd = -1;
    }
    if (self.child_id > 0) {
        _ = linux.kill(self.child_id, linux.SIG.TERM);
        var status: u32 = undefined;
        _ = linux.wait4(self.child_id, &status, linux.W.NOHANG, null);
        self.child_id = 0;
        self.child.id = null;
    }
}

/// Try writing bytes to the coprocess stdin without blocking.
pub fn writeNonblocking(self: *const Coprocess, bytes: []const u8) usize {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(self.stdin_fd, bytes.ptr + offset, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => offset += rc,
            .INTR => continue,
            .AGAIN => break,
            .PIPE, .IO => break,
            else => |err| {
                log.err("coprocess write failed: {}", .{err});
                break;
            },
        }
    }
    return offset;
}

fn setNonblocking(fd: posix.fd_t) !void {
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.SetNonblockingFailed;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

test "coprocess spawn and echo test" {
    const testing = std.testing;

    var proc = try spawn(testing.io, "cat");
    defer proc.deinit();

    const msg = "hello coprocess";
    const written = proc.writeNonblocking(msg);
    try testing.expectEqual(msg.len, written);
}
