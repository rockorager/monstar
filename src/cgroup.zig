//! Transient systemd scope isolation for the child process: asks the
//! session systemd manager (via D-Bus) to move the shell into its own
//! cgroup so OOM kills and resource accounting apply to the shell's
//! process tree instead of the whole terminal.

const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const DbusConnection = @import("dbus/Connection.zig");

const log = std.log.scoped(.cgroup);

pub const Error = error{ScopeFailed};

const scope_prefix = "app-monstar-transient-";
const scope_suffix = ".scope";
/// Largest scope name: prefix + decimal u32 + suffix.
pub const scope_name_max = scope_prefix.len + 10 + scope_suffix.len;

/// Whether the system was booted with systemd; without it there is no
/// manager to create transient scopes.
pub fn systemdBooted() bool {
    const rc = linux.faccessat(linux.AT.FDCWD, "/run/systemd/system", linux.F_OK, 0);
    return linux.errno(rc) == .SUCCESS;
}

/// An in-flight StartTransientUnit request. Created by
/// `startMoveIntoScope`; the caller must consume it with either
/// `finish` (confirm the migration, then release the gated child) or
/// `cancel` (abandon it on an error path).
pub const Pending = struct {
    connection: if (build_options.enable_dbus) *DbusConnection else void,
    serial: if (build_options.enable_dbus) u32 else void,
    pid: u32,

    /// Wait for systemd's reply and for the pid migration to become
    /// visible in /proc. Both typically completed while the caller was
    /// doing other setup, so this rarely blocks. The caller is expected
    /// to keep the child gated (see Pty.SpawnOptions.gate_child) until
    /// this returns so grandchildren cannot escape into the terminal's
    /// cgroup.
    pub fn finish(self: Pending) Error!void {
        if (!build_options.enable_dbus) return;
        var reply = self.connection.waitForReply(self.serial, 1000) catch
            return error.ScopeFailed;
        defer reply.deinit();

        var name_buf: [scope_name_max + 1]u8 = undefined;
        const name = fmtScope(&name_buf, self.pid);
        if (reply.messageType() == .error_reply) {
            log.warn("StartTransientUnit {s} failed: {s}", .{
                name,
                reply.header.error_name orelse "unknown error",
            });
            return error.ScopeFailed;
        }
        if (reply.messageType() != .method_return) return error.ScopeFailed;

        try waitForMigration(self.pid, name);
        log.debug("child {d} moved into {s}", .{ self.pid, name });
    }

    pub fn cancel(self: Pending) void {
        if (!build_options.enable_dbus) return;
        // Cancel is only used while unwinding App initialization, which closes
        // the connection and discards the outstanding reply immediately.
        _ = self;
    }
};

/// Ask systemd to create a transient scope containing `pid`, without
/// waiting for the reply: the round trip to systemd and the cgroup
/// migration proceed while the caller does other setup. Confirm with
/// `Pending.finish` before releasing the gated child.
pub fn startMoveIntoScope(connection: *DbusConnection, pid: u32) Error!Pending {
    var name_buf: [scope_name_max + 1]u8 = undefined;
    const name = fmtScope(&name_buf, pid);
    const serial = try startTransientUnit(connection, name, pid);
    return .{ .connection = connection, .serial = serial, .pid = pid };
}

/// Unit name for the child's scope. Follows the XDG cgroup naming
/// convention (app-<app>-<unique>.scope) so desktop tools recognize it.
fn fmtScope(buf: []u8, pid: u32) [:0]const u8 {
    std.debug.assert(buf.len > scope_name_max);
    return std.mem.printSentinel(buf, scope_prefix ++ "{d}" ++ scope_suffix, .{pid}, 0) catch unreachable;
}

