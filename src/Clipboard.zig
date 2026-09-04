//! Owns Wayland clipboard, primary-selection, drag-and-drop, and their
//! bounded, nonblocking transfers: one incoming pipe and a small outgoing
//! pool, all with deadlines. Application policy remains with App.

const Clipboard = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const clipboard_format = @import("clipboard_format.zig");

const log = std.log.scoped(.app);

// Keep one transfer within the PTY write backlog's bound. Without a cap, a
// clipboard owner that never closes its pipe can grow this process without
// limit while the event loop continues draining it.
const max_transfer_size = 1024 * 1024;
pub const max_outgoing_transfers = 8;
const max_outgoing_bytes = 16 * 1024 * 1024;
const transfer_timeout_ms: i64 = 10 * 1000;
const max_write_per_dispatch = 64 * 1024;

pub const Target = enum { clipboard, primary };

pub const Purpose = union(enum) {
    terminal: Target,
    osc52_read: u8,
    kitty_read,
};

pub const RequestResult = enum { started, busy, unavailable };

pub const DndData = struct {
    mime: []const u8,
    data: []const u8,
    x: f64,
    y: f64,
    operations: DndOperations,
};

pub const Event = union(enum) {
    terminal: struct {
        target: Target,
        mime: []const u8,
        data: []const u8,
    },
    osc52_read: struct { kind: u8, data: []const u8 },
    kitty_read: struct { mime: []const u8, data: []const u8 },
    dnd: DndData,
};

pub const DndOperations = packed struct(u2) {
    copy: bool = false,
    move: bool = false,
};

pub const DndMotion = struct {
    x: f64,
    y: f64,
    mime: []const u8,
    operations: DndOperations,
};

pub const DndEvent = union(enum) {
    motion: DndMotion,
    leave,
};

pub const DndFn = *const fn (ctx: *anyopaque, event: DndEvent) bool;

alloc: std.mem.Allocator,
data_manager: ?*wl.DataDeviceManager,
data_device: ?*wl.DataDevice,
primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1,
primary_device: ?*zwp.PrimarySelectionDeviceV1,
clip_offer: ?*DataOffer,
clip_pending_offer: ?*DataOffer,
primary_offer: ?*PrimaryOffer,
primary_pending_offer: ?*PrimaryOffer,
dnd_offer: ?*DataOffer,
clip_source: ?*Source,
primary_source: ?*Source,
transfer_fd: posix.fd_t,
transfer_buf: std.ArrayList(u8),
transfer_action: TransferAction,
transfer_deadline_ms: i64,
outgoing: [max_outgoing_transfers]?OutgoingTransfer,
outgoing_bytes: usize,
dnd_ctx: ?*anyopaque,
dnd_fn: ?DndFn,

const TransferAction = union(enum) {
    terminal: struct {
        target: Target,
        mime: [*:0]const u8,
    },
    osc52_read: u8,
    kitty_read: [*:0]const u8,
    dnd: *DataOffer,
};

const OutgoingTransfer = struct {
    fd: posix.fd_t,
    data: []u8,
    offset: usize,
    deadline_ms: i64,
};

const TransferOffer = union(enum) {
    clipboard: *DataOffer,
    primary: *PrimaryOffer,

    fn receive(self: TransferOffer, mime: [*:0]const u8, fd: posix.fd_t) void {
        switch (self) {
            .clipboard => |offer| offer.offer.receive(mime, fd),
            .primary => |offer| offer.offer.receive(mime, fd),
        }
    }
};

const DataOffer = struct {
    clipboard: *Clipboard,
    offer: *wl.DataOffer,
    mimes: clipboard_format.MimeMask = 0,
    dnd_mimes: clipboard_format.MimeMask = 0,
    dnd_action: wl.DataDeviceManager.DndAction = .{},
    source_actions: wl.DataDeviceManager.DndAction = .{ .copy = true },
    enter_serial: u32 = 0,
    x: f64 = 0,
    y: f64 = 0,

    fn noteMime(self: *DataOffer, mime_type: [*:0]const u8) void {
        if (clipboard_format.mimeBit(&clipboard_format.paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
        if (clipboard_format.mimeBit(&clipboard_format.dnd_mime_preference, mime_type)) |bit| self.dnd_mimes |= bit;
    }

    fn bestMime(self: *const DataOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.paste_mime_preference, self.mimes);
    }

    fn bestDndMime(self: *const DataOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.dnd_mime_preference, self.dnd_mimes);
    }

    fn destroy(self: *DataOffer) void {
        const clipboard = self.clipboard;
        if (clipboard.clip_offer == self) clipboard.clip_offer = null;
        if (clipboard.clip_pending_offer == self) clipboard.clip_pending_offer = null;
        if (clipboard.dnd_offer == self) clipboard.dnd_offer = null;
        self.offer.destroy();
        clipboard.alloc.destroy(self);
    }
};

