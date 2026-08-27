//! `GraphCollab` — the per-doc sync driver for ONE `GraphDoc` over one
//! channel quad of a `Session` (stemma delta 5, doc/substrate.md §2:
//! "ObjectDoc's version/eventsSince/merge already speak the same token
//! model [as TextDoc], so it is binding work, not protocol work").
//!
//! ## The seam this file IS the answer to
//!
//! `Collab.zig` (the TextDoc driver) is not a thin wrapper over
//! `{version, eventsSince, merge}` — most of its surface (`presence_layer`,
//! `export_diag_layer`/`import_diag_layer`, `blob_server`/`remote_file`,
//! `peer_fs_root`/`remote_fs`, `partial` checkout, the `.grant` per-doc
//! authority handshake) is real TextDoc-only machinery: presence/diagnostics
//! ride the buffer's `layers.Layer`s (a `Document`-shaped concept), blob/fs
//! serving answers stemma's lazy-hole realization (`PartialDoc`), and
//! `.grant` feeds `Document.my_grant`, which gates the buffer's INTERACTIVE
//! edit path — a path `GraphDoc` clients don't have yet (this slice's only
//! client, `transcript.zig`, projects `.read_only`; nothing calls
//! `GraphDoc.textInsert`/`seq*` from user keystrokes). Forcing all of that
//! onto a graph doc quad would be exactly the "guessed from one case"
//! premature abstraction `graph.zig`'s own doc comment refuses for
//! `Projection`.
//!
//! So this is NOT `Collab` generalized over a doc type. What IS shared —
//! frontier tracking, announce-once, push-on-move, the batch/frontier wire
//! framing, and the batch-decode-plus-admission-gate — is factored into
//! `sync_core.zig`'s `SyncCore(Doc)`, embedded here AND in `Collab` (a
//! first review of this slice found `GraphCollab` had reimplemented that
//! core byte-for-byte instead of sharing it — see `sync_core.zig`'s doc
//! comment for the extraction and exactly where the two drivers still
//! genuinely diverge). This file is what's left after that: the quad
//! wiring, the frame-class dispatch, and the `GraphDoc.merge` call itself
//! (which `sync_core.zig` deliberately does not own — see there). A future
//! second graph client that needs presence or a per-doc grant handshake is
//! the signal to lift that piece up, not a reason to have built it here
//! unused now.
//!
//! ## Quad layout (v1, minimal — now with one claimed feed channel)
//!
//! The `base` channel carries `OpKind.batch`/`.frontier`/`.region_refused`/
//! `.grant` (`.share` is consumed by `Conn`). `base + 1` (W6 slice 1,
//! doc/substrate.md §4) carries the per-region LEASE announce/release feed —
//! the same slot `Collab` claims for presence, left unclaimed here until
//! that slice; leases are presence-shaped data (§5.2: "a lease is a presence
//! span with a locked flag"), so reusing the slot instead of minting a new
//! one is deliberate. `base + 2` (diagnostics) and `base + 3`
//! (blob/`.peer`-fs) remain unclaimed; a graph quad still reserves the full
//! 4-wide slot (`Conn`'s `next_base` counter is shared with text shares, so
//! bases never collide either way). W6 slice 2 (identity-anchored SUBTREE
//! GRANTS, doc/substrate.md) claimed no new channel: grants are
//! HOST-declared and enforced entirely locally (`bindGrants`/`grantSubtree`
//! below). **D3 (doc/substrate.md §5) now ALSO announces**: `base`'s
//! `OpKind.grant` — precedented by `Collab`'s own per-doc grade announce
//! (`Collab.zig`'s `.grant` emit at `push`/consume in `handleFrame`, the
//! one-for-one template this mirrors) and previously unconsumed here —
//! carries this peer's live, reachable granted root `NodeRef` tokens on a
//! GRAPH quad (a bare `Access` byte on a TEXT quad, unchanged; disambiguated
//! by quad type, exactly like `region_refused` already is graph-only). This
//! is DISPLAY/PREVENTION state for the grantee (`granted_roots`,
//! `mayEditNode` below) — the host still enforces at `admitRegions`; the
//! announcement can never widen authority, only let a grantee refuse its own
//! out-of-grant edits LOCALLY instead of discovering the boundary by being
//! refused. `.region_refused`'s payload gains one trailing byte (a
//! `RefusalReason`) so a refused sender can tell a lease refusal from an
//! authority one from a collapsed-grant one — additive, same
//! version-tolerance convention as the lease frame's trailing `hue16`.
//!
//! ## Bootstrap = the frontier exchange itself
//!
//! No explicit serialize/open handshake is needed: a joiner binds a
//! virgin, structurally-empty `GraphDoc` (`graph.zig#GraphDoc.init` — NOT
//! `.open`, which decodes a `stemma.ObjectDoc`-encoded byte batch and
//! rejects a literal empty slice as corrupt; `init`'s empty `ObjectDoc` and
//! `open`'s "merge zero events" both start from the identical inert state,
//! so this is the same "genuinely starts empty" shell `graph.zig`'s module
//! doc comment carves out for an origin, just reused for a joiner that —
//! unlike `TranscriptDoc.create` — never mints any LOCAL structure on it
//! before the wire fills it in) and gets its full bootstrap for free from
//! the ordinary protocol below: both ends announce their frontier on first
//! `push`; on receiving the peer's frontier, `sendBatch` computes
//! `eventsSince(their_frontier)`, which for an empty joiner IS the
//! origin's entire history (`serialize`'s equivalent, computed as a delta
//! against nothing). A client-level invariant that can't be validated on
//! an empty doc (like `TranscriptDoc`'s "entries list exists" check) is
//! validated by the CLIENT once content has actually landed
//! (`TranscriptDoc.adopt`), not by this driver, which only ever speaks
//! `GraphDoc`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const GraphDoc = @import("../graph.zig");
const NodeRef = GraphDoc.NodeRef;

const Session = @import("Session.zig");
const sync_core = @import("sync_core.zig");
const region_lease = @import("region_lease.zig");
const LeaseTable = region_lease.LeaseTable;
const grants_mod = @import("../grants.zig");

const GraphCollab = @This();

gpa: Allocator,
session: *Session,
doc: *GraphDoc,
name: []u8,
/// First channel of this document's quad (multiple of 4).
base: u64 = 0,
/// Caller-owned bookkeeping (the editor stores its buffer id).
tag: u64 = 0,
/// Frontier tracking + batch/frontier wire framing — shared with `Collab`
/// (see `sync_core.zig`). No text-only concept (partial checkout, grant)
/// applies here, so every call site below passes `skip = false`.
core: sync_core.SyncCore(GraphDoc) = .{},

