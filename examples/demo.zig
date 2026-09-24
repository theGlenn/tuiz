//! ARGO-7 ascent telemetry — the tuiz showcase.
//!
//!     zig build demo                  # live at 10x speed; space pauses, q quits
//!     zig build demo -- --at 134      # held at T+02:14, the README screenshot
//!
//! Every module in the toolkit has a job here: `logo` draws the
//! mission patch, `bigtext` the altitude, `Series` the velocity chart
//! and the downlink sparkline, `meter` the engines and propellant,
//! `cell` keeps the Japanese station names in their columns, and
//! `sanitize` defuses the relay message that tries to clear the
//! screen.
//!
//! The flight is a closed-form function of mission time rather than an
//! integration, so `--at` lands on the same frame every run. The
//! vehicle, the numbers, and the mission are illustrative.

const std = @import("std");
const tuiz = @import("tuiz");

// ── palette ─────────────────────────────────────────────────────────
// The toolkit ships none; this is the application's.

const white = tuiz.color.fg("#e6edf3");
const accent = tuiz.color.fg("#f5c518");
const muted = tuiz.color.fg("#5f7f86");
const label_color = tuiz.color.fg("#9fb8bd");
const rule_color = tuiz.color.fg("#1f4a52");
const live_color = tuiz.color.fg("#ef4444");
const teal = tuiz.Rgb.hex("#2dd4bf");
const amber = tuiz.Rgb.hex("#f5c518");
const red = tuiz.Rgb.hex("#ef4444");
const heat = tuiz.Ramp{ .stops = &.{ teal, amber, red } };
const track: tuiz.meter.Track = .{ .sgr = rule_color };

const limits = tuiz.Limits{ .min_cols = 80, .min_rows = 28, .max_cols = 120, .margin = 2 };
const chart_rows = 8;
const log_rows = 4;
/// Column the headline's stats start at, counted from the gutter.
const stats_col = 44;
const snapshot_size: std.posix.winsize = .{ .col = 100, .row = 32, .xpixel = 0, .ypixel = 0 };
const default_snapshot_t = 134;

// ── mission patch ───────────────────────────────────────────────────

/// A 10×10 patch, five terminal rows tall — the same height as the
/// altitude numerals beside it.
const patch = paint(&.{
    "...gggg...",
    ".ggnwwngg.",
    ".gsnwwnng.",
    "gnnnwwnnsg",
    "gnnnwwnnng",
    "gnnwwwwnng",
    "gnnwrrwnng",
    ".gnnoonng.",
    ".ggnnnngg.",
    "...gggg...",
});

const navy = tuiz.Rgb.hex("#1d3557");
const ivory = tuiz.Rgb.hex("#e6edf3");
const star = tuiz.Rgb.hex("#9fb8bd");
const flame = tuiz.Rgb.hex("#f59e0b");

fn swatch(comptime c: u8) ?tuiz.Rgb {
    return switch (c) {
        '.' => tuiz.logo.transparent,
        'g' => amber,
        'n' => navy,
        'w' => ivory,
        's' => star,
        'r' => red,
        'o' => flame,
        else => @compileError("unknown swatch '" ++ [_]u8{c} ++ "'"),
    };
}

/// Art as rows of swatch letters, converted at compile time.
fn paint(comptime rows: []const []const u8) tuiz.logo.Bitmap {
    const w = rows[0].len;
    const art = struct {
        const px = blk: {
            @setEvalBranchQuota(10 * w * rows.len + 1000);
            var out: [w * rows.len]?tuiz.Rgb = undefined;
            for (rows, 0..) |row, y| {
                if (row.len != w) @compileError("ragged art row");
                for (row, 0..) |c, x| out[y * w + x] = swatch(c);
            }
            break :blk out;
        };
    };
    return .{ .w = w, .h = rows.len, .px = &art.px };
}

// ── flight model ────────────────────────────────────────────────────

const meco = 152;
const separation = 155;
const ses = 158;
const seco = 520;

const Milestone = struct { t: u32, name: []const u8 };

const milestones = [_]Milestone{
    .{ .t = 72, .name = "max-Q" },
    .{ .t = meco, .name = "MECO" },
    .{ .t = separation, .name = "separation" },
    .{ .t = ses, .name = "S2 ignition" },
    .{ .t = 190, .name = "fairing sep" },
    .{ .t = seco, .name = "SECO" },
};

