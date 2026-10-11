//! Owns Wayland clipboard, primary-selection, drag-and-drop in both
//! directions, and their bounded, nonblocking transfers: one incoming pipe
//! and a small outgoing pool, all with deadlines. Application policy
//! remains with App.

const Clipboard = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const clipboard_format = @import("clipboard_format.zig");
const DragIcon = @import("DragIcon.zig");
const DragOffer = @import("DragOffer.zig");

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

/// Progress of an outgoing drag started with `startDrag`. Indices refer to
/// the drag's `DragOffer` items.
pub const DragEvent = union(enum) {
    /// A drop target would accept this item.
    target: usize,
    action: DndOperations,
    dropped,
    /// The drag ended. Queued transfers continue.
    finished: struct { cancelled: bool },
    /// A drop target asked for an item whose data is still pending.
    request: usize,
};

pub const DragFn = *const fn (ctx: *anyopaque, event: DragEvent) void;

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
/// Bytes copied for selection transfers; drag transfers share their offer.
outgoing_bytes: usize,
dnd_ctx: ?*anyopaque,
dnd_fn: ?DndFn,
drag_source: ?*DragSource,
drag_ctx: ?*anyopaque,
drag_fn: ?DragFn,

const TransferAction = union(enum) {
    terminal: struct {
        target: Target,
        mime: [*:0]const u8,
    },
    osc52_read: struct { kind: u8, mime: [*:0]const u8 },
    kitty_read: [*:0]const u8,
    dnd: *DataOffer,
};

const OutgoingTransfer = struct {
    fd: posix.fd_t,
    source: union(enum) {
        /// Selection text copied for this transfer.
        owned: []u8,
        /// Drag data, which may still be arriving from the client.
        drag: struct {
            offer: *DragOffer,
            index: usize,
            /// Data length when the deadline was last refreshed.
            seen: usize,
        },
    },
    offset: usize,
    /// Drag transfers refresh this on progress, since their data can be
    /// large and arrive slowly; selection transfers keep a fixed deadline.
    deadline_ms: i64,

    fn data(self: *const OutgoingTransfer) []const u8 {
        return switch (self.source) {
            .owned => |text| text,
            .drag => |drag| drag.offer.items.items[drag.index].data.items,
        };
    }

    fn finished(self: *const OutgoingTransfer) bool {
        if (self.offset < self.data().len) return false;
        return switch (self.source) {
            .owned => true,
            .drag => |drag| drag.offer.items.items[drag.index].state == .complete,
        };
    }
};

/// Heap context for the native side of an outgoing drag. Transfers hold
/// their own offer references, so they outlive the source.
const DragSource = struct {
    clipboard: *Clipboard,
    source: *wl.DataSource,
    offer: *DragOffer,
    icon: ?*DragIcon,

    fn destroy(self: *DragSource) void {
        const clipboard = self.clipboard;
        if (clipboard.drag_source == self) clipboard.drag_source = null;
        self.source.destroy();
        if (self.icon) |icon| icon.destroy();
        self.offer.release();
        clipboard.alloc.destroy(self);
    }
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
/// text and its optional Latin-1 representation, plus the source proxy,
/// until cancellation, replacement, or teardown.
const Source = struct {
    clipboard: *Clipboard,
    text: [:0]const u8,
    latin1: ?[]const u8,
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
        if (self.latin1) |text| clipboard.alloc.free(text);
        clipboard.alloc.free(self.text);
        clipboard.alloc.destroy(self);
    }

    fn supportsMime(self: *const Source, mime: [:0]const u8) bool {
        return !std.mem.eql(u8, mime, "STRING") or self.latin1 != null;
    }

    fn send(self: *Source, mime: [*:0]const u8, fd: i32) void {
        const text = if (std.mem.eql(u8, std.mem.span(mime), "STRING"))
            self.latin1 orelse {
                _ = std.os.linux.close(fd);
                return;
            }
        else
            self.text;
        self.clipboard.sendSelection(text, fd);
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
        .drag_source = null,
        .drag_ctx = null,
        .drag_fn = null,
    };
}

pub fn deinit(self: *Clipboard) void {
    self.abortTransfer();
    for (0..max_outgoing_transfers) |i| self.closeOutgoing(i);
    if (self.drag_source) |source| source.destroy();
    self.transfer_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.dnd_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
}

fn freeOutgoingSlot(self: *const Clipboard) ?usize {
    for (self.outgoing, 0..) |transfer, i| {
        if (transfer == null) return i;
    }
    return null;
}

