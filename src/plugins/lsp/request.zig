//! lsp — REQUEST IDENTITY: one in-flight slot per (session, kind).
//!
//! Completion, hover and definition are concurrently in flight under their
//! own rpc ids, because they are different KINDS; a second ask of the SAME
//! kind supersedes the first — the server is told `$/cancelRequest`, the slot
//! is given back, and the superseded reply, arriving under an id nothing
//! claims, is dropped rather than misapplied.
//!
//! Every send captures an opaque document witness, so a reply can only ever
//! land in the buffer that asked.

const std = @import("std");
const weft = @import("weft");
const rpc = @import("weft_jsonrpc");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Kind = session_mod.Kind;
const kind_count = session_mod.kind_count;
const Pending = session_mod.Pending;
const reqParams = session_mod.reqParams;
const PickTarget = session_mod.PickTarget;
const captureTarget = session_mod.captureTarget;
const releaseTarget = session_mod.releaseTarget;
const targetOffset = session_mod.targetOffset;
const syncDoc = session_mod.syncDoc;
const Pos = session_mod.Pos;
const posOf = session_mod.posOf;

pub fn slotOf(s: *Session, kind: Kind) *Pending {
    return &s.pending[@intFromEnum(kind)];
}

/// The ask `id` belongs to, if it is still ours to answer. A superseded or
/// abandoned ask has already given its slot back, so its late reply finds
/// nothing here and is dropped.
pub fn findPending(s: *Session, id: i64) ?struct { *Pending, Kind } {
    for (&s.pending, 0..) |*p, k| {
        if (p.used and p.id == id) return .{ p, @enumFromInt(k) };
    }
    return null;
}

pub fn cancelRequest(s: *Session, id: i64) void {
    var buf: [48]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return;
    s.conn.notify("$/cancelRequest", params);
}

/// Give a slot back: the server is asked to stop (where it honors
/// `$/cancelRequest`), the captured witness and cursor identity are released,
/// and a completion's caps session is declined so the merge is never left
/// waiting on us.
pub fn retire(s: *Session, p: *Pending) void {
    if (!p.used) return;
    if (p.id > 0) cancelRequest(s, p.id);
    if (p.snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    if (p.target) |target| releaseTarget(target);
    if (p.caps != 0) weft.capsDecline(p.caps);
    p.* = .{};
}

/// Arm an ask of `kind` against the cursor, superseding this session's previous
/// one of the same kind.
pub fn arm(s: *Session, kind: Kind) ?*Pending {
    const p = slotOf(s, kind);
    retire(s, p);
    p.target = captureTarget(weft.cursor()) orelse return null;
    p.used = true;
    return p;
}

/// Put an armed ask on the wire. The slot is given back (and the caps session
/// declined) whenever the document it captured is no longer the one in front of
/// us — a request whose answer could not be interpreted is not worth sending.
pub fn send(s: *Session, p: *Pending, kind: Kind) bool {
    if (!s.conn.live) {
        retire(s, p);
        return false;
    }
    if (!syncDoc(s)) {
        if (kind != .completion) weft.echo("lsp: could not synchronize document");
        retire(s, p);
        return false;
    }
    const offset = targetOffset(p.target orelse {
        retire(s, p);
        return false;
    }) orelse {
        retire(s, p);
        return false;
    };
    if (p.snapshot) |snapshot| {
        weft.releaseDocSnapshot(snapshot);
        p.snapshot = null;
    }
    p.snapshot = weft.docSnapshot() orelse {
        retire(s, p);
        return false;
    };
    const id = requestOf(s, kind, posOf(offset));
    if (id < 0) {
        if (kind != .completion) weft.echo("lsp: could not send request");
        retire(s, p);
        return false;
    }
    p.id = id;
    return true;
}

/// Send every ask this session has armed but not yet dispatched. Called when the
/// handshake lands and when the session's document takes focus — the two moments
/// a deferred ask becomes sendable.
pub fn flushArmed(s: *Session) void {
    for (&s.pending, 0..) |*p, k| {
        if (!p.used or p.id != 0) continue;
        const kind: Kind = @enumFromInt(k);
        if (kind == .rename and s.rename.len == 0) continue; // still prompting
        _ = send(s, p, kind);
    }
}

/// Build and fire the wire request for `kind`. -1 when the parameters or the
/// envelope don't fit.
pub fn requestOf(s: *Session, kind: Kind, pos: Pos) i64 {
    const uri = s.uri;
    return switch (kind) {
        .hover => posRequest(s, "textDocument/hover", pos, ""),
        .definition => posRequest(s, "textDocument/definition", pos, ""),
        .references => posRequest(s, "textDocument/references", pos, ",\"context\":{\"includeDeclaration\":true}"),
        .signature => posRequest(s, "textDocument/signatureHelp", pos, ""),
        .completion => posRequest(s, "textDocument/completion", pos, ""),
        .symbols => s.conn.request("textDocument/documentSymbol", reqParams(
            "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
            .{uri},
        ) orelse return -1),
        .format => s.conn.request("textDocument/formatting", reqParams(
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}",
            .{uri},
        ) orelse return -1),
        .rename => s.conn.request("textDocument/rename", reqParams(
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"{s}\"}}",
            .{ uri, pos.line, pos.col, s.rename },
        ) orelse return -1),
        .inlay => blk: {
            const last = posOf(weft.byteLen());
            break :blk s.conn.request("textDocument/inlayHint", reqParams(
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}}}",
                .{ uri, last.line + 1 },
            ) orelse return -1);
        },
        // Actions for the cursor's line, passing any diagnostics on it as
        // context (so quick-fixes surface).
        .codeaction => s.conn.request("textDocument/codeAction", reqParams(
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}",
            .{ uri, pos.line, pos.line + 1 },
        ) orelse return -1),
    };
}

/// A position-based request: `{textDocument, position[, extra]}`.
pub fn posRequest(s: *Session, method: []const u8, pos: Pos, extra: []const u8) i64 {
    return s.conn.request(method, reqParams(
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}{s}}}",
        .{ s.uri, pos.line, pos.col, extra },
    ) orelse return -1);
}

// Hover popup: capped row count (mirrors the view's `Hud.max_hover_rows` —
// this guest doesn't depend on `gfx/view`, so the cap is repeated here as a
// plain constant, not imported).
pub const max_hover_rows = 16;
