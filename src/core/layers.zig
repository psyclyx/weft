//! Annotation layers — the feed substrate. A layer is a named,
//! scope-tagged store of annotations over one document, owned by
//! exactly one feed provider and read by any consumer (the view,
//! location lists, …). Two storage forms, because annotation densities
//! genuinely differ:
//!
//! - **spans** — sparse anchored ranges (diagnostics, presence,
//!   lenses). Anchors live in the document's auto-shifted AnchorSet,
//!   so spans stay valid at the head with zero per-frame work.
//! - **bulk** — a dense stamped region (highlight paint: class-per-byte
//!   over a range). Consumers rebase the region wholesale or treat a
//!   stale one as slightly-old truth — for highlights that is correct
//!   and invisible.
//!
//! Feeds are droppable by definition: replacing a layer's content is
//! the only write operation; nothing here can block or accumulate
//! unboundedly.
//!
//! Scopes: `local` (this process), `host` (computed on the document's
//! host peer), `replicated` (every peer sees it). Until the wire lands
//! (phase-2 workstream 4) scope is routing metadata; the storage is
//! identical.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const Document = @import("Document.zig");

pub const Scope = enum { local, host, replicated };

/// What a layer IS to a presentation. A `builtin` feed is one core's own
/// render paths read by name (styles, folds, decorations, presence, …); an
/// `annotation` feed is the third-party decoration package
/// (doc/contextual-workspace-architecture.md §11.7) — published against an
/// entry the provider does not own, revision-stamped, and composited
/// generically by whatever presentation hosts the entry. A name never
/// changes class: claiming one across the classes is refused, so a decorator
/// cannot take over `styles` and paint through core's own path.
pub const Feed = enum { builtin, annotation };

/// How a span presents (plan 02 P8). `range` (default) is the classic
/// anchored face painted over `[start, end)`. The rest are decorations
/// anchored at `start`, drawn beside the text rather than over it, with
/// `message` as their display string: `virtual_before`/`virtual_after`
/// insert display-only text at the offset (never in the document, so no
/// commit, no sync — pure local overlay), `eol` floats it at the line end
/// (inlay hints, blame), `gutter` shows it in the margin (breakpoints,
/// diagnostics severity, fold arrows), `overlay` draws it OVER the cells
/// starting at `start` (jump labels) without moving any text. One
/// anchored-annotation type covers all of them — the density split is
/// spans-vs-bulk, not a third store.
pub const Placement = enum(u8) { range, virtual_before, virtual_after, eol, gutter, overlay };

/// Presentation attributes orthogonal to the `kind` a span carries: does
/// the range fold, is it hidden (folded/concealed), does it respond to a
/// click. Packed to one byte so it rides every span for free.
pub const Face = packed struct(u8) {
    foldable: bool = false,
    invisible: bool = false,
    clickable: bool = false,
    _pad: u5 = 0,
};

/// The one sanctioned `replicated` layer: presence. Its relay across the
/// wire IS built (session/hub); every other replicated layer is unwired and
/// must trap (see `Layers.claim` and design [FIX 10]) until the replicated
/// feed is grant-keyed end-to-end.
pub const presence_layer = "presence";

pub const SpanIn = struct {
    start: usize,
    end: usize,
    kind: u32,
    message: []const u8,
    /// How to present it (default: a face over the range). Decorations
    /// (virtual text / gutter) anchor at `start` and use `message` as text.
    placement: Placement = .range,
    /// Presentation flags (fold/hide/click), independent of `kind`.
    face: Face = .{},
};

pub const Span = struct {
    start: stemma.AnchorSet.Handle,
    end: stemma.AnchorSet.Handle,
    /// Consumer-interpreted kind (profile constants: diagnostics use
    /// severity 1–4; presence uses peer index; etc.).
    kind: u32,
    /// Owned by the layer.
    message: []u8 = &.{},
    placement: Placement = .range,
    face: Face = .{},
};

pub const Bulk = struct {
    /// Version the paint was computed against (owned).
    version: []u8,
    start: usize,
    /// One class byte per document byte in [start, start+classes.len).
    classes: []u8,
};