fn sendSelection(self: *Clipboard, text: []const u8, fd: posix.fd_t) void {
    const slot = self.freeOutgoingSlot() orelse {
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
        .source = .{ .owned = owned },
        .offset = 0,
        .deadline_ms = monotonicMs() + transfer_timeout_ms,
    };
    self.outgoing_bytes += owned.len;
}

/// Serve an advertised drag item, including data the client has not sent
/// yet. Each transfer fails alone, so one closed pipe ends one read.
fn sendDragItem(self: *Clipboard, offer: *DragOffer, mime: []const u8, fd: posix.fd_t) void {
    const index = offer.advertisedIndex(mime) orelse {
        _ = std.os.linux.close(fd);
        return;
    };
    const item = &offer.items.items[index];
    const slot = self.freeOutgoingSlot() orelse {
        _ = std.os.linux.close(fd);
        return;
    };
    if (item.state == .failed) {
        _ = std.os.linux.close(fd);
        return;
    }
    setNonblocking(fd) catch {
        _ = std.os.linux.close(fd);
        return;
    };
    self.outgoing[slot] = .{
        .fd = fd,
        .source = .{ .drag = .{ .offer = offer.retain(), .index = index, .seen = item.data.items.len } },
        .offset = 0,
        .deadline_ms = monotonicMs() + transfer_timeout_ms,
    };
    if (item.state == .pending) self.reportDrag(.{ .request = index });
}

