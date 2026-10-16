//! A cache that cannot grow without bound. Each entry costs bytes, as its
//! owner counts them; the cache holds at most `Limits.bytes` of them and at
//! most `Limits.entries` entries, and makes room by dropping the entry used
//! least recently. An entry dearer than the whole budget is refused, not
//! cached. Nothing here knows what is cached: shaped text, laid-out
//! documents, rasterized images and GPU handles all fit, because the owner
//! says how to hash, compare, cost and release its keys and values.
//!
//! `put` takes ownership of the key and value it is handed, even when it
//! fails or refuses them: whatever happens, each is released exactly once.
//! A pointer `get` returns is the cache's, valid until the cache next
//! changes (`put`, `remove`, `clear`) — a caller that keeps a value across
//! one copies it out.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    /// The most bytes the entries may cost together.
    bytes: usize,
    /// The most entries, whatever they cost.
    entries: u32,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    /// Entries dropped to make room.
    evictions: u64 = 0,
    /// Entries refused for costing more than the whole budget.
    refused: u64 = 0,
};

/// `Ctx` says what the cache cannot know about `K` and `V`:
///
///     fn hash(Ctx, K) u64
///     fn eql(Ctx, K, K) bool
///     fn cost(Ctx, K, V) usize                // bytes the entry holds
///     fn release(Ctx, Allocator, K, V) void   // frees what `put` was given
pub fn Bounded(comptime K: type, comptime V: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const none = std.math.maxInt(u32);

        const Entry = struct {
            key: K,
            value: V,
            hash: u64,
            cost: usize,
            /// The next entry whose key hashes the same (`none` ends it).
            same_hash: u32,
            /// Recency, a doubly linked list from `newest` to `oldest`.
            newer: u32,
            older: u32,
        };

        gpa: Allocator,
        ctx: Ctx,
        limits: Limits,
        stats: Stats = .{},
        /// Every slot ever used; those in `vacant` hold nothing.
        slots: std.ArrayList(Entry) = .empty,
        vacant: std.ArrayList(u32) = .empty,
        /// A hash to the first entry of its chain.
        heads: std.AutoHashMapUnmanaged(u64, u32) = .empty,
        newest: u32 = none,
        oldest: u32 = none,
        bytes: usize = 0,
        count: u32 = 0,

        pub fn init(gpa: Allocator, ctx: Ctx, limits: Limits) Self {
            std.debug.assert(limits.entries > 0 and limits.entries < none);
            return .{ .gpa = gpa, .ctx = ctx, .limits = limits };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.slots.deinit(self.gpa);
            self.vacant.deinit(self.gpa);
            self.heads.deinit(self.gpa);
            self.* = undefined;
        }

        /// Release every entry, keeping the cache's own storage for reuse.
        pub fn clear(self: *Self) void {
            var i = self.newest;
            while (i != none) {
                const e = self.slots.items[i];
                self.ctx.release(self.gpa, e.key, e.value);
                i = e.older;
            }
            self.slots.clearRetainingCapacity();
            self.vacant.clearRetainingCapacity();
            self.heads.clearRetainingCapacity();
            self.newest = none;
            self.oldest = none;
            self.bytes = 0;
            self.count = 0;
        }

        /// The value cached for `key`, now the most recently used.
        pub fn get(self: *Self, key: K) ?*const V {
            const i = self.find(key, self.ctx.hash(key)) orelse {
                self.stats.misses += 1;
                return null;
            };
            self.stats.hits += 1;
            self.unlinkRecency(i);
            self.linkNewest(i);
            return &self.slots.items[i].value;
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.find(key, self.ctx.hash(key)) != null;
        }

        /// Cache `value` for `key`, replacing what `key` had, dropping the
        /// least recently used entries until it fits. Owns both from the
        /// call on (see the file's comment).
        pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
            const hash = self.ctx.hash(key);
            const cost = self.ctx.cost(key, value);
            if (cost > self.limits.bytes) {
                self.stats.refused += 1;
                self.ctx.release(self.gpa, key, value);
                return;
            }
            if (self.find(key, hash)) |old| self.drop(old);
            // Room in the index first, so a failure leaves the cache whole.
            self.reserve() catch |err| {
                self.ctx.release(self.gpa, key, value);
                return err;
            };
            while (self.count > 0 and (self.count + 1 > self.limits.entries or self.bytes + cost > self.limits.bytes)) {
                self.drop(self.oldest);
                self.stats.evictions += 1;
            }
            const i: u32 = self.vacant.pop() orelse blk: {
                self.slots.appendAssumeCapacity(undefined);
                break :blk @intCast(self.slots.items.len - 1);
            };
            const head = self.heads.getOrPutAssumeCapacity(hash);
            self.slots.items[i] = .{
                .key = key,
                .value = value,
                .hash = hash,
                .cost = cost,
                .same_hash = if (head.found_existing) head.value_ptr.* else none,
                .newer = none,
                .older = none,
            };
            head.value_ptr.* = i;
            self.linkNewest(i);
            self.bytes += cost;
            self.count += 1;
        }

        /// Release `key`'s entry; whether there was one.
        pub fn remove(self: *Self, key: K) bool {
            const i = self.find(key, self.ctx.hash(key)) orelse return false;
            self.drop(i);
            return true;
        }

        fn reserve(self: *Self) Allocator.Error!void {
            if (self.vacant.items.len == 0) try self.slots.ensureUnusedCapacity(self.gpa, 1);
            try self.heads.ensureUnusedCapacity(self.gpa, 1);
            // A dropped entry's slot goes back on `vacant`: room for every
            // slot there could be, so dropping never allocates.
            try self.vacant.ensureTotalCapacity(self.gpa, self.slots.items.len + 1);
        }

        fn find(self: *const Self, key: K, hash: u64) ?u32 {
            var i = self.heads.get(hash) orelse return null;
            while (i != none) : (i = self.slots.items[i].same_hash) {
                if (self.ctx.eql(self.slots.items[i].key, key)) return i;
            }
            return null;
        }

        fn drop(self: *Self, i: u32) void {
            const e = self.slots.items[i];
            // Out of its hash chain.
            const head = self.heads.getPtr(e.hash).?;
            if (head.* == i) {
                if (e.same_hash == none) _ = self.heads.remove(e.hash) else head.* = e.same_hash;
            } else {
                var p = head.*;
                while (self.slots.items[p].same_hash != i) p = self.slots.items[p].same_hash;
                self.slots.items[p].same_hash = e.same_hash;
            }
            self.unlinkRecency(i);
            self.bytes -= e.cost;
            self.count -= 1;
            self.vacant.appendAssumeCapacity(i);
            self.ctx.release(self.gpa, e.key, e.value);
        }

        fn unlinkRecency(self: *Self, i: u32) void {
            const e = &self.slots.items[i];
            if (e.newer != none) self.slots.items[e.newer].older = e.older else self.newest = e.older;
            if (e.older != none) self.slots.items[e.older].newer = e.newer else self.oldest = e.newer;
            e.newer = none;
            e.older = none;
        }

        fn linkNewest(self: *Self, i: u32) void {
            const e = &self.slots.items[i];
            e.older = self.newest;
            e.newer = none;
            if (self.newest != none) self.slots.items[self.newest].newer = i else self.oldest = i;
            self.newest = i;
        }
    };
}

