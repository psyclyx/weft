//! lsp — a Language Server Protocol client, as a fast wasm guest (design:
//! doc/lsp.md). Layer 3: it imports the shared `jsonrpc` framing (layer 2) over
//! the host's raw streaming membrane (layer 1) and adds only LSP semantics —
//! which methods to send, what each result means, how it's presented through the
//! editor membrane (echo / jump / pick).
//!
//! Async shape: a request is fired from a command; its response arrives later on
//! `on_poll` (the host calls it when the server stream has bytes). State is a
//! small machine: spawn → initialize → (initialized + didOpen) → serve requests.
//! Each feature is a `Want` variant + a params builder + a response handler.

const std = @import("std");
const weft = @import("weft");
const rpc = @import("jsonrpc.zig");

// ── Connection state ─────────────────────────────────────────────────
var conn: rpc.Conn = .{};
var init_id: i64 = 0; // the `initialize` request id
var ready: bool = false; // initialize answered + initialized/didOpen sent
var opened: bool = false; // didOpen sent for the current document
// Change tracking: the host owns an opaque witness for the exact causal
// frontier last streamed to the server. The plugin can test equality, but it
// cannot inspect or order the witness. `doc_version` is separate: an integer
// required by the external LSP protocol and never used as a CRDT clock.
var synced_snapshot: ?u32 = null;
var doc_version: i64 = 1;