pub const Layer = struct {
    name: []u8,
    scope: Scope,
    provider: []u8,
    doc: *Document,
    feed: Feed = .builtin,
    /// The entry revision an ANNOTATION feed's spans were computed against
    /// (`begin` stamps it; a builtin feed is unstamped). Once the entry moves
    /// past it the spans no longer resolve, and `spanCount` reports none until
    /// the provider republishes — dropped, never guessed (§11.7).
    stamp: ?Document.Revision = null,
    /// The round was opened to last until the next key (`beginUntilKey`):
    /// dispatch drops its spans when the next key arrives
    /// (`Layers.expireUntilKey`) — a search's highlights, gone the moment
    /// you do anything else.
    until_key: bool = false,
    spans: std.ArrayList(Span) = .empty,
    bulk: ?Bulk = null,

    fn clearSpans(self: *Layer, gpa: Allocator) void {
        for (self.spans.items) |s| {
            self.doc.removeAnchor(s.start);
            self.doc.removeAnchor(s.end);
            gpa.free(s.message);
        }
        self.spans.clearRetainingCapacity();
    }

    fn clearBulk(self: *Layer, gpa: Allocator) void {
        if (self.bulk) |b| {
            gpa.free(b.version);
            gpa.free(b.classes);
            self.bulk = null;
        }
    }

    fn deinit(self: *Layer, gpa: Allocator) void {
        self.clearSpans(gpa);
        self.clearBulk(gpa);
        self.spans.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.provider);
    }

    /// Replace the span set. Ranges are anchored immediately (they must
    /// be valid at the current head — remote publishers rebase before
    /// calling; that adapter lives with the wire).
    pub fn publishSpans(self: *Layer, gpa: Allocator, spans: []const SpanIn) !void {
        self.clearSpans(gpa);
        for (spans) |s| {
            const a = try self.doc.addAnchor(gpa, s.start, .right);
            errdefer self.doc.removeAnchor(a);
            const b = try self.doc.addAnchor(gpa, @max(s.start, s.end), .left);
            errdefer self.doc.removeAnchor(b);
            try self.spans.append(gpa, .{
                .start = a,
                .end = b,
                .kind = s.kind,
                .message = try gpa.dupe(u8, s.message),
                .placement = s.placement,
                .face = s.face,
            });
        }
    }

    /// Append ONE anchored span to the existing set (unlike publishSpans,
    /// which replaces). For feeds a plugin streams incrementally after a
    /// clear — e.g. folds: `clear` then one `appendSpan` per hidden range.
    pub fn appendSpan(self: *Layer, gpa: Allocator, s: SpanIn) !void {
        const a = try self.doc.addAnchor(gpa, s.start, .right);
        errdefer self.doc.removeAnchor(a);
        const b = try self.doc.addAnchor(gpa, @max(s.start, s.end), .left);
        errdefer self.doc.removeAnchor(b);
        try self.spans.append(gpa, .{
            .start = a,
            .end = b,
            .kind = s.kind,
            .message = try gpa.dupe(u8, s.message),
            .placement = s.placement,
            .face = s.face,
        });
    }

    /// Replace the bulk region (takes ownership of nothing; copies).
    pub fn publishBulk(self: *Layer, gpa: Allocator, version_token: []const u8, start: usize, classes: []const u8) !void {
        const v = try gpa.dupe(u8, version_token);
        errdefer gpa.free(v);
        const c = try gpa.dupe(u8, classes);
        errdefer gpa.free(c);
        self.clearBulk(gpa);
        self.bulk = .{ .version = v, .start = start, .classes = c };
    }

    pub const ResolvedSpan = struct {
        start: usize,
        end: usize,
        kind: u32,
        message: []const u8,
        placement: Placement = .range,
        face: Face = .{},
    };

    /// Open an annotation round: drop the previous set and stamp the entry
    /// revision the incoming spans are computed against. Spans appended after
    /// this paint only while the entry is still at that revision.
    pub fn begin(self: *Layer, gpa: Allocator) void {
        self.clearSpans(gpa);
        self.stamp = self.doc.revision();
        self.until_key = false;
    }

    /// `begin`, for a round that lasts only until the next key: the entry
    /// revision still gates it, and the next dispatched key ends it.
    pub fn beginUntilKey(self: *Layer, gpa: Allocator) void {
        self.begin(gpa);
        self.until_key = true;
    }

    /// Whether this feed's spans still resolve against the entry revision they
    /// were published for. A builtin feed always resolves — its anchors ARE
    /// its truth. An ANNOTATION feed resolves only inside a round it stamped,
    /// so skipping `begin` publishes nothing rather than publishing something
    /// staleness can never catch up with.
    pub fn resolves(self: *const Layer) bool {
        const stamp = self.stamp orelse return self.feed == .builtin;
        return stamp == self.doc.revision();
    }

    /// Spans at the current head (anchors already shifted).
    pub fn resolvedSpan(self: *const Layer, i: usize) ResolvedSpan {
        const s = self.spans.items[i];
        return .{
            .start = self.doc.anchorOffset(s.start),
            .end = self.doc.anchorOffset(s.end),
            .kind = s.kind,
            .message = s.message,
            .placement = s.placement,
            .face = s.face,
        };
    }

    /// Spans a CONSUMER may paint: none while the feed is stale, so every
    /// consumer (view, gutter, status line, location list) drops a stale
    /// annotation without each having to remember the rule.
    pub fn spanCount(self: *const Layer) usize {
        return if (self.resolves()) self.spans.items.len else 0;
    }

    /// This layer as of now, over `window`: what a frame draws from
    /// (doc/model.md §2.7). Every span a consumer may paint (`spanCount`)
    /// that touches the window, resolved to offsets, and the bulk paint
    /// clipped to it — copied into `arena`, so a later edit, republish or
    /// release leaves the snapshot as it was. `gutter`-placed spans are kept
    /// wherever they are: one anywhere in the entry sizes the sign column on
    /// every row. Messages are copied too; nothing in a snapshot points back
    /// into the layer.
    pub fn snapshot(self: *const Layer, arena: Allocator, window: stemma.Range) Allocator.Error!Snapshot {
        var spans: std.ArrayList(ResolvedSpan) = .empty;
        for (0..self.spanCount()) |i| {
            var s = self.resolvedSpan(i);
            if (s.placement != .gutter and (s.end < window.start or s.start > window.end)) continue;
            s.message = try arena.dupe(u8, s.message);
            try spans.append(arena, s);
        }
        const bulk: ?Snapshot.Paint = if (self.bulk) |b| blk: {
            const from = @max(b.start, window.start);
            const to = @min(b.start + b.classes.len, window.end);
            if (from >= to) break :blk null;
            break :blk .{ .start = from, .classes = try arena.dupe(u8, b.classes[from - b.start .. to - b.start]) };
        } else null;
        return .{ .spans = spans.items, .bulk = bulk };
    }
};

