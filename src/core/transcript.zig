//! `transcript.zig` — the agent transcript: W5's REQUIRED first `graph.zig`
//! client (doc/substrate.md "W5 ordering — transcript
//! first, DECIDED"; review A7b: W6's check-in scenario needs a real graph
//! document to attach to, not magit, which stays on the current
//! tool-buffer machinery). A transcript is a sequence of role-tagged
//! entries (user/agent/tool turns), each entry's body a real text CRDT —
//! collaboratively editable later, without redesign.
//!
//! Model code runs HOST-SIDE/in-process, per §2.6's "where the graph-side
//! plugin code runs": no graph ABI crosses the wasm membrane yet (fn-
//! pointer `Projection` contracts don't survive wasm; a guest-facing
//! `wl_graph_*` ABI is its own later, priced step). `core` is the right
//! home for the same reason `Document`/`Buffers` are: this is
//! infrastructure other host machinery (W6's check-in, eventually the
//! session/wire layer) is built on, not a single feature's private state.
//!
//! ## Why entries are a `seq`, not a structural list (F3)
//!
//! `graph.zig`'s module doc comment states F3's general rule: ObjectDoc's
//! list op (`seqInsert`/`seqAppend` here) is legitimate ONLY for leaf
//! sequences that never reparent. Applied honestly to THIS model: a
//! transcript entry is created once (`append`), read, and its body text
//! may be edited in place (`editText`) — it never moves to a different
//! transcript, never nests under another entry, never gets reordered
//! relative to its siblings (a transcript's order IS its history; there is
//! no "drag message 3 above message 1"). That is exactly the "leaf
//! sequence" carve-out F3 draws, stated against this model rather than
//! asserted in the abstract: `entries` is legitimately a `seq`. Deletion
//! (retracting a turn) uses `seqDelete`, which removes an index — not a
//! move-to-trash reparent; a future "soft delete" would be a `deleted`
//! flag on the entry map, not a structural change.
//!
//! If a later graph client needs actual structure (a tool-call tree with
//! collapsible sub-turns that can be reparented, say) it must NOT reuse
//! this pattern — it waits for F3's parent-register mechanism.
//!
//! ## `fill` + `reconcileOnSave` — the `on_save` `Projection` instance (W5
//! slice 3)
//!
//! `fill` (below) projects the model to text; `reconcileOnSave` (further
//! below, by the "`on_save` reconciliation" section) is the other half —
//! an edited projection buffer's `save` reconciles BACK into the graph
//! doc, by NODE IDENTITY, never by row position. See that section's doc
//! comment for the contract shape and how it relates to dired's own
//! (differently-shaped, but same-MECHANISM) `on_save`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const GraphDoc = @import("graph.zig");
const Document = @import("Document.zig");
const Buffers = @import("Buffers.zig");
const subbuffer = @import("subbuffer.zig");
const command = @import("command.zig");
const Actions = @import("action.zig");
const textdiff = @import("textdiff.zig");

const TranscriptDoc = @This();

graph: GraphDoc = .{},

const entries_key = "entries";

/// Origin constructor: a fresh transcript, with its root `entries`
/// sequence created locally. Exactly ONE replica in a transcript's
/// lifetime should call `create` — mirrors `Document`'s peer model, where
/// the owning replica is `init`ed and every other participant is cloned
/// FROM it (`Document.addPeer`'s doc comment), never independently
/// `init`ed. Two independent `create` calls would each mint their own
/// competing "entries" list under the same root key: ObjectDoc's map
/// conflict resolution picks a deterministic winner (see `ObjectDoc.
/// ValueRef.mapGet`), but the LOSER's entries silently drop out of the
/// winning replica's view — a real footgun `create` cannot detect (a
/// virgin doc has no way to know whether it's "the first"), so this is a
/// documented discipline, not a structurally enforced one. Every joining
/// participant calls `open`.
pub fn create(gpa: Allocator, agent_name: []const u8) Allocator.Error!TranscriptDoc {
    var g = try GraphDoc.init(gpa, agent_name);
    errdefer g.deinit(gpa);
    _ = try g.set(gpa, null, entries_key, .list);
    return .{ .graph = g };
}

/// Joining constructor: bootstrap from another replica's full history
/// (`bytes` from `GraphDoc.serialize`/`eventsSince`), then register the
/// local agent identity. `entries` arrives with the merged bytes — never
/// created locally, so no competing-root-list race is possible here.
pub fn open(gpa: Allocator, agent_name: []const u8, bytes: []const u8) GraphDoc.MergeError!TranscriptDoc {
    var g = try GraphDoc.open(gpa, agent_name, bytes);
    errdefer g.deinit(gpa);
    return adopt(g);
}

