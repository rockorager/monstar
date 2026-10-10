//! Bridges OSC 72 drag offers to a native Wayland data source. A real
//! pointer press authorizes each offer. Data stays bounded and transfers
//! use Clipboard's nonblocking queue. File URLs must refer to this machine.

const KittyDrag = @This();

const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").client.wl;
const vt = @import("ghostty-vt");
const Clipboard = @import("Clipboard.zig");
const Font = @import("Font.zig");
const Window = @import("Window.zig");
const ShmBuffer = @import("ShmBuffer.zig");
const drag_icon = @import("drag_icon.zig");
const dnd = vt.kitty.dnd;

const max_data_bytes = 64 * 1024 * 1024;
const max_mimes = 64;
const timeout_ms = 10 * 1000;

pub const WriteFn = *const fn (*anyopaque, []const u8) void;

alloc: std.mem.Allocator,
clipboard: *Clipboard,
window: *Window,
font: *const Font,
ctx: *anyopaque,
write_fn: WriteFn,
enabled: bool = false,
local_files: bool = true,
client_id: u32 = 0,
gesture: ?Gesture = null,
source: ?*wl.DataSource = null,
operations: wl.DataDeviceManager.DndAction = .{},
mimes: std.ArrayList(Mime) = .empty,
chunking: dnd.Chunking = .{},
encoded: std.ArrayList(u8) = .empty,
retained_bytes: usize = 0,
pending: [Clipboard.max_outgoing_transfers]?Pending = @splat(null),
icons: std.ArrayList(*ShmBuffer) = .empty,
icon_surface: ?*wl.Surface = null,
icon_bytes: usize = 0,
icon_scale: u31 = 1,

const Gesture = struct {
    serial: u32,
    x: f64,
    y: f64,
    position: dnd.MoveEvent,
    requested: bool = false,
    deadline_ms: i64 = 0,
};

const Mime = struct {
    name: [:0]u8,
    data: std.ArrayList(u8) = .empty,
    state: enum { offered, requested, ready, failed } = .offered,
};

const Pending = struct {
    fd: posix.fd_t,
    index: usize,
    deadline_ms: i64,
};

pub fn deinit(self: *KittyDrag) void {
    self.clearOffer();
}

pub fn reset(self: *KittyDrag) void {
    self.clearOffer();
    self.enabled = false;
    self.client_id = 0;
}

fn clearOffer(self: *KittyDrag) void {
    self.clipboard.cancelDragTransfers();
    if (self.source) |source| source.destroy();
    self.source = null;
    if (self.icon_surface) |surface| surface.destroy();
    self.icon_surface = null;
    for (self.icons.items) |icon| icon.destroy(self.alloc);
    self.icons.clearAndFree(self.alloc);
    self.icon_bytes = 0;
    self.gesture = null;
    for (&self.pending) |*pending| {
        if (pending.*) |item| _ = std.os.linux.close(item.fd);
        pending.* = null;
    }
    for (self.mimes.items) |*mime| {
        self.alloc.free(mime.name);
        mime.data.deinit(self.alloc);
    }
    self.mimes.clearAndFree(self.alloc);
    self.encoded.clearAndFree(self.alloc);
    self.chunking = .{};
    self.retained_bytes = 0;
}

/// Arm only for a left press inside the grid, without Shift or Ctrl.
pub fn press(self: *KittyDrag, serial: u32, x: f64, y: f64, position: dnd.MoveEvent) void {
    if (!self.enabled or self.source != null or self.clipboard.data_device == null) return;
    self.clearOffer();
    self.gesture = .{ .serial = serial, .x = x, .y = y, .position = position };
}

pub fn motion(self: *KittyDrag, x: f64, y: f64) void {
    const gesture = if (self.gesture) |*g| g else return;
    if (gesture.requested or self.source != null) return;
    const dx = x - gesture.x;
    const dy = y - gesture.y;
    if (dx * dx + dy * dy < 64) return;
    gesture.requested = true;
    gesture.deadline_ms = Clipboard.monotonicMs() + timeout_ms;
    const p = gesture.position;
    var buf: [128]u8 = undefined;
    const metadata = std.fmt.bufPrint(&buf, "t=o:x={d}:y={d}:X={d}:Y={d}", .{
        p.cell_x, p.cell_y, p.pixel_x, p.pixel_y,
    }) catch return;
    self.reply(metadata, "");
}

pub fn release(self: *KittyDrag) void {
    if (self.source != null) return;
    const gesture = self.gesture orelse return;
    if (gesture.requested and self.mimes.items.len != 0) self.reply("t=E", "EPERM");
    self.clearOffer();
}