fn releaseSyncedSnapshot() void {
    if (synced_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    synced_snapshot = null;
}

// The user request awaiting the server (one in flight).
const Want = enum { none, hover, definition, references, symbols, format, rename, signature, inlay, codeaction };
var want: Want = .none;
var want_id: i64 = 0;

// Rename: the new name typed into the prompt pick, sent once the server's ready.
const pick_id_rename: u32 = 2;
var rename_name: [256]u8 = undefined;
var rename_nlen: usize = 0;

// The open document's `file://` uri.
var uri_buf: [1200]u8 = undefined;
var uri_len: usize = 0;
// The language the current connection serves (from the active file's extension).
// A different-language file restarts the connection with that language's server.
// (One active server at a time; concurrent multi-server is a refinement.)
var cur_lang: [16]u8 = undefined;
var cur_lang_len: usize = 0;

// A location pick (references / symbols): retained CRDT targets index-aligned
// to the entries. LSP byte positions are converted once when presented; edits
// while the picker is open move the target anchors rather than redirecting a
// stored raw offset.
const pick_id_results: u32 = 1;
const PickTarget = struct { range: u32, at_end: bool };
var pick_targets: [256]PickTarget = undefined;
var pick_n: usize = 0;

fn captureTarget(offset: usize) ?PickTarget {
    const len = weft.byteLen();
    const at = @min(offset, len);
    const at_end = at == len;
    const target = weft.anchorRange(.{ .start = at, .end = if (at_end) at else at + 1 }) orelse return null;
    if (!weft.retainRange(target)) {
        weft.releaseRange(target);
        return null;
    }
    return .{ .range = target, .at_end = at_end };
}

fn targetOffset(target: PickTarget) ?usize {
    const current = weft.rangeEnds(target.range) orelse return null;
    return if (target.at_end) current.end else current.start;
}

fn releaseTarget(target: PickTarget) void {
    weft.releaseRange(target.range);
}

fn releasePickTargets() void {
    for (pick_targets[0..pick_n]) |target| weft.releaseRange(target.range);
    pick_n = 0;
}

fn resetPickTargets() void {
    // End the old interaction before releasing its guest-side resources. The
    // Head owns one picker, so this also makes replacing results reentrant.
    weft.run("pick-cancel");
    releasePickTargets();
}

fn addPickTarget(offset: usize) bool {
    if (pick_n >= pick_targets.len) return false;
    pick_targets[pick_n] = captureTarget(offset) orelse return false;
    pick_n += 1;
    return true;
}

// One in-flight LSP request owns a cursor target plus an opaque snapshot
// witness captured after didChange and immediately before request send. The
// witness supports equality only: no version bytes, arithmetic, or ordering
// cross the plugin boundary.
var want_target: ?PickTarget = null;
var want_snapshot: ?u32 = null;

fn releaseWantSnapshot() void {
    if (want_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    want_snapshot = null;
}

fn cancelWant() void {
    releaseWantSnapshot();
    if (want_target) |target| releaseTarget(target);
    want_target = null;
    want = .none;
}

fn prepareWant(kind: Want) bool {
    cancelWant();
    want_target = captureTarget(weft.cursor()) orelse return false;
    want = kind;
    return true;
}

// Hover popup: capped row count (mirrors the view's `Hud.max_hover_rows` —
// this guest doesn't depend on `gfx/view`, so the cap is repeated here as a
// plain constant, not imported).
const max_hover_rows = 16;

// Diagnostics pushed by the server (publishDiagnostics): offset + severity +
// packed message, for gutter markers and `]d`/`[d` navigation.
const MAX_DIAG = 256;
var diag_targets: [MAX_DIAG]PickTarget = undefined;
var diag_sev: [MAX_DIAG]u8 = undefined;
var diag_moff: [MAX_DIAG]usize = undefined;
var diag_mlen: [MAX_DIAG]usize = undefined;
var diag_msgs: [1 << 14]u8 = undefined;
var diag_n: usize = 0;
var diag_snapshot: ?u32 = null;
const DiagnosticProvenance = enum { versioned, legacy_unversioned };
var diag_provenance: DiagnosticProvenance = .legacy_unversioned;

fn releaseDiagnostics() void {
    for (diag_targets[0..diag_n]) |target| releaseTarget(target);
    diag_n = 0;
    if (diag_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    diag_snapshot = null;
}

// Completion is an async caps PROVIDER, not a command — its own pending slot,
// independent of `want`. `on_complete(session)` sends textDocument/completion and
// defers; the response commits rich items into that session (see complete_ui).
var comp_session: u32 = 0;
var comp_id: i64 = 0;
var comp_snapshot: ?u32 = null;

fn cancelCompletion() void {
    if (comp_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    comp_snapshot = null;
    if (comp_session != 0) weft.capsDecline(comp_session);
    comp_session = 0;
}

var parambuf: [4096]u8 = undefined; // small position/range params (bounded)

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "hover", .handler = cmdHover },
    .{ .name = "goto-definition", .handler = cmdDefinition },
    .{ .name = "references", .handler = cmdReferences },
    .{ .name = "symbols", .handler = cmdSymbols },
    .{ .name = "next-diagnostic", .handler = cmdNextDiag },
    .{ .name = "prev-diagnostic", .handler = cmdPrevDiag },
    .{ .name = "lsp-format", .handler = cmdFormat },
    .{ .name = "rename", .handler = cmdRename },
    .{ .name = "signature-help", .handler = cmdSignature },
    .{ .name = "inlay-hints", .handler = cmdInlay },
    .{ .name = "code-actions", .handler = cmdCodeActions },
    // Internal: the deferred half of `on_poll`'s message dispatch (task #19
    // item 4) — not a user-facing verb, invoked only via `weft.run` from
    // `on_poll` itself. See `on_poll`'s doc.
    .{ .name = "lsp-deliver-internal", .handler = lspDeliverInternal },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.declareCapability("edit/completion");
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    weft.provideCompletion();
}

/// Completion request (caps provider): send textDocument/completion for the
/// cursor and DEFER — the response commits into `session` off a later poll. If
/// there's no server for this buffer's language (or it isn't ready yet), decline
/// so the merge isn't left waiting on us.
export fn on_complete(session: u32) void {
    cancelCompletion();
    ensureServer();
    if (!ready) {
        weft.capsDecline(session);
        return;
    }
    if (!syncDoc()) {
        weft.capsDecline(session);
        return;
    }
    comp_snapshot = weft.docSnapshot() orelse {
        weft.capsDecline(session);
        return;
    };
    const pos = posOf(weft.cursor());
    const params = std.fmt.bufPrint(
        &parambuf,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ uri_buf[0..uri_len], pos.line, pos.col },
    ) catch {
        if (comp_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
        comp_snapshot = null;
        weft.capsDecline(session);
        return;
    };
    comp_id = conn.request("textDocument/completion", params);
    if (comp_id < 0) {
        if (comp_snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
        comp_snapshot = null;
        weft.capsDecline(session);
        return;
    }
    comp_session = session;
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Drain every complete server message and dispatch it. BACKGROUND (task #19
/// item 4): `dispatch` (below) presents results through `weft.echo`/
/// `weft.pick` — both head-gated, and `on_poll` has no dispatching head to
/// route them through directly. Defer each message through a self-
/// registered command instead: a nested `weft.run` from a background entry
/// IS a dispatching entry for its duration (`wasm_host/plugin.zig`'s
/// `requireDispatch` doc — the sanctioned door), so `lspDeliverInternal`
/// runs with a real one. `pending_msg` is valid synchronously across the
/// nested call (nothing re-parses `conn`'s buffer until the NEXT loop
/// iteration's `conn.next()`).
export fn on_poll() void {
    while (conn.next()) |msg| {
        pending_msg = msg;
        weft.run("lsp-deliver-internal");
    }
}

var pending_msg: rpc.Value = undefined;
fn lspDeliverInternal() void {
    dispatch(pending_msg);
}

/// A buffer took focus: if it's a zig file, ensure the server is up and the doc
/// is opened, so diagnostics flow without waiting for a request. (Single-server,
/// single-language for now — multi-server routing is a later phase.)
export fn on_activate() void {
    var lb: [16]u8 = undefined;
    const lang = activeLang(&lb);
    cancelWant();
    cancelCompletion();
    releaseDiagnostics();
    weft.decorateClear();
    releaseSyncedSnapshot();
    if (pick_n > 0) resetPickTargets();
    opened = false;
    // Only files whose language has a configured server participate. Cleanup
    // still happens above so retained state cannot leak across buffer loci.
    if (serverCmd(lang).len == 0) return;
    ensureServer();
    // A different file → re-open under its uri.
    buildUri();
    if (ready) _ = syncDoc();
}

/// A pick entry was chosen: a location jump, or the rename name.
export fn on_pick_accept(pick_id: u32) void {
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    if (pick_id == pick_id_results) {
        defer releasePickTargets();
        const idx = switch (outcome) {
            .candidate => |candidate| candidate.index,
            .input, .cancelled => return,
        };
        if (idx < pick_n) {
            const target = pick_targets[idx];
            weft.jump(targetOffset(target) orelse return);
        }
        return;
    }
    if (pick_id == pick_id_rename) {
        const name = switch (outcome) {
            .candidate => |candidate| candidate.text,
            .input => |input| input,
            .cancelled => {
                cancelWant();
                return;
            },
        }; // owned by `outcome` until this callback returns
        if (name.len == 0) {
            cancelWant();
            return;
        }
        rename_nlen = @min(name.len, rename_name.len);
        @memcpy(rename_name[0..rename_nlen], name[0..rename_nlen]);
        if (ready) sendWant();
    }
}

// ── Commands ─────────────────────────────────────────────────────────
fn cmdHover() void {
    fire(.hover);
}
fn cmdDefinition() void {
    fire(.definition);
}
fn cmdReferences() void {
    fire(.references);
}
fn cmdSymbols() void {
    fire(.symbols);
}
fn cmdNextDiag() void {
    gotoDiag(true);
}
fn cmdPrevDiag() void {
    gotoDiag(false);
}
fn cmdFormat() void {
    fire(.format);
}
fn cmdSignature() void {
    fire(.signature);
}
fn cmdInlay() void {
    fire(.inlay);
}
fn cmdCodeActions() void {
    fire(.codeaction);
}
/// Rename the symbol under the cursor. With an arg, use it as the new name; else
/// prompt (a free-text pick). On accept the request goes out (see on_pick_accept).
fn cmdRename() void {
    ensureServer();
    if (!prepareWant(.rename)) return;
    if (weft.argStr(0)) |name| {
        if (name.len > 0) {
            rename_nlen = @min(name.len, rename_name.len);
            @memcpy(rename_name[0..rename_nlen], name[0..rename_nlen]);
            if (ready) sendWant();
            return;
        }
    }
    resetPickTargets();
    weft.pickBegin("rename to", pick_id_rename);
    weft.pickEnd(); // no items — the typed query is the new name
}

/// Jump to the next/previous stored diagnostic from the cursor (wrapping) and
/// echo its severity + message.
fn gotoDiag(fwd: bool) void {
    if (diag_n == 0) {
        weft.echo("lsp: no diagnostics");
        return;
    }
    const snapshot = diag_snapshot orelse {
        releaseDiagnostics();
        weft.decorateClear();
        weft.echo("lsp: diagnostics became stale");
        return;
    };
    if (!weft.docSnapshotIsCurrent(snapshot)) {
        releaseDiagnostics();
        weft.decorateClear();
        weft.echo("lsp: diagnostics became stale");
        return;
    }
    const cur = weft.cursor();
    const Located = struct { index: usize, offset: usize };
    var best: ?Located = null; // nearest strictly after/before
    var wrap: ?Located = null; // extreme for wrap-around
    var i: usize = 0;
    while (i < diag_n) : (i += 1) {
        const off = targetOffset(diag_targets[i]) orelse continue;
        if (fwd) {
            if (off > cur and (best == null or off < best.?.offset)) best = .{ .index = i, .offset = off };
            if (wrap == null or off < wrap.?.offset) wrap = .{ .index = i, .offset = off };
        } else {
            if (off < cur and (best == null or off > best.?.offset)) best = .{ .index = i, .offset = off };
            if (wrap == null or off > wrap.?.offset) wrap = .{ .index = i, .offset = off };
        }
    }
    const located = best orelse wrap orelse {
        weft.echo("lsp: diagnostics became stale");
        return;
    };
    const idx = located.index;
    weft.jump(located.offset);
    const label: []const u8 = switch (diag_sev[idx]) {
        1 => "error",
        2 => "warning",
        3 => "info",
        else => "hint",
    };
    var buf: [1024]u8 = undefined;
    const msg = diag_msgs[diag_moff[idx]..][0..diag_mlen[idx]];
    const line = switch (diag_provenance) {
        .versioned => std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, msg }) catch label,
        .legacy_unversioned => std.fmt.bufPrint(&buf, "{s} (unverified server position): {s}", .{ label, msg }) catch label,
    };
    weft.echo(line);
}

fn fire(kind: Want) void {
    ensureServer();
    if (!prepareWant(kind)) return;
    if (ready) sendWant();
}

// ── Lifecycle ────────────────────────────────────────────────────────
/// The active file's language id (its extension), copied out of scratch.
fn activeLang(out: *[16]u8) []const u8 {
    const path = weft.path() orelse return "";
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    const ext = path[dot + 1 ..];
    const n = @min(ext.len, out.len);
    @memcpy(out[0..n], ext[0..n]);
    return out[0..n];
}

/// The server command for `lang`: config (`weft.set("lsp","<lang>","<cmd>")`), or
/// a built-in default. "" ⇒ no server for this language.
fn serverCmd(lang: []const u8) []const u8 {
    const c = weft.config(lang);
    if (c.len > 0) return c;
    if (std.mem.eql(u8, lang, "zig")) return "zls";
    return "";
}

/// Ensure a server is running for the ACTIVE file's language, starting (or
/// switching) the connection as needed.
fn ensureServer() void {
    var lb: [16]u8 = undefined;
    const lang = activeLang(&lb);
    if (conn.live and std.mem.eql(u8, lang, cur_lang[0..cur_lang_len])) return;
    if (conn.live) conn.close();
    cancelWant();
    cancelCompletion();
    releaseSyncedSnapshot();
    releaseDiagnostics();
    weft.decorateClear();
    ready = false;
    opened = false;
    const cmd = serverCmd(lang);
    if (cmd.len == 0) return; // no server configured for this language
    if (!conn.start(cmd)) {
        weft.echo("lsp: could not start server");
        return;
    }
    cur_lang_len = @min(lang.len, cur_lang.len);
    @memcpy(cur_lang[0..cur_lang_len], lang[0..cur_lang_len]);
    init_id = conn.request("initialize",
        \\{"processId":null,"rootUri":null,"capabilities":{"textDocument":{"hover":{"contentFormat":["plaintext","markdown"]},"synchronization":{},"publishDiagnostics":{"versionSupport":true}}}}
    );
}

/// Send the pending request now that the server is ready.
fn sendWant() void {
    if (want == .none) return;
    // Invalidate the prior request id before any fallible parameter build.
    // A late response to the superseded request can then only be ignored.
    want_id = -1;
    if (!syncDoc()) {
        weft.echo("lsp: could not synchronize document");
        cancelWant();
        return;
    }
    const target = want_target orelse {
        cancelWant();
        return;
    };
    const offset = targetOffset(target) orelse {
        cancelWant();
        return;
    };
    releaseWantSnapshot();
    want_snapshot = weft.docSnapshot() orelse {
        cancelWant();
        return;
    };
    const pos = posOf(offset);
    switch (want) {
        .none => {},
        .hover => want_id = posRequest("textDocument/hover", pos, ""),
        .definition => want_id = posRequest("textDocument/definition", pos, ""),
        .references => want_id = posRequest("textDocument/references", pos, ",\"context\":{\"includeDeclaration\":true}"),
        .symbols => blk: {
            const params = std.fmt.bufPrint(&parambuf, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{uri_buf[0..uri_len]}) catch {
                want_id = -1;
                break :blk;
            };
            want_id = conn.request("textDocument/documentSymbol", params);
        },
        .format => blk: {
            const params = std.fmt.bufPrint(&parambuf, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}", .{uri_buf[0..uri_len]}) catch {
                want_id = -1;
                break :blk;
            };
            want_id = conn.request("textDocument/formatting", params);
        },
        .rename => blk: {
            const params = std.fmt.bufPrint(
                &parambuf,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"{s}\"}}",
                .{ uri_buf[0..uri_len], pos.line, pos.col, rename_name[0..rename_nlen] },
            ) catch {
                want_id = -1;
                break :blk;
            };
            want_id = conn.request("textDocument/rename", params);
        },
        .signature => want_id = posRequest("textDocument/signatureHelp", pos, ""),
        .inlay => blk: {
            const last = posOf(weft.byteLen());
            const params = std.fmt.bufPrint(
                &parambuf,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}}}",
                .{ uri_buf[0..uri_len], last.line + 1 },
            ) catch {
                want_id = -1;
                break :blk;
            };
            want_id = conn.request("textDocument/inlayHint", params);
        },
        .codeaction => blk: {
            // Actions for the cursor's line, passing any diagnostics on it as
            // context (so quick-fixes surface).
            const params = std.fmt.bufPrint(
                &parambuf,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}",
                .{ uri_buf[0..uri_len], pos.line, pos.line + 1 },
            ) catch {
                want_id = -1;
                break :blk;
            };
            want_id = conn.request("textDocument/codeAction", params);
        },
    }
    if (want_id < 0) {
        weft.echo("lsp: could not send request");
        cancelWant();
    }
}

