//! Pick — the fuzzy-select primitive. One core mechanism, many uses:
//! the command palette is `pick-commands` over the registry's names, a
//! config can `weft.pick` its own items with a Fennel callback. State
//! is plain data the view renders (prompt, query, filtered items,
//! selection); interaction is ordinary commands bound in the "pick"
//! keymap mode, with `pick-input` as the mode's text command — the
//! picker adds no new input machinery at all.
//!
//! Entries carry an optional docstring the view renders beside the
//! text (the palette shows command summaries). Filtering runs a
//! selectable completion `Style` (default ORDERLESS — space-split tokens,
//! each a case-insensitive subsequence, matched in any order; also flex,
//! substring, prefix), ranked by word-boundary hits, then span tightness,
//! then earliest match, then FRECENCY — what you accepted recently under
//! this prompt floats up, so an empty-query palette is your recent list.
//! A sticky NARROWING filter (`pick-narrow`) pre-restricts the set, the
//! live query ranking within it. Recency is an ordinal use counter, not a
//! clock. Tab completes the query (common prefix of the matches, else
//! the selection).

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const task = @import("task.zig");
const stemma = @import("stemma");
const Value = command.Value;

pub const Acceptor = struct {
    handler: *const fn (ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void,
    /// Called exactly once when the pick closes (accept or cancel).
    cleanup: ?*const fn (data: ?*anyopaque, gpa: Allocator) void = null,
    data: ?*anyopaque = null,
};

/// A candidate producer driven by the picker's per-frame `tick`. The
/// consult-async shape: `onQuery` (re)generates as the query changes
/// (epoch-tagged so stale generations self-discard), `poll` folds ready
/// candidates into the live pick each frame, `close` signals cancel and
/// drops the owner's reference when the pick closes. `close` must NEVER
/// block or join — the pick can close inside the input hot section, so
/// teardown hands off ownership (a refcount) rather than waiting.
///
/// A source that only walks once (file finder, dir listing) leaves
/// `onQuery` null and streams via `poll`; the general regenerate path
/// (grep) sets `onQuery`. The in-core fuzzy filter narrows either.
pub const Source = struct {
    onQuery: ?*const fn (data: ?*anyopaque, ctx: *command.Context, query: []const u8, epoch: u64) anyerror!void = null,
    poll: ?*const fn (data: ?*anyopaque, ctx: *command.Context) anyerror!bool = null,
    close: ?*const fn (data: ?*anyopaque, gpa: Allocator) void = null,
    data: ?*anyopaque = null,
    /// Below this query length `onQuery` is not fired (grep guard).
    min_query: usize = 0,
    /// Coalesce keystrokes: `onQuery` fires only once the query has been
    /// still this long.
    debounce_ns: u64 = 0,
};

/// How the query filters candidates.
pub const Style = enum {
    /// Space-split tokens, each a case-insensitive subsequence, matched in
    /// ANY order (Emacs "orderless"). The default — "open file" finds
    /// "file-open" and "open-file" alike.
    orderless,
    /// One case-insensitive subsequence over the whole query.
    flex,
    /// One contiguous case-insensitive run.
    substring,
    /// The item begins with the query (case-insensitive).
    prefix,

    pub fn parse(s: []const u8) ?Style {
        return std.meta.stringToEnum(Style, s);
    }
};

pub const Options = struct {
    /// Accept the typed query itself (new filename, rename, freeform),
    /// not only an existing candidate. See `pick-accept-input`.
    allow_free_text: bool = false,
    source: ?Source = null,
    /// Completion style for this pick (default orderless).
    style: Style = .orderless,
};

/// One selectable item: the text is what matching and acceptance see;
/// the doc is display-only.
pub const Entry = struct {
    text: []const u8,
    doc: []const u8 = "",
};

pub const Pick = struct {
    active: bool = false,
    prompt: []u8 = &.{},
    items: std.ArrayList([]u8) = .empty,
    /// Parallel to `items`: display-only docstrings ("" when none).
    docs: std.ArrayList([]u8) = .empty,
    query: std.ArrayList(u8) = .empty,
    /// Indices into `items`, filtered by `query`, rank order.
    filtered: std.ArrayList(u32) = .empty,
    selected: usize = 0,
    acceptor: ?Acceptor = null,
    prev_mode: []u8 = &.{},
    /// Accept the typed query, not only a candidate (see `Options`).
    allow_free_text: bool = false,
    /// Async candidate producer for this pick (null = static list).
    source: ?Source = null,
    /// Bumped on every query mutation; the source acts when it lags.
    query_epoch: u64 = 0,
    source_epoch: u64 = 0,
    /// `task.nowNs()` of the last query mutation (debounce baseline).
    last_query_ns: u64 = 0,
    /// "prompt\x00text" → use record; survives across opens (session
    /// scope). Keys owned.
    frecency: std.StringHashMapUnmanaged(Frec) = .empty,
    use_counter: u64 = 0,
    /// Completion style for the live query (default orderless).
    style: Style = .orderless,
    /// Sticky narrowing filter (space-joined tokens): a candidate must
    /// match it (orderless) IN ADDITION to the live query. `pick-narrow`
    /// promotes the current query into it and clears the query; a further
    /// `pick-narrow` ANDs another facet; `pick-widen` clears it.
    narrow: std.ArrayList(u8) = .empty,

    const Frec = struct { uses: u32, last: u64 };

    pub const empty: Pick = .{};

    pub fn deinit(self: *Pick, gpa: Allocator) void {
        self.clear(gpa);
        var it = self.frecency.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.frecency.deinit(gpa);
        self.* = .{};
    }

    fn clear(self: *Pick, gpa: Allocator) void {
        // Stop the async source first: it hands off ownership (refcount)
        // and never blocks, so this is legal inside the input hot
        // section. Then run the acceptor's cleanup.
        if (self.source) |s| {
            if (s.close) |f| f(s.data, gpa);
        }
        self.source = null;
        self.allow_free_text = false;
        self.query_epoch = 0;
        self.source_epoch = 0;
        self.last_query_ns = 0;
        if (self.acceptor) |a| {
            if (a.cleanup) |f| f(a.data, gpa);
        }
        self.acceptor = null;
        gpa.free(self.prompt);
        self.prompt = &.{};
        for (self.items.items) |it| gpa.free(it);
        self.items.deinit(gpa);
        self.items = .empty;
        for (self.docs.items) |d| gpa.free(d);
        self.docs.deinit(gpa);
        self.docs = .empty;
        self.query.deinit(gpa);
        self.query = .empty;
        self.filtered.deinit(gpa);
        self.filtered = .empty;
        self.selected = 0;
        self.style = .orderless;
        self.narrow.deinit(gpa);
        self.narrow = .empty;
        gpa.free(self.prev_mode);
        self.prev_mode = &.{};
        self.active = false;
    }

    /// Open a static pick session: copies `entries`, switches to "pick"
    /// mode. The common case; `openWith` adds free-text/async options.
    pub fn open(
        self: *Pick,
        ctx: *command.Context,
        prompt: []const u8,
        entries: []const Entry,
        acceptor: Acceptor,
    ) !void {
        return self.openWith(ctx, prompt, entries, acceptor, .{});
    }

    /// Open a pick session with options (free-text accept, an async
    /// candidate source). On error the source's `close` is invoked so a
    /// producer created by the caller is never leaked.
    pub fn openWith(
        self: *Pick,
        ctx: *command.Context,
        prompt: []const u8,
        entries: []const Entry,
        acceptor: Acceptor,
        opts: Options,
    ) !void {
        const gpa = ctx.gpa;
        // On any failure the source is closed (never leaked) and the
        // acceptor is left UNSET — so a caller that owns a callback
        // handle (the plugin's LuaPick) can clean it up without risking
        // a later `clear()` running cleanup on a freed handle.
        errdefer if (opts.source) |s| {
            if (s.close) |f| f(s.data, gpa);
        };
        if (self.active) self.clear(gpa);
        self.prompt = try gpa.dupe(u8, prompt);
        for (entries) |e| {
            const owned = try gpa.dupe(u8, e.text);
            errdefer gpa.free(owned);
            try self.items.append(gpa, owned);
            const doc = try gpa.dupe(u8, e.doc);
            errdefer gpa.free(doc);
            try self.docs.append(gpa, doc);
        }
        try self.refilter(gpa);
        const prev = try gpa.dupe(u8, ctx.keymap.currentMode());
        errdefer gpa.free(prev);
        try ctx.keymap.setMode(gpa, "pick");
        // Commit — infallible from here, so the acceptor/source become
        // live only once the pick is fully open.
        self.acceptor = acceptor;
        self.allow_free_text = opts.allow_free_text;
        self.style = opts.style;
        self.source = opts.source;
        self.query_epoch = 0;
        self.source_epoch = 0;
        self.last_query_ns = 0;
        self.prev_mode = prev;
        self.active = true;
    }

    /// Per-frame driver for the async source: (re)generate on a settled
    /// query change, then fold whatever is ready into the live pick.
    /// Returns whether the UI changed (→ repaint). No-op without a
    /// source, so it is cheap to call every frame.
    pub fn tick(self: *Pick, ctx: *command.Context) anyerror!bool {
        if (!self.active) return false;
        const src = if (self.source) |*s| s else return false;
        var changed = false;
        if (self.source_epoch != self.query_epoch and
            self.query.items.len >= src.min_query and
            task.nowNs() - self.last_query_ns >= src.debounce_ns)
        {
            self.source_epoch = self.query_epoch;
            if (src.onQuery) |f| try f(src.data, ctx, self.query.items, self.query_epoch);
        }
        if (src.poll) |f| changed = (try f(src.data, ctx)) or changed;
        return changed;
    }

    /// Note a query mutation (drives debounce + source regeneration).
    fn queryChanged(self: *Pick) void {
        self.query_epoch +%= 1;
        self.last_query_ns = task.nowNs();
    }

    /// Stream more candidates into a live pick, preserving the query and
    /// the current selection (matched back by text). Unlike `refresh`,
    /// this APPENDS — the streaming counterpart for async producers.
    pub fn appendItems(
        p: *Pick,
        gpa: Allocator,
        texts: []const []const u8,
        docs: ?[]const []const u8,
    ) !void {
        if (!p.active or texts.len == 0) return;
        const keep = p.selection();
        const keep_owned = if (keep) |k| try gpa.dupe(u8, k) else null;
        defer if (keep_owned) |k| gpa.free(k);
        for (texts, 0..) |it, i| {
            const owned = try gpa.dupe(u8, it);
            errdefer gpa.free(owned);
            try p.items.append(gpa, owned);
            const d = if (docs) |ds| ds[i] else "";
            const doc = try gpa.dupe(u8, d);
            errdefer gpa.free(doc);
            try p.docs.append(gpa, doc);
        }
        try p.refilter(gpa);
        if (keep_owned) |k| {
            for (p.filtered.items, 0..) |idx, i| {
                if (std.mem.eql(u8, p.items.items[idx], k)) {
                    p.selected = i;
                    break;
                }
            }
        }
    }

    fn close(self: *Pick, ctx: *command.Context) !void {
        const prev = try ctx.gpa.dupe(u8, self.prev_mode);
        defer ctx.gpa.free(prev);
        self.clear(ctx.gpa);
        try ctx.keymap.setMode(ctx.gpa, prev);
    }

    fn frecOf(self: *const Pick, text: []const u8) Frec {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ self.prompt, text }) catch return .{ .uses = 0, .last = 0 };
        return self.frecency.get(key) orelse .{ .uses = 0, .last = 0 };
    }

    /// Record an acceptance for frecency ranking.
    fn recordUse(self: *Pick, gpa: Allocator, text: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ self.prompt, text }) catch return;
        self.use_counter += 1;
        if (self.frecency.getPtr(key)) |f| {
            f.uses +|= 1;
            f.last = self.use_counter;
            return;
        }
        const owned = gpa.dupe(u8, key) catch return;
        self.frecency.put(gpa, owned, .{ .uses = 1, .last = self.use_counter }) catch gpa.free(owned);
    }

    fn refilter(self: *Pick, gpa: Allocator) !void {
        self.filtered.clearRetainingCapacity();
        const Scored = struct { index: u32, m: Match, frec: Frec };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        const narrowing = self.narrow.items.len > 0;
        for (self.items.items, 0..) |it, i| {
            // Narrowing is a sticky pre-filter (orderless over text or doc);
            // the live query then ranks within the narrowed set.
            if (narrowing and orderlessMatch(self.narrow.items, it) == null and
                orderlessMatch(self.narrow.items, self.docs.items[i]) == null) continue;
            if (matchScore(self.style, self.query.items, it)) |m| {
                try scored.append(gpa, .{
                    .index = @intCast(i),
                    .m = m,
                    .frec = self.frecOf(it),
                });
            }
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                // Word-boundary hits first (acronyms / word starts), then a
                // tighter span, then an earlier first match, then frecency.
                if (a.m.boundaries != b.m.boundaries) return a.m.boundaries > b.m.boundaries;
                if (a.m.span != b.m.span) return a.m.span < b.m.span;
                if (a.m.start != b.m.start) return a.m.start < b.m.start;
                if (a.frec.last != b.frec.last) return a.frec.last > b.frec.last;
                if (a.frec.uses != b.frec.uses) return a.frec.uses > b.frec.uses;
                return a.index < b.index;
            }
        }.lt);
        for (scored.items) |s| try self.filtered.append(gpa, s.index);
        if (self.selected >= self.filtered.items.len) self.selected = 0;
    }

    /// Current choice's text, if any.
    pub fn selection(self: *const Pick) ?[]const u8 {
        if (self.filtered.items.len == 0) return null;
        return self.items.items[self.filtered.items[self.selected]];
    }

    /// The docstring of the `i`-th filtered row.
    pub fn docOf(self: *const Pick, filtered_index: usize) []const u8 {
        return self.docs.items[self.filtered.items[filtered_index]];
    }
};