/// A downlink message. `station` and `text` arrive over the relay, so
/// the renderer treats both as untrusted.
const Event = struct { t: u32, station: []const u8, text: []const u8 };

const events = [_]Event{
    .{ .t = 0, .station = "種子島", .text = "liftoff" },
    .{ .t = 11, .station = "種子島", .text = "tower clear · pitch program" },
    .{ .t = 72, .station = "種子島", .text = "max-Q · 32.1 kPa" },
    // A relay that tries to wipe the screen. It renders as `?[2J`.
    .{ .t = 96, .station = "小笠原", .text = "handover ack\x1b[2J" },
    .{ .t = meco, .station = "小笠原", .text = "MECO" },
    .{ .t = separation, .station = "小笠原", .text = "stage separation confirmed" },
    .{ .t = ses, .station = "小笠原", .text = "second-stage ignition" },
    .{ .t = 190, .station = "小笠原", .text = "fairing jettison" },
    .{ .t = 310, .station = "Kiritimati", .text = "AOS · downlink nominal" },
    .{ .t = seco, .station = "Kiritimati", .text = "SECO" },
    .{ .t = 528, .station = "Santiago", .text = "orbit 198 × 212 km · 51.6°" },
};

fn pow(x: f32, e: f32) f32 {
    return std.math.pow(f32, @max(x, 0), e);
}

fn unit(t: f32, from: f32, to: f32) f32 {
    return std.math.clamp((t - from) / (to - from), 0, 1);
}

/// m/s
fn velocity(t: f32) f32 {
    if (t <= meco) return 2300 * pow(t / meco, 2.1);
    if (t <= ses) return 2300 - (t - meco) * 4;
    return 2276 + (7650 - 2276) * pow(unit(t, ses, seco), 1.6);
}

/// km
fn altitude(t: f32) f32 {
    if (t <= meco) return 70 * pow(t / meco, 1.7);
    const u = unit(t, meco, seco);
    return 70 + 135 * (1 - (1 - u) * (1 - u));
}

/// km
fn downrange(t: f32) f32 {
    return 1100 * pow(unit(t, 0, seco), 2.2);
}

/// kPa, peaking at max-Q.
fn dynamicPressure(t: f32) f32 {
    const z = (t - 72) / 30;
    return 32.1 * @exp(-z * z);
}

/// Percent. Three first-stage engines throttle down through max-Q;
/// engine 3 is the second stage's.
fn throttle(t: u32, engine: u32) u32 {
    const tf: f32 = @floatFromInt(t);
    if (engine == 3) {
        if (t < ses or t >= seco) return 0;
        return @intFromFloat(100 * unit(tf, ses, ses + 3));
    }
    if (t >= meco) return 0;
    const z = (tf - 68) / 10;
    const bucket = 28 * @exp(-z * z);
    const pct = 99 - bucket + 1.5 * jitter(t, engine);
    return @intFromFloat(std.math.clamp(pct, 0, 100));
}

/// Fraction of the current stage's propellant left; LOX drains a
/// little faster than fuel.
fn propellant(t: u32, oxidiser: bool) f32 {
    const tf: f32 = @floatFromInt(t);
    const burn: f32 = if (oxidiser) 0.97 else 0.95;
    if (t < separation) return 1 - burn * unit(tf, 0, meco);
    return 1 - burn * unit(tf, ses, seco);
}

/// Link quality in percent, with a fade at each station handover.
fn signal(t: u32) f32 {
    const tf: f32 = @floatFromInt(t);
    var q = 82 + 8 * @sin(tf / 9) + 5 * jitter(t, 7);
    for ([_]f32{ 96, 310, 528 }) |handover| {
        if (@abs(tf - handover) < 4) q -= 45 * (1 - @abs(tf - handover) / 4);
    }
    return std.math.clamp(q, 3, 100);
}

/// Deterministic noise in [-1, 1].
fn jitter(t: u32, salt: u32) f32 {
    var h = t *% 0x9e3779b1 +% salt *% 0x85ebca77;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    return @as(f32, @floatFromInt(h & 0xffff)) / 32767.5 - 1;
}

const History = tuiz.Series(512);

