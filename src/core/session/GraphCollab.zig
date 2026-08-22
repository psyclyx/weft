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
//! ## Quad layout (v1, deliberately minimal)
//!
//! Only the `base` channel is used (`OpKind.batch`/`.frontier`; `.share` is
//! consumed by `Conn`, `.grant` is not implemented here — see above). No
//! feed channel (`base+1` presence, `base+2` diagnostics) and no request
//! channel (`base+3` blob/`.peer`-fs) are claimed; a graph quad still
//! reserves the full 4-wide slot (`Conn`'s `next_base` counter is shared
//! with text shares, so bases never collide either way), it just never
//! sends or answers anything on the other three.
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

const Session = @import("Session.zig");
const sync_core = @import("sync_core.zig");

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
    self.gpa.free(self.name);
}

/// Point at a fresh session after a reconnect: the announce + frontier
/// exchange replays from scratch (idempotent by design — duplicate
/// events are no-ops).
pub fn rebind(self: *GraphCollab, new_session: *Session) void {
    self.session = new_session;
    self.core.rebind(self.gpa);
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

/// Fold one inbound frame belonging to this quad's `base` channel. Every
/// other channel in the quad (presence/diagnostics/blob — unclaimed text-
/// doc machinery, see the module doc comment) and every non-`.op` class is
/// a no-op here; `false` either way (nothing changed).
pub fn handleFrame(self: *GraphCollab, frame: wire.Decoder.Decoded) !bool {
    if (frame.channel != self.base or frame.class != .op) return false;
    const gpa = self.gpa;
    switch (std.enums.fromInt(wire.OpKind, frame.kind) orelse return false) {
        .batch => {
            // Decode + frontier-track + admission gate: shared with the
            // text driver (`sync_core.SyncCore.admitBatch`). The merge
            // call itself stays here — `GraphDoc.merge` has no `Collab`-
            // style error-recovery branch to diverge on (see
            // `sync_core.zig`'s doc comment on why merge isn't shared).
            const batch = (try self.core.admitBatch(gpa, self.session, frame.payload)) orelse return false;
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
        // `.share` is connection-level (Conn consumes it); `.grant` has no
        // consumer yet — see the module doc comment.
        .share, .grant => return false,
    }
}

/// Announce once, then push whenever our head moved. Call after the
/// frames of a tick.
pub fn push(self: *GraphCollab) !bool {
    const live = self.session.liveness();
    if (live != .connected and live != .degraded) return false;

    const gpa = self.gpa;
    try self.core.announceOnce(gpa, self.session, self.base, self.doc);
    try self.core.pushOnMove(gpa, self.session, self.base, self.doc, false);
    return false;
}
