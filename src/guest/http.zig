//! http — a minimal HTTP/1.0 client (design: "HTTP is built in the guest over a
//! Sock; only TLS is native"), a `.wasm` plugin (perms `{net}`). `http-get`
//! parses a URL, dials it (TLS for https via the native transport), sends a GET,
//! and streams the raw response into a target buffer (default `*http*`, or an
//! explicit trailing arg — each target is its own instance, so several
//! outstanding GETs coexist). This is what turns the `net.connect` transport
//! into something an agent adapter can build on.

const std = @import("std");
const weft = @import("weft");

const default_buf = "*http*";
var url_buf: [1024]u8 = undefined;
var hostport_buf: [512]u8 = undefined;
var req_buf: [1536]u8 = undefined;

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
/// runs — it's just unaddressable for a later close-on-reopen.
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

/// GET arg0 (a URL) into arg1 (the target buffer, default `*http*`); the raw
/// HTTP response streams into it.
fn get() void {
    const raw = weft.argStr(0) orelse return;
    const u = parse(raw) orelse return;
    const name = weft.argStr(1) orelse default_buf;
    if (take(name)) |h| weft.netClose(h); // reopening the same target replaces it
    weft.runStr("buffer-create", name);
    const h = weft.netConnect(u.hostport, name, if (u.tls) u.host else "") orelse return;
    store(name, h);
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: weft\r\nConnection: close\r\n\r\n", .{ u.path, u.host }) catch return;
    weft.netSend(h, req);
}