/// Validate an already-populated `GraphDoc` as a transcript — the same
/// invariant `open` checks, factored out so a `GraphDoc` bootstrapped
/// through a DIFFERENT path than an explicit `serialize`/`open` byte
/// handshake (stemma delta 5's session driver: `GraphCollab`'s frontier
/// exchange fills a virgin `GraphDoc.init(gpa, name)` shell over the wire —
/// see `GraphCollab.zig`'s module doc comment — with no single "bytes"
/// value this call ever holds directly) can validate it once content has
/// actually landed. `GraphCollab` itself never calls this: it
/// only ever speaks `GraphDoc`'s generic token model, deliberately with no
/// knowledge of `entries` — the caller adopts once its own convergence
/// predicate (or the entries key's mere presence) says it's time.
///
/// **Pointer-stability footgun (a real one — a W6 remote observer hits this
/// on the very first wire-bootstrap path):** this takes `GraphDoc` BY VALUE
/// and returns a fresh `TranscriptDoc` by value. If a caller has already
/// bound a `GraphCollab` to `&some_graph_doc` (the ordinary shape —
/// `Conn.openGraphOffer`/`shareGraph` take a stable `*GraphDoc`) and then
/// calls `adopt(some_graph_doc)` into a DIFFERENT variable, the result is a
/// COPY at a new address — the `GraphCollab` keeps writing into the OLD
/// variable, which the caller has stopped reading, so the replica silently
/// stops updating from the caller's point of view. The fix is to build the
/// holder as a `TranscriptDoc` from the start (`var tr: TranscriptDoc =
/// .{ .graph = try GraphDoc.init(gpa, name) }`), bind `GraphCollab` to
/// `&tr.graph`, and assign `adopt`'s result back into the SAME variable
/// (`tr = try adopt(tr.graph);` — never `var tr2 = try adopt(...)`): the
/// bound address (`&tr.graph`) never moves, only the value stored there
/// changes. See `session/tests.zig`'s "GraphDoc over the wire" and "W6
/// check-in" tests for this pattern applied end to end.
pub fn adopt(g: GraphDoc) error{Corrupt}!TranscriptDoc {
    if (g.root().mapGet(entries_key) == null) return error.Corrupt;
    // The documented split-brain footgun (two independent create()s merged
    // = two concurrent entries lists, one silently shadowed) made
    // DETECTABLE: a conflicted root key here means someone violated the
    // one-create rule — refuse rather than show half the transcript.
    if (g.root().mapConflictCount(entries_key) > 1) return error.Corrupt;
    return .{ .graph = g };
}

pub fn deinit(self: *TranscriptDoc, gpa: Allocator) void {
    self.graph.deinit(gpa);
}

fn entriesRef(self: *const TranscriptDoc) GraphDoc.ValueRef {
    return self.graph.root().mapGet(entries_key).?;
}

/// Number of entries.
pub fn count(self: *const TranscriptDoc) usize {
    return self.entriesRef().listLen();
}

/// A read handle onto one entry (`role`/`ts`/`text`/`node` — its own
/// `ObjId`, the identity `graph.zig`'s `NodeRef` wraps for anything that
/// needs to name this entry outside the local replica).
pub const Entry = struct {
    ref: GraphDoc.ValueRef,

    pub fn node(self: Entry) GraphDoc.ObjId {
        return self.ref.objId().?;
    }
    pub fn role(self: Entry) []const u8 {
        return self.ref.mapGet("role").?.asStr();
    }
    pub fn timestamp(self: Entry) i64 {
        return self.ref.mapGet("ts").?.asInt();
    }
    /// The entry body's text object id — pass to `TranscriptDoc.editText`.
    pub fn textObj(self: Entry) GraphDoc.ObjId {
        return self.ref.mapGet("text").?.objId().?;
    }
    /// The entry body's current content. Caller owns.
    pub fn text(self: Entry, gpa: Allocator) Allocator.Error![]u8 {
        return self.ref.mapGet("text").?.textRope().toOwnedSlice(gpa);
    }
};

/// The `i`-th entry, in append order (append order IS transcript order —
/// see the module doc comment on why that's a `seq`, not structure).
pub fn at(self: *const TranscriptDoc, index: usize) Entry {
    return .{ .ref = self.entriesRef().listAt(index) };
}

/// Append a new entry: `role` (e.g. "user"/"agent"/"tool"), a caller-
/// supplied timestamp, and its initial body text. Returns the entry's
/// `ObjId` (mint a `NodeRef` from it via `self.graph.nodeRef` to name it
/// portably — e.g. for a subbuffer identity fact; see `fill` below).
pub fn append(self: *TranscriptDoc, gpa: Allocator, role: []const u8, ts: i64, initial_text: []const u8) Allocator.Error!GraphDoc.ObjId {
    const entries = self.entriesRef().objId().?;
    const entry = (try self.graph.seqAppend(gpa, entries, .map)).?;
    _ = try self.graph.set(gpa, entry, "role", .{ .str = role });
    _ = try self.graph.set(gpa, entry, "ts", .{ .int = ts });
    const text_obj = (try self.graph.set(gpa, entry, "text", .text)).?;
    if (initial_text.len > 0) _ = try self.graph.textInsert(gpa, text_obj, 0, initial_text);
    return entry;
}

/// Edit an entry's body in place — a real CRDT text edit on the entry's
/// `text` object (`Entry.textObj`), collaboratively mergeable exactly
/// like a `Document`'s text.
pub fn editText(self: *TranscriptDoc, gpa: Allocator, text_obj: GraphDoc.ObjId, byte_offset: usize, content: []const u8) Allocator.Error!void {
    _ = try self.graph.textInsert(gpa, text_obj, byte_offset, content);
}

pub fn deleteText(self: *TranscriptDoc, gpa: Allocator, text_obj: GraphDoc.ObjId, range: stemma.Range) Allocator.Error!void {
    _ = try self.graph.textDelete(gpa, text_obj, range);
}

// ── The projection skeleton (§2.6) ────────────────────────────────────
//
// `graph.zig`'s module doc comment explains why this is a concrete `fill`
// rather than the generic `Projection`/`ReconcileMode` union §2.6
// sketches. What follows is that one concrete instance.

/// The `renderInto`/subbuffer peer identity `fill` authors content as and
/// claims id-spans under.
pub const projection_author = "agent-transcript";
/// Subbuffer fact name carrying an entry's `NodeRef` export token — the
/// graph↔text identity bridge §2.6 names ("subbuffer id-spans are the
/// existing text-side identity bridge; use them"). The fact's VALUE is
/// the raw token bytes (`GraphDoc.NodeRef.token`), not further encoded —
/// `SubBuffer.facts` stores arbitrary bytes, not just printable text.
pub const node_fact = "node";

