const std = @import("std");
const tuiz = @import("tuiz");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (std.mem.eql(u8, mode, "drain")) {
        tuiz.terminal.drainStdin();
        return;
    }
    if (!std.mem.eql(u8, mode, "raw")) return error.UnknownMode;
    var raw = tuiz.RawTty.enable();
    defer raw.disable();
    if (!raw.enabled) return error.RawModeUnavailable;
    tuiz.terminal.watchResize();
    try std.Io.File.stdout().writeStreamingAll(init.io, "ready\n");

    var pfd = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    // The parent sends SIGWINCH before supplying the byte that wakes us.
    if (try std.posix.poll(&pfd, 2000) == 0) return error.InputTimeout;
    var key: [1]u8 = undefined;
    if (try std.posix.read(std.posix.STDIN_FILENO, &key) != 1) return error.MissingInput;
    if (key[0] != 'q') return error.WrongInput;
    if (!tuiz.terminal.takeResize()) return error.MissingResize;
    if (tuiz.terminal.takeResize()) return error.ResizeNotConsumed;
}
