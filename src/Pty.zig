//! Pseudo-terminal handling: opens a master/slave PTY pair and spawns a
//! child process attached to the slave side as its controlling terminal.

const Pty = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.pty);

master: posix.fd_t,
slave: posix.fd_t,
/// Write end of the spawn gate pipe (-1 when unused): the child blocks
/// just before exec until `releaseChild` closes it.
gate: posix.fd_t,

pub const Error = error{PtyFailed};

pub const SpawnOptions = struct {
    /// Child working directory. Null inherits the parent's cwd.
    cwd: ?[*:0]const u8 = null,
    /// Hold the child just before exec until `releaseChild` is called
    /// (or the Pty is deinitialized). Lets the parent move the child
    /// into a cgroup before it can spawn grandchildren.
    gate_child: bool = false,
};

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

    return .{ .master = master, .slave = slave, .gate = -1 };
}

pub fn deinit(self: *Pty) void {
    self.releaseChild();
    self.closeMaster();
    if (self.slave >= 0) _ = linux.close(self.slave);
    self.* = undefined;
}

/// Release a gated child (see SpawnOptions.gate_child): the child sees
/// EOF on the gate pipe and proceeds to exec.
pub fn releaseChild(self: *Pty) void {
    if (self.gate >= 0) {
        _ = linux.close(self.gate);
        self.gate = -1;
    }
}

pub fn closeMaster(self: *Pty) void {
    if (self.master >= 0) {
        _ = linux.close(self.master);
        self.master = -1;
    }
}

/// Fork and exec `path` with the slave side as the child's controlling
/// terminal and stdio. Returns the child pid.
///
/// The parent keeps its slave fd open for the pty's lifetime: with a
/// slave always open, the master can never return EIO/EOF/HUP, so a
/// child that transiently closes every slave fd (some shells reopen
/// their tty at startup) is a non-event instead of a failure mode.
/// Child exit is detected via SIGCHLD, never via the master.
///
/// `argv` and `envp` must outlive the call in the parent (the child copies
/// them into its own image via execve).
pub fn spawn(
    self: *Pty,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: SpawnOptions,
) Error!posix.pid_t {
    std.debug.assert(self.slave >= 0);
    std.debug.assert(self.gate == -1);

    var gate_fds: [2]posix.fd_t = .{ -1, -1 };
    if (options.gate_child) {
        try check(linux.pipe2(&gate_fds, .{ .CLOEXEC = true }));
    }

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        if (options.gate_child) {
            _ = linux.close(gate_fds[0]);
            _ = linux.close(gate_fds[1]);
        }
        return error.PtyFailed;
    }
    const pid: posix.pid_t = @intCast(fork_rc);

    if (pid == 0) {
        // Child. Only async-signal-safe calls from here on.
        // The parent blocks SIGCHLD for its signalfd; the child must
        // start with a clean signal mask (shells need SIGCHLD).
        const empty_mask = posix.sigemptyset();
        posix.sigprocmask(linux.SIG.SETMASK, &empty_mask, null);
        if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.ioctl(self.slave, linux.T.IOCSCTTY, 0)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(self.slave, 0)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(self.slave, 1)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(self.slave, 2)) != .SUCCESS) linux.exit(126);
        _ = linux.close(self.master);
        if (self.slave > 2) _ = linux.close(self.slave);
        if (options.cwd) |cwd| {
            if (linux.errno(linux.chdir(cwd)) != .SUCCESS) linux.exit(126);
        }
        if (options.gate_child) {
            // Close our copy of the write end so the parent closing
            // its end is observable as EOF. A byte or EOF both mean go;
            // retry on signal interruption.
            _ = linux.close(gate_fds[1]);
            var byte: [1]u8 = undefined;
            while (true) {
                const rc = linux.read(gate_fds[0], &byte, 1);
                if (linux.errno(rc) != .INTR) break;
            }
            _ = linux.close(gate_fds[0]);
        }
        _ = linux.execve(path, argv, envp);
        linux.exit(127); // exec failed
    }

    // Parent: keep our slave fd (see doc comment); it is CLOEXEC so it
    // cannot leak into exec'd children.
    if (options.gate_child) {
        _ = linux.close(gate_fds[0]);
        self.gate = gate_fds[1];
    }
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

/// Reap the child if it has exited; null while it is still running.
pub fn tryWait(pid: posix.pid_t) Error!?u32 {
    var status: u32 = undefined;
    const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
    return switch (linux.errno(rc)) {
        .SUCCESS => if (rc == 0) null else status,
        .CHILD => 0,
        else => |err| {
            log.err("wait4 failed: {}", .{err});
            return error.PtyFailed;
        },
    };
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
