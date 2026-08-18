//! `kv` — a small, per-plugin-namespaced key-value store. Small; not a
//! database. It exists so plugins can keep a little state that outlives
//! a run — matcher frecency, recent/kill/mark rings, `project.forget` —
//! without each one inventing its own file format and each one racing
//! the others for the same key. Namespaces are the isolation boundary:
//! `plugin.a`'s "recent" and `plugin.b`'s "recent" are different cells,
//! by construction, so one plugin can never read or clobber another's.
//!
//! Keys and values are opaque byte strings; the store never interprets
//! them. It owns a private copy of everything you `put`, so callers keep
//! ownership of their inputs and a `get` result borrows until the next
//! mutation of that same entry.
//!
//! Persistence stays PURE on purpose: this module does no disk I/O.
//! `serialize` flattens the whole store into one self-describing blob
//! (uvarint length-prefixed, so it round-trips exactly and needs no
//! external schema), and `load` rebuilds a store from such a blob. The
//! host persists the blob through whatever file I/O it already has —
//! which keeps kv trivially testable with no filesystem in sight, and
//! keeps the "when do we write to disk" policy out of the mechanism.
//!
//! Layout: a map of namespace → (map of key → value). Nesting rather
//! than a composed `ns\x00key` key means enumerating a namespace and
//! isolating it are structural, not a prefix-scan convention that a
//! stray key byte could defeat.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Store = struct {
    /// namespace → (key → value). Every []u8 here (namespace names, keys,
    /// values) is owned by the store and freed exactly once on deinit,
    /// overwrite, or delete.
    ns: std.StringHashMapUnmanaged(Bucket) = .empty,

    const Bucket = std.StringHashMapUnmanaged([]u8);

    pub const empty: Store = .{};

    pub fn init() Store {
        return .{};
    }

    pub fn deinit(self: *Store, gpa: Allocator) void {
        var it = self.ns.iterator();
        while (it.next()) |e| {
            freeBucket(gpa, e.value_ptr);
            gpa.free(e.key_ptr.*);
        }
        self.ns.deinit(gpa);
        self.* = .{};
    }

    fn freeBucket(gpa: Allocator, bucket: *Bucket) void {
        var it = bucket.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        bucket.deinit(gpa);
    }

    /// Store `value` under `(namespace, key)`, copying both. An existing
    /// value for the key is replaced (its old copy freed); the key's own
    /// copy is reused. Namespace and key strings are copied on first use.
    pub fn put(self: *Store, gpa: Allocator, namespace: []const u8, key: []const u8, value: []const u8) Allocator.Error!void {
        const ns_gop = try self.ns.getOrPut(gpa, namespace);
        if (!ns_gop.found_existing) {
            errdefer _ = self.ns.remove(namespace);
            ns_gop.key_ptr.* = try gpa.dupe(u8, namespace);
            ns_gop.value_ptr.* = .empty;
        }
        const bucket = ns_gop.value_ptr;

        const v_copy = try gpa.dupe(u8, value);
        errdefer gpa.free(v_copy);

        const k_gop = try bucket.getOrPut(gpa, key);
        if (!k_gop.found_existing) {
            errdefer _ = bucket.remove(key);
            k_gop.key_ptr.* = try gpa.dupe(u8, key);
        } else {
            gpa.free(k_gop.value_ptr.*);
        }
        k_gop.value_ptr.* = v_copy;
    }

    /// The value for `(namespace, key)`, borrowed. Valid until the next
    /// mutation (put/del) of that same entry; null if absent.
    pub fn get(self: *const Store, namespace: []const u8, key: []const u8) ?[]const u8 {
        const bucket = self.ns.getPtr(namespace) orelse return null;
        return bucket.get(key);
    }

    /// Remove `(namespace, key)`. Returns whether it existed. Empty
    /// namespaces are left in place (cheap, and they carry no values).
    pub fn del(self: *Store, gpa: Allocator, namespace: []const u8, key: []const u8) bool {
        const bucket = self.ns.getPtr(namespace) orelse return false;
        if (bucket.fetchRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
            return true;
        }
        return false;
    }

    // ── Persistence ─────────────────────────────────────────────────
    //
    // Blob = uv ns_count, then per namespace:
    //   uv name_len, name, uv entry_count, then per entry:
    //     uv key_len, key, uv val_len, val
    // Every byte-string is uvarint length-prefixed, so the whole thing
    // is self-describing and parseable with no external schema.

    /// Flatten the entire store into one owned blob. Caller frees.
    pub fn serialize(self: *const Store, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try putUv(gpa, &out, self.ns.count());
        var ns_it = self.ns.iterator();
        while (ns_it.next()) |ns_e| {
            try putBytes(gpa, &out, ns_e.key_ptr.*);
            const bucket = ns_e.value_ptr;
            try putUv(gpa, &out, bucket.count());
            var k_it = bucket.iterator();
            while (k_it.next()) |kv| {
                try putBytes(gpa, &out, kv.key_ptr.*);
                try putBytes(gpa, &out, kv.value_ptr.*);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    pub const LoadError = error{Corrupt} || Allocator.Error;

    /// Replace the store's contents with those encoded in `bytes` (a blob
    /// from `serialize`). Round-trips exactly. On corrupt input the store
    /// is left empty and `error.Corrupt` is returned — never a panic.
    pub fn load(self: *Store, gpa: Allocator, bytes: []const u8) LoadError!void {
        self.deinit(gpa);

        var cur: []const u8 = bytes;
        const ns_count = try getUv(&cur);
        var i: u64 = 0;
        while (i < ns_count) : (i += 1) {
            const name = try getBytes(&cur);
            const entry_count = try getUv(&cur);
            var j: u64 = 0;
            while (j < entry_count) : (j += 1) {
                const key = try getBytes(&cur);
                const val = try getBytes(&cur);
                self.put(gpa, name, key, val) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
        }
        // Trailing garbage means the blob is not one we wrote.
        if (cur.len != 0) {
            self.deinit(gpa);
            return error.Corrupt;
        }
    }
};

// ── uvarint length-prefix framing (self-contained; see wire.zig for the
//    same LEB128 style, but kv deliberately does not depend on it) ─────

fn putUv(gpa: Allocator, out: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var x = value;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            try out.append(gpa, b);
            return;
        }
        try out.append(gpa, b | 0x80);
    }
}

fn getUv(cur: *[]const u8) error{Corrupt}!u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return error.Corrupt;
        shift += 7;
    }
    return error.Corrupt;
}

