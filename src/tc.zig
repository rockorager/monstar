//! Terminal Compositing via Wayland (TC-Wayland) Prototype Module.
//! Provides binary cell memory ABI, compositor display server,
//! buffer factory, grid surface management, and client helper.

pub const abi = @import("tc/abi.zig");
pub const CompactCell = abi.CompactCell;
pub const CompactFlags = abi.CompactFlags;
pub const RichCell = abi.RichCell;

pub const Buffer = @import("tc/Buffer.zig");
pub const Surface = @import("tc/Surface.zig");
pub const Compositor = @import("tc/Compositor.zig");
pub const Client = @import("tc/Client.zig");

test {
    _ = abi;
    _ = Buffer;
    _ = Surface;
    _ = Compositor;
    _ = Client;
}
