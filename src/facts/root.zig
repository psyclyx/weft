//! Facts — the merged context vocabulary the Container resolves against
//! (doc/cwa-prior-docs-audit.md §5). `Facts` is the union of two vocabularies
//! that used to live in separate, incompatible predicate systems:
//!
//!   - the buffer-resource axis (`ext`/`shebang`/`glob` over `path`, `tags`,
//!     `locus`), which arrived from a `mode.zig` that had the right shape and
//!     no consumers;
//!   - the interaction axis (`action.zig`'s `When`/`Ctx`: `mode`, `lang`,
//!     `tool`) — live code, the thing actually gating action dispatch.
//!
//! That merger is now complete in the only way that lasts: `mode.zig` is
//! DELETED. It survived the merge as a 346-line module holding a second,
//! structurally-similar `Predicate`, a `Resource`, and an `Engine` — none of
//! them reachable — imported by this file alone, for an enum and a glob
//! matcher, both of which live here now. Two predicate vocabularies is the
//! condition this module exists to end; leaving the loser in the tree kept it
//! one import away from coming back.
//!
//! `Predicate` is that `{ext,shebang,glob,tag,locus,all,any,not}` vocabulary
//! plus `{mode,tool,lang}`, evaluated over `Facts` instead of the
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
//! Host-evaluated, pure data, O(predicate size), no callback — predicates stay
//! DATA, never a callback the engine has to trust.
//!
//! `std` is the only import, deliberately: this vocabulary is the one every
//! plane must agree on, so it must be able to compile anywhere one of them
//! runs — including `wasm32-freestanding`.

const std = @import("std");

/// Where a buffer's bytes live.
pub const Locality = enum { local, remote, tool, none };

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
    /// Keymap mode ("normal", "insert", "files", ...).
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

/// A host-evaluated predicate over `Facts`. The buffer-resource vocabulary
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
            .glob => |g| if (f.path) |p| globMatch(g, p) else false,
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

// ── The wire form ────────────────────────────────────────────────────
//
// A predicate has to cross the membrane, and until now it crossed as one of
// two DIFFERENT narrowings of itself: `wl_slot_bind`'s four-tag blob (no
// combinators at all, so `any(ext=".zig", ext=".rs")` was unencodable) and
// `wl_provide`'s three fixed string parameters. Two lossy projections of one
// type is how vocabularies drift apart, which is the condition this module
// was created to end — and it had merely been moved to the membrane.
//
// So the codec lives HERE, beside the type, and both planes call it. Not a
// shared format that two implementations agree to honour: one function, used
// twice. There is nothing for a mirror to get wrong because there is no
// mirror.
//
// The uvarint is written out longhand rather than imported from `weft_wire`,
// to keep this file's only dependency `std` (see the module doc — it must
// compile wherever any plane runs).

/// Wire tags. Explicitly numbered: these are a format, and a reordering of
/// the union above must not silently renumber them.
pub const Tag = enum(u8) {
    all = 0,
    any = 1,
    not = 2,
    ext = 3,
    shebang = 4,
    glob = 5,
    tag = 6,
    mode = 7,
    lang = 8,
    tool = 9,
    locus = 10,
};

/// How deep a decoded predicate may nest. A guest supplies these bytes, and
/// decoding recurses — so without a ceiling a hostile blob is a host stack
/// overflow through a door that carries no permission. Far above anything an
/// author would write by hand.
pub const max_depth: usize = 32;

pub const DecodeError = error{ Malformed, TooDeep } || std.mem.Allocator.Error;

fn putUv(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: usize) !void {
    var x = v;
    while (true) {
        const byte: u8 = @intCast(x & 0x7f);
        x >>= 7;
        try out.append(gpa, if (x == 0) byte else byte | 0x80);
        if (x == 0) break;
    }
}

