//! `handles` — the ONE monotonic capability table behind every host-owned
//! resource a guest holds by number.
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

test {
    std.testing.refAllDecls(@This());
}
