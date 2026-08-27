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

const std = @import("std");
const weft = @import("weft");

const max_sessions = 8;
const name_cap = 32;

const Session = struct {
    handle: u32,
    buf: [name_cap]u8,
    buf_len: usize,

    fn name(self: *const Session) []const u8 {
        return self.buf[0..self.buf_len];
    }
};

var sessions: [max_sessions]?Session = @splat(null);
var recent: ?usize = null;

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
    const slot = freeSlot() orelse return weft.echo("repl: too many sessions");
    var name_buf: [name_cap]u8 = undefined;
    const ordinal = weft.instanceOrdinal("repl") orelse return;
    const name = weft.instanceName("repl", ordinal, &name_buf) orelse return;
    weft.runStr("buffer-create", name);
    const handle = weft.replStart(weft.argStr(0) orelse "sh", name) orelse return;
    var s: Session = .{ .handle = handle, .buf = undefined, .buf_len = name.len };
    @memcpy(s.buf[0..name.len], name);
    sessions[slot] = s;
    recent = slot;
}
/// Send arg0 to this entry's REPL.
fn send() void {
    const slot = current() orelse return;
    weft.replSend(sessions[slot].?.handle, weft.argStr(0) orelse return);
}
/// Send the current line to this entry's REPL.
fn sendLine() void {
    const slot = current() orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    weft.replSend(sessions[slot].?.handle, weft.slice(l.start, l.end));
}
/// Quit this entry's REPL only; every other session stays live.
fn quit() void {
    const slot = current() orelse return;
    weft.replQuit(sessions[slot].?.handle);
    sessions[slot] = null;
    if (recent == slot) recent = anyLive();
}

fn freeSlot() ?usize {
    for (sessions, 0..) |s, i| if (s == null) return i;
    return null;
}

fn anyLive() ?usize {
    for (sessions, 0..) |s, i| if (s != null) return i;
    return null;
}

/// The session a command acts on: the one owning the focused buffer, else the
/// most recent — named on the status line, so a command run from a source file
/// never silently drives an interpreter the user cannot see.
fn current() ?usize {
    var name_buf: [name_cap]u8 = undefined;
    if (weft.activeBufferName(&name_buf)) |active| {
        for (sessions, 0..) |maybe, i| {
            const s = maybe orelse continue;
            if (std.mem.eql(u8, s.name(), active)) {
                recent = i;
                return i;
            }
        }
    }
    const slot = recent orelse return null;
    const s = sessions[slot] orelse return null;
    var msg: [name_cap + 8]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&msg, "repl: {s}", .{s.name()}) catch return slot);
    return slot;
}