const PrimaryOffer = struct {
    clipboard: *Clipboard,
    offer: *zwp.PrimarySelectionOfferV1,
    mimes: clipboard_format.MimeMask = 0,

    fn noteMime(self: *PrimaryOffer, mime_type: [*:0]const u8) void {
        if (clipboard_format.mimeBit(&clipboard_format.paste_mime_preference, mime_type)) |bit| self.mimes |= bit;
    }

    fn bestMime(self: *const PrimaryOffer) ?[*:0]const u8 {
        return clipboard_format.preferredMime(&clipboard_format.paste_mime_preference, self.mimes);
    }

    fn destroy(self: *PrimaryOffer) void {
        const clipboard = self.clipboard;
        if (clipboard.primary_offer == self) clipboard.primary_offer = null;
        if (clipboard.primary_pending_offer == self) clipboard.primary_pending_offer = null;
        self.offer.destroy();
        clipboard.alloc.destroy(self);
    }
};

/// Heap context for an outgoing selection source. It owns both the sentinel
/// text and source proxy until cancellation, replacement, or teardown.
const Source = struct {
    clipboard: *Clipboard,
    text: [:0]const u8,
    source: union(enum) {
        clipboard: *wl.DataSource,
        primary: *zwp.PrimarySelectionSourceV1,
    },

    fn destroy(self: *Source) void {
        const clipboard = self.clipboard;
        switch (self.source) {
            .clipboard => |source| {
                if (clipboard.clip_source == self) clipboard.clip_source = null;
                source.destroy();
            },
            .primary => |source| {
                if (clipboard.primary_source == self) clipboard.primary_source = null;
                source.destroy();
            },
        }
        clipboard.alloc.free(self.text);
        clipboard.alloc.destroy(self);
    }

    fn send(self: *Source, fd: i32) void {
        self.clipboard.sendSelection(self.text, fd);
    }
};

pub fn init(
    alloc: std.mem.Allocator,
    data_manager: ?*wl.DataDeviceManager,
    primary_manager: ?*zwp.PrimarySelectionDeviceManagerV1,
) Clipboard {
    return .{
        .alloc = alloc,
        .data_manager = data_manager,
        .data_device = null,
        .primary_manager = primary_manager,
        .primary_device = null,
        .clip_offer = null,
        .clip_pending_offer = null,
        .primary_offer = null,
        .primary_pending_offer = null,
        .dnd_offer = null,
        .clip_source = null,
        .primary_source = null,
        .transfer_fd = -1,
        .transfer_buf = .empty,
        .transfer_action = .{ .terminal = .{
            .target = .clipboard,
            .mime = clipboard_format.paste_mime_preference[0].ptr,
        } },
        .transfer_deadline_ms = 0,
        .outgoing = @splat(null),
        .outgoing_bytes = 0,
        .dnd_ctx = null,
        .dnd_fn = null,
    };
}

pub fn deinit(self: *Clipboard) void {
    self.abortTransfer();
    for (0..max_outgoing_transfers) |i| self.closeOutgoing(i);
    self.transfer_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.dnd_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
}

fn sendSelection(self: *Clipboard, text: []const u8, fd: posix.fd_t) void {
    const slot = for (&self.outgoing, 0..) |transfer, i| {
        if (transfer == null) break i;
    } else {
        _ = std.os.linux.close(fd);
        return;
    };
    if (text.len > max_outgoing_bytes -| self.outgoing_bytes) {
        _ = std.os.linux.close(fd);
        return;
    }
    const owned = self.alloc.dupe(u8, text) catch {
        _ = std.os.linux.close(fd);
        return;
    };
    setNonblocking(fd) catch {
        self.alloc.free(owned);
        _ = std.os.linux.close(fd);
        return;
    };
    self.outgoing[slot] = .{
        .fd = fd,
        .data = owned,
        .offset = 0,
        .deadline_ms = monotonicMs() + transfer_timeout_ms,
    };
    self.outgoing_bytes += owned.len;
}