// ── W6 slice 1: the per-region lease (doc/substrate.md §4) ────
// Reuses `base + 1` — the presence slot `Collab` claims but this quad has
// left unclaimed until now (see the module doc comment's "Quad layout").
// `leases` is NOT owned here: it is one table per REPLICA's view of this
// doc (see `region_lease.zig`'s module doc comment on why it can't be a
// single cross-wire-shared instance), constructed and owned by whoever
// owns the `GraphDoc` and bound in with `bindLeases` — `null` (the
// default) means no lease enforcement, so every existing caller of this
// driver keeps today's canEdit-only admission unchanged.
leases: ?*LeaseTable = null,
/// This quad's remote peer's self-declared principal name, learned from
/// its lease announcements (there is no separate identity handshake for
/// this — same trust level as `Collab`'s presence names). `null` until the
/// peer has announced at least one lease.
peer_name: ?[]u8 = null,
/// A batch we refused at the per-region admission hook, echoed to us as
/// the LOUD refusal (never a silent drop — doc/substrate.md §4
/// test 5). Append-only; the caller drains/inspects and is responsible for
/// freeing each entry's owned fields (`Refusal.free`).
refusals: std.ArrayList(Refusal) = .empty,
/// Guards a single `leases.reap` call per dead session (reap is itself
/// idempotent, but this avoids repeated table walks every tick).
reaped: bool = false,
/// Set by `rebind`; cleared by the next `push` once it has re-announced
/// every region we still hold to the fresh session — presence parity
/// (`Collab.rebind` forces a presence republish by resetting
/// its cached published presence; §5.2 promises leases are "re-announced like
/// presence"). Without this, a peer who reaped our leases across the
/// disconnect (§5.2's own lifetime discipline) never re-learns we still
/// hold them, and their next fresh acquire would fold against nothing —
/// silently taking a region we never released.
needs_lease_reannounce: bool = false,

// ── W6 slice 2: identity-anchored SUBTREE GRANTS (doc/substrate.md §4's
// "the same [per-region admission] machinery W6 needs for identity-anchored
// subtree grants... used for mutual exclusion instead of authority") — the
// SECOND predicate `admitRegions`'s doc comment names, composing over the
// SAME `touchedRegions` call the lease predicate already uses, ANDed into
// the same admit/refuse control flow (see `admitRegions` below). `grants`
// is NOT owned here — same "one table per REPLICA, bound in, not built in"
// shape as `leases` — `null` (the default) means no grant enforcement, so
// every existing caller of this driver keeps today's canEdit-only admission
// unchanged. Reuses `grants.zig`'s `HandleTable` wholesale
// (`Row`/`CapHandle`/`revoke`/`Reason` machinery already built, tested, and
// System-agnostic — nothing about it requires the plugin/Ctx apparatus
// `System.grants` happens to also use it for) rather than growing a THIRD
// bespoke grant table alongside `HandleTable` and `LeaseTable` — see
// `grantSubtree`'s doc comment for the declaration API and
// `Limit.graph_subtree`'s doc comment (grants.zig) for the row shape and
// collapse policy.
grants: ?*grants_mod.HandleTable = null,
/// Stable storage for `self.session`'s peer's AUTHENTICATED identity
/// fingerprint (`Session.peerFingerprint()`), populated the first time
/// `grantSubtree` mints a row — a `grants.HandleTable.Row.principal` is a
/// BORROWED `[]const u8` that must outlive the row (see `grantSubtree`'s
/// doc comment), and `peerFingerprint()` itself returns a fresh VALUE each
/// call, not a pointer into anything stable, so this field is what a
/// minted row actually borrows from. Copied, not a pointer into
/// `self.session` itself, because a `rebind` across a reconnect swaps
/// `self.session` to a DIFFERENT `*Session` object for the SAME peer
/// (`rebind`'s own doc comment: "the peer's declared name is still valid —
/// same peer, new link") — borrowing straight from the live session would
/// dangle the instant the old session is destroyed. The identity itself
/// (the peer's persistent keypair, hence its fingerprint) does not change
/// across a reconnect, so a row minted before a rebind stays correctly
/// matchable after one without needing to be re-minted.
peer_fingerprint: ?[24]u8 = null,

// ── D3: PREVENTION — announce the subtree grant to its grantee
// (doc/substrate.md §5) ─────────────────────────────────────
// The HOST side of this pair (`needs_grant_reannounce`/`announceGrant`)
// posts this peer's live granted-root set over the graph quad's
// `OpKind.grant` frame — the SAME host→client authority-announce shape
// `Collab.zig`'s per-doc grade already uses (emit at `push`, consume in
// `handleFrame`, client-role-only, never a reverse vector). The GRANTEE
// side (`granted_roots`/`mayEditNode`) is what a grantee's edit path
// consults BEFORE minting a local op, so the stuck-authority-refusal class
// doc/substrate.md §5 names becomes UNREACHABLE for a grantee
// that consults it, rather than merely recoverable (§2.2, `needsRebootstrap`
// below) after the fact.

/// Set true whenever `grantSubtree`/`revokeSubtreeGrants` change THIS
/// peer's live `.graph_subtree` rows, and by `rebind` (the SAME
/// re-announce-on-reconnect discipline `needs_lease_reannounce` already
/// documents for leases — soft state a fresh session starts knowing
/// nothing about). Consumed by `push`, which re-announces the CURRENT full
/// live set (never a delta) and clears this. Only ever meaningfully set on
/// the HOST side — nothing else calls `grantSubtree`/`revokeSubtreeGrants` —
/// but harmless to check unconditionally in `push` (a grantee with no
/// grant table bound never sets it, so `announceGrant` never runs there
/// either way, since `gatherGrantRoots`'s `self.grants orelse return`
/// short-circuits to an empty set even if it somehow did).
needs_grant_reannounce: bool = false,
/// The CLIENT (grantee) side of the pair above: the last-announced set of
/// this replica's own live, reachable granted root `NodeRef` tokens, as
/// told to us by the HOST over the graph quad's `.grant` frame
/// (`handleFrame`'s `.grant` case, client-role-only — same reverse-vector
/// guard `Collab`'s `.grant` consume already enforces, since a host must
/// never let a peer dictate ITS OWN authority). **DISPLAY/PREVENTION STATE,
/// NEVER AUTHORITY**: the host's own `grants.HandleTable`, consulted at
/// `admitRegions`, is the only real enforcement — this field can only ever
/// make `mayEditNode` REFUSE a candidate edit early; it can never cause one
/// the host would refuse to be ADMITTED (D3 §6 test 4: a grantee that
/// ignores, misreads, or is fed a wider claim than the host's table
/// actually holds still can't get an out-of-grant op merged). Empty (the
/// default) = "no confinement announced" = today's unrestricted behavior,
/// mirroring the host-side "absence of a grant row keeps today's behavior"
/// rule. Owned tokens, replaced WHOLESALE on every inbound `.grant` frame
/// (the host always announces its current full live set, never a delta —
/// see `announceGrant`), freed in `deinit`.
granted_roots: []NodeRef = &.{},

/// This quad's publication (§13.2), the key `sync_core.admitBatch`'s
/// per-export check runs against. `id = 0` = unpublished: the connection
/// grade alone governs, exactly as before per-export grants — which is
/// every graph caller today, since a graph quad's sub-document authority
/// already rides `grants`/`admitRegions` rather than the coarse gate.
publication: grants_mod.PublicationRef = .{ .id = 0, .epoch = 0 },
/// Why the last inbound batch was refused at the COARSE gate (per-export
/// authority / dead epoch), as opposed to the per-region hook, whose
/// refusals are echoed to the sender in `refusals`.
last_refusal: ?grants_mod.Reason = null,