/// Render `tr` into `doc`: one row per entry, `"role: text"` (an entry
/// whose body contains newlines renders as-is — its claimed span covers
/// the whole entry, not just its first physical line). Reclaims (drops
/// ALL of `doc`'s existing claims, then re-claims) one subbuffer id-span
/// per row on EVERY call — a full re-fill, not an incremental patch —
/// carrying fact `node_fact` = the entry's portable `NodeRef` token.
/// `subs.at(doc, some_offset)` then answers "which graph node produced
/// the byte under the caret" without any position-based guessing (exactly
/// the id-span mechanism `subbuffer.zig`/doc/contextual-workspace-architecture.md §11.8
/// already use for dired's rows).
///
/// The claimed span covers the BODY ONLY — `"role: "` is decoration, not
/// identity (the dired reframe's "name-is-content, metadata-is-decoration"
/// generalizes here: `role` is an immutable field of the entry, never
/// user-editable through this projection, so it must never be inside a
/// span `reconcileOnSave` would treat as editable text). This is what
/// makes the structural-edit gate below a byte-exact check instead of a
/// guess: everything OUTSIDE a claim is decoration chrome with an exact
/// expected value (`role`, `": "`, and the `"\n"` between rows), so any
/// buffer byte that doesn't match it is unambiguously a structural edit,
/// never a body edit misread as one.
///
/// `doc` is assumed to be a buffer's `Editor.doc` where the OWNING
/// `Buffers.Buffer.read_only` is left `false` — an `on_save` projection
/// (below) is, precisely because it isn't, an EDITABLE buffer; `fill`
/// itself doesn't care either way, since it authors through
/// `command.renderInto`, which (like `Context.render`) bypasses
/// read-only by design: read-only blocks `edit` (interactive typing),
/// never `render`/`renderInto` (model-driven production).
pub fn fill(gpa: Allocator, tr: *const TranscriptDoc, doc: *Document, subs: *subbuffer.SubBuffers) command.RenderError!void {
    const Span = struct { start: usize, end: usize, node: GraphDoc.ObjId };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);

    const n = tr.count();
    for (0..n) |i| {
        const e = tr.at(i);
        const body = try e.text(gpa);
        defer gpa.free(body);
        try text.print(gpa, "{s}: ", .{e.role()});
        const start = text.items.len;
        try text.appendSlice(gpa, body);
        try spans.append(gpa, .{ .start = start, .end = text.items.len, .node = e.node() });
        if (i + 1 < n) try text.append(gpa, '\n');
    }

    const old_len = doc.text().byteLen();
    try command.renderInto(gpa, doc, .plugin, projection_author, &.{
        .{ .range = .{ .start = 0, .end = old_len }, .bytes = text.items },
    });

    subs.dropDoc(gpa, doc);
    for (spans.items) |sp| {
        const sub = try subs.claim(gpa, doc, .{ .start = sp.start, .end = sp.end });
        const ref = try tr.graph.nodeRef(gpa, sp.node);
        defer ref.free(gpa);
        try sub.putFact(gpa, node_fact, ref.token);
    }
}

/// The subbuffer claim `fill` minted for its LAST row (the model's most
/// recently appended entry) — the one a live-streaming producer needs to
/// grow INCREMENTALLY (see `quickjs.zig`'s `cTranscriptAppend`, the
/// per-chunk path this exists for) without paying `fill`'s full
/// re-projection cost on every chunk. Correct only IMMEDIATELY after a
/// `fill` call and only while nothing else has claimed on `doc` in between:
/// `fill` drops every claim on `doc` then mints one per row IN APPEND ORDER
/// via `subs.claim` (a plain list append), so right after it returns, the
/// LAST claim anywhere in `subs.list` that still belongs to `doc` is
/// exactly the last row's — this walks backward from the end of `subs.
/// list` for the first match, which is O(1) in the common case (nothing
/// else has claimed on `doc` since) and never wrong (it doesn't ASSUME
/// that, it VERIFIES `s.doc == doc` at each step). `null` for an empty
/// transcript (nothing to return) or if `doc` never had anything claimed
/// on it at all.
pub fn lastRowClaim(subs: *const subbuffer.SubBuffers, doc: *const Document) ?*subbuffer.SubBuffer {
    var i = subs.list.items.len;
    while (i > 0) {
        i -= 1;
        const s = subs.list.items[i];
        if (s.doc == doc) return s;
    }
    return null;
}

/// The model→buffer PUSH trigger for a REMOTE change (W6 check-in,
/// doc/substrate.md, "the model replicates over a session"
/// gate). `fill` above is deliberately PULL — it recomputes from the model
/// whenever called, on no particular schedule. A LOCAL producer already
/// knows it just changed something, so it needs no help from this
/// function to notice — but it does NOT necessarily call this full `fill`
/// at its own call site: `quickjs.zig`'s `cTranscriptEntry` (a new row —
/// structure changed, so a full re-projection is the honest floor) does;
/// `cTranscriptAppend` (a streamed chunk onto the row already open) does
/// NOT — it grows the projected buffer and `lastRowClaim`'s claim
/// INCREMENTALLY instead (a point-insert + one claim's `extendEnd`, not a
/// full `fill`), see that handler's doc comment for the mechanism and
/// exactly when it falls back to a full `fill`. A REMOTE merge is
/// different: nothing local calls `fill` for you when a
/// `GraphCollab`-fed batch lands, so SOME caller has to notice and re-run
/// it. The "notice" this function asks for is `changed`: whatever the
/// caller's own collab tick already tells it (`GraphCollab.tick`'s or
/// `Conn.tick`'s return value) — the EXACT signal an ordinary shared TEXT
/// buffer's redraw already rides (`app/collab.zig`'s `tickCollab`: `dirty
/// = try c.tick()`). The only real difference is what "dirty" must DO: a
/// TextDoc buffer's rope IS the replicated content, so "dirty" only means
/// "redraw, the bytes are already right"; a `GraphDoc` has no directly
/// renderable text of its own, so a changed transcript must be
/// RE-PROJECTED (`fill`), not merely repainted. No timer, no polling, no
/// second admission path invented here — `changed` is already
/// frame-driven, this just answers the one extra question a graph-backed
/// projection needs answered before a redraw would show anything true.
pub fn refillOnChange(gpa: Allocator, tr: *const TranscriptDoc, doc: *Document, subs: *subbuffer.SubBuffers, changed: bool) command.RenderError!void {
    if (changed) try fill(gpa, tr, doc, subs);
}