/// A position-based request: `{textDocument, position[, extra]}`.
fn posRequest(method: []const u8, pos: Pos, extra: []const u8) i64 {
    const params = std.fmt.bufPrint(
        &parambuf,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}{s}}}",
        .{ uri_buf[0..uri_len], pos.line, pos.col, extra },
    ) catch return -1;
    return conn.request(method, params);
}

/// Keep the server's copy current: didOpen once, then didChange (full-text)
/// whenever the last opaque causal-frontier witness no longer equals the live
/// document. Called before every request, so coordinate-bearing responses can
/// be accepted only against the exact text the server saw.
///
/// STREAMED, never held whole: stemma docs can be multi-gig, and a wasm32 guest
/// can't hold that in one allocation. We frame the JSON-RPC envelope with the
/// exact body length (a chunked size pass), then push the envelope prefix, the
/// document escaped chunk-by-chunk (each chunk read via `slice`, escaped on the
/// growable heap, sent, freed), and the suffix. Two full reads of the doc — the
/// price of not materializing it — bounded by the server's appetite, not us.
fn syncDoc() bool {
    if (opened) {
        if (synced_snapshot) |snapshot| {
            if (weft.docSnapshotIsCurrent(snapshot)) return true;
        }
    }
    if (!conn.live) return false;
    buildUri();
    const alloc = weft.allocator;
    const uri = uri_buf[0..uri_len];
    const total = weft.byteLen();

    // The JSON-RPC envelope around the (streamed) document text. `params` is the
    // {textDocument…text:"} … "} object; the envelope wraps it.
    const prefix = if (!opened) blk: {
        doc_version = 1;
        break :blk std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\",\"version\":1,\"text\":\"", .{ uri, cur_lang[0..cur_lang_len] }) catch return false;
    } else blk: {
        doc_version += 1;
        break :blk std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}},\"contentChanges\":[{{\"text\":\"", .{ uri, doc_version }) catch return false;
    };
    defer alloc.free(prefix);
    const suffix: []const u8 = if (!opened) "\"}}}" else "\"}]}}";

    // Size pass: escaped byte count of the whole document (chunked, no hold).
    var esc_total: usize = 0;
    {
        var pos: usize = 0;
        while (pos < total) {
            const chunk = weft.slice(pos, total); // ≤ slice scratch per call
            if (chunk.len == 0) break;
            esc_total += escapedLen(chunk);
            pos += chunk.len;
        }
    }

    // Frame + stream: header, prefix, escaped chunks, suffix.
    conn.beginFrame(prefix.len + esc_total + suffix.len);
    conn.writeChunk(prefix);
    {
        var esc: std.ArrayListUnmanaged(u8) = .empty;
        defer esc.deinit(alloc);
        var pos: usize = 0;
        while (pos < total) {
            const chunk = weft.slice(pos, total);
            if (chunk.len == 0) break;
            esc.clearRetainingCapacity();
            escapeAppend(&esc, chunk) catch return false; // OOM mid-frame desyncs; rare, bounded
            conn.writeChunk(esc.items);
            pos += chunk.len;
        }
    }
    conn.writeChunk(suffix);

    if (!opened) opened = true;
    releaseSyncedSnapshot();
    synced_snapshot = weft.docSnapshot();
    return synced_snapshot != null;
}

