//! Renderer glyph constraint and spill policy.
//!
//! This controls how terminal cells constrain rasterized glyphs without
//! changing the terminal grid's Unicode width decisions.

const std = @import("std");
const vt = @import("ghostty-vt");

/// How many cells a cell's background covers (wide chars span two).
pub fn cellSpan(cell: vt.Cell) u31 {
    return if (cell.wide == .wide) 2 else 1;
}

/// Renderer-only glyph constraint width, matching Ghostty's symbol heuristic:
/// symbol-like one-column glyphs may render into the following empty/space
/// cell, without changing the terminal grid width.
pub fn constraintWidth(raws: []const vt.Cell, x: usize, cols: usize) u2 {
    const grid_width: u2 = @intCast(@min(cellSpan(raws[x]), 2));
    if (grid_width > 1) return grid_width;

    const cp = cellCodepoint(raws[x]);
    if (!isSymbol(cp)) return grid_width;

    if (x + 1 >= cols) return 1;

    if (x > 0) {
        const prev_cp = cellCodepoint(raws[x - 1]);
        if (isSymbol(prev_cp) and !isGraphicsElement(prev_cp)) return 1;
    }

    const next_cp = cellCodepoint(raws[x + 1]);
    return if (next_cp == 0 or isSpace(next_cp)) 2 else 1;
}

pub fn cellCodepoint(cell: vt.Cell) u21 {
    return switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.content.codepoint.data,
        else => 0,
    };
}

pub fn isSymbol(cp: u21) bool {
    return switch (cp) {
        0x2190...0x21FF, // Arrows
        0x2460...0x24FF, // Enclosed Alphanumerics
        0x2600...0x27BF, // Miscellaneous Symbols, Dingbats
        0x1F000...0x1FAFF, // Emoji/symbol blocks
        0xE000...0xF8FF, // BMP private use area, where Nerd Fonts live
        0xF0000...0xFFFFD, // Supplementary private use area A
        0x100000...0x10FFFD, // Supplementary private use area B
        => true,
        else => false,
    };
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x0020, // SPACE
        0x2002, // EN SPACE
        => true,
        else => false,
    };
}

fn isGraphicsElement(cp: u21) bool {
    return isBoxDrawing(cp) or isBlockElement(cp) or isLegacyComputing(cp) or isPowerline(cp);
}

fn isBoxDrawing(cp: u21) bool {
    return switch (cp) {
        0x2500...0x257F => true,
        else => false,
    };
}

fn isBlockElement(cp: u21) bool {
    return switch (cp) {
        0x2580...0x259F => true,
        else => false,
    };
}

fn isLegacyComputing(cp: u21) bool {
    return switch (cp) {
        0x1FB00...0x1FBFF => true,
        0x1CC00...0x1CEBF => true,
        else => false,
    };
}

fn isPowerline(cp: u21) bool {
    return switch (cp) {
        0xE0B0...0xE0D7 => true,
        else => false,
    };
}

test "symbol glyph constraint widths match Ghostty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    {
        term.fullReset();
        stream.nextSlice("");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice(" z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 0, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("   ");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 3, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("   ");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 2, 3));
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 2, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 0, state.cols));
        try testing.expectEqual(@as(u2, 1), constraintWidth(raws, 1, state.cols));
    }

    {
        term.fullReset();
        stream.nextSlice("z");
        try state.update(alloc, &term);
        const raws = state.row_data.get(0).cells.items(.raw);
        try testing.expectEqual(@as(u2, 2), constraintWidth(raws, 1, state.cols));
    }
}
