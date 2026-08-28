//! env.zig — the environment an effect runs WITH, resolved for a place.
//!
//! `wasm_host/plugin.zig`'s `g_environ` is one process-wide environment, set
//! once from `main`. It is read at exactly the same five spawn sites as the
//! working directory used to be, and it has the same defect: nothing can vary
//! it per interaction. That is why `direnv` is display-only today — its own
//! header says applying the exported environment "is the next step, once a
//! per-project env overlay crosses the membrane" — and it is why per-project
//! toolchains (nix shells, mise/asdf, virtualenvs, node versions) cannot work
//! at all.
//!
//! ## An environment is resolved FOR a place, not part of one
//!
//! `doc/place.md` §2. A `Place` is `(locus, container)` and nothing else. If
//! the environment were a component of that value, a `direnv reload` — which
//! changes only the environment — would change the place's IDENTITY,
//! invalidating every session linked to it and every entry that inherited it.
//! Keeping identity stable while what is true at that identity moves is the
//! whole reason this is a separate table keyed BY a place.
//!
//! ## Publishing an environment is publishing execution
//!
//! Load-bearing, and the reason this is a granted capability rather than
//! ambient authority: anything that can set `PATH` for a place owns every
//! subprocess run in it. `direnv` already treats its own `allow` as
//! TOFU-shaped ("runs arbitrary code on the target host, hence a deliberate
//! explicit action"); an overlay inherits exactly that weight. This module is
//! the mechanism; the gate belongs at the door that calls `publish`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Place = @import("place.zig").Place;

/// A revision-stamped environment overlay for one place, from one publisher.
pub const Overlay = struct {
    place: Place,
    /// The publishing principal. Part of the key, so two providers can each
    /// speak for a place without silently clobbering one another, and so a
    /// retraction can only withdraw what its owner published.
    owner: []u8,
    /// Bumped on every republish. A consumer that cached a resolution compares
    /// this to know it is stale, rather than polling for changes.
    revision: u64,
    /// NUL-separated `KEY=VALUE` records. Kept in the publisher's own wire
    /// shape rather than a parsed map: this table never interprets the values,
    /// and a shape it does not parse is a shape it cannot corrupt.
    vars: []u8,
};

/// The per-place environment overlays. Owns everything it holds.
pub const Environments = struct {
    gpa: Allocator,
    entries: std.ArrayList(Overlay) = .empty,
    /// Bumped on every publish or retraction, so a consumer can cheaply notice
    /// that ANY overlay moved without diffing the table.
    epoch: u64 = 0,

    pub fn init(gpa: Allocator) Environments {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Environments) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.owner);
            self.gpa.free(e.vars);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Publish (or replace) `owner`'s overlay for `place`. Returns the new
    /// revision.
    ///
    /// A republish REPLACES IN PLACE rather than appending, so the order
    /// overlays are applied in stays stable across reloads. Otherwise a
    /// `direnv reload` could silently change which of two publishers wins a
    /// contested key.
    pub fn publish(self: *Environments, place: Place, owner: []const u8, vars: []const u8) Allocator.Error!u64 {
        const owned_vars = try self.gpa.dupe(u8, vars);
        errdefer self.gpa.free(owned_vars);
        for (self.entries.items) |*e| {
            if (!e.place.eql(place) or !std.mem.eql(u8, e.owner, owner)) continue;
            self.gpa.free(e.vars);
            e.vars = owned_vars;
            e.revision += 1;
            self.epoch += 1;
            return e.revision;
        }
        const owned_owner = try self.gpa.dupe(u8, owner);
        errdefer self.gpa.free(owned_owner);
        try self.entries.append(self.gpa, .{
            .place = place,
            .owner = owned_owner,
            .revision = 1,
            .vars = owned_vars,
        });
        self.epoch += 1;
        return 1;
    }

    /// Withdraw `owner`'s overlay for `place`. True when something was
    /// withdrawn. An owner can only retract its own.
    pub fn retract(self: *Environments, place: Place, owner: []const u8) bool {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const e = self.entries.items[i];
            if (!e.place.eql(place) or !std.mem.eql(u8, e.owner, owner)) continue;
            self.gpa.free(e.owner);
            self.gpa.free(e.vars);
            _ = self.entries.orderedRemove(i);
            self.epoch += 1;
            return true;
        }
        return false;
    }

    /// Drop every overlay for `place` — what a container going away means.
    pub fn retractPlace(self: *Environments, place: Place) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (!self.entries.items[i].place.eql(place)) {
                i += 1;
                continue;
            }
            const e = self.entries.items[i];
            self.gpa.free(e.owner);
            self.gpa.free(e.vars);
            _ = self.entries.orderedRemove(i);
            removed += 1;
        }
        if (removed != 0) self.epoch += 1;
        return removed;
    }

    /// Whether any overlay applies to `place` — the cheap check a spawn door
    /// makes before doing the work of merging an environment.
    pub fn has(self: *const Environments, place: Place) bool {
        for (self.entries.items) |e| if (e.place.eql(place)) return true;
        return false;
    }

    /// The combined revision of every overlay applying to `place`. Two calls
    /// returning the same value mean the same environment; it changes whenever
    /// any contributing overlay is republished, retracted, or added.
    pub fn revisionFor(self: *const Environments, place: Place) u64 {
        var sum: u64 = 0;
        for (self.entries.items) |e| {
            if (!e.place.eql(place)) continue;
            sum +%= e.revision;
            sum +%= 0x9e3779b97f4a7c15; // separate "one overlay at rev 2" from "two at rev 1"
        }
        return sum;
    }

    /// `base` with every overlay for `place` applied, in publish order, as an
    /// OWNED environment the caller must `deinit`. Null when no overlay
    /// applies — the caller then passes `base` through untouched, which keeps
    /// the ordinary case allocation-free.
    ///
    /// Later publishers win a contested key, which is what publish order
    /// means; `publish` replacing in place is what keeps that stable.
    pub fn merged(
        self: *const Environments,
        gpa: Allocator,
        base: std.process.Environ,
        place: Place,
    ) !?std.process.Environ {
        if (!self.has(place)) return null;
        var map = try base.createMap(gpa);
        defer map.deinit();
        for (self.entries.items) |e| {
            if (!e.place.eql(place)) continue;
            var it = std.mem.splitScalar(u8, e.vars, 0);
            while (it.next()) |record| {
                if (record.len == 0) continue;
                // A record without '=' is not a variable. Skip it rather than
                // guessing an empty value: a malformed publish must not be
                // able to blank out an inherited key.
                const eq = std.mem.indexOfScalar(u8, record, '=') orelse continue;
                if (eq == 0) continue; // no name
                try map.put(record[0..eq], record[eq + 1 ..]);
            }
        }
        const block = try map.createPosixBlock(gpa, .{});
        return .{ .block = block };
    }
};

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn at(slot: u32) Place {
    return .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = slot, .generation = 1 },
        .revision = 1,
    } };
}

