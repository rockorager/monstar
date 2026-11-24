//! Rex client: runs one Rex terminal block in place of a local shell.
//!
//! With `monstar --rex TARGET`, the App starts a `Client` instead of a
//! child process. The client's thread connects to the Rex server and opens
//! a new shell block in the `monstar` session. The block's data stream is
//! a Ghostty snapshot followed by live VT output: the thread decodes the
//! snapshot into a terminal the App adopts as its own, then passes the live
//! output to the App over a socket pair that stands in for the pty.
//!
//! Input goes the other way as Rex events, not bytes: keys, pastes, mouse,
//! wheel, and focus are encoded by the block's own Ghostty terminal, which
//! tracks the program's modes. The App also pushes its size and colors,
//! and the server's terminal answers queries such as DA, DSR, and OSC
//! 10/11 from them, so the App does not answer those for a Rex block.

const std = @import("std");
const vt = @import("ghostty-vt");
const WebSocket = @import("WebSocket.zig");

const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.rex);

const control_protocol = "rex.control.v1";
const data_protocol = "rex.data.terminal.v1";
const shell_flavor = "com.superlogical.terminal.shell";
const session_label = "monstar";
/// Port of a Rex listener on a machine's tailnet address.
const default_port = 7297;
/// The only API revision this client has been tested against.
const api_revision = 19;
/// Rex closes a block's data connection with this code when the block ends.
const close_block_ended = 4000;

pub const Endpoint = union(enum) {
    unix: []const u8,
    tcp: struct { host: []const u8, port: u16 },
};

pub const EndpointError = error{ InvalidEndpoint, TlsUnsupported, OutOfMemory };

/// Parse a `--rex` target: `local` (or empty) for this machine's server,
/// `unix:///path` or `/path`, `http://host[:port]`, or `host[:port]` for a
/// tailnet listener (port 7297 by default). HTTPS needs TLS, which the
/// client does not do yet.
pub fn parseEndpoint(arena: std.mem.Allocator, target: []const u8, environ: std.process.Environ) EndpointError!Endpoint {
    if (target.len == 0 or std.mem.eql(u8, target, "local")) {
        if (environ.getPosix("REX_SERVER")) |server| {
            if (server.len > 0 and !std.mem.eql(u8, server, "local")) return parseEndpoint(arena, server, environ);
        }
        const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse
            return .{ .unix = try std.fmt.allocPrint(arena, "/run/user/{d}/rex/server.sock", .{linux.getuid()}) };
        return .{ .unix = try std.fmt.allocPrint(arena, "{s}/rex/server.sock", .{runtime}) };
    }
    if (std.mem.startsWith(u8, target, "unix://")) return .{ .unix = target["unix://".len..] };
    if (target[0] == '/') return .{ .unix = target };
    if (std.mem.startsWith(u8, target, "https://")) return error.TlsUnsupported;
    if (std.mem.startsWith(u8, target, "http://")) {
        const rest = target["http://".len..];
        return parseHostPort(rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len], 80);
    }
    if (std.mem.indexOf(u8, target, "://") != null) return error.InvalidEndpoint;
    return parseHostPort(target, default_port);
}

fn parseHostPort(text: []const u8, port: u16) EndpointError!Endpoint {
    if (text.len == 0) return error.InvalidEndpoint;
    if (text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidEndpoint;
        const rest = text[close + 1 ..];
        if (rest.len == 0) return .{ .tcp = .{ .host = text[1..close], .port = port } };
        if (rest[0] != ':') return error.InvalidEndpoint;
        return .{ .tcp = .{ .host = text[1..close], .port = try parsePort(rest[1..]) } };
    }
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{ .tcp = .{ .host = text, .port = port } };
    // More than one colon: a bare IPv6 address with no port.
    if (std.mem.indexOfScalarPos(u8, text, colon + 1, ':') != null) return .{ .tcp = .{ .host = text, .port = port } };
    if (colon == 0) return error.InvalidEndpoint;
    return .{ .tcp = .{ .host = text[0..colon], .port = try parsePort(text[colon + 1 ..]) } };
}

fn parsePort(text: []const u8) EndpointError!u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;
    return port;
}

