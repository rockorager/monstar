//! Pseudo-terminal handling: opens a master/slave PTY pair and spawns a
//! child process attached to the slave side as its controlling terminal.

const Pty = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.pty);

master: posix.fd_t,
slave: posix.fd_t,

pub const Error = error{PtyFailed};

/// Open a master/slave PTY pair with the given window size.
pub fn open(size: posix.winsize) Error!Pty {
    const master = openRw("/dev/ptmx") orelse return error.PtyFailed;
    errdefer _ = linux.close(master);

    // Unlock the slave side, then resolve its /dev/pts/N path.
    var unlock: c_int = 0;
    try check(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)));
    var pts_num: c_uint = undefined;
    try check(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pts_num)));

    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{pts_num}) catch
        unreachable; // 32 bytes always fits "/dev/pts/" + u32

    const slave = openRw(path) orelse return error.PtyFailed;
    errdefer _ = linux.close(slave);

    try check(linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&size)));

    return .{ .master = master, .slave = slave };
}

pub fn deinit(self: *Pty) void {
    _ = linux.close(self.master);
    if (self.slave >= 0) _ = linux.close(self.slave);
    self.* = undefined;
}

/// Fork and exec `path` with the slave side as the child's controlling
/// terminal and stdio. Returns the child pid; the slave fd is closed in
/// the parent so that EOF is observable on the master when the child exits.
///
/// `argv` and `envp` must outlive the call in the parent (the child copies
/// them into its own image via execve).
pub fn spawn(
    self: *Pty,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) Error!posix.pid_t {
    std.debug.assert(self.slave >= 0);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.PtyFailed;
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // Child. Only async-signal-safe calls from here on.
        _ = linux.setsid();
        _ = linux.ioctl(self.slave, linux.T.IOCSCTTY, 0);
        _ = linux.dup2(self.slave, 0);
        _ = linux.dup2(self.slave, 1);
        _ = linux.dup2(self.slave, 2);
        _ = linux.close(self.master);
        if (self.slave > 2) _ = linux.close(self.slave);
        _ = linux.execve(path, argv, envp);
        linux.exit(127); // exec failed
    }

    // Parent: the slave belongs to the child now.
    _ = linux.close(self.slave);
    self.slave = -1;
    return pid;
}

/// Propagate a new window size to the PTY (and thus the child via SIGWINCH).
pub fn setWinsize(self: *Pty, size: posix.winsize) Error!void {
    try check(linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&size)));
}

/// Wait for the child to exit; returns its wait status.
pub fn wait(pid: posix.pid_t) Error!u32 {
    var status: u32 = undefined;
    try check(linux.wait4(pid, &status, 0, null));
    return status;
}

fn openRw(path: [*:0]const u8) ?posix.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) {
        log.err("open {s} failed: {}", .{ path, linux.errno(rc) });
        return null;
    }
    return @intCast(rc);
}

fn check(rc: usize) Error!void {
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        log.err("syscall failed: {}", .{err});
        return error.PtyFailed;
    }
}

test "pty open and resize" {
    var pty: Pty = try .open(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer pty.deinit();
    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
}
