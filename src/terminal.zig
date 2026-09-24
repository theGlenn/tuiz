//! Terminal state: raw mode, alternate screen, and resize events.
//!
//! Deliberately does no I/O of its own beyond termios and the resize
//! ioctl. The escape sequences are exported as plain strings so the
//! application keeps ownership of *how* bytes reach the tty (a raw
//! `write`, a buffered writer, a socket for a remote UI) — the
//! framework only knows what to send.

const std = @import("std");

/// Setup sequence, in order:
///   ?25l   hide cursor
///   ?1049h enter alternate screen (quit restores the user's buffer)
///   ?1000l ?1002l ?1003l ?1006l  disable every mouse-reporting mode
///          in case a prior app (vim, tmux, helix) left one on.
///          Without this, clicks inject escape sequences into stdin
///          that a keybind reader silently consumes.
///   ?2004l disable bracketed paste so a stray paste doesn't burst a
///          wall of bytes through the keybind switch.
pub const enter_alt_screen = "\x1b[?25l\x1b[?1049h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l";

/// Teardown: leave alt screen, show cursor, re-enable bracketed
/// paste. Mouse-reporting modes stay off — apps that need them
/// re-enable on focus, so a brief gap is fine. Bracketed paste is
/// different: shells with bracketed-paste-magic expect it on for the
/// next prompt, and there is no auto-restore hook.
pub const leave_alt_screen = "\x1b[?1049l\x1b[?25h\x1b[?2004h";

/// Home the cursor and erase everything below — the correct reset
/// after a shrink, where the old frame's right edge would otherwise
/// linger.
pub const home_and_clear_below = "\x1b[H\x1b[J";

/// stdin in raw mode, restored on `disable`. Degrades to a no-op
/// when stdin isn't a tty, so piped runs still work (without
/// keybinds) instead of erroring.
pub const RawTty = struct {
    saved: std.posix.termios = undefined,
    enabled: bool = false,

    pub fn enable() RawTty {
        const fd = std.posix.STDIN_FILENO;
        // Skip the tcgetattr probe entirely when stdin isn't a tty
        // (piped, redirected, or driven by a non-pty harness). On
        // some non-tty fds tcgetattr returns an errno that Zig's std
        // wrapper treats as "unexpected" and dumps a stack trace —
        // the isatty gate avoids that noise.
        if (std.c.isatty(fd) == 0) return .{};
        const orig = std.posix.tcgetattr(fd) catch return .{};

        var raw = orig;
        // Disable echo so keystrokes don't appear on screen, canonical
        // mode so reads return per-byte, signal generation so ^C
        // becomes a regular 0x03 byte (handled as quit), and the
        // CR-to-NL + flow-control mappings that would interfere with
        // a keybind table.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        // VMIN=0 + VTIME=0 → read returns immediately with whatever's
        // available (poll() handles the wait). @intFromEnum on the V
        // index enum portably reaches into the cc array.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        std.posix.tcsetattr(fd, .FLUSH, raw) catch return .{};
        return .{ .saved = orig, .enabled = true };
    }

    pub fn disable(self: *RawTty) void {
        if (self.enabled) {
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
            self.enabled = false;
        }
    }
};

/// Set by the SIGWINCH handler; consumed at the top of an event-loop
/// iteration via `takeResize()`. Atomic because the handler runs on
/// the signal stack and may interrupt the render.
var resize_flag = std.atomic.Value(u32).init(0);

fn winchHandler(_: std.posix.SIG) callconv(.c) void {
    resize_flag.store(1, .release);
}

/// Install the SIGWINCH handler. Only worth calling when stdout is a
/// tty — otherwise there is no resize source to listen for.
pub fn watchResize() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = winchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.c.SIG.WINCH, &act, null);
}

/// True once per resize since the last call.
pub fn takeResize() bool {
    return resize_flag.swap(0, .acquire) != 0;
}

/// Current terminal size, or null when stdout isn't a tty.
pub fn size() ?std.posix.winsize {
    const T = std.c.T;
    var ws: std.posix.winsize = undefined;
    const rc = std.c.ioctl(std.posix.STDOUT_FILENO, T.IOCGWINSZ, &ws);
    if (rc != 0) return null;
    return ws;
}

/// Drain anything already sitting in stdin — input that arrived
/// between entering raw mode and the loop starting (a click to focus
/// the window, shell type-ahead).
pub fn drainStdin() void {
    var scratch: [256]u8 = undefined;
    while (true) {
        var pfd = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&pfd, 0) catch break;
        if (n == 0) break;
        _ = std.posix.read(std.posix.STDIN_FILENO, &scratch) catch break;
    }
}
