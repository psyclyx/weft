//! Capabilities — the phase-2 core subsystem. A capability is a name +
//! schema version + shape + composition (doc/capabilities.md is the
//! ABI); providers register implementations with scope predicate,
//! placement, latency class, and priority; consumers fire *sessions*
//! against capability names and never see a provider type.
//!
//! Queries are races: `fire` stamps the document version, invokes every
//! matching provider, and hands back a session id. Providers push
//! results whenever they land (same frame for `instant`, later ticks
//! for `fast`/`slow`) — through the registry, by session id, so a dead
//! consumer is a no-op and a dead provider merely never arrives.
//! Actions ride the same session machinery; their payload is a
//! replacement batch against a stated version that the consumer applies
//! through the normal edit path. Feeds don't need sessions at all: a
//! feed registration claims a layer (layers.zig) and publishes into it.
//!
//! Composition lives here, chosen by the profile: merge-ranked
//! (completion), first-wins-by-priority (hover/definition/symbols/
//! actions), union (references, diagnostics-by-layer).
//!
//! **F5 Container adapter (north-star-plan §2.2/§5/§6 W1).** The "which
//! providers match this fire" step — the extension filter formerly inline in
//! `fire` — is now a `container.Container` query: `register` binds each
//! provider as a `Binding` (predicate built from its `extensions`,
//! composition from `Kind.composition()`), and `fire` asks the Container for
//! the eligible set instead of hand-scanning `self.providers`. Sessions,
//! restamping, and the race/merge machinery below are UNTOUCHED — this is
//! the "only the match step delegates" adapter the plan calls for. TRANSIENT:
//! named deletion gate **W3** (north-star-plan §6), once the UI mesh's own
//! Container-native slots exist.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Document = @import("Document.zig");
const layers_mod = @import("layers.zig");
const position = @import("position.zig");
const facts = @import("facts.zig");
const container_mod = @import("container.zig");

pub const Shape = enum { query, feed, action };

/// The `edit/highlight` schema's class vocabulary (one byte per
/// document byte in bulk layer paint). Part of the ABI: consumers map
/// classes to presentation, providers map their analyses to classes.
pub const HighlightClass = enum(u8) {
    none,
    keyword,
    string,
    comment,
    number,
    type,
    function,
    variable,
    constant,
    operator,
    punctuation,
    attribute,
    label,
};

/// Semantic style classes for tool-buffer output (git/grep/make …), published
/// by a plugin through the `styles` feed and painted by the view via
/// `Theme.styleColor`. Kept SEPARATE from `HighlightClass`: tool styling is a
/// distinct concern from tree-sitter syntax, keyed on a plugin's own analysis
/// rather than a grammar, and the two never collide (tool buffers have no
/// grammar → no highlight bulk). `.normal` = 0 so a zeroed class array (the
/// styleClear baseline) reads as unstyled foreground. Rides the same
/// `Bulk.classes` one-byte-per-doc-byte storage as highlight.
pub const StyleClass = enum(u8) {
    normal,
    added,
    removed,
    header,
    location,
    emphasis,
    muted,
};

/// Inline markdown role — the size/face family for a byte's span.
pub const InlineRole = enum(u3) { normal, h1, h2, h3, h4, h5, h6, code };

/// Per-byte markdown styling — the rich analogue of `HighlightClass`,
/// packed to one byte so it rides the same `Bulk.classes` storage (the
/// consumer bitcasts `[]u8` → `[]InlineAttr`). `role` picks size + base
/// family; `bold`/`italic` pick the sans variant; `link` recolors; a
/// `marker` byte is a syntax delimiter (dimmed but still rendered, so the
/// source-offset→geometry map stays total). One spare bit.
pub const InlineAttr = packed struct(u8) {
    role: InlineRole = .normal,
    bold: bool = false,
    italic: bool = false,
    link: bool = false,
    marker: bool = false,
    _pad: u1 = 0,
};
pub const Composition = enum { merge_ranked, union_all, first_wins };
pub const Latency = enum { instant, fast, slow };
pub const Placement = enum { local, host };