pub fn pollOutgoing(self: *Clipboard, fds: *[max_outgoing_transfers]posix.pollfd) void {
    for (self.outgoing, 0..) |transfer, i| fds[i] = if (transfer) |item|
        .{ .fd = item.fd, .events = posix.POLL.OUT, .revents = 0 }
    else
        .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 };
}

pub fn dispatchOutgoing(self: *Clipboard, fds: *const [max_outgoing_transfers]posix.pollfd) void {
    for (fds, 0..) |poll_fd, i| {
        const transfer = &(self.outgoing[i] orelse continue);
        if (poll_fd.fd != transfer.fd or poll_fd.revents == 0) continue;
        if (poll_fd.revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            self.closeOutgoing(i);
            continue;
        }
        if (poll_fd.revents & posix.POLL.OUT == 0) continue;
        const remaining = transfer.data[transfer.offset..];
        const amount = @min(remaining.len, max_write_per_dispatch);
        const rc = writeWithoutSigpipe(transfer.fd, remaining[0..amount]);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                transfer.offset += rc;
                if (transfer.offset == transfer.data.len) self.closeOutgoing(i);
            },
            .INTR, .AGAIN => {},
            else => self.closeOutgoing(i),
        }
    }
}

pub fn pollTimeoutMs(self: *const Clipboard) i32 {
    var deadline: ?i64 = if (self.transfer_fd >= 0) self.transfer_deadline_ms else null;
    for (self.outgoing) |transfer| if (transfer) |item| {
        if (deadline == null or item.deadline_ms < deadline.?) deadline = item.deadline_ms;
    };
    const end = deadline orelse return -1;
    return @intCast(@min(@max(end - monotonicMs(), 0), std.math.maxInt(i32)));
}

/// Expires stale transfers. True means an incoming transfer was aborted.
pub fn expireTransfers(self: *Clipboard) bool {
    const now = monotonicMs();
    const incoming_expired = self.transfer_fd >= 0 and self.transfer_deadline_ms <= now;
    if (incoming_expired) self.abortTransfer();
    for (self.outgoing, 0..) |transfer, i| {
        if (transfer) |item| if (item.deadline_ms <= now) self.closeOutgoing(i);
    }
    return incoming_expired;
}

pub fn osc52ReadKind(self: *const Clipboard) ?u8 {
    if (self.transfer_fd < 0) return null;
    return switch (self.transfer_action) {
        .osc52_read => |kind| kind,
        else => null,
    };
}

fn closeOutgoing(self: *Clipboard, i: usize) void {
    if (self.outgoing[i]) |transfer| {
        _ = std.os.linux.close(transfer.fd);
        self.outgoing_bytes -= transfer.data.len;
        self.alloc.free(transfer.data);
        self.outgoing[i] = null;
    }
}

pub fn setDevices(
    self: *Clipboard,
    data_device: ?*wl.DataDevice,
    primary_device: ?*zwp.PrimarySelectionDeviceV1,
) void {
    self.data_device = data_device;
    self.primary_device = primary_device;
    if (data_device) |device| device.setListener(*Clipboard, dataDeviceListener, self);
    if (primary_device) |device| device.setListener(*Clipboard, primaryDeviceListener, self);
}

pub fn setDndCallback(self: *Clipboard, ctx: *anyopaque, callback: DndFn) void {
    self.dnd_ctx = ctx;
    self.dnd_fn = callback;
}

/// Apply the running program's OSC 72 acceptance to the active Wayland drag.
pub fn setDndAcceptance(self: *Clipboard, operation: enum { none, copy, move }) void {
    const offer = self.dnd_offer orelse return;
    const mime = if (operation == .none) null else offer.bestDndMime();
    offer.offer.accept(offer.enter_serial, mime);
    const allowed: wl.DataDeviceManager.DndAction = .{
        .copy = offer.source_actions.copy,
        .move = offer.source_actions.move,
    };
    const preferred: wl.DataDeviceManager.DndAction = switch (operation) {
        .none => .{},
        .copy => .{ .copy = true },
        .move => .{ .move = true },
    };
    offer.offer.setActions(allowed, preferred);
}