// ── `on_save` reconciliation (§2.6's `ReconcileMode.on_save`, formalized) ──
//
// `graph.zig`'s module doc comment named `Projection`/`ReconcileMode` as
// sketched, not built: a generic union guessed from one case is exactly
// the premature abstraction this plan refuses. What's built here is the
// concrete `on_save` INSTANCE for transcript, now that a second real
// on_save-shaped mechanism exists to check the shape against — dired's
// (doc/contextual-workspace-architecture.md §11.8, wired through the `save` ACTION scoped
// to tool identity, `action.zig`'s `When{.tool=...}`). Transcript reuses
// that SAME mechanism (a tool-scoped `save` provider — see `install`
// below), not a parallel one: the two diverge only in what "reconcile"
// MEANS for their model (dired infers rename/move/delete/create file ops
// from a path snapshot; a transcript has no paths, no snapshot to keep —
// every row's CURRENT model text is its own always-live "snapshot", read
// fresh at save time). That divergence is real domain logic, not
// duplicated mechanism — see `reconcileOnSave` below for where it lives,
// and `textdiff.zig` for the ONE piece that WAS shared out from under a
// second implementation (`backing.zig`'s external-file-merge needed the
// identical "old vs new → one window" diff).
//
// Correcting an earlier note (the pre-slice-3 version of this file's `fill`
// doc comment argued `on_save` was "wrong for a transcript" because the
// graph doc has no EXTERNAL authority to reconcile against, unlike dired's
// filesystem). That conflated two different things: `on_save` reconciles
// a PROJECTED BUFFER's accumulated edits against ITS MODEL at a save
// point — the model doesn't need to be external to the whole system, only
// external to the buffer, which is always just a rendered copy, never
// the source of truth. The graph doc "being the truth, live, always" is
// not in tension with `on_save` at all; it's the reason `on_save` works
// here without inventing anything dired's design didn't already need.

/// A parsed, still-anchored row of the SAVED buffer: `range` is the
/// claim's CURRENT (rebased) byte span, `obj` is the LOCAL `ObjId` the
/// claim's `NodeRef` token resolved to. Sorted by `range.start` (buffer
/// position) purely to walk the buffer's decoration chrome left to right —
/// identity, never position, decides which MODEL entry a row reconciles
/// into.
const RowClaim = struct { range: stemma.Range, obj: GraphDoc.ObjId };

fn rowClaimLess(_: void, a: RowClaim, b: RowClaim) bool {
    return a.range.start < b.range.start;
}

/// Is `obj` one of `tr`'s CURRENTLY LIVE entries (reachable from `entries`
/// right now)? An `ObjId` never stops existing in the CRDT sense — its
/// creating event is permanent history — so a deleted entry's fields stay
/// individually readable (`ref(obj).mapGet(...)` does not fail); only
/// reachability from the live sequence withers. This is therefore a real
/// scan, not a `resolve` failure check: `reconcileOnSave` uses it to tell
/// "the entry this row named is gone" apart from "this row's identity is
/// simply unverifiable," which need different responses (see there).
fn isLiveEntry(tr: *const TranscriptDoc, obj: GraphDoc.ObjId) bool {
    const n = tr.count();
    for (0..n) |i| {
        if (std.meta.eql(tr.at(i).node(), obj)) return true;
    }
    return false;
}

pub const ReconcileError = error{
    /// A buffer byte belongs to no row's claimed identity, OR a claim's
    /// `NodeRef` token doesn't resolve at all (foreign/corrupt — this
    /// replica cannot even read what row it WOULD be, so it cannot verify
    /// the byte layout around it either). Covers: text typed outside any
    /// row's span, the `"role: "` decoration itself edited, and a whole
    /// row deleted from the buffer (its neighbors' expected decoration
    /// no longer lines up once the deleted row's bytes are gone). Refused
    /// for the WHOLE save — unlike `SaveReport.stale` below, a
    /// mis-shapen buffer can't be safely decomposed row by row, because
    /// the byte ranges everything else is checked against are exactly
    /// what's in question.
    UnclaimedText,
} || Allocator.Error;

pub const SaveReport = struct {
    /// Rows whose body diff was computed against their entry's CURRENT
    /// text and applied as a `textDelete`+`textInsert` (or left untouched
    /// when identical — still "applied": reconciled cleanly).
    applied: usize = 0,
    /// Rows whose claim named an entry no longer live (deleted from the
    /// model — by this replica or a merged peer — between `fill` and
    /// `save`). Refused INDIVIDUALLY: that row's edit (if it had one) is
    /// discarded and counted here, never guessed at and never allowed to
    /// block every OTHER row's legitimate edit from landing. A caller
    /// that wants to surface this to the user (dired's pending-changes
    /// confirm popup is the general affordance
    /// `doc/contextual-workspace-architecture.md` §11.8 names — not
    /// built for transcript this slice, see `install`'s doc comment)
    /// reads this count; it is never silently dropped.
    stale: usize = 0,
};

