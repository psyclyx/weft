//! lsp — a Language Server Protocol client, as a fast wasm guest (design:
//! doc/lsp.md). Layer 3: it imports the shared `jsonrpc` framing (layer 2) over
//! the host's raw streaming membrane (layer 1) and adds only LSP semantics —
//! which methods to send, what each result means, how it's presented through the
//! editor membrane (echo / jump / pick).
//!
//! SESSIONS: one `Session` per (server command, language, workspace root). A Zig
//! buffer and a Nix buffer get their own server, handshake, document sync and
//! diagnostics; nothing is shared, so one server dying leaves the other whole
//! (doc/contextual-workspace-architecture.md §18).
//!
//! REQUEST IDENTITY: one slot per (session, kind), so completion, hover and
//! definition are concurrently in flight under their own rpc ids. A second ask
//! of the SAME kind supersedes the first: the server is told `$/cancelRequest`,
//! the slot is given back, and the superseded reply — arriving under an id
//! nothing claims — is dropped rather than misapplied.
//!
//! Async shape: an ask is armed by a command (or by the caps provider), sent
//! once its session is ready, and answered on `on_poll`. Every delivery is gated
//! on the opaque document witness captured at send: a handle naming the captured
//! ENTRY as well as its causal frontier, so a reply can only ever land in the
//! buffer that asked.

const std = @import("std");
const weft = @import("weft");
const rpc = @import("jsonrpc.zig");

// ── Captured document identities ─────────────────────────────────────
// LSP byte positions are converted once, when they are presented; everything
// held across a round-trip is a CRDT anchor, so edits move the target rather
// than rotting a stored offset. A retained range resolves ONLY in the entry it
// was captured in (`wl_range_ends` refuses elsewhere) — the seam that keeps a
// background delivery off whatever buffer happens to be active.
const PickTarget = struct { range: u32, at_end: bool };

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

// A location pick (references / symbols) and the rename prompt share the Head's
// one picker, so their retained targets are one list.
const pick_id_results: u32 = 1;
const pick_id_rename: u32 = 2;
var pick_targets: [256]PickTarget = undefined;
var pick_n: usize = 0;

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

// ── Diagnostics ──────────────────────────────────────────────────────
// Pushed by the server (publishDiagnostics): anchor + severity + packed
// message, for gutter markers and `]d`/`[d` navigation. One set per session,
// belonging to the document that session has open.
const MAX_DIAG = 256;
const DiagnosticProvenance = enum { versioned, legacy_unversioned };

const Diags = struct {
    targets: [MAX_DIAG]PickTarget = undefined,
    sev: [MAX_DIAG]u8 = undefined,
    moff: [MAX_DIAG]usize = undefined,
    mlen: [MAX_DIAG]usize = undefined,
    msgs: [1 << 13]u8 = undefined,
    n: usize = 0,
    snapshot: ?u32 = null,
    provenance: DiagnosticProvenance = .legacy_unversioned,

    fn message(self: *const Diags, i: usize) []const u8 {
        return self.msgs[self.moff[i]..][0..self.mlen[i]];
    }
};

// ── Sessions ─────────────────────────────────────────────────────────
/// A live server and everything it is about. The key is the triple the server
/// was spawned FOR, so a config change re-keys onto a new session rather than
/// quietly repurposing the running one.
const Session = struct {
    used: bool = false,
    conn: rpc.Conn = .{},

    lang_buf: [16]u8 = undefined,
    lang_len: usize = 0,
    cmd_buf: [1 << 12]u8 = undefined,
    cmd_len: usize = 0,
    root_buf: [512]u8 = undefined,
    root_len: usize = 0,

    init_id: i64 = 0,
    ready: bool = false, // initialize answered + initialized sent
    opened: bool = false, // didOpen sent for `uri`
    /// An integer the external protocol requires, never used as a CRDT clock.
    doc_version: i64 = 1,
    /// The host's opaque witness for the exact causal frontier last streamed to
    /// this server. Equality only: no version bytes, arithmetic or ordering
    /// cross the plugin boundary.
    synced: ?u32 = null,
    /// The `file://` uri this session currently has open (one document per
    /// server; focusing another file of the same language re-opens under it).
    uri_buf: [1200]u8 = undefined,
    uri_len: usize = 0,

    diag: Diags = .{},
    /// The new name typed into the rename prompt, sent once the server is ready.
    rename_buf: [256]u8 = undefined,
    rename_len: usize = 0,
    /// Last time this session was asked for — the retirement order.
    touched: usize = 0,

    fn lang(self: *const Session) []const u8 {
        return self.lang_buf[0..self.lang_len];
    }
    fn cmd(self: *const Session) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }
    fn root(self: *const Session) []const u8 {
        return self.root_buf[0..self.root_len];
    }
    fn uri(self: *const Session) []const u8 {
        return self.uri_buf[0..self.uri_len];
    }
};

