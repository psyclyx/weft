//! console — a command console (design §6.3, comint-flavored), a `.wasm` plugin
//! (perms `{proc, timer}`). `console-open` focuses a *console* buffer; typing a
//! command and running `console-send` appends its output below via the native
//! `proc` APPEND surface. This is the STATELESS end of the REPL story — each
//! line is an independent command. A stateful REPL (python -i, nREPL, keeping
//! session state) needs a persistent interactive-proc session, the next tier.

const std = @import("std");
const weft = @import("weft");

const console = "*console*";
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

/// Focus (create) the console buffer.
fn open() void {
    weft.runStr("buffer-create", console);
}

/// Run the current line as a command; its output appends to the console.
fn send() void {
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end);
    if (line.len == 0) return;
    const n = @min(line.len, cmd_buf.len);
    @memcpy(cmd_buf[0..n], line[0..n]); // copy — procAppendBuffer reads later ABI
    weft.procAppendBuffer(cmd_buf[0..n], console, 0);
}
