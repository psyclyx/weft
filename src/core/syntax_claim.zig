//! `syntax_claim` — the SYNTAX-CLAIM RECONCILE (W7b, doc/w7-rebase.md §4,
//! doc/d1-live-reconcile.md §1.3's id-diff discipline, reused). This is the
//! genuinely novel piece the flagship needs: a code buffer's function-shaped
//! regions, minted as `graph.zig#GraphDoc` STRUCT NODES (W7b's other new
//! piece — see `graph.zig`'s "The struct forest — exposed" module doc
//! comment) whose identity persists across edits AND across a peer's move
//! of the function, which an `EventAnchor` pair cannot do
//! (doc/w7-rebase.md §2.2 point 1).
//!
//! ## The model this reconcile maintains
//!
//! Each detected function is its OWN struct node (`GraphDoc.structCreate`,
//! parented at the struct forest's `.root` sentinel — a flat, single-file
//! forest for v1, no nested/namespaced functions yet), carrying two map
//! fields: `"name"` (the parsed identifier) and `"body"` (a DEDICATED text
//! object holding just that function's source). This is the load-bearing
//! design choice, so it is stated plainly:
//!
//! **A function's content lives in ITS OWN text object, never in one
//! whole-buffer shared text object.** This is what makes BOTH halves of
//! the flagship gate true for free, with zero new admission machinery:
//!
//! - **In-function edits are admitted by plain subtree containment.** A
//!   peer's `textInsert`/`textDelete` on a function's `"body"` object is a
//!   `.text{obj}` change whose `obj` is a DIRECT map child of the
//!   function's own struct node — `GraphDoc.contains(function_node,
//!   body_obj)` is trivially true, no anchor-range check needed at all
//!   (contrast `grants.DocRegion`, which needs one because a `TextDoc`/
//!   one-shared-text-object model has no sub-object to key containment on
//!   — see `grants.zig`'s `.doc_region` doc comment).
//! - **A move never touches text identity, so it can never collapse
//!   anything.** "Moving" a function in this model is a PURE
//!   `GraphDoc.structMove` (reparent/reorder in the struct forest) — the
//!   function's own `ObjId` and its `"body"` text object are completely
//!   untouched. Contrast a flat shared buffer, where "moving" a function
//!   is unavoidably a cut (delete) + paste (insert) — new insertion
//!   identity, collapsed anchors, a trapped grant (w7-rebase.md §2.2: "a
//!   genuine cut+paste mints new insertion identity, so the pair collapses
//!   and traps... only real on the graph substrate"). Decoupling "where a
//!   function sits" from "what a function's content IS" is exactly what
//!   buys move-survival, and it falls out of this model rather than
//!   needing bespoke move-aware admission logic.
//!
//! A `.graph_subtree` grant (`grants.zig`, `GraphCollab.grantSubtree`)
//! rooted at a function's `NodeRef` therefore already does the right thing
//! for BOTH gate clauses through the EXISTING W6 slice 2 machinery
//! (`GraphCollab.admitRegions` → `GraphDoc.touchedRegionsWithin` →
//! `contains`), once `contains`/`reachable` know the struct forest
//! (`graph.zig`'s piece 1) — this module adds no new admission code, only
//! the reconcile that KEEPS the struct-node model in sync with what a
//! human/parser sees as "the functions in this file."
//!
//! ## The reconcile trigger and identity discipline
//!
//! `reconcile` takes a plain `source: []const u8` snapshot — the honest v1
//! trigger point, standing in for "whatever the real syntax pipeline's
//! update point is" (`syntax.zig`'s `Syntax.sync`, called after the
//! commit-log mirror drains). A real integration calls `reconcile` from
//! THAT point, handing it the buffer's current flat text; this module does
//! not depend on `syntax.zig`/tree-sitter at all, by design (see "Parser
//! fidelity, deferred" below) — it only needs a byte slice.
//!
//! It diffs the newly-parsed function list against the EXISTING struct
//! children of `.root`, matched BY NAME — the v1 identity currency (see
//! "Parser fidelity, deferred" for why this is NOT full `objectAnchorAt`
//! content-anchor matching, and what upgrading to that would buy). A
//! MATCHED node is left completely alone: its `"body"` text object is
//! NEVER overwritten by this reconcile, because in-function text edits are
//! already convergent by construction (doc/d1-live-reconcile.md §1.2 — "no
//! commit point, because there is nothing a commit point would buy") —
//! reconcile's job is EXISTENCE (does a node for this name exist?), not
//! content sync. An unmatched OLD node (its name no longer appears)
//! `structDelete`s (trash). An unmatched NEW span (a name with no existing
//! node) `structCreate`s fresh, seeded with its parsed content.
//!
//! **Ambiguity, decided, loud by construction, not by exception:** if two
//! spans in ONE parse share a name (an invalid-but-possible input — a
//! duplicate function name), the FIRST occurrence in `source` (lowest
//! start offset — `scanFunctions`' own emission order) matches an existing
//! same-named node; every further duplicate is treated as UNMATCHED and
//! mints its own separate node. This is deterministic (a pure function of
//! `source`'s byte content and the existing node set, never of arrival
//! order or wall-clock time) and never silently drops or merges either
//! function's content.
//!
//! **Determinism, stated as the property it is:** `reconcile` is a pure
//! function of `(existing struct-node names, source)` — running it twice
//! on the SAME `(doc, source)` pair is a no-op the second time (every name
//! already has a matching node, so nothing is created or deleted); running
//! it on two independently-built docs with the same starting struct-node
//! names against the same `source` produces the same created/kept/deleted
//! partition on both. New nodes are appended after the current last live
//! sibling in `source`-scan order (`orderKeyBetween(lastKey, null)`
//! chained forward), so re-running with unchanged input never reshuffles
//! existing order either.
//!
//! **Single-reconciler, DECIDED (the authority-model question, answered
//! honestly):** `reconcile` MUST be called only by the buffer's OWNING/HOST
//! replica — never by a peer, and never concurrently by two replicas of
//! the same buffer. The reason is structural, not a convention that could
//! be relaxed by care: `structCreate` always mints a BRAND NEW `ObjId` with
//! no relationship to any other node, so if two replicas independently
//! reconcile the SAME newly-appeared function name, they mint TWO
//! DIFFERENT struct nodes for "the same" function — nothing in stemma
//! merges them back into one (unlike a map key, where two concurrent
//! writers to the SAME slot at least produce an inspectable MV conflict
//! set, `mapConflictCount`). A concurrent second reconciler is therefore a
//! genuine duplicate-minting hazard, not a race that merely needs a
//! tiebreak. **Future work, named rather than built**: a multi-reconciler
//! design would need reconcile itself to become a structural op with a
//! deterministic winner (mirroring `structCycleBroken`'s global-order
//! resolution) — e.g. "the causally-earliest `structCreate` for a given
//! name wins; a later one is retroactively folded/trashed on merge" — real
//! design work this module does not attempt. v1's single-reconciler rule
//! is what D1 §2.2 calls the `on_save`-shaped discipline applied here:
//! reconcile is host-authoritative, like `on_save`'s explicit commit
//! point, not a live multi-writer operation.
//!
//! ## Parser fidelity, deferred
//!
//! `scanFunctions` below is a DELIBERATELY simple, deterministic
//! function-boundary heuristic (line-anchored `fn NAME(` / `pub fn NAME(`,
//! brace-depth matching for the body) — not a real tree-sitter query
//! against `syntax.zig`'s grammar machinery. This is a scoped-down v1, not
//! an oversight: the flagship gate is about identity surviving edits/
//! moves/deletes under a subtree grant, not about parser fidelity, and a
//! full ts-query integration (capture names per grammar, multi-language
//! function/method shapes) is real, separable work. The heuristic is
//! swapped for `Syntax.queryCaptures`-driven detection (`syntax.zig`
//! already exposes the primitive: a `function`/`method` capture query
//! over the current tree) as the named follow-up, WITHOUT changing
//! anything below this line — `reconcile`'s diff/identity logic only
//! needs `(name, start, end)` triples, wherever they come from.
//! Similarly, matching by NAME (not a resolved `objectAnchorAt` content
//! anchor into a shared source) is the v1 identity currency; a real
//! content-anchor upgrade would let a RENAMED function still match its old
//! node (today, a rename mints a new node and trashes the old one — an
//! honest, named limitation, not a silent bug: nothing here claims to
//! survive a rename).