/// A match: byte span (tightness), first-match index, and how many matched
/// characters landed on a word boundary (start-of-word bonus).
const Match = struct { span: usize, start: usize, boundaries: usize };

fn isSep(c: u8) bool {
    return switch (c) {
        ' ', '-', '_', '/', '.', ':', '\\' => true,
        else => false,
    };
}

fn ciEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// The empty query matches everything at the top.
const empty_match: Match = .{ .span = 0, .start = 0, .boundaries = 0 };

/// Greedy case-insensitive subsequence, scoring word-boundary hits.
fn flexMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    var qi: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    var boundaries: usize = 0;
    for (item, 0..) |ch, i| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            if (first == null) first = i;
            last = i;
            if (i == 0 or isSep(item[i - 1])) boundaries += 1;
            qi += 1;
            if (qi == query.len) return .{ .span = last - first.? + 1, .start = first.?, .boundaries = boundaries };
        }
    }
    return null;
}

fn substringMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    if (item.len < query.len) return null;
    var i: usize = 0;
    while (i + query.len <= item.len) : (i += 1) {
        if (ciEql(item[i .. i + query.len], query)) {
            const at_boundary = i == 0 or isSep(item[i - 1]);
            return .{ .span = query.len, .start = i, .boundaries = @intFromBool(at_boundary) };
        }
    }
    return null;
}

