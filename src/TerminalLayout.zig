//! Physical terminal-grid geometry inside a window surface.

const TerminalLayout = @This();

const std = @import("std");

pub const Padding = struct {
    top: u31 = 0,
    right: u31 = 0,
    bottom: u31 = 0,
    left: u31 = 0,
};

surface_width: u31,
surface_height: u31,
grid_x: u31,
grid_y: u31,
grid_width: u31,
grid_height: u31,
columns: u16,
rows: u16,
padding: Padding,

pub fn init(
    surface_width: u31,
    surface_height: u31,
    cell_width: u31,
    cell_height: u31,
    requested: Padding,
) TerminalLayout {
    std.debug.assert(cell_width > 0 and cell_height > 0);

    const horizontal = fitPadding(surface_width, cell_width, requested.left, requested.right);
    const vertical = fitPadding(surface_height, cell_height, requested.top, requested.bottom);
    const available_width = surface_width - horizontal.before - horizontal.after;
    const available_height = surface_height - vertical.before - vertical.after;
    const columns: u16 = @intCast(@min(
        std.math.maxInt(u16),
        @max(1, available_width / cell_width),
    ));
    const rows: u16 = @intCast(@min(
        std.math.maxInt(u16),
        @max(1, available_height / cell_height),
    ));
    const grid_width = @min(surface_width - horizontal.before, @as(u31, columns) * cell_width);
    const grid_height = @min(surface_height - vertical.before, @as(u31, rows) * cell_height);

    return .{
        .surface_width = surface_width,
        .surface_height = surface_height,
        .grid_x = horizontal.before,
        .grid_y = vertical.before,
        .grid_width = grid_width,
        .grid_height = grid_height,
        .columns = columns,
        .rows = rows,
        .padding = .{
            .top = vertical.before,
            .right = surface_width - horizontal.before - grid_width,
            .bottom = surface_height - vertical.before - grid_height,
            .left = horizontal.before,
        },
    };
}

/// Fit requested padding while retaining one full cell whenever the surface
/// itself can contain one. If both sides must shrink, preserve their ratio.
fn fitPadding(surface: u31, cell: u31, before: u31, after: u31) struct { before: u31, after: u31 } {
    const capacity = surface -| @min(surface, cell);
    const total = @as(u64, before) + after;
    if (total <= capacity) return .{ .before = before, .after = after };
    if (total == 0) return .{ .before = 0, .after = 0 };

    const fitted_before: u31 = @intCast((@as(u64, capacity) * before) / total);
    return .{
        .before = fitted_before,
        .after = capacity - fitted_before,
    };
}

test "layout keeps requested padding and puts cell remainder at the end" {
    const layout = init(105, 86, 10, 20, .{ .left = 4, .right = 6, .top = 2, .bottom = 3 });
    try std.testing.expectEqual(@as(u16, 9), layout.columns);
    try std.testing.expectEqual(@as(u16, 4), layout.rows);
    try std.testing.expectEqual(@as(u31, 4), layout.grid_x);
    try std.testing.expectEqual(@as(u31, 2), layout.grid_y);
    try std.testing.expectEqual(@as(u31, 90), layout.grid_width);
    try std.testing.expectEqual(@as(u31, 80), layout.grid_height);
    try std.testing.expectEqual(Padding{ .left = 4, .right = 11, .top = 2, .bottom = 4 }, layout.padding);
}

test "layout reduces excessive padding to retain a cell" {
    const layout = init(20, 20, 10, 10, .{ .left = 30, .right = 10, .top = 50, .bottom = 50 });
    try std.testing.expectEqual(@as(u16, 1), layout.columns);
    try std.testing.expectEqual(@as(u16, 1), layout.rows);
    try std.testing.expectEqual(@as(u31, 7), layout.padding.left);
    try std.testing.expectEqual(@as(u31, 3), layout.padding.right);
    try std.testing.expectEqual(@as(u31, 5), layout.padding.top);
    try std.testing.expectEqual(@as(u31, 5), layout.padding.bottom);
}

test "layout clips one cell when the surface is smaller than a cell" {
    const layout = init(4, 7, 10, 20, .{ .left = 2, .right = 2, .top = 2, .bottom = 2 });
    try std.testing.expectEqual(@as(u16, 1), layout.columns);
    try std.testing.expectEqual(@as(u16, 1), layout.rows);
    try std.testing.expectEqual(@as(u31, 4), layout.grid_width);
    try std.testing.expectEqual(@as(u31, 7), layout.grid_height);
    try std.testing.expectEqual(Padding{}, layout.padding);
}
