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

const std = @import("std");
const weft = @import("weft");

const max_consoles = 8;
const name_cap = 32;

const Console = struct {
    buf: [name_cap]u8,
    buf_len: usize,

    fn name(self: *const Console) []const u8 {
        return self.buf[0..self.buf_len];
    }
};

var consoles: [max_consoles]?Console = @splat(null);
var recent: ?usize = null;
var cmd_buf: [1 << 12]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "console-open", .handler = open },
    .{ .name = "console-send", .handler = send },
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

/// Open a console of its own.
fn open() void {
    const slot = freeSlot() orelse return weft.echo("console: too many consoles");
    var name_buf: [name_cap]u8 = undefined;
    const ordinal = weft.instanceOrdinal("console") orelse return;
    const name = weft.instanceName("console", ordinal, &name_buf) orelse return;
    weft.runStr("buffer-create", name);
    var c: Console = .{ .buf = undefined, .buf_len = name.len };
    @memcpy(c.buf[0..name.len], name);
    consoles[slot] = c;
    recent = slot;
}

/// Run the current line as a command; its output appends to that console.
fn send() void {
    const slot = current() orelse return; // resolve first: reading the line reuses the scratch
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end);
    if (line.len == 0) return;
    const n = @min(line.len, cmd_buf.len);
    @memcpy(cmd_buf[0..n], line[0..n]); // copy — the read scratch is reused below
    weft.procAppendBuffer(cmd_buf[0..n], consoles[slot].?.name(), 0);
}

fn freeSlot() ?usize {
    for (consoles, 0..) |c, i| if (c == null) return i;
    return null;
}

/// The console a send appends to: the focused one, else the most recent —
/// named on the status line so output never lands out of sight silently.
fn current() ?usize {
    var name_buf: [name_cap]u8 = undefined;
    if (weft.activeBufferName(&name_buf)) |active| {
        for (consoles, 0..) |maybe, i| {
            const c = maybe orelse continue;
            if (std.mem.eql(u8, c.name(), active)) {
                recent = i;
                return i;
            }
        }
    }
    const slot = recent orelse return null;
    const c = consoles[slot] orelse return null;
    var msg: [name_cap + 11]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&msg, "console: {s}", .{c.name()}) catch return slot);
    return slot;
}
