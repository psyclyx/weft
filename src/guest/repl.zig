//! repl — stateful interactive REPLs (design §6.3), a `.wasm` plugin (perms
//! `{proc, timer}`). `repl-start` spawns a persistent interpreter (arg0, e.g.
//! `python3 -i`, `node`, `nix repl`) whose output streams into its own comint
//! buffer; `repl-send-line` feeds it the current line and `repl-quit` ends it.
//! Unlike the stateless `console`, the process KEEPS its session state between
//! sends — a real read-eval-print loop.
//!
//! REPLs are INSTANCES: every start takes a fresh buffer (`*repl*`, `*repl:2*`,
//! …) and a session bound to it, so two interpreters never share a sink or a
//! lifetime. A command acts on the session whose buffer is focused; run from
//! anywhere else it targets the most recent one and echoes which.

const weft = @import("weft");

/// Each live interpreter, keyed by the comint buffer it streams into; the
/// value is its host session handle.
var sessions: weft.Instances(u32) = .{};

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
/// Start a REPL running arg0 (default `sh` — a shell REPL; pass e.g.
/// "python3 -u", "node", "nix repl") in a buffer of its own. Note:
/// pipe-buffered interpreters may need an unbuffered flag (python `-u`) to
/// stream promptly.
fn start() void {
    const slot = sessions.open("repl") orelse return weft.echo("repl: out of memory — could not open another interpreter");
    slot.value = weft.replStart(weft.argStr(0) orelse "sh", slot.name()) orelse
        return sessions.close(slot);
}
/// Send arg0 to this entry's REPL.
fn send() void {
    const slot = sessions.current("repl") orelse return;
    weft.replSend(slot.value, weft.argStr(0) orelse return);
}
/// Send the current line to this entry's REPL.
fn sendLine() void {
    const slot = sessions.current("repl") orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    weft.replSend(slot.value, weft.slice(l.start, l.end));
}
/// Quit this entry's REPL only; every other session stays live.
fn quit() void {
    const slot = sessions.current("repl") orelse return;
    weft.replQuit(slot.value);
    sessions.close(slot);
}
