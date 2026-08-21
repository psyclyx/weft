//! The mode model (design §7, plan 02 P13) — there is no `nix-mode` object.
//! A buffer has *facts* (a `Resource`); independently-predicated
//! *contributions* each match those facts and stack. This module is the
//! reconcile engine: the pure mechanism that, on any fact change, diffs the
//! set of contributions that SHOULD be active against the set that IS, and
//! reports what to activate and what to deactivate — React-style. Every
//! contribution is reversible by construction (activate/deactivate are the
//! same declaration), which kills the two classic Emacs defects: add-only
//! mode hooks (irreversible) and load-order fragility (the result depends
//! only on the final declaration set, never the order it was built in).
//!
//! Predicates are host-evaluated DATA (ext / shebang / glob / tag / locus +
//! all/any/not) — O(contributions), no guest callback, no general
//! expression language (the footgun list refuses those). This same matcher
//! is what capability `fire`, keymap-layer activation, and fact resolution
//! all share.
//!
//! Mechanism only: the engine says WHAT changed; a caller applies the
//! effect (bind the keymap layer, attach the grammar, register the
//! provider). WHO contributes what is policy, declared elsewhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where a buffer's bytes live, first-class so predicates can gate on it
/// (an LSP activates only where files are real; a remote viewer consumes
/// results instead). Distinct from `locus.Tier` — this is the buffer-fact
/// vocabulary of §7 (`local|remote|tool|none`).
pub const Locality = enum { local, remote, tool, none };

/// The facts of one buffer, recomputed per buffer per replica. `Resource.of`
/// (the caller's job — it knows the buffer) fills this; the engine only
/// reads it. `first_line` is a bounded sniff (shebang/modeline), never the
/// whole file.
pub const Resource = struct {
    locality: Locality = .none,
    path: ?[]const u8 = null,
    name: []const u8 = "",
    first_line: []const u8 = "",
    tags: []const []const u8 = &.{},
    size: usize = 0,

    fn hasTag(self: Resource, tag: []const u8) bool {
        for (self.tags) |tg| if (std.mem.eql(u8, tg, tag)) return true;
        return false;
    }
};

/// A host-evaluated predicate over a `Resource`. Pure data — bounded work,
/// no callback. Generalizes the old `Provider.extensions` suffix match.
pub const Predicate = union(enum) {
    /// Path ends with this suffix (".rs", ".test.zig").
    ext: []const u8,
    /// `first_line` starts with `#!` and contains this substring.
    shebang: []const u8,
    /// Shell-style glob over `path` (`*` = any run, `?` = any one byte).
    glob: []const u8,
    /// The buffer carries this tag.
    tag: []const u8,
    /// The buffer's bytes live at this locality.
    locus: Locality,
    /// Every child matches.
    all: []const Predicate,
    /// Any child matches.
    any: []const Predicate,
    /// The child does not match.
    not: *const Predicate,

    pub fn matches(self: Predicate, r: Resource) bool {
        return switch (self) {
            .ext => |e| if (r.path) |p| std.mem.endsWith(u8, p, e) else false,
            .shebang => |s| std.mem.startsWith(u8, r.first_line, "#!") and
                std.mem.indexOf(u8, r.first_line, s) != null,
            .glob => |g| if (r.path) |p| globMatch(g, p) else false,
            .tag => |tg| r.hasTag(tg),
            .locus => |l| r.locality == l,
            .all => |kids| {
                for (kids) |k| if (!k.matches(r)) return false;
                return true;
            },
            .any => |kids| {
                for (kids) |k| if (k.matches(r)) return true;
                return false;
            },
            .not => |k| !k.matches(r),
        };
    }
};

/// What a contribution IS, for collision rules. `grammar` is the one
/// genuinely singular kind (a buffer parses with exactly one grammar —
/// first-wins by priority, and an exact priority tie is a hard error). The
/// rest STACK: they are total-ordered by `(priority, owner, id)` ([FIX 9]),
/// so they never collide — order is fully determined, never load-dependent.
pub const Kind = enum { keymap_layer, grammar, capability, facts };

/// A registered contribution: its predicate and the metadata the engine
/// needs. The actual payload (which layer, which grammar) is the caller's —
/// keyed by the returned `id`.
pub const Activation = struct {
    id: u32,
    predicate: Predicate,
    kind: Kind,
    priority: i32 = 0,
    /// Owner fingerprint — the final, total tie-breaker so ordering is
    /// deterministic even at equal priority across plugins.
    owner: [24]u8 = @splat(0),
};

pub const Error = error{ GrammarCollision, OutOfMemory };

