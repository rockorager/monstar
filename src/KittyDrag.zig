//! Terminal side of drag-out in the Kitty drag-and-drop protocol (OSC 72),
//! where a program starts a native drag. libghostty implements only drops
//! and refuses these commands, so App routes them here first. This type
//! owns the protocol state and writes replies; App owns the pointer gesture
//! and the native drag.
//!
//! A session moves idle → requested (a drag gesture sent t=o) → offered
//! (the MIME list arrived; pre-sent data and images may follow) → dragging
//! (the native drag started and t=E;OK was sent) → idle. A protocol error
//! replies t=E with a POSIX error name and ends the session.
//!
//! Drag images are kept until the drag starts, when App renders them.

const KittyDrag = @This();

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const clipboard_format = @import("clipboard_format.zig");
const DragOffer = @import("DragOffer.zig");

const dnd = vt.kitty.dnd;

/// The protocol requires accepting at least 64 MiB of pre-sent data. The
/// same budget covers data streamed during the drag.
const max_data_bytes = 64 * 1024 * 1024;
const max_image_bytes = 16 * 1024 * 1024;
const max_items = 64;
const max_images = 8;
const max_machine_id_bytes = 256;

alloc: std.mem.Allocator,
enabled: bool = false,
/// Whether the client runs on this machine, so its file URLs name local files.
local: bool = true,
client_id: u32 = 0,
chunking: dnd.Chunking = .{},
/// Set while skipping the rest of a chunked command that already failed.
discarding: bool = false,
/// Replies to a command use its terminator; events always use ST.
terminator: vt.osc.Terminator = .st,
/// Plain payload (machine ID or MIME list) accumulated across chunks.
text: std.ArrayList(u8) = .empty,
phase: Phase = .idle,
operations: dnd.Operations = .{},
/// Present from offered until the session ends.
offer: ?*DragOffer = null,
/// Parallel to `offer.items`.
streams: std.ArrayList(Stream) = .empty,
/// Validated once the drag starts and freed by `dragStarted`.
images: std.ArrayList(Image) = .empty,
/// The image to show; out of range shows none.
image_index: usize = 0,
data_bytes: usize = 0,
image_bytes: usize = 0,

const Phase = enum { idle, requested, offered, dragging };

const Stream = struct {
    decoder: Base64Stream = .{},
    /// Whether t=p data arrived; such items are complete once the drag starts.
    presented: bool = false,
    /// Whether t=e:x=5 already asked the client for this item.
    requested: bool = false,
};

pub const Image = struct {
    /// 0 is UTF-8 text, 24 RGB, 32 RGBA, and 100 PNG.
    format: u8,
    /// Pixel size, or for text a font scale of width / height.
    width: u32,
    height: u32,
    /// Text background opacity in 1024ths.
    opacity: u32,
    data: std.ArrayList(u8) = .empty,
    decoder: Base64Stream = .{},
};

const Error = error{ NotAllowed, Invalid, TooLarge } || std.mem.Allocator.Error;

pub const Action = enum {
    /// Not a drag-out command; libghostty handles it.
    forward,
    handled,
    /// Start a native drag for `offer` with `operations`, then report the
    /// outcome with `dragStarted` or `dragFailed`.
    start_drag,
    /// The session ended; cancel the native drag.
    cancel_drag,
    /// Show `image_index` instead of the current drag image.
    change_image,
};

pub fn init(alloc: std.mem.Allocator) KittyDrag {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *KittyDrag) void {
    self.endSession();
    self.text.deinit(self.alloc);
    self.streams.deinit(self.alloc);
    self.images.deinit(self.alloc);
}

/// Forget the client's registration, as on a terminal reset. The caller
/// cancels any native drag.
pub fn reset(self: *KittyDrag) void {
    self.endSession();
    self.enabled = false;
    self.local = true;
    self.client_id = 0;
    self.chunking = .{};
    self.discarding = false;
}