const testing = std.testing;

/// Keys and values that count their releases and may all collide.
const TestCtx = struct {
    released: *std.ArrayList(u32),
    collide: bool = false,

    pub fn hash(self: TestCtx, k: u32) u64 {
        return if (self.collide) 7 else std.hash.int(k);
    }
    pub fn eql(_: TestCtx, a: u32, b: u32) bool {
        return a == b;
    }
    pub fn cost(_: TestCtx, _: u32, v: []u8) usize {
        return v.len;
    }
    pub fn release(self: TestCtx, gpa: Allocator, k: u32, v: []u8) void {
        gpa.free(v);
        self.released.append(testing.allocator, k) catch unreachable;
    }
};

fn testValue(n: usize) ![]u8 {
    const v = try testing.allocator.alloc(u8, n);
    @memset(v, 0);
    return v;
}

test "cache: the least recently used goes first, and a read makes an entry recent" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released }, .{ .bytes = 30, .entries = 100 });
    defer c.deinit();

    try c.put(1, try testValue(10));
    try c.put(2, try testValue(10));
    try c.put(3, try testValue(10));
    _ = c.get(1); // 2 is now the oldest
    try c.put(4, try testValue(10));
    try testing.expectEqualSlices(u32, &.{2}, released.items);
    try testing.expect(c.contains(1) and c.contains(3) and c.contains(4));
    try testing.expectEqual(@as(usize, 30), c.bytes);
    try testing.expectEqual(@as(u64, 1), c.stats.evictions);
}

