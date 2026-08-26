//! Facts — the merged context vocabulary the Container resolves against
//! (doc/cwa-prior-docs-audit.md §5). `Facts` is the union of two vocabularies
//! that used to live in separate, incompatible predicate systems:
//!
//!   - the buffer-resource axis (`mode.zig`'s `Resource`: ext/shebang/glob
//!     over `path`, `tags`, `locus`) — dead code today, zero consumers, but
//!     the right shape;
//!   - the interaction axis (`action.zig`'s `When`/`Ctx`: `mode`, `lang`,
//!     `tool`) — live code, the thing actually gating action dispatch.
//!
//! `Predicate` is `mode.zig`'s `{ext,shebang,glob,tag,locus,all,any,not}`
//! vocabulary plus `{mode,tool,lang}`, evaluated over `Facts` instead of the
//! narrower `Resource` — so a cross-axis conjunction (`mode=normal AND
//! ext=.nix`) is an ORDINARY predicate, not something a single-scope matcher
//! has no home for. This is the repair review finding A1/C-F5 asked for
//! (doc/cwa-prior-docs-audit.md §5): the old single-scope eligibility made cross-axis
//! predicates inexpressible, which is what forced scope-depth dominance,
//! which is what resurrected [FIX 5]'s bug. There is no scope concept here
//! at all — see container.zig's total order for why that is load-bearing,
//! not an omission.
//!
//! `lang` follows `action.langOfName`'s exact semantics (an extension sans
//! dot, computed by the CALLER and placed into `Facts.lang`) — this module
//! does not re-derive it from `path`, so adapters must preserve whatever
//! computation callers relied on before (action.zig does; `.lang` predicates
//! never re-run `langOfName` themselves).
//!
//! Host-evaluated, pure data, O(predicate size), no callback — the same
//! footgun-list discipline `mode.zig` documents.

const std = @import("std");
const mode = @import("mode.zig");

/// Reused from `mode.zig` rather than redeclared: one enum, not two
/// structurally-identical-but-nominally-distinct types drifting apart.
pub const Locality = mode.Locality;

/// The merged fact set a `Predicate` matches against. Buffer-resource facts
/// default to "no information" (`.none`/null/empty); interaction facts
/// default to `""` (mirrors `action.Ctx`'s "" = don't-care/absent convention,
/// so an adapter that only fills a subset of `Facts` — e.g. capability's
/// path-only query — still matches exactly the predicates it should).
pub const Facts = struct {
    locality: Locality = .none,
    path: ?[]const u8 = null,
    name: []const u8 = "",
    first_line: []const u8 = "",
    tags: []const []const u8 = &.{},
    size: usize = 0,
    /// Keymap mode ("normal", "insert", "dired", ...).
    mode: []const u8 = "",
    /// Buffer language: an extension sans dot, `action.langOfName`'s output.
    lang: []const u8 = "",
    /// The active buffer's tool-backing identity, or "" when not a
    /// projection (`action.Ctx.tool`'s exact convention).
    tool: []const u8 = "",
    /// The focused pane handle (doc/cwa-prior-docs-audit.md §5: "`pane` is a fact on
    /// head scopes, `principal` is identity, never a scope axis"). Mirrors
    /// `Head.focused_pane` — 0 is not a sentinel here either (see that
    /// field's doc); a predicate that cares about a SPECIFIC pane compares
    /// this against a value it already validated through
    /// `window_layout.headFocus`, never against the bare default.
    pane: u32 = 0,

    fn hasTag(self: Facts, tag: []const u8) bool {
        for (self.tags) |tg| if (std.mem.eql(u8, tg, tag)) return true;
        return false;
    }
};