fn buildUri() void {
    // Copy the (possibly scratch-backed) path out before calling cwd (also
    // scratch). Absolute paths pass through; relative ones get the cwd prefix, so
    // the uri matches the absolute uris a server returns in its locations.
    var pbuf: [1024]u8 = undefined;
    const path = weft.path() orelse "untitled";
    const pn = @min(path.len, pbuf.len);
    @memcpy(pbuf[0..pn], path[0..pn]);
    const pc = pbuf[0..pn];
    const s = if (pn > 0 and pc[0] == '/')
        std.fmt.bufPrint(&uri_buf, "file://{s}", .{pc}) catch return
    else
        std.fmt.bufPrint(&uri_buf, "file://{s}/{s}", .{ weft.cwd(), pc }) catch return;
    uri_len = s.len;
}

// ── Response dispatch ────────────────────────────────────────────────
fn dispatch(msg: rpc.Value) void {
    if (msg != .object) return;
    const obj = msg.object;
    if (obj.get("id")) |idv| {
        const id = asInt(idv) orelse return;
        if (id == init_id and !ready) {
            ready = true;
            conn.notify("initialized", "{}");
            _ = syncDoc(); // didOpen the active doc → diagnostics start flowing
            if (want != .none) sendWant();
            return;
        }
        if (comp_session != 0 and id == comp_id) {
            const snapshot = comp_snapshot orelse {
                cancelCompletion();
                return;
            };
            if (!weft.docSnapshotIsCurrent(snapshot)) {
                cancelCompletion();
                return;
            }
            weft.releaseDocSnapshot(snapshot);
            comp_snapshot = null;
            presentCompletion(obj.get("result") orelse rpc.Value{ .null = {} });
            return;
        }
        if (id == want_id) {
            const snapshot = want_snapshot orelse {
                cancelWant();
                return;
            };
            if (!weft.docSnapshotIsCurrent(snapshot)) {
                // The server answered coordinates from an older document.
                // Keep the request's CRDT target, sync, and ask again against
                // a fresh opaque witness; never reinterpret stale positions.
                releaseWantSnapshot();
                if (want != .none) sendWant();
                return;
            }
            releaseWantSnapshot();
            const result = obj.get("result") orelse rpc.Value{ .null = {} };
            switch (want) {
                .hover => presentHover(result),
                .definition => presentDefinition(result),
                .references => presentLocations(result, "reference"),
                .symbols => presentSymbols(result),
                .format => weft.echo(if (applyEdits(result) > 0) "lsp: formatted" else "lsp: nothing to format"),
                .rename => weft.echo(if (applyWorkspaceEdit(result) > 0) "lsp: renamed" else "lsp: rename made no change"),
                .signature => presentSignature(result),
                .inlay => presentInlay(result),
                .codeaction => presentCodeActions(result),
                .none => {},
            }
            cancelWant();
        }
        return;
    }
    // A notification: only publishDiagnostics matters to us.
    if (obj.get("method")) |m| {
        if (m == .string and std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
            onDiagnostics(obj.get("params"));
        }
    }
}