const std = @import("std");
const Allocator = std.mem.Allocator;

const GraphDoc = @import("graph.zig");
const ObjId = GraphDoc.ObjId;

/// One detected function region. `name`/the span `[start, end)` both
/// borrow from the `source` slice passed to `scanFunctions` — consumed
/// synchronously by `reconcile` (copied into the doc's own storage via
/// `mapSet`/`textInsert`), never stashed past the call that produced it.
pub const FnSpan = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The v1 function-boundary heuristic — see "Parser fidelity, deferred"
/// above. Scans line-by-line for `fn NAME(` (optionally `pub fn NAME(`),
/// finds the first `{` after the name (the body's opening brace — the
/// signature/return-type between them is assumed brace-free, true of
/// ordinary zig-ish source), then matches braces to find the body's
/// close. A function whose signature never resolves to a balanced body
/// (truncated/malformed source) is simply not emitted — fail-quiet on
/// malformed input, not a caller-visible error: a syntax overlay must
/// degrade gracefully on code that doesn't parse cleanly yet, the same
/// spirit as `syntax.zig`'s own hole-aware `readCb`.
///
/// **Two named heuristic gaps, both inherited from "brace-depth counting
/// is not parsing," both closed for free by the ts-query upgrade (see
/// "Parser fidelity, deferred"):** (1) the signature/return-type
/// brace-free assumption above — an anonymous-struct return type or a
/// default-value struct literal in the parameter list would miscount;
/// (2) a `{`/`}` INSIDE A STRING OR CHARACTER LITERAL, OR A COMMENT,
/// inside the body counts exactly like a real one — `fn f() void { const
/// s = "}"; }` sees the `}` in the string literal as the body's close,
/// truncating the span one token early (the depth counter has no lexical
/// awareness at all, not even of strings/comments). Not exploitable
/// against the RECONCILE's identity/admission guarantees (a truncated
/// span still gets a real, unique struct node — it just may miss a
/// trailing brace's worth of source), but a real fidelity gap a caller
/// should not be surprised by.
pub fn scanFunctions(gpa: Allocator, source: []const u8) Allocator.Error![]FnSpan {
    var out: std.ArrayList(FnSpan) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < source.len) {
        const line_begin = i;
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const line = source[line_begin..line_end];
        const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
        var rest = line[lead..];
        var kw_offset = lead;
        if (std.mem.startsWith(u8, rest, "pub ")) {
            kw_offset += 4;
            rest = rest[4..];
        }
        if (std.mem.startsWith(u8, rest, "fn ") and rest.len > 3 and isIdentStart(rest[3])) {
            const name_start = line_begin + kw_offset + 3;
            var ne = name_start;
            while (ne < source.len and isIdentChar(source[ne])) ne += 1;
            const name = source[name_start..ne];
            if (std.mem.indexOfScalarPos(u8, source, ne, '{')) |brace_start| {
                var depth: usize = 1;
                var k = brace_start + 1;
                while (k < source.len and depth > 0) : (k += 1) {
                    switch (source[k]) {
                        '{' => depth += 1,
                        '}' => depth -= 1,
                        else => {},
                    }
                }
                if (depth == 0) {
                    const span_start = line_begin + lead;
                    try out.append(gpa, .{ .name = name, .start = span_start, .end = k });
                    i = k;
                    continue;
                }
            }
        }
        i = line_end + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// What `reconcile` did, for a caller (a test, or the real integration)
/// that wants to know which nodes are now live. `created` is owned
/// (`NodeRef.free` each, or call `deinit`); kept/deleted are just counts —
/// a caller that needs the KEPT nodes' refs already has them (nothing
/// about them changed) and can re-query `GraphDoc.structChildren(.root)`.
pub const ReconcileResult = struct {
    /// OWNED — each `NodeRef.token` and the list itself belong to the
    /// caller; `deinit` below frees both. Callers at a call site: don't
    /// let `res` go out of scope without `deinit`, same as any other
    /// owned resource this codebase returns (mirrors `TouchedRegion`'s
    /// slice above).
    created: std.ArrayList(GraphDoc.NodeRef) = .empty,
    /// BORROWED — a plain count, not a resource; nothing to free. The
    /// matched nodes themselves are already owned by `doc`, not by this
    /// result (a caller that needs their `NodeRef`s re-queries
    /// `structChildren`/`findByName`, which mint their OWN owned tokens).
    kept: usize = 0,
    /// BORROWED — same as `kept`: a plain count, nothing to free.
    deleted: usize = 0,

    pub fn deinit(self: *ReconcileResult, gpa: Allocator) void {
        for (self.created.items) |r| r.free(gpa);
        self.created.deinit(gpa);
        self.* = undefined;
    }
};

/// The reconcile itself — see the module doc comment for the full
/// discipline (identity = name matching, single-reconciler, deterministic,
/// content-preserving for matched nodes). HOST-ONLY: see "Single-
/// reconciler, DECIDED" above.
pub fn reconcile(gpa: Allocator, doc: *GraphDoc, source: []const u8) !ReconcileResult {
    const new_fns = try scanFunctions(gpa, source);
    defer gpa.free(new_fns);

    const old_ids = try doc.structChildren(gpa, .root);
    defer gpa.free(old_ids);

    const matched = try gpa.alloc(bool, new_fns.len);
    defer gpa.free(matched);
    @memset(matched, false);

    var result: ReconcileResult = .{};
    errdefer result.deinit(gpa);

    // Pass 1: match existing nodes against the new parse, by name, first
    // unmatched occurrence wins (source order — deterministic, see the
    // module doc comment's ambiguity rule). Unmatched existing nodes are
    // trashed.
    for (old_ids) |node| {
        const nv = doc.ref(node).mapGet("name") orelse continue; // not a syntax-claim node — ignore, don't touch
        const name_str = nv.asStr();
        var found: ?usize = null;
        for (new_fns, 0..) |nf, i| {
            if (matched[i]) continue;
            if (std.mem.eql(u8, nf.name, name_str)) {
                found = i;
                break;
            }
        }
        if (found) |i| {
            matched[i] = true;
            result.kept += 1;
            // The node's own "body" text object is deliberately left
            // untouched — see the module doc comment: in-function edits
            // are already convergent by construction, reconcile's job is
            // existence, not content sync.
        } else {
            try doc.structDelete(gpa, node);
            result.deleted += 1;
        }
    }

    // Pass 2: mint a fresh node for every unmatched new span, appended
    // after the current last LIVE sibling (deterministic order-key
    // chaining — see the module doc comment's determinism paragraph).
    const live = try doc.structChildren(gpa, .root);
    defer gpa.free(live);
    var last_key: ?[]const u8 = if (live.len > 0) doc.structOrderKey(live[live.len - 1]) else null;

    for (new_fns, 0..) |nf, i| {
        if (matched[i]) continue;
        const key = try GraphDoc.orderKeyBetween(gpa, last_key, null);
        defer gpa.free(key);
        const node = try doc.structCreate(gpa, .root, key);
        _ = try doc.set(gpa, node, "name", .{ .str = nf.name });
        const body = (try doc.set(gpa, node, "body", .text)).?;
        _ = try doc.textInsert(gpa, body, 0, source[nf.start..nf.end]);
        last_key = doc.structOrderKey(node); // borrowed, valid for the doc's lifetime — safe to chain from
        try result.created.append(gpa, try doc.nodeRef(gpa, node));
    }

    return result;
}

/// Look up a currently-live syntax-claim node by its `"name"` field —
/// O(children), fine for a file's expected function count. `null` if no
/// live child of `.root` has that name. The lookup a caller (a grant-
/// minting command, a test) uses to turn "grant me function B" into the
/// `NodeRef` `GraphCollab.grantSubtree` wants.
pub fn findByName(gpa: Allocator, doc: *const GraphDoc, name: []const u8) Allocator.Error!?GraphDoc.NodeRef {
    const children = try doc.structChildren(gpa, .root);
    defer gpa.free(children);
    for (children) |node| {
        const v = doc.ref(node).mapGet("name") orelse continue;
        if (std.mem.eql(u8, v.asStr(), name)) return try doc.nodeRef(gpa, node);
    }
    return null;
}

/// The `"body"` text object `ObjId` of a live struct node — the object a
/// caller with a resolved function `ObjId` (from `findByName`/
/// `structChildren`/a resolved grant root) actually calls
/// `textInsert`/`textDelete` on. `null` if `node` isn't a syntax-claim
/// node (no `"body"` field) or isn't live.
pub fn bodyOf(doc: *const GraphDoc, node: ObjId) ?ObjId {
    const v = doc.ref(node).mapGet("body") orelse return null;
    return v.objId();
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "scanFunctions: finds top-level fn/pub fn spans, skips nested fn inside a body" {
    const gpa = t.allocator;
    const source =
        \\const std = @import("std");
        \\
        \\fn a() void {
        \\    doStuff();
        \\}
        \\
        \\pub fn b(x: i32) i32 {
        \\    const inner = struct {
        \\        fn nested() void {}
        \\    };
        \\    _ = inner;
        \\    return x + 1;
        \\}
        \\
        \\fn c() void {}
        \\
    ;
    const spans = try scanFunctions(gpa, source);
    defer gpa.free(spans);
    try t.expectEqual(@as(usize, 3), spans.len);
    try t.expectEqualStrings("a", spans[0].name);
    try t.expectEqualStrings("b", spans[1].name);
    try t.expectEqualStrings("c", spans[2].name);
    // `b`'s span swallows the nested `fn nested` — never emitted as its
    // own top-level span (source-order skip, see the doc comment).
    try t.expect(spans[1].start < spans[2].start);
    try t.expect(std.mem.indexOf(u8, source[spans[1].start..spans[1].end], "nested") != null);
}

test "reconcile: mints one struct node per function, seeded with its own body text" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "host");
    defer doc.deinit(gpa);

    const source =
        \\fn a() void {
        \\    return;
        \\}
        \\
        \\fn b() void {
        \\    doThing();
        \\}
        \\
    ;
    var res = try reconcile(gpa, &doc, source);
    defer res.deinit(gpa);
    try t.expectEqual(@as(usize, 2), res.created.items.len);
    try t.expectEqual(@as(usize, 0), res.kept);
    try t.expectEqual(@as(usize, 0), res.deleted);

    const children = try doc.structChildren(gpa, .root);
    defer gpa.free(children);
    try t.expectEqual(@as(usize, 2), children.len);
    try t.expectEqualStrings("a", doc.ref(children[0]).mapGet("name").?.asStr());
    try t.expectEqualStrings("b", doc.ref(children[1]).mapGet("name").?.asStr());

    const b_body = bodyOf(&doc, children[1]).?;
    const body_bytes = try doc.ref(b_body).textRope().toOwnedSlice(gpa);
    defer gpa.free(body_bytes);
    try t.expect(std.mem.indexOf(u8, body_bytes, "doThing") != null);
}

