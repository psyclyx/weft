//! Place — WHERE an effect runs.
//!
//! `locus.zig` states the rule this module exists to honour (R1): "a path or
//! handle is meaningless on its own; it means something only paired with the
//! locus that hosts it." Everything that spawns a child, opens a relative
//! name, or asks a language server about a workspace needs an answer to
//! "where", and until this type existed the only answer available was
//! `getcwd()` — one process-wide value, fixed at launch, that no interaction
//! could vary. See `doc/place.md`.
//!
//! A place is `(locus, container)` and NOTHING ELSE. In particular it does not
//! carry an environment: an environment is a property RESOLVED FOR a place
//! (revision-stamped, provider-published), not a component of it. If it were a
//! component, a `direnv reload` — which changes only the environment — would
//! change the place's identity, orphaning every session linked to it and every
//! entry that inherited it. Identity must be stable while what is true at that
//! identity moves.
//!
//! ## The degenerate case is an instance, not a bypass
//!
//! `.process` — the editor's own directory — is an ORDINARY value in this
//! space, the way `Locus.here` is an ordinary locus. Today's behaviour is
//! therefore the degenerate INSTANCE of the general rule rather than an escape
//! from it, which is what lets consumers stop carrying a "…or fall back to
//! cwd" branch. It is `.here` by construction: a process has exactly one
//! working directory, so pairing `.process` with a remote locus is not a state
//! this type can represent.

const std = @import("std");

const locus_mod = @import("locus.zig");
const semantic = @import("weft_semantic");

pub const Locus = locus_mod.Locus;

/// Where an effect runs. Compare with `eql`, never with `==` on the whole
/// value — see `Container.revision` for why.
pub const Place = union(enum) {
    /// The editor process's own directory. Always `.here`: a process has one
    /// working directory, so this arm carries no locus field rather than
    /// carrying one that could be set wrong.
    process,
    /// A container published by a target authority, on some locus.
    container: Container,

    pub const Container = struct {
        locus: Locus,
        /// The published container. `semantic.target.Ref` is a generation-
        /// checked handle, so a retired target's ref stops resolving on its
        /// own — staleness of the TARGET needs no extra bookkeeping here.
        ref: semantic.target.Ref,
        /// The descriptor revision observed when this place was taken.
        ///
        /// Carried so a consumer can notice that the publisher REPLACED the
        /// descriptor underneath it (the lazy-clear rule
        /// `semantic.Services.workingTarget` applies). It is deliberately NOT
        /// part of identity — see `eql`. Two places naming the same container
        /// at different revisions are the SAME place, so republishing a
        /// directory never orphans the sessions, entries, or environment
        /// overlays linked to it.
        revision: u64,
    };

    /// The locus this place is on. `.process` is `.here` by construction.
    pub fn locus(self: Place) Locus {
        return switch (self) {
            .process => .here,
            .container => |c| c.locus,
        };
    }

    /// Identity comparison: locus and container ref, NEVER revision.
    ///
    /// This is the whole reason `Place` has a named comparison instead of
    /// relying on structural equality. A republished descriptor bumps
    /// `revision` while naming the same container; if that counted as a
    /// different place, every session link and environment overlay keyed on it
    /// would silently detach on an ordinary refresh.
    pub fn eql(self: Place, other: Place) bool {
        return switch (self) {
            .process => other == .process,
            .container => |a| switch (other) {
                .process => false,
                .container => |b| a.locus == b.locus and a.ref.eql(b.ref),
            },
        };
    }

    /// Whether this place is the editor's own directory.
    pub fn isProcess(self: Place) bool {
        return self == .process;
    }

    /// Whether this place is on the local process's own machine. A `false`
    /// here is the signal that a local-only effect (`chdir`, an OS path) must
    /// REFUSE rather than silently act somewhere else.
    pub fn isHere(self: Place) bool {
        return self.locus() == .here;
    }
};

/// Dense, opaque ids for places, so a guest can tell two places apart without
/// being handed either one.
///
/// A session table wants to answer "is this slot's place the place I am in?"
/// and nothing more. Answering it with the place's DIRECTORY would put a raw
/// path back in every plugin that keeps sessions — the exact spelling this
/// design removes, and one that cannot name a peer or synthetic container
/// anyway. So the guest gets an integer with the same contract `Locus` states
/// for itself: compare for equality, never interpret.
///
/// Ids are stable for the life of a run and dense from zero, which is what
/// makes them cheap to key a small fixed table on. They are NOT durable across
/// runs — a place that must survive a restart is serialized as its `weft://`
/// designation, not as one of these.
pub const Ids = struct {
    gpa: std.mem.Allocator,
    /// Index IS the id. Entry 0 is always `.process`, so the degenerate place
    /// needs no lookup and no special case at the membrane.
    seen: std.ArrayList(Place) = .empty,

    pub const process_id: u32 = 0;

    pub fn init(gpa: std.mem.Allocator) !Ids {
        var self: Ids = .{ .gpa = gpa };
        try self.seen.append(gpa, .process);
        return self;
    }

    pub fn deinit(self: *Ids) void {
        self.seen.deinit(self.gpa);
        self.* = undefined;
    }

    /// This place's id, minting one if it is new. Interning by `eql` — which
    /// ignores the descriptor revision — is what makes an id survive a
    /// republish: a session linked to a directory stays linked to it when its
    /// publisher refreshes the descriptor underneath.
    pub fn idOf(self: *Ids, p: Place) u32 {
        for (self.seen.items, 0..) |known, i| {
            if (known.eql(p)) return @intCast(i);
        }
        self.seen.append(self.gpa, p) catch return process_id; // degrade, never fail a dispatch
        return @intCast(self.seen.items.len - 1);
    }
};

