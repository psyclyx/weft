//! debug — breakpoints: the first slice of a debugger. Toggle a breakpoint on
//! the cursor's line and a gutter marker (●) shows it. This establishes the
//! `debug-*` command surface and the breakpoint MODEL a DAP adapter will consume
//! next; "set a breakpoint" is real here — run / step / inspect are the follow-on
//! increment (a debug-adapter subprocess, mirroring the ACP agent's shape).
//!
//! Breakpoints are PER-BUFFER — keyed by the buffer path from `on_activate` — so
//! switching files keeps each file's breakpoints. They are display-only gutter
//! decorations (perms `{}`): never a document byte, so `yy` never yanks one and
//! they take no commit. Stored as line-start offsets in fixed scratch (no
//! allocator). Limitation (first slice): an edit ABOVE a breakpoint shifts its
//! stored offset until the next re-render — a proper anchor comes with the
//! adapter work.

const std = @import("std");
const weft = @import("weft.zig");

const MAX_BP = 128;
const PATHLEN = 256;
var bp_path: [MAX_BP][PATHLEN]u8 = undefined;
var bp_plen: [MAX_BP]usize = undefined;
var bp_off: [MAX_BP]usize = undefined; // line-start byte offset of the breakpoint
var bp_n: usize = 0;

// The focused buffer's path (from on_activate) — which file a toggle/render acts on.
var cur_path: [PATHLEN]u8 = undefined;
var cur_plen: usize = 0;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "debug-toggle-breakpoint", .handler = toggle },
    .{ .name = "debug-clear-breakpoints", .handler = clearAll },
    .{ .name = "debug-list-breakpoints", .handler = list },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The focused buffer changed: track its path and repaint ITS breakpoints (the
/// decorations layer is per-buffer, so a switch would otherwise show nothing).
export fn on_activate() void {
    const p = weft.activatePath();
    cur_plen = @min(p.len, PATHLEN);
    @memcpy(cur_path[0..cur_plen], p[0..cur_plen]);
    render();
}

fn samePath(i: usize) bool {
    return bp_plen[i] == cur_plen and
        std.mem.eql(u8, bp_path[i][0..bp_plen[i]], cur_path[0..cur_plen]);
}

fn findBp(off: usize) ?usize {
    var i: usize = 0;
    while (i < bp_n) : (i += 1) if (samePath(i) and bp_off[i] == off) return i;
    return null;
}

fn removeAt(i: usize) void {
    bp_n -= 1;
    bp_path[i] = bp_path[bp_n];
    bp_plen[i] = bp_plen[bp_n];
    bp_off[i] = bp_off[bp_n];
}

/// Toggle a breakpoint on the cursor's line.
fn toggle() void {
    const off = weft.lineAt(weft.cursor()).start;
    if (findBp(off)) |i| {
        removeAt(i);
        weft.echo("debug: breakpoint cleared");
    } else if (bp_n < MAX_BP) {
        bp_plen[bp_n] = cur_plen;
        @memcpy(bp_path[bp_n][0..cur_plen], cur_path[0..cur_plen]);
        bp_off[bp_n] = off;
        bp_n += 1;
        weft.echo("debug: breakpoint set");
    } else {
        weft.echo("debug: too many breakpoints");
    }
    render();
}

/// Clear every breakpoint in the focused buffer.
fn clearAll() void {
    var i: usize = 0;
    while (i < bp_n) {
        if (samePath(i)) removeAt(i) else i += 1;
    }
    weft.echo("debug: breakpoints cleared");
    render();
}

fn list() void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bp_n) : (i += 1) if (samePath(i)) {
        n += 1;
    };
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "debug: {d} breakpoint(s)", .{n}) catch return;
    weft.echo(msg);
}

/// Repaint the focused buffer's breakpoints as gutter markers. `decorateClear`
/// targets the active buffer's decorations layer (breakpoints are the only
/// code-buffer decorator today — dired's live on *dired*).
fn render() void {
    weft.decorateClear();
    var i: usize = 0;
    while (i < bp_n) : (i += 1) if (samePath(i)) {
        weft.decorate(bp_off[i], .gutter, .removed, "\u{25CF}"); // ● in red-ish (removed)
    };
}
