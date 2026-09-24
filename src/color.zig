//! Truecolor primitives: 24-bit RGB, comptime SGR strings, and
//! piecewise-linear colour ramps.
//!
//! No palette lives here — palettes are an application's design
//! tokens, not the framework's. See `examples/dashboard.zig`
//! for what a consumer-side palette looks like.

const std = @import("std");

pub const bold = "\x1b[1m";
pub const reset = "\x1b[0m";

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// `Rgb.hex("#f5c518")`. Comptime-only: an invalid literal is a
    /// compile error rather than a runtime surprise.
    pub fn hex(comptime s: *const [7]u8) Rgb {
        comptime std.debug.assert(s[0] == '#');
        return .{
            .r = std.fmt.parseInt(u8, s[1..3], 16) catch unreachable,
            .g = std.fmt.parseInt(u8, s[3..5], 16) catch unreachable,
            .b = std.fmt.parseInt(u8, s[5..7], 16) catch unreachable,
        };
    }

    /// Linear interpolation per channel, `t` in [0, 1].
    pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        return .{
            .r = mixChannel(a.r, b.r, t),
            .g = mixChannel(a.g, b.g, t),
            .b = mixChannel(a.b, b.b, t),
        };
    }
};

fn mixChannel(x: u8, y: u8, t: f32) u8 {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    return @intFromFloat(@round(xf + (yf - xf) * t));
}

/// Comptime foreground SGR string for a hex literal. Use for the
/// fixed palette entries — costs nothing at runtime, and the escape
/// is a plain `[]const u8` that concatenates into format strings.
pub fn fg(comptime hexstr: *const [7]u8) []const u8 {
    const c = comptime Rgb.hex(hexstr);
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Runtime foreground SGR, for colours computed from data (ramps).
pub fn writeFg(w: anytype, c: Rgb) !void {
    try w.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Runtime background SGR. Only half-block bitmap art needs this — an
/// open layout paints no panels, so every other widget leaves the
/// background alone.
pub fn writeBg(w: anytype, c: Rgb) !void {
    try w.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// Piecewise-linear gradient over two or more stops.
pub const Ramp = struct {
    stops: []const Rgb,

    /// Colour at `t` in [0, 1]; out-of-range values clamp to the ends.
    pub fn at(self: Ramp, t_in: f32) Rgb {
        std.debug.assert(self.stops.len >= 2);
        const t = std.math.clamp(t_in, 0, 1);
        const nseg: f32 = @floatFromInt(self.stops.len - 1);
        const pos = t * nseg;
        const i: usize = @min(@as(usize, @intFromFloat(pos)), self.stops.len - 2);
        return Rgb.mix(self.stops[i], self.stops[i + 1], pos - @as(f32, @floatFromInt(i)));
    }
};

test "hex parses each channel" {
    const c = Rgb.hex("#f5c518");
    try std.testing.expectEqual(@as(u8, 0xf5), c.r);
    try std.testing.expectEqual(@as(u8, 0xc5), c.g);
    try std.testing.expectEqual(@as(u8, 0x18), c.b);
}

test "ramp endpoints return the outer stops exactly" {
    const ramp = Ramp{ .stops = &.{ Rgb.hex("#000000"), Rgb.hex("#808080"), Rgb.hex("#ffffff") } };
    try std.testing.expectEqual(@as(u8, 0), ramp.at(0).r);
    try std.testing.expectEqual(@as(u8, 0x80), ramp.at(0.5).r);
    try std.testing.expectEqual(@as(u8, 0xff), ramp.at(1).r);
    // Clamped, not wrapped.
    try std.testing.expectEqual(@as(u8, 0xff), ramp.at(9).r);
    try std.testing.expectEqual(@as(u8, 0), ramp.at(-3).r);
}