/// Whether the last announcement said this peer is CONFINED at all — the
/// distinction `granted_roots` alone cannot carry, since "never narrowed"
/// and "narrowed to nothing left" are both the empty set and mean opposite
/// things. True with an empty `granted_roots` is total local refusal: every
/// grant this peer held is revoked or collapsed.
granted_confined: bool = false,

/// The capability name every `grantSubtree` row is minted under — a graph
/// doc's own namespace, distinct from `.doc_region`'s `"doc.edit"` (a
/// different substrate, a different chokepoint — see `Limit.graph_subtree`'s
/// doc comment).
pub const graph_edit_capability = "graph.edit";

/// Why a batch was refused at `admitRegions` — the taxonomy a refused
/// SENDER needs to tell "someone else is using this region right now"
/// (`.lease`, occupancy, W6 slice 1) apart from "you were never given
/// authority over this region" (`.authority`, W6 slice 2) apart from "your
/// grant's root node no longer exists" (`.collapsed`, the trap-on-collapse
/// discipline, §2.4) — the no-silent-third-result rule applied to the
/// refusal channel itself: three DISTINCT reasons a batch didn't land, not
/// one bit of "refused" a sender has to guess the cause of. Numbered
/// explicitly (not just declaration order) because it rides the wire
/// (`sendRefusal`/`.region_refused`'s trailing byte, additive like the
/// lease frame's trailing `hue16` — see `handleFrame`): `.lease = 0` keeps
/// an OLDER peer's decode (pre-W6-slice-2, no trailing byte at all)
/// correct by construction, since lease refusal was the only reason that
/// existed before this slice.
pub const RefusalReason = enum(u8) {
    lease = 0,
    authority = 1,
    collapsed = 2,
};

pub const Refusal = struct {
    region: NodeRef,
    /// The lease holder's name for `.lease` refusals; empty (`""`) for
    /// `.authority`/`.collapsed` (there is no "other holder" to name —
    /// the sender itself simply lacks, or lost, authority).
    holder: []u8,
    reason: RefusalReason = .lease,

    pub fn free(self: Refusal, gpa: Allocator) void {
        gpa.free(self.region.token);
        gpa.free(self.holder);
    }
};

pub fn init(gpa: Allocator, session: *Session, doc: *GraphDoc, name: []const u8) !GraphCollab {
    return .{
        .gpa = gpa,
        .session = session,
        .doc = doc,
        .name = try gpa.dupe(u8, name),
    };
}

pub fn deinit(self: *GraphCollab) void {
    self.core.deinit(self.gpa);
    if (self.peer_name) |n| self.gpa.free(n);
    for (self.refusals.items) |r| r.free(self.gpa);
    self.refusals.deinit(self.gpa);
    for (self.granted_roots) |r| r.free(self.gpa);
    self.gpa.free(self.granted_roots);
    self.gpa.free(self.name);
}

/// Bind a per-replica lease table (W6 slice 1, see the field's doc
/// comment). Opt-in and additive: a `GraphCollab` with no table bound
/// behaves exactly as before this slice.
pub fn bindLeases(self: *GraphCollab, table: *LeaseTable) void {
    self.leases = table;
}

/// Bind a per-replica `grants.HandleTable` for subtree-grant enforcement
/// (W6 slice 2, see the field's doc comment). Opt-in and additive, exactly
/// like `bindLeases`: an unbound `GraphCollab` behaves exactly as before
/// this slice. Typically bound only on the ENFORCING (host) side — the
/// peer being granted authority needs no table at all (see `grantSubtree`'s
/// doc comment on provenance).
pub fn bindGrants(self: *GraphCollab, table: *grants_mod.HandleTable) void {
    self.grants = table;
}

/// The HOST-side subtree-grant declaration API (W6 slice 2,
/// doc/substrate.md §4's admission hook, second predicate): declare
/// that the peer AUTHENTICATED at the other end of THIS quad's
/// `session` may edit within `root`'s subtree on THIS doc.
///
/// **The identity-binding shape, DECIDED (post-review REQUIRED FIX 1) —
/// keyed on `session.peerFingerprint()`, never a self-declared name.** The
/// first shipped version of this API took a `principal: []const u8` name
/// parameter and minted rows keyed on it, matched at admission against
/// `self.peer_name` — the SAME self-declared string the LEASE mechanism
/// learns from an inbound announce frame (`peer_name`'s doc comment: "no
/// separate identity handshake... same trust level as `Collab`'s presence
/// names"). That is fine for a lease (collaboration hygiene, not a security
/// boundary, per `region_lease.zig`'s own module doc) but is a real
/// authority hole for a GRANT: a peer holding `access = .edit` and a
/// confining grant could announce a lease under ANY other string (an
/// ungranted name, or nothing at all) and thereby have `admitRegions` find
/// zero rows for "that" principal — `doc_has_grants = true`,
/// `peer_has_grants = false` — which this design's own rule ("absence of a
/// grant row for a peer keeps today's behavior") then reads as
/// UNRESTRICTED. A grantee sheds its own confinement by renaming — exactly
/// the silent widening §2.4 forbids, and it works with nothing more than
/// controlling a string nobody authenticates.
///
/// The fix: `Session` already proves an unforgeable identity in its secure
/// handshake — `their_id` (the peer's public key), from which
/// `peerFingerprint()` derives (Session.zig's `peerFingerprint`/`their_id`
/// doc comments: "valid once established"). THIS quad's peer is exactly
/// `self.session`'s peer (`GraphCollab` is one quad per `Session`, one
/// `Session` per encrypted link — see the module doc comment), so a
/// subtree grant declared through THIS `GraphCollab` unambiguously targets
/// that authenticated identity; there is no `principal` parameter to spoof
/// because there is nothing left for a caller to name — the grantee is
/// whoever cryptographically proved themselves on this link, full stop.
/// This closes the hub/mesh face of the same bug for free too: a peer
/// declaring another peer's self-chosen name can never make THEIR
/// fingerprint match a row minted against someone else's `Session`.
/// `peer_name` stays exactly what it always was — a DISPLAY-trust label for
/// the lease/presence UI, never consulted for authority again.
///
/// Requires `self.session` to be `established` (returns
/// `error.PeerNotEstablished` otherwise) — a grant cannot be honestly bound
/// to an identity that hasn't yet proven itself.
///
/// Mints a fresh, independently-revocable row (`grants.HandleTable.grant` —
/// a SECOND call for the same peer ADDS to the union, it never replaces a
/// prior row — see `Limit.graph_subtree`'s doc comment for the
/// union-of-grants confinement this composes into). The row's `principal`
/// bytes are the fingerprint, stably stored in `self.peer_fingerprint` (see
/// that field's doc comment for why a fresh `peerFingerprint()` value can't
/// be borrowed directly).
///
/// **Deferred, named**: no config/manifest surface exists yet — see
/// `Limit.graph_subtree`'s module-doc entry in grants.zig for why.
/// **D3 correction (doc/substrate.md §5) to the claim this
/// comment used to make**: an EARLIER version said "nothing here crosses
/// the wire" — no longer true. `push` now announces this peer's resulting
/// live, reachable granted-root set over the graph quad's `OpKind.grant`
/// frame (`announceGrant`, triggered by `needs_grant_reannounce` below), so
/// a grantee that consumes it (client role only) learns its boundary
/// PROACTIVELY instead of only by succeeding at edits it would previously
/// have been refused for — the announcement is advisory (`granted_roots`,
/// `mayEditNode`), never authority: this table, consulted at `admitRegions`,
/// remains the only real enforcement, exactly like the coarse per-doc
/// `canEdit` grant it composes with.
pub fn grantSubtree(self: *GraphCollab, root: NodeRef) !grants_mod.CapHandle {
    const table = self.grants orelse return error.NoGrantTable;
    const fp = self.session.peerFingerprint() orelse return error.PeerNotEstablished;
    // Every row this quad has EVER minted borrows its `principal` bytes
    // from this SAME `self.peer_fingerprint` storage (see that field's doc
    // comment) — overwriting it with a DIFFERENT identity would silently
    // reinterpret every prior row as belonging to someone else. This can't
    // happen through normal use (one `Session`, hence one peer, per quad;
    // `rebind` swaps `self.session` but never touches this cache — see
    // `rebind`'s doc comment: "the peer's declared name is still valid,
    // same peer, new link"), but asserting it here makes the
    // one-identity-per-`GraphCollab` invariant STRUCTURAL rather than
    // dependent on nothing elsewhere in this file ever violating it by
    // accident.
    if (self.peer_fingerprint) |cached| {
        std.debug.assert(std.mem.eql(u8, &cached, &fp));
    }
    self.peer_fingerprint = fp;
    const h = try table.grant(.{
        .capability = graph_edit_capability,
        .limit = .{ .graph_subtree = .{ .doc_id = self.name, .root = root } },
    }, &self.peer_fingerprint.?, null);
    self.needs_grant_reannounce = true; // D3 §2.1: this peer's live set changed
    return h;
}

