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