const MAX_SESSIONS = 8;
var sessions: [MAX_SESSIONS]Session = undefined;

fn sessionIndex(s: *const Session) usize {
    return (@intFromPtr(s) - @intFromPtr(&sessions[0])) / @sizeOf(Session);
}

/// The identity of the server the ACTIVE buffer needs. Every part is copied out
/// of host scratch — `path`/`cwd` share one buffer and `config` another, so the
/// three cannot be held at once.
const Key = struct {
    lang_buf: [16]u8 = undefined,
    lang_len: usize = 0,
    cmd_buf: [1 << 12]u8 = undefined,
    cmd_len: usize = 0,
    root_buf: [512]u8 = undefined,
    root_len: usize = 0,

    fn lang(self: *const Key) []const u8 {
        return self.lang_buf[0..self.lang_len];
    }
    fn cmd(self: *const Key) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }
    fn root(self: *const Key) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

/// Copy `src` into a fixed field, reporting whether it fit whole. A key that
/// was truncated is a DIFFERENT key, so the callers that build one refuse
/// rather than route onto a neighbouring server.
fn copyInto(out: []u8, len: *usize, src: []const u8) bool {
    len.* = @min(src.len, out.len);
    @memcpy(out[0..len.*], src[0..len.*]);
    return len.* == src.len;
}

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

/// The server identity the active buffer needs, or null when no server is
/// configured for its language (the common no-op every plain file takes).
fn activeKey(key: *Key) ?void {
    key.lang_len = activeLang(&key.lang_buf).len; // written in place
    if (key.lang_len == 0) return null;
    const cmd = serverCmd(key.lang());
    if (cmd.len == 0) return null;
    if (!copyInto(&key.cmd_buf, &key.cmd_len, cmd)) return null;
    // WHERE, not the process's launch directory (`doc/place.md`). This field
    // has always been part of the key; filling it from a process-wide constant
    // is what made every project share one server. An empty place has no local
    // root to serve, so no session is minted for it at all.
    const root = weft.placeRoot();
    if (root.len == 0) return null;
    if (!copyInto(&key.root_buf, &key.root_len, root)) return null;
    return {};
}

fn matches(s: *const Session, key: *const Key) bool {
    return std.mem.eql(u8, s.lang(), key.lang()) and
        std.mem.eql(u8, s.cmd(), key.cmd()) and
        std.mem.eql(u8, s.root(), key.root());
}

/// The session serving the active buffer, WITHOUT starting one. The honest test
/// for "does this server's document sit in front of us right now" — a poll-time
/// delivery asks it before touching any coordinate, anchor or layer.
fn lookupActive() ?*Session {
    var key: Key = .{};
    _ = activeKey(&key) orelse return null;
    for (&sessions) |*s| {
        if (s.used and matches(s, &key)) return touch(s);
    }
    return null;
}

/// The session serving the active buffer, started if this is the first file of
/// its language. A slot whose spawn failed stays occupied and dead, so a missing
/// server binary is reported once per language rather than once per keystroke.
fn ensureActive() ?*Session {
    var key: Key = .{};
    _ = activeKey(&key) orelse return null;
    for (&sessions) |*s| {
        if (s.used and matches(s, &key)) return touch(s);
    }
    const s = freeSession() orelse coldest();
    closeSession(s);
    s.* = .{ .used = true };
    _ = touch(s);
    _ = copyInto(&s.lang_buf, &s.lang_len, key.lang());
    _ = copyInto(&s.cmd_buf, &s.cmd_len, key.cmd());
    _ = copyInto(&s.root_buf, &s.root_len, key.root());
    if (!s.conn.start(s.cmd())) {
        weft.echo("lsp: could not start server");
        return s;
    }
    s.init_id = s.conn.request("initialize", initializeParams(s));
    return s;
}