/// A layer as of one revision, over one window (`Layer.snapshot`): plain
/// data, read through the same `spanCount`/`resolvedSpan`/`bulk` a live
/// layer offers, and owned by whoever allocated it. A frame draws from these,
/// never from a live `Layer`, so nothing that runs while it draws — or after,
/// before it is shown — can move what it reads. A peer that rendered a view
/// would receive exactly this.
pub const Snapshot = struct {
    spans: []const Layer.ResolvedSpan = &.{},
    bulk: ?Paint = null,

    /// Bulk paint over `[start, start + classes.len)`.
    pub const Paint = struct {
        start: usize,
        classes: []const u8,
    };

    pub fn spanCount(self: *const Snapshot) usize {
        return self.spans.len;
    }

    pub fn resolvedSpan(self: *const Snapshot, i: usize) Layer.ResolvedSpan {
        return self.spans[i];
    }
};

/// All layers of one editor session, keyed by (document, name) — the
/// multi-buffer index: each buffer's providers claim under its own
/// document; the view reads the active document's layers.
pub const Layers = struct {
    list: std.ArrayList(*Layer) = .empty,

    pub const empty: Layers = .{};

    pub fn deinit(self: *Layers, gpa: Allocator) void {
        for (self.list.items) |l| {
            l.deinit(gpa);
            gpa.destroy(l);
        }
        self.list.deinit(gpa);
        self.* = .{};
    }

    /// Get-or-create the layer `(doc, name)` owned by `provider`.
    /// Re-claiming a name from a different provider replaces its
    /// content ownership (last registration wins, like the command
    /// registry) — but never across feed classes (`error.Reserved`).
    pub const ClaimError = Allocator.Error || error{ Unimplemented, Reserved };

    pub fn claim(self: *Layers, gpa: Allocator, doc: *Document, name: []const u8, scope: Scope, provider: []const u8) ClaimError!*Layer {
        return self.claimFeed(gpa, doc, name, scope, provider, .builtin);
    }

    /// Claim a THIRD-PARTY annotation feed on any entry the provider can
    /// reference (§11.7). Local scope: an annotation is a view of the entry,
    /// not content, so it neither commits nor replicates. Ownership is
    /// per-name, as for every layer, and a builtin name is refused.
    pub fn claimAnnotation(self: *Layers, gpa: Allocator, doc: *Document, name: []const u8, provider: []const u8) ClaimError!*Layer {
        return self.claimFeed(gpa, doc, name, .local, provider, .annotation);
    }

    fn claimFeed(self: *Layers, gpa: Allocator, doc: *Document, name: []const u8, scope: Scope, provider: []const u8, feed: Feed) ClaimError!*Layer {
        // [FIX 10] Replicated state is not yet grant-keyed on the wire. Only
        // presence (whose relay is wired) may claim `replicated`; any other
        // replicated claim traps rather than silently degrading to a local
        // layer nobody else will ever see — a speced-but-unwired feature
        // must fail loudly, not no-op.
        if (scope == .replicated and !std.mem.eql(u8, name, presence_layer))
            return error.Unimplemented;
        for (self.list.items) |l| {
            if (l.doc == doc and std.mem.eql(u8, l.name, name)) {
                if (l.feed != feed) return error.Reserved;
                if (!std.mem.eql(u8, l.provider, provider)) {
                    gpa.free(l.provider);
                    l.provider = try gpa.dupe(u8, provider);
                    l.clearSpans(gpa);
                    l.clearBulk(gpa);
                    l.stamp = null;
                }
                return l;
            }
        }
        const l = try gpa.create(Layer);
        errdefer gpa.destroy(l);
        l.* = .{
            .name = try gpa.dupe(u8, name),
            .scope = scope,
            .provider = try gpa.dupe(u8, provider),
            .doc = doc,
            .feed = feed,
        };
        try self.list.append(gpa, l);
        return l;
    }

    pub fn find(self: *const Layers, doc: *const Document, name: []const u8) ?*Layer {
        for (self.list.items) |l| {
            if (l.doc == doc and std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    /// The annotation feeds over `doc`, in claim order — what a presentation
    /// composites on top of the entry's own paint. Caller owns the slice.
    pub fn annotations(self: *const Layers, gpa: Allocator, doc: *const Document) Allocator.Error![]const *const Layer {
        var out: std.ArrayList(*const Layer) = .empty;
        errdefer out.deinit(gpa);
        for (self.list.items) |l| {
            if (l.doc == doc and l.feed == .annotation) try out.append(gpa, l);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Drop one provider's layer — the decorator going away takes its paint
    /// with it and touches nothing else. A name owned by somebody else (a
    /// later claim won it) is left alone.
    pub fn release(self: *Layers, gpa: Allocator, doc: *const Document, name: []const u8, provider: []const u8) void {
        for (self.list.items, 0..) |l, i| {
            if (l.doc != doc or !std.mem.eql(u8, l.name, name)) continue;
            if (!std.mem.eql(u8, l.provider, provider)) return;
            l.deinit(gpa);
            gpa.destroy(l);
            _ = self.list.swapRemove(i);
            return;
        }
    }

    /// A key arrived: every round opened to last until the next key is over.
    /// Its spans go; the layer stays claimed for the provider's next round.
    pub fn expireUntilKey(self: *Layers, gpa: Allocator) void {
        for (self.list.items) |l| {
            if (!l.until_key) continue;
            l.clearSpans(gpa);
            l.until_key = false;
        }
    }

    /// Drop every layer of `doc` (buffer close).
    pub fn dropDoc(self: *Layers, gpa: Allocator, doc: *const Document) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const l = self.list.items[i];
            if (l.doc == doc) {
                l.deinit(gpa);
                gpa.destroy(l);
                _ = self.list.swapRemove(i);
            } else i += 1;
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "layers: a round opened until the next key ends at the next key, and only that round" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "ab ab ab\n");
    var store: Layers = .empty;
    defer store.deinit(gpa);

    const hits = try store.claimAnnotation(gpa, &doc, "hits", "snipe");
    hits.beginUntilKey(gpa);
    try hits.appendSpan(gpa, .{ .start = 3, .end = 5, .kind = 0, .message = "" });
    const marks = try store.claimAnnotation(gpa, &doc, "marks", "other");
    marks.begin(gpa);
    try marks.appendSpan(gpa, .{ .start = 0, .end = 2, .kind = 0, .message = "" });
    try std.testing.expectEqual(@as(usize, 1), hits.spanCount());

    store.expireUntilKey(gpa);
    try std.testing.expectEqual(@as(usize, 0), hits.spanCount());
    // An ordinary round is untouched by keys.
    try std.testing.expectEqual(@as(usize, 1), marks.spanCount());
    // The layer stays claimed, and a plain round after it is not key-scoped.
    hits.begin(gpa);
    try hits.appendSpan(gpa, .{ .start = 6, .end = 8, .kind = 0, .message = "" });
    store.expireUntilKey(gpa);
    try std.testing.expectEqual(@as(usize, 1), hits.spanCount());
}

test "layers: virtual-text and gutter decorations anchor and rebase" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "let x = 1\n");
    var store: Layers = .empty;
    defer store.deinit(gpa);

    const layer = try store.claim(gpa, &doc, "inlay", .local, "lsp");
    // An inlay hint after "x" (offset 5), and a gutter mark on line start.
    try layer.publishSpans(gpa, &.{
        .{ .start = 5, .end = 5, .kind = 0, .message = ": int", .placement = .virtual_after },
        .{ .start = 0, .end = 0, .kind = 2, .message = "●", .placement = .gutter, .face = .{ .clickable = true } },
    });
    try std.testing.expectEqual(@as(usize, 2), layer.spanCount());
    {
        const inlay = layer.resolvedSpan(0);
        try std.testing.expectEqual(Placement.virtual_after, inlay.placement);
        try std.testing.expectEqual(@as(usize, 5), inlay.start);
        try std.testing.expectEqualStrings(": int", inlay.message);
        const mark = layer.resolvedSpan(1);
        try std.testing.expectEqual(Placement.gutter, mark.placement);
        try std.testing.expect(mark.face.clickable);
    }

    // Insert two chars at the head: the anchored decorations rebase.
    try doc.insert(gpa, 0, "  ");
    try std.testing.expectEqual(@as(usize, 7), layer.resolvedSpan(0).start); // 5 → 7
    try std.testing.expectEqual(@as(usize, 2), layer.resolvedSpan(1).start); // 0 → 2
}

test "layers: replicated scope traps except for presence (FIX 10)" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var store: Layers = .empty;
    defer store.deinit(gpa);

    // Presence is the one wired replicated feature — allowed.
    _ = try store.claim(gpa, &doc, presence_layer, .replicated, "collab");
    // Any other replicated claim traps loudly instead of localizing.
    try std.testing.expectError(error.Unimplemented, store.claim(gpa, &doc, "notes", .replicated, "plugin.x"));
    // Local and host scopes are unaffected.
    _ = try store.claim(gpa, &doc, "notes", .local, "plugin.x");
    _ = try store.claim(gpa, &doc, "diagnostics", .host, "lsp");
}

test "layers: an annotation feed is dropped after an edit and returns on republish" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "// TODO: ship it\n");
    var store: Layers = .empty;
    defer store.deinit(gpa);

    // A third party decorates an entry it does not own.
    const marks = try store.claimAnnotation(gpa, &doc, "marks", "marks");
    marks.begin(gpa);
    try marks.appendSpan(gpa, .{ .start = 3, .end = 7, .kind = 5, .message = "" });
    try std.testing.expectEqual(@as(usize, 1), marks.spanCount());
    try std.testing.expectEqual(@as(usize, 3), marks.resolvedSpan(0).start);

    // The entry moves: the feed no longer resolves, so no consumer sees it —
    // the anchors are still there, they are simply not published truth.
    try doc.insert(gpa, 0, "\n");
    try std.testing.expect(!marks.resolves());
    try std.testing.expectEqual(@as(usize, 0), marks.spanCount());

    // Republishing against the new revision brings the paint back.
    marks.begin(gpa);
    try marks.appendSpan(gpa, .{ .start = 4, .end = 8, .kind = 5, .message = "" });
    try std.testing.expectEqual(@as(usize, 1), marks.spanCount());
    try std.testing.expectEqual(@as(usize, 4), marks.resolvedSpan(0).start);
}

