//! The OPEN half of context (doc/model.md §2.5): keyed string values any
//! plugin may publish at a scope, resolved most-specific-wins over the stack
//! entry → place → global.
//!
//! Core computes a handful of keys it alone can answer (`entry`, `place`,
//! `mode`, `posture`, `locality`, `lang`, `tool`, `role`, `offers`), and those
//! stay typed fields of `Facts`. Everything else — "a REPL is connected
//! here", "this project has a test runner" — used to have nowhere to live:
//! `Facts` was a closed struct, so a plugin that knew something about a
//! context could only act on it, never SAY it where a predicate could read
//! it. This is where it says it.
//!
//! Two rules make the space safe to leave open:
//!
//!   - **A published key is namespaced** (`repl.session`): it contains a dot,
//!     and every builtin key has none. A plugin therefore cannot shadow a
//!     builtin — not by policy, but because no builtin name passes
//!     `isPublishableKey`. Core names no plugin key, and no plugin can name a
//!     core one.
//!   - **A namespace is its publisher's name.** A plugin publishes only
//!     keys under its own name (`repl` publishes `repl.session`), so a key
//!     has exactly one possible owner by construction: no plugin can take
//!     another's key by publishing it first, and resolution cannot depend
//!     on load order (`ownsKey`; a write outside one's namespace is
//!     `error.NotOwnNamespace`). `error.Held` stays as the store's own
//!     guard for a write by a different owner of a held key.
//!
//! Values are strings, because the values worth publishing are names — and a
//! durable name for content is a designation, which is a string
//! (`weft://here/proc/7`).
//!
//! `std` is the only import, for the same reason as `root.zig`'s: `Facts`
//! carries a reader into this store, and `Facts` must compile wherever any
//! plane runs.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The keys core computes. A predicate or a reader may name them like any
/// other key (`Facts.get` answers them from the typed fields); a plugin can
/// never publish one — none contains a dot.
pub const builtin_keys = [_][]const u8{ "entry", "place", "mode", "posture", "locality", "lang", "tool", "role", "offers", "places" };

pub const max_key_len = 64;
/// Long enough for any designation a value is expected to be.
pub const max_value_len = 2048;

pub fn isBuiltinKey(key: []const u8) bool {
    for (builtin_keys) |b| if (std.mem.eql(u8, b, key)) return true;
    return false;
}

/// A key a plugin may publish: 1..`max_key_len` bytes of `[a-z0-9_-]`
/// segments joined by dots, at least two segments. The dot is the namespace,
/// and its presence is what keeps every builtin (none has one) out of reach.
pub fn isPublishableKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    var dots: usize = 0;
    var prev_dot = true; // a leading dot is an empty segment
    for (key) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '_', '-' => prev_dot = false,
            '.' => {
                if (prev_dot) return false;
                dots += 1;
                prev_dot = true;
            },
            else => return false,
        }
    }
    return dots > 0 and !prev_dot;
}

/// Whether publisher `owner` may write `key`: the key's namespace (its first
/// segment) is the owner's name.
pub fn ownsKey(owner: []const u8, key: []const u8) bool {
    return owner.len != 0 and key.len > owner.len and
        std.mem.startsWith(u8, key, owner) and key[owner.len] == '.';
}

/// A key a reader or predicate may name: a builtin or a publishable key.
/// Anything else is a spelling mistake, refused where it is written rather
/// than matching nothing forever.
pub fn isKeyName(key: []const u8) bool {
    return isBuiltinKey(key) or isPublishableKey(key);
}

/// Which level of the stack a value is published at. The wire value is the
/// integer (`wl_context_set`'s last argument).
pub const ScopeKind = enum(u32) { entry = 0, place = 1, global = 2 };