/// Takes ownership of `text` on every path.
pub fn claim(self: *Clipboard, target: Target, text: [:0]const u8, serial: u32) bool {
    return switch (target) {
        .clipboard => self.claimClipboard(text, serial),
        .primary => self.claimPrimary(text, serial),
    };
}

pub fn request(self: *Clipboard, target: Target, purpose: Purpose) RequestResult {
    if (self.transfer_fd >= 0) return .busy;

    switch (target) {
        .clipboard => {
            const offer = self.clip_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            const action: TransferAction = switch (purpose) {
                .terminal => |source| .{ .terminal = .{ .target = source, .mime = mime } },
                .osc52_read => |kind| .{ .osc52_read = kind },
                .kitty_read => .{ .kitty_read = mime },
            };
            self.beginTransfer(mime, .{ .clipboard = offer }, action) catch return .unavailable;
        },
        .primary => {
            const offer = self.primary_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            const action: TransferAction = switch (purpose) {
                .terminal => |source| .{ .terminal = .{ .target = source, .mime = mime } },
                .osc52_read => |kind| .{ .osc52_read = kind },
                .kitty_read => .{ .kitty_read = mime },
            };
            self.beginTransfer(mime, .{ .primary = offer }, action) catch return .unavailable;
        },
    }
    return .started;
}

pub fn transferFd(self: *const Clipboard) posix.fd_t {
    return self.transfer_fd;
}

/// Returns null only when the nonblocking transfer needs more input. A
/// returned event borrows the transfer buffer until `finishEvent` is called.
pub fn readTransfer(self: *Clipboard) !?Event {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(self.transfer_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                self.abortTransfer();
                return err;
            },
        };
        if (n == 0) break;
        if (n > max_transfer_size -| self.transfer_buf.items.len) {
            self.abortTransfer();
            return error.TransferTooLarge;
        }
        self.transfer_buf.appendSlice(self.alloc, buf[0..n]) catch |err| {
            self.abortTransfer();
            return err;
        };
    }

    _ = std.os.linux.close(self.transfer_fd);
    self.transfer_fd = -1;
    return switch (self.transfer_action) {
        .terminal => |transfer| .{ .terminal = .{
            .target = transfer.target,
            .mime = std.mem.span(transfer.mime),
            .data = self.transfer_buf.items,
        } },
        .osc52_read => |kind| .{ .osc52_read = .{ .kind = kind, .data = self.transfer_buf.items } },
        .kitty_read => |mime| .{ .kitty_read = .{
            .mime = std.mem.span(mime),
            .data = self.transfer_buf.items,
        } },
        .dnd => |offer| .{ .dnd = .{
            .mime = std.mem.span(offer.bestDndMime() orelse unreachable),
            .data = self.transfer_buf.items,
            .x = offer.x,
            .y = offer.y,
            .operations = dndOperations(offer.source_actions),
        } },
    };
}

pub fn finishEvent(self: *Clipboard) void {
    switch (self.transfer_action) {
        .dnd => |offer| {
            if (offer.dnd_action.copy or offer.dnd_action.move) offer.offer.finish();
            offer.destroy();
        },
        else => {},
    }
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = .{ .terminal = .{
        .target = .clipboard,
        .mime = clipboard_format.paste_mime_preference[0].ptr,
    } };
}

fn abortTransfer(self: *Clipboard) void {
    if (self.transfer_fd >= 0) _ = std.os.linux.close(self.transfer_fd);
    self.transfer_fd = -1;
    switch (self.transfer_action) {
        .dnd => |offer| offer.destroy(),
        else => {},
    }
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = .{ .terminal = .{
        .target = .clipboard,
        .mime = clipboard_format.paste_mime_preference[0].ptr,
    } };
}

