//! One authenticated connection to the D-Bus session bus.
//!
//! This is deliberately a client transport, not a general D-Bus binding: it
//! supports Linux Unix-domain session buses, method calls, signals, correlated
//! replies, and Unix file-descriptor passing. Service-specific messages remain
//! in their owning modules.

const Connection = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wire = @import("wire.zig");

pub const Encoder = wire.Encoder;
pub const Message = wire.Message;
pub const MessageType = wire.MessageType;

const max_queued_messages = 256;
const max_queued_bytes = 4 * 1024 * 1024;
const max_message_fds = 16;
const receive_buffer_size = 16 * 1024;
const auth_line_max = 1024;
const cmsg_header_size = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
const receive_control_size = cmsg_header_size +
    std.mem.alignForward(usize, max_message_fds * @sizeOf(posix.fd_t), @sizeOf(usize));

pub const Error = error{
    AddressUnavailable,
    AuthenticationFailed,
    ConnectionClosed,
    InvalidAddress,
    OutgoingQueueFull,
    ProtocolError,
    RemoteError,
    Timeout,
    UnixFdUnsupported,
    WriteFailed,
};

pub const Method = struct {
    destination: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
};

pub const Signal = struct {
    path: []const u8,
    interface: []const u8,
    member: []const u8,
};

allocator: std.mem.Allocator,
io: std.Io,
fd: posix.fd_t,
next_serial: u32 = 1,
unix_fd_enabled: bool = false,
broken: bool = false,
receive_buffer: std.ArrayList(u8) = .empty,
received_fds: std.ArrayList(posix.fd_t) = .empty,
messages: std.ArrayList(Message) = .empty,
outgoing: std.ArrayList(OutgoingMessage) = .empty,
outgoing_bytes: usize = 0,

const OutgoingMessage = struct {
    data: []u8,
    fds: []posix.fd_t,
    offset: usize = 0,

    fn deinit(message: *OutgoingMessage, allocator: std.mem.Allocator) void {
        for (message.fds) |fd| _ = linux.close(fd);
        allocator.free(message.fds);
        allocator.free(message.data);
    }
};

/// Connect, authenticate, and register with the session bus. The caller owns
/// the returned connection and must call `deinit`. Only Unix socket addresses
/// are supported; multiple alternatives are tried in order.
pub fn connectSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) !Connection {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const addresses = environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse fallback: {
        const runtime_dir = environ.getPosix("XDG_RUNTIME_DIR") orelse
            return error.AddressUnavailable;
        break :fallback try std.fmt.allocPrint(arena, "unix:path={s}/bus", .{runtime_dir});
    };

    var alternatives = std.mem.splitScalar(u8, addresses, ';');
    while (alternatives.next()) |address| {
        if (address.len == 0) continue;
        const fd = connectUnixAddress(arena, address) catch continue;
        var connection: Connection = .{
            .allocator = allocator,
            .io = io,
            .fd = fd,
        };
        errdefer connection.deinit();

        connection.authenticate() catch {
            connection.deinit();
            continue;
        };
        connection.hello() catch {
            connection.deinit();
            continue;
        };
        return connection;
    }
    return error.AddressUnavailable;
}

pub fn deinit(self: *Connection) void {
    for (self.outgoing.items) |*message| message.deinit(self.allocator);
    self.outgoing.deinit(self.allocator);
    for (self.messages.items) |*message| message.deinit();
    self.messages.deinit(self.allocator);
    for (self.received_fds.items) |fd| _ = linux.close(fd);
    self.received_fds.deinit(self.allocator);
    self.receive_buffer.deinit(self.allocator);
    _ = linux.close(self.fd);
    self.* = undefined;
}

pub fn getFd(self: *const Connection) posix.fd_t {
    return self.fd;
}

pub fn hasQueuedMessages(self: *const Connection) bool {
    if (self.messages.items.len != 0) return true;
    // Buffered frames need dispatch even when the socket is no longer readable.
    // Malformed framing also needs dispatch so the caller observes the error.
    return (wire.messageLength(self.receive_buffer.items) catch return true) != null;
}

pub fn hasPendingWrites(self: *const Connection) bool {
    return self.outgoing.items.len != 0;
}

/// Send a method call and return its nonzero serial number.
pub fn sendMethod(
    self: *Connection,
    method: Method,
    signature: []const u8,
    body: []const u8,
    fds: []const posix.fd_t,
) !u32 {
    return self.sendMessage(.{
        .message_type = .method_call,
        .path = method.path,
        .interface = method.interface,
        .member = method.member,
        .destination = method.destination,
        .signature = signature,
    }, body, fds);
}

