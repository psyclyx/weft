//! console — command consoles (design §6.3, comint-flavored), a `.wasm` plugin
//! (perms `{proc, timer}`). `console-open` opens a console buffer; typing a
//! command and running `console-send` appends its output below via the native
//! `proc` APPEND surface. This is the STATELESS end of the REPL story — each
//! line is an independent command. A stateful REPL (python -i, nREPL, keeping
//! session state) is the `repl` plugin's persistent interactive-proc session.
//!
//! Consoles are INSTANCES: each open takes a fresh buffer (`*console*`,
//! `*console:2*`, …), so two of them keep separate logs. A send appends to the
//! focused console, else to the most recent one — echoing which.

const weft = @import("weft");

/// Each open console, keyed by the log buffer it appends to; a console holds
/// no other state (each line is an independent command).
var consoles: weft.Instances(void) = .{};
var cmd_buf: [1 << 12]u8 = undefined;

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]weft.CommandEntry{
    .{ .name = "console-open", .call = open, .summary = "open a command console of its own" },
    .{ .name = "console-send", .call = send, .summary = "run the current line in this console" },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

/// Open a console of its own.
fn open() void {
    _ = consoles.open("console") orelse weft.echo("console: out of memory — could not open another console");
}

/// Run the current line as a command; its output appends to that console.
fn send() void {
    const slot = consoles.current("console") orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end);
    if (line.len == 0) return;
    const n = @min(line.len, cmd_buf.len);
    @memcpy(cmd_buf[0..n], line[0..n]); // copy — the read scratch is reused below
    weft.procAppendBuffer(cmd_buf[0..n], slot.name(), 0);
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra }).exportAll();
}