/// Splits a block's data stream into the leading Ghostty snapshot and the
/// live VT output after it, removing Rex's in-band
/// `ESC _ rex1;<nonce>;{json} ESC \` metadata from the live output.
pub const DataFilter = struct {
    /// `ESC _ rex1;<nonce>;`, which starts every metadata sequence.
    prefix: []const u8,
    /// Snapshot bytes until FINISH, then null.
    snapshot: ?std.ArrayList(u8) = .empty,
    /// Live bytes held back because they may start a metadata sequence.
    pending: std.ArrayList(u8) = .empty,

    const apc_end = "\x1b\\";
    const max_metadata_len = 1024 * 1024;
    const max_snapshot_len = 256 * 1024 * 1024;
    const envelope = "GHOSTSNP\x01\x00";
    const record_header_len = 10;
    const finish_tag = 6;

    pub fn init(alloc: std.mem.Allocator, nonce: u64) !DataFilter {
        return .{ .prefix = try std.fmt.allocPrint(alloc, "\x1b_rex1;{d};", .{nonce}) };
    }

    pub fn deinit(self: *DataFilter, alloc: std.mem.Allocator) void {
        alloc.free(self.prefix);
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        self.pending.deinit(alloc);
        self.* = undefined;
    }

    /// Write the live output in `bytes` to `out`. Returns the complete
    /// snapshot, owned by the caller, from the call that finishes it; the
    /// live output written by that call follows the snapshot.
    pub fn feed(self: *DataFilter, alloc: std.mem.Allocator, bytes: []const u8, out: *std.Io.Writer) !?[]u8 {
        const snapshot = if (self.snapshot) |*snapshot| snapshot else {
            try self.feedLive(alloc, bytes, out);
            return null;
        };
        if (snapshot.items.len + bytes.len > max_snapshot_len) return error.SnapshotTooLarge;
        try snapshot.appendSlice(alloc, bytes);
        const end = try snapshotEnd(snapshot.items) orelse return null;
        const complete = try alloc.dupe(u8, snapshot.items[0..end]);
        errdefer alloc.free(complete);
        var tail = snapshot.*;
        self.snapshot = null;
        defer tail.deinit(alloc);
        try self.feedLive(alloc, tail.items[end..], out);
        return complete;
    }

    /// Length of the complete snapshot at the start of `bytes`, or null
    /// while its FINISH record has not arrived. Ghostty verifies records
    /// and CRCs when it decodes; this only finds the boundary.
    fn snapshotEnd(bytes: []const u8) !?usize {
        if (bytes.len < envelope.len) return null;
        if (!std.mem.eql(u8, bytes[0..envelope.len], envelope)) return error.UnsupportedSnapshot;
        var offset: usize = envelope.len;
        while (bytes.len >= offset + record_header_len) {
            const tag = std.mem.readInt(u16, bytes[offset..][0..2], .little);
            const len = std.mem.readInt(u32, bytes[offset + 2 ..][0..4], .little);
            offset += record_header_len + len;
            if (tag == finish_tag) return if (offset <= bytes.len) offset else null;
        }
        return null;
    }

    fn feedLive(self: *DataFilter, alloc: std.mem.Allocator, bytes: []const u8, out: *std.Io.Writer) !void {
        try self.pending.appendSlice(alloc, bytes);
        const data = self.pending.items;
        // data[written..] has not been written; keep_from marks where an
        // incomplete metadata sequence (or a prefix of one) starts. The
        // metadata itself describes state this client set or learns
        // elsewhere (resize, theme, exit), so it is dropped.
        var written: usize = 0;
        var i: usize = 0;
        const keep_from = while (std.mem.indexOfScalarPos(u8, data, i, 0x1b)) |esc| {
            const rest = data[esc..];
            if (std.mem.startsWith(u8, rest, self.prefix)) {
                const end = std.mem.indexOfPos(u8, data, esc + self.prefix.len, apc_end) orelse {
                    if (rest.len > max_metadata_len) return error.MetadataTooLarge;
                    break esc;
                };
                try out.writeAll(data[written..esc]);
                written = end + apc_end.len;
                i = written;
            } else if (rest.len < self.prefix.len and std.mem.startsWith(u8, self.prefix, rest)) {
                break esc;
            } else {
                i = esc + 1;
            }
        } else data.len;
        try out.writeAll(data[written..keep_from]);
        const kept = data.len - keep_from;
        std.mem.copyForwards(u8, data[0..kept], data[keep_from..]);
        self.pending.items.len = kept;
    }
};

