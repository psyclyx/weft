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
//!     `lang`, `tool`, `role`, `offers`, `places`) plus every open key resolved
//!     there. `offers` and `places` are revisions, not values.
//!   - **One event**: `observe` compares the primary context's per-key
//!     fingerprints with the last delivered ones and reports the keys that
//!     moved. The app calls it once per frame, after layout, never inside a
//!     dispatch; listeners — wasm plugins (`on_context_changed`) and Zig
//!     consumers (`Listener`) alike — hear the same list.
//!
//! SUBJECTS. A projection presents ANOTHER entry's content — the outline is
//! the symbols of a document — so it must hear that content change: an edit,
//! and a parse that lands frames later without any edit at all. That is state
//! (a revision), not an occurrence, so it lives here beside the keys: a
//! producer WATCHES a subject by its designation (`watch`), `observeSubjects`
//! compares each watched subject's revision (`revisionOf`: the opening, its
//! text, and what is derived from the text) at the same frame boundary, and
//! the owner hears `on_subject_changed` once per moved subject, bound to the
//! subject's entry — so the doors it reads there are the subject's, and it
//! never brings the subject to the front to read it. Coalesced like the
//! keys: any number of edits and parses in one wake are one delivery, and a
//! change the listener makes is the next frame's.
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
const file = @import("file.zig");
const durable = @import("weft_semantic").durable;
const designation = @import("designation.zig");
const Router = @import("weft_fs_runtime").Router;

pub const Store = facts.context.Store;
pub const Open = facts.context.Open;
pub const Scope = facts.context.Scope;
pub const ScopeKind = facts.context.ScopeKind;