fn getUv(cur: *[]const u8) DecodeError!usize {
    var v: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (cur.len == 0) return error.Malformed;
        const byte = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return v;
        shift = std.math.add(u6, shift, 7) catch return error.Malformed;
    }
}

/// Encode `pred` into freshly-allocated bytes the caller owns.
pub fn encode(gpa: std.mem.Allocator, pred: Predicate) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encodeInto(&out, gpa, pred);
    return out.toOwnedSlice(gpa);
}

fn encodeInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, pred: Predicate) std.mem.Allocator.Error!void {
    switch (pred) {
        .all, .any => |kids| {
            try out.append(gpa, @intFromEnum(@as(Tag, if (pred == .all) .all else .any)));
            try putUv(out, gpa, kids.len);
            for (kids) |k| try encodeInto(out, gpa, k);
        },
        .not => |k| {
            try out.append(gpa, @intFromEnum(Tag.not));
            try encodeInto(out, gpa, k.*);
        },
        .locus => |l| {
            try out.append(gpa, @intFromEnum(Tag.locus));
            try out.append(gpa, @intFromEnum(l));
        },
        inline .ext, .shebang, .glob, .tag, .mode, .lang, .tool => |s, kind| {
            try out.append(gpa, @intFromEnum(@field(Tag, @tagName(kind))));
            try putUv(out, gpa, s.len);
            try out.appendSlice(gpa, s);
        },
    }
}

/// Decode bytes into a predicate whose strings and children are owned by
/// `gpa` — release with `free`. Empty input is the unconstrained predicate,
/// which is what "this provider did not narrow" means.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Predicate {
    if (bytes.len == 0) return .{ .all = &.{} };
    var cur = bytes;
    const pred = try decodeOne(gpa, &cur, 0);
    return pred;
}

fn decodeOne(gpa: std.mem.Allocator, cur: *[]const u8, depth: usize) DecodeError!Predicate {
    if (depth >= max_depth) return error.TooDeep;
    if (cur.len == 0) return error.Malformed;
    const raw = cur.*[0];
    cur.* = cur.*[1..];
    const tag = std.enums.fromInt(Tag, raw) orelse return error.Malformed;
    switch (tag) {
        .all, .any => {
            const n = try getUv(cur);
            // Each child costs at least one byte, so a length that cannot
            // possibly be backed by the remaining input is malformed — this
            // refuses a blob claiming a billion children before allocating.
            if (n > cur.len) return error.Malformed;
            const kids = try gpa.alloc(Predicate, n);
            var built: usize = 0;
            errdefer {
                for (kids[0..built]) |k| free(gpa, k);
                gpa.free(kids);
            }
            while (built < n) : (built += 1) kids[built] = try decodeOne(gpa, cur, depth + 1);
            return if (tag == .all) .{ .all = kids } else .{ .any = kids };
        },
        .not => {
            const kid = try gpa.create(Predicate);
            errdefer gpa.destroy(kid);
            kid.* = try decodeOne(gpa, cur, depth + 1);
            return .{ .not = kid };
        },
        .locus => {
            if (cur.len == 0) return error.Malformed;
            const l = std.enums.fromInt(Locality, cur.*[0]) orelse return error.Malformed;
            cur.* = cur.*[1..];
            return .{ .locus = l };
        },
        inline else => |kind| {
            const n = try getUv(cur);
            if (n > cur.len) return error.Malformed;
            const owned = try gpa.dupe(u8, cur.*[0..n]);
            cur.* = cur.*[n..];
            return @unionInit(Predicate, @tagName(kind), owned);
        },
    }
}

/// Release a predicate produced by `decode`.
pub fn free(gpa: std.mem.Allocator, pred: Predicate) void {
    switch (pred) {
        .all, .any => |kids| {
            for (kids) |k| free(gpa, k);
            gpa.free(kids);
        },
        .not => |k| {
            free(gpa, k.*);
            gpa.destroy(k);
        },
        .locus => {},
        inline .ext, .shebang, .glob, .tag, .mode, .lang, .tool => |s| gpa.free(s),
    }
}