/// Revoke every subtree grant THIS quad's authenticated peer holds on THIS
/// doc (v1 granularity — `grants.HandleTable.revoke`'s own (principal,
/// capability) scope; there is only one capability name this API ever
/// mints, so this narrows to exactly "every graph-subtree row this peer
/// holds here"). `0` (a harmless no-op) if the session isn't established or
/// nothing was ever granted. A caller that wants to revoke a SINGLE row
/// (leaving others in the union intact) already has that row's `CapHandle`
/// from `grantSubtree` and can go straight through the bound table's
/// lower-level API instead.
///
/// D3 (§2.1): a non-zero result also marks the announced set dirty — the
/// peer's live root set shrank (possibly to empty), and `push` re-announces
/// it, same as `grantSubtree`.
pub fn revokeSubtreeGrants(self: *GraphCollab) usize {
    const table = self.grants orelse return 0;
    const fp = self.session.peerFingerprint() orelse return 0;
    const n = table.revoke(&fp, graph_edit_capability);
    if (n > 0) self.needs_grant_reannounce = true;
    return n;
}

/// Point at a fresh session after a reconnect: the announce + frontier
/// exchange replays from scratch (idempotent by design — duplicate
/// events are no-ops); leases we still hold get re-announced on the next
/// `push` (see `needs_lease_reannounce`'s doc comment).
pub fn rebind(self: *GraphCollab, new_session: *Session) void {
    self.session = new_session;
    self.core.rebind(self.gpa);
    // A fresh session gets its own disconnect-reaping check; the peer's
    // declared name is still valid (same peer, new link) so it stays.
    self.reaped = false;
    self.needs_lease_reannounce = true;
    // D3 §2.1: re-announce the grant, same soft-state discipline as the
    // lease re-announce above — a fresh session starts knowing nothing.
    self.needs_grant_reannounce = true;
}

/// Per-frame (solo use): drain inbound frames, handle the ones in our
/// quad, then push. Under `Conn` the drain/dispatch happens once for all
/// Collabs/GraphCollabs instead.
pub fn tick(self: *GraphCollab) !bool {
    const gpa = self.gpa;
    var changed = false;
    var frames: std.ArrayList(wire.Decoder.Decoded) = .empty;
    defer frames.deinit(gpa);
    try self.session.drain(gpa, &frames);
    for (frames.items) |frame| {
        defer gpa.free(frame.payload);
        changed = (self.handleFrame(frame) catch false) or changed;
    }
    return (try self.push()) or changed;
}

/// Fold one inbound frame belonging to this quad. The `base` channel
/// carries `.op` frames (batch/frontier/share/grant/region_refused);
/// `base + 1` (W6 slice 1) carries lease announce/release feeds — the
/// presence slot `Collab` claims, left unclaimed here until now (see the
/// module doc comment). Every other channel/class in the quad
/// (diagnostics/blob — still unclaimed text-doc machinery) is a no-op;
/// `false` either way (nothing changed).
pub fn handleFrame(self: *GraphCollab, frame: wire.Decoder.Decoded) !bool {
    const gpa = self.gpa;
    if (frame.channel == self.base and frame.class == .op) {
        switch (std.enums.fromInt(wire.OpKind, frame.kind) orelse return false) {
            .batch => {
                // Decode + frontier-track + the coarse per-doc admission
                // gate: shared with the text driver (`sync_core.SyncCore.
                // admitBatch`). The PER-REGION gate (W6 slice 1) composes
                // right after it, at the SAME chokepoint, before the merge
                // call — see `admitRegions`'s doc comment for why it's
                // shaped as a second gate here rather than folded into
                // `sync_core` (only `GraphDoc` has regions; `sync_core` is
                // doc-agnostic with exactly one other client, `Collab`,
                // that has none). The merge call itself stays here —
                // `GraphDoc.merge` has no `Collab`-style error-recovery
                // branch to diverge on (see `sync_core.zig`'s doc comment
                // on why merge isn't shared).
                //
                // Deliberate ordering: `admitBatch` records the SENDER's
                // stated frontier (`setTheirFrontier`) UNCONDITIONALLY,
                // before the region gate below even runs — including for a
                // batch this quad is about to refuse. That's correct, not
                // an oversight: the frontier token is the sender's honest
                // statement of their OWN causal position, true regardless
                // of whether we admit their ops, and refusing to record it
                // would make us think they're behind when they aren't —
                // spurious resync traffic, not a safety issue either way.
                const batch = switch (try self.core.admitBatch(gpa, self.session, self.publication, frame.payload)) {
                    .idle => return false,
                    .refused => |why| {
                        // Loud on the transition, quiet on repeats — see
                        // `Collab`'s own `.refused` arm for why.
                        if (self.last_refusal == null or self.last_refusal.? != why)
                            std.log.warn("graph-collab: batch refused: {t}", .{why});
                        self.last_refusal = why;
                        return false;
                    },
                    .merge => |b| b,
                };
                switch (self.admitRegions(gpa, batch) catch |err| {
                    std.log.warn("graph-collab: region admission check failed: {t}", .{err});
                    return false;
                }) {
                    .refuse => |r| {
                        defer r.free(gpa);
                        self.sendRefusal(r.region, r.holder, r.reason) catch |err| {
                            std.log.warn("graph-collab: refusal echo failed: {t}", .{err});
                        };
                        return false;
                    },
                    .admit => {},
                }
                const changes = self.doc.merge(gpa, batch) catch |err| {
                    std.log.warn("graph-collab: batch rejected: {t}", .{err});
                    return false;
                };
                defer gpa.free(changes);
                return changes.len > 0;
            },
            .frontier => {
                try self.core.setTheirFrontier(gpa, frame.payload);
                try self.core.sendBatch(gpa, self.session, self.base, self.doc, false);
                return false;
            },
            // Connection-level (Conn consumes these on channel 0).
            .share, .publish, .unpublish => return false,
            // D3 §2.1: the host's announced granted-root set. Client role
            // only — same reverse-vector guard `Collab.zig`'s `.grant`
            // consume enforces (a host is the authority; it is never
            // granted anything by a peer).
            .grant => {
                if (self.session.role != .client) return false;
                self.setGrantedRoots(gpa, frame.payload) catch |err| {
                    std.log.warn("graph-collab: grant announce decode failed: {t}", .{err});
                    return false;
                };
                return true;
            },
            .region_refused => {
                var cur: []const u8 = frame.payload;
                const rlen = wire.getUv(&cur) catch return false;
                if (rlen > cur.len) return false;
                const region_token = cur[0..rlen];
                cur = cur[rlen..];
                const hlen = wire.getUv(&cur) catch return false;
                if (hlen > cur.len) return false;
                const holder = cur[0..hlen];
                cur = cur[hlen..];
                // Trailing reason byte (W6 slice 2) — additive/version-
                // tolerant exactly like the lease frame's trailing `hue16`
                // (see `handleLeaseFrame`'s doc comment for the precedent):
                // an OLDER sender (pre-W6-slice-2) never sent this byte at
                // all, since `.lease` was the only refusal reason that
                // existed — `getUv`'s `catch` default of `0` decodes to
                // `.lease` either way, so an old peer's refusal is still
                // interpreted correctly, never a decode error.
                const reason_code = wire.getUv(&cur) catch 0;
                const reason = std.enums.fromInt(RefusalReason, reason_code) orelse .lease;
                const region_owned: NodeRef = .{ .token = try gpa.dupe(u8, region_token) };
                errdefer region_owned.free(gpa);
                const holder_owned = try gpa.dupe(u8, holder);
                errdefer gpa.free(holder_owned);
                try self.refusals.append(gpa, .{ .region = region_owned, .holder = holder_owned, .reason = reason });
                return false;
            },
        }
    } else if (frame.channel == self.base + 1 and frame.class == .feed) {
        return self.handleLeaseFrame(gpa, frame.payload);
    }
    return false;
}

