//! net — raw network access (design §4 Group D `net.connect`), a `.wasm` plugin
//! (perms `{net}`). `net-open`/`net-open-tls` dial a host, streaming the socket
//! into a *net* buffer; `net-send` writes bytes; `net-close` hangs up. This is
//! the TRANSPORT primitive — HTTP/nREPL/etc. framing is built in the guest over
//! it (design: only TLS is native). A single connection at a time here; a
//! richer client keys many.

const std = @import("std");
const weft = @import("weft.zig");

const net_buf = "*net*";
var host_buf: [512]u8 = undefined;
var conn: ?u32 = null;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "net-open", .handler = open },
    .{ .name = "net-open-tls", .handler = openTls },
    .{ .name = "net-send", .handler = send },
    .{ .name = "net-close", .handler = close },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.net);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn open() void {
    dial(weft.argStr(0) orelse return, "");
}
/// TLS: arg0 = host:port, arg1 = the SNI/verification host name.
fn openTls() void {
    const host = weft.argStr(0) orelse return;
    const n = @min(host.len, host_buf.len);
    @memcpy(host_buf[0..n], host[0..n]); // copy — a second argStr reuses the scratch
    dial(host_buf[0..n], weft.argStr(1) orelse "");
}
fn dial(host: []const u8, sni: []const u8) void {
    if (conn) |h| weft.netClose(h);
    weft.runStr("buffer-create", net_buf);
    conn = weft.netConnect(host, net_buf, sni);
}
fn send() void {
    const h = conn orelse return;
    weft.netSend(h, weft.argStr(0) orelse return);
}
fn close() void {
    if (conn) |h| {
        weft.netClose(h);
        conn = null;
    }
}
