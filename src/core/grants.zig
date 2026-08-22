//! grants — the GRANT TABLE (north-star-plan §2.4, §6 W4 slice 1: "the
//! capture-time grant powerbox"). Read the plan section in full before
//! touching this file; this comment is the compressed version.
//!
//! **The shape, in one paragraph.** A `GrantDecl` is a declared authority
//! (`capability` name + `predicate` over `Facts` + a `limit`). A
//! `HandleTable` (owned by a `System`, see `System.zig`'s `grants` field) is
//! an APPEND-ONLY table of `Row`s — one row per (principal, capability) a
//! plugin's `describe()` handshake actually granted, minted at LOAD time
//! (`wasm_host/plugin.zig`'s `mintGrantHandles`). A `CapHandle` is a small
//! POD (`idx` + `gen`) naming one row — cheap to copy, cheap to compare,
//! cheap to invalidate. **Revocation is table invalidation**: flip `alive`
//! and bump `gen`, never mutate a live `CapHandle` anyone is holding — it
//! simply stops `check`ing true.
//!
//! **Two consumers, one table, no wallet.**
//!   1. **Use = possession** (`wasm_host/plugin.zig`'s `hasPerm`): a loaded
//!      plugin holds its OWN handles (`WasmPlugin.grant_handles`, minted
//!      once at load) and checks them directly at the point of use — no
//!      context-stack walk, no table scan, just `table.check(my_handle)`.
//!      This is what makes revoking a RUNNING plugin's fs perm take effect
//!      on its very next call: the plugin never re-reads a boolean, it
//!      re-checks the SAME row, which the revoke just flipped.
//!   2. **Capture-time resolution** (`ctx.zig`'s `Ctx.capture`): the
//!      OTHER consumer, for anything that wants "what can THIS interaction
//!      currently do" without being a plugin identity — `collectForPrincipal`
//!      scans the table for rows matching a principal + the captured facts
//!      and appends the matching handles into a caller-owned, bounded list
//!      (zero allocation — see `ctx.zig`'s `GrantList`). This is the
//!      capture-time powerbox itself: what rides `Ctx.grants` is exactly
//!      the rows eligible for THIS capture, never a wallet the receiving
//!      code could pick and choose from. STATUS: the table has two READERS,
//!      but consumer #2's RESULT has no production consumer yet — collected,
//!      tested, unconsumed (see `Ctx.grants`' field doc for the coupling
//!      rule its first consumer must honor). A swept scope's rows currently
//!      report `.revoked` — a future `scope_expired` Reason variant would
//!      be more precise once #8's structured taxonomy lands.
//!
//! **Scope lifetime** (§2.4: "a handle's lifetime is bounded by the scope
//! its GrantDecl matched"). A row MAY carry an owning `scope: ?u64` token
//! (`HandleTable.newScope`/a caller-chosen token like a transient's `depth`,
//! see `ctx.zig`'s `Ctx.grantScopedToTransient`); `sweepScope` invalidates
//! every row tagged with a given token — the scope-exit sweep. **Honest v1
//! scope of this mechanism**: every PRODUCTION grant today is plugin-
//! lifetime (minted at load, `scope = null`, swept only when the whole
//! table is torn down with its owning `System`) — `sweepScope` exists and is
//! tested (`ctx.zig`'s paired-transient test), but nothing production wires
//! a scoped grant yet. A manifest-authored `GrantDecl` verb (buffer/
//! transient-scoped grants a config or plugin can actually DECLARE) is a
//! later slice; this table is the machinery it will populate, not a stand-in
//! for it.
//!
//! **What's deliberately NOT here**: predicate-gated admission at USE time
//! (a row's `predicate`/`limit` are recorded and inspectable, but
//! `hasPerm`'s possession check does not currently evaluate them — the fs
//! semantic bodies check ONLY aliveness, per capability, exactly like the
//! boolean they replace); `Limit.fs_root` enforcement (the shape exists so a
//! later slice can start checking paths against it, `fs.zig`'s bodies don't
//! consult it yet); a config-authored `GrantDecl` verb. All three are named,
//! not silently dropped — see the north-star-plan §6 W4 report for the full
//! deferred list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");

pub const Facts = facts_mod.Facts;
pub const Predicate = facts_mod.Predicate;

/// A limit narrowing a grant (north-star-plan §2.4). `.none` = unrestricted
/// within the capability; `.fs_root` = confined to a subtree (the first REAL
/// limit shape — not yet enforced by any semantic body, see the module doc).
/// A tagged union, not a bare string, so a future limit kind (a doc-region
/// EventAnchor pair, a net host) is a new variant, never a stringly-typed
/// convention.
pub const Limit = union(enum) {
    none,
    fs_root: []const u8,
};