fn prefixMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    if (item.len < query.len or !ciEql(item[0..query.len], query)) return null;
    return .{ .span = query.len, .start = 0, .boundaries = 1 };
}

/// Space-split tokens, each a flex match, matched in any order; scores
/// combine (summed spans/boundaries, earliest start).
fn orderlessMatch(query: []const u8, item: []const u8) ?Match {
    var toks = std.mem.tokenizeScalar(u8, query, ' ');
    var span: usize = 0;
    var start: usize = std.math.maxInt(usize);
    var boundaries: usize = 0;
    var any = false;
    while (toks.next()) |tok| {
        any = true;
        const m = flexMatch(tok, item) orelse return null;
        span += m.span;
        start = @min(start, m.start);
        boundaries += m.boundaries;
    }
    if (!any) return empty_match; // whitespace-only query
    return .{ .span = span, .start = start, .boundaries = boundaries };
}

fn matchScore(style: Style, query: []const u8, item: []const u8) ?Match {
    return switch (style) {
        .orderless => orderlessMatch(query, item),
        .flex => flexMatch(query, item),
        .substring => substringMatch(query, item),
        .prefix => prefixMatch(query, item),
    };
}

/// Back-compat thin wrapper (flex span) for the tightness test.
fn matchSpan(query: []const u8, item: []const u8) ?usize {
    return if (flexMatch(query, item)) |m| m.span else null;
}