/// `on_save`: reconcile `doc`'s current text back into `tr` BY NODE
/// IDENTITY — the reconcile unit is a row (a subbuffer claim carrying
/// `node_fact`), never a line number or byte offset. `subs` reflects
/// EXACTLY what the last `fill` claimed (claims are added only by `fill`
/// and never auto-removed by editing — a row's claim persists, possibly
/// collapsed to near-zero width, even if its body text is emptied), so
/// this is a true reconciliation of "what fill rendered" against "what
/// the model says now" and "what the buffer says now", never a fresh
/// guess at either.
///
/// Two things are verified BEFORE any graph op is applied:
///  1. every buffer byte outside a claim matches EXACTLY the decoration
///     `fill` would write for its neighbors (`"role: "` before a row,
///     `"\n"` between rows, nothing before the first or after the last) —
///     any mismatch is a structural edit and refuses the WHOLE save
///     (`error.UnclaimedText`; see the error's doc comment for why this
///     one can't be partial);
///  2. per row, whether its claim's `NodeRef` still names a LIVE entry —
///     a row that doesn't is refused ALONE (`SaveReport.stale`), so a
///     concurrent deletion elsewhere in the transcript can never misdirect
///     ITS edit onto a different (reused-looking) entry, and can never
///     block every other row's edit either.
/// Only THEN does a live row's body diff (`textdiff.diffWindow` of the
/// entry's current model text vs. the claim's current buffer text) become
/// a minimal `textDelete`+`textInsert` on that entry's OWN text object —
/// never a wholesale replace, so identity anchors inside an unmodified
/// prefix/suffix of the body survive.
///
/// LIMITATION (interior edits only): claims bias inward (start `.right`,
/// end `.left`), so an edit at a body's EXACT start or end — including
/// appending to the end of a message — lands outside the claim and
/// refuses the whole save as a structural edit. Loud, never a silent
/// drop, but it means this reconcile handles only edits strictly interior
/// to an existing body. The limit dissolves when the transcript moves to
/// `live (text)` (doc/substrate.md §3's seam note) and per-edit
/// translation replaces save-time diffing; until then any real save UI
/// wired to this must surface the refusal, not swallow it.
pub fn reconcileOnSave(gpa: Allocator, tr: *TranscriptDoc, doc: *Document, subs: *const subbuffer.SubBuffers) ReconcileError!SaveReport {
    const rope = doc.text();

    var rows: std.ArrayList(RowClaim) = .empty;
    defer rows.deinit(gpa);
    for (subs.list.items) |s| {
        if (s.doc != doc) continue;
        const token = s.fact(node_fact) orelse continue;
        const obj = tr.graph.resolve(.{ .token = token }) catch return error.UnclaimedText;
        try rows.append(gpa, .{ .range = s.resolve(), .obj = obj });
    }
    std.mem.sort(RowClaim, rows.items, {}, rowClaimLess);

    const Op = struct { text_obj: GraphDoc.ObjId, old: []u8, new: []u8 };
    var ops: std.ArrayList(Op) = .empty;
    defer {
        for (ops.items) |op| {
            gpa.free(op.old);
            gpa.free(op.new);
        }
        ops.deinit(gpa);
    }
    var report: SaveReport = .{};

    var cursor: usize = 0;
    for (rows.items, 0..) |row, i| {
        const ref = tr.graph.ref(row.obj);
        const role_val = ref.mapGet("role") orelse return error.UnclaimedText;
        if (role_val.kind() != .str) return error.UnclaimedText;
        const role = role_val.asStr();

        const sep: []const u8 = if (i == 0) "" else "\n";
        const prefix_len = sep.len + role.len + 2; // + ": "
        if (row.range.start < cursor or row.range.start - cursor != prefix_len) return error.UnclaimedText;
        const got = try gpa.alloc(u8, prefix_len);
        defer gpa.free(got);
        rope.copyRange(got, .{ .start = cursor, .end = row.range.start });
        if (!std.mem.eql(u8, got[0..sep.len], sep) or
            !std.mem.eql(u8, got[sep.len..][0..role.len], role) or
            !std.mem.eql(u8, got[sep.len + role.len ..], ": "))
        {
            return error.UnclaimedText;
        }
        cursor = row.range.end;

        if (!isLiveEntry(tr, row.obj)) {
            report.stale += 1;
            continue;
        }
        const text_val = ref.mapGet("text") orelse return error.UnclaimedText;
        const text_obj = text_val.objId() orelse return error.UnclaimedText;
        const new_body = try gpa.alloc(u8, row.range.end - row.range.start);
        errdefer gpa.free(new_body);
        rope.copyRange(new_body, row.range);
        const old_body = try text_val.textRope().toOwnedSlice(gpa);
        errdefer gpa.free(old_body);
        try ops.append(gpa, .{ .text_obj = text_obj, .old = old_body, .new = new_body });
        report.applied += 1;
    }
    if (cursor != rope.byteLen()) return error.UnclaimedText;

    for (ops.items) |op| {
        const w = textdiff.diffWindow(op.old, op.new) orelse continue;
        if (w.old_end > w.start) try tr.deleteText(gpa, op.text_obj, .{ .start = w.start, .end = w.old_end });
        if (w.new_end > w.start) try tr.editText(gpa, op.text_obj, w.start, op.new[w.start..w.new_end]);
    }
    return report;
}

