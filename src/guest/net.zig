//! net — raw network access (design §4 Group D `net.connect`), a `.wasm` plugin
//! (perms `{net}`). `net-open`/`net-open-tls` dial a host, streaming the socket
//! into a target buffer (default `*net*`, or an explicit trailing arg); a
//! connection is addressed by that buffer name, so several can coexist —
//! `net-send`/`net-close` take the same optional name. This is the TRANSPORT
//! primitive — HTTP/nREPL/etc. framing is built in the guest over it (design:
//! only TLS is native). Host-side sessions are already multi-instance
//! (`net_session.zig`); this table is only the guest's own handle→name index.

const std = @import("std");
const weft = @import("weft");

const default_buf = "*net*";
var host_buf: [512]u8 = undefined;
var sni_buf: [256]u8 = undefined;

const max_conns = 8;
const Conn = struct { name_buf: [64]u8 = undefined, name_len: u8 = 0, handle: u32 = 0 };
var conns: [max_conns]?Conn = .{null} ** max_conns;

fn connName(c: *const Conn) []const u8 {
    return c.name_buf[0..c.name_len];
}
fn find(name: []const u8) ?usize {
    for (conns, 0..) |slot, i| {
        if (slot) |c| if (std.mem.eql(u8, connName(&c), name)) return i;
    }
    return null;
}
/// Record `handle` under `name` (reusing its slot if already tracked, else
/// the first free one). Past `max_conns` live names the connection still
/// runs — it's just unaddressable by a later send/close.
fn store(name: []const u8, handle: u32) void {
    var c = Conn{ .handle = handle };
    const n = @min(name.len, c.name_buf.len);
    @memcpy(c.name_buf[0..n], name[0..n]);
    c.name_len = @intCast(n);
    const i = find(name) orelse blk: {
        for (&conns, 0..) |*slot, i| if (slot.* == null) break :blk i;
        return;
    };
    conns[i] = c;
}
fn take(name: []const u8) ?u32 {
    const i = find(name) orelse return null;
    return conns[i].?.handle;
}
fn drop(name: []const u8) void {
    if (find(name)) |i| conns[i] = null;
}

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

/// arg0 = host:port, arg1 = the target buffer (default `*net*`).
fn open() void {
    dial(weft.argStr(0) orelse return, "", weft.argStr(1) orelse default_buf);
}
/// TLS: arg0 = host:port, arg1 = the SNI/verification host name, arg2 = the
/// target buffer (default `*net*`).
fn openTls() void {
    const host = weft.argStr(0) orelse return;
    const n = @min(host.len, host_buf.len);
    @memcpy(host_buf[0..n], host[0..n]); // copy — later argStr calls reuse the scratch
    const sni = weft.argStr(1) orelse "";
    const sn = @min(sni.len, sni_buf.len);
    @memcpy(sni_buf[0..sn], sni[0..sn]);
    dial(host_buf[0..n], sni_buf[0..sn], weft.argStr(2) orelse default_buf);
}
fn dial(host: []const u8, sni: []const u8, name: []const u8) void {
    if (take(name)) |h| weft.netClose(h); // reopening the same target replaces it
    weft.runStr("buffer-create", name);
    const h = weft.netConnect(host, name, sni) orelse return;
    store(name, h);
}
fn send() void {
    const name = weft.argStr(1) orelse default_buf;
    const h = take(name) orelse return;
    weft.netSend(h, weft.argStr(0) orelse return);
}
fn close() void {
    const name = weft.argStr(0) orelse default_buf;
    if (take(name)) |h| {
        weft.netClose(h);
        drop(name);
    }
}
