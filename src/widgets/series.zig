//! A fixed-capacity ring of samples that can draw itself two ways:
//! a one-row sparkline, or a multi-row area chart.
//!
//! Storage capacity and render width are independent. A series holds
//! `capacity` samples; `chartRow` and `sparkline` render whatever
//! width the caller has, trimming to fit.
//!
//! One series is one quantity. A dashboard showing two — throughput
//! and CPU load, say — gives each its own series and its own lane,
//! because a shared vertical axis would invite a comparison between
//! values that have no common unit.

const std = @import("std");

/// `Series(120)` gives a 120-sample ring. Capacity is a comptime
/// parameter so the ring stays inline — a TUI redraws on every event
/// and should not be chasing pointers to do it.
pub fn Series(comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);

    return struct {
        const Self = @This();

        pub const cap = capacity;

        samples: [capacity]f32 = @splat(0),
        head: usize = 0,
        /// Largest sample seen so far; only ever grows. The all-time
        /// figure a "peak" readout wants. For scaling a chart, prefer
        /// `maxRecent` — a spike that has scrolled off the panel
        /// should stop flattening what is still on it.
        max: f32 = 0,
        /// Lower bound on the `sparkline` normaliser. Without it, an
        /// idle source with every sample in [0, 5] gets max=5 and each
        /// reading renders as a near-full bar. Set `floor` to a
        /// sensible "interesting range upper bound" to keep idle data
        /// visually small; once a real spike arrives, max overtakes
        /// floor and the sparkline auto-scales as before.
        floor: f32 = 1,
        /// Samples pushed so far, capped at `capacity`. Lets `avg()`
        /// run over real data instead of the zero-filled tail of a
        /// freshly reset ring.
        count: usize = 0,

        /// Store finite samples. Negative values contribute to `avg`
        /// but draw as empty bars; maxima have a lower bound of zero.
        /// NaN and infinities are dropped to keep scaling finite.
        ///
        /// A caller keeping two series in lockstep on one clock should
        /// substitute 0 rather than skip the push — 0 draws as an
        /// empty column, and skipping would slide the two out of step.
        pub fn push(self: *Self, v: f32) void {
            if (!std.math.isFinite(v)) return;
            self.samples[self.head] = v;
            self.head = (self.head + 1) % capacity;
            if (v > self.max) self.max = v;
            self.count = @min(self.count + 1, capacity);
        }

        /// Mean over the pushed samples only. 0 on an empty series.
        pub fn avg(self: *const Self) f32 {
            if (self.count == 0) return 0;
            var sum: f32 = 0;
            var j: usize = 0;
            while (j < self.count) : (j += 1) {
                sum += self.samples[self.sampleIndex(self.count, j)];
            }
            return sum / @as(f32, @floatFromInt(self.count));
        }

        /// Largest of the most recent `window` samples. This is the
        /// one to scale a chart by, passing the same width the chart
        /// draws: unlike `max` it falls again once the spike that set
        /// it has scrolled out of view, so a later, smaller run is not
        /// squashed flat by an earlier, larger one that is no longer
        /// on screen. Scanning the whole ring instead would hold the
        /// scale up for as many ticks as the ring is longer than the
        /// panel is wide.
        pub fn maxRecent(self: *const Self, window: usize) f32 {
            const n = @min(window, self.count);
            var m: f32 = 0;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const v = self.samples[self.sampleIndex(n, j)];
                if (v > m) m = v;
            }
            return m;
        }

        /// Index of the `j`th oldest sample within a window of the
        /// most recent `window` samples. The ring's oldest live
        /// sample sits `window` slots behind head.
        fn sampleIndex(self: *const Self, window: usize, j: usize) usize {
            return (self.head + capacity - window + j) % capacity;
        }

        /// One row of a multi-row area chart, exactly `width` cells.
        /// `row` 0 is the top of `rows`; `denom` is the value that
        /// reaches full height. Nonpositive or nonfinite denominators
        /// draw blank rows. For nonempty output, `row` must be < `rows`.
        ///
        /// Live-feed: the newest sample sits at the right edge and
        /// older ones scroll left, padding on the left until the ring
        /// has filled the width. Colour is the caller's job — one SGR
        /// per row, not per cell, is what keeps a full-frame redraw
        /// small.
        pub fn chartRow(
            self: *const Self,
            w: anytype,
            row: usize,
            rows: usize,
            width: usize,
            denom: f32,
        ) !void {
            if (width == 0 or rows == 0) return;
            std.debug.assert(row < rows);

            const show_n = @min(width, self.count);
            var pad_n = width - show_n;
            while (pad_n > 0) : (pad_n -= 1) try w.writeAll(" ");
            if (show_n == 0) return;

            // A non-positive denominator means "nothing to scale
            // against yet"; drawing blank beats dividing by zero.
            if (!std.math.isFinite(denom) or denom <= 0) {
                var j: usize = 0;
                while (j < show_n) : (j += 1) try w.writeAll(" ");
                return;
            }

            const rows_f: f32 = @floatFromInt(rows);
            const base: f32 = @floatFromInt(rows - 1 - row);
            var j: usize = 0;
            while (j < show_n) : (j += 1) {
                try w.writeAll(chartCell(self.samples[self.sampleIndex(show_n, j)], denom, rows_f, base));
            }
        }

        /// One-row sparkline, exactly `width` cells. Widths at or
        /// under `capacity` show the most recent `width` samples;
        /// wider ones pad on the left so the newest sample still
        /// lands on the right edge.
        pub fn sparkline(self: *const Self, w: anytype, width: usize) !void {
            if (width == 0) return;
            const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

            const show_n = @min(width, capacity);
            var pad_n = if (width > capacity) width - capacity else 0;
            while (pad_n > 0) : (pad_n -= 1) try w.writeAll(" ");

            const effective_max = @max(self.max, self.floor);
            var j: usize = 0;
            while (j < show_n) : (j += 1) {
                const v = self.samples[self.sampleIndex(show_n, j)];
                const norm = if (effective_max > 0) v / effective_max else 0;
                const slot: usize = @intFromFloat(std.math.clamp(norm, 0, 1) * 8);
                try w.writeAll(blocks[slot]);
            }
        }
    };
}