pub fn handle(
    self: *KittyDrag,
    writer: *std.Io.Writer,
    command: vt.osc.Command.KittyDndProtocol,
) std.Io.Writer.Error!Action {
    // libghostty ignores malformed metadata too.
    const raw = dnd.Metadata.parse(command.metadata) orelse return .forward;
    // Queries are allowed mid-chunk and libghostty answers them.
    if (raw.type == .query) return .forward;
    if (!self.chunking.active) switch (raw.type orelse return .forward) {
        .offer, .present, .start_drag, .drag_event, .drag_error, .remote_data => {},
        else => return .forward,
    };
    const meta = self.chunking.apply(raw);
    if (self.discarding) {
        self.discarding = self.chunking.active;
        return .handled;
    }
    self.terminator = command.terminator;
    return self.process(meta, command.payload orelse "") catch |err| {
        self.discarding = self.chunking.active;
        return self.fail(writer, switch (err) {
            error.NotAllowed => .EPERM,
            error.Invalid => .EINVAL,
            error.TooLarge => .EFBIG,
            error.OutOfMemory => .ENOMEM,
        });
    };
}

/// Whether a drag gesture should be reported with `requestDrag`.
pub fn wantsGesture(self: *const KittyDrag) bool {
    return self.enabled and self.phase == .idle;
}

/// Ask the client whether to start a drag where the gesture crossed the
/// drag threshold. The pointer button must still be held.
pub fn requestDrag(self: *KittyDrag, writer: *std.Io.Writer, position: dnd.MoveEvent) std.Io.Writer.Error!void {
    std.debug.assert(self.wantsGesture());
    self.phase = .requested;
    try self.event(writer, "t=o:x={d}:y={d}:X={d}:Y={d}", .{
        position.cell_x, position.cell_y, position.pixel_x, position.pixel_y,
    });
}

/// The button that started the gesture was released. A drag that has not
/// started can no longer start.
pub fn endGesture(self: *KittyDrag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.phase) {
        .idle, .dragging => {},
        // The client may still be deciding; a late offer gets EPERM.
        .requested => self.endSession(),
        .offered => {
            self.endSession();
            try dnd.encodeError(writer, .drag, .{}, self.client_id, .EPERM, "", .st);
        },
    }
}

/// The native drag started with images rendered from `images`.
pub fn dragStarted(self: *KittyDrag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    std.debug.assert(self.phase == .offered);
    self.phase = .dragging;
    self.clearImages();
    try dnd.encodeError(writer, .drag, .{}, self.client_id, .OK, "", self.terminator);
}

pub fn dragFailed(self: *KittyDrag, writer: *std.Io.Writer, errno: dnd.Errno) std.Io.Writer.Error!void {
    std.debug.assert(self.phase == .offered);
    _ = try self.fail(writer, errno);
}

/// A drop target would accept the item at `index`.
pub fn targetChanged(self: *KittyDrag, writer: *std.Io.Writer, index: usize) std.Io.Writer.Error!void {
    if (self.phase != .dragging) return;
    try self.event(writer, "t=e:x=1:y={d}", .{index});
}

pub fn actionChanged(self: *KittyDrag, writer: *std.Io.Writer, operation: dnd.Operation) std.Io.Writer.Error!void {
    if (self.phase != .dragging) return;
    try self.event(writer, "t=e:x=2:o={d}", .{@intFromEnum(operation)});
}

pub fn dropped(self: *KittyDrag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.phase != .dragging) return;
    try self.event(writer, "t=e:x=3", .{});
}

/// The native drag ended. Transfers already queued may still complete.
pub fn finished(self: *KittyDrag, writer: *std.Io.Writer, cancelled: bool) std.Io.Writer.Error!void {
    if (self.phase != .dragging) return;
    self.endSession();
    try self.event(writer, "t=e:x=4:y={d}", .{@intFromBool(cancelled)});
}

/// A drop target asked for an item. Ask the client once for data it did
/// not pre-send.
pub fn requestData(self: *KittyDrag, writer: *std.Io.Writer, index: usize) std.Io.Writer.Error!void {
    if (self.phase != .dragging) return;
    const stream = &self.streams.items[index];
    if (stream.requested or self.offer.?.items.items[index].state != .pending) return;
    stream.requested = true;
    try self.event(writer, "t=e:x=5:y={d}", .{index});
}