test "reconcile: idempotent — re-running with unchanged source mints nothing new and keeps the same ObjIds" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "host");
    defer doc.deinit(gpa);

    const source =
        \\fn a() void {}
        \\fn b() void {}
        \\
    ;
    var res1 = try reconcile(gpa, &doc, source);
    defer res1.deinit(gpa);
    const children1 = try doc.structChildren(gpa, .root);
    defer gpa.free(children1);
    try t.expectEqual(@as(usize, 2), children1.len);

    var res2 = try reconcile(gpa, &doc, source);
    defer res2.deinit(gpa);
    try t.expectEqual(@as(usize, 0), res2.created.items.len); // no duplicate minting
    try t.expectEqual(@as(usize, 2), res2.kept);
    try t.expectEqual(@as(usize, 0), res2.deleted);

    const children2 = try doc.structChildren(gpa, .root);
    defer gpa.free(children2);
    try t.expectEqual(@as(usize, 2), children2.len);
    try t.expectEqual(children1[0], children2[0]); // same ObjId — same node, not a fresh one
    try t.expectEqual(children1[1], children2[1]);
}

test "reconcile: a function that disappears is trashed; a new one is minted; survivors are untouched" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "host");
    defer doc.deinit(gpa);

    var res1 = try reconcile(gpa, &doc,
        \\fn a() void {}
        \\fn b() void {}
        \\
    );
    defer res1.deinit(gpa);
    const a_ref = (try findByName(gpa, &doc, "a")).?;
    defer a_ref.free(gpa);
    const b_ref = (try findByName(gpa, &doc, "b")).?;
    defer b_ref.free(gpa);

    // `a` disappears, `b` survives unchanged, `c` is new.
    var res2 = try reconcile(gpa, &doc,
        \\fn b() void {}
        \\fn c() void {}
        \\
    );
    defer res2.deinit(gpa);
    try t.expectEqual(@as(usize, 1), res2.deleted); // a
    try t.expectEqual(@as(usize, 1), res2.kept); // b
    try t.expectEqual(@as(usize, 1), res2.created.items.len); // c

    try t.expect((try findByName(gpa, &doc, "a")) == null); // trashed — no longer a live child of .root
    const b_still = (try findByName(gpa, &doc, "b")).?;
    defer b_still.free(gpa);
    try t.expect(b_still.eql(b_ref)); // SAME identity, untouched by the reconcile
    const c_ref = (try findByName(gpa, &doc, "c")).?;
    defer c_ref.free(gpa);

    // `a`'s own ObjId is genuinely gone from `.root`'s children, not just
    // renamed — `structParent` now resolves it to `.trash`.
    const a_obj = try doc.resolve(a_ref);
    try t.expectEqual(GraphDoc.StructRef.trash, doc.structParent(a_obj).?);
}