/// Store the server's diagnostics for the current doc and mark them in the
/// gutter. Replaces the previous set (a publish is the whole list for the uri).
fn onDiagnostics(params: ?rpc.Value) void {
    const p = params orelse return;
    if (p != .object) return;
    if (p.object.get("uri")) |u| {
        if (u == .string and !sameUri(u.string)) return;
    }
    const synced = synced_snapshot orelse {
        releaseDiagnostics();
        weft.decorateClear();
        return;
    };
    if (!weft.docSnapshotIsCurrent(synced)) {
        releaseDiagnostics();
        weft.decorateClear();
        return;
    }
    // Push diagnostics have no request id. A server-provided version proves
    // which LSP snapshot produced the coordinates; malformed/mismatched values
    // fail closed. Some widely deployed servers omit this optional field even
    // after versionSupport is advertised. Keep that case explicitly typed as
    // legacy/unverified: it may drive non-destructive presentation/navigation,
    // but must never become an edit precondition or feed a code action.
    diag_provenance = if (p.object.get("version")) |version| blk: {
        const reported = asInt(version) orelse return;
        if (reported != doc_version) return;
        break :blk .versioned;
    } else .legacy_unversioned;
    releaseDiagnostics();
    diag_snapshot = weft.docSnapshot() orelse return;
    var mw: usize = 0;
    var dropped = false;
    weft.decorateClear();
    const list = p.object.get("diagnostics") orelse {
        releaseDiagnostics();
        return;
    };
    if (list != .array) {
        releaseDiagnostics();
        return;
    }
    for (list.array.items) |d| {
        if (d != .object) continue;
        if (diag_n >= MAX_DIAG) {
            dropped = true;
            continue;
        }
        const rng = d.object.get("range") orelse continue;
        const pos = posInRange(rng) orelse continue;
        const off = offsetOf(pos.line, pos.col);
        const msg = if (d.object.get("message")) |mm| (if (mm == .string) mm.string else "") else "";
        const sev: u8 = if (d.object.get("severity")) |s| (if (s == .integer) @intCast(@max(1, @min(4, s.integer))) else 1) else 1;
        diag_targets[diag_n] = captureTarget(off) orelse continue;
        diag_sev[diag_n] = sev;
        const ml = @min(msg.len, diag_msgs.len - mw);
        @memcpy(diag_msgs[mw..][0..ml], msg[0..ml]);
        diag_moff[diag_n] = mw;
        diag_mlen[diag_n] = ml;
        mw += ml;
        diag_n += 1;
        weft.decorate(weft.lineAt(off).start, .gutter, if (sev == 1) .removed else .emphasis, if (sev == 1) "\u{25CF}" else "\u{25B2}");
    }
    if (diag_n == 0) releaseDiagnostics();
    if (dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} diagnostics — some omitted", .{MAX_DIAG}));
}

