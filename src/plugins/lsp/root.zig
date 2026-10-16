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
const base_cmds = [_]weft.CommandEntry{
    .{ .name = "lsp.hover", .arity = .one, .call = cmdHover, .summary = "Describe the symbol under the cursor.", .label = "Hover", .icon = "info" },
    .{ .name = "lsp.goto-definition", .arity = .one, .call = cmdDefinition, .summary = "Jump to the definition of the symbol under the cursor.", .label = "Go to Definition", .menu = "Go", .group = "symbol", .order = 1, .icon = "crosshair" },
    .{ .name = "lsp.goto-type-definition", .arity = .one, .call = cmdTypeDefinition, .summary = "Jump to the definition of the symbol's type.", .label = "Go to Type Definition", .menu = "Go", .group = "symbol", .order = 2 },
    .{ .name = "lsp.goto-implementation", .arity = .one, .call = cmdImplementation, .summary = "Jump to the implementation of the symbol under the cursor.", .label = "Go to Implementation", .menu = "Go", .group = "symbol", .order = 3 },
    .{ .name = "lsp.references", .arity = .one, .call = cmdReferences, .summary = "List the references to the symbol under the cursor.", .label = "Find References", .prompts = true, .menu = "Go", .group = "symbol", .order = 4, .icon = "search" },
    .{ .name = "lsp.pick-symbol", .call = cmdSymbols, .arity = .whole, .summary = "Pick a symbol in this file and jump to it.", .label = "Go to Symbol", .prompts = true, .menu = "Go", .group = "symbol", .order = 5, .icon = "list-tree" },
    .{ .name = "lsp.next-diagnostic", .call = cmdNextDiag, .arity = .whole, .summary = "Go to the next diagnostic.", .label = "Next Problem", .menu = "Go", .group = "problems", .order = 1, .icon = "chevron-down" },
    .{ .name = "lsp.prev-diagnostic", .call = cmdPrevDiag, .arity = .whole, .summary = "Go to the previous diagnostic.", .label = "Previous Problem", .menu = "Go", .group = "problems", .order = 2, .icon = "chevron-up" },
    .{ .name = "lsp.pick-diagnostic", .call = cmdDiagnostics, .arity = .whole, .summary = "Pick a diagnostic in this file and jump to it.", .label = "Go to Problem", .prompts = true, .menu = "Go", .group = "problems", .order = 3, .icon = "warning" },
    .{ .name = "lsp.list-diagnostics", .call = cmdDiagnosticsList, .arity = .whole, .summary = "Return every stored diagnostic as a row of path, line, column, severity and message.", .internal = true },
    .{ .name = "lsp.format", .call = cmdFormat, .arity = .whole, .summary = "Format the buffer through the language server.", .label = "Format with Language Server", .menu = "Edit", .group = "format", .order = 2, .icon = "format" },
    .{ .name = "lsp.rename", .arity = .one, .call = cmdRename, .summary = "Rename the symbol under the cursor everywhere.", .label = "Rename Symbol", .prompts = true, .menu = "Edit", .group = "refactor", .order = 1, .icon = "rename" },
    .{ .name = "lsp.signature-help", .arity = .one, .call = cmdSignature, .summary = "Show the signature of the call around the cursor.", .label = "Signature Help" },
    .{ .name = "lsp.toggle-inlay-hints", .call = cmdInlay, .arity = .whole, .summary = "Show or hide the language server's inlay hints.", .label = "Toggle Inlay Hints" },
    .{ .name = "lsp.code-actions", .arity = .one, .call = cmdCodeActions, .summary = "Offer the code actions available at the cursor.", .label = "Code Actions", .prompts = true, .menu = "Edit", .group = "refactor", .order = 2, .icon = "lightbulb" },
    // Internal: the deferred half of `on_poll`'s message dispatch (task #19
    // item 4) — not a user-facing verb, invoked only via `weft.run` from
    // `on_poll` itself. See `on_poll`'s doc.
    .{ .name = "lsp.deliver", .call = lspDeliverInternal, .arity = .whole, .summary = "Deliver the language server's queued messages.", .internal = true },
    // Internal: what a heard signal does (`on_signal`), run as a dispatch.
    .{ .name = "lsp.popup-close", .call = closePopup, .arity = .whole, .summary = "Close the hover or signature popup.", .internal = true },
    .{ .name = "lsp.popup-typed", .call = typed, .arity = .whole, .summary = "Ask for signature help where typing left the caret, if it is due.", .internal = true },
};

