//! `handles` — how a guest names a host-owned thing.
//!
//! Everything a plugin holds across a membrane call it holds by NUMBER: an
//! anchored range, a document frontier witness, an annotation claim, a live
//! subprocess, a socket. Seven such registries were written out by hand
//! across `wasm_abi/WasmPlugin.zig`, `wasm_host/sessions.zig`,
//! `wasm_host/proc.zig` and `quickjs.zig`, and each re-derived the same
//! invariants — badly, in the places nobody thought to look twice.
//!
//! There are two shapes here, and the difference is real rather than
//! historical:
//!
//!   - `Handles(T)` holds DATA the host must take apart with context this
//!     file does not have (drop two document anchors, free a frontier blob,
//!     hand a layer name back to the layer store). Sparse; closing removes
//!     the entry.
//!   - `Slots(T)` holds `*T` LIVE RESOURCES that own themselves and know how
//!     to die (`T.deinit()`): a subprocess, a connection. Dense, because
//!     callers sweep it every frame; and a closed slot STAYS, so a late
//!     `send` on a dead handle is a no-op rather than a hit on whatever was
//!     opened next.
//!
//! Both refuse to recycle a number, for the same reason: a guest may hold a
//! handle across calls, so reuse would let a stale release or a late callback
//! land on a resource minted after it.
//!
//! ── `Handles(T)` ────────────────────────────────────────────────────
//!
//! Three tables in `wasm_abi/WasmPlugin.zig` used to spell this out
//! separately — anchored ranges, document frontier witnesses, annotation
//! claims — and each re-derived the same three properties:
//!
//!   - **Monotonic, never recycled.** A handle names ONE resource for the
//!     life of the plugin that opened it. A late release or a stale callback
//!     therefore cannot target a resource minted after it (no handle ABA),
//!     which is the whole reason a guest is allowed to hold one across calls
//!     at all.
//!   - **Exhaustion fails CLOSED.** The wasm ABI reserves negative `i32` for
//!     failure, so the positive half of the 32-bit space is the entire
//!     budget. Running out returns `error.HandlesExhausted` rather than
//!     wrapping — a wrap would silently alias two live resources, which is
//!     precisely the failure the no-recycling rule exists to prevent.
//!   - **Storage is the table's; RELEASE is not.** `deinit` frees the table,
//!     never the values: what releasing a `T` means (drop two document
//!     anchors, free a frontier blob, hand a layer name back to the layer
//!     store) is knowledge this file does not have and should not acquire.
//!     Callers drain through `valueIterator` first. The duplication worth
//!     removing was handle ALLOCATION, and that is all this owns.
//!
//! Two of the three tables checked exhaustion and one — `annotations` — did
//! not. That asymmetry, invisible while the logic was written out three
//! times, is why this is a type rather than a convention.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{HandlesExhausted} || Allocator.Error;

/// A monotonic handle → `T` table. `T` is held BY VALUE; a `T` that owns
/// memory is released by the caller draining `valueIterator` before `deinit`.
pub fn Handles(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.AutoHashMapUnmanaged(u32, T) = .empty,
        /// The next handle to issue. Advances only on a successful `open`, so
        /// a failed allocation costs no capability; never decreases, never
        /// wraps (see `open`).
        next: u32 = 0,

        pub const empty: Self = .{};

        /// Store `value` and return the handle that names it. The handle is
        /// unique for this table's whole life.
        pub fn open(self: *Self, gpa: Allocator, value: T) Error!u32 {
            // The positive half of the i32 space is the budget; past it there
            // is no handle left that a guest could tell from a failure.
            if (self.next > std.math.maxInt(i32)) return error.HandlesExhausted;
            const handle = self.next;
            try self.map.putNoClobber(gpa, handle, value);
            self.next += 1;
            return handle;
        }

        pub fn get(self: *const Self, handle: u32) ?T {
            return self.map.get(handle);
        }

        pub fn getPtr(self: *Self, handle: u32) ?*T {
            return self.map.getPtr(handle);
        }

        /// Remove `handle`, handing its value back so the caller can release
        /// it. Null for an unknown or already-taken handle, which makes every
        /// close idempotent without the caller tracking that itself.
        pub fn take(self: *Self, handle: u32) ?T {
            const removed = self.map.fetchRemove(handle) orelse return null;
            return removed.value;
        }

        pub fn valueIterator(self: *Self) std.AutoHashMapUnmanaged(u32, T).ValueIterator {
            return self.map.valueIterator();
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// Drop every entry, keeping the allocation and the handle counter.
        /// The counter deliberately survives: reuse after a bulk clear would
        /// be exactly the ABA this table refuses.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.map.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.map.deinit(gpa);
        }
    };
}

