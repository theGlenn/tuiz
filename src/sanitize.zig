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

/// Write valid UTF-8, replacing controls, bidi overrides/isolates, and
/// each malformed input byte with `?`. Valid multibyte text is preserved.
pub fn write(w: anytype, s: []const u8) !void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const cp = if (len != 0 and len <= s.len - i)
            std.unicode.utf8Decode(s[i..][0..len]) catch null
        else
            null;
        const consumed: usize = if (cp != null) len else 1;
        if (cp != null and !dangerous(cp.?)) {
            i += consumed;
            continue;
        }
        if (i > run_start) try w.writeAll(s[run_start..i]);
        try w.writeAll(replacement);
        i += consumed;
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

fn dangerous(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
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

test "malformed UTF-8 and raw C1 bytes are replaced" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a?b?2J", into(&buf, "a\xffb\x9b2J"));
    for ([_][]const u8{ "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x80" }) |s| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(into(&buf, s)));
    }
    // 0x9b is safe inside a valid multibyte character (U+00DB).
    try std.testing.expectEqualStrings("Û字🚀", into(&buf, "Û字🚀"));
}

test "arbitrary bytes remain safe and decodable at every buffer boundary" {
    var random: std.Random.DefaultPrng = .init(0x7475697a);
    var input: [32]u8 = undefined;
    var buf: [32]u8 = undefined;
    for (0..256) |_| {
        random.random().bytes(&input);
        for (0..buf.len + 1) |size| {
            const safe = into(buf[0..size], &input);
            var it = (try std.unicode.Utf8View.init(safe)).iterator();
            while (it.nextCodepoint()) |cp| {
                try std.testing.expect(cp >= 0x20 and !(cp >= 0x7f and cp <= 0x9f));
                try std.testing.expect(!(cp >= 0x202a and cp <= 0x202e));
                try std.testing.expect(!(cp >= 0x2066 and cp <= 0x2069));
            }
        }
    }
}

test "truncation never splits a valid multibyte character" {
    const s = "A字🚀e\u{0301}\x1b!";
    var buf: [64]u8 = undefined;
    for (0..s.len + 1) |size| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(into(buf[0..size], s)));
    }
}