/// A reader into `context`'s store at `entry` — what `Facts.context` holds.
/// No context (a bare fixture) is a reader with no store: every open key
/// reads as unset.
pub fn openAt(context: ?*const Context, entry: *const Buffers.Buffer) Open {
    const c = context orelse return .{};
    return .{ .store = &c.store, .at = c.at(entry) };
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

/// What an entry's content derives besides its text — a grammar's tree — as
/// a number that moves whenever a derived reading lands (`Syntax.generation`).
/// Installed by whoever attaches such readings (the app's providers); core
/// cannot see them. Absent, a subject's revision is its opening and its text.
pub const Derived = *const fn (entry: *Buffers.Buffer) u64;

/// One producer watching one subject (`Context.watch`).
pub const Watch = struct {
    /// Who hears it: the plugin's name. Owned; compared, never interpreted.
    owner: []u8,
    /// The designation watched, as the owner spelled it. Owned.
    subject: []u8,
    /// The revision last delivered (or current when the watch began); null
    /// while no entry opens the subject.
    revision: ?u64,
};

/// A watched subject whose revision moved, as the last `observeSubjects`
/// found it: who hears it, and the entry its delivery is bound to.
pub const MovedSubject = struct {
    /// Owned copy: an owner unloading mid-delivery cannot free it.
    owner: []u8,
    entry: Buffers.Ref,
};

/// How many subjects one plugin may watch at once. A producer watches one
/// per tree it presents, so this is far past any real use; it bounds the
/// per-frame cost a misbehaving plugin can add.
pub const max_watches = 64;

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
    /// Who names a container place (`Router.designationOf`): the same system's
    /// filesystem router, set by whoever owns both. Absent, only the
    /// degenerate place has a name.
    filesystems: ?*const Router = null,
    /// The degenerate place's designation — the process directory, as
    /// `weft://here/dir/<path>` — taken once, when the context is made.
    /// Owned; empty when the directory cannot be named.
    process_place: []u8 = &.{},
    /// Who derives state from an entry's text (`Derived`), set by the app.
    derived: ?Derived = null,
    /// The subjects producers watch (`watch`), in the order they began.
    watches: std.ArrayList(Watch) = .empty,
    /// What the last `observeSubjects` found moved, for the app to deliver.
    /// Owned; replaced by the next observation.
    subjects_moved: std.ArrayList(MovedSubject) = .empty,

    pub fn init(gpa: Allocator) Context {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var named: [std.fs.max_path_bytes + 32]u8 = undefined;
        const dir = file.processDirectory(&buf) orelse "";
        const text: []const u8 = if (durable.Designation.ofPath(.directory, dir)) |d| d.render(&named) catch "" else "";
        return .{ .gpa = gpa, .store = .init(gpa), .process_place = gpa.dupe(u8, text) catch &.{} };
    }

    /// The designation a place is named by — the key a place-scoped value is
    /// published at and the `place` builtin's value. A container is named by
    /// whoever bound it; one nothing names (a directory since closed) is ""
    /// and covers nothing.
    pub fn placeName(self: *const Context, p: place_mod.Place) []const u8 {
        return switch (p) {
            .process => self.process_place,
            .container => |c| blk: {
                const router = self.filesystems orelse break :blk "";
                break :blk router.designationOf(c.ref, c.revision) orelse "";
            },
        };
    }

    /// The places the workspace is working in (doc/model.md §2.4's
    /// `places` projection): the place of every open entry, then every tree
    /// a peer shares with us (a peer directory binding at its root), each by
    /// its designation, once, in that order. Borrowed until the entries or
    /// the bindings change.
    pub fn places(self: *const Context, gpa: Allocator, buffers: *const Buffers, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        var it = buffers.iterator();
        while (it.next()) |entry| try addPlace(gpa, out, self.placeName(entry.place));
        const router = self.filesystems orelse return;
        const Visit = struct {
            gpa: Allocator,
            out: *std.ArrayList([]const u8),
            failed: bool = false,
            fn one(v: *@This(), text: []const u8) void {
                const d = durable.parse(text) orelse return;
                if (d.authority != .peer or d.kind != .directory or !std.mem.eql(u8, std.mem.trim(u8, d.ref, "/"), "")) return;
                addPlace(v.gpa, v.out, text) catch {
                    v.failed = true;
                };
            }
        };
        var visit: Visit = .{ .gpa = gpa, .out = out };
        router.eachDirectoryDesignation(&visit, Visit.one);
        if (visit.failed) return error.OutOfMemory;
    }

    fn addPlace(gpa: Allocator, out: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
        if (name.len == 0) return;
        for (out.items) |have| if (std.mem.eql(u8, have, name)) return;
        try out.append(gpa, name);
    }

    /// The store's coordinates for `entry`: its generation (unique for the
    /// life of the process, so a closed entry's values can never be read by
    /// the entry that reuses its slot) and its place's designation.
    pub fn at(self: *const Context, entry: *const Buffers.Buffer) facts.context.At {
        return .{ .entry = entry.generation, .place = self.placeName(entry.place) };
    }

    /// The coordinate a publication at `kind` lands on, for the entry a call
    /// is about. The place is the ENTRY's own, the level the stack names —
    /// not the head's working-target pin, which is where effects run, not
    /// what an entry is in — unless the publisher names one (`place`, a
    /// place's designation): a REPL retracting its session from wherever it
    /// is asked to quit names the place it published at, by the same string.
    pub fn scopeFor(self: *const Context, kind: ScopeKind, entry: *const Buffers.Buffer, place: []const u8) Scope {
        return switch (kind) {
            .entry => .{ .entry = entry.generation },
            .place => .{ .place = if (place.len != 0) place else self.placeName(entry.place) },
            .global => .global,
        };
    }

    pub fn deinit(self: *Context) void {
        self.gpa.free(self.process_place);
        for (self.watches.items) |w| self.freeWatch(w);
        self.watches.deinit(self.gpa);
        self.clearSubjectsMoved();
        self.subjects_moved.deinit(self.gpa);
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
        // An entry that closed took its entry-scoped values with it.
        for (ctx.buffers.drainClosed()) |generation| _ = self.store.retractEntry(generation);
        var now: Builder = .{ .gpa = self.gpa };
        defer now.list.deinit(self.gpa);
        if (intent.primaryScopeOf(ctx)) |scope| try now.primary(self, ctx, scope);
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

    /// What a projection of `entry` reads, as one number: which opening it
    /// is (a reopened subject is new content), its text's revision, and what
    /// is derived from the text (`derived` — a parse lands frames after the
    /// edit it reads, with no edit of its own). Equal numbers mean a reader
    /// sees the same thing. The chrome answer cache keys on it too, so a
    /// status answer asked before a parse landed is asked again after.
    pub fn revisionOf(self: *const Context, entry: *Buffers.Buffer) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&entry.generation));
        const text: u64 = if (entry.textEditor()) |ed| @intFromEnum(ed.doc.revision()) else 0;
        h.update(std.mem.asBytes(&text));
        const derived: u64 = if (self.derived) |d| d(entry) else 0;
        h.update(std.mem.asBytes(&derived));
        return h.final();
    }

    pub const WatchError = Allocator.Error || error{ NotADesignation, TooMany };

    /// `owner` hears `on_subject_changed` whenever the entry opening
    /// `subject` (a designation) reads differently (`revisionOf`), from the
    /// next frame boundary on. Watching what one already watches is a no-op.
    /// The revision now is the baseline, so a producer that watches right
    /// after reading its subject is not told about what it just read.
    pub fn watch(self: *Context, owner: []const u8, subject: []const u8, buffers: *const Buffers) WatchError!void {
        if (durable.parse(subject) == null) return error.NotADesignation;
        var mine: usize = 0;
        for (self.watches.items) |w| {
            if (!std.mem.eql(u8, w.owner, owner)) continue;
            if (std.mem.eql(u8, w.subject, subject)) return;
            mine += 1;
        }
        if (mine >= max_watches) return error.TooMany;
        const owned_owner = try self.gpa.dupe(u8, owner);
        errdefer self.gpa.free(owned_owner);
        const owned_subject = try self.gpa.dupe(u8, subject);
        errdefer self.gpa.free(owned_subject);
        const now = if (designation.findText(buffers, subject)) |entry| self.revisionOf(entry) else null;
        try self.watches.append(self.gpa, .{ .owner = owned_owner, .subject = owned_subject, .revision = now });
    }

    /// Stop `owner` hearing about `subject`. Not watched is not an error.
    pub fn unwatch(self: *Context, owner: []const u8, subject: []const u8) void {
        for (self.watches.items, 0..) |w, i| {
            if (!std.mem.eql(u8, w.owner, owner) or !std.mem.eql(u8, w.subject, subject)) continue;
            self.freeWatch(self.watches.orderedRemove(i));
            return;
        }
    }

    /// Every watch `owner` holds ends (the plugin unloaded).
    pub fn unwatchOwner(self: *Context, owner: []const u8) void {
        var i = self.watches.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.watches.items[i].owner, owner)) self.freeWatch(self.watches.orderedRemove(i));
        }
    }

    fn freeWatch(self: *Context, w: Watch) void {
        self.gpa.free(w.owner);
        self.gpa.free(w.subject);
    }

    fn clearSubjectsMoved(self: *Context) void {
        for (self.subjects_moved.items) |m| self.gpa.free(m.owner);
        self.subjects_moved.clearRetainingCapacity();
    }

    /// Compare every watched subject's revision with the one last delivered
    /// and record which moved (`subjects_moved`). A subject no entry opens
    /// has nothing to read and is not delivered; it moves again when an
    /// entry opens it. Returns whether any moved. The caller (the app's frame
    /// boundary) decides WHEN, and delivers.
    pub fn observeSubjects(self: *Context, buffers: *const Buffers) Allocator.Error!bool {
        self.clearSubjectsMoved();
        for (self.watches.items) |*w| {
            const entry = designation.findText(buffers, w.subject) orelse {
                w.revision = null;
                continue;
            };
            const now = self.revisionOf(entry);
            if (w.revision != null and w.revision.? == now) continue;
            try self.subjects_moved.ensureUnusedCapacity(self.gpa, 1);
            const owner = try self.gpa.dupe(u8, w.owner);
            self.subjects_moved.appendAssumeCapacity(.{ .owner = owner, .entry = entry.ref() });
            w.revision = now;
        }
        return self.subjects_moved.items.len > 0;
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

    fn primary(self: *Builder, context: *const Context, ctx: *command.Context, scope: intent.Scope) Allocator.Error!void {
        const f = intent.factsIn(scope);

        for (facts.context.builtin_keys) |key| {
            if (std.mem.eql(u8, key, "offers")) {
                const plane = ctx.intent orelse continue;
                self.add(key, plane.offersFingerprint(ctx, .primary));
                continue;
            }
            if (std.mem.eql(u8, key, "places")) {
                // The workspace's places list, in order: an entry opening in
                // a new place anywhere, or a peer sharing a tree, moves it
                // while the primary `place` stays put.
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.gpa);
                try context.places(self.gpa, ctx.buffers, &names);
                var h = std.hash.Wyhash.init(0);
                for (names.items) |n| {
                    h.update(n);
                    h.update("\n");
                }
                self.add(key, h.final());
                continue;
            }
            const v = f.get(key) orelse continue;
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

test "context: a place is named by its designation, and one nothing names is no place" {
    var context = Context.init(t.allocator);
    defer context.deinit();
    // The degenerate place is the process directory, as a designation.
    try t.expect(std.mem.startsWith(u8, context.placeName(.process), "weft://here/dir/"));
    // A container nothing binds (no router, or a closed directory) has no
    // name, so nothing can be published at it or read from it.
    const unnamed: place_mod.Place = .{ .container = .{ .locus = .here, .ref = .{ .authority = .here, .slot = 1, .generation = 1 }, .revision = 3 } };
    try t.expectEqualStrings("", context.placeName(unnamed));
}

test "context: closing an entry retracts what was published at it" {
    const gpa = t.allocator;
    var env: @import("TestHost.zig") = undefined;
    try @import("TestHost.zig").init(gpa, &env);
    defer env.deinit(gpa);
    const id = try env.buffers.create(gpa, "*tool*");
    const generation = env.buffers.get(id).?.generation;
    _ = try env.context.store.set("x", .{ .entry = generation }, "x.k", "v");
    _ = try env.context.store.set("x", .global, "x.g", "stays");
    try env.buffers.close(gpa, id, &env.head, &env.keymap);
    _ = try env.context.observe(&env.ctx);
    try t.expectEqual(@as(usize, 1), env.context.store.values.items.len);
    try t.expectEqualStrings("stays", env.context.store.get(.{}, "x.g").?);
}

/// A stand-in for the app's parse generation: what a test moves by hand.
var test_derived: u64 = 0;
fn testDerived(_: *Buffers.Buffer) u64 {
    return test_derived;
}

test "context: a watched subject moves on an edit and on a derived reading, once per observation" {
    const gpa = t.allocator;
    var env: @import("TestHost.zig") = undefined;
    try @import("TestHost.zig").init(gpa, &env);
    defer env.deinit(gpa);
    env.context.derived = testDerived;
    test_derived = 0;
    const entry = env.buffers.active();
    var buf: [designation.max_len]u8 = undefined;
    const subject = designation.of(entry, &buf).?;

    try env.context.watch("symbols", subject, &env.buffers);
    try env.context.watch("symbols", subject, &env.buffers); // idempotent
    try t.expectEqual(@as(usize, 1), env.context.watches.items.len);
    try t.expectError(error.NotADesignation, env.context.watch("symbols", "not one", &env.buffers));
    // The baseline is what the watcher just read: nothing has moved.
    try t.expect(!try env.context.observeSubjects(&env.buffers));

    // Many edits in one wake are one delivery, bound to the subject's entry.
    try entry.textEditor().?.doc.insert(gpa, 0, "a");
    try entry.textEditor().?.doc.insert(gpa, 1, "b");
    try t.expect(try env.context.observeSubjects(&env.buffers));
    try t.expectEqual(@as(usize, 1), env.context.subjects_moved.items.len);
    try t.expectEqualStrings("symbols", env.context.subjects_moved.items[0].owner);
    try t.expect(std.meta.eql(entry.ref(), env.context.subjects_moved.items[0].entry));
    try t.expect(!try env.context.observeSubjects(&env.buffers));

    // A parse that lands with no edit is a move too.
    test_derived += 1;
    try t.expect(try env.context.observeSubjects(&env.buffers));

    // Unloading ends every watch the owner held.
    env.context.unwatchOwner("symbols");
    try t.expectEqual(@as(usize, 0), env.context.watches.items.len);
    try entry.textEditor().?.doc.insert(gpa, 0, "c");
    try t.expect(!try env.context.observeSubjects(&env.buffers));
}

test "context: one plugin's watches are bounded, and another's are its own" {
    const gpa = t.allocator;
    var env: @import("TestHost.zig") = undefined;
    try @import("TestHost.zig").init(gpa, &env);
    defer env.deinit(gpa);
    var name: [64]u8 = undefined;
    for (0..max_watches) |i| try env.context.watch("p", try std.fmt.bufPrint(&name, "weft://here/p.k/{d}", .{i}), &env.buffers);
    try t.expectError(error.TooMany, env.context.watch("p", "weft://here/p.k/over", &env.buffers));
    try env.context.watch("q", "weft://here/q.k/0", &env.buffers);
}
