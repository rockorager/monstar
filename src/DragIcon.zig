//! The surface previewing an outgoing drag. Every preview is uploaded when
//! the drag starts, so switching previews mid-drag only reattaches a buffer.

const DragIcon = @This();

const std = @import("std");
const wl = @import("wayland").client.wl;
const ShmBuffer = @import("ShmBuffer.zig");
const drag_preview = @import("drag_preview.zig");

alloc: std.mem.Allocator,
surface: *wl.Surface,
previews: []Preview,

const Preview = struct {
    buffer: *ShmBuffer,
    scale: u31,
};

/// Copies `pixels`; the caller keeps ownership of them.
pub fn create(
    alloc: std.mem.Allocator,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    pixels: []const drag_preview.Pixels,
) !*DragIcon {
    const surface = try compositor.createSurface();
    errdefer surface.destroy();
    const previews = try alloc.alloc(Preview, pixels.len);
    errdefer alloc.free(previews);
    var created: usize = 0;
    errdefer for (previews[0..created]) |preview| preview.buffer.destroy(alloc);
    for (pixels, previews) |src, *preview| {
        const buffer = try ShmBuffer.create(alloc, shm, src.width, src.height, .argb8888);
        @memcpy(buffer.pixels(), src.argb);
        preview.* = .{ .buffer = buffer, .scale = src.scale };
        created += 1;
    }
    const self = try alloc.create(DragIcon);
    self.* = .{ .alloc = alloc, .surface = surface, .previews = previews };
    return self;
}

pub fn destroy(self: *DragIcon) void {
    self.surface.destroy();
    for (self.previews) |preview| preview.buffer.destroy(self.alloc);
    self.alloc.free(self.previews);
    self.alloc.destroy(self);
}

/// Show the preview at `index`, or none when it is out of range, as the
/// protocol asks.
pub fn show(self: *DragIcon, index: usize) void {
    if (index < self.previews.len) {
        const preview = self.previews[index];
        if (self.surface.getVersion() >= wl.Surface.set_buffer_scale_since_version)
            self.surface.setBufferScale(preview.scale);
        self.surface.attach(preview.buffer.wl_buffer, 0, 0);
        self.surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    } else {
        self.surface.attach(null, 0, 0);
    }
    self.surface.commit();
}