/// Code actions for the line. Applies the first action that carries an inline
/// `edit` (a quick-fix WorkspaceEdit) and echoes its title; a pick of titles is a
/// refinement (holding N edits needs cross-poll storage). Command-only actions
/// (needing a resolve/execute round-trip) just report their title.
fn presentCodeActions(result: rpc.Value) void {
    if (result != .array or result.array.items.len == 0) {
        weft.echo("lsp: no code actions");
        return;
    }
    for (result.array.items) |a| {
        if (a != .object) continue;
        const title = if (a.object.get("title")) |t| (if (t == .string) t.string else "action") else "action";
        if (a.object.get("edit")) |edit| {
            if (applyWorkspaceEdit(edit) > 0) {
                var b: [256]u8 = undefined;
                weft.echo(std.fmt.bufPrint(&b, "lsp: code action applied — '{s}'", .{title}) catch "lsp: code action applied");
                return;
            }
        }
    }
    // Actions exist but none had an inline in-file edit (command/resolve kind).
    const first = result.array.items[0];
    const title = if (first == .object) (if (first.object.get("title")) |t| (if (t == .string) t.string else "") else "") else "";
    var b: [256]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&b, "lsp: code action '{s}' (needs resolve)", .{title}) catch "lsp: code action");
}

/// Convert an LSP completion response into rich items and commit them into the
/// pending session. Handles both a bare `CompletionItem[]` and a
/// `CompletionList{items}`; carries label / insertText / detail / kind /
/// documentation across to the merge + info popup. Capped so a huge list can't
/// blow the frame. An empty result still commits (answers the session).
fn presentCompletion(result: rpc.Value) void {
    const session = comp_session;
    comp_session = 0;
    const items: []const rpc.Value = switch (result) {
        .array => |a| a.items,
        .object => |o| if (o.get("items")) |it| (if (it == .array) it.array.items else &.{}) else &.{},
        else => &.{},
    };
    var rank: i32 = 0;
    for (items) |it| {
        if (rank >= 200) break;
        if (it != .object) continue;
        const o = it.object;
        const label = strOf(o.get("label"));
        if (label.len == 0) continue;
        const ins = strOf(o.get("insertText"));
        const kind: u8 = if (o.get("kind")) |k| (if (k == .integer) @intCast(@max(0, @min(255, k.integer))) else 0) else 0;
        weft.capsItem(session, .{
            .text = if (ins.len > 0) ins else label,
            .label = label,
            .detail = strOf(o.get("detail")),
            .documentation = if (o.get("documentation")) |d| contentsText(d) else "",
            .kind = kind,
            .rank = rank,
        });
        rank += 1;
    }
    weft.capsCommit(session);
}

fn strOf(v: ?rpc.Value) []const u8 {
    const o = v orelse return "";
    return if (o == .string) o.string else "";
}

/// Rendering P2 (doc/rendering.md): a LIVE hover producer. `want_target` is
/// the CRDT identity captured when the request was fired, so hover shows as a
/// caret popup at that identity — the same generic
/// `drawCaretSurface` renderer the picker's own completion list uses,
/// through the `wl_surface_caret` membrane call. Echo is now the fallback
/// ONLY for the no-position case: an empty result, nothing to anchor.
fn presentHover(result: rpc.Value) void {
    const text: []const u8 = switch (result) {
        .object => |o| if (o.get("contents")) |c| contentsText(c) else "",
        else => "",
    };
    if (text.len == 0) {
        weft.surfaceClose(); // drop any popup from a still-live prior hover
        weft.echo("lsp: no hover");
        return;
    }
    const offset = targetOffset(want_target orelse {
        weft.echo("lsp: hover target disappeared");
        return;
    }) orelse {
        weft.echo("lsp: hover target disappeared");
        return;
    };
    weft.surfaceCaret(offset);
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (rows += 1) {
        if (rows >= max_hover_rows) break;
        weft.surfaceRow();
        weft.surfaceSpan(line, .normal);
    }
    weft.surfaceEnd(-1);
}