const Flight = struct {
    t: u32 = 0,
    velocity: History = .{},
    signal: History = .{},

    fn at(t: u32) Flight {
        var f: Flight = .{};
        f.record();
        // Requests beyond the illustrative flight hold at its final frame.
        const end = @min(t, seco + 30);
        while (f.t < end) f.advance();
        return f;
    }

    fn advance(self: *Flight) void {
        if (self.t >= seco + 30) return;
        self.t += 1;
        self.record();
    }

    fn record(self: *Flight) void {
        self.velocity.push(velocity(self.seconds()));
        self.signal.push(signal(self.t));
    }

    fn seconds(self: *const Flight) f32 {
        return @floatFromInt(self.t);
    }

    fn stage(self: *const Flight) []const u8 {
        if (self.t < meco) return "stage 1";
        if (self.t < ses) return "coast";
        if (self.t < seco) return "stage 2";
        return "orbit";
    }

    fn station(self: *const Flight) []const u8 {
        var name: []const u8 = events[0].station;
        for (events) |e| {
            if (e.t <= self.t) name = e.station;
        }
        return name;
    }

    fn nextMilestone(self: *const Flight) ?Milestone {
        for (milestones) |m| {
            if (m.t > self.t) return m;
        }
        return null;
    }
};

// ── event loop ──────────────────────────────────────────────────────

const Options = struct {
    /// Hold the flight at this mission time instead of flying it.
    at: ?u32 = null,
};

fn parseOptions(args: std.process.Args) !Options {
    var it = args.iterate();
    _ = it.next();
    var opts: Options = .{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--at")) {
            const value = it.next() orelse return error.MissingValue;
            opts.at = try std.fmt.parseInt(u32, value, 10);
        } else return error.UnknownArgument;
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const opts = parseOptions(init.minimal.args) catch {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: demo [--at <mission seconds>]\n");
        std.process.exit(2);
    };
    var frame: [64 * 1024]u8 = undefined;

    if (std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
        const flight = Flight.at(opts.at orelse default_snapshot_t);
        var out: std.Io.Writer = .fixed(&frame);
        try draw(&out, &flight, snapshot_size, false);
        try out.writeAll(tuiz.color.reset ++ "\n");
        return stdout.writeStreamingAll(io, out.buffered());
    }

    var raw = tuiz.RawTty.enable();
    defer raw.disable();
    try stdout.writeStreamingAll(io, tuiz.terminal.enter_alt_screen);
    defer stdout.writeStreamingAll(io, tuiz.terminal.leave_alt_screen) catch {};
    tuiz.terminal.watchResize();
    tuiz.terminal.drainStdin();

    var flight = Flight.at(opts.at orelse 0);
    var paused = false;
    while (true) {
        if (tuiz.terminal.takeResize()) {
            try stdout.writeStreamingAll(io, tuiz.terminal.home_and_clear_below);
        }
        const ws = tuiz.terminal.size() orelse return;
        var out: std.Io.Writer = .fixed(&frame);
        try draw(&out, &flight, ws, paused);
        try stdout.writeStreamingAll(io, out.buffered());

        switch (readKey(100)) {
            .quit => return,
            .pause => paused = !paused,
            .none => {},
        }
        if (!paused and opts.at == null) flight.advance();
    }
}

const Key = enum { none, pause, quit };

/// Wait up to `timeout_ms` for a key.
fn readKey(timeout_ms: i32) Key {
    var pfd = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, timeout_ms) catch return .none;
    if (ready == 0) return .none;
    if (pfd[0].revents & std.posix.POLL.IN == 0) return .quit;
    var keys: [32]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &keys) catch return .quit;
    if (n == 0) return .quit;
    for (keys[0..n]) |key| switch (key) {
        'q', 0x03 => return .quit,
        ' ' => return .pause,
        else => {},
    };
    return .none;
}

// ── frame ───────────────────────────────────────────────────────────

const Line = struct {
    buf: [tuiz.scratch_len]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn start(self: *Line, view: tuiz.Viewport) !*std.Io.Writer {
        self.w = .fixed(&self.buf);
        try tuiz.padWidth(&self.w, view.margin);
        return &self.w;
    }
};