test "env: publish is keyed by (place, owner) and republish replaces in place" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();

    try t.expectEqual(@as(u64, 1), try envs.publish(at(1), "direnv", "A=1\x00"));
    try t.expectEqual(@as(u64, 1), try envs.publish(at(1), "nix", "B=2\x00"));
    try t.expectEqual(@as(usize, 2), envs.entries.items.len);

    // A republish by the same owner bumps its revision and keeps its slot, so
    // the order overlays are applied in does not move under a reload.
    try t.expectEqual(@as(u64, 2), try envs.publish(at(1), "direnv", "A=9\x00"));
    try t.expectEqual(@as(usize, 2), envs.entries.items.len);
    try t.expectEqualStrings("direnv", envs.entries.items[0].owner);
}

test "env: a place with no overlay merges to null, not to an empty environment" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();
    try t.expectEqual(@as(u64, 1), try envs.publish(at(1), "direnv", "A=1\x00"));

    // The ordinary case stays allocation-free: nothing published HERE.
    try t.expect(!envs.has(at(2)));
    try t.expect((try envs.merged(t.allocator, .empty, at(2))) == null);
}

test "env: overlays layer, later publishers win a contested key" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();
    _ = try envs.publish(at(1), "aaa", "SHARED=first\x00ONLY_A=a\x00");
    _ = try envs.publish(at(1), "zzz", "SHARED=second\x00");

    var merged = (try envs.merged(t.allocator, .empty, at(1))).?;
    defer merged.block.deinit(t.allocator);
    try t.expectEqualStrings("second", merged.getPosix("SHARED").?);
    try t.expectEqualStrings("a", merged.getPosix("ONLY_A").?);
}

test "env: a malformed record cannot blank an inherited key" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();
    // "NOEQUALS" has no '=' and "=novalue" has no name. Neither is a variable,
    // and neither may be interpreted as "set this to empty".
    _ = try envs.publish(at(1), "d", "NOEQUALS\x00=novalue\x00GOOD=yes\x00");

    var merged = (try envs.merged(t.allocator, .empty, at(1))).?;
    defer merged.block.deinit(t.allocator);
    try t.expectEqualStrings("yes", merged.getPosix("GOOD").?);
    try t.expect(merged.getPosix("NOEQUALS") == null);
}

test "env: retraction is owner-scoped, and a place can be cleared wholesale" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();
    _ = try envs.publish(at(1), "direnv", "A=1\x00");
    _ = try envs.publish(at(1), "nix", "B=2\x00");
    _ = try envs.publish(at(2), "direnv", "C=3\x00");

    // An owner withdraws only its own.
    try t.expect(envs.retract(at(1), "direnv"));
    try t.expect(!envs.retract(at(1), "direnv")); // already gone
    try t.expect(envs.has(at(1))); // nix's overlay survives

    // A container going away takes every overlay for it, and nothing else.
    try t.expectEqual(@as(usize, 1), envs.retractPlace(at(1)));
    try t.expect(!envs.has(at(1)));
    try t.expect(envs.has(at(2)));
}

test "env: the revision for a place moves whenever its environment does" {
    var envs: Environments = .init(t.allocator);
    defer envs.deinit();
    const none = envs.revisionFor(at(1));

    _ = try envs.publish(at(1), "direnv", "A=1\x00");
    const one = envs.revisionFor(at(1));
    try t.expect(one != none);

    // A reload changes it...
    _ = try envs.publish(at(1), "direnv", "A=2\x00");
    const reloaded = envs.revisionFor(at(1));
    try t.expect(reloaded != one);

    // ...and so does a second publisher arriving, which a naive sum of
    // revisions would have missed (1+1 vs 2).
    _ = try envs.publish(at(1), "nix", "B=1\x00");
    try t.expect(envs.revisionFor(at(1)) != reloaded);

    // An unrelated place is untouched throughout.
    try t.expectEqual(none, envs.revisionFor(at(2)));
}

test {
    std.testing.refAllDecls(@This());
}