test "layers: feeds coexist per name, never cross classes, and release takes only their own" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "fn main() {}\n");
    var store: Layers = .empty;
    defer store.deinit(gpa);

    // Two decorators over one entry, beside the entry's own builtin feed.
    const diagnostics = try store.claim(gpa, &doc, "diagnostics", .host, "lsp");
    try diagnostics.publishSpans(gpa, &.{.{ .start = 3, .end = 7, .kind = 1, .message = "unused" }});
    const marks = try store.claimAnnotation(gpa, &doc, "marks", "marks");
    marks.begin(gpa);
    try marks.appendSpan(gpa, .{ .start = 0, .end = 2, .kind = 5, .message = "" });
    const lens = try store.claimAnnotation(gpa, &doc, "lens", "codelens");
    lens.begin(gpa);
    try lens.appendSpan(gpa, .{ .start = 0, .end = 0, .kind = 6, .message = "2 refs", .placement = .eol });

    const feeds = try store.annotations(gpa, &doc);
    defer gpa.free(feeds);
    try std.testing.expectEqual(@as(usize, 2), feeds.len);

    // A name never changes class: neither side can take over the other's.
    try std.testing.expectError(error.Reserved, store.claimAnnotation(gpa, &doc, "diagnostics", "marks"));
    try std.testing.expectError(error.Reserved, store.claim(gpa, &doc, "marks", .local, "lsp"));

    // Removing one decorator removes its paint and nothing else.
    store.release(gpa, &doc, "marks", "marks");
    try std.testing.expect(store.find(&doc, "marks") == null);
    try std.testing.expectEqual(@as(usize, 1), store.find(&doc, "lens").?.spanCount());
    try std.testing.expectEqual(@as(usize, 1), store.find(&doc, "diagnostics").?.spanCount());
    // A name someone else owns is not the caller's to drop.
    store.release(gpa, &doc, "lens", "marks");
    try std.testing.expect(store.find(&doc, "lens") != null);

    // Staleness is not a decorator's to opt out of: spans published outside a
    // stamped round paint nothing at all.
    const unstamped = try store.claimAnnotation(gpa, &doc, "unstamped", "marks");
    try unstamped.appendSpan(gpa, .{ .start = 0, .end = 2, .kind = 5, .message = "" });
    try std.testing.expect(!unstamped.resolves());
    try std.testing.expectEqual(@as(usize, 0), unstamped.spanCount());
}

