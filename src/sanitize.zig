//! Emission of text a terminal must not interpret.
//!
//! Anything a TUI renders that it did not write itself — a device
//! name off the wire, a filename, a subprocess's stderr — is a
//! command channel unless it is filtered. A single `\x1b` in a device
//! name lets whoever supplied it move the cursor, repaint rows, set
//! the window title, or write the clipboard via OSC 52. Even without
//! malice it breaks layout: `cell.width` skips CSI sequences, so an
//! embedded escape measures as zero cells and every column downstream
//! of it lands in the wrong place.
//!
//! The rule here is deliberately blunt: bytes that a terminal parses
//! as a command become `?`. Nothing is dropped silently — a
//! substituted glyph keeps the field's width honest and shows the
//! reader that something was elided.
//!
//! Known limit: this filters *control* sequences, not confusable
//! glyphs. A name in Cyrillic homographs still reads as Latin, and
//! combining marks can still stack. Defending against those needs
//! Unicode category tables, which is a different library.

const std = @import("std");
const cell = @import("cell.zig");

/// Stand-in for one filtered byte or sequence. One cell wide, and
/// visibly not a letter.
pub const replacement = "?";

/// Write `s` with every terminal-interpreted byte replaced.
pub fn write(w: anytype, s: []const u8) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const skip = dangerousAt(s, i);
        if (skip == 0) {
            i += 1;
            continue;
        }
        if (i > run_start) try w.writeAll(s[run_start..i]);
        try w.writeAll(replacement);
        i += skip;
        run_start = i;
    }
    if (run_start < s.len) try w.writeAll(s[run_start..]);
}

/// Copy `s` into `buf`, filtered. Truncates when `buf` is too small,
/// which is the right failure for a fixed-width dashboard field.
/// Returns the filtered slice, which borrows `buf`.
///
/// A truncation that lands mid-sequence is trimmed back, so the
/// result is always decodable — otherwise a trailing partial glyph
/// would measure as one cell and render as garbage.
pub fn into(buf: []u8, s: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, s) catch {};
    return cell.trimPartialCodepoint(w.buffered());
}

/// Length in bytes of the dangerous sequence starting at `s[i]`, or 0
/// when the byte is safe to pass through.
fn dangerousAt(s: []const u8, i: usize) usize {
    const b = s[i];

    // C0 controls and DEL. This includes ESC (command introducer) but
    // also CR / LF / TAB, which would let external text forge rows and
    // columns even without an escape sequence.
    if (b < 0x20 or b == 0x7f) return 1;

    // C1 controls encoded as UTF-8 (U+0080–U+009F). Terminals that
    // decode UTF-8 before dispatching treat U+009B as a bare CSI, so
    // filtering only the C0 ESC would leave a second way in.
    if (b == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) return 2;

    // Bidi overrides and isolates (U+202A–U+202E, U+2066–U+2069).
    // Not commands, but the cheapest available way to make a name
    // render as something other than its bytes — worth the two
    // explicit ranges even though general confusable detection is out
    // of scope.
    if (b == 0xe2 and i + 2 < s.len) {
        const b1 = s[i + 1];
        const b2 = s[i + 2];
        if (b1 == 0x80 and b2 >= 0xaa and b2 <= 0xae) return 3;
        if (b1 == 0x81 and b2 >= 0xa6 and b2 <= 0xa9) return 3;
    }

    return 0;
}

test "plain text passes through untouched" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("CPH2655 / SM8750", into(&buf, "CPH2655 / SM8750"));
    try std.testing.expectEqualStrings("Bonsai-8B-Q1_0", into(&buf, "Bonsai-8B-Q1_0"));
    // Multi-byte glyphs the dashboard actually renders.
    try std.testing.expectEqualStrings("42.0°C ▇·—", into(&buf, "42.0°C ▇·—"));
}

test "an escape sequence in a device name cannot reach the terminal" {
    var buf: [64]u8 = undefined;
    const attack = "Pixel\x1b[2J\x1b[H owned";
    const safe = into(&buf, attack);
    try std.testing.expect(std.mem.indexOfScalar(u8, safe, 0x1b) == null);
    try std.testing.expectEqualStrings("Pixel?[2J?[H owned", safe);
}

test "newlines and carriage returns cannot forge rows" {
    var buf: [64]u8 = undefined;
    const safe = into(&buf, "a\nb\rc\td");
    try std.testing.expectEqualStrings("a?b?c?d", safe);
    try std.testing.expect(std.mem.indexOfScalar(u8, safe, '\n') == null);
}

test "UTF-8 encoded C1 CSI is filtered too" {
    var buf: [64]u8 = undefined;
    // U+009B is a bare CSI on terminals that decode UTF-8 first.
    try std.testing.expectEqualStrings("x?31m", into(&buf, "x\u{009b}31m"));
}

test "bidi overrides are replaced" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("gpu?nvidia", into(&buf, "gpu\u{202e}nvidia"));
    try std.testing.expectEqualStrings("a?b", into(&buf, "a\u{2066}b"));
}

test "filtered text measures one cell per replaced sequence" {
    var buf: [64]u8 = undefined;
    // Without filtering, cell.width skips the CSI and reports 5 —
    // which is exactly how injected text corrupts column alignment.
    try std.testing.expectEqual(@as(usize, 5), cell.width("Pixel\x1b[2J"));
    try std.testing.expectEqual(@as(usize, 9), cell.width(into(&buf, "Pixel\x1b[2J")));
}

test "into truncates rather than overflowing a fixed field" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", into(&buf, "abcdefgh"));
}