fn presentDefinition(result: rpc.Value) void {
    const loc = firstLocation(result) orelse {
        weft.echo("lsp: no definition");
        return;
    };
    if (!sameUri(loc.uri)) {
        weft.echo("lsp: definition in another file");
        return;
    }
    weft.jump(offsetOf(loc.line, loc.col));
}

fn presentLocations(result: rpc.Value, prompt: []const u8) void {
    resetPickTargets();
    var dropped = false;
    if (result == .array) {
        weft.pickBegin(prompt, pick_id_results);
        for (result.array.items) |item| {
            const loc = locationOf(item) orelse continue;
            if (!sameUri(loc.uri)) continue; // cross-file later
            if (pick_n >= pick_targets.len) {
                dropped = true;
                break;
            }
            if (!addPickTarget(offsetOf(loc.line, loc.col))) continue;
            var lbl: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&lbl, "line {d}", .{loc.line + 1}) catch "?";
            weft.pickAdd(s, "");
        }
        weft.pickEnd();
    }
    if (pick_n == 0) weft.echo("lsp: no references");
    if (dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} references — some omitted", .{pick_targets.len}));
}

var symbols_dropped = false;

fn presentSymbols(result: rpc.Value) void {
    resetPickTargets();
    symbols_dropped = false;
    if (result == .array) {
        weft.pickBegin("symbol", pick_id_results);
        for (result.array.items) |item| addSymbol(item);
        weft.pickEnd();
    }
    if (pick_n == 0) weft.echo("lsp: no symbols");
    if (symbols_dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} symbols — some omitted", .{pick_targets.len}));
}

/// A DocumentSymbol (nested, has selectionRange/children) or a SymbolInformation
/// (flat, has location). Add it + recurse children (bounded).
fn addSymbol(item: rpc.Value) void {
    if (item != .object) return;
    if (pick_n >= pick_targets.len) {
        symbols_dropped = true;
        return;
    }
    const o = item.object;
    const name = if (o.get("name")) |n| (if (n == .string) n.string else "?") else "?";
    // Prefer selectionRange (DocumentSymbol), else range, else location.range.
    const rng = o.get("selectionRange") orelse o.get("range") orelse blk: {
        if (o.get("location")) |l| if (l == .object) break :blk (l.object.get("range") orelse rpc.Value{ .null = {} });
        break :blk rpc.Value{ .null = {} };
    };
    if (posInRange(rng)) |p| {
        if (addPickTarget(offsetOf(p.line, p.col))) weft.pickAdd(name, "");
    }
    if (o.get("children")) |ch| if (ch == .array) {
        for (ch.array.items) |c| addSymbol(c);
    };
}

/// Apply a server's TextEdit[] (formatting; also each file's edits in a
/// rename/code-action WorkspaceEdit). BOTTOM-UP so earlier ranges' offsets stay
/// valid. Returns how many were applied. The gated edit door authors as our peer.
fn applyEdits(result: rpc.Value) usize {
    if (result != .array) return 0;
    const edits = result.array.items;
    var applied: usize = 0;
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i];
        if (e != .object) continue;
        const rng = e.object.get("range") orelse continue;
        if (rng != .object) continue;
        const s = pointOf(rng.object.get("start")) orelse continue;
        const en = pointOf(rng.object.get("end")) orelse continue;
        const newText = if (e.object.get("newText")) |n| (if (n == .string) n.string else "") else "";
        weft.edit(.{ .start = offsetOf(s.line, s.col), .end = offsetOf(en.line, en.col) }, newText);
        applied += 1;
    }
    return applied;
}

/// Apply a WorkspaceEdit's edits for the CURRENT file (the `changes` map or
/// `documentChanges` list — same-file rename for now; cross-file with multi-open).
fn applyWorkspaceEdit(result: rpc.Value) usize {
    if (result != .object) return 0;
    const o = result.object;
    if (o.get("changes")) |ch| {
        if (ch == .object) {
            var it = ch.object.iterator();
            while (it.next()) |entry| {
                if (sameUri(entry.key_ptr.*)) return applyEdits(entry.value_ptr.*);
            }
        }
    }
    if (o.get("documentChanges")) |dc| {
        if (dc == .array) {
            for (dc.array.items) |d| {
                if (d != .object) continue;
                const td = d.object.get("textDocument") orelse continue;
                if (td != .object) continue;
                const uri = td.object.get("uri") orelse continue;
                if (uri == .string and sameUri(uri.string)) {
                    return applyEdits(d.object.get("edits") orelse rpc.Value{ .null = {} });
                }
            }
        }
    }
    return 0;
}

/// A `{line,character}` position value → editor coordinates.
fn pointOf(v: ?rpc.Value) ?Pos {
    const o = v orelse return null;
    if (o != .object) return null;
    const line = asInt(o.object.get("line") orelse return null) orelse return null;
    const col = asInt(o.object.get("character") orelse return null) orelse return null;
    return .{ .line = @intCast(@max(line, 0)), .col = @intCast(@max(col, 0)) };
}

