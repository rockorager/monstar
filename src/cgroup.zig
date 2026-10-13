//! Optional cgroup isolation: moves child processes (the shell at
//! startup, detached new windows) into their own cgroup so OOM kills and
//! resource accounting apply to that process tree instead of the whole
//! terminal. Two backend structs implement the mechanism, chosen once at
//! startup by `probe`:
//!
//! - SystemdBackend: transient scopes via StartTransientUnit over the
//!   session bus; used when booted under systemd. With -Ddbus=false the
//!   caller's session bus handle is a void placeholder, so probe can
//!   never select it — systemd scopes cannot work without D-Bus.
//! - CgroupfsBackend: mkdir plus cgroup.procs writes under a base cgroup
//!   (the configured linux-cgroup-path, or our own cgroup); used when the
//!   v2 hierarchy is mounted and the base is writable, i.e. a subtree was
//!   delegated to us (see contrib/pam-cgroup-userwork).

const std = @import("std");
const linux = std.os.linux;
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

/// Dereference the caller's session bus handle: a live connection, or
/// null when the handle is empty — including when D-Bus support is
/// compiled out (-Ddbus=false) and the handle is a void placeholder.
fn dbusConnection(dbus_handle: anytype) ?*DbusConnection {
    if (@TypeOf(dbus_handle.*) == void) return null;
    return if (dbus_handle.*) |*conn| conn else null;
}

/// The probed isolation mechanism: a thin dispatch over the two backend
/// structs. Probe once at startup with `probe`; null means isolation is
/// unavailable and children run in the inherited cgroup.
pub const Backend = union(enum) {
    systemd: SystemdBackend,
    cgroupfs: CgroupfsBackend,

    /// Move the gated shell child `pid` into its own scope. Confirm with
    /// `Pending.finish` before releasing the gate.
    pub fn startMoveIntoScope(self: Backend, pid: u32) Error!Pending {
        return switch (self) {
            .systemd => |backend| .{ .systemd = try backend.startMoveIntoScope(pid) },
            .cgroupfs => |backend| .{ .cgroupfs = try backend.startMoveIntoScope(pid) },
        };
    }

    /// After the session bus connection moves to its final home (the App
    /// struct), retarget the systemd backend's pointer at it. A systemd
    /// backend exists only when probe saw a live connection, so the
    /// handle cannot be empty here.
    pub fn retargetConnection(self: *Backend, dbus_handle: anytype) void {
        switch (self.*) {
            .systemd => |*backend| backend.connection = dbusConnection(dbus_handle).?,
            .cgroupfs => {},
        }
    }
};

/// Pick an isolation backend at startup, honoring the linux-cgroup
/// policy: `probeSystemd` or `probeCgroupfs` restrict the choice to one
/// mechanism, `probe` tries systemd first and falls back to cgroupfs.
/// Null means that backend is unavailable. `dbus_handle` points at the
/// caller's session bus handle (see dbusConnection). `cgroup_path`
/// (linux-cgroup-path) overrides the cgroupfs base; unset, our own cgroup
/// from /proc/self/cgroup is used.
pub fn probe(dbus_handle: anytype, cgroup_path: ?[]const u8) ?Backend {
    return probeSystemd(dbus_handle) orelse probeCgroupfs(cgroup_path);
}

pub fn probeSystemd(dbus_handle: anytype) ?Backend {
    const backend = SystemdBackend.probe(dbusConnection(dbus_handle)) orelse return null;
    return .{ .systemd = backend };
}

pub fn probeCgroupfs(cgroup_path: ?[]const u8) ?Backend {
    const backend = CgroupfsBackend.probe(cgroup_path) orelse return null;
    return .{ .cgroupfs = backend };
}

