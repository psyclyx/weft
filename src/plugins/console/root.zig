//! console — command consoles (design §6.3, comint-flavored), a `.wasm` plugin
//! (perms `{proc, timer}`). `console.open` opens a console buffer; typing a
//! command and running `console.send` appends its output below via the native
//! `proc` APPEND surface. This is the STATELESS end of the REPL story — each
//! line is an independent command. A stateful REPL (python -i, nREPL, keeping
//! session state) is the `repl` plugin's persistent interactive-proc session.
//!
//! Consoles are INSTANCES: each open takes a fresh buffer (`*console*`,
//! `*console:2*`, …), so two of them keep separate logs. A send appends to the
//! focused console, else to the most recent one — echoing which.

const std = @import("std");
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
    .{ .name = "console.open", .call = open, .arity = .whole, .summary = "Open a new command console in its own buffer.", .label = "New Console", .menu = "Terminal", .group = "new", .order = 2, .icon = "terminal" },
    .{ .name = "console.send", .arity = .one, .call = send, .summary = "Run the current line in this console.", .label = "Send Line to Console" },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}

/// Open a console of its own.
fn open() void {
    const slot = consoles.open("console") orelse return weft.echo("console: out of memory — could not open another console");
    // `open` created and focused the console's buffer. It is a live resource
    // (doc/model.md §2.1) — `weft://here/proc/console`, `…/console.2` — that
    // designates something only while this plugin runs it.
    const bare = std.mem.trim(u8, slot.name(), "*");
    var id: [64]u8 = undefined;
    if (bare.len == 0 or bare.len > id.len) return;
    @memcpy(id[0..bare.len], bare);
    std.mem.replaceScalar(u8, id[0..bare.len], ':', '.');
    var named: [96]u8 = undefined;
    _ = weft.designate(std.fmt.bufPrint(&named, "weft://here/proc/{s}", .{id[0..bare.len]}) catch return);
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
