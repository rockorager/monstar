//! Owns asynchronous OSC 5522 request state and preserves protocol order.
//! libghostty supplies parsing, write-transaction, grant, and response types;
//! Monstar owns committed operations until the Wayland poll loop completes them.

const KittyClipboard = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

const clipboard = vt.kitty.clipboard;

alloc: std.mem.Allocator,
queue: std.ArrayList(Request) = .empty,
write_state: ?*clipboard.WriteState = null,
paste_grants: std.ArrayList(PasteGrant) = .empty,

const max_paste_grants = 32;

pub const Target = enum { clipboard, primary };

pub const Request = union(enum) {
    read: Read,
    write: Write,
    status: Status,

    fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .read => |*read| read.deinit(),
            .write => |*write| write.deinit(alloc),
            .status => |status| alloc.free(status.id),
        }
    }
};

pub const Read = struct {
    arena: std.heap.ArenaAllocator,
    target: Target,
    mimes: []const []const u8,
    list: bool,
    id: []const u8,
    pw: []const u8,
    terminator: vt.osc.Terminator,
    paste: ?vt.clipboard.Content,
    grant_checked: bool = false,
    started: bool = false,

    fn deinit(self: *Read) void {
        self.arena.deinit();
    }

    pub fn needsTransfer(self: *const Read) bool {
        if (self.paste != null) return false;
        for (self.mimes) |mime| if (vt.clipboard.isTextMime(mime)) return true;
        return false;
    }

    pub fn encodeSuccess(
        self: *const Read,
        writer: *std.Io.Writer,
        available: []const []const u8,
        content: ?vt.clipboard.Content,
    ) std.Io.Writer.Error!void {
        var served_buf: [clipboard.max_read_mimes]vt.clipboard.Content = undefined;
        var served_len: usize = 0;
        for (self.mimes) |mime| {
            const source = content orelse continue;
            if (!std.mem.eql(u8, source.mime, mime) and
                !(vt.clipboard.isTextMime(source.mime) and vt.clipboard.isTextMime(mime)))
            {
                continue;
            }
            served_buf[served_len] = .{ .mime = mime, .data = source.data };
            served_len += 1;
        }

        try (clipboard.ReadSuccess{
            .primary = self.target == .primary,
            .id = self.id,
            .list = self.list,
            .available = available,
            .contents = served_buf[0..served_len],
            .terminator = self.terminator,
        }).encode(writer);
    }
};

pub const Write = struct {
    state: *clipboard.WriteState,
    committed: clipboard.WriteState.Committed,
    terminator: vt.osc.Terminator,

    fn deinit(self: *Write, alloc: std.mem.Allocator) void {
        self.committed.deinit(alloc);
        self.state.deinit(alloc);
        alloc.destroy(self.state);
    }
};

pub const Status = struct {
    op: clipboard.Operation,
    status: clipboard.Status,
    id: []const u8,
    terminator: vt.osc.Terminator,

    pub fn encode(self: *const Status, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try (clipboard.Response{
            .op = self.op,
            .status = self.status,
            .id = self.id,
            .terminator = self.terminator,
        }).encode(writer);
    }
};

const PasteGrant = struct {
    arena: std.heap.ArenaAllocator,
    target: Target,
    pw: []const u8,
    content: vt.clipboard.Content,

    fn deinit(self: *PasteGrant) void {
        self.arena.deinit();
    }
};

pub fn init(alloc: std.mem.Allocator) KittyClipboard {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *KittyClipboard) void {
    self.abortWrite();
    for (self.queue.items) |*request| request.deinit(self.alloc);
    self.queue.deinit(self.alloc);
    for (self.paste_grants.items) |*grant| grant.deinit();
    self.paste_grants.deinit(self.alloc);
}

pub fn reset(self: *KittyClipboard) void {
    self.abortWrite();
    for (self.paste_grants.items) |*grant| grant.deinit();
    self.paste_grants.clearRetainingCapacity();
}