/// `initialize`'s params, naming the workspace this server is FOR.
///
/// `rootUri` was the literal `null` while every session shared the process's
/// launch directory — there was no honest answer to give. A session is keyed
/// by its place now, so the root it was minted for is the root it serves, and
/// a server that resolves configuration, indexes, or cross-file references
/// against a workspace gets the right one.
///
/// `workspaceFolders` is deliberately NOT sent (`doc/place.md` §9): multi-root
/// is its own protocol with its own lifecycle notification, and one honest
/// root beats a half-implemented list of them.
fn initializeParams(s: *const Session) []const u8 {
    const caps =
        \\"capabilities":{"textDocument":{"hover":{"contentFormat":["plaintext","markdown"]},"synchronization":{},"publishDiagnostics":{"versionSupport":true}}}
    ;
    const root = s.root();
    if (root.len == 0 or root[0] != '/')
        return "{\"processId\":null,\"rootUri\":null," ++ caps ++ "}";
    return std.fmt.bufPrint(
        &init_buf,
        "{{\"processId\":null,\"rootUri\":\"file://{s}\",{s}}}",
        .{ root, caps },
    ) catch "{\"processId\":null,\"rootUri\":null," ++ caps ++ "}";
}

/// Scratch for `initialize`'s params — its own buffer, since the request is
/// written while the session's own fields are borrowed.
var init_buf: [1024]u8 = undefined;

fn freeSession() ?*Session {
    for (&sessions) |*s| {
        if (!s.used) return s;
    }
    return null;
}

/// Recency, so a saturated table sheds the server nobody is editing against
/// rather than refusing the file in front of the user. A session owns no buffer
/// the user can see, so retiring one costs a handshake, not state.
var touches: usize = 0;

fn touch(s: *Session) *Session {
    touches += 1;
    s.touched = touches;
    return s;
}

fn coldest() *Session {
    var found = &sessions[0];
    for (&sessions) |*s| {
        if (s.touched < found.touched) found = s;
    }
    return found;
}

/// Shut a session down: its server, its document witnesses, and every ask still
/// outstanding against it (a completion among them declines, so no merge waits
/// on a server that is gone).
fn closeSession(s: *Session) void {
    if (!s.used) return;
    if (prompting == sessionIndex(s)) prompting = null;
    for (&pending[sessionIndex(s)]) |*p| retire(s, p);
    releaseDiagnostics(s);
    releaseSynced(s);
    s.conn.close();
    s.used = false;
}