// ── The candidate pool + matcher seam (design §5/§8, plan 02 P9) ─────

/// An append-only, columnar candidate pool — the single native primitive
/// under the pick loop. Sources push BATCHES (never one item across a
/// boundary; the footgun rule); a matcher ranks the WHOLE pool in one bulk
/// call per keystroke and returns `u32[]` ranked indices. Append-only makes
/// "the set changed under the matcher" inexpressible — the same inversion
/// the CRDT gives text. `version` advances on every append so a matcher's
/// mirror knows in O(1) that its copy is stale; `scope` is always `.local`
/// (your palette is not my palette — what's shared is only the consequence
/// of ACCEPTING, a versioned edit the CRDT merges).
///
/// The built-in `rank` here IS the fallback matcher; a guest `pick/matcher`
/// (plan 05, wasm) is a one-line swap that never crosses the bright line
/// (host invoking guest N=candidate-count times) — it scans its own mirror
/// once and hands back the ranked array.
pub const Pool = struct {
    /// All candidate text concatenated; the columns index into it.
    blob: std.ArrayList(u8) = .empty,
    /// Per-candidate `[start,end)` into `blob`.
    spans: std.ArrayList(Span) = .empty,
    /// Per-candidate metadata (source identity, an opaque accept key, and
    /// an optional document anchor so a candidate that names a position
    /// rebases through edits — the anchor column, [FIX 1]).
    meta: std.ArrayList(Meta) = .empty,
    /// Bumped on every content change; a matcher mirror polls it.
    version: u64 = 0,

    pub const scope: layers_scope = .local;
    const layers_scope = @import("layers.zig").Scope;

    pub const Span = struct { start: u32, end: u32 };
    pub const Meta = struct {
        source_id: u32,
        /// Resolved at accept (embark: `{source_id,key}` → the real target).
        key: u64 = 0,
        /// A live document anchor for a candidate whose target is a
        /// position; resolve with `doc.anchorOffset` at accept time.
        anchor: ?stemma.AnchorSet.Handle = null,
    };

    pub const empty: Pool = .{};

    pub fn deinit(self: *Pool, gpa: Allocator) void {
        self.blob.deinit(gpa);
        self.spans.deinit(gpa);
        self.meta.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const Pool) usize {
        return self.spans.items.len;
    }

    /// The `i`-th candidate's text (borrowed; valid until the next append).
    pub fn text(self: *const Pool, i: usize) []const u8 {
        const s = self.spans.items[i];
        return self.blob.items[s.start..s.end];
    }

    /// Append a batch of candidates from one source. The ONLY ingest path —
    /// sources always batch. `keys`, if given, are the per-candidate accept
    /// keys (else 0). Bumps `version`.
    pub fn appendBatch(self: *Pool, gpa: Allocator, texts: []const []const u8, source_id: u32, keys: ?[]const u64) Allocator.Error!void {
        try self.blob.ensureUnusedCapacity(gpa, blk: {
            var n: usize = 0;
            for (texts) |txt| n += txt.len;
            break :blk n;
        });
        try self.spans.ensureUnusedCapacity(gpa, texts.len);
        try self.meta.ensureUnusedCapacity(gpa, texts.len);
        for (texts, 0..) |txt, i| {
            const start: u32 = @intCast(self.blob.items.len);
            self.blob.appendSliceAssumeCapacity(txt);
            self.spans.appendAssumeCapacity(.{ .start = start, .end = @intCast(self.blob.items.len) });
            self.meta.appendAssumeCapacity(.{ .source_id = source_id, .key = if (keys) |k| k[i] else 0 });
        }
        self.version +%= 1;
    }

    /// Attach a document anchor to candidate `i` (the anchor column).
    pub fn setAnchor(self: *Pool, i: usize, anchor: stemma.AnchorSet.Handle) void {
        self.meta.items[i].anchor = anchor;
    }

    /// Rank the whole pool against `query` in ONE call and return ranked
    /// candidate indices, best first (non-matches dropped). Caller frees.
    /// The same order the live pick uses (word-boundary, tightness, earliest
    /// start, then stable by index) minus frecency (a pool has no history).
    pub fn rank(self: *const Pool, gpa: Allocator, style: Style, query: []const u8) Allocator.Error![]u32 {
        const Scored = struct { index: u32, m: Match };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (0..self.count()) |i| {
            if (matchScore(style, query, self.text(i))) |m| {
                try scored.append(gpa, .{ .index = @intCast(i), .m = m });
            }
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                if (a.m.boundaries != b.m.boundaries) return a.m.boundaries > b.m.boundaries;
                if (a.m.span != b.m.span) return a.m.span < b.m.span;
                if (a.m.start != b.m.start) return a.m.start < b.m.start;
                return a.index < b.index;
            }
        }.lt);
        const out = try gpa.alloc(u32, scored.items.len);
        for (scored.items, out) |s, *o| o.* = s.index;
        return out;
    }
};

