//! Context — what is true here, as ONE keyed, open, observable value
//! (doc/model.md §2.5).
//!
//! Three mechanisms used to answer "what is the editor looking at": the
//! Zig-only focus feed (whose `Companion` helper let an outline follow the
//! editor), `on_offers_changed` (which told a toolbar to redraw), and nothing
//! at all for a sidebar. Each described one slice of the same fact. This
//! module is the fact:
//!
//!   - **The published store** (`weft_facts`' `context.Store`): the open keys
//!     plugins set at a scope (`weft.contextSet("repl.session", …, .place)`),
//!     read back through every `Facts` (`openAt`), so a predicate can test
//!     them anywhere a predicate is evaluated.
//!   - **The primary context**: the context at the head's primary viewport —
//!     the last pane focused whose viewport is a `focus_source`. Its keys are
//!     core's builtins (`entry`, `place`, `mode`, `posture`, `locality`,
//!     `lang`, `tool`, `role`, `offers`) plus every open key resolved there.
//!   - **One event**: `observe` compares the primary context's per-key
//!     fingerprints with the last delivered ones and reports the keys that
//!     moved. The app calls it once per frame, after layout, never inside a
//!     dispatch; listeners — wasm plugins (`on_context_changed`) and Zig
//!     consumers (`Listener`) alike — hear the same list.
//!
//! THE COMPANION PROPERTY, KEPT BY CONSTRUCTION. The focus feed's load-bearing
//! detail was that a follower never observed its own focus: `Companion`
//! filtered out events from non-`focus_source` viewports before the follower
//! ran. Here there is nothing to filter. The primary context reads focus from
//! `Head.primary_focus` alone, which the layout phase moves only on a
//! `focus_source` pane — so a companion taking focus changes no key, and a
//! follower subscribed to `entry` cannot be told about itself. And with no
//! primary recorded there is no primary context (`intent.primaryScopeOf`), not
//! a fallback to whatever pane is active.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts = @import("weft_facts");
const command = @import("command.zig");
const intent = @import("intent.zig");
const Buffers = @import("Buffers.zig");
const place_mod = @import("place.zig");

pub const Store = facts.context.Store;
pub const Open = facts.context.Open;
pub const Scope = facts.context.Scope;
pub const ScopeKind = facts.context.ScopeKind;

/// A place's exact coordinate in the store: its identity fields packed, the
/// same fields `Place.eql` compares (never the revision). `.process` is 0; a
/// container's handle generation is never 0, so no container packs to it.
pub fn placeCoord(p: place_mod.Place) u128 {
    return switch (p) {
        .process => 0,
        .container => |c| @as(u128, @intFromEnum(c.locus)) << 96 |
            @as(u128, @intFromEnum(c.ref.authority)) << 64 |
            @as(u128, c.ref.slot) << 32 |
            c.ref.generation,
    };
}

/// The store's coordinates for `entry`: its generation (unique for the life
/// of the process, so a closed entry's values can never be read by the entry
/// that reuses its slot) and its place.
pub fn at(entry: *const Buffers.Buffer) facts.context.At {
    return .{ .entry = entry.generation, .place = placeCoord(entry.place) };
}

/// A reader into `context`'s store at `entry` — what `Facts.context` holds.
/// No context (a bare fixture) is a reader with no store: every open key
/// reads as unset.
pub fn openAt(context: ?*const Context, entry: *const Buffers.Buffer) Open {
    const c = context orelse return .{};
    return .{ .store = &c.store, .at = at(entry) };
}

/// The coordinate a publication at `kind` lands on, for the entry a call is
/// about. The place is the ENTRY's own, the level the stack names — not the
/// head's working-target pin, which is where effects run, not what an entry
/// is in.
pub fn scopeFor(kind: ScopeKind, entry: *const Buffers.Buffer) Scope {
    return switch (kind) {
        .entry => .{ .entry = entry.generation },
        .place => .{ .place = placeCoord(entry.place) },
        .global => .global,
    };
}

/// A Zig consumer of the primary-context event: told, at the frame boundary,
/// which keys moved. The keys are borrowed for the call.
pub const Listener = struct {
    context: ?*anyopaque,
    notify: *const fn (?*anyopaque, keys: []const []const u8) void,
};

const Seen = struct {
    key: []u8,
    fingerprint: u64,
};