/// Session kinds — the profile's query/action entries.
pub const Kind = enum {
    completion,
    hover,
    definition,
    references,
    symbols,
    format,
    rename,

    pub fn capabilityName(self: Kind) []const u8 {
        return switch (self) {
            .completion => "edit/completion",
            .hover => "edit/hover",
            .definition => "edit/definition",
            .references => "edit/references",
            .symbols => "edit/symbols-document",
            .format => "edit/format",
            .rename => "edit/rename",
        };
    }

    /// The action-registry name for this capability kind — its semantic
    /// identity in the unified dispatch registry (a `race`-policy action). The
    /// trigger COMMAND may differ (`goto-definition` runs the `definition`
    /// intent); this is the intent.
    pub fn actionName(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn composition(self: Kind) Composition {
        return switch (self) {
            .completion => .merge_ranked,
            .references => .union_all,
            else => .first_wins,
        };
    }
};

pub const CompletionItem = struct {
    text: []u8,
    label: []u8 = &.{},
    detail: []u8 = &.{},
    /// Documentation body (markdown/plain) for the info popup — resolved
    /// lazily by richer providers; empty when none.
    documentation: []u8 = &.{},
    /// Semantic kind, LSP `CompletionItemKind` numbering (1=text … 25),
    /// 0 = unknown. The UI maps this to an icon/short tag; core does not
    /// interpret it.
    kind: u8 = 0,
    rank: i32 = 0,
};

pub const Location = struct {
    /// Empty = this document.
    uri: []u8 = &.{},
    range: position.StampedRange,
};

pub const Symbol = struct {
    name: []u8,
    kind: u8,
    range: position.StampedRange,
    depth: u8 = 0,
};

pub const Replacement = struct {
    /// Old-space against the payload's version.
    start: usize,
    end: usize,
    text: []u8,
};

pub const Payload = union(enum) {
    completion: []CompletionItem,
    text: []u8, // hover
    locations: []Location, // definition/references
    symbols: []Symbol,
    edits: []Replacement, // format/rename (against the result's version)
};

pub const Result = struct {
    provider: []u8,
    priority: i32,
    latency: Latency,
    elapsed_ns: u64,
    /// Version the payload was computed against (owned).
    version: []u8,
    payload: Payload,

    fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.provider);
        gpa.free(self.version);
        switch (self.payload) {
            .completion => |items| {
                for (items) |it| {
                    gpa.free(it.text);
                    gpa.free(it.label);
                    gpa.free(it.detail);
                    gpa.free(it.documentation);
                }
                gpa.free(items);
            },
            .text => |t_| gpa.free(t_),
            .locations => |ls| {
                for (ls) |l| gpa.free(l.uri);
                gpa.free(ls);
            },
            .symbols => |ss| {
                for (ss) |s| gpa.free(s.name);
                gpa.free(ss);
            },
            .edits => |es| {
                for (es) |e| gpa.free(e.text);
                gpa.free(es);
            },
        }
    }
};

/// What a provider's handler receives. Borrowed for the duration of the
/// synchronous call — async providers copy what they need and answer
/// later through `push*` by session id.
pub const Request = struct {
    session: u64,
    kind: Kind,
    doc: *Document,
    path: ?[]const u8,
    /// Version stamp taken at fire time (equals the head).
    version: []const u8,
    /// Cursor/target offset, valid at `version`.
    offset: usize,
    /// Completion: the word prefix before the cursor. Rename: new name.
    text: []const u8,
};

pub const Provider = struct {
    capability: []u8,
    id: []u8,
    latency: Latency = .instant,
    placement: Placement = .local,
    priority: i32 = 0,
    /// File extensions this provider matches; empty = all documents.
    extensions: [][]u8 = &.{},
    data: ?*anyopaque = null,
    handler: *const fn (data: ?*anyopaque, caps: *Caps, req: *const Request) anyerror!void,
    /// Owned backing array for the Container `Binding.predicate` this
    /// provider bound (`predicateFromExtensions`'s `.all`/`.any` slice).
    predicate_owned: []facts.Predicate = &.{},
    /// Per-registration unique key (see `container_mod.ProviderRef.caps_provider`'s
    /// doc for why `id` alone is not enough to find this struct back).
    seq: u64 = 0,

    fn deinit(self: *Provider, gpa: Allocator) void {
        gpa.free(self.capability);
        gpa.free(self.id);
        for (self.extensions) |e| gpa.free(e);
        gpa.free(self.extensions);
        gpa.free(self.predicate_owned);
    }

    /// Superseded by the Container query `fire` now uses (see the file doc's
    /// F5 note) — kept as a small, still-correct standalone predicate for
    /// any future direct introspection; not on the dispatch path anymore.
    fn matches(self: *const Provider, path: ?[]const u8) bool {
        if (self.extensions.len == 0) return true;
        const p = path orelse return false;
        for (self.extensions) |ext| {
            if (std.mem.endsWith(u8, p, ext)) return true;
        }
        return false;
    }
};