/// Send a method call and wait for its corresponding return or error reply.
/// The caller owns the returned message and must call `Message.deinit`.
pub fn call(
    self: *Connection,
    method: Method,
    signature: []const u8,
    body: []const u8,
    fds: []const posix.fd_t,
    timeout_ms: u32,
) !Message {
    const serial = try self.sendMethod(method, signature, body, fds);
    return self.waitForReply(serial, timeout_ms);
}

pub fn sendSignal(
    self: *Connection,
    signal: Signal,
    signature: []const u8,
    body: []const u8,
) !void {
    _ = try self.sendMessage(.{
        .message_type = .signal,
        .path = signal.path,
        .interface = signal.interface,
        .member = signal.member,
        .signature = signature,
    }, body, &.{});
}

/// Install a bus match rule and confirm that the bus accepted it.
pub fn addMatch(self: *Connection, rule: []const u8) !void {
    var body: Encoder = .init(self.allocator);
    defer body.deinit();
    try body.string(rule);
    var reply = try self.call(.{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "AddMatch",
    }, "s", body.bytes(), &.{}, 1000);
    defer reply.deinit();
    if (reply.messageType() != .method_return) return error.RemoteError;
}

/// Wait for a reply while preserving unrelated messages for later dispatch.
pub fn waitForReply(self: *Connection, serial: u32, timeout_ms: u32) !Message {
    const started = std.Io.Clock.awake.now(self.io);
    const timeout_ns: i96 = @as(i96, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        if (self.takeReply(serial)) |reply| return reply;
        const received = try self.readAvailable();
        if (self.takeReply(serial)) |reply| return reply;

        const elapsed = started.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        if (elapsed >= timeout_ns) return error.Timeout;
        if (received) continue;
        const remaining_ns = timeout_ns - elapsed;
        const remaining_ms: i32 = @intCast(@min(
            @as(i96, std.math.maxInt(i32)),
            @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
        ));
        var events: i16 = posix.POLL.IN;
        if (self.hasPendingWrites()) events |= posix.POLL.OUT;
        var poll_fd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = events,
            .revents = 0,
        }};
        if (try posix.poll(&poll_fd, remaining_ms) == 0) return error.Timeout;
        if (poll_fd[0].revents & posix.POLL.NVAL != 0) return error.ConnectionClosed;
        if (poll_fd[0].revents & posix.POLL.OUT != 0) try self.flushWrites();
    }
}

/// Return one queued or newly received message without blocking. The caller
/// owns a returned message and must call `Message.deinit`.
pub fn nextMessage(self: *Connection) !?Message {
    if (self.messages.items.len == 0) _ = try self.readAvailable();
    if (self.messages.items.len == 0) return null;
    return self.messages.orderedRemove(0);
}

fn hello(self: *Connection) !void {
    var reply = try self.call(.{
        .destination = "org.freedesktop.DBus",
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "Hello",
    }, "", &.{}, &.{}, 1000);
    defer reply.deinit();
    if (reply.messageType() != .method_return or
        !std.mem.eql(u8, reply.bodySignature(), "s")) return error.AuthenticationFailed;
    var decoder = reply.bodyDecoder();
    _ = decoder.string() catch return error.AuthenticationFailed;
    decoder.end() catch return error.AuthenticationFailed;
}

fn sendMessage(
    self: *Connection,
    metadata: wire.Metadata,
    body: []const u8,
    fds: []const posix.fd_t,
) !u32 {
    if (self.broken) return error.ConnectionClosed;
    if (fds.len > max_message_fds) return error.ProtocolError;
    if (fds.len != 0 and !self.unix_fd_enabled) return error.UnixFdUnsupported;
    const serial = self.next_serial;

    const data = try wire.encodeMessage(
        self.allocator,
        metadata,
        serial,
        body,
        @intCast(fds.len),
    );
    var accepted = false;
    errdefer if (!accepted) self.allocator.free(data);
    if (self.outgoing.items.len >= max_queued_messages or
        data.len > max_queued_bytes -| self.outgoing_bytes) return error.OutgoingQueueFull;
    try self.outgoing.ensureUnusedCapacity(self.allocator, 1);
    const owned_fds = try self.allocator.alloc(posix.fd_t, fds.len);
    errdefer if (!accepted) self.allocator.free(owned_fds);
    var duplicated: usize = 0;
    errdefer if (!accepted) {
        for (owned_fds[0..duplicated]) |fd| _ = linux.close(fd);
    };
    for (fds, 0..) |fd, index| {
        const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        owned_fds[index] = @intCast(rc);
        duplicated += 1;
    }
    self.outgoing.appendAssumeCapacity(.{ .data = data, .fds = owned_fds });
    accepted = true;
    self.outgoing_bytes += data.len;
    self.next_serial +%= 1;
    if (self.next_serial == 0) self.next_serial = 1;
    try self.flushWrites();
    return serial;
}