// ── LSP value helpers ────────────────────────────────────────────────
const Loc = struct { uri: []const u8, line: usize, col: usize };

fn firstLocation(result: rpc.Value) ?Loc {
    return switch (result) {
        .object => locationOf(result),
        .array => |a| if (a.items.len > 0) locationOf(a.items[0]) else null,
        else => null,
    };
}

/// A Location `{uri,range}` or a LocationLink `{targetUri,targetSelectionRange}`.
fn locationOf(v: rpc.Value) ?Loc {
    if (v != .object) return null;
    const o = v.object;
    const uri = o.get("uri") orelse o.get("targetUri") orelse return null;
    const rng = o.get("range") orelse o.get("targetSelectionRange") orelse o.get("targetRange") orelse return null;
    const p = posInRange(rng) orelse return null;
    return .{ .uri = if (uri == .string) uri.string else "", .line = p.line, .col = p.col };
}

fn posInRange(rng: rpc.Value) ?Pos {
    if (rng != .object) return null;
    return pointOf(rng.object.get("start"));
}

fn sameUri(uri: []const u8) bool {
    return uri.len == 0 or std.mem.eql(u8, uri, uri_buf[0..uri_len]);
}

fn presentSignature(result: rpc.Value) void {
    if (result != .object) {
        weft.echo("lsp: no signature");
        return;
    }
    const sigs = result.object.get("signatures") orelse {
        weft.echo("lsp: no signature");
        return;
    };
    if (sigs != .array or sigs.array.items.len == 0) {
        weft.echo("lsp: no signature");
        return;
    }
    const sig = sigs.array.items[0];
    const label = if (sig == .object) (if (sig.object.get("label")) |l| (if (l == .string) l.string else "") else "") else "";
    weft.echo(if (label.len == 0) "lsp: no signature" else label);
}

/// Inlay hints → virtual text after each position. Echoes the count (a screenshot
/// shows the hints themselves). Appends (no clear) so it doesn't clobber the
/// diagnostics gutter on the shared decoration layer.
fn presentInlay(result: rpc.Value) void {
    if (result != .array) {
        weft.echo("lsp: no inlay hints");
        return;
    }
    var count: usize = 0;
    for (result.array.items) |hint| {
        if (hint != .object) continue;
        const pos = pointOf(hint.object.get("position")) orelse continue;
        const label = inlayLabel(hint.object.get("label"));
        if (label.len > 0) weft.decorate(offsetOf(pos.line, pos.col), .virtual_after, .muted, label);
        count += 1;
    }
    var b: [48]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&b, "lsp: {d} inlay hints", .{count}) catch "lsp: inlay hints");
}

/// An inlay-hint label: a plain string, or an array of parts (take the first).
fn inlayLabel(v: ?rpc.Value) []const u8 {
    const o = v orelse return "";
    return switch (o) {
        .string => |s| s,
        .array => |a| if (a.items.len > 0 and a.items[0] == .object)
            (if (a.items[0].object.get("value")) |vv| (if (vv == .string) vv.string else "") else "")
        else
            "",
        else => "",
    };
}

fn contentsText(c: rpc.Value) []const u8 {
    return switch (c) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |v| (if (v == .string) v.string else "") else "",
        .array => |a| if (a.items.len > 0) contentsText(a.items[0]) else "",
        else => "",
    };
}

fn asInt(v: rpc.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

// ── Position ↔ offset (ASCII columns for now) ────────────────────────
const Pos = struct { line: usize, col: usize };

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
    return .{ .line = line, .col = offset - weft.lineAt(offset).start };
}

fn offsetOf(line: usize, col: usize) usize {
    const total = weft.byteLen();
    if (line == 0) return @min(col, total);
    var seen: usize = 0;
    var pos: usize = 0;
    while (pos < total) {
        const s = weft.slice(pos, total);
        if (s.len == 0) break;
        for (s, 0..) |ch, k| {
            if (ch == '\n') {
                seen += 1;
                if (seen == line) return @min(pos + k + 1 + col, total);
            }
        }
        pos += s.len;
    }
    return total;
}

/// JSON-escaped length of one byte — MUST match `escapeAppend` exactly, so the
/// size pass and the send pass of a streamed document agree on the frame length.
fn escapedLen(chunk: []const u8) usize {
    var n: usize = 0;
    for (chunk) |c| n += switch (c) {
        '"', '\\', '\n', '\r', '\t' => @as(usize, 2),
        0...8, 11, 12, 14...31 => 6,
        else => 1,
    };
    return n;
}

/// Append `chunk` JSON-escaped to `list` (grows on the heap). Byte-for-byte the
/// same escaping `escapedLen` counts; a UTF-8 sequence split across chunks is
/// fine — bytes ≥ 0x80 copy verbatim.
fn escapeAppend(list: *std.ArrayListUnmanaged(u8), chunk: []const u8) !void {
    const alloc = weft.allocator;
    for (chunk) |c| switch (c) {
        '"' => try list.appendSlice(alloc, "\\\""),
        '\\' => try list.appendSlice(alloc, "\\\\"),
        '\n' => try list.appendSlice(alloc, "\\n"),
        '\r' => try list.appendSlice(alloc, "\\r"),
        '\t' => try list.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31 => {
            const hex = "0123456789abcdef";
            try list.appendSlice(alloc, &[_]u8{ '\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf] });
        },
        else => try list.append(alloc, c),
    };
}