/// One cell of an area chart: `▇` when the column's level clears
/// this row, a partial ▁..▇ on the boundary, blank below.
///
/// Never a full `█`. The ⅛ gap at the top of every row is the
/// terminal's stand-in for the line-height hairlines a web mock gets
/// for free, and it is what keeps a saturated chart reading as
/// banded terrain instead of a solid wall.
fn chartCell(v: f32, denom: f32, rows_f: f32, base: f32) []const u8 {
    const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇" };
    const level = (v / denom) * rows_f;
    const d = level - base;
    if (d >= 1) return "▇";
    if (d <= 0) return " ";
    const slot: usize = @intFromFloat(@round(d * 8));
    return blocks[std.math.clamp(slot, 1, 7)];
}

test "avg ignores the unfilled tail of a fresh ring" {
    var s = Series(8){};
    s.push(10);
    s.push(20);
    try std.testing.expectEqual(@as(f32, 15), s.avg());
}

test "push drops NaN so it never reaches the normaliser" {
    var s = Series(8){};
    s.push(std.math.nan(f32));
    try std.testing.expectEqual(@as(usize, 0), s.count);
    try std.testing.expectEqual(@as(f32, 0), s.max);
}

test "maxRecent falls with the spike, max keeps it" {
    var s = Series(4){};
    s.push(99);
    for (0..4) |_| s.push(1);
    try std.testing.expectEqual(@as(f32, 1), s.maxRecent(4));
    try std.testing.expectEqual(@as(f32, 99), s.max);
}

test "maxRecent only sees the window a chart of that width would draw" {
    // A spike still in the ring but off the left of a narrow panel
    // must not go on inflating that panel's scale.
    var s = Series(16){};
    s.push(99);
    for (0..8) |_| s.push(1);
    try std.testing.expectEqual(@as(f32, 99), s.maxRecent(16));
    try std.testing.expectEqual(@as(f32, 1), s.maxRecent(4));
}

test "chartRow emits exactly width cells, blank when empty" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const s = Series(8){};
    try s.chartRow(&w, 0, 3, 6, 100);
    try std.testing.expectEqualStrings("      ", w.buffered());
}

test "chartRow pads on the left so the newest sample lands right" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = Series(8){};
    s.push(100);
    s.push(100);
    try s.chartRow(&w, 0, 1, 4, 100);
    try std.testing.expectEqualStrings("  ▇▇", w.buffered());
}

test "a zero sample draws as an empty column, not a baseline" {
    // Callers keeping two lanes on one clock push 0 for "no value
    // here"; it has to read as a gap.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = Series(8){};
    s.push(0);
    s.push(100);
    try s.chartRow(&w, 0, 1, 2, 100);
    try std.testing.expectEqualStrings(" ▇", w.buffered());
}

test "chartRow tops out at the eighth-gap block, never a full cell" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = Series(8){};
    s.push(100);
    s.push(100);
    try s.chartRow(&w, 1, 2, 2, 100);
    try std.testing.expectEqualStrings("▇▇", w.buffered());
}

test "sparkline pads on the left so the newest sample lands right" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = Series(2){ .floor = 1 };
    s.push(1);
    s.push(1);
    try s.sparkline(&w, 4);
    try std.testing.expectEqualStrings("  ██", w.buffered());
}

test "negative samples preserve statistics and draw empty bars" {
    var s = Series(4){};
    s.push(-1);
    s.push(1);
    try std.testing.expectEqual(@as(f32, 0), s.avg());
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.sparkline(&w, 2);
    try std.testing.expectEqualStrings(" █", w.buffered());
    w = .fixed(&buf);
    try s.chartRow(&w, 0, 1, 2, 1);
    try std.testing.expectEqualStrings(" ▇", w.buffered());
}

test "nonfinite samples are dropped without poisoning later samples" {
    var s = Series(4){};
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |v| s.push(v);
    try std.testing.expectEqual(@as(usize, 0), s.count);
    s.push(1);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.sparkline(&w, 1);
    try std.testing.expectEqualStrings("█", w.buffered());
}

test "invalid chart denominators produce blank rows" {
    var s = Series(4){};
    s.push(1);
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |denom| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try s.chartRow(&w, 0, 1, 2, denom);
        try std.testing.expectEqualStrings("  ", w.buffered());
    }
}
