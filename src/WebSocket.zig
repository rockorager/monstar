//! Minimal blocking RFC 6455 WebSocket client over a connected stream socket.
//!
//! It covers what Rex's control and data connections need: the HTTP/1.1
//! upgrade with a subprotocol, masked client frames, fragmented messages,
//! and ping/pong. Reads are split into `fill` (one read syscall) and
//! `nextEvent` (parse buffered frames without blocking) so a caller can
//! drive several sockets from one poll loop.

const WebSocket = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.websocket);

/// Largest message accepted from the server. Rex's control limit is 1 MiB;
/// data messages are much smaller.
const max_message_len = 16 * 1024 * 1024;

alloc: std.mem.Allocator,
io: std.Io,
fd: posix.fd_t,
/// Bytes read from the socket; `buf.items[start..]` are not yet parsed.
buf: std.ArrayList(u8) = .empty,
start: usize = 0,
/// Payload of a fragmented message being assembled, and its opcode.
fragments: std.ArrayList(u8) = .empty,
fragment_opcode: ?Opcode = null,

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

/// A complete message or the server's close. Slices stay valid until the
/// next `fill` or `nextEvent` call.
pub const Event = union(enum) {
    text: []const u8,
    binary: []const u8,
    close: ?u16,
};

pub const Error = error{
    HandshakeFailed,
    ProtocolError,
    MessageTooLarge,
    EndOfStream,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

/// Upgrade the connected socket `fd` to a WebSocket. Takes ownership of
/// `fd`, which stays blocking.
pub fn handshake(
    alloc: std.mem.Allocator,
    io: std.Io,
    fd: posix.fd_t,
    host: []const u8,
    path: []const u8,
    protocol: []const u8,
) Error!WebSocket {
    var ws: WebSocket = .{ .alloc = alloc, .io = io, .fd = fd };
    errdefer ws.deinit();

    var key_bytes: [16]u8 = undefined;
    io.random(&key_bytes);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_bytes);

    var request_buf: [1024]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Protocol: {s}\r\n\r\n", .{ path, host, &key, protocol }) catch return error.HandshakeFailed;
    try writeAll(fd, request);

    const head_end = while (true) {
        if (std.mem.indexOf(u8, ws.buf.items, "\r\n\r\n")) |i| break i;
        if (ws.buf.items.len > 16 * 1024) return error.HandshakeFailed;
        if (!try ws.fill()) return error.HandshakeFailed;
    };
    const head = ws.buf.items[0..head_end];
    const status_line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) {
        log.err("websocket upgrade of {s} refused: {s}", .{ path, status_line });
        return error.HandshakeFailed;
    }
    var expected_accept: [28]u8 = undefined;
    acceptKey(&key, &expected_accept);
    if (!headerHasValue(head, "sec-websocket-accept", &expected_accept)) {
        log.err("websocket upgrade of {s}: bad Sec-WebSocket-Accept", .{path});
        return error.HandshakeFailed;
    }
    ws.start = head_end + 4;
    return ws;
}

/// Tell the server this end is going away (status 1000), so it can drop
/// the connection now instead of keeping it for a reconnect.
pub fn sendClose(self: *WebSocket) void {
    self.send(.close, &.{ 0x03, 0xe8 }) catch {};
}

pub fn deinit(self: *WebSocket) void {
    _ = linux.close(self.fd);
    self.buf.deinit(self.alloc);
    self.fragments.deinit(self.alloc);
    self.* = undefined;
}

/// Read once from the socket into the buffer, blocking until data or EOF.
/// Returns false at EOF. Invalidates slices from earlier events.
pub fn fill(self: *WebSocket) Error!bool {
    if (self.start > 0) {
        const rest = self.buf.items.len - self.start;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
        self.buf.items.len = rest;
        self.start = 0;
    }
    try self.buf.ensureUnusedCapacity(self.alloc, 64 * 1024);
    const n = posix.read(self.fd, self.buf.unusedCapacitySlice()) catch return error.ReadFailed;
    self.buf.items.len += n;
    return n > 0;
}

/// Block until the next message or close.
pub fn next(self: *WebSocket) Error!Event {
    while (true) {
        if (try self.nextEvent()) |event| return event;
        if (!try self.fill()) return error.EndOfStream;
    }
}

/// Parse the next complete message from buffered bytes, answering pings.
/// Returns null when more bytes are needed.
pub fn nextEvent(self: *WebSocket) Error!?Event {
    while (true) {
        const frame = try parseFrame(self.buf.items[self.start..]) orelse return null;
        self.start += frame.len;
        switch (frame.opcode) {
            .ping => try self.send(.pong, frame.payload),
            .pong => {},
            .close => return .{ .close = if (frame.payload.len >= 2) std.mem.readInt(u16, frame.payload[0..2], .big) else null },
            .text, .binary => {
                if (self.fragment_opcode != null) return error.ProtocolError;
                if (frame.fin) return messageEvent(frame.opcode, frame.payload);
                self.fragment_opcode = frame.opcode;
                self.fragments.clearRetainingCapacity();
                try self.appendFragment(frame.payload);
            },
            .continuation => {
                const opcode = self.fragment_opcode orelse return error.ProtocolError;
                try self.appendFragment(frame.payload);
                if (frame.fin) {
                    self.fragment_opcode = null;
                    return messageEvent(opcode, self.fragments.items);
                }
            },
            _ => return error.ProtocolError,
        }
    }
}