fn process(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!Action {
    switch (meta.type.?) {
        .offer => switch (meta.cell_x) {
            0 => try self.receiveOffer(meta, payload),
            1, 2 => try self.configure(meta, payload),
            else => return error.Invalid,
        },
        .present => if (meta.cell_x >= 0)
            try self.presentData(meta, payload)
        else
            try self.presentImage(meta, payload),
        .start_drag => return if (meta.cell_x == -1) self.start() else self.changeImage(meta.cell_x),
        .drag_event => try self.receiveData(meta, payload),
        .drag_error => return self.receiveError(meta),
        // The terminal never requests remote file data.
        .remote_data => {},
        else => unreachable,
    }
    return .handled;
}

fn configure(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!void {
    if (meta.cell_x == 2) {
        self.enabled = false;
        // A started drag keeps its data; only new gestures stop.
        if (self.phase != .dragging) self.endSession();
        return;
    }
    try self.appendText(payload, max_machine_id_bytes);
    if (meta.more) return;
    defer self.text.clearRetainingCapacity();
    var buf: [256]u8 = undefined;
    self.enabled = true;
    self.client_id = meta.client_id;
    self.local = machineIdMatches(self.text.items, readMachineId(&buf));
}

fn receiveOffer(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!void {
    switch (self.phase) {
        // The gesture ended or never asked for an offer.
        .idle => return error.NotAllowed,
        .requested => {},
        .offered, .dragging => return error.Invalid,
    }
    if (meta.operation == 0 or meta.operation > 3) return error.Invalid;
    try self.appendText(payload, dnd.max_mime_list_bytes);
    if (meta.more) return;
    defer self.text.clearRetainingCapacity();

    const offer = try DragOffer.create(self.alloc);
    errdefer offer.release();
    var advertised: usize = 0;
    var mimes = std.mem.tokenizeScalar(u8, self.text.items, ' ');
    while (mimes.next()) |mime| {
        if (offer.items.items.len == max_items) return error.TooLarge;
        for (mime) |byte| if (byte <= ' ' or byte >= 0x7f) return error.Invalid;
        // A remote client's file URLs name files on its machine, and this
        // terminal cannot fetch them (t=k), so keep them out of the drag.
        const advertise = self.local or !std.mem.eql(u8, mime, clipboard_format.uri_list_mime);
        try offer.append(mime, advertise);
        if (advertise) advertised += 1;
    }
    if (offer.items.items.len == 0) return error.Invalid;
    if (advertised == 0) return error.NotAllowed;
    try self.streams.appendNTimes(self.alloc, .{}, offer.items.items.len);
    self.offer = offer;
    self.operations = @bitCast(@as(u2, @intCast(meta.operation)));
    self.client_id = meta.client_id;
    self.phase = .offered;
}

fn presentData(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!void {
    switch (self.phase) {
        // Leftovers from an offer that was already refused.
        .idle => return,
        .offered => {},
        .requested, .dragging => return error.Invalid,
    }
    const index = try self.itemIndex(meta.cell_x);
    const stream = &self.streams.items[index];
    stream.presented = true;
    const item = &self.offer.?.items.items[index];
    self.data_bytes += try stream.decoder.feed(self.alloc, &item.data, payload, max_data_bytes - self.data_bytes);
}

fn presentImage(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!void {
    switch (self.phase) {
        .idle => return,
        .offered => {},
        .requested, .dragging => return error.Invalid,
    }
    const index: usize = @intCast(-@as(i64, meta.cell_x) - 1);
    // Images arrive consecutively: continue the last one or start the next.
    if (index == self.images.items.len) {
        if (index == max_images) return error.TooLarge;
        switch (meta.cell_y) {
            0, 24, 32, 100 => {},
            else => return error.Invalid,
        }
        // Text (format 0) uses X/Y as a font scale and may omit them.
        if (meta.cell_y != 0 and (meta.pixel_x < 1 or meta.pixel_y < 1)) return error.Invalid;
        try self.images.append(self.alloc, .{
            .format = @intCast(meta.cell_y),
            .width = @intCast(@max(meta.pixel_x, 0)),
            .height = @intCast(@max(meta.pixel_y, 0)),
            .opacity = meta.operation,
        });
    } else if (index + 1 != self.images.items.len) return error.Invalid;
    const image = &self.images.items[index];
    self.image_bytes += try image.decoder.feed(self.alloc, &image.data, payload, max_image_bytes - self.image_bytes);
}

fn start(self: *KittyDrag) Error!Action {
    switch (self.phase) {
        // The offer was already refused.
        .idle => return .handled,
        .offered => {},
        .requested, .dragging => return error.Invalid,
    }
    // Like kitty, treat whatever was pre-sent as complete when the drag
    // starts; the empty terminating chunk is optional.
    for (self.streams.items, self.offer.?.items.items) |*stream, *item| {
        if (!stream.presented) continue;
        self.data_bytes += try stream.decoder.finish(self.alloc, &item.data, max_data_bytes - self.data_bytes);
        item.state = .complete;
    }
    for (self.images.items) |*image| {
        self.image_bytes += try image.decoder.finish(self.alloc, &image.data, max_image_bytes - self.image_bytes);
        if (!validImage(image)) return error.Invalid;
    }
    return .start_drag;
}

fn changeImage(self: *KittyDrag, index: i32) Error!Action {
    if (index < 0) return error.Invalid;
    switch (self.phase) {
        .idle, .requested => return .handled,
        .offered, .dragging => {},
    }
    self.image_index = @intCast(index);
    return if (self.phase == .dragging) .change_image else .handled;
}

fn receiveData(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8) Error!void {
    switch (self.phase) {
        // Leftovers after the drag ended.
        .idle => return,
        .dragging => {},
        .requested, .offered => return error.Invalid,
    }
    const index = try self.itemIndex(meta.cell_y);
    const item = &self.offer.?.items.items[index];
    if (item.state != .pending) {
        // A repeated end of data is harmless, as in kitty; more data is not.
        if (item.state == .complete and !meta.more and payload.len == 0) return;
        return error.Invalid;
    }
    const stream = &self.streams.items[index];
    self.data_bytes += try stream.decoder.feed(self.alloc, &item.data, payload, max_data_bytes - self.data_bytes);
    // Only an empty final chunk ends the data.
    if (meta.more or payload.len > 0) return;
    self.data_bytes += try stream.decoder.finish(self.alloc, &item.data, max_data_bytes - self.data_bytes);
    item.state = .complete;
}

fn receiveError(self: *KittyDrag, meta: dnd.Metadata) Error!Action {
    if (meta.cell_y == -1) {
        const dragging = self.phase == .dragging;
        self.endSession();
        return if (dragging) .cancel_drag else .handled;
    }
    switch (self.phase) {
        .idle => return .handled,
        .dragging => {},
        .requested, .offered => return error.Invalid,
    }
    const index = try self.itemIndex(meta.cell_y);
    self.offer.?.items.items[index].state = .failed;
    return .handled;
}

fn itemIndex(self: *const KittyDrag, index: i32) Error!usize {
    if (index < 0 or index >= self.offer.?.items.items.len) return error.Invalid;
    return @intCast(index);
}

fn appendText(self: *KittyDrag, payload: []const u8, limit: usize) Error!void {
    if (payload.len > limit -| self.text.items.len) return error.TooLarge;
    try self.text.appendSlice(self.alloc, payload);
}

fn fail(self: *KittyDrag, writer: *std.Io.Writer, errno: dnd.Errno) std.Io.Writer.Error!Action {
    const dragging = self.phase == .dragging;
    self.endSession();
    try dnd.encodeError(writer, .drag, .{}, self.client_id, errno, "", self.terminator);
    return if (dragging) .cancel_drag else .handled;
}

fn event(self: *const KittyDrag, writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    var buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    try dnd.encode(writer, header, self.client_id, "", .plain, .st);
}

/// Keeps the client registration and any chunk state.
fn endSession(self: *KittyDrag) void {
    if (self.offer) |offer| offer.release();
    self.offer = null;
    self.streams.clearRetainingCapacity();
    self.clearImages();
    self.text.clearRetainingCapacity();
    self.phase = .idle;
    self.image_index = 0;
    self.data_bytes = 0;
}

fn clearImages(self: *KittyDrag) void {
    for (self.images.items) |*image| image.data.deinit(self.alloc);
    self.images.clearRetainingCapacity();
    self.image_bytes = 0;
}

fn validImage(image: *const Image) bool {
    const pixels = @as(u64, image.width) * image.height;
    return switch (image.format) {
        0 => std.unicode.utf8ValidateSlice(image.data.items),
        24 => image.data.items.len == pixels * 3,
        32 => image.data.items.len == pixels * 4,
        100 => pngHasSize(image.data.items, image.width, image.height),
        else => unreachable,
    };
}

fn pngHasSize(data: []const u8, width: u32, height: u32) bool {
    // The signature is followed by the IHDR chunk: length, type, width, height.
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return false;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return false;
    return std.mem.readInt(u32, data[16..20], .big) == width and
        std.mem.readInt(u32, data[20..24], .big) == height;
}

/// `client` is the ID from t=o:x=1; `host` is this machine's raw machine
/// ID, null when unknown. Like kitty, an absent client ID or an unknown
/// host ID counts as the same machine and an unknown version as different.
fn machineIdMatches(client: []const u8, host: ?[]const u8) bool {
    if (client.len == 0) return true;
    const id = host orelse return true;
    if (!std.mem.startsWith(u8, client, "1:")) return false;
    var digest: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, id, "tty-dnd-protocol-machine-id");
    return std.mem.eql(u8, client[2..], &std.fmt.bytesToHex(digest, .lower));
}

fn readMachineId(buf: []u8) ?[]const u8 {
    const fd = posix.openat(posix.AT.FDCWD, "/etc/machine-id", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    const n = posix.read(fd, buf) catch return null;
    const id = std.mem.trimEnd(u8, buf[0..n], " \t\r\n");
    return if (id.len == 0) null else id;
}

/// Decodes base64 that may be split anywhere across chunks. Padding is
/// optional and may only end the stream.
const Base64Stream = struct {
    carry: [4]u8 = undefined,
    carry_len: u8 = 0,
    padded: bool = false,

    /// Appends the decoded bytes to `out` and returns their count, which
    /// may not exceed `budget`.
    fn feed(
        self: *Base64Stream,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        input: []const u8,
        budget: usize,
    ) Error!usize {
        if (input.len == 0) return 0;
        if (self.padded) return error.Invalid;
        var rest = input;
        var decoded: usize = 0;
        if (self.carry_len > 0) {
            const take = @min(4 - self.carry_len, rest.len);
            @memcpy(self.carry[self.carry_len..][0..take], rest[0..take]);
            self.carry_len += @intCast(take);
            rest = rest[take..];
            if (self.carry_len < 4) return 0;
            self.carry_len = 0;
            decoded += try self.decodeQuanta(alloc, out, &self.carry, budget);
        }
        const whole = rest.len - rest.len % 4;
        if (rest.len > 0 and self.padded) return error.Invalid;
        if (whole > 0) decoded += try self.decodeQuanta(alloc, out, rest[0..whole], budget - decoded);
        const tail = rest[whole..];
        if (tail.len > 0 and self.padded) return error.Invalid;
        @memcpy(self.carry[0..tail.len], tail);
        self.carry_len = @intCast(tail.len);
        return decoded;
    }

    /// Decodes an unpadded final quantum and resets the stream.
    fn finish(self: *Base64Stream, alloc: std.mem.Allocator, out: *std.ArrayList(u8), budget: usize) Error!usize {
        defer self.* = .{};
        if (self.carry_len == 0) return 0;
        return decodeInto(std.base64.standard_no_pad.Decoder, alloc, out, self.carry[0..self.carry_len], budget);
    }

    fn decodeQuanta(self: *Base64Stream, alloc: std.mem.Allocator, out: *std.ArrayList(u8), quanta: []const u8, budget: usize) Error!usize {
        const size = try decodeInto(std.base64.standard.Decoder, alloc, out, quanta, budget);
        self.padded = quanta[quanta.len - 1] == '=';
        return size;
    }

    fn decodeInto(
        decoder: std.base64.Base64Decoder,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        encoded: []const u8,
        budget: usize,
    ) Error!usize {
        const size = decoder.calcSizeForSlice(encoded) catch return error.Invalid;
        if (size > budget) return error.TooLarge;
        try out.ensureUnusedCapacity(alloc, size);
        decoder.decode(out.unusedCapacitySlice()[0..size], encoded) catch return error.Invalid;
        out.items.len += size;
        return size;
    }
};

const testing = std.testing;
const origin: dnd.MoveEvent = .{ .cell_x = 0, .cell_y = 0, .pixel_x = 0, .pixel_y = 0, .operations = .{} };

const Harness = struct {
    drag: KittyDrag,
    out: std.Io.Writer.Allocating,

    fn init() Harness {
        return .{ .drag = .init(testing.allocator), .out = .init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.drag.deinit();
        self.out.deinit();
    }

    fn send(self: *Harness, metadata: []const u8, payload: ?[]const u8) !Action {
        return self.drag.handle(&self.out.writer, .{ .metadata = metadata, .payload = payload, .terminator = .st });
    }

    /// Returns and clears everything written so far.
    fn take(self: *Harness) ![]u8 {
        const written = try testing.allocator.dupe(u8, self.out.writer.buffered());
        self.out.clearRetainingCapacity();
        return written;
    }

    fn expectOutput(self: *Harness, expected: []const u8) !void {
        const written = try self.take();
        defer testing.allocator.free(written);
        try testing.expectEqualStrings(expected, written);
    }

    /// Enable offers, cross the gesture threshold, and offer `mimes`.
    fn offer(self: *Harness, mimes: []const u8) !void {
        try testing.expectEqual(Action.handled, try self.send("t=o:x=1", null));
        try self.drag.requestDrag(&self.out.writer, origin);
        try testing.expectEqual(Action.handled, try self.send("t=o:o=1", mimes));
        self.out.clearRetainingCapacity();
    }

    fn startDrag(self: *Harness, mimes: []const u8) !void {
        try self.offer(mimes);
        try testing.expectEqual(Action.start_drag, try self.send("t=P:x=-1", null));
        try self.drag.dragStarted(&self.out.writer);
        self.out.clearRetainingCapacity();
    }

    fn item(self: *Harness, index: usize) *DragOffer.Item {
        return &self.drag.offer.?.items.items[index];
    }
};

test "chunked offer and pre-sent data split mid-quantum start a drag" {
    var h: Harness = .init();
    defer h.deinit();

    try testing.expectEqual(Action.handled, try h.send("t=o:x=1:i=7", null));
    try testing.expect(h.drag.wantsGesture());
    try h.drag.requestDrag(&h.out.writer, .{ .cell_x = 3, .cell_y = 4, .pixel_x = 30, .pixel_y = 64, .operations = .{} });
    try h.expectOutput("\x1b]72;t=o:x=3:y=4:X=30:Y=64:i=7\x1b\\");

    // The MIME list splits inside a name, and continuations carry only m.
    try testing.expectEqual(Action.handled, try h.send("t=o:x=0:o=3:i=7:m=1", "text/plain te"));
    try testing.expectEqual(Action.handled, try h.send("m=0", "xt/uri-list"));
    // "hello world" split after five base64 characters, with no padding
    // and no empty terminator, like kitty accepts.
    try testing.expectEqual(Action.handled, try h.send("t=p:x=0:m=1", "aGVsb"));
    try testing.expectEqual(Action.handled, try h.send("m=0", "G8gd29ybGQ"));
    try h.expectOutput("");

    try testing.expectEqual(Action.start_drag, try h.send("t=P:x=-1", null));
    try testing.expectEqual(dnd.Operations{ .copy = true, .move = true }, h.drag.operations);
    try testing.expectEqualStrings("text/plain", h.item(0).mime);
    try testing.expectEqualStrings("hello world", h.item(0).data.items);
    try testing.expectEqual(DragOffer.State.complete, h.item(0).state);
    try testing.expectEqualStrings("text/uri-list", h.item(1).mime);
    try testing.expectEqual(DragOffer.State.pending, h.item(1).state);
    try testing.expect(h.item(1).advertised);

    try h.drag.dragStarted(&h.out.writer);
    try h.expectOutput("\x1b]72;t=E:i=7:m=0;OK\x1b\\");
}

test "requested data completes only on an empty final chunk" {
    var h: Harness = .init();
    defer h.deinit();
    try h.startDrag("text/plain image/png");

    try h.drag.requestData(&h.out.writer, 1);
    try h.drag.requestData(&h.out.writer, 1);
    try h.expectOutput("\x1b]72;t=e:x=5:y=1\x1b\\");

    try testing.expectEqual(Action.handled, try h.send("t=e:y=1", "AAEC"));
    try testing.expectEqual(DragOffer.State.pending, h.item(1).state);
    try testing.expectEqual(Action.handled, try h.send("t=e:y=1", ""));
    try testing.expectEqual(DragOffer.State.complete, h.item(1).state);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, h.item(1).data.items);
    // A second end of data is tolerated.
    try testing.expectEqual(Action.handled, try h.send("t=e:y=1", ""));
    try h.expectOutput("");

    try testing.expectEqual(Action.handled, try h.send("t=E:y=0", "ENOENT"));
    try testing.expectEqual(DragOffer.State.failed, h.item(0).state);
    try h.expectOutput("");

    try h.drag.finished(&h.out.writer, false);
    try h.expectOutput("\x1b]72;t=e:x=4:y=0\x1b\\");
    try testing.expect(h.drag.wantsGesture());
    // Data that was still in flight is ignored after the drag.
    try testing.expectEqual(Action.handled, try h.send("t=e:y=0", "AAAA"));
    try h.expectOutput("");
}

test "a released gesture refuses its offer once" {
    var h: Harness = .init();
    defer h.deinit();

    // Released before the client offered: silent, then the offer is refused.
    _ = try h.send("t=o:x=1", null);
    try h.drag.requestDrag(&h.out.writer, origin);
    h.out.clearRetainingCapacity();
    try h.drag.endGesture(&h.out.writer);
    try h.expectOutput("");
    try testing.expectEqual(Action.handled, try h.send("t=o:o=1", "text/plain"));
    try h.expectOutput("\x1b]72;t=E:m=0;EPERM\x1b\\");
    try testing.expectEqual(Action.handled, try h.send("t=p:x=0", "QQ"));
    try testing.expectEqual(Action.handled, try h.send("t=P:x=-1", null));
    try h.expectOutput("");

    // Released after the offer: refused immediately, and the rest of the
    // client's drag is ignored.
    try h.offer("text/plain");
    try h.drag.endGesture(&h.out.writer);
    try h.expectOutput("\x1b]72;t=E:m=0;EPERM\x1b\\");
    try testing.expectEqual(Action.handled, try h.send("t=P:x=-1", null));
    try h.expectOutput("");
}

test "an error ends the session and skips the rest of its chunks" {
    var h: Harness = .init();
    defer h.deinit();

    try h.offer("text/plain");
    try testing.expectEqual(Action.handled, try h.send("t=e:y=0", "QQ"));
    try h.expectOutput("\x1b]72;t=E:m=0;EINVAL\x1b\\");
    try testing.expect(h.drag.wantsGesture());

    // Later chunks of a failed offer would otherwise each draw EPERM.
    try h.drag.requestDrag(&h.out.writer, origin);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(Action.handled, try h.send("t=o:o=9:m=1", "text/plain "));
    try testing.expectEqual(Action.handled, try h.send("m=1", "image/png "));
    try testing.expectEqual(Action.handled, try h.send("m=0", "text/html"));
    try h.expectOutput("\x1b]72;t=E:m=0;EINVAL\x1b\\");
    // The next command is processed normally again.
    try testing.expectEqual(Action.handled, try h.send("t=o:x=2", null));
    try testing.expect(!h.drag.wantsGesture());

    // During a drag, an error also cancels the native drag.
    try h.startDrag("text/plain");
    try testing.expectEqual(Action.cancel_drag, try h.send("t=e:y=1", "QQ"));
    try h.expectOutput("\x1b]72;t=E:m=0;EINVAL\x1b\\");
}

test "drag data is bounded" {
    var h: Harness = .init();
    defer h.deinit();
    try h.startDrag("text/plain");
    // Two bytes remain; four base64 characters decode to three.
    h.drag.data_bytes = max_data_bytes - 2;
    try testing.expectEqual(Action.cancel_drag, try h.send("t=e:y=0", "AAAA"));
    try h.expectOutput("\x1b]72;t=E:m=0;EFBIG\x1b\\");
}

test "the client can cancel its drag" {
    var h: Harness = .init();
    defer h.deinit();
    try h.startDrag("text/plain");
    try testing.expectEqual(Action.cancel_drag, try h.send("t=E:y=-1", null));
    try h.drag.finished(&h.out.writer, true);
    try h.expectOutput("");
    try testing.expect(h.drag.wantsGesture());
}

test "remote clients keep file URLs out of the native drag" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.send("t=o:x=1", null);
    h.drag.local = false;
    try h.drag.requestDrag(&h.out.writer, origin);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(Action.handled, try h.send("t=o:o=1", "text/uri-list text/plain"));
    try testing.expectEqual(@as(?usize, null), h.drag.offer.?.advertisedIndex("text/uri-list"));
    try testing.expectEqual(@as(?usize, 1), h.drag.offer.?.advertisedIndex("text/plain"));

    try h.drag.endGesture(&h.out.writer);
    try h.drag.requestDrag(&h.out.writer, origin);
    h.out.clearRetainingCapacity();
    try testing.expectEqual(Action.handled, try h.send("t=o:o=1", "text/uri-list"));
    try h.expectOutput("\x1b]72;t=E:m=0;EPERM\x1b\\");
}

test "machine IDs compare kitty's salted hash" {
    // HMAC-SHA256 keyed by "tty-dnd-protocol-machine-id", computed with Python's hmac.
    const client = "1:a81b6c3c9d37b0caa4a9c6b7de41059238bc101829db2975223b93d39d663b08";
    const host = "0123456789abcdef0123456789abcdef";
    try testing.expect(machineIdMatches(client, host));
    try testing.expect(!machineIdMatches(client, "fedcba9876543210fedcba9876543210"));
    try testing.expect(!machineIdMatches("2" ++ client[1..], host));
    try testing.expect(machineIdMatches("", host));
    try testing.expect(machineIdMatches(client, null));
}

test "drag images are validated when the drag starts" {
    var h: Harness = .init();
    defer h.deinit();

    // A 2x1 RGB image needs six bytes; five arrive.
    try h.offer("text/plain");
    _ = try h.send("t=p:x=-1:y=24:X=2:Y=1", "AAAAAAA");
    try testing.expectEqual(Action.handled, try h.send("t=P:x=-1", null));
    try h.expectOutput("\x1b]72;t=E:m=0;EINVAL\x1b\\");

    // Images must start at -1 and arrive in order.
    try h.offer("text/plain");
    _ = try h.send("t=p:x=-2:y=32:X=1:Y=1", "AAAAAA");
    try h.expectOutput("\x1b]72;t=E:m=0;EINVAL\x1b\\");

    // Text without a scale and a PNG whose header matches X and Y.
    try h.offer("text/plain");
    var png: [32]u8 = undefined;
    var png_b64: [44]u8 = undefined;
    const header = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x03\x00\x00\x00\x02";
    @memcpy(png[0..header.len], header);
    @memset(png[header.len..], 0);
    _ = try h.send("t=p:x=-1", "4p6Q");
    _ = try h.send("t=p:x=-2:y=100:X=3:Y=2", std.base64.standard.Encoder.encode(&png_b64, &png));
    // Choosing an image before the start applies when the drag starts.
    try testing.expectEqual(Action.handled, try h.send("t=P:x=1", null));
    try testing.expectEqual(Action.start_drag, try h.send("t=P:x=-1", null));
    try h.expectOutput("");
    // App renders the images between start_drag and dragStarted.
    try testing.expectEqual(@as(usize, 2), h.drag.images.items.len);
    try testing.expectEqual(@as(usize, 1), h.drag.image_index);
    try testing.expectEqualStrings("\u{2790}", h.drag.images.items[0].data.items);
    try h.drag.dragStarted(&h.out.writer);
    try testing.expectEqual(@as(usize, 0), h.drag.images.items.len);
    try testing.expectEqual(Action.change_image, try h.send("t=P:x=5", null));
    try testing.expectEqual(@as(usize, 5), h.drag.image_index);
}

test "base64 streams reject data after padding and a dangling character" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    var stream: Base64Stream = .{};
    _ = try stream.feed(testing.allocator, &out, "QQ=", 16);
    _ = try stream.feed(testing.allocator, &out, "=", 16);
    try testing.expectEqualStrings("A", out.items);
    try testing.expectError(error.Invalid, stream.feed(testing.allocator, &out, "QQ", 16));

    stream = .{};
    _ = try stream.feed(testing.allocator, &out, "QUJDR", 16);
    try testing.expectError(error.Invalid, stream.finish(testing.allocator, &out, 16));
}

test "drop commands, queries, and malformed metadata go to libghostty" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expectEqual(Action.forward, try h.send("t=a", "text/plain"));
    try testing.expectEqual(Action.forward, try h.send("t=r:x=1", null));
    try testing.expectEqual(Action.forward, try h.send("m=0", "continuation"));
    try testing.expectEqual(Action.forward, try h.send("t=o:x=", null));

    try h.offer("text/plain");
    try testing.expectEqual(Action.handled, try h.send("t=p:x=0:m=1", "AAAA"));
    try testing.expectEqual(Action.forward, try h.send("t=q", null));
    try testing.expectEqual(Action.handled, try h.send("m=0", "AAAA"));
    try h.expectOutput("");
}