/// Clear a selection immediately. Wayland accepts the request without a
/// round trip, which lets terminal protocol writes be answered synchronously.
pub fn clear(self: *Clipboard, target: Target, serial: u32) bool {
    switch (target) {
        .clipboard => {
            const device = self.data_device orelse return false;
            device.setSelection(null, serial);
            if (self.clip_source) |source| source.destroy();
        },
        .primary => {
            const device = self.primary_device orelse return false;
            device.setSelection(null, serial);
            if (self.primary_source) |source| source.destroy();
        },
    }
    return true;
}

/// Return the text representations currently offered for a selection.
/// The returned slice borrows `buf` and the static MIME names.
pub fn availableMimes(
    self: *const Clipboard,
    target: Target,
    buf: *[clipboard_format.paste_mime_preference.len][]const u8,
) []const []const u8 {
    const mask: clipboard_format.MimeMask = switch (target) {
        .clipboard => if (self.clip_offer) |offer| offer.mimes else 0,
        .primary => if (self.primary_offer) |offer| offer.mimes else 0,
    };
    var len: usize = 0;
    for (clipboard_format.paste_mime_preference, 0..) |mime, i| {
        if (mask & (@as(clipboard_format.MimeMask, 1) << @intCast(i)) == 0) continue;
        buf[len] = mime;
        len += 1;
    }
    return buf[0..len];
}

fn claimClipboard(self: *Clipboard, text: [:0]const u8, serial: u32) bool {
    const manager = self.data_manager orelse {
        self.alloc.free(text);
        return false;
    };
    const device = self.data_device orelse {
        self.alloc.free(text);
        return false;
    };
    const source = manager.createDataSource() catch {
        self.alloc.free(text);
        return false;
    };
    const ctx = self.alloc.create(Source) catch {
        source.destroy();
        self.alloc.free(text);
        return false;
    };
    ctx.* = .{ .clipboard = self, .text = text, .source = .{ .clipboard = source } };
    inline for (clipboard_format.paste_mime_preference) |mime| source.offer(mime.ptr);
    source.setListener(*Source, dataSourceListener, ctx);
    device.setSelection(source, serial);
    if (self.clip_source) |old| old.destroy();
    self.clip_source = ctx;
    log.debug("claimed clipboard ({d} bytes)", .{text.len});
    return true;
}

fn claimPrimary(self: *Clipboard, text: [:0]const u8, serial: u32) bool {
    const manager = self.primary_manager orelse {
        self.alloc.free(text);
        return false;
    };
    const device = self.primary_device orelse {
        self.alloc.free(text);
        return false;
    };
    const source = manager.createSource() catch {
        self.alloc.free(text);
        return false;
    };
    const ctx = self.alloc.create(Source) catch {
        source.destroy();
        self.alloc.free(text);
        return false;
    };
    ctx.* = .{ .clipboard = self, .text = text, .source = .{ .primary = source } };
    inline for (clipboard_format.paste_mime_preference) |mime| source.offer(mime.ptr);
    source.setListener(*Source, primarySourceListener, ctx);
    device.setSelection(source, serial);
    if (self.primary_source) |old| old.destroy();
    self.primary_source = ctx;
    log.debug("claimed primary selection ({d} bytes)", .{text.len});
    return true;
}

fn beginTransfer(
    self: *Clipboard,
    mime: [*:0]const u8,
    offer: TransferOffer,
    action: TransferAction,
) !void {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    errdefer _ = std.os.linux.close(fds[0]);
    errdefer _ = std.os.linux.close(fds[1]);

    try setNonblocking(fds[0]);
    offer.receive(mime, fds[1]);
    _ = std.os.linux.close(fds[1]);
    self.transfer_fd = fds[0];
    self.transfer_deadline_ms = monotonicMs() + transfer_timeout_ms;
    self.transfer_buf.clearRetainingCapacity();
    self.transfer_action = action;
}

