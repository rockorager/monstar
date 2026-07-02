//! Minimal grid metrics consumed by the vendored sprite draw code.
//! Positions are distances in pixels from the top of the cell to the
//! top of the drawn line, matching ghostty's Metrics semantics.
pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    box_thickness: u32,

    underline_position: u32 = 0,
    underline_thickness: u32 = 1,

    strikethrough_position: u32 = 0,
    strikethrough_thickness: u32 = 1,

    /// May be negative to draw above the top of the cell.
    overline_position: i32 = 0,
    overline_thickness: u32 = 1,

    cursor_thickness: u32 = 1,
};