test "layers: a snapshot holds what the layer said, over its window, whatever the layer does next" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "aaaa\nbbbb\ncccc\n");
    var store: Layers = .empty;
    defer store.deinit(gpa);
    const diags = try store.claim(gpa, &doc, "diagnostics", .host, "lsp");
    try diags.publishSpans(gpa, &.{
        .{ .start = 0, .end = 2, .kind = 1, .message = "first" },
        .{ .start = 10, .end = 12, .kind = 2, .message = "third" },
        .{ .start = 11, .end = 11, .kind = 3, .message = "●", .placement = .gutter },
    });
    const hl = try store.claim(gpa, &doc, "highlight", .local, "syntax");
    try hl.publishBulk(gpa, "v", 0, &[_]u8{7} ** 15);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // The first line's window: the third line's span is outside it, its
    // gutter mark is not (a mark anywhere sizes the column), and the paint
    // is clipped to the window.
    const snap = try diags.snapshot(arena.allocator(), .{ .start = 0, .end = 5 });
    try std.testing.expectEqual(@as(usize, 2), snap.spanCount());
    try std.testing.expectEqualStrings("first", snap.resolvedSpan(0).message);
    try std.testing.expectEqual(Placement.gutter, snap.resolvedSpan(1).placement);
    const paint = (try hl.snapshot(arena.allocator(), .{ .start = 5, .end = 10 })).bulk.?;
    try std.testing.expectEqual(@as(usize, 5), paint.start);
    try std.testing.expectEqual(@as(usize, 5), paint.classes.len);

    // The layer moves on — an edit shifts its anchors, a republish frees its
    // messages — and the snapshot still says what it said.
    try doc.insert(gpa, 0, "zz");
    try diags.publishSpans(gpa, &.{.{ .start = 1, .end = 3, .kind = 1, .message = "other" }});
    try hl.publishBulk(gpa, "w", 0, &[_]u8{1} ** 17);
    try std.testing.expectEqual(@as(usize, 0), snap.resolvedSpan(0).start);
    try std.testing.expectEqualStrings("first", snap.resolvedSpan(0).message);
    try std.testing.expectEqual(@as(u8, 7), paint.classes[0]);
}