fn draw(out: *std.Io.Writer, flight: *const Flight, ws: std.posix.winsize, paused: bool) !void {
    const view = tuiz.Viewport.fromWinsize(ws, limits);
    var canvas = tuiz.Canvas.init(out, view.margin, .{ .rule = rule_color, .label = label_color });
    try canvas.home();
    if (view.too_small) {
        try canvas.writeRaw("terminal too small — 80×28 or larger");
        return canvas.finish();
    }

    // Spare rows become breathing room between sections; a terminal
    // at the minimum height gets the dense layout.
    const airy = view.rowsOr(limits.min_rows) >= limits.min_rows + 4;

    try canvas.blank();
    try drawHeader(&canvas, flight, view, paused);
    if (airy) try canvas.blank();
    try canvas.section("altitude", view.content_w);
    try drawHeadline(&canvas, flight, view);
    if (airy) try canvas.blank();
    try drawChart(&canvas, flight, view);
    if (airy) try canvas.blank();
    try canvas.section("propulsion", view.content_w);
    try drawEngines(&canvas, flight, view);
    try drawPropellant(&canvas, flight, view);
    if (airy) try canvas.blank();
    try canvas.section("downlink", view.content_w);
    try drawLog(&canvas, flight, view);
    try drawSignal(&canvas, flight, view);
    try canvas.blank();
    try drawFooter(&canvas, view);
    try canvas.finish();
}

fn drawHeader(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport, paused: bool) !void {
    var line: Line = .{};
    const lw = try line.start(view);
    try lw.print("{s}{s}tuiz{s}  {s}ARGO-7 ascent telemetry", .{
        tuiz.color.bold, accent, tuiz.color.reset, white,
    });

    // Right-aligned chip. The station name is CJK — two cells a glyph
    // — so only a width that counts cells lands it on the edge.
    var chip_buf: [128]u8 = undefined;
    var chip: std.Io.Writer = .fixed(&chip_buf);
    try chip.print("{s}GS ", .{muted});
    try tuiz.sanitize.write(&chip, flight.station());
    if (paused) {
        try chip.print("  {s}‖ PAUSED", .{label_color});
    } else {
        try chip.print("  {s}● LIVE", .{live_color});
    }
    try tuiz.cell.padTo(lw, view.margin + view.content_w -| tuiz.cell.width(chip.buffered()));
    try lw.writeAll(chip.buffered());
    try emit(canvas, lw.buffered(), view);
}

fn drawHeadline(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    var alt_buf: [16]u8 = undefined;
    const alt = try altitudeText(&alt_buf, flight.seconds());

    var r: usize = 0;
    while (r < tuiz.bigtext.rows) : (r += 1) {
        var line: Line = .{};
        const lw = try line.start(view);
        try tuiz.logo.writeBitmapRow(lw, patch, r);
        try lw.writeAll("   ");
        try lw.writeAll(accent);
        try tuiz.bigtext.writeRow(lw, alt, r, 1);
        if (r == tuiz.bigtext.rows - 1) try lw.print(" {s}km", .{muted});
        try lw.writeAll(tuiz.color.reset);
        try tuiz.cell.padTo(lw, view.margin + stats_col);
        try writeStat(lw, flight, r);
        try emit(canvas, lw.buffered(), view);
    }
}

/// Altitude for the numerals. Past 100 km the decimal goes, so the
/// figure never grows wider than `dd.d` and never pushes into the
/// stats column.
fn altitudeText(buf: []u8, t: f32) ![]const u8 {
    const km = altitude(t);
    if (km < 100) return std.fmt.bufPrint(buf, "{d:.1}", .{km});
    return std.fmt.bufPrint(buf, "{d:.0}", .{km});
}

fn writeStat(lw: *std.Io.Writer, flight: *const Flight, row: usize) !void {
    const t = flight.seconds();
    switch (row) {
        0 => {
            try lw.print("{s}{s}T+ ", .{ tuiz.color.bold, white });
            try writeClock(lw, flight.t);
            try lw.print("{s}   {s}{s}", .{ tuiz.color.reset, muted, flight.stage() });
        },
        1 => {
            try lw.print("{s}velocity   {s}", .{ muted, white });
            try writeGrouped(lw, @intFromFloat(velocity(t)));
            try lw.print(" {s}m/s", .{muted});
        },
        2 => try lw.print("{s}downrange  {s}{d:.0} {s}km", .{ muted, white, downrange(t), muted }),
        3 => try lw.print("{s}dyn. press {s}{d:.1} {s}kPa", .{ muted, white, dynamicPressure(t), muted }),
        4 => if (flight.nextMilestone()) |m| {
            try lw.print("{s}next       {s}{s}{s} in ", .{ muted, accent, m.name, muted });
            try writeClock(lw, m.t - flight.t);
        } else {
            try lw.print("{s}next       {s}nominal orbit", .{ muted, accent });
        },
        else => unreachable,
    }
}

