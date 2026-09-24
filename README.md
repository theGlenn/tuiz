# tuiz

A small, dependency-free Zig toolkit for open-layout terminal
dashboards — the kind with no box borders, one accent colour, a
display-sized headline figure, and a chart behind it.

Extracted from the live dashboard of the `zzzbench` inference
benchmark, where it draws device telemetry and generation speed.

```sh
zig build run    # animated example; q quits
```

## Scope

Truecolor, a row-oriented canvas with a gutter, cell-accurate width
accounting, and the widgets a telemetry dashboard needs:

| Module | What it does |
| --- | --- |
| `color` | 24-bit RGB, comptime SGR strings, gradient ramps |
| `cell` | visible width of colourised UTF-8 (CJK and emoji count as two cells), truncation, padding to a column |
| `sanitize` | emit untrusted text without letting it drive the terminal |
| `Canvas` | frame writer: rows, rules, section dividers, gutters |
| `Viewport` | terminal size → drawable content box, with size limits |
| `terminal` | raw mode, alt screen, SIGWINCH, stdin drain |
| `Series` | sample ring → multi-row area chart or sparkline |
| `meter` | eighth-block percentage bar over a dotted track |
| `bigtext` | 3×5 block-glyph numerals for a headline figure |
| `logo` | half-block bitmap art, two pixels per cell |

The toolkit does not include an event loop, a widget tree, cell diffing,
mouse input, or grapheme-cluster segmentation (a ZWJ emoji sequence
measures as its parts). If you need those, reach for
[libvaxis](https://github.com/rockorager/libvaxis) or notcurses.

## Design

The toolkit writes bytes into a writer you supply. Your application
manages file descriptors, chooses the I/O backend, and supplies the
palette.

`terminal` exports escape sequences as `[]const u8` constants,
`Canvas` takes a `Style`, and every widget takes its colours as
arguments. Your application also runs the event loop.

## Untrusted text

Pass any string your app did not write itself through `sanitize.write`
before it reaches a row. This includes hostnames, filenames, and a
subprocess's stderr. One `\x1b` in a device name otherwise lets whoever
supplied it repaint the screen, set the window title, or write the
clipboard. It also silently breaks layout: `cell.width` skips CSI
sequences, so an embedded escape measures as zero cells and every
column after it lands wrong.

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

// Your palette. The toolkit ships none.
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

    // Chart rows: one SGR per row, not per cell. The last argument is
    // the value that reaches full height — a fixed 100 for a
    // percentage, or `cpu.maxRecent(width)` to auto-scale to whatever
    // is currently on screen.
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
complete program: raw mode, alt screen, resize handling, a poll-based
loop, and every widget above.

## Testing

```sh
zig build test
```

Every module carries its own unit tests; the example adds a test that
each frame fits the viewport it was drawn for.

## License

Apache-2.0. See [LICENSE](LICENSE).