/// A host-evaluated predicate over `Facts`. `mode.zig`'s vocabulary
/// (`ext,shebang,glob,tag,locus,all,any,not`) plus the interaction axis
/// (`mode,tool,lang`) — the generalization W1 was pulled forward to build
/// (doc/configuration.md §7, review C-F5).
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
    /// Keymap mode equals this string exactly.
    mode: []const u8,
    /// Buffer language equals this string exactly (see file doc: the
    /// caller, not this predicate, computes "language" from a name).
    lang: []const u8,
    /// Active buffer's tool-backing identity equals this string exactly.
    tool: []const u8,
    /// Every child matches (a bare leaf is the same as `all` of one child;
    /// an empty slice is vacuously true — the "unconstrained" predicate).
    all: []const Predicate,
    /// Any child matches. Opaque for `specificity` (a single `any` counts
    /// as one conjunct regardless of internal structure) — but NOT opaque
    /// for `disjoint`, which unwraps it with the correct (universal)
    /// quantifier; see both functions' docs below.
    any: []const Predicate,
    /// The child does not match. Opaque for both `specificity` and
    /// `disjoint` — never proven disjoint from anything.
    not: *const Predicate,

    pub fn matches(self: Predicate, f: Facts) bool {
        return switch (self) {
            .ext => |e| if (f.path) |p| std.mem.endsWith(u8, p, e) else false,
            .shebang => |s| std.mem.startsWith(u8, f.first_line, "#!") and
                std.mem.indexOf(u8, f.first_line, s) != null,
            .glob => |g| if (f.path) |p| mode.globMatch(g, p) else false,
            .tag => |tg| f.hasTag(tg),
            .locus => |l| f.locality == l,
            .mode => |m| std.mem.eql(u8, m, f.mode),
            .lang => |l| std.mem.eql(u8, l, f.lang),
            .tool => |tl| std.mem.eql(u8, tl, f.tool),
            .all => |kids| {
                for (kids) |k| if (!k.matches(f)) return false;
                return true;
            },
            .any => |kids| {
                for (kids) |k| if (k.matches(f)) return true;
                return false;
            },
            .not => |k| !k.matches(f),
        };
    }

    /// Conjunct count over the merged facts — generalizes `action.When`'s
    /// specificity rule (count of non-null fields) to an arbitrary
    /// predicate tree: `all` sums its children (so `all{mode,ext}` = 2,
    /// exactly the cross-axis case revision 1 couldn't express); every leaf,
    /// `any`, and `not` counts as one conjunct regardless of internal
    /// structure — unlike `disjoint`, which DOES look inside `any` (a
    /// different question: "how many constraints does authoring this
    /// impose" vs "can this ever co-match something else").
    pub fn specificity(self: Predicate) u32 {
        return switch (self) {
            .all => |kids| blk: {
                var n: u32 = 0;
                for (kids) |k| n += k.specificity();
                break :blk n;
            },
            else => 1,
        };
    }
};

/// Two predicates are "provably disjoint" when they can never both hold for
/// the same `Facts` — the honest approximation container.zig's collision
/// rule leans on (predicate-overlap is undecidable in general; this proves
/// only the easy, common case). Recurses through `all`/`any` on EITHER side
/// with the quantifier each combinator actually means:
///
///   - `all(k1,k2,...)` holds only if EVERY ki holds — so it is disjoint
///     from `other` as soon as ANY SINGLE ki is disjoint from `other`
///     (existential: one impossible conjunct kills the whole conjunction).
///   - `any(k1,k2,...)` holds if ANY ki holds — so it is disjoint from
///     `other` only if EVERY ki is disjoint from `other` (universal: if even
///     one alternative can co-match `other`, picking that alternative makes
///     both sides true at once).
///
/// Getting this backwards is the bug a caps-adapter regression proved live
/// (doc/configuration.md §7 review): `predicateFromExtensions` emits `any(ext,
/// ext, ...)` for a multi-extension provider, and treating `any` as one
/// opaque non-disjoint atom (the pre-fix behavior) made two DIFFERENT
/// languages' tree-sitter providers — same slot, same priority, same
/// specificity, different owners, one `any` each — look like an
/// unresolvable collision, which is false: `any(ext=".zig")` and
/// `any(ext=".nix")` can never both hold for one `Facts.path`.
///
/// The two atomic (non-`all`/`any`) leaves that finally get compared are
/// checked by `sameAxisDisjoint`: proven disjoint only when they name the
/// SAME AXIS with a DIFFERENT LITERAL VALUE (`ext=".zig"` vs `ext=".py"`,
/// `mode="normal"` vs `mode="insert"`, ...). NOT attempted: `shebang`/`glob`
/// (substring/pattern matching, not literal equality — two different globs
/// might still overlap) and anything inside `not` (opaque, same reasoning).
/// A false "not disjoint" only costs an avoidable collision error at bind
/// time — never a silent runtime ambiguity.
pub fn disjoint(a: Predicate, b: Predicate) bool {
    switch (a) {
        .all => |kids| {
            for (kids) |k| if (disjoint(k, b)) return true;
            return false;
        },
        .any => |kids| {
            for (kids) |k| if (!disjoint(k, b)) return false;
            return true;
        },
        else => {},
    }
    switch (b) {
        .all => |kids| {
            for (kids) |k| if (disjoint(a, k)) return true;
            return false;
        },
        .any => |kids| {
            for (kids) |k| if (!disjoint(a, k)) return false;
            return true;
        },
        else => {},
    }
    return sameAxisDisjoint(a, b);
}

