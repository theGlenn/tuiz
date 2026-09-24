//! A live telemetry dashboard over a synthetic signal: a headline
//! figure, a meter, an area chart, and a sparkline.
//!
//!     zig build run
//!
//! `q` or Ctrl-C quits. With stdout redirected it renders one 80×24
//! frame and exits, which is how CI smoke-tests it.
//!
//! Everything the toolkit deliberately leaves to the application
//! lives here: the palette, the tty writes, and the event loop.

const std = @import("std");
const tuiz = @import("tuiz");

// The palette. The toolkit ships none.
const accent = tuiz.color.fg("#f5c518");
const muted = tuiz.color.fg("#5f7f86");
const rule_color = tuiz.color.fg("#14343a");
const label_color = tuiz.color.fg("#9fb8bd");
const meter_fill = tuiz.Rgb.hex("#2dd4bf");
const heat = tuiz.Ramp{ .stops = &.{
    tuiz.Rgb.hex("#2dd4bf"),
    tuiz.Rgb.hex("#f5c518"),
    tuiz.Rgb.hex("#ef4444"),
} };

const limits = tuiz.Limits{ .min_cols = 48, .min_rows = 22, .max_cols = 160, .margin = 2 };
const chart_rows = 8;

/// Text the application did not write. A name read off the wire can
/// carry escapes; this one tries to clear the screen, and
/// `sanitize.write` turns the attempt into `?`.
const untrusted_source = "sensor-01\x1b[2J";

const Load = tuiz.Series(256);

const State = struct {
    load: Load = .{},
    prng: std.Random.DefaultPrng = .init(0x7475_697a),
    t: f32 = 0,
    latest: f32 = 0,

    fn tick(self: *State) void {
        self.t += 1;
        const wave = 50 + 30 * @sin(self.t / 15);
        const noise = (self.prng.random().float(f32) - 0.5) * 20;
        self.latest = std.math.clamp(wave + noise, 0, 100);
        self.load.push(self.latest);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    var state: State = .{};
    var frame: [64 * 1024]u8 = undefined;

    if (std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
        for (0..160) |_| state.tick();
        var out: std.Io.Writer = .fixed(&frame);
        try draw(&out, &state, .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 });
        try out.writeAll(tuiz.color.reset ++ "\n");
        return stdout.writeStreamingAll(io, out.buffered());
    }

    var raw = tuiz.RawTty.enable();
    defer raw.disable();
    try stdout.writeStreamingAll(io, tuiz.terminal.enter_alt_screen);
    defer stdout.writeStreamingAll(io, tuiz.terminal.leave_alt_screen) catch {};
    tuiz.terminal.watchResize();
    tuiz.terminal.drainStdin();

    while (true) {
        if (tuiz.terminal.takeResize()) {
            try stdout.writeStreamingAll(io, tuiz.terminal.home_and_clear_below);
        }
        state.tick();
        const ws = tuiz.terminal.size() orelse return;
        var out: std.Io.Writer = .fixed(&frame);
        try draw(&out, &state, ws);
        try stdout.writeStreamingAll(io, out.buffered());
        if (quitPressed(100)) return;
    }
}

/// Wait up to `timeout_ms` for input; true on `q` or Ctrl-C.
fn quitPressed(timeout_ms: i32) bool {
    var pfd = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, timeout_ms) catch return false;
    if (ready == 0) return false;
    if (pfd[0].revents & std.posix.POLL.IN == 0) return true;
    var keys: [32]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &keys) catch return true;
    if (n == 0) return true;
    for (keys[0..n]) |key| {
        if (key == 'q' or key == 0x03) return true;
    }
    return false;
}

fn draw(out: *std.Io.Writer, state: *const State, ws: std.posix.winsize) !void {
    const view = tuiz.Viewport.fromWinsize(ws, limits);
    var canvas = tuiz.Canvas.init(out, view.margin, .{ .rule = rule_color, .label = label_color });
    try canvas.home();
    if (view.too_small) {
        try canvas.writeRaw("terminal too small");
        return canvas.finish();
    }

    try canvas.blank();
    try drawTitle(&canvas, view);
    try canvas.section("load", view.content_w);
    try drawHeadline(&canvas, state, view);
    try canvas.section("history", view.content_w);
    try drawChart(&canvas, state, view);
    try canvas.section("trend", view.content_w);
    try drawSparkline(&canvas, state, view);
    try canvas.rowPrint("{s}{s}q quits{s}", .{ gutter(view), muted, tuiz.color.reset });
    try canvas.finish();
}