test "reconcile: two functions with the same name in one parse — first occurrence matches, the rest mint separately (loud, deterministic)" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "host");
    defer doc.deinit(gpa);

    var res1 = try reconcile(gpa, &doc,
        \\fn dup() void {
        \\    return;
        \\}
        \\
    );
    defer res1.deinit(gpa);
    const first_ref = (try findByName(gpa, &doc, "dup")).?;
    defer first_ref.free(gpa);

    // A second `dup` appears alongside the first (a duplicate-name input —
    // the ambiguous case).
    var res2 = try reconcile(gpa, &doc,
        \\fn dup() void {
        \\    return;
        \\}
        \\
        \\fn dup() void {
        \\    otherThing();
        \\}
        \\
    );
    defer res2.deinit(gpa);
    try t.expectEqual(@as(usize, 0), res2.deleted);
    try t.expectEqual(@as(usize, 1), res2.kept); // the first occurrence re-matches the existing node
    try t.expectEqual(@as(usize, 1), res2.created.items.len); // the second is a genuinely separate node

    const children = try doc.structChildren(gpa, .root);
    defer gpa.free(children);
    try t.expectEqual(@as(usize, 2), children.len);
    const kept_obj = try doc.resolve(first_ref);
    try t.expectEqual(kept_obj, children[0]); // the ORIGINAL node, order preserved
    try t.expect(!std.meta.eql(kept_obj, children[1])); // the new one is a distinct ObjId
}

