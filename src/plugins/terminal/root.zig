//! terminal — a shell in the panel, LINE-MODE: what you type is held as one
//! input line, echoed into the buffer, and written to the shell's stdin when
//! you press Return; the shell's output streams in below. It is the `repl`
//! plugin's persistent session (`weft.replStart`) with a shell at the other
//! end and a mode that owns the input line, NOT a terminal emulator: there
//! is no VT100 screen, so full-screen programs (an editor, a pager, `top`)
//! do not work, and core strips the colors and cursor controls a shell
//! prints (`repl_session.stripControls`).
//!
//! `terminal` opens it — starting the shell the first time — and puts its
//! entry in the viewport named by `viewport` (default `panel`) through core's
//! generic `viewport-take`, focused there. `shell` names what runs (see
//! `invocation`; default `$SHELL`, interactive, its own line editing off).
//!
//! A shell that exits (`exit`, a crash) is noticed on the next C-` or
//! keystroke: the buffer says `[process exited N]`, and a fresh shell starts
//! below it — input never goes to a dead child.
//!
//! The `terminal` mode commits typed text into the input line and falls back
//! to `default`, so every workspace key the config binds globally still
//! reaches it. Return sends, BackSpace edits, C-u clears.

const std = @import("std");
const weft = @import("weft");

const buffer_name = "*terminal*";
const mode = "terminal";

/// The shell's session handle, while it runs.
var session: ?u32 = null;
/// The line being typed, not yet sent. It is also echoed at the end of the
/// buffer; this is the copy that is sent.
var input: [1 << 12]u8 = undefined;
var input_len: usize = 0;

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len > 0) v else default;
}

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

fn init() void {
    weft.textInput(mode, "terminal-type");
    weft.setFallback(mode, "default");
    const keys = [_][2][]const u8{
        .{ "Return", "terminal-send" },         .{ "KP_Enter", "terminal-send" },
        .{ "BackSpace", "terminal-backspace" }, .{ "C-u", "terminal-clear" },
    };
    for (keys) |k| weft.bindKey(mode, k[0], k[1]);
}

var command_buf: [1024]u8 = undefined;

/// What runs, under `/bin/sh -c`: the `shell` setting. A whole command line
/// (anything with a space) runs as written. A bare program — `bash`,
/// `/bin/zsh`, or by default `$SHELL` — starts interactive with ITS OWN line
/// editing off: this plugin owns the input line and echoes it, so a shell
/// that also edited it (bash's readline, zsh's ZLE) would print every line a
/// second time. bash takes `--noediting` and zsh `+Z`; every shell gets
/// `TERM=dumb`, which the rest (and the programs they run) honour.
fn invocation() []const u8 {
    const v = weft.config("shell");
    if (std.mem.indexOfAny(u8, v, " \t") != null) return v;
    const program = if (v.len > 0) v else "${SHELL:-sh}";
    return std.fmt.bufPrint(&command_buf,
        \\p="{s}"; export TERM=dumb; case "${{p##*/}}" in bash) exec "$p" --noediting -i;; zsh) exec "$p" +Z -i;; *) exec "$p" -i;; esac
    , .{program}) catch "exec \"${SHELL:-sh}\" -i";
}

/// Is the focused entry the terminal's buffer? Every input verb acts only
/// there.
fn onTerminal() bool {
    var buf: [64]u8 = undefined;
    const name = weft.activeBufferName(&buf) orelse return false;
    return std.mem.eql(u8, name, buffer_name);
}

/// The running shell, with the terminal's buffer focused: the one there is,
/// or — none yet, or the last one exited — a fresh one, after the buffer
/// says how the last one ended. Null when none will start (said so).
fn shell() ?u32 {
    if (session) |h| {
        const code = weft.replExited(h) orelse return h;
        var note: [48]u8 = undefined;
        const end = weft.byteLen();
        const at_line_start = end == 0 or weft.slice(end - 1, end)[0] == '\n';
        echoAtEnd(std.fmt.bufPrint(&note, "{s}[process exited {d}]\n", .{ if (at_line_start) "" else "\n", code }) catch "[process exited]\n");
        // Reap it and free its slot; the handle stays dead.
        weft.replQuit(h);
        session = null;
    }
    input_len = 0;
    weft.toolBacking("terminal");
    session = weft.replStart(invocation(), buffer_name) orelse {
        weft.echo("terminal: could not start the shell");
        return null;
    };
    return session;
}

/// `terminal`: the shell in the panel, focused; started on first use, and
/// again once it has exited.
fn open() void {
    weft.focusOrCreateBuffer(buffer_name);
    _ = shell() orelse return;
    weft.setMode(mode);
    // The caret rides the end, where output and the echoed input land.
    weft.jump(weft.byteLen());
    weft.runStr("viewport-take", orDefault("viewport", "panel"));
}

fn echoAtEnd(text: []const u8) void {
    const end = weft.byteLen();
    weft.render(.{ .start = end, .end = end }, text);
    weft.jump(weft.byteLen());
}

fn typeText() void {
    if (!onTerminal()) return;
    _ = shell() orelse return;
    const s = weft.argStr(0) orelse return;
    if (input_len + s.len > input.len) return weft.echo("terminal: the input line is full");
    @memcpy(input[input_len..][0..s.len], s);
    input_len += s.len;
    echoAtEnd(s);
}

/// Take the last character back out of the input line, and out of the
/// buffer when the echo is still the last thing there (output that arrived
/// since is left alone).
fn backspace() void {
    if (!onTerminal() or input_len == 0) return;
    var cut = input_len - 1;
    while (cut > 0 and input[cut] & 0xc0 == 0x80) cut -= 1;
    const gone = input[cut..input_len];
    input_len = cut;
    const end = weft.byteLen();
    if (end < gone.len) return;
    if (std.mem.eql(u8, weft.slice(end - gone.len, end), gone))
        weft.render(.{ .start = end - gone.len, .end = end }, "");
}

fn clearLine() void {
    while (input_len > 0) backspace();
}

/// Return: the line goes to the shell's stdin, the echo gets its newline. A
/// shell that exited meanwhile is reported and replaced, and the line is
/// the new one's.
fn send() void {
    if (!onTerminal()) return;
    const typed = input_len;
    const was = session;
    const handle = shell() orelse return;
    // A restart emptied the line: the old shell never read it.
    if (was != handle) return;
    echoAtEnd("\n");
    weft.replSend(handle, input[0..typed]);
    input_len = 0;
}

/// `terminal-quit`: stop the shell; the buffer stays with what it printed.
fn quit() void {
    const handle = session orelse return;
    weft.replQuit(handle);
    session = null;
    input_len = 0;
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "terminal", .call = open, .summary = "open the shell in the panel (line-mode: no terminal emulation)" },
    .{ .name = "terminal-type", .call = typeText, .params = "text", .summary = "add typed text to the terminal's input line" },
    .{ .name = "terminal-send", .call = send, .summary = "send the terminal's input line to the shell" },
    .{ .name = "terminal-backspace", .call = backspace, .summary = "delete the last character of the input line" },
    .{ .name = "terminal-clear", .call = clearLine, .summary = "clear the input line" },
    .{ .name = "terminal-quit", .call = quit, .summary = "stop the terminal's shell" },
};

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = init }).exportAll();
}
