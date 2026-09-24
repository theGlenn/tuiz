# tuiz

A small, dependency-free Zig toolkit for terminal dashboards with
open layouts, large headline figures, charts, and meters.

![ARGO-7 ascent telemetry drawn with tuiz: a mission patch, altitude
in block numerals, a velocity area chart, engine and propellant
meters, and a downlink log](assets/demo.png)

```sh
zig build demo    # flight demo shown above; space pauses, q quits
zig build run     # simpler dashboard example; q quits
```

## Scope

Supports 24-bit colour, draws one row at a time, and
measures text in terminal cells to keep columns aligned.

| Module | What it does |
| --- | --- |
| `color` | 24-bit RGB, compile-time colour escape sequences, gradient ramps |
| `cell` | visible width of colourised UTF-8 (Chinese, Japanese, Korean characters and emoji count as two cells), truncation, padding to a column |
| `sanitize` | replace control characters in untrusted text before printing it |
| `Canvas` | frame writer: rows, rules, section dividers, gutters |
| `Viewport` | terminal size → drawable content box, with size limits |
| `terminal` | raw mode, alternate screen, resize signals, input draining |
| `Series` | ring buffer of samples rendered as an area chart or sparkline |
| `meter` | eighth-block percentage bar over a dotted track |
| `bigtext` | 3×5 block-glyph numerals for a headline figure |
| `logo` | half-block bitmap art, two pixels per cell |

Does not include:

- an event loop
- a widget tree
- cell diffing
- mouse input
- grapheme-cluster segmentation (emoji joined with a
zero-width joiner are measured as separate parts).

If you need those, reach for [libvaxis](https://github.com/rockorager/libvaxis) or notcurses.

## Design

The toolkit writes bytes into a writer you supply. Your application
manages file descriptors, chooses the I/O backend, supplies the
palette, and runs the event loop.

`terminal` exports escape sequences as `[]const u8` constants,
`Canvas` takes a `Style`, and every widget takes its colours as
arguments.

## Untrusted text

Pass any string your app did not write itself through `sanitize.write`
before it reaches a row. This includes hostnames, filenames, and a
subprocess's stderr. Escape sequences beginning with `\x1b` can repaint
the screen, set the window title, or write to the clipboard. They can
also break layout: `cell.width` ignores terminal control sequences
that begin with `\x1b[`, even when those commands move the cursor or
clear the screen.

```zig
try lw.print(" {s}", .{label_color});
try tuiz.sanitize.write(&lw, device_name);   // not print("{s}", .{…})
```

## Install

Requires Zig 0.16.0.

```sh
zig fetch --save git+https://github.com/theGlenn/tuiz
```

```zig
// build.zig
const tuiz = b.dependency("tuiz", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "dashboard",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Only `terminal` needs libc (isatty, tcgetattr, the
        // TIOCGWINSZ ioctl). Rendering into a buffer does not.
        .link_libc = true,
        .imports = &.{.{ .name = "tuiz", .module = tuiz.module("tuiz") }},
    }),
});
```

## Usage

```zig
const std = @import("std");
const tuiz = @import("tuiz");

// Define the dashboard's colours.
const rule_color = tuiz.color.fg("#14343a");
const accent = tuiz.color.fg("#f5c518");
const heat = tuiz.Ramp{ .stops = &.{
    tuiz.Rgb.hex("#2dd4bf"),
    tuiz.Rgb.hex("#ef4444"),
} };

const Series = tuiz.Series(120);

pub fn drawFrame(out: *std.Io.Writer, cpu: *const Series, ws: std.posix.winsize) !void {
    const view = tuiz.Viewport.fromWinsize(ws, .{
        .min_cols = 56,
        .min_rows = 20,
        .max_cols = 200,
        .margin = 2,
    });
    var canvas = tuiz.Canvas.init(out, view.margin, .{ .rule = rule_color });

    try canvas.home();
    if (view.too_small) {
        try canvas.writeRaw("terminal too small");
        return canvas.finish();
    }

    try canvas.rowPrint("  {s}dashboard", .{accent});
    try canvas.rule(view.content_w);

    // Set one colour per chart row. The last chartRow argument is
    // the value that reaches full height: 100 for a percentage, or
    // `cpu.maxRecent(view.content_w)` to scale to the visible samples.
    const rows = 8;
    for (0..rows) |r| {
        var line: [tuiz.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line);
        try tuiz.color.writeFg(&lw, heat.at(1.0 - @as(f32, @floatFromInt(r)) / (rows - 1)));
        try cpu.chartRow(&lw, r, rows, view.content_w, 100);
        try canvas.row(lw.buffered());
    }

    try canvas.finish();
}
```

Then push `out.buffered()` to the terminal using your chosen I/O backend.
[`examples/dashboard.zig`](examples/dashboard.zig) is a
complete program: raw mode, alternate screen, resize handling, a poll-based
loop, and every widget above.

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-terminal                         # Python 3; Linux/macOS PTY tests
zig build --build-file tests/consumer/build.zig  # downstream import without libc
python3 tools/generate_widths.py --check
```

Wide-character tables use pinned Unicode 17 data. Regenerate them with
`python3 tools/generate_widths.py`; normal builds need only Zig.
Ambiguous characters count as one cell, so terminals with a different
width policy can disagree.

`Series` stores finite samples and drops NaN and infinities. Negative
values contribute to averages and draw as empty bars. Logo rows reset
incoming attributes and use the terminal's default background for
transparent pixels.

## License

Apache-2.0. See [LICENSE](LICENSE).