/// One transcript buffer's save binding — the opaque closure `install`
/// hangs `transcript-save` off (`command.Command.data`, "the command's
/// closure payload", the exact mechanism `registerAction`'s own trampoline
/// uses). Named deferral: this binds the `save` action to exactly ONE
/// live `TranscriptDoc`/`SubBuffers` pair, matching dired's own single-
/// active-instance assumption (its gather state is a guest module
/// global) — multiplexing several simultaneously-open transcript buffers
/// through one `save` dispatch needs a per-BUFFER model registry
/// (`command.Context` carries no such slot; `Buffers.Buffer.frontend` is
/// documented as shell-owned, not core's to repurpose) that is real,
/// un-built infrastructure, not a gap papered over here. Calling
/// `install` twice REBINDS the command to the new pair (`registry.bind`
/// overwrites) — single-instance is a precondition, not enforced; a
/// mis-paired binding degrades to a loud reconcile refusal (foreign
/// tokens fail `resolve`), never silent mis-application.
pub const SaveBinding = struct {
    tr: *TranscriptDoc,
    subs: *subbuffer.SubBuffers,
};

fn cTranscriptSave(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const bind: *SaveBinding = @ptrCast(@alignCast(data.?));
    const gpa = ctx.gpa;
    const ed = ctx.textEditor() catch return .nil;
    const report = reconcileOnSave(gpa, bind.tr, &ed.doc, bind.subs) catch |err| {
        // Loud, never silent — the general pending-changes CONFIRM popup
        // doc/contextual-workspace-architecture.md §11.8 step 4 envisions is dired's UI
        // surface to build, not duplicated here; the honest floor for
        // this slice is an echoed refusal reason on the one channel every
        // command already reports through.
        ctx.head.echo.clearRetainingCapacity();
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "transcript-save: refused ({t})", .{err}) catch "transcript-save: refused";
        ctx.head.echo.appendSlice(gpa, msg) catch {};
        return .{ .boolean = false };
    };
    // Re-fill: the buffer now shows the model's own canonical text for
    // every row (normalizes anything `diffWindow`'s single-window
    // coarseness left imprecise, and drops the `stale` rows' now-inert
    // claims) — the same "re-gather after apply" discipline dired's
    // `on_save_apply` follows.
    try fill(gpa, bind.tr, &(try ctx.textEditor()).doc, bind.subs);
    if (report.stale > 0) {
        ctx.head.echo.clearRetainingCapacity();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "transcript-save: {d} row(s) were stale, discarded", .{report.stale}) catch "transcript-save: some rows were stale";
        ctx.head.echo.appendSlice(gpa, msg) catch {};
    }
    return .{ .boolean = true };
}

/// Wire `save` (`C-s`/`:w`/palette — every route, per `action.zig`'s
/// module doc) to `reconcileOnSave` for `bind`'s buffer: the SAME
/// mechanism dired's `save` provider uses (`actions.provide` scoped to
/// `When{.tool=projection_author}`, winning by priority over the core
/// default file-save provider), extended here to its first HOST-NATIVE
/// provider — until now only wasm guests registered a tool-scoped `save`.
pub fn install(gpa: Allocator, commands: *command.Commands, actions: *Actions, bind: *SaveBinding) !void {
    _ = try commands.bind(gpa, "transcript-save", .{
        .name = "transcript-save",
        .summary = "Reconcile an edited transcript projection's rows back into the graph doc by NodeRef identity.",
        .args = &.{},
        .handler = cTranscriptSave,
        .data = bind,
    });
    try actions.provide(.{
        .action = "save",
        .when = .{ .tool = projection_author },
        .command = "transcript-save",
        .priority = 10,
        .owner = "transcript",
    });
}

/// Create a tool-backed buffer suitable for `fill`/`on_save` — the
/// tool-buffer machinery `dired`/`magit` use (`Buffers.Buffer.setTool`),
/// wired up host-side instead of from a wasm guest's `on_fill` (per
/// `graph.zig`'s "where the graph-side plugin code runs": this client's
/// model AND its projection are host/in-process). NOT read-only: an
/// `on_save` projection is, structurally, an editable buffer — `edit`
/// (interactive typing) is exactly what accumulates the rows
/// `reconcileOnSave` later reconciles.
pub fn openBuffer(gpa: Allocator, buffers: *Buffers, display_name: []const u8) Buffers.Error!Buffers.Id {
    const id = try buffers.create(gpa, display_name);
    const buf = buffers.get(id).?;
    try buf.setTool(gpa, projection_author);
    return id;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "TranscriptDoc: append/read/edit" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);

    _ = try tr.append(gpa, "user", 100, "hello");
    const agent_node = try tr.append(gpa, "agent", 101, "hi there");
    try t.expectEqual(@as(usize, 2), tr.count());

    const e0 = tr.at(0);
    try t.expectEqualStrings("user", e0.role());
    try t.expectEqual(@as(i64, 100), e0.timestamp());
    const b0 = try e0.text(gpa);
    defer gpa.free(b0);
    try t.expectEqualStrings("hello", b0);

    const e1 = tr.at(1);
    try t.expectEqual(agent_node, e1.node());

    // Edit entry 1's body in place.
    try tr.editText(gpa, e1.textObj(), 2, "XX");
    const b1 = try tr.at(1).text(gpa);
    defer gpa.free(b1);
    try t.expectEqualStrings("hiXX there", b1);
}