/// The control connection: JSON requests and responses, plus events.
const Control = struct {
    ws: WebSocket,
    next_id: u64 = 0,
    /// The server's message for the last failed `call`, for the user.
    failure_buf: [256]u8 = undefined,
    failure: []const u8 = "",

    const RequestError = error{RexRequestFailed} || WebSocket.Error;

    /// Send a request without waiting for its response; returns its id.
    fn send(self: *Control, alloc: std.mem.Allocator, method: []const u8, payload: anytype) RequestError!u64 {
        self.next_id += 1;
        var id_buf: [20]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{self.next_id}) catch unreachable;
        const text = try std.json.Stringify.valueAlloc(alloc, .{
            .type = "request",
            .id = id,
            .method = method,
            .payload = payload,
        }, .{});
        defer alloc.free(text);
        try self.ws.send(.text, text);
        return self.next_id;
    }

    /// Send a `block.event` request with the event JSON as is.
    fn sendEvent(self: *Control, alloc: std.mem.Allocator, block: Block, event: []const u8) RequestError!void {
        self.next_id += 1;
        const text = try std.fmt.allocPrint(
            alloc,
            "{{\"type\":\"request\",\"id\":\"{d}\",\"method\":\"block.event\",\"payload\":{{\"session_id\":{f},\"block_id\":{f},\"event\":{s}}}}}",
            .{ self.next_id, std.json.fmt(block.session_id, .{}), std.json.fmt(block.block_id, .{}), event },
        );
        defer alloc.free(text);
        try self.ws.send(.text, text);
    }

    /// Send a request and wait for its response payload. Events that
    /// arrive meanwhile are dropped; nothing during setup needs them.
    fn call(self: *Control, alloc: std.mem.Allocator, method: []const u8, payload: anytype) RequestError!std.json.Parsed(std.json.Value) {
        const id = try self.send(alloc, method, payload);
        while (true) {
            const text = switch (try self.ws.next()) {
                .text => |text| text,
                .binary => continue,
                .close => return error.EndOfStream,
            };
            var message = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return error.ProtocolError;
            if (responseId(message.value) != id) {
                message.deinit();
                continue;
            }
            if (responseError(message.value)) |err| {
                self.failure = std.fmt.bufPrint(&self.failure_buf, "{s}: {s}", .{ method, err }) catch method;
                message.deinit();
                return error.RexRequestFailed;
            }
            return message;
        }
    }
};

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return switch (field(value, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The id of a response message, or null for anything else.
fn responseId(message: std.json.Value) ?u64 {
    const kind = stringField(message, "type") orelse return null;
    if (!std.mem.eql(u8, kind, "response")) return null;
    return std.fmt.parseInt(u64, stringField(message, "id") orelse return null, 10) catch null;
}

fn responseError(message: std.json.Value) ?[]const u8 {
    const err = field(message, "error") orelse return null;
    if (err == .null) return null;
    return stringField(err, "message") orelse stringField(err, "code") orelse "unknown error";
}

/// Whether a control message is the `block_closed` event for `block_id`.
fn isBlockClosed(message: std.json.Value, block_id: []const u8) bool {
    const kind = stringField(message, "type") orelse return false;
    if (!std.mem.eql(u8, kind, "event")) return false;
    const outer = field(message, "payload") orelse return false;
    const session_event = field(outer, "payload") orelse return false;
    const event = field(session_event, "event") orelse return false;
    const event_kind = stringField(event, "type") orelse return false;
    if (!std.mem.eql(u8, event_kind, "block_closed")) return false;
    const closed = stringField(field(event, "payload") orelse return false, "block_id") orelse return false;
    return std.mem.eql(u8, closed, block_id);
}

/// Copy `bytes` as valid UTF-8, replacing invalid sequences with U+FFFD,
/// because Rex takes typed input as a JSON string.
fn appendUtf8Lossy(alloc: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len and (len == 1 or std.unicode.utf8ValidateSlice(bytes[i..][0..len]))) {
            try out.appendSlice(alloc, bytes[i..][0..len]);
            i += len;
        } else {
            try out.appendSlice(alloc, "\u{FFFD}");
            i += 1;
        }
    }
}

const Connection = struct {
    fd: posix.fd_t,
    /// The Host header value.
    host: []const u8,
};

fn connect(io: std.Io, endpoint: Endpoint) !Connection {
    switch (endpoint) {
        .unix => |path| {
            const address = try std.Io.net.UnixAddress.init(path);
            const stream = try address.connect(io);
            return .{ .fd = stream.socket.handle, .host = "localhost" };
        },
        .tcp => |tcp| {
            const host_name = try std.Io.net.HostName.init(tcp.host);
            const stream = try host_name.connect(io, tcp.port, .{ .mode = .stream });
            return .{ .fd = stream.socket.handle, .host = tcp.host };
        },
    }
}

fn openSocket(alloc: std.mem.Allocator, io: std.Io, endpoint: Endpoint, path: []const u8, protocol: []const u8) !WebSocket {
    const connection = try connect(io, endpoint);
    return WebSocket.handshake(alloc, io, connection.fd, connection.host, path, protocol);
}

const Block = struct {
    session_id: []const u8,
    block_id: []const u8,
};

/// Open a new shell block in the `monstar` session, creating the session
/// if it does not exist, and attach the connection to the session.
fn newShellBlock(control: *Control, alloc: std.mem.Allocator, arena: std.mem.Allocator) !Block {
    const layout = .{ .block = .{ .flavor = shell_flavor } };

    // An empty tuple would serialize as [], which Rex rejects.
    var sessions = try control.call(alloc, "session.list", struct {}{});
    defer sessions.deinit();
    const existing: ?[]const u8 = existing: {
        const list = field(field(sessions.value, "payload") orelse break :existing null, "sessions") orelse break :existing null;
        if (list != .array) break :existing null;
        for (list.array.items) |session| {
            const label = stringField(session, "label") orelse continue;
            if (std.mem.eql(u8, label, session_label)) break :existing stringField(session, "session_id") orelse stringField(session, "id");
        }
        break :existing null;
    };

    // A session can only be changed by a connection attached to it. If it
    // ended since it was listed, start a new one instead.
    if (existing) |session_id| attached: {
        var attach = control.call(alloc, "session.attach", .{ .session_id = session_id }) catch |err| switch (err) {
            error.RexRequestFailed => break :attached,
            else => return err,
        };
        attach.deinit();
        var window = try control.call(alloc, "session.new_window", .{ .session_id = session_id, .layout = layout });
        defer window.deinit();
        const block_id = firstBlockId(field(window.value, "payload") orelse .null) orelse return error.ProtocolError;
        return .{ .session_id = try arena.dupe(u8, session_id), .block_id = try arena.dupe(u8, block_id) };
    }

    var created = try control.call(alloc, "session.create", .{
        .label = session_label,
        .initial_windows = .{.{ .layout = layout }},
    });
    defer created.deinit();
    const payload = field(created.value, "payload") orelse return error.ProtocolError;
    const session_id = stringField(payload, "session_id") orelse return error.ProtocolError;
    const windows = field(payload, "initial_windows") orelse return error.ProtocolError;
    if (windows != .array or windows.array.items.len == 0) return error.ProtocolError;
    const block_id = firstBlockId(windows.array.items[0]) orelse return error.ProtocolError;
    (try control.call(alloc, "session.attach", .{ .session_id = session_id })).deinit();
    return .{ .session_id = try arena.dupe(u8, session_id), .block_id = try arena.dupe(u8, block_id) };
}