test "pick pool: append batches, rank 100k in one call, anchor rebases" {
    const gpa = std.testing.allocator;
    var pool: Pool = .empty;
    defer pool.deinit(gpa);

    // 100k candidates pushed in batches (never one across a boundary).
    var batch: [1000][]const u8 = undefined;
    var buf: [1000][16]u8 = undefined;
    var b: usize = 0;
    while (b < 100) : (b += 1) {
        for (0..1000) |i| batch[i] = try std.fmt.bufPrint(&buf[i], "cand{d}_{d}", .{ b, i });
        try pool.appendBatch(gpa, &batch, @intCast(b), null);
    }
    try pool.appendBatch(gpa, &.{"zzTARGETzz"}, 999, null); // the needle
    try std.testing.expectEqual(@as(usize, 100_001), pool.count());
    const v_before = pool.version;

    // One bulk rank ranks the whole pool; only the needle matches "TARGET".
    const ranked = try pool.rank(gpa, .orderless, "TARGET");
    defer gpa.free(ranked);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("zzTARGETzz", pool.text(ranked[0]));
    try std.testing.expectEqual(v_before, pool.version); // rank is read-only

    // The anchor column: a candidate anchored into a live doc rebases.
    const Document = @import("Document.zig");
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "abcdef");
    pool.setAnchor(ranked[0], try doc.addAnchor(gpa, 3, .right));
    try doc.insert(gpa, 0, "XX"); // shift everything right by two
    try std.testing.expectEqual(@as(usize, 5), doc.anchorOffset(pool.meta.items[ranked[0]].anchor.?));
}

// ── Commands ────────────────────────────────────────────────────────

fn pickOf(ctx: *command.Context) *Pick {
    return ctx.pick;
}

/// Promote the current query into the sticky narrowing filter and clear
/// the query — a consult-style live narrow. Repeated calls AND facets.
fn cNarrow(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    const q = std.mem.trim(u8, p.query.items, " ");
    if (q.len == 0) return .nil;
    if (p.narrow.items.len > 0) try p.narrow.append(ctx.gpa, ' ');
    try p.narrow.appendSlice(ctx.gpa, q);
    p.query.clearRetainingCapacity();
    try p.refilter(ctx.gpa); // local: narrowing does not re-run the source
    return .nil;
}

/// Drop the narrowing filter.
fn cWiden(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.narrow.items.len == 0) return .nil;
    p.narrow.clearRetainingCapacity();
    try p.refilter(ctx.gpa);
    return .nil;
}

