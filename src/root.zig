//! tuiz — a small, dependency-free toolkit for open-layout terminal
//! dashboards.
//!
//! Scope, deliberately narrow: truecolor, a row-oriented canvas with
//! a gutter, cell-accurate width accounting, filtered emission of
//! untrusted text, and the widgets a telemetry dashboard actually
//! needs (area chart, sparkline, meter, block-glyph numerals,
//! half-block bitmap art). No event loop, no widget tree, no diffing.
//!
//! One rule the caller has to honour: text the application did not
//! write itself goes through `sanitize.write`, never `print("{s}")`.
//! See `sanitize.zig`.
//!
//! The division of labour is the whole design:
//!   • the framework writes bytes into a caller-supplied writer
//!   • the application owns the fd, the palette, and the event loop
//!
//! That is why nothing here imports a socket shim or declares a
//! colour, and why `terminal.zig` exports escape sequences as strings
//! rather than writing them. Vendoring this directory into another
//! project should require no edits.
//!
//! Usage sketch:
//! ```zig
//! const tuiz = @import("tuiz");
//!
//! const Series = tuiz.Series(120);
//! const rule_color = tuiz.color.fg("#14343a");
//!
//! var buf: [32768]u8 = undefined;
//! var out: std.Io.Writer = .fixed(&buf);
//! var canvas = tuiz.Canvas.init(&out, 2, .{ .rule = rule_color });
//! try canvas.home();
//! try canvas.rowPrint("{s}hello", .{tuiz.color.bold});
//! try canvas.rule(viewport.content_w);
//! try canvas.finish();
//! try writeToTty(out.buffered());
//! ```

pub const cell = @import("cell.zig");
pub const color = @import("color.zig");
pub const layout = @import("layout.zig");
pub const sanitize = @import("sanitize.zig");
pub const terminal = @import("terminal.zig");

const canvas_mod = @import("canvas.zig");
pub const Canvas = canvas_mod.Canvas;
pub const Style = canvas_mod.Style;
pub const padWidth = canvas_mod.padWidth;
/// Scratch size a caller should give its own per-row line buffers to
/// match what the canvas can carry.
pub const scratch_len = canvas_mod.scratch_len;

pub const Rgb = color.Rgb;
pub const Ramp = color.Ramp;

pub const Limits = layout.Limits;
pub const Viewport = layout.Viewport;

pub const RawTty = terminal.RawTty;

pub const bigtext = @import("widgets/bigtext.zig");
pub const logo = @import("widgets/logo.zig");
pub const meter = @import("widgets/meter.zig");
pub const Series = @import("widgets/series.zig").Series;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("widgets/series.zig").Series(8);
}
