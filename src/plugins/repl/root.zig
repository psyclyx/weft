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
//!
//! While a session is live it is PUBLISHED: context key `repl.session` holds
//! its buffer name on the place it runs in (doc/model.md §2.5), so a config
//! can offer "Send to REPL" exactly where there is a REPL to send to —
//! `weft.provide(…, { context: { "repl.session": "*" } }, "repl-send-line")`
//! — and a toolbar shows it with no toolbar code knowing a REPL exists. The
//! key names the most recent live session in that place, and is retracted
//! when the last one quits or is found to have exited (and by the host, if
//! this plugin unloads).

const std = @import("std");
const weft = @import("weft");

const session_key = "repl.session";

/// Each live interpreter, keyed by the comint buffer it streams into; the
/// value is its host session handle.
const Sessions = weft.Instances(u32);
var sessions: Sessions = .{};

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
    .{ .name = "repl-start", .call = start, .params = "[interpreter]", .summary = "start an interpreter in its own buffer (default sh)" },
    .{ .name = "repl-send", .call = send, .params = "text", .summary = "send a line to this buffer's REPL" },
    .{ .name = "repl-send-line", .call = sendLine, .summary = "send the current line to this buffer's REPL" },
    .{ .name = "repl-quit", .call = quit, .summary = "stop this buffer's REPL; others stay live" },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
/// Start a REPL running arg0 (default `sh` — a shell REPL; pass e.g.
/// "python3 -u", "node", "nix repl") in a buffer of its own. Note:
/// pipe-buffered interpreters may need an unbuffered flag (python `-u`) to
/// stream promptly.
fn start() void {
    reap();
    const slot = sessions.open("repl") orelse return weft.echo("repl: out of memory — could not open another interpreter");
    slot.value = weft.replStart(weft.argStr(0) orelse "sh", slot.name()) orelse
        return sessions.close(slot);
    publish(slot.place);
}
/// Send arg0 to this entry's REPL.
fn send() void {
    reap();
    const slot = sessions.current("repl") orelse return;
    weft.replSend(slot.value, weft.argStr(0) orelse return);
}
/// Send the current line to this entry's REPL.
fn sendLine() void {
    reap();
    const slot = sessions.current("repl") orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    weft.replSend(slot.value, weft.slice(l.start, l.end));
}
/// Quit this entry's REPL only; every other session stays live.
fn quit() void {
    reap();
    const slot = sessions.current("repl") orelse return;
    weft.replQuit(slot.value);
    retire(slot);
}

/// Close a session's slot and say what is live in its place now.
fn retire(slot: *Sessions.Slot) void {
    const place = slot.place;
    sessions.close(slot);
    publish(place);
}

/// Retire every session whose interpreter has exited on its own (`exit`, a
/// crash), so the published key never names a dead REPL past the next
/// command. The host reaps the child; the buffer keeps what it printed.
fn reap() void {
    var i: usize = sessions.slots.items.len;
    while (i > 0) {
        i -= 1;
        const slot = sessions.slots.items[i];
        if (weft.replExited(slot.value) == null) continue;
        weft.replQuit(slot.value);
        retire(slot);
    }
}

/// Publish the most recent live session opened in `place` as `repl.session`
/// on the current entry's place, or retract the key when none is left.
/// Publishing addresses the place of the entry this command runs in, so it
/// only speaks for `place` when that is where the command runs — which it is
/// for a start (the new buffer inherits its place) and for a quit or send
/// from the REPL's own buffer or a file beside it.
fn publish(place: i32) void {
    if (weft.placeId() != place) return;
    var newest: ?*Sessions.Slot = null;
    for (sessions.slots.items) |slot| {
        if (slot.place != place) continue;
        if (newest == null or slot.opened > newest.?.opened) newest = slot;
    }
    const name = if (newest) |slot| slot.name() else "";
    weft.contextSet(session_key, name, .place) catch |err| {
        var buf: [96]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&buf, "repl: could not publish {s}: {t}", .{ session_key, err }) catch session_key);
    };
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra }).exportAll();
}
