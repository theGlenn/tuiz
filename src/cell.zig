//! Cell-width accounting for colourised text.
//!
//! Everything a terminal renderer aligns (padding, right-aligned
//! chips, rules) has to measure *visible* width, not byte length —
//! SGR escapes are zero-width, UTF-8 glyphs are multi-byte, and CJK
//! and emoji occupy two cells each.
//!
//! The table below is biased toward safety rather than toward
//! accuracy. Undercounting is what overflows a row, so every range
//! that is known to be double-width is listed, while an unlisted or
//! ambiguous code point counts as one cell. Zero-width combining
//! marks are handled for the common cases; anything missed there
//! costs a cell of padding, never a wrapped line.

const std = @import("std");

/// Terminal cells one code point occupies: 0 for combining marks and
/// zero-width formatting, 2 for East Asian Wide/Fullwidth and emoji,
/// 1 otherwise.
pub fn codepointWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    if (cp < 0x300) return 1; // fast path: Latin, punctuation, digits
    if (inRanges(cp, &zero_width)) return 0;
    if (inRanges(cp, &double_width)) return 2;
    return 1;
}

const Range = struct { lo: u21, hi: u21 };

/// Sorted, non-overlapping. Binary search relies on both.
fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Combining marks and zero-width formatting characters. Not
/// exhaustive — the Unicode Mn/Me categories run to hundreds of
/// ranges — but covers what actually turns up in device names and
/// error strings. A mark missed here is counted as one cell, which
/// leaves a row one cell short of full, never over.
const zero_width = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036f }, // combining diacriticals
    .{ .lo = 0x0483, .hi = 0x0489 },
    .{ .lo = 0x0591, .hi = 0x05bd },
    .{ .lo = 0x0610, .hi = 0x061a },
    .{ .lo = 0x064b, .hi = 0x065f },
    .{ .lo = 0x0670, .hi = 0x0670 },
    .{ .lo = 0x06d6, .hi = 0x06dc },
    .{ .lo = 0x0e31, .hi = 0x0e31 },
    .{ .lo = 0x0e34, .hi = 0x0e3a },
    .{ .lo = 0x0e47, .hi = 0x0e4e },
    .{ .lo = 0x1ab0, .hi = 0x1aff },
    .{ .lo = 0x1dc0, .hi = 0x1dff },
    .{ .lo = 0x200b, .hi = 0x200f }, // ZWSP, ZWNJ, ZWJ, LRM, RLM
    .{ .lo = 0x20d0, .hi = 0x20f0 },
    .{ .lo = 0xfe00, .hi = 0xfe0f }, // variation selectors
    .{ .lo = 0xfe20, .hi = 0xfe2f },
    .{ .lo = 0xfeff, .hi = 0xfeff }, // BOM / ZWNBSP
};

/// East Asian Wide and Fullwidth, plus the emoji blocks terminals
/// render double-width. Derived from Unicode's EastAsianWidth W and F
/// classes; ranges are merged where the gaps are also wide.
const double_width = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115f }, // Hangul Jamo initial consonants
    .{ .lo = 0x2e80, .hi = 0x303e }, // CJK radicals through symbols
    .{ .lo = 0x3041, .hi = 0x33ff }, // kana, Hangul compat, CJK compat
    .{ .lo = 0x3400, .hi = 0x4dbf }, // CJK extension A
    .{ .lo = 0x4e00, .hi = 0x9fff }, // CJK unified ideographs
    .{ .lo = 0xa000, .hi = 0xa4cf }, // Yi
    .{ .lo = 0xa960, .hi = 0xa97f }, // Hangul Jamo extended-A
    .{ .lo = 0xac00, .hi = 0xd7a3 }, // Hangul syllables
    .{ .lo = 0xf900, .hi = 0xfaff }, // CJK compatibility ideographs
    .{ .lo = 0xfe10, .hi = 0xfe19 }, // vertical forms
    .{ .lo = 0xfe30, .hi = 0xfe6f }, // CJK compatibility forms
    .{ .lo = 0xff00, .hi = 0xff60 }, // fullwidth forms
    .{ .lo = 0xffe0, .hi = 0xffe6 }, // fullwidth signs
    .{ .lo = 0x1f200, .hi = 0x1f251 }, // enclosed ideographic supplement
    // Pictographs through supplemental symbols. Taken as one span
    // rather than the dozen fragments Unicode actually defines: the
    // gaps hold a handful of narrow symbols, and counting one of
    // those as two cells costs a cell of slack, while missing a wide
    // one costs a wrapped row.
    .{ .lo = 0x1f300, .hi = 0x1f9ff },
    .{ .lo = 0x1fa70, .hi = 0x1faff }, // symbols and pictographs ext-A
    .{ .lo = 0x20000, .hi = 0x2fffd }, // CJK extension B and beyond
    .{ .lo = 0x30000, .hi = 0x3fffd },
};