/// Parse one libghostty OSC 5522 action. Borrowed parser slices are copied
/// before this returns; committed reads and writes enter the FIFO.
pub fn handle(
    self: *KittyClipboard,
    command: vt.osc.Command.KittyClipboardProtocol,
) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const meta = (clipboard.Metadata.parse(arena.allocator(), command.metadata) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidValue => {
            const state = self.write_state orelse return;
            switch (clipboard.Metadata.operation(command.metadata) orelse return) {
                .wdata, .walias => try self.finishWriteStatus(state, .EINVAL, command.terminator),
                .read, .write => {},
            }
            return;
        },
    }) orelse return;

    const payload = command.payload orelse "";
    switch (meta.op) {
        .read => try self.enqueueRead(&meta, payload, command.terminator),
        .write => try self.beginWrite(&meta),
        .wdata => try self.writeData(&meta, payload, command.terminator),
        .walias => try self.writeAlias(&meta, payload, command.terminator),
    }
}

pub fn front(self: *KittyClipboard) ?*Request {
    if (self.queue.items.len == 0) return null;
    return &self.queue.items[0];
}

pub fn pop(self: *KittyClipboard) void {
    var request = self.queue.orderedRemove(0);
    request.deinit(self.alloc);
}

/// Consume a read grant only when this request reaches the FIFO head. This
/// keeps one-time password state ordered with clipboard side effects.
pub fn prepareRead(self: *KittyClipboard, read: *Read) error{OutOfMemory}!void {
    if (read.grant_checked) return;
    read.grant_checked = true;
    if (clipboard.readPromptExempt(read.mimes.len)) return;
    read.paste = try self.takePasteGrant(read.arena.allocator(), read.pw, read.target);
}

/// A one-time read password is consumed even when presented to a write,
/// matching libghostty's pop-on-check grant behavior. Persistent write grants
/// are not currently created because Monstar has no remember-permission UI.
pub fn prepareWrite(self: *KittyClipboard, write: *const Write) void {
    const pw = if (write.committed.name.len > 0) write.committed.pw else "";
    self.discardPasteGrant(pw);
}

/// Emit a Kitty paste event and retain its exact contents under the generated
/// one-time password. A later granted read receives this snapshot even if the
/// Wayland selection changes while it waits in the FIFO.
pub fn paste(
    self: *KittyClipboard,
    io: std.Io,
    target: Target,
    mime: []const u8,
    data: []const u8,
    writer: *std.Io.Writer,
) !void {
    const pw = try clipboard.generateOtp(io);
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    var grant_installed = false;
    errdefer if (!grant_installed) arena.deinit();
    const grant_alloc = arena.allocator();
    const owned_pw = try grant_alloc.dupe(u8, &pw);
    const owned_mime = try grant_alloc.dupe(u8, mime);
    const owned_data = try grant_alloc.dupe(u8, data);
    const grant: PasteGrant = .{
        .target = target,
        .pw = owned_pw,
        .content = .{
            .mime = owned_mime,
            .data = owned_data,
        },
        // Copy the arena last so it includes every allocation above.
        .arena = arena,
    };

    if (self.paste_grants.items.len >= max_paste_grants) {
        var oldest = self.paste_grants.orderedRemove(0);
        oldest.deinit();
    }
    try self.paste_grants.append(self.alloc, grant);
    grant_installed = true;
    errdefer {
        var removed = self.paste_grants.pop().?;
        removed.deinit();
    }

    const available = [_][]const u8{mime};
    try (clipboard.PasteEvent{
        .primary = target == .primary,
        .pw = &pw,
        .available = &available,
    }).encode(writer);
}

