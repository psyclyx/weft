//! `SyncCore` — the doc-agnostic sync core shared by `Collab` (TextDoc) and
//! `GraphCollab` (GraphDoc), lifted out after a review (stemma delta 5,
//! doc/substrate.md) found `GraphCollab` had
//! reimplemented seven blocks byte-identical to `Collab`: frontier
//! tracking, announce-once, push-on-move, the batch/frontier WIRE FRAMING
//! (encode + decode), batch decode + the view-peer admission gate, the
//! `.frontier` handler, and the frontier-reset subset of `rebind`. That is
//! the drift hazard the one-implementation doctrine exists for: a protocol
//! fix (a gate-point change, a retransmit tweak, a frontier-comparison
//! correction) landing in one driver and not the other.
//!
//! ## What's IN here vs what stays in each driver
//!
//! Only the parts that are ALREADY textually and semantically identical
//! between the two drivers: frontier state + its wire framing. Both
//! `Document` and `GraphDoc` already share the exact method names this
//! needs (`version`/`eventsSince`/`serialize` — see `graph.zig`'s own doc
//! comment: deliberately mirrored so the token model lines up), so `Doc`
//! is used structurally — no vtable struct, no per-type adapter.
//!
//! The actual MERGE call is deliberately NOT here, even though it could be
//! forced into a normalized `fn(*Doc, Allocator, []const u8) !bool` shape
//! (`GraphDoc.merge`'s `[]Change` via `len > 0`; `Document.mergeRemote`
//! already returns `bool`). `Collab`'s merge path has a real per-driver
//! branch that needs context this core doesn't have: on
//! `error.Unrealized` it stashes the batch into `self.partial` (a
//! `Collab`-only field) instead of logging a rejection. Forcing that
//! through a normalized vtable would either lose the recovery path or
//! require threading extra opaque context through a generic that's
//! supposed to be doc-agnostic — the same call the driver split makes for
//! presence/diagnostics/blob/partial. So `admitBatch` below does exactly
//! the part that WAS duplicated (decode the frame, track the frontier,
//! enforce the admission gate) and hands the caller the batch bytes to
//! merge; the merge call and its error recovery stay put.
//!
//! The one place a driver-only concept (`Collab`'s partial-checkout) still
//! touches the shared framing is the "don't bootstrap a partial client
//! with a full serialize" guard — threaded through as a plain `skip: bool`
//! computed by the caller, so `SyncCore` never has to know `PartialDoc`
//! exists.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const Session = @import("Session.zig");
const grants = @import("../grants.zig");

/// What the singular replica-op admission point decided about one `.batch`
/// frame. `.idle` (a corrupt or empty payload) is deliberately NOT spelled
/// the same as `.refused`: nothing was denied, there was simply nothing to
/// merge, and collapsing the two would hand every driver a "refused" it
/// would have to guess the meaning of.
pub const Admission = union(enum) {
    /// Authorized: merge these bytes.
    merge: []const u8,
    /// Nothing to do — not a refusal.
    idle,
    /// Denied by authority, with the reason the enforcement point decided.
    refused: grants.Reason,
};