/// Writable is only interesting while data is waiting; otherwise poll
/// reports just errors and hangups.
pub fn pollOutgoing(self: *Clipboard, fds: *[max_outgoing_transfers]posix.pollfd) void {
    for (&self.outgoing, 0..) |*transfer, i| fds[i] = if (transfer.*) |*item| .{
        .fd = item.fd,
        .events = if (item.offset < item.data().len) posix.POLL.OUT else 0,
        .revents = 0,
    } else .{ .fd = -1, .events = posix.POLL.OUT, .revents = 0 };
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
        const remaining = transfer.data()[transfer.offset..];
        if (remaining.len == 0) continue;
        const amount = @min(remaining.len, max_write_per_dispatch);
        const rc = writeWithoutSigpipe(transfer.fd, remaining[0..amount]);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                transfer.offset += rc;
                if (transfer.source == .drag) transfer.deadline_ms = monotonicMs() + transfer_timeout_ms;
                if (transfer.finished()) self.closeOutgoing(i);
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

/// Expires stale transfers and retires drag transfers whose data finished
/// or failed since the last call. True means an incoming transfer was
/// aborted.
pub fn expireTransfers(self: *Clipboard) bool {
    const now = monotonicMs();
    const incoming_expired = self.transfer_fd >= 0 and self.transfer_deadline_ms <= now;
    if (incoming_expired) self.abortTransfer();
    for (&self.outgoing, 0..) |*slot, i| {
        const transfer = &(slot.* orelse continue);
        switch (transfer.source) {
            .owned => {},
            .drag => |*drag| {
                const item = &drag.offer.items.items[drag.index];
                if (item.state == .failed or transfer.finished()) {
                    self.closeOutgoing(i);
                    continue;
                }
                // Data arriving from the client counts as progress.
                if (item.data.items.len > drag.seen) {
                    drag.seen = item.data.items.len;
                    transfer.deadline_ms = now + transfer_timeout_ms;
                }
            },
        }
        if (transfer.deadline_ms <= now) self.closeOutgoing(i);
    }
    return incoming_expired;
}

pub fn osc52ReadKind(self: *const Clipboard) ?u8 {
    if (self.transfer_fd < 0) return null;
    return switch (self.transfer_action) {
        .osc52_read => |read| read.kind,
        else => null,
    };
}

fn closeOutgoing(self: *Clipboard, i: usize) void {
    if (self.outgoing[i]) |transfer| {
        _ = std.os.linux.close(transfer.fd);
        switch (transfer.source) {
            .owned => |text| {
                self.outgoing_bytes -= text.len;
                self.alloc.free(text);
            },
            .drag => |drag| drag.offer.release(),
        }
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
    const allowed: wl.DataDeviceManager.DndAction = .{
        .copy = offer.source_actions.copy,
        .move = offer.source_actions.move,
    };
    // OSC 72 can request an unavailable action, including a stale response
    // after source actions change. Wayland requires preferred to be in allowed.
    const preferred: wl.DataDeviceManager.DndAction = switch (operation) {
        .none => .{},
        .copy => .{ .copy = allowed.copy },
        .move => .{ .move = allowed.move },
    };
    const mime = if (preferred.copy or preferred.move) offer.bestDndMime() else null;
    offer.offer.accept(offer.enter_serial, mime);
    if (offer.offer.getVersion() >= wl.DataOffer.set_actions_since_version)
        offer.offer.setActions(allowed, preferred);
}

pub fn setDragCallback(self: *Clipboard, ctx: *anyopaque, callback: DragFn) void {
    self.drag_ctx = ctx;
    self.drag_fn = callback;
}

/// Start a native drag serving `offer`'s advertised items, replacing any
/// current drag. Takes ownership of `icon` on every path; show a preview
/// with `showDragIcon`. `serial` must be the press whose implicit grab is
/// still active; a stale one surfaces later as a cancelled event.
pub fn startDrag(
    self: *Clipboard,
    offer: *DragOffer,
    actions: DndOperations,
    origin: *wl.Surface,
    icon: ?*DragIcon,
    serial: u32,
) error{ Unsupported, OutOfMemory }!void {
    errdefer if (icon) |owned| owned.destroy();
    const manager = self.data_manager orelse return error.Unsupported;
    const device = self.data_device orelse return error.Unsupported;
    // Version 3 negotiates copy or move and reports the end of the drop.
    if (manager.getVersion() < wl.DataSource.set_actions_since_version) return error.Unsupported;
    const source = manager.createDataSource() catch return error.OutOfMemory;
    errdefer source.destroy();
    const ctx = try self.alloc.create(DragSource);
    ctx.* = .{ .clipboard = self, .source = source, .offer = offer.retain(), .icon = icon };
    for (offer.items.items) |item| {
        if (item.advertised) source.offer(item.mime.ptr);
    }
    source.setActions(.{ .copy = actions.copy, .move = actions.move });
    source.setListener(*DragSource, dragSourceListener, ctx);
    if (self.drag_source) |old| old.destroy();
    self.drag_source = ctx;
    device.startDrag(source, origin, if (icon) |owned| owned.surface else null, serial);
}

/// Show the current drag's preview at `index`; out of range hides it.
pub fn showDragIcon(self: *Clipboard, index: usize) void {
    const source = self.drag_source orelse return;
    const icon = source.icon orelse return;
    icon.show(index);
}

/// End the current native drag without reporting it. Queued transfers
/// still complete.
pub fn cancelDrag(self: *Clipboard) void {
    if (self.drag_source) |source| source.destroy();
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
                .osc52_read => |kind| .{ .osc52_read = .{ .kind = kind, .mime = mime } },
                .kitty_read => .{ .kitty_read = mime },
            };
            self.beginTransfer(mime, .{ .clipboard = offer }, action) catch return .unavailable;
        },
        .primary => {
            const offer = self.primary_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            const action: TransferAction = switch (purpose) {
                .terminal => |source| .{ .terminal = .{ .target = source, .mime = mime } },
                .osc52_read => |kind| .{ .osc52_read = .{ .kind = kind, .mime = mime } },
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
        .osc52_read => |read| read: {
            // OSC 52 carries text without a MIME label, unlike Kitty reads.
            if (std.mem.eql(u8, std.mem.span(read.mime), "STRING")) {
                const decoded = clipboard_format.decodeLatin1(self.alloc, self.transfer_buf.items) catch |err| {
                    self.abortTransfer();
                    return err;
                };
                self.transfer_buf.deinit(self.alloc);
                self.transfer_buf = .fromOwnedSlice(decoded);
            }
            break :read .{ .osc52_read = .{ .kind = read.kind, .data = self.transfer_buf.items } };
        },
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
    ctx.* = .{
        .clipboard = self,
        .text = text,
        .latin1 = clipboard_format.encodeLatin1(self.alloc, text) catch null,
        .source = .{ .clipboard = source },
    };
    inline for (clipboard_format.paste_mime_preference) |mime| {
        if (ctx.supportsMime(mime)) source.offer(mime.ptr);
    }
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
    ctx.* = .{
        .clipboard = self,
        .text = text,
        .latin1 = clipboard_format.encodeLatin1(self.alloc, text) catch null,
        .source = .{ .primary = source },
    };
    inline for (clipboard_format.paste_mime_preference) |mime| {
        if (ctx.supportsMime(mime)) source.offer(mime.ptr);
    }
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
        .send => |send| ctx.send(send.mime_type, send.fd),
        .cancelled => ctx.destroy(),
        else => {},
    }
}

fn dragSourceListener(_: *wl.DataSource, event: wl.DataSource.Event, ctx: *DragSource) void {
    const clipboard = ctx.clipboard;
    switch (event) {
        .send => |send| clipboard.sendDragItem(ctx.offer, std.mem.span(send.mime_type), send.fd),
        .target => |target| if (target.mime_type) |mime| {
            if (ctx.offer.advertisedIndex(std.mem.span(mime))) |index| clipboard.reportDrag(.{ .target = index });
        },
        .action => |action| clipboard.reportDrag(.{ .action = dndOperations(action.dnd_action) }),
        .dnd_drop_performed => clipboard.reportDrag(.dropped),
        .dnd_finished, .cancelled => {
            ctx.destroy();
            clipboard.reportDrag(.{ .finished = .{ .cancelled = event == .cancelled } });
        },
    }
}

fn reportDrag(self: *Clipboard, event: DragEvent) void {
    const callback = self.drag_fn orelse return;
    callback(self.drag_ctx orelse return, event);
}

fn primarySourceListener(
    _: *zwp.PrimarySelectionSourceV1,
    event: zwp.PrimarySelectionSourceV1.Event,
    ctx: *Source,
) void {
    switch (event) {
        .send => |send| ctx.send(send.mime_type, send.fd),
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
                if (offer.offer.getVersion() >= wl.DataOffer.set_actions_since_version)
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
    if (offer.offer.getVersion() < wl.DataOffer.set_actions_since_version) return;
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

test "selection source callbacks honor the requested text encoding" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    const cases = [_]struct { text: [:0]const u8, latin1: ?[]const u8 }{
        .{ .text = "café £ÿ\n", .latin1 = "caf\xe9 \xa3\xff\n" },
        .{ .text = "price: 5€", .latin1 = null },
    };
    for (cases) |case| {
        var source: Source = .{
            .clipboard = &clipboard,
            .text = case.text,
            .latin1 = try clipboard_format.encodeLatin1(std.testing.allocator, case.text),
            .source = undefined,
        };
        defer if (source.latin1) |text| std.testing.allocator.free(text);
        try std.testing.expectEqual(case.latin1 != null, source.supportsMime("STRING"));
        for ([_]Target{ .clipboard, .primary }) |target| {
            for (clipboard_format.paste_mime_preference) |mime| {
                const is_latin1 = std.mem.eql(u8, mime, "STRING");
                if (!is_latin1) try std.testing.expect(source.supportsMime(mime));
                var fds: [2]posix.fd_t = undefined;
                try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })));
                defer _ = linux.close(fds[0]);
                switch (target) {
                    .clipboard => dataSourceListener(undefined, .{ .send = .{ .mime_type = mime, .fd = fds[1] } }, &source),
                    .primary => primarySourceListener(undefined, .{ .send = .{ .mime_type = mime, .fd = fds[1] } }, &source),
                }
                var polls: [max_outgoing_transfers]posix.pollfd = undefined;
                clipboard.pollOutgoing(&polls);
                _ = try posix.poll(&polls, 0);
                clipboard.dispatchOutgoing(&polls);
                var buf: [64]u8 = undefined;
                const n = try posix.read(fds[0], &buf);
                try std.testing.expectEqualStrings(if (is_latin1) case.latin1 orelse "" else case.text, buf[0..n]);
                try std.testing.expectEqual(@as(usize, 0), try posix.read(fds[0], &buf));
                try std.testing.expectEqual(@as(usize, 0), clipboard.outgoing_bytes);
            }
        }
    }
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