fn releaseDiagnostics(s: *Session) void {
    for (s.diag.targets[0..s.diag.n]) |target| releaseTarget(target);
    s.diag.n = 0;
    if (s.diag.snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    s.diag.snapshot = null;
}

fn releaseSynced(s: *Session) void {
    if (s.synced) |snapshot| weft.releaseDocSnapshot(snapshot);
    s.synced = null;
}

// ── Request identities ───────────────────────────────────────────────
const Kind = enum { hover, definition, references, symbols, format, rename, signature, inlay, codeaction, completion };
const kind_count = std.meta.fields(Kind).len;

/// One ask. `id` 0 means ARMED: built, but not yet on the wire (the handshake
/// hasn't landed, or the rename prompt is still open); a positive id is in
/// flight and is what a reply is matched against.
const Pending = struct {
    used: bool = false,
    id: i64 = 0,
    /// The cursor identity the ask is about, as a CRDT anchor.
    target: ?PickTarget = null,
    /// The document witness captured immediately before send — the entry and
    /// frontier a coordinate-bearing reply may be interpreted against.
    snapshot: ?u32 = null,
    /// The caps session a completion must answer (0 for every other kind).
    caps: u32 = 0,
};

/// One slot per (session, kind): concurrency between kinds is structural, and a
/// second ask of one kind can only ever supersede its own predecessor.
var pending: [MAX_SESSIONS][kind_count]Pending = @splat(@splat(.{}));

fn slotOf(s: *const Session, kind: Kind) *Pending {
    return &pending[sessionIndex(s)][@intFromEnum(kind)];
}

/// The ask `id` belongs to, if it is still ours to answer. A superseded or
/// abandoned ask has already given its slot back, so its late reply finds
/// nothing here and is dropped.
fn findPending(s: *const Session, id: i64) ?struct { *Pending, Kind } {
    for (&pending[sessionIndex(s)], 0..) |*p, k| {
        if (p.used and p.id == id) return .{ p, @enumFromInt(k) };
    }
    return null;
}

fn cancelRequest(s: *Session, id: i64) void {
    var buf: [48]u8 = undefined;
    const params = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return;
    s.conn.notify("$/cancelRequest", params);
}

/// Give a slot back: the server is asked to stop (where it honors
/// `$/cancelRequest`), the captured witness and cursor identity are released,
/// and a completion's caps session is declined so the merge is never left
/// waiting on us.
fn retire(s: *Session, p: *Pending) void {
    if (!p.used) return;
    if (p.id > 0) cancelRequest(s, p.id);
    if (p.snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    if (p.target) |target| releaseTarget(target);
    if (p.caps != 0) weft.capsDecline(p.caps);
    p.* = .{};
}

/// Arm an ask of `kind` against the cursor, superseding this session's previous
/// one of the same kind.
fn arm(s: *Session, kind: Kind) ?*Pending {
    const p = slotOf(s, kind);
    retire(s, p);
    p.target = captureTarget(weft.cursor()) orelse return null;
    p.used = true;
    return p;
}

/// Put an armed ask on the wire. The slot is given back (and the caps session
/// declined) whenever the document it captured is no longer the one in front of
/// us — a request whose answer could not be interpreted is not worth sending.
fn send(s: *Session, p: *Pending, kind: Kind) bool {
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
fn flushArmed(s: *Session) void {
    for (&pending[sessionIndex(s)], 0..) |*p, k| {
        if (!p.used or p.id != 0) continue;
        const kind: Kind = @enumFromInt(k);
        if (kind == .rename and s.rename_len == 0) continue; // still prompting
        _ = send(s, p, kind);
    }
}

/// Build and fire the wire request for `kind`. -1 when the parameters or the
/// envelope don't fit.
fn requestOf(s: *Session, kind: Kind, pos: Pos) i64 {
    const uri = s.uri();
    return switch (kind) {
        .hover => posRequest(s, "textDocument/hover", pos, ""),
        .definition => posRequest(s, "textDocument/definition", pos, ""),
        .references => posRequest(s, "textDocument/references", pos, ",\"context\":{\"includeDeclaration\":true}"),
        .signature => posRequest(s, "textDocument/signatureHelp", pos, ""),
        .completion => posRequest(s, "textDocument/completion", pos, ""),
        .symbols => s.conn.request("textDocument/documentSymbol", std.fmt.bufPrint(
            &parambuf,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
            .{uri},
        ) catch return -1),
        .format => s.conn.request("textDocument/formatting", std.fmt.bufPrint(
            &parambuf,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}",
            .{uri},
        ) catch return -1),
        .rename => s.conn.request("textDocument/rename", std.fmt.bufPrint(
            &parambuf,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"{s}\"}}",
            .{ uri, pos.line, pos.col, s.rename_buf[0..s.rename_len] },
        ) catch return -1),
        .inlay => blk: {
            const last = posOf(weft.byteLen());
            break :blk s.conn.request("textDocument/inlayHint", std.fmt.bufPrint(
                &parambuf,
                "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}}}",
                .{ uri, last.line + 1 },
            ) catch return -1);
        },
        // Actions for the cursor's line, passing any diagnostics on it as
        // context (so quick-fixes surface).
        .codeaction => s.conn.request("textDocument/codeAction", std.fmt.bufPrint(
            &parambuf,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"context\":{{\"diagnostics\":[]}}}}",
            .{ uri, pos.line, pos.line + 1 },
        ) catch return -1),
    };
}

/// A position-based request: `{textDocument, position[, extra]}`.
fn posRequest(s: *Session, method: []const u8, pos: Pos, extra: []const u8) i64 {
    const params = std.fmt.bufPrint(
        &parambuf,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}{s}}}",
        .{ s.uri(), pos.line, pos.col, extra },
    ) catch return -1;
    return s.conn.request(method, params);
}

// Hover popup: capped row count (mirrors the view's `Hud.max_hover_rows` —
// this guest doesn't depend on `gfx/view`, so the cap is repeated here as a
// plain constant, not imported).
const max_hover_rows = 16;

var parambuf: [4096]u8 = undefined; // small position/range params (bounded)

// ── Plugin surface ───────────────────────────────────────────────────
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
    for (&sessions) |*s| s.* = .{};
    for (cmds) |c| _ = weft.register(c.name);
    weft.provideCompletion();
}