/// Which regions (portable `NodeRef`s) `batch` touches, checked against the
/// bound lease table AND the bound grant table — the GENERAL per-region
/// admission hook (doc/substrate.md §4: "the same per-region admission W6
/// needs for identity-anchored subtree grants"). The lease was this hook's
/// FIRST client (W6 slice 1); the subtree grant (`gatherGrantRoots` + the
/// authority loop in `admitRegions`, W6 slice 2) is its SECOND — another
/// predicate over the exact same dry-run pass, ANDed into the same
/// admit/refuse control flow, not a second, parallel admission path. See
/// this file's `.batch` handler for where this whole function sits relative
/// to `sync_core`'s coarse gate, and `admitRegions`'s own doc comment for
/// the authority-then-lease composition order.
///
/// ## "Refused" is deferred-until-release, not a permanent verdict
///
/// A refused batch is NEVER merged (§6 test 5's letter) — but that is a
/// statement about THIS admission attempt, not a promise the sender's edit
/// is lost or must be manually retried. `sync_core.pushOnMove` computes
/// what to send as "everything since the peer's LAST KNOWN frontier"; a
/// refusal doesn't advance that frontier (we never merged, so our stated
/// frontier to the sender doesn't move), so the refused op stays part of
/// "what the sender still owes us" from OUR point of view. The NEXT time
/// the sender's head moves for ANY reason (a further edit — nothing
/// proactive retries on its own; there is no timer here), the resulting
/// batch naturally re-includes the earlier refused op bundled with the new
/// one, and THIS gate re-evaluates it against the lease state AT THAT
/// TIME — if the holder has since released, admission now passes and the
/// once-refused op finally lands ("late apply on release"); if the same
/// principal still holds it, refused again, harmlessly. This falls out of
/// the existing frontier-delta design for free — no special-casing here.
/// **This property is why REQUIRED FIX 2 matters**: before it, a
/// create-and-populate batch's touched region (the new node) could NEVER
/// resolve against `self` no matter how many times it was re-sent — the
/// node's identity never gets "older" — so "deferred-until-release" quietly
/// became a PERMANENT lockout for exactly the grantee-appends-an-entry case
/// this whole mechanism exists to serve. See `GraphDoc.touchedRegionsWithin`'s
/// doc comment for the fix. The sender's OWN replica has a real, if
/// transient, local divergence in the meantime (their local doc has the
/// edit; the shared replica doesn't yet) — visible to them via `refusals`
/// (append-only; draining/freeing each entry is the caller's job, same
/// contract as `Collab`'s other accumulator lists).
pub const RegionVerdict = union(enum) {
    admit,
    refuse: Refusal,
};

/// This peer's LIVE `.graph_subtree` rows for THIS doc — the authority
/// half of `admitRegions`, split out because it must run BEFORE the
/// dry-run merge below (grant roots are always PRE-EXISTING nodes, never
/// batch-fresh, so resolving/reachable-checking them against `self.doc`
/// needs no scratch clone — see `GraphDoc.touchedRegionsWithin`'s doc
/// comment for why the TOUCHED regions are a different story).
///
/// **Identity, DECIDED (REQUIRED FIX 1)**: matched against
/// `self.session.peerFingerprint()` — the AUTHENTICATED identity of this
/// quad's peer — never `self.peer_name` (self-declared, spoofable; see
/// `grantSubtree`'s doc comment for the exploit this closes and why).
///
/// **Union-of-grants confinement + collapse, DECIDED**: see
/// `Limit.graph_subtree`'s doc comment (grants.zig) for the policy. A
/// collapsed (root deleted/unreachable) row is NOT dropped from the
/// union and does NOT fall back to unrestricted — it is simply excluded
/// from `roots` (there is no live subtree left to test containment
/// against), so if it was this peer's ONLY row, `peer_has_grants` stays
/// `true` while `roots` ends up EMPTY: every subsequent touched region
/// then fails containment against the (empty) union, and `admitRegions`
/// refuses EVERYTHING for this peer on this doc with `.collapsed` — total
/// refusal, not a partial or silent one. That is the intended behavior,
/// not a bug: a grantee with a dead grant has no OTHER standing to edit
/// with (per-doc `canEdit` still gates elsewhere, but authority here is
/// what W6 added, and it has nothing to fall back to once its one grant is
/// gone).
const GrantContext = struct {
    doc_has_grants: bool = false,
    peer_has_grants: bool = false,
    any_collapsed: bool = false,
    /// This peer's alive+reachable granted roots, as PORTABLE tokens
    /// (borrowed from the table's rows — never freed here; `roots.deinit`
    /// only frees the ArrayList's own backing memory). Passed straight
    /// into `GraphDoc.touchedRegionsWithin`, which resolves them inside
    /// its own scratch clone.
    roots: std.ArrayList(NodeRef) = .empty,

    fn deinit(self: *GrantContext, gpa: Allocator) void {
        self.roots.deinit(gpa);
    }
};

