//! jsonrpc — the JSON-RPC layer (design: doc/lsp.md), a SHARED guest module, not
//! a plugin. It sits between the host's raw streaming membrane (`weft.procSpawn`/
//! `procSend`/`procRead`) and a protocol plugin (`lsp`, a future `dap`): it owns
//! `Content-Length` framing, request↔response correlation, and message parsing,
//! and nothing protocol-specific. LSP and DAP both speak JSON-RPC, so both import
//! this — compile-time shared, no cross-plugin calls.
//!
//! Freestanding-wasm shaped, but NOT fixed-buffer: storage grows over the guest
//! wasm heap (`weft.allocator`), so a message's size is bounded by wasm memory,
//! not a compile-time constant. The rx accumulator and every outgoing envelope
//! grow on demand; a document too large to marshal whole (multi-gig, stemma's
//! territory) is streamed frame-by-frame via `beginFrame`/`writeChunk` so it is
//! never held in one allocation. Parsing owns a per-message arena (freed on the
//! next `next()`); a returned `Value` is valid until then.

const std = @import("std");
const weft = @import("weft");

pub const Value = std.json.Value;

fn a() std.mem.Allocator {
    return weft.allocator;
}

/// A JSON-RPC connection over one raw stream. The caller owns the storage
/// (`var conn: Conn = .{}` then `conn.start(cmd)`); its buffers grow on the heap,
/// so hold it by pointer, never by value.
pub const Conn = struct {
    stream: u32 = 0,
    live: bool = false,
    seq: i64 = 1,

    /// Accumulates raw stream bytes until a full `Content-Length` frame is present
    /// (grows to the largest single message the server sends).
    rx: std.ArrayListUnmanaged(u8) = .empty,
    /// Owns the CURRENT parsed message's arena; freed on the next `next()`.
    parsed: ?std.json.Parsed(Value) = null,

    pub fn start(self: *Conn, cmd: []const u8) bool {
        self.stream = weft.procSpawn(cmd) orelse return false;
        self.rx.clearRetainingCapacity();
        self.seq = 1;
        self.live = true;
        return true;
    }

    pub fn close(self: *Conn) void {
        if (self.live) weft.procClose(self.stream);
        self.live = false;
        if (self.parsed) |*pp| {
            pp.deinit();
            self.parsed = null;
        }
        self.rx.clearAndFree(a());
    }

    /// Send a request; returns its id (correlate the response by it). `params` is
    /// a ready JSON value (object/array text) the protocol layer built. The
    /// envelope grows to any params size; -1 on OOM.
    pub fn request(self: *Conn, method: []const u8, params: []const u8) i64 {
        const id = self.seq;
        self.seq += 1;
        const body = std.fmt.allocPrint(
            a(),
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params },
        ) catch return -1;
        defer a().free(body);
        self.frameAndSend(body);
        return id;
    }

    /// Send a notification (no id, no response). Grows to any params size.
    pub fn notify(self: *Conn, method: []const u8, params: []const u8) void {
        const body = std.fmt.allocPrint(
            a(),
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params },
        ) catch return;
        defer a().free(body);
        self.frameAndSend(body);
    }

    fn frameAndSend(self: *Conn, body: []const u8) void {
        self.beginFrame(body.len);
        self.writeChunk(body);
    }

    // ── Streamed send (bodies too large to hold whole) ──────────────────
    // Emit the header with the total body length, then push the body in parts.
    // The caller computes `body_len` up front (a size pass) and must write EXACTLY
    // that many bytes across `writeChunk` calls — LSP framing has no terminator.

    pub fn beginFrame(self: *Conn, body_len: usize) void {
        var hdr: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body_len}) catch return;
        weft.procSend(self.stream, h);
    }

    pub fn writeChunk(self: *Conn, bytes: []const u8) void {
        weft.procSend(self.stream, bytes);
    }

    /// Drain the stream and return the NEXT complete message parsed, or null when
    /// none is buffered yet. Call in a loop from the plugin's `on_poll`:
    /// `while (conn.next()) |msg| handle(msg);`. The returned `Value` borrows the
    /// message arena — read it before the next `next()`.
    pub fn next(self: *Conn) ?Value {
        if (self.parsed) |*pp| {
            pp.deinit();
            self.parsed = null;
        }
        self.pull();
        const data = self.rx.items;
        // Header block ends at the first CRLFCRLF.
        const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const header = data[0..sep];
        const clen = parseContentLength(header) orelse {
            // Malformed header — drop it to resync rather than wedge.
            self.consume(sep + 4);
            return null;
        };
        const body_start = sep + 4;
        if (self.rx.items.len < body_start + clen) return null; // body not all here yet
        const body = self.rx.items[body_start .. body_start + clen];
        const parsed = std.json.parseFromSlice(Value, a(), body, .{}) catch {
            self.consume(body_start + clen);
            return null;
        };
        self.consume(body_start + clen); // safe: the arena holds its own copy
        self.parsed = parsed;
        return parsed.value;
    }

    /// Pull all currently-available stream bytes into `rx` (grows as needed).
    fn pull(self: *Conn) void {
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            const got = weft.procRead(self.stream, &chunk);
            if (got.len == 0) break;
            self.rx.appendSlice(a(), got) catch return; // OOM: stop pulling this round
            if (got.len < chunk.len) break; // stream drained for now
        }
    }

    fn consume(self: *Conn, n: usize) void {
        const k = @min(n, self.rx.items.len);
        const rest = self.rx.items.len - k;
        std.mem.copyForwards(u8, self.rx.items[0..rest], self.rx.items[k..]);
        self.rx.shrinkRetainingCapacity(rest);
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