/// Completion request (caps provider): send textDocument/completion for the
/// cursor and DEFER — the response commits into `session` off a later poll. The
/// provider registration is one; the predicate is per language, resolved here as
/// "which session serves this buffer". No server for it (or not ready yet) ⇒
/// decline, so the merge isn't left waiting on us.
export fn on_complete(session: u32) void {
    const s = ensureActive() orelse {
        weft.capsDecline(session);
        return;
    };
    if (!s.conn.live or !s.ready) {
        weft.capsDecline(session);
        return;
    }
    const p = arm(s, .completion) orelse {
        weft.capsDecline(session);
        return;
    };
    p.caps = session;
    _ = send(s, p, .completion); // a refusal declines through `retire`
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
/// nested call (nothing re-parses that session's buffer until the NEXT loop
/// iteration's `conn.next()`).
export fn on_poll() void {
    for (&sessions) |*s| {
        while (s.used and s.conn.live) {
            pending_msg = s.conn.next() orelse break;
            pending_session = sessionIndex(s);
            weft.run("lsp-deliver-internal");
        }
    }
}

var pending_msg: rpc.Value = undefined;
var pending_session: usize = 0;
fn lspDeliverInternal() void {
    dispatch(&sessions[pending_session], pending_msg);
}

/// A buffer took focus: ensure its language's server is up and its document is
/// the one that server has open, so diagnostics flow without waiting for a
/// request. Every OTHER session is left untouched — that is what makes two
/// languages two independent servers.
export fn on_activate() void {
    if (pick_n > 0) resetPickTargets();
    weft.decorateClear();
    const s = ensureActive() orelse return;
    if (!s.conn.live or !s.ready) return;
    if (!syncDoc(s)) return;
    flushArmed(s);
    paintDiagnostics(s);
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
    if (pick_id != pick_id_rename) return;
    const s = &sessions[prompting orelse return];
    prompting = null;
    const p = slotOf(s, .rename);
    if (!p.used or p.id != 0) return;
    const name = switch (outcome) {
        .candidate => |candidate| candidate.text,
        .input => |input| input,
        .cancelled => {
            retire(s, p);
            return;
        },
    }; // owned by `outcome` until this callback returns
    if (name.len == 0) {
        retire(s, p);
        return;
    }
    _ = copyInto(&s.rename_buf, &s.rename_len, name);
    if (s.ready) _ = send(s, p, .rename);
}

/// The session whose rename prompt is open. The Head owns one picker, so at most
/// one rename is ever being typed.
var prompting: ?usize = null;

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

fn fire(kind: Kind) void {
    const s = ensureActive() orelse return;
    if (!s.conn.live) return;
    const p = arm(s, kind) orelse return;
    if (s.ready) _ = send(s, p, kind);
}

/// Rename the symbol under the cursor. With an arg, use it as the new name; else
/// prompt (a free-text pick). On accept the request goes out (see on_pick_accept).
fn cmdRename() void {
    const s = ensureActive() orelse return;
    if (!s.conn.live) return;
    const p = arm(s, .rename) orelse return;
    s.rename_len = 0;
    if (weft.argStr(0)) |name| {
        if (name.len > 0) {
            _ = copyInto(&s.rename_buf, &s.rename_len, name);
            if (s.ready) _ = send(s, p, .rename);
            return;
        }
    }
    resetPickTargets();
    prompting = sessionIndex(s);
    weft.pickBegin("rename to", pick_id_rename);
    weft.pickEnd(); // no items — the typed query is the new name
}

/// Jump to the next/previous stored diagnostic from the cursor (wrapping) and
/// echo its severity + message.
fn gotoDiag(fwd: bool) void {
    const s = lookupActive() orelse {
        weft.echo("lsp: no diagnostics");
        return;
    };
    if (s.diag.n == 0) {
        weft.echo("lsp: no diagnostics");
        return;
    }
    const snapshot = s.diag.snapshot orelse {
        staleDiagnostics(s);
        return;
    };
    if (!weft.docSnapshotIsCurrent(snapshot)) {
        staleDiagnostics(s);
        return;
    }
    const cur = weft.cursor();
    const Located = struct { index: usize, offset: usize };
    var best: ?Located = null; // nearest strictly after/before
    var wrap: ?Located = null; // extreme for wrap-around
    var i: usize = 0;
    while (i < s.diag.n) : (i += 1) {
        const off = targetOffset(s.diag.targets[i]) orelse continue;
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
    weft.jump(located.offset);
    const label: []const u8 = switch (s.diag.sev[located.index]) {
        1 => "error",
        2 => "warning",
        3 => "info",
        else => "hint",
    };
    var buf: [1024]u8 = undefined;
    const msg = s.diag.message(located.index);
    const line = switch (s.diag.provenance) {
        .versioned => std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, msg }) catch label,
        .legacy_unversioned => std.fmt.bufPrint(&buf, "{s} (unverified server position): {s}", .{ label, msg }) catch label,
    };
    weft.echo(line);
}

fn staleDiagnostics(s: *Session) void {
    releaseDiagnostics(s);
    weft.decorateClear();
    weft.echo("lsp: diagnostics became stale");
}