fn createDataOffer(self: *Clipboard, proxy: *wl.DataOffer) ?*DataOffer {
    if (self.clip_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(DataOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .clipboard = self, .offer = proxy };
    proxy.setListener(*DataOffer, dataOfferListener, offer);
    self.clip_pending_offer = offer;
    return offer;
}

fn takeDataOffer(self: *Clipboard, proxy: *wl.DataOffer) ?*DataOffer {
    const offer = self.clip_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.clip_pending_offer = null;
    return offer;
}

fn createPrimaryOffer(self: *Clipboard, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    if (self.primary_pending_offer) |old| old.destroy();
    const offer = self.alloc.create(PrimaryOffer) catch {
        proxy.destroy();
        return null;
    };
    offer.* = .{ .clipboard = self, .offer = proxy };
    proxy.setListener(*PrimaryOffer, primaryOfferListener, offer);
    self.primary_pending_offer = offer;
    return offer;
}

fn takePrimaryOffer(self: *Clipboard, proxy: *zwp.PrimarySelectionOfferV1) ?*PrimaryOffer {
    const offer = self.primary_pending_offer orelse return null;
    if (offer.offer != proxy) return null;
    self.primary_pending_offer = null;
    return offer;
}

fn beginDrop(self: *Clipboard) void {
    const offer = self.dnd_offer orelse return;
    self.dnd_offer = null;
    if (self.transfer_fd >= 0) {
        offer.destroy();
        return;
    }
    const mime = offer.bestDndMime() orelse {
        offer.destroy();
        return;
    };
    self.beginTransfer(mime, .{ .clipboard = offer }, .{ .dnd = offer }) catch {
        offer.destroy();
    };
}

fn dataSourceListener(_: *wl.DataSource, event: wl.DataSource.Event, ctx: *Source) void {
    switch (event) {
        .send => |send| ctx.send(send.fd),
        .cancelled => ctx.destroy(),
        else => {},
    }
}

fn primarySourceListener(
    _: *zwp.PrimarySelectionSourceV1,
    event: zwp.PrimarySelectionSourceV1.Event,
    ctx: *Source,
) void {
    switch (event) {
        .send => |send| ctx.send(send.fd),
        .cancelled => ctx.destroy(),
    }
}

fn dataOfferListener(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *DataOffer) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
        .source_actions => |ev| {
            offer.source_actions = ev.source_actions;
            const clipboard = offer.clipboard;
            // Wayland sends the source's real actions after data-device enter,
            // so refresh both the application and compositor negotiation.
            if (clipboard.dnd_offer == offer) clipboard.updateDndNegotiation(offer);
        },
        .action => |ev| offer.dnd_action = ev.dnd_action,
    }
}

fn primaryOfferListener(
    _: *zwp.PrimarySelectionOfferV1,
    event: zwp.PrimarySelectionOfferV1.Event,
    offer: *PrimaryOffer,
) void {
    switch (event) {
        .offer => |ev| offer.noteMime(ev.mime_type),
    }
}

fn dataDeviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
    switch (event) {
        .data_offer => |data_offer| _ = self.createDataOffer(data_offer.id),
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takeDataOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.clip_offer) |old| old.destroy();
            self.clip_offer = offer;
        },
        .enter => |enter| {
            const id = enter.id orelse return;
            const offer = self.takeDataOffer(id) orelse {
                id.destroy();
                return;
            };
            if (offer.bestDndMime()) |mime| {
                offer.enter_serial = enter.serial;
                offer.x = enter.x.toDouble();
                offer.y = enter.y.toDouble();
                offer.offer.accept(enter.serial, mime);
                offer.offer.setActions(.{ .copy = true }, .{ .copy = true });
                if (self.dnd_offer) |old| old.destroy();
                self.dnd_offer = offer;
                self.updateDndNegotiation(offer);
            } else {
                offer.offer.accept(enter.serial, null);
                offer.destroy();
            }
        },
        .leave => if (self.dnd_offer) |offer| {
            _ = self.reportDnd(.leave);
            offer.destroy();
        },
        .drop => self.beginDrop(),
        .motion => |motion| if (self.dnd_offer) |offer| {
            offer.x = motion.x.toDouble();
            offer.y = motion.y.toDouble();
            _ = self.reportDndMotion(offer);
        },
    }
}

fn reportDndMotion(self: *Clipboard, offer: *const DataOffer) bool {
    const mime = offer.bestDndMime() orelse return false;
    return self.reportDnd(.{ .motion = .{
        .x = offer.x,
        .y = offer.y,
        .mime = std.mem.span(mime),
        .operations = dndOperations(offer.source_actions),
    } });
}