/// Iterative `*`/`?` glob with backtracking over a path. Lives here rather
/// than in a sibling because `Predicate.glob` is its only caller.
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

test "facts: a predicate survives the wire whole, combinators included" {
    const gpa = t.allocator;
    // The shape the OLD wire could not express at all: a disjunction over
    // extensions, which is exactly what a language server's file filter is.
    const zig: Predicate = .{ .ext = ".zig" };
    const rs: Predicate = .{ .ext = ".rs" };
    const langs: Predicate = .{ .any = &.{ zig, rs } };
    const normal: Predicate = .{ .mode = "normal" };
    const pred: Predicate = .{ .all = &.{ langs, normal, .{ .locus = .local } } };

    const bytes = try encode(gpa, pred);
    defer gpa.free(bytes);
    const back = try decode(gpa, bytes);
    defer free(gpa, back);

    const zig_local: Facts = .{ .path = "a/b.zig", .mode = "normal", .locality = .local };
    const rs_local: Facts = .{ .path = "a/b.rs", .mode = "normal", .locality = .local };
    const py_local: Facts = .{ .path = "a/b.py", .mode = "normal", .locality = .local };
    const zig_insert: Facts = .{ .path = "a/b.zig", .mode = "insert", .locality = .local };
    for ([_]Predicate{ pred, back }) |p| {
        try t.expect(p.matches(zig_local));
        try t.expect(p.matches(rs_local));
        try t.expect(!p.matches(py_local));
        try t.expect(!p.matches(zig_insert));
    }
    // Specificity must survive too — it is what orders competing bindings.
    try t.expectEqual(pred.specificity(), back.specificity());
}

test "facts: a hostile blob is refused, not obeyed and not fatal" {
    const gpa = t.allocator;
    // Empty is the unconstrained predicate — "this provider did not narrow".
    const empty = try decode(gpa, "");
    try t.expectEqual(@as(usize, 0), empty.all.len);

    // A tag the format does not define.
    try t.expectError(error.Malformed, decode(gpa, &.{99}));
    // A string claiming more bytes than were sent — the classic over-read.
    try t.expectError(error.Malformed, decode(gpa, &.{ @intFromEnum(Tag.ext), 200, 'a' }));
    // A container claiming more children than could possibly be backed,
    // refused BEFORE it allocates for them.
    try t.expectError(error.Malformed, decode(gpa, &.{ @intFromEnum(Tag.all), 250 }));
    // Nesting past the ceiling: a guest cannot recurse the host off its
    // stack through a door that carries no permission.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    for (0..max_depth + 2) |_| try deep.append(gpa, @intFromEnum(Tag.not));
    try deep.append(gpa, @intFromEnum(Tag.locus));
    try deep.append(gpa, @intFromEnum(Locality.local));
    try t.expectError(error.TooDeep, decode(gpa, deep.items));
}

test "facts: glob backtracks, and arrived here with its coverage" {
    // `mode.zig` held this algorithm and the only tests of it; both moved
    // rather than one of them being dropped on the way.
    try t.expect(globMatch("src/*.rs", "src/main.rs"));
    try t.expect(!globMatch("test/*.rs", "src/main.rs"));
    try t.expect(globMatch("*", "anything"));
    try t.expect(globMatch("?ain.zig", "main.zig"));
    try t.expect(!globMatch("?ain.zig", "ain.zig"));
    // The backtracking case: a `*` that must give ground for a later literal.
    try t.expect(globMatch("*.test.zig", "a/b/c.test.zig"));
    try t.expect(!globMatch("*.test.zig", "a/b/c.zig"));
    // Trailing stars collapse; an exhausted pattern with input left fails.
    try t.expect(globMatch("src/**", "src/a/b"));
    try t.expect(!globMatch("src", "src/a"));
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
