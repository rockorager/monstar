//! Detects whole-row viewport shifts by matching the previous render
//! snapshot's row pins against the terminal's new viewport. Ghostty marks a
//! viewport-pin change as a full redraw but does not report the displacement.
//! In-place one-row rotations instead require matching copied cell contents.

const ScrollDetector = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

pub const Scroll = struct {
    /// Rows the content moved: positive moves content up, negative down.
    shift: isize,
};

pins: std.ArrayList(vt.Pin) = .empty,
predirty: std.DynamicBitSetUnmanaged = .{},

pub fn deinit(self: *ScrollDetector, alloc: std.mem.Allocator) void {
    self.pins.deinit(alloc);
    self.predirty.deinit(alloc);
}

/// Must run immediately before RenderState.update while both the old row
/// pins and the terminal's unconsumed dirty flags are available.
pub fn detect(
    self: *ScrollDetector,
    alloc: std.mem.Allocator,
    state: *const vt.RenderState,
    term: *const vt.Terminal,
) !?Scroll {
    if (state.dirty != .false) return null;
    const rows: usize = state.rows;
    if (rows == 0 or state.row_data.len != rows) return null;
    const screen = term.screens.active;
    if (term.screens.active_key != state.screen) return null;
    if (rows != screen.pages.rows or state.cols != screen.pages.cols) return null;

    const TerminalDirtyInt = @typeInfo(vt.Terminal.Dirty).@"struct".backing_integer.?;
    if (@as(TerminalDirtyInt, @bitCast(term.flags.dirty)) != 0) return null;
    const ScreenDirtyInt = @typeInfo(vt.Screen.Dirty).@"struct".backing_integer.?;
    if (@as(ScreenDirtyInt, @bitCast(screen.dirty)) != 0) return null;

    // Selection pixels are tied to viewport positions and cannot safely
    // be carried along with terminal content.
    if (screen.selection != null) return null;
    for (state.row_data.items(.selection)) |selection| {
        if (selection != null) return null;
    }

    const old_viewport = state.viewport_pin orelse return null;
    const new_viewport = screen.pages.getTopLeft(.viewport);
    if (old_viewport.eql(new_viewport)) {
        // Row rotation changes the page layout without moving its pins.
        // Ordinary writes leave the layout serial unchanged: avoid scanning
        // the viewport on those updates. Only dereference the current pin.
        if (rows < 2 or new_viewport.node.serial == state.row_data.items(.serial)[0]) return null;
        try self.predirty.resize(alloc, rows, false);
        self.predirty.unsetAll();
        for ([_]isize{ 1, -1 }) |shift| {
            var current = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
            var matched: usize = 0;
            var y: usize = 0;
            while (current.next()) |pin| : (y += 1) {
                const old_y = @as(isize, @intCast(y)) + shift;
                if (old_y < 0 or old_y >= rows) continue;
                if (!rowMatches(pin, state.row_data.items(.cells)[@intCast(old_y)].slice())) break;
                matched += 1;
            }
            if (matched == rows - 1) return .{ .shift = shift };
        }
        return null;
    }

    try self.pins.resize(alloc, rows);
    try self.predirty.resize(alloc, rows, false);
    self.predirty.unsetAll();
    var it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var y: usize = 0;
    while (it.next()) |pin| : (y += 1) {
        if (y >= rows) return null;
        self.pins.items[y] = pin;
        if (pin.node.page().dirty or pin.rowAndCell().row.dirty) self.predirty.set(y);
    }
    if (y != rows) return null;

    const old_pins = state.row_data.items(.pin);
    const new_pins = self.pins.items;
    if (findPin(new_pins[0], old_pins)) |shift| {
        if (pinsMatch(new_pins[0 .. rows - shift], old_pins[shift..rows])) {
            return .{ .shift = @intCast(shift) };
        }
    }
    if (findPin(old_pins[0], new_pins)) |shift| {
        if (pinsMatch(new_pins[shift..rows], old_pins[0 .. rows - shift])) {
            return .{ .shift = -@as(isize, @intCast(shift)) };
        }
    }
    return null;
}

/// Replace Ghostty's all-row dirty result with the rows not supplied by
/// shifted pixels, plus terminal writes and cursor pixels.
pub fn prepare(self: *const ScrollDetector, state: *vt.RenderState, scroll: Scroll, old_cursor: vt.RenderState.Cursor) void {
    const rows: usize = state.rows;
    const shift: usize = @abs(scroll.shift);
    std.debug.assert(shift > 0 and shift < rows);
    std.debug.assert(self.predirty.bit_length == rows);

    const dirty_rows = state.row_data.items(.dirty);
    for (dirty_rows[0..rows], 0..) |*dirty, y| {
        const entered = if (scroll.shift > 0) y >= rows - shift else y < shift;
        dirty.* = entered or self.predirty.isSet(y);
    }
    if (old_cursor.visible) {
        if (old_cursor.viewport) |old| {
            const moved = @as(isize, @intCast(old.y)) - scroll.shift;
            if (moved >= 0 and moved < rows) dirty_rows[@intCast(moved)] = true;
        }
    }
    if (state.cursor.visible) {
        if (state.cursor.viewport) |current| {
            if (current.y < rows) dirty_rows[current.y] = true;
        }
    }
    state.dirty = .partial;
}