/// What a LOCAL effect gets when it asks a place to become bytes.
///
/// Four arms, because the honest answers are four. Collapsing `elsewhere` or
/// `unavailable` into "no cwd" would be the whole bug this design exists to
/// prevent: a child that cannot run where it was asked to must REFUSE, not
/// quietly run in the editor's launch directory and report success.
pub const Realized = union(enum) {
    /// The editor process's own directory. A spawn passes no cwd — which is
    /// not a fallback, it is precisely correct for this place.
    process,
    /// An absolute directory path, BORROWED for the duration of the call. The
    /// authority that opened the root owns these bytes; nothing may retain
    /// them past the call, and they never cross the guest membrane.
    path: []const u8,
    /// The place is real but is not on this machine (a peer or shell locus).
    /// A local child cannot run there. Callers refuse.
    elsewhere,
    /// The container could not be resolved: retired, or no authority is wired
    /// to answer for it. Callers refuse.
    unavailable,
};

/// Turns a place into an OS directory, host-side.
///
/// A seam rather than a function because core must not invent path joining:
/// the authority that opened a root is the only party entitled to say what it
/// is called, exactly as `app/session.zig`'s activation gate already insists
/// ("the path is reconstructed from a root this session itself opened, so a
/// plugin's opaque target never becomes an arbitrary path").
///
/// Deliberately has no guest-facing door. Realization exists so the HOST can
/// hand a child its working directory; a plugin that could call it would be
/// holding a raw path again, which is the state this whole design removes.
pub const Realizer = struct {
    ctx: *anyopaque,
    realizeFn: *const fn (ctx: *anyopaque, p: Place) ?[]const u8,

    pub fn realize(self: Realizer, p: Place) ?[]const u8 {
        return self.realizeFn(self.ctx, p);
    }
};