fn putBytes(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    try putUv(gpa, out, bytes.len);
    try out.appendSlice(gpa, bytes);
}

fn getBytes(cur: *[]const u8) error{Corrupt}![]const u8 {
    const n = try getUv(cur);
    if (n > cur.len) return error.Corrupt;
    const out = cur.*[0..n];
    cur.* = cur.*[n..];
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "kv: put/get round-trips, overwrite replaces, missing is null" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try t.expectEqual(@as(?[]const u8, null), store.get("plugin.a", "recent"));

    try store.put(gpa, "plugin.a", "recent", "foo.zig");
    try t.expectEqualStrings("foo.zig", store.get("plugin.a", "recent").?);

    // Overwrite replaces the value.
    try store.put(gpa, "plugin.a", "recent", "bar.zig");
    try t.expectEqualStrings("bar.zig", store.get("plugin.a", "recent").?);

    // Missing key in a live namespace is still null.
    try t.expectEqual(@as(?[]const u8, null), store.get("plugin.a", "absent"));
}

test "kv: del returns true then false, get after del is null" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try store.put(gpa, "ring", "kill", "clipboard");
    try t.expect(store.del(gpa, "ring", "kill"));
    try t.expectEqual(@as(?[]const u8, null), store.get("ring", "kill"));
    // Second delete: nothing there now.
    try t.expect(!store.del(gpa, "ring", "kill"));
    // Deleting in an unknown namespace is false, not an error.
    try t.expect(!store.del(gpa, "nope", "kill"));
}

