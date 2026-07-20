//! Tracks recent frame damage for stale-buffer repair and surface commits.
//!
//! Repair and surface-damage slices borrow tracker-owned scratch storage. A
//! repair slice remains valid until planning the next repair, and a surface
//! damage slice remains valid until converting the next frame's damage.

const FrameDamageTracker = @This();

const std = @import("std");
const AsyncRaster = @import("AsyncRaster.zig");
const Renderer = @import("Renderer.zig");
const Window = @import("Window.zig");

const frame_damage_len = 8;

alloc: std.mem.Allocator,
frame_damage: [frame_damage_len]FrameDamage,
frame_damage_index: usize,
damage_rects: std.ArrayList(Window.DamageRect),
repair_rects: std.ArrayList(AsyncRaster.RepairRect),

pub const Geometry = struct {
    width: u31,
    height: u31,
    grid_x: u31,
    grid_y: u31,
    grid_width: u31,
    grid_height: u31,
    cell_width: u31,
    cell_height: u31,
};

/// What one frame changed, recorded so stale shm buffers can be brought
/// current from the newest rendered shm buffer without copying everything.
const FrameDamage = struct {
    /// Everything changed (or rendering failed partway); ignore `rects`.
    full: bool,
    /// Physical buffer rectangles changed by Renderer.renderDirty.
    rects: std.ArrayList(Renderer.PixelRect),
    /// Pixel geometry this entry was recorded at.
    geometry: Geometry,
};

pub fn init(alloc: std.mem.Allocator) FrameDamageTracker {
    return .{
        .alloc = alloc,
        .frame_damage = @splat(.{
            .full = true,
            .rects = .empty,
            .geometry = .{
                .width = 0,
                .height = 0,
                .grid_x = 0,
                .grid_y = 0,
                .grid_width = 0,
                .grid_height = 0,
                .cell_width = 0,
                .cell_height = 0,
            },
        }),
        .frame_damage_index = 0,
        .damage_rects = .empty,
        .repair_rects = .empty,
    };
}

pub fn deinit(self: *FrameDamageTracker) void {
    for (&self.frame_damage) |*damage| damage.rects.deinit(self.alloc);
    self.damage_rects.deinit(self.alloc);
    self.repair_rects.deinit(self.alloc);
}

/// Advance the damage ring and reset the new current entry to full.
pub fn begin(self: *FrameDamageTracker, geometry: Geometry) void {
    self.frame_damage_index = (self.frame_damage_index + 1) % frame_damage_len;
    const damage = &self.frame_damage[self.frame_damage_index];
    damage.full = true;
    damage.rects.clearRetainingCapacity();
    damage.geometry = geometry;
}

pub fn record(self: *FrameDamageTracker, async_raster: *AsyncRaster, rendered: AsyncRaster.Damage) !void {
    const damage = &self.frame_damage[self.frame_damage_index];
    if (rendered == .full) return;
    damage.full = false;
    switch (rendered) {
        .full => unreachable,
        .partial => {
            try async_raster.copyRenderedRects(self.alloc, &damage.rects);
            std.debug.assert(damage.rects.items.len > 0);
            for (damage.rects.items) |*rect| {
                rect.x += damage.geometry.grid_x;
                rect.y += damage.geometry.grid_y;
            }
            coalesceDamageRects(&damage.rects);
        },
        .none => {},
    }
}

/// Describe the rectangles a stale target missed since it last represented
/// a committed frame. Current cell damage is not known until the render
/// worker scans dirty rows, so repair every missed rectangle first.
pub fn planRepair(
    self: *FrameDamageTracker,
    age: usize,
    dirty_full: bool,
    geometry: Geometry,
) !AsyncRaster.Repair {
    self.repair_rects.clearRetainingCapacity();
    if (dirty_full or age == 1) return .none;
    if (age == 0 or age > frame_damage_len + 1) return .full;

    const missed_frames = age - 1;
    const frame_area = @as(u64, geometry.width) * geometry.height;
    var repair_area: u64 = 0;
    for (0..missed_frames) |back| {
        const entry = self.frameDamageBack(back);
        if (entry.full or !std.meta.eql(entry.geometry, geometry)) return .full;
        for (entry.rects.items) |rect| {
            if (rect.x > geometry.width or rect.width > geometry.width - rect.x or
                rect.y > geometry.height or rect.height > geometry.height - rect.y)
            {
                return .full;
            }
            try self.repair_rects.append(self.alloc, rect);
            repair_area += @as(u64, rect.width) * rect.height;
            // Many small strided copies or enough overlapping area cost more
            // than one linear full-frame copy.
            if (self.repair_rects.items.len > 512 or repair_area * 2 >= frame_area) return .full;
        }
    }
    return .{ .rects = self.repair_rects.items };
}

