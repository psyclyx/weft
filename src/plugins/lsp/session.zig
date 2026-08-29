//! lsp — SESSIONS: one language server per (command, language, workspace root).
//!
//! A Zig buffer and a Nix buffer get their own server, handshake, document
//! sync and diagnostics; nothing is shared, so one server dying leaves the
//! other whole. The key is the triple the server was spawned FOR, owned in
//! full, so a config change re-keys onto a new session rather than quietly
//! repurposing the running one.
//!
//! This file answers "which server serves the buffer I am looking at, what
//! does it have in flight, and is its document current" — a session's whole
//! state, including the anchors a round trip holds (an LSP byte position is
//! converted once, at presentation; everything held across a reply is a CRDT
//! anchor), the document sync that keeps the server's copy honest, and the
//! small JSON/position helpers both halves above it need.
//!
//! It sends no request and presents no result. `request.zig` decides WHEN to
//! send and `root.zig` decides what an answer looks like.

const std = @import("std");
const weft = @import("weft");
const rpc = @import("weft_jsonrpc");

// ── Captured document identities ─────────────────────────────────────
// LSP byte positions are converted once, when they are presented; everything
// held across a round-trip is a CRDT anchor, so edits move the target rather
// than rotting a stored offset. A retained range resolves ONLY in the entry it
// was captured in (`wl_range_ends` refuses elsewhere) — the seam that keeps a
// background delivery off whatever buffer happens to be active.
pub const PickTarget = struct { range: u32, at_end: bool };

