//! Transient systemd scope isolation for the child process: asks the
//! session systemd manager (via D-Bus) to move the shell into its own
//! cgroup so OOM kills and resource accounting apply to the shell's
//! process tree instead of the whole terminal.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const build_options = @import("build_options");

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
    call: if (build_options.enable_dbus) *c.DBusPendingCall else void,
    pid: u32,

    /// Wait for systemd's reply and for the pid migration to become
    /// visible in /proc. Both typically completed while the caller was
    /// doing other setup, so this rarely blocks. The caller is expected
    /// to keep the child gated (see Pty.SpawnOptions.gate_child) until
    /// this returns so grandchildren cannot escape into the terminal's
    /// cgroup.
    pub fn finish(self: Pending) Error!void {
        if (!build_options.enable_dbus) return;
        defer c.dbus_pending_call_unref(self.call);
        c.dbus_pending_call_block(self.call);
        const reply = c.dbus_pending_call_steal_reply(self.call) orelse
            return error.ScopeFailed;
        defer c.dbus_message_unref(reply);

        var name_buf: [scope_name_max + 1]u8 = undefined;
        const name = fmtScope(&name_buf, self.pid);
        if (c.dbus_message_get_type(reply) == c.DBUS_MESSAGE_TYPE_ERROR) {
            const error_name = c.dbus_message_get_error_name(reply);
            log.warn("StartTransientUnit {s} failed: {s}", .{
                name,
                if (error_name) |e| std.mem.span(e) else "unknown error",
            });
            return error.ScopeFailed;
        }

        try waitForMigration(self.pid, name);
        log.debug("child {d} moved into {s}", .{ self.pid, name });
    }

    pub fn cancel(self: Pending) void {
        if (!build_options.enable_dbus) return;
        c.dbus_pending_call_cancel(self.call);
        c.dbus_pending_call_unref(self.call);
    }
};

/// Ask systemd to create a transient scope containing `pid`, without
/// waiting for the reply: the round trip to systemd and the cgroup
/// migration proceed while the caller does other setup. Confirm with
/// `Pending.finish` before releasing the gated child.
pub fn startMoveIntoScope(connection: *c.DBusConnection, pid: u32) Error!Pending {
    var name_buf: [scope_name_max + 1]u8 = undefined;
    const name = fmtScope(&name_buf, pid);
    const call = try startTransientUnit(connection, name, pid);
    return .{ .call = call, .pid = pid };
}

/// Unit name for the child's scope. Follows the XDG cgroup naming
/// convention (app-<app>-<unique>.scope) so desktop tools recognize it.
fn fmtScope(buf: []u8, pid: u32) [:0]const u8 {
    std.debug.assert(buf.len > scope_name_max);
    return std.fmt.bufPrintZ(buf, scope_prefix ++ "{d}" ++ scope_suffix, .{pid}) catch unreachable;
}

fn startTransientUnit(connection: *c.DBusConnection, name: [:0]const u8, pid: u32) Error!*c.DBusPendingCall {
    const message = c.dbus_message_new_method_call(
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
    ) orelse return error.ScopeFailed;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);

    var name_ptr: [*:0]const u8 = name.ptr;
    try appendBasic(&iter, c.DBUS_TYPE_STRING, &name_ptr);
    // "fail" makes systemd error out if the unit already exists instead
    // of replacing it.
    var mode: [*:0]const u8 = "fail";
    try appendBasic(&iter, c.DBUS_TYPE_STRING, &mode);

    var props: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "(sv)", &props) == 0)
        return error.ScopeFailed;
    try appendPidsProperty(&props, pid);
    // Let systemd-oomd kill this scope on memory pressure instead of an
    // ancestor cgroup that contains the terminal.
    try appendStringProperty(&props, "ManagedOOMMemoryPressure", "kill");
    if (c.dbus_message_iter_close_container(&iter, &props) == 0) return error.ScopeFailed;

    // Auxiliary units: unused, but the call signature requires the array.
    var aux: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "(sa(sv))", &aux) == 0)
        return error.ScopeFailed;
    if (c.dbus_message_iter_close_container(&iter, &aux) == 0) return error.ScopeFailed;

    // Async send: the reply is collected later by Pending.finish. The
    // flush pushes the request onto the socket now so systemd starts
    // working while the caller continues setup.
    var call: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(connection, message, &call, 1000) == 0)
        return error.ScopeFailed;
    const pending = call orelse return error.ScopeFailed;
    c.dbus_connection_flush(connection);
    return pending;
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
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cgroup", .{pid}) catch
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

fn appendBasic(iter: *c.DBusMessageIter, type_: c_int, value: anytype) Error!void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.ScopeFailed;
}

/// ("PIDs", variant au [pid]): the process systemd adopts into the scope.
fn appendPidsProperty(props: *c.DBusMessageIter, pid: u32) Error!void {
    var entry: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(props, c.DBUS_TYPE_STRUCT, null, &entry) == 0)
        return error.ScopeFailed;
    var key: [*:0]const u8 = "PIDs";
    try appendBasic(&entry, c.DBUS_TYPE_STRING, &key);
    var variant: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "au", &variant) == 0)
        return error.ScopeFailed;
    var pids: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&variant, c.DBUS_TYPE_ARRAY, "u", &pids) == 0)
        return error.ScopeFailed;
    var pid_value: u32 = pid;
    try appendBasic(&pids, c.DBUS_TYPE_UINT32, &pid_value);
    if (c.dbus_message_iter_close_container(&variant, &pids) == 0) return error.ScopeFailed;
    if (c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.ScopeFailed;
    if (c.dbus_message_iter_close_container(props, &entry) == 0) return error.ScopeFailed;
}

fn appendStringProperty(props: *c.DBusMessageIter, name: [:0]const u8, value: [:0]const u8) Error!void {
    var entry: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(props, c.DBUS_TYPE_STRUCT, null, &entry) == 0)
        return error.ScopeFailed;
    var name_ptr: [*:0]const u8 = name;
    try appendBasic(&entry, c.DBUS_TYPE_STRING, &name_ptr);
    var variant: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "s", &variant) == 0)
        return error.ScopeFailed;
    var value_ptr: [*:0]const u8 = value;
    try appendBasic(&variant, c.DBUS_TYPE_STRING, &value_ptr);
    if (c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.ScopeFailed;
    if (c.dbus_message_iter_close_container(props, &entry) == 0) return error.ScopeFailed;
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
