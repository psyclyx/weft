//! `GraphCollab` — the per-doc sync driver for ONE `GraphDoc` over one
//! channel quad of a `Session` (stemma delta 5, doc/north-star-plan.md
//! §2.6/§4 C19/§6 W5: "ObjectDoc's version/eventsSince/merge already speak
//! the same token model [as TextDoc], so it is binding work, not protocol
//! work").
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
//! The `base` channel carries `OpKind.batch`/`.frontier`/`.region_refused`
//! (`.share` is consumed by `Conn`, `.grant` is not implemented here — see
//! above). `base + 1` (W6 slice 1, doc/d1-live-reconcile.md §5) now carries
//! the per-region LEASE announce/release feed — the same slot `Collab`
//! claims for presence, left unclaimed here until this slice; leases are
//! presence-shaped data (§5.2: "a lease is a presence span with a locked
//! flag"), so reusing the slot instead of minting a new one is deliberate.
//! `base + 2` (diagnostics) and `base + 3` (blob/`.peer`-fs) remain
//! unclaimed; a graph quad still reserves the full 4-wide slot (`Conn`'s
//! `next_base` counter is shared with text shares, so bases never collide
//! either way).
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

const wire = @import("../wire.zig");
const GraphDoc = @import("../graph.zig");
const NodeRef = GraphDoc.NodeRef;

const Session = @import("Session.zig");
const sync_core = @import("sync_core.zig");
const region_lease = @import("region_lease.zig");
const LeaseTable = region_lease.LeaseTable;

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

// ── W6 slice 1: the per-region lease (doc/d1-live-reconcile.md §5) ────
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
/// the LOUD refusal (never a silent drop — d1-live-reconcile.md §5.2, §6
/// test 5). Append-only; the caller drains/inspects and is responsible for
/// freeing each entry's owned fields (`Refusal.free`).
refusals: std.ArrayList(Refusal) = .empty,
/// Guards a single `leases.reap` call per dead session (reap is itself
/// idempotent, but this avoids repeated table walks every tick).
reaped: bool = false,
/// Set by `rebind`; cleared by the next `push` once it has re-announced
/// every region we still hold to the fresh session — presence parity
/// (`Collab.rebind` forces a presence republish by resetting
/// `last_presence_offset`; §5.2 promises leases are "re-announced like
/// presence"). Without this, a peer who reaped our leases across the
/// disconnect (§5.2's own lifetime discipline) never re-learns we still
/// hold them, and their next fresh acquire would fold against nothing —
/// silently taking a region we never released.
needs_lease_reannounce: bool = false,

pub const Refusal = struct {
    region: NodeRef,
    holder: []u8,

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
    self.gpa.free(self.name);
}

/// Bind a per-replica lease table (W6 slice 1, see the field's doc
/// comment). Opt-in and additive: a `GraphCollab` with no table bound
/// behaves exactly as before this slice.
pub fn bindLeases(self: *GraphCollab, table: *LeaseTable) void {
    self.leases = table;
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
                const batch = (try self.core.admitBatch(gpa, self.session, frame.payload)) orelse return false;
                switch (self.admitRegions(gpa, batch) catch |err| {
                    std.log.warn("graph-collab: region admission check failed: {t}", .{err});
                    return false;
                }) {
                    .refuse => |r| {
                        defer r.free(gpa);
                        self.sendRefusal(r.region, r.holder) catch |err| {
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
            // `.share` is connection-level (Conn consumes it); `.grant`
            // has no consumer yet — see the module doc comment.
            .share, .grant => return false,
            .region_refused => {
                var cur: []const u8 = frame.payload;
                const rlen = wire.getUv(&cur) catch return false;
                if (rlen > cur.len) return false;
                const region_token = cur[0..rlen];
                cur = cur[rlen..];
                const hlen = wire.getUv(&cur) catch return false;
                if (hlen > cur.len) return false;
                const holder = cur[0..hlen];
                const region_owned: NodeRef = .{ .token = try gpa.dupe(u8, region_token) };
                errdefer region_owned.free(gpa);
                const holder_owned = try gpa.dupe(u8, holder);
                errdefer gpa.free(holder_owned);
                try self.refusals.append(gpa, .{ .region = region_owned, .holder = holder_owned });
                return false;
            },
        }
    } else if (frame.channel == self.base + 1 and frame.class == .feed) {
        return self.handleLeaseFrame(gpa, frame.payload);
    }
    return false;
}

/// Which regions (portable `NodeRef`s) `batch` touches, checked against
/// the bound lease table — the GENERAL per-region admission hook (doc/
/// d1-live-reconcile.md §5.2: "the same per-region admission W6 needs for
/// identity-anchored subtree grants"; north-star-plan.md §6 W6). The lease
/// is this hook's FIRST client, not its only intended one: a future
/// subtree-grant check composes here the same way (another predicate over
/// the same `touchedRegions` call, ANDed into the same admit/refuse
/// control flow) rather than a second, parallel admission path — see this
/// file's `.batch` handler for where it sits relative to `sync_core`'s
/// coarse gate.
///
/// No lease table bound, or an empty one, is the fast path: no clone, no
/// dry-run merge — `GraphDoc.touchedRegions` is only ever called when
/// there is something to protect (see its own doc comment for the cost
/// this avoids paying on every batch).
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
/// The sender's OWN replica has a real, if transient, local divergence in
/// the meantime (their local doc has the edit; the shared replica doesn't
/// yet) — visible to them via `refusals` (append-only; draining/freeing
/// each entry is the caller's job, same contract as `Collab`'s other
/// accumulator lists).
pub const RegionVerdict = union(enum) {
    admit,
    refuse: Refusal,
};

pub fn admitRegions(self: *GraphCollab, gpa: Allocator, batch: []const u8) !RegionVerdict {
    const table = self.leases orelse return .admit;
    if (table.isEmpty()) return .admit;
    const touched = try self.doc.touchedRegions(gpa, batch);
    defer {
        for (touched) |r| r.free(gpa);
        gpa.free(touched);
    }
    for (touched) |region| {
        const holder = table.holderOf(region) orelse continue; // free — no restriction
        if (self.peer_name) |pn| {
            if (std.mem.eql(u8, holder, pn)) continue; // the sender's own held region
        }
        return .{ .refuse = .{
            .region = try region.dupe(gpa),
            .holder = try gpa.dupe(u8, holder),
        } };
    }
    return .admit;
}

fn sendRefusal(self: *GraphCollab, region: NodeRef, holder: []const u8) !void {
    const gpa = self.gpa;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try wire.putUv(gpa, &payload, region.token.len);
    try payload.appendSlice(gpa, region.token);
    try wire.putUv(gpa, &payload, holder.len);
    try payload.appendSlice(gpa, holder);
    try self.session.post(.op, @intFromEnum(wire.OpKind.region_refused), self.base, payload.items);
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

/// The LOCAL "I want this region" intent (d1-live-reconcile.md §5.2's
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

/// Explicit release (d1-live-reconcile.md §5.2). A no-op if we don't hold
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
    return false;
}