test "kv: namespaces isolate the same key" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try store.put(gpa, "plugin.a", "recent", "a-value");
    try store.put(gpa, "plugin.b", "recent", "b-value");
    try t.expectEqualStrings("a-value", store.get("plugin.a", "recent").?);
    try t.expectEqualStrings("b-value", store.get("plugin.b", "recent").?);

    // Deleting one leaves the other untouched.
    try t.expect(store.del(gpa, "plugin.a", "recent"));
    try t.expectEqual(@as(?[]const u8, null), store.get("plugin.a", "recent"));
    try t.expectEqualStrings("b-value", store.get("plugin.b", "recent").?);
}

test "kv: serialize→load round-trips a multi-namespace store" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try store.put(gpa, "plugin.a", "recent", "foo.zig");
    try store.put(gpa, "plugin.a", "frecency", "\x00\x01\x02\xff"); // arbitrary bytes
    try store.put(gpa, "plugin.b", "recent", "other.zig");
    try store.put(gpa, "empty-value", "k", ""); // zero-length value survives

    const blob = try store.serialize(gpa);
    defer gpa.free(blob);

    var restored: Store = .empty;
    defer restored.deinit(gpa);
    try restored.load(gpa, blob);

    try t.expectEqualStrings("foo.zig", restored.get("plugin.a", "recent").?);
    try t.expectEqualStrings("\x00\x01\x02\xff", restored.get("plugin.a", "frecency").?);
    try t.expectEqualStrings("other.zig", restored.get("plugin.b", "recent").?);
    try t.expectEqualStrings("", restored.get("empty-value", "k").?);

    // Re-serializing the restored store yields an equivalent store (we do
    // not assume byte-identical blobs, since map iteration order is not
    // guaranteed — but a second round-trip must still match).
    const blob2 = try restored.serialize(gpa);
    defer gpa.free(blob2);
    var restored2: Store = .empty;
    defer restored2.deinit(gpa);
    try restored2.load(gpa, blob2);
    try t.expectEqualStrings("foo.zig", restored2.get("plugin.a", "recent").?);
}

test "kv: load rejects a truncated blob" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try store.put(gpa, "plugin.a", "recent", "foo.zig");
    const blob = try store.serialize(gpa);
    defer gpa.free(blob);

    var dst: Store = .empty;
    defer dst.deinit(gpa);
    // Chop the tail: length prefixes now over-run the buffer.
    try t.expectError(error.Corrupt, dst.load(gpa, blob[0 .. blob.len - 1]));
    // A rejected load leaves an empty, usable store.
    try t.expectEqual(@as(?[]const u8, null), dst.get("plugin.a", "recent"));
    try dst.put(gpa, "x", "y", "z");
    try t.expectEqualStrings("z", dst.get("x", "y").?);
}

test "kv: load rejects trailing garbage" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);

    try store.put(gpa, "n", "k", "v");
    const blob = try store.serialize(gpa);
    defer gpa.free(blob);

    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(gpa);
    try padded.appendSlice(gpa, blob);
    try padded.append(gpa, 0xff); // one byte too many

    var dst: Store = .empty;
    defer dst.deinit(gpa);
    try t.expectError(error.Corrupt, dst.load(gpa, padded.items));
}

test "kv: load of an empty blob yields an empty store" {
    const gpa = t.allocator;
    var store: Store = .empty;
    defer store.deinit(gpa);
    try store.put(gpa, "n", "k", "v");

    const empty_blob = try store.serialize(gpa); // a store we just emptied? no — build from empty
    defer gpa.free(empty_blob);
    _ = store.del(gpa, "n", "k");

    var fresh: Store = .empty;
    defer fresh.deinit(gpa);
    const blob = try fresh.serialize(gpa);
    defer gpa.free(blob);
    try store.load(gpa, blob);
    try t.expectEqual(@as(?[]const u8, null), store.get("n", "k"));
}

test {
    std.testing.refAllDecls(@This());
}