fn startTransientUnit(connection: *DbusConnection, name: [:0]const u8, pid: u32) Error!u32 {
    var body: DbusConnection.Encoder = .init(connection.allocator);
    defer body.deinit();
    body.string(name) catch return error.ScopeFailed;
    // "fail" makes systemd error out if the unit already exists instead
    // of replacing it.
    body.string("fail") catch return error.ScopeFailed;

    const props = body.beginArray(8) catch return error.ScopeFailed;
    appendPidsProperty(&body, pid) catch return error.ScopeFailed;
    // Let systemd-oomd kill this scope on memory pressure instead of an
    // ancestor cgroup that contains the terminal.
    appendStringProperty(&body, "ManagedOOMMemoryPressure", "kill") catch
        return error.ScopeFailed;
    body.endArray(props) catch return error.ScopeFailed;

    // Auxiliary units: unused, but the call signature requires the array.
    const aux = body.beginArray(8) catch return error.ScopeFailed;
    body.endArray(aux) catch return error.ScopeFailed;

    // Async send: the reply is collected later by Pending.finish. The
    // encoded message is written immediately, so systemd starts working
    // while the caller continues setup.
    return connection.sendMethod(.{
        .destination = "org.freedesktop.systemd1",
        .path = "/org/freedesktop/systemd1",
        .interface = "org.freedesktop.systemd1.Manager",
        .member = "StartTransientUnit",
    }, "ssa(sv)a(sa(sv))", body.bytes(), &.{}) catch error.ScopeFailed;
}

/// StartTransientUnit's reply means the job is queued, not that the PID
/// has been written into the new cgroup, so poll /proc until the move
/// is visible (or give up after ~250ms). Migration typically lands
/// within a few ms, so back off exponentially from 200µs: the common
/// case waits roughly the true latency instead of a coarse quantum.
fn waitForMigration(pid: u32, name: []const u8) Error!void {
    const budget_ns = 250 * std.time.ns_per_ms;
    var sleep_ns: u64 = 200 * std.time.ns_per_us;
    var waited_ns: u64 = 0;
    while (waited_ns < budget_ns) {
        var buf: [4096]u8 = undefined;
        if (readCgroupFile(&buf, pid)) |data| {
            if (leafCgroup(data)) |current| {
                if (std.mem.eql(u8, current, name)) return;
            }
        }
        const ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(sleep_ns) };
        _ = linux.nanosleep(&ts, null);
        waited_ns += sleep_ns;
        sleep_ns = @min(sleep_ns * 2, 10 * std.time.ns_per_ms);
    }
    log.warn("migration into {s} not observed in time", .{name});
    return error.ScopeFailed;
}

fn readCgroupFile(buf: []u8, pid: u32) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/proc/{d}/cgroup", .{pid}, 0) catch
        unreachable; // 32 bytes always fits "/proc/" + u32 + "/cgroup"

    const open_rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    const read_rc = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(read_rc) != .SUCCESS) return null;
    return buf[0..read_rc];
}

/// Leaf cgroup name from /proc/<pid>/cgroup contents: the cgroup v2
/// (unified) entry is the line starting with "0::".
fn leafCgroup(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trimEnd(u8, line, " \r");
        if (!std.mem.startsWith(u8, path, "0::")) continue;
        const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        return path[idx + 1 ..];
    }
    return null;
}

/// ("PIDs", variant au [pid]): the process systemd adopts into the scope.
fn appendPidsProperty(body: *DbusConnection.Encoder, pid: u32) !void {
    try body.structAlignment();
    try body.string("PIDs");
    try body.variantSignature("au");
    const pids = try body.beginArray(4);
    try body.uint32(pid);
    try body.endArray(pids);
}

fn appendStringProperty(
    body: *DbusConnection.Encoder,
    name: []const u8,
    value: []const u8,
) !void {
    try body.structAlignment();
    try body.string(name);
    try body.variantSignature("s");
    try body.string(value);
}

test "fmtScope" {
    var buf: [scope_name_max + 1]u8 = undefined;
    try std.testing.expectEqualStrings(
        "app-monstar-transient-1234.scope",
        fmtScope(&buf, 1234),
    );
    try std.testing.expectEqualStrings(
        "app-monstar-transient-4294967295.scope",
        fmtScope(&buf, std.math.maxInt(u32)),
    );
}

test "leafCgroup" {
    try std.testing.expectEqualStrings(
        "session-1.scope",
        leafCgroup("0::/user.slice/user-1000.slice/session-1.scope\n").?,
    );
    // Hybrid layout: v1 controller lines are skipped.
    const hybrid =
        "12:pids:/user.slice\n" ++
        "1:name=systemd:/user.slice/other.scope\n" ++
        "0::/user.slice/app-monstar-transient-99.scope\n";
    try std.testing.expectEqualStrings(
        "app-monstar-transient-99.scope",
        leafCgroup(hybrid).?,
    );
    try std.testing.expect(leafCgroup("") == null);
    try std.testing.expect(leafCgroup("12:pids:/user.slice\n") == null);
}