/// Attempt to drain queued messages without blocking. Call again after POLLOUT.
pub fn flushWrites(self: *Connection) !void {
    if (self.broken) return error.ConnectionClosed;
    errdefer self.broken = true;
    while (self.outgoing.items.len != 0) {
        const queued = &self.outgoing.items[0];
        var control: [receive_control_size]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
        if (queued.fds.len != 0) {
            const header: *linux.cmsghdr = @ptrCast(&control);
            header.* = .{ .len = cmsgLength(queued.fds.len * @sizeOf(posix.fd_t)), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(control[cmsg_header_size..][0 .. queued.fds.len * @sizeOf(posix.fd_t)], std.mem.sliceAsBytes(queued.fds));
        }
        var iov = [_]posix.iovec_const{.{
            .base = queued.data[queued.offset..].ptr,
            .len = queued.data.len - queued.offset,
        }};
        const message: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = if (queued.fds.len != 0) &control else null,
            .controllen = if (queued.fds.len != 0) cmsgSpace(queued.fds.len * @sizeOf(posix.fd_t)) else 0,
            .flags = 0,
        };
        const rc = linux.sendmsg(self.fd, &message, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectionClosed;
                queued.offset += rc;
                if (queued.fds.len != 0) {
                    for (queued.fds) |fd| _ = linux.close(fd);
                    self.allocator.free(queued.fds);
                    queued.fds = &.{};
                }
                if (queued.offset == queued.data.len) {
                    self.outgoing_bytes -= queued.data.len;
                    self.allocator.free(queued.data);
                    self.allocator.free(queued.fds);
                    _ = self.outgoing.orderedRemove(0);
                }
            },
            .INTR => continue,
            .AGAIN => return,
            .PIPE, .CONNRESET, .NOTCONN => return error.ConnectionClosed,
            else => return error.WriteFailed,
        }
    }
}

/// Queue at most one complete message. Dispatch must keep pace with reads:
/// draining the socket first can overflow the queue on a valid signal burst.
fn readAvailable(self: *Connection) !bool {
    while (true) {
        if (try self.parseMessage()) return true;
        var data: [receive_buffer_size]u8 = undefined;
        var control: [receive_control_size]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var iov = [_]posix.iovec{.{ .base = &data, .len = data.len }};
        var message: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(self.fd, &message, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectionClosed;
                if (message.flags & linux.MSG.CTRUNC != 0) {
                    closeControlFds(control[0..message.controllen]);
                    return error.ProtocolError;
                }
                try self.collectFds(control[0..message.controllen]);
                try self.receive_buffer.appendSlice(self.allocator, data[0..rc]);
            },
            .INTR => continue,
            .AGAIN => return false,
            .CONNRESET, .NOTCONN => return error.ConnectionClosed,
            else => return error.ProtocolError,
        }
    }
}

fn collectFds(self: *Connection, control: []const u8) !void {
    const count = countControlFds(control) catch |err| {
        closeControlFds(control);
        return err;
    };
    if (self.received_fds.items.len + count > max_message_fds) {
        closeControlFds(control);
        return error.ProtocolError;
    }
    self.received_fds.ensureUnusedCapacity(self.allocator, count) catch |err| {
        closeControlFds(control);
        return err;
    };

    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const bytes = control[offset + cmsg_header_size .. offset + header.len];
            var index: usize = 0;
            while (index < bytes.len) : (index += @sizeOf(posix.fd_t)) {
                const fd = std.mem.readInt(
                    posix.fd_t,
                    @ptrCast(bytes[index..][0..@sizeOf(posix.fd_t)]),
                    .native,
                );
                self.received_fds.appendAssumeCapacity(fd);
            }
        }
        offset = std.mem.alignForward(usize, offset + header.len, @sizeOf(usize));
    }
}

fn countControlFds(control: []const u8) !usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (header.len < cmsg_header_size or header.len > control.len - offset)
            return error.ProtocolError;
        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const bytes_len = header.len - cmsg_header_size;
            if (bytes_len % @sizeOf(posix.fd_t) != 0) return error.ProtocolError;
            count += bytes_len / @sizeOf(posix.fd_t);
        }
        offset = std.mem.alignForward(usize, offset + header.len, @sizeOf(usize));
    }
    return count;
}

