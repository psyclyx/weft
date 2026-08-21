//! jsonrpc — the JSON-RPC layer (design: doc/lsp.md), a SHARED guest module, not
//! a plugin. It sits between the host's raw streaming membrane (`weft.procSpawn`/
//! `procSend`/`procRead`) and a protocol plugin (`lsp`, a future `dap`): it owns
//! `Content-Length` framing, request↔response correlation, and message parsing,
//! and nothing protocol-specific. LSP and DAP both speak JSON-RPC, so both import
//! this — compile-time shared, no cross-plugin calls.
//!
//! Freestanding-wasm shaped: fixed buffers, no ambient allocator. Parsing uses
//! `std.json` over a `FixedBufferAllocator` on an owned arena, reset per message;
//! a returned `Value` is valid until the next `next()`.

const std = @import("std");
const weft = @import("weft.zig");

pub const Value = std.json.Value;

/// A JSON-RPC connection over one raw stream. The caller owns the storage
/// (`var conn: Conn = .{}` then `conn.start(cmd)`) — it's ~½ MiB of buffers, so
/// never pass it by value.
pub const Conn = struct {
    stream: u32 = 0,
    live: bool = false,
    seq: i64 = 1,

    /// Accumulates raw stream bytes until a full `Content-Length` frame is present.
    rx: [1 << 19]u8 = undefined, // 512 KiB — caps the largest single message
    rxlen: usize = 0,
    /// Backs the parse of the CURRENT message (reset every `next`).
    arena: [1 << 19]u8 = undefined,
    /// Assembles an outgoing envelope.
    tx: [1 << 18]u8 = undefined,

    pub fn start(self: *Conn, cmd: []const u8) bool {
        self.stream = weft.procSpawn(cmd) orelse return false;
        self.rxlen = 0;
        self.seq = 1;
        self.live = true;
        return true;
    }

    pub fn close(self: *Conn) void {
        if (self.live) weft.procClose(self.stream);
        self.live = false;
    }

    /// Send a request; returns its id (correlate the response by it). `params` is
    /// a ready JSON value (object/array text) the protocol layer built.
    pub fn request(self: *Conn, method: []const u8, params: []const u8) i64 {
        const id = self.seq;
        self.seq += 1;
        const body = std.fmt.bufPrint(
            &self.tx,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params },
        ) catch return -1;
        self.frameAndSend(body);
        return id;
    }

    /// Send a notification (no id, no response).
    pub fn notify(self: *Conn, method: []const u8, params: []const u8) void {
        const body = std.fmt.bufPrint(
            &self.tx,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params },
        ) catch return;
        self.frameAndSend(body);
    }

    fn frameAndSend(self: *Conn, body: []const u8) void {
        var hdr: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        weft.procSend(self.stream, h);
        weft.procSend(self.stream, body);
    }

    /// Drain the stream and return the NEXT complete message parsed, or null when
    /// none is buffered yet. Call in a loop from the plugin's `on_poll`:
    /// `while (conn.next()) |msg| handle(msg);`. The returned `Value` borrows the
    /// arena — read it before the next `next()`.
    pub fn next(self: *Conn) ?Value {
        self.pull();
        const data = self.rx[0..self.rxlen];
        // Header block ends at the first CRLFCRLF.
        const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const header = data[0..sep];
        const clen = parseContentLength(header) orelse {
            // Malformed header — drop it to resync rather than wedge.
            self.consume(sep + 4);
            return null;
        };
        const body_start = sep + 4;
        if (self.rxlen < body_start + clen) return null; // body not all here yet
        const body = self.rx[body_start .. body_start + clen];
        var fba = std.heap.FixedBufferAllocator.init(&self.arena);
        const v = std.json.parseFromSliceLeaky(Value, fba.allocator(), body, .{}) catch {
            self.consume(body_start + clen);
            return null;
        };
        self.consume(body_start + clen);
        return v;
    }

    /// Pull all currently-available stream bytes into `rx` (bounded by capacity;
    /// an over-cap message is dropped by the framer, not corrupted).
    fn pull(self: *Conn) void {
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            const got = weft.procRead(self.stream, &chunk);
            if (got.len == 0) break;
            if (self.rxlen + got.len <= self.rx.len) {
                @memcpy(self.rx[self.rxlen..][0..got.len], got);
                self.rxlen += got.len;
            }
            if (got.len < chunk.len) break; // stream drained for now
        }
    }

    fn consume(self: *Conn, n: usize) void {
        const k = @min(n, self.rxlen);
        std.mem.copyForwards(u8, self.rx[0 .. self.rxlen - k], self.rx[k..self.rxlen]);
        self.rxlen -= k;
    }
};

/// Parse the `Content-Length` value out of a header block (case-sensitive, as
/// LSP/DAP emit it).
fn parseContentLength(header: []const u8) ?usize {
    const key = "Content-Length:";
    const at = std.mem.indexOf(u8, header, key) orelse return null;
    var i = at + key.len;
    while (i < header.len and header[i] == ' ') i += 1;
    var n: usize = 0;
    var any = false;
    while (i < header.len and header[i] >= '0' and header[i] <= '9') : (i += 1) {
        n = n * 10 + (header[i] - '0');
        any = true;
    }
    return if (any) n else null;
}
