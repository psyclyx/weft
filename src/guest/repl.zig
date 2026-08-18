//! repl — a stateful interactive REPL (design §6.3), a `.wasm` plugin (perms
//! `{proc, timer}`). `repl-start` spawns a persistent interpreter (arg0, e.g.
//! `python3 -i`, `node`, `nix repl`; default `cat`) whose output streams into a
//! *repl* comint buffer; `repl-send-line` feeds it the current line and
//! `repl-quit` ends it. Unlike the stateless `console`, the process KEEPS its
//! session state between sends — a real read-eval-print loop.

const std = @import("std");
const weft = @import("weft.zig");

const repl_buf = "*repl*";
var session: ?u32 = null;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "repl-start", .handler = start },
    .{ .name = "repl-send", .handler = send },
    .{ .name = "repl-send-line", .handler = sendLine },
    .{ .name = "repl-quit", .handler = quit },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Start (or restart) the REPL running arg0 (default `sh` — a shell REPL; pass
/// e.g. "python3 -u", "node", "nix repl"). Note: pipe-buffered interpreters may
/// need an unbuffered flag (python `-u`) to stream promptly.
fn start() void {
    if (session) |h| weft.replQuit(h);
    weft.runStr("buffer-create", repl_buf);
    session = weft.replStart(weft.argStr(0) orelse "sh", repl_buf);
}
/// Send arg0 to the REPL's stdin.
fn send() void {
    const h = session orelse return;
    weft.replSend(h, weft.argStr(0) orelse return);
}
/// Send the current line to the REPL.
fn sendLine() void {
    const h = session orelse return;
    const l = weft.lineAt(weft.cursor());
    weft.replSend(h, weft.slice(l.start, l.end));
}
fn quit() void {
    if (session) |h| {
        weft.replQuit(h);
        session = null;
    }
}