comptime {
    assertSorted(&zero_width);
    assertSorted(&double_width);
}

fn assertSorted(ranges: []const Range) void {
    for (ranges, 0..) |r, i| {
        std.debug.assert(r.lo <= r.hi);
        if (i > 0) std.debug.assert(ranges[i - 1].hi < r.lo);
    }
}

/// One decoded step through a string: how many bytes it consumed and
/// how many cells it occupies. Escape sequences consume bytes and
/// occupy nothing.
pub const Step = struct { bytes: usize, cells: usize };

/// One display unit from the front of `s`: an escape sequence (zero
/// cells), or a code point together with a trailing VS16 (one step of
/// two cells, never split). Public so text-wrapping callers advance by
/// the same units `width` and `truncate` measure by — a wrapper with
/// its own stepping disagrees with the clipper exactly at the widths
/// where it matters.
pub fn step(s: []const u8) Step {
    return stepAt(s, 0);
}

fn stepAt(s: []const u8, i: usize) Step {
    // CSI: ESC `[` ... <final byte in 0x40..0x7E>. Final byte is
    // typically 'm' for SGR; the range also covers cursor moves.
    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
        var j = i + 2;
        while (j < s.len) {
            const b = s[j];
            j += 1;
            if (b >= 0x40 and b <= 0x7e) break;
        }
        return .{ .bytes = j - i, .cells = 0 };
    }

    const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
        // Invalid lead byte: treat it as one opaque cell rather than
        // resynchronising, so measurement never runs off the end.
        return .{ .bytes = 1, .cells = 1 };
    };
    if (i + seq_len > s.len) return .{ .bytes = s.len - i, .cells = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
        return .{ .bytes = 1, .cells = 1 };
    };

    // Emoji presentation sequence: a base plus U+FE0F renders
    // double-width even when the base alone is narrow — `⚠️`, `❤️`,
    // `✔️` are all BMP code points outside every wide range. The pair
    // is consumed as one step so `truncate` can never split it and
    // leave a dangling selector behind.
    //
    // Only VS16 does this. U+FE0E (VS15) asks for *text* presentation
    // and stays one cell, which is why the bare forms this layout
    // draws with (`✓`, `▲`, `●`) are untouched.
    if (startsWithVs16(s[i + seq_len ..])) {
        return .{ .bytes = seq_len + vs16_len, .cells = 2 };
    }

    return .{ .bytes = seq_len, .cells = codepointWidth(cp) };
}

/// U+FE0F encoded as UTF-8.
const vs16_bytes = [_]u8{ 0xef, 0xb8, 0x8f };
const vs16_len = vs16_bytes.len;

fn startsWithVs16(rest: []const u8) bool {
    return rest.len >= vs16_len and std.mem.eql(u8, rest[0..vs16_len], &vs16_bytes);
}

/// Visible cell width of a UTF-8 string, escapes excluded.
pub fn width(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const unit = stepAt(s, i);
        i += unit.bytes;
        n += unit.cells;
    }
    return n;
}

