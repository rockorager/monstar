//! Stores rendered cell fingerprints and measures dirty-row repaint ranges.

const CellDamageTracker = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

const kitty_placeholder = vt.kitty.graphics.unicode.placeholder;

alloc: std.mem.Allocator,
fingerprints: std.ArrayList(CellFingerprint) = .empty,
fingerprint_scratch: std.ArrayList(CellFingerprint) = .empty,
fingerprint_valid: std.DynamicBitSetUnmanaged = .{},
damage: std.ArrayList(?CellRange) = .empty,
rows: usize = 0,
cols: usize = 0,
colors: ?Colors = null,
stats: CellDamageStats = .{},

pub const Colors = @FieldType(vt.RenderState, "colors");

pub const CellDamageStats = struct {
    dirty_rows: usize = 0,
    unchanged_dirty_rows: usize = 0,
    scanned_cells: usize = 0,
    changed_cells: usize = 0,
    /// Cells covered by one first-through-last changed interval per row.
    spanned_cells: usize = 0,
};

pub const CellFingerprint = struct {
    raw: vt.Cell,
    style: vt.Style,
    grapheme: u64,
    visual: u8,
    cursor_style: u8,

    fn eql(self: CellFingerprint, other: CellFingerprint) bool {
        return @as(u64, @bitCast(self.raw)) == @as(u64, @bitCast(other.raw)) and
            (self.raw.style_id == 0 or self.style.eql(other.style)) and
            self.grapheme == other.grapheme and
            self.visual == other.visual and
            self.cursor_style == other.cursor_style;
    }
};

pub const CellRange = struct {
    start: usize,
    end: usize,
};

pub const Measurement = enum {
    snapshot,
    compare,
};

pub fn init(alloc: std.mem.Allocator) CellDamageTracker {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *CellDamageTracker) void {
    self.fingerprints.deinit(self.alloc);
    self.fingerprint_scratch.deinit(self.alloc);
    self.fingerprint_valid.deinit(self.alloc);
    self.damage.deinit(self.alloc);
    self.* = undefined;
}

/// Returns tracker-owned scratch space for Renderer to populate with the
/// current row's visual fingerprints.
pub fn rowScratch(self: *CellDamageTracker, cols: usize) ![]CellFingerprint {
    try self.fingerprint_scratch.resize(self.alloc, cols);
    return self.fingerprint_scratch.items;
}

pub fn beginSnapshot(self: *CellDamageTracker, rows: usize, cols: usize, colors: Colors) !void {
    const len = try std.math.mul(usize, rows, cols);
    try self.fingerprints.resize(self.alloc, len);
    try self.fingerprint_valid.resize(self.alloc, rows, false);
    self.fingerprint_valid.unsetAll();
    self.rows = rows;
    self.cols = cols;
    self.colors = colors;
    if (cols == 0 and rows > 0) self.fingerprint_valid.setRangeValue(.{ .start = 0, .end = rows }, true);
}

/// After beginSnapshot, the caller supplies every cell in row/column order.
/// Writing a row's final column marks that row's snapshot valid.
pub fn snapshotCell(self: *CellDamageTracker, row: usize, col: usize, fingerprint: CellFingerprint) void {
    std.debug.assert(row < self.rows);
    std.debug.assert(col < self.cols);
    self.fingerprints.items[row * self.cols + col] = fingerprint;
    if (col + 1 == self.cols) self.fingerprint_valid.set(row);
}

pub fn beginMeasurement(
    self: *CellDamageTracker,
    rows: usize,
    cols: usize,
    colors: Colors,
    dirty: []const bool,
) !Measurement {
    std.debug.assert(dirty.len >= rows);
    const len = try std.math.mul(usize, rows, cols);
    try self.damage.resize(self.alloc, rows);
    @memset(self.damage.items, null);
    if (self.rows != rows or
        self.cols != cols or
        self.fingerprints.items.len != len or
        self.fingerprint_valid.bit_length != rows or
        self.colors == null or
        !std.meta.eql(self.colors.?, colors))
    {
        try self.beginSnapshot(rows, cols, colors);
        for (dirty[0..rows], self.damage.items) |is_dirty, *row_damage| {
            if (is_dirty) row_damage.* = .{ .start = 0, .end = cols };
        }
        return .snapshot;
    }
    _ = try self.rowScratch(cols);
    return .compare;
}

pub fn measureRow(
    self: *CellDamageTracker,
    row: usize,
    raw_cells: []const vt.Cell,
    current: []const CellFingerprint,
) void {
    std.debug.assert(row < self.rows);
    std.debug.assert(raw_cells.len == self.cols);
    std.debug.assert(current.len == self.cols);

    self.stats.dirty_rows += 1;
    self.stats.scanned_cells += self.cols;
    var first = self.cols;
    var end: usize = 0;
    const previous = self.fingerprints.items[row * self.cols ..][0..self.cols];
    for (current, 0..) |fingerprint, x| {
        if (!self.fingerprint_valid.isSet(row) or !previous[x].eql(fingerprint)) {
            first = @min(first, x);
            end = x + 1;
            self.stats.changed_cells += 1;
        }
    }
    if (first == self.cols) {
        self.stats.unchanged_dirty_rows += 1;
    } else {
        const row_damage = expandCellDamage(previous, raw_cells, .{ .start = first, .end = end });
        self.damage.items[row] = row_damage;
        self.stats.spanned_cells += row_damage.end - row_damage.start;
    }
    @memcpy(previous, current);
    self.fingerprint_valid.set(row);
}

