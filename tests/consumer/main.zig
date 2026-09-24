const std = @import("std");
const tuiz = @import("tuiz");

pub fn main() !void {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tuiz.Canvas.init(&out, 0, .{});
    try canvas.home();
    try canvas.row("hello");
    try canvas.finish();
    if (!std.mem.eql(u8, out.buffered(), "\x1b[Hhello\x1b[K\n\x1b[K\x1b[J")) {
        return error.IncorrectFrame;
    }
}