/// A publication's coordinate, exact (no hashing): an entry is its
/// generation, unique for the life of the process and never reused; a place
/// is its DESIGNATION (`weft://here/dir/…`, doc/model.md §2.1) — the durable
/// name of its container, so two handles to one directory are one place,
/// and a publisher can name a place it is not standing in (a REPL retracting
/// its session from another project) by the same string it published at.
/// In a stored value the place bytes are the store's; in a question they
/// are borrowed.
pub const Scope = union(ScopeKind) {
    entry: u64,
    place: []const u8,
    global,

    pub fn eql(a: Scope, b: Scope) bool {
        return switch (a) {
            .entry => |e| b == .entry and b.entry == e,
            .place => |p| b == .place and std.mem.eql(u8, b.place, p),
            .global => b == .global,
        };
    }

    /// How specific: an entry says more than its place, a place more than
    /// the workspace. Higher wins.
    fn rank(self: Scope) u8 {
        return switch (self) {
            .entry => 2,
            .place => 1,
            .global => 0,
        };
    }
};

/// WHERE a question is asked: the entry (0 = none) and the designation of
/// the place it is in ("" = none). Every value whose scope covers these
/// coordinates is a candidate.
pub const At = struct {
    entry: u64 = 0,
    place: []const u8 = "",

    fn covers(self: At, s: Scope) bool {
        return switch (s) {
            .entry => |e| e != 0 and e == self.entry,
            .place => |p| p.len != 0 and std.mem.eql(u8, p, self.place),
            .global => true,
        };
    }
};

const Value = struct {
    owner: []u8,
    scope: Scope,
    key: []u8,
    value: []u8,
    /// The store's clock when this value was last written (`Store.revision`).
    stamp: u64,

    fn free(self: Value, gpa: Allocator) void {
        if (self.scope == .place) gpa.free(self.scope.place);
        gpa.free(self.owner);
        gpa.free(self.key);
        gpa.free(self.value);
    }
};

pub const SetError = error{
    /// Not a publishable key (see `isPublishableKey`).
    BadKey,
    /// Longer than `max_value_len`.
    BadValue,
    /// Another owner already publishes this key at this scope.
    Held,
    /// The key is not under the publisher's own name (`ownsKey`).
    NotOwnNamespace,
    /// A place scope that names no place (the entry is in none this editor
    /// can name, or the publisher gave an empty designation).
    NoPlace,
} || Allocator.Error;