// ── Document sync ────────────────────────────────────────────────────
/// Keep `s`'s copy current: didOpen once per document, then didChange
/// (full-text) whenever the last opaque causal-frontier witness no longer equals
/// the live document. Called before every request, so coordinate-bearing
/// responses can be accepted only against the exact text the server saw. Focusing
/// a different file of the same language closes the old document first, so one
/// server never holds two documents open under one version stream.
///
/// STREAMED, never held whole: stemma docs can be multi-gig, and a wasm32 guest
/// can't hold that in one allocation. We frame the JSON-RPC envelope with the
/// exact body length (a chunked size pass), then push the envelope prefix, the
/// document escaped chunk-by-chunk (each chunk read via `slice`, escaped on the
/// growable heap, sent, freed), and the suffix. Two full reads of the doc — the
/// price of not materializing it — bounded by the server's appetite, not us.
fn syncDoc(s: *Session) bool {
    if (!s.conn.live) return false;
    retargetDoc(s);
    if (s.opened) {
        if (s.synced) |snapshot| {
            if (weft.docSnapshotIsCurrent(snapshot)) return true;
        }
    }
    const alloc = weft.allocator;
    const uri = s.uri();
    const total = weft.byteLen();

    // The JSON-RPC envelope around the (streamed) document text. `params` is the
    // {textDocument…text:"} … "} object; the envelope wraps it.
    const prefix = if (!s.opened) blk: {
        s.doc_version = 1;
        break :blk std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\",\"version\":1,\"text\":\"", .{ uri, s.lang() }) catch return false;
    } else blk: {
        s.doc_version += 1;
        break :blk std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}},\"contentChanges\":[{{\"text\":\"", .{ uri, s.doc_version }) catch return false;
    };
    defer alloc.free(prefix);
    const suffix: []const u8 = if (!s.opened) "\"}}}" else "\"}]}}";

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
    s.conn.beginFrame(prefix.len + esc_total + suffix.len);
    s.conn.writeChunk(prefix);
    {
        var esc: std.ArrayListUnmanaged(u8) = .empty;
        defer esc.deinit(alloc);
        var pos: usize = 0;
        while (pos < total) {
            const chunk = weft.slice(pos, total);
            if (chunk.len == 0) break;
            esc.clearRetainingCapacity();
            escapeAppend(&esc, chunk) catch return false; // OOM mid-frame desyncs; rare, bounded
            s.conn.writeChunk(esc.items);
            pos += chunk.len;
        }
    }
    s.conn.writeChunk(suffix);

    s.opened = true;
    releaseSynced(s);
    s.synced = weft.docSnapshot();
    return s.synced != null;
}

/// Point `s` at the active buffer's document, closing whatever it held before.
/// Diagnostics belong to a uri, so the old set goes with the old document.
fn retargetDoc(s: *Session) void {
    var buf: [1200]u8 = undefined;
    const uri = buildUri(&buf);
    if (s.opened and std.mem.eql(u8, uri, s.uri())) return;
    if (s.opened) {
        var params: [1300]u8 = undefined;
        if (std.fmt.bufPrint(&params, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{s.uri()})) |body|
            s.conn.notify("textDocument/didClose", body)
        else |_| {}
    }
    releaseDiagnostics(s);
    releaseSynced(s);
    s.opened = false;
    _ = copyInto(&s.uri_buf, &s.uri_len, uri);
}

/// The active buffer's `file://` uri, into `out`. Absolute paths pass through;
/// relative ones are resolved INSIDE the place they belong to, so the uri
/// matches the absolute uris a server rooted at that place returns in its
/// locations.
///
/// `weft.placePath` is what reconciles the two spellings — see its doc for why
/// a naive `<root>/<path>` double-counts what they share.
fn buildUri(out: []u8) []const u8 {
    // Copy the (possibly scratch-backed) path out before calling placeRoot
    // (also scratch).
    var pbuf: [1024]u8 = undefined;
    const path = weft.path() orelse "untitled";
    const pn = @min(path.len, pbuf.len);
    @memcpy(pbuf[0..pn], path[0..pn]);
    var abuf: [1024]u8 = undefined;
    const abs = weft.placePath(weft.placeRoot(), pbuf[0..pn], &abuf);
    if (abs.len == 0) return "";
    return std.fmt.bufPrint(out, "file://{s}", .{abs}) catch "";
}

// ── Response dispatch ────────────────────────────────────────────────
fn dispatch(s: *Session, msg: rpc.Value) void {
    if (msg != .object) return;
    const obj = msg.object;
    if (obj.get("id")) |idv| {
        const id = asInt(idv) orelse return;
        if (id == s.init_id and !s.ready) {
            s.ready = true;
            s.conn.notify("initialized", "{}");
            // Only the session whose document is in front of us may open it —
            // otherwise the handshake would didOpen someone else's buffer.
            if (lookupActive() == s) {
                _ = syncDoc(s); // didOpen the active doc → diagnostics start flowing
                flushArmed(s);
            }
            return;
        }
        // A reply nothing claims is a superseded/cancelled ask's: drop it.
        const found = findPending(s, id) orelse return;
        const p, const kind = found;
        deliver(s, p, kind, obj.get("result") orelse rpc.Value{ .null = {} });
        return;
    }
    // A notification: only publishDiagnostics matters to us.
    if (obj.get("method")) |m| {
        if (m == .string and std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
            onDiagnostics(s, obj.get("params"));
        }
    }
}