/// An in-flight scope migration. Created by `Backend.startMoveIntoScope`;
/// the caller must consume it with either `finish` (confirm the
/// migration, then release the gated child) or `cancel` (abandon it on an
/// error path).
pub const Pending = union(enum) {
    systemd: SystemdBackend.Pending,
    cgroupfs: CgroupfsBackend.Pending,

    /// Wait for the migration to become visible in /proc. Both backends
    /// typically completed while the caller was doing other setup, so
    /// this rarely blocks. The caller is expected to keep the child gated
    /// (see Pty.SpawnOptions.gate_child) until this returns so
    /// grandchildren cannot escape into the terminal's cgroup.
    pub fn finish(self: Pending) Error!void {
        return switch (self) {
            inline else => |pending| pending.finish(),
        };
    }

    pub fn cancel(self: Pending) void {
        // Cancel is only used while unwinding App initialization. Nothing
        // to unwind for either backend: App closes the session bus
        // connection (discarding systemd's outstanding reply), and an
        // abandoned cgroupfs scope directory is inert.
        _ = self;
    }
};

/// systemd backend: transient scopes via the session manager over D-Bus.
/// probe selects it only with a live session bus connection, so every
/// method relies on it unconditionally.
pub const SystemdBackend = struct {
    connection: *DbusConnection,

    /// An in-flight StartTransientUnit request.
    pub const Pending = struct {
        connection: *DbusConnection,
        serial: u32,
        pid: u32,

        /// Wait for systemd's reply and for the pid migration to become
        /// visible in /proc.
        pub fn finish(self: @This()) Error!void {
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
    };

    pub fn probe(connection: ?*DbusConnection) ?@This() {
        const conn = connection orelse return null; // systemd scopes need D-Bus
        if (!systemdBooted()) return null;
        return .{ .connection = conn };
    }

    /// Ask systemd to create a transient scope containing `pid`, without
    /// waiting for the reply: the round trip to systemd and the cgroup
    /// migration proceed while the caller does other setup.
    pub fn startMoveIntoScope(self: @This(), pid: u32) Error!@This().Pending {
        var name_buf: [scope_name_max + 1]u8 = undefined;
        const name = fmtScope(&name_buf, pid);
        const serial = try startTransientUnit(self.connection, name, pid);
        return .{ .connection = self.connection, .serial = serial, .pid = pid };
    }
};

/// cgroupfs backend: scope cgroups created directly under a base
/// directory within the v2 mount, resolved and verified writable at
/// probe time.
pub const CgroupfsBackend = struct {
    base_buf: [4096]u8,
    base_len: u32,

    /// Absolute path of the base directory on disk.
    pub fn basePath(self: *const CgroupfsBackend) [:0]const u8 {
        return self.base_buf[0..self.base_len :0];
    }

    /// Probe the base directory: the configured path with the real uid
    /// appended (<path>/<uid>, matching the login hook's layout), or our
    /// own cgroup from /proc/self/cgroup when unset. Null when the v2
    /// hierarchy is not mounted or no writable (delegated) base exists.
    pub fn probe(cgroup_path: ?[]const u8) ?CgroupfsBackend {
        var mount_buf: [1024]u8 = undefined;
        const mount = cgroup2Mount(&mount_buf) orelse return null;

        var sub_buf: [4096]u8 = undefined;
        if (cgroup_path) |path| {
            if (!validCgroupPath(path)) {
                log.warn("linux-cgroup-path {s} must be an absolute path without '..'", .{path});
            } else if (uidSubPath(&sub_buf, path)) |sub| {
                if (checkBase(mount, sub)) |resolved| {
                    resolved.sweepStaleScopes();
                    return resolved;
                }
                log.warn("linux-cgroup-path {s} (<uid> appended) is not a writable cgroup directory", .{path});
            } else {
                log.warn("linux-cgroup-path {s} is too long", .{path});
            }
            // Fall through to our own cgroup before giving up.
        }

        var data_buf: [4096]u8 = undefined;
        const data = readCgroupFile(&data_buf, @intCast(linux.getpid())) orelse return null;
        const own = cgroupPath(data) orelse return null;
        // The root cgroup path "/" maps onto the mount point itself.
        const sub = if (std.mem.eql(u8, own, "/")) "" else own;
        const base = checkBase(mount, sub) orelse return null;
        base.sweepStaleScopes();
        return base;
    }

    /// Scope migration is synchronous here: the mkdir and cgroup.procs
    /// write already happened, so finish only confirms the move is
    /// visible in /proc.
    pub const Pending = struct {
        pid: u32,

        pub fn finish(self: @This()) Error!void {
            var name_buf: [scope_name_max + 1]u8 = undefined;
            const name = fmtScope(&name_buf, self.pid);
            try waitForMigration(self.pid, name);
            log.debug("child {d} moved into {s}", .{ self.pid, name });
        }
    };

    /// Create the scope under the base and move `pid` into it now.
    pub fn startMoveIntoScope(self: CgroupfsBackend, pid: u32) Error!@This().Pending {
        if (cgroupfsMove(self.basePath(), pid)) |err| {
            log.warn("moving pid {d} into a scope under {s} failed: {s}", .{
                pid,
                self.basePath(),
                @tagName(err),
            });
            return error.ScopeFailed;
        }
        return .{ .pid = pid };
    }

    /// Move the calling process into a new scope under the base. Silent
    /// and async-signal-safe — fixed buffers and raw syscalls only — so a
    /// forked child can call it between fork and exec; failure just
    /// leaves the process in its inherited cgroup.
    pub fn moveSelfIntoScope(self: CgroupfsBackend) void {
        _ = cgroupfsMove(self.basePath(), @intCast(linux.getpid()));
    }

    /// Remove stale scope directories under the base. Scopes of exited
    /// processes are empty, and the kernel refuses to rmdir a populated
    /// cgroup (EBUSY) or one with children (ENOTEMPTY), so blindly
    /// attempting removal of every matching name is race-safe. Best
    /// effort; called at probe time and before spawning new windows, so
    /// stale scopes are swept by the next Monstar launch or Ctrl+Shift+N.
    pub fn sweepStaleScopes(self: *const CgroupfsBackend) void {
        const open_rc = linux.openat(linux.AT.FDCWD, self.basePath(), .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        if (linux.errno(open_rc) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(open_rc);
        defer _ = linux.close(fd);

        var buf: [4096]u8 = undefined;
        while (true) {
            const read_rc = linux.getdents64(fd, &buf, buf.len);
            if (linux.errno(read_rc) != .SUCCESS) return;
            if (read_rc == 0) return;
            var offset: usize = 0;
            while (offset < read_rc) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(buf[offset..].ptr);
                const name: [*:0]const u8 = @ptrCast(&entry.name);
                if (isScopeName(std.mem.sliceTo(name, 0))) {
                    _ = linux.unlinkat(fd, name, linux.AT.REMOVEDIR);
                }
                offset += entry.reclen;
            }
        }
    }

    /// Whether a directory entry name is one of our scopes.
    fn isScopeName(name: []const u8) bool {
        return std.mem.startsWith(u8, name, scope_prefix) and
            std.mem.endsWith(u8, name, scope_suffix);
    }

    /// mkdir app-monstar-transient-<pid>.scope under `base` and write
    /// `pid` into its cgroup.procs. Null on success, otherwise the errno
    /// of the failing step.
    fn cgroupfsMove(base: [:0]const u8, pid: u32) ?linux.E {
        var dir_buf: [4096]u8 = undefined;
        const dir = scopeDir(&dir_buf, base, pid) orelse return .NAMETOOLONG;

        // EEXIST means a stale scope from a reused pid; reuse the directory.
        switch (linux.errno(linux.mkdir(dir, 0o755))) {
            .SUCCESS, .EXIST => {},
            else => |err| return err,
        }

        var procs_buf: [4096]u8 = undefined;
        const procs = std.fmt.bufPrintZ(&procs_buf, "{s}/cgroup.procs", .{dir}) catch
            return .NAMETOOLONG;
        const open_rc = linux.openat(linux.AT.FDCWD, procs, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        const open_err = linux.errno(open_rc);
        if (open_err != .SUCCESS) return open_err;
        const fd: linux.fd_t = @intCast(open_rc);
        defer _ = linux.close(fd);

        var pid_buf: [10]u8 = undefined; // decimal u32
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;
        const write_err = linux.errno(linux.write(fd, pid_str.ptr, pid_str.len));
        if (write_err != .SUCCESS) return write_err;
        return null;
    }

    /// Join `sub` (a path within the v2 hierarchy) onto the cgroup2 mount
    /// and accept it as the base directory only when writable, i.e. a
    /// subtree delegated to us (e.g. by pam_exec at login, see contrib/).
    fn checkBase(mount: []const u8, sub: []const u8) ?CgroupfsBackend {
        var base: CgroupfsBackend = .{ .base_buf = undefined, .base_len = 0 };
        const dir = std.fmt.bufPrintZ(&base.base_buf, "{s}{s}", .{ mount, sub }) catch return null;
        base.base_len = @intCast(dir.len);
        const rc = linux.faccessat(linux.AT.FDCWD, base.basePath(), linux.W_OK, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return base;
    }

    /// Configured base paths must be absolute and stay inside the mount.
    fn validCgroupPath(path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, "/")) return false;
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return false;
        }
        return true;
    }

    /// The configured base with the real uid appended — scopes live under
    /// <path>/<uid>, matching the login hook's layout (see contrib/).
    /// Null when the result does not fit `buf`.
    fn uidSubPath(buf: []u8, path: []const u8) ?[]const u8 {
        const base = std.mem.trimEnd(u8, path, "/");
        return std.fmt.bufPrint(buf, "{s}/{d}", .{ base, linux.getuid() }) catch null;
    }

    /// Full path of the scope directory for `pid`:
    /// <base>/app-monstar-transient-<pid>.scope.
    fn scopeDir(buf: []u8, base: [:0]const u8, pid: u32) ?[:0]const u8 {
        var name_buf: [scope_name_max + 1]u8 = undefined;
        const name = fmtScope(&name_buf, pid);
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ base, name }) catch null;
    }

    /// Mount point of the cgroup v2 filesystem, e.g. "/sys/fs/cgroup".
    /// Null when no cgroup2 filesystem is mounted.
    fn cgroup2Mount(buf: []u8) ?[]const u8 {
        const open_rc = linux.openat(linux.AT.FDCWD, "/proc/self/mounts", .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
        }, 0);
        if (linux.errno(open_rc) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(open_rc);
        defer _ = linux.close(fd);

        var data: [16384]u8 = undefined;
        var len: usize = 0;
        while (len < data.len) {
            const rc = linux.read(fd, data[len..].ptr, data.len - len);
            if (linux.errno(rc) != .SUCCESS) return null;
            if (rc == 0) break;
            len += rc;
        }
        const mount_point = parseCgroup2Mount(data[0..len]) orelse return null;
        if (mount_point.len > buf.len) return null;
        @memcpy(buf[0..mount_point.len], mount_point);
        return buf[0..mount_point.len];
    }

    /// Mount point of the cgroup2 filesystem within /proc/self/mounts
    /// contents ("source mountpoint fstype options dump pass" per line).
    fn parseCgroup2Mount(data: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next() orelse continue; // source
            const mount_point = fields.next() orelse continue;
            const fstype = fields.next() orelse continue;
            if (std.mem.eql(u8, fstype, "cgroup2")) return mount_point;
        }
        return null;
    }

    /// Full cgroup v2 path from /proc/<pid>/cgroup contents: the unified
    /// entry is the line starting with "0::".
    fn cgroupPath(data: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const entry = std.mem.trimEnd(u8, line, " \r");
            if (!std.mem.startsWith(u8, entry, "0::")) continue;
            return entry[3..];
        }
        return null;
    }
};