/// The rename prompt's five editing commands (`rename_prompt`, below),
/// mapped into lsp's `weft.CommandEntry` so `on_command`'s id indexing stays one table.
const prompt_cmds: [rename_prompt.commands.len]weft.CommandEntry = blk: {
    var arr: [rename_prompt.commands.len]weft.CommandEntry = undefined;
    // Editing the prompt's own line: never the selection.
    for (rename_prompt.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
    break :blk arr;
};

const cmds = base_cmds ++ prompt_cmds;

fn describeExtra() void {
    weft.declareCapability("edit/completion");
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    weft.provideCompletion();
    typed_sig = weft.signalSubscribe(weft.typed_signal);
    caret_sig = weft.signalSubscribe(weft.caret_signal);
    mode_sig = weft.signalSubscribe(weft.mode_signal);
    rename_prompt.install();
}

/// Completion request (caps provider): send textDocument/completion for the
/// cursor and DEFER — the response commits into `session` off a later poll. The
/// provider registration is one; the predicate is per language, resolved here as
/// "which session serves this buffer". No server for it (or not ready yet) ⇒
/// decline, so the merge isn't left waiting on us.
fn on_complete(session: u32) callconv(.c) void {
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
fn on_poll() callconv(.c) void {
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
            weft.run("lsp.deliver");
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
fn on_activate() callconv(.c) void {
    if (session_mod.pick_n > 0) resetPickTargets();
    weft.decorateClear();
    const s = ensureActive() orelse return;
    if (!s.conn.live or !s.ready) return;
    publishTriggers(s);
    if (!syncDoc(s)) return;
    flushArmed(s);
    paintDiagnostics(s);
}

/// A pick entry was chosen — a location jump. The picker is a PICKER again:
/// its one job here is choosing among references and symbols, which are
/// candidates. Typing a new name is `rename_prompt`'s.
fn onPickAccept(pick_id: u32) void {
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
        const offset = targetOffset(target) orelse return;
        // Going to a reference or a symbol is a jump in every grammar: the
        // place it leaves is where `jump.back` returns.
        weft.jumpPush();
        weft.jump(offset);
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
fn cmdTypeDefinition() void {
    fire(.type_definition);
}
fn cmdImplementation() void {
    fire(.implementation);
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
    sig_auto = false;
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
    .name = "lsp.rename",
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

/// Pick among this document's diagnostics, in the order the server sent
/// them; accepting one jumps there (`onPickAccept`, like a reference).
fn cmdDiagnostics() void {
    const s = lookupActive() orelse return weft.echo("lsp: no diagnostics");
    if (s.diag.n == 0) return weft.echo("lsp: no diagnostics");
    const snapshot = s.diag.snapshot orelse return staleDiagnostics(s);
    if (!weft.docSnapshotIsCurrent(snapshot)) return staleDiagnostics(s);
    resetPickTargets();
    weft.pickBegin("diagnostic", pick_id_results);
    var i: usize = 0;
    while (i < s.diag.n) : (i += 1) {
        const off = targetOffset(s.diag.targets[i]) orelse continue;
        if (!addPickTarget(off)) break;
        const label: []const u8 = switch (s.diag.sev[i]) {
            1 => "error",
            2 => "warning",
            3 => "info",
            else => "hint",
        };
        var buf: [512]u8 = undefined;
        const msg = s.diag.message(i);
        const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, msg[0..@min(msg.len, 400)] }) catch label;
        weft.pickAdd(text, "");
    }
    weft.pickEnd();
}

var list_buf: [1 << 15]u8 = undefined;

/// Every session's stored diagnostics as the command's string result, one
/// `path\tline\tcol\tseverity\tmessage` row each (1-based line and column,
/// as the server placed them) — what a list of problems reads when the
/// `diagnostics` signal says they moved. Rows past the buffer are dropped
/// whole; tabs and newlines in a message become spaces.
fn cmdDiagnosticsList() void {
    var w: usize = 0;
    outer: for (sessions.items) |s| {
        const path = if (std.mem.startsWith(u8, s.uri, "file://")) s.uri["file://".len..] else s.uri;
        var i: usize = 0;
        while (i < s.diag.n) : (i += 1) {
            const label: []const u8 = switch (s.diag.sev[i]) {
                1 => "error",
                2 => "warning",
                3 => "info",
                else => "hint",
            };
            const row = std.fmt.bufPrint(list_buf[w..], "{s}\t{d}\t{d}\t{s}\t", .{ path, s.diag.line[i] + 1, s.diag.col[i] + 1, label }) catch break :outer;
            const msg = s.diag.message(i);
            if (w + row.len + msg.len + 1 > list_buf.len) break :outer;
            w += row.len;
            for (msg) |c| {
                list_buf[w] = if (c == '\t' or c == '\n' or c == '\r') ' ' else c;
                w += 1;
            }
            list_buf[w] = '\n';
            w += 1;
        }
    }
    weft.setResultStr(list_buf[0..w]);
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
            keepTriggers(s, obj.get("result"));
            keepSignatureTriggers(s, obj.get("result"));
            // Only the session whose document is in front of us may open it —
            // otherwise the handshake would didOpen someone else's buffer.
            if (lookupActive() == s) {
                _ = syncDoc(s); // didOpen the active doc → diagnostics start flowing
                flushArmed(s);
                publishTriggers(s);
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
        if (kind != .completion and kind != .resolve and resolvable) {
            _ = send(s, p, kind);
        } else retire(s, p);
        return;
    }
    weft.releaseDocSnapshot(snapshot);
    p.snapshot = null;
    p.id = 0; // answered
    switch (kind) {
        .hover => presentHover(p, result),
        .definition, .type_definition, .implementation => presentDefinition(s, result),
        .references => presentLocations(s, result, "reference"),
        .symbols => presentSymbols(result),
        .format => weft.echo(if (applyEdits(result) > 0) "lsp: formatted" else "lsp: nothing to format"),
        .rename => weft.echo(if (applyWorkspaceEdit(s, result) > 0) "lsp: renamed" else "lsp: rename made no change"),
        .signature => presentSignature(p, result),
        .inlay => presentInlay(result),
        .codeaction => presentCodeActions(s, result),
        .completion => presentCompletion(s, p, result),
        .resolve => presentResolve(s, result),
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
        s.diag.line[s.diag.n] = std.math.cast(u32, pos.line) orelse 0;
        s.diag.col[s.diag.n] = std.math.cast(u32, pos.col) orelse 0;
        const ml = @min(msg.len, s.diag.msgs.len - mw);
        @memcpy(s.diag.msgs[mw..][0..ml], msg[0..ml]);
        s.diag.moff[s.diag.n] = mw;
        s.diag.mlen[s.diag.n] = ml;
        mw += ml;
        s.diag.n += 1;
    }
    if (s.diag.n == 0) releaseDiagnostics(s);
    paintDiagnostics(s);
    weft.signalEmit(session_mod.diagnostics_signal);
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
fn presentCompletion(s: *Session, p: *Pending, result: rpc.Value) void {
    const session = p.caps;
    p.caps = 0; // answered: `retire` must not also decline it
    if (session == 0) return;
    // Kept, as sent, for `completionItem/resolve` to send back.
    forgetAnswered(s);
    s.answered = session;
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
        if (s.resolves) {
            if (std.json.Stringify.valueAlloc(weft.allocator, it, .{})) |json| {
                s.answered_items.append(weft.allocator, json) catch weft.allocator.free(json);
            } else |_| {}
        }
    }
    weft.capsCommit(session);
}

fn forgetAnswered(s: *Session) void {
    for (s.answered_items.items) |j| weft.allocator.free(j);
    s.answered_items.clearRetainingCapacity();
    s.answered = 0;
}

/// A completion's popup asks for what an item of ours left out (its docs):
/// send the item back to the server (`completionItem/resolve`), and fill it
/// in when the answer lands (`presentResolve`).
fn on_resolve(session: i32, index: i32) callconv(.c) void {
    if (index < 0) return;
    const id: u32 = @bitCast(session);
    for (sessions.items) |s| {
        if (s.answered != id) continue;
        const i: usize = @intCast(index);
        if (!s.resolves or i >= s.answered_items.items.len) return;
        s.resolving = .{ .session = id, .index = i, .item = s.answered_items.items[i] };
        const p = arm(s, .resolve) orelse return;
        if (s.ready) _ = send(s, p, .resolve);
        return;
    }
}

/// The server filled the item in: hand its detail and documentation back
/// to the race it answered.
fn presentResolve(s: *Session, result: rpc.Value) void {
    const r = s.resolving;
    if (r.session == 0 or r.session != s.answered) return;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(weft.allocator);
    if (field(result, "documentation")) |d| contentsMarkdown(&doc, d);
    const detail = strOf(field(result, "detail"));
    if (doc.items.len == 0 and detail.len == 0) return;
    weft.capsItemDoc(r.session, r.index, detail, doc.items);
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
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(weft.allocator);
    if (result == .object) if (result.object.get("contents")) |c| contentsMarkdown(&md, c);
    if (md.items.len == 0) {
        closePopup(); // drop any popup from a still-live prior hover
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
    // The server's markdown, as it sent it: the host renders it as a
    // document, wrapped to the popup.
    weft.surfaceCaret(offset);
    weft.surfaceDoc(md.items, .{});
    weft.surfaceEnd(-1);
    popup = .hover;
}

// ── The popup: what shows, and when it goes ──────────────────────────
//
// One caret popup at a time: a hover, or a signature's help. Which, and when
// it closes, is this plugin's to decide — core raises `input.caret` and
// `input.mode` and keeps no rule of its own. A hover goes when the caret
// moves or the mode changes; a signature's help goes with the mode (insert
// left), and is asked again as the arguments are typed or the caret moves,
// so it follows the active parameter and closes itself — on an empty answer
// — once the caret is out of the call.

const Popup = enum { none, hover, signature };
var popup: Popup = .none;
/// The signature ask in flight came from typing, not the command: an empty
/// answer closes quietly rather than echoing.
var sig_auto = false;
var typed_sig: ?u32 = null;
var caret_sig: ?u32 = null;
var mode_sig: ?u32 = null;

fn closePopup() void {
    if (popup != .none) weft.surfaceClose();
    popup = .none;
}

/// A signal is heard off any dispatch; what it does runs through the
/// sanctioned door (`weft.run`, a dispatching entry for its duration), as
/// `on_poll`'s deliveries do.
fn on_signal(id: i32) callconv(.c) void {
    if (id < 0) return;
    const sig: u32 = @intCast(id);
    if (mode_sig == sig) {
        if (popup != .none) weft.run("lsp.popup-close");
    } else if (typed_sig == sig) {
        weft.run("lsp.popup-typed");
    } else if (caret_sig == sig) switch (popup) {
        // The caret landing past a trigger opens it too: a bracket an
        // autopair inserted is not typed text, and an arrow into a call is
        // as good a place to ask.
        .none, .signature => weft.run("lsp.popup-typed"),
        .hover => weft.run("lsp.popup-close"),
    };
}

/// A person typed, or the caret moved: past one of the server's signature
/// characters (`(`, `,`), or while its help shows, ask for it.
fn typed() void {
    const s = lookupActive() orelse return;
    if (popup == .signature) return askSignature();
    if (s.sig_triggers.len == 0) return;
    const cur = weft.cursor();
    if (cur == 0) return;
    const last = weft.slice(cur - 1, cur);
    if (last.len == 1 and std.mem.indexOfScalar(u8, s.sig_triggers, last[0]) != null) askSignature();
}

fn askSignature() void {
    sig_auto = true;
    fire(.signature);
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
    // A jump in every grammar's sense, so no grammar wraps this command to
    // push one first: the place it leaves is where `jump.back` returns.
    weft.jumpPush();
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

/// A signature's help, as a popup above the caret: the signature as code,
/// the active parameter and what it is for, then what the function does.
/// An empty answer to an ask typing made closes it quietly; to the command,
/// it says so.
fn presentSignature(p: *Pending, result: rpc.Value) void {
    const auto = sig_auto;
    sig_auto = false;
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(weft.allocator);
    signatureMarkdown(&md, result) catch {};
    if (md.items.len == 0) {
        if (popup == .signature) closePopup();
        if (!auto) weft.echo("lsp: no signature");
        return;
    }
    const offset = (if (p.target) |target| targetOffset(target) else null) orelse return;
    weft.surfaceCaret(offset);
    weft.surfaceDoc(md.items, .{ .above = true });
    weft.surfaceEnd(-1);
    popup = .signature;
}

/// `SignatureHelp` as markdown: the active signature's label in a code
/// block, its active parameter in bold with that parameter's documentation,
/// and the signature's own documentation. Empty when there is none.
fn signatureMarkdown(md: *std.ArrayList(u8), result: rpc.Value) !void {
    const a = weft.allocator;
    const sigs = field(result, "signatures") orelse return;
    if (sigs != .array or sigs.array.items.len == 0) return;
    var which: usize = 0;
    if (field(result, "activeSignature")) |v| if (asInt(v)) |n| {
        if (n >= 0 and n < sigs.array.items.len) which = @intCast(n);
    };
    const sig = sigs.array.items[which];
    const label = strOf(field(sig, "label"));
    if (label.len == 0) return;
    try md.appendSlice(a, "```\n");
    try md.appendSlice(a, label);
    try md.appendSlice(a, "\n```\n");
    // The active parameter: the signature's own, else the help's.
    var active: ?i64 = null;
    if (field(result, "activeParameter")) |v| active = asInt(v);
    if (field(sig, "activeParameter")) |v| active = asInt(v) orelse active;
    if (field(sig, "parameters")) |params| if (params == .array) if (active) |n| if (n >= 0 and n < params.array.items.len) {
        const param = params.array.items[@intCast(n)];
        // A parameter's label is its text, or an offset pair into the
        // signature's (`labelOffsetSupport`).
        const name: []const u8 = if (field(param, "label")) |l| switch (l) {
            .string => |str| str,
            .array => |pair| if (pair.items.len == 2) blk: {
                const lo = asInt(pair.items[0]) orelse break :blk "";
                const hi = asInt(pair.items[1]) orelse break :blk "";
                if (lo < 0 or hi < lo or hi > label.len) break :blk "";
                break :blk label[@intCast(lo)..@intCast(hi)];
            } else "",
            else => "",
        } else "";
        if (name.len > 0) {
            try md.appendSlice(a, "\n**`");
            try md.appendSlice(a, name);
            try md.appendSlice(a, "`**");
            var doc: std.ArrayList(u8) = .empty;
            defer doc.deinit(a);
            if (field(param, "documentation")) |d| contentsMarkdown(&doc, d);
            if (doc.items.len > 0) {
                try md.appendSlice(a, " — ");
                try md.appendSlice(a, doc.items);
            }
            try md.append(a, '\n');
        }
    };
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(a);
    if (field(sig, "documentation")) |d| contentsMarkdown(&doc, d);
    if (doc.items.len > 0) {
        try md.appendSlice(a, "\n");
        try md.appendSlice(a, doc.items);
    }
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

/// Hover contents, a signature's or a parameter's documentation, as
/// markdown: `MarkupContent` as it came (plaintext is markdown that has no
/// markup), a `MarkedString` with a language as a code block, a list of them
/// one after another.
fn contentsMarkdown(md: *std.ArrayList(u8), c: rpc.Value) void {
    const a = weft.allocator;
    switch (c) {
        .string => |s| md.appendSlice(a, s) catch {},
        .object => |o| {
            const value = strOf(o.get("value"));
            if (value.len == 0) return;
            if (o.get("language")) |lang| if (lang == .string) {
                md.appendSlice(a, "```") catch {};
                md.appendSlice(a, lang.string) catch {};
                md.append(a, '\n') catch {};
                md.appendSlice(a, value) catch {};
                md.appendSlice(a, "\n```") catch {};
                return;
            };
            md.appendSlice(a, value) catch {};
        },
        .array => |items| for (items.items) |item| {
            if (md.items.len > 0) md.appendSlice(a, "\n\n") catch {};
            contentsMarkdown(md, item);
        },
        else => {},
    }
}

fn contentsText(c: rpc.Value) []const u8 {
    return switch (c) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |v| (if (v == .string) v.string else "") else "",
        .array => |a| if (a.items.len > 0) contentsText(a.items[0]) else "",
        else => "",
    };
}

/// Keep what `initialize` said opens completion
/// (`capabilities.completionProvider.triggerCharacters`), one byte per
/// trigger: its last, the one typed last (`Session.triggers`).
fn keepTriggers(s: *Session, result: ?rpc.Value) void {
    const caps = field(result orelse return, "capabilities") orelse return;
    const provider = field(caps, "completionProvider") orelse return;
    if (field(provider, "resolveProvider")) |rp| s.resolves = rp == .bool and rp.bool;
    const list = field(provider, "triggerCharacters") orelse return;
    if (list != .array) return;
    var bytes: std.ArrayList(u8) = .empty;
    for (list.array.items) |t| {
        if (t != .string or t.string.len == 0) continue;
        const b = t.string[t.string.len - 1];
        if (std.mem.indexOfScalar(u8, bytes.items, b) != null) continue;
        bytes.append(weft.allocator, b) catch break;
    }
    const kept = bytes.toOwnedSlice(weft.allocator) catch {
        bytes.deinit(weft.allocator);
        return;
    };
    weft.allocator.free(s.triggers);
    s.triggers = kept;
}

/// Keep what `initialize` said opens or refreshes signature help
/// (`signatureHelpProvider.triggerCharacters`, `retriggerCharacters`), one
/// byte per trigger as `keepTriggers` keeps completion's.
fn keepSignatureTriggers(s: *Session, result: ?rpc.Value) void {
    const caps = field(result orelse return, "capabilities") orelse return;
    const provider = field(caps, "signatureHelpProvider") orelse return;
    var bytes: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "triggerCharacters", "retriggerCharacters" }) |name| {
        const list = field(provider, name) orelse continue;
        if (list != .array) continue;
        for (list.array.items) |t| {
            if (t != .string or t.string.len == 0) continue;
            const b = t.string[t.string.len - 1];
            if (std.mem.indexOfScalar(u8, bytes.items, b) != null) continue;
            bytes.append(weft.allocator, b) catch break;
        }
    }
    const kept = bytes.toOwnedSlice(weft.allocator) catch {
        bytes.deinit(weft.allocator);
        return;
    };
    weft.allocator.free(s.sig_triggers);
    s.sig_triggers = kept;
}

fn field(v: rpc.Value, name: []const u8) ?rpc.Value {
    return if (v == .object) v.object.get(name) else null;
}

/// Say, on the entry in front of us, which characters this server's
/// completion opens on — a context key (`lsp.trigger-characters`) any
/// auto-trigger may read, and core reads nothing into. Called where the
/// session and the active entry are known to match.
fn publishTriggers(s: *const Session) void {
    weft.contextSet("lsp.trigger-characters", s.triggers, .entry) catch {};
}

fn asInt(v: rpc.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra, .pick = onPickAccept }).exportAll();
}

comptime {
    weft.exportCallback("on_complete", &on_complete);
    weft.exportCallback("on_poll", &on_poll);
    weft.exportCallback("on_activate", &on_activate);
    weft.exportCallback("on_signal", &on_signal);
    weft.exportCallback("on_resolve", &on_resolve);
}