fn closeControlFds(control: []const u8) void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (header.len < cmsg_header_size or header.len > control.len - offset) return;
        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const bytes = control[offset + cmsg_header_size .. offset + header.len];
            if (bytes.len % @sizeOf(posix.fd_t) != 0) return;
            var index: usize = 0;
            while (index < bytes.len) : (index += @sizeOf(posix.fd_t)) {
                const fd = std.mem.readInt(
                    posix.fd_t,
                    @ptrCast(bytes[index..][0..@sizeOf(posix.fd_t)]),
                    .native,
                );
                _ = linux.close(fd);
            }
        }
        offset = std.mem.alignForward(usize, offset + header.len, @sizeOf(usize));
    }
}

fn parseMessage(self: *Connection) !bool {
    if (try wire.messageLength(self.receive_buffer.items)) |length| {
        if (self.messages.items.len >= max_queued_messages) return error.ProtocolError;
        try self.messages.ensureUnusedCapacity(self.allocator, 1);
        const owned_data = try self.allocator.dupe(u8, self.receive_buffer.items[0..length]);
        errdefer self.allocator.free(owned_data);

        const endian: std.builtin.Endian = if (owned_data[0] == 'l') .little else .big;
        const fields_len = std.mem.readInt(u32, owned_data[12..16], endian);
        var header_decoder: wire.Decoder = .{
            .data = owned_data[16 .. 16 + fields_len],
            .endian = endian,
            .base_offset = 16,
        };
        var fd_count: u32 = 0;
        while (!header_decoder.finished()) {
            try header_decoder.structAlignment();
            const code = try header_decoder.byte();
            const signature = try header_decoder.variantSignature();
            if (code == 9) {
                if (!std.mem.eql(u8, signature, "u")) return error.ProtocolError;
                fd_count = try header_decoder.uint32();
            } else {
                try header_decoder.skipSignatureValue(signature);
            }
        }
        if (fd_count > max_message_fds or fd_count > self.received_fds.items.len)
            return error.ProtocolError;

        const owned_fds = try self.allocator.alloc(posix.fd_t, fd_count);
        errdefer self.allocator.free(owned_fds);
        @memcpy(owned_fds, self.received_fds.items[0..fd_count]);
        const remaining_fds = self.received_fds.items.len - fd_count;
        std.mem.copyForwards(
            posix.fd_t,
            self.received_fds.items[0..remaining_fds],
            self.received_fds.items[fd_count..],
        );
        self.received_fds.items.len = remaining_fds;

        const parsed = wire.parseMessage(self.allocator, owned_data, owned_fds) catch |err| {
            for (owned_fds) |fd| _ = linux.close(fd);
            return err;
        };
        self.messages.appendAssumeCapacity(parsed);

        const remaining = self.receive_buffer.items.len - length;
        std.mem.copyForwards(
            u8,
            self.receive_buffer.items[0..remaining],
            self.receive_buffer.items[length..],
        );
        self.receive_buffer.items.len = remaining;
        return true;
    }
    return false;
}

fn takeReply(self: *Connection, serial: u32) ?Message {
    for (self.messages.items, 0..) |message, index| {
        if ((message.messageType() == .method_return or message.messageType() == .error_reply) and
            message.header.reply_serial == serial)
        {
            return self.messages.orderedRemove(index);
        }
    }
    return null;
}

fn authenticate(self: *Connection) !void {
    // Bound the entire handshake, including partial lines and blocked writes,
    // so an unresponsive bus cannot prevent the terminal from starting.
    const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(1000));
    var uid_buffer: [32]u8 = undefined;
    const uid = try std.fmt.bufPrint(&uid_buffer, "{d}", .{linux.getuid()});
    var auth_buffer: [2 * uid_buffer.len + 32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&auth_buffer);
    try stream.writeByte(0);
    try stream.writeAll("AUTH EXTERNAL ");
    for (uid) |byte| try stream.print("{x:0>2}", .{byte});
    try stream.writeAll("\r\n");
    try self.writeAuth(stream.buffered(), deadline);

    var line_buffer: [auth_line_max]u8 = undefined;
    const response = try self.readAuthLine(&line_buffer, deadline);
    if (!std.mem.startsWith(u8, response, "OK ")) return error.AuthenticationFailed;

    try self.writeAuth("NEGOTIATE_UNIX_FD\r\n", deadline);
    const negotiation = try self.readAuthLine(&line_buffer, deadline);
    if (std.mem.eql(u8, negotiation, "AGREE_UNIX_FD")) {
        self.unix_fd_enabled = true;
    } else if (!std.mem.startsWith(u8, negotiation, "ERROR")) {
        return error.AuthenticationFailed;
    }
    try self.writeAuth("BEGIN\r\n", deadline);
}