fn firstBlockId(window: std.json.Value) ?[]const u8 {
    const ids = field(window, "block_ids") orelse return null;
    if (ids != .array or ids.array.items.len == 0) return null;
    return switch (ids.array.items[0]) {
        .string => |s| s,
        else => null,
    };
}

/// Open a data connection to the block and return it with its nonce.
fn openData(control: *Control, alloc: std.mem.Allocator, io: std.Io, endpoint: Endpoint, block: Block) !struct { WebSocket, u64 } {
    var ticket_reply = try control.call(alloc, "data.connect", .{
        .session_id = block.session_id,
        .block_id = block.block_id,
        .data_ref_id = "terminal",
        .subprotocol = data_protocol,
    });
    defer ticket_reply.deinit();
    const ticket_text = stringField(field(ticket_reply.value, "payload") orelse .null, "ticket") orelse return error.ProtocolError;
    var hello: [17]u8 = undefined;
    hello[0] = 1;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    if ((decoder.calcSizeForSlice(ticket_text) catch return error.ProtocolError) != 16) return error.ProtocolError;
    decoder.decode(hello[1..], ticket_text) catch return error.ProtocolError;

    var data = try openSocket(alloc, io, endpoint, "/api/data", data_protocol);
    errdefer data.deinit();
    try data.send(.binary, &hello);
    const welcome = switch (try data.next()) {
        .binary => |bytes| bytes,
        else => return error.ProtocolError,
    };
    if (welcome.len >= 2 and welcome[0] == 0x82) {
        log.err("data connection rejected (reason {d})", .{welcome[1]});
        return error.DataRejected;
    }
    if (welcome.len != 32 or welcome[0] != 0x81) return error.ProtocolError;
    const nonce = std.mem.readInt(u64, welcome[24..32], .little);
    if (nonce == 0) return error.ProtocolError;
    return .{ data, nonce };
}

/// A terminal size for `com.superlogical.terminal.resize`.
pub const Size = struct {
    columns: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
};

/// The colors pushed with `com.superlogical.terminal.set_theme`. The Rex
/// server's terminal answers color queries from them.
pub const Theme = struct {
    foreground: vt.color.RGB,
    background: vt.color.RGB,
    cursor: ?vt.color.RGB,
    palette: vt.color.Palette,
    scheme: vt.device_status.ColorScheme,
};

/// Rex's modifier list: names joined with `+`, and `<mod>_side` for a
/// held modifier on the right-hand side.
fn modsText(buf: *[96]u8, mods: vt.input.KeyMods) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const names = .{ "shift", "ctrl", "alt", "super", "caps_lock", "num_lock" };
    inline for (names) |name| {
        if (@field(mods, name)) writeMod(&writer, name);
    }
    inline for (.{ "shift", "ctrl", "alt", "super" }) |name| {
        if (@field(mods, name) and @field(mods.sides, name) == .right) writeMod(&writer, name ++ "_side");
    }
    return writer.buffered();
}

fn writeMod(writer: *std.Io.Writer, name: []const u8) void {
    // 96 bytes fits every modifier at once.
    if (writer.end > 0) writer.writeByte('+') catch unreachable;
    writer.writeAll(name) catch unreachable;
}

/// A `block.event` event: `{"type": kind, "payload": payload}`.
fn eventJson(alloc: std.mem.Allocator, kind: []const u8, payload: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .type = kind, .payload = payload }, .{ .emit_null_optional_fields = false });
}

/// Rex encodes key events with the block's own Ghostty terminal, so the
/// event is sent as Ghostty describes it.
fn keyJson(alloc: std.mem.Allocator, event: vt.input.KeyEvent) ![]u8 {
    var mods: [96]u8 = undefined;
    var consumed: [96]u8 = undefined;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try appendUtf8Lossy(alloc, &text, event.utf8);
    return eventJson(alloc, "key", .{
        .key = @tagName(event.key),
        .mods = modsText(&mods, event.mods),
        .consumed_mods = modsText(&consumed, event.consumed_mods),
        .text = text.items,
        .unshifted_codepoint = @as(u32, event.unshifted_codepoint),
        .composing = event.composing,
        .action = @tagName(event.action),
    });
}

/// Null for buttons Rex has no name for.
fn mouseJson(alloc: std.mem.Allocator, event: vt.input.MouseEncodeEvent, x: u16, y: u16) !?[]u8 {
    const button: ?[]const u8 = if (event.button) |button| switch (button) {
        .left, .right, .middle => @tagName(button),
        else => return null,
    } else null;
    var mods: [96]u8 = undefined;
    return try eventJson(alloc, "mouse", .{
        .action = @tagName(event.action),
        .button = button,
        .x = x,
        .y = y,
        .mods = modsText(&mods, event.mods),
    });
}

const Input = struct {
    kind: enum { write, event },
    /// Raw bytes for a write; event JSON for an event.
    bytes: []u8,
};

/// Bounds the input queued while the server is unreachable.
const max_queued_inputs = 4096;