pub const Store = struct {
    gpa: Allocator,
    /// Every publication, GROUPED BY KEY — sorted by the key's bytes, so one
    /// key's candidates are one contiguous run: resolving a key is a binary
    /// search and a run, and resolving every key at a coordinate (`each`,
    /// every frame) is one pass.
    values: std.ArrayList(Value) = .empty,
    /// The store's clock: every write stamps the value it leaves with the
    /// next tick (`Value.stamp`), so a reader's digest can fold exactly the
    /// values it sees, and moves for nothing else.
    revision: u64 = 0,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.values.items) |v| v.free(self.gpa);
        self.values.deinit(self.gpa);
        self.* = undefined;
    }

    fn tick(self: *Store) u64 {
        self.revision += 1;
        return self.revision;
    }

    /// The first index whose key is not below `key` (`upper`: not at or
    /// below it).
    fn bound(self: *const Store, key: []const u8, comptime upper: bool) usize {
        var lo: usize = 0;
        var hi: usize = self.values.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const order = std.mem.order(u8, self.values.items[mid].key, key);
            if (order == .lt or (upper and order == .eq)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The run of values published for `key`.
    fn group(self: *const Store, key: []const u8) []const Value {
        return self.values.items[self.bound(key, false)..self.bound(key, true)];
    }

    fn find(self: *const Store, scope: Scope, key: []const u8) ?usize {
        const start = self.bound(key, false);
        for (self.group(key), start..) |v, i| if (v.scope.eql(scope)) return i;
        return null;
    }

    fn removeAt(self: *Store, i: usize) void {
        self.values.orderedRemove(i).free(self.gpa);
        _ = self.tick();
    }

    /// Publish `value` for `key` at `scope`, as `owner`. An EMPTY value
    /// retracts — "nothing is true here" is absence, not an empty claim.
    /// Returns whether anything changed.
    pub fn set(self: *Store, owner: []const u8, scope: Scope, key: []const u8, value: []const u8) SetError!bool {
        if (!isPublishableKey(key)) return error.BadKey;
        if (!ownsKey(owner, key)) return error.NotOwnNamespace;
        if (scope == .place and scope.place.len == 0) return error.NoPlace;
        if (value.len > max_value_len) return error.BadValue;
        if (self.find(scope, key)) |i| {
            const held = &self.values.items[i];
            if (!std.mem.eql(u8, held.owner, owner)) return error.Held;
            if (value.len == 0) {
                self.removeAt(i);
                return true;
            }
            if (std.mem.eql(u8, held.value, value)) return false;
            const copy = try self.gpa.dupe(u8, value);
            self.gpa.free(held.value);
            held.value = copy;
            held.stamp = self.tick();
            return true;
        }
        if (value.len == 0) return false;
        const owned_owner = try self.gpa.dupe(u8, owner);
        errdefer self.gpa.free(owned_owner);
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const owned_value = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(owned_value);
        const owned_scope: Scope = switch (scope) {
            .place => |p| .{ .place = try self.gpa.dupe(u8, p) },
            else => scope,
        };
        errdefer if (owned_scope == .place) self.gpa.free(owned_scope.place);
        // At the end of its key's run: the grouping holds, and one key's
        // values keep the order they were published in.
        try self.values.insert(self.gpa, self.bound(key, true), .{
            .owner = owned_owner,
            .scope = owned_scope,
            .key = owned_key,
            .value = owned_value,
            .stamp = self.revision + 1,
        });
        _ = self.tick();
        return true;
    }

    /// Retract every value `drop` says to.
    fn retractWhere(self: *Store, context: anytype, comptime drop: fn (@TypeOf(context), *const Value) bool) usize {
        var n: usize = 0;
        var i = self.values.items.len;
        while (i > 0) {
            i -= 1;
            if (drop(context, &self.values.items[i])) {
                self.removeAt(i);
                n += 1;
            }
        }
        return n;
    }

    /// Retract everything `owner` published — what unloading a plugin does,
    /// so a value can never outlive the code that knew it was true.
    pub fn retractOwner(self: *Store, owner: []const u8) usize {
        return self.retractWhere(owner, struct {
            fn drop(o: []const u8, v: *const Value) bool {
                return std.mem.eql(u8, v.owner, o);
            }
        }.drop);
    }

    /// Retract every value published at the entry of `generation` — what
    /// closing that entry does. A generation is never reused, so nothing
    /// could read them again; retracting is what stops them costing every
    /// reader that walks the store.
    pub fn retractEntry(self: *Store, generation: u64) usize {
        return self.retractWhere(generation, struct {
            fn drop(g: u64, v: *const Value) bool {
                return v.scope == .entry and v.scope.entry == g;
            }
        }.drop);
    }

    /// The winner among `run` (one key's values) at `at`: the most specific
    /// scope that covers it.
    fn winner(run: []const Value, at: At) ?*const Value {
        var best: ?*const Value = null;
        for (run) |*v| {
            if (!at.covers(v.scope)) continue;
            if (best == null or v.scope.rank() > best.?.scope.rank()) best = v;
        }
        return best;
    }

    /// The winning value for `key` at `at`: the most specific scope that
    /// covers it. Null when nothing is published there.
    pub fn get(self: *const Store, at: At, key: []const u8) ?[]const u8 {
        return if (winner(self.group(key), at)) |w| w.value else null;
    }

    /// Visit every key resolved at `at`, once each, with its winning value,
    /// in key order. One pass: a key's values are one run.
    pub fn each(self: *const Store, at: At, context: anytype, comptime visit: fn (@TypeOf(context), []const u8, []const u8) void) void {
        var it = self.winners(at);
        while (it.next()) |w| visit(context, w.key, w.value);
    }

    /// The value that wins each key resolved at `at`, in key order.
    fn winners(self: *const Store, at: At) Winners {
        return .{ .values = self.values.items, .at = at };
    }

    const Winners = struct {
        values: []const Value,
        at: At,
        i: usize = 0,

        fn next(self: *Winners) ?*const Value {
            while (self.i < self.values.len) {
                const start = self.i;
                const key = self.values[start].key;
                while (self.i < self.values.len and std.mem.eql(u8, self.values[self.i].key, key)) self.i += 1;
                if (winner(self.values[start..self.i], self.at)) |w| return w;
            }
            return null;
        }
    };
};

/// A reader into a store at fixed coordinates — what `Facts.context` holds.
/// Absent (no store) means "this caller did not say", which the reflective
/// `Facts.merge` reads through `present`.
pub const Open = struct {
    store: ?*const Store = null,
    at: At = .{},

    pub fn present(self: Open) bool {
        return self.store != null;
    }

    pub fn get(self: Open, key: []const u8) ?[]const u8 {
        const s = self.store orelse return null;
        return s.get(self.at, key);
    }

    /// Moves exactly when a resolution through this reader could: it folds
    /// the value that wins each key here (its key and stamp) and nothing
    /// else, so a publication in another place, at another entry, or
    /// shadowed here by a more specific one leaves every cache keyed on this
    /// reader standing (a pane's answers, a catalog snapshot). For
    /// signatures and catalog clocks.
    pub fn digest(self: Open) u64 {
        const s = self.store orelse return 0;
        var h = std.hash.Wyhash.init(0);
        var it = s.winners(self.at);
        while (it.next()) |w| {
            h.update(w.key);
            h.update(std.mem.asBytes(&w.stamp));
        }
        return h.final();
    }
};

const t = std.testing;

test "context: the most specific scope wins, and each scope is only seen where it covers" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    _ = try s.set("x", .global, "x.k", "global");
    _ = try s.set("x", .{ .place = "weft://here/dir/p7" }, "x.k", "place");
    _ = try s.set("x", .{ .entry = 3 }, "x.k", "entry");

    try t.expectEqualStrings("entry", s.get(.{ .entry = 3, .place = "weft://here/dir/p7" }, "x.k").?);
    // Another entry in the same place sees the place's value…
    try t.expectEqualStrings("place", s.get(.{ .entry = 4, .place = "weft://here/dir/p7" }, "x.k").?);
    // …another place sees the workspace's…
    try t.expectEqualStrings("global", s.get(.{ .entry = 4, .place = "weft://here/dir/p8" }, "x.k").?);
    // …and an entry value never leaks to an entryless question.
    try t.expectEqualStrings("place", s.get(.{ .place = "weft://here/dir/p7" }, "x.k").?);
    try t.expectEqual(@as(?[]const u8, null), s.get(.{}, "y.k"));

    // Retracting the entry's value uncovers the place's.
    _ = try s.set("x", .{ .entry = 3 }, "x.k", "");
    try t.expectEqualStrings("place", s.get(.{ .entry = 3, .place = "weft://here/dir/p7" }, "x.k").?);
}