fn drawTitle(canvas: *tuiz.Canvas, view: tuiz.Viewport) !void {
    var line: [tuiz.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try tuiz.padWidth(&lw, view.margin);
    try lw.print("{s}{s}tuiz{s}{s}  dashboard · source ", .{
        tuiz.color.bold, accent, tuiz.color.reset, muted,
    });
    try tuiz.sanitize.write(&lw, untrusted_source);
    try emit(canvas, lw.buffered(), view);
}

fn drawHeadline(canvas: *tuiz.Canvas, state: *const State, view: tuiz.Viewport) !void {
    var figure_buf: [16]u8 = undefined;
    const figure = try std.fmt.bufPrint(&figure_buf, "{d:.1}", .{state.latest});

    var r: usize = 0;
    while (r < tuiz.bigtext.rows) : (r += 1) {
        var line: [tuiz.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line);
        try tuiz.padWidth(&lw, view.margin);
        try lw.writeAll(accent);
        try tuiz.bigtext.writeRow(&lw, figure, r, 1);
        try emit(canvas, lw.buffered(), view);
    }

    var line: [tuiz.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try tuiz.padWidth(&lw, view.margin);
    const pct: u32 = @intFromFloat(@round(state.latest));
    try tuiz.meter.write(&lw, pct, meter_fill, .{ .sgr = rule_color });
    // `meter.write` leaves the colour reset.
    try lw.print(" {d:>3}%   {s}avg {d:.1}   peak {d:.1}", .{
        pct, muted, state.load.avg(), state.load.max,
    });
    try emit(canvas, lw.buffered(), view);
}

fn drawChart(canvas: *tuiz.Canvas, state: *const State, view: tuiz.Viewport) !void {
    var r: usize = 0;
    while (r < chart_rows) : (r += 1) {
        var line: [tuiz.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line);
        try tuiz.padWidth(&lw, view.margin);
        // One SGR per row: the top of the chart is the hot end.
        const t = 1.0 - @as(f32, @floatFromInt(r)) / (chart_rows - 1);
        try tuiz.color.writeFg(&lw, heat.at(t));
        try state.load.chartRow(&lw, r, chart_rows, view.content_w, 100);
        try emit(canvas, lw.buffered(), view);
    }
}

fn drawSparkline(canvas: *tuiz.Canvas, state: *const State, view: tuiz.Viewport) !void {
    var line: [tuiz.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line);
    try tuiz.padWidth(&lw, view.margin);
    try lw.writeAll(accent);
    try state.load.sparkline(&lw, @min(view.content_w, Load.cap));
    try emit(canvas, lw.buffered(), view);
}

/// Clip a composed line to the drawable width, then reset colour so a
/// cut-off SGR cannot bleed into the next row.
fn emit(canvas: *tuiz.Canvas, line: []const u8, view: tuiz.Viewport) !void {
    try canvas.writeRaw(tuiz.cell.truncate(line, view.inner_w));
    try canvas.row(tuiz.color.reset);
}

fn gutter(view: tuiz.Viewport) []const u8 {
    const spaces = " " ** 16;
    return spaces[0..@min(view.margin, spaces.len)];
}

test "a frame fits the viewport it was drawn for" {
    var state: State = .{};
    for (0..300) |_| state.tick();
    var buf: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(&out, &state, .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 });

    var rows = std.mem.splitScalar(u8, out.buffered(), '\n');
    var n: usize = 0;
    while (rows.next()) |row| : (n += 1) {
        try std.testing.expect(tuiz.cell.width(row) < 80);
    }
    try std.testing.expect(n <= 24);
}

test "untrusted text cannot clear the screen" {
    var state: State = .{};
    state.tick();
    var buf: [64 * 1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(&out, &state, .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\x1b[2J") == null);
}