/// A declared grant: what a principal MAY hold for `capability`, gated by
/// `predicate` over the merged `Facts` a `Ctx` captures, narrowed by
/// `limit`. `predicate` defaults to "always matches" (`.all` over zero
/// children — `Predicate.matches`'s vacuous-truth case) because every
/// PRODUCTION decl today is the plugin-lifetime baseline (§2.4's
/// "manifest-static baseline... what the approval diff shows"): a loaded
/// plugin's fs grant holds everywhere it dispatches, not just in some fact
/// subset. A predicate-scoped decl (§2.4's identity-anchored doc limits, a
/// later slice) sets this explicitly.
pub const GrantDecl = struct {
    capability: []const u8,
    predicate: Predicate = .{ .all = &.{} },
    limit: Limit = .none,
};

/// Sentinel: no row (a handle that was never minted, or was defaulted).
const none_idx: u32 = std.math.maxInt(u32);

/// An index+generation into a `HandleTable` — the revocation point (§2.4).
/// Cheap POD: copy it anywhere (a plugin's own `grant_handles` array, a
/// `Ctx.grants` list) without touching the table. `check`ing a stale copy
/// against an invalidated row (`gen` bumped, `alive` cleared) fails —
/// exactly the "use = possession, revocation = invalidation" contract.
pub const CapHandle = struct {
    idx: u32 = none_idx,
    gen: u32 = 0,

    pub const none: CapHandle = .{};

    pub fn isNone(self: CapHandle) bool {
        return self.idx == none_idx;
    }
};

/// One granted row. `principal`/`capability` are BORROWED (the caller — the
/// plugin's own `name`, a `Perm.label()` — owns the backing memory for at
/// least the table's lifetime; every current caller passes `'static`-for-
/// practical-purposes strings: a plugin's `name` field, a perm-enum literal
/// label). `scope`, `null` for a plugin-lifetime row, names the owning scope
/// token a `sweepScope` call invalidates by (see the module doc).
pub const Row = struct {
    principal: []const u8,
    capability: []const u8,
    predicate: Predicate,
    limit: Limit,
    gen: u32 = 0,
    alive: bool = true,
    scope: ?u64 = null,
};

/// Why a handle fails `check` — the trap-message distinction §6 W4 asks for
/// ("revoked" vs "never requested"), and the groundwork for #8's structured
/// deny-trap reasons.
pub const Reason = enum { ok, never_granted, revoked };