/// Resolve `p` for a local effect. `realizer` may be null (headless, or before
/// the shell has wired one), in which case only the degenerate place resolves
/// — everything else is honestly `unavailable` rather than silently local.
pub fn realize(p: Place, realizer: ?Realizer) Realized {
    switch (p) {
        .process => return .process,
        .container => |c| {
            if (c.locus != .here) return .elsewhere;
            const r = realizer orelse return .unavailable;
            const path = r.realize(p) orelse return .unavailable;
            return .{ .path = path };
        },
    }
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn ref(slot: u32, generation: u32) semantic.target.Ref {
    return .{ .authority = .here, .slot = slot, .generation = generation };
}

test "place: the degenerate instance is here by construction" {
    const p: Place = .process;
    try t.expect(p.isProcess());
    try t.expect(p.isHere());
    try t.expectEqual(Locus.here, p.locus());
}

test "place: identity ignores descriptor revision" {
    // The load-bearing property: a publisher replacing its descriptor must not
    // detach anything keyed on the place (doc/place.md §2).
    const a: Place = .{ .container = .{ .locus = .here, .ref = ref(3, 1), .revision = 7 } };
    const b: Place = .{ .container = .{ .locus = .here, .ref = ref(3, 1), .revision = 9 } };
    try t.expect(a.eql(b));
    try t.expect(b.eql(a));
}

test "place: identity distinguishes container, generation, and locus" {
    const base: Place = .{ .container = .{ .locus = .here, .ref = ref(3, 1), .revision = 1 } };

    // A different slot is a different container.
    try t.expect(!base.eql(.{ .container = .{ .locus = .here, .ref = ref(4, 1), .revision = 1 } }));
    // A reused slot at a new generation is NOT the old container.
    try t.expect(!base.eql(.{ .container = .{ .locus = .here, .ref = ref(3, 2), .revision = 1 } }));
    // The same ref on another locus is another place entirely (rule R1).
    const elsewhere: Locus = @enumFromInt(1);
    try t.expect(!base.eql(.{ .container = .{ .locus = elsewhere, .ref = ref(3, 1), .revision = 1 } }));
}

test "place: the process place is never equal to a container place" {
    const p: Place = .process;
    const c: Place = .{ .container = .{ .locus = .here, .ref = ref(1, 1), .revision = 1 } };
    try t.expect(!p.eql(c));
    try t.expect(!c.eql(p));
}

test "place: a non-here container reports it is not local" {
    const elsewhere: Locus = @enumFromInt(1);
    const c: Place = .{ .container = .{ .locus = elsewhere, .ref = ref(1, 1), .revision = 1 } };
    try t.expect(!c.isHere());
    try t.expect(!c.isProcess());
}

test {
    std.testing.refAllDecls(@This());
}

// ── realization ─────────────────────────────────────────────────────

const FakeAuthority = struct {
    answer: ?[]const u8,
    asked: usize = 0,

    fn realize(ctx: *anyopaque, _: Place) ?[]const u8 {
        const self: *FakeAuthority = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        return self.answer;
    }

    fn realizer(self: *FakeAuthority) Realizer {
        return .{ .ctx = self, .realizeFn = FakeAuthority.realize };
    }
};

test "place: the degenerate place realizes to `process`, never asking an authority" {
    var auth: FakeAuthority = .{ .answer = "/should/not/be/asked" };
    const r = realize(.process, auth.realizer());
    try t.expectEqual(Realized.process, r);
    // The process place is answered by construction; consulting a target
    // authority for it would be inventing a question it cannot have.
    try t.expectEqual(@as(usize, 0), auth.asked);
}

test "place: a local container realizes through its authority" {
    var auth: FakeAuthority = .{ .answer = "/home/u/proj" };
    const p: Place = .{ .container = .{ .locus = .here, .ref = ref(1, 1), .revision = 1 } };
    switch (realize(p, auth.realizer())) {
        .path => |got| try t.expectEqualStrings("/home/u/proj", got),
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(usize, 1), auth.asked);
}

test "place: a non-here container is `elsewhere` and is never asked locally" {
    var auth: FakeAuthority = .{ .answer = "/home/u/proj" };
    const elsewhere_locus: Locus = @enumFromInt(1);
    const p: Place = .{ .container = .{ .locus = elsewhere_locus, .ref = ref(1, 1), .revision = 1 } };
    try t.expectEqual(Realized.elsewhere, realize(p, auth.realizer()));
    // Critically NOT `.process`: falling back to the editor's own directory is
    // how a child ends up silently acting on the wrong machine's files.
    try t.expectEqual(@as(usize, 0), auth.asked);
}

test "place: an unresolvable container is unavailable, with or without an authority" {
    const p: Place = .{ .container = .{ .locus = .here, .ref = ref(1, 1), .revision = 1 } };
    // No authority wired at all (headless, or pre-wiring).
    try t.expectEqual(Realized.unavailable, realize(p, null));
    // An authority that cannot answer for this container (retired).
    var auth: FakeAuthority = .{ .answer = null };
    try t.expectEqual(Realized.unavailable, realize(p, auth.realizer()));
    try t.expectEqual(@as(usize, 1), auth.asked);
}

// ── ids ─────────────────────────────────────────────────────────────

test "place: the degenerate place is id 0, without a lookup" {
    var ids = try Ids.init(t.allocator);
    defer ids.deinit();
    try t.expectEqual(Ids.process_id, ids.idOf(.process));
    try t.expectEqual(@as(usize, 1), ids.seen.items.len); // nothing minted
}

test "place: ids are stable, dense, and distinct per place" {
    var ids = try Ids.init(t.allocator);
    defer ids.deinit();
    const a: Place = .{ .container = .{ .locus = .here, .ref = ref(1, 1), .revision = 1 } };
    const b: Place = .{ .container = .{ .locus = .here, .ref = ref(2, 1), .revision = 1 } };

    const id_a = ids.idOf(a);
    const id_b = ids.idOf(b);
    try t.expect(id_a != id_b);
    try t.expect(id_a != Ids.process_id and id_b != Ids.process_id);
    // Stable: asking again is the same answer, not a new id.
    try t.expectEqual(id_a, ids.idOf(a));
    try t.expectEqual(id_b, ids.idOf(b));
    try t.expectEqual(@as(usize, 3), ids.seen.items.len); // process + two
}

test "place: a republished descriptor keeps its id" {
    var ids = try Ids.init(t.allocator);
    defer ids.deinit();
    const before: Place = .{ .container = .{ .locus = .here, .ref = ref(7, 1), .revision = 1 } };
    const after: Place = .{ .container = .{ .locus = .here, .ref = ref(7, 1), .revision = 99 } };
    // The load-bearing property for session links: a publisher refreshing its
    // descriptor must not detach the sessions linked to that place.
    try t.expectEqual(ids.idOf(before), ids.idOf(after));
    try t.expectEqual(@as(usize, 2), ids.seen.items.len);
}