/// Unit name for the child's scope. Follows the XDG cgroup naming
/// convention (app-<app>-<unique>.scope) so desktop tools recognize it.
fn fmtScope(buf: []u8, pid: u32) [:0]const u8 {
    std.debug.assert(buf.len > scope_name_max);
    return std.fmt.bufPrintZ(buf, scope_prefix ++ "{d}" ++ scope_suffix, .{pid}) catch unreachable;
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

/// Migration into the scope is not synchronous (systemd queues a job,
/// and /proc visibility lags the cgroup.procs write), so poll /proc until
/// the move is visible (or give up after ~250ms). Migration typically
/// lands within a few ms, so back off exponentially from 200µs: the
/// common case waits roughly the true latency instead of a coarse quantum.
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

/// Leaf cgroup name from /proc/<pid>/cgroup contents.
fn leafCgroup(data: []const u8) ?[]const u8 {
    const path = CgroupfsBackend.cgroupPath(data) orelse return null;
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (idx + 1 == path.len) return null; // the root cgroup has no leaf
    return path[idx + 1 ..];
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

test "cgroupPath" {
    try std.testing.expectEqualStrings(
        "/user.slice/user-1000.slice/session-1.scope",
        CgroupfsBackend.cgroupPath("0::/user.slice/user-1000.slice/session-1.scope\n").?,
    );
    // Hybrid layout: v1 controller lines are skipped.
    const hybrid =
        "12:pids:/user.slice\n" ++
        "1:name=systemd:/user.slice/other.scope\n" ++
        "0::/userwork/1000/app-monstar-transient-99.scope\n";
    try std.testing.expectEqualStrings(
        "/userwork/1000/app-monstar-transient-99.scope",
        CgroupfsBackend.cgroupPath(hybrid).?,
    );
    try std.testing.expect(CgroupfsBackend.cgroupPath("") == null);
    try std.testing.expect(CgroupfsBackend.cgroupPath("12:pids:/user.slice\n") == null);
}

test "leafCgroup" {
    try std.testing.expectEqualStrings(
        "session-1.scope",
        leafCgroup("0::/user.slice/user-1000.slice/session-1.scope\n").?,
    );
    try std.testing.expectEqualStrings(
        "app-monstar-transient-99.scope",
        leafCgroup("0::/userwork/1000/app-monstar-transient-99.scope\n").?,
    );
    try std.testing.expect(leafCgroup("0::/\n") == null);
}

test "validCgroupPath" {
    try std.testing.expect(CgroupfsBackend.validCgroupPath("/userwork/1000"));
    try std.testing.expect(CgroupfsBackend.validCgroupPath("/"));
    try std.testing.expect(!CgroupfsBackend.validCgroupPath("userwork/1000"));
    try std.testing.expect(!CgroupfsBackend.validCgroupPath(""));
    try std.testing.expect(!CgroupfsBackend.validCgroupPath("/userwork/../1000"));
}

test "uidSubPath appends the real uid to the configured base" {
    var buf: [128]u8 = undefined;
    var expected_buf: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "/userwork/{d}", .{linux.getuid()}) catch unreachable;
    try std.testing.expectEqualStrings(expected, CgroupfsBackend.uidSubPath(&buf, "/userwork").?);
    try std.testing.expectEqualStrings(expected, CgroupfsBackend.uidSubPath(&buf, "/userwork/").?);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(CgroupfsBackend.uidSubPath(&tiny, "/userwork") == null);
}

test "isScopeName" {
    try std.testing.expect(CgroupfsBackend.isScopeName("app-monstar-transient-123.scope"));
    try std.testing.expect(CgroupfsBackend.isScopeName("app-monstar-transient-4294967295.scope"));
    try std.testing.expect(!CgroupfsBackend.isScopeName("app-monstar-transient-123"));
    try std.testing.expect(!CgroupfsBackend.isScopeName("other.scope"));
    try std.testing.expect(!CgroupfsBackend.isScopeName("."));
}

test "parseCgroup2Mount" {
    const mounts =
        "proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0\n" ++
        "sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0\n" ++
        "cgroup2 /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime 0 0\n" ++
        "tmpfs /run tmpfs rw,nosuid,nodev 0 0\n";
    try std.testing.expectEqualStrings("/sys/fs/cgroup", CgroupfsBackend.parseCgroup2Mount(mounts).?);
    try std.testing.expect(CgroupfsBackend.parseCgroup2Mount("proc /proc proc rw 0 0\n") == null);
    try std.testing.expect(CgroupfsBackend.parseCgroup2Mount("") == null);
}