/// Map a capability NAME (not just the closed `Kind` enum) to the Container
/// composition its slot should declare. Recognized `Kind` names use
/// `Kind.composition()`; anything else (a host-defined capability outside
/// the closed enum) defaults to `.first_wins` — the collision-checked,
/// single-winner default is the safer unknown-composition guess.
fn compositionForCapability(name: []const u8) container_mod.Composition {
    inline for (std.meta.tags(Kind)) |k| {
        if (std.mem.eql(u8, k.capabilityName(), name)) {
            return switch (k.composition()) {
                .merge_ranked => .merge_ranked,
                .union_all => .ordered_union,
                .first_wins => .first_wins,
            };
        }
    }
    return .first_wins;
}

/// The Container predicate for a provider's extension list: empty = matches
/// every document (`.all` of zero conjuncts, specificity 0, same standing as
/// the pre-Container `matches`'s empty-extensions case); ONE extension = a
/// bare `.ext` leaf (cheaper than wrapping a single-element `.any`, and
/// `explain` reads it more plainly — `disjoint` no longer NEEDS the `.any`
/// wrapper to prove two single-extension providers apart, but there is no
/// reason to allocate one either); more than one = an OR across extensions
/// (`.any`), matching `matches`'s exact semantics — `facts.disjoint` unwraps
/// `.any` correctly (universally, per its doc), so two providers each
/// scoped to a different language's extensions never collide at bind time.
/// `exts` must already be the provider's OWNED, duped extension strings (not
/// the caller's borrowed `spec.extensions`) — the returned predicate's
/// leaves reference them directly. Neither the empty nor single-extension
/// case allocates; `Provider.deinit`'s `gpa.free(self.predicate_owned)` is
/// still safe either way (`ownedBacking` returns `&.{}` for a bare leaf, and
/// freeing an empty slice is always a no-op).
fn predicateFromExtensions(gpa: Allocator, exts: []const []u8) Allocator.Error!facts.Predicate {
    if (exts.len == 0) return .{ .all = &.{} };
    if (exts.len == 1) return .{ .ext = exts[0] };
    const owned = try gpa.alloc(facts.Predicate, exts.len);
    for (exts, 0..) |e, i| owned[i] = .{ .ext = e };
    return .{ .any = owned };
}

fn ownedBacking(p: facts.Predicate) []facts.Predicate {
    return switch (p) {
        .all => |k| @constCast(k),
        .any => |k| @constCast(k),
        else => &.{},
    };
}

pub const Session = struct {
    kind: Kind,
    version: []u8,
    fired_ns: u64,
    deadline_ns: u64,
    outstanding: usize,
    results: std.ArrayList(Result) = .empty,
    fresh: usize = 0,

    fn deinit(self: *Session, gpa: Allocator) void {
        for (self.results.items) |*r| r.deinit(gpa);
        self.results.deinit(gpa);
        gpa.free(self.version);
    }

    /// Results that arrived since the last poll.
    pub fn poll(self: *Session) []const Result {
        const new = self.results.items[self.fresh..];
        self.fresh = self.results.items.len;
        return new;
    }

    pub fn all(self: *const Session) []const Result {
        return self.results.items;
    }

    pub fn done(self: *const Session, now_ns: u64) bool {
        return self.outstanding == 0 or now_ns >= self.deadline_ns;
    }

    /// first-wins-by-priority over what has arrived.
    pub fn best(self: *const Session) ?*const Result {
        var winner: ?*const Result = null;
        for (self.results.items) |*r| {
            if (winner == null or r.priority > winner.?.priority) winner = r;
        }
        return winner;
    }
};

pub const FeedRegistration = struct {
    capability: []u8,
    layer: []u8,
    scope: layers_mod.Scope,
    provider: []u8,

    fn deinit(self: *FeedRegistration, gpa: Allocator) void {
        gpa.free(self.capability);
        gpa.free(self.layer);
        gpa.free(self.provider);
    }
};

