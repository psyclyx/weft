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

/// How a span presents (plan 02 P8). `range` (default) is the classic
/// anchored face painted over `[start, end)`. The rest are decorations
/// anchored at `start`, drawn beside the text rather than over it, with
/// `message` as their display string: `virtual_before`/`virtual_after`
/// insert display-only text at the offset (never in the document, so no
/// commit, no sync — pure local overlay), `eol` floats it at the line end
/// (inlay hints, blame), `gutter` shows it in the margin (breakpoints,
/// diagnostics severity, fold arrows). One anchored-annotation type covers
/// all of them — the density split is spans-vs-bulk, not a third store.
pub const Placement = enum(u8) { range, virtual_before, virtual_after, eol, gutter };

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

    pub fn spanCount(self: *const Layer) usize {
        return self.spans.items.len;
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
    /// registry).
    pub const ClaimError = Allocator.Error || error{Unimplemented};

    pub fn claim(self: *Layers, gpa: Allocator, doc: *Document, name: []const u8, scope: Scope, provider: []const u8) ClaimError!*Layer {
        // [FIX 10] Replicated state is not yet grant-keyed on the wire. Only
        // presence (whose relay is wired) may claim `replicated`; any other
        // replicated claim traps rather than silently degrading to a local
        // layer nobody else will ever see — a speced-but-unwired feature
        // must fail loudly, not no-op.
        if (scope == .replicated and !std.mem.eql(u8, name, presence_layer))
            return error.Unimplemented;
        for (self.list.items) |l| {
            if (l.doc == doc and std.mem.eql(u8, l.name, name)) {
                if (!std.mem.eql(u8, l.provider, provider)) {
                    gpa.free(l.provider);
                    l.provider = try gpa.dupe(u8, provider);
                    l.clearSpans(gpa);
                    l.clearBulk(gpa);
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