/// Owned by the `System`, reached through `command.Context.context`.
pub const Context = struct {
    gpa: Allocator,
    store: Store,
    /// The primary context as last delivered: one fingerprint per key.
    seen: std.ArrayList(Seen) = .empty,
    /// The keys the last `observe` found moved — what `on_context_changed`
    /// lists (`wl_context_changed` reads it during the delivery). Owned;
    /// replaced by the next `observe`.
    moved: std.ArrayList([]u8) = .empty,
    listeners: std.ArrayList(Listener) = .empty,

    pub fn init(gpa: Allocator) Context {
        return .{ .gpa = gpa, .store = .init(gpa) };
    }

    pub fn deinit(self: *Context) void {
        for (self.seen.items) |s| self.gpa.free(s.key);
        self.seen.deinit(self.gpa);
        self.clearMoved();
        self.moved.deinit(self.gpa);
        self.listeners.deinit(self.gpa);
        self.store.deinit();
        self.* = undefined;
    }

    pub fn subscribe(self: *Context, listener: Listener) Allocator.Error!void {
        try self.listeners.append(self.gpa, listener);
    }

    /// Retire every listener registered with `context` as its key.
    pub fn unsubscribe(self: *Context, context: ?*anyopaque) void {
        var i = self.listeners.items.len;
        while (i > 0) {
            i -= 1;
            if (self.listeners.items[i].context == context) _ = self.listeners.orderedRemove(i);
        }
    }

    /// The keys the last observation reported.
    pub fn movedKeys(self: *const Context) []const []const u8 {
        return @ptrCast(self.moved.items);
    }

    /// The fingerprint last delivered for `key`, if the primary context had
    /// it — how a reader asks after `offers`, which is a revision, not a
    /// value anything stores.
    pub fn fingerprint(self: *const Context, key: []const u8) ?u64 {
        for (self.seen.items) |s| if (std.mem.eql(u8, s.key, key)) return s.fingerprint;
        return null;
    }

    fn clearMoved(self: *Context) void {
        for (self.moved.items) |k| self.gpa.free(k);
        self.moved.clearRetainingCapacity();
    }

    /// Recompute the primary context's fingerprints and record which keys
    /// moved since the last call. Returns whether any did. The caller (the
    /// app's frame boundary) decides WHEN, and calls `notify` after.
    pub fn observe(self: *Context, ctx: *command.Context) Allocator.Error!bool {
        var now: Builder = .{ .gpa = self.gpa };
        defer now.list.deinit(self.gpa);
        if (intent.primaryScopeOf(ctx)) |scope| try now.primary(ctx, scope);
        if (now.failed) return error.OutOfMemory;

        self.clearMoved();
        for (now.list.items) |cur| {
            const was = self.fingerprint(cur.key);
            if (was == null or was.? != cur.fingerprint) try self.moved.append(self.gpa, try self.gpa.dupe(u8, cur.key));
        }
        for (self.seen.items) |old| {
            const still = for (now.list.items) |cur| {
                if (std.mem.eql(u8, cur.key, old.key)) break true;
            } else false;
            if (!still) try self.moved.append(self.gpa, try self.gpa.dupe(u8, old.key));
        }
        if (self.moved.items.len == 0) return false;

        // Adopt the new fingerprints, owning their keys (the builder's
        // borrow the store and the entry, which move on).
        var next: std.ArrayList(Seen) = try .initCapacity(self.gpa, now.list.items.len);
        errdefer {
            for (next.items) |s| self.gpa.free(s.key);
            next.deinit(self.gpa);
        }
        for (now.list.items) |cur| next.appendAssumeCapacity(.{ .key = try self.gpa.dupe(u8, cur.key), .fingerprint = cur.fingerprint });
        for (self.seen.items) |s| self.gpa.free(s.key);
        self.seen.deinit(self.gpa);
        self.seen = next;
        return true;
    }

    /// Tell every Zig listener which keys the last `observe` moved. Returns
    /// whether any listened.
    pub fn notify(self: *Context) bool {
        const keys = self.movedKeys();
        for (self.listeners.items) |l| l.notify(l.context, keys);
        return self.listeners.items.len > 0;
    }
};

/// One observation's (key, fingerprint) list. Keys are BORROWED — builtin
/// names are static, open keys live in the store — until `observe` copies
/// the ones it keeps.
const Builder = struct {
    gpa: Allocator,
    list: std.ArrayList(struct { key: []const u8, fingerprint: u64 }) = .empty,
    failed: bool = false,

    fn add(self: *Builder, key: []const u8, fp: u64) void {
        self.list.append(self.gpa, .{ .key = key, .fingerprint = fp }) catch {
            self.failed = true;
        };
    }

    fn visitOpen(self: *Builder, key: []const u8, value: []const u8) void {
        // A key the typed view already answered is not listed twice. None
        // can collide today (published keys are namespaced), and this keeps
        // it that way should the vocabularies ever meet.
        if (facts.context.isBuiltinKey(key)) return;
        self.add(key, std.hash.Wyhash.hash(0, value));
    }

    fn primary(self: *Builder, ctx: *command.Context, scope: intent.Scope) Allocator.Error!void {
        const f = intent.factsIn(scope);
        var scratch: [facts.Facts.scratch_len]u8 = undefined;
        for (facts.context.builtin_keys) |key| {
            if (std.mem.eql(u8, key, "offers")) {
                const plane = ctx.intent orelse continue;
                self.add(key, plane.offersFingerprint(ctx, .primary));
                continue;
            }
            const v = f.get(key, &scratch) orelse continue;
            var h = std.hash.Wyhash.init(0);
            h.update(v);
            // Two entries can share a name (two `*scratch*`s): the entry key
            // moves with the opening, not only with what it is called.
            if (std.mem.eql(u8, key, "entry")) h.update(std.mem.asBytes(&scope.entry.generation));
            self.add(key, h.final());
        }
        if (f.context.store) |store| store.each(f.context.at, self, visitOpen);
    }
};

const t = std.testing;

test "context: a place packs exactly, and the process place is its own coordinate" {
    try t.expectEqual(@as(u128, 0), placeCoord(.process));
    const a: place_mod.Place = .{ .container = .{ .locus = .here, .ref = .{ .authority = .here, .slot = 1, .generation = 1 }, .revision = 3 } };
    var b = a;
    b.container.revision = 9; // a republish is the same place
    try t.expectEqual(placeCoord(a), placeCoord(b));
    var c = a;
    c.container.ref.slot = 2;
    try t.expect(placeCoord(a) != placeCoord(c));
    try t.expect(placeCoord(a) != 0);
}