pub fn invalidate(self: *FrameDamageTracker) void {
    for (&self.frame_damage) |*damage| damage.full = true;
}

/// Surface damage of the current frame only, in physical buffer pixels.
pub fn currentSurfaceDamage(self: *FrameDamageTracker, height: u31) !Window.Damage {
    const entry = self.frameDamageBack(0);
    if (entry.full) return .full;
    std.debug.assert(entry.geometry.height == height);
    self.damage_rects.clearRetainingCapacity();
    for (entry.rects.items) |rect| {
        try self.damage_rects.append(self.alloc, .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        });
    }
    return .{ .rects = self.damage_rects.items };
}

/// The damage entry recorded `back` frames ago (0 = current frame).
fn frameDamageBack(self: *const FrameDamageTracker, back: usize) *const FrameDamage {
    std.debug.assert(back < frame_damage_len);
    return &self.frame_damage[(self.frame_damage_index + frame_damage_len - back) % frame_damage_len];
}

fn coalesceDamageRects(rects: *std.ArrayList(Renderer.PixelRect)) void {
    var kept: usize = 0;
    for (rects.items) |rect| {
        if (kept > 0) {
            const previous = &rects.items[kept - 1];
            const previous_end = previous.y + previous.height;
            if (previous.x == rect.x and previous.width == rect.width and rect.y <= previous_end) {
                previous.height = @max(previous_end, rect.y + rect.height) - previous.y;
                continue;
            }
        }
        rects.items[kept] = rect;
        kept += 1;
    }
    rects.items.len = kept;
}

test "damage rectangles coalesce vertically when columns match" {
    const alloc = std.testing.allocator;
    var rects: std.ArrayList(Renderer.PixelRect) = .empty;
    defer rects.deinit(alloc);
    try rects.appendSlice(alloc, &.{
        .{ .x = 9, .y = 18, .width = 27, .height = 18 },
        .{ .x = 9, .y = 36, .width = 27, .height = 18 },
        .{ .x = 18, .y = 54, .width = 18, .height = 18 },
    });

    coalesceDamageRects(&rects);
    try std.testing.expectEqualSlices(Renderer.PixelRect, &.{
        .{ .x = 9, .y = 18, .width = 27, .height = 36 },
        .{ .x = 18, .y = 54, .width = 18, .height = 18 },
    }, rects.items);
}

test "repair planning preserves dirty and age precedence" {
    var tracker: FrameDamageTracker = .init(std.testing.allocator);
    defer tracker.deinit();
    const geometry: Geometry = .{
        .width = 100,
        .height = 50,
        .grid_x = 5,
        .grid_y = 5,
        .grid_width = 90,
        .grid_height = 40,
        .cell_width = 10,
        .cell_height = 20,
    };

    try std.testing.expectEqual(.none, try tracker.planRepair(0, true, geometry));
    try std.testing.expectEqual(.none, try tracker.planRepair(1, false, geometry));
    try std.testing.expectEqual(.full, try tracker.planRepair(0, false, geometry));
    try std.testing.expectEqual(.full, try tracker.planRepair(frame_damage_len + 2, false, geometry));
}

test "repair planning requires matching valid geometry" {
    var tracker: FrameDamageTracker = .init(std.testing.allocator);
    defer tracker.deinit();
    const geometry: Geometry = .{
        .width = 100,
        .height = 50,
        .grid_x = 5,
        .grid_y = 5,
        .grid_width = 90,
        .grid_height = 40,
        .cell_width = 10,
        .cell_height = 20,
    };
    tracker.begin(geometry);
    tracker.frame_damage[tracker.frame_damage_index].full = false;

    const repair = try tracker.planRepair(2, false, geometry);
    try std.testing.expectEqual(@as(usize, 0), repair.rects.len);
    var changed = geometry;
    changed.cell_width += 1;
    try std.testing.expectEqual(.full, try tracker.planRepair(2, false, changed));
    tracker.invalidate();
    try std.testing.expectEqual(.full, try tracker.planRepair(2, false, geometry));
}