test "drag transfers stream arriving data, outlive the session, and fail alone" {
    const linux = std.os.linux;
    const alloc = std.testing.allocator;
    var clipboard: Clipboard = .init(alloc, null, null);
    defer clipboard.deinit();
    const Requests = struct {
        indices: [4]usize = undefined,
        len: usize = 0,

        fn record(ctx: *anyopaque, event: DragEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.indices[self.len] = event.request;
            self.len += 1;
        }
    };
    var requests: Requests = .{};
    clipboard.setDragCallback(&requests, Requests.record);

    const offer = try DragOffer.create(alloc);
    try offer.append("text/plain", true);
    try offer.append("text/uri-list", false);
    try offer.append("image/png", true);

    var plain: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&plain, .{ .CLOEXEC = true, .NONBLOCK = true })));
    defer _ = linux.close(plain[0]);
    var hidden: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&hidden, .{ .CLOEXEC = true })));
    defer _ = linux.close(hidden[0]);
    var png: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&png, .{ .CLOEXEC = true })));
    defer _ = linux.close(png[0]);

    clipboard.sendDragItem(offer, "text/plain", plain[1]);
    clipboard.sendDragItem(offer, "image/png", png[1]);
    // Unadvertised items are refused at once.
    clipboard.sendDragItem(offer, "text/uri-list", hidden[1]);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try posix.read(hidden[0], &buf));
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, requests.indices[0..requests.len]);

    const pump = struct {
        fn run(c: *Clipboard) !void {
            _ = c.expireTransfers();
            var polls: [max_outgoing_transfers]posix.pollfd = undefined;
            c.pollOutgoing(&polls);
            _ = try posix.poll(&polls, 0);
            c.dispatchOutgoing(&polls);
        }
    }.run;

    // Pending data is served as it arrives.
    try offer.items.items[0].data.appendSlice(alloc, "ab");
    try pump(&clipboard);
    try std.testing.expectEqualStrings("ab", buf[0..try posix.read(plain[0], &buf)]);

    // Arriving data counts as progress, so a past deadline does not expire it.
    clipboard.outgoing[0].?.deadline_ms = monotonicMs() - 1;
    try offer.items.items[0].data.appendSlice(alloc, "c");
    try pump(&clipboard);
    try std.testing.expectEqualStrings("c", buf[0..try posix.read(plain[0], &buf)]);

    // The session drops its reference; the transfer finishes with EOF.
    offer.items.items[0].state = .complete;
    offer.items.items[2].state = .failed;
    offer.release();
    try pump(&clipboard);
    try std.testing.expectEqual(@as(usize, 0), try posix.read(plain[0], &buf));
    try std.testing.expectEqual(@as(usize, 0), try posix.read(png[0], &buf));
    for (clipboard.outgoing) |transfer| try std.testing.expect(transfer == null);
}

