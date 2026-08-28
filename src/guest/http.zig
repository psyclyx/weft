//! http — a minimal HTTP/1.0 client (design: "HTTP is built in the guest over a
//! Sock; only TLS is native"), a `.wasm` plugin (perms `{net}`). `http-get`
//! parses a URL, dials it (TLS for https via the native transport), sends a GET,
//! and streams the raw response into a buffer. This is what turns the
//! `net.connect` transport into something an agent adapter can build on.
//!
//! Every GET is an INSTANCE, like a REPL or a console: it takes a fresh buffer
//! (`*http*`, `*http:2*`, …), so two requests in flight never overwrite each
//! other's response. A GET is one-shot, though, and the host reaps a net session
//! only on close — so this plugin hangs up the oldest request rather than
//! leaking one connection per GET.

const std = @import("std");
const weft = @import("weft");

/// Each outstanding request, keyed by the buffer its response streams into;
/// the value is its host session handle.
var conns: weft.Instances(u32) = .{};

/// How many GETs may be outstanding at once. Unlike the instance tables this
/// plugin's neighbours used to carry, this IS a policy, and it is not about the
/// table: a GET is one-shot and nobody ever closes it, while the host reaps a
/// net session only on close — so without a bound, `http-get` in a loop leaks
/// one host connection per call. The bound therefore lives next to the resource
/// it protects instead of riding on the height of a fixed array.
const max_outstanding = 8;

var url_buf: [1024]u8 = undefined;
var hostport_buf: [512]u8 = undefined;
var req_buf: [1536]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "http-get", .handler = get },
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

const Url = struct { tls: bool, host: []const u8, hostport: []const u8, path: []const u8 };

/// Parse `scheme://host[:port][/path]` into `url_buf`/`hostport_buf` (copied so
/// the source arg-scratch can be reused). Defaults: port 80/443, path "/".
fn parse(raw: []const u8) ?Url {
    const n = @min(raw.len, url_buf.len);
    @memcpy(url_buf[0..n], raw[0..n]);
    var s = url_buf[0..n];

    var tls = false;
    if (std.mem.startsWith(u8, s, "https://")) {
        tls = true;
        s = s[8..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s[7..];
    }
    // Split host[:port] from /path.
    const slash = std.mem.indexOfScalar(u8, s, '/');
    const authority = if (slash) |i| s[0..i] else s;
    const path = if (slash) |i| s[i..] else "/";
    if (authority.len == 0) return null;

    const host = if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority[0..c] else authority;
    // Build "host:port" (defaulting the port) into a stable buffer.
    const hp = if (std.mem.indexOfScalar(u8, authority, ':') != null)
        std.fmt.bufPrint(&hostport_buf, "{s}", .{authority}) catch return null
    else
        std.fmt.bufPrint(&hostport_buf, "{s}:{s}", .{ authority, if (tls) "443" else "80" }) catch return null;
    return .{ .tls = tls, .host = host, .hostport = hp, .path = path };
}

/// GET arg0 (a URL); the raw HTTP response streams into a buffer of its own.
fn get() void {
    const u = parse(weft.argStr(0) orelse return) orelse return;
    if (conns.slots.items.len >= max_outstanding) retire();
    const slot = conns.open("http") orelse
        return weft.echo("http: out of memory — could not start another request");
    slot.value = weft.netConnect(u.hostport, slot.name(), if (u.tls) u.host else "") orelse
        return conns.close(slot);
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: weft\r\nConnection: close\r\n\r\n", .{ u.path, u.host }) catch return;
    weft.netSend(slot.value, req);
}

/// Hang up the longest-outstanding request to make room for a new one.
fn retire() void {
    const old = conns.oldest() orelse return;
    weft.netClose(old.value);
    conns.close(old);
}