/// Present one answer, but only against the exact document it was asked of. The
/// witness names the captured entry as well as its frontier, so a reply that
/// arrives over a different buffer — or over an edit — never lands.
fn deliver(s: *Session, p: *Pending, kind: Kind, result: rpc.Value) void {
    const snapshot = p.snapshot orelse {
        retire(s, p);
        return;
    };
    if (!weft.docSnapshotIsCurrent(snapshot)) {
        weft.releaseDocSnapshot(snapshot);
        p.snapshot = null;
        p.id = 0; // answered under coordinates we refuse; nothing to cancel
        // The document moved under a live ask. If its cursor identity still
        // resolves, the entry is still ours: sync and ask again against a fresh
        // witness. If it doesn't, we are looking at another buffer entirely and
        // the ask dies here rather than being reinterpreted. A completion is not
        // re-asked: its caps session is racing a deadline, and an answer that
        // arrives after the merge closed is worse than none.
        const resolvable = if (p.target) |target| targetOffset(target) != null else false;
        if (kind != .completion and resolvable) {
            _ = send(s, p, kind);
        } else retire(s, p);
        return;
    }
    weft.releaseDocSnapshot(snapshot);
    p.snapshot = null;
    p.id = 0; // answered
    switch (kind) {
        .hover => presentHover(p, result),
        .definition => presentDefinition(s, result),
        .references => presentLocations(s, result, "reference"),
        .symbols => presentSymbols(result),
        .format => weft.echo(if (applyEdits(result) > 0) "lsp: formatted" else "lsp: nothing to format"),
        .rename => weft.echo(if (applyWorkspaceEdit(s, result) > 0) "lsp: renamed" else "lsp: rename made no change"),
        .signature => presentSignature(result),
        .inlay => presentInlay(result),
        .codeaction => presentCodeActions(s, result),
        .completion => presentCompletion(p, result),
    }
    retire(s, p);
}

/// Store the server's diagnostics for its open document and mark them in the
/// gutter. Replaces the previous set (a publish is the whole list for the uri).
/// The versioned layer refuses when the session's document is not the entry in
/// front of us: anchors can only be captured where they belong, so a publish for
/// an unfocused buffer is dropped and re-requested by the didOpen that focusing
/// it sends.
fn onDiagnostics(s: *Session, params: ?rpc.Value) void {
    const p = params orelse return;
    if (p != .object) return;
    if (p.object.get("uri")) |u| {
        if (u == .string and !sameUri(s, u.string)) return;
    }
    const synced = s.synced orelse {
        releaseDiagnostics(s);
        return;
    };
    if (!weft.docSnapshotIsCurrent(synced)) {
        releaseDiagnostics(s);
        return;
    }
    // Push diagnostics have no request id. A server-provided version proves
    // which LSP snapshot produced the coordinates; malformed/mismatched values
    // fail closed. Some widely deployed servers omit this optional field even
    // after versionSupport is advertised. Keep that case explicitly typed as
    // legacy/unverified: it may drive non-destructive presentation/navigation,
    // but must never become an edit precondition or feed a code action.
    s.diag.provenance = if (p.object.get("version")) |version| blk: {
        const reported = asInt(version) orelse return;
        if (reported != s.doc_version) return;
        break :blk .versioned;
    } else .legacy_unversioned;
    releaseDiagnostics(s);
    s.diag.snapshot = weft.docSnapshot() orelse return;
    var mw: usize = 0;
    var dropped = false;
    weft.decorateClear();
    const list = p.object.get("diagnostics") orelse {
        releaseDiagnostics(s);
        return;
    };
    if (list != .array) {
        releaseDiagnostics(s);
        return;
    }
    for (list.array.items) |d| {
        if (d != .object) continue;
        if (s.diag.n >= MAX_DIAG) {
            dropped = true;
            continue;
        }
        const rng = d.object.get("range") orelse continue;
        const pos = posInRange(rng) orelse continue;
        const off = offsetOf(pos.line, pos.col);
        const msg = if (d.object.get("message")) |mm| (if (mm == .string) mm.string else "") else "";
        const sev: u8 = if (d.object.get("severity")) |sv| (if (sv == .integer) @intCast(@max(1, @min(4, sv.integer))) else 1) else 1;
        s.diag.targets[s.diag.n] = captureTarget(off) orelse continue;
        s.diag.sev[s.diag.n] = sev;
        const ml = @min(msg.len, s.diag.msgs.len - mw);
        @memcpy(s.diag.msgs[mw..][0..ml], msg[0..ml]);
        s.diag.moff[s.diag.n] = mw;
        s.diag.mlen[s.diag.n] = ml;
        mw += ml;
        s.diag.n += 1;
    }
    if (s.diag.n == 0) releaseDiagnostics(s);
    paintDiagnostics(s);
    if (dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} diagnostics — some omitted", .{MAX_DIAG}));
}