/// Cycle the completion style (orderless → flex → substring → prefix → …).
fn cStyleCycle(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    p.style = switch (p.style) {
        .orderless => .flex,
        .flex => .substring,
        .substring => .prefix,
        .prefix => .orderless,
    };
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cInput(ctx: *command.Context, args: struct { text: []const u8 }) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    try p.query.appendSlice(ctx.gpa, args.text);
    p.queryChanged();
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cBackspace(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    while (p.query.items.len > 0) {
        const b = p.query.items[p.query.items.len - 1];
        p.query.items.len -= 1;
        if (b & 0xC0 != 0x80) break; // whole scalar removed
    }
    p.queryChanged();
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cNext(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active and p.filtered.items.len > 0) {
        p.selected = (p.selected + 1) % p.filtered.items.len;
    }
    return .nil;
}

fn cPrev(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active and p.filtered.items.len > 0) {
        p.selected = (p.selected + p.filtered.items.len - 1) % p.filtered.items.len;
    }
    return .nil;
}

fn cCancel(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active) try p.close(ctx);
    return .nil;
}

/// Tab: complete the query — to the longest common prefix of the
/// matches when that extends it, else to the selected item.
fn cComplete(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active or p.filtered.items.len == 0) return .nil;
    var lcp = p.items.items[p.filtered.items[0]];
    for (p.filtered.items[1..]) |idx| {
        const it = p.items.items[idx];
        var n: usize = 0;
        while (n < @min(lcp.len, it.len) and std.ascii.toLower(lcp[n]) == std.ascii.toLower(it[n])) n += 1;
        lcp = lcp[0..n];
    }
    const target = if (lcp.len > p.query.items.len) lcp else p.selection().?;
    p.query.clearRetainingCapacity();
    try p.query.appendSlice(ctx.gpa, target);
    p.queryChanged();
    try p.refilter(ctx.gpa);
    return .nil;
}

/// Accept `text` as the choice: hand the acceptor a stable copy and
/// close FIRST (the acceptor may open another pick), then run it. The
/// close-before-call dance is the whole reason this is factored out.
fn acceptText(p: *Pick, ctx: *command.Context, text: []const u8) !void {
    const choice = try ctx.gpa.dupe(u8, text);
    defer ctx.gpa.free(choice);
    p.recordUse(ctx.gpa, text);
    const acceptor = p.acceptor.?;
    p.acceptor = null; // close() must not run cleanup before the call
    try p.close(ctx);
    defer if (acceptor.cleanup) |f| f(acceptor.data, ctx.gpa);
    try acceptor.handler(ctx, acceptor.data, choice);
}

fn cAccept(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.selection()) |sel| {
        try acceptText(p, ctx, sel);
    } else if (p.allow_free_text and p.query.items.len > 0) {
        try acceptText(p, ctx, p.query.items);
    } else {
        try p.close(ctx);
    }
    return .nil;
}

/// Accept the typed query verbatim, even when it matches a candidate —
/// the "I mean this literal text" key (C-j / S-Return). Falls back to
/// candidate acceptance when free text is not allowed.
fn cAcceptInput(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.allow_free_text and p.query.items.len > 0) {
        try acceptText(p, ctx, p.query.items);
        return .nil;
    }
    return cAccept(ctx, .{});
}

/// The command palette: pick over every command (summary as the
/// docstring), run the choice.
fn cPalette(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(ctx.gpa);
    for (0..ctx.commands.count()) |i| {
        const n: command.Commands.Name = @enumFromInt(i);
        if (ctx.commands.lookup(n)) |cmd| {
            try entries.append(ctx.gpa, .{ .text = ctx.commands.nameOf(n), .doc = cmd.summary });
        }
    }
    try ctx.pick.open(ctx, "command", entries.items, .{ .handler = runChoice });
    return .nil;
}

fn runChoice(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = data;
    _ = command.run(ctx.commands, ctx, choice, &.{}) catch |err| {
        std.log.warn("palette: {s} failed: {t}", .{ choice, err });
    };
}

