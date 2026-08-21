//! lsp — a Language Server Protocol client, as a fast wasm guest (design:
//! doc/lsp.md). Layer 3: it imports the shared `jsonrpc` framing (layer 2) over
//! the host's raw streaming membrane (layer 1) and adds only LSP semantics —
//! which methods to send, what each result means, how it's presented through the
//! editor membrane (echo / jump / pick / edit / decorate).
//!
//! Async shape: a request is fired from a command and its response arrives later,
//! on `on_poll` (the host calls it when the server stream has bytes). State is a
//! small machine: spawn → initialize → (initialized + didOpen) → serve requests.
//!
//! Phase 2 is hover against one server (zls). Definition/references/symbols/
//! diagnostics/… layer on by adding a `Want` variant + a response handler.

const std = @import("std");
const weft = @import("weft.zig");
const rpc = @import("jsonrpc.zig");

// ── Connection state ─────────────────────────────────────────────────
var conn: rpc.Conn = .{};
var init_id: i64 = 0; // the `initialize` request id
var ready: bool = false; // initialize answered + initialized/didOpen sent
var opened: bool = false; // didOpen sent for the current document

// The user request awaiting the server (one in flight for now).
const Want = enum { none, hover };
var want: Want = .none;
var want_off: usize = 0;
var want_id: i64 = 0;

// The open document's `file://` uri.
var uri_buf: [1200]u8 = undefined;
var uri_len: usize = 0;

// Scratch for building JSON params / escaping text.
var parambuf: [4096]u8 = undefined;
var textbuf: [1 << 18]u8 = undefined; // JSON-escaped document text for didOpen

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "lsp-hover", .handler = hoverCmd },
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

/// The host calls this when the server stream has bytes: drain every complete
/// message and dispatch it.
export fn on_poll() void {
    while (conn.next()) |msg| dispatch(msg);
}

// ── Commands ─────────────────────────────────────────────────────────
fn hoverCmd() void {
    ensureServer();
    want = .hover;
    want_off = weft.cursor();
    if (ready) sendWant();
    // else: fired once `initialize` is answered (see dispatch).
}

// ── Lifecycle ────────────────────────────────────────────────────────
fn ensureServer() void {
    if (conn.live) return;
    if (!conn.start("zls")) {
        weft.echo("lsp: could not start server");
        return;
    }
    ready = false;
    opened = false;
    // initialize: minimal capabilities; rootUri null (single-file analysis).
    init_id = conn.request("initialize",
        \\{"processId":null,"rootUri":null,"capabilities":{"textDocument":{"hover":{"contentFormat":["plaintext","markdown"]},"synchronization":{}}}}
    );
}

/// Send the pending request now that the server is ready.
fn sendWant() void {
    syncDoc();
    switch (want) {
        .none => {},
        .hover => {
            const pos = posOf(want_off);
            const params = std.fmt.bufPrint(
                &parambuf,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ uri_buf[0..uri_len], pos.line, pos.col },
            ) catch return;
            want_id = conn.request("textDocument/hover", params);
        },
    }
}

/// didOpen the current document once (full-text sync for now — didChange comes
/// with the diagnostics phase).
fn syncDoc() void {
    if (opened) return;
    buildUri();
    const n = @min(weft.byteLen(), textbuf.len / 6); // escaping can grow ~6x worst case
    const raw = weft.slice(0, n);
    const esc = jsonEscape(raw);
    const params = std.fmt.bufPrint(
        &parambuf,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"zig\",\"version\":1,\"text\":\"{s}\"}}}}",
        .{ uri_buf[0..uri_len], esc },
    ) catch return;
    conn.notify("textDocument/didOpen", params);
    opened = true;
}

fn buildUri() void {
    const path = weft.path() orelse "untitled";
    // `file://` + path. Relative paths still work for single-file hover (zls
    // keys the doc by uri and analyses the didOpen text); an absolute-uri pass
    // arrives with the multi-file/project phase.
    const s = std.fmt.bufPrint(&uri_buf, "file://{s}", .{path}) catch {
        uri_len = 0;
        return;
    };
    uri_len = s.len;
}

// ── Response dispatch ────────────────────────────────────────────────
fn dispatch(msg: rpc.Value) void {
    if (msg != .object) return;
    const obj = msg.object;
    // A response carries an id.
    if (obj.get("id")) |idv| {
        const id = asInt(idv) orelse return;
        if (id == init_id and !ready) {
            ready = true;
            conn.notify("initialized", "{}");
            if (want != .none) sendWant();
            return;
        }
        if (id == want_id) {
            const result = obj.get("result") orelse return;
            switch (want) {
                .hover => presentHover(result),
                .none => {},
            }
            want = .none;
        }
        return;
    }
    // Otherwise a notification (publishDiagnostics, …) — handled in later phases.
}

fn presentHover(result: rpc.Value) void {
    // hover.contents is a MarkupContent {kind,value}, a string, or a list.
    const text: []const u8 = switch (result) {
        .object => |o| blk: {
            const c = o.get("contents") orelse break :blk "";
            break :blk contentsText(c);
        },
        else => "",
    };
    if (text.len == 0) {
        weft.echo("lsp: no hover");
        return;
    }
    weft.echo(text);
}

fn contentsText(c: rpc.Value) []const u8 {
    return switch (c) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |v| (if (v == .string) v.string else "") else "",
        .array => |a| if (a.items.len > 0) contentsText(a.items[0]) else "",
        else => "",
    };
}

// ── Helpers ──────────────────────────────────────────────────────────
const Pos = struct { line: usize, col: usize };
/// Offset → 0-based LSP position. ASCII columns for now (UTF-16 handling comes
/// with the cross-file phase); line count scans in scratch-sized chunks.
fn posOf(offset: usize) Pos {
    var line: usize = 0;
    var pos: usize = 0;
    while (pos < offset) {
        const s = weft.slice(pos, offset);
        if (s.len == 0) break;
        for (s) |ch| {
            if (ch == '\n') line += 1;
        }
        pos += s.len;
    }
    const ls = weft.lineAt(offset).start;
    return .{ .line = line, .col = offset - ls };
}

fn asInt(v: rpc.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// JSON-escape `raw` into `textbuf`; returns the escaped slice.
fn jsonEscape(raw: []const u8) []const u8 {
    var w: usize = 0;
    for (raw) |c| {
        if (w + 6 > textbuf.len) break;
        switch (c) {
            '"' => {
                textbuf[w] = '\\';
                textbuf[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                textbuf[w] = '\\';
                textbuf[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                textbuf[w] = '\\';
                textbuf[w + 1] = 'n';
                w += 2;
            },
            '\r' => {
                textbuf[w] = '\\';
                textbuf[w + 1] = 'r';
                w += 2;
            },
            '\t' => {
                textbuf[w] = '\\';
                textbuf[w + 1] = 't';
                w += 2;
            },
            0...8, 11, 12, 14...31 => {
                const hex = "0123456789abcdef";
                textbuf[w] = '\\';
                textbuf[w + 1] = 'u';
                textbuf[w + 2] = '0';
                textbuf[w + 3] = '0';
                textbuf[w + 4] = hex[(c >> 4) & 0xf];
                textbuf[w + 5] = hex[c & 0xf];
                w += 6;
            },
            else => {
                textbuf[w] = c;
                w += 1;
            },
        }
    }
    return textbuf[0..w];
}