/// Longest prefix of `s` that fits in `max_cells`, cut on a code
/// point boundary. Escape sequences are copied whole and cost
/// nothing, so a truncated span keeps whatever colour it started in
/// rather than ending mid-escape. A double-width glyph that would
/// straddle the limit is dropped rather than half-drawn.
pub fn truncate(s: []const u8, max_cells: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const unit = stepAt(s, i);
        if (n + unit.cells > max_cells) return s[0..i];
        i += unit.bytes;
        n += unit.cells;
    }
    return s;
}

/// Drop a trailing partial UTF-8 sequence, so a buffer filled to its
/// capacity never ends mid-code-point. Callers that copy into a fixed
/// buffer use this before handing the result on to be measured.
pub fn trimPartialCodepoint(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    // A sequence starts at most 4 bytes back; scan for the last lead
    // byte and drop it if its sequence is not fully present.
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        if (s[i] & 0xc0 == 0x80) continue; // continuation byte
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
        return if (i + seq_len <= s.len) s else s[0..i];
    }
    return s;
}

/// Pad `w` with spaces until its buffered content reaches `target`
/// visible cells. No-op when already at or past the target.
///
/// `w` must be a `std.Io.Writer` over a fixed buffer — `buffered()`
/// is what gets measured.
pub fn padTo(w: anytype, target: usize) !void {
    var cw = width(w.buffered());
    while (cw < target) : (cw += 1) try w.writeAll(" ");
}