test "reconcile: in-function edit on a matched node's own body is untouched by the next reconcile pass" {
    const gpa = t.allocator;
    var doc = try GraphDoc.init(gpa, "host");
    defer doc.deinit(gpa);

    var res1 = try reconcile(gpa, &doc,
        \\fn a() void {
        \\    return;
        \\}
        \\
    );
    defer res1.deinit(gpa);
    const a_ref = (try findByName(gpa, &doc, "a")).?;
    defer a_ref.free(gpa);
    const a_obj = try doc.resolve(a_ref);
    const body = bodyOf(&doc, a_obj).?;

    // A live in-function edit — exactly what a peer holding a subtree
    // grant on `a_obj` would send: a plain textInsert on `a`'s OWN body
    // object, nothing structural.
    _ = try doc.textInsert(gpa, body, 5, "EDITED ");

    // Reconcile against the ORIGINAL (unedited) source again — the flat
    // parse hasn't changed, so `a` still matches by name and its body is
    // left alone: the edit survives.
    var res2 = try reconcile(gpa, &doc,
        \\fn a() void {
        \\    return;
        \\}
        \\
    );
    defer res2.deinit(gpa);
    try t.expectEqual(@as(usize, 0), res2.created.items.len);
    try t.expectEqual(@as(usize, 1), res2.kept);

    const still_a = (try findByName(gpa, &doc, "a")).?;
    defer still_a.free(gpa);
    try t.expect(still_a.eql(a_ref)); // same node
    const body_bytes = try doc.ref(body).textRope().toOwnedSlice(gpa);
    defer gpa.free(body_bytes);
    try t.expect(std.mem.indexOf(u8, body_bytes, "EDITED") != null); // the live edit is still there
}

test {
    std.testing.refAllDecls(@This());
}