fn enqueueRead(
    self: *KittyClipboard,
    meta: *const clipboard.Metadata,
    payload: []const u8,
    terminator: vt.osc.Terminator,
) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const decoded = clipboard.Payload.init(alloc, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return,
    };
    if (!decoded.isValidUtf8()) return;

    var mimes_buf: [clipboard.max_read_mimes][]const u8 = undefined;
    var mimes_len: usize = 0;
    var list = false;
    var it = decoded.mimeIterator();
    while (it.next()) |mime| {
        if (std.mem.eql(u8, mime, clipboard.targets_mime)) {
            list = true;
            continue;
        }
        if (mimes_len == mimes_buf.len) continue;
        mimes_buf[mimes_len] = mime;
        mimes_len += 1;
    }

    const mimes = try alloc.alloc([]const u8, mimes_len);
    for (mimes_buf[0..mimes_len], mimes) |src, *dst| dst.* = try alloc.dupe(u8, src);
    const target: Target = if (meta.loc == .primary) .primary else .clipboard;
    const effective_pw = if (meta.name.len > 0) meta.pw else "";
    const id = try alloc.dupe(u8, meta.id);
    const pw = try alloc.dupe(u8, effective_pw);
    try self.queue.append(self.alloc, .{
        .read = .{
            .target = target,
            .mimes = mimes,
            .list = list,
            .id = id,
            .pw = pw,
            .terminator = terminator,
            .paste = null,
            // Copy the arena last so it includes every allocation above.
            .arena = arena,
        },
    });
}

fn beginWrite(self: *KittyClipboard, meta: *const clipboard.Metadata) error{OutOfMemory}!void {
    self.abortWrite();
    const state = try self.alloc.create(clipboard.WriteState);
    errdefer self.alloc.destroy(state);
    state.* = try .init(self.alloc, meta, .{});
    self.write_state = state;
}

fn writeData(
    self: *KittyClipboard,
    meta: *const clipboard.Metadata,
    payload: []const u8,
    terminator: vt.osc.Terminator,
) error{OutOfMemory}!void {
    const state = self.write_state orelse return;
    if (meta.mime.len == 0) return self.commitWrite(state, terminator);
    state.data(self.alloc, meta, payload) catch |err| switch (err) {
        error.OutOfMemory => {
            try self.finishWriteStatus(state, .EIO, terminator);
            return error.OutOfMemory;
        },
        error.TooLarge => try self.finishWriteStatus(state, .EFBIG, terminator),
    };
}

fn writeAlias(
    self: *KittyClipboard,
    meta: *const clipboard.Metadata,
    payload: []const u8,
    terminator: vt.osc.Terminator,
) error{OutOfMemory}!void {
    const state = self.write_state orelse return;
    if (meta.mime.len == 0) return self.finishWriteStatus(state, .EINVAL, terminator);
    state.alias(self.alloc, meta, payload) catch |err| switch (err) {
        error.OutOfMemory => {
            try self.finishWriteStatus(state, .EIO, terminator);
            return error.OutOfMemory;
        },
        error.Invalid => try self.finishWriteStatus(state, .EINVAL, terminator),
    };
}

fn commitWrite(
    self: *KittyClipboard,
    state: *clipboard.WriteState,
    terminator: vt.osc.Terminator,
) error{OutOfMemory}!void {
    const committed = state.commit(self.alloc) catch |err| switch (err) {
        error.OutOfMemory => {
            try self.finishWriteStatus(state, .EIO, terminator);
            return error.OutOfMemory;
        },
    };
    errdefer committed.deinit(self.alloc);
    try self.queue.append(self.alloc, .{ .write = .{
        .state = state,
        .committed = committed,
        .terminator = terminator,
    } });
    self.write_state = null;
}

fn finishWriteStatus(
    self: *KittyClipboard,
    state: *clipboard.WriteState,
    status: clipboard.Status,
    terminator: vt.osc.Terminator,
) error{OutOfMemory}!void {
    const id = try self.alloc.dupe(u8, state.id);
    errdefer self.alloc.free(id);
    try self.queue.append(self.alloc, .{ .status = .{
        .op = .write,
        .status = status,
        .id = id,
        .terminator = terminator,
    } });
    self.abortWrite();
}

fn abortWrite(self: *KittyClipboard) void {
    if (self.write_state) |state| {
        state.deinit(self.alloc);
        self.alloc.destroy(state);
        self.write_state = null;
    }
}

fn takePasteGrant(
    self: *KittyClipboard,
    alloc: std.mem.Allocator,
    pw: []const u8,
    target: Target,
) error{OutOfMemory}!?vt.clipboard.Content {
    if (pw.len == 0) return null;
    for (self.paste_grants.items, 0..) |grant, i| {
        if (!std.mem.eql(u8, grant.pw, pw)) continue;
        var consumed = self.paste_grants.orderedRemove(i);
        defer consumed.deinit();
        if (consumed.target != target) return null;
        return .{
            .mime = try alloc.dupe(u8, consumed.content.mime),
            .data = try alloc.dupe(u8, consumed.content.data),
        };
    }
    return null;
}