/// Return true for outbound commands, leaving drop handling to libghostty.
pub fn handle(self: *KittyDrag, command: vt.osc.Command.KittyDndProtocol) bool {
    const raw = dnd.Metadata.parse(command.metadata) orelse return true;
    if (raw.type == .query) return false;
    if (!self.chunking.active) switch (raw.type orelse return false) {
        .offer, .present, .start_drag, .drag_event, .drag_error, .remote_data => {},
        else => return false,
    };
    const continuation = self.chunking.active;
    if (!continuation and raw.type == .offer and raw.client_id != 0) self.client_id = raw.client_id;
    if (!continuation and raw.type == .offer and (raw.cell_x == 1 or raw.cell_x == 2)) {
        self.clearOffer();
        self.client_id = raw.client_id;
        self.enabled = false;
    }
    const meta = self.chunking.apply(raw);
    const payload = command.payload orelse "";
    if (payload.len > 4096) {
        self.fail("EFBIG");
        return true;
    }
    self.process(meta, payload, continuation) catch |err| self.fail(switch (err) {
        error.OutOfMemory => "ENOMEM",
        error.TooLarge => "EFBIG",
        error.NotAllowed => "EPERM",
        else => "EINVAL",
    });
    return true;
}

fn process(self: *KittyDrag, meta: dnd.Metadata, payload: []const u8, continuation: bool) !void {
    switch (meta.type.?) {
        .offer => {
            if (meta.cell_x == 1 or meta.cell_x == 2) {
                try self.appendEncoded(payload, 256);
                if (!meta.more) {
                    self.local_files = matchesMachine(self.encoded.items);
                    self.encoded.clearRetainingCapacity();
                    self.enabled = meta.cell_x == 1;
                }
                return;
            }
            const gesture = self.gesture orelse return error.NotAllowed;
            if (meta.cell_x != 0 or !gesture.requested or self.source != null) return error.NotAllowed;
            if (!continuation and self.mimes.items.len != 0) return error.NotAllowed;
            if (meta.operation < 1 or meta.operation > 3) return error.InvalidOperation;
            try self.appendEncoded(payload, dnd.max_mime_list_bytes);
            if (meta.more) return;
            self.operations = .{ .copy = meta.operation & 1 != 0, .move = meta.operation & 2 != 0 };
            var names = std.mem.tokenizeScalar(u8, self.encoded.items, ' ');
            while (names.next()) |name| {
                if (self.mimes.items.len == max_mimes) return error.TooLarge;
                if (!validMime(name)) return error.InvalidMime;
                if (!self.local_files and std.mem.eql(u8, name, "text/uri-list")) return error.NotAllowed;
                for (self.mimes.items) |mime| if (std.mem.eql(u8, mime.name, name)) return error.InvalidMime;
                const owned = try self.alloc.dupeZ(u8, name);
                errdefer self.alloc.free(owned);
                try self.mimes.append(self.alloc, .{ .name = owned });
            }
            if (self.mimes.items.len == 0) return error.InvalidMime;
            self.encoded.clearRetainingCapacity();
        },
        .present, .drag_event => {
            if (meta.type == .drag_event and self.source == null) return error.InvalidState;
            if (self.mimes.items.len == 0) return error.NotAllowed;
            const streaming = meta.type == .drag_event;
            if (streaming != (self.source != null)) return error.NotAllowed;
            const index = if (streaming) meta.cell_y else meta.cell_x;
            if (index < 0 and !streaming) {
                const limit: usize = if (meta.cell_y == 0) 4096 else drag_icon.max_bytes;
                try self.appendEncoded(payload, (limit + 2) / 3 * 4);
                if (meta.more or self.encoded.items.len == 0) return;
                const icon_index = -@as(i64, index) - 1;
                if (icon_index != self.icons.items.len or icon_index >= 8) return error.InvalidIndex;
                var data: std.ArrayList(u8) = .empty;
                defer data.deinit(self.alloc);
                _ = try self.decodeInto(&data, limit);
                self.encoded.clearAndFree(self.alloc);
                if (self.icons.items.len == 0) self.icon_scale = if (self.window.surface.getVersion() >= wl.Surface.set_buffer_scale_since_version)
                    @intCast(@max(1, (self.window.scale120 + 119) / 120))
                else
                    1;
                const icon = try drag_icon.create(self.alloc, self.window.shm, self.font, self.icon_scale, self.window.scale120, meta, data.items, drag_icon.max_bytes -| self.icon_bytes);
                errdefer icon.destroy(self.alloc);
                const bytes = icon.pixels().len * 4;
                try self.icons.append(self.alloc, icon);
                self.icon_bytes += bytes;
                return;
            }
            if (index < 0 or index >= self.mimes.items.len) return error.InvalidIndex;
            const mime = &self.mimes.items[@intCast(index)];
            if (streaming and mime.state != .requested) return error.NotAllowed;
            if (mime.state == .ready or mime.state == .failed) return error.NotAllowed;
            try self.appendEncoded(payload, (max_data_bytes - self.retained_bytes + 2) / 3 * 4);
            if (meta.more) return;
            self.retained_bytes += try self.decodeInto(&mime.data, max_data_bytes - self.retained_bytes);
            if (payload.len == 0) {
                mime.state = .ready;
                self.flushPending(@intCast(index));
            }
        },
        .start_drag => {
            if (meta.cell_x != -1) {
                if (self.source == null) return error.NotAllowed;
                self.showIcon(meta.cell_x);
                return;
            }
            const gesture = self.gesture orelse return error.NotAllowed;
            if (!gesture.requested or self.source != null or self.mimes.items.len == 0 or meta.more) return error.NotAllowed;
            const manager = self.clipboard.data_manager orelse return error.NotAllowed;
            const device = self.clipboard.data_device orelse return error.NotAllowed;
            // v3 reports completion and negotiates copy/move. Older versions
            // cannot faithfully report the lifetime of an outbound drag.
            if (manager.getVersion() < wl.DataSource.set_actions_since_version) return error.NotAllowed;
            const surface = try self.window.compositor.createSurface();
            errdefer surface.destroy();
            const source = try manager.createDataSource();
            for (self.mimes.items) |mime| source.offer(mime.name.ptr);
            source.setActions(self.operations);
            source.setListener(*KittyDrag, sourceListener, self);
            self.encoded.clearAndFree(self.alloc);
            self.source = source;
            self.icon_surface = surface;
            device.startDrag(source, self.window.surface, surface, gesture.serial);
            self.showIcon(0);
            self.reply("t=E", "OK");
        },
        .drag_error => {
            if (self.source == null) return error.InvalidState;
            if (meta.more) return;
            if (meta.cell_y == -1) {
                self.clearOffer();
                return;
            }
            if (meta.cell_y < 0 or meta.cell_y >= self.mimes.items.len) return error.InvalidIndex;
            const index: usize = @intCast(meta.cell_y);
            const mime = &self.mimes.items[index];
            if (mime.state != .requested) return error.NotAllowed;
            self.retained_bytes -= mime.data.items.len;
            mime.data.clearAndFree(self.alloc);
            mime.state = .failed;
            self.flushPending(index);
        },
        .remote_data => return error.NotAllowed,
        else => unreachable,
    }
}

