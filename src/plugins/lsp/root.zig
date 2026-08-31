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
const rpc = @import("weft_jsonrpc");
const prompt = @import("weft_prompt");
const annotate = @import("weft_annotate");
const session_mod = @import("session.zig");
const request = @import("request.zig");

// The parts, named once. A command below composes them; none of them knows
// about a command.
const Session = session_mod.Session;
const sessions = &session_mod.sessions;
const PickTarget = session_mod.PickTarget;
const pick_id_results = session_mod.pick_id_results;
const captureTarget = session_mod.captureTarget;
const targetOffset = session_mod.targetOffset;
const releaseTarget = session_mod.releaseTarget;
const releasePickTargets = session_mod.releasePickTargets;
const resetPickTargets = session_mod.resetPickTargets;
const addPickTarget = session_mod.addPickTarget;
const Diags = session_mod.Diags;
const MAX_DIAG = session_mod.MAX_DIAG;
const DiagnosticProvenance = session_mod.DiagnosticProvenance;
const ensureActive = session_mod.ensureActive;
const lookupActive = session_mod.lookupActive;
const keyForActive = session_mod.keyForActive;
const syncDoc = session_mod.syncDoc;
const Pos = session_mod.Pos;
const posOf = session_mod.posOf;
const escapedLen = session_mod.escapedLen;
const escapeAppend = session_mod.escapeAppend;
const releaseDiagnostics = session_mod.releaseDiagnostics;
const max_hover_rows = request.max_hover_rows;

const reqParams = session_mod.reqParams;
const param_buf = &session_mod.param_buf;
const offsetOf = session_mod.offsetOf;
const Kind = session_mod.Kind;
const kind_count = session_mod.kind_count;
const Pending = session_mod.Pending;
const slotOf = request.slotOf;
const findPending = request.findPending;
const cancelRequest = request.cancelRequest;
const retire = request.retire;
const arm = request.arm;
const send = request.send;
const flushArmed = request.flushArmed;
const requestOf = request.requestOf;
const posRequest = request.posRequest;

// ── Plugin surface ───────────────────────────────────────────────────
const Cmd = struct { name: []const u8, handler: *const fn () void };
const base_cmds = [_]Cmd{
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

/// The rename prompt's five editing commands (`rename_prompt`, below),
/// mapped into lsp's `Cmd` so `on_command`'s id indexing stays one table.
const prompt_cmds: [rename_prompt.commands.len]Cmd = blk: {
    var arr: [rename_prompt.commands.len]Cmd = undefined;
    for (rename_prompt.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .handler = c.handler };
    break :blk arr;
};

const cmds = base_cmds ++ prompt_cmds;

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.declareCapability("edit/completion");
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    weft.provideCompletion();
    rename_prompt.install();
    // …and annotate the completion rows this plugin's own answers produce.
    // See `on_slot_fire` below for why the tag lives here and not in core.
    annotate.bind();
}

// ── Naming a CompletionItemKind ──────────────────────────────────────
//
// `CompletionItemKind` is an LSP number, and this is the LSP plugin. Core
// stores the number on a completion item and carries it across as a row key;
// what "3" is called is protocol knowledge, and protocol knowledge belongs to
// whoever speaks the protocol.
//
// It used to be `complete_ui.kindTag` — a switch in core, over a number space
// core has no other reason to understand, producing display text core has no
// business choosing. It moved here whole.

var tag_storage: [256][]const u8 = undefined;

export fn on_slot_fire(session: i32) void {
    var round = annotate.ask(@bitCast(session)) orelse return;
    // Only completion rows. Every other category names rows this plugin
    // cannot resolve, and declining is cheaper than answering with blanks.
    if (!std.mem.eql(u8, round.category, "complete")) return;

    var n: usize = 0;
    while (round.next()) |row| {
        if (n == tag_storage.len) break;
        // The row's key is the item's kind, in decimal — core carries the
        // digits and reads nothing into them.
        const kind = std.fmt.parseInt(u8, row.key, 10) catch 0;
        tag_storage[n] = kindTag(kind);
        n += 1;
    }
    annotate.tell(@bitCast(session), round.from, tag_storage[0..n]);
}

fn kindTag(kind: u8) []const u8 {
    return switch (kind) {
        2, 3 => "fn", // Method, Function
        4 => "new", // Constructor
        5, 10 => "field", // Field, Property
        6 => "var", // Variable
        7, 22 => "type", // Class, Struct
        8 => "iface", // Interface
        9 => "mod", // Module
        13, 20 => "enum", // Enum, EnumMember
        14 => "kw", // Keyword
        15 => "snip", // Snippet
        21, 12 => "const", // Constant, Value
        25 => "typaram", // TypeParameter
        else => "", // Text/unknown → no tag
    };
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
    // Indexed, and re-reading `sessions.items` each step: the nested `weft.run`
    // below is a real dispatching entry, so what it drives may mint a session
    // and grow the table under us. A session is never removed, so index `i`
    // keeps naming the same one; only the array of POINTERS can move, and
    // re-reading it each iteration is what makes that harmless.
    var i: usize = 0;
    while (i < sessions.items.len) : (i += 1) {
        const s = sessions.items[i];
        while (s.conn.live) {
            pending_msg = s.conn.next() orelse break;
            pending_session = s;
            weft.run("lsp-deliver-internal");
        }
    }
}