fn gatherGrantRoots(self: *GraphCollab, gpa: Allocator) !GrantContext {
    var ctx: GrantContext = .{};
    const table = self.grants orelse return ctx;
    if (table.rows.items.len == 0) return ctx; // fast path — nothing minted anywhere

    const peer_fp = self.session.peerFingerprint(); // ?[24]u8 — AUTHENTICATED, never peer_name (FIX 1)

    for (table.rows.items) |r| {
        const gs = switch (r.limit) {
            .graph_subtree => |g| g,
            .none, .fs_root, .doc_region => continue,
        };
        if (!std.mem.eql(u8, gs.doc_id, self.name)) continue;
        ctx.doc_has_grants = true;
        const fp = peer_fp orelse continue; // not (yet) authenticated — matches no row
        if (!std.mem.eql(u8, r.principal, &fp)) continue;
        ctx.peer_has_grants = true;
        // A REVOKED row still counts as a grant this peer once held, and
        // contributes no root — the same total-refusal shape a collapsed
        // root gets (see `GrantContext`'s doc comment). Skipping dead rows
        // outright would let revocation WIDEN authority back to
        // unrestricted, which §13.5's "missing grant state never means
        // unrestricted" forbids.
        if (!r.alive) continue;
        const root_obj = self.doc.resolve(gs.root) catch {
            ctx.any_collapsed = true;
            continue;
        };
        if (!try self.doc.reachable(gpa, root_obj)) {
            ctx.any_collapsed = true;
            continue;
        }
        try ctx.roots.append(gpa, gs.root);
    }
    return ctx;
}

/// **Composition order, DECIDED (W6 slice 2, doc/substrate.md): canEdit (per-doc,
/// `sync_core.admitBatch` — already run by the caller BEFORE this function)
/// → subtree grants (AUTHORITY) → lease (OCCUPANCY).** Authority runs before
/// occupancy at this chokepoint because it is the more fundamental — and
/// more ACTIONABLE — question: a sender who was never granted a region at
/// all should be told THAT ("you have no authority here"), not "someone
/// else happens to be using it right now" (which would be true but
/// misleading — it implies the sender WOULD be allowed if only the holder
/// released, which isn't so for an unauthorized sender).
///
/// At most ONE dry-run merge, and ZERO when there is nothing to protect:
/// `gatherGrantRoots` resolves this peer's granted roots against `self.doc`
/// (cheap, no clone — see its doc comment) and reports `doc_has_grants` for
/// free from that same walk; combined with `self.leases`' own emptiness
/// (equally cheap), an ordinary share with NEITHER a grant table nor a
/// lease table holding anything active returns `.admit` immediately below,
/// before `GraphDoc.touchedRegionsWithin`'s `serialize`+`open`+`merge` ever
/// runs — this is the fast path `touchedRegionsWithin`'s own doc comment
/// prices the dry-run cost against ("paid only when the caller has active
/// regions to protect"), and it is load-bearing: `admitRegions` runs on
/// EVERY inbound batch on EVERY graph quad, so a plain share (no grants,
/// no leases — the common case) must not pay a full-history dry-run per
/// batch just because the mechanism EXISTS. When something IS active,
/// `touchedRegionsWithin` runs its ONE scratch-clone merge, and both the
/// authority loop and the lease loop below read from that SAME result —
/// never two dry-run merges for one batch either (module doc comment: "do
/// NOT clone the lease plumbing").
pub fn admitRegions(self: *GraphCollab, gpa: Allocator, batch: []const u8) !RegionVerdict {
    var grant_ctx = try self.gatherGrantRoots(gpa);
    defer grant_ctx.deinit(gpa);

    // The fast path, restored (post-review: the consolidation below had
    // dropped it, making EVERY inbound batch on an ordinary share — no
    // grants, no leases bound at all — pay a full serialize+open+merge
    // dry-run that was previously zero cost). `gatherGrantRoots` already
    // walked the grant table for free (no clone); `leases_active` is an
    // equally cheap table-emptiness check. Neither table having anything
    // to protect means there is nothing for the clone below to answer —
    // skip it entirely, exactly like `touchedRegions`'s own doc comment
    // promises ("paid only when the caller has active regions to
    // protect").
    const leases_active = if (self.leases) |lt| !lt.isEmpty() else false;
    if (!grant_ctx.doc_has_grants and !leases_active) return .admit;

    const touched = try self.doc.touchedRegionsWithin(gpa, batch, grant_ctx.roots.items);
    defer {
        for (touched) |tr| tr.region.free(gpa);
        gpa.free(touched);
    }
    if (touched.len == 0) return .admit;

    if (grant_ctx.doc_has_grants) {
        if (self.session.peerFingerprint() == null) {
            // Grants are configured for this doc, but we cannot attribute
            // the sender to ANY identity yet (session not established —
            // see `gatherGrantRoots`'s doc comment) — fail CLOSED rather
            // than silently admit (this codebase's standing doctrine,
            // grants.zig's `.doc_region` collapse policy: "ANY failure
            // fails CLOSED, not open"). Unreachable in practice once a
            // `.batch` frame could even be decrypted (that already implies
            // `established`); kept as a real, defensive branch rather than
            // an `unreachable` for direct `admitRegions` callers (tests).
            return .{ .refuse = .{
                .region = try touched[0].region.dupe(gpa),
                .holder = try gpa.dupe(u8, ""),
                .reason = .authority,
            } };
        }
        if (grant_ctx.peer_has_grants) {
            for (touched) |tr| {
                if (!tr.within_roots) {
                    return .{
                        .refuse = .{
                            .region = try tr.region.dupe(gpa),
                            .holder = try gpa.dupe(u8, ""),
                            // If ANY of this peer's granted roots has
                            // collapsed, surface THAT rather than a flat
                            // "outside your grant" — see `GrantContext`'s doc
                            // comment for the total-refusal-on-sole-collapse
                            // case this composes with.
                            .reason = if (grant_ctx.any_collapsed) .collapsed else .authority,
                        },
                    };
                }
            }
        }
        // else: this doc has grants for SOMEONE, but not for this
        // authenticated peer — unrestricted (today's behavior; grants
        // narrow, they never default-deny the world).
    }

    const table = self.leases orelse return .admit;
    if (table.isEmpty()) return .admit;
    for (touched) |tr| {
        const holder = table.holderOf(tr.region) orelse continue; // free — no restriction
        if (self.peer_name) |pn| {
            if (std.mem.eql(u8, holder, pn)) continue; // the sender's own held region
        }
        return .{ .refuse = .{
            .region = try tr.region.dupe(gpa),
            .holder = try gpa.dupe(u8, holder),
            .reason = .lease,
        } };
    }
    return .admit;
}