test "width skips SGR escapes and counts glyphs, not bytes" {
    try std.testing.expectEqual(@as(usize, 3), width("abc"));
    try std.testing.expectEqual(@as(usize, 3), width("\x1b[38;2;1;2;3mabc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), width("█▏"));
    try std.testing.expectEqual(@as(usize, 4), width("12°C"));
}

test "East Asian and emoji glyphs count as two cells" {
    try std.testing.expectEqual(@as(usize, 2), width("字"));
    try std.testing.expectEqual(@as(usize, 6), width("模型名"));
    try std.testing.expectEqual(@as(usize, 2), width("한"));
    try std.testing.expectEqual(@as(usize, 2), width("あ"));
    try std.testing.expectEqual(@as(usize, 2), width("Ｗ")); // fullwidth latin
    try std.testing.expectEqual(@as(usize, 2), width("🚀"));
    try std.testing.expectEqual(@as(usize, 2), width("🔥"));
    // Mixed with narrow text, which is what a model name looks like:
    // `Qwen-` (5) + two wide glyphs (4) + `-8B` (3).
    try std.testing.expectEqual(@as(usize, 12), width("Qwen-字模-8B"));
}

test "the glyphs the dashboard draws with stay one cell" {
    // Geometric shapes, box drawing, and the Latin-1 symbols sit
    // below the CJK blocks — if any of them started measuring as two,
    // every bar and rule in the layout would come out short.
    for ([_][]const u8{ "✓", "▲", "●", "○", "▇", "█", "▏", "·", "—", "─", "×", "°", "≥", "«", "»", "░" }) |g| {
        try std.testing.expectEqual(@as(usize, 1), width(g));
    }
}

test "a BMP base plus VS16 is an emoji, and emoji are two cells" {
    // The bases are all outside every wide range, so without the
    // variation-selector rule these measure 1 while a terminal draws
    // 2 — and the selector itself is zero-width, so the pair would
    // slip through a fit check by exactly one column.
    try std.testing.expectEqual(@as(usize, 2), width("⚠\u{fe0f}"));
    try std.testing.expectEqual(@as(usize, 2), width("❤\u{fe0f}"));
    try std.testing.expectEqual(@as(usize, 2), width("✔\u{fe0f}"));
    // The bare forms stay narrow — VS15 asks for text presentation.
    try std.testing.expectEqual(@as(usize, 1), width("⚠"));
    try std.testing.expectEqual(@as(usize, 1), width("⚠\u{fe0e}"));
}

test "truncate keeps a variation selector with its base" {
    const s = "ab⚠\u{fe0f}cd";
    // Three cells of budget cannot hold `ab` plus a two-cell emoji.
    try std.testing.expectEqualStrings("ab", truncate(s, 3));
    try std.testing.expectEqualStrings("ab⚠\u{fe0f}", truncate(s, 4));
    // Whatever the cut, no orphaned selector is left behind.
    for (0..10) |budget| {
        const cut = truncate(s, budget);
        try std.testing.expect(width(cut) <= budget);
        try std.testing.expect(!std.mem.endsWith(u8, cut, "\u{fe0f}") or
            std.mem.endsWith(u8, cut, "⚠\u{fe0f}"));
    }
}

test "combining marks and zero-width formatting cost nothing" {
    try std.testing.expectEqual(@as(usize, 1), width("e\u{0301}")); // e + acute
    try std.testing.expectEqual(@as(usize, 0), width("\u{200b}"));
    try std.testing.expectEqual(@as(usize, 0), width("\u{feff}"));
    // VS15 asks for text presentation and stays zero-width; VS16 is
    // the one that promotes its base to a two-cell emoji, covered in
    // the emoji test above.
    try std.testing.expectEqual(@as(usize, 1), width("a\u{fe0e}"));
}

test "truncate cuts on a code point boundary, not a byte" {
    try std.testing.expectEqualStrings("ab", truncate("abcd", 2));
    try std.testing.expectEqualStrings("abcd", truncate("abcd", 9));
    try std.testing.expectEqualStrings("", truncate("abcd", 0));
    // `°` is two bytes; cutting at one cell must keep it whole.
    try std.testing.expectEqualStrings("4°", truncate("4°C", 2));
    try std.testing.expectEqual(@as(usize, 2), width(truncate("4°C", 2)));
}

test "truncate never lets a wide glyph straddle the limit" {
    // Three double-width glyphs: a four-cell budget takes two, not
    // two-and-a-half, and certainly not three.
    const s = "字字字";
    try std.testing.expectEqual(@as(usize, 4), width(truncate(s, 4)));
    try std.testing.expectEqual(@as(usize, 2), width(truncate(s, 3)));
    try std.testing.expectEqual(@as(usize, 0), width(truncate(s, 1)));
    // The cut is still on a code point boundary.
    try std.testing.expectEqualStrings("字字", truncate(s, 5));
}

test "truncate keeps escape sequences whole and free" {
    const s = "\x1b[31mabcd\x1b[0m";
    const cut = truncate(s, 2);
    try std.testing.expectEqualStrings("\x1b[31mab", cut);
    try std.testing.expectEqual(@as(usize, 2), width(cut));
}

test "truncated output always measures within its budget" {
    const samples = [_][]const u8{
        "plain ascii",
        "字字字字字",
        "mixed 字 text 🚀 more",
        "e\u{0301}\u{200b}combining",
        "\x1b[31mcoloured 字\x1b[0m",
    };
    for (samples) |s| {
        for (0..12) |budget| {
            try std.testing.expect(width(truncate(s, budget)) <= budget);
        }
    }
}

test "trimPartialCodepoint drops a sequence the buffer could not hold" {
    const full = "a字"; // 1 + 3 bytes
    try std.testing.expectEqualStrings(full, trimPartialCodepoint(full));
    try std.testing.expectEqualStrings("a", trimPartialCodepoint(full[0 .. full.len - 1]));
    try std.testing.expectEqualStrings("a", trimPartialCodepoint(full[0 .. full.len - 2]));
    try std.testing.expectEqualStrings("", trimPartialCodepoint(""));
}

test "padTo fills to the target visible width" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("\x1b[1mhi\x1b[0m");
    try padTo(&w, 5);
    try std.testing.expectEqual(@as(usize, 5), width(w.buffered()));
}