test "TranscriptDoc: two replicas converge; joiner never races the origin's entries list" {
    const gpa = t.allocator;
    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "one");

    const bytes = try origin.graph.serialize(gpa);
    defer gpa.free(bytes);
    var joiner = try TranscriptDoc.open(gpa, "bob", bytes);
    defer joiner.deinit(gpa);
    try t.expectEqual(@as(usize, 1), joiner.count());

    _ = try joiner.append(gpa, "agent", 2, "two");

    const origin_v = try origin.graph.version(gpa);
    defer gpa.free(origin_v);
    const batch = try joiner.graph.eventsSince(gpa, origin_v);
    defer gpa.free(batch);
    const changes = try origin.graph.merge(gpa, batch);
    defer gpa.free(changes);

    try t.expectEqual(@as(usize, 2), origin.count());
    try t.expectEqualStrings("agent", origin.at(1).role());
    const txt = try origin.at(1).text(gpa);
    defer gpa.free(txt);
    try t.expectEqualStrings("two", txt);
    // Frontier equality, matching graph.zig's convergence rigor — content
    // agreement alone can mask an unconverged frontier.
    const ov = try origin.graph.version(gpa);
    defer gpa.free(ov);
    const jv = try joiner.graph.version(gpa);
    defer gpa.free(jv);
    try t.expectEqual(GraphDoc.VersionOrder.equal, try origin.graph.compareVersions(gpa, ov, jv));
}

test "Projection.fill: entries render to text; each row's subbuffer carries the right NodeRef" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    const n0 = try tr.append(gpa, "user", 1, "hi");
    const n1 = try tr.append(gpa, "agent", 2, "yo");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    try fill(gpa, &tr, &doc, &subs);

    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    const ref0 = try tr.graph.nodeRef(gpa, n0);
    defer ref0.free(gpa);
    const ref1 = try tr.graph.nodeRef(gpa, n1);
    defer ref1.free(gpa);

    // Offsets land INSIDE each row's body — after "role: ", never on the
    // decoration prefix (see `fill`'s doc comment: the prefix is chrome,
    // not identity, so it carries no claim to land on).
    const sub0 = subs.at(&doc, "user: ".len).?;
    try t.expectEqualStrings(ref0.token, sub0.fact(node_fact).?);
    const sub1 = subs.at(&doc, "user: hi\nagent: ".len).?;
    try t.expectEqualStrings(ref1.token, sub1.fact(node_fact).?);
}

test "Projection.fill: a second append re-fills without losing the mapping" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    const n0 = try tr.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    try fill(gpa, &tr, &doc, &subs);
    const n1 = try tr.append(gpa, "agent", 2, "yo");
    try fill(gpa, &tr, &doc, &subs);

    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    // Exactly two live claims (the old ones were dropped, not leaked
    // alongside fresh duplicates).
    try t.expectEqual(@as(usize, 2), subs.list.items.len);

    const ref0 = try tr.graph.nodeRef(gpa, n0);
    defer ref0.free(gpa);
    const ref1 = try tr.graph.nodeRef(gpa, n1);
    defer ref1.free(gpa);
    try t.expectEqualStrings(ref0.token, subs.at(&doc, "user: ".len).?.fact(node_fact).?);
    try t.expectEqualStrings(ref1.token, subs.at(&doc, "user: hi\nagent: ".len).?.fact(node_fact).?);
}

test "refillOnChange: false is a true no-op (stale content untouched); true re-projects" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    _ = try tr.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &tr, &doc, &subs);

    // The model changes (as a remote merge would), but `changed=false` —
    // the "nothing to notice" case a quiet tick reports — must leave the
    // buffer exactly as stale as it already was: the whole point of a PUSH
    // trigger is that it never re-projects without being told to.
    _ = try tr.append(gpa, "agent", 2, "yo");
    try refillOnChange(gpa, &tr, &doc, &subs, false);
    {
        const got = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi", got);
    }

    // `changed=true` re-projects, picking up everything that accumulated
    // since the last `fill` — exactly what a collab tick's own bool would
    // report once the merge actually lands.
    try refillOnChange(gpa, &tr, &doc, &subs, true);
    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);
}

test "Projection.fill: merging a second replica's append updates the projection" {
    const gpa = t.allocator;
    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &origin, &doc, &subs);

    const bytes = try origin.graph.serialize(gpa);
    defer gpa.free(bytes);
    var joiner = try TranscriptDoc.open(gpa, "bob", bytes);
    defer joiner.deinit(gpa);
    const n1 = try joiner.append(gpa, "agent", 2, "yo");

    const origin_v = try origin.graph.version(gpa);
    defer gpa.free(origin_v);
    const batch = try joiner.graph.eventsSince(gpa, origin_v);
    defer gpa.free(batch);
    const changes = try origin.graph.merge(gpa, batch);
    defer gpa.free(changes);

    try fill(gpa, &origin, &doc, &subs);
    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    // `n1` is a `joiner`-LOCAL ObjId (agent numbering doesn't cross
    // replicas — the whole reason `NodeRef` exists); mint its portable
    // token from `joiner` and use THAT to check the fact `fill` wrote on
    // `origin`'s (post-merge) buffer.
    const joiner_ref1 = try joiner.graph.nodeRef(gpa, n1);
    defer joiner_ref1.free(gpa);
    try t.expectEqualStrings(joiner_ref1.token, subs.at(&doc, "user: hi\nagent: ".len).?.fact(node_fact).?);
}