fn reportDnd(self: *Clipboard, event: DndEvent) bool {
    const callback = self.dnd_fn orelse return false;
    return callback(self.dnd_ctx orelse return false, event);
}

fn updateDndNegotiation(self: *Clipboard, offer: *DataOffer) void {
    if (!self.reportDndMotion(offer)) return;
    const actions = dndActions(offer.source_actions);
    offer.offer.setActions(actions.allowed, actions.preferred);
}

fn dndActions(source: wl.DataDeviceManager.DndAction) struct {
    allowed: wl.DataDeviceManager.DndAction,
    preferred: wl.DataDeviceManager.DndAction,
} {
    const allowed: wl.DataDeviceManager.DndAction = .{
        .copy = source.copy,
        .move = source.move,
    };
    const preferred: wl.DataDeviceManager.DndAction = if (allowed.copy)
        .{ .copy = true }
    else if (allowed.move)
        .{ .move = true }
    else
        .{};
    return .{ .allowed = allowed, .preferred = preferred };
}

fn dndOperations(actions: wl.DataDeviceManager.DndAction) DndOperations {
    return .{ .copy = actions.copy, .move = actions.move };
}

fn primaryDeviceListener(
    _: *zwp.PrimarySelectionDeviceV1,
    event: zwp.PrimarySelectionDeviceV1.Event,
    self: *Clipboard,
) void {
    switch (event) {
        .data_offer => |data_offer| _ = self.createPrimaryOffer(data_offer.offer),
        .selection => |selection| {
            const offer = if (selection.id) |id| offer: {
                break :offer self.takePrimaryOffer(id) orelse {
                    id.destroy();
                    break :offer null;
                };
            } else null;
            if (self.primary_offer) |old| old.destroy();
            self.primary_offer = offer;
        },
    }
}

fn setNonblocking(fd: posix.fd_t) !void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.FcntlFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | nonblock)) != .SUCCESS)
        return error.FcntlFailed;
}

fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn sigpipePending() bool {
    const linux = std.os.linux;
    var pending = posix.sigemptyset();
    const rc = linux.syscall2(.rt_sigpending, @intFromPtr(&pending), linux.NSIG / 8);
    return linux.errno(rc) == .SUCCESS and posix.sigismember(&pending, .PIPE);
}

fn writeWithoutSigpipe(fd: posix.fd_t, data: []const u8) usize {
    const linux = std.os.linux;
    var pipe_mask = posix.sigemptyset();
    posix.sigaddset(&pipe_mask, .PIPE);
    var old_mask: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, &pipe_mask, &old_mask);
    const was_pending = sigpipePending();
    const rc = linux.write(fd, data.ptr, data.len);
    // Consume only the signal generated by this failed write, preserving a
    // SIGPIPE that was already pending for the caller.
    if (linux.errno(rc) == .PIPE and !was_pending) {
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        while (true) {
            const waited = linux.syscall4(
                .rt_sigtimedwait,
                @intFromPtr(&pipe_mask),
                0,
                @intFromPtr(&zero),
                linux.NSIG / 8,
            );
            if (linux.errno(waited) != .INTR) break;
        }
    }
    posix.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
    return rc;
}

test "closed clipboard writer consumes its own SIGPIPE and restores the mask" {
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    var before: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, null, &before);
    try std.testing.expectEqual(.PIPE, linux.errno(writeWithoutSigpipe(fds[1], "x")));
    try std.testing.expect(!sigpipePending());
    var after: posix.sigset_t = undefined;
    posix.sigprocmask(linux.SIG.BLOCK, null, &after);
    try std.testing.expectEqual(posix.sigismember(&before, .PIPE), posix.sigismember(&after, .PIPE));
}

test "transfer read failure discards partial data" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();

    try clipboard.transfer_buf.appendSlice(std.testing.allocator, "partial");
    const rc = linux.openat(
        linux.AT.FDCWD,
        "/tmp",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true },
        0,
    );
    try std.testing.expectEqual(.SUCCESS, linux.errno(rc));
    clipboard.transfer_fd = @intCast(rc);

    try std.testing.expectError(error.IsDir, clipboard.readTransfer());
    try std.testing.expectEqual(@as(posix.fd_t, -1), clipboard.transfer_fd);
    try std.testing.expectEqual(@as(usize, 0), clipboard.transfer_buf.items.len);
}