pub fn captureTarget(offset: usize) ?PickTarget {
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

pub fn targetOffset(target: PickTarget) ?usize {
    const current = weft.rangeEnds(target.range) orelse return null;
    return if (target.at_end) current.end else current.start;
}

pub fn releaseTarget(target: PickTarget) void {
    weft.releaseRange(target.range);
}

// The picker holds locations (references / symbols) and nothing else. It used
// to double as the rename prompt — opened with no items so its free-text
// accept could stand in for a text field — which is `weft_prompt`'s job now.
pub const pick_id_results: u32 = 1;
pub var pick_targets: [256]PickTarget = undefined;
pub var pick_n: usize = 0;

pub fn releasePickTargets() void {
    for (pick_targets[0..pick_n]) |target| weft.releaseRange(target.range);
    pick_n = 0;
}

pub fn resetPickTargets() void {
    // End the old interaction before releasing its guest-side resources. The
    // Head owns one picker, so this also makes replacing results reentrant.
    weft.run("pick-cancel");
    releasePickTargets();
}

pub fn addPickTarget(offset: usize) bool {
    if (pick_n >= pick_targets.len) return false;
    pick_targets[pick_n] = captureTarget(offset) orelse return false;
    pick_n += 1;
    return true;
}

// ── Diagnostics ──────────────────────────────────────────────────────
// Pushed by the server (publishDiagnostics): anchor + severity + packed
// message, for gutter markers and `]d`/`[d` navigation. One set per session,
// belonging to the document that session has open.
pub const MAX_DIAG = 256;
pub const DiagnosticProvenance = enum { versioned, legacy_unversioned };

pub const Diags = struct {
    targets: [MAX_DIAG]PickTarget = undefined,
    sev: [MAX_DIAG]u8 = undefined,
    moff: [MAX_DIAG]usize = undefined,
    mlen: [MAX_DIAG]usize = undefined,
    msgs: [1 << 13]u8 = undefined,
    n: usize = 0,
    snapshot: ?u32 = null,
    provenance: DiagnosticProvenance = .legacy_unversioned,

    pub fn message(self: *const Diags, i: usize) []const u8 {
        return self.msgs[self.moff[i]..][0..self.mlen[i]];
    }
};

// ── Sessions ─────────────────────────────────────────────────────────
/// A live server and everything it is about. The key is the triple the server
/// was spawned FOR, so a config change re-keys onto a new session rather than
/// quietly repurposing the running one.
pub const Session = struct {
    conn: rpc.Conn = .{},

    /// The triple this server was spawned for, OWNED. A workspace root is as
    /// long as the user's directories are, and while these were fixed fields a
    /// root that did not fit made the whole key unbuildable — so LSP silently
    /// did nothing for that project, indistinguishable from "not configured".
    /// Owning them means a key is always the WHOLE identity, which is what the
    /// refusal-on-truncation used to be protecting: half a root names a
    /// different workspace, and routing onto a neighbour's server is worse than
    /// any refusal.
    lang: []u8,
    cmd: []u8,
    root: []u8,

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
    /// Owned, for the same reason `root` is: it is BUILT from that root.
    uri: []u8 = &.{},

    diag: Diags = .{},
    /// The new name typed into the rename prompt, sent once the server is
    /// ready. Owned: a truncated new name renames the symbol to the wrong
    /// thing, and a silent wrong edit is the worst answer available.
    rename: []u8 = &.{},

    /// One slot per kind: concurrency between kinds is structural, and a second
    /// ask of one kind can only ever supersede its own predecessor. It lives
    /// HERE, on the session, because that is what it is — per-(session, kind)
    /// state. It used to be a parallel static array indexed by pointer
    /// arithmetic back into the session table, which is why that table could
    /// not move.
    pending: [kind_count]Pending = @splat(.{}),
};

/// Every live session, each individually allocated so a `*Session` handed out
/// earlier survives the table growing (`core/Buffers.zig`'s shape, and its
/// reason). There is no cap: how many `(language, project)` pairs you may work
/// on at once was never a decision anybody made, and a session costs a
/// handshake plus a re-index to re-establish — so the only honest bound is the
/// guest heap, which says so when it refuses.
///
/// A session is never retired. It was, once, but only to make room in a fixed
/// table; nothing else ever wanted a running server gone, and with the table
/// unbounded there is no room left to make.
pub var sessions: std.ArrayList(*Session) = .empty;

/// The identity of the server the ACTIVE buffer needs, freshly read and OWNED —
/// `path`/`cwd` share one host scratch buffer and `config` another, so the three
/// parts cannot be borrowed at once. A session that keeps this key TAKES these
/// slices rather than copying them into fields of its own.
pub const Key = struct {
    lang: []u8,
    cmd: []u8,
    root: []u8,

    pub fn deinit(self: Key) void {
        const alloc = weft.allocator;
        alloc.free(self.lang);
        alloc.free(self.cmd);
        alloc.free(self.root);
    }
};

/// Why this buffer has no session. `unserved` is the common no-op every plain
/// file takes and says nothing; the other two are REFUSALS, and a capability
/// that refuses silently is one the user cannot tell from an unconfigured one.
pub const Refusal = enum { none, no_place, out_of_memory };

/// What was last said about a refusal, so it is echoed when it STARTS rather
/// than on every keystroke that re-asks. Cleared the moment a key resolves, so
/// the next occasion speaks again.
pub var announced: Refusal = .none;

pub fn announce(why: Refusal) void {
    if (announced == why) return;
    announced = why;
    switch (why) {
        .none => {},
        .no_place => weft.echo("lsp: this place has no local directory — no server started"),
        .out_of_memory => weft.echo("lsp: out of memory — could not start a server here"),
    }
}

/// Why building a key did not produce one. `Unserved` is the no-op; the other
/// two are the refusals `announce` speaks.
pub const KeyError = error{ Unserved, NoPlace, OutOfMemory };

/// The active file's language id (its extension), copied out of scratch.
pub fn activeLang() KeyError![]u8 {
    const path = weft.path() orelse return error.Unserved;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return error.Unserved;
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return error.Unserved;
    return weft.allocator.dupe(u8, ext);
}

/// The server command for `lang`: config (`weft.set("lsp","<lang>","<cmd>")`), or
/// a built-in default. "" ⇒ no server for this language.
pub fn serverCmd(lang: []const u8) []const u8 {
    const c = weft.config(lang);
    if (c.len > 0) return c;
    if (std.mem.eql(u8, lang, "zig")) return "zls";
    return "";
}

/// The server identity the active buffer needs.
pub fn activeKey() KeyError!Key {
    const alloc = weft.allocator;
    const lang = try activeLang();
    errdefer alloc.free(lang);
    const configured = serverCmd(lang);
    if (configured.len == 0) return error.Unserved;
    const cmd = try alloc.dupe(u8, configured);
    errdefer alloc.free(cmd);
    // WHERE, not the process's launch directory (`doc/place.md`). This field
    // has always been part of the key; filling it from a process-wide constant
    // is what made every project share one server. A place with no local
    // directory has no root to serve, and it SAYS so: a configured language
    // that quietly starts nothing is indistinguishable from an unconfigured one.
    const here = weft.placeRoot();
    if (here.len == 0) return error.NoPlace;
    const root = try alloc.dupe(u8, here);
    return .{ .lang = lang, .cmd = cmd, .root = root };
}

/// The key for the active buffer, with any refusal spoken once. Null covers
/// both the no-op (nothing configured) and the refusals, which have already
/// said their piece by the time this returns.
///
/// Deliberately does NOT clear `announced` on success: only actually HAVING a
/// session ends the condition that was reported, and the mint after this can
/// still fail. The two callers clear it where they hand one back.
pub fn keyForActive() ?Key {
    return activeKey() catch |err| switch (err) {
        error.Unserved => null, // not a refusal: this file has no server
        error.NoPlace => {
            announce(.no_place);
            return null;
        },
        error.OutOfMemory => {
            announce(.out_of_memory);
            return null;
        },
    };
}

pub fn matches(s: *const Session, key: Key) bool {
    return std.mem.eql(u8, s.lang, key.lang) and
        std.mem.eql(u8, s.cmd, key.cmd) and
        std.mem.eql(u8, s.root, key.root);
}

/// The session serving the active buffer, WITHOUT starting one. The honest test
/// for "does this server's document sit in front of us right now" — a poll-time
/// delivery asks it before touching any coordinate, anchor or layer.
pub fn lookupActive() ?*Session {
    const key = keyForActive() orelse return null;
    defer key.deinit();
    for (sessions.items) |s| {
        if (matches(s, key)) {
            announce(.none);
            return s;
        }
    }
    return null;
}

/// The session serving the active buffer, started if this is the first file of
/// its language in this place. A session whose spawn failed stays in the table
/// and dead, so a missing server binary is reported once per language rather
/// than once per keystroke.
pub fn ensureActive() ?*Session {
    const key = keyForActive() orelse return null;
    for (sessions.items) |s| {
        if (matches(s, key)) {
            key.deinit();
            announce(.none);
            return s;
        }
    }
    const alloc = weft.allocator;
    const s = mint(key) orelse {
        key.deinit();
        announce(.out_of_memory);
        return null;
    };
    announce(.none); // there IS a session here now, whatever happens to it next
    if (!s.conn.start(s.cmd)) {
        weft.echo("lsp: could not start server");
        return s;
    }
    const params = initializeParams(s) orelse {
        // Naming the workspace is not optional: `rootUri: null` would tell the
        // server it is rooted nowhere, which is the silent wrong answer this
        // whole key exists to prevent.
        weft.echo("lsp: out of memory — could not name the workspace");
        return s;
    };
    defer alloc.free(params);
    s.init_id = s.conn.request("initialize", params);
    return s;
}

/// Allocate a session that TAKES `key`'s slices (nothing is copied twice) and
/// add it to the table. Null when the guest heap refuses; `key` is the caller's
/// to free in that case.
pub fn mint(key: Key) ?*Session {
    const alloc = weft.allocator;
    sessions.ensureUnusedCapacity(alloc, 1) catch return null;
    const s = alloc.create(Session) catch return null;
    s.* = .{ .lang = key.lang, .cmd = key.cmd, .root = key.root };
    sessions.appendAssumeCapacity(s);
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
/// Allocated, because the root it names is as long as the user's directories
/// are. Caller frees.
pub fn initializeParams(s: *const Session) ?[]u8 {
    const caps =
        \\"capabilities":{"textDocument":{"hover":{"contentFormat":["plaintext","markdown"]},"synchronization":{},"publishDiagnostics":{"versionSupport":true}}}
    ;
    if (s.root.len == 0 or s.root[0] != '/')
        return weft.allocator.dupe(u8, "{\"processId\":null,\"rootUri\":null," ++ caps ++ "}") catch null;
    return std.fmt.allocPrint(
        weft.allocator,
        "{{\"processId\":null,\"rootUri\":\"file://{s}\",{s}}}",
        .{ s.root, caps },
    ) catch null;
}

pub fn releaseDiagnostics(s: *Session) void {
    for (s.diag.targets[0..s.diag.n]) |target| releaseTarget(target);
    s.diag.n = 0;
    if (s.diag.snapshot) |snapshot| weft.releaseDocSnapshot(snapshot);
    s.diag.snapshot = null;
}

pub fn releaseSynced(s: *Session) void {
    if (s.synced) |snapshot| weft.releaseDocSnapshot(snapshot);
    s.synced = null;
}

// ── Position ↔ offset (ASCII columns for now) ────────────────────────
pub const Pos = struct { line: usize, col: usize };

pub fn posOf(offset: usize) Pos {
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

pub fn offsetOf(line: usize, col: usize) usize {
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
pub fn syncDoc(s: *Session) bool {
    if (!s.conn.live) return false;
    if (!retargetDoc(s)) return false;
    if (s.opened) {
        if (s.synced) |snapshot| {
            if (weft.docSnapshotIsCurrent(snapshot)) return true;
        }
    }
    const alloc = weft.allocator;
    const uri = s.uri;
    const total = weft.byteLen();

    // The JSON-RPC envelope around the (streamed) document text. `params` is the
    // {textDocument…text:"} … "} object; the envelope wraps it.
    const prefix = if (!s.opened) blk: {
        s.doc_version = 1;
        break :blk std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\",\"version\":1,\"text\":\"", .{ uri, s.lang }) catch return false;
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
///
/// False when the active buffer has no uri to name it by. The caller must NOT
/// go on: streaming this buffer's text under the previous document's uri is a
/// silent wrong answer, and refusing to sync is one the user is told about.
pub fn retargetDoc(s: *Session) bool {
    const uri = buildUri() orelse return false;
    if (s.opened and std.mem.eql(u8, uri, s.uri)) {
        weft.allocator.free(uri);
        return true;
    }
    if (s.opened) {
        if (reqParams("{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{s.uri})) |body|
            s.conn.notify("textDocument/didClose", body);
    }
    releaseDiagnostics(s);
    releaseSynced(s);
    s.opened = false;
    weft.allocator.free(s.uri);
    s.uri = uri;
    return true;
}

/// The active buffer's `file://` uri, allocated (caller owns). Absolute paths
/// pass through; relative ones are resolved INSIDE the place they belong to, so
/// the uri matches the absolute uris a server rooted at that place returns in
/// its locations.
///
/// `weft.placePath` is what reconciles the two spellings — see its doc for why
/// a naive `<root>/<path>` double-counts what they share.
pub fn buildUri() ?[]u8 {
    const alloc = weft.allocator;
    // Copy the (possibly scratch-backed) path out before calling placeRoot
    // (also scratch).
    const spelled = alloc.dupe(u8, weft.path() orelse "untitled") catch return null;
    defer alloc.free(spelled);
    const root = weft.placeRoot();
    // The widest a join of the two can be: root, a separator, and the whole
    // spelling — `placePath` only ever drops from the spelling, never adds.
    const joined = alloc.alloc(u8, root.len + 1 + spelled.len) catch return null;
    defer alloc.free(joined);
    const abs = weft.placePath(root, spelled, joined);
    if (abs.len == 0) return null;
    return std.fmt.allocPrint(alloc, "file://{s}", .{abs}) catch null;
}

// ── Request identity: what a session has in flight ────────────────────

// ── Request identities ───────────────────────────────────────────────
pub const Kind = enum { hover, definition, references, symbols, format, rename, signature, inlay, codeaction, completion };
pub const kind_count = std.meta.fields(Kind).len;

/// One ask. `id` 0 means ARMED: built, but not yet on the wire (the handshake
/// hasn't landed, or the rename prompt is still open); a positive id is in
/// flight and is what a reply is matched against.
pub const Pending = struct {
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

/// JSON-escaped length of one byte — MUST match `escapeAppend` exactly, so the
/// size pass and the send pass of a streamed document agree on the frame length.
pub fn escapedLen(chunk: []const u8) usize {
    var n: usize = 0;
    for (chunk) |c| n += switch (c) {
        '"', '\\', '\n', '\r', '\t' => @as(usize, 2),
        0...8, 11, 12, 14...31 => 6,
        else => 1,
    };
    return n;
}

/// A request's JSON params, built into one growable scratch. Valid until the
/// next `reqParams` call — each caller writes it straight to the wire.
pub var param_buf: std.ArrayList(u8) = .empty;

pub fn reqParams(comptime fmt: []const u8, args: anytype) ?[]const u8 {
    param_buf.clearRetainingCapacity();
    param_buf.print(weft.allocator, fmt, args) catch return null;
    return param_buf.items;
}

/// Append `chunk` JSON-escaped to `list` (grows on the heap). Byte-for-byte the
/// same escaping `escapedLen` counts; a UTF-8 sequence split across chunks is
/// fine — bytes ≥ 0x80 copy verbatim.
pub fn escapeAppend(list: *std.ArrayListUnmanaged(u8), chunk: []const u8) !void {
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
