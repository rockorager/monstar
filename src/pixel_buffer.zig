//! A tagged view over render-target storage: 8-bit sRGB pixels or 16-bit
//! linear-light pixels. The active tag, not renderer state, selects the
//! raster code path; renderers dispatch on it, buffer owners construct it.

const std = @import("std");

pub const PixelBuffer = union(enum) {
    rgba8: []u32,
    rgba16: []u64,

    pub const Const = union(enum) {
        rgba8: []const u32,
        rgba16: []const u64,
    };

    pub fn asConst(self: PixelBuffer) Const {
        return switch (self) {
            .rgba8 => |pixels| .{ .rgba8 = pixels },
            .rgba16 => |pixels| .{ .rgba16 = pixels },
        };
    }
};