test "oversized transfer is aborted before growing past the paste backlog" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();

    try clipboard.transfer_buf.resize(std.testing.allocator, max_transfer_size);
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    clipboard.transfer_fd = pipe_fds[0];
    _ = linux.write(pipe_fds[1], "x", 1);
    _ = linux.close(pipe_fds[1]);

    try std.testing.expectError(error.TransferTooLarge, clipboard.readTransfer());
    try std.testing.expectEqual(@as(posix.fd_t, -1), clipboard.transfer_fd);
    try std.testing.expectEqual(@as(usize, 0), clipboard.transfer_buf.items.len);
}

test "selection send does not block while the consumer is idle" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    defer _ = linux.close(pipe_fds[0]);

    const text = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, i| byte.* = @truncate(i);

    clipboard.sendSelection(text, pipe_fds[1]);
    @memset(text, 0); // The transfer retains the selection's original bytes.

    var received: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (clipboard.outgoing_bytes != 0) {
        var polls: [max_outgoing_transfers]posix.pollfd = undefined;
        clipboard.pollOutgoing(&polls);
        _ = try posix.poll(&polls, 0);
        clipboard.dispatchOutgoing(&polls);
        while (posix.read(pipe_fds[0], &buf)) |n| {
            if (n == 0) break;
            for (buf[0..n], received..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
            received += n;
        } else |err| try std.testing.expectEqual(error.WouldBlock, err);
    }
    try std.testing.expectEqual(text.len, received);
}

test "selection writer survives a consumer closing early" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var pipe_fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })),
    );
    _ = linux.close(pipe_fds[0]);
    clipboard.sendSelection("selection", pipe_fds[1]);
    var polls: [max_outgoing_transfers]posix.pollfd = undefined;
    clipboard.pollOutgoing(&polls);
    _ = try posix.poll(&polls, 0);
    clipboard.dispatchOutgoing(&polls);
    try std.testing.expectEqual(@as(usize, 0), clipboard.outgoing_bytes);
}

test "outgoing limits, timeout, and teardown close transfers" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);

    var readers: [max_outgoing_transfers + 1]posix.fd_t = undefined;
    for (0..max_outgoing_transfers + 1) |i| {
        var fds: [2]posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
        readers[i] = fds[0];
        clipboard.sendSelection("x", fds[1]);
    }
    // The ninth writer was rejected and its reader observes EOF.
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try posix.read(readers[max_outgoing_transfers], &byte));
    _ = linux.close(readers[max_outgoing_transfers]);

    clipboard.outgoing[0].?.deadline_ms = monotonicMs() - 1;
    try std.testing.expect(!clipboard.expireTransfers());
    try std.testing.expect(clipboard.outgoing[0] == null);
    for (readers[0..max_outgoing_transfers]) |fd| _ = linux.close(fd);
    clipboard.deinit();
}

test "incoming deadline preserves OSC 52 kind until expiry" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(fds[1]);
    clipboard.transfer_fd = fds[0];
    clipboard.transfer_action = .{ .osc52_read = 'c' };
    clipboard.transfer_deadline_ms = monotonicMs() - 1;
    try std.testing.expectEqual(@as(?u8, 'c'), clipboard.osc52ReadKind());
    try std.testing.expectEqual(@as(i32, 0), clipboard.pollTimeoutMs());
    try std.testing.expect(clipboard.expireTransfers());
    try std.testing.expectEqual(@as(?u8, null), clipboard.osc52ReadKind());
}

test "drag negotiation prefers a supported source action" {
    const move_only = dndActions(.{ .move = true });
    try std.testing.expect(!move_only.allowed.copy);
    try std.testing.expect(move_only.allowed.move);
    try std.testing.expect(!move_only.preferred.copy);
    try std.testing.expect(move_only.preferred.move);

    const copy_and_move = dndActions(.{ .copy = true, .move = true });
    try std.testing.expect(copy_and_move.allowed.copy);
    try std.testing.expect(copy_and_move.allowed.move);
    try std.testing.expect(copy_and_move.preferred.copy);
    try std.testing.expect(!copy_and_move.preferred.move);
}