fn sameAxisDisjoint(a: Predicate, b: Predicate) bool {
    return switch (a) {
        .ext => |v| b == .ext and !std.mem.eql(u8, v, b.ext),
        .tag => |v| b == .tag and !std.mem.eql(u8, v, b.tag),
        .mode => |v| b == .mode and !std.mem.eql(u8, v, b.mode),
        .lang => |v| b == .lang and !std.mem.eql(u8, v, b.lang),
        .tool => |v| b == .tool and !std.mem.eql(u8, v, b.tool),
        .locus => |v| b == .locus and v != b.locus,
        else => false,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "facts: predicates match merged buffer + interaction facts" {
    const f: Facts = .{
        .locality = .local,
        .path = "src/main.rs",
        .name = "main.rs",
        .first_line = "#!/bin/sh\n",
        .tags = &.{ "vcs", "dirty" },
        .mode = "normal",
        .lang = "rs",
        .tool = "",
    };
    try t.expect((Predicate{ .ext = ".rs" }).matches(f));
    try t.expect(!(Predicate{ .ext = ".zig" }).matches(f));
    try t.expect((Predicate{ .tag = "dirty" }).matches(f));
    try t.expect((Predicate{ .shebang = "sh" }).matches(f));
    try t.expect((Predicate{ .locus = .local }).matches(f));
    try t.expect((Predicate{ .glob = "src/*.rs" }).matches(f));
    try t.expect((Predicate{ .mode = "normal" }).matches(f));
    try t.expect(!(Predicate{ .mode = "insert" }).matches(f));
    try t.expect((Predicate{ .lang = "rs" }).matches(f));
    try t.expect((Predicate{ .tool = "" }).matches(f));

    // Cross-axis conjunction — inexpressible under revision 1's single-scope
    // eligibility (review A1/A3); an ordinary predicate here.
    try t.expect((Predicate{ .all = &.{ .{ .mode = "normal" }, .{ .ext = ".rs" } } }).matches(f));
    try t.expect(!(Predicate{ .all = &.{ .{ .mode = "insert" }, .{ .ext = ".rs" } } }).matches(f));
}

test "facts: specificity generalizes conjunct-count to any predicate tree" {
    try t.expectEqual(@as(u32, 0), (Predicate{ .all = &.{} }).specificity());
    try t.expectEqual(@as(u32, 1), (Predicate{ .ext = ".zig" }).specificity());
    try t.expectEqual(@as(u32, 1), (Predicate{ .mode = "normal" }).specificity());
    try t.expectEqual(@as(u32, 2), (Predicate{ .all = &.{ .{ .mode = "normal" }, .{ .ext = ".nix" } } }).specificity());
    try t.expectEqual(@as(u32, 1), (Predicate{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".zon" } } }).specificity());
}

test "facts: disjoint proves same-axis literal mismatches, stays conservative elsewhere" {
    try t.expect(disjoint(.{ .ext = ".zig" }, .{ .ext = ".py" }));
    try t.expect(!disjoint(.{ .ext = ".zig" }, .{ .ext = ".zig" }));
    try t.expect(disjoint(.{ .mode = "normal" }, .{ .mode = "insert" }));
    try t.expect(disjoint(.{ .locus = .local }, .{ .locus = .remote }));
    // Cross-axis predicates are never proven disjoint by this approximation.
    try t.expect(!disjoint(.{ .ext = ".zig" }, .{ .mode = "normal" }));
    // A conjunction is disjoint from the other side if ANY conjunct proves it.
    try t.expect(disjoint(.{ .all = &.{ .{ .mode = "normal" }, .{ .ext = ".zig" } } }, .{ .ext = ".py" }));
    // glob/shebang/not: never proven disjoint (the honest limit).
    try t.expect(!disjoint(.{ .glob = "*.zig" }, .{ .glob = "*.py" }));
    const not_zig: Predicate = .{ .ext = ".zig" };
    try t.expect(!disjoint(.{ .not = &not_zig }, .{ .ext = ".py" }));

    // `any` is a DISJUNCTION, not an opaque atom: proving it disjoint from
    // `other` requires EVERY alternative to be disjoint from `other` — the
    // exact bug a live capability-adapter regression exposed (two
    // tree-sitter providers, one `any(ext=".zig")` and one
    // `any(ext=".nix")`, wrongly refused as a collision when `any` was
    // treated as one opaque non-disjoint atom).
    try t.expect(disjoint(.{ .any = &.{.{ .ext = ".zig" }} }, .{ .any = &.{.{ .ext = ".nix" }} }));
    try t.expect(disjoint(
        .{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".zon" } } },
        .{ .any = &.{ .{ .ext = ".py" }, .{ .ext = ".pyi" } } },
    ));
    // If even ONE alternative on either side can co-match, the whole `any`
    // is NOT provably disjoint — a shared ".zig" alternative here means some
    // Facts (a .zig path) satisfies both sides at once.
    try t.expect(!disjoint(
        .{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".zon" } } },
        .{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".py" } } },
    ));
    // `any` nested inside `all` composes correctly too (existential over the
    // `all`'s conjuncts, each check itself unwrapping the `any` universally).
    try t.expect(disjoint(
        .{ .all = &.{ .{ .mode = "normal" }, .{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".zon" } } } } },
        .{ .ext = ".py" },
    ));
}

test {
    std.testing.refAllDecls(@This());
}