/// The System-owned grant table (§2.4's "resolves the principal's
/// GrantDecls" mechanism; see `System.zig`'s `grants` field). Append-only:
/// rows are never removed or reordered, so a `CapHandle.idx` stays valid to
/// look up for the table's whole lifetime — only `alive`/`gen` change. Rows
/// live in a plain `ArrayList` (not individually heap-allocated): nothing
/// outside this file ever holds a raw `*Row`, only `CapHandle`s, so an
/// internal reallocation on grant/append never invalidates anything a
/// caller holds.
pub const HandleTable = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    next_scope: u64 = 1,

    pub fn init(gpa: Allocator) HandleTable {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HandleTable) void {
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    /// Mint a new row for `principal`/`decl`, optionally scoped. This is the
    /// ONLY way a row is created — there is no "re-grant the same slot"; a
    /// second `grant` for the same (principal, capability) is a SEPARATE
    /// row (harmless: `hasPerm`'s possession check holds whichever handle
    /// it was given; `revoke` invalidates every matching row, not just one).
    pub fn grant(self: *HandleTable, decl: GrantDecl, principal: []const u8, scope: ?u64) !CapHandle {
        const idx: u32 = @intCast(self.rows.items.len);
        try self.rows.append(self.gpa, .{
            .principal = principal,
            .capability = decl.capability,
            .predicate = decl.predicate,
            .limit = decl.limit,
            .scope = scope,
        });
        return .{ .idx = idx, .gen = 0 };
    }

    /// The possession check (§2.4 "use = possession"): is `h` a live row?
    /// O(1), no allocation, no principal/predicate re-evaluation — a
    /// possessed handle is checked, not re-resolved.
    pub fn check(self: *const HandleTable, h: CapHandle) bool {
        if (h.isNone() or h.idx >= self.rows.items.len) return false;
        const r = self.rows.items[h.idx];
        return r.alive and r.gen == h.gen;
    }

    /// Why `h` fails `check` (or `.ok` if it wouldn't) — the trap-message
    /// distinction (§6 W4 gate: "distinct from never-granted").
    pub fn reasonFor(self: *const HandleTable, h: CapHandle) Reason {
        if (h.isNone() or h.idx >= self.rows.items.len) return .never_granted;
        const r = self.rows.items[h.idx];
        if (r.alive and r.gen == h.gen) return .ok;
        return .revoked;
    }

    /// Invalidate every LIVE row for (principal, capability) — the
    /// revocation point. Bumps `gen` in addition to clearing `alive`
    /// (belt-and-suspenders: rows are never reused in v1, so `alive` alone
    /// already suffices, but a future slot-reuse scheme can't accidentally
    /// re-validate a stale handle whose `gen` this already moved past).
    /// Returns how many rows were invalidated (0 = no match: a typo'd name,
    /// an already-revoked capability, or a principal that never held it).
    pub fn revoke(self: *HandleTable, principal: []const u8, capability: []const u8) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (r.alive and std.mem.eql(u8, r.principal, principal) and std.mem.eql(u8, r.capability, capability)) {
                r.alive = false;
                r.gen +%= 1;
                n += 1;
            }
        }
        return n;
    }

    /// Mint a fresh scope token (monotonic, never reused within one table's
    /// lifetime) for a caller that wants to bind a grant's lifetime to
    /// something other than "the plugin's whole load-to-unload span" — see
    /// `ctx.zig`'s scope-lifetime test for the worked example.
    pub fn newScope(self: *HandleTable) u64 {
        defer self.next_scope += 1;
        return self.next_scope;
    }

    /// The scope-exit sweep (§2.4: "scope exit revokes; a stashed handle
    /// from a dead Ctx traps"). Invalidates every LIVE row tagged with
    /// `scope`. Returns the count invalidated (0 is ordinary: most scopes
    /// never had a grant bound to them).
    pub fn sweepScope(self: *HandleTable, scope: u64) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (r.alive and r.scope != null and r.scope.? == scope) {
                r.alive = false;
                r.gen +%= 1;
                n += 1;
            }
        }
        return n;
    }

    /// CAPTURE-TIME resolution (§2.4's powerbox, the no-wallet rule): collect
    /// every LIVE row belonging to `principal` whose predicate holds against
    /// `facts`, appending each as a `CapHandle` into `out`. Zero allocation —
    /// this only ever READS `self.rows` (never grown/shrunk by a capture) and
    /// writes into the caller-owned `out`, which must expose an `append(CapHandle)
    /// void`-ish method (`ctx.zig`'s bounded `GrantList`, or a test double).
    /// `out` never sees the rows it DOESN'T match — there is no wallet to
    /// choose from, only what capture resolved.
    pub fn collectForPrincipal(self: *const HandleTable, principal: []const u8, facts: Facts, out: anytype) void {
        for (self.rows.items, 0..) |r, i| {
            if (!r.alive) continue;
            if (!std.mem.eql(u8, r.principal, principal)) continue;
            if (!r.predicate.matches(facts)) continue;
            out.append(.{ .idx = @as(u32, @intCast(i)), .gen = r.gen });
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "grants: grant/check/revoke — the possession + invalidation contract" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const h = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    try t.expect(table.check(h));
    try t.expectEqual(Reason.ok, table.reasonFor(h));

    // A handle that was never minted (CapHandle.none) is never-granted, not
    // revoked — the message-distinction gate.
    try t.expectEqual(Reason.never_granted, table.reasonFor(.none));

    const n = table.revoke("notes", "fs_read");
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(!table.check(h));
    try t.expectEqual(Reason.revoked, table.reasonFor(h));

    // Revoking again — nothing left to invalidate.
    try t.expectEqual(@as(usize, 0), table.revoke("notes", "fs_read"));

    // A DIFFERENT principal's identically-named capability is untouched.
    const h2 = try table.grant(.{ .capability = "fs_read" }, "vim", null);
    try t.expect(table.check(h2));
}

test "grants: revoke narrows to the exact (principal, capability) pair" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const read = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    const write = try table.grant(.{ .capability = "fs_write" }, "notes", null);
    _ = table.revoke("notes", "fs_write");
    try t.expect(table.check(read)); // sibling capability unaffected
    try t.expect(!table.check(write));
}

test "grants: scope sweep invalidates only rows tagged with that scope" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const plugin_lifetime = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    const scope = table.newScope();
    const transient = try table.grant(.{ .capability = "doc.edit" }, "notes", scope);

    try t.expect(table.check(plugin_lifetime));
    try t.expect(table.check(transient));

    const n = table.sweepScope(scope);
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(table.check(plugin_lifetime)); // plugin-lifetime row untouched
    try t.expect(!table.check(transient)); // scoped row died with its scope

    // Sweeping an already-swept (or unused) scope is a harmless no-op.
    try t.expectEqual(@as(usize, 0), table.sweepScope(scope));
}

test "grants: collectForPrincipal — capture-time resolution, predicate-gated, no cross-principal leak" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    _ = try table.grant(.{ .capability = "fs_read" }, "notes", null); // always matches
    _ = try table.grant(.{ .capability = "doc.edit", .predicate = .{ .mode = "insert" } }, "notes", null);
    _ = try table.grant(.{ .capability = "fs_read" }, "vim", null); // different principal

    const Out = struct {
        items: [8]CapHandle = undefined,
        len: usize = 0,
        pub fn append(self: *@This(), h: CapHandle) void {
            self.items[self.len] = h;
            self.len += 1;
        }
    };
    var out: Out = .{};
    table.collectForPrincipal("notes", .{ .mode = "normal" }, &out);
    try t.expectEqual(@as(usize, 1), out.len); // only the always-matching row — insert-mode one doesn't hold in "normal"

    out = .{};
    table.collectForPrincipal("notes", .{ .mode = "insert" }, &out);
    try t.expectEqual(@as(usize, 2), out.len); // both notes rows now match

    out = .{};
    table.collectForPrincipal("ghost", .{ .mode = "insert" }, &out);
    try t.expectEqual(@as(usize, 0), out.len); // no such principal — never leaks vim's or notes's rows
}

test {
    std.testing.refAllDecls(@This());
}