test "incoming deadline preserves OSC 52 kind until expiry" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer _ = linux.close(fds[1]);
    clipboard.transfer_fd = fds[0];
    clipboard.transfer_action = .{ .osc52_read = .{ .kind = 'c', .mime = "UTF8_STRING" } };
    clipboard.transfer_deadline_ms = monotonicMs() - 1;
    try std.testing.expectEqual(@as(?u8, 'c'), clipboard.osc52ReadKind());
    try std.testing.expectEqual(@as(i32, 0), clipboard.pollTimeoutMs());
    try std.testing.expect(clipboard.expireTransfers());
    try std.testing.expectEqual(@as(?u8, null), clipboard.osc52ReadKind());
}

test "OSC 52 reads normalize STRING while Kitty reads preserve MIME bytes" {
    const linux = std.os.linux;
    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    const cases = [_]struct { action: TransferAction, data: []const u8, expected: []const u8 }{
        .{ .action = .{ .osc52_read = .{ .kind = 'p', .mime = "STRING" } }, .data = "caf\xe9 \xc3\xa9", .expected = "café Ã©" },
        .{ .action = .{ .osc52_read = .{ .kind = 'p', .mime = "UTF8_STRING" } }, .data = "café €", .expected = "café €" },
        .{ .action = .{ .kitty_read = "STRING" }, .data = "caf\xe9", .expected = "caf\xe9" },
    };
    for (cases) |case| {
        var fds: [2]posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })));
        clipboard.transfer_fd = fds[0];
        clipboard.transfer_action = case.action;
        try std.testing.expectEqual(case.data.len, linux.write(fds[1], case.data.ptr, case.data.len));
        _ = linux.close(fds[1]);
        const event = (try clipboard.readTransfer()).?;
        defer clipboard.finishEvent();
        switch (event) {
            .osc52_read => |read| {
                try std.testing.expectEqual(@as(u8, 'p'), read.kind);
                try std.testing.expectEqualStrings(case.expected, read.data);
            },
            .kitty_read => |read| {
                try std.testing.expectEqualStrings("STRING", read.mime);
                try std.testing.expectEqualStrings(case.expected, read.data);
            },
            else => return error.TestUnexpectedResult,
        }
    }
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