/// D3 PREVENTION, the grantee-side pre-flight (doc/substrate.md §5's
/// "pre-flight"): is `node`, as it exists RIGHT NOW on THIS replica's own
/// live `self.doc`, within any of the announced `granted_roots`? Answers via
/// `GraphDoc.contains` directly against `self.doc` — no scratch clone
/// needed, unlike `admitRegions`' `touchedRegionsWithin` dry-run: THAT
/// function must handle a batch-fresh node that doesn't exist on the
/// enforcer's pre-merge replica yet (REQUIRED FIX 2's whole reason for
/// being); a client calling `mayEditNode` is asking about a node that
/// already exists on ITS OWN live doc at edit time (you can't type into a
/// node your own replica hasn't created), so there is no equivalent "doesn't
/// exist yet" case to clone around.
///
/// **Unannounced/empty `granted_roots` = unconfined (`true`)** — today's
/// behavior, mirroring `admitRegions`' "absence of a grant row keeps
/// today's behavior." **Advisory only, NEVER authority** (see
/// `granted_roots`'s field doc comment): this can only ever cause a caller
/// to REFUSE a candidate local edit early; the host's `admitRegions`
/// remains the sole real enforcement regardless of what this returns.
///
/// A root that no longer `resolve`s against `self.doc` (this replica
/// hasn't merged its creating event, or it's foreign) is skipped, not
/// fatal — same "excluded, not fatal" treatment
/// `touchedRegionsWithin`/`gatherGrantRoots` already give an unresolvable
/// root; a client should not trap on state it hasn't even caught up to yet.
///
/// **Where this hooks into an actual edit path, honestly**: there is no
/// SINGLE existing client-side edit chokepoint for graph docs today to wire
/// this into — `transcript.zig`'s `reconcileOnSave` calls
/// `TranscriptDoc.editText`/`deleteText` directly against the model, with
/// no `GraphCollab` in the loop at all (a `TranscriptDoc` doesn't hold one).
/// Inventing a new edit-path layer just to thread this through is exactly
/// what this design forbids ("do NOT invent a new edit-path layer for
/// this," the caller's own brief). This predicate, and its use in the §6
/// tests below (a simulated client consulting it before minting a local
/// op), is the honest bar this slice clears; wiring `reconcileOnSave` (or a
/// future live, per-edit graph-doc client) to call this before applying an
/// out-of-grant model edit is the named, un-built remainder.
pub fn mayEditNode(self: *const GraphCollab, gpa: Allocator, node: GraphDoc.ObjId) Allocator.Error!bool {
    if (self.granted_roots.len == 0) return !self.granted_confined;
    for (self.granted_roots) |root_ref| {
        const root_obj = self.doc.resolve(root_ref) catch continue;
        if (try self.doc.contains(gpa, root_obj, node)) return true;
    }
    return false;
}

/// D3 RECOVERY, the trigger-honesty predicate (doc/substrate.md §5): does
/// `self.refusals` hold any `.authority`/ `.collapsed` entry — the taxonomy
/// that has NO release to wait for (only `.lease` self-heals,
/// `admitRegions`' own "deferred-until-release, not permanent rejection"
/// doc comment)? `true` is the client's OWN policy signal to RE-BOOTSTRAP
/// (discard this doc, `GraphDoc.init` fresh, re-attach, replay wanted
/// in-grant edits, §2.2/§1.3) — never to keep waiting: nothing about a
/// subtree-grant boundary ever releases, so sitting and re-riding the
/// refused op (the LEASE-only healing property) degenerates to a permanent
/// poison for authority, exactly as doc/substrate.md §5 traces. This is a
/// HELPER, not a recipe: it answers the one question this driver can answer
/// on its own state (refusals it already tracks); the re-bootstrap SEQUENCE
/// itself (discard/init/rebind/replay) is inherently session- and
/// model-specific — it needs a live `Session`/`Conn` this driver doesn't
/// own and a "which edits are still wanted" answer only the model-owning
/// caller (a `TranscriptDoc`, say) can give — so it stays a documented
/// recipe, proven end to end by the §6 test 5 recovery test, not
/// generalized into a second helper here.
pub fn needsRebootstrap(self: *const GraphCollab) bool {
    for (self.refusals.items) |r| {
        if (r.reason == .authority or r.reason == .collapsed) return true;
    }
    return false;
}

fn sendRefusal(self: *GraphCollab, region: NodeRef, holder: []const u8, reason: RefusalReason) !void {
    const gpa = self.gpa;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, region.token.len);
    try payload.appendSlice(gpa, region.token);
    try wire.putUv(gpa, &payload, holder.len);
    try payload.appendSlice(gpa, holder);
    try wire.putUv(gpa, &payload, @intFromEnum(reason));
    try self.session.post(.op, @intFromEnum(wire.OpKind.region_refused), self.base, payload.items);
}

/// D3 §2.1 emit: post THIS peer's current live, reachable granted-root set
/// on the graph quad's `.grant` frame (`base` channel, `OpKind.grant`) —
/// the one-for-one mirror of `Collab.zig`'s per-doc grade emit at `push`.
/// Payload: `uv n | (uv token_len | token) × n`. Reuses `gatherGrantRoots`
/// wholesale — it already computes EXACTLY this (this quad's authenticated
/// peer's alive+reachable `.graph_subtree` roots, cheap, no clone) for
/// `admitRegions`'s own authority check, so emit and enforcement can never
/// disagree about what "this peer's live granted roots" means. `n = 0`
/// (an empty announcement) is a real, meaningful frame — "no confinement
/// announced" — not skipped, so a grantee whose last grant was just fully
/// revoked learns that too. A no-op (no frame sent at all) when no grant
/// table is bound — the common case for a graph quad that never uses
/// authority at all should not pay even one empty announce per reconnect,
/// same "fast path" discipline `admitRegions`' own doc comment prices for
/// the dry-run clone. Also a no-op off the SERVER role — same emit-side
/// reverse-vector guard `Collab.zig`'s own per-doc grade emit uses (`role
/// == .server`), kept here too even though the receive-side guard in
/// `handleFrame` already fully protects against a rogue client's frame on
/// its own: a client-role quad should never emit `.grant` AT ALL, matching
/// the "one-for-one mirror" claim literally.
fn announceGrant(self: *GraphCollab, gpa: Allocator) !void {
    if (self.grants == null or self.session.role != .server) return;
    var ctx = try self.gatherGrantRoots(gpa);
    defer ctx.deinit(gpa);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, ctx.roots.items.len);
    for (ctx.roots.items) |root| {
        try wire.putUv(gpa, &payload, root.token.len);
        try payload.appendSlice(gpa, root.token);
    }
    // ADDITIVE trailing confinement byte: "this peer is confined" is not the
    // same claim as "here are some roots". Without it, a peer whose only
    // grant was revoked receives an EMPTY set and reads it as the
    // unconfined default — its preflight would wave through edits the host
    // is about to refuse. An older grantee stops after the roots and never
    // sees this byte, degrading to exactly today's infer-from-non-empty
    // behavior (which is advisory anyway; the host still enforces).
    try payload.append(gpa, @intFromBool(ctx.peer_has_grants));
    try self.session.post(.op, @intFromEnum(wire.OpKind.grant), self.base, payload.items);
}

