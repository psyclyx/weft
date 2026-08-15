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

pub const SpanIn = struct { start: usize, end: usize, kind: u32, message: []const u8 };

pub const Span = struct {
    start: stemma.AnchorSet.Handle,
    end: stemma.AnchorSet.Handle,
    /// Consumer-interpreted kind (profile constants: diagnostics use
    /// severity 1–4; presence uses peer index; etc.).
    kind: u32,
    /// Owned by the layer.
    message: []u8 = &.{},
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

    pub const ResolvedSpan = struct { start: usize, end: usize, kind: u32, message: []const u8 };

    /// Spans at the current head (anchors already shifted).
    pub fn resolvedSpan(self: *const Layer, i: usize) ResolvedSpan {
        const s = self.spans.items[i];
        return .{
            .start = self.doc.anchorOffset(s.start),
            .end = self.doc.anchorOffset(s.end),
            .kind = s.kind,
            .message = s.message,
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
    pub fn claim(self: *Layers, gpa: Allocator, doc: *Document, name: []const u8, scope: Scope, provider: []const u8) !*Layer {
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