/// Mark `s`'s diagnostics in the gutter. Each anchor resolves only in the entry
/// it was captured in, so a set belonging to another buffer paints nothing at
/// all rather than the wrong lines.
fn paintDiagnostics(s: *Session) void {
    for (s.diag.targets[0..s.diag.n], s.diag.sev[0..s.diag.n]) |target, sev| {
        const off = targetOffset(target) orelse continue;
        weft.decorate(
            weft.lineAt(off).start,
            .gutter,
            if (sev == 1) .removed else .emphasis,
            if (sev == 1) "\u{25CF}" else "\u{25B2}",
        );
    }
}

/// Code actions for the line. Applies the first action that carries an inline
/// `edit` (a quick-fix WorkspaceEdit) and echoes its title; a pick of titles is a
/// refinement (holding N edits needs cross-poll storage). Command-only actions
/// (needing a resolve/execute round-trip) just report their title.
fn presentCodeActions(s: *Session, result: rpc.Value) void {
    if (result != .array or result.array.items.len == 0) {
        weft.echo("lsp: no code actions");
        return;
    }
    for (result.array.items) |a| {
        if (a != .object) continue;
        const title = if (a.object.get("title")) |t| (if (t == .string) t.string else "action") else "action";
        if (a.object.get("edit")) |edit| {
            if (applyWorkspaceEdit(s, edit) > 0) {
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
fn presentCompletion(p: *Pending, result: rpc.Value) void {
    const session = p.caps;
    p.caps = 0; // answered: `retire` must not also decline it
    if (session == 0) return;
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

/// Rendering P2 (doc/rendering.md): a LIVE hover producer. The ask's `target` is
/// the CRDT identity captured when the request was fired, so hover shows as a
/// caret popup at that identity — the same generic `drawCaretSurface` renderer
/// the picker's own completion list uses, through the `wl_surface_caret`
/// membrane call. Echo is now the fallback ONLY for the no-position case: an
/// empty result, nothing to anchor.
fn presentHover(p: *Pending, result: rpc.Value) void {
    const text: []const u8 = switch (result) {
        .object => |o| if (o.get("contents")) |c| contentsText(c) else "",
        else => "",
    };
    if (text.len == 0) {
        weft.surfaceClose(); // drop any popup from a still-live prior hover
        weft.echo("lsp: no hover");
        return;
    }
    const offset = targetOffset(p.target orelse {
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

fn presentDefinition(s: *Session, result: rpc.Value) void {
    const loc = firstLocation(result) orelse {
        weft.echo("lsp: no definition");
        return;
    };
    if (!sameUri(s, loc.uri)) {
        weft.echo("lsp: definition in another file");
        return;
    }
    weft.jump(offsetOf(loc.line, loc.col));
}

fn presentLocations(s: *Session, result: rpc.Value, prompt: []const u8) void {
    resetPickTargets();
    var dropped = false;
    if (result == .array) {
        weft.pickBegin(prompt, pick_id_results);
        for (result.array.items) |item| {
            const loc = locationOf(item) orelse continue;
            if (!sameUri(s, loc.uri)) continue; // cross-file later
            if (pick_n >= pick_targets.len) {
                dropped = true;
                break;
            }
            if (!addPickTarget(offsetOf(loc.line, loc.col))) continue;
            var lbl: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&lbl, "line {d}", .{loc.line + 1}) catch "?";
            weft.pickAdd(text, "");
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

/// Apply a WorkspaceEdit's edits for the session's OPEN file (the `changes` map
/// or `documentChanges` list — same-file rename for now; cross-file with
/// multi-open).
fn applyWorkspaceEdit(s: *Session, result: rpc.Value) usize {
    if (result != .object) return 0;
    const o = result.object;
    if (o.get("changes")) |ch| {
        if (ch == .object) {
            var it = ch.object.iterator();
            while (it.next()) |entry| {
                if (sameUri(s, entry.key_ptr.*)) return applyEdits(entry.value_ptr.*);
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
                if (uri == .string and sameUri(s, uri.string)) {
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

fn sameUri(s: *const Session, uri: []const u8) bool {
    return uri.len == 0 or std.mem.eql(u8, uri, s.uri());
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