fn drawChart(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    // Scale to what is on screen, with headroom, so the curve fills
    // the panel at every stage of the flight.
    const top = @max(flight.velocity.maxRecent(view.content_w) * 1.1, 1);
    var label_buf: [48]u8 = undefined;
    var label: std.Io.Writer = .fixed(&label_buf);
    try label.writeAll("velocity · 0–");
    try writeGrouped(&label, @intFromFloat(top));
    try label.writeAll(" m/s");
    try canvas.section(label.buffered(), view.content_w);

    var r: usize = 0;
    while (r < chart_rows) : (r += 1) {
        var line: Line = .{};
        const lw = try line.start(view);
        const hot = 1.0 - @as(f32, @floatFromInt(r)) / (chart_rows - 1);
        try tuiz.color.writeFg(lw, heat.at(hot));
        try flight.velocity.chartRow(lw, r, chart_rows, view.content_w, top);
        try emit(canvas, lw.buffered(), view);
    }
}

fn drawEngines(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    const names = [_][]const u8{ "E1", "E2", "E3", "S2" };
    var line: Line = .{};
    const lw = try line.start(view);
    for (names, 0..) |name, i| {
        const pct = throttle(flight.t, @intCast(i));
        try lw.print("{s}{s} ", .{ label_color, name });
        try tuiz.meter.write(lw, pct, amber, track);
        try lw.print(" {s}{d:>3}%{s}   ", .{ white, pct, tuiz.color.reset });
    }
    try emit(canvas, lw.buffered(), view);
}

fn drawPropellant(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    const stage: []const u8 = if (flight.t < separation) "S1" else "S2";
    var line: Line = .{};
    const lw = try line.start(view);
    for ([_]bool{ false, true }) |oxidiser| {
        const left = propellant(flight.t, oxidiser);
        const pct: u32 = @intFromFloat(@round(left * 100));
        try lw.print("{s}{s} {s} ", .{ label_color, stage, if (oxidiser) "LOX " else "RP-1" });
        try tuiz.meter.write(lw, pct, if (left < 0.15) red else teal, track);
        try lw.print(" {s}{d:>3}%{s}   ", .{ white, pct, tuiz.color.reset });
    }
    try emit(canvas, lw.buffered(), view);
}

fn drawLog(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    var seen: usize = 0;
    for (events) |e| {
        if (e.t <= flight.t) seen += 1;
    }
    const first = seen -| log_rows;
    var r: usize = 0;
    while (r < log_rows) : (r += 1) {
        var line: Line = .{};
        const lw = try line.start(view);
        if (first + r < seen) try writeEvent(lw, events[first + r], view);
        try emit(canvas, lw.buffered(), view);
    }
}

fn writeEvent(lw: *std.Io.Writer, e: Event, view: tuiz.Viewport) !void {
    try lw.print("{s}T+", .{muted});
    try writeClock(lw, e.t);
    try lw.print("  {s}", .{label_color});
    // Relay-supplied: filtered, then padded by cells, not bytes.
    try tuiz.sanitize.write(lw, e.station);
    try tuiz.cell.padTo(lw, view.margin + 22);
    try lw.writeAll(white);
    try tuiz.sanitize.write(lw, e.text);
}

fn drawSignal(canvas: *tuiz.Canvas, flight: *const Flight, view: tuiz.Viewport) !void {
    var line: Line = .{};
    const lw = try line.start(view);
    try lw.print("{s}link  ", .{muted});
    try lw.writeAll(tuiz.color.fg("#2dd4bf"));
    const width = view.content_w -| 12;
    try flight.signal.sparkline(lw, @min(width, History.cap));
    try lw.print(" {s}{d:>3.0}%", .{ white, flight.signal.maxRecent(1) });
    try emit(canvas, lw.buffered(), view);
}