/// One Rex block, run by a background thread that does all the socket I/O.
///
/// The App reads the block's live output from the socket pair `start`
/// returns, as it would read a pty, and closes its end to close the
/// block. Everything else goes through the mailbox: the App posts size,
/// colors, and an ordered queue of input, and takes the restored snapshot.
pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    target: []const u8,
    kitty_image_storage_limit: usize,
    /// The thread's end of the socket pair.
    fd: posix.fd_t,
    /// Wakes the thread when the mailbox changes.
    wake_fd: posix.fd_t,
    /// Readable once `takeSnapshot` has a terminal for the App.
    ready_fd: posix.fd_t,
    thread: ?std.Thread = null,

    mutex: std.atomic.Mutex = .unlocked,
    // Mailbox, guarded by mutex. size and theme hold the newest value not
    // yet sent to the server.
    size: ?Size = null,
    theme: ?Theme = null,
    input: std.ArrayList(Input) = .empty,
    snapshot: ?vt.snapshot.Decoded = null,
    snapshot_installed: bool = false,

    pub const Options = struct {
        target: []const u8,
        /// Sent as soon as the block exists, so its snapshot is cut at
        /// the window's size.
        size: Size,
        theme: Theme,
        /// For the restored terminal; snapshots do not carry it.
        kitty_image_storage_limit: usize,
    };

    /// Start a client and return it with the App's end of the socket pair.
    pub fn start(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !struct { *Client, posix.fd_t } {
        const self = try alloc.create(Client);
        errdefer alloc.destroy(self);
        const target = try alloc.dupe(u8, options.target);
        errdefer alloc.free(target);

        var fds: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS)
            return error.SocketPairFailed;
        errdefer for (fds) |fd| {
            _ = linux.close(fd);
        };
        const wake_fd = try eventFd();
        errdefer _ = linux.close(wake_fd);
        const ready_fd = try eventFd();
        errdefer _ = linux.close(ready_fd);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .environ = environ,
            .target = target,
            .kitty_image_storage_limit = options.kitty_image_storage_limit,
            .fd = fds[1],
            .wake_fd = wake_fd,
            .ready_fd = ready_fd,
            .size = options.size,
            .theme = options.theme,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return .{ self, fds[0] };
    }

    /// Wait for the thread and free the client. The App closes its end of
    /// the socket pair first, which ends the thread.
    pub fn deinit(self: *Client) void {
        if (self.thread) |thread| thread.join();
        for (self.input.items) |item| self.alloc.free(item.bytes);
        self.input.deinit(self.alloc);
        if (self.snapshot) |*snapshot| snapshot.deinit(self.alloc);
        _ = linux.close(self.wake_fd);
        _ = linux.close(self.ready_fd);
        self.alloc.free(self.target);
        self.alloc.destroy(self);
    }

    pub fn resize(self: *Client, size: Size) void {
        self.lock();
        self.size = size;
        self.unlockAndWake();
    }

    pub fn setTheme(self: *Client, theme: Theme) void {
        self.lock();
        self.theme = theme;
        self.unlockAndWake();
    }

    /// Bytes the terminal writes back to the program, such as clipboard
    /// replies. Typed input goes through the event methods instead.
    pub fn write(self: *Client, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const owned = self.alloc.dupe(u8, bytes) catch return;
        self.queue(.write, owned);
    }

    pub fn key(self: *Client, event: vt.input.KeyEvent) void {
        self.queue(.event, keyJson(self.alloc, event) catch return);
    }

    /// Pasted or IME-committed text. The block brackets and filters it
    /// according to its own modes.
    pub fn paste(self: *Client, text: []const u8) void {
        var valid: std.ArrayList(u8) = .empty;
        defer valid.deinit(self.alloc);
        appendUtf8Lossy(self.alloc, &valid, text) catch return;
        self.queue(.event, eventJson(self.alloc, "paste", .{ .text = valid.items }) catch return);
    }

    /// A mouse event at cell (`x`, `y`).
    pub fn mouse(self: *Client, event: vt.input.MouseEncodeEvent, x: u16, y: u16) void {
        const json = mouseJson(self.alloc, event, x, y) catch return orelse return;
        self.queue(.event, json);
    }

    /// Wheel steps at cell (`x`, `y`); negative deltas scroll up or left.
    pub fn wheel(self: *Client, x: u16, y: u16, delta_x: i32, delta_y: i32) void {
        self.queue(.event, eventJson(self.alloc, "wheel", .{ .x = x, .y = y, .delta_x = delta_x, .delta_y = delta_y }) catch return);
    }

    pub fn focus(self: *Client, focused: bool) void {
        self.queue(.event, eventJson(self.alloc, "focus", .{ .action = if (focused) "in" else "out" }) catch return);
    }

    fn queue(self: *Client, kind: @FieldType(Input, "kind"), bytes: []u8) void {
        self.lock();
        const full = self.input.items.len >= max_queued_inputs;
        if (full) {
            self.mutex.unlock();
            log.warn("dropping input: queue full", .{});
            self.alloc.free(bytes);
            return;
        }
        self.input.append(self.alloc, .{ .kind = kind, .bytes = bytes }) catch {
            self.mutex.unlock();
            self.alloc.free(bytes);
            return;
        };
        self.unlockAndWake();
    }

    /// The restored terminal, once `ready_fd` is readable. The App stores
    /// the terminal at its final address, replays the continuation, and
    /// calls `snapshotInstalled`, which releases the live output held back
    /// until then.
    pub fn takeSnapshot(self: *Client) ?vt.snapshot.Decoded {
        var counter: u64 = undefined;
        _ = linux.read(self.ready_fd, std.mem.asBytes(&counter), @sizeOf(u64));
        self.lock();
        defer self.mutex.unlock();
        const snapshot = self.snapshot;
        self.snapshot = null;
        return snapshot;
    }

    pub fn snapshotInstalled(self: *Client) void {
        self.lock();
        self.snapshot_installed = true;
        self.unlockAndWake();
    }

    fn lock(self: *Client) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn unlockAndWake(self: *Client) void {
        self.mutex.unlock();
        bump(self.wake_fd);
    }

    const Mail = struct {
        size: ?Size,
        theme: ?Theme,
        input: std.ArrayList(Input),
        snapshot_installed: bool,

        fn deinit(mail: *Mail, alloc: std.mem.Allocator) void {
            for (mail.input.items) |item| alloc.free(item.bytes);
            mail.input.deinit(alloc);
        }
    };

    fn takeMail(self: *Client) Mail {
        var counter: u64 = undefined;
        _ = linux.read(self.wake_fd, std.mem.asBytes(&counter), @sizeOf(u64));
        self.lock();
        defer self.mutex.unlock();
        const mail: Mail = .{
            .size = self.size,
            .theme = self.theme,
            .input = self.input,
            .snapshot_installed = self.snapshot_installed,
        };
        self.size = null;
        self.theme = null;
        self.input = .empty;
        self.snapshot_installed = false;
        return mail;
    }

    fn run(self: *Client) void {
        var failure_buf: [256]u8 = undefined;
        var failure: []const u8 = "";
        self.session(&failure_buf, &failure) catch |err| {
            // Show the failure in the window until a key is pressed or the
            // window closes, so it can be read.
            var buf: [512]u8 = undefined;
            const reason = if (failure.len > 0) failure else switch (err) {
                error.TlsUnsupported => "https endpoints are not supported yet; use http:// or a tailnet listener",
                error.InvalidEndpoint => "not a Rex endpoint",
                else => @errorName(err),
            };
            const message = std.fmt.bufPrint(&buf, "\r\nmonstar: rex {s}: {s}\r\n[press any key to close]", .{ self.target, reason }) catch "";
            WebSocket.writeAll(self.fd, message) catch {};
            var fds = [_]posix.pollfd{
                .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            wait: while (true) {
                _ = posix.poll(&fds, -1) catch break;
                if (fds[0].revents != 0) break;
                var mail = self.takeMail();
                defer mail.deinit(self.alloc);
                for (mail.input.items) |item| if (item.kind == .event) break :wait;
            }
        };
        // The App reads end of stream as the end of the session.
        _ = linux.close(self.fd);
    }

    fn session(self: *Client, failure_buf: *[256]u8, failure: *[]const u8) !void {
        const alloc = self.alloc;
        const io = self.io;
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const endpoint = try parseEndpoint(arena, self.target, self.environ);

        var control: Control = .{ .ws = try openSocket(alloc, io, endpoint, "/api/control", control_protocol) };
        defer {
            control.ws.sendClose();
            control.ws.deinit();
        }
        // control.failure points into control, which is about to go away.
        errdefer {
            const len = @min(control.failure.len, failure_buf.len);
            @memcpy(failure_buf[0..len], control.failure[0..len]);
            failure.* = failure_buf[0..len];
        }
        const hello = try std.json.Stringify.valueAlloc(alloc, .{
            .type = "hello",
            .api_revision = api_revision,
            .api_min_revision = api_revision,
            .client = .{ .kind = "app", .platform = "linux", .name = "monstar", .label = "monstar" },
        }, .{});
        defer alloc.free(hello);
        try control.ws.send(.text, hello);
        switch (try control.ws.next()) {
            .text => |text| if (std.mem.indexOf(u8, text, "\"welcome\"") == null) return error.ProtocolError,
            else => return error.ProtocolError,
        }

        const block = try newShellBlock(&control, alloc, arena);
        var closed = false;
        defer if (!closed) {
            // Rex drops requests still running when their connection
            // closes, so wait for the reply, but not on a dead server.
            const timeout: linux.timeval = .{ .sec = 2, .usec = 0 };
            _ = linux.setsockopt(control.ws.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
            if (control.call(alloc, "block.close", .{ .session_id = block.session_id, .block_id = block.block_id })) |reply| {
                var response = reply;
                response.deinit();
            } else |err| log.warn("closing block failed: {}", .{err});
        };
        (try control.call(alloc, "session.own_block", .{ .session_id = block.session_id, .block_ids = .{block.block_id} })).deinit();
        // Size and colors apply before the snapshot so it is cut at the
        // window's size and colors.
        {
            var mail = self.takeMail();
            defer mail.deinit(alloc);
            try self.deliver(&control, block, &mail);
        }

        var data, const nonce = try openData(&control, alloc, io, endpoint, block);
        defer {
            data.sendClose();
            data.deinit();
        }
        var filter: DataFilter = try .init(alloc, nonce);
        defer filter.deinit(alloc);

        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        // Live output that follows the snapshot, held until the App has
        // installed the restored terminal.
        var held: ?std.ArrayList(u8) = null;
        defer if (held) |*bytes| bytes.deinit(alloc);
        var discard: [256]u8 = undefined;

        var fds = [_]posix.pollfd{
            .{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = control.ws.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = data.fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        while (true) {
            _ = try posix.poll(&fds, -1);

            if (fds[3].revents & posix.POLL.IN != 0) {
                var mail = self.takeMail();
                defer mail.deinit(alloc);
                try self.deliver(&control, block, &mail);
                if (mail.snapshot_installed) {
                    if (held) |*bytes| {
                        try WebSocket.writeAll(self.fd, bytes.items);
                        bytes.deinit(alloc);
                        held = null;
                    }
                }
            }

            // The App never writes; end of stream means the window closed.
            if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                if ((posix.read(self.fd, &discard) catch 0) == 0) return;
            }

            if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                if (!try control.ws.fill()) return error.EndOfStream;
                while (try control.ws.nextEvent()) |event| switch (event) {
                    .text => |text| {
                        var message = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch continue;
                        defer message.deinit();
                        if (responseError(message.value)) |err| log.warn("request failed: {s}", .{err});
                        if (isBlockClosed(message.value, block.block_id)) {
                            closed = true;
                            return;
                        }
                    },
                    .binary => {},
                    .close => return error.EndOfStream,
                };
            }

            if (fds[2].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                if (!try data.fill()) return error.EndOfStream;
                while (try data.nextEvent()) |event| switch (event) {
                    .binary => |bytes| {
                        output.clearRetainingCapacity();
                        if (try filter.feed(alloc, bytes, &output.writer)) |snapshot| {
                            defer alloc.free(snapshot);
                            try self.postSnapshot(snapshot);
                            held = .empty;
                        }
                        if (held) |*pending| {
                            try pending.appendSlice(alloc, output.written());
                        } else {
                            try WebSocket.writeAll(self.fd, output.written());
                        }
                    },
                    .text => {},
                    .close => |code| {
                        if (code == close_block_ended) {
                            closed = true;
                            return;
                        }
                        log.err("data connection closed ({?d})", .{code});
                        return error.EndOfStream;
                    },
                };
            }
        }
    }

    /// Decode the snapshot here, off the App's thread, and hand it over.
    fn postSnapshot(self: *Client, bytes: []const u8) !void {
        var reader: std.Io.Reader = .fixed(bytes);
        const decoded = try vt.snapshot.decode(self.alloc, self.io, &reader, .{
            .max_continuation_bytes = 1024 * 1024,
            .kitty_image_storage_limit = self.kitty_image_storage_limit,
        });
        self.lock();
        if (self.snapshot) |*stale| stale.deinit(self.alloc);
        self.snapshot = decoded;
        self.mutex.unlock();
        bump(self.ready_fd);
    }

    /// Send what the App posted, input in the order it was queued.
    fn deliver(self: *Client, control: *Control, block: Block, mail: *const Mail) !void {
        const alloc = self.alloc;
        if (mail.size) |size| {
            _ = try control.send(alloc, "com.superlogical.terminal.resize", .{
                .session_id = block.session_id,
                .block_id = block.block_id,
                .args = size,
            });
        }
        if (mail.theme) |theme| try sendTheme(control, alloc, block, theme);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);
        for (mail.input.items) |item| switch (item.kind) {
            .write => {
                text.clearRetainingCapacity();
                try appendUtf8Lossy(alloc, &text, item.bytes);
                // client.action runs in order with other input on this
                // connection; calling the block method directly may not.
                _ = try control.send(alloc, "client.action", .{
                    .action = "com.superlogical.terminal.write",
                    .session_id = block.session_id,
                    .block_id = block.block_id,
                    .args = .{ .data = text.items },
                });
            },
            .event => try control.sendEvent(alloc, block, item.bytes),
        };
    }
};