/// A dense, stable-index registry of live `*T` resources a guest holds by
/// handle. `T` must expose `deinit(*T) void` — every resource here is an
/// actor that has to be TOLD to stop (kill a child and join its reader, shut
/// a socket and join its reader), which is exactly why this shape can own
/// release where `Handles(T)` cannot.
///
/// A handle is an index and is never reused. `close` nulls the slot but keeps
/// it, so a guest that sends on a handle it already closed hits a dead slot
/// instead of whatever was opened after it.
pub fn Slots(comptime T: type) type {
    return struct {
        const Self = @This();

        list: std.ArrayList(?*T) = .empty,

        pub const empty: Self = .{};

        /// Register `value` and return its handle. On failure the caller still
        /// owns `value` (nothing was stored), so it releases it as it would
        /// any other failed start.
        pub fn open(self: *Self, gpa: Allocator, value: *T) Allocator.Error!u32 {
            const handle: u32 = @intCast(self.list.items.len);
            try self.list.append(gpa, value);
            return handle;
        }

        /// The live resource behind a guest-supplied handle, or null when the
        /// handle is negative, out of range, or already closed.
        ///
        /// Takes `i32` deliberately: that is what actually crosses the
        /// membrane. The import table DECLARES these parameters `.u32`, but a
        /// handler receives the raw word, so a guest passing 2^31 arrives here
        /// negative — and a bare `@intCast` to `usize` would panic the HOST on
        /// a guest's bad argument. Every lookup goes through this one door so
        /// that check cannot be forgotten in a fifth copy.
        pub fn at(self: *Self, handle: i32) ?*T {
            if (handle < 0) return null;
            const i: usize = @intCast(handle);
            if (i >= self.list.items.len) return null;
            return self.list.items[i];
        }

        /// Release the resource behind `handle` and null its slot. Idempotent;
        /// a stale or nonsense handle is simply nothing to close.
        pub fn close(self: *Self, handle: i32) void {
            const live = self.at(handle) orelse return;
            live.deinit();
            self.list.items[@intCast(handle)] = null;
        }

        /// The slot array, for callers that sweep every live resource each
        /// frame (drain, tick) and need the INDEX to call back with. Const:
        /// a sweep may drive a resource it finds, but only `open`/`close` may
        /// change which slots exist.
        pub fn slice(self: *const Self) []const ?*T {
            return self.list.items;
        }

        pub fn len(self: *const Self) usize {
            return self.list.items.len;
        }

        /// Release every live resource, then the list. Unlike `Handles(T)`,
        /// this shape can finish the job: `T` knows how to die.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.list.items) |maybe| if (maybe) |live| live.deinit();
            self.list.deinit(gpa);
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "handles: monotonic, never recycled" {
    const gpa = t.allocator;
    var h: Handles(u64) = .empty;
    defer h.deinit(gpa);

    const a = try h.open(gpa, 10);
    const b = try h.open(gpa, 20);
    try t.expect(a != b);

    // Closing `a` must not free its number for the next open: a stale release
    // arriving later would otherwise land on an unrelated resource.
    try t.expectEqual(@as(?u64, 10), h.take(a));
    const c = try h.open(gpa, 30);
    try t.expect(c != a);
    try t.expect(c != b);

    // Idempotent close.
    try t.expectEqual(@as(?u64, null), h.take(a));
}

test "handles: a bulk clear does not reopen the retired numbers" {
    const gpa = t.allocator;
    var h: Handles(u64) = .empty;
    defer h.deinit(gpa);

    const a = try h.open(gpa, 1);
    _ = try h.open(gpa, 2);
    h.clearRetainingCapacity();
    try t.expectEqual(@as(usize, 0), h.count());

    const fresh = try h.open(gpa, 3);
    try t.expect(fresh != a);
}

test "handles: exhaustion fails closed rather than wrapping" {
    const gpa = t.allocator;
    var h: Handles(u64) = .empty;
    defer h.deinit(gpa);

    // Park the counter one past the last handle a guest could tell from a
    // failure result; the next open must refuse, not alias handle 0.
    h.next = std.math.maxInt(i32);
    const last = try h.open(gpa, 1);
    try t.expectEqual(@as(u32, std.math.maxInt(i32)), last);
    try t.expectError(error.HandlesExhausted, h.open(gpa, 2));
    // Still refuses on every later attempt — the counter never wrapped.
    try t.expectError(error.HandlesExhausted, h.open(gpa, 3));
}

test "handles: values are the caller's to release" {
    const gpa = t.allocator;
    var h: Handles([]u8) = .empty;
    defer h.deinit(gpa);

    _ = try h.open(gpa, try gpa.dupe(u8, "one"));
    _ = try h.open(gpa, try gpa.dupe(u8, "two"));

    // The drain-then-deinit shape every call site uses; `deinit` alone would
    // leak, and that is deliberate — this table cannot know what a `T` owns.
    var it = h.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    h.clearRetainingCapacity();
    try t.expectEqual(@as(usize, 0), h.count());
}

/// A stand-in for the live resources `Slots` really holds (a REPL session, a
/// net connection, a proc stream): self-owning, and it knows how to die.
const FakeResource = struct {
    gpa: Allocator,
    stopped: *usize,

    fn start(gpa: Allocator, stopped: *usize) !*FakeResource {
        const self = try gpa.create(FakeResource);
        self.* = .{ .gpa = gpa, .stopped = stopped };
        return self;
    }

    pub fn deinit(self: *FakeResource) void {
        self.stopped.* += 1;
        self.gpa.destroy(self);
    }
};

test "slots: a closed handle stays dead rather than naming the next resource" {
    const gpa = t.allocator;
    var stopped: usize = 0;
    var s: Slots(FakeResource) = .empty;
    defer s.deinit(gpa);

    const a = try s.open(gpa, try FakeResource.start(gpa, &stopped));
    s.close(@intCast(a));
    try t.expectEqual(@as(usize, 1), stopped);

    // The slot is kept, so the next open cannot land on `a`'s number — a
    // guest that sends on its stale handle must hit nothing.
    const b = try s.open(gpa, try FakeResource.start(gpa, &stopped));
    try t.expect(a != b);
    try t.expectEqual(@as(?*FakeResource, null), s.at(@intCast(a)));
    try t.expect(s.at(@intCast(b)) != null);

    // Idempotent close.
    s.close(@intCast(a));
    try t.expectEqual(@as(usize, 1), stopped);
}

test "slots: a hostile handle is refused, not @intCast into a host panic" {
    const gpa = t.allocator;
    var stopped: usize = 0;
    var s: Slots(FakeResource) = .empty;
    defer s.deinit(gpa);
    _ = try s.open(gpa, try FakeResource.start(gpa, &stopped));

    // The import table declares these parameters `.u32`, but the handler gets
    // the raw word: a guest passing 2^31 arrives NEGATIVE. Before this door
    // existed, `wasm_host/sessions.zig` cast it straight to `usize` and took
    // the host down on a guest's bad argument.
    try t.expectEqual(@as(?*FakeResource, null), s.at(-1));
    try t.expectEqual(@as(?*FakeResource, null), s.at(std.math.minInt(i32)));
    try t.expectEqual(@as(?*FakeResource, null), s.at(9999));
    s.close(-1); // must not panic, must not stop the live resource
    s.close(std.math.minInt(i32));
    try t.expectEqual(@as(usize, 0), stopped);
}

test "slots: teardown stops every live resource exactly once" {
    const gpa = t.allocator;
    var stopped: usize = 0;
    var s: Slots(FakeResource) = .empty;

    _ = try s.open(gpa, try FakeResource.start(gpa, &stopped));
    const mid = try s.open(gpa, try FakeResource.start(gpa, &stopped));
    _ = try s.open(gpa, try FakeResource.start(gpa, &stopped));
    s.close(@intCast(mid)); // already dead: teardown must not double-free it

    s.deinit(gpa);
    try t.expectEqual(@as(usize, 3), stopped);
}

test {
    std.testing.refAllDecls(@This());
}
