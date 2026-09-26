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
//! generic `viewport-take`, focused there. `shell` names what runs (default
//! `exec "${SHELL:-sh}" -i`, under `/bin/sh -c`).
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

/// `terminal`: the shell in the panel, focused; started on first use.
fn open() void {
    weft.focusOrCreateBuffer(buffer_name);
    if (session == null) {
        weft.toolBacking("terminal");
        session = weft.replStart(orDefault("shell", "exec \"${SHELL:-sh}\" -i"), buffer_name) orelse
            return weft.echo("terminal: could not start the shell");
        input_len = 0;
    }
    weft.setMode(mode);
    // The caret rides the end, where output and the echoed input land.
    weft.jump(weft.byteLen());
    weft.runStr("viewport-take", orDefault("viewport", "panel"));
}

/// Is the focused entry the terminal's? Every input verb acts only there.
fn here() bool {
    var buf: [64]u8 = undefined;
    const name = weft.activeBufferName(&buf) orelse return false;
    return session != null and std.mem.eql(u8, name, buffer_name);
}

fn echoAtEnd(text: []const u8) void {
    const end = weft.byteLen();
    weft.render(.{ .start = end, .end = end }, text);
    weft.jump(weft.byteLen());
}

fn typeText() void {
    if (!here()) return;
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
    if (!here() or input_len == 0) return;
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

/// Return: the line goes to the shell's stdin, the echo gets its newline.
fn send() void {
    if (!here()) return;
    const handle = session orelse return;
    echoAtEnd("\n");
    weft.replSend(handle, input[0..input_len]);
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
