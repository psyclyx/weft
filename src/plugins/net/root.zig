//! net — raw network access (design §4 Group D `net.connect`), a `.wasm` plugin
//! (perms `{net}`). `net-open`/`net-open-tls` dial a host, streaming the socket
//! into a buffer; `net-send` writes bytes; `net-close` hangs up. This is the
//! TRANSPORT primitive — HTTP/nREPL/etc. framing is built in the guest over it
//! (design: only TLS is native).
//!
//! Connections are INSTANCES, like REPLs and consoles: every open takes a fresh
//! buffer (`*net*`, `*net:2*`, …) and is addressed by it, so a second dial never
//! hangs up the first. `net-send`/`net-close` act on the connection whose buffer
//! is focused, else the most recent — echoing which. Host-side sessions were
//! already multi-instance (`net_session.zig`); this table is the guest's own
//! buffer→handle index.

const weft = @import("weft");

/// Each live connection, keyed by the buffer its socket streams into; the
/// value is its host session handle.
var conns: weft.Instances(u32) = .{};

var host_buf: [512]u8 = undefined;
var sni_buf: [256]u8 = undefined;

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): it is what the palette shows beside the row,
/// what the `:` line hints while you type, and what gets ASKED for when you
/// run `net-open` without saying where.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]Cmd{
    .{ .name = "net-open", .handler = open, .params = "host:port", .summary = "Dial a host, streaming the socket into its own buffer." },
    .{ .name = "net-open-tls", .handler = openTls, .params = "host:port sni", .summary = "Dial a host over TLS, verifying the given SNI name." },
    .{ .name = "net-send", .handler = send, .params = "bytes", .summary = "Write bytes to this buffer's connection." },
    .{ .name = "net-close", .handler = close, .summary = "Hang up this buffer's connection; others stay live." },
};

export fn describe() void {
    for (cmds) |c| weft.describeCommand(c.name, c.params, c.summary);
    weft.requestPerm(.net);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// arg0 = host:port.
fn open() void {
    dial(weft.argStr(0) orelse return, "");
}
/// TLS: arg0 = host:port, arg1 = the SNI/verification host name.
fn openTls() void {
    const host = weft.argStr(0) orelse return;
    const n = @min(host.len, host_buf.len);
    @memcpy(host_buf[0..n], host[0..n]); // copy — a second argStr reuses the scratch
    const sni = weft.argStr(1) orelse "";
    const sn = @min(sni.len, sni_buf.len);
    @memcpy(sni_buf[0..sn], sni[0..sn]);
    dial(host_buf[0..n], sni_buf[0..sn]);
}
fn dial(host: []const u8, sni: []const u8) void {
    const slot = conns.open("net") orelse return weft.echo("net: out of memory — could not open another connection");
    slot.value = weft.netConnect(host, slot.name(), sni) orelse return conns.close(slot);
}
/// Send arg0 to this entry's connection.
fn send() void {
    const slot = conns.current("net") orelse return;
    weft.netSend(slot.value, weft.argStr(0) orelse return);
}
/// Hang up this entry's connection only; every other one stays live.
fn close() void {
    const slot = conns.current("net") orelse return;
    weft.netClose(slot.value);
    conns.close(slot);
}