fn connectUnixAddress(allocator: std.mem.Allocator, address: []const u8) !posix.fd_t {
    if (!std.mem.startsWith(u8, address, "unix:")) return error.InvalidAddress;
    var path: ?[]const u8 = null;
    var abstract: ?[]const u8 = null;
    var options = std.mem.splitScalar(u8, address["unix:".len..], ',');
    while (options.next()) |option| {
        const separator = std.mem.indexOfScalar(u8, option, '=') orelse return error.InvalidAddress;
        const key = option[0..separator];
        const value = try unescapeAddress(allocator, option[separator + 1 ..]);
        if (std.mem.eql(u8, key, "path")) path = value else if (std.mem.eql(u8, key, "abstract")) abstract = value;
    }
    if ((path == null) == (abstract == null)) return error.InvalidAddress;
    const socket_path = if (path) |value| value else value: {
        const name = abstract.?;
        const storage = try allocator.alloc(u8, name.len + 1);
        storage[0] = 0;
        @memcpy(storage[1..], name);
        break :value storage;
    };
    var socket_address: linux.sockaddr.un = .{ .path = @splat(0) };
    if (socket_path.len > socket_address.path.len) return error.InvalidAddress;
    @memcpy(socket_address.path[0..socket_path.len], socket_path);
    // A trailing NUL terminates a filesystem path but changes an abstract name.
    const address_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") +
        @min(socket_address.path.len, socket_path.len + @intFromBool(path != null)));

    // A Unix stream connect completes immediately unless the listener's accept
    // queue is full. NONBLOCK makes that case fail with EAGAIN rather than hang
    // startup before authentication's deadline; try the next address or fallback.
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return error.AddressUnavailable;
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.connect(fd, &socket_address, address_len)) != .SUCCESS)
        return error.AddressUnavailable;
    return fd;
}

fn unescapeAddress(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, value.len);
    errdefer allocator.free(output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < value.len) {
        if (value[input_index] == '%') {
            if (input_index + 2 >= value.len) return error.InvalidAddress;
            output[output_index] = std.fmt.parseInt(u8, value[input_index + 1 .. input_index + 3], 16) catch
                return error.InvalidAddress;
            input_index += 3;
        } else {
            output[output_index] = value[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(output, output_index);
}

fn waitAuth(self: *Connection, events: i16, deadline: std.Io.Timestamp) !void {
    while (true) {
        const remaining_ns = std.Io.Clock.awake.now(self.io).durationTo(deadline).nanoseconds;
        if (remaining_ns <= 0) return error.Timeout;
        const remaining_ms: i32 = @intCast(@divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        // Recompute the remaining time after EINTR instead of restarting the
        // full poll timeout. Read/write classify EOF and socket errors.
        const rc = linux.poll(&fds, fds.len, remaining_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Timeout;
                if (fds[0].revents & posix.POLL.NVAL != 0) return error.ConnectionClosed;
                return;
            },
            .INTR => continue,
            else => return error.AuthenticationFailed,
        }
    }
}

fn writeAuth(self: *Connection, data: []const u8, deadline: std.Io.Timestamp) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        try self.waitAuth(posix.POLL.OUT, deadline);
        const rc = linux.sendto(self.fd, data[offset..].ptr, data.len - offset, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectionClosed;
                offset += rc;
            },
            .INTR, .AGAIN => continue,
            .PIPE, .CONNRESET, .NOTCONN => return error.ConnectionClosed,
            else => return error.WriteFailed,
        }
    }
}

fn readAuthLine(self: *Connection, buffer: []u8, deadline: std.Io.Timestamp) ![]const u8 {
    var length: usize = 0;
    while (length < buffer.len) {
        try self.waitAuth(posix.POLL.IN, deadline);
        const rc = linux.recvfrom(self.fd, buffer[length..].ptr, 1, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectionClosed;
                length += 1;
                if (length >= 2 and buffer[length - 2] == '\r' and buffer[length - 1] == '\n')
                    return buffer[0 .. length - 2];
            },
            .INTR, .AGAIN => continue,
            .CONNRESET, .NOTCONN => return error.ConnectionClosed,
            else => return error.AuthenticationFailed,
        }
    }
    return error.AuthenticationFailed;
}

fn cmsgLength(data_len: usize) usize {
    return cmsg_header_size + data_len;
}

fn cmsgSpace(data_len: usize) usize {
    return cmsg_header_size + std.mem.alignForward(usize, data_len, @sizeOf(usize));
}

test "session address unescaping" {
    const allocator = std.testing.allocator;
    const value = try unescapeAddress(allocator, "/run/user/1000/dbus%2Dbus");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("/run/user/1000/dbus-bus", value);
    try std.testing.expectError(error.InvalidAddress, unescapeAddress(allocator, "%2"));
}