/// `Doc` need only provide `version(*const Doc, Allocator) E![]u8`,
/// `eventsSince(*const Doc, Allocator, []const u8) E![]u8`, and
/// `serialize(*const Doc, Allocator) E![]u8` — the shared token model
/// `Document` and `GraphDoc` already speak (see this file's doc comment).
pub fn SyncCore(comptime Doc: type) type {
    return struct {
        their_frontier: ?[]u8 = null,
        last_sent_version: ?[]u8 = null,
        announced: bool = false,

        const Self = @This();

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.their_frontier) |f| gpa.free(f);
            if (self.last_sent_version) |v| gpa.free(v);
        }

        /// The frontier-reset subset of a reconnect rebind: the announce +
        /// frontier exchange replays from scratch (idempotent by design —
        /// duplicate events are no-ops). Callers reset their own
        /// additional state (presence, grant re-announce flags, …) around
        /// this.
        pub fn rebind(self: *Self, gpa: Allocator) void {
            self.announced = false;
            if (self.their_frontier) |f| gpa.free(f);
            self.their_frontier = null;
            if (self.last_sent_version) |v| gpa.free(v);
            self.last_sent_version = null;
        }

        pub fn setTheirFrontier(self: *Self, gpa: Allocator, token: []const u8) !void {
            if (self.their_frontier) |f| gpa.free(f);
            self.their_frontier = try gpa.dupe(u8, token);
        }

        /// Announce our frontier once (idempotent — safe to call every
        /// push).
        pub fn announceOnce(self: *Self, gpa: Allocator, session: *Session, base: u64, doc: *Doc) !void {
            if (self.announced) return;
            self.announced = true;
            const v = try doc.version(gpa);
            defer gpa.free(v);
            try session.post(.op, @intFromEnum(wire.OpKind.frontier), base, v);
        }

        /// The wire framing shared by both drivers: everything the peer
        /// lacks (their frontier, or the whole history when unknown — an
        /// empty joiner's bootstrap), prefixed with our frontier.
        /// Duplicates on their side are no-ops — retransmit-safe. `skip`
        /// is a caller-computed escape hatch for `Collab`'s partial-
        /// checkout guard ("don't serialize a full bootstrap to a partial
        /// client before its base is adopted") — always `false` for a
        /// driver with no such concept.
        pub fn sendBatch(self: *Self, gpa: Allocator, session: *Session, base: u64, doc: *Doc, skip: bool) !void {
            if (skip) return;
            const head = try doc.version(gpa);
            errdefer gpa.free(head);
            const batch = if (self.their_frontier) |f|
                try doc.eventsSince(gpa, f)
            else
                try doc.serialize(gpa);
            defer gpa.free(batch);

            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(gpa);
            try wire.putUv(gpa, &payload, head.len);
            try payload.appendSlice(gpa, head);
            try payload.appendSlice(gpa, batch);
            try session.post(.op, @intFromEnum(wire.OpKind.batch), base, payload.items);

            if (self.last_sent_version) |v| gpa.free(v);
            self.last_sent_version = head;
        }

        /// Push whenever our head moved since the last send. Same `skip`
        /// contract as `sendBatch`.
        pub fn pushOnMove(self: *Self, gpa: Allocator, session: *Session, base: u64, doc: *Doc, skip: bool) !void {
            const head = try doc.version(gpa);
            defer gpa.free(head);
            const moved = self.last_sent_version == null or !std.mem.eql(u8, self.last_sent_version.?, head);
            if (moved) try self.sendBatch(gpa, session, base, doc, skip);
        }

        /// Decode + admit a `.batch` frame payload (`uv token_len | token
        /// | batch`): records `token` as `their_frontier` (tracked even
        /// for a refused peer, so frontier resync keeps working), then
        /// asks `Session.authorize` whether the sender may write this
        /// publication's replica. **This is the singular replica-op
        /// enforcement point** — both drivers reach it, and it is the only
        /// place a remote op is admitted, which is why the per-export
        /// re-key happened HERE rather than growing a second gate beside
        /// it. It re-decides on EVERY frame, so a revoke (or an epoch
        /// advance) lands on the next frame of an already-flowing stream:
        /// frame granularity is the honest in-flight check a batched
        /// protocol has.
        ///
        /// The merge call itself (and any doc-specific error recovery)
        /// stays with the caller — see this file's doc comment on why
        /// `merge` isn't part of the core.
        pub fn admitBatch(
            self: *Self,
            gpa: Allocator,
            session: *Session,
            publication: grants.PublicationRef,
            payload: []const u8,
        ) !Admission {
            var cur: []const u8 = payload;
            const tlen = wire.getUv(&cur) catch return .idle;
            if (tlen > cur.len) return .idle;
            const token = cur[0..tlen];
            const batch = cur[tlen..];
            try self.setTheirFrontier(gpa, token);
            // Emptiness is checked BEFORE authority on purpose: a peer that
            // merely echoes its frontier (every read-only peer, on every
            // merge) is carrying no op to admit, and calling that an
            // authority refusal would turn ordinary sync traffic into a
            // stream of violations. Nothing is weakened — a batch with any
            // op in it still goes through `authorize`.
            if (batch.len == 0) return .idle;
            const verdict = session.authorize(publication, .replica_write);
            if (verdict != .ok) return .{ .refused = verdict };
            return .{ .merge = batch };
        }
    };
}
