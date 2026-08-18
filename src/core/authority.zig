//! Authority — *who* is invoking, and *what grade* they hold. Every text
//! mutation carries a truthful author (a `Document.PeerId`) and is gated by
//! the invoker's grade on the document it targets. This is the CRDT-grant
//! half of the design's authority model: attribution + a grade gate, kept
//! separate from the host-capability half (fs/net/proc sandboxing).
//!
//! A `Principal` names the invoker but does NOT capture its peer id: the
//! peer is *resolved against the active document at edit time* (a command
//! can buffer-switch mid-flight, so a captured id would dangle). The grade
//! is likewise a per-document lookup, not a field — see `command.Context`.

const Document = @import("Document.zig");

/// The grant lattice: `view` < `edit` < `own`. Reuses the wire's `Access`
/// so there is exactly one definition of the grade concept — a peer's
/// admission grade on the wire and a principal's grade on a document are
/// the same thing, and cannot drift apart.
pub const Grade = @import("session.zig").Access;

/// The lower of two grades (`view` < `edit` < `own`) — a plugin's grade on
/// a document is `min(the user's grade, the plugin's ceiling)`, so a plugin
/// can never exceed the authority of the user it runs for.
pub fn gradeMin(a: Grade, b: Grade) Grade {
    return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
}

/// What kind of agent is invoking. `user` is the interactive peer (the
/// authoritative replica's own agent); the rest hold shadow replicas and
/// author as their own peer.
pub const Role = enum { user, plugin, agent, remote };

/// Who is invoking right now. Borrows `name` (for logs/attribution). For
/// non-`user` roles, `ctx`+`resolve` re-derive the invoker's peer against
/// whatever document is active at edit time.
pub const Principal = struct {
    role: Role = .user,
    name: []const u8 = "user",
    /// Opaque payload for `resolve` (the `*Plugin` for plugin/agent roles).
    ctx: ?*anyopaque = null,
    /// Resolve this principal's peer on `doc`. Null for the `user` role
    /// (which is always `PeerId.user`).
    resolve: ?*const fn (ctx: *anyopaque, doc: *Document) Document.AddPeerError!Document.PeerId = null,

    /// The default interactive user — the safe fallback every `Context`
    /// literal gets, so unadorned command dispatch authors as the user.
    pub const user: Principal = .{};

    /// This principal's peer on `doc`, resolved now (never captured).
    pub fn peerOn(self: Principal, doc: *Document) Document.AddPeerError!Document.PeerId {
        if (self.role == .user) return .user;
        return self.resolve.?(self.ctx.?, doc);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