test "session connection does not wait for a saturated accept queue" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const socket_path = try std.fmt.allocPrint(arena, "{s}/bus", .{path_buf[0..path_len]});
    const address = try std.fmt.allocPrint(arena, "unix:path={s}", .{socket_path});
    const unix_address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try unix_address.listen(std.testing.io, .{ .kernel_backlog = 0 });
    defer server.deinit(std.testing.io);

    // Linux admits one pending connection with backlog zero. Leave it pending
    // so a blocking second connect cannot finish until somebody accepts it.
    const first = try connectUnixAddress(arena, address);
    defer _ = linux.close(first);
    const fork_rc = linux.fork();
    try std.testing.expectEqual(.SUCCESS, linux.errno(fork_rc));
    const pid: posix.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        // Bound the regression too: the old blocking implementation dies on
        // SIGALRM instead of hanging the test suite indefinitely.
        _ = std.c.alarm(2);
        var buffer: [1024]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const fd = connectUnixAddress(fixed.allocator(), address) catch |err| {
            linux.exit(if (err == error.AddressUnavailable) 0 else 2);
        };
        _ = linux.close(fd);
        linux.exit(1);
    }
    var status: u32 = undefined;
    while (true) {
        const rc = linux.wait4(pid, &status, 0, null);
        if (linux.errno(rc) == .INTR) continue;
        try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
        break;
    }
    try std.testing.expectEqual(@as(u32, 0), status);
    try std.testing.expect(linux.fcntl(first, linux.F.GETFD, 0) & linux.FD_CLOEXEC != 0);
    const flags: linux.O = @bitCast(@as(u32, @intCast(linux.fcntl(first, linux.F.GETFL, 0))));
    try std.testing.expect(flags.NONBLOCK);
}

test "session connection uses the exact abstract socket name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = try std.fmt.allocPrint(arena, "monstar-dbus-abstract-{d}", .{linux.getpid()});
    const address = try std.fmt.allocPrint(arena, "unix:abstract={s}", .{name});
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
    const listener: posix.fd_t = @intCast(rc);
    defer _ = linux.close(listener);
    var socket_address: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(socket_address.path[1..][0..name.len], name);
    // Abstract names are counted bytes, not NUL-terminated strings. Bind via
    // the kernel so the test cannot inherit the client's address conversion.
    const address_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&socket_address), address_len)));
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.listen(listener, 1)));
    const fd = try connectUnixAddress(arena, address);
    defer _ = linux.close(fd);
}

fn testSocketConnection(allocator: std.mem.Allocator) !struct { Connection, posix.fd_t } {
    var sockets: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &sockets);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    return .{ .{ .allocator = allocator, .io = std.testing.io, .fd = sockets[0], .unix_fd_enabled = true }, sockets[1] };
}

test "incoming burst is dispatched without overflowing the reply queue" {
    const allocator = std.testing.allocator;
    const pair = try testSocketConnection(allocator);
    var connection = pair[0];
    defer connection.deinit();
    defer _ = linux.close(pair[1]);

    var burst: std.Io.Writer.Allocating = .init(allocator);
    defer burst.deinit();
    const count = max_queued_messages + 1;
    for (0..count) |i| {
        const data = try wire.encodeMessage(allocator, .{
            .message_type = .signal,
            .path = "/a",
            .interface = "a.b",
            .member = "Changed",
        }, @intCast(i + 1), &.{}, 0);
        defer allocator.free(data);
        try burst.writer.writeAll(data);
    }
    const bytes = burst.written();
    try std.testing.expectEqual(bytes.len, linux.write(pair[1], bytes.ptr, bytes.len));
    for (0..count) |i| {
        var message = (try connection.nextMessage()) orelse return error.MissingMessage;
        defer message.deinit();
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), message.header.serial);
    }
    try std.testing.expectEqual(null, try connection.nextMessage());
}

