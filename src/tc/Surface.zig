//! Server-side surface state for TC-Wayland.
//! Tracks wl_surface lifecycle, role assignment (Grid, Stream, CursorAnchor),
//! double-buffered attachment state, and atomic commits.

const Surface = @This();

const std = @import("std");
const wayland = @import("wayland");
const server = wayland.server;
const Buffer = @import("Buffer.zig");

pub const Role = enum {
    none,
    grid,
    stream,
};

pub const CursorShape = enum(u32) {
    block = 0,
    beam = 1,
    underline = 2,
};

pub const CursorState = struct {
    col: i32 = 0,
    row: i32 = 0,
    visible: bool = true,
    shape: CursorShape = .block,
};

pub const AnchorPlacement = enum(u32) {
    below_start = 1,
    above_start = 2,
    right = 3,
    left = 4,
};

pub const CursorAnchor = struct {
    target: *Surface,
    placement: AnchorPlacement = .below_start,
    col_offset: i32 = 0,
    row_offset: i32 = 0,
};

allocator: std.mem.Allocator,
resource: *server.wl.Surface,
role: Role = .none,

// Surface positioning
x: i32 = 0,
y: i32 = 0,
z_index: i32 = 0,
visible: bool = true,
anchor: ?CursorAnchor = null,

// Double-buffered state
current_buffer: ?Buffer = null,
pending_buffer: ?Buffer = null,
has_pending_buffer: bool = false,
buffer_damaged: bool = false,

// Grid specific state
title: ?[]const u8 = null,
cursor: CursorState = .{},
grid_resource: ?*server.zterm.GridSurfaceV1 = null,

pub fn init(allocator: std.mem.Allocator, resource: *server.wl.Surface) !*Surface {
    const self = try allocator.create(Surface);
    self.* = .{
        .allocator = allocator,
        .resource = resource,
    };
    return self;
}

pub fn deinit(self: *Surface) void {
    if (self.title) |t| self.allocator.free(t);
    if (self.current_buffer) |*b| b.deinit();
    if (self.pending_buffer) |*b| b.deinit();
    self.allocator.destroy(self);
}

pub fn attach(self: *Surface, buf: ?Buffer) void {
    if (self.pending_buffer) |*b| {
        b.deinit();
    }
    self.pending_buffer = buf;
    self.has_pending_buffer = true;
    self.buffer_damaged = true;
}

pub fn commit(self: *Surface) bool {
    var changed = false;
    if (self.has_pending_buffer) {
        if (self.current_buffer) |*old_buf| {
            old_buf.deinit();
        }
        self.current_buffer = self.pending_buffer;
        self.pending_buffer = null;
        self.has_pending_buffer = false;
        changed = true;
    }
    if (self.buffer_damaged) {
        changed = true;
        self.buffer_damaged = false;
    }
    return changed;
}

pub fn setTitle(self: *Surface, title_str: []const u8) !void {
    if (self.title) |t| self.allocator.free(t);
    self.title = try self.allocator.dupe(u8, title_str);
    if (std.mem.indexOf(u8, title_str, "Palette") != null or
        std.mem.indexOf(u8, title_str, "Overlay") != null or
        std.mem.indexOf(u8, title_str, "Popup") != null)
    {
        self.z_index = 100;
    }
}