fn eventFd() !posix.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventFdFailed;
    return @intCast(rc);
}

fn bump(fd: posix.fd_t) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
}

fn sendTheme(control: *Control, alloc: std.mem.Allocator, block: Block, theme: Theme) !void {
    var hex: [3][7]u8 = undefined;
    var entries: [256][11]u8 = undefined;
    var palette: [256][]const u8 = undefined;
    for (&palette, &entries, theme.palette, 0..) |*entry, *buf, rgb, i| {
        entry.* = std.fmt.bufPrint(buf, "{d}=#{x:0>2}{x:0>2}{x:0>2}", .{ i, rgb.r, rgb.g, rgb.b }) catch unreachable;
    }
    _ = try control.send(alloc, "com.superlogical.terminal.set_theme", .{
        .session_id = block.session_id,
        .block_id = block.block_id,
        .args = .{
            .foreground = hexColor(&hex[0], theme.foreground),
            .background = hexColor(&hex[1], theme.background),
            // Empty keeps Rex's built-in cursor color, which follows text.
            .cursor = if (theme.cursor) |cursor| hexColor(&hex[2], cursor) else "",
            .palette = &palette,
            .scheme = @tagName(theme.scheme),
        },
    });
}

fn hexColor(buf: *[7]u8, rgb: vt.color.RGB) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
}