/// D3 §2.1 consume: fold an inbound graph `.grant` frame into
/// `self.granted_roots` — a WHOLESALE replacement (the host always
/// announces its current full live set, never a delta; see `announceGrant`),
/// never a merge with whatever was recorded before. Malformed payload
/// (truncated uv/length) is treated as version-tolerant-if-empty: `n = 0`
/// (or a decode that yields nothing) simply clears `granted_roots`, which
/// degrades to the safe "unconfined" default rather than an error — a
/// grant announcement is advisory, so failing to parse it should never be
/// treated as a hard fault.
fn setGrantedRoots(self: *GraphCollab, gpa: Allocator, payload: []const u8) !void {
    var cur: []const u8 = payload;
    const n = wire.getUv(&cur) catch 0;
    var roots: std.ArrayList(NodeRef) = .empty;
    errdefer {
        for (roots.items) |r| r.free(gpa);
        roots.deinit(gpa);
    }
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const tlen = wire.getUv(&cur) catch break;
        if (tlen > cur.len) break;
        const token = cur[0..tlen];
        cur = cur[tlen..];
        try roots.append(gpa, .{ .token = try gpa.dupe(u8, token) });
    }
    // Additive trailing confinement byte (see `announceGrant`). Absent — an
    // older host, or a payload that ran out mid-decode — falls back to
    // inferring confinement from a non-empty set, today's behavior.
    const confined = if (cur.len > 0) cur[0] != 0 else roots.items.len > 0;
    // Materialize the new set BEFORE freeing the old one: toOwnedSlice can
    // fail, and freeing first would leave granted_roots dangling for the
    // next deinit/setGrantedRoots to double-free (review-caught, OOM-only).
    const new_roots = try roots.toOwnedSlice(gpa);
    for (self.granted_roots) |r| r.free(gpa);
    gpa.free(self.granted_roots);
    self.granted_roots = new_roots;
    self.granted_confined = confined;
}

/// Fold an inbound lease announce/release frame (`base + 1`): uv
/// name_len | name | uv region_token_len | region_token | uv flag (1 =
/// acquired, 0 = released) | uv hue16 (additive — see below). Also learns
/// `self.peer_name` from it (see the field's doc comment): this quad's
/// remote peer is whoever announces leases on it.
///
/// The trailing `hue16` is additive/version-tolerant exactly like
/// `Collab`'s presence frame (module doc comment precedent: "the trailing
/// fields are additive — an older peer sends only head, so ... defaults to
/// a stable per-name fallback"): a peer that predates this field simply
/// doesn't send it, `getUv` falls through to the `catch` default, and the
/// span just renders with a deterministic fallback hue instead of the
/// announcer's real one — never a decode error.
fn handleLeaseFrame(self: *GraphCollab, gpa: Allocator, payload: []const u8) !bool {
    var cur: []const u8 = payload;
    const nlen = wire.getUv(&cur) catch return false;
    if (nlen > cur.len) return false;
    const name = cur[0..nlen];
    cur = cur[nlen..];
    const tlen = wire.getUv(&cur) catch return false;
    if (tlen > cur.len) return false;
    const token = cur[0..tlen];
    cur = cur[tlen..];
    const flag = wire.getUv(&cur) catch return false;
    const hue16 = wire.getUv(&cur) catch (std.hash.Fnv1a_64.hash(name) & 0xffff);

    if (self.peer_name == null or !std.mem.eql(u8, self.peer_name.?, name)) {
        if (self.peer_name) |old| gpa.free(old);
        self.peer_name = try gpa.dupe(u8, name);
    }
    const table = self.leases orelse return true;
    const region: NodeRef = .{ .token = token };
    if (flag != 0) {
        try table.foldRemoteAcquire(gpa, region, name, @intCast(hue16));
    } else {
        table.release(gpa, region, name);
    }
    return true;
}

fn announceLease(self: *GraphCollab, region: NodeRef, acquired: bool) !void {
    const gpa = self.gpa;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, self.name.len);
    try payload.appendSlice(gpa, self.name);
    try wire.putUv(gpa, &payload, region.token.len);
    try payload.appendSlice(gpa, region.token);
    try wire.putUv(gpa, &payload, if (acquired) 1 else 0);
    const hue16: u32 = @intFromFloat(self.session.id.hue() * 65535.0);
    try wire.putUv(gpa, &payload, hue16);
    // Coalescing key is per-region: acquire/release for the SAME region
    // coalesce under backpressure (latest state wins), independent
    // regions never collide — same pattern as presence's per-peer key.
    const key = std.hash.Fnv1a_64.hash(region.token);
    try self.session.postFeed(self.base + 1, key, payload.items);
}

/// The LOCAL "I want this region" intent (doc/substrate.md §4's
/// acquire, "granted iff no other principal holds it"). Announces to the
/// peer on grant so their admission gate and display learn about it too;
/// the conflict answer (already held by X) is returned as data, never a
/// silent failure.
pub fn acquireLease(self: *GraphCollab, region: NodeRef) !LeaseTable.AcquireResult {
    const table = self.leases orelse return error.NoLeaseTable;
    const gpa = self.gpa;
    const hue16: u32 = @intFromFloat(self.session.id.hue() * 65535.0);
    const res = try table.tryAcquire(gpa, region, self.name, hue16);
    if (res == .granted) try self.announceLease(region, true);
    return res;
}

/// Explicit release (doc/substrate.md §4). A no-op if we don't hold
/// it (`LeaseTable.release`'s holder-matched guard).
pub fn releaseLease(self: *GraphCollab, region: NodeRef) !void {
    const table = self.leases orelse return;
    table.release(self.gpa, region, self.name);
    try self.announceLease(region, false);
}

/// Disconnect reaping (§5.2): once this quad's session is confirmed dead,
/// drop the peer's leases from our local table so the region becomes
/// acquirable again — "a dead session's leases die". Called from `tick`/
/// `push`; idempotent (guarded by `reaped`, and `LeaseTable.reap` itself
/// is a harmless no-op on a principal with nothing held).
fn reapIfDead(self: *GraphCollab) void {
    if (self.reaped) return;
    if (self.session.liveness() != .offline) return;
    self.reaped = true;
    const table = self.leases orelse return;
    const pn = self.peer_name orelse return;
    table.reap(self.gpa, pn);
}

/// Announce once, then push whenever our head moved. Call after the
/// frames of a tick.
pub fn push(self: *GraphCollab) !bool {
    self.reapIfDead();
    const live = self.session.liveness();
    if (live != .connected and live != .degraded) return false;

    const gpa = self.gpa;
    try self.core.announceOnce(gpa, self.session, self.base, self.doc);
    try self.core.pushOnMove(gpa, self.session, self.base, self.doc, false);

    // Presence parity on reconnect (§5.2): re-teach the fresh session
    // every region we still hold locally — the peer may have reaped it
    // across the disconnect (§5.2's own lifetime discipline), and without
    // this it never re-learns we still hold it. See
    // `needs_lease_reannounce`'s doc comment.
    if (self.needs_lease_reannounce) {
        self.needs_lease_reannounce = false;
        if (self.leases) |table| {
            const held = try table.regionsHeldBy(gpa, self.name);
            defer {
                for (held) |r| r.free(gpa);
                gpa.free(held);
            }
            for (held) |region| try self.announceLease(region, true);
        }
    }

    // D3 §2.1: (re-)announce this peer's live granted-root set, same
    // dirty-flag discipline as the lease re-announce above — set by
    // `grantSubtree`/`revokeSubtreeGrants` (the peer's live rows changed)
    // and by `rebind` (a fresh session starts knowing nothing).
    if (self.needs_grant_reannounce) {
        self.needs_grant_reannounce = false;
        try self.announceGrant(gpa);
    }
    return false;
}