/// Register pick commands + the "pick" mode bindings.
pub fn install(gpa: Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig")) !void {
    const defs = [_]command.Command{
        command.define("pick-input", "Append text to the pick query.", cInput),
        command.define("pick-backspace", "Delete the last query character.", cBackspace),
        command.define("pick-next", "Select the next match.", cNext),
        command.define("pick-prev", "Select the previous match.", cPrev),
        command.define("pick-accept", "Accept the selected match (else the typed text, if free-text).", cAccept),
        command.define("pick-accept-input", "Accept the typed text verbatim (free-text picks).", cAcceptInput),
        command.define("pick-cancel", "Close the picker.", cCancel),
        command.define("pick-complete", "Complete the query (common prefix, else selection).", cComplete),
        command.define("pick-commands", "Open the command palette.", cPalette),
        command.define("pick-narrow", "Promote the query into a sticky narrowing filter.", cNarrow),
        command.define("pick-widen", "Drop the narrowing filter.", cWiden),
        command.define("pick-style-cycle", "Cycle the completion style (orderless/flex/substring/prefix).", cStyleCycle),
    };
    for (defs) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    const binds = [_][2][]const u8{
        .{ "Return", "pick-accept" },
        .{ "Escape", "pick-cancel" },
        .{ "C-g", "pick-cancel" },
        .{ "BackSpace", "pick-backspace" },
        .{ "Down", "pick-next" },
        .{ "Up", "pick-prev" },
        .{ "C-n", "pick-next" },
        .{ "C-p", "pick-prev" },
        .{ "Tab", "pick-complete" },
        .{ "C-j", "pick-accept-input" },
        .{ "S-Return", "pick-accept-input" },
    };
    for (binds) |b| try keymap.bind(gpa, "pick", b[0], b[1]);
    try keymap.setTextCommand(gpa, "pick", "pick-input");
    _ = try commands.bind(gpa, "palette", (comptime command.define("palette", "Open the command palette.", cPalette)));
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "matchSpan: subsequence with tightness" {
    try t.expectEqual(@as(?usize, 0), matchSpan("", "anything"));
    try t.expectEqual(@as(?usize, null), matchSpan("xyz", "cursor-left"));
    try t.expectEqual(@as(?usize, 4), matchSpan("save", "save"));
    try t.expect(matchSpan("cl", "cursor-left") != null);
    try t.expect(matchSpan("CL", "cursor-left") != null);
}

test "match styles: orderless, prefix, substring, boundary bonus" {
    // orderless — tokens in any order, each a subsequence.
    try t.expect(orderlessMatch("file open", "open-file") != null);
    try t.expect(orderlessMatch("open file", "open-file") != null);
    try t.expect(orderlessMatch("file open", "file-open") != null);
    try t.expect(orderlessMatch("open", "profile") == null); // no "open"

    // prefix — anchored at the start.
    try t.expect(prefixMatch("open", "open-file") != null);
    try t.expect(prefixMatch("open", "file-open") == null);

    // substring — one contiguous run.
    try t.expect(substringMatch("en-f", "open-file") != null);
    try t.expect(substringMatch("enf", "open-file") == null);

    // boundary bonus: "of" hits two word-starts in open-file, none in profile.
    try t.expect(flexMatch("of", "open-file").?.boundaries > flexMatch("of", "profile").?.boundaries);
}

test "pick refilter: boundary ranking and sticky narrowing" {
    const gpa = t.allocator;
    var p: Pick = .empty;
    defer p.deinit(gpa);
    const items = [_][]const u8{ "profile", "open-file", "file-open", "close-buffer" };
    for (items) |s| {
        try p.items.append(gpa, try gpa.dupe(u8, s));
        try p.docs.append(gpa, try gpa.dupe(u8, ""));
    }

    const H = struct {
        fn has(pk: *const Pick, s: []const u8) bool {
            for (pk.filtered.items) |fi| if (std.mem.eql(u8, pk.items.items[fi], s)) return true;
            return false;
        }
    };

    // flex "of": open-file ranks above profile (two word-boundary hits).
    p.style = .flex;
    try p.query.appendSlice(gpa, "of");
    try p.refilter(gpa);
    try t.expect(p.filtered.items.len >= 2);
    try t.expectEqualStrings("open-file", p.items.items[p.filtered.items[0]]);

    // orderless "file open" → both -file/-open words, never profile.
    p.style = .orderless;
    p.query.clearRetainingCapacity();
    try p.query.appendSlice(gpa, "file open");
    try p.refilter(gpa);
    try t.expectEqual(@as(usize, 2), p.filtered.items.len);
    try t.expect(H.has(&p, "open-file") and H.has(&p, "file-open"));

    // Narrow to "file", then query "open": the sticky filter AND the query.
    p.query.clearRetainingCapacity();
    try p.narrow.appendSlice(gpa, "file");
    try p.query.appendSlice(gpa, "open");
    try p.refilter(gpa);
    try t.expect(H.has(&p, "open-file") and H.has(&p, "file-open"));
    try t.expect(!H.has(&p, "close-buffer")); // no "file"
}

test {
    std.testing.refAllDecls(@This());
}

// A heap-stable editor context for driving the picker in tests (Context
// holds pointers into these fields, so the env must not move).
const TestEnv = struct {
    gpa: Allocator,
    pool: *task.Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands = .empty,
    keymap: @import("Keymap.zig") = .empty,
    caps: @import("capability.zig").Caps,
    quit: bool = false,
    echo: std.ArrayList(u8) = .empty,
    pick: Pick = .empty,

    fn init(gpa: Allocator) !*TestEnv {
        const pool = try task.Pool.init(gpa, .{ .threads = 1 });
        const self = try gpa.create(TestEnv);
        self.* = .{
            .gpa = gpa,
            .pool = pool,
            .buffers = try @import("Buffers.zig").init(gpa, pool, "user"),
            .caps = @import("capability.zig").Caps.init(gpa, task.nowNs),
        };
        return self;
    }

    fn ctx(self: *TestEnv) command.Context {
        return .{
            .gpa = self.gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
    }

    fn deinit(self: *TestEnv) void {
        const gpa = self.gpa;
        self.pick.deinit(gpa);
        self.echo.deinit(gpa);
        self.caps.deinit();
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self);
    }
};

const Sink = struct {
    got: std.ArrayList(u8) = .empty,
    called: bool = false,
    fn accept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
        const s: *Sink = @ptrCast(@alignCast(data.?));
        s.called = true;
        s.got.clearRetainingCapacity();
        try s.got.appendSlice(ctx.gpa, choice);
    }
};