fn showIcon(self: *KittyDrag, index: i32) void {
    const surface = self.icon_surface orelse return;
    if (surface.getVersion() >= wl.Surface.set_buffer_scale_since_version) surface.setBufferScale(@intCast(self.icon_scale));
    if (index >= 0 and index < self.icons.items.len) {
        const icon = self.icons.items[@intCast(index)];
        surface.attach(icon.wl_buffer, 0, 0);
    } else surface.attach(null, 0, 0);
    surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
}

fn appendEncoded(self: *KittyDrag, payload: []const u8, limit: usize) !void {
    if (payload.len > limit -| self.encoded.items.len) return error.TooLarge;
    try self.encoded.appendSlice(self.alloc, payload);
}

fn decodeInto(self: *KittyDrag, data: *std.ArrayList(u8), limit: usize) !usize {
    const encoded = self.encoded.items;
    const decoder = if (std.mem.endsWith(u8, encoded, "=")) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    if (size > limit) return error.TooLarge;
    const offset = data.items.len;
    try data.resize(self.alloc, offset + size);
    try decoder.decode(data.items[offset..], encoded);
    self.encoded.clearRetainingCapacity();
    return size;
}

fn reply(self: *KittyDrag, metadata: []const u8, payload: []const u8) void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    dnd.encode(&writer, metadata, self.client_id, payload, .plain, .st) catch return;
    self.write_fn(self.ctx, writer.buffered());
}

fn fail(self: *KittyDrag, name: []const u8) void {
    self.reply("t=E", name);
    self.clearOffer();
}