test "cache: the entry count bounds it whatever the entries cost" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released }, .{ .bytes = 1 << 20, .entries = 3 });
    defer c.deinit();
    for (0..10) |k| try c.put(@intCast(k), try testValue(1));
    try testing.expectEqual(@as(u32, 3), c.count);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, released.items);
    // The storage is bounded too: slots are reused, never more than the limit.
    try testing.expect(c.slots.items.len <= 3);
}

test "cache: an entry dearer than the budget is refused and released, and the rest stay" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released }, .{ .bytes = 16, .entries = 8 });
    defer c.deinit();
    try c.put(1, try testValue(8));
    try c.put(2, try testValue(17));
    try testing.expect(c.contains(1) and !c.contains(2));
    try testing.expectEqualSlices(u32, &.{2}, released.items);
    try testing.expectEqual(@as(u64, 1), c.stats.refused);
}

test "cache: keys whose hashes collide are told apart, and each comes out of the chain alone" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released, .collide = true }, .{ .bytes = 100, .entries = 100 });
    defer c.deinit();
    for (0..5) |k| try c.put(@intCast(k), try testValue(k + 1));
    for (0..5) |k| try testing.expectEqual(k + 1, c.get(@intCast(k)).?.len);
    try testing.expect(c.remove(2)); // the middle of the chain
    try testing.expect(c.remove(4)); // its head (the newest put)
    try testing.expect(c.remove(0)); // its tail
    try testing.expect(!c.contains(2) and !c.contains(4) and !c.contains(0));
    try testing.expectEqual(@as(usize, 2), c.get(1).?.len);
    try testing.expectEqual(@as(usize, 4), c.get(3).?.len);
    try testing.expect(!c.remove(9));
}

test "cache: putting a key again replaces its value, releasing the old one" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released }, .{ .bytes = 100, .entries = 4 });
    defer c.deinit();
    try c.put(1, try testValue(5));
    try c.put(1, try testValue(9));
    try testing.expectEqual(@as(usize, 9), c.get(1).?.len);
    try testing.expectEqual(@as(u32, 1), c.count);
    try testing.expectEqual(@as(usize, 9), c.bytes);
    try testing.expectEqualSlices(u32, &.{1}, released.items);
}

test "cache: clear releases everything once, and the cache is usable after" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var c = Bounded(u32, []u8, TestCtx).init(testing.allocator, .{ .released = &released }, .{ .bytes = 100, .entries = 8 });
    defer c.deinit();
    for (0..4) |k| try c.put(@intCast(k), try testValue(2));
    c.clear();
    try testing.expectEqual(@as(usize, 4), released.items.len);
    try testing.expectEqual(@as(usize, 0), c.bytes);
    try c.put(7, try testValue(3));
    try testing.expect(c.contains(7));
}

test "cache: a put that cannot allocate still releases what it was handed, and leaves the cache whole" {
    var released: std.ArrayList(u32) = .empty;
    defer released.deinit(testing.allocator);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var c = Bounded(u32, []u8, TestCtx).init(failing.allocator(), .{ .released = &released }, .{ .bytes = 100, .entries = 8 });
    defer c.deinit();
    // The value comes from the failing allocator's parent so it frees cleanly.
    const v = try failing.allocator().alloc(u8, 0);
    failing.fail_index = failing.alloc_index; // the next allocation fails
    try testing.expectError(error.OutOfMemory, c.put(1, v));
    try testing.expectEqualSlices(u32, &.{1}, released.items);
    try testing.expectEqual(@as(u32, 0), c.count);
}