fn drawFooter(canvas: *tuiz.Canvas, view: tuiz.Viewport) !void {
    var line: Line = .{};
    const lw = try line.start(view);
    try lw.print("{s}space pause · q quit", .{muted});
    const note = "illustrative flight · not a real vehicle";
    try tuiz.cell.padTo(lw, view.margin + view.content_w -| tuiz.cell.width(note));
    try lw.writeAll(note);
    // The last row takes no newline: on a terminal exactly as tall as
    // the frame, one would scroll the alt screen. `finish` erases the
    // rest.
    try canvas.writeRaw(tuiz.cell.truncate(lw.buffered(), view.inner_w));
    try canvas.writeRaw(tuiz.color.reset);
}

/// Clip a composed line to the drawable width, then reset colour so a
/// cut-off SGR cannot bleed into the next row.
fn emit(canvas: *tuiz.Canvas, line: []const u8, view: tuiz.Viewport) !void {
    try canvas.writeRaw(tuiz.cell.truncate(line, view.inner_w));
    try canvas.row(tuiz.color.reset);
}

fn writeClock(w: *std.Io.Writer, seconds: u32) !void {
    try w.print("{d:0>2}:{d:0>2}", .{ seconds / 60, seconds % 60 });
}

/// `1766` → `1,766`.
fn writeGrouped(w: *std.Io.Writer, n: u32) !void {
    if (n >= 1000) {
        try w.print("{d},{d:0>3}", .{ n / 1000, n % 1000 });
    } else {
        try w.print("{d}", .{n});
    }
}

// ── tests ───────────────────────────────────────────────────────────

fn render(buf: []u8, t: u32, ws: std.posix.winsize) ![]const u8 {
    const flight = Flight.at(t);
    var out: std.Io.Writer = .fixed(buf);
    try draw(&out, &flight, ws, false);
    return out.buffered();
}

test "every frame of the flight fits the viewport" {
    var buf: [64 * 1024]u8 = undefined;
    for ([_]u16{ 80, 100, 120, 200 }) |cols| {
        for ([_]u16{ 28, 32 }) |height| {
            var t: u32 = 0;
            while (t <= seco + 30) : (t += 7) {
                const frame = try render(&buf, t, .{ .col = cols, .row = height, .xpixel = 0, .ypixel = 0 });
                var rows = std.mem.splitScalar(u8, frame, '\n');
                var n: usize = 0;
                while (rows.next()) |row| : (n += 1) {
                    try std.testing.expect(tuiz.cell.width(row) < cols);
                }
                try std.testing.expect(n <= height);
            }
        }
    }
}

test "the hostile relay message is shown, not executed" {
    var buf: [64 * 1024]u8 = undefined;
    const frame = try render(&buf, default_snapshot_t, snapshot_size);
    try std.testing.expect(std.mem.indexOf(u8, frame, "handover ack?[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
}

test "the station chip ends on the right edge despite double-width names" {
    var buf: [64 * 1024]u8 = undefined;
    const frame = try render(&buf, default_snapshot_t, snapshot_size);
    var rows = std.mem.splitScalar(u8, frame, '\n');
    _ = rows.next(); // blank
    const header = rows.next().?;
    const view = tuiz.Viewport.fromWinsize(snapshot_size, limits);
    try std.testing.expect(std.mem.indexOf(u8, header, "小笠原") != null);
    try std.testing.expectEqual(view.margin + view.content_w, tuiz.cell.width(header));
}

test "the altitude numerals never reach the stats column" {
    var buf: [16]u8 = undefined;
    var t: u32 = 0;
    while (t <= seco + 30) : (t += 1) {
        const alt = try altitudeText(&buf, @floatFromInt(t));
        const used = patch.w + 3 + tuiz.bigtext.measure(alt, 1) + " km".len;
        try std.testing.expect(used < stats_col);
    }
}

test "the flight is monotonic where it should be" {
    var t: f32 = 1;
    while (t < seco) : (t += 1) {
        try std.testing.expect(altitude(t) >= altitude(t - 1));
        try std.testing.expect(downrange(t) >= downrange(t - 1));
    }
}

test "snapshot times at and beyond the endpoint hold the final frame" {
    for ([_]u32{ seco + 30, seco + 31, std.math.maxInt(u32) }) |t| {
        const flight = Flight.at(t);
        try std.testing.expectEqual(@as(u32, seco + 30), flight.t);
        try std.testing.expectEqualStrings("orbit", flight.stage());
    }
}