fn event(self: *KittyDrag, code: u8, value: i32) void {
    var buf: [64]u8 = undefined;
    const metadata = if (code == 2)
        std.fmt.bufPrint(&buf, "t=e:x={d}:o={d}", .{ code, value }) catch return
    else
        std.fmt.bufPrint(&buf, "t=e:x={d}:y={d}", .{ code, value }) catch return;
    self.reply(metadata, "");
}

fn sourceListener(_: *wl.DataSource, ev: wl.DataSource.Event, self: *KittyDrag) void {
    switch (ev) {
        .target => |target| if (target.mime_type) |name| {
            for (self.mimes.items, 0..) |mime, i| {
                if (std.mem.eql(u8, mime.name, std.mem.span(name))) {
                    self.event(1, @intCast(i));
                    break;
                }
            }
        },
        .action => |action| self.event(2, if (action.dnd_action.move) 2 else if (action.dnd_action.copy) 1 else 0),
        .dnd_drop_performed => self.event(3, 0),
        .dnd_finished, .cancelled => {
            self.event(4, if (ev == .cancelled) 1 else 0);
            if (ev == .dnd_finished) self.clipboard.finishDragTransfers();
            self.clearOffer();
        },
        .send => |request| self.send(std.mem.span(request.mime_type), request.fd),
    }
}

fn send(self: *KittyDrag, name: []const u8, fd: posix.fd_t) void {
    const index = for (self.mimes.items, 0..) |mime, i| {
        if (std.mem.eql(u8, mime.name, name)) break i;
    } else {
        _ = std.os.linux.close(fd);
        return;
    };
    const mime = &self.mimes.items[index];
    if (mime.state == .failed) {
        _ = std.os.linux.close(fd);
        return;
    }
    if (mime.state == .ready) {
        self.clipboard.sendDragData(mime.data.items, fd) catch |err| self.failTransfer(err);
        return;
    }
    const slot = for (&self.pending) |*pending| {
        if (pending.* == null) break pending;
    } else {
        _ = std.os.linux.close(fd);
        self.fail("EMFILE");
        return;
    };
    slot.* = .{ .fd = fd, .index = index, .deadline_ms = Clipboard.monotonicMs() + timeout_ms };
    if (mime.state == .offered) {
        mime.state = .requested;
        self.event(5, @intCast(index));
    }
}

fn flushPending(self: *KittyDrag, index: usize) void {
    const mime = &self.mimes.items[index];
    for (&self.pending) |*pending| {
        const item = pending.* orelse continue;
        if (item.index != index) continue;
        pending.* = null;
        if (mime.state == .failed) {
            _ = std.os.linux.close(item.fd);
            continue;
        }
        self.clipboard.sendDragData(mime.data.items, item.fd) catch |err| {
            self.failTransfer(err);
            return;
        };
    }
}

fn failTransfer(self: *KittyDrag, err: anyerror) void {
    self.fail(switch (err) {
        error.OutOfMemory => "ENOMEM",
        error.TooManyResources => "EMFILE",
        else => "EIO",
    });
}

pub fn pollTimeoutMs(self: *const KittyDrag) i32 {
    var deadline: ?i64 = null;
    if (self.source == null) {
        if (self.gesture) |gesture| if (gesture.requested) {
            deadline = gesture.deadline_ms;
        };
    }
    for (self.pending) |pending| if (pending) |item| {
        deadline = if (deadline) |end| @min(end, item.deadline_ms) else item.deadline_ms;
    };
    const end = deadline orelse return -1;
    return @intCast(@min(@max(end - Clipboard.monotonicMs(), 0), std.math.maxInt(i32)));
}

pub fn expire(self: *KittyDrag) void {
    if (self.clipboard.takeDragError()) |err| {
        self.fail(if (err == .timed_out) "ETIMEDOUT" else "EIO");
        return;
    }
    if (self.pollTimeoutMs() == 0) self.fail("ETIMEDOUT");
}

fn validMime(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') == null) return false;
    for (name) |ch| if (ch <= 0x20 or ch >= 0x7f) return false;
    return true;
}

fn matchesMachine(id: []const u8) bool {
    if (id.len == 0) return true;
    if (!std.mem.startsWith(u8, id, "1:") or id.len != 66) return false;
    const fd = posix.openat(posix.AT.FDCWD, "/etc/machine-id", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    defer _ = std.os.linux.close(fd);
    var buf: [256]u8 = undefined;
    const n = posix.read(fd, &buf) catch return false;
    const machine = std.mem.trimEnd(u8, buf[0..n], " \t\r\n");
    if (machine.len == 0) return false;
    var digest: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, machine, "tty-dnd-protocol-machine-id");
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, id[2..], &hex);
}