test "context: a key has one possible owner — its namespace's — whoever publishes first, and unloading retracts it" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // Another plugin cannot take `repl.session`, at any scope, even first.
    try t.expectError(error.NotOwnNamespace, s.set("other", .{ .place = "weft://here/dir/p2" }, "repl.session", "mine"));
    try t.expectError(error.NotOwnNamespace, s.set("rep", .global, "repl.session", "mine"));
    try t.expect(try s.set("repl", .{ .place = "weft://here/dir/p1" }, "repl.session", "*repl*"));
    // The same write again changes nothing.
    try t.expect(!try s.set("repl", .{ .place = "weft://here/dir/p1" }, "repl.session", "*repl*"));
    try t.expectError(error.NotOwnNamespace, s.set("other", .{ .place = "weft://here/dir/p1" }, "repl.session", "mine"));
    try t.expect(try s.set("other", .{ .place = "weft://here/dir/p1" }, "other.session", "mine"));

    const rev = s.revision;
    try t.expectEqual(@as(usize, 1), s.retractOwner("repl"));
    try t.expect(s.revision != rev);
    try t.expectEqual(@as(?[]const u8, null), s.get(.{ .place = "weft://here/dir/p1" }, "repl.session"));
    try t.expectEqualStrings("mine", s.get(.{ .place = "weft://here/dir/p1" }, "other.session").?);
}