test "reply wait consumes buffered frames and preserves surrounding signals" {
    const allocator = std.testing.allocator;
    const pair = try testSocketConnection(allocator);
    var connection = pair[0];
    defer connection.deinit();
    defer _ = linux.close(pair[1]);

    var burst: std.Io.Writer.Allocating = .init(allocator);
    defer burst.deinit();
    for (0..3) |i| {
        const metadata: wire.Metadata = if (i == 1)
            .{ .message_type = .method_return, .reply_serial = 42 }
        else
            .{ .message_type = .signal, .path = "/a", .interface = "a.b", .member = "Changed" };
        const data = try wire.encodeMessage(allocator, metadata, @intCast(i + 1), &.{}, 0);
        defer allocator.free(data);
        try burst.writer.writeAll(data);
    }
    const bytes = burst.written();
    // An incomplete header is not ready work and must not make the poll loop spin.
    try std.testing.expectEqual(@as(usize, 8), linux.write(pair[1], bytes.ptr, 8));
    try std.testing.expectEqual(null, try connection.nextMessage());
    try std.testing.expect(!connection.hasQueuedMessages());
    try std.testing.expectEqual(bytes.len - 8, linux.write(pair[1], bytes.ptr + 8, bytes.len - 8));

    var reply = try connection.waitForReply(42, 100);
    defer reply.deinit();
    try std.testing.expectEqual(@as(u32, 2), reply.header.serial);
    var first = (try connection.nextMessage()).?;
    defer first.deinit();
    try std.testing.expectEqual(@as(u32, 1), first.header.serial);
    try std.testing.expectEqual(@as(usize, 0), connection.messages.items.len);
    try std.testing.expect(connection.hasQueuedMessages());
    var last = (try connection.nextMessage()).?;
    defer last.deinit();
    try std.testing.expectEqual(@as(u32, 3), last.header.serial);
    try std.testing.expect(!connection.hasQueuedMessages());
    try std.testing.expectEqual(null, try connection.nextMessage());
}

test "complete message is delivered before peer EOF" {
    const allocator = std.testing.allocator;
    const pair = try testSocketConnection(allocator);
    var connection = pair[0];
    defer connection.deinit();
    const data = try wire.encodeMessage(allocator, .{
        .message_type = .method_return,
        .reply_serial = 42,
    }, 1, &.{}, 0);
    defer allocator.free(data);
    const written = linux.write(pair[1], data.ptr, data.len);
    _ = linux.close(pair[1]);
    try std.testing.expectEqual(data.len, written);

    var reply = try connection.waitForReply(42, 100);
    defer reply.deinit();
    try std.testing.expectEqual(@as(u32, 42), reply.header.reply_serial.?);
    try std.testing.expectError(error.ConnectionClosed, connection.nextMessage());
}

test "authentication times out for silent and stalled peers" {
    for ([_][]const u8{ "", "OK partial", "OK bus\r\n" }) |reply| {
        const pair = try testSocketConnection(std.testing.allocator);
        var connection = pair[0];
        defer connection.deinit();
        defer _ = linux.close(pair[1]);
        // Session sockets are still blocking during authentication. Cover no
        // reply, a partial line, and a stall during Unix FD negotiation.
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.fcntl(connection.fd, linux.F.SETFL, 0)));
        if (reply.len > 0) try std.testing.expectEqual(reply.len, linux.write(pair[1], reply.ptr, reply.len));
        try std.testing.expectError(error.Timeout, connection.authenticate());
    }
}

test "authentication times out under write backpressure" {
    const pair = try testSocketConnection(std.testing.allocator);
    var connection = pair[0];
    defer connection.deinit();
    defer _ = linux.close(pair[1]);
    var fill: [4096]u8 = @splat(0);
    while (true) {
        const rc = linux.write(connection.fd, &fill, fill.len);
        if (linux.errno(rc) == .AGAIN) break;
        try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
        try std.testing.expect(rc > 0);
    }
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.fcntl(connection.fd, linux.F.SETFL, 0)));
    try std.testing.expectError(error.Timeout, connection.authenticate());
}

test "authentication accepts Unix FD negotiation success and refusal" {
    for ([_][]const u8{ "AGREE_UNIX_FD", "ERROR unsupported" }, [_]bool{ true, false }) |negotiation, enabled| {
        const pair = try testSocketConnection(std.testing.allocator);
        var connection = pair[0];
        defer connection.deinit();
        defer _ = linux.close(pair[1]);
        connection.unix_fd_enabled = false;
        const reply = try std.fmt.allocPrint(std.testing.allocator, "OK bus\r\n{s}\r\n", .{negotiation});
        defer std.testing.allocator.free(reply);
        try std.testing.expectEqual(reply.len, linux.write(pair[1], reply.ptr, reply.len));
        try connection.authenticate();
        try std.testing.expectEqual(enabled, connection.unix_fd_enabled);

        var sent: [256]u8 = undefined;
        const n = try posix.read(pair[1], &sent);
        try std.testing.expect(std.mem.startsWith(u8, sent[0..n], "\x00AUTH EXTERNAL "));
        try std.testing.expect(std.mem.endsWith(u8, sent[0..n], "\r\nNEGOTIATE_UNIX_FD\r\nBEGIN\r\n"));
    }
}