pub const Caps = struct {
    gpa: Allocator,
    providers: std.ArrayList(Provider) = .empty,
    feeds: std.ArrayList(FeedRegistration) = .empty,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    next_session: u64 = 1,
    layers: layers_mod.Layers = .empty,
    /// Monotonic clock, injectable for tests.
    now: *const fn () u64,
    /// The Container this module adapts onto (F5, W1) — see the file doc.
    /// Every capability name is a slot; every `register`ed provider is a
    /// `Binding` whose owner is the provider's `id`.
    container: container_mod.Container = undefined,
    /// Assigns each `register`ed provider its unique `seq` — see
    /// `Provider.seq`'s doc.
    next_provider_seq: u64 = 0,

    pub fn init(gpa: Allocator, now: *const fn () u64) Caps {
        return .{ .gpa = gpa, .now = now, .container = container_mod.Container.init(gpa) };
    }

    pub fn deinit(self: *Caps) void {
        for (self.providers.items) |*p| p.deinit(self.gpa);
        self.providers.deinit(self.gpa);
        for (self.feeds.items) |*f| f.deinit(self.gpa);
        self.feeds.deinit(self.gpa);
        var it = self.sessions.valueIterator();
        while (it.next()) |s| {
            s.*.deinit(self.gpa);
            self.gpa.destroy(s.*);
        }
        self.sessions.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        self.container.deinit();
    }

    // ── Registration ────────────────────────────────────────────

    pub const ProviderSpec = struct {
        capability: []const u8,
        id: []const u8,
        latency: Latency = .instant,
        placement: Placement = .local,
        priority: i32 = 0,
        extensions: []const []const u8 = &.{},
        data: ?*anyopaque = null,
        handler: *const fn (?*anyopaque, *Caps, *const Request) anyerror!void,
    };

    pub fn register(self: *Caps, spec: ProviderSpec) !void {
        const gpa = self.gpa;
        var exts = try gpa.alloc([]u8, spec.extensions.len);
        var filled: usize = 0;
        errdefer {
            for (exts[0..filled]) |e| gpa.free(e);
            gpa.free(exts);
        }
        for (spec.extensions, 0..) |e, i| {
            exts[i] = try gpa.dupe(u8, e);
            filled += 1;
        }
        const cap_owned = try gpa.dupe(u8, spec.capability);
        errdefer gpa.free(cap_owned);
        const id_owned = try gpa.dupe(u8, spec.id);
        errdefer gpa.free(id_owned);
        const pred = try predicateFromExtensions(gpa, exts);
        errdefer gpa.free(ownedBacking(pred));

        // Reserve capacity first so storing the provider after a successful
        // bind is infallible — same ownership reasoning as action.zig's
        // `provide` (see its comment): a late OOM here must never leave the
        // Container referencing a provider that didn't end up stored.
        try self.providers.ensureUnusedCapacity(gpa, 1);

        const seq = self.next_provider_seq;
        self.next_provider_seq += 1;

        try self.container.declareSlot(.{
            .name = cap_owned,
            .shape = .query,
            .composition = compositionForCapability(cap_owned),
        });
        try self.container.bind(.{
            .slot = cap_owned,
            .provider = .{ .caps_provider = .{ .id = id_owned, .seq = seq } },
            .predicate = pred,
            .priority = spec.priority,
            // TIER: uniform `.plugin` for every capability provider — an
            // APPROVED, W2b-PENDING deviation from §2.2's "tier from owner
            // class" language, not the end state; see action.zig's `provide`
            // for the identical call and the full reasoning (real tier
            // stratification needs manifest-carried owner identity, which
            // doesn't exist yet).
            .tier = .plugin,
            .owner = id_owned,
        });

        self.providers.appendAssumeCapacity(.{
            .capability = cap_owned,
            .id = id_owned,
            .latency = spec.latency,
            .placement = spec.placement,
            .priority = spec.priority,
            .extensions = exts,
            .data = spec.data,
            .handler = spec.handler,
            .predicate_owned = ownedBacking(pred),
            .seq = seq,
        });
    }

    /// Remove every provider and feed whose id starts with `id_prefix`
    /// (plugin teardown). Container bindings (owner = provider id) are
    /// dropped FIRST — they borrow `capability`/`id` from the Provider
    /// structs `deinit` is about to free; see container.zig's
    /// `unbindOwnerPrefix` doc for why the order matters.
    pub fn unregisterByIdPrefix(self: *Caps, id_prefix: []const u8) void {
        self.container.unbindOwnerPrefix(id_prefix);
        var i: usize = 0;
        while (i < self.providers.items.len) {
            if (std.mem.startsWith(u8, self.providers.items[i].id, id_prefix)) {
                var p = self.providers.swapRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
        i = 0;
        while (i < self.feeds.items.len) {
            if (std.mem.startsWith(u8, self.feeds.items[i].provider, id_prefix)) {
                var f = self.feeds.swapRemove(i);
                f.deinit(self.gpa);
            } else i += 1;
        }
    }

    /// Register a feed: claims (or re-claims) the layer for `provider`.
    pub fn registerFeed(
        self: *Caps,
        doc: *Document,
        capability: []const u8,
        layer_name: []const u8,
        scope: layers_mod.Scope,
        provider: []const u8,
    ) !*layers_mod.Layer {
        const gpa = self.gpa;
        try self.feeds.append(gpa, .{
            .capability = try gpa.dupe(u8, capability),
            .layer = try gpa.dupe(u8, layer_name),
            .scope = scope,
            .provider = try gpa.dupe(u8, provider),
        });
        return self.layers.claim(gpa, doc, layer_name, scope, provider);
    }

    // ── Query/action sessions ───────────────────────────────────

    pub const FireOptions = struct {
        offset: usize = 0,
        text: []const u8 = &.{},
        /// Overall deadline; latency classes stage the UI, this bounds
        /// the session.
        timeout_ns: u64 = 2 * std.time.ns_per_s,
    };

    /// The Provider a Container binding's `caps_provider` ref names, found
    /// by its unique `seq` — NOT by `id` (see `container_mod.ProviderRef`'s
    /// doc: `syntax.registerProviders` legitimately registers the same id
    /// once per buffer, so an id-only lookup could return the WRONG
    /// buffer's provider — a real bug this `seq` scan exists to avoid, not
    /// defensive paranoia).
    fn findProviderBySeq(self: *const Caps, seq: u64) ?*const Provider {
        for (self.providers.items) |*p| {
            if (p.seq == seq) return p;
        }
        return null;
    }

    /// Fire `kind` at every matching provider. Returns a session id
    /// (finish it) — or null when no provider matches.
    pub fn fire(self: *Caps, kind: Kind, doc: *Document, path: ?[]const u8, opts: FireOptions) !?u64 {
        const gpa = self.gpa;
        const cap_name = kind.capabilityName();
        const elig = try self.container.eligible(gpa, cap_name, .{ .path = path });
        defer gpa.free(elig);
        var matched: std.ArrayList(*const Provider) = .empty;
        defer matched.deinit(gpa);
        for (elig) |b| {
            const ref = switch (b.provider) {
                .caps_provider => |r| r,
                else => continue,
            };
            if (self.findProviderBySeq(ref.seq)) |p| {
                try matched.append(gpa, p);
            }
        }
        if (matched.items.len == 0) return null;

        const version = try doc.version(gpa);
        errdefer gpa.free(version);
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const now = self.now();
        s.* = .{
            .kind = kind,
            .version = version,
            .fired_ns = now,
            .deadline_ns = now + opts.timeout_ns,
            .outstanding = matched.items.len,
        };
        const id = self.next_session;
        self.next_session += 1;
        try self.sessions.put(gpa, id, s);

        const req: Request = .{
            .session = id,
            .kind = kind,
            .doc = doc,
            .path = path,
            .version = version,
            .offset = opts.offset,
            .text = opts.text,
        };
        for (matched.items) |p| {
            p.handler(p.data, self, &req) catch |err| {
                std.log.warn("capability {s}: provider {s} failed: {t}", .{
                    kind.capabilityName(), p.id, err,
                });
                if (self.sessions.get(id)) |live| live.outstanding -|= 1;
            };
        }
        return id;
    }

    pub fn session(self: *Caps, id: u64) ?*Session {
        return self.sessions.get(id);
    }

    pub fn finish(self: *Caps, id: u64) void {
        if (self.sessions.fetchRemove(id)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }
    }

    pub const From = struct {
        id: []const u8,
        priority: i32 = 0,
        latency: Latency = .instant,
    };

    /// Providers push through this; a finished session is a no-op. The
    /// payload is deep-copied, and every stamped range inside it is
    /// re-stamped with the session version — the stamp is enforced by
    /// the core, not trusted from the provider.
    pub fn push(self: *Caps, id: u64, from: From, payload: Payload) !void {
        const s = self.sessions.get(id) orelse return;
        const gpa = self.gpa;
        var owned = try dupePayload(gpa, payload);
        errdefer {
            var r: Result = .{
                .provider = &.{},
                .priority = 0,
                .latency = .instant,
                .elapsed_ns = 0,
                .version = &.{},
                .payload = owned,
            };
            r.deinit(gpa);
        }
        const version = try gpa.dupe(u8, s.version);
        errdefer gpa.free(version);
        restamp(&owned, version);
        try s.results.append(gpa, .{
            .provider = try gpa.dupe(u8, from.id),
            .priority = from.priority,
            .latency = from.latency,
            .elapsed_ns = self.now() - s.fired_ns,
            .version = version,
            .payload = owned,
        });
        s.outstanding -|= 1;
    }

    /// A provider that will never answer (dead, unsupported).
    pub fn decline(self: *Caps, id: u64) void {
        if (self.sessions.get(id)) |s| s.outstanding -|= 1;
    }

    // ── Composition ─────────────────────────────────────────────

    /// merge-ranked completion view: pointers into the session's
    /// results, ordered by (latency class, provider priority desc,
    /// rank, text). Caller frees the slice (not the items).
    pub fn mergedCompletion(self: *Caps, gpa: Allocator, id: u64) ![]*const CompletionItem {
        const s = self.sessions.get(id) orelse return try gpa.alloc(*const CompletionItem, 0);
        const Entry = struct {
            item: *const CompletionItem,
            class: u8,
            prio: i32,
        };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (s.results.items) |*r| {
            if (r.payload != .completion) continue;
            for (r.payload.completion) |*it| {
                try entries.append(gpa, .{
                    .item = it,
                    .class = @intFromEnum(r.latency),
                    .prio = r.priority,
                });
            }
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.class != b.class) return a.class < b.class;
                if (a.prio != b.prio) return a.prio > b.prio;
                if (a.item.rank != b.item.rank) return a.item.rank < b.item.rank;
                return std.mem.lessThan(u8, a.item.text, b.item.text);
            }
        }.lt);
        // Dedup by text (first occurrence wins — highest-ranked source).
        var out: std.ArrayList(*const CompletionItem) = .empty;
        errdefer out.deinit(gpa);
        outer: for (entries.items) |e| {
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen.text, e.item.text)) continue :outer;
            }
            try out.append(gpa, e.item);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Point every stamped range at the session's owned version bytes.