pub fn damageForRow(self: *const CellDamageTracker, row: usize) ?CellRange {
    std.debug.assert(row < self.damage.items.len);
    return self.damage.items[row];
}

pub fn fingerprintIsValid(self: *const CellDamageTracker, row: usize) bool {
    std.debug.assert(row < self.fingerprint_valid.bit_length);
    return self.fingerprint_valid.isSet(row);
}

pub fn resetStats(self: *CellDamageTracker) void {
    self.stats = .{};
}

pub fn readStats(self: *const CellDamageTracker) CellDamageStats {
    return self.stats;
}

/// Move stored fingerprints with a framebuffer scroll and invalidate newly
/// exposed rows until Renderer supplies their current visual state.
pub fn shift(self: *CellDamageTracker, rows: usize, cols: usize, shift_rows: isize) !void {
    const shift_rows_abs: usize = @abs(shift_rows);
    std.debug.assert(shift_rows_abs > 0 and shift_rows_abs < rows);
    if (self.rows != rows or
        self.cols != cols or
        self.fingerprints.items.len != rows * cols or
        self.fingerprint_valid.bit_length != rows)
    {
        try self.fingerprint_valid.resize(self.alloc, rows, false);
        self.fingerprint_valid.unsetAll();
        return;
    }
    if (shift_rows > 0) {
        for (0..rows - shift_rows_abs) |dst| {
            const src = dst + shift_rows_abs;
            @memcpy(
                self.fingerprints.items[dst * cols ..][0..cols],
                self.fingerprints.items[src * cols ..][0..cols],
            );
            self.fingerprint_valid.setValue(dst, self.fingerprint_valid.isSet(src));
        }
        self.fingerprint_valid.setRangeValue(.{ .start = rows - shift_rows_abs, .end = rows }, false);
    } else {
        var dst = rows;
        while (dst > shift_rows_abs) {
            dst -= 1;
            const src = dst - shift_rows_abs;
            @memcpy(
                self.fingerprints.items[dst * cols ..][0..cols],
                self.fingerprints.items[src * cols ..][0..cols],
            );
            self.fingerprint_valid.setValue(dst, self.fingerprint_valid.isSet(src));
        }
        self.fingerprint_valid.setRangeValue(.{ .start = 0, .end = shift_rows_abs }, false);
    }
}

fn expandCellDamage(
    previous: []const CellFingerprint,
    current: []const vt.Cell,
    initial: CellRange,
) CellRange {
    std.debug.assert(previous.len == current.len);
    const cols = current.len;
    var result = initial;

    result.start = @min(
        textRunStart(previous, result.start),
        textRunStartRaw(current, result.start),
    );
    result.end = @max(
        textRunEnd(previous, result.end),
        textRunEndRaw(current, result.end),
    );

    // Covers horizontal glyph bearings and the symbol constraint heuristic,
    // which can consume the empty cell immediately after a glyph.
    result.start -|= 1;
    result.end = @min(cols, result.end + 1);

    // Keep wide heads and spacer tails in the same repaint interval.
    if (result.start > 0 and
        (previous[result.start].raw.wide == .spacer_tail or current[result.start].wide == .spacer_tail))
    {
        result.start -= 1;
    }
    if (result.end < cols and
        (previous[result.end - 1].raw.wide == .wide or current[result.end - 1].wide == .wide))
    {
        result.end += 1;
    }
    return result;
}

fn textRunStart(cells: []const CellFingerprint, x: usize) usize {
    if (x >= cells.len or !cellHasText(cells[x].raw)) return x;
    var start = x;
    while (start > 0 and cellHasText(cells[start - 1].raw)) start -= 1;
    return start;
}

fn textRunStartRaw(cells: []const vt.Cell, x: usize) usize {
    if (x >= cells.len or !cellHasText(cells[x])) return x;
    var start = x;
    while (start > 0 and cellHasText(cells[start - 1])) start -= 1;
    return start;
}

fn textRunEnd(cells: []const CellFingerprint, end: usize) usize {
    if (end == 0 or !cellHasText(cells[end - 1].raw)) return end;
    var result = end;
    while (result < cells.len and cellHasText(cells[result].raw)) result += 1;
    return result;
}

fn textRunEndRaw(cells: []const vt.Cell, end: usize) usize {
    if (end == 0 or !cellHasText(cells[end - 1])) return end;
    var result = end;
    while (result < cells.len and cellHasText(cells[result])) result += 1;
    return result;
}

fn cellHasText(cell: vt.Cell) bool {
    return switch (cell.content_tag) {
        .codepoint => cell.content.codepoint.data != 0 and
            cell.content.codepoint.data != ' ' and
            cell.content.codepoint.data != kitty_placeholder,
        .codepoint_grapheme => cell.content.codepoint.data != 0 and
            cell.content.codepoint.data != kitty_placeholder,
        else => false,
    };
}