test "context: a place is its designation — named by value, held by the store, never empty" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    var named = "weft://here/dir/srv/proj".*;
    _ = try s.set("repl", .{ .place = &named }, "repl.session", "weft://here/proc/repl.1");
    // The store keeps its own copy: the publisher's bytes can go.
    @memset(&named, 'x');
    try t.expectEqualStrings("weft://here/proc/repl.1", s.get(.{ .entry = 9, .place = "weft://here/dir/srv/proj" }, "repl.session").?);
    // An entry in no nameable place sees no place's values…
    try t.expectEqual(@as(?[]const u8, null), s.get(.{ .entry = 9 }, "repl.session"));
    // …and nothing can be published at one.
    try t.expectError(error.NoPlace, s.set("repl", .{ .place = "" }, "repl.session", "v"));
    // Retracting names the place by the same string, from anywhere.
    _ = try s.set("repl", .{ .place = "weft://here/dir/srv/proj" }, "repl.session", "");
    try t.expectEqual(@as(?[]const u8, null), s.get(.{ .place = "weft://here/dir/srv/proj" }, "repl.session"));
}

test "context: no plugin can publish a builtin, or a key that is not namespaced" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    for (builtin_keys) |b| try t.expectError(error.BadKey, s.set("p", .global, b, "v"));
    for ([_][]const u8{ "", "repl", ".x", "x.", "a..b", "A.b", "a b.c", "a.b/c" }) |bad|
        try t.expectError(error.BadKey, s.set("p", .global, bad, "v"));
    try t.expect(isKeyName("mode") and isKeyName("repl.session") and !isKeyName("repl"));
    const long = [_]u8{'x'} ** (max_value_len + 1);
    try t.expectError(error.BadValue, s.set("a", .global, "a.b", &long));
}

test "context: each visits every resolved key once, with its winner" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    _ = try s.set("a", .global, "a.k", "g");
    _ = try s.set("a", .{ .entry = 1 }, "a.k", "e");
    _ = try s.set("b", .global, "b.k", "g2");
    _ = try s.set("c", .{ .place = "weft://here/dir/p9" }, "c.k", "elsewhere");
    const Seen = struct {
        buf: [4][2][]const u8 = undefined,
        n: usize = 0,
        fn visit(self: *@This(), k: []const u8, v: []const u8) void {
            self.buf[self.n] = .{ k, v };
            self.n += 1;
        }
    };
    var seen: Seen = .{};
    s.each(.{ .entry = 1 }, &seen, Seen.visit);
    try t.expectEqual(@as(usize, 2), seen.n);
    try t.expectEqualStrings("a.k", seen.buf[0][0]);
    try t.expectEqualStrings("e", seen.buf[0][1]);
    try t.expectEqualStrings("b.k", seen.buf[1][0]);
}

test "context: a reader's digest moves only for what it can see" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const here: Open = .{ .store = &s, .at = .{ .entry = 1, .place = "weft://here/dir/p1" } };
    const other: Open = .{ .store = &s, .at = .{ .entry = 2, .place = "weft://here/dir/p2" } };
    _ = try s.set("a", .{ .place = "weft://here/dir/p1" }, "a.k", "one");
    const before = here.digest();
    const other_before = other.digest();

    // Another place's publication and another entry's are not visible here…
    _ = try s.set("b", .{ .place = "weft://here/dir/p2" }, "b.k", "two");
    _ = try s.set("b", .{ .entry = 2 }, "b.j", "three");
    try t.expectEqual(before, here.digest());
    try t.expect(other.digest() != other_before);
    // …nor is a value shadowed here by a more specific one.
    _ = try s.set("a", .{ .entry = 1 }, "a.k", "mine");
    const shadowed = here.digest();
    try t.expect(shadowed != before);
    _ = try s.set("a", .global, "a.k", "under");
    try t.expectEqual(shadowed, here.digest());

    // What it does see moves it: a change, and a retraction.
    _ = try s.set("a", .{ .entry = 1 }, "a.k", "");
    try t.expect(here.digest() != shadowed);
    _ = try s.set("a", .{ .place = "weft://here/dir/p1" }, "a.k", "");
    try t.expect(here.digest() != before);
}

test "context: an entry's values go with its generation" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    _ = try s.set("a", .{ .entry = 7 }, "a.k", "x");
    _ = try s.set("b", .{ .entry = 7 }, "b.k", "y");
    _ = try s.set("a", .{ .entry = 8 }, "a.k", "z");
    try t.expectEqual(@as(usize, 2), s.retractEntry(7));
    try t.expectEqual(@as(usize, 1), s.values.items.len);
    try t.expectEqualStrings("z", s.get(.{ .entry = 8 }, "a.k").?);
}