test "endpoints accept local, unix, http, and tailnet host forms" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const environ: std.process.Environ = .{ .block = .{ .slice = &.{"XDG_RUNTIME_DIR=/run/user/7"} } };

    try std.testing.expectEqualStrings("/run/user/7/rex/server.sock", (try parseEndpoint(arena, "local", environ)).unix);
    try std.testing.expectEqualStrings("/tmp/rex.sock", (try parseEndpoint(arena, "unix:///tmp/rex.sock", environ)).unix);
    try std.testing.expectEqualStrings("/tmp/rex.sock", (try parseEndpoint(arena, "/tmp/rex.sock", environ)).unix);

    const bare = (try parseEndpoint(arena, "xps", environ)).tcp;
    try std.testing.expectEqualStrings("xps", bare.host);
    try std.testing.expectEqual(7297, bare.port);
    const with_port = (try parseEndpoint(arena, "xps.example.ts.net:9000", environ)).tcp;
    try std.testing.expectEqualStrings("xps.example.ts.net", with_port.host);
    try std.testing.expectEqual(9000, with_port.port);
    const http = (try parseEndpoint(arena, "http://box:7297/", environ)).tcp;
    try std.testing.expectEqualStrings("box", http.host);
    try std.testing.expectEqual(7297, http.port);
    try std.testing.expectEqual(80, (try parseEndpoint(arena, "http://box", environ)).tcp.port);
    const v6 = (try parseEndpoint(arena, "[fd7a::1]:8000", environ)).tcp;
    try std.testing.expectEqualStrings("fd7a::1", v6.host);
    try std.testing.expectEqual(8000, v6.port);
    try std.testing.expectEqualStrings("fd7a::1", (try parseEndpoint(arena, "fd7a::1", environ)).tcp.host);

    try std.testing.expectError(error.TlsUnsupported, parseEndpoint(arena, "https://box", environ));
    try std.testing.expectError(error.InvalidEndpoint, parseEndpoint(arena, "ssh://me@box", environ));
    try std.testing.expectError(error.InvalidEndpoint, parseEndpoint(arena, "box:0", environ));
}

