//! Binary Cell Memory ABI definitions for Terminal Compositing via Wayland (TC-Wayland).
//! Conforms to protocol/term-compositor.md Section 4 and protocol/term-compositor-v1.xml.

const std = @import("std");

/// 8-byte compact cell format for low memory footprint and high throughput streaming.
pub const CompactCell = extern struct {
    codepoint: u32,
    fg_color: u8,
    bg_color: u8,
    flags: CompactFlags,

    pub fn init(codepoint: u32, fg: u8, bg: u8, flags: CompactFlags) CompactCell {
        return .{
            .codepoint = codepoint,
            .fg_color = fg,
            .bg_color = bg,
            .flags = flags,
        };
    }

    pub fn ascii(char: u8, fg: u8, bg: u8) CompactCell {
        return .{
            .codepoint = char,
            .fg_color = fg,
            .bg_color = bg,
            .flags = .{},
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(CompactCell) == 8);
    std.debug.assert(@alignOf(CompactCell) == 4);
}

pub const CompactFlags = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    fg_is_palette: bool = true,
    bg_is_palette: bool = true,
    reserved: u7 = 0,
};

/// 32-byte rich cell format for TrueColor RGBA blending, grapheme clusters, hyperlinks.
pub const RichCell = extern struct {
    codepoint: u32,
    fg_rgba: u32,
    bg_rgba: u32,
    ul_rgba: u32,
    hyperlink_id: u32,
    flags: u32,
    width: u8,
    reserved: [7]u8 = [_]u8{0} ** 7,

    pub fn init(codepoint: u32, fg_rgba: u32, bg_rgba: u32) RichCell {
        return .{
            .codepoint = codepoint,
            .fg_rgba = fg_rgba,
            .bg_rgba = bg_rgba,
            .ul_rgba = 0,
            .hyperlink_id = 0,
            .flags = 0,
            .width = 1,
            .reserved = [_]u8{0} ** 7,
        };
    }

    pub fn ascii(char: u8, fg_rgba: u32, bg_rgba: u32) RichCell {
        return init(char, fg_rgba, bg_rgba);
    }
};

comptime {
    std.debug.assert(@sizeOf(RichCell) == 32);
    std.debug.assert(@alignOf(RichCell) == 4);
}

test "abi sizes and layouts" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CompactCell));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RichCell));

    const cell = CompactCell.ascii('A', 7, 0);
    try std.testing.expectEqual(@as(u32, 'A'), cell.codepoint);
    try std.testing.expectEqual(@as(u8, 7), cell.fg_color);
    try std.testing.expectEqual(@as(u8, 0), cell.bg_color);
    try std.testing.expect(cell.flags.fg_is_palette);
}
