//! Bitmap art drawn out of half-block cells.
//!
//! A terminal cell can carry two vertically stacked pixels: `▀` paints
//! its top half in the foreground colour and its bottom half in the
//! background, so a W × H image lands in W × (H/2) cells.
//!
//! Those subpixels are close to square but not square: a cell is not
//! exactly twice as tall as it is wide, so art mapped to a square grid
//! renders a few percent too wide. Correcting that is the generator's
//! job, not this file's. What arrives here is already in
//! the right proportions, and is drawn one subpixel per half-cell with
//! no scaling of any kind.
//!
//! Every richer option is unavailable where the output actually has to
//! land. The kitty, iTerm2, and sixel image protocols all need a
//! terminal that implements them, and the GIFs this dashboard is
//! captured into come out of vhs — ttyd driving xterm.js, which
//! implements none of the three. Half-blocks and truecolor survive that
//! pipeline, so half-blocks are what this draws.
//!
//! Two source formats, because logo art splits cleanly in two:
//!   • `Bitmap` — a colour per subpixel, for full-colour marks.
//!   • `Mask`   — one bit per subpixel plus a caller-chosen colour, for
//!     the single-colour marks that are most of them, at 1/32 the size.
//!
//! Transparent subpixels use the terminal's default background.
//! Each row resets incoming attributes and restores defaults on success.

const std = @import("std");
const color = @import("../color.zig");

const Rgb = color.Rgb;

/// An empty subpixel. Named so generated art reads as art.
pub const transparent: ?Rgb = null;

const upper = "▀";
const lower = "▄";
/// Restore the default background without disturbing the foreground.
/// `\x1b[0m` would work too, but it also drops the foreground and so
/// forces a re-emit on the very next opaque cell.
const bg_default = "\x1b[49m";

/// Full-colour art: one optional colour per subpixel, row-major.
/// `px` is borrowed and must hold at least `w * h` subpixels.
pub const Bitmap = struct {
    w: usize,
    h: usize,
    px: []const ?Rgb,

    /// Terminal rows this occupies. An odd `h` leaves the final row's
    /// bottom half empty rather than dropping it.
    pub fn rows(self: Bitmap) usize {
        return self.h / 2 + self.h % 2;
    }

    fn at(self: Bitmap, x: usize, y: usize) ?Rgb {
        if (y >= self.h) return null;
        return self.px[y * self.w + x];
    }
};

/// Single-colour art: one bit per subpixel, row-major, MSB first, each
/// row padded to a byte boundary. `bits` is borrowed and must hold at
/// least `stride() * h` bytes.
pub const Mask = struct {
    w: usize,
    h: usize,
    bits: []const u8,

    pub fn rows(self: Mask) usize {
        return self.h / 2 + self.h % 2;
    }

    /// Bytes one row of the mask occupies, padding included.
    pub fn stride(self: Mask) usize {
        return self.w / 8 + @intFromBool(self.w % 8 != 0);
    }

    fn at(self: Mask, x: usize, y: usize) bool {
        if (y >= self.h) return false;
        return (self.bits[y * self.stride() + x / 8] >> @intCast(7 - x % 8)) & 1 == 1;
    }
};

/// Draw cell-row `row` of `bmp`. Unlike the rest of the toolkit this
/// emits its own SGRs, because the colours are data rather than
/// palette. Resets incoming attributes before drawing; transparent
/// halves use the default background. On success, attributes are reset.
/// `row` must be below `bmp.rows()`. Writer errors may leave partial output.
pub fn writeBitmapRow(w: anytype, bmp: Bitmap, row: usize) !void {
    std.debug.assert(row < bmp.rows());
    std.debug.assert(bmp.w == 0 or bmp.h <= bmp.px.len / bmp.w);
    try w.writeAll(color.reset);
    var sgr = SgrState{};
    var x: usize = 0;
    while (x < bmp.w) : (x += 1) {
        try writeCell(w, &sgr, bmp.at(x, 2 * row), bmp.at(x, 2 * row + 1));
    }
    try sgr.clear(w);
}

/// Draw cell-row `row` of `mask` in `ink`. Same contract as
/// `writeBitmapRow`: colours are reset on return.
pub fn writeMaskRow(w: anytype, mask: Mask, ink: Rgb, row: usize) !void {
    std.debug.assert(row < mask.rows());
    std.debug.assert(mask.stride() == 0 or mask.h <= mask.bits.len / mask.stride());
    try w.writeAll(color.reset);
    var sgr = SgrState{};
    var x: usize = 0;
    while (x < mask.w) : (x += 1) {
        const top: ?Rgb = if (mask.at(x, 2 * row)) ink else null;
        const bot: ?Rgb = if (mask.at(x, 2 * row + 1)) ink else null;
        try writeCell(w, &sgr, top, bot);
    }
    try sgr.clear(w);
}

/// Bytes one row can cost in the worst case, so a caller can size its
/// line buffer instead of discovering the limit as a truncated frame.
/// Worst case is a cell that changes both colours: two 19-byte
/// truecolor SGRs plus a 3-byte glyph.
pub fn maxRowBytes(cells: usize) usize {
    return cells * (19 + 19 + 3) + bg_default.len + 2 * color.reset.len;
}