test "reconcileOnSave: edit -> save -> model updated -> re-fill reflects it (round trip)" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    _ = try tr.append(gpa, "user", 1, "hi");
    _ = try tr.append(gpa, "agent", 2, "yo");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &tr, &doc, &subs);

    // Edit entry 1's body IN THE PROJECTED BUFFER, like a user typing:
    // insert STRICTLY INSIDE its claimed span (never at either edge —
    // the claim's anchors bias INWARD, `subbuffer.zig`'s documented
    // "text typed at either edge grows the surrounding buffer, not the
    // embedded island", so an edge insert is deliberately NOT this test's
    // concern; the structural-edit test below covers that case), never
    // touching the "agent: " chrome. "yo" -> "y!!o".
    const row1_mid = "user: hi\nagent: y".len;
    try doc.insert(gpa, row1_mid, "!!");

    const report = try reconcileOnSave(gpa, &tr, &doc, &subs);
    try t.expectEqual(@as(usize, 2), report.applied);
    try t.expectEqual(@as(usize, 0), report.stale);

    // The MODEL'S entry — a real text-CRDT body — holds the edit now.
    const b1 = try tr.at(1).text(gpa);
    defer gpa.free(b1);
    try t.expectEqualStrings("y!!o", b1);
    // The untouched row reconciled to a no-op.
    const b0 = try tr.at(0).text(gpa);
    defer gpa.free(b0);
    try t.expectEqualStrings("hi", b0);

    // Re-fill from the now-updated model reflects the save.
    try fill(gpa, &tr, &doc, &subs);
    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: y!!o", got);
}

test "reconcileOnSave: identity, not row position — a concurrent model deletion elsewhere never misdirects the edit" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    _ = try tr.append(gpa, "user", 1, "zero");
    const n1 = try tr.append(gpa, "agent", 2, "one");
    _ = try tr.append(gpa, "user", 3, "two");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &tr, &doc, &subs);
    try t.expectEqual(@as(usize, 3), tr.count());

    // Edit row 1's body ("one" -> "oXYZne") STRICTLY INSIDE its claimed
    // span, same edge-avoidance discipline as the round-trip test above.
    const row1_mid = "user: zero\nagent: o".len;
    try doc.insert(gpa, row1_mid, "XYZ");

    // Concurrently — a merged peer's delete, simulated directly against
    // `graph.zig`'s own vocabulary (deleting an entry is legitimately
    // outside `TranscriptDoc`'s own API, F3's append-only discipline; a
    // real peer would do this through its own `merge`, which lands the
    // identical `seqDelete` op): entry 0 is removed from `entries`,
    // shifting n1 from model index 1 down to index 0.
    const entries_obj = tr.graph.root().mapGet(entries_key).?.objId().?;
    try tr.graph.seqDelete(gpa, entries_obj, 0);
    try t.expectEqual(@as(usize, 2), tr.count());
    try t.expectEqual(n1, tr.at(0).node()); // confirms the index shift happened

    // Reconcile: n1's edit lands on n1 BY NODEREF — never on "whatever the
    // model now has at row 1's ORIGINAL index" (that would be n1 anyway
    // before the shift, but nothing dereferences an index at all here, so
    // the shift cannot matter). The untouched row naming the now-deleted
    // entry is refused ALONE; it does not block n1's or n2's reconcile.
    const report = try reconcileOnSave(gpa, &tr, &doc, &subs);
    try t.expectEqual(@as(usize, 1), report.stale);
    try t.expectEqual(@as(usize, 2), report.applied);

    const b_n1 = try tr.at(0).text(gpa); // n1, now at index 0
    defer gpa.free(b_n1);
    try t.expectEqualStrings("oXYZne", b_n1);
    const b_n2 = try tr.at(1).text(gpa); // n2, untouched
    defer gpa.free(b_n2);
    try t.expectEqualStrings("two", b_n2);
}

test "reconcileOnSave: a structural edit (typing a whole new row) refuses the WHOLE save, loudly" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    _ = try tr.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &tr, &doc, &subs);

    // A brand-new line with no claim over it at all — no NodeRef, so
    // there is nothing to reconcile it BY.
    try doc.insert(gpa, doc.text().byteLen(), "\nsystem: injected");

    try t.expectError(error.UnclaimedText, reconcileOnSave(gpa, &tr, &doc, &subs));
    // Refused means refused — the one real entry is untouched.
    try t.expectEqual(@as(usize, 1), tr.count());
    const b0 = try tr.at(0).text(gpa);
    defer gpa.free(b0);
    try t.expectEqualStrings("hi", b0);
}

test "install: `save` dispatches to transcript-save through the same tool-scoped action mechanism dired uses" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: @import("Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var head: @import("Head.zig") = .empty;
    defer head.deinit(gpa);
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = Actions.init(gpa, &container);
    defer actions.deinit();
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    // The trampoline `save` dispatches through — `builtins.install` binds
    // this in the real app; a focused unit test binds just the piece it
    // exercises.
    try command.registerAction(gpa, &commands, &actions, "save", .pick);

    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    _ = try tr.append(gpa, "user", 1, "hi");
    _ = try tr.append(gpa, "agent", 2, "yo");

    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    const buf_id = try openBuffer(gpa, &buffers, "*transcript*");
    buffers.active_id = buf_id;
    const doc = &buffers.get(buf_id).?.textEditor().?.doc;
    try fill(gpa, &tr, doc, &subs);

    var bind: SaveBinding = .{ .tr = &tr, .subs = &subs };
    try install(gpa, &commands, &actions, &bind);

    // Edit through the projected buffer, exactly like a user typing —
    // strictly inside the claimed span (see the round-trip test's note).
    const row1_mid = "user: hi\nagent: y".len;
    try doc.insert(gpa, row1_mid, "!");

    var quit = false;
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };
    _ = try command.run(&commands, &ctx, "save", &.{});

    const b1 = try tr.at(1).text(gpa);
    defer gpa.free(b1);
    try t.expectEqualStrings("y!o", b1);
}

test {
    std.testing.refAllDecls(@This());
}