fn rowMatches(pin: vt.Pin, previous: std.MultiArrayList(vt.RenderState.Cell).Slice) bool {
    const cells = pin.cells(.all);
    if (cells.len != previous.len) return false;
    for (cells, previous.items(.raw), 0..) |*cell, old, x| {
        if (@as(u64, @bitCast(cell.*)) != @as(u64, @bitCast(old))) return false;
        // Interned IDs are page-local and may have been reused since the
        // snapshot. Compare resolved values, never old page pointers.
        if (cell.style_id != 0 and !pin.style(cell).eql(previous.items(.style)[x])) return false;
        if (cell.content_tag == .codepoint_grapheme and
            !std.mem.eql(u21, pin.grapheme(cell) orelse &.{}, previous.items(.grapheme)[x])) return false;
    }
    return true;
}

fn findPin(needle: vt.Pin, pins: []const vt.Pin) ?usize {
    for (pins[1..], 1..) |pin, index| {
        if (needle.eql(pin)) return index;
    }
    return null;
}

fn pinsMatch(a: []const vt.Pin, b: []const vt.Pin) bool {
    std.debug.assert(a.len == b.len);
    for (a, b) |pin_a, pin_b| {
        if (!pin_a.eql(pin_b)) return false;
    }
    return true;
}

fn clearStateDirty(state: *vt.RenderState) void {
    const rows = state.row_data.slice();
    for (rows.items(.dirty)) |*dirty| dirty.* = false;
    state.dirty = .false;
}

test "scroll detector finds viewport shifts and narrows dirty rows" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 10,
        .rows = 4,
        .max_scrollback_bytes = 100,
    });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    var detector: ScrollDetector = .{};
    defer detector.deinit(alloc);

    for (0..8) |i| {
        var buf: [16]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}) catch unreachable);
    }
    try state.update(alloc, &term);
    clearStateDirty(&state);

    const old_cursor = state.cursor;
    stream.nextSlice("next\r\n");
    const down = (try detector.detect(alloc, &state, &term)).?;
    try std.testing.expectEqual(@as(isize, 1), down.shift);
    try state.update(alloc, &term);
    detector.prepare(&state, down, old_cursor);
    try std.testing.expectEqual(vt.RenderState.Dirty.partial, state.dirty);
    try std.testing.expect(state.row_data.items(.dirty)[state.rows - 1]);
    clearStateDirty(&state);

    term.screens.active.pages.scroll(.{ .delta_row = -2 });
    const up = (try detector.detect(alloc, &state, &term)).?;
    try std.testing.expectEqual(@as(isize, -2), up.shift);
    try state.update(alloc, &term);
    detector.prepare(&state, up, state.cursor);
    const dirty = state.row_data.items(.dirty);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false }, dirty[0..4]);
}

test "alternate screen row rotation reuses unchanged content" {
    const alloc = std.testing.allocator;
    for ([_]isize{ 1, -1 }) |shift| {
        var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049h\x1b[?25lfirst\r\n\x1b[31msecond\r\n\x1b[32mc\u{301}\r\nlast");
        var state: vt.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &term);
        clearStateDirty(&state);
        const old_cursor = state.cursor;
        stream.nextSlice(if (shift > 0) "\r\nnew" else "\x1b[T\x1b[1;1Hnew");
        var detector: ScrollDetector = .{};
        defer detector.deinit(alloc);
        const scroll = (try detector.detect(alloc, &state, &term)).?;
        try std.testing.expectEqual(shift, scroll.shift);
        try state.update(alloc, &term);
        detector.prepare(&state, scroll, old_cursor);
        try std.testing.expectEqualSlices(bool, if (shift > 0)
            &.{ false, false, false, true }
        else
            &.{ true, false, false, false }, state.row_data.items(.dirty));
    }
}

test "row rotation rejects changed retained cells and resolved contents" {
    const alloc = std.testing.allocator;
    for (0..3) |change| {
        var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049hfirst\r\n\x1b[31msecond\r\n\x1b[32mc\u{301}\r\nlast");
        var state: vt.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &term);
        clearStateDirty(&state);
        stream.nextSlice("\r\nnew");
        switch (change) {
            0 => stream.nextSlice("\x1b[1;1HX"),
            // Simulate interned IDs reused for different resolved data:
            // raw cells still compare equal, but their old pixels do not.
            1 => state.row_data.items(.cells)[1].items(.style)[0].flags.bold = true,
            2 => state.row_data.items(.cells)[2].items(.grapheme)[0] = &.{0x300},
            else => unreachable,
        }
        var detector: ScrollDetector = .{};
        defer detector.deinit(alloc);
        try std.testing.expectEqual(@as(?Scroll, null), try detector.detect(alloc, &state, &term));
    }
}