/// The reconcile engine. Holds the declaration set and each buffer's active
/// set; `reconcile` diffs them.
pub const Engine = struct {
    activations: std.ArrayList(Activation) = .empty,
    /// buffer key (an opaque stable id — a buffer id or `@intFromPtr(doc)`)
    /// → the ids currently active on it (ascending).
    active: std.AutoHashMapUnmanaged(usize, std.ArrayList(u32)) = .empty,
    next_id: u32 = 1,

    pub const empty: Engine = .{};

    pub fn deinit(self: *Engine, gpa: Allocator) void {
        self.activations.deinit(gpa);
        var it = self.active.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.active.deinit(gpa);
        self.* = .{};
    }

    /// Declare a contribution. Returns its id (the caller maps it to the
    /// real payload). Order of declaration does not affect any reconcile.
    pub fn activate(self: *Engine, gpa: Allocator, a: Activation) Allocator.Error!u32 {
        const id = self.next_id;
        self.next_id += 1;
        var owned = a;
        owned.id = id;
        try self.activations.append(gpa, owned);
        return id;
    }

    /// Remove a contribution (plugin teardown). It vanishes from every
    /// buffer's active set on the next reconcile — reversibility for free.
    pub fn deactivate(self: *Engine, id: u32) void {
        for (self.activations.items, 0..) |a, i| {
            if (a.id == id) {
                _ = self.activations.swapRemove(i);
                return;
            }
        }
    }

    pub const Diff = struct {
        activated: []const u32,
        deactivated: []const u32,
    };

    /// Diff the contributions that SHOULD be active on `buf_key` (given its
    /// facts) against those that ARE, updating the stored active set and
    /// appending the delta to the caller's lists (ascending ids). The result
    /// depends ONLY on the current declaration set and `resource` — never on
    /// call history — so a plugin loading late retroactively applies with no
    /// reopen ritual. A `grammar` priority tie among matches is a hard error
    /// (the buffer cannot parse two ways at once).
    pub fn reconcile(
        self: *Engine,
        gpa: Allocator,
        buf_key: usize,
        resource: Resource,
        activated: *std.ArrayList(u32),
        deactivated: *std.ArrayList(u32),
    ) Error!void {
        // want = ids whose predicate matches (singular grammar collapsed to
        // its winner, which also enforces the no-tie rule).
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        try self.computeWant(gpa, resource, &want);
        std.mem.sort(u32, want.items, {}, std.sort.asc(u32));

        const gop = try self.active.getOrPut(gpa, buf_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const have = gop.value_ptr;

        // activated = want \ have; deactivated = have \ want.
        for (want.items) |w| {
            if (!contains(have.items, w)) try activated.append(gpa, w);
        }
        for (have.items) |h| {
            if (!contains(want.items, h)) try deactivated.append(gpa, h);
        }
        // The active set becomes want.
        have.clearRetainingCapacity();
        try have.appendSlice(gpa, want.items);
    }

    /// Drop a buffer's active set (buffer close). The caller should first
    /// reconcile against an empty want (or just deactivate everything it
    /// applied); this frees the bookkeeping.
    pub fn forget(self: *Engine, gpa: Allocator, buf_key: usize) void {
        if (self.active.fetchRemove(buf_key)) |kv| {
            var list = kv.value;
            list.deinit(gpa);
        }
    }

    fn computeWant(self: *Engine, gpa: Allocator, resource: Resource, want: *std.ArrayList(u32)) Error!void {
        // Singular grammar: pick the highest-priority match; an exact tie is
        // a collision. Everything else stacks.
        var best_grammar: ?Activation = null;
        var grammar_tie = false;
        for (self.activations.items) |a| {
            if (!a.predicate.matches(resource)) continue;
            if (a.kind == .grammar) {
                if (best_grammar) |b| {
                    if (a.priority > b.priority) {
                        best_grammar = a;
                        grammar_tie = false;
                    } else if (a.priority == b.priority) {
                        grammar_tie = true; // ambiguous winner
                    }
                } else best_grammar = a;
            } else {
                try want.append(gpa, a.id);
            }
        }
        if (best_grammar) |b| {
            if (grammar_tie) return error.GrammarCollision;
            try want.append(gpa, b.id);
        }
    }
};

/// Shared with `facts.zig` (W1): the merged-fact `Predicate.glob` case reuses
/// this exact algorithm rather than forking a second copy.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    // Iterative `*`/`?` glob with backtracking — O(len·len) worst case,
    // fine for paths; no regex engine (footgun rule: predicates stay data).
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;
    while (s < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[s])) {
            p += 1;
            s += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_s = s;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            star_s += 1;
            s = star_s;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "mode: predicates match resource facts and combinators" {
    const rs: Resource = .{ .locality = .local, .path = "src/main.rs", .name = "main.rs", .first_line = "#!/bin/sh\n", .tags = &.{ "vcs", "dirty" } };
    try t.expect((Predicate{ .ext = ".rs" }).matches(rs));
    try t.expect(!(Predicate{ .ext = ".zig" }).matches(rs));
    try t.expect((Predicate{ .tag = "dirty" }).matches(rs));
    try t.expect((Predicate{ .shebang = "sh" }).matches(rs));
    try t.expect((Predicate{ .locus = .local }).matches(rs));
    try t.expect((Predicate{ .glob = "src/*.rs" }).matches(rs));
    try t.expect(!(Predicate{ .glob = "test/*.rs" }).matches(rs));

    const not_zig: Predicate = .{ .ext = ".zig" };
    try t.expect((Predicate{ .not = &not_zig }).matches(rs));
    try t.expect((Predicate{ .all = &.{ .{ .ext = ".rs" }, .{ .tag = "vcs" } } }).matches(rs));
    try t.expect(!(Predicate{ .all = &.{ .{ .ext = ".rs" }, .{ .tag = "absent" } } }).matches(rs));
    try t.expect((Predicate{ .any = &.{ .{ .ext = ".zig" }, .{ .tag = "dirty" } } }).matches(rs));
}

test "mode: reconcile activates/deactivates by predicate, order-independent" {
    const gpa = t.allocator;
    var eng: Engine = .empty;
    defer eng.deinit(gpa);

    // Declared in a deliberately mixed order — the result must not care.
    const rust_layer = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .ext = ".rs" }, .kind = .keymap_layer, .priority = 10 });
    const any_cap = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .locus = .local }, .kind = .capability });
    const zig_layer = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .ext = ".zig" }, .kind = .keymap_layer, .priority = 10 });

    const buf: usize = 1;
    var act: std.ArrayList(u32) = .empty;
    defer act.deinit(gpa);
    var deact: std.ArrayList(u32) = .empty;
    defer deact.deinit(gpa);

    // Open a .rs local file: the rust layer + the local capability activate.
    try eng.reconcile(gpa, buf, .{ .locality = .local, .path = "a.rs" }, &act, &deact);
    try t.expectEqual(@as(usize, 2), act.items.len);
    try t.expect(contains(act.items, rust_layer) and contains(act.items, any_cap));
    try t.expectEqual(@as(usize, 0), deact.items.len);

    // Re-tag/rename it to a .zig REMOTE file: rust layer AND local cap
    // deactivate; zig layer activates. Pure diff — no reopen.
    act.clearRetainingCapacity();
    deact.clearRetainingCapacity();
    try eng.reconcile(gpa, buf, .{ .locality = .remote, .path = "a.zig" }, &act, &deact);
    try t.expect(contains(act.items, zig_layer));
    try t.expect(contains(deact.items, rust_layer) and contains(deact.items, any_cap));

    // Reconciling the SAME facts again is a no-op (nothing to change).
    act.clearRetainingCapacity();
    deact.clearRetainingCapacity();
    try eng.reconcile(gpa, buf, .{ .locality = .remote, .path = "a.zig" }, &act, &deact);
    try t.expectEqual(@as(usize, 0), act.items.len);
    try t.expectEqual(@as(usize, 0), deact.items.len);
}

test "mode: an equal-priority grammar collision is an error" {
    const gpa = t.allocator;
    var eng: Engine = .empty;
    defer eng.deinit(gpa);

    _ = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .ext = ".md" }, .kind = .grammar, .priority = 5 });
    _ = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .ext = ".md" }, .kind = .grammar, .priority = 5 });
    var act: std.ArrayList(u32) = .empty;
    defer act.deinit(gpa);
    var deact: std.ArrayList(u32) = .empty;
    defer deact.deinit(gpa);
    try t.expectError(error.GrammarCollision, eng.reconcile(gpa, 1, .{ .path = "x.md" }, &act, &deact));

    // A higher-priority grammar breaks the tie cleanly (first-wins).
    const win = try eng.activate(gpa, .{ .id = 0, .predicate = .{ .ext = ".md" }, .kind = .grammar, .priority = 9 });
    act.clearRetainingCapacity();
    try eng.reconcile(gpa, 2, .{ .path = "y.md" }, &act, &deact);
    try t.expect(contains(act.items, win));
}

fn contains(haystack: []const u32, needle: u32) bool {
    for (haystack) |x| if (x == needle) return true;
    return false;
}

test {
    std.testing.refAllDecls(@This());
}
