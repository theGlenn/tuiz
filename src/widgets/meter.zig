//! Fixed-width percentage meter drawn with eighth-block glyphs over
//! a dotted track, so a near-zero reading still occupies a visible
//! slot instead of vanishing.

const std = @import("std");
const color = @import("../color.zig");

/// Meter width in cells. Ten cells × eight sub-steps = 80 usable
/// levels, which is finer than a percentage readout beside it.
pub const width: usize = 10;

const levels = width * 8;

// The literals below are visually cell-aligned UTF-8 blocks; zig
// fmt's byte-based column counter would scatter them across the
// page, so formatting is off until after the table.
// zig fmt: off
const fills = [levels + 1][]const u8{
    "          ", "▏         ", "▎         ", "▍         ", "▌         ",
    "▋         ", "▊         ", "▉         ", "█         ", "█▏        ",
    "█▎        ", "█▍        ", "█▌        ", "█▋        ", "█▊        ",
    "█▉        ", "██        ", "██▏       ", "██▎       ", "██▍       ",
    "██▌       ", "██▋       ", "██▊       ", "██▉       ", "███       ",
    "███▏      ", "███▎      ", "███▍      ", "███▌      ", "███▋      ",
    "███▊      ", "███▉      ", "████      ", "████▏     ", "████▎     ",
    "████▍     ", "████▌     ", "████▋     ", "████▊     ", "████▉     ",
    "█████     ", "█████▏    ", "█████▎    ", "█████▍    ", "█████▌    ",
    "█████▋    ", "█████▊    ", "█████▉    ", "██████    ", "██████▏   ",
    "██████▎   ", "██████▍   ", "██████▌   ", "██████▋   ", "██████▊   ",
    "██████▉   ", "███████   ", "███████▏  ", "███████▎  ", "███████▍  ",
    "███████▌  ", "███████▋  ", "███████▊  ", "███████▉  ", "████████  ",
    "████████▏ ", "████████▎ ", "████████▍ ", "████████▌ ", "████████▋ ",
    "████████▊ ", "████████▉ ", "█████████ ", "█████████▏", "█████████▎",
    "█████████▍", "█████████▌", "█████████▋", "█████████▊", "█████████▉",
    "██████████",
};
// zig fmt: on

/// Glyph run for `pct` (0..100), space-padded to `width` cells.
/// Values above 100 clamp to full.
pub fn glyphs(pct: u32) []const u8 {
    return fills[@min(pct * levels / 100, levels)];
}

/// How the unfilled remainder of the meter is drawn.
pub const Track = struct {
    /// One cell of track. A dot reads as "capacity", a space reads
    /// as "nothing here".
    glyph: []const u8 = "·",
    /// SGR prefix for the track cells.
    sgr: []const u8 = color.reset,
};

/// `██▍·······` — filled portion in `fill`, remainder in `track`.
pub fn write(w: anytype, pct: u32, fill: color.Rgb, track: Track) !void {
    const filled = glyphs(pct);
    const run = std.mem.trimEnd(u8, filled, " ");
    try color.writeFg(w, fill);
    try w.writeAll(run);
    // Trailing cells in the table are 1-byte spaces, so the byte
    // difference is exactly the remaining cell count.
    var rest = filled.len - run.len;
    try w.writeAll(track.sgr);
    while (rest > 0) : (rest -= 1) try w.writeAll(track.glyph);
    try w.writeAll(color.reset);
}

test "glyphs clamps above 100 and starts empty at 0" {
    try std.testing.expectEqualStrings("          ", glyphs(0));
    try std.testing.expectEqualStrings("██████████", glyphs(100));
    try std.testing.expectEqualStrings("██████████", glyphs(4000));
}

test "write covers exactly the meter width in cells" {
    const cell = @import("../cell.zig");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, 37, color.Rgb.hex("#2dd4bf"), .{});
    try std.testing.expectEqual(width, cell.width(w.buffered()));
}
