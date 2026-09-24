//! Row-oriented frame writer for open (borderless) TUI layouts.
//!
//! A `Canvas` owns the two things every row of such a layout shares:
//! the frame buffer it appends to, and the outer gutter + rule/label
//! colours that give the layout its rhythm. Widgets stay pure
//! functions over a writer; the canvas is what makes a *frame*.
//!
//! Rows never pad to the right edge. Each one terminates with `[K`
//! (erase to end of line) so a shorter frame wipes the previous,
//! longer one without touching scrollback — the same trick htop and
//! vim use, and the reason `finish()` ends with `[J` instead of the
//! screen-clearing `[2J`.

const std = @import("std");
const cell = @import("cell.zig");
const color = @import("color.zig");

/// Per-row scratch size. Sized for the worst case a chart row hits:
/// ~600 bytes of block glyphs at a 200-column cap, plus a truecolor
/// SGR, the reset, and a left-column prefix.
pub const scratch_len: usize = 1024;

/// Chrome colours the canvas draws with. Supplied by the consumer's
/// palette — the framework ships no design tokens of its own.
pub const Style = struct {
    /// Horizontal rules and section dividers.
    rule: []const u8 = color.reset,
    /// Section labels inside a divider.
    label: []const u8 = color.reset,
};

pub const Canvas = struct {
    out: *std.Io.Writer,
    /// Outer gutter in cells, applied by `rule` and `section` and
    /// available to callers doing absolute-column padding.
    margin: usize,
    style: Style,
    scratch: [scratch_len]u8 = undefined,

    /// `margin` cells of gutter on both sides. The gutter is spaces,
    /// so it is capped at what a small scratch line can carry.
    pub fn init(out: *std.Io.Writer, margin: usize, style: Style) Canvas {
        std.debug.assert(margin < scratch_len);
        return .{ .out = out, .margin = margin, .style = style };
    }

    /// Home the cursor without clearing. Call once per frame, before
    /// the first row.
    pub fn home(self: *Canvas) !void {
        try self.out.writeAll("\x1b[H");
    }

    /// Emit `content` verbatim as one row. Content is expected to
    /// already carry its own gutter when it needs one — hero and
    /// stats rows build a full line in their own scratch buffer and
    /// hand it over whole.
    pub fn row(self: *Canvas, content: []const u8) !void {
        try self.out.writeAll(content);
        try self.out.writeAll("\x1b[K\n");
    }

    /// Blank row — the vertical rhythm between sections.
    pub fn blank(self: *Canvas) !void {
        try self.row("");
    }

    /// Append bytes without terminating a row. For the last row of a
    /// frame, which must not end in a newline: `finish()` supplies the
    /// erase codes and leaves the cursor there, so the next frame's
    /// `home()` never scrolls the alt screen.
    pub fn writeRaw(self: *Canvas, bytes: []const u8) !void {
        try self.out.writeAll(bytes);
    }

    /// Format one row through the canvas scratch buffer.
    pub fn rowPrint(self: *Canvas, comptime fmt: []const u8, args: anytype) !void {
        var lw: std.Io.Writer = .fixed(&self.scratch);
        try lw.print(fmt, args);
        // `buffered()` borrows scratch; copy out before `row` can be
        // tempted to reuse it (it does not today, but the invariant
        // should not depend on that).
        try self.out.writeAll(lw.buffered());
        try self.out.writeAll("\x1b[K\n");
    }

    /// Full-width horizontal rule, inset by the gutter on both sides.
    pub fn rule(self: *Canvas, content_w: usize) !void {
        try self.writeGutter();
        try self.out.writeAll(self.style.rule);
        var i: usize = 0;
        while (i < content_w) : (i += 1) try self.out.writeAll("─");
        try self.out.writeAll(color.reset);
        try self.out.writeAll("\x1b[K\n");
    }

    /// Open section divider: `─ label ──────────`.
    pub fn section(self: *Canvas, label: []const u8, content_w: usize) !void {
        var lw: std.Io.Writer = .fixed(&self.scratch);
        try padWidth(&lw, self.margin);
        try lw.print("{s}─ {s}{s}{s} ", .{ self.style.rule, self.style.label, label, self.style.rule });
        const used = self.margin + 2 + cell.width(label) + 1;
        const full = self.margin + content_w;
        var pad: usize = if (used < full) full - used else 0;
        while (pad > 0) : (pad -= 1) try lw.writeAll("─");
        try lw.writeAll(color.reset);
        try self.out.writeAll(lw.buffered());
        try self.out.writeAll("\x1b[K\n");
    }

    /// Close the frame: erase everything below the cursor so a
    /// previously taller frame leaves no residue. No trailing
    /// newline — the cursor stays on the last row, so the next
    /// frame's `home()` never scrolls.
    pub fn finish(self: *Canvas) !void {
        try self.out.writeAll("\x1b[K\x1b[J");
    }

    /// The gutter prefix, for callers building their own line.
    pub fn writeGutter(self: *Canvas) !void {
        try padWidth(self.out, self.margin);
    }
};

/// Write `n` spaces. Separate from `cell.padTo` because this pads a
/// *relative* amount rather than to an absolute column.
pub fn padWidth(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(" ");
}

test "row terminates with erase-to-end-of-line" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = Canvas.init(&out, 2, .{});
    try canvas.row("hi");
    try std.testing.expectEqualStrings("hi\x1b[K\n", out.buffered());
}

test "rule spans content_w cells inside the gutter" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = Canvas.init(&out, 2, .{});
    try canvas.rule(5);
    // 2 gutter cells + 5 rule cells, escapes excluded.
    const line = out.buffered();
    try std.testing.expectEqual(@as(usize, 7), cell.width(line[0 .. line.len - "\x1b[K\n".len]));
}

test "section pads the divider out to the full content width" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = Canvas.init(&out, 2, .{});
    try canvas.section("peer · pixel", 40);
    const line = out.buffered();
    try std.testing.expectEqual(
        @as(usize, 42),
        cell.width(line[0 .. line.len - "\x1b[K\n".len]),
    );
}