fn discardPasteGrant(self: *KittyClipboard, pw: []const u8) void {
    if (pw.len == 0) return;
    for (self.paste_grants.items, 0..) |grant, i| {
        if (!std.mem.eql(u8, grant.pw, pw)) continue;
        var consumed = self.paste_grants.orderedRemove(i);
        consumed.deinit();
        return;
    }
}

test "committed operations preserve read then write order" {
    var state: KittyClipboard = .init(std.testing.allocator);
    defer state.deinit();

    try state.handle(.{
        .metadata = "type=read:id=first",
        .payload = "dGV4dC9wbGFpbg==",
        .terminator = .st,
    });
    try state.handle(.{ .metadata = "type=write:id=second", .payload = null, .terminator = .st });
    try state.handle(.{
        .metadata = "type=wdata:mime=dGV4dC9wbGFpbg==",
        .payload = "aGVsbG8=",
        .terminator = .st,
    });
    try state.handle(.{ .metadata = "type=wdata", .payload = null, .terminator = .st });

    try std.testing.expectEqualStrings("first", state.front().?.read.id);
    state.pop();
    try std.testing.expectEqualStrings("second", state.front().?.write.committed.id);
}

test "read response serves text aliases in request order" {
    var state: KittyClipboard = .init(std.testing.allocator);
    defer state.deinit();
    try state.handle(.{
        .metadata = "type=read:id=r",
        .payload = "VVRGOF9TVFJJTkcgdGV4dC9wbGFpbg==",
        .terminator = .st,
    });

    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try state.front().?.read.encodeSuccess(
        &writer,
        &.{"text/plain"},
        .{ .mime = "text/plain", .data = "hello" },
    );
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), ":mime=VVRGOF9TVFJJTkc=") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), ":mime=dGV4dC9wbGFpbg==") != null);
}

test "targets listing does not consume a paste grant" {
    var state: KittyClipboard = .init(std.testing.allocator);
    defer state.deinit();

    var paste_output: [1024]u8 = undefined;
    var paste_writer: std.Io.Writer = .fixed(&paste_output);
    try state.paste(std.testing.io, .clipboard, "text/plain", "snapshot", &paste_writer);
    const pw = state.paste_grants.items[0].pw;
    var encoded_pw: [std.base64.standard.Encoder.calcSize(clipboard.otp_len)]u8 = undefined;
    const metadata = try std.fmt.allocPrint(
        std.testing.allocator,
        "type=read:pw={s}:name=YXBw",
        .{std.base64.standard.Encoder.encode(&encoded_pw, pw)},
    );
    defer std.testing.allocator.free(metadata);

    try state.handle(.{ .metadata = metadata, .payload = "Lg==", .terminator = .st });
    try std.testing.expectEqual(@as(usize, 1), state.paste_grants.items.len);
    try state.prepareRead(&state.front().?.read);
    try std.testing.expectEqual(@as(usize, 1), state.paste_grants.items.len);
    state.pop();

    try state.handle(.{
        .metadata = metadata,
        .payload = "dGV4dC9wbGFpbg==",
        .terminator = .st,
    });
    try std.testing.expectEqual(@as(usize, 1), state.paste_grants.items.len);
    try state.prepareRead(&state.front().?.read);
    try std.testing.expectEqual(@as(usize, 0), state.paste_grants.items.len);
    try std.testing.expectEqualStrings("snapshot", state.front().?.read.paste.?.data);
}

test "paste event write failure discards its grant" {
    var state: KittyClipboard = .init(std.testing.allocator);
    defer state.deinit();

    var output: [0]u8 = .{};
    var writer: std.Io.Writer = .fixed(&output);
    try std.testing.expectError(
        error.WriteFailed,
        state.paste(std.testing.io, .clipboard, "text/plain", "snapshot", &writer),
    );
    try std.testing.expectEqual(@as(usize, 0), state.paste_grants.items.len);
}