/// One cell of output plus the colour state needed to skip redundant
/// SGRs. Real art is mostly flat runs and empty space, so coalescing
/// takes a typical row far below `maxRowBytes`.
fn writeCell(w: anytype, sgr: *SgrState, top: ?Rgb, bot: ?Rgb) !void {
    if (top == null and bot == null) {
        // Blank: only the background can show through a space, so the
        // foreground is left alone for the next opaque cell to reuse.
        try sgr.setBg(w, null);
        try w.writeAll(" ");
        return;
    }
    if (top) |t| {
        // A solid bottom becomes the background under an upper block;
        // an empty one falls back to the terminal's.
        try sgr.setFg(w, t);
        try sgr.setBg(w, bot);
        try w.writeAll(upper);
        return;
    }
    try sgr.setFg(w, bot.?);
    try sgr.setBg(w, null);
    try w.writeAll(lower);
}

const SgrState = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,

    fn setFg(self: *SgrState, w: anytype, c: Rgb) !void {
        if (self.fg) |cur| if (eql(cur, c)) return;
        try color.writeFg(w, c);
        self.fg = c;
    }

    fn setBg(self: *SgrState, w: anytype, c: ?Rgb) !void {
        if (c) |want| {
            if (self.bg) |cur| if (eql(cur, want)) return;
            try color.writeBg(w, want);
            self.bg = want;
            return;
        }
        if (self.bg == null) return;
        try w.writeAll(bg_default);
        self.bg = null;
    }

    fn clear(self: *SgrState, w: anytype) !void {
        try w.writeAll(color.reset);
        self.* = .{};
    }
};

fn eql(a: Rgb, b: Rgb) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

const testing = std.testing;
const cell = @import("../cell.zig");

const gold = Rgb.hex("#f5c518");
const teal = Rgb.hex("#2dd4bf");

test "a row is exactly as many cells wide as the art" {
    const bmp = Bitmap{ .w = 3, .h = 2, .px = &.{ gold, transparent, teal, transparent, teal, gold } };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 0);
    try testing.expectEqual(@as(usize, 3), cell.width(w.buffered()));
}

test "each half-lit cell picks the block that matches the lit half" {
    // Top-only, bottom-only, both, neither.
    const bmp = Bitmap{ .w = 4, .h = 2, .px = &.{
        gold,        transparent, gold, transparent,
        transparent, gold,        teal, transparent,
    } };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 0);
    const out = w.buffered();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, upper));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, lower));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, " "));
}

test "transparent subpixels use the terminal default background" {
    const bmp = Bitmap{ .w = 4, .h = 2, .px = &(.{transparent} ** 8) };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 0);
    try testing.expectEqualStrings(color.reset ++ "    " ++ color.reset, w.buffered());
}

test "a flat run emits one SGR pair, not one per cell" {
    const bmp = Bitmap{ .w = 8, .h = 2, .px = &(.{gold} ** 16) };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 0);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "\x1b[38;2;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "\x1b[48;2;"));
}

test "an odd height leaves the last row half-drawn rather than dropping it" {
    const bmp = Bitmap{ .w = 2, .h = 3, .px = &.{ gold, gold, gold, gold, gold, gold } };
    try testing.expectEqual(@as(usize, 2), bmp.rows());
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 1);
    // The absent bottom half means upper blocks over a default bg.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, w.buffered(), upper));
}

test "a mask row draws the same shape a bitmap row would" {
    // 0b1010_0000 over 0b0110_0000: four cells, matching the block
    // assertions above.
    const mask = Mask{ .w = 4, .h = 2, .bits = &.{ 0b1010_0000, 0b0110_0000 } };
    var mbuf: [256]u8 = undefined;
    var mw: std.Io.Writer = .fixed(&mbuf);
    try writeMaskRow(&mw, mask, gold, 0);

    const bmp = Bitmap{ .w = 4, .h = 2, .px = &.{
        gold,        transparent, gold, transparent,
        transparent, gold,        gold, transparent,
    } };
    var bbuf: [256]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&bbuf);
    try writeBitmapRow(&bw, bmp, 0);

    try testing.expectEqualStrings(bw.buffered(), mw.buffered());
}

test "maxRowBytes bounds what a worst-case row actually emits" {
    // Alternating colours defeat coalescing, which is the case the
    // bound exists for.
    var px: [16]?Rgb = undefined;
    for (&px, 0..) |*p, i| p.* = if (i % 2 == 0) gold else teal;
    const bmp = Bitmap{ .w = 8, .h = 2, .px = &px };
    var buf: [maxRowBytes(8)]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBitmapRow(&w, bmp, 0);
    try testing.expect(w.buffered().len <= maxRowBytes(8));
}

test "transparent rows restore an inherited foreground and background" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try color.writeBg(&w, gold);
    try color.writeFg(&w, teal);
    const start = w.buffered().len;
    try writeBitmapRow(&w, .{ .w = 1, .h = 2, .px = &.{ null, null } }, 0);
    try testing.expectEqualStrings(color.reset ++ " " ++ color.reset, w.buffered()[start..]);
    w = .fixed(&buf);
    try writeMaskRow(&w, .{ .w = 1, .h = 2, .bits = &.{ 0, 0 } }, gold, 0);
    try testing.expectEqualStrings(color.reset ++ " " ++ color.reset, w.buffered());
}