fn appendFragment(self: *WebSocket, payload: []const u8) Error!void {
    if (self.fragments.items.len + payload.len > max_message_len) return error.MessageTooLarge;
    try self.fragments.appendSlice(self.alloc, payload);
}

fn messageEvent(opcode: Opcode, payload: []const u8) Event {
    return switch (opcode) {
        .text => .{ .text = payload },
        .binary => .{ .binary = payload },
        else => unreachable,
    };
}

/// Send one unfragmented, masked frame.
pub fn send(self: *WebSocket, opcode: Opcode, payload: []const u8) Error!void {
    var header: [14]u8 = undefined;
    var mask: [4]u8 = undefined;
    self.io.random(&mask);
    const header_len = encodeHeader(&header, opcode, payload.len, mask);
    try writeAll(self.fd, header[0..header_len]);

    var chunk: [16 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const n = @min(chunk.len, payload.len - offset);
        for (chunk[0..n], payload[offset..][0..n], offset..) |*out, byte, i| out.* = byte ^ mask[i % 4];
        try writeAll(self.fd, chunk[0..n]);
        offset += n;
    }
}

const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
    /// Bytes the whole frame occupies in the buffer.
    len: usize,
};

/// Parse one server frame from the front of `bytes`, or null if incomplete.
fn parseFrame(bytes: []const u8) Error!?Frame {
    if (bytes.len < 2) return null;
    // Servers never mask, and Rex negotiates no extensions (RSV bits).
    if (bytes[0] & 0x70 != 0 or bytes[1] & 0x80 != 0) return error.ProtocolError;
    var offset: usize = 2;
    var payload_len: u64 = bytes[1] & 0x7f;
    if (payload_len == 126) {
        if (bytes.len < 4) return null;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (bytes.len < 10) return null;
        payload_len = std.mem.readInt(u64, bytes[2..10], .big);
        offset = 10;
    }
    if (payload_len > max_message_len) return error.MessageTooLarge;
    const end = offset + @as(usize, @intCast(payload_len));
    if (bytes.len < end) return null;
    return .{
        .fin = bytes[0] & 0x80 != 0,
        .opcode = @fromBackingInt(@intCast(@as(u4, @truncate(bytes[0])))),
        .payload = bytes[offset..end],
        .len = end,
    };
}

fn encodeHeader(out: *[14]u8, opcode: Opcode, len: usize, mask: [4]u8) usize {
    out[0] = 0x80 | @as(u8, @backingInt(opcode));
    var n: usize = 2;
    if (len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= std.math.maxInt(u16)) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        n = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], len, .big);
        n = 10;
    }
    out[n..][0..4].* = mask;
    return n + 4;
}

fn acceptKey(key: []const u8, out: *[28]u8) void {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Whether the HTTP response head has header `name` (lowercase) with `value`.
fn headerHasValue(head: []const u8, name: []const u8, value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), value);
    }
    return false;
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => offset += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

test "frame parser handles each length form and partial input" {
    var buf: [70000]u8 = undefined;
    // 7-bit length.
    buf[0] = 0x81;
    buf[1] = 3;
    @memcpy(buf[2..5], "abc");
    try std.testing.expectEqual(null, try parseFrame(buf[0..4]));
    const small = (try parseFrame(buf[0..5])).?;
    try std.testing.expectEqualStrings("abc", small.payload);
    try std.testing.expectEqual(Opcode.text, small.opcode);
    try std.testing.expectEqual(5, small.len);

    // 16-bit length, unfinished binary fragment.
    buf[0] = 0x02;
    buf[1] = 126;
    std.mem.writeInt(u16, buf[2..4], 300, .big);
    try std.testing.expectEqual(null, try parseFrame(buf[0..303]));
    const medium = (try parseFrame(buf[0..304])).?;
    try std.testing.expect(!medium.fin);
    try std.testing.expectEqual(300, medium.payload.len);

    // 64-bit length.
    buf[0] = 0x82;
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], 65536, .big);
    const large = (try parseFrame(buf[0 .. 10 + 65536])).?;
    try std.testing.expectEqual(65536, large.payload.len);

    // Masked server frames are a protocol error.
    buf[1] = 0x81;
    try std.testing.expectError(error.ProtocolError, parseFrame(buf[0..10]));
}

test "client header masks and picks the length form at its boundaries" {
    var out: [14]u8 = undefined;
    const mask: [4]u8 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(6, encodeHeader(&out, .text, 125, mask));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x80 | 125, 1, 2, 3, 4 }, out[0..6]);
    try std.testing.expectEqual(8, encodeHeader(&out, .binary, 126, mask));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x80 | 126, 0, 126 }, out[0..4]);
    try std.testing.expectEqual(8, encodeHeader(&out, .binary, 65535, mask));
    try std.testing.expectEqual(14, encodeHeader(&out, .binary, 65536, mask));
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x80 | 127, 0, 0, 0, 0, 0, 1, 0, 0 }, out[0..10]);
}

test "accept key matches RFC 6455 example" {
    var out: [28]u8 = undefined;
    acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