test "data filter strips metadata split across reads and keeps lookalikes" {
    const alloc = std.testing.allocator;
    var filter: DataFilter = try .init(alloc, 42);
    defer filter.deinit(alloc);
    filter.snapshot.?.deinit(alloc);
    filter.snapshot = null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const stream = "a\x1b[1mb\x1b_rex1;42;{\"type\":\"resize\",\"cols\":80}\x1b\\c" ++
        "\x1b_rex1;7;other\x1b\\" ++ // another nonce is program output
        "\x1b_rex1;42;{\"type\":\"child_exited\",\"exit_code\":3}\x1b\\d";
    // Feed one byte at a time so every split point is exercised.
    for (stream) |byte| try std.testing.expectEqual(null, try filter.feed(alloc, &.{byte}, &out.writer));
    try std.testing.expectEqualStrings("a\x1b[1mbc\x1b_rex1;7;other\x1b\\d", out.written());
}

test "data filter returns the snapshot and passes the live tail through" {
    const alloc = std.testing.allocator;
    var source: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 20, .rows = 4 });
    defer source.deinit(alloc);
    var source_stream = source.vtStream();
    defer source_stream.deinit();
    source_stream.nextSlice("hello \x1b[31mred\x1b[0m");

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try vt.snapshot.encode(alloc, &encoded.writer, &source, .{ .continuation = .ground });
    const snapshot_len = encoded.written().len;
    try encoded.writer.writeAll("\x1b_rex1;9;{\"type\":\"theme\"}\x1b\\ live");

    var filter: DataFilter = try .init(alloc, 9);
    defer filter.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const bytes = encoded.written();
    try std.testing.expectEqual(null, try filter.feed(alloc, bytes[0..7], &out.writer));
    const snapshot = (try filter.feed(alloc, bytes[7..], &out.writer)).?;
    defer alloc.free(snapshot);
    try std.testing.expectEqual(snapshot_len, snapshot.len);
    try std.testing.expectEqualStrings(" live", out.written());

    // The snapshot restores the screen.
    var reader: std.Io.Reader = .fixed(snapshot);
    var decoded = try vt.snapshot.decode(alloc, std.testing.io, &reader, .{ .max_continuation_bytes = 0 });
    defer decoded.deinit(alloc);
    const text = try decoded.terminal.?.plainString(alloc);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("hello red", text);
}

test "key events carry Ghostty's key, mods, and text" {
    const alloc = std.testing.allocator;
    const json = try keyJson(alloc, .{
        .action = .repeat,
        .key = .key_a,
        .mods = .{ .shift = true, .alt = true, .sides = .{ .alt = .right, .ctrl = .right } },
        .consumed_mods = .{ .shift = true },
        .utf8 = "A",
        .unshifted_codepoint = 'a',
    });
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        \\{"type":"key","payload":{"key":"key_a","mods":"shift+alt+alt_side","consumed_mods":"shift","text":"A","unshifted_codepoint":97,"composing":false,"action":"repeat"}}
    , json);
}

test "mouse events name Rex's buttons and skip the others" {
    const alloc = std.testing.allocator;
    const json = (try mouseJson(alloc, .{ .action = .motion, .mods = .{ .ctrl = true } }, 3, 7)).?;
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        \\{"type":"mouse","payload":{"action":"motion","x":3,"y":7,"mods":"ctrl"}}
    , json);
    try std.testing.expectEqual(null, try mouseJson(alloc, .{ .button = .eight }, 0, 0));
}