test "authentication I/O honors an expired deadline even on a ready socket" {
    const pair = try testSocketConnection(std.testing.allocator);
    var connection = pair[0];
    defer connection.deinit();
    defer _ = linux.close(pair[1]);
    try std.testing.expectEqual(@as(usize, 4), linux.write(pair[1], "OK\r\n", 4));
    const deadline = std.Io.Clock.awake.now(connection.io).subDuration(.fromMilliseconds(1));
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.Timeout, connection.readAuthLine(&buffer, deadline));
    try std.testing.expectError(error.Timeout, connection.writeAuth("BEGIN\r\n", deadline));
}

test "backpressure preserves queued order and duplicated fd ownership" {
    const pair = try testSocketConnection(std.testing.allocator);
    var connection = pair[0];
    defer connection.deinit();
    var receiver: Connection = .{ .allocator = std.testing.allocator, .io = std.testing.io, .fd = pair[1] };
    defer receiver.deinit();

    var fill: [4096]u8 = @splat(0xaa);
    while (true) {
        const rc = linux.write(connection.fd, &fill, fill.len);
        if (linux.errno(rc) == .AGAIN) break;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    }

    const opened = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const original: posix.fd_t = @intCast(opened);
    var body: Encoder = .init(std.testing.allocator);
    defer body.deinit();
    try body.unixFd(0);
    _ = try connection.sendMessage(.{ .message_type = .signal, .path = "/a", .interface = "a.b", .member = "First", .signature = "h" }, body.bytes(), &.{original});
    _ = linux.close(original);
    _ = try connection.sendSignal(.{ .path = "/a", .interface = "a.b", .member = "Second" }, "", &.{});

    try std.testing.expect(connection.hasPendingWrites());
    try std.testing.expectEqual(@as(usize, 2), connection.outgoing.items.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, connection.outgoing.items[0].data[8..12], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, connection.outgoing.items[1].data[8..12], .little));
    const duplicate = connection.outgoing.items[0].fds[0];
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(duplicate, linux.F.GETFD, 0)));
    try std.testing.expect(linux.fcntl(duplicate, linux.F.GETFD, 0) & linux.FD_CLOEXEC != 0);

    // Drain the artificial backpressure before letting the framed messages
    // through. The caller's original FD has already been closed.
    while (true) {
        const rc = linux.read(receiver.fd, &fill, fill.len);
        if (linux.errno(rc) == .AGAIN) break;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        try std.testing.expect(rc > 0);
    }
    try connection.flushWrites();
    try std.testing.expect(!connection.hasPendingWrites());
    try std.testing.expectEqual(@as(usize, 0), connection.outgoing_bytes);
    var first = (try receiver.nextMessage()).?;
    defer first.deinit();
    try std.testing.expectEqualStrings("First", first.header.member.?);
    try std.testing.expectEqual(@as(usize, 1), first.fds.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(first.fds[0], linux.F.GETFD, 0)));
    var second = (try receiver.nextMessage()).?;
    defer second.deinit();
    try std.testing.expectEqualStrings("Second", second.header.member.?);
    try std.testing.expectEqual(@as(usize, 0), second.fds.len);
}

test "queue rejection is atomic and does not break connection" {
    const pair = try testSocketConnection(std.testing.allocator);
    var connection = pair[0];
    defer connection.deinit();
    defer _ = linux.close(pair[1]);
    connection.outgoing_bytes = max_queued_bytes;

    const opened = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const original: posix.fd_t = @intCast(opened);
    defer _ = linux.close(original);
    try std.testing.expectError(error.OutgoingQueueFull, connection.sendMessage(.{ .message_type = .signal, .path = "/a", .interface = "a.b", .member = "Rejected" }, &.{}, &.{original}));
    try std.testing.expect(!connection.broken);
    try std.testing.expect(!connection.hasPendingWrites());
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(original, linux.F.GETFD, 0)));
    connection.outgoing_bytes = 0;
}

test "live session bus accepts a Unix fd" {
    if (!std.mem.eql(
        u8,
        std.testing.environ.getPosix("MONSTAR_DBUS_INTEGRATION") orelse
            return error.SkipZigTest,
        "1",
    )) return error.SkipZigTest;

    var connection = try connectSession(
        std.testing.io,
        std.testing.allocator,
        std.testing.environ,
    );
    defer connection.deinit();

    const rc = linux.openat(
        linux.AT.FDCWD,
        "/dev/null",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var body: Encoder = .init(std.testing.allocator);
    defer body.deinit();
    try body.unixFd(0);
    var reply = try connection.call(.{
        .destination = "dev.rockorager.Monstar.Nonexistent",
        .path = "/dev/rockorager/Monstar",
        .interface = "dev.rockorager.Monstar",
        .member = "TakeFd",
    }, "h", body.bytes(), &.{fd}, 1000);
    defer reply.deinit();
    try std.testing.expectEqual(MessageType.error_reply, reply.messageType());
}
