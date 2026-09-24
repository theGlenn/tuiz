//! Drawable-area arithmetic: terminal size in, content box out.
//!
//! The framework answers "how big is my canvas, and is it big enough
//! to draw at all". What goes inside the box is the application's
//! business.

const std = @import("std");

/// Size bounds a layout needs to be usable. Below `min_cols` or
/// `min_rows` the viewport reports `too_small` and the application
/// should render a one-line apology instead of a broken frame.
pub const Limits = struct {
    /// Smallest usable terminal width; must be positive.
    min_cols: usize,
    min_rows: usize,
    /// Hard ceiling on drawable width. Very wide terminals stretch a
    /// fixed-content layout into unreadable sparseness, and every row
    /// buffer has to be sized for the widest row the layout can emit.
    /// Must be at least `min_cols - 1` (one column is reserved).
    max_cols: usize,
    /// Outer gutter, applied on both sides. Approximates the card
    /// padding of a design mock; content never touches the edge.
    /// Both gutters must fit within `min_cols - 1` cells.
    margin: usize = 0,
};

pub const Viewport = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    /// Drawable width including the gutters. 0 when `too_small`.
    inner_w: usize = 0,
    /// Drawable width between the gutters — what most rows budget
    /// against. 0 when `too_small`.
    content_w: usize = 0,
    margin: usize = 0,
    too_small: bool = false,

    pub fn fromWinsize(ws: std.posix.winsize, limits: Limits) Viewport {
        std.debug.assert(limits.min_cols > 0);
        std.debug.assert(limits.max_cols >= limits.min_cols - 1);
        std.debug.assert(limits.margin <= (limits.min_cols - 1) / 2);
        // `ws.row == 0` happens on non-tty fallbacks that only fake a
        // column count; treat it as "unknown, assume tall enough"
        // rather than refusing to draw.
        if (ws.col < limits.min_cols or (ws.row != 0 and ws.row < limits.min_rows)) {
            return .{ .cols = ws.col, .rows = ws.row, .margin = limits.margin, .too_small = true };
        }
        // Keep one spare column so the last glyph of a full-width row
        // never wraps on an exact-width terminal.
        const inner = @min(@as(usize, ws.col) - 1, limits.max_cols);
        return .{
            .cols = ws.col,
            .rows = ws.row,
            .inner_w = inner,
            .content_w = inner -| (2 * limits.margin),
            .margin = limits.margin,
        };
    }

    /// Terminal height, substituting `fallback` when the size probe
    /// reported an unknown row count.
    pub fn rowsOr(self: Viewport, fallback: usize) usize {
        return if (self.rows == 0) fallback else self.rows;
    }
};

const test_limits = Limits{ .min_cols = 56, .min_rows = 20, .max_cols = 200, .margin = 2 };

test "viewport reserves the gutters and one spare column" {
    const v = Viewport.fromWinsize(.{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 }, test_limits);
    try std.testing.expect(!v.too_small);
    try std.testing.expectEqual(@as(usize, 79), v.inner_w);
    try std.testing.expectEqual(@as(usize, 75), v.content_w);
}

test "viewport caps very wide terminals" {
    const v = Viewport.fromWinsize(.{ .col = 400, .row = 60, .xpixel = 0, .ypixel = 0 }, test_limits);
    try std.testing.expectEqual(@as(usize, 200), v.inner_w);
}

test "unknown row count is treated as tall enough" {
    const v = Viewport.fromWinsize(.{ .col = 80, .row = 0, .xpixel = 0, .ypixel = 0 }, test_limits);
    try std.testing.expect(!v.too_small);
    try std.testing.expectEqual(@as(usize, 24), v.rowsOr(24));
}

test "too small below either bound" {
    const narrow = Viewport.fromWinsize(.{ .col = 40, .row = 40, .xpixel = 0, .ypixel = 0 }, test_limits);
    try std.testing.expect(narrow.too_small);
    const short = Viewport.fromWinsize(.{ .col = 200, .row = 8, .xpixel = 0, .ypixel = 0 }, test_limits);
    try std.testing.expect(short.too_small);
}