test "drag acceptance never sends an unsupported Wayland preferred action" {
    const linux = std.os.linux;
    var fds: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    )));
    defer _ = linux.close(fds[1]);
    const display = try wl.Display.connectToFd(fds[0]);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();
    // Create a real client proxy, but inspect requests ourselves instead of
    // running a compositor. No server replies are needed to marshal requests.
    const proxy = try registry.bind(1, wl.DataOffer, 3);
    defer proxy.destroy();
    try std.testing.expectEqual(.SUCCESS, display.flush());
    var buf: [512]u8 align(4) = undefined;
    _ = try posix.read(fds[1], &buf); // Discard registry construction requests.

    var clipboard: Clipboard = .init(std.testing.allocator, null, null);
    defer clipboard.deinit();
    var offer: DataOffer = .{ .clipboard = &clipboard, .offer = proxy, .enter_serial = 17 };
    offer.noteMime("text/plain");
    clipboard.dnd_offer = &offer;
    defer clipboard.dnd_offer = null;

    // Source mask, application choice, expected preference. Include a stale
    // move choice after a source switches to copy-only, and the reverse.
    inline for (.{
        .{ @as(u32, 1), .move, @as(u32, 0) },
        .{ @as(u32, 2), .copy, @as(u32, 0) },
        .{ @as(u32, 3), .move, @as(u32, 2) },
        .{ @as(u32, 1), .copy, @as(u32, 1) },
        .{ @as(u32, 3), .none, @as(u32, 0) },
        .{ @as(u32, 0), .copy, @as(u32, 0) },
    }) |case| {
        offer.source_actions = @bitCast(case[0]);
        clipboard.setDndAcceptance(case[1]);
        try std.testing.expectEqual(.SUCCESS, display.flush());
        const n = try posix.read(fds[1], &buf);
        const words = std.mem.bytesAsSlice(u32, buf[0..n]);
        const accept_size = words[1] >> 16;
        try std.testing.expectEqual(proxy.getId(), words[0]);
        try std.testing.expectEqual(@as(u32, 0), words[1] & 0xffff); // accept
        try std.testing.expectEqual(@as(u32, 17), words[2]);
        if (case[2] == 0) {
            try std.testing.expectEqual(@as(u32, 0), words[3]); // Null MIME rejects the drop.
        } else {
            try std.testing.expectEqualStrings("text/plain\x00", buf[16..][0..words[3]]);
        }
        const actions = words[accept_size / 4 ..];
        try std.testing.expectEqual(@as(usize, 4), actions.len);
        try std.testing.expectEqual(proxy.getId(), actions[0]);
        try std.testing.expectEqual(@as(u32, (16 << 16) | 4), actions[1]); // set_actions
        try std.testing.expectEqual(case[0], actions[2]);
        try std.testing.expectEqual(case[2], actions[3]);
    }
}

test "drag negotiation respects the negotiated data offer version" {
    const linux = std.os.linux;
    for ([_]u32{ 1, 2, 3 }) |version| {
        var fds: [2]posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            0,
            &fds,
        )));
        defer _ = linux.close(fds[1]);
        const display = try wl.Display.connectToFd(fds[0]);
        defer display.disconnect();
        const registry = try display.getRegistry();
        defer registry.destroy();
        const proxy = try registry.bind(1, wl.DataOffer, version);
        var clipboard: Clipboard = .init(std.testing.allocator, null, null);
        defer clipboard.deinit();
        const offer = clipboard.createDataOffer(proxy).?;
        offer.noteMime("text/plain");
        const Callback = struct {
            fn motion(_: *anyopaque, _: DndEvent) bool {
                return true; // Exercise Kitty drag negotiation as well.
            }
        };
        clipboard.setDndCallback(&clipboard, Callback.motion);
        try std.testing.expectEqual(.SUCCESS, display.flush());
        var buf: [512]u8 align(4) = undefined;
        _ = try posix.read(fds[1], &buf);

        dataDeviceListener(undefined, .{ .enter = .{
            .serial = 17,
            .surface = undefined,
            .x = .fromInt(0),
            .y = .fromInt(0),
            .id = proxy,
        } }, &clipboard);
        clipboard.setDndAcceptance(.copy);
        try std.testing.expectEqual(.SUCCESS, display.flush());
        const n = try posix.read(fds[1], &buf);
        var words = std.mem.bytesAsSlice(u32, buf[0..n]);
        var accepts: usize = 0;
        var actions: usize = 0;
        while (words.len > 0) {
            try std.testing.expectEqual(proxy.getId(), words[0]);
            switch (words[1] & 0xffff) {
                0 => accepts += 1,
                4 => actions += 1,
                else => return error.TestUnexpectedResult,
            }
            words = words[(words[1] >> 16) / 4 ..];
        }
        try std.testing.expectEqual(@as(usize, 2), accepts);
        try std.testing.expectEqual(@as(usize, if (version >= 3) 3 else 0), actions);
    }
}