var pending_msg: rpc.Value = undefined;
var pending_session: ?*Session = null;
fn lspDeliverInternal() void {
    dispatch(pending_session orelse return, pending_msg);
}

/// A buffer took focus: ensure its language's server is up and its document is
/// the one that server has open, so diagnostics flow without waiting for a
/// request. Every OTHER session is left untouched — that is what makes two
/// languages two independent servers.
export fn on_activate() void {
    if (session_mod.pick_n > 0) resetPickTargets();
    weft.decorateClear();
    const s = ensureActive() orelse return;
    if (!s.conn.live or !s.ready) return;
    if (!syncDoc(s)) return;
    flushArmed(s);
    paintDiagnostics(s);
}

/// A pick entry was chosen — a location jump. The picker is a PICKER again:
/// its one job here is choosing among references and symbols, which are
/// candidates. Typing a new name is `rename_prompt`'s.
export fn on_pick_accept(pick_id: u32) void {
    if (pick_id != pick_id_results) return;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    defer releasePickTargets();
    const idx = switch (outcome) {
        .candidate => |candidate| candidate.index,
        .input, .cancelled => return,
    };
    if (idx < session_mod.pick_n) {
        const target = session_mod.pick_targets[idx];
        weft.jump(targetOffset(target) orelse return);
    }
}

/// Hold the new name this session will rename to. False when the guest heap
/// refuses, so the caller refuses out loud rather than sending a half name.
fn setRename(s: *Session, name: []const u8) bool {
    const owned = weft.allocator.dupe(u8, name) catch return false;
    weft.allocator.free(s.rename);
    s.rename = owned;
    return true;
}

/// The session whose rename prompt is open. The Head owns one picker, so at most
/// one rename is ever being typed.
var prompting: ?*Session = null;

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
    weft.allocator.free(s.rename);
    s.rename = &.{};
    if (weft.argStr(0)) |name| {
        if (name.len > 0) {
            if (!setRename(s, name)) {
                weft.echo("lsp: out of memory — rename not sent");
                retire(s, p);
                return;
            }
            if (s.ready) _ = send(s, p, .rename);
            return;
        }
    }
    prompting = s;
    rename_prompt.open("rename to: ");
}

/// The new-name prompt. This used to be `pickBegin`/`pickEnd` with NO ITEMS
/// — the fuzzy picker opened as an empty list so its free-text accept could
/// be read as a text field. It worked, but it told the user "search" when it
/// meant "type a name", it put the answer through candidate ranking that had
/// nothing to rank, and it made cancelling a rename a different gesture from
/// cancelling anything else. It is the shared minibuffer now.
///
/// `resting` is null deliberately: lsp is a SERVICE, live under vim, helix
/// and emacs alike, so it returns you to the mode the ENTRY declares rather
/// than to a mode lsp chose on your behalf.
const rename_prompt = prompt.Prompt(.{
    .name = "lsp-rename",
    .capacity = 256,
    .on_accept = onRenameName,
    .on_cancel = struct {
        fn cancelled() void {
            const s = prompting orelse return;
            prompting = null;
            retire(s, slotOf(s, .rename));
        }
    }.cancelled,
});

/// The typed name: hold it on the session and send, or refuse out loud.
fn onRenameName(name: []const u8) void {
    const s = prompting orelse return;
    prompting = null;
    const p = slotOf(s, .rename);
    if (!p.used or p.id != 0) return;
    if (name.len == 0) {
        retire(s, p);
        return;
    }
    if (!setRename(s, name)) {
        weft.echo("lsp: out of memory — rename not sent");
        retire(s, p);
        return;
    }
    if (s.ready) _ = send(s, p, .rename);
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

fn presentLocations(s: *Session, result: rpc.Value, title: []const u8) void {
    resetPickTargets();
    var dropped = false;
    if (result == .array) {
        weft.pickBegin(title, pick_id_results);
        for (result.array.items) |item| {
            const loc = locationOf(item) orelse continue;
            if (!sameUri(s, loc.uri)) continue; // cross-file later
            if (session_mod.pick_n >= session_mod.pick_targets.len) {
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
    if (session_mod.pick_n == 0) weft.echo("lsp: no references");
    if (dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} references — some omitted", .{session_mod.pick_targets.len}));
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
    if (session_mod.pick_n == 0) weft.echo("lsp: no symbols");
    if (symbols_dropped) weft.echo(std.fmt.comptimePrint("lsp: >{d} symbols — some omitted", .{session_mod.pick_targets.len}));
}

/// A DocumentSymbol (nested, has selectionRange/children) or a SymbolInformation
/// (flat, has location). Add it + recurse children (bounded).
fn addSymbol(item: rpc.Value) void {
    if (item != .object) return;
    if (session_mod.pick_n >= session_mod.pick_targets.len) {
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
    return uri.len == 0 or std.mem.eql(u8, uri, s.uri);
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
