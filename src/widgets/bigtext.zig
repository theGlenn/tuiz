//! Block-glyph numerals for a display-sized headline figure.
//!
//! A terminal has one font at one size, so the only way to give a
//! number the weight a design mock gives a 112px figure is to draw
//! it out of cells. This is a 3×5 pixel font, each font pixel
//! rendered as `2 * scale` cells wide and `scale` rows tall.

const std = @import("std");

/// Rows in the font. A caller renders `rows * scale` terminal rows.
pub const rows: usize = 5;

/// One bit-row per glyph row, MSB = leftmost pixel. Index 10 is `.`,
/// which is one pixel wide instead of three.
const glyphs = [11][rows]u3{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
    .{ 0b111, 0b001, 0b011, 0b001, 0b111 }, // 3
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
    .{ 0b111, 0b001, 0b001, 0b001, 0b001 }, // 7
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
    .{ 0b000, 0b000, 0b000, 0b000, 0b100 }, // .
};

const dot_index: usize = 10;

/// Write one row (`0 .. rows*scale - 1`) of the block rendering of
/// `str`. Characters outside `0-9` and `.` are skipped, so a
/// pre-formatted number can be passed straight through.
///
/// Colour is the caller's: emit an SGR before, a reset after.
pub fn writeRow(w: anytype, str: []const u8, row: usize, scale: usize) !void {
    std.debug.assert(scale > 0);
    std.debug.assert(row < rows * scale);
    const glyph_row = row / scale;
    for (str) |ch| {
        const gi: usize = switch (ch) {
            '0'...'9' => ch - '0',
            '.' => dot_index,
            else => continue,
        };
        const pixels: usize = if (gi == dot_index) 1 else 3;
        const mask = glyphs[gi][glyph_row];
        var p: usize = 0;
        while (p < pixels) : (p += 1) {
            const shift: u2 = @intCast(2 - p);
            const on = ((mask >> shift) & 1) == 1;
            var c: usize = 0;
            while (c < 2 * scale) : (c += 1) try w.writeAll(if (on) "█" else " ");
        }
        // Inter-glyph gap, one font pixel wide.
        var g: usize = 0;
        while (g < scale) : (g += 1) try w.writeAll(" ");
    }
}

/// Cell width of `str` rendered at `scale`, for layout budgeting
/// without drawing.
pub fn measure(str: []const u8, scale: usize) usize {
    var cells: usize = 0;
    for (str) |ch| {
        const pixels: usize = switch (ch) {
            '0'...'9' => 3,
            '.' => 1,
            else => continue,
        };
        cells += pixels * 2 * scale + scale;
    }
    return cells;
}

test "measure matches what writeRow emits" {
    const cell = @import("../cell.zig");
    for ([_]usize{ 1, 2 }) |scale| {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeRow(&w, "12.34", 0, scale);
        try std.testing.expectEqual(measure("12.34", scale), cell.width(w.buffered()));
    }
}

test "non-numeric characters are skipped, not drawn" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRow(&w, "n/a", 0, 1);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}
