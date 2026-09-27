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
//! Each session's entry is a LIVE RESOURCE (doc/model.md §2.1):
//! `weft://here/proc/repl` (`…/repl.2` for the second), which designates it
//! only while the interpreter runs — a jump back to it after the buffer is
//! closed is refused by name rather than answered with a fresh shell.
//!
//! While a session is live it is PUBLISHED: context key `repl.session` holds
//! that designation on the place it runs in (doc/model.md §2.5), so a config
//! can offer "Send to REPL" exactly where there is a REPL to send to —
//! `weft.provide(…, { context: { "repl.session": "*" } }, "repl-send-line")`
//! — and a toolbar shows it with no toolbar code knowing a REPL exists. The
//! key names the most recent live session in that place, and is retracted
//! when the last one quits or is found to have exited — at the place it was
//! published on, named by its designation, whichever place the user is in
//! when that happens (and by the host, if this plugin unloads).

const std = @import("std");
const weft = @import("weft");

const session_key = "repl.session";

/// One live interpreter.
const Session = struct {
    /// The host's session handle.
    handle: u32,
    /// Where it was started, by the place's designation: where its
    /// `repl.session` is published and retracted.
    place_buf: [1024]u8 = undefined,
    place_len: usize = 0,
    /// What its entry is: `weft://here/proc/<instance>`.
    named_buf: [96]u8 = undefined,
    named_len: usize = 0,

    fn place(self: *const Session) []const u8 {
        return self.place_buf[0..self.place_len];
    }
    fn named(self: *const Session) []const u8 {
        return self.named_buf[0..self.named_len];
    }
};

/// Each live interpreter, keyed by the comint buffer it streams into.
const Sessions = weft.Instances(Session);
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
    .{ .name = "repl-start", .call = start, .arity = .whole, .params = "[interpreter]", .summary = "start an interpreter in its own buffer (default sh)" },
    .{ .name = "repl-send", .call = send, .arity = .whole, .params = "text", .summary = "send a line to this buffer's REPL" },
    .{ .name = "repl-send-line", .arity = .one, .call = sendLine, .summary = "send the current line to this buffer's REPL" },
    .{ .name = "repl-quit", .call = quit, .arity = .whole, .summary = "stop this buffer's REPL; others stay live" },
    .{ .name = "repl-reattach", .call = reattach, .arity = .whole, .params = "designation", .summary = "show the live REPL a `weft://here/proc/repl…` designation names" },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

fn init() void {
    // This plugin's processes are `weft://here/proc/repl…`: it reattaches
    // them, and no other plugin may declare one.
    _ = weft.designationOpener("proc.repl", "repl-reattach");
}

/// `open weft://here/proc/repl.N` with no entry showing it: the interpreter
/// is still running (its buffer was closed), so its entry comes back — the
/// output it streams lands there again. An interpreter that has exited is
/// refused by name: a live resource does not outlive its process.
fn reattach() void {
    reap();
    const wanted = weft.argStr(0) orelse return;
    for (sessions.slots.items) |slot| {
        if (!std.mem.eql(u8, slot.value.named(), wanted)) continue;
        weft.focusOrCreateBuffer(slot.name());
        _ = weft.designate(slot.value.named());
        return;
    }
    weft.setResultStr("repl: that interpreter has exited");
}
/// Start a REPL running arg0 (default `sh` — a shell REPL; pass e.g.
/// "python3 -u", "node", "nix repl") in a buffer of its own. Note:
/// pipe-buffered interpreters may need an unbuffered flag (python `-u`) to
/// stream promptly.
fn start() void {
    reap();
    const slot = sessions.open("repl") orelse return weft.echo("repl: out of memory — could not open another interpreter");
    const handle = weft.replStart(weft.argStr(0) orelse "sh", slot.name()) orelse
        return sessions.close(slot);
    slot.value = .{ .handle = handle };
    if (weft.placeDesignation(&slot.value.place_buf)) |named| slot.value.place_len = named.len;
    // `open` created and focused the session's buffer: declare what it is.
    if (procDesignation(slot.name(), &slot.value.named_buf)) |named| {
        slot.value.named_len = named.len;
        _ = weft.designate(named);
    }
    publish(slot.value.place());
}

/// `weft://here/proc/<instance>` for the buffer `*repl*` / `*repl:N*`.
fn procDesignation(buffer: []const u8, out: []u8) ?[]const u8 {
    const bare = std.mem.trim(u8, buffer, "*");
    var id: [64]u8 = undefined;
    if (bare.len == 0 or bare.len > id.len) return null;
    @memcpy(id[0..bare.len], bare);
    std.mem.replaceScalar(u8, id[0..bare.len], ':', '.');
    return std.fmt.bufPrint(out, "weft://here/proc/{s}", .{id[0..bare.len]}) catch null;
}

/// Send arg0 to this entry's REPL.
fn send() void {
    reap();
    const slot = sessions.current("repl") orelse return;
    weft.replSend(slot.value.handle, weft.argStr(0) orelse return);
}
/// Send the current line to this entry's REPL.
fn sendLine() void {
    reap();
    const slot = sessions.current("repl") orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    weft.replSend(slot.value.handle, weft.slice(l.start, l.end));
}
/// Quit this entry's REPL only; every other session stays live.
fn quit() void {
    reap();
    const slot = sessions.current("repl") orelse return;
    weft.replQuit(slot.value.handle);
    retire(slot);
}

/// Close a session's slot and say what is live in its place now.
fn retire(slot: *Sessions.Slot) void {
    var place_buf: [1024]u8 = undefined;
    const place = place_buf[0..slot.value.place_len];
    @memcpy(place, slot.value.place());
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
        if (weft.replExited(slot.value.handle) == null) continue;
        weft.replQuit(slot.value.handle);
        retire(slot);
    }
}

/// Publish the most recent live session opened in `place` as `repl.session`
/// on that place, or retract the key there when none is left. The place is
/// named by its designation, so this speaks for the place a session was
/// started in wherever the command runs — a quit from another project, a
/// reap noticed from anywhere.
fn publish(place: []const u8) void {
    if (place.len == 0) return;
    var newest: ?*Sessions.Slot = null;
    for (sessions.slots.items) |slot| {
        if (!std.mem.eql(u8, slot.value.place(), place)) continue;
        if (newest == null or slot.opened > newest.?.opened) newest = slot;
    }
    const value = if (newest) |slot| slot.value.named() else "";
    weft.contextSetAt(session_key, value, place) catch |err| {
        var buf: [96]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&buf, "repl: could not publish {s}: {t}", .{ session_key, err }) catch session_key);
    };
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = init }).exportAll();
}
