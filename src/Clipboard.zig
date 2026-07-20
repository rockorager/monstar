//! Owns Wayland clipboard, primary-selection, drag-and-drop, and their
//! single in-flight transfer transport. Application policy remains with App.

const Clipboard = @This();

const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;
const clipboard_format = @import("clipboard_format.zig");

const log = std.log.scoped(.app);

pub const Target = enum { clipboard, primary };

pub const Purpose = union(enum) {
    terminal,
    osc52_read: u8,
};

pub const RequestResult = enum { started, busy, unavailable };

pub const Event = union(enum) {
    terminal: []u8,
    osc52_read: struct { kind: u8, data: []const u8 },
    dnd: struct { mime: []const u8, data: []const u8 },
};

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

const TransferAction = union(enum) {
    terminal,
    osc52_read: u8,
    dnd: *DataOffer,
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
        const linux = std.os.linux;
        defer _ = linux.close(fd);
        var offset: usize = 0;
        while (offset < self.text.len) {
            const rc = linux.write(fd, self.text.ptr + offset, self.text.len - offset);
            switch (linux.errno(rc)) {
                .SUCCESS => offset += rc,
                .INTR => continue,
                else => return,
            }
        }
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
        .transfer_action = .terminal,
    };
}

pub fn deinit(self: *Clipboard) void {
    if (self.transfer_fd >= 0) _ = std.os.linux.close(self.transfer_fd);
    self.transfer_buf.deinit(self.alloc);
    if (self.clip_offer) |offer| offer.destroy();
    if (self.clip_pending_offer) |offer| offer.destroy();
    if (self.primary_offer) |offer| offer.destroy();
    if (self.primary_pending_offer) |offer| offer.destroy();
    if (self.dnd_offer) |offer| offer.destroy();
    if (self.clip_source) |source| source.destroy();
    if (self.primary_source) |source| source.destroy();
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

/// Takes ownership of `text` on every path.
pub fn claim(self: *Clipboard, target: Target, text: [:0]const u8, serial: u32) bool {
    return switch (target) {
        .clipboard => self.claimClipboard(text, serial),
        .primary => self.claimPrimary(text, serial),
    };
}

pub fn request(self: *Clipboard, target: Target, purpose: Purpose) RequestResult {
    if (self.transfer_fd >= 0) return .busy;

    const action: TransferAction = switch (purpose) {
        .terminal => .terminal,
        .osc52_read => |kind| .{ .osc52_read = kind },
    };
    switch (target) {
        .clipboard => {
            const offer = self.clip_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
            self.beginTransfer(mime, .{ .clipboard = offer }, action) catch return .unavailable;
        },
        .primary => {
            const offer = self.primary_offer orelse return .unavailable;
            const mime = offer.bestMime() orelse return .unavailable;
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
pub fn readTransfer(self: *Clipboard) ?Event {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(self.transfer_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => break,
        };
        if (n == 0) break;
        self.transfer_buf.appendSlice(self.alloc, buf[0..n]) catch break;
    }

    _ = std.os.linux.close(self.transfer_fd);
    self.transfer_fd = -1;
    return switch (self.transfer_action) {
        .terminal => .{ .terminal = self.transfer_buf.items },
        .osc52_read => |kind| .{ .osc52_read = .{ .kind = kind, .data = self.transfer_buf.items } },
        .dnd => |offer| .{ .dnd = .{
            .mime = std.mem.span(offer.bestDndMime() orelse unreachable),
            .data = self.transfer_buf.items,
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
    self.transfer_action = .terminal;
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

    offer.receive(mime, fds[1]);
    _ = std.os.linux.close(fds[1]);
    setNonblocking(fds[0]);
    self.transfer_fd = fds[0];
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
        .action => |ev| offer.dnd_action = ev.dnd_action,
        else => {},
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
                offer.offer.accept(enter.serial, mime);
                offer.offer.setActions(.{ .copy = true }, .{ .copy = true });
                if (self.dnd_offer) |old| old.destroy();
                self.dnd_offer = offer;
            } else {
                offer.offer.accept(enter.serial, null);
                offer.destroy();
            }
        },
        .leave => if (self.dnd_offer) |offer| offer.destroy(),
        .drop => self.beginDrop(),
        .motion => {},
    }
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

fn setNonblocking(fd: posix.fd_t) void {
    const linux = std.os.linux;
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}
