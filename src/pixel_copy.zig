//! Pixel copying policy for write-only compositor buffers.
//!
//! Large copies use architecture-specific non-temporal stores where they
//! avoid polluting the renderer's working set; other copies use `@memcpy`.

const std = @import("std");
const builtin = @import("builtin");

/// Copy pixels into a buffer the CPU will not read back (a wl_shm
/// buffer). Large copies use non-temporal stores on x86_64: they skip
/// the read-for-ownership of every destination cache line (about a
/// third of the bus traffic) and keep the copy from evicting the
/// render working set.
pub fn copyPixels(noalias dst: []u32, noalias src: []const u32) void {
    std.debug.assert(dst.len == src.len);
    // Below this size the fence and alignment fixup outweigh the saved
    // traffic, and freshly written destination lines may still be hot.
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    // The self-hosted backend's assembler can't parse the SSE memory
    // operands, so the non-temporal path is LLVM-only (all release
    // builds; debug performance doesn't matter).
    if (comptime builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm) {
        if (dst.len >= nt_threshold) return copyNonTemporal(dst, src);
    }
    @memcpy(dst, src);
}

fn copyNonTemporal(noalias dst: []u32, noalias src: []const u32) void {
    var d: [*]u8 = @ptrCast(dst.ptr);
    var s: [*]const u8 = @ptrCast(src.ptr);
    var n: usize = dst.len * @sizeOf(u32);

    // movntdq requires a 16-byte-aligned destination.
    const misalign = @intFromPtr(d) & 15;
    if (misalign != 0) {
        const head = @min(16 - misalign, n);
        @memcpy(d[0..head], s[0..head]);
        d += head;
        s += head;
        n -= head;
    }
    while (n >= 64) {
        asm volatile (
            \\movdqu  (%%rsi), %%xmm0
            \\movdqu 16(%%rsi), %%xmm1
            \\movdqu 32(%%rsi), %%xmm2
            \\movdqu 48(%%rsi), %%xmm3
            \\movntdq %%xmm0,  (%%rdi)
            \\movntdq %%xmm1, 16(%%rdi)
            \\movntdq %%xmm2, 32(%%rdi)
            \\movntdq %%xmm3, 48(%%rdi)
            :
            : [s] "{rsi}" (s),
              [d] "{rdi}" (d),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
        d += 64;
        s += 64;
        n -= 64;
    }
    if (n != 0) @memcpy(d[0..n], s[0..n]);
    // Non-temporal stores are weakly ordered; publish them before the
    // buffer is handed to the compositor.
    asm volatile ("sfence" ::: .{ .memory = true });
}

test "copyPixels matches scalar copying across policy and alignment boundaries" {
    const nt_threshold = 256 * 1024 / @sizeOf(u32);
    const lengths = [_]usize{
        0,
        1,
        15,
        nt_threshold - 1,
        nt_threshold,
        nt_threshold + 1,
        nt_threshold * 2 + 17,
    };

    for (lengths) |len| {
        for (0..4) |dst_offset| {
            try expectMatchesScalar(len, dst_offset);
        }
    }
}

fn expectMatchesScalar(len: usize, dst_offset: usize) !void {
    const alloc = std.testing.allocator;
    const src_storage = try alloc.alignedAlloc(u32, .@"16", len + 1);
    defer alloc.free(src_storage);
    const dst_storage = try alloc.alignedAlloc(u32, .@"16", len + 7);
    defer alloc.free(dst_storage);
    const expected = try alloc.alloc(u32, len);
    defer alloc.free(expected);

    const src = src_storage[1 .. len + 1];
    const dst = dst_storage[dst_offset .. dst_offset + len];
    for (src, 0..) |*pixel, i| pixel.* = @truncate(i *% 0x9e3779b1 +% 0x12345678);
    @memset(dst_storage, 0xdeadbeef);
    for (src, expected) |pixel, *out| out.* = pixel;

    copyPixels(dst, src);

    try std.testing.expectEqualSlices(u32, expected, dst);
    for (dst_storage[0..dst_offset]) |guard| try std.testing.expectEqual(@as(u32, 0xdeadbeef), guard);
    for (dst_storage[dst_offset + len ..]) |guard| try std.testing.expectEqual(@as(u32, 0xdeadbeef), guard);
}