test "pick: free-text accept — typed query when nothing matches" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.pick.openWith(&ctx, "read", &.{.{ .text = "apple" }}, .{
        .handler = Sink.accept,
        .data = &sink,
    }, .{ .allow_free_text = true });
    _ = try cInput(&ctx, .{ .text = "zzz" }); // matches nothing
    try t.expect(env.pick.selection() == null);
    _ = try cAccept(&ctx, .{});
    try t.expect(sink.called);
    try t.expectEqualStrings("zzz", sink.got.items);
    try t.expect(!env.pick.active);
}

test "pick: free-text off — no candidate means no acceptance" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.pick.open(&ctx, "cmd", &.{.{ .text = "apple" }}, .{
        .handler = Sink.accept,
        .data = &sink,
    });
    _ = try cInput(&ctx, .{ .text = "zzz" });
    _ = try cAccept(&ctx, .{});
    try t.expect(!sink.called);
    try t.expect(!env.pick.active);
}

test "pick: appendItems preserves query and selection" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.pick.open(&ctx, "p", &.{
        .{ .text = "one" }, .{ .text = "two" }, .{ .text = "three" },
    }, .{ .handler = Sink.accept, .data = &sink });
    _ = try cNext(&ctx, .{}); // select "two"
    try t.expectEqualStrings("two", env.pick.selection().?);
    try env.pick.appendItems(gpa, &.{"four"}, null);
    try t.expectEqual(@as(usize, 4), env.pick.items.items.len);
    try t.expectEqualStrings("two", env.pick.selection().?);
}

const FakeSrc = struct {
    polls: usize = 0,
    closes: usize = 0,
    query_fires: usize = 0,
    emitted: bool = false,
    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.polls += 1;
        if (s.emitted) return false;
        s.emitted = true;
        try ctx.pick.appendItems(ctx.gpa, &.{ "alpha", "beta" }, null);
        return true;
    }
    fn close(data: ?*anyopaque, gpa: Allocator) void {
        _ = gpa;
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.closes += 1;
    }
    fn onQuery(data: ?*anyopaque, ctx: *command.Context, query: []const u8, epoch: u64) anyerror!void {
        _ = ctx;
        _ = query;
        _ = epoch;
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.query_fires += 1;
    }
};

test "pick: async source — poll folds, onQuery on change, close once" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var fake: FakeSrc = .{};
    var ctx = env.ctx();

    try env.pick.openWith(&ctx, "src", &.{}, .{
        .handler = Sink.accept,
        .data = &sink,
    }, .{ .source = .{
        .data = &fake,
        .poll = FakeSrc.poll,
        .close = FakeSrc.close,
        .onQuery = FakeSrc.onQuery,
        .debounce_ns = 0,
    } });

    try t.expect(try env.pick.tick(&ctx)); // poll emits
    try t.expectEqual(@as(usize, 2), env.pick.items.items.len);
    try t.expect(!try env.pick.tick(&ctx)); // nothing new
    try t.expectEqual(@as(usize, 0), fake.query_fires); // no query change yet

    _ = try cInput(&ctx, .{ .text = "a" });
    _ = try env.pick.tick(&ctx);
    try t.expectEqual(@as(usize, 1), fake.query_fires); // fired on change

    _ = try cCancel(&ctx, .{});
    try t.expectEqual(@as(usize, 1), fake.closes);
    try t.expect(!env.pick.active);
}

/// Replace the item set of a live pick, preserving query and selection
/// (race-and-refine consumers call this as results land).
pub fn refresh(p: *Pick, gpa: Allocator, items: []const []const u8) !void {
    if (!p.active) return;
    const keep = p.selection();
    const keep_owned = if (keep) |k| try gpa.dupe(u8, k) else null;
    defer if (keep_owned) |k| gpa.free(k);
    for (p.items.items) |it| gpa.free(it);
    p.items.clearRetainingCapacity();
    for (p.docs.items) |d| gpa.free(d);
    p.docs.clearRetainingCapacity();
    for (items) |it| {
        const owned = try gpa.dupe(u8, it);
        errdefer gpa.free(owned);
        try p.items.append(gpa, owned);
        const doc = try gpa.dupe(u8, "");
        errdefer gpa.free(doc);
        try p.docs.append(gpa, doc);
    }
    try p.refilter(gpa);
    if (keep_owned) |k| {
        for (p.filtered.items, 0..) |idx, i| {
            if (std.mem.eql(u8, p.items.items[idx], k)) {
                p.selected = i;
                break;
            }
        }
    }
}