fn restamp(p: *Payload, version: []const u8) void {
    switch (p.*) {
        .locations => |ls| for (ls) |*l| {
            l.range._version = version;
        },
        .symbols => |ss| for (ss) |*sy| {
            sy.range._version = version;
        },
        else => {},
    }
}

fn dupePayload(gpa: Allocator, p: Payload) !Payload {
    switch (p) {
        .completion => |items| {
            const out = try gpa.alloc(CompletionItem, items.len);
            var n: usize = 0;
            errdefer {
                for (out[0..n]) |it| {
                    gpa.free(it.text);
                    gpa.free(it.label);
                    gpa.free(it.detail);
                    gpa.free(it.documentation);
                }
                gpa.free(out);
            }
            for (items, 0..) |it, i| {
                out[i] = .{
                    .text = try gpa.dupe(u8, it.text),
                    .label = try gpa.dupe(u8, it.label),
                    .detail = try gpa.dupe(u8, it.detail),
                    .documentation = try gpa.dupe(u8, it.documentation),
                    .kind = it.kind,
                    .rank = it.rank,
                };
                n += 1;
            }
            return .{ .completion = out };
        },
        .text => |t_| return .{ .text = try gpa.dupe(u8, t_) },
        .locations => |ls| {
            const out = try gpa.alloc(Location, ls.len);
            var n: usize = 0;
            errdefer {
                for (out[0..n]) |l| gpa.free(l.uri);
                gpa.free(out);
            }
            for (ls, 0..) |l, i| {
                out[i] = .{ .uri = try gpa.dupe(u8, l.uri), .range = l.range };
                n += 1;
            }
            return .{ .locations = out };
        },
        .symbols => |ss| {
            const out = try gpa.alloc(Symbol, ss.len);
            var n: usize = 0;
            errdefer {
                for (out[0..n]) |sy| gpa.free(sy.name);
                gpa.free(out);
            }
            for (ss, 0..) |sy, i| {
                out[i] = .{
                    .name = try gpa.dupe(u8, sy.name),
                    .kind = sy.kind,
                    .range = sy.range,
                    .depth = sy.depth,
                };
                n += 1;
            }
            return .{ .symbols = out };
        },
        .edits => |es| {
            const out = try gpa.alloc(Replacement, es.len);
            var n: usize = 0;
            errdefer {
                for (out[0..n]) |e| gpa.free(e.text);
                gpa.free(out);
            }
            for (es, 0..) |e, i| {
                out[i] = .{ .start = e.start, .end = e.end, .text = try gpa.dupe(u8, e.text) };
                n += 1;
            }
            return .{ .edits = out };
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
